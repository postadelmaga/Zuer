//! Navigazione e caricamento file di zuer-gui — la logica "latest-wins".
//!
//! Contiene la navigazione tra i file della cartella (frecce), l'installazione
//! del contenuto decodificato (`applyDecoded`, unico a toccare il renderer), il
//! loader asincrono della navigazione a cache-miss (`postLoad`/`loadWorker`),
//! il decode iniziale in background (`decodeInitial`) e il prefetch dei vicini
//! (`prefetchWorker`). Estratto da gui.zig: stesse funzioni, stesso comportamento.

const std = @import("std");
const decoder_mod = @import("decoder.zig");
const loader_mod = @import("loader.zig");
const text_render = @import("text_render.zig");
// Player video nativo (libav): la navigazione verso/da un video lo avvia/ferma.
const videomod = @import("video.zig");
const midi_player = @import("midi_player.zig");
// Content-kind classification (path/decode → WinKind) + geometria iniziale finestra.
const layout = @import("layout.zig");
const gui_state_mod = @import("gui_state.zig");
const GuiAppState = gui_state_mod.GuiAppState;
const Prefetched = gui_state_mod.Prefetched;
const resetScroll = gui_state_mod.resetScroll;
const freeTextLines = gui_state_mod.freeTextLines;
const rgbToRgba = gui_state_mod.rgbToRgba;
const build_options = @import("build_options");
/// Vulkan mesh/text renderer available (Linux + Windows). Comptime so the GPU code links
/// only when enabled. Distinct from `has_video`: on Windows Vulkan is on but video is off.
const native = build_options.gpu;
/// libav-backed native video player available. Gates every call into `videomod`'s
/// real player API.
const has_video = build_options.video;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Estrae dalla cache il file già decodificato per `path` (e lo rimuove),
/// oppure `null` se non pronto. Chiamato dal thread main alla navigazione.
pub fn cacheTake(state: *GuiAppState, path: []const u8) ?Prefetched {
    state.pf.mutex.lockUncancelable(state.io);
    defer state.pf.mutex.unlock(state.io);
    if (state.pf.cache.fetchRemove(path)) |kv| {
        state.gpa.free(kv.key);
        return kv.value;
    }
    return null;
}

/// Imposta i due vicini da tenere in cache (duplica i percorsi) e sveglia il
/// thread di prefetch. `null` = nessun vicino su quel lato.
pub fn requestPrefetch(state: *GuiAppState, a: ?[]const u8, b: ?[]const u8) void {
    state.pf.mutex.lockUncancelable(state.io);
    for (&state.pf.want, [2]?[]const u8{ a, b }) |*slot, want| {
        if (slot.*) |old| state.gpa.free(old);
        slot.* = if (want) |w| (state.gpa.dupe(u8, w) catch null) else null;
    }
    state.pf.dirty = true;
    state.pf.mutex.unlock(state.io);
    state.pf.cond.signal(state.io);
}

/// Programma il prefetch dei file immediatamente prima/dopo quello corrente
/// nella lista della cartella. No-op per liste ≤1 o indice ignoto.
pub fn schedulePrefetchAround(state: *GuiAppState) void {
    const idx = state.current_file_index orelse return;
    const n = state.file_list.items.len;
    if (n <= 1) return;
    const dir_path = std.fs.path.dirname(state.shared.current_file_path);
    const prev_i = if (idx == 0) n - 1 else idx - 1;
    const next_i = (idx + 1) % n;
    var buf: [2]?[]u8 = .{ null, null };
    for (&buf, [2]usize{ prev_i, next_i }) |*out, i| {
        if (i == idx) continue; // liste di 2: prev==next==state va evitato
        const filename = state.file_list.items[i];
        out.* = if (dir_path) |dp|
            std.fs.path.join(state.gpa, &.{ dp, filename }) catch null
        else
            state.gpa.dupe(u8, filename) catch null;
    }
    defer for (buf) |p| if (p) |x| state.gpa.free(x);
    requestPrefetch(state, buf[0], buf[1]);
}

pub fn loadFile(state: *GuiAppState, new_path: []const u8) !void {
    // 1. Decodifica il nuovo file (fuori dal lock: non tocca stato condiviso)
    var new_decoded = decoder_mod.decode(new_path, state.io, state.gpa);
    if (new_decoded == .err) {
        std.debug.print("Errore nel caricamento del file {s}: {s}\n", .{ new_path, new_decoded.err });
        new_decoded.deinit(state.gpa);
        return;
    }
    try applyDecoded(state, new_decoded, null, new_path, null);
}

