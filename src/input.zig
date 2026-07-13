//! Gestione input di zuer-gui: i tre callback zrame (tastiera, rotella, mouse),
//! il rilevamento del doppio-click, l'hit-testing/selezione del testo e i
//! comandi di vista (zoom, pan, scroll, pagina PDF, voxel).
//! Estratto da gui.zig: stesse funzioni, stesso comportamento.

const std = @import("std");
const builtin = @import("builtin");
// CPU frame compositor: qui servono la geometria del blit testo (hit-test) e cpLen.
const compose = @import("compose.zig");
const clipboard = @import("clipboard.zig");
// Player video nativo: hit-test dei controlli overlay e seek da tastiera/mouse.
const videomod = @import("video.zig");
const nav = @import("nav.zig");
const gui_state_mod = @import("gui_state.zig");
const GuiAppState = gui_state_mod.GuiAppState;
const resetScroll = gui_state_mod.resetScroll;
const isPdfPath = gui_state_mod.isPdfPath;
const minimalFrame = gui_state_mod.minimalFrame;
const build_options = @import("build_options");
/// Vulkan renderer available: gates the voxel view (GPU-only feature).
const native = build_options.gpu;
const zrame = @import("zrame");

// evdev key codes standard per Linux
const KEY_ESC: u32 = 1;
const KEY_UP: u32 = 103;
const KEY_DOWN: u32 = 108;
const KEY_LEFT: u32 = 105;
const KEY_RIGHT: u32 = 106;
const KEY_PGUP: u32 = 104;
const KEY_PGDOWN: u32 = 109;
const KEY_MINUS: u32 = 12;
const KEY_EQUAL: u32 = 13;
const KEY_1: u32 = 2;
const KEY_2: u32 = 3;
const KEY_3: u32 = 4;
const KEY_4: u32 = 5;
const KEY_5: u32 = 6;
const KEY_C: u32 = 46;
const KEY_V: u32 = 47;
const KEY_F: u32 = 33;
const KEY_SPACE: u32 = 57;
const KEY_0: u32 = 11;
const KEY_Q: u32 = 16;
const KEY_ENTER: u32 = 28;

// Stato per il rilevamento del doppio-click sinistro (solo thread finestra).
var last_click_ms: i64 = -1000;
var last_click_x: f32 = 0;
var last_click_y: f32 = 0;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

/// Orologio monotono in millisecondi (per intervalli, es. doppio-click).
/// Linux: `clock_gettime(MONOTONIC)`; Windows: `GetTickCount64`.
fn nowMs() i64 {
    if (comptime builtin.os.tag == .windows) {
        return @intCast(GetTickCount64());
    } else {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
}
const KEY_LEFTCTRL: u32 = 29;
const KEY_RIGHTCTRL: u32 = 97;
const KEY_LEFTSHIFT: u32 = 42;
const KEY_RIGHTSHIFT: u32 = 54;

const scroll_step: f32 = 60.0;

/// Mappa una coordinata finestra in (riga, colonna) sulla griglia del testo,
/// clampata al documento. Da chiamare con `state.shared.mutex` acquisito.
fn textHit(state: *GuiAppState, W: u32, H: u32, mx: f32, my: f32) [2]i32 {
    const m = state.shared.text_metrics;
    const geom = compose.textBlitGeom(W, H, state.shared.static_w, state.shared.static_h, state.shared.scroll_y, state.shared.scroll_x);
    const sx = @as(i32, @intFromFloat(mx)) - @as(i32, @intCast(geom.x_dst)) + @as(i32, @intCast(geom.x_src));
    const sy = @as(i32, @intFromFloat(my)) + @as(i32, @intCast(geom.off_y));
    const nrows: i32 = @intCast(state.shared.text_lines.items.len);
    var row: i32 = if (m.line_h > 0) @divFloor(sy - m.pad_y, m.line_h) else 0;
    row = std.math.clamp(row, 0, @max(nrows - 1, 0));
    const llen: i32 = if (nrows > 0) compose.cpLen(state.shared.text_lines.items[@intCast(row)]) else 0;
    // Arrotonda alla colonna più vicina (mezza cella) per un aggancio naturale.
    var col: i32 = if (m.advance > 0) @divFloor(sx - m.pad_x + @divTrunc(m.advance, 2), m.advance) else 0;
    col = std.math.clamp(col, 0, llen);
    return .{ row, col };
}

/// Zoom moltiplicativo attorno al punto focale (`cx`,`cy`) nel viewport `W`×`H`:
/// tiene fisso il contenuto sotto quel punto (zoom verso il cursore, standard nei
/// viewer). Con focale al centro equivale a zoomare centrato. Il pan viene poi
/// clampato dal worker (`clampImagePan`), quindi non serve preoccuparsi dei limiti.
fn applyZoomAt(app_state: *GuiAppState, factor: f32, cx: f32, cy: f32, W: u32, H: u32) void {
    app_state.shared.mutex.lockUncancelable(app_state.io);
    defer app_state.shared.mutex.unlock(app_state.io);
    const old = app_state.shared.zoom;
    const nz = std.math.clamp(old * factor, 0.1, 20.0);
    const f = if (old > 0) nz / old else 1.0;
    app_state.shared.zoom = nz;
    const ox = cx - @as(f32, @floatFromInt(W)) / 2.0;
    const oy = cy - @as(f32, @floatFromInt(H)) / 2.0;
    app_state.shared.pan_x = ox * (1.0 - f) + app_state.shared.pan_x * f;
    app_state.shared.pan_y = oy * (1.0 - f) + app_state.shared.pan_y * f;
    app_state.shared.file_changed = true;
}

/// Doppio-click su immagine: alterna fit (zoom 1) ↔ 100% (1:1 pixel), zoomando
/// verso il cursore. `z100` è il fattore che porta il contenuto alla risoluzione
/// nativa (rispetto al fit che riempie il viewport).
fn toggleFitActual(app_state: *GuiAppState, cx: f32, cy: f32, W: u32, H: u32) void {
    // Snapshot sotto lock: static_w/h e zoom sono scritti dai thread loader
    // (`applyDecoded`) e dal worker — mai leggerli a nudo dal thread finestra.
    app_state.shared.mutex.lockUncancelable(app_state.io);
    const sw = app_state.shared.static_w;
    const sh = app_state.shared.static_h;
    const cur = app_state.shared.zoom;
    app_state.shared.mutex.unlock(app_state.io);
    if (sw == 0 or sh == 0 or W == 0 or H == 0) return;
    const fw: f32 = @floatFromInt(W);
    const fh: f32 = @floatFromInt(H);
    const sa = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(sh));
    const wa = fw / fh;
    const fit_w = if (sa > wa) fw else fh * sa;
    const z100 = @as(f32, @floatFromInt(sw)) / fit_w;
    if (@abs(cur - 1.0) < 0.01 and @abs(z100 - 1.0) > 0.02) {
        applyZoomAt(app_state, z100 / cur, cx, cy, W, H);
    } else {
        resetView(app_state);
    }
}

