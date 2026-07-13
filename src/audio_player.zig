//! Riproduzione audio del player video di zuer. Apre lo stream audio del file
//! (handle libav separato da quello video), lo decodifica e ricampiona a
//! **f32 interleaved 48 kHz stereo** (swresample), e lo suona su un `DeviceOut`
//! di zicro in un **thread dedicato**. La scrittura sul device è bloccante
//! (backpressure) → il thread avanza a tempo reale e mantiene un **clock**
//! (secondi riprodotti) che `video.zig` usa come master per sincronizzare il
//! video (oggi il video avanza a wall-clock; con audio presente segue questo).
//!
//! Handle separato apposta: il container si legge da un solo thread, e tenere
//! l'audio su un proprio `AVFormatContext` evita di intrecciare il pull dei frame
//! video (nel worker) con il pacing audio (real-time). Costo: il file è aperto
//! due volte — trascurabile per un viewer, in cambio di zero contese sul demux.

const std = @import("std");
const builtin = @import("builtin");
const player = @import("decoders/player.zig");
const c = player.c;
const zicro = @import("zicro");
const DeviceOut = zicro.audio_device.DeviceOut;
const AudioBlock = zicro.audio.AudioBlock;

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

/// Sleep breve cross-platform senza `io` (il thread audio non ne ha uno).
fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        Sleep(ms);
    } else {
        const req = std.c.timespec{ .sec = ms / 1000, .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&req, null);
    }
}

const OUT_RATE: c_int = 48_000;
const OUT_CH: c_int = 2;
// Il device bufferizza ~qualche decina di ms davanti al "consumato"; il clock è
// il "sottomesso" meno questa latenza stimata, così il video non anticipa. Allineato
// al ring PipeWire di zicro (4 quanti da 256 @48k ≈ 21 ms + latenza grafo ≈ 26 ms).
const LATENCY_S: f64 = 0.03;

/// Campioni (mono) tenuti in coda per l'oscilloscopio del player audio (~170 ms a
/// 48 kHz). Potenza di 2 → il modulo sul ring è un semplice AND. Abbondante rispetto
/// alla finestra mostrata (~43 ms) così la testina di lettura ancorata al wall-clock
/// ha margine per scorrere senza uscire dai campioni validi.
const scope_len: usize = 8192;