/// Posta una richiesta di caricamento asincrono al `loadWorker` e accende lo
/// spinner. Usata dalla navigazione a cache-miss: il decode avviene fuori dal
/// thread finestra, che resta libero di committare i frame dello spinner.
pub fn postLoad(state: *GuiAppState, new_path: []const u8) void {
    // Duplica prima di toccare lo stato: se l'alloc fallisce nessuna
    // richiesta viene accodata, quindi `loading` non va acceso (spinner
    // infinito senza nessuno che lo spenga).
    const req = state.gpa.dupe(u8, new_path) catch return;
    state.nav.mutex.lockUncancelable(state.io);
    if (state.nav.req) |old| state.gpa.free(old);
    state.nav.req = req;
    state.nav.gen +%= 1;
    state.nav.mutex.unlock(state.io);
    state.shared.mutex.lockUncancelable(state.io);
    state.shared.loading = true;
    state.shared.file_changed = true;
    state.shared.mutex.unlock(state.io);
    state.nav.cond.signal(state.io);
}

/// True se una navigazione più recente è arrivata dopo che il worker ha preso
/// `gen` (spam di frecce): il lavoro in corso è ormai superato e va scartato,
/// così il worker non spreca coarse+full+upload su modelli già oltrepassati.
pub fn navSuperseded(state: *GuiAppState, gen: u32) bool {
    state.nav.mutex.lockUncancelable(state.io);
    defer state.nav.mutex.unlock(state.io);
    return gen != state.nav.gen;
}

/// Libera i dati CPU della mesh dopo l'upload su GPU: sono tutti duplicati
/// altrove e non più necessari alla visualizzazione, ma su modelli grossi
/// valgono centinaia di MB. Azzera gli slice così `deinit` non rilibera.
///  - Geometria (vertici/facce/normali/uv/tangenti): interamente interleaved
///    nel buffer staging (il vertex buffer GPU, che resta vivo). Il voxel la
///    ricostruisce da lì on-demand (`voxelizeFromStage`).
///  - Texture (tex_pixels/nrm): baked su disco (cache VT) + pool GPU.
/// Conserva i metadati dei submesh (range indici + base_color): minuscoli e
/// usati dalla voxelizzazione per il colore di fallback.
pub fn freeMeshCpuData(state: *GuiAppState) void {
    if (state.shared.decoded != .mesh) return;
    const mesh = &state.shared.decoded.mesh;
    const free = struct {
        fn s(gpa: std.mem.Allocator, slice: anytype) @TypeOf(slice) {
            if (slice.len > 0) gpa.free(slice);
            return slice[0..0];
        }
    }.s;
    mesh.vertices = free(state.gpa, mesh.vertices);
    mesh.faces = free(state.gpa, mesh.faces);
    mesh.normals = free(state.gpa, mesh.normals);
    mesh.uvs = free(state.gpa, mesh.uvs);
    mesh.tangents = free(state.gpa, mesh.tangents);
    mesh.tex_pixels = free(state.gpa, mesh.tex_pixels);
    // Le texture dei submesh possono essere condivise (dedup atlas glTF):
    // il free dedup-aware libera ogni buffer una volta sola, poi si azzerano
    // gli slice così `deinit` non rilibera.
    decoder_mod.freeSubmeshTextures(mesh.submeshes, state.gpa);
    for (mesh.submeshes) |*sm| {
        sm.tex_pixels = sm.tex_pixels[0..0];
        sm.nrm_tex_pixels = sm.nrm_tex_pixels[0..0];
    }
}

