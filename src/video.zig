//! Player video nativo per zuer-gui: apertura container, avanzamento della
//! riproduzione, decodifica dei frame in `static_rgba` e disegno dei controlli
//! overlay (timeline + play/pausa, stile YouTube).
//!
//! È la controparte a finestra del decoder `media` (poster). Tutta l'interazione
//! con libav vive in `player.zig`, importato qui **solo** quando il player video è
//! abilitato (`build_options.video`); altrimenti è uno stub e ogni funzione reale
//! resta non-analizzata perché gui.zig la chiama solo sotto `if (has_video)`.
//! Il resto del viewer (testo/immagini/mesh) non dipende da questo modulo:
//! `has_video` è così un vero confine di modulo, non solo un flag sparso.

const std = @import("std");
const builtin = @import("builtin");
const zicro = @import("zicro");
const paint = zicro.paint;
const glyph = @import("glyph.zig");

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

/// Orologio monotono in millisecondi, stessa primitiva di `nowMs` in gui.zig
/// (Linux: `clock_gettime(MONOTONIC)`; Windows: `GetTickCount64`). Usato per il
/// budget di tempo del catch-up post-seek in `advanceVideo`.
fn nowMs() i64 {
    if (comptime builtin.os.tag == .windows) {
        return @intCast(GetTickCount64());
    } else {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
}

// player.zig fa un @cImport degli header libav: importalo solo quando il video è
// attivo, con uno stub minimale altrimenti (vedi il gate `has_video` in gui.zig).
const player_mod = if (@import("build_options").video) @import("decoders/player.zig") else struct {
    pub const Player = struct {
        pub fn deinit(_: *Player) void {}
    };
    pub const Frame = struct {};
};

// Audio del player (thread + device zicro). Solo con video attivo; altrimenti uno
// stub, mai usato (gui chiama il path video sotto `if (has_video)` comptime).
const AudioPlayer = if (@import("build_options").video) @import("audio_player.zig").AudioPlayer else struct {};

/// Frame video decodificato al massimo a questa dimensione per lato (limita memoria
/// e tempo di rasterizzazione: i 4K si riscalano a 1920 sul lato lungo).
const video_max_dim: usize = 1920;

/// Stato del player video nativo (libav). Il *worker* è l'unico a toccare il
/// `Player` (decodifica, seek); il thread finestra comunica solo via flag sotto
/// `mutex` (play/pausa, `seek_to`, attività del mouse per l'auto-hide dei controlli).
pub const VideoState = struct {
    player: ?player_mod.Player = null,
    playing: bool = true,
    pos_s: f64 = 0, // posizione di riproduzione corrente (secondi)
    dur_s: f64 = 0, // durata totale (0 se ignota)
    shown_pts: f64 = 0, // PTS del frame attualmente in `static_rgba`
    // Controlli overlay (stile YouTube): `controls` = alpha di fade (0..1),
    // `idle_s` = secondi dall'ultimo movimento del mouse (guida l'auto-hide).
    // La temporizzazione è ad accumulo di `frame_dt`: nessun orologio a muro.
    controls: f32 = 0,
    idle_s: f64 = 999,
    // Seek richiesto dall'input (secondi, <0 = nessuno) e stato scrubbing.
    seek_to: f64 = -1,
    scrubbing: bool = false,
    // Catch-up post-seek (<0 = inattivo): `p.seek` con AVSEEK_FLAG_BACKWARD
    // atterra al keyframe PRECEDENTE il target; i frame tra keyframe e target
    // vanno decodificati ma NON presentati (altrimenti si vedono secondi di
    // video accelerato). Finché >= 0, `advanceVideo` decodifica a budget di
    // tempo scartando i frame con pts < catchup_until e tiene `pos_s` ancorato
    // al target; il primo frame con pts >= target viene presentato e il campo
    // torna -1.
    catchup_until: f64 = -1,
    // Riproduzione audio (thread + device). null se il file non ha audio o il
    // device non si apre → il video va muto. Quando presente E in avanzamento, è
    // il clock master; `audio_clk_prev` traccia il valore precedente per capire se
    // sta davvero drenando (device muto → clock fermo → NON congelare il video).
    audio: ?*AudioPlayer = null,
    audio_clk_prev: f64 = -1,
    // Modalità audio-only (mp3, wav, flac…): nessun `player` video, il frame è un
    // oscilloscopio disegnato dai campioni live (`drawOscilloscope`). La stessa
    // macchina di controlli/seek/pausa del video vale identica.
    audio_only: bool = false,
    // Testina di lettura dell'oscilloscopio (indice ASSOLUTO di campione, stesse
    // unità di `AudioPlayer.scopeWritten`). Avanza al wall-clock (`dt·rate`) così il
    // tracciato scorre in continuo tra un blocco audio e l'altro; si riaggancia se
    // esce dai campioni validi (pausa, seek, underrun).
    scope_head: f64 = 0,

    pub fn isActive(self: *const VideoState) bool {
        return self.player != null or self.audio_only;
    }

    /// Chiude il container libav (e ferma l'audio). Idempotente: azzera anche
    /// `player` così una seconda chiamata è un no-op e lo stato è pronto per un
    /// eventuale `setupVideo` successivo (navigazione verso un altro video).
    pub fn deinit(self: *VideoState) void {
        if (@import("build_options").video) {
            if (self.audio) |a| a.stopAndDestroy();
            self.audio = null;
        }
        if (self.player) |*p| p.deinit();
        self.player = null;
        // Riporta a sentinella lo stato di riproduzione residuo: un seek o uno
        // scrubbing pendenti non devono applicarsi al PROSSIMO video aperto, e
        // il clock audio precedente non deve inquinare la drift-correction.
        self.seek_to = -1;
        self.scrubbing = false;
        self.catchup_until = -1;
        self.audio_clk_prev = -1;
        self.audio_only = false;
        self.scope_head = 0;
    }
};

/// Destinazione del frame corrente: `gpa` più i puntatori al buffer RGBA e alle sue
/// dimensioni (locali del thread finestra in gui.zig). Disaccoppia il player dal
/// `GuiAppState` completo — tocca solo questi campi.
pub const FrameSink = struct {
    gpa: std.mem.Allocator,
    rgba: *[]u8,
    w: *u32,
    h: *u32,
};

/// Primo frame (poster) restituito da `setupVideo`: il chiamante ne prende possesso
/// (diventa `static_rgba`).
pub const VideoFirst = struct { rgba: []u8, w: u32, h: u32 };

/// Apre il player video, decodifica il primo frame (poster) in RGBA e inizializza
/// `vs` (durata, posizione, temporizzazione, `playing`). Il chiamante prende
/// possesso di `.rgba` (→ `static_rgba`) e di `vs.player` (chiuso da `deinit`).
pub fn setupVideo(vs: *VideoState, path: []const u8, gpa: std.mem.Allocator) !VideoFirst {
    // Strippa un eventuale suffisso `#N` (pagina/frammento interno) SOLO se dopo
    // il `#` ci sono esclusivamente cifre: un nome legittimo come "video #1.mp4"
    // non va troncato.
    var clean: []const u8 = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| {
        const suffix = path[h + 1 ..];
        const all_digits = suffix.len > 0 and blk: {
            for (suffix) |ch| if (!std.ascii.isDigit(ch)) break :blk false;
            break :blk true;
        };
        if (all_digits) clean = path[0..h];
    }
    const path_z = try gpa.dupeZ(u8, clean);
    defer gpa.free(path_z);

    var p = try player_mod.Player.open(path_z.ptr);
    errdefer p.deinit();
    // Il player live emette RGBA prestando il proprio scratch: copialo nel poster di
    // proprietà del chiamante (→ `static_rgba`) prima che `p` avanzi al frame dopo.
    const frame = (try p.nextFrame(video_max_dim, gpa)) orelse return error.NoFrameDecoded;

    const w: u32 = @intCast(frame.width);
    const h: u32 = @intCast(frame.height);
    const rgba = try gpa.alloc(u8, @as(usize, w) * h * 4);
    @memcpy(rgba, frame.pixels[0 .. @as(usize, w) * h * 4]);

    vs.dur_s = p.duration_s;
    vs.pos_s = frame.pts_s;
    vs.shown_pts = frame.pts_s;
    vs.playing = true;
    vs.player = p;
    // Avvia l'audio (handle libav separato + thread). null se il file è muto.
    vs.audio = AudioPlayer.start(path_z.ptr, gpa);
    return .{ .rgba = rgba, .w = w, .h = h };
}

/// Apre SOLO l'audio di un file (mp3, wav, flac, ogg…) e mette `vs` in modalità
/// visualizzatore: nessun player video, l'oscilloscopio viene disegnato dai
/// campioni live in `advanceAudio`+`drawOscilloscope`. Ritorna un canvas iniziale
/// (→ `static_rgba`) così la finestra nasce già dimensionata come un video. Usato
/// da `nav.startVideo` come fallback quando `setupVideo` non trova stream video.
pub fn setupAudio(vs: *VideoState, path: []const u8, gpa: std.mem.Allocator) !VideoFirst {
    if (comptime @import("build_options").video) {
        var clean: []const u8 = path;
        if (std.mem.indexOfScalar(u8, path, '#')) |h| clean = path[0..h];
        const path_z = try gpa.dupeZ(u8, clean);
        defer gpa.free(path_z);

        const a = AudioPlayer.start(path_z.ptr, gpa) orelse return error.NoAudio;
        errdefer a.stopAndDestroy();

        const w: u32 = 960;
        const h: u32 = 540;
        const rgba = try gpa.alloc(u8, @as(usize, w) * h * 4);
        drawOscBackground(rgba, w, h);

        vs.audio = a;
        vs.audio_only = true;
        vs.player = null;
        vs.dur_s = a.duration_s;
        vs.pos_s = 0;
        vs.shown_pts = 0;
        vs.playing = true;
        return .{ .rgba = rgba, .w = w, .h = h };
    }
    return error.NoAudio;
}

/// Copia il frame corrente (RGBA, prestato dal player) in `sink.rgba`, riallocando
/// solo se cambia la dimensione. Non prende possesso di `fr.pixels` (è lo scratch
/// del player, valido solo fino al prossimo `nextFrame`): va copiato subito.
fn updateVideoFrame(sink: FrameSink, fr: player_mod.Frame) void {
    const w: u32 = @intCast(fr.width);
    const h: u32 = @intCast(fr.height);
    const need = @as(usize, w) * h * 4;
    if (sink.rgba.*.len != need) {
        sink.gpa.free(sink.rgba.*);
        sink.rgba.* = sink.gpa.alloc(u8, need) catch {
            sink.rgba.* = &.{};
            sink.w.* = 0;
            sink.h.* = 0;
            return;
        };
    }
    @memcpy(sink.rgba.*, fr.pixels[0..need]);
    sink.w.* = w;
    sink.h.* = h;
}

/// Avanza la riproduzione di `dt` secondi: applica un seek pendente, fa avanzare
/// `pos_s`, gestisce il loop a fine video e decodifica in avanti finché il frame
/// mostrato raggiunge `pos_s` (recupero, con tetto di iterazioni per non stallare).
/// Ritorna `true` se ha aggiornato il frame in `sink.rgba` (→ serve ricomporre).
pub fn advanceVideo(sink: FrameSink, vs: *VideoState, dt: f32) bool {
    if (vs.seek_to >= 0) {
        if (vs.player) |*p| p.seek(vs.seek_to);
        if (comptime @import("build_options").video) {
            if (vs.audio) |a| a.seek(vs.seek_to);
        }
        vs.pos_s = vs.seek_to;
        vs.shown_pts = vs.seek_to - 1.0; // forza il decode del prossimo frame
        // Arma il catch-up: dal keyframe (precedente) fino al target si decodifica
        // senza presentare. Un seek arrivato DURANTE un catch-up passa di qui e
        // aggiorna semplicemente il target.
        vs.catchup_until = vs.seek_to;
        vs.seek_to = -1;
    } else if (vs.catchup_until >= 0) {
        // Catch-up in corso: `pos_s` resta ancorato al target (niente avanzamento
        // wall-clock, altrimenti il traguardo si allontana mentre recuperiamo e il
        // recupero si allunga). L'audio riceve comunque lo stato play/pausa; il
        // clock precedente viene riallineato così la drift-correction riparte
        // pulita a recupero finito.
        if (comptime @import("build_options").video) {
            if (vs.audio) |a| {
                a.setPlaying(vs.playing);
                vs.audio_clk_prev = a.clockSeconds();
            }
        }
        vs.pos_s = vs.catchup_until;
    } else {
        // Timing del video. `pos_s` avanza SEMPRE col wall-clock (`dt`), così la
        // cadenza dei frame è regolare e non eredita gli scatti del clock audio (che
        // salta a passi di ~20 ms per blocco). Se l'audio DRENA davvero (device
        // attivo) lo usiamo solo per correggere la DERIVA e restare in sync A/V:
        // deriva grande (avvio/seek/loop) → resync duro, piccola → nudge morbido
        // impercettibile. Se l'audio è fermo o assente resta il puro wall-clock, così
        // il video non si congela mai per colpa dell'audio.
        var drained = false;
        var audio_pos: f64 = 0;
        if (comptime @import("build_options").video) {
            if (vs.audio) |a| {
                a.setPlaying(vs.playing);
                const ac = a.clockSeconds();
                if (ac > vs.audio_clk_prev + 0.0005) drained = true;
                vs.audio_clk_prev = ac;
                audio_pos = ac;
            }
        }
        if (vs.playing) {
            vs.pos_s += dt;
            if (drained) {
                const err = audio_pos - vs.pos_s;
                if (@abs(err) > 0.2) vs.pos_s = audio_pos else vs.pos_s += err * 0.05;
            }
        }
    }
    if (vs.dur_s > 0 and vs.pos_s >= vs.dur_s) {
        if (vs.player) |*p| p.seek(0);
        // Loop coordinato video/audio: riavvolgi anche l'audio, altrimenti il suo
        // auto-rewind a EOF e il seek del video si rincorrono (seek-spam/freeze).
        if (comptime @import("build_options").video) {
            if (vs.audio) |a| a.seek(0);
        }
        vs.pos_s = 0;
        vs.shown_pts = -1;
        // Un target di catch-up oltre la durata non è più raggiungibile dopo il
        // riavvolgimento: disarmalo, si riparte in riproduzione normale da zero.
        vs.catchup_until = -1;
        // Clock audio precedente a sentinella: la drift-correction riparte pulita
        // dopo il salto all'indietro (il vecchio valore direbbe "clock fermo").
        vs.audio_clk_prev = -1;
    }
    var decoded_any = false;
    // Catch-up post-seek: decodifica in un loop a BUDGET DI TEMPO (~8 ms per
    // chiamata, il worker gira a 120 Hz quindi il recupero prosegue ai giri
    // successivi) SCARTANDO i frame con pts < target — niente updateVideoFrame,
    // niente copia nel sink, quindi niente "fast-forward visibile". Il primo
    // frame con pts >= target viene presentato subito (lo scratch del player è
    // valido solo fino al prossimo nextFrame: non si può rimandare) e il
    // catch-up si chiude.
    if (vs.catchup_until >= 0) {
        const target = vs.catchup_until;
        const budget_ms: i64 = 8;
        const t0 = nowMs();
        while (nowMs() - t0 < budget_ms) {
            const p = if (vs.player) |*pl| pl else {
                vs.catchup_until = -1;
                break;
            };
            const maybe = p.nextFrame(video_max_dim, sink.gpa) catch |err| {
                // Errore di decode durante il catch-up: logga, disarma e torna
                // al percorso normale (si riprova frame per frame al giro dopo).
                std.debug.print("[video] decode in catch-up fallito: {s}\n", .{@errorName(err)});
                vs.catchup_until = -1;
                break;
            };
            if (maybe) |fr| {
                if (fr.pts_s >= target) {
                    // Primo frame al/oltre il target: presentalo e chiudi il catch-up.
                    updateVideoFrame(sink, fr);
                    vs.shown_pts = fr.pts_s;
                    decoded_any = true;
                    vs.catchup_until = -1;
                    break;
                }
                // Frame intermedio: scartato (mai presentato). `shown_pts` resta
                // quello del frame in `static_rgba`, coerente col suo contratto.
            } else {
                // EOF durante il catch-up (target oltre la coda del file): disarma
                // e lascia che il percorso normale qui sotto gestisca il loop a 0.
                vs.catchup_until = -1;
                break;
            }
        }
    }
    var guard: u32 = 0;
    // Decodifica AL PIÙ un frame per chiamata: mai un "burst" di catch-up che
    // congela il present per centinaia di ms. La decodifica (~1 ms) + scaling
    // (~10 ms) è più veloce del real-time (33 ms @30fps), quindi restando a 1
    // frame/iterazione il video sta comunque al passo, ma senza scatti.
    // Con catch-up ancora attivo (budget esaurito) questo loop NON deve girare:
    // presenterebbe un frame intermedio, l'esatto difetto che stiamo evitando.
    // In PAUSA non si avanza: `pos_s` (barra) è congelato ma se la decodifica era
    // in ritardo sul wall-clock `shown_pts` gli è rimasto indietro — senza questo
    // gate il loop continuerebbe a decodificare un frame per giro per raggiungere
    // `pos_s`, e l'immagine "continuerebbe a girare" a barra ferma (il seek/scrub
    // resta comunque coperto dal ramo catch-up qui sopra, che non guarda `playing`).
    while (vs.playing and vs.catchup_until < 0 and vs.shown_pts < vs.pos_s and guard < 1) : (guard += 1) {
        // Unwrap guardato come per ogni altro accesso a `vs.player` nella funzione.
        const p = if (vs.player) |*pl| pl else break;
        // Errore di decode (packet corrotto a metà file) ≠ EOF: logga e salta il
        // frame SENZA riavvolgere — si riprova al prossimo giro. Solo il ritorno
        // `null` (vero fine stream) fa ripartire il loop.
        const maybe = p.nextFrame(video_max_dim, sink.gpa) catch |err| {
            std.debug.print("[video] decode frame fallito: {s}\n", .{@errorName(err)});
            break;
        };
        if (maybe) |fr| {
            updateVideoFrame(sink, fr);
            vs.shown_pts = fr.pts_s;
            decoded_any = true;
        } else {
            p.seek(0); // EOF → loop
            // Come nel ramo `pos_s >= dur_s`: riavvolgi anche l'audio e azzera il
            // clock precedente, così video e audio ripartono insieme da zero.
            if (comptime @import("build_options").video) {
                if (vs.audio) |a| a.seek(0);
            }
            vs.pos_s = 0;
            vs.shown_pts = 0;
            vs.audio_clk_prev = -1;
            break;
        }
    }
    return decoded_any;
}

/// Modalità audio-only: aggiorna la temporizzazione (posizione, seek, play/pausa)
/// dal clock audio. Non decodifica nulla — il "frame" è l'oscilloscopio, disegnato
/// a parte con `drawOscilloscope`. Ritorna true in riproduzione (il tracciato si
/// muove → il chiamante ripresenta) e false in pausa (frame congelato).
pub fn advanceAudio(vs: *VideoState, dt: f32) bool {
    if (comptime @import("build_options").video) {
        if (vs.seek_to >= 0) {
            if (vs.audio) |a| a.seek(vs.seek_to);
            vs.pos_s = vs.seek_to;
            vs.seek_to = -1;
            vs.scope_head = 0; // fuori banda → il draw riaggancia al nuovo flusso
        } else if (vs.audio) |a| {
            a.setPlaying(vs.playing);
            // Il clock audio è la verità: in pausa è fermo, a fine brano l'auto-loop
            // del thread audio lo riporta a 0 e la barra riparte da capo.
            if (vs.playing) {
                vs.pos_s = a.clockSeconds();
                // Testina al wall-clock: scorre di `dt·rate` campioni. In pausa NON
                // avanza (frame congelato). Il clamp entro la banda valida del ring
                // (e il riaggancio se ne esce) sta nel draw, che rilegge `scope_w`.
                vs.scope_head += @as(f64, dt) * AudioPlayer.scope_rate;
            }
        }
        if (vs.dur_s > 0 and vs.pos_s > vs.dur_s) vs.pos_s = vs.dur_s;
        return vs.playing;
    }
    return false;
}

// ── Oscilloscopio stile Winamp (neon glow) ──────────────────────────────────
const osc_bg_edge = [3]u8{ 3, 5, 9 }; // ai bordi: quasi nero
const osc_bg_center = [3]u8{ 10, 16, 26 }; // al centro: un filo di blu notte

/// Fondo a gradiente verticale (scuro ai bordi, un po' più chiaro al centro) per
/// dare profondità al vetro. RGBA opaco.
fn drawOscBackground(buf: []u8, W: u32, H: u32) void {
    if (H == 0) return;
    const half: f32 = @as(f32, @floatFromInt(H)) * 0.5;
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        const dy = @abs(@as(f32, @floatFromInt(y)) - half) / @max(1.0, half); // 0 centro → 1 bordo
        const t = (1.0 - dy) * (1.0 - dy); // luce concentrata al centro
        const r: u8 = @intFromFloat(@as(f32, @floatFromInt(osc_bg_edge[0])) + (@as(f32, @floatFromInt(osc_bg_center[0])) - @as(f32, @floatFromInt(osc_bg_edge[0]))) * t);
        const g: u8 = @intFromFloat(@as(f32, @floatFromInt(osc_bg_edge[1])) + (@as(f32, @floatFromInt(osc_bg_center[1])) - @as(f32, @floatFromInt(osc_bg_edge[1]))) * t);
        const b: u8 = @intFromFloat(@as(f32, @floatFromInt(osc_bg_edge[2])) + (@as(f32, @floatFromInt(osc_bg_center[2])) - @as(f32, @floatFromInt(osc_bg_edge[2]))) * t);
        const row = @as(usize, y) * W;
        var x: u32 = 0;
        while (x < W) : (x += 1) {
            const idx = (row + x) * 4;
            buf[idx + 0] = r;
            buf[idx + 1] = g;
            buf[idx + 2] = b;
            buf[idx + 3] = 255;
        }
    }
}

