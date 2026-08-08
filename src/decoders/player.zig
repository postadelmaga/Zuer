//! Core di decodifica multimediale nativo, basato su libav (ffmpeg): apertura
//! container, decodifica video → RGB24 e (in seguito) audio → PCM. È la
//! fondamenta del player nativo: qui vive tutta l'interazione con ffmpeg,
//! mentre presentazione, audio e controlli overlay stanno altrove.
//!
//! `Player` tiene aperto il container e produce i frame video in sequenza (con
//! il loro PTS in secondi), esponendo durata e seek — il motore che la GUI
//! pilota nel render loop. `firstVideoFrame` è la scorciatoia one-shot usata per
//! il poster/anteprima.

const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/imgutils.h");
    // Decodifica hardware VAAPI: device context (hwcontext) e descrittori dei
    // pixel format (per riconoscere i formati hw nel callback get_format).
    @cInclude("libavutil/hwcontext.h");
    @cInclude("libavutil/pixdesc.h");
    @cInclude("libswscale/swscale.h");
    // Audio: resample → f32 interleaved e gestione dei channel layout (usati da
    // src/audio_player.zig, che riusa questo @cImport per condividere i tipi).
    @cInclude("libswresample/swresample.h");
    @cInclude("libavutil/channel_layout.h");
    @cInclude("libavutil/opt.h");
});

// Decoder VP9 su GPU compute (libcompute_vp9): Linux-only (la libreria non è portata su
// Windows) e solo con il renderer Vulkan attivo. Altrove `cvp9` è uno struct vuoto e il
// suo @cImport non viene mai analizzato — così player.zig compila senza la libreria, e i
// VP9 li decodifica libav.
const cvp9_enabled = builtin.os.tag == .linux and @import("build_options").gpu;
const cvp9 = if (cvp9_enabled) @import("cvp9.zig") else struct {};

// ── libav a runtime ──────────────────────────────────────────────────────────
// Le firme vengono dagli header (@TypeOf sui simboli del cImport), quindi
// restano allineate da sole. Nei build a link diretto (plugin media, player_dbg)
// i campi puntano agli extern del link diretto (LinkAv); in zuer-gui (Linux e
// Windows) l'exe NON linka le lib: si caricano al primo video (`ensureAv`, dlopen
// su Linux/LoadLibrary su Windows) e l'app parte anche senza FFmpeg o con un
// FFmpeg di sistema disallineato — i file multimediali danno errore, tutto il
// resto (incluso aprire un semplice file di testo) non tocca mai libav.

const bo = @import("build_options");
const av_dynamic = @hasDecl(bo, "av_runtime") and bo.av_runtime;

/// Tabella delle funzioni libav usate qui e in src/audio_player.zig.
pub const AvApi = struct {
    av_buffer_ref: *const @TypeOf(c.av_buffer_ref),
    av_buffer_unref: *const @TypeOf(c.av_buffer_unref),
    av_channel_layout_check: *const @TypeOf(c.av_channel_layout_check),
    av_channel_layout_copy: *const @TypeOf(c.av_channel_layout_copy),
    av_channel_layout_default: *const @TypeOf(c.av_channel_layout_default),
    av_channel_layout_uninit: *const @TypeOf(c.av_channel_layout_uninit),
    avcodec_alloc_context3: *const @TypeOf(c.avcodec_alloc_context3),
    avcodec_find_decoder: *const @TypeOf(c.avcodec_find_decoder),
    avcodec_flush_buffers: *const @TypeOf(c.avcodec_flush_buffers),
    avcodec_free_context: *const @TypeOf(c.avcodec_free_context),
    avcodec_get_hw_config: *const @TypeOf(c.avcodec_get_hw_config),
    avcodec_open2: *const @TypeOf(c.avcodec_open2),
    avcodec_parameters_to_context: *const @TypeOf(c.avcodec_parameters_to_context),
    avcodec_receive_frame: *const @TypeOf(c.avcodec_receive_frame),
    avcodec_send_packet: *const @TypeOf(c.avcodec_send_packet),
    av_find_best_stream: *const @TypeOf(c.av_find_best_stream),
    avformat_close_input: *const @TypeOf(c.avformat_close_input),
    avformat_find_stream_info: *const @TypeOf(c.avformat_find_stream_info),
    avformat_open_input: *const @TypeOf(c.avformat_open_input),
    av_frame_alloc: *const @TypeOf(c.av_frame_alloc),
    av_frame_free: *const @TypeOf(c.av_frame_free),
    av_frame_unref: *const @TypeOf(c.av_frame_unref),
    av_hwdevice_ctx_create: *const @TypeOf(c.av_hwdevice_ctx_create),
    av_hwframe_transfer_data: *const @TypeOf(c.av_hwframe_transfer_data),
    av_packet_alloc: *const @TypeOf(c.av_packet_alloc),
    av_packet_free: *const @TypeOf(c.av_packet_free),
    av_packet_unref: *const @TypeOf(c.av_packet_unref),
    av_pix_fmt_desc_get: *const @TypeOf(c.av_pix_fmt_desc_get),
    av_read_frame: *const @TypeOf(c.av_read_frame),
    av_seek_frame: *const @TypeOf(c.av_seek_frame),
    swr_alloc_set_opts2: *const @TypeOf(c.swr_alloc_set_opts2),
    swr_convert: *const @TypeOf(c.swr_convert),
    swr_free: *const @TypeOf(c.swr_free),
    swr_init: *const @TypeOf(c.swr_init),
    sws_freeContext: *const @TypeOf(c.sws_freeContext),
    sws_getContext: *const @TypeOf(c.sws_getContext),
    sws_scale: *const @TypeOf(c.sws_scale),
};

const av_static: AvApi = if (av_dynamic) undefined else blk: {
    var t: AvApi = undefined;
    for (@typeInfo(AvApi).@"struct".fields) |f| {
        @field(t, f.name) = &@field(c, f.name);
    }
    break :blk t;
};

var av_runtime_table: AvApi = undefined;
var av_state: enum { unloaded, ok, failed } = if (av_dynamic) .unloaded else .ok;
var av_mutex: std.atomic.Mutex = .unlocked;

/// Le funzioni libav, pronte all'uso DOPO un `ensureAv()` riuscito.
pub const av: *const AvApi = if (av_dynamic) &av_runtime_table else &av_static;

/// Nome di libreria versionato derivato dagli header (es. "avcodec-63.dll" su
/// Windows, "libavcodec.so.63" su Linux): build e runtime restano allineati da
/// soli, e un ffmpeg di sistema con soname diverso non fa fallire l'avvio —
/// solo l'apertura di un video (vedi `ensureAvRuntime`).
fn libName(comptime base: []const u8, comptime major: u32) [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => std.fmt.comptimePrint("{s}-{d}.dll", .{ base, major }),
        else => std.fmt.comptimePrint("lib{s}.so.{d}", .{ base, major }),
    };
}