/// Reset della vista: fit sullo schermo (zoom 1) e immagine ricentrata (pan 0).
fn resetView(app_state: *GuiAppState) void {
    app_state.shared.mutex.lockUncancelable(app_state.io);
    defer app_state.shared.mutex.unlock(app_state.io);
    app_state.shared.zoom = 1.0;
    app_state.shared.pan_x = 0;
    app_state.shared.pan_y = 0;
    app_state.shared.file_changed = true;
}

/// Clampa il pan dell'immagine così non possa mai scivolare nel vuoto: quando
/// l'immagine (zoomata) è più piccola del viewport su un asse la RI-CENTRA (pan=0),
/// altrimenti impedisce ai bordi di rientrare dentro il viewport. È il comportamento
/// standard dei viewer: a fit l'immagine è sempre centrata, si pana solo da zoomati.
pub fn clampImagePan(pan_x: *f32, pan_y: *f32, zoom: f32, W: u32, H: u32, sw: u32, sh: u32) void {
    if (sw == 0 or sh == 0 or W == 0 or H == 0) return;
    const fw: f32 = @floatFromInt(W);
    const fh: f32 = @floatFromInt(H);
    const sa = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(sh));
    const wa = fw / fh;
    const fit_w = if (sa > wa) fw else fh * sa;
    const fit_h = if (sa > wa) fw / sa else fh;
    const max_x = @max(0.0, (fit_w * zoom - fw) / 2.0);
    const max_y = @max(0.0, (fit_h * zoom - fh) / 2.0);
    pan_x.* = std.math.clamp(pan_x.*, -max_x, max_x);
    pan_y.* = std.math.clamp(pan_y.*, -max_y, max_y);
}

/// Scroll verticale fluido (rotella/tasti): accumula `delta` px nel buffer di
/// smoothing low-pass della primitiva, che il worker applica in `tick` (stesso feel
/// egui della rotella). Il clamp ai limiti del contenuto avviene nel `tick`.
/// Una cella-nome è una voce apribile se non è una cartella (`/` finale) né una
/// delle righe speciali di riepilogo generate dai decoder archivio.
fn isOpenableEntryName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[name.len - 1] == '/') return false; // cartella
    if (std.mem.startsWith(u8, name, "TOTALE")) return false;
    if (std.mem.startsWith(u8, name, "…")) return false; // "… altre N voci" / "… elenco troncato"
    return true;
}

/// Tasti per la navigazione dentro un archivio. Nel listato (path base, tabella):
/// ↑/↓ spostano `table_sel_row` (saltando le righe di riepilogo) e Invio apre
/// `archivio#voce`. Dentro una voce (`archivio#voce`): Esc torna al listato.
/// Porta la riga selezionata `sel` dentro la viewport agendo sull'offset verticale
/// della primitiva scroll condivisa (stessa che il worker `tick`-a). Da chiamare con
/// `shared.mutex` già acquisito. No-op se la riga è già visibile: non "ruba" lo
/// scroll all'utente quando la selezione si muove entro lo schermo.
fn ensureRowVisible(app_state: *GuiAppState, win: *zrame.Window, sel: i32) void {
    const m = app_state.shared.text_metrics;
    if (m.line_h <= 0) return;
    const line_h: f32 = @floatFromInt(m.line_h);
    const pad_y: f32 = @floatFromInt(m.pad_y);
    const vp_h: f32 = @floatFromInt(win.contentPx().h);
    // Banda header pinnata (riga 0), identica a quella di gui.zig/compose.
    const header_h = pad_y + line_h;
    const row_top = pad_y + @as(f32, @floatFromInt(1 + sel)) * line_h; // riga dati
    const row_bot = row_top + line_h;

    var off = app_state.shared.sc.offset[1];
    if (row_top - off < header_h) {
        off = row_top - header_h; // riga sopra il bordo (sotto l'header) → scorri su
    } else if (row_bot - off > vp_h) {
        off = row_bot - vp_h; // riga sotto il bordo inferiore → scorri giù
    } else return; // già visibile

    const content_h: f32 = @floatFromInt(app_state.shared.static_h);
    const max_off = @max(0.0, content_h - vp_h);
    off = std.math.clamp(off, 0.0, max_off);
    app_state.shared.sc.offset[1] = off;
    app_state.shared.sc.vel[1] = 0; // taglia l'inerzia: salto netto alla riga
}