/// Installa un contenuto già decodificato nello stato condiviso (swap sotto
/// lock). Prende possesso di `new_decoded` e, se presente, di `stage_override`
/// (staging GPU già calcolato dal prefetch: evita di ricalcolarlo qui).
/// Condiviso da `loadFile`, dal thread di decodifica iniziale (spinner) e dal
/// percorso di navigazione con cache-hit. DEVE girare sul thread main:
/// `setMesh` tocca il renderer Vulkan (serializzato con il render worker).
/// `gen` (se non null) è la generazione di navigazione del chiamante:
/// viene RIVERIFICATA qui sotto `mutex` (latest-wins senza TOCTOU — vedi sotto).
pub fn applyDecoded(state: *GuiAppState, new_decoded: decoder_mod.Decoded, stage_override: ?loader_mod.GpuStage, new_path: []const u8, gen: ?u32) !void {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);

    // Latest-wins senza TOCTOU: il check `navSuperseded` fatto dal chiamante
    // PRIMA di questo lock può essere già stantio (un cache-hit di `navigate`
    // può aver installato un file più recente nel frattempo). Riverifica la
    // generazione DENTRO la sezione critica e abortisci l'install se superata,
    // liberando le risorse di cui avremmo preso possesso. L'ordine di lock
    // `mutex` → `ld_mutex` è sicuro: nessun percorso tiene `ld_mutex` mentre
    // acquisisce `mutex` (postLoad/navigate/loadWorker li prendono in sequenza).
    if (gen) |g| {
        if (navSuperseded(state, g)) {
            var nd = new_decoded;
            nd.deinit(state.gpa);
            if (stage_override) |s| {
                var st = s;
                st.buffer.deinit(state.gpa);
            }
            return;
        }
    }

    // Ferma lo spinner in OGNI uscita da qui in poi, errori compresi (dupe
    // del percorso o staging falliti): altrimenti `loading` resterebbe true
    // per sempre e `navigate` ignorerebbe ogni freccia successiva.
    defer state.shared.loading = false;

    // Duplica SUBITO il percorso: se l'alloc fallisce non abbiamo ancora
    // toccato lo stato (niente `current_file_path` dangling da double-free
    // nel defer del main) e le risorse di cui prendiamo possesso — decoded
    // e stage prefetchato — vengono liberate qui invece di trapelare.
    const path_copy = state.gpa.dupe(u8, new_path) catch |e| {
        var nd = new_decoded;
        nd.deinit(state.gpa);
        if (stage_override) |s| {
            var st = s;
            st.buffer.deinit(state.gpa);
        }
        return e;
    };

    // Navigazione via da un video: ferma e chiudi il player precedente PRIMA
    // di installare il nuovo contenuto, altrimenti il render worker vedrebbe
    // ancora `video.isActive()` e `advanceVideo` sovrascriverebbe il nuovo
    // `static_rgba` coi frame del VECCHIO video (con l'audio che continua a
    // suonare). Thread-safety: siamo sotto `mutex`, lo stesso lock sotto cui
    // il worker tocca il Player in `advanceVideo` → il deinit è serializzato.
    if (has_video and state.video.isActive()) state.video.deinit();

    // Stessa cosa per il MIDI: navigando via, il synth precedente va fermato
    // (il thread audio viene joinato da stopAndDestroy). Siamo sotto `mutex`,
    // quindi serializzati col key handler che legge `state.midi`.
    if (state.midi) |mp| {
        mp.stopAndDestroy();
        state.midi = null;
    }

    // Refine progressivo: se il file è lo STESSO (fase full che rimpiazza la
    // coarse), preserva la camera così una rotazione fatta durante la coarse
    // non viene azzerata quando arriva il dettaglio pieno.
    const same_file = std.mem.eql(u8, new_path, state.shared.current_file_path);

    // 2. Libera le vecchie risorse decodificate. La geometria Vulkan è
    // importata zero-copy dal memfd dello stage: va rilasciata PRIMA del
    // munmap del buffer (vedi `releaseMesh` in gpu_renderer), altrimenti la
    // GPU legge memoria unmappata.
    state.shared.decoded.deinit(state.gpa);
    if (state.shared.stage_opt) |*s| {
        if (native) {
            // Il renderer non è più serializzato da `mutex`: il worker può stare
            // dentro `render()` fuori dal lock condiviso — il rilascio va sotto
            // il suo lock dedicato (vedi `renderer_mutex` in GuiAppState).
            state.renderer_mutex.lockUncancelable(state.io);
            state.renderer.releaseMesh();
            state.renderer_mutex.unlock(state.io);
        }
        s.buffer.deinit(state.gpa);
        state.shared.stage_opt = null;
    }

    // 3. Aggiorna decoded
    state.shared.decoded = new_decoded;

    // 4. Aggiorna percorso file corrente
    state.gpa.free(state.shared.current_file_path);
    state.shared.current_file_path = path_copy;

    // 5. Aggiorna flag tipo
    state.shared.is_mesh = state.shared.decoded == .mesh;
    state.shared.is_text = (state.shared.decoded != .mesh and state.shared.decoded != .image);
    state.shared.is_table = state.shared.decoded == .csv or state.shared.decoded == .workbook;

    // Listato di un archivio (tabella + path base senza `#voce`): parte con la
    // prima riga selezionata, così ↑/↓/Invio navigano subito. Altrimenti niente
    // selezione riga (-1).
    state.shared.table_sel_row = if (state.shared.is_table and gui_state_mod.isArchiveListing(path_copy)) 0 else -1;

    // Il prefetch prepara lo staging solo per le mesh: se per qualsiasi motivo
    // arriva uno stage per un non-mesh, liberalo qui (solo il ramo mesh lo usa).
    if (!state.shared.is_mesh) {
        if (stage_override) |s| {
            var st = s;
            st.buffer.deinit(state.gpa);
        }
    }

    // 6. Aggiorna i dati per GPU/CPU. I contenuti testuali non vengono
    // rasterizzati qui: lo fa il thread di rendering alla larghezza
    // corrente della finestra, per una resa 1:1 nitida.
    if (state.shared.is_mesh) {
        const m = state.shared.decoded.mesh;
        // Se staging o upload falliscono il render loop NON deve campionare
        // una mesh stantia/unmappata (quella vecchia è già stata rilasciata):
        // torna a "nessuna mesh" prima di propagare l'errore.
        errdefer state.shared.is_mesh = false;
        // Se il prefetch ha già preparato il buffer, riusalo (niente ricalcolo
        // di normali/tangenti qui, sul thread main): swap istantaneo.
        // stageToGpu is Linux/memfd-only → a mesh cleanly fails to load on a CPU-only
        // build; the GPU upload below is also comptime-excluded when !native.
        state.shared.stage_opt = if (stage_override) |s| s else (loader_mod.stageToGpu(state.gpa, &state.shared.decoded) orelse return error.StageFailed);
        const stage = &state.shared.stage_opt.?;
        if (native) {
            state.renderer_mutex.lockUncancelable(state.io);
            defer state.renderer_mutex.unlock(state.io);
            try state.renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
            try state.renderer.setMeshMaterials(&m);
            // Geometria e texture sono ora su GPU (vertex buffer + pool VT) e
            // su disco: libera i duplicati CPU (centinaia di MB su modelli
            // grossi). Il voxel li rigenera on-demand da `voxelizeFromStage`.
            freeMeshCpuData(state);
        }
        state.shared.mesh_center = m.center;
        state.shared.mesh_max_size = @max(m.bbox_max[0] - m.bbox_min[0], @max(m.bbox_max[1] - m.bbox_min[1], m.bbox_max[2] - m.bbox_min[2]));
        state.shared.mesh_material = .{ .base_color = m.base_color, .metallic = m.metallic, .roughness = m.roughness };
        // Nuova mesh: invalida la griglia voxel (verrà rigenerata al tasto V).
        state.shared.voxel_mode = false;
        state.shared.voxel_dim = 0;
    } else if (state.shared.decoded == .image) {
        const img = state.shared.decoded.image;
        state.gpa.free(state.shared.static_rgba);
        state.shared.static_rgba = &.{};
        // Dimensioni azzerate finché l'alloc non riesce: mai dims ≠ 0 con
        // pixel vuoti (il compose andrebbe out-of-bounds).
        state.shared.static_w = 0;
        state.shared.static_h = 0;
        state.shared.static_rgba = try rgbToRgba(state.gpa, img.pixels, @intCast(img.width), @intCast(img.height));
        state.shared.static_w = @intCast(img.width);
        state.shared.static_h = @intCast(img.height);
    } else {
        state.gpa.free(state.shared.static_rgba);
        state.shared.static_rgba = &.{};
        state.shared.static_w = 0;
        state.shared.static_h = 0;
    }

    // Navigazione VERSO un video: stessa logica di rilevamento del main
    // (l'estensione ha priorità: l'union `Decoded` non ha variante video, il
    // decoder media produce solo il poster `.image`). Avvia il player nativo
    // come fa il main all'apertura; il primo frame sostituisce il poster in
    // `static_rgba`. Sicuro dai worker thread: `setupVideo` tocca solo libav
    // e lo stato video/buffer condivisi, tutti protetti dal `mutex` già
    // acquisito qui (nessuna risorsa legata al thread finestra).
    if (has_video and layout.winKindFromExt(new_path) == .video) {
        if (startVideo(state, new_path)) {
            // Instrada tastiera/compose sul percorso video (il decode può
            // aver prodotto un poster `.image` o un errore testuale).
            state.shared.is_text = false;
            state.shared.is_table = false;
        }
    }

    // Navigazione VERSO un MIDI: la card informativa del plugin media resta il
    // contenuto mostrato; il synth (TinySoundFont) suona a lato e parte subito
    // (autoplay, come il video). `null` = SoundFont mancante o file invalido:
    // si resta sulla card, con un hint su stderr.
    if (isMidiPath(new_path)) {
        state.midi = midi_player.MidiPlayer.start(new_path, state.gpa);
        if (state.midi == null) std.debug.print(
            "MIDI non riproducibile: SoundFont mancante? Imposta ZUER_SOUNDFONT " ++
                "o installa un GM .sf2 (es. soundfont-fluid) in /usr/share/soundfonts/\n",
            .{},
        );
    }

    if (!same_file) {
        state.shared.zoom = 1.0;
        state.shared.yaw = 0.0;
        state.shared.pitch = 0.0;
        state.shared.pan_x = 0.0;
        state.shared.pan_y = 0.0;
    }
    state.shared.scroll_y = 0.0;
    state.shared.scroll_x = 0.0;
    resetScroll(&state.shared.sc);
    freeTextLines(state);
    // Nuovo contenuto: il layout ritenuto del documento precedente non vale più
    // (per i testi verrà ricostruito da `rasterizeText` al prossimo load_seq).
    gui_state_mod.freeTextDoc(state);
    // Follow (-f): riparti dall'inizio del nuovo file (0 = reinizializza al poll).
    state.shared.follow_off = 0;
    state.shared.sel_active = false;
    state.shared.sel_selecting = false;
    state.shared.load_seq +%= 1;
    state.shared.file_changed = true;
}

