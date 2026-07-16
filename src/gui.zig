//! zuer-gui — viewer GPU a finestra basato su zrame.
//!
//! Decodifica il file con gli stessi plugin di zuer, poi presenta in una
//! finestra Wayland zrame: le mesh sono rasterizzate dal renderer Vulkan
//! offscreen condiviso (`gpu_renderer.zig`), le immagini e testi sono
//! compositati a CPU; il frame finale RGBA viene inviato a zrame per la presentazione.

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu_renderer.zig");
const decoder_mod = @import("decoder.zig");
const text_render = @import("text_render.zig");
// The native video player (libav container/decoding + overlay controls) lives in its own
// module, imported as `videomod` (the local name `vid` is taken by a VideoState pointer in
// the input handler). It owns the conditional libav import; gui.zig calls into it only
// under `if (has_video)`.
const videomod = @import("video.zig");
// Content-kind classification (path/decode → WinKind) + initial window geometry/zoom.
const layout = @import("layout.zig");
const WinKind = layout.WinKind;
// CPU frame compositor (image aspect-fit + text blit + selection + tab bar).
const compose = @import("compose.zig");
const glyph = @import("glyph.zig");
const max_tabs = compose.max_tabs;
// Stato condiviso dell'app (GuiAppState raggruppato per lock + helper posseduti).
const gui_state_mod = @import("gui_state.zig");
const GuiAppState = gui_state_mod.GuiAppState;
const freeTextLines = gui_state_mod.freeTextLines;
const rgbToRgba = gui_state_mod.rgbToRgba;
// Navigazione/caricamento latest-wins (navigate/applyDecoded/loadWorker/prefetch).
const nav = @import("nav.zig");
// Callback input zrame (tastiera/rotella/mouse) + comandi di vista.
const input = @import("input.zig");
// Ricerca YouTube (overlay tasto `y`): stato in Shared, ricerca/streaming yt-dlp.
const yt_search = @import("yt_search.zig");
const file_explorer = @import("file_explorer.zig");
const crash_log = @import("crash_log.zig");
const crash_report = @import("crash_report.zig");
const build_options = @import("build_options");

/// Su Windows l'exe è subsystem GUI: un panic non ha stderr e l'app sparisce
/// muta. Prima del panic di default, lascia una riga in crash.log.
pub const panic = std.debug.FullPanic(panicWithLog);

fn panicWithLog(msg: []const u8, first_trace_addr: ?usize) noreturn {
    crash_log.writeCrash(msg, first_trace_addr orelse @returnAddress());
    std.debug.defaultPanic(msg, first_trace_addr);
}
/// Vulkan mesh/text renderer available (Linux + Windows). Comptime so the GPU code links
/// only when enabled. Distinct from `has_video`: on Windows Vulkan is on but video is off.
const native = build_options.gpu;
/// libav-backed native video player available. Windows + Linux (needs vendored FFmpeg
/// import libs elsewhere). Gates every call into `videomod`'s real player API.
const has_video = build_options.video;
const zrame = @import("zrame");
const zicro = @import("zicro");
const paint = zicro.paint;

// Il testo viene ri-rasterizzato al pointsize scalato: oltre questi limiti la
// resa degrada (corpo minuscolo) o esplode in memoria (immagini enormi).
const text_zoom_min: f32 = 0.4;
const text_zoom_max: f32 = 6.0;

/// Rasterizza il contenuto testuale corrente alla larghezza richiesta e al
/// corpo scalato dallo zoom, sostituendo il buffer statico RGBA.
/// Da chiamare con `state.shared.mutex` già acquisito.
fn rasterizeText(state: *GuiAppState, width: u32, text_zoom: f32) void {
    const pointsize: usize = @intFromFloat(@round(14.0 * text_zoom));
    const opts = text_render.RenderOpts{ .width = @max(width, 64), .pointsize = @max(pointsize, 6) };
    const name = std.fs.path.basename(state.shared.current_file_path);

    if (native and state.text_gpu) {
        rasterizeTextGpu(state, name, opts);
        return;
    }

    // La geometria (wrapping) cambia con larghezza/zoom: la vecchia selezione
    // non è più valida.
    freeTextLines(state);
    gui_state_mod.freeTextDoc(state);
    state.shared.sel_active = false;
    state.shared.sel_selecting = false;

    // Testo/codice/markdown: layout ritenuto, niente bitmap del documento — la
    // pittura avviene per viewport a ogni compose. static_w/h restano le
    // dimensioni LOGICHE (scrollbar/selezione), static_rgba resta vuoto.
    const is_grid_doc = switch (state.shared.decoded) {
        .csv, .workbook => false,
        else => true,
    };
    if (is_grid_doc) {
        const doc = text_render.layoutDoc(state.gpa, &state.shared.decoded, name, opts, &state.shared.text_lines, &state.shared.text_metrics) catch |err| {
            std.debug.print("Impossibile impaginare il testo: {s}\n", .{@errorName(err)});
            return;
        };
        state.gpa.free(state.shared.static_rgba);
        state.shared.static_rgba = &.{};
        state.shared.static_w = @intCast(doc.width);
        state.shared.static_h = @intCast(doc.height);
        state.shared.text_doc = doc;
        rasterizeTabBar(state, width);
        return;
    }

    var img = text_render.renderDoc(state.gpa, &state.shared.decoded, name, opts, &state.shared.text_lines, &state.shared.text_metrics) catch |err| {
        std.debug.print("Impossibile rasterizzare il testo: {s}\n", .{@errorName(err)});
        return;
    };
    defer img.deinit(state.gpa);

    const w: u32 = @intCast(img.width);
    const h: u32 = @intCast(img.height);
    const rgba = rgbToRgba(state.gpa, img.pixels, w, h) catch return;

    state.gpa.free(state.shared.static_rgba);
    state.shared.static_rgba = rgba;
    state.shared.static_w = w;
    state.shared.static_h = h;

    rasterizeTabBar(state, width);
}

/// (Ri)genera la barra delle linguette per un workbook, alla larghezza corrente.
/// Non-workbook → azzera la barra (nessuna linguetta). Immagine RGB → RGBA opaca.
/// Da chiamare con `state.shared.mutex` acquisito (come `rasterizeText`).
fn rasterizeTabBar(state: *GuiAppState, width: u32) void {
    const tb = &state.shared.tab_bar;
    if (state.shared.decoded != .workbook) {
        tb.count = 0;
        return;
    }
    const wb = &state.shared.decoded.workbook;
    var img = text_render.renderTabBar(state.gpa, wb.sheets, wb.active, @max(width, 64), &tb.bounds) catch {
        tb.count = 0;
        return;
    };
    defer img.deinit(state.gpa);

    const tw: u32 = @intCast(img.width);
    const th: u32 = @intCast(img.height);
    const rgba = rgbToRgba(state.gpa, img.pixels, tw, th) catch {
        tb.count = 0;
        return;
    };
    state.gpa.free(tb.rgba);
    tb.rgba = rgba;
    tb.w = tw;
    tb.h = th;
    tb.count = @min(wb.sheets.len, max_tabs);
}