/// Ritorna true se il tasto è stato consumato.
fn handleArchiveKey(app_state: *GuiAppState, win: *zrame.Window, key: u32) bool {
    app_state.shared.mutex.lockUncancelable(app_state.io);
    const path = app_state.shared.current_file_path;

    // Esc dentro una voce → ricarica l'archivio base (strip del frammento).
    if (key == KEY_ESC and gui_state_mod.isInsideArchive(path)) {
        const hash = std.mem.indexOfScalar(u8, path, '#') orelse {
            app_state.shared.mutex.unlock(app_state.io);
            return false;
        };
        const base = app_state.gpa.dupe(u8, path[0..hash]) catch {
            app_state.shared.mutex.unlock(app_state.io);
            return false;
        };
        app_state.shared.mutex.unlock(app_state.io);
        defer app_state.gpa.free(base);
        nav.postLoad(app_state, base);
        return true;
    }

    // Da qui in poi serve il listato di un archivio.
    if (!gui_state_mod.isArchiveListing(path) or app_state.shared.decoded != .csv) {
        app_state.shared.mutex.unlock(app_state.io);
        return false;
    }
    const rows = app_state.shared.decoded.csv.rows;

    // Ultimo indice apribile: esclude le righe di riepilogo in coda.
    var last_openable: i32 = -1;
    var i: usize = rows.len;
    while (i > 0) {
        i -= 1;
        if (rows[i].len > 0 and isOpenableEntryName(rows[i][0])) {
            last_openable = @intCast(i);
            break;
        }
    }

    if (key == KEY_UP or key == KEY_DOWN) {
        // Nessuna voce apribile (es. archivio vuoto: solo la riga TOTALE): niente
        // selezione da spostare.
        if (last_openable < 0) {
            app_state.shared.mutex.unlock(app_state.io);
            return true;
        }
        var sel = app_state.shared.table_sel_row;
        if (sel < 0) sel = 0;
        sel += if (key == KEY_DOWN) @as(i32, 1) else -1;
        if (sel < 0) sel = 0;
        if (sel > last_openable) sel = last_openable;
        app_state.shared.table_sel_row = sel;
        ensureRowVisible(app_state, win, sel); // segui la selezione con lo scroll
        app_state.shared.file_changed = true; // la selezione è un overlay: ridisegna
        app_state.shared.mutex.unlock(app_state.io);
        return true;
    }

    if (key == KEY_ENTER) {
        const sel = app_state.shared.table_sel_row;
        if (sel < 0 or sel >= @as(i32, @intCast(rows.len)) or rows[@intCast(sel)].len == 0) {
            app_state.shared.mutex.unlock(app_state.io);
            return true;
        }
        const name = rows[@intCast(sel)][0];
        if (!isOpenableEntryName(name)) {
            app_state.shared.mutex.unlock(app_state.io);
            return true;
        }
        // `path` è il listato (nessun `#`): la voce è `path#nome`. allocPrint copia
        // i byte, quindi è sicuro rilasciare il lock subito dopo.
        const new_path = std.fmt.allocPrint(app_state.gpa, "{s}#{s}", .{ path, name }) catch {
            app_state.shared.mutex.unlock(app_state.io);
            return true;
        };
        app_state.shared.mutex.unlock(app_state.io);
        defer app_state.gpa.free(new_path);
        nav.postLoad(app_state, new_path);
        return true;
    }

    app_state.shared.mutex.unlock(app_state.io);
    return false;
}

fn scrollText(app_state: *GuiAppState, delta: f32) void {
    app_state.shared.mutex.lockUncancelable(app_state.io);
    defer app_state.shared.mutex.unlock(app_state.io);
    app_state.shared.sc.unprocessed[1] += delta;
    app_state.shared.file_changed = true;
}

/// Come `scrollText` ma sull'asse orizzontale (tabelle più larghe della finestra).
fn scrollTextX(app_state: *GuiAppState, delta: f32) void {
    app_state.shared.mutex.lockUncancelable(app_state.io);
    defer app_state.shared.mutex.unlock(app_state.io);
    app_state.shared.sc.unprocessed[0] += delta;
    app_state.shared.file_changed = true;
}

/// Scroll immediato (senza smoothing) a una posizione verticale assoluta: per il
/// trascinamento del documento (fallback), dove serve reattività 1:1. Il clamp
/// definitivo ai limiti avviene nel `tick` del worker.
fn scrollTo(app_state: *GuiAppState, y: f32) void {
    app_state.shared.mutex.lockUncancelable(app_state.io);
    defer app_state.shared.mutex.unlock(app_state.io);
    app_state.shared.sc.offset[1] = @max(y, 0);
    app_state.shared.sc.vel[1] = 0;
    app_state.shared.sc.unprocessed[1] = 0;
    app_state.shared.file_changed = true;
}