/// Somma additiva (con clamp a 255) di un colore f32 sul pixel RGBA: è ciò che dà
/// il "bloom" neon quando linea e glow si sovrappongono su fondo scuro.
fn addPix(buf: []u8, idx: usize, r: f32, g: f32, b: f32) void {
    buf[idx + 0] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(buf[idx + 0])) + r));
    buf[idx + 1] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(buf[idx + 1])) + g));
    buf[idx + 2] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(buf[idx + 2])) + b));
}

/// Colore del tracciato per magnitudine 0..1: verde al centro → giallo → rosso ai
/// picchi (gradiente stile analizzatore Winamp).
fn oscColor(mag: f32) [3]u8 {
    const m = std.math.clamp(mag, 0.0, 1.0);
    if (m < 0.5) {
        const t = m / 0.5; // verde → giallo
        return .{ @intFromFloat(60.0 + 195.0 * t), 255, @intFromFloat(120.0 * (1.0 - t)) };
    }
    const t = (m - 0.5) / 0.5; // giallo → rosso
    return .{ 255, @intFromFloat(255.0 * (1.0 - 0.75 * t)), 0 };
}

/// Disegna l'oscilloscopio Winamp: fondo scuro, linea centrale fioca e il
/// tracciato dei campioni live (colonna verticale connessa, colore per ampiezza).
pub fn drawOscilloscope(buf: []u8, W: u32, H: u32, vs: *VideoState) void {
    drawOscBackground(buf, W, H);
    if (W == 0 or H == 0) return;
    if (comptime !@import("build_options").video) return;
    const a = vs.audio orelse return;

    const Hi: i32 = @intCast(H);
    const cyf: f32 = @as(f32, @floatFromInt(H)) * 0.5;
    const cy: i32 = @intFromFloat(cyf);

    // Linea centrale di riferimento: glow orizzontale fioco (additivo).
    {
        const band: i32 = @max(@as(i32, 1), @divTrunc(Hi, 260));
        var dyi: i32 = -band;
        while (dyi <= band) : (dyi += 1) {
            const yy = cy + dyi;
            if (yy < 0 or yy >= Hi) continue;
            const f = 1.0 - @abs(@as(f32, @floatFromInt(dyi))) / @as(f32, @floatFromInt(band + 1));
            const row = @as(usize, @intCast(yy)) * W;
            var x: u32 = 0;
            while (x < W) : (x += 1) addPix(buf, (row + x) * 4, 4.0 * f, 20.0 * f, 12.0 * f);
        }
    }

    // ~2048 campioni (~43 ms) danno un tracciato stabile ma vivo. Mappati sulle
    // colonne della finestra, con linea connessa tra colonne adiacenti.
    var samples: [2048]f32 = undefined;
    const n: usize = @min(samples.len, @max(@as(usize, 1), @as(usize, W)));

    // Testina di lettura ancorata al wall-clock (avanzata in `advanceAudio`),
    // riclampata sulla banda valida del ring RILEGGENDO `scope_w` ora. Latenza
    // MINIMA: nessun buffer artificiale dietro la punta — quando la testina
    // raggiunge l'ultimo campione (`> scope_w`, tra un blocco e l'altro) si aggancia
    // lì (`= scope_w`) e riparte appena arriva un blocco nuovo. Così il bordo destro
    // del tracciato è sempre il campione più recente disponibile: media ~mezzo
    // blocco di ritardo. Se resta troppo indietro (pausa lunga/seek/underrun) →
    // riaggancio secco alla punta.
    const cap = AudioPlayer.scope_capacity;
    const w = a.scopeWritten();
    const min_end: usize = if (w > cap - n) w - (cap - n) else 0;
    var end: usize = if (vs.scope_head <= 0) 0 else @intFromFloat(vs.scope_head);
    if (end > w or end < min_end) {
        end = w; // aggancio alla punta (nessun lag artificiale)
        vs.scope_head = @floatFromInt(end);
    }
    a.copyScopeAt(samples[0..n], end);

    const amp: f32 = @as(f32, @floatFromInt(H)) * 0.44;
    const den: usize = @max(@as(usize, 1), @as(usize, W) - 1);
    // Raggio del glow: scala con l'altezza (~3-9 px) per un neon coerente a ogni
    // dimensione di finestra. `invR` normalizza il falloff.
    const R: i32 = @max(@as(i32, 5), @divTrunc(Hi, 90));
    const invR: f32 = 1.0 / @as(f32, @floatFromInt(R + 1));
    var prev_y: i32 = cy;
    var x: u32 = 0;
    while (x < W) : (x += 1) {
        const si = (@as(usize, x) * (n - 1)) / den;
        const s = std.math.clamp(samples[@min(si, n - 1)], -1.0, 1.0);
        const y: i32 = @intFromFloat(cyf - s * amp);
        const col = oscColor(@abs(s));
        const cr: f32 = @floatFromInt(col[0]);
        const cg: f32 = @floatFromInt(col[1]);
        const cb: f32 = @floatFromInt(col[2]);
        // Segmento connesso tra colonne: core pieno tra prev_y..y, glow additivo ±R.
        const ylo = @min(prev_y, y);
        const yhi = @max(prev_y, y);
        var yy = @max(@as(i32, 0), ylo - R);
        const yy_end = @min(Hi - 1, yhi + R);
        while (yy <= yy_end) : (yy += 1) {
            const idx = (@as(usize, @intCast(yy)) * W + x) * 4;
            if (yy >= ylo and yy <= yhi) {
                // Core: tiene la tinta neon (0.8·colore) + spinta bianca contenuta.
                addPix(buf, idx, cr * 0.8 + 95.0, cg * 0.8 + 95.0, cb * 0.8 + 95.0);
            } else {
                const d: f32 = @floatFromInt(if (yy < ylo) ylo - yy else yy - yhi);
                const f = 1.0 - d * invR; // 0..1
                if (f > 0) {
                    const g2 = f * f * 1.35; // falloff morbido, alone con più corpo
                    addPix(buf, idx, cr * g2, cg * g2, cb * g2);
                }
            }
        }
        prev_y = y;
    }
}