pub const AudioPlayer = struct {
    fmt_ctx: [*c]c.AVFormatContext,
    codec_ctx: [*c]c.AVCodecContext,
    frame: [*c]c.AVFrame,
    packet: [*c]c.AVPacket,
    swr: ?*c.SwrContext,
    stream_idx: c_int,
    time_base: f64,
    in_rate: c_int,
    dev: DeviceOut,
    gpa: std.mem.Allocator,

    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    playing: std.atomic.Value(bool) = .init(true),
    seek_ms: std.atomic.Value(i64) = .init(-1), // richiesta di seek (ms), -1 = nessuna
    clock_ms: std.atomic.Value(i64) = .init(0), // posizione riprodotta stimata (ms)
    // Soglia post-seek in secondi (-1 = nessuna): av_seek_frame(BACKWARD) riparte
    // dal keyframe PRECEDENTE la posizione chiesta, quindi i primi frame decodificati
    // sono pre-seek. Vanno scartati finché pts < soglia, altrimenti si suonano
    // campioni vecchi col clock che dice la posizione nuova → offset A/V sistematico.
    // Toccata solo dal thread audio (la richiesta passa dall'atomico `seek_ms`).
    skip_until_s: f64 = -1,

    // Durata totale del brano in secondi (0 se il container non la fornisce): usata
    // dal player audio-only per la timeline dei controlli.
    duration_s: f64 = 0,

    // Tap per il visualizzatore (oscilloscopio): ring degli ultimi campioni MONO
    // prodotti. Il thread audio scrive, il thread finestra legge con `copyScope`.
    // Nessun lock: un campione strappato è invisibile in un visualizzatore; solo
    // l'indice di scrittura `scope_w` usa un atomico per un avanzamento coerente.
    scope: [scope_len]f32 = [_]f32{0} ** scope_len,
    scope_w: std.atomic.Value(usize) = .init(0),

    /// Apre l'audio del file e avvia il thread. `null` (senza errore) se il file
    /// non ha stream audio o il device non si apre → il video va muto.
    pub fn start(path_z: [*:0]const u8, gpa: std.mem.Allocator) ?*AudioPlayer {
        return startInner(path_z, gpa) catch null;
    }

    /// Corpo di `start` con gestione errori esplicita: gli early-out sono errori
    /// veri (non `return null`) così gli `errdefer` scattano e liberano davvero
    /// format ctx (e il suo fd!), codec ctx, swr, frame, packet e device — un
    /// `return null` li salterebbe, leakando risorse per ogni video muto aperto.
    fn startInner(path_z: [*:0]const u8, gpa: std.mem.Allocator) anyerror!*AudioPlayer {
        var fmt_ctx: [*c]c.AVFormatContext = null;
        if (c.avformat_open_input(&fmt_ctx, path_z, null, null) != 0) return error.OpenFailed;
        errdefer c.avformat_close_input(&fmt_ctx);
        if (c.avformat_find_stream_info(fmt_ctx, null) < 0) return error.NoStreamInfo;

        var codec: [*c]const c.AVCodec = null;
        const idx = c.av_find_best_stream(fmt_ctx, c.AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
        if (idx < 0 or codec == null) return error.NoAudio; // nessun audio: video muto
        const stream = fmt_ctx.*.streams[@intCast(idx)];

        const codec_ctx = c.avcodec_alloc_context3(codec) orelse return error.AllocFailed;
        var cc_free = codec_ctx;
        errdefer c.avcodec_free_context(&cc_free);
        if (c.avcodec_parameters_to_context(codec_ctx, stream.*.codecpar) < 0) return error.CodecParamsFailed;
        if (c.avcodec_open2(codec_ctx, codec, null) < 0) return error.CodecOpenFailed;

        // swresample → f32 interleaved 48k stereo. Il layout di ingresso è quello
        // REALE del codec quando è valido (5.1(side) ≠ 5.1: il default sbaglierebbe
        // il mapping dei canali); il default per numero di canali è solo fallback.
        var in_layout: c.AVChannelLayout = undefined;
        if (c.av_channel_layout_check(&codec_ctx.*.ch_layout) != 0) {
            if (c.av_channel_layout_copy(&in_layout, &codec_ctx.*.ch_layout) < 0) return error.ChannelLayoutFailed;
        } else {
            const in_ch: c_int = if (codec_ctx.*.ch_layout.nb_channels > 0) codec_ctx.*.ch_layout.nb_channels else 2;
            c.av_channel_layout_default(&in_layout, in_ch);
        }
        // La copia può allocare (layout custom); swr ne fa una propria copia.
        defer c.av_channel_layout_uninit(&in_layout);
        var out_layout: c.AVChannelLayout = undefined;
        c.av_channel_layout_default(&out_layout, OUT_CH);
        var swr: ?*c.SwrContext = null;
        errdefer c.swr_free(&swr); // no-op se null; copre anche swr_init fallita
        if (c.swr_alloc_set_opts2(&swr, &out_layout, c.AV_SAMPLE_FMT_FLT, OUT_RATE, &in_layout, codec_ctx.*.sample_fmt, codec_ctx.*.sample_rate, 0, null) < 0) return error.SwrSetupFailed;
        if (swr == null or c.swr_init(swr) < 0) return error.SwrInitFailed;

        const frame = c.av_frame_alloc() orelse return error.AllocFailed;
        var f_free = frame;
        errdefer c.av_frame_free(&f_free);
        const packet = c.av_packet_alloc() orelse return error.AllocFailed;
        var p_free = packet;
        errdefer c.av_packet_free(&p_free);

        var dev = try DeviceOut.open(@intCast(OUT_RATE), @intCast(OUT_CH));
        errdefer dev.close();

        const tb = stream.*.time_base;
        const time_base: f64 = if (tb.den != 0) @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(tb.den)) else 0;

        // Durata: preferisci quella del container (AV_TIME_BASE = 1e6), poi lo stream
        // (nel suo time_base). 0 se ignota → timeline senza durata (solo posizione).
        var duration_s: f64 = 0;
        if (fmt_ctx.*.duration > 0) {
            duration_s = @as(f64, @floatFromInt(fmt_ctx.*.duration)) / 1_000_000.0;
        } else if (stream.*.duration > 0 and time_base > 0) {
            duration_s = @as(f64, @floatFromInt(stream.*.duration)) * time_base;
        }

        const self = try gpa.create(AudioPlayer);
        errdefer gpa.destroy(self); // spawn fallito → gli errdefer sopra liberano libav+dev
        self.* = .{
            .fmt_ctx = fmt_ctx,
            .codec_ctx = codec_ctx,
            .frame = frame,
            .packet = packet,
            .swr = swr,
            .stream_idx = idx,
            .time_base = time_base,
            .in_rate = codec_ctx.*.sample_rate,
            .dev = dev,
            .gpa = gpa,
            .duration_s = duration_s,
        };
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    /// Posizione audio riprodotta in secondi (clock master per il video). Valore
    /// GREZZO: salta a passi di ~20 ms (un blocco audio per volta). Il video lo usa
    /// come riferimento ma avanza col wall-clock correggendo la deriva verso questo,
    /// così la cadenza dei frame resta regolare (vedi `advanceVideo`).
    pub fn clockSeconds(self: *const AudioPlayer) f64 {
        return @as(f64, @floatFromInt(self.clock_ms.load(.monotonic))) / 1000.0;
    }

    pub fn setPlaying(self: *AudioPlayer, on: bool) void {
        self.playing.store(on, .monotonic);
    }

    /// Capacità del ring dell'oscilloscopio e cadenza di uscita: servono al
    /// visualizzatore per ancorare la testina di lettura entro i campioni validi.
    pub const scope_capacity: usize = scope_len;
    pub const scope_rate: f64 = 48_000.0;

    /// Totale campioni (mono) scritti finora nel ring: indice assoluto del prossimo.
    pub fn scopeWritten(self: *const AudioPlayer) usize {
        return self.scope_w.load(.monotonic);
    }

    /// Copia `dst.len` campioni mono che TERMINANO all'indice assoluto `end_abs`
    /// (dal più vecchio al più recente). Le posizioni che precedono l'inizio del
    /// prodotto restano a 0. Il chiamante deve tenere `end_abs` entro la finestra
    /// valida del ring (`[scopeWritten - scope_capacity, scopeWritten]`); oltre, i
    /// campioni sarebbero già sovrascritti.
    pub fn copyScopeAt(self: *const AudioPlayer, dst: []f32, end_abs: usize) void {
        const n = dst.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const back = n - i; // 1 = campione a `end_abs`
            dst[i] = if (back > end_abs) 0 else self.scope[(end_abs - back) & (scope_len - 1)];
        }
    }

    pub fn seek(self: *AudioPlayer, seconds: f64) void {
        self.seek_ms.store(@intFromFloat(@max(0, seconds) * 1000.0), .monotonic);
    }

    /// Ferma il thread e libera tutto (idempotente lato chiamante: `video.zig`
    /// lo chiama una volta e azzera il puntatore).
    pub fn stopAndDestroy(self: *AudioPlayer) void {
        self.stop.store(true, .monotonic);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.teardown();
        self.gpa.destroy(self);
    }

    fn teardown(self: *AudioPlayer) void {
        self.dev.close();
        c.swr_free(&self.swr);
        c.av_packet_free(&self.packet);
        c.av_frame_free(&self.frame);
        c.avcodec_free_context(&self.codec_ctx);
        c.avformat_close_input(&self.fmt_ctx);
    }

    fn threadMain(self: *AudioPlayer) void {
        var submitted: i64 = 0; // frame a 48k sottomessi al device
        // Buffer di conversione riusato (cresce al bisogno).
        var out: std.ArrayListUnmanaged(f32) = .empty;
        defer out.deinit(self.gpa);

        while (!self.stop.load(.monotonic)) {
            const sk = self.seek_ms.swap(-1, .monotonic);
            if (sk >= 0) {
                const ts: i64 = if (self.time_base > 0) @intFromFloat((@as(f64, @floatFromInt(sk)) / 1000.0) / self.time_base) else 0;
                _ = c.av_seek_frame(self.fmt_ctx, self.stream_idx, ts, c.AVSEEK_FLAG_BACKWARD);
                c.avcodec_flush_buffers(self.codec_ctx);
                // `submitted` qui è provvisorio: si riallinea sul pts reale del primo
                // frame valido (>= soglia) più sotto, scartando i frame pre-seek.
                self.skip_until_s = @as(f64, @floatFromInt(sk)) / 1000.0;
                submitted = @divTrunc(sk * OUT_RATE, 1000);
                self.clock_ms.store(sk, .monotonic);
            }
            if (!self.playing.load(.monotonic)) {
                sleepMs(10);
                continue;
            }
            // Legge/decodifica un frame audio; a EOF fa loop (come il video).
            const got = self.decodeOne() catch {
                sleepMs(5);
                continue;
            };
            if (!got) {
                _ = c.av_seek_frame(self.fmt_ctx, self.stream_idx, 0, c.AVSEEK_FLAG_BACKWARD);
                c.avcodec_flush_buffers(self.codec_ctx);
                submitted = 0;
                self.skip_until_s = -1;
                continue;
            }
            // Post-seek: scarta i frame del keyframe precedente (pts < soglia) e
            // riallinea `submitted` al pts reale del primo frame buono, così il
            // clock conta solo campioni davvero riprodotti.
            if (self.skip_until_s >= 0) {
                const pts_s = self.framePtsSeconds();
                if (pts_s >= 0 and pts_s < self.skip_until_s) continue;
                const base_s: f64 = if (pts_s >= 0) pts_s else self.skip_until_s;
                submitted = @intFromFloat(base_s * @as(f64, @floatFromInt(OUT_RATE)));
                self.skip_until_s = -1;
            }
            const n = self.convert(&out) catch continue;
            if (n == 0) continue;
            // Tap oscilloscopio: downmix mono di questo blocco nel ring PRIMA del
            // play bloccante, così il visualizzatore vede i campioni appena decodificati.
            {
                var w = self.scope_w.load(.monotonic);
                var si: usize = 0;
                while (si < n) : (si += 1) {
                    const l = out.items[si * @as(usize, OUT_CH)];
                    const r = out.items[si * @as(usize, OUT_CH) + 1];
                    self.scope[w & (scope_len - 1)] = (l + r) * 0.5;
                    w += 1;
                }
                self.scope_w.store(w, .monotonic);
            }

            var block = AudioBlock.init(self.gpa, @intCast(OUT_RATE), @intCast(OUT_CH), out.items[0 .. n * @as(usize, OUT_CH)]) catch continue;
            defer block.deinit();
            self.dev.play(&block); // bloccante → pacing real-time (backpressure)

            submitted += @intCast(n);
            const played_ms = @divTrunc(submitted * 1000, OUT_RATE) - @as(i64, @intFromFloat(LATENCY_S * 1000.0));
            self.clock_ms.store(@max(0, played_ms), .monotonic);
        }
    }

    /// Pts del frame corrente in secondi, -1 se il container non lo fornisce
    /// (in quel caso il filtro post-seek non può scartare: si ripiega sulla soglia).
    fn framePtsSeconds(self: *const AudioPlayer) f64 {
        const ts = self.frame.*.best_effort_timestamp;
        if (ts == c.AV_NOPTS_VALUE or self.time_base <= 0) return -1;
        return @as(f64, @floatFromInt(ts)) * self.time_base;
    }

    /// Decodifica il prossimo frame audio in `self.frame`. `false` a fine file.
    fn decodeOne(self: *AudioPlayer) !bool {
        while (true) {
            const r = c.avcodec_receive_frame(self.codec_ctx, self.frame);
            if (r == 0) return true;
            if (r != c.AVERROR(c.EAGAIN) and r != c.AVERROR_EOF) return error.Decode;
            // Serve un altro packet.
            const rr = c.av_read_frame(self.fmt_ctx, self.packet);
            if (rr < 0) {
                _ = c.avcodec_send_packet(self.codec_ctx, null); // flush
                const r2 = c.avcodec_receive_frame(self.codec_ctx, self.frame);
                return r2 == 0;
            }
            defer c.av_packet_unref(self.packet);
            if (self.packet.*.stream_index != self.stream_idx) continue;
            _ = c.avcodec_send_packet(self.codec_ctx, self.packet);
        }
    }

    /// Ricampiona `self.frame` in `out` (f32 interleaved). Ritorna i frame/canale.
    fn convert(self: *AudioPlayer, out: *std.ArrayListUnmanaged(f32)) !usize {
        const max_out: usize = @intCast(@divTrunc(@as(i64, self.frame.*.nb_samples) * OUT_RATE, @max(self.in_rate, 1)) + 256);
        try out.resize(self.gpa, max_out * @as(usize, OUT_CH));
        var out_ptr: [*c]u8 = @ptrCast(out.items.ptr);
        const n = c.swr_convert(self.swr, &out_ptr, @intCast(max_out), @ptrCast(self.frame.*.extended_data), self.frame.*.nb_samples);
        if (n < 0) return error.Resample;
        return @intCast(n);
    }
};