fn changePdfPage(app_state: *GuiAppState, direction: i32) void {
    app_state.shared.mutex.lockUncancelable(app_state.io);
    const path = app_state.gpa.dupe(u8, app_state.shared.current_file_path) catch {
        app_state.shared.mutex.unlock(app_state.io);
        return;
    };
    // Conteggio pagine STRUTTURATO dal decoder (0 = documento non paginato o
    // sconosciuto): niente più parsing della label di presentazione
    // "(pagina N di M)", fragile perché legata a formato/lingua.
    const total_pages: usize = if (app_state.shared.decoded == .image)
        app_state.shared.decoded.image.total_pages
    else
        0;
    app_state.shared.mutex.unlock(app_state.io);
    defer app_state.gpa.free(path);

    var clean_path = path;
    var current_page: usize = 1;
    if (std.mem.indexOfScalar(u8, path, '#')) |hash_idx| {
        clean_path = path[0..hash_idx];
        const suffix = path[hash_idx + 1 ..];
        var page_str = suffix;
        if (std.mem.startsWith(u8, suffix, "page=")) {
            page_str = suffix["page=".len..];
        }
        current_page = std.fmt.parseInt(usize, page_str, 10) catch 1;
    }

    var new_page = current_page;
    if (direction > 0) {
        // total_pages == 0 → nessuna paginazione nota: niente navigazione in
        // avanti (mai un fallback tipo 99999, che porterebbe su pagine
        // inesistenti con conseguenti errori di decode).
        if (total_pages > 0 and current_page < total_pages) {
            new_page += 1;
        }
    } else {
        if (current_page > 1) {
            new_page -= 1;
        }
    }

    if (new_page == current_page) return;

    const new_path = std.fmt.allocPrint(app_state.gpa, "{s}#{d}", .{ clean_path, new_page }) catch return;
    defer app_state.gpa.free(new_path);

    // Cambio pagina in ASINCRONO sul loader thread: il decode PDF lancia un
    // processo esterno (pdftoppm) che bloccherebbe il thread finestra per
    // secondi a ogni pagina. Il numero di pagina viaggia nel suffisso `#N`
    // del percorso, quindi passa pulito per `postLoad` (latest-wins in caso
    // di spam di PgUp/PgDown) e lo spinner resta animato.
    nav.postLoad(app_state, new_path);
}

/// Alterna la modalità voxel. Alla prima attivazione voxelizza la mesh corrente
/// (griglia 96³) e la carica nel renderer; le attivazioni successive riusano la
/// griglia già caricata. Tiene il mutex: il thread di render usa lo stesso renderer.
fn toggleVoxel(app_state: *GuiAppState) void {
    if (!native) return; // voxel view is a GPU-only feature
    app_state.shared.mutex.lockUncancelable(app_state.io);
    defer app_state.shared.mutex.unlock(app_state.io);

    if (!app_state.shared.voxel_mode and app_state.shared.voxel_dim == 0 and app_state.shared.decoded == .mesh) {
        var grid = app_state.voxelizeFromStage(96) orelse {
            std.debug.print("[voxel] voxelizzazione fallita\n", .{});
            return;
        };
        defer grid.deinit(app_state.gpa);
        {
            // Il renderer è serializzato dal suo lock dedicato (non più da `mutex`).
            app_state.renderer_mutex.lockUncancelable(app_state.io);
            defer app_state.renderer_mutex.unlock(app_state.io);
            app_state.renderer.setVoxels(grid.dim, grid.data) catch |e| {
                std.debug.print("[voxel] setVoxels: {s}\n", .{@errorName(e)});
                return;
            };
        }
        app_state.shared.voxel_bbox_min = grid.bbox_min;
        app_state.shared.voxel_bbox_size = grid.bbox_size;
        app_state.shared.voxel_dim = grid.dim;
    }
    // Il path mesh `render()` è pipelined (fence ping-pong), il voxel è slot 0
    // sincrono: risincronizza il double-buffer a ogni cambio di modalità.
    app_state.renderer_mutex.lockUncancelable(app_state.io);
    app_state.renderer.resetFrameSync();
    app_state.renderer_mutex.unlock(app_state.io);
    app_state.shared.voxel_mode = !app_state.shared.voxel_mode;
    app_state.shared.file_changed = true; // forza un re-render
}