/// Alpha-blend src-over di un colore sul pixel RGBA in `buf[idx..]`.
fn blendPixel(buf: []u8, idx: usize, r: u8, g: u8, b: u8, a: u8) void {
    const af: u32 = a;
    const inv: u32 = 255 - af;
    buf[idx + 0] = @intCast((@as(u32, r) * af + @as(u32, buf[idx + 0]) * inv) / 255);
    buf[idx + 1] = @intCast((@as(u32, g) * af + @as(u32, buf[idx + 1]) * inv) / 255);
    buf[idx + 2] = @intCast((@as(u32, b) * af + @as(u32, buf[idx + 2]) * inv) / 255);
    buf[idx + 3] = @max(buf[idx + 3], a);
}

/// Triangolo "play" pieno (punta a destra) fuso sul buffer RGBA, alpha `a`.
fn fillPlayTriangle(buf: []u8, W: u32, H: u32, cx: f32, cy: f32, s: f32, a: f32) void {
    const half = s / 2.0;
    const left = cx - s * 0.35;
    const right = cx + s * 0.45;
    const alpha: u8 = @intFromFloat(@round(255.0 * std.math.clamp(a, 0.0, 1.0)));
    var y: i32 = @intFromFloat(@floor(cy - half));
    const y1: i32 = @intFromFloat(@ceil(cy + half));
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    while (y < y1) : (y += 1) {
        if (y < 0 or y >= hi) continue;
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const dy = @abs(fy - cy);
        if (dy > half) continue;
        const frac = 1.0 - dy / half; // 1 al centro, 0 agli estremi
        const xr = left + (right - left) * frac;
        var x: i32 = @intFromFloat(@floor(left));
        const xend: i32 = @intFromFloat(@ceil(xr));
        while (x < xend) : (x += 1) {
            if (x < 0 or x >= wi) continue;
            const off = (@as(usize, @intCast(y)) * W + @as(usize, @intCast(x))) * 4;
            blendPixel(buf, off, 255, 255, 255, alpha);
        }
    }
}