/// Apre il player video nativo su `path` e installa il primo frame (poster)
/// in `static_rgba`. Stessa sequenza di setup del main (VideoState + audio
/// dentro `setupVideo`). Da chiamare con `mutex` già acquisito — o prima
/// dello spawn dei thread, come fa `main` — perché tocca il Player e i
/// buffer condivisi col render worker. Ritorna false se il video non è
/// apribile (si resta sul contenuto corrente, es. il poster).
/// Estensione .mid/.midi (case-insensitive), al netto del frammento `#`.
fn isMidiPath(path: []const u8) bool {
    var clean = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| clean = path[0..h];
    const base = std.fs.path.basename(clean);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    const ext = base[dot + 1 ..];
    if (ext.len != 3 and ext.len != 4) return false;
    if ((ext[0] | 32) != 'm' or (ext[1] | 32) != 'i' or (ext[2] | 32) != 'd') return false;
    return ext.len == 3 or (ext[3] | 32) == 'i';
}

pub fn startVideo(state: *GuiAppState, path: []const u8) bool {
    const first = videomod.setupVideo(&state.video, path, state.gpa) catch |e| {
        // Nessuno stream video (mp3, wav, flac…): apri come audio-only →
        // oscilloscopio stile Winamp, riusando la stessa finestra/controlli.
        const af = videomod.setupAudio(&state.video, path, state.gpa) catch |e2| {
            std.debug.print("Media non apribile (video: {s}, audio: {s})\n", .{ @errorName(e), @errorName(e2) });
            return false;
        };
        state.gpa.free(state.shared.static_rgba);
        state.shared.static_rgba = af.rgba;
        state.shared.static_w = af.w;
        state.shared.static_h = af.h;
        return true;
    };
    state.gpa.free(state.shared.static_rgba);
    state.shared.static_rgba = first.rgba;
    state.shared.static_w = first.w;
    state.shared.static_h = first.h;
    return true;
}