pub fn keyCallback(win: *zrame.Window, key: u32, state: u32, user: ?*anyopaque) void {
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    const pressed = (state == 1);
    if (key == KEY_LEFTSHIFT or key == KEY_RIGHTSHIFT) {
        app_state.shift_down = pressed;
    }
    if (key == KEY_LEFTCTRL or key == KEY_RIGHTCTRL) {
        app_state.ctrl_down = pressed;
        return;
    }
    if (pressed) {
        // Snapshot sotto lock: `current_file_path` è liberato/riassegnato e i
        // flag di tipo (is_text/is_mesh) riscritti da `applyDecoded` (thread
        // loader) sotto `mutex` — mai leggerli a nudo.
        app_state.shared.mutex.lockUncancelable(app_state.io);
        const is_text = app_state.shared.is_text;
        const is_mesh = app_state.shared.is_mesh;
        const is_pdf = isPdfPath(app_state.shared.current_file_path);
        app_state.shared.mutex.unlock(app_state.io);
        // Video: Spazio = play/pausa, ←/→ = seek ∓5 s (stile YouTube). ESC/F
        // cadono al comportamento comune (chiudi / fullscreen).
        if (app_state.video.isActive()) {
            const vid = &app_state.video;
            if (key == KEY_SPACE) {
                app_state.shared.mutex.lockUncancelable(app_state.io);
                vid.playing = !vid.playing;
                vid.idle_s = 0;
                app_state.shared.mutex.unlock(app_state.io);
                return;
            } else if (key == KEY_RIGHT or key == KEY_LEFT) {
                app_state.shared.mutex.lockUncancelable(app_state.io);
                var t = vid.pos_s + (if (key == KEY_RIGHT) @as(f64, 5) else -5);
                if (t < 0) t = 0;
                if (vid.dur_s > 0 and t > vid.dur_s - 0.1) t = vid.dur_s - 0.1;
                vid.seek_to = t;
                vid.idle_s = 0;
                app_state.shared.mutex.unlock(app_state.io);
                return;
            }
        }
        // MIDI: Spazio = play/pausa; a fine brano (il synth si auto-pausa col
        // clock fermo sulla durata) Spazio riparte da capo. Il puntatore
        // `midi` è protetto dal mutex (applyDecoded può fermarlo dai worker);
        // le operazioni sul player sono atomics interne.
        if (key == KEY_SPACE) {
            app_state.shared.mutex.lockUncancelable(app_state.io);
            if (app_state.midi) |mp| {
                const dur = mp.durationSeconds();
                if (!mp.isPlaying() and dur > 0 and mp.clockSeconds() >= dur - 0.05) {
                    mp.seek(0);
                    mp.setPlaying(true);
                } else {
                    mp.setPlaying(!mp.isPlaying());
                }
                app_state.shared.mutex.unlock(app_state.io);
                return;
            }
            app_state.shared.mutex.unlock(app_state.io);
        }
        // Ctrl+C: copia la selezione negli appunti.
        if (key == KEY_C and app_state.ctrl_down and is_text) {
            app_state.shared.mutex.lockUncancelable(app_state.io);
            const sel = buildSelectedText(app_state, app_state.gpa);
            app_state.shared.mutex.unlock(app_state.io);
            if (sel) |txt| {
                clipboard.copy(txt);
                app_state.gpa.free(txt);
            }
            return;
        }
        // Navigazione archivio: nel listato ↑/↓ spostano la riga e Invio apre la
        // voce; dentro una voce Esc torna al listato. Ha priorità sul resto (il
        // ramo is_text sotto scorrerebbe la tabella invece di selezionare).
        if (handleArchiveKey(app_state, win, key)) return;
        if (key == KEY_ESC or key == KEY_Q) {
            win.close();
        } else if (key == KEY_0) {
            // Reset vista: torna al fit (1:1 sullo schermo) e ricentra.
            resetView(app_state);
        } else if (is_text and (key == KEY_UP or key == KEY_DOWN)) {
            // Nei documenti le frecce verticali scorrono; ← → restano
            // la navigazione tra i file della cartella (parità con viewer).
            scrollText(app_state, if (key == KEY_DOWN) scroll_step else -scroll_step);
        } else if (is_text and (key == KEY_PGUP or key == KEY_PGDOWN)) {
            scrollText(app_state, if (key == KEY_PGDOWN) scroll_step * 10 else -scroll_step * 10);
        } else if (is_pdf and (key == KEY_UP or key == KEY_DOWN or key == KEY_PGUP or key == KEY_PGDOWN)) {
            const dir: i32 = if (key == KEY_DOWN or key == KEY_PGDOWN) 1 else -1;
            changePdfPage(app_state, dir);
        } else if (key == KEY_RIGHT or key == KEY_DOWN) {
            nav.navigate(app_state, 1);
        } else if (key == KEY_LEFT or key == KEY_UP) {
            nav.navigate(app_state, -1);
        } else if (key == KEY_EQUAL) {
            const cpx = win.contentPx();
            applyZoomAt(app_state, 1.1, @as(f32, @floatFromInt(cpx.w)) / 2.0, @as(f32, @floatFromInt(cpx.h)) / 2.0, cpx.w, cpx.h);
        } else if (key == KEY_MINUS) {
            const cpx = win.contentPx();
            applyZoomAt(app_state, 1.0 / 1.1, @as(f32, @floatFromInt(cpx.w)) / 2.0, @as(f32, @floatFromInt(cpx.h)) / 2.0, cpx.w, cpx.h);
        } else if (key == KEY_F) {
            win.toggleFullscreen();
        } else if (key == KEY_V and is_mesh) {
            toggleVoxel(app_state);
        } else if (key == KEY_1) {
            win.setStyle(minimalFrame(zrame.Style.fluent())) catch {};
        } else if (key == KEY_2) {
            win.setStyle(minimalFrame(zrame.Style.macos())) catch {};
        } else if (key == KEY_3) {
            win.setStyle(minimalFrame(zrame.Style.aurora())) catch {};
        } else if (key == KEY_4) {
            win.setStyle(minimalFrame(zrame.Style.material())) catch {};
        } else if (key == KEY_5) {
            win.setStyle(minimalFrame(zrame.Style.psy())) catch {};
        }
    }
}