/// Percorso GPU (Soluzione B): costruisce i quad glifo + atlante e li renderizza
/// con la pipeline testo Vulkan, poi copia i pixel RGBA nel buffer statico.
fn rasterizeTextGpu(state: *GuiAppState, name: []const u8, opts: text_render.RenderOpts) void {
    var mesh = text_render.buildTextMesh(state.gpa, &state.shared.decoded, name, opts) catch |err| {
        std.debug.print("Impossibile costruire i quad del testo: {s}\n", .{@errorName(err)});
        return;
    };
    defer mesh.deinit(state.gpa);

    // Renderer sotto il suo lock dedicato (ordine: shared.mutex → renderer_mutex;
    // qui shared.mutex è già tenuto dal chiamante).
    state.renderer_mutex.lockUncancelable(state.io);
    const rgba_src = state.renderer.renderText(
        std.mem.sliceAsBytes(mesh.vertices),
        @intCast(mesh.vertices.len),
        mesh.atlas.pixels,
        @intCast(mesh.atlas.w),
        @intCast(mesh.atlas.h),
        @intCast(mesh.width),
        @intCast(mesh.height),
        text_render.clear_bg,
    ) catch |err| {
        state.renderer_mutex.unlock(state.io);
        std.debug.print("Render testo GPU fallito: {s}\n", .{@errorName(err)});
        return;
    };
    defer state.renderer_mutex.unlock(state.io);

    // Il readback è riusato dalla chiamata successiva: copiane una proprietà.
    // Allineato a 4: `composeTextFrame` aliasa `static_rgba` come []u32 (color-key
    // a word), quindi il buffer deve essere word-aligned come gli altri percorsi.
    const rgba = state.gpa.alignedAlloc(u8, .@"4", rgba_src.len) catch return;
    @memcpy(rgba, rgba_src);
    state.gpa.free(state.shared.static_rgba);
    state.shared.static_rgba = rgba;
    state.shared.static_w = @intCast(mesh.width);
    state.shared.static_h = @intCast(mesh.height);
}

/// Poll della modalità follow (-f), da chiamare con `state.shared.mutex` acquisito
/// e con `decoded == .text`: se il file corrente è cresciuto oltre i byte già
/// mostrati, accoda i byte nuovi a `decoded.text` (buffer gpa per contratto:
/// `Decoded.deinit` libera con gpa) e bumpa `load_seq` così il worker rifà il
/// layout ritenuto. File rimpicciolito (rotazione log) → si riparte dal contenuto
/// nuovo. Ritorna true se lo scroll era agganciato al fondo PRIMA della crescita:
/// il chiamante lo riaggancia dopo il re-layout.
fn followPoll(state: *GuiAppState, viewport_h: u32) bool {
    var path: []const u8 = state.shared.current_file_path;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];

    var f = std.Io.Dir.cwd().openFile(state.io, path, .{}) catch return false;
    defer f.close(state.io);
    const st = f.stat(state.io) catch return false;

    // Primo poll: quanto già mostrato = il testo decodificato (il decoder testo
    // restituisce i byte grezzi del file).
    if (state.shared.follow_off == 0) state.shared.follow_off = state.shared.decoded.text.len;
    const off = state.shared.follow_off;
    if (st.size == off) return false;

    // Agganciato al fondo? Valutato con l'altezza PRE-crescita (mezzo px di slack).
    const pinned = state.shared.scroll_y + @as(f32, @floatFromInt(viewport_h)) >=
        @as(f32, @floatFromInt(state.shared.static_h)) - 2.0;

    if (st.size < off) {
        // Troncato/ruotato: butta il testo vecchio e riparti dal file nuovo.
        const fresh = state.gpa.alloc(u8, @intCast(st.size)) catch return false;
        const n = f.readPositionalAll(state.io, fresh, 0) catch 0;
        var kept: []u8 = fresh;
        if (n < fresh.len) {
            kept = state.gpa.realloc(fresh, n) catch blk: {
                @memset(fresh[n..], ' ');
                break :blk fresh;
            };
        }
        state.gpa.free(@constCast(state.shared.decoded.text));
        state.shared.decoded.text = kept;
        state.shared.follow_off = kept.len;
        state.shared.load_seq +%= 1;
        state.shared.file_changed = true;
        return pinned;
    }

    const add: usize = @intCast(st.size - off);
    const old_len = state.shared.decoded.text.len;
    var buf = state.gpa.realloc(@constCast(state.shared.decoded.text), old_len + add) catch return false;
    // Dopo il realloc il vecchio slice non è più valido: aggiorna subito lo stato.
    state.shared.decoded.text = buf;
    const n = f.readPositionalAll(state.io, buf[old_len..], off) catch 0;
    if (n < add) {
        // Race col writer (o lettura corta): tieni solo ciò che è arrivato davvero.
        state.shared.decoded.text = state.gpa.realloc(buf, old_len + n) catch blk: {
            @memset(buf[old_len + n ..], ' ');
            break :blk buf;
        };
    }
    if (n == 0) return false;
    state.shared.follow_off = off + n;
    state.shared.load_seq +%= 1;
    state.shared.file_changed = true;
    return pinned;
}

/// Schermata di caricamento: sfondo completamente trasparente (si vede il vetro
/// della finestra / blur del compositore) con lo **spinner** di zicro al centro —
/// un arco rotante che "respira", identico a egui. `frame` (contatore a ~60 Hz)
/// fornisce la fase temporale in secondi.
fn drawLoader(buf: []u8, W: u32, H: u32, frame: u32) void {
    const n_px: usize = @as(usize, W) * H;
    // Sfondo trasparente: solo lo spinner resta visibile sul pannello di vetro.
    @memset(buf[0 .. n_px * 4], 0);

    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);
    const cx: f32 = @as(f32, @floatFromInt(W)) / 2.0;
    const cy: f32 = @as(f32, @floatFromInt(H)) / 2.0;
    const radius: f32 = @max(@as(f32, @floatFromInt(@min(W, H))) / 14.0, 18.0);
    const width: f32 = @max(radius / 4.0, 3.0);
    const phase: f32 = @as(f32, @floatFromInt(frame)) / 60.0; // clock ~60 Hz → secondi
    canvas.drawSpinner(cx, cy, radius, width, phase, paint.Color.rgba(205, 210, 230, 1.0));
}

/// Fonde un pixel RGB `(r,g,b)` con copertura `a` sopra il buffer RGBA (alpha
/// straight): tiene il canale alpha al massimo tra esistente e copertura.
fn blendLabelPx(buf: []u8, idx: usize, r: u8, g: u8, b: u8, a: u8) void {
    if (a == 0) return;
    const av: u32 = a;
    const inv: u32 = 255 - av;
    buf[idx + 0] = @intCast((@as(u32, buf[idx + 0]) * inv + @as(u32, r) * av) / 255);
    buf[idx + 1] = @intCast((@as(u32, buf[idx + 1]) * inv + @as(u32, g) * av) / 255);
    buf[idx + 2] = @intCast((@as(u32, buf[idx + 2]) * inv + @as(u32, b) * av) / 255);
    buf[idx + 3] = @max(buf[idx + 3], a);
}

/// Disegna il nome file in alto a destra: pill scura semi-trasparente + testo
/// monospazio (Hack) bianco. Right-aligned con margine; se il nome è più largo
/// della finestra si ancora a sinistra. Chiamato dal worker su ogni frame reso.
fn drawFilenameLabel(buf: []u8, W: u32, H: u32, raster: *glyph.Raster, name: []const u8) void {
    if (name.len == 0 or W == 0 or H == 0) return;
    var view = std.unicode.Utf8View.init(name) catch return;

    const cell = raster.advance;
    var n: i32 = 0;
    {
        var it = view.iterator();
        while (it.nextCodepoint()) |_| n += 1;
    }
    if (n == 0 or cell <= 0) return;

    const asc = raster.ascent;
    const line_h = asc - raster.descent;
    const pad_x: i32 = 8;
    const pad_y: i32 = 3;
    const margin: i32 = 12;
    const box_w = n * cell + pad_x * 2;
    const box_h = line_h + pad_y * 2;
    const wi: i32 = @intCast(W);
    var box_x = wi - margin - box_w;
    if (box_x < margin) box_x = margin;
    const box_y: i32 = margin;

    // Sfondo pill scuro via il Canvas straight di zicro (buffer 4-allineato).
    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);
    canvas.fillRoundedRect(@floatFromInt(box_x), @floatFromInt(box_y), @floatFromInt(box_w), @floatFromInt(box_h), 6.0, paint.Color.rgba(16, 18, 26, 0.62));

    // Testo monospazio bianco.
    const hi: i32 = @intCast(H);
    const baseline = box_y + pad_y + asc;
    var pen_x = box_x + pad_x;
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
                    blendLabelPx(buf, @intCast((py * wi + px) * 4), 235, 238, 245, cov);
                }
            }
        }
        pen_x += cell;
    }
}