pub fn initFileList(state: *GuiAppState) !void {
    const dir_path = std.fs.path.dirname(state.shared.current_file_path) orelse ".";
    var dir = try std.Io.Dir.cwd().openDir(state.io, dir_path, .{ .iterate = true });
    defer dir.close(state.io);

    var iterator = dir.iterate();
    while (try iterator.next(state.io)) |entry| {
        // Stesso filtro di `resolveInitialFile`: salta i file nascosti, così
        // le frecce non navigano su dotfile che l'apertura iniziale salta.
        if (entry.kind == .file and entry.name.len > 0 and entry.name[0] != '.') {
            try state.file_list.append(state.gpa, try state.gpa.dupe(u8, entry.name));
        }
    }

    std.mem.sort([]const u8, state.file_list.items, {}, struct {
        fn compare(context: void, a: []const u8, b: []const u8) bool {
            _ = context;
            return std.mem.order(u8, a, b) == .lt;
        }
    }.compare);

    const cur_filename = std.fs.path.basename(state.shared.current_file_path);
    state.current_file_index = null;
    for (state.file_list.items, 0..) |f, idx| {
        if (std.mem.eql(u8, f, cur_filename)) {
            state.current_file_index = idx;
            break;
        }
    }
}

pub fn navigate(state: *GuiAppState, direction: i2) void {
    // Direttiva UX: mentre un modello sta caricando (spinner, non ancora
    // visibile) ignora le nuove frecce, così non si accumulano navigazioni e
    // non si "impalla". Esc resta prioritario (gestito prima nel key handler:
    // chiude). Appena il modello è visibile `loading` torna false (lo azzera
    // applyDecoded, anche sulla fase coarse ~0.5s) → frecce reattive all'istante.
    if (state.shared.loading) return;
    if (state.file_list.items.len <= 1) return;
    const current_idx = state.current_file_index orelse return;

    var next_idx: usize = 0;
    if (direction > 0) {
        next_idx = (current_idx + 1) % state.file_list.items.len;
    } else {
        if (current_idx == 0) {
            next_idx = state.file_list.items.len - 1;
        } else {
            next_idx = current_idx - 1;
        }
    }

    // `current_file_path` è liberato/riassegnato da `applyDecoded` (anche sui
    // thread loader) sotto `mutex`: leggilo — e usa la slice di dirname —
    // solo sotto lock, costruendo qui il nuovo percorso.
    const filename = state.file_list.items[next_idx];
    state.shared.mutex.lockUncancelable(state.io);
    const dir_path = std.fs.path.dirname(state.shared.current_file_path);
    const new_path = if (dir_path) |dp|
        std.fs.path.join(state.gpa, &.{ dp, filename }) catch {
            state.shared.mutex.unlock(state.io);
            return;
        }
    else
        state.gpa.dupe(u8, filename) catch {
            state.shared.mutex.unlock(state.io);
            return;
        };
    state.shared.mutex.unlock(state.io);
    defer state.gpa.free(new_path);

    state.current_file_index = next_idx;

    // Cache-hit: il vicino è già decodificato (e staged) → swap istantaneo e
    // sincrono (nessuno spinner: è già pronto).
    if (cacheTake(state, new_path)) |pf| {
        // Latest-wins anche qui: invalida ogni load async in volo, altrimenti
        // un decode full del file PRECEDENTE potrebbe atterrare dopo e
        // sovrascrivere quello appena mostrato dalla cache.
        state.nav.mutex.lockUncancelable(state.io);
        if (state.nav.req) |old| {
            state.gpa.free(old);
            state.nav.req = null;
        }
        state.nav.gen +%= 1;
        state.nav.mutex.unlock(state.io);
        // gen = null: questo swap È la navigazione più recente per costruzione
        // (la generazione è appena stata invalidata qui sopra, e `navigate`
        // gira solo sul thread finestra) → installa sempre.
        applyDecoded(state, pf.decoded, pf.stage, new_path, null) catch |err|
            std.debug.print("Impossibile applicare il file (cache): {s}\n", .{@errorName(err)});
        // Contenuto nuovo installato: ridimensiona la finestra sulla forma del
        // contenuto (stessa euristica del sizing iniziale) con un'animazione.
        resizeToContent(state);
        // Precarica i nuovi vicini per rendere istantanea la prossima freccia.
        schedulePrefetchAround(state);
    } else {
        // Cache-miss (scroll più veloce del prefetch, o file troppo grande per
        // il prefetch): carica in ASINCRONO col loader thread, così il worker
        // può mostrare lo spinner e il thread finestra resta reattivo. resize +
        // prefetch li fa `loadWorker` dopo l'apply.
        postLoad(state, new_path);
    }
}