pub fn scrollCallback(win: *zrame.Window, axis: u32, value: i32, user: ?*anyopaque) void {
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    // Snapshot sotto lock (stesso pattern di `is_pdf` nel key handler):
    // `is_text` è riscritto da `applyDecoded` sui thread loader.
    app_state.shared.mutex.lockUncancelable(app_state.io);
    const is_text = app_state.shared.is_text;
    app_state.shared.mutex.unlock(app_state.io);
    if (axis == 1) {
        // Asse orizzontale (trackpad/tilt-wheel): scorre le tabelle larghe.
        if (is_text) {
            const val = @as(f32, @floatFromInt(value)) / 256.0;
            scrollTextX(app_state, val * 5.0);
        }
        return;
    }
    if (axis == 0) {
        const val = @as(f32, @floatFromInt(value)) / 256.0;
        if (is_text) {
            // Shift+rotella = scroll orizzontale (per chi non ha rotella orizzontale).
            if (app_state.shift_down) {
                scrollTextX(app_state, val * 5.0);
                return;
            }
            // Documento: la rotella scorre (lo zoom testo resta su +/-)
            scrollText(app_state, val * 5.0);
            return;
        }
        // Rotella = zoom immagini/mesh VERSO IL CURSORE (ultima posizione nota).
        const cpx = win.contentPx();
        if (val < 0) {
            applyZoomAt(app_state, 1.1, app_state.last_x, app_state.last_y, cpx.w, cpx.h);
        } else if (val > 0) {
            applyZoomAt(app_state, 1.0 / 1.1, app_state.last_x, app_state.last_y, cpx.w, cpx.h);
        }
    }
}