/// Rettangolo del video in aspect-fit CENTRATO nell'area contenuto (`panel`). Il
/// frame video è composto in un buffer STRETTO (`w`×`h`): è zrame a centrarlo nel
/// vetro e ad arrotondarne gli angoli (content_radius), esattamente come per ogni
/// altro tipo di file. `off_x/off_y` è l'offset di centratura che l'hit-test del
/// mouse sottrae; la divisione intera rispecchia la centratura di `chrome.composeContent`.
pub const FitRect = struct { off_x: f32, off_y: f32, w: u32, h: u32 };

pub fn videoFitRect(panel_w: u32, panel_h: u32, vid_w: u32, vid_h: u32) FitRect {
    if (panel_w == 0 or panel_h == 0 or vid_w == 0 or vid_h == 0)
        return .{ .off_x = 0, .off_y = 0, .w = @max(1, panel_w), .h = @max(1, panel_h) };
    const va = @as(f32, @floatFromInt(vid_w)) / @as(f32, @floatFromInt(vid_h));
    const ca = @as(f32, @floatFromInt(panel_w)) / @as(f32, @floatFromInt(panel_h));
    var w = panel_w;
    var h = panel_h;
    if (va > ca) {
        h = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(panel_w)) / va))));
    } else {
        w = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(panel_h)) * va))));
    }
    return .{ .off_x = @floatFromInt((panel_w - w) / 2), .off_y = @floatFromInt((panel_h - h) / 2), .w = w, .h = h };
}