/// Ridimensiona (con animazione) la finestra sulla forma del contenuto
/// appena caricato, usando la stessa euristica del sizing iniziale
/// (`initialWindowSize`): immagini adattate all'aspetto reale con tetto,
/// tabelle sulla larghezza naturale delle colonne, documenti/mesh con
/// proporzioni fisse sensate. No-op finché la finestra non esiste.
pub fn resizeToContent(state: *GuiAppState) void {
    const win = state.win orelse return;
    // Snapshot delle dimensioni naturali sotto lock (il render worker legge
    // `decoded`/`static_*` concorrentemente): le immagini hanno static_w/h
    // note, le tabelle richiedono la misura naturale della griglia.
    state.shared.mutex.lockUncancelable(state.io);
    const kind = layout.winKindFromDecoded(&state.shared.decoded);
    var nat_w: u32 = 0;
    var nat_h: u32 = 0;
    switch (kind) {
        .image => {
            nat_w = state.shared.static_w;
            nat_h = state.shared.static_h;
        },
        .table => {
            const opts0 = text_render.RenderOpts{ .width = 1280, .pointsize = 15 };
            const csv0: ?decoder_mod.CsvData = switch (state.shared.decoded) {
                .csv => |c| c,
                .workbook => |w| w.activeCsv(),
                else => null,
            };
            if (csv0) |c| {
                if (text_render.tableNaturalSize(state.gpa, c, opts0)) |ns| {
                    nat_w = @intCast(ns.w);
                    nat_h = @intCast(ns.h);
                } else |_| {}
            }
        },
        // Documenti/mesh/generic: proporzioni fisse (nat_w/h = 0 → default).
        else => {},
    }
    // Contenuto piccolo → ingrandiscilo un po' e dimensiona la finestra sul
    // contenuto già zoomato (aderente, niente vuoto). Lo zoom pilota il worker,
    // che lo legge sotto lock: va scritto PRIMA di rilasciare il mutex.
    // Immagini: la finestra viene dimensionata sul contenuto già ingrandito e
    // il compose scala rispetto al FIT della finestra → `zoom = az` qui
    // raddoppierebbe l'ingrandimento (≈ az², immagine croppata). Il fit sulla
    // finestra ingrandita realizza da solo l'auto-zoom: zoom resta 1.
    const az = layout.autoZoomForContent(kind, nat_w, nat_h);
    state.shared.zoom = if (kind == .image) 1.0 else az;
    state.shared.mutex.unlock(state.io);
    const size = layout.initialWindowSize(kind, layout.scaleDim(nat_w, az), layout.scaleDim(nat_h, az));
    // `resizeToContent` gira anche sul loadWorker (navigazione a cache-miss):
    // il resize va differito al thread finestra, le surface Wayland non sono
    // thread-safe (altrimenti `xdg_surface: attached a buffer before configure`).
    win.requestResize(size.w, size.h);
}

/// Risolve l'argomento iniziale in un percorso di file. Se `arg` è una CARTELLA,
/// restituisce il primo file al suo interno (ordine alfabetico) — così invocando
/// zuer su una cartella si apre una preview navigabile con le frecce (initFileList
/// popola la lista con gli altri file). Se `arg` è già un file, lo duplica. Il
/// chiamante possiede e libera la stringa restituita.
pub fn resolveInitialFile(io: std.Io, gpa: std.mem.Allocator, arg: []const u8) !?[]u8 {
    // openDir riesce solo sulle cartelle; su un file dà errore → è già un file.
    var dir = std.Io.Dir.cwd().openDir(io, arg, .{ .iterate = true }) catch
        return try gpa.dupe(u8, arg);
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and entry.name.len > 0 and entry.name[0] != '.')
            try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    if (names.items.len == 0) return null; // cartella senza file visibili

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return try std.fs.path.join(gpa, &.{ arg, names.items[0] });
}