/// In ordine di dipendenza (avutil prima di tutti). File-scope: il nome deve
/// essere comptime-known per la conversione UTF-16 nell'inline for (Windows).
const av_lib_names = [_][:0]const u8{
    libName("avutil", c.LIBAVUTIL_VERSION_MAJOR),
    libName("swresample", c.LIBSWRESAMPLE_VERSION_MAJOR),
    libName("swscale", c.LIBSWSCALE_VERSION_MAJOR),
    libName("avcodec", c.LIBAVCODEC_VERSION_MAJOR),
    libName("avformat", c.LIBAVFORMAT_VERSION_MAJOR),
};

/// true se libav è utilizzabile. Carica le librerie al primo uso (LoadLibrary su
/// Windows, dlopen su Linux) e risolve la tabella; un fallimento è ricordato e i
/// media restituiscono errore senza riprovare.
pub fn ensureAv() bool {
    // Ramo comptime: nei build a link diretto (plugin media, player_dbg)
    // ensureAvRuntime non viene mai analizzata (né il suo import di dynlib).
    if (comptime !av_dynamic) return true;
    return ensureAvRuntime();
}

fn ensureAvRuntime() bool {
    // Externs locali (niente import di dynlib.zig: nel plugin media quel file
    // appartiene al modulo `decoder` e l'import da qui dividerebbe i moduli).
    const win = struct {
        extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn FreeLibrary(mod: *anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn GetProcAddress(mod: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    };
    const is_win = comptime builtin.os.tag == .windows;

    while (!av_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer av_mutex.unlock();
    switch (av_state) {
        .ok => return true,
        .failed => return false,
        .unloaded => {},
    }
    av_state = .failed;

    var libs: [av_lib_names.len]*anyopaque = undefined;
    var opened: usize = 0;
    inline for (av_lib_names, 0..) |n, i| {
        libs[i] = (if (is_win) blk: {
            const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(n);
            break :blk win.LoadLibraryW(wide);
        } else std.c.dlopen(n.ptr, .{ .NOW = true })) orelse {
            std.debug.print("zuer: libav non disponibile ({s} mancante): niente audio/video\n", .{n});
            for (libs[0..opened]) |l| {
                if (is_win) _ = win.FreeLibrary(l) else _ = std.c.dlclose(l);
            }
            return false;
        };
        opened += 1;
    }
    // Le librerie restano caricate per la vita del processo (mai chiuse): i
    // puntatori della tabella vivono dentro di loro.
    inline for (@typeInfo(AvApi).@"struct".fields) |f| {
        var found = false;
        for (libs) |l| {
            const sym = if (is_win) win.GetProcAddress(l, f.name) else std.c.dlsym(l, f.name);
            if (sym) |p| {
                @field(av_runtime_table, f.name) = @ptrCast(@alignCast(p));
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("zuer: simbolo libav mancante: {s}\n", .{f.name});
            return false;
        }
    }
    av_state = .ok;
    return true;
}

pub const Frame = struct {
    width: usize,
    height: usize,
    /// Pixel impacchettati, righe contigue senza padding. Formato secondo il player:
    /// RGB24 (3 B/px) per il poster one-shot, di proprietà del chiamante; RGBA (4 B/px)
    /// per il player live, che PRESTA il proprio `scratch` (valido fino al prossimo
    /// `nextFrame`/`deinit`: da consumare subito, non liberare).
    pixels: []u8,
    /// Timestamp di presentazione in secondi (0 se il container non lo fornisce).
    pts_s: f64 = 0,
};

pub const Error = error{
    OpenFailed,
    NoStreamInfo,
    NoVideoStream,
    NoDecoder,
    CodecOpenFailed,
    AllocFailed,
    ScaleInitFailed,
    NoFrameDecoded,
    OutOfMemory,
};

/// Dimensioni scalate mantenendo l'aspect ratio, così che il lato maggiore non
/// superi `max_dim` (mai ingrandito).
fn fitDims(src_w: c_int, src_h: c_int, max_dim: usize) struct { w: c_int, h: c_int } {
    if (src_w <= 0 or src_h <= 0) return .{ .w = 1, .h = 1 };
    const fmax: f64 = @floatFromInt(max_dim);
    const bigger: f64 = @floatFromInt(@max(src_w, src_h));
    const scale = @min(1.0, fmax / bigger);
    const w: c_int = @max(1, @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(src_w)) * scale))));
    const h: c_int = @max(1, @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(src_h)) * scale))));
    return .{ .w = w, .h = h };
}

/// Callback `get_format` per la decodifica VAAPI. È una funzione C senza stato
/// catturabile, quindi la scelta è fissa: AV_PIX_FMT_VAAPI se il decoder lo
/// propone, altrimenti il primo formato SOFTWARE della lista (fallback
/// dinamico: alcuni stream cambiano parametri a metà e perdono l'hwaccel).
fn pickVaapiFormat(ctx: [*c]c.AVCodecContext, fmts: [*c]const c.enum_AVPixelFormat) callconv(.c) c.enum_AVPixelFormat {
    _ = ctx;
    var i: usize = 0;
    while (fmts[i] != c.AV_PIX_FMT_NONE) : (i += 1) {
        if (fmts[i] == c.AV_PIX_FMT_VAAPI) return c.AV_PIX_FMT_VAAPI;
    }
    // Niente VAAPI nella lista: primo formato NON hardware (un formato hw di un
    // altro tipo non sarebbe usabile senza il relativo device context).
    i = 0;
    while (fmts[i] != c.AV_PIX_FMT_NONE) : (i += 1) {
        const desc = av.av_pix_fmt_desc_get(fmts[i]);
        if (desc != null and (desc.*.flags & c.AV_PIX_FMT_FLAG_HWACCEL) == 0) return fmts[i];
    }
    return fmts[0];
}

/// Ultimo stato hwaccel loggato (null = mai): un log solo quando il percorso
/// cambia, non a ogni open (i poster aprono un Player per ogni anteprima).
var vaapi_last_logged: ?bool = null;

const max_hw_devices = 8;
const max_hw_device_path = 32; // "/dev/dri/renderD255\0" basta e avanza