/// Layout della riga di controlli (coordinate locali all'area video, origine in alto
/// a sinistra del video). Una sola riga: play/pausa · tempo · timeline · durata.
const Ctrl = struct {
    cy: f32, // centro verticale della riga
    play_x: f32, // centro del pulsante play/pausa
    el_x: f32, // inizio testo tempo trascorso
    tl_x0: f32, // inizio timeline
    tl_x1: f32, // fine timeline
    dur_x: f32, // inizio testo durata
    scrim_h: f32,
};

fn ctrlLayout(vw: u32, vh: u32) Ctrl {
    const w: f32 = @floatFromInt(vw);
    const h: f32 = @floatFromInt(vh);
    const pad: f32 = 18.0;
    const time_w: f32 = 52.0; // larghezza riservata a "MM:SS"
    const gap: f32 = 12.0;
    const cy = h - 26.0;
    const play_x = pad + 8.0;
    const el_x = play_x + 22.0;
    const tl_x0 = el_x + time_w + gap;
    const tl_x1 = w - pad - time_w - gap;
    const dur_x = w - pad - time_w;
    return .{ .cy = cy, .play_x = play_x, .el_x = el_x, .tl_x0 = tl_x0, .tl_x1 = tl_x1, .dur_x = dur_x, .scrim_h = @min(h, 96.0) };
}