/// Thread loader: attende richieste (`postLoad`) e decodifica il file più recente
/// (latest-wins) fuori dal thread di input, installandolo con `applyDecoded`
/// (che spegne lo spinner). Sugli errori mostra il messaggio come testo.
/// Decodifica il file iniziale su un thread di background e lo installa nello
/// stato quando è pronto (azzerando lo spinner via `applyDecoded`). Sugli errori
/// mostra il messaggio come testo nella finestra invece di terminare il processo.
pub fn decodeInitial(state: *GuiAppState, path: []const u8) void {
    // Latest-wins anche per il decode iniziale (come `loadWorker`): appena la
    // fase coarse spegne lo spinner l'utente può navigare, e il full del file
    // iniziale — ormai superato — non deve sovrascrivere quello navigato.
    state.nav.mutex.lockUncancelable(state.io);
    const gen = state.nav.gen;
    state.nav.mutex.unlock(state.io);

    // Fase 1 (progressiva): se la cache texture coarse è calda (riapertura), una
    // resa a bassa risoluzione quasi istantanea; poi la fase 2 raffina a pieno.
    // decodeCoarse ritorna null se il formato non la supporta, o .err se la cache
    // è fredda (prima apertura) → in entrambi i casi si salta alla fase full.
    if (decoder_mod.decodeCoarse(path, state.io, state.gpa)) |coarse| {
        if (!navSuperseded(state, gen) and coarse == .mesh)
            applyDecoded(state, coarse, null, path, gen) catch |e|
                std.debug.print("apply coarse: {s}\n", .{@errorName(e)})
        else {
            var c = coarse;
            c.deinit(state.gpa);
        }
    }

    // L'utente ha già navigato oltre? Salta il full decode (l'operazione costosa).
    if (navSuperseded(state, gen)) return;

    var d = decoder_mod.decode(path, state.io, state.gpa);
    if (navSuperseded(state, gen)) {
        d.deinit(state.gpa);
        return;
    }
    if (d == .err) {
        const msg: []const u8 = std.fmt.allocPrint(state.gpa, "Errore nel caricamento del file:\n{s}", .{d.err}) catch "";
        d.deinit(state.gpa);
        applyDecoded(state, .{ .text = msg }, null, path, gen) catch {};
        return;
    }
    applyDecoded(state, d, null, path, gen) catch |e|
        std.debug.print("Impossibile applicare il file decodificato: {s}\n", .{@errorName(e)});
    // Contenuto iniziale pronto: precarica i vicini per una navigazione fluida.
    schedulePrefetchAround(state);
}

/// Thread di caricamento asincrono della navigazione: attende le richieste di
/// `postLoad` (cache-miss), decodifica fuori dal thread finestra e installa il
/// risultato con `applyDecoded` (che spegne lo spinner) + resize + prefetch.
/// Latest-wins: se nel frattempo è arrivata una richiesta più recente (`ld_gen`
/// cambiato) scarta il risultato — la nuova verrà processata al giro dopo.
pub fn loadWorker(state: *GuiAppState) void {
    const io = state.io;
    const gpa = state.gpa;
    while (true) {
        state.nav.mutex.lockUncancelable(io);
        while (!state.nav.stop and state.nav.req == null)
            state.nav.cond.waitUncancelable(io, &state.nav.mutex);
        if (state.nav.stop) {
            state.nav.mutex.unlock(io);
            break;
        }
        const path = state.nav.req.?;
        state.nav.req = null;
        const gen = state.nav.gen;
        state.nav.mutex.unlock(io);
        defer gpa.free(path);

        // Spam di frecce: se è GIÀ arrivata una navigazione più recente, salta
        // questa per intero (niente decode né upload) → la più recente verrà presa
        // al giro dopo. Evita di impegnare il worker su modelli oltrepassati.
        if (navSuperseded(state, gen)) continue;

        // Fase 1 progressiva: se la cache mesh coarse è calda (già visto), una resa
        // blurry quasi istantanea → tornando a un modello con le frecce lo spinner
        // si ferma subito invece di attendere il decode full. Se superata nel
        // frattempo o non disponibile, si scarta.
        if (decoder_mod.decodeCoarse(path, io, gpa)) |coarse| {
            if (!navSuperseded(state, gen) and coarse == .mesh)
                applyDecoded(state, coarse, null, path, gen) catch |e|
                    std.debug.print("apply coarse (async): {s}\n", .{@errorName(e)})
            else {
                var c = coarse;
                c.deinit(gpa);
            }
        }

        // Prima del full decode (l'operazione più costosa, ~secondi): se nel
        // frattempo l'utente ha già navigato oltre, saltalo e vai alla più recente.
        // È qui che si evita il "si impalla" dello spam frecce.
        if (navSuperseded(state, gen)) continue;

        // Decode CPU fuori da ogni lock.
        var d = decoder_mod.decode(path, io, gpa);

        // Superseded da una navigazione più recente? scarta (la più nuova arriverà).
        if (navSuperseded(state, gen)) {
            d.deinit(gpa);
            continue;
        }

        if (d == .err) {
            const msg: []const u8 = std.fmt.allocPrint(gpa, "Errore nel caricamento del file:\n{s}", .{d.err}) catch "";
            d.deinit(gpa);
            applyDecoded(state, .{ .text = msg }, null, path, gen) catch {};
        } else {
            applyDecoded(state, d, null, path, gen) catch |e|
                std.debug.print("Impossibile applicare il file (async): {s}\n", .{@errorName(e)});
        }
        // Se nel frattempo la richiesta è stata superata, l'install è stato
        // abortito dentro `applyDecoded`: niente resize/prefetch su contenuto
        // che non è mai stato installato.
        if (navSuperseded(state, gen)) continue;
        resizeToContent(state);
        schedulePrefetchAround(state);
    }
}