/// Enumera i render node VAAPI (/dev/dri/renderD*), ordinati per nome. Su
/// sistemi multi-GPU (iGPU + dGPU) il device scelto di default dal driver non
/// è detto sia quello capace del profilo dello stream: es. iGPU Intel con
/// H.264 High Profile completo + dGPU NVIDIA via nouveau, che spesso non lo
/// supporta. Si prova ogni device in ordine finché uno decodifica davvero in
/// hardware (vedi probeHwDevice, chiamata da Player.openEx). Nessuna
/// directory/device trovato → 0, in silenzio (non-Linux, o sistema senza DRM).
fn listHwDevices(out: *[max_hw_devices][max_hw_device_path]u8) u8 {
    // libc diretto (opendir/readdir), non std.Io.Dir: Player.openEx non riceve
    // un `io: std.Io` (troppi chiamanti da rivedere, incl. il thread produttore
    // in video_decoder.zig) — stesso principio di decoder.zig (readFileLibc
    // ecc.): evita di infilare `std.Io` in un percorso che oggi non lo usa.
    const dir = std.c.opendir("/dev/dri") orelse return 0;
    defer _ = std.c.closedir(dir);
    var count: u8 = 0;
    while (count < max_hw_devices) {
        const entry = std.c.readdir(dir) orelse break;
        const name = std.mem.sliceTo(@as([*]const u8, &entry.name), 0);
        if (!std.mem.startsWith(u8, name, "renderD")) continue;
        _ = std.fmt.bufPrintZ(&out[count], "/dev/dri/{s}", .{name}) catch continue;
        count += 1;
    }
    std.mem.sort([max_hw_device_path]u8, out[0..count], {}, struct {
        fn lt(_: void, a: [max_hw_device_path]u8, b: [max_hw_device_path]u8) bool {
            return std.mem.lessThan(u8, std.mem.sliceTo(&a, 0), std.mem.sliceTo(&b, 0));
        }
    }.lt);
    return count;
}

const OpenedHw = struct { codec_ctx: [*c]c.AVCodecContext, hw_device_ctx: [*c]c.AVBufferRef };