/// Ritorna true se zuer ha "consumato" l'evento: zrame allora salta le sue azioni
/// di default (spostamento/ridimensionamento finestra dal bordo, senza titlebar).
/// Così un click sulla scrollbar afferra il thumb invece di spostare la finestra.
pub fn mouseCallback(win: *zrame.Window, event: zrame.MouseEvent, user: ?*anyopaque) bool {
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return false));
    // Gli eventi puntatore arrivano da zrame già in coordinate del frame presentato
    // (vedi `zrame.MouseEvent`): lo stesso spazio in cui zuer disegna, quindi tutti gli
    // hit-test qui sotto (scrollbar, selezione testo, tab bar, controlli video) usano
    // le coordinate così come sono.
    switch (event) {
        .button => |btn| {
            // 0x110 = BTN_LEFT (click sinistro), 0x111 = BTN_RIGHT (click destro)
            if (btn.button != 0x110 and btn.button != 0x111) return false;
            const down = (btn.state == 1);
            // Snapshot dei flag di tipo sotto lock (pattern `is_pdf` del key
            // handler): sono riscritti da `applyDecoded` sui thread loader.
            app_state.shared.mutex.lockUncancelable(app_state.io);
            const is_text = app_state.shared.is_text;
            const is_mesh = app_state.shared.is_mesh;
            const is_table = app_state.shared.is_table;
            app_state.shared.mutex.unlock(app_state.io);
            // Doppio-click sinistro: video → fullscreen; immagine → fit ↔ 100% (verso
            // il cursore). Standard e comodo. Rilevato a orologio (gli eventi button
            // di zrame non portano timestamp).
            if (down and btn.button == 0x110) {
                const now = nowMs();
                const cxp = app_state.last_x;
                const cyp = app_state.last_y;
                const near = (cxp - last_click_x) * (cxp - last_click_x) + (cyp - last_click_y) * (cyp - last_click_y) < 36.0;
                const dbl = (now - last_click_ms) < 350 and near;
                last_click_ms = now;
                last_click_x = cxp;
                last_click_y = cyp;
                if (dbl) {
                    if (app_state.video.isActive()) {
                        win.toggleFullscreen();
                        return true;
                    } else if (!is_text and !is_mesh) {
                        const cpx = win.contentPx();
                        toggleFitActual(app_state, cxp, cyp, cpx.w, cpx.h);
                        return true;
                    }
                }
            }
            // Video: controlli overlay. Click sinistro su play/pausa o timeline;
            // il rilascio termina lo scrubbing. Click sul corpo → non consumato
            // (zrame muove/ridimensiona la finestra come al solito).
            if (app_state.video.isActive() and btn.button == 0x110) {
                const vid = &app_state.video;
                // Tutto nella STESSA sezione critica: static_w/h (per il fit-rect)
                // sono riscritti dal worker (`advanceVideo`) e dai thread loader,
                // e lo stato del player (scrubbing/playing/seek_to) è condiviso
                // col worker — l'hit-test deve vedere dimensioni coerenti.
                app_state.shared.mutex.lockUncancelable(app_state.io);
                // Il buffer video presentato È il fit-rect (zrame lo centra nel vetro e
                // consegna il mouse già nel suo spazio): serve solo la sua dimensione.
                const cpx = win.contentPx();
                const fr = videomod.videoFitRect(cpx.w, cpx.h, app_state.shared.static_w, app_state.shared.static_h);
                const vx = app_state.last_x;
                const vy = app_state.last_y;
                if (!down) {
                    if (vid.scrubbing) {
                        vid.scrubbing = false;
                        vid.idle_s = 0;
                        app_state.shared.mutex.unlock(app_state.io);
                        return true;
                    }
                    app_state.shared.mutex.unlock(app_state.io);
                } else switch (videomod.videoControlsHit(fr.w, fr.h, vx, vy)) {
                    .toggle => {
                        vid.playing = !vid.playing;
                        vid.idle_s = 0;
                        app_state.shared.mutex.unlock(app_state.io);
                        return true;
                    },
                    .timeline => {
                        vid.scrubbing = true;
                        vid.seek_to = videomod.videoTimelineFrac(fr.w, fr.h, vx) * (if (vid.dur_s > 0) vid.dur_s else 0);
                        vid.idle_s = 0;
                        app_state.shared.mutex.unlock(app_state.io);
                        return true;
                    },
                    .none => app_state.shared.mutex.unlock(app_state.io),
                }
            }
            if (!down) {
                app_state.shared.mutex.lockUncancelable(app_state.io);
                _ = app_state.shared.sc.onButtonUp();
                app_state.shared.sel_selecting = false;
                // Click senza trascinamento (ancora == estremo) → deseleziona.
                if (app_state.shared.sel_a[0] == app_state.shared.sel_b[0] and app_state.shared.sel_a[1] == app_state.shared.sel_b[1]) {
                    app_state.shared.sel_active = false;
                    app_state.shared.file_changed = true;
                }
                app_state.dragging = false;
                app_state.shared.mutex.unlock(app_state.io);
                return true;
            }
            // Click sinistro sulla barra delle linguette (in fondo): cambia foglio.
            if (btn.button == 0x110 and is_table and app_state.shared.tab_bar.count > 0) {
                const H = win.contentPx().h;
                const tb = &app_state.shared.tab_bar;
                if (tb.h <= H and app_state.last_y >= @as(f32, @floatFromInt(H - tb.h))) {
                    const mx: u32 = @intFromFloat(@max(app_state.last_x, 0));
                    var idx: usize = 0;
                    while (idx < tb.count and mx >= tb.bounds[idx]) : (idx += 1) {}
                    if (idx < tb.count) {
                        app_state.shared.mutex.lockUncancelable(app_state.io);
                        if (app_state.shared.decoded == .workbook and app_state.shared.decoded.workbook.active != idx) {
                            app_state.shared.decoded.workbook.active = idx;
                            // Nuovo foglio: riparti dall'alto/sinistra e ri-rasterizza.
                            app_state.shared.scroll_y = 0;
                            app_state.shared.scroll_x = 0;
                            resetScroll(&app_state.shared.sc);
                            app_state.shared.load_seq +%= 1;
                            app_state.shared.file_changed = true;
                        }
                        app_state.shared.mutex.unlock(app_state.io);
                    }
                    return true; // click sulla barra consumato (niente selezione)
                }
            }
            // Click sinistro: prima offri la pressione alla scrollbar (afferra il
            // thumb o salta sotto il cursore); se la consuma, niente selezione/drag.
            if (btn.button == 0x110) {
                app_state.shared.mutex.lockUncancelable(app_state.io);
                const grabbed = app_state.shared.sc.onButtonDown(app_state.last_x, app_state.last_y);
                if (grabbed) app_state.shared.file_changed = true;
                app_state.shared.mutex.unlock(app_state.io);
                if (grabbed) return true;
            }
            // Pressione sinistra sul testo: avvia la selezione — ma non troppo vicino al
            // bordo, dove (se il thumb non ha già afferrato sopra) lasciamo a zrame il
            // ridimensionamento della finestra. Senza questo, ogni click sul contenuto
            // consuma l'evento e la finestra risulta "fissa".
            if (btn.button == 0x110 and is_text) {
                const cpx = win.contentPx();
                const W = cpx.w;
                const H = cpx.h;
                const eb: f32 = 8.0; // banda resize di zrame (resizeEdgeAt)
                const rx = app_state.last_x;
                const ry = app_state.last_y;
                const near_edge = rx < eb or ry < eb or
                    rx > @as(f32, @floatFromInt(W)) - eb or
                    ry > @as(f32, @floatFromInt(H)) - eb;
                if (near_edge) {
                    app_state.dragging = down;
                    return false; // bordo libero: zrame ridimensiona
                }
                app_state.shared.mutex.lockUncancelable(app_state.io);
                if (app_state.shared.text_lines.items.len > 0) {
                    const hit = textHit(app_state, W, H, app_state.last_x, app_state.last_y);
                    app_state.shared.sel_a = hit;
                    app_state.shared.sel_b = hit;
                    app_state.shared.sel_active = true;
                    app_state.shared.sel_selecting = true;
                    app_state.shared.file_changed = true;
                    app_state.shared.mutex.unlock(app_state.io);
                    return true;
                }
                app_state.shared.mutex.unlock(app_state.io);
            }
            app_state.dragging = down;
            // Non consumato: click nel contenuto senza elemento interattivo — lascia a
            // zrame l'eventuale move/resize dal bordo (comportamento di default).
            return false;
        },
        .motion => |mot| {
            // Video: ogni movimento rivela i controlli (azzera l'idle); durante lo
            // scrubbing il movimento cerca sulla timeline. Consuma solo mentre
            // scrubba, così sul corpo la finestra resta trascinabile/ridimensionabile.
            if (app_state.video.isActive()) {
                const vid = &app_state.video;
                app_state.shared.mutex.lockUncancelable(app_state.io);
                vid.idle_s = 0;
                const scrub = vid.scrubbing;
                if (scrub) {
                    const cpx = win.contentPx();
                    const fr = videomod.videoFitRect(cpx.w, cpx.h, app_state.shared.static_w, app_state.shared.static_h);
                    vid.seek_to = videomod.videoTimelineFrac(fr.w, fr.h, mot.x) * (if (vid.dur_s > 0) vid.dur_s else 0);
                }
                app_state.shared.mutex.unlock(app_state.io);
                app_state.last_x = mot.x;
                app_state.last_y = mot.y;
                return scrub;
            }
            // La scrollbar vede sempre il movimento: aggiorna hover/thumb e, se sta
            // trascinando il cursore, muove l'offset. Se lo consuma (sopra la barra o
            // in drag), non facciamo selezione/pan.
            app_state.shared.mutex.lockUncancelable(app_state.io);
            const sc_consumed = app_state.shared.sc.onMotion(mot.x, mot.y);
            if (sc_consumed) app_state.shared.file_changed = true;
            app_state.shared.mutex.unlock(app_state.io);
            if (sc_consumed) {
                app_state.last_x = mot.x;
                app_state.last_y = mot.y;
                return true;
            }
            if (app_state.shared.sel_selecting) {
                const cpx = win.contentPx();
                app_state.shared.mutex.lockUncancelable(app_state.io);
                app_state.shared.sel_b = textHit(app_state, cpx.w, cpx.h, mot.x, mot.y);
                app_state.shared.file_changed = true;
                app_state.shared.mutex.unlock(app_state.io);
            } else if (app_state.dragging) {
                const dx = mot.x - app_state.last_x;
                const dy = mot.y - app_state.last_y;
                // Flag di tipo e camera sotto lo stesso mutex del pan: yaw/pitch
                // sono letti dal renderWorker e AZZERATI da `applyDecoded` sotto
                // `mutex` — incrementi a nudo potrebbero far perdere il reset.
                app_state.shared.mutex.lockUncancelable(app_state.io);
                if (app_state.shared.is_mesh) {
                    app_state.shared.yaw += dx * 0.01;
                    app_state.shared.pitch += dy * 0.01;
                    app_state.shared.mutex.unlock(app_state.io);
                } else if (app_state.shared.is_text) {
                    // Fallback (testo senza righe selezionabili, es. percorso GPU):
                    // il trascinamento scorre il documento. `scrollTo` riprende il
                    // lock da sé: rilascialo prima, con lo scroll_y già campionato.
                    const sy = app_state.shared.scroll_y;
                    app_state.shared.mutex.unlock(app_state.io);
                    scrollTo(app_state, sy - dy);
                } else {
                    app_state.shared.pan_x += dx;
                    app_state.shared.pan_y += dy;
                    app_state.shared.file_changed = true;
                    app_state.shared.mutex.unlock(app_state.io);
                }
            }
            app_state.last_x = mot.x;
            app_state.last_y = mot.y;
            // Consuma il movimento mentre selezioni/trascini, così zrame non mostra il
            // cursore di resize sul bordo durante l'interazione.
            return app_state.shared.sel_selecting or app_state.dragging;
        },
        .leave => {
            // Puntatore fuori dalla finestra: spegni l'hover della scrollbar (fade)
            // e dimentica l'ultima posizione così un click successivo non parte da
            // coordinate stantie.
            app_state.shared.mutex.lockUncancelable(app_state.io);
            app_state.shared.sc.onLeave();
            app_state.shared.file_changed = true;
            app_state.shared.mutex.unlock(app_state.io);
            app_state.last_x = -1;
            app_state.last_y = -1;
            return false;
        },
    }
}