/// Thread di prefetch: decodifica (e stage-a, se mesh) i file vicini indicati da
/// `pf_want` nella cache `pf_cache`, evitando quelli già presenti ed evincendo
/// quelli non più desiderati (cache limitata ai 2 vicini). Fa SOLO decode+stage
/// (CPU/memfd): non tocca mai il renderer né lo stato condiviso della finestra.
pub fn prefetchWorker(state: *GuiAppState) void {
    const io = state.io;
    const gpa = state.gpa;
    // Soglia oltre cui NON precaricare (file enormi: lenti e pesanti in RAM;
    // tenerne 2 in cache gonfierebbe la memoria). Configurabile via env.
    const max_mb: u64 = blk: {
        if (getenv("ZUER_PREFETCH_MAX_MB")) |v| {
            if (std.fmt.parseInt(u64, std.mem.span(v), 10) catch null) |n| break :blk n;
        }
        break :blk 48;
    };
    while (true) {
        // Attende una richiesta (o lo stop) e ne prende una copia dei percorsi.
        state.pf.mutex.lockUncancelable(io);
        // Attende una richiesta NUOVA (pf_dirty), non la semplice presenza di
        // vicini desiderati: pf_want è persistente e resterebbe sempre non-null,
        // facendo girare il worker a vuoto. Consuma il flag qui sotto il lock.
        while (!state.pf.stop and !state.pf.dirty)
            state.pf.cond.waitUncancelable(io, &state.pf.mutex);
        if (state.pf.stop) {
            state.pf.mutex.unlock(io);
            break;
        }
        state.pf.dirty = false;
        var want: [2]?[]u8 = .{ null, null };
        for (&want, state.pf.want) |*w, src| w.* = if (src) |s| (gpa.dupe(u8, s) catch null) else null;
        // Evince dalla cache tutto ciò che non è più tra i vicini desiderati.
        var it = state.pf.cache.iterator();
        var to_evict: [8][]const u8 = undefined;
        var n_evict: usize = 0;
        while (it.next()) |entry| {
            const keep = wantContains(&want, entry.key_ptr.*);
            if (!keep and n_evict < to_evict.len) {
                to_evict[n_evict] = entry.key_ptr.*;
                n_evict += 1;
            }
        }
        for (to_evict[0..n_evict]) |k| {
            if (state.pf.cache.fetchRemove(k)) |kv| {
                var v = kv.value;
                v.deinit(gpa);
                gpa.free(kv.key);
            }
        }
        state.pf.mutex.unlock(io);
        defer for (want) |w| if (w) |x| gpa.free(x);

        // Decodifica (fuori dal lock) i vicini mancanti.
        for (want) |maybe_path| {
            const path = maybe_path orelse continue;
            state.pf.mutex.lockUncancelable(io);
            const already = state.pf.cache.contains(path) or state.pf.stop;
            state.pf.mutex.unlock(io);
            if (already) continue;

            // Salta i file troppo grandi (memoria) — verranno decodificati
            // sincronamente alla navigazione, come prima.
            if (fileSizeBytes(io, path)) |sz| {
                if (sz > max_mb * 1024 * 1024) continue;
            }

            var d = decoder_mod.decode(path, io, gpa);
            if (d == .err) {
                d.deinit(gpa);
                continue;
            }
            var pf = Prefetched{ .decoded = d };
            if (d == .mesh) pf.stage = loader_mod.stageToGpu(gpa, &pf.decoded);

            // Reinserisce solo se ancora desiderato e la richiesta non è cambiata.
            state.pf.mutex.lockUncancelable(io);
            const still_wanted = wantContains(&state.pf.want, path) and !state.pf.stop and !state.pf.cache.contains(path);
            if (still_wanted) {
                const key = gpa.dupe(u8, path) catch {
                    state.pf.mutex.unlock(io);
                    pf.deinit(gpa);
                    continue;
                };
                state.pf.cache.put(gpa, key, pf) catch {
                    gpa.free(key);
                    state.pf.mutex.unlock(io);
                    pf.deinit(gpa);
                    continue;
                };
                state.pf.mutex.unlock(io);
            } else {
                state.pf.mutex.unlock(io);
                pf.deinit(gpa);
            }
        }
    }
}

fn wantContains(want: *const [2]?[]u8, path: []const u8) bool {
    for (want) |w| {
        if (w) |x| if (std.mem.eql(u8, x, path)) return true;
    }
    return false;
}

/// Dimensione del file in byte, o `null` se non stat-abile.
fn fileSizeBytes(io: std.Io, path: []const u8) ?u64 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    return st.size;
}