fn renderWorker(
    win: *zrame.Window,
    state: *GuiAppState,
    composited_rgba: *[]u8,
) void {
    var last_w: u32 = 0;
    var last_h: u32 = 0;
    var last_text_w: u32 = 0;
    var last_text_zoom: f32 = 0;
    var last_seq: u32 = 0;
    // Ultima camera renderizzata: le mesh si ri-renderizzano SOLO quando cambia
    // (NaN iniziale ⇒ primo frame sempre reso). Senza questo il worker presenta
    // a 60 Hz all'infinito anche a mesh ferma, contendendo il socket Wayland col
    // thread di dispatch input → tasti (ESC) poco reattivi.
    var last_yaw: f32 = std.math.nan(f32);
    var last_pitch: f32 = std.math.nan(f32);
    var last_zoom: f32 = std.math.nan(f32);

    var pacer_60 = zicro.time.Pacer.hz(state.io, 60.0);
    var pacer_20 = zicro.time.Pacer.hz(state.io, 20.0);
    // Pacer dedicato al video in riproduzione: campiona il clock più fitto (120 Hz)
    // per rilevare i confini dei frame con meno jitter → meno scatti.
    var pacer_vid = zicro.time.Pacer.hz(state.io, 120.0);
    // Fotogramma dello spinner di caricamento (animazione a 60 Hz).
    var spin_frame: u32 = 0;
    // Tracking del ramo video per il gate "presenta solo se cambia qualcosa":
    // dimensioni e alpha dei controlli all'ultimo present.
    var vid_pw: u32 = 0;
    var vid_ph: u32 = 0;
    var vid_prev_ctrl: f32 = -1;
    // Dopo un cambio contenuto (navigazione) ripresenta per qualche frame: il
    // frame staged viene committato dal thread finestra solo su un suo "wake", e
    // se il primo redraw è differito (entrambi gli slot buffer occupati) resterebbe
    // in sospeso finché un input non risveglia il loop → la mesh/immagine "appare
    // solo dopo un click". Più present ravvicinati garantiscono il commit.
    var present_pulse: u32 = 0;
    // Soglia anti-flash dello spinner: mostralo solo se il caricamento supera
    // ~120 ms (i file veloci/piccoli si aprono senza far lampeggiare il loader).
    // Sotto soglia il worker continua a mostrare il contenuto PRECEDENTE.
    var load_elapsed: f64 = 0;
    var was_loading = false;

    // Rasterizzatore monospazio (Hack) per la label del nome file in alto a destra.
    // Creato una volta e riusato; null se l'init fallisce (label semplicemente omessa).
    var name_raster: ?glyph.Raster = glyph.Raster.init(state.gpa, 13.0) catch null;
    defer if (name_raster) |*r| r.deinit();

    // Autorepeat del Backspace nell'overlay YouTube (zrame non sintetizza il
    // key-repeat di Wayland): dopo il ritardo iniziale, una cancellazione ogni
    // 50 ms finché il tasto resta giù (bs_held, azzerato al rilascio).
    var bs_delay: f32 = 0;
    var bs_rep: f32 = 0;

    // La primitiva scrollbar `state.shared.sc` è condivisa coi callback input: qui la si usa
    // solo entro il lock del mutex (già preso attorno alla sezione compose).
    // Secondi trascorsi dall'ultimo frame presentato (dal Pacer a fine loop); guida
    // fade/hover/kinetica delle scrollbar. Primo giro: stima a 1/60.
    var frame_dt: f32 = 1.0 / 60.0;
    // Timer del poll di follow (-f): il file viene sondato ~2 volte al secondo.
    var follow_accum: f32 = 0;

    while (!win.closed) {
        // Dimensione FISICA del content rect (non `panel_w/h`, che sono logici):
        // su output scalati (HiDPI/frazionario) un frame logico verrebbe centrato
        // da zrame con un bordo vuoto tutt'attorno — presentando a contentPx il
        // contenuto riempie il vetro da bordo a bordo, 1:1 col puntatore.
        const cpx = win.contentPx();
        const cur_w = cpx.w;
        const cur_h = cpx.h;
        if (cur_w == 0 or cur_h == 0) {
            // Clamp: alternando pacer_60/pacer_20 quello inattivo ha `last` vecchio e
            // restituisce un dt enorme al primo tick → il fade delle barre scatterebbe.
            frame_dt = @min(0.1, @as(f32, @floatCast(pacer_20.tick())));
            continue;
        }

        state.shared.mutex.lockUncancelable(state.io);

        // Autorepeat Backspace dell'overlay (vale per ogni ramo: testo, video…).
        if (state.shared.yt.active and state.shared.yt.bs_held) {
            bs_delay += frame_dt;
            if (bs_delay >= 0.35) {
                bs_rep += frame_dt;
                while (bs_rep >= 0.05) : (bs_rep -= 0.05) yt_search.backspaceOnce(state);
            }
        } else {
            bs_delay = 0;
            bs_rep = 0;
        }

        // Traccia da quanto dura il caricamento per la soglia anti-flash.
        const now_loading = state.shared.loading;
        if (now_loading and !was_loading) load_elapsed = 0;
        load_elapsed = if (now_loading) load_elapsed + frame_dt else 0;
        was_loading = now_loading;

        // Caricamento in corso da oltre la soglia: anima lo spinner a 60 Hz finché
        // `applyDecoded` non azzera il flag. Sotto soglia si prosegue mostrando il
        // contenuto precedente (niente lampeggio del loader sui file veloci).
        if (now_loading and load_elapsed >= 0.12) {
            // Fuori dal lock: lo spinner tocca solo il framebuffer del worker (che
            // ne è l'unico proprietario) e `presentRgba` COPIA subito il frame nel
            // mailbox di zrame (`chrome.stageFrame`, thread-safe) — nessuno stato
            // condiviso in gioco, i callback input non restano bloccati.
            state.shared.mutex.unlock(state.io);
            if (composited_rgba.len < cur_w * cur_h * 4) {
                state.gpa.free(composited_rgba.*);
                // 4-byte aligned: la fase di compose lo rilegge come []u32 per il
                // Canvas straight di zicro (scrollbar).
                composited_rgba.* = state.gpa.alignedAlloc(u8, .@"4", cur_w * cur_h * 4) catch |e| {
                    // Non uccidere il worker (finestra viva ma congelata per
                    // sempre): azzera lo slice (il vecchio è già stato liberato),
                    // logga, salta il frame e riprova al prossimo giro.
                    composited_rgba.* = &.{};
                    std.debug.print("[gui] alloc framebuffer (loader) fallita: {s}\n", .{@errorName(e)});
                    frame_dt = @min(0.1, @as(f32, @floatCast(pacer_20.tick())));
                    continue;
                };
            }
            drawLoader(composited_rgba.*, cur_w, cur_h, spin_frame);
            win.presentRgba(cur_w, cur_h, composited_rgba.*);
            spin_frame +%= 1;
            _ = pacer_60.tick();
            continue;
        }

        // Video: percorso a sé (come lo spinner). Guida la riproduzione in tempo
        // reale (accumulo di `frame_dt`), compone il frame corrente e vi disegna
        // sopra i controlli overlay stile YouTube, poi presenta e ricomincia.
        // `has_video` only: the player is libav-backed, gated out when video is off.
        if (has_video and state.video.isActive()) {
            const vs = &state.video;
            if (composited_rgba.len < cur_w * cur_h * 4) {
                state.gpa.free(composited_rgba.*);
                composited_rgba.* = state.gpa.alignedAlloc(u8, .@"4", cur_w * cur_h * 4) catch |e| {
                    // Come per il loader: niente `break` (worker morto = finestra
                    // congelata), si salta il frame e si ritenta al giro dopo.
                    composited_rgba.* = &.{};
                    std.debug.print("[gui] alloc framebuffer (video) fallita: {s}\n", .{@errorName(e)});
                    state.shared.mutex.unlock(state.io);
                    frame_dt = @min(0.1, @as(f32, @floatCast(pacer_20.tick())));
                    continue;
                };
            }
            // Audio-only (mp3, wav…): nessun frame video da decodificare, il
            // "frame" è l'oscilloscopio disegnato più sotto direttamente nel buffer
            // finestra. `static_w/h` seguono la finestra così il fit-rect è pieno e
            // l'hit-test dei controlli (che usa le stesse dimensioni) resta corretto.
            const audio_only = vs.audio_only;
            const new_frame = if (audio_only) blk: {
                const nf = videomod.advanceAudio(vs, frame_dt);
                state.shared.static_w = cur_w;
                state.shared.static_h = cur_h;
                break :blk nf;
            } else videomod.advanceVideo(.{
                .gpa = state.gpa,
                .rgba = &state.shared.static_rgba,
                .w = &state.shared.static_w,
                .h = &state.shared.static_h,
            }, vs, frame_dt);
            // Auto-hide: controlli visibili in pausa, durante lo scrubbing o entro
            // 2.5 s dall'ultimo movimento del mouse; poi sfumano (fade ~8/s).
            vs.idle_s += frame_dt;
            const want: f32 = if (!vs.playing or vs.scrubbing or vs.idle_s < 2.5) 1.0 else 0.0;
            vs.controls += (want - vs.controls) * @min(1.0, frame_dt * 8.0);
            if (want == 0.0 and vs.controls < 0.02) vs.controls = 0;
            // Presenta solo se è cambiato qualcosa: nuovo frame, resize, oppure
            // l'alpha dei controlli si sta muovendo. In pausa a controlli fermi
            // non ricomponiamo (niente 60 Hz sprecati sullo stesso fotogramma).
            // L'overlay YouTube conta come cambiamento: digitazione/selezione
            // arrivano via `file_changed` (consumato qui: il ramo normale non
            // gira finché il video è attivo), lo spinner anima da sé.
            const size_ch = (cur_w != vid_pw or cur_h != vid_ph);
            const ctrl_ch = @abs(vs.controls - vid_prev_ctrl) > 0.002;
            const yt_active = state.shared.yt.active;
            const yt_anim = yt_active and (state.shared.yt.searching or state.shared.yt.opening);
            const yt_ch = state.shared.file_changed;
            state.shared.file_changed = false;
            const do_present = new_frame or size_ch or ctrl_ch or vs.scrubbing or yt_ch or yt_anim;
            var pres_w: u32 = 0;
            var pres_h: u32 = 0;
            if (do_present) {
                // Buffer STRETTO in aspect-fit: zrame lo centra nel vetro e ne arrotonda
                // gli angoli col solito content_radius — stesso frame di ogni altro tipo
                // di file (nessun percorso speciale per il video).
                const fr = videomod.videoFitRect(cur_w, cur_h, state.shared.static_w, state.shared.static_h);
                if (audio_only) {
                    // Oscilloscopio disegnato a piena finestra (fr = cur_w×cur_h):
                    // niente static_rgba/composeFrame, si dipinge diretto nel buffer.
                    videomod.drawOscilloscope(composited_rgba.*, fr.w, fr.h, vs);
                } else {
                    // Buffer STRETTO in aspect-fit: zrame lo centra nel vetro e ne arrotonda
                    // gli angoli col solito content_radius — stesso frame di ogni altro tipo
                    // di file (nessun percorso speciale per il video).
                    const px = @as(usize, fr.w) * fr.h * 4;
                    @memset(composited_rgba.*[0..px], 0);
                    compose.composeFrame(composited_rgba.*, fr.w, fr.h, state.shared.static_rgba, state.shared.static_w, state.shared.static_h, false, 1.0, 0.0, 0.0);
                }
                const raster: ?*glyph.Raster = if (name_raster) |*r| r else null;
                videomod.drawVideoControls(composited_rgba.*, fr.w, fr.h, vs, raster);
                if (name_raster) |*r| drawFilenameLabel(composited_rgba.*, fr.w, fr.h, r, std.fs.path.basename(state.shared.current_file_path));
                if (state.shared.fx.active) {
                    if (name_raster) |*r| file_explorer.drawOverlay(composited_rgba.*, fr.w, fr.h, state, r);
                }
                if (yt_active) {
                    if (name_raster) |*r| yt_search.drawOverlay(composited_rgba.*, fr.w, fr.h, state, r, @as(f32, @floatFromInt(spin_frame)) / 60.0);
                    spin_frame +%= 1;
                }
                vid_pw = cur_w;
                vid_ph = cur_h;
                vid_prev_ctrl = vs.controls;
                pres_w = fr.w;
                pres_h = fr.h;
            }
            // Stato del pacer campionato ANCORA sotto lock (il worker lo rilegge
            // dopo l'unlock); il catch-up post-seek conta come "busy" così il
            // recupero prosegue a 120 Hz anche in pausa.
            const busy = vs.playing or vs.scrubbing or ctrl_ch or vs.catchup_until >= 0 or yt_anim;
            state.shared.mutex.unlock(state.io);
            // Present FUORI dal lock: `presentRgba` copia subito il buffer (di cui
            // il worker è unico proprietario) nel mailbox di zrame → i callback
            // input non aspettano la copia del frame.
            if (do_present) win.presentRgba(pres_w, pres_h, composited_rgba.*);
            // Vsync: dopo un present in riproduzione, attendi il frame callback
            // del compositor (zrame.waitFrame) così la fase del loop si aggancia
            // al repaint reale — il frame appena committato viene mostrato al
            // refresh e il successivo parte da lì. Il pacer subito dopo NON
            // dorme oltre (fa resync senza burst) e fornisce solo il dt. Su
            // Win32/finestra occlusa waitFrame ritorna subito o a timeout e
            // resta il solo pacing software di prima.
            // Anche l'audio si aggancia al vsync via waitFrame: è LUI a dare la
            // cadenza fluida (~refresh dello schermo), il pacer sotto fornisce solo
            // il dt. Saltarlo (com'era) lasciava l'oscilloscopio al solo pacer
            // software → present non sincronizzati col compositor e scatti percepiti.
            if (do_present and busy) _ = win.waitFrame(20);
            // In riproduzione: clock a 120 Hz così, dopo il waitFrame (vsync), il
            // pacer NON dorme oltre e fornisce solo il dt. A riposo (pausa, controlli
            // fermi) 20 Hz. Video e audio condividono lo stesso percorso.
            frame_dt = @min(0.1, @as(f32, @floatCast(if (busy) pacer_vid.tick() else pacer_20.tick())));
            continue;
        }

        var did_compose = false;
        // Job mesh campionato sotto lock e renderizzato DOPO l'unlock (vedi ramo
        // mesh sotto): push constants pronti + nome file copiato (il path può
        // essere liberato da una navigazione concorrente dopo l'unlock).
        var mesh_push: ?gpu.PushConstants = null;
        var mesh_voxel_push: ?gpu.VoxelPush = null;
        var mesh_vt_zoom: f32 = 1.0;
        var mesh_name_buf: [512]u8 = undefined;
        var mesh_name_len: usize = 0;
        const size_changed = (cur_w != last_w or cur_h != last_h);
        // La mesh va ridisegnata solo se la camera è cambiata (drag/zoom).
        const mesh_moved = state.shared.is_mesh and
            (state.shared.yaw != last_yaw or state.shared.pitch != last_pitch or state.shared.zoom != last_zoom);
        var need_render = size_changed or state.shared.file_changed or mesh_moved;
        // Un cambio contenuto arma qualche present di rinforzo (vedi present_pulse).
        if (state.shared.file_changed) present_pulse = 4;
        if (present_pulse > 0) need_render = true;
        // Spinner dell'overlay YouTube: anima finché ricerca/apertura sono in corso.
        if (state.shared.yt.active and (state.shared.yt.searching or state.shared.yt.opening)) need_render = true;
        var text_animating = false;

        // Modalità follow (-f): sonda la crescita del file (~2 volte/s) e accoda i
        // byte nuovi al testo; il bump di load_seq fa ripartire il layout ritenuto
        // qui sotto. Se si era in fondo, dopo il re-layout lo scroll si riaggancia.
        var follow_pin = false;
        if (state.follow and state.shared.is_text and !state.shared.loading and state.shared.decoded == .text) {
            follow_accum += frame_dt;
            if (follow_accum >= 0.5) {
                follow_accum = 0;
                follow_pin = followPoll(state, cur_h);
            }
        }

        if (state.shared.is_text) {
            // (Ri)compone il testo quando cambiano larghezza finestra, zoom o
            // file: un solo tentativo per cambio di parametri (evita di ripetere
            // il layout a 20 Hz se qualcosa fallisce in modo persistente).
            // TODO(lock-scope): il raster (centinaia di ms sui documenti grandi)
            // gira ancora sotto `state.shared.mutex` perché legge `state.shared.decoded` per
            // TUTTA la durata, e `applyDecoded` (thread loader) può liberarlo in
            // qualunque momento: portarlo fuori richiede una copia profonda del
            // documento o un protocollo di ownership dedicato, non basta uno
            // snapshot di puntatori. Per ora fuori dal lock è uscito il present.
            // Il raster ora avviene in pixel FISICI (cur_w = contentPx): il corpo va
            // moltiplicato per la scala della superficie o il testo rimpicciolirebbe
            // sugli output HiDPI (stessa dimensione visiva di prima, ma nitida).
            const tz = std.math.clamp(state.shared.zoom, text_zoom_min, text_zoom_max) * win.scaleFactor();
            if (last_text_w != cur_w or last_text_zoom != tz or last_seq != state.shared.load_seq) {
                rasterizeText(state, cur_w, tz);
                last_text_w = cur_w;
                last_text_zoom = tz;
                last_seq = state.shared.load_seq;
                need_render = true;
            }
            // La scrollbar flottante egui possiede l'offset di scroll: la geometria
            // viene da viewport (finestra) e contenuto (testo rasterizzato); `tick`
            // applica rotella/tasti smussati + fade + kinetica di `dt` e clampa. Poi
            // rispecchiamo l'offset in scroll_y/scroll_x per compose/selezione/header.
            // Wheel/click/motion sono instradati alla primitiva dai callback (sotto lock).
            state.shared.sc.setViewport(.{ .x = 0, .y = 0, .w = @floatFromInt(cur_w), .h = @floatFromInt(cur_h) });
            state.shared.sc.setContent(@floatFromInt(state.shared.static_w), @floatFromInt(state.shared.static_h));
            if (follow_pin) {
                // tail -f: contenuto cresciuto mentre si era in fondo → resta in fondo.
                const max_off = @max(0.0, @as(f32, @floatFromInt(state.shared.static_h)) - @as(f32, @floatFromInt(cur_h)));
                state.shared.sc.offset[1] = max_off;
                state.shared.sc.vel[1] = 0;
                need_render = true;
            }
            if (state.shared.sc.tick(frame_dt)) {
                need_render = true;
                text_animating = true;
            }
            state.shared.scroll_y = state.shared.sc.scrollY();
            state.shared.scroll_x = state.shared.sc.scrollX();
        }

        if (need_render) {
            state.shared.file_changed = false;
            last_w = cur_w;
            last_h = cur_h;

            if (composited_rgba.len < cur_w * cur_h * 4) {
                state.gpa.free(composited_rgba.*);
                // 4-byte aligned: rilettura come []u32 per il Canvas straight (scrollbar).
                composited_rgba.* = state.gpa.alignedAlloc(u8, .@"4", cur_w * cur_h * 4) catch |e| {
                    // Niente `break`: si salta il frame e si ritenta. `file_changed`
                    // viene riarmato (è appena stato azzerato qui sopra) così il
                    // prossimo giro rientra in questo ramo e riprova il render.
                    composited_rgba.* = &.{};
                    state.shared.file_changed = true;
                    std.debug.print("[gui] alloc framebuffer fallita: {s}\n", .{@errorName(e)});
                    state.shared.mutex.unlock(state.io);
                    frame_dt = @min(0.1, @as(f32, @floatCast(pacer_20.tick())));
                    continue;
                };
            }

            if (native and state.shared.is_mesh) {
                // Il render Vulkan (vkWaitForFences, ms per frame) NON gira più
                // sotto `shared.mutex`: durante un drag affamava i callback input
                // (ESC/tasti lenti). Qui, sotto lock, si campionano solo i push
                // constants (pura CPU) e il nome file; il render avviene dopo
                // l'unlock, serializzato con setMesh/setVoxels da `renderer_mutex`.
                // `hasVoxels` è coerente: `setVoxels` avviene sotto `shared.mutex`
                // (toggleVoxel), che qui stiamo tenendo.
                if (state.shared.voxel_mode and state.renderer.hasVoxels()) {
                    // Modalità voxel (tasto V): ray-march della griglia invece
                    // della mesh triangolata.
                    mesh_voxel_push = gpu.buildVoxelPush(state.shared.mesh_center, state.shared.mesh_max_size / state.shared.zoom, state.shared.yaw, state.shared.pitch, cur_w, cur_h, state.shared.voxel_bbox_min, state.shared.voxel_bbox_size, state.shared.voxel_dim);
                } else {
                    mesh_push = gpu.buildPushConstants(state.shared.mesh_center, state.shared.mesh_max_size / state.shared.zoom, state.shared.yaw, state.shared.pitch, cur_w, cur_h, state.shared.mesh_material);
                    mesh_vt_zoom = state.shared.zoom; // pilota il mip dinamico delle texture virtuali
                }
                const bn = std.fs.path.basename(state.shared.current_file_path);
                mesh_name_len = @min(bn.len, mesh_name_buf.len);
                @memcpy(mesh_name_buf[0..mesh_name_len], bn[0..mesh_name_len]);
                last_yaw = state.shared.yaw;
                last_pitch = state.shared.pitch;
                last_zoom = state.shared.zoom;
            } else if (state.shared.is_text) {
                // Tabelle: àncora la banda header (top padding + riga intestazione)
                // in cima durante lo scroll verticale. Clampata all'altezza finestra.
                const header_band: u32 = if (state.shared.is_table) blk: {
                    const m = state.shared.text_metrics;
                    const hb = m.pad_y + m.line_h;
                    break :blk if (hb > 0) @min(@as(u32, @intCast(hb)), cur_h) else 0;
                } else 0;
                if (state.shared.text_doc) |*doc| {
                    // Documento a layout ritenuto: dipingi SOLO le righe visibili
                    // direttamente nel frame (stessa geometria di selezione/hit-test).
                    const geom = compose.textBlitGeom(cur_w, cur_h, state.shared.static_w, state.shared.static_h, state.shared.scroll_y, state.shared.scroll_x);
                    text_render.paintDocViewport(doc, composited_rgba.*, cur_w, cur_h, geom.off_y, geom.x_src, geom.x_dst) catch |e| {
                        std.debug.print("[gui] paintDocViewport fallito: {s}\n", .{@errorName(e)});
                    };
                } else {
                    compose.composeTextFrame(composited_rgba.*, cur_w, cur_h, state.shared.static_rgba, state.shared.static_w, state.shared.static_h, state.shared.scroll_y, state.shared.scroll_x, header_band);
                }
                // Listato archivio: evidenzia la riga selezionata (overlay, nessuna
                // ri-rasterizzazione della tabella bitmap).
                if (state.shared.is_table and state.shared.table_sel_row >= 0) {
                    compose.drawTableRowHighlight(composited_rgba.*, cur_w, cur_h, state.shared.static_w, state.shared.static_h, state.shared.scroll_y, state.shared.scroll_x, state.shared.text_metrics, state.shared.table_sel_row, header_band);
                }
                if (state.shared.sel_active) {
                    compose.drawTextSelection(composited_rgba.*, cur_w, cur_h, state.shared.static_w, state.shared.static_h, state.shared.scroll_y, state.shared.scroll_x, state.shared.text_metrics, state.shared.text_lines.items, state.shared.sel_a, state.shared.sel_b);
                }
                // Scrollbar flottanti egui, disegnate dal Canvas straight di zicro
                // direttamente sul frame RGBA8 (rilettura []u8 → []u32 aliasata).
                const buf = composited_rgba.*;
                const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
                var sc_canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, cur_w) * cur_h], cur_w, cur_h);
                state.shared.sc.draw(&sc_canvas);
                // Barra delle linguette in fondo (workbook multi-foglio), sopra tutto.
                compose.blitTabBar(composited_rgba.*, cur_w, cur_h, &state.shared.tab_bar);
            } else {
                // Sorgente assente (es. win_kind video ma setupVideo fallito, o
                // alloc immagine fallita): frame vuoto — composeFrame con 0×0
                // dividerebbe per zero (NaN → panic su @intFromFloat).
                if (state.shared.static_w == 0 or state.shared.static_h == 0) {
                    @memset(composited_rgba.*[0 .. @as(usize, cur_w) * cur_h * 4], 0);
                } else {
                    // Mantieni l'immagine sempre centrata / dentro i bordi (no re-center manuale).
                    input.clampImagePan(&state.shared.pan_x, &state.shared.pan_y, state.shared.zoom, cur_w, cur_h, state.shared.static_w, state.shared.static_h);
                    compose.composeFrame(composited_rgba.*, cur_w, cur_h, state.shared.static_rgba, state.shared.static_w, state.shared.static_h, false, state.shared.zoom, state.shared.pan_x, state.shared.pan_y);
                }
            }

            // Nome file in alto a destra (monospazio), sopra ogni contenuto. Nel
            // ramo mesh il frame viene composto DOPO l'unlock: label e flag lì.
            if (mesh_push == null and mesh_voxel_push == null) {
                if (name_raster) |*r| drawFilenameLabel(composited_rgba.*, cur_w, cur_h, r, std.fs.path.basename(state.shared.current_file_path));
                // Esploratore file sotto l'eventuale overlay YouTube (siamo sotto lock).
                if (state.shared.fx.active) {
                    if (name_raster) |*r| file_explorer.drawOverlay(composited_rgba.*, cur_w, cur_h, state, r);
                }
                // Overlay di ricerca YouTube, sopra tutto (siamo ancora sotto lock).
                if (state.shared.yt.active) {
                    if (name_raster) |*r| yt_search.drawOverlay(composited_rgba.*, cur_w, cur_h, state, r, @as(f32, @floatFromInt(spin_frame)) / 60.0);
                    spin_frame +%= 1;
                }
                did_compose = true;
            }
        }

        state.shared.mutex.unlock(state.io);

        // Render mesh FUORI da `shared.mutex` (input reattivo durante il drag),
        // sotto `renderer_mutex` che lo serializza con setMesh/setMeshMaterials
        // (applyDecoded, thread loader) e setVoxels/resetFrameSync (toggleVoxel).
        if (native and (mesh_push != null or mesh_voxel_push != null)) {
            state.renderer_mutex.lockUncancelable(state.io);
            const mesh_rgba: ?[]const u8 = blk: {
                if (mesh_voxel_push) |*vpc| {
                    break :blk state.renderer.renderVoxel(cur_w, cur_h, vpc) catch |e| {
                        // Errore Vulkan transitorio: non uccidere il worker (finestra
                        // congelata per sempre) — logga, riarma il redraw e riprova.
                        std.debug.print("[gui] renderVoxel fallito: {s}\n", .{@errorName(e)});
                        break :blk null;
                    };
                }
                state.renderer.vt_zoom = mesh_vt_zoom;
                break :blk state.renderer.render(cur_w, cur_h, &mesh_push.?) catch |e| {
                    // Come sopra: salta il frame invece di terminare il loop.
                    std.debug.print("[gui] render mesh fallito: {s}\n", .{@errorName(e)});
                    break :blk null;
                };
            };
            state.renderer_mutex.unlock(state.io);
            if (mesh_rgba) |mr| {
                // Il readback appartiene al renderer (2 slot pipelined) e il worker
                // è l'unico a chiamare render: lo slot resta valido fino al prossimo
                // render, quindi comporre fuori dal lock è sicuro.
                compose.composeFrame(composited_rgba.*, cur_w, cur_h, mr, cur_w, cur_h, false, 1.0, 0.0, 0.0);
                if (name_raster) |*r| drawFilenameLabel(composited_rgba.*, cur_w, cur_h, r, mesh_name_buf[0..mesh_name_len]);
                // Overlay (esploratore file + YouTube) anche sulle mesh: qui il frame
                // è composto fuori dal lock, quindi lo stato va riletto sotto mutex.
                state.shared.mutex.lockUncancelable(state.io);
                if (state.shared.fx.active) {
                    if (name_raster) |*r| file_explorer.drawOverlay(composited_rgba.*, cur_w, cur_h, state, r);
                }
                if (state.shared.yt.active) {
                    if (name_raster) |*r| yt_search.drawOverlay(composited_rgba.*, cur_w, cur_h, state, r, @as(f32, @floatFromInt(spin_frame)) / 60.0);
                    spin_frame +%= 1;
                }
                state.shared.mutex.unlock(state.io);
                did_compose = true;
            } else {
                // Riarma il redraw così il prossimo giro riprova il render.
                state.shared.mutex.lockUncancelable(state.io);
                state.shared.file_changed = true;
                state.shared.mutex.unlock(state.io);
            }
        }

        // Present FUORI dal lock: il frame è già composto nel buffer del worker
        // (unico proprietario) e `presentRgba` lo COPIA subito nel mailbox di
        // zrame (`chrome.stageFrame`, thread-safe) → i callback input non restano
        // bloccati dietro la copia.
        if (did_compose) {
            win.presentRgba(cur_w, cur_h, composited_rgba.*);
            if (present_pulse > 0) present_pulse -= 1;
        }

        // 60 Hz mentre la mesh si muove (drag/zoom) o durante l'animazione dello
        // scroll testo; 20 Hz a riposo (così il dispatch input resta reattivo). Il
        // dt restituito alimenta l'animazione delle scrollbar al giro successivo.
        // Clamp: il pacer inattivo (l'altro ramo) porta un `last` vecchio → dt enorme
        // al primo tick dopo un cambio di ritmo; limitalo così i fade non scattano.
        frame_dt = @min(0.1, @as(f32, @floatCast(if (mesh_moved or text_animating or present_pulse > 0)
            pacer_60.tick()
        else
            pacer_20.tick())));
    }
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Set a process env var so decoder plugins (loaded in-process) can read it via getenv.
/// `setenv` is POSIX; Windows' CRT spells it `_putenv_s` (which updates the CRT env that
/// `getenv` reads).
fn setEnvVar(name: [*:0]const u8, value: [*:0]const u8) void {
    if (builtin.os.tag == .windows) {
        const putenv_s = struct {
            extern "c" fn _putenv_s(n: [*:0]const u8, v: [*:0]const u8) c_int;
        };
        _ = putenv_s._putenv_s(name, value);
    } else {
        const setenv = struct {
            extern "c" fn setenv(n: [*:0]const u8, v: [*:0]const u8, overwrite: c_int) c_int;
        };
        _ = setenv.setenv(name, value, 1);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Ignora SIGPIPE (solo POSIX): la write libc verso un processo morto (es.
    // `wl-copy` della clipboard) altrimenti ucciderebbe l'intera GUI. Con
    // SIG_IGN la write fallisce con EPIPE e il chiamante la gestisce.
    if (comptime builtin.os.tag != .windows) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.PIPE, &act, null);
    }

    // Comunica ai plugin decoder che siamo in modalità GUI (quindi vogliamo la massima risoluzione possibile)
    setEnvVar("ZUER_GUI", "1");

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    defer decoder_mod.closePluginCache(gpa);

    // Se l'avvio precedente è finito in panic, propone l'issue GitHub
    // precompilata aprendo il browser (vedi crash_report.zig). Su thread:
    // legge il crash log e fa l'handoff al browser, mai bloccare l'avvio.
    if (std.Thread.spawn(.{}, crash_report.maybeReport, .{ io, gpa })) |t| t.detach() else |_| {}

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    // -f/--follow: modalità "tail -f" — sorveglia la crescita del file di testo
    // e tiene lo scroll agganciato al fondo (vedi followPoll).
    var follow = false;
    var arg_path_opt: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--follow")) {
            follow = true;
        } else if (arg_path_opt == null) {
            arg_path_opt = a;
        }
    }
    // Senza argomenti (es. scorciatoia di sistema o lancio dal menu: KDE non
    // espande %f) si sfoglia la home invece di uscire subito. Su Windows la
    // HOME non esiste: il collegamento del menu Start lancia senza argomenti.
    const arg_path = arg_path_opt orelse home: {
        if (getenv("HOME") orelse getenv("USERPROFILE")) |h| break :home std.mem.span(h);
        std.debug.print("Uso: zuer-gui [-f] <file|cartella>\n", .{});
        std.process.exit(1);
    };
    // Se l'argomento è una cartella, apri il primo file: la navigazione con le
    // frecce (e il prefetch) permette di sfogliare tutti i file della cartella.
    const file_path = (nav.resolveInitialFile(io, gpa, arg_path) catch |e| {
        std.debug.print("Impossibile accedere a '{s}': {s}\n", .{ arg_path, @errorName(e) });
        std.process.exit(1);
    }) orelse {
        std.debug.print("La cartella '{s}' non contiene file da mostrare.\n", .{arg_path});
        std.process.exit(1);
    };
    defer gpa.free(file_path);

    // Decodifica differita: la finestra deve apparire SUBITO. I file grandi (o i
    // PDF, che lanciano processi esterni) si decodificano su un thread di
    // background mentre il worker mostra uno spinner; i file piccoli si
    // decodificano qui sotto in modo sincrono, così la finestra può ancora
    // dimensionarsi sull'immagine (nessuna regressione di sizing).
    var clean_path: []const u8 = file_path;
    if (std.mem.indexOfScalar(u8, file_path, '#')) |h| clean_path = file_path[0..h];
    var loader_threshold_mb: u64 = 4;
    if (getenv("ZUER_LOADER_MB")) |v| {
        if (std.fmt.parseInt(u64, std.mem.span(v), 10)) |mb| {
            loader_threshold_mb = mb;
        } else |_| {}
    }
    var loading = gui_state_mod.isPdfPath(file_path);
    if (std.Io.Dir.cwd().statFile(io, clean_path, .{})) |st| {
        if (st.size >= loader_threshold_mb * 1024 * 1024) loading = true;
    } else |_| {}

    // Stato dell'app posseduto da un'unica struct (vedi gui_state.zig): i campi
    // partono dai default dichiarati lì; qui si impostano solo quelli calcolati
    // (percorso iniziale, spinner iniziale, motore di resa testo). I worker e i
    // callback ricevono `*GuiAppState`.
    var gui_state = GuiAppState{
        .gpa = gpa,
        .io = io,
        .follow = follow,
        .text_gpu = text_gpu: {
            if (!native) break :text_gpu false; // GPU text needs the Vulkan renderer
            if (getenv("ZUER_TEXT_ENGINE")) |v| break :text_gpu std.mem.eql(u8, std.mem.span(v), "gpu");
            break :text_gpu false;
        },
        .shared = .{
            .current_file_path = try gpa.dupe(u8, file_path),
            .loading = loading,
        },
    };
    // Contenuto decodificato: parte come testo vuoto (placeholder, deinit no-op)
    // e viene sostituito da `applyDecoded` — sul thread di decodifica o qui sotto.
    defer gui_state.shared.decoded.deinit(gpa);
    defer gpa.free(gui_state.shared.tab_bar.rgba);
    defer if (gui_state.shared.stage_opt) |*s| s.buffer.deinit(gpa);

    // Renderer Vulkan Offscreen (nessuna estensione swapchain WSI richiesta). Solo con
    // rendering nativo: su build CPU-only resta `undefined` e non viene mai usato (tutti
    // i suoi call site sono esclusi a comptime da `native`).
    if (native) gui_state.renderer = try gpu.Renderer.init(gpa, .{});
    defer if (native) gui_state.renderer.deinit();

    defer gpa.free(gui_state.shared.static_rgba);
    defer gui_state_mod.freeTextDoc(&gui_state);
    defer if (has_video) gui_state.video.deinit();
    defer yt_search.deinit(&gui_state);
    defer file_explorer.deinit(&gui_state);
    defer if (gui_state.shared.av_src_video) |s| gpa.free(s);
    defer if (gui_state.shared.av_src_audio) |s| gpa.free(s);

    defer {
        gpa.free(gui_state.shared.current_file_path);
        for (gui_state.file_list.items) |f| gpa.free(f);
        gui_state.file_list.deinit(gpa);
        for (gui_state.shared.text_lines.items) |l| gpa.free(l);
        gui_state.shared.text_lines.deinit(gpa);
        // Svuota la cache di prefetch e i percorsi desiderati.
        var pit = gui_state.pf.cache.iterator();
        while (pit.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        gui_state.pf.cache.deinit(gpa);
        for (gui_state.pf.want) |w| if (w) |x| gpa.free(x);
    }
    try nav.initFileList(&gui_state);

    // File piccolo: decodifica sincrona prima di creare la finestra, così può
    // dimensionarsi sull'immagine. I file grandi restano placeholder (spinner)
    // e vengono decodificati sul thread di background più sotto.
    if (!gui_state.shared.loading) {
        var d = decoder_mod.decode(file_path, io, gpa);
        if (d == .err) {
            std.debug.print("Errore: {s}\n", .{d.err});
            d.deinit(gpa);
            std.process.exit(1);
        }
        nav.applyDecoded(&gui_state, d, null, file_path, null) catch |e| {
            std.debug.print("Errore inizializzazione file: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
    }

    var composited_rgba: []u8 = &.{};
    defer gpa.free(composited_rgba);

    // Proporzioni intelligenti per tipo di contenuto: nel percorso sincrono il
    // tipo è già noto dal decoded; in quello async (spinner) si stima
    // dall'estensione, così la finestra nasce già con la forma giusta.
    // Le estensioni video usano SEMPRE il player nativo: l'union `Decoded` non ha
    // variante video (il decoder media ritorna solo un poster `.image`), quindi
    // `winKindFromDecoded` classificherebbe un video come immagine e `setupVideo`
    // non partirebbe mai (video fermo sul poster). L'estensione ha la priorità.
    const win_kind: WinKind = if (layout.winKindFromExt(file_path) == .video)
        .video
    else if (gui_state.shared.loading)
        layout.winKindFromExt(file_path)
    else
        layout.winKindFromDecoded(&gui_state.shared.decoded);

    // Video: apri il player nativo (libav) e usa il primo frame come poster
    // iniziale. Niente decode async/spinner — aprire il container è veloce — così
    // il worker parte già in riproduzione. `static_rgba` diventa il frame corrente
    // che il worker aggiorna nel tempo (vedi il ramo video di renderWorker).
    if (has_video and win_kind == .video) {
        gui_state.shared.loading = false;
        gui_state.shared.is_text = false;
        // Il percorso sincrono (file piccolo) può aver GIÀ avviato il player
        // dentro `applyDecoded` (rilevamento per estensione): non aprirlo due
        // volte. Qui siamo prima dello spawn dei thread → niente lock necessario.
        if (!gui_state.video.isActive()) _ = nav.startVideo(&gui_state, file_path);
    }
    // Per le tabelle (percorso sincrono) la finestra si dimensiona sulla larghezza
    // reale delle colonne, non su un valore fisso.
    var tbl_w: u32 = 0;
    var tbl_h: u32 = 0;
    if (!gui_state.shared.loading and (gui_state.shared.decoded == .csv or gui_state.shared.decoded == .workbook)) {
        const opts0 = text_render.RenderOpts{ .width = 1280, .pointsize = 14 };
        const csv0 = switch (gui_state.shared.decoded) {
            .csv => |c| c,
            .workbook => |w| w.activeCsv(),
            else => unreachable,
        };
        if (text_render.tableNaturalSize(gpa, csv0, opts0)) |ns| {
            tbl_w = @intCast(ns.w);
            tbl_h = @intCast(ns.h);
        } else |_| {}
    }
    const size_w = if (win_kind == .table) tbl_w else gui_state.shared.static_w;
    const size_h = if (win_kind == .table) tbl_h else gui_state.shared.static_h;
    // Contenuto piccolo → zoom iniziale un po' più grande, finestra aderente al
    // contenuto zoomato (stessa euristica della navigazione).
    const az0 = layout.autoZoomForContent(win_kind, size_w, size_h);
    // Immagini: la finestra è già dimensionata sul contenuto ingrandito e il
    // compose scala rispetto al FIT della finestra → passare anche `zoom = az`
    // raddoppierebbe l'ingrandimento (≈ az², immagine croppata all'apertura).
    // Il fit sulla finestra ingrandita realizza da solo l'auto-zoom.
    gui_state.shared.zoom = if (win_kind == .image) 1.0 else az0;
    const win_size = layout.initialWindowSize(win_kind, layout.scaleDim(size_w, az0), layout.scaleDim(size_h, az0));
    const win = try zrame.Window.init(gpa, .{
        .title = "zuer-gui",
        .app_id = "it.zuer.gui",
        .width = win_size.w,
        .height = win_size.h,
        .on_key = input.keyCallback,
        .on_text = input.textCallback,
        .on_scroll = input.scrollCallback,
        .on_mouse = input.mouseCallback,
        .user = &gui_state,
        .style = gui_state_mod.minimalFrame(zrame.Style.fluent()),
    });
    defer win.deinit();
    // La navigazione con le frecce usa la finestra per animare il resize sul
    // contenuto. Impostata prima di `win.run()` (dove partono le callback).
    gui_state.win = win;

    // Spawna il thread lavoratore per il rendering offscreen e compositing
    const thread = try std.Thread.spawn(.{}, renderWorker, .{ win, &gui_state, &composited_rgba });
    defer thread.join();

    // File grande/PDF iniziale: decodifica su un thread di background mentre il
    // worker mostra lo spinner. Va gioinato prima dei defer che liberano lo stato.
    var decode_thread: ?std.Thread = null;
    if (gui_state.shared.loading) {
        decode_thread = try std.Thread.spawn(.{}, nav.decodeInitial, .{ &gui_state, file_path });
    }
    defer if (decode_thread) |t| t.join();

    // Thread di prefetch dei file adiacenti (navigazione istantanea). Il suo
    // defer è registrato DOPO quello che libera la cache → viene eseguito PRIMA:
    // il thread è fermato e gioinato prima che la cache venga distrutta.
    const prefetch_thread = try std.Thread.spawn(.{}, nav.prefetchWorker, .{&gui_state});
    defer {
        gui_state.pf.mutex.lockUncancelable(io);
        gui_state.pf.stop = true;
        gui_state.pf.mutex.unlock(io);
        gui_state.pf.cond.signal(io);
        prefetch_thread.join();
    }

    // Loader thread della navigazione async (cache-miss): fermato e gioinato prima
    // che lo stato condiviso venga distrutto (defer registrato dopo → esegue prima).
    const load_thread = try std.Thread.spawn(.{}, nav.loadWorker, .{&gui_state});
    defer {
        gui_state.nav.mutex.lockUncancelable(io);
        gui_state.nav.stop = true;
        gui_state.nav.mutex.unlock(io);
        gui_state.nav.cond.signal(io);
        load_thread.join();
        if (gui_state.nav.req) |x| gpa.free(x);
    }
    // Percorso sincrono: il file iniziale è già pronto → precarica subito i
    // vicini. (Nel percorso async lo fa `decodeInitial` dopo aver installato
    // il contenuto, per non decodificare in parallelo al decode iniziale.)
    if (!gui_state.shared.loading) nav.schedulePrefetchAround(&gui_state);

    win.run() catch {};
    // Esc/chiusura: esci SUBITO. NON aspettare il join dei thread di decode: possono
    // essere dentro una decodifica non interrompibile in un plugin .so, e attenderli
    // renderebbe Esc lento. Un viewer non ha stato da salvare; il SO libera
    // memoria/GPU/fd e la disconnessione Wayland fa sparire la finestra all'istante.
    std.process.exit(0);
}