/// Formatta i secondi in "M:SS" (o "H:MM:SS" oltre l'ora) dentro `out`.
fn formatTime(sec: f64, out: []u8) []const u8 {
    const total: u64 = if (sec > 0) @intFromFloat(sec) else 0;
    const s = total % 60;
    const m = (total / 60) % 60;
    const hh = total / 3600;
    if (hh > 0) return std.fmt.bufPrint(out, "{d}:{d:0>2}:{d:0>2}", .{ hh, m, s }) catch out[0..0];
    return std.fmt.bufPrint(out, "{d}:{d:0>2}", .{ m, s }) catch out[0..0];
}

/// Disegna testo monospazio (Hack) a partire da (`x`,`baseline`), colore chiaro
/// modulato da `a`. Coordinate nel buffer `W`×`H`.
fn drawText(buf: []u8, W: u32, H: u32, raster: *glyph.Raster, x: i32, baseline: i32, text: []const u8, a: f32) void {
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    const cell = raster.advance;
    if (cell <= 0) return;
    var pen_x = x;
    var view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const gph = raster.getGlyph(.regular, cp) catch {
            pen_x += cell;
            continue;
        };
        if (gph.bitmap.len != 0) {
            const gx0 = pen_x + gph.xoff;
            const gy0 = baseline + gph.yoff;
            var gy: i32 = 0;
            while (gy < gph.h) : (gy += 1) {
                const py = gy0 + gy;
                if (py < 0 or py >= hi) continue;
                var gx: i32 = 0;
                while (gx < gph.w) : (gx += 1) {
                    const px = gx0 + gx;
                    if (px < 0 or px >= wi) continue;
                    const cov = gph.bitmap[@intCast(gy * gph.w + gx)];
                    if (cov == 0) continue;
                    const av: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(cov)) * a));
                    if (av == 0) continue;
                    blendPixel(buf, @intCast((py * wi + px) * 4), 235, 238, 245, av);
                }
            }
        }
        pen_x += cell;
    }
}