/// Tenta di aprire `codec` in hardware sul device VAAPI `device_path`
/// (`null` = device di default del sistema). Verifica che il decoder supporti
/// il metodo hw_device_ctx e che `avcodec_open2` riesca; NON garantisce che il
/// profilo dello stream sia davvero decodificato in hardware (lo si scopre
/// solo al primo frame: alcuni driver accettano il device e la open ma
/// ricadono in software silenziosamente dentro avcodec_send_packet/
/// receive_frame — vedi probeHwDevice, che verifica anche questo). Ritorna
/// null e libera tutto se un qualsiasi passo fallisce: il chiamante prova il
/// device successivo o degrada a software.
fn tryOpenVaapiDevice(
    codec: [*c]const c.AVCodec,
    stream: [*c]c.AVStream,
    device_path: ?[*:0]const u8,
) ?OpenedHw {
    var hw_device_ctx: [*c]c.AVBufferRef = null;
    const dev_c: [*c]const u8 = if (device_path) |p| p else null;
    if (av.av_hwdevice_ctx_create(&hw_device_ctx, c.AV_HWDEVICE_TYPE_VAAPI, dev_c, null, 0) < 0) return null;

    var supported = false;
    var ci: c_int = 0;
    while (av.avcodec_get_hw_config(codec, ci)) |cfg| : (ci += 1) {
        if ((cfg.*.methods & c.AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 and
            cfg.*.device_type == c.AV_HWDEVICE_TYPE_VAAPI)
        {
            supported = true;
            break;
        }
    }
    if (!supported) {
        av.av_buffer_unref(&hw_device_ctx);
        return null;
    }

    const codec_ctx = av.avcodec_alloc_context3(codec) orelse {
        av.av_buffer_unref(&hw_device_ctx);
        return null;
    };
    if (av.avcodec_parameters_to_context(codec_ctx, stream.*.codecpar) < 0) {
        var cc: [*c]c.AVCodecContext = codec_ctx;
        av.avcodec_free_context(&cc);
        av.av_buffer_unref(&hw_device_ctx);
        return null;
    }
    const dev_ref = av.av_buffer_ref(hw_device_ctx);
    if (dev_ref == null) {
        var cc: [*c]c.AVCodecContext = codec_ctx;
        av.avcodec_free_context(&cc);
        av.av_buffer_unref(&hw_device_ctx);
        return null;
    }
    codec_ctx.*.hw_device_ctx = dev_ref;
    codec_ctx.*.get_format = pickVaapiFormat;
    // Con VAAPI il frame-threading non serve (decodifica la GPU) e aggiunge
    // solo latenza di pipeline: un thread solo, tipi azzerati.
    codec_ctx.*.thread_count = 1;
    codec_ctx.*.thread_type = 0;
    if (av.avcodec_open2(codec_ctx, codec, null) < 0) {
        var cc: [*c]c.AVCodecContext = codec_ctx;
        av.avcodec_free_context(&cc);
        av.av_buffer_unref(&hw_device_ctx);
        return null;
    }
    return .{ .codec_ctx = codec_ctx, .hw_device_ctx = hw_device_ctx };
}

/// Come tryOpenVaapiDevice, ma verifica ANCHE che il primo frame dello stream
/// sia davvero decodificato in hardware (`AV_PIX_FMT_VAAPI`), non solo che
/// l'apertura riesca: alcuni driver (es. nouveau) accettano il device e la
/// open ma poi ricadono in software in silenzio dentro
/// avcodec_send_packet/receive_frame — lo si scopre solo decodificando.
/// Riavvolge SEMPRE il demuxer all'inizio dello stream dopo il tentativo
/// (successo o fallimento) con `av_seek_frame` + `avcodec_flush_buffers`:
/// scambiare il codec context a metà stream perde lo stato dei frame di
/// riferimento e su contenuti con keyframe rade il decoder non si riprende
/// più (visto in pratica: passare device dopo aver già consumato packet
/// troncava la riproduzione a metà file). Va quindi deciso PRIMA di
/// consegnare il primo frame al chiamante, mai a decodifica già iniziata.
/// `probe_packet`/`probe_frame` sono riusati (verranno anche i frame/packet
/// definitivi del Player): a questo punto dell'apertura sono ancora vuoti.
fn probeHwDevice(
    codec: [*c]const c.AVCodec,
    stream: [*c]c.AVStream,
    device_path: ?[*:0]const u8,
    fmt_ctx: [*c]c.AVFormatContext,
    stream_idx: c_int,
    probe_packet: [*c]c.AVPacket,
    probe_frame: [*c]c.AVFrame,
) ?OpenedHw {
    const opened = tryOpenVaapiDevice(codec, stream, device_path) orelse return null;
    var real_hw = false;
    var tries: u32 = 0;
    while (tries < 64) : (tries += 1) {
        const rr = av.av_read_frame(fmt_ctx, probe_packet);
        if (rr < 0) break; // EOF prematuro: niente da verificare, considera fallito
        defer av.av_packet_unref(probe_packet);
        if (probe_packet.*.stream_index != stream_idx) continue;
        const sr = av.avcodec_send_packet(opened.codec_ctx, probe_packet);
        if (sr < 0 and sr != c.AVERROR(c.EAGAIN)) break;
        const r = av.avcodec_receive_frame(opened.codec_ctx, probe_frame);
        if (r == c.AVERROR(c.EAGAIN)) continue;
        if (r < 0) break;
        real_hw = probe_frame.*.format == c.AV_PIX_FMT_VAAPI;
        break;
    }
    // Sempre: il chiamante (prossimo device, o il player stesso se abbiamo
    // vinto) deve poter iniziare la decodifica vera dal frame 0.
    _ = av.av_seek_frame(fmt_ctx, stream_idx, 0, c.AVSEEK_FLAG_BACKWARD);
    av.avcodec_flush_buffers(opened.codec_ctx);
    if (real_hw) return opened;
    var cc: [*c]c.AVCodecContext = opened.codec_ctx;
    av.avcodec_free_context(&cc);
    var hw_ref: [*c]c.AVBufferRef = opened.hw_device_ctx;
    av.av_buffer_unref(&hw_ref);
    return null;
}

pub const Player = struct {
    fmt_ctx: [*c]c.AVFormatContext,
    codec_ctx: [*c]c.AVCodecContext,
    frame: [*c]c.AVFrame,
    packet: [*c]c.AVPacket,
    video_stream: c_int,
    time_base: f64, // secondi per unità di PTS dello stream video
    duration_s: f64, // durata del container in secondi (0 se ignota)
    // Alcuni container (tipici AVI) non danno PTS per-frame → best_effort_timestamp
    // resta a 0/NOPTS su tutti i frame e il pacing si blocca. Fallback: PTS
    // sintetizzato da un contatore di frame diviso il frame rate.
    frame_rate: f64 = 25.0, // fps dello stream (per il PTS sintetico)
    frame_index: i64 = 0, // frame decodificati (avanza; azzerato/rimappato al seek)

    // Contesto di scaling riusato tra i frame; ricreato se cambiano le dimensioni.
    sws: ?*c.struct_SwsContext = null,
    sws_src_w: c_int = 0,
    sws_src_h: c_int = 0,
    sws_src_fmt: c_int = -1,
    sws_dst_w: c_int = 0,
    sws_dst_h: c_int = 0,

    // Decoder VP9 su GPU (libcompute_vp9). `is_vp9` = stiamo instradando i packet a
    // cvp9 invece che a libavcodec. Il contesto avcodec resta comunque aperto come
    // fallback (es. se un seek non riesce a ricreare il contesto cvp9).
    cvp9_ctx: if (cvp9_enabled) ?cvp9.Ctx else void = if (cvp9_enabled) null else {},
    is_vp9: bool = false,

    // Decodifica hardware VAAPI: device context (ref del player, oltre a quella
    // trattenuta dal codec context), frame CPU riusato per il download GPU→CPU
    // dei frame AV_PIX_FMT_VAAPI e guardia per loggare una sola volta
    // l'eventuale degrado a software durante la riproduzione.
    hw_device_ctx: [*c]c.AVBufferRef = null,
    sw_frame: [*c]c.AVFrame = null,
    hw_active: bool = false,
    hw_warned: bool = false,
    // Render node VAAPI scoperti all'apertura (sistemi multi-GPU: iGPU + dGPU)
    // e indice di quello scelto (verificato, vedi probeHwDevice), solo per il
    // log diagnostico.
    hw_devices: [max_hw_devices][max_hw_device_path]u8 = undefined,
    hw_device_count: u8 = 0,
    hw_device_idx: u8 = 0,

    // Formato di uscita e buffer di scaling. Il player live (`Player.open`) emette
    // RGBA (il formato di presentazione) riusando `scratch`: niente malloc per-frame
    // né passaggio scalare RGB→RGBA a valle. `nextFrame` restituisce allora un Frame
    // che PRESTA `scratch`, valido fino alla chiamata successiva o a `deinit`. Il
    // poster one-shot (`openEx(…, false)`/`firstVideoFrame`) resta invece su RGB24 di
    // proprietà del chiamante (lo consuma `decoder.ImageData`, RGB 24-bit).
    out_fmt: c_int = c.AV_PIX_FMT_RGB24,
    out_bpp: usize = 3,
    reuse: bool = false,
    scratch: []u8 = &.{},
    scratch_gpa: ?std.mem.Allocator = null,

    pub fn open(path: [*:0]const u8) Error!Player {
        var p = try openEx(path, true);
        // Player live: emette RGBA riusando il buffer di scaling.
        p.out_fmt = c.AV_PIX_FMT_RGBA;
        p.out_bpp = 4;
        p.reuse = true;
        return p;
    }

    /// Buffer di destinazione per `need` byte: con `reuse` cresce `scratch` solo se
    /// necessario e ne PRESTA una fetta; altrimenti alloca di proprietà del chiamante.
    fn outBuf(self: *Player, need: usize, allocator: std.mem.Allocator) Error![]u8 {
        if (!self.reuse) return allocator.alloc(u8, need) catch return Error.OutOfMemory;
        if (self.scratch.len < need) {
            self.scratch = if (self.scratch.len == 0)
                allocator.alloc(u8, need) catch return Error.OutOfMemory
            else
                allocator.realloc(self.scratch, need) catch return Error.OutOfMemory;
            self.scratch_gpa = allocator;
        }
        return self.scratch[0..need];
    }

    /// `allow_cvp9` = consenti il decoder GPU per gli stream VP9 E la sonda
    /// hardware VAAPI per H.264/HEVC. Il poster (`firstVideoFrame`) passa
    /// false: un solo frame non giustifica un contesto GPU, VAAPI incluso —
    /// e il file explorer genera i thumbnail in background mentre l'utente
    /// può avere un video in riproduzione live: niente contesa di sessioni
    /// hardware concorrenti sulla stessa GPU.
    pub fn openEx(path: [*:0]const u8, allow_cvp9: bool) Error!Player {
        if (!ensureAv()) return Error.OpenFailed; // libav assente o soname disallineato
        var fmt_ctx: [*c]c.AVFormatContext = null;
        if (av.avformat_open_input(&fmt_ctx, path, null, null) != 0) return Error.OpenFailed;
        errdefer av.avformat_close_input(&fmt_ctx);

        if (av.avformat_find_stream_info(fmt_ctx, null) < 0) return Error.NoStreamInfo;

        var codec: [*c]const c.AVCodec = null;
        const stream_idx = av.av_find_best_stream(fmt_ctx, c.AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
        if (stream_idx < 0 or codec == null) return Error.NoVideoStream;
        const stream = fmt_ctx.*.streams[@intCast(stream_idx)];
        // Copertina embedded (mp3/flac con APIC): è uno stream "video" di un solo
        // frame marcato attached_pic. Per il player LIVE non è un video: aprirlo
        // qui manderebbe l'audio nel player video, dove ogni nextFrame demuxa
        // l'intero file cercando un secondo frame che non esiste e il loop a EOF
        // fa ripartire la riproduzione da capo all'infinito. Il poster one-shot
        // (allow_cvp9=false) invece la usa eccome: è la cover art dell'anteprima.
        if (allow_cvp9 and (stream.*.disposition & c.AV_DISPOSITION_ATTACHED_PIC) != 0)
            return Error.NoVideoStream;

        var codec_ctx: [*c]c.AVCodecContext = null;
        errdefer {
            var cc: [*c]c.AVCodecContext = codec_ctx;
            av.avcodec_free_context(&cc);
        }
        var hw_device_ctx: [*c]c.AVBufferRef = null;
        errdefer av.av_buffer_unref(&hw_device_ctx);
        var use_hw = false;

        // Frame/packet allocati ORA (non più giù): servono già per la sonda hw
        // qui sotto, poi diventano i frame/packet definitivi del player — nessuna
        // doppia allocazione.
        const frame = av.av_frame_alloc() orelse return Error.AllocFailed;
        errdefer {
            var f: [*c]c.AVFrame = frame;
            av.av_frame_free(&f);
        }
        const packet = av.av_packet_alloc() orelse return Error.AllocFailed;
        errdefer {
            var p: [*c]c.AVPacket = packet;
            av.av_packet_free(&p);
        }

        // Decodifica hardware VAAPI: su Linux prova ogni render node
        // (/dev/dri/renderD*) finché uno decodifica DAVVERO in hardware il primo
        // frame (probeHwDevice) — sui sistemi multi-GPU (iGPU + dGPU) il device
        // di default non è detto sia quello capace del profilo dello stream, e
        // alcuni driver lo scoprono solo a decodifica iniziata. Verificarlo qui,
        // riavvolgendo il demuxer dopo ogni tentativo, evita di dover cambiare
        // device a metà riproduzione (perderebbe lo stato dei frame di
        // riferimento). Nessun device apribile → software puro, in silenzio (il
        // log è più giù).
        //
        // Solo per `allow_cvp9`: il poster one-shot (`firstVideoFrame`, un solo
        // frame) NON prova mai VAAPI, stessa logica del commento su
        // `allow_cvp9` sopra ("un solo frame non giustifica un contesto GPU").
        // Il file explorer genera i thumbnail dei video in background mentre
        // l'utente può aprirne uno in riproduzione live: più Player in hardware
        // concorrenti sulla stessa iGPU hanno saturato in pratica il decoder
        // fisso (VA_STATUS_ERROR_DECODING_ERROR) — il poster non ne trae comunque
        // beneficio percepibile, quindi meglio non contendere risorse.
        var hw_devices: [max_hw_devices][max_hw_device_path]u8 = undefined;
        var hw_device_count: u8 = 0;
        var hw_device_idx: u8 = 0;
        if (allow_cvp9) {
            hw_device_count = if (comptime builtin.os.tag == .linux) listHwDevices(&hw_devices) else 0;
            if (hw_device_count > 0) {
                var i: u8 = 0;
                while (i < hw_device_count) : (i += 1) {
                    const dev_path: [*:0]const u8 = std.mem.sliceTo(@as([*]const u8, &hw_devices[i]), 0).ptr;
                    if (probeHwDevice(codec, stream, dev_path, fmt_ctx, stream_idx, packet, frame)) |opened| {
                        codec_ctx = opened.codec_ctx;
                        hw_device_ctx = opened.hw_device_ctx;
                        use_hw = true;
                        hw_device_idx = i;
                        break;
                    }
                }
            } else if (probeHwDevice(codec, stream, null, fmt_ctx, stream_idx, packet, frame)) |opened| {
                // Nessun render node enumerabile (non-Linux, o sistema senza DRM):
                // prova comunque il device di default del sistema.
                codec_ctx = opened.codec_ctx;
                hw_device_ctx = opened.hw_device_ctx;
                use_hw = true;
            }
        }

        if (!use_hw) {
            // Decodifica multi-thread: `thread_count = 0` = auto (n. core logici), con
            // threading sia a livello di frame che di slice. È la leva principale sulle
            // performance: un H.264/HEVC HD su un solo core non regge 30/60 fps.
            codec_ctx = av.avcodec_alloc_context3(codec) orelse return Error.AllocFailed;
            if (av.avcodec_parameters_to_context(codec_ctx, stream.*.codecpar) < 0) return Error.CodecOpenFailed;
            codec_ctx.*.thread_count = 0;
            codec_ctx.*.thread_type = c.FF_THREAD_FRAME | c.FF_THREAD_SLICE;
            if (av.avcodec_open2(codec_ctx, codec, null) < 0) return Error.CodecOpenFailed;
        }

        // Frame CPU per il download dei frame VAAPI (allocato una volta,
        // unref-ato a ogni iterazione in frameFromCurrent).
        var sw_frame: [*c]c.AVFrame = null;
        errdefer av.av_frame_free(&sw_frame);
        if (use_hw) sw_frame = av.av_frame_alloc() orelse return Error.AllocFailed;

        // Log una tantum (solo al cambio di percorso/device) così l'utente può
        // verificare se la decodifica hardware è attiva e su quale device.
        if (vaapi_last_logged != use_hw) {
            vaapi_last_logged = use_hw;
            if (use_hw and hw_device_count > 0) {
                std.log.info("zuer video: decodifica VAAPI attiva (codec {s}, device {s})", .{
                    std.mem.span(codec.*.name),
                    std.mem.sliceTo(&hw_devices[hw_device_idx], 0),
                });
            } else if (use_hw) {
                std.log.info("zuer video: decodifica VAAPI attiva (codec {s})", .{std.mem.span(codec.*.name)});
            } else {
                std.log.info("zuer video: decodifica software (codec {s})", .{std.mem.span(codec.*.name)});
            }
        }

        const tb = stream.*.time_base;
        const time_base: f64 = if (tb.den != 0)
            @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(tb.den))
        else
            0;

        var duration_s: f64 = 0;
        if (fmt_ctx.*.duration != c.AV_NOPTS_VALUE and fmt_ctx.*.duration > 0) {
            duration_s = @as(f64, @floatFromInt(fmt_ctx.*.duration)) / @as(f64, c.AV_TIME_BASE);
        } else if (stream.*.duration != c.AV_NOPTS_VALUE and stream.*.duration > 0) {
            duration_s = @as(f64, @floatFromInt(stream.*.duration)) * time_base;
        }

        // VP9 → prova il decoder GPU compute; se il backend non parte, resta libav.
        var cvp9_ctx: if (cvp9_enabled) ?cvp9.Ctx else void = if (cvp9_enabled) null else {};
        var is_vp9 = false;
        if (comptime cvp9_enabled) {
            const is_vp9_stream = stream.*.codecpar.*.codec_id == c.AV_CODEC_ID_VP9;
            const forced_libav = std.c.getenv("ZUER_VP9_LIBAV") != null;
            if (allow_cvp9 and is_vp9_stream and !forced_libav) {
                if (cvp9.Ctx.create()) |cx| {
                    cvp9_ctx = cx;
                    is_vp9 = true;
                    std.log.info("[cvp9] VP9 via GPU compute, backend {s}", .{cx.backendName()});
                } else {
                    std.log.warn("[cvp9] init fallita, VP9 via libav (libvpx)", .{});
                }
            }
        }

        // Frame rate per il PTS sintetico: avg_frame_rate, poi r_frame_rate, poi 25.
        const afr = stream.*.avg_frame_rate;
        const rfr = stream.*.r_frame_rate;
        const frame_rate: f64 = if (afr.num > 0 and afr.den > 0)
            @as(f64, @floatFromInt(afr.num)) / @as(f64, @floatFromInt(afr.den))
        else if (rfr.num > 0 and rfr.den > 0)
            @as(f64, @floatFromInt(rfr.num)) / @as(f64, @floatFromInt(rfr.den))
        else
            25.0;

        return .{
            .fmt_ctx = fmt_ctx,
            .codec_ctx = codec_ctx,
            .frame = frame,
            .packet = packet,
            .video_stream = stream_idx,
            .time_base = time_base,
            .duration_s = duration_s,
            .frame_rate = frame_rate,
            .cvp9_ctx = cvp9_ctx,
            .is_vp9 = is_vp9,
            .hw_device_ctx = hw_device_ctx,
            .sw_frame = sw_frame,
            .hw_active = use_hw,
            .hw_devices = hw_devices,
            .hw_device_count = hw_device_count,
            .hw_device_idx = hw_device_idx,
        };
    }

    pub fn deinit(self: *Player) void {
        if (self.scratch_gpa) |g| g.free(self.scratch);
        if (comptime cvp9_enabled) {
            if (self.cvp9_ctx) |cx| cx.destroy();
        }
        if (self.sws) |s| av.sws_freeContext(s);
        // Risorse VAAPI: frame CPU di download e ref del device (il codec
        // context libera la propria in avcodec_free_context).
        var sf: [*c]c.AVFrame = self.sw_frame;
        av.av_frame_free(&sf);
        av.av_buffer_unref(&self.hw_device_ctx);
        var p: [*c]c.AVPacket = self.packet;
        av.av_packet_free(&p);
        var f: [*c]c.AVFrame = self.frame;
        av.av_frame_free(&f);
        var cc: [*c]c.AVCodecContext = self.codec_ctx;
        av.avcodec_free_context(&cc);
        av.avformat_close_input(&self.fmt_ctx);
    }

    fn ptsSeconds(self: *Player) f64 {
        const idx = self.frame_index;
        self.frame_index += 1;
        const ts = self.frame.*.best_effort_timestamp;
        // PTS reale se disponibile e progressivo; altrimenti (AVI senza timestamp:
        // ts=0/NOPTS su tutti i frame) sintetizzato da indice/fps così il pacing
        // avanza invece di restare bloccato a 0.
        if (ts != c.AV_NOPTS_VALUE and ts > 0 and self.time_base > 0) {
            return @as(f64, @floatFromInt(ts)) * self.time_base;
        }
        return @as(f64, @floatFromInt(idx)) / self.frame_rate;
    }

    /// Secondi da un timestamp grezzo nella time_base dello stream (per i frame cvp9,
    /// il cui PTS è quello del packet che abbiamo sottomesso).
    fn rawPtsSeconds(self: *Player, ts: i64) f64 {
        if (ts == c.AV_NOPTS_VALUE) return 0;
        return @as(f64, @floatFromInt(ts)) * self.time_base;
    }

    /// Decodifica il prossimo frame video, scalato a `max_dim`, con il suo PTS.
    /// Ritorna `null` a fine stream. Il chiamante possiede `Frame.pixels`.
    ///
    /// `skip_before_pts`: se non-null, i frame con pts < questo valore vengono
    /// scartati internamente (si continua a decodificare finché non se ne trova
    /// uno all'altezza) SENZA il costo di download GPU→CPU/scaling — solo il
    /// pts viene calcolato (vedi frameFromCurrent). Usato dal produttore dopo
    /// un seek per attraversare i frame tra il keyframe di atterraggio e il
    /// target: senza questo, con VAAPI attivo ogni frame scartato pagherebbe
    /// comunque il transfer sincrono GPU→CPU, rendendo il seek percepibilmente
    /// lento sui file con GOP ampie (keyframe rade).
    pub fn nextFrame(self: *Player, max_dim: usize, allocator: std.mem.Allocator, skip_before_pts: ?f64) Error!?Frame {
        if (comptime cvp9_enabled) {
            if (self.is_vp9) return self.nextFrameCvp9(max_dim, allocator);
        }
        while (true) {
            const rr = av.av_read_frame(self.fmt_ctx, self.packet);
            if (rr < 0) {
                // Fine file: svuota il decoder con un packet nullo.
                _ = av.avcodec_send_packet(self.codec_ctx, null);
                const r = av.avcodec_receive_frame(self.codec_ctx, self.frame);
                if (r < 0) return null;
                // Se il download hw fallisse proprio all'ultimo frame (null),
                // il file finisce qui comunque: nessun frame da recuperare.
                return try self.frameFromCurrent(max_dim, allocator, skip_before_pts);
            }
            defer av.av_packet_unref(self.packet);
            if (self.packet.*.stream_index != self.video_stream) continue;
            const sr = av.avcodec_send_packet(self.codec_ctx, self.packet);
            if (sr == c.AVERROR(c.EAGAIN)) {
                // Decoder pieno (frame-threading): l'API garantisce che c'è un frame
                // in uscita. Drenalo e ri-sottometti lo STESSO packet — scartarlo
                // (il vecchio `continue`) perdeva frame. Dopo il drenaggio il
                // send è accettato; il packet viene poi unref-ato dal defer.
                const rd = av.avcodec_receive_frame(self.codec_ctx, self.frame);
                if (rd < 0) continue; // stato anomalo: rinuncia a questo packet
                _ = av.avcodec_send_packet(self.codec_ctx, self.packet);
                if (try self.frameFromCurrent(max_dim, allocator, skip_before_pts)) |fr| return fr;
                continue; // scartato per pts, o download hw fallito: prosegui
            }
            if (sr < 0) {
                // A questo punto il device VAAPI è già stato verificato in
                // apertura (Player.openEx prova ogni device e ne conferma la
                // resa hardware reale prima di tornare al chiamante): un
                // errore qui è un cedimento runtime genuino (non un profilo
                // non supportato scoperto tardi). Degrada a software diretto,
                // senza ritentare altri device — cambiare contesto a metà
                // stream perde lo stato dei frame di riferimento ed è
                // difficile da recuperare su contenuti con keyframe rade.
                if (self.hw_active) {
                    if (!self.hw_warned) {
                        self.hw_warned = true;
                        std.log.warn("zuer video: errore VAAPI runtime, degrado a decodifica software", .{});
                    }
                    if (!self.reopenSoftware()) return Error.NoFrameDecoded;
                }
                continue; // errore vero: packet inservibile
            }
            const r = av.avcodec_receive_frame(self.codec_ctx, self.frame);
            if (r == c.AVERROR(c.EAGAIN)) continue; // servono altri packet
            if (r == c.AVERROR_EOF) return null;
            if (r < 0) {
                if (self.hw_active) {
                    if (!self.hw_warned) {
                        self.hw_warned = true;
                        std.log.warn("zuer video: errore VAAPI runtime, degrado a decodifica software", .{});
                    }
                    if (!self.reopenSoftware()) return Error.NoFrameDecoded;
                    continue;
                }
                return Error.NoFrameDecoded;
            }
            if (try self.frameFromCurrent(max_dim, allocator, skip_before_pts)) |fr| return fr;
            continue; // scartato per pts, o download hw fallito: prosegui
        }
    }

    /// Frame appena decodificato (`self.frame`) → Frame impacchettato. Il pts
    /// si calcola SUBITO (prima di qualunque download/scaling): se sotto
    /// `skip_before_pts` il frame è scartato qui, a costo quasi zero — senza
    /// questo, un frame VAAPI scartato pagherebbe comunque il transfer
    /// sincrono GPU→CPU (vedi commento su `nextFrame`). Se il decoder ha
    /// prodotto un frame VAAPI (e non va scartato) lo scarica in `sw_frame`
    /// (GPU→CPU, tipicamente NV12); se il download fallisce degrada l'intera
    /// riproduzione a software e ritorna null: il chiamante prosegue col
    /// prossimo packet, che verrà decodificato dal nuovo contesto software.
    fn frameFromCurrent(self: *Player, max_dim: usize, allocator: std.mem.Allocator, skip_before_pts: ?f64) Error!?Frame {
        const pts = self.ptsSeconds();
        if (skip_before_pts) |target| {
            if (pts < target) return null; // scartato: niente download/scale
        }
        var src: [*c]c.AVFrame = self.frame;
        if (self.frame.*.format == c.AV_PIX_FMT_VAAPI) {
            var ok = self.sw_frame != null;
            if (ok) {
                av.av_frame_unref(self.sw_frame);
                ok = av.av_hwframe_transfer_data(self.sw_frame, self.frame, 0) >= 0;
            }
            if (!ok) {
                if (!self.hw_warned) {
                    self.hw_warned = true;
                    std.log.warn("zuer video: download frame VAAPI fallito, degrado a decodifica software", .{});
                }
                if (!self.reopenSoftware()) return Error.NoFrameDecoded;
                return null;
            }
            src = self.sw_frame;
        } else if (self.hw_active) {
            // Il device VAAPI è già stato verificato in apertura (vedi
            // probeHwDevice): se il decoder ricade comunque in software a
            // metà riproduzione è un cedimento runtime raro (es. cambio di
            // risoluzione/profilo a metà stream). Degrada e basta, senza
            // ritentare altri device (vedi commento in nextFrame).
            if (!self.hw_warned) {
                self.hw_warned = true;
                std.log.warn("zuer video: hwaccel VAAPI ricaduto in software a metà stream, degrado", .{});
            }
            if (!self.reopenSoftware()) return Error.NoFrameDecoded;
        }
        return try self.scaleCurrent(src, max_dim, allocator, pts);
    }

    /// Riapre il codec context in software puro dopo un fallimento runtime del
    /// percorso VAAPI. Il decode riparte pulito dal prossimo keyframe. Ritorna
    /// false se la riapertura non riesce: il player non è più utilizzabile e il
    /// chiamante deve propagare un errore (mai continuare con un ctx nullo).
    fn reopenSoftware(self: *Player) bool {
        self.hw_active = false;
        av.av_buffer_unref(&self.hw_device_ctx);
        const stream = self.fmt_ctx.*.streams[@intCast(self.video_stream)];
        const codec = av.avcodec_find_decoder(stream.*.codecpar.*.codec_id);
        if (codec == null) return false;
        var cc: [*c]c.AVCodecContext = self.codec_ctx;
        av.avcodec_free_context(&cc);
        self.codec_ctx = null; // deinit non deve rivedere il puntatore morto
        self.codec_ctx = av.avcodec_alloc_context3(codec) orelse return false;
        if (av.avcodec_parameters_to_context(self.codec_ctx, stream.*.codecpar) < 0) return false;
        self.codec_ctx.*.thread_count = 0;
        self.codec_ctx.*.thread_type = c.FF_THREAD_FRAME | c.FF_THREAD_SLICE;
        if (av.avcodec_open2(self.codec_ctx, codec, null) < 0) return false;
        return true;
    }

    /// Percorso VP9 su GPU: sottomette i packet grezzi a cvp9 e raccoglie i frame
    /// I420 in ordine di presentazione (pipeline: alcuni frame possono essere in
    /// volo). A fine stream drena i frame residui in modo bloccante.
    fn nextFrameCvp9(self: *Player, max_dim: usize, allocator: std.mem.Allocator) Error!?Frame {
        var f: cvp9.Frame = undefined;
        while (true) {
            // Un frame potrebbe essere già pronto dalla pipeline.
            if (self.cvp9_ctx.?.getFrame(&f) == .ok) return try self.scaleI420(f, max_dim, allocator);
            const rr = av.av_read_frame(self.fmt_ctx, self.packet);
            if (rr < 0) {
                // Fine file: drena i frame ancora in volo (pipeline poco profonda),
                // con un tetto di tentativi così un frame bloccato non appende il worker.
                var tries: u32 = 0;
                while (tries < 256) : (tries += 1) {
                    switch (self.cvp9_ctx.?.getFrame(&f)) {
                        .ok => return try self.scaleI420(f, max_dim, allocator),
                        .none => return null,
                        .again => std.Thread.yield() catch {},
                    }
                }
                return null;
            }
            defer av.av_packet_unref(self.packet);
            if (self.packet.*.stream_index != self.video_stream) continue;
            self.cvp9_ctx.?.decode(self.packet.*.data, @intCast(self.packet.*.size), self.packet.*.pts);
        }
    }

    /// Converte un frame I420 di cvp9 in RGB24 impacchettato scalato a `max_dim`.
    fn scaleI420(self: *Player, f: cvp9.Frame, max_dim: usize, allocator: std.mem.Allocator) Error!Frame {
        const src_w: c_int = @intCast(f.width);
        const src_h: c_int = @intCast(f.height);
        const dims = fitDims(src_w, src_h, max_dim);
        try self.ensureSws(src_w, src_h, c.AV_PIX_FMT_YUV420P, dims.w, dims.h);

        const w: usize = @intCast(dims.w);
        const h: usize = @intCast(dims.h);
        const pixels = try self.outBuf(w * h * self.out_bpp, allocator);

        var src_data = [_][*c]u8{ f.y, f.u, f.v, null };
        var src_linesize = [_]c_int{ @intCast(f.stride_y), @intCast(f.stride_uv), @intCast(f.stride_uv), 0 };
        var dst_data = [_][*c]u8{ pixels.ptr, null, null, null };
        var dst_linesize = [_]c_int{ @intCast(w * self.out_bpp), 0, 0, 0 };
        _ = av.sws_scale(self.sws, &src_data[0], &src_linesize[0], 0, src_h, &dst_data[0], &dst_linesize[0]);

        return .{ .width = w, .height = h, .pixels = pixels, .pts_s = self.rawPtsSeconds(f.pts) };
    }

    /// (Ri)crea il contesto swscale se dimensioni/formato sorgente o la
    /// destinazione sono cambiati.
    fn ensureSws(self: *Player, src_w: c_int, src_h: c_int, src_fmt: c_int, dst_w: c_int, dst_h: c_int) Error!void {
        if (self.sws != null and src_w == self.sws_src_w and src_h == self.sws_src_h and
            src_fmt == self.sws_src_fmt and dst_w == self.sws_dst_w and dst_h == self.sws_dst_h)
        {
            return;
        }
        if (self.sws) |s| {
            av.sws_freeContext(s);
            self.sws = null;
        }
        const sws = av.sws_getContext(src_w, src_h, src_fmt, dst_w, dst_h, self.out_fmt, c.SWS_FAST_BILINEAR, null, null, null) orelse return Error.ScaleInitFailed;
        self.sws = sws;
        self.sws_src_w = src_w;
        self.sws_src_h = src_h;
        self.sws_src_fmt = src_fmt;
        self.sws_dst_w = dst_w;
        self.sws_dst_h = dst_h;
    }

    /// Converte `src` (self.frame, oppure sw_frame dopo il download VAAPI) in
    /// pixel impacchettati scalati a `max_dim`. ensureSws è keyed anche sul
    /// formato sorgente, quindi il passaggio dinamico YUV420P↔NV12 è coperto.
    fn scaleCurrent(self: *Player, src: [*c]c.AVFrame, max_dim: usize, allocator: std.mem.Allocator, pts_s: f64) Error!Frame {
        const src_w = src.*.width;
        const src_h = src.*.height;
        const dims = fitDims(src_w, src_h, max_dim);
        try self.ensureSws(src_w, src_h, src.*.format, dims.w, dims.h);

        const w: usize = @intCast(dims.w);
        const h: usize = @intCast(dims.h);
        const pixels = try self.outBuf(w * h * self.out_bpp, allocator);

        var dst_data = [_][*c]u8{ pixels.ptr, null, null, null };
        var dst_linesize = [_]c_int{ @intCast(w * self.out_bpp), 0, 0, 0 };
        _ = av.sws_scale(self.sws, &src.*.data[0], &src.*.linesize[0], 0, src_h, &dst_data[0], &dst_linesize[0]);

        return .{ .width = w, .height = h, .pixels = pixels, .pts_s = pts_s };
    }

    /// Riposiziona la riproduzione a `seconds` (approssimato al keyframe più
    /// vicino) e svuota i buffer del decoder.
    pub fn seek(self: *Player, seconds: f64) void {
        if (self.time_base > 0) {
            const ts: i64 = @intFromFloat(seconds / self.time_base);
            _ = av.av_seek_frame(self.fmt_ctx, self.video_stream, ts, c.AVSEEK_FLAG_BACKWARD);
        } else {
            // Senza time_base il ts è in unità AV_TIME_BASE: va passato con stream
            // index -1 (default), altrimenti verrebbe interpretato nella time_base
            // dello stream video → seek a una posizione sbagliata.
            const ts: i64 = @intFromFloat(seconds * @as(f64, c.AV_TIME_BASE));
            _ = av.av_seek_frame(self.fmt_ctx, -1, ts, c.AVSEEK_FLAG_BACKWARD);
        }
        // Rimappa il contatore del PTS sintetico al punto di seek (per gli AVI
        // senza timestamp, così il pacing riprende coerente dalla nuova posizione).
        self.frame_index = @intFromFloat(@max(0, seconds) * self.frame_rate);
        if (comptime cvp9_enabled) {
            if (self.is_vp9) {
                // cvp9 non ha una flush: ricrea il contesto per azzerare i frame di
                // riferimento (dal keyframe il decode riparte pulito). Se la ricreazione
                // fallisce, ripiega su libav (il contesto avcodec è già aperto).
                if (self.cvp9_ctx) |cx| cx.destroy();
                self.cvp9_ctx = cvp9.Ctx.create();
                if (self.cvp9_ctx == null) {
                    self.is_vp9 = false;
                    av.avcodec_flush_buffers(self.codec_ctx);
                }
                return;
            }
        }
        av.avcodec_flush_buffers(self.codec_ctx);
    }
};

/// Scorciatoia one-shot: primo frame video del file in RGB24 scalato a
/// `max_dim`. Usata per poster/anteprima.
pub fn firstVideoFrame(path: [*:0]const u8, max_dim: usize, allocator: std.mem.Allocator) Error!Frame {
    // Poster via libav (allow_cvp9 = false): un singolo frame non giustifica il
    // costo di un contesto GPU cvp9.
    var player = try Player.openEx(path, false);
    defer player.deinit();
    return (try player.nextFrame(max_dim, allocator, null)) orelse Error.NoFrameDecoded;
}