/// Offset di byte del `col`-esimo codepoint in una riga UTF-8 (o fine stringa).
fn byteAtCol(s: []const u8, col: i32) usize {
    if (col <= 0) return 0;
    var n: i32 = 0;
    var i: usize = 0;
    while (i < s.len and n < col) {
        const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(@as(usize, seq), s.len - i);
        n += 1;
    }
    return i;
}

/// Costruisce il testo selezionato (righe unite da '\n'). Con `state.shared.mutex`
/// acquisito. Ritorna null se non c'è selezione; il chiamante libera il buffer.
fn buildSelectedText(state: *GuiAppState, gpa: std.mem.Allocator) ?[]u8 {
    if (!state.shared.sel_active) return null;
    const lines = state.shared.text_lines.items;
    if (lines.len == 0) return null;
    var a = state.shared.sel_a;
    var b = state.shared.sel_b;
    if (a[0] > b[0] or (a[0] == b[0] and a[1] > b[1])) {
        const t = a;
        a = b;
        b = t;
    }
    if (a[0] == b[0] and a[1] == b[1]) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const nrows: i32 = @intCast(lines.len);
    var row: i32 = std.math.clamp(a[0], 0, nrows - 1);
    while (row <= b[0] and row < nrows) : (row += 1) {
        const line = lines[@intCast(row)];
        const llen = compose.cpLen(line);
        const c0 = std.math.clamp(if (row == a[0]) a[1] else 0, 0, llen);
        const c1 = std.math.clamp(if (row == b[0]) b[1] else llen, 0, llen);
        const bs = byteAtCol(line, c0);
        const be = byteAtCol(line, c1);
        if (be > bs) out.appendSlice(gpa, line[bs..be]) catch return null;
        if (row < b[0]) out.append(gpa, '\n') catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}