/// Controlli overlay su UNA riga (play/pausa · tempo · timeline · durata), stile
/// player moderno, disegnati sul buffer video `W`×`H` (l'area video è l'intero
/// buffer), modulati dall'alpha di fade `vs.controls`.
pub fn drawVideoControls(buf: []u8, W: u32, H: u32, vs: *VideoState, raster: ?*glyph.Raster) void {
    const a = std.math.clamp(vs.controls, 0.0, 1.0);
    if (a <= 0.01) return;
    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);
    const L = ctrlLayout(W, H);
    const vwf: f32 = @floatFromInt(W);

    // Scrim: sfuma da trasparente a scuro verso il basso.
    const bands: u32 = 12;
    var i: u32 = 0;
    while (i < bands) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(bands));
        const by = @as(f32, @floatFromInt(H)) - L.scrim_h + t * L.scrim_h;
        const bh = L.scrim_h / @as(f32, @floatFromInt(bands)) + 1.0;
        canvas.fillRoundedRect(0, by, vwf, bh, 0, paint.Color.rgba(0, 0, 0, 0.55 * t * t * a));
    }

    // Timeline + knob.
    const bar_h: f32 = 4.0;
    const tl_y = L.cy - bar_h / 2.0;
    const tl_x = L.tl_x0;
    const tl_w = @max(1.0, L.tl_x1 - L.tl_x0);
    const prog: f32 = if (vs.dur_s > 0) @floatCast(std.math.clamp(vs.pos_s / vs.dur_s, 0.0, 1.0)) else 0.0;
    canvas.fillProgressBar(tl_x, tl_y, tl_w, bar_h, bar_h / 2.0, prog, paint.Color.rgba(255, 255, 255, 0.28 * a), paint.Color.rgba(237, 45, 45, 0.98 * a));
    const knob_x = tl_x + tl_w * prog;
    const knob_r: f32 = if (vs.scrubbing) 8.0 else 6.0;
    canvas.fillRoundedRect(knob_x - knob_r, L.cy - knob_r, knob_r * 2.0, knob_r * 2.0, knob_r, paint.Color.rgba(255, 255, 255, a));

    // Pulsante play/pausa (a sinistra, sulla stessa riga).
    const btn_cx = L.play_x;
    const btn_cy = L.cy;
    const s: f32 = 15.0;
    if (vs.playing) {
        const bw: f32 = 3.5;
        const gap: f32 = 3.0;
        canvas.fillRoundedRect(btn_cx - gap - bw, btn_cy - s / 2.0, bw, s, 1.5, paint.Color.rgba(255, 255, 255, a));
        canvas.fillRoundedRect(btn_cx + gap, btn_cy - s / 2.0, bw, s, 1.5, paint.Color.rgba(255, 255, 255, a));
    } else {
        fillPlayTriangle(buf, W, H, btn_cx, btn_cy, s, a);
    }

    // Testo tempo trascorso / durata (monospazio) allineato alla riga.
    if (raster) |r| {
        const baseline = @as(i32, @intFromFloat(L.cy)) + @divFloor(r.ascent + r.descent, 2);
        var el_buf: [16]u8 = undefined;
        var du_buf: [16]u8 = undefined;
        drawText(buf, W, H, r, @intFromFloat(L.el_x), baseline, formatTime(vs.pos_s, &el_buf), a);
        if (vs.dur_s > 0) drawText(buf, W, H, r, @intFromFloat(L.dur_x), baseline, formatTime(vs.dur_s, &du_buf), a);
    }
}

/// Hit-test dei controlli, in coordinate locali all'area video (`vw`×`vh`).
pub const VideoHit = enum { none, toggle, timeline };
pub fn videoControlsHit(vw: u32, vh: u32, x: f32, y: f32) VideoHit {
    const L = ctrlLayout(vw, vh);
    // Pulsante play/pausa.
    if (@abs(x - L.play_x) <= 16.0 and @abs(y - L.cy) <= 16.0) return .toggle;
    // Timeline: banda generosa attorno alla barra.
    if (y >= L.cy - 12.0 and y <= L.cy + 12.0 and x >= L.tl_x0 - 8.0 and x <= L.tl_x1 + 8.0) return .timeline;
    return .none;
}

/// Frazione 0..1 della timeline per l'ascissa `x` (coordinate locali all'area video).
pub fn videoTimelineFrac(vw: u32, vh: u32, x: f32) f32 {
    const L = ctrlLayout(vw, vh);
    const w = L.tl_x1 - L.tl_x0;
    if (w <= 0) return 0;
    return std.math.clamp((x - L.tl_x0) / w, 0.0, 1.0);
}
