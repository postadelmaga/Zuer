//! Stato condiviso di zuer-gui.
//!
//! Contiene `GuiAppState` — il fascio di stato condiviso tra thread finestra
//! (callback input), render worker e thread loader/prefetch — con i campi
//! raggruppati in sotto-struct ESPLICITE per lock (`shared`/`nav`/`pf`, vedi i
//! doc-comment dei tipi), più gli helper che appartengono allo stato stesso
//! (`resetScroll`, `freeTextLines`, `rgbToRgba`) e quelli contesi tra gui.zig e
//! input.zig (`isPdfPath`, `minimalFrame`).

const std = @import("std");
const gpu = @import("gpu_renderer.zig");
const voxel = @import("voxel.zig");
const decoder_mod = @import("decoder.zig");
const loader_mod = @import("loader.zig");
const text_render = @import("text_render.zig");
// Player video nativo (libav): puntato da `GuiAppState.video`.
const videomod = @import("video.zig");
const midi_player = @import("midi_player.zig");
const compose = @import("compose.zig");
const TabBarState = compose.TabBarState;
const zrame = @import("zrame");
const zicro = @import("zicro");
const zscroll = zicro.scroll;

/// Un file già decodificato (e, se mesh, già "staged" su memfd) tenuto in cache
/// dal thread di prefetch, pronto per uno swap istantaneo alla navigazione.
/// Lo staging è pura CPU/memfd (`stageToGpu`), NON tocca il renderer Vulkan.
pub const Prefetched = struct {
    decoded: decoder_mod.Decoded,
    stage: ?loader_mod.GpuStage = null,

    pub fn deinit(self: *Prefetched, gpa: std.mem.Allocator) void {
        self.decoded.deinit(gpa);
        if (self.stage) |*s| s.buffer.deinit(gpa);
    }
};

pub const GuiAppState = struct {
    /// Stato condiviso protetto da `shared.mutex` (l'ex `state.mutex`): tutto
    /// ciò che thread finestra (callback input), render worker (rasterizzazione
    /// testo, compose) e thread loader (`applyDecoded`) leggono/scrivono in
    /// concorrenza. REGOLA: ogni accesso a questi campi avviene con
    /// `shared.mutex` acquisito. (Poche letture a nudo dal thread finestra —
    /// `loading` in `navigate`, `tab_bar.count`/`sel_selecting`/`sel_a`/`sel_b`
    /// nel mouse handler — sono comportamento storico, mantenute tali e quali.)
    pub const Shared = struct {
        // Protegge lo stato condiviso tra thread finestra (callback input,
        // loadFile) e thread di rendering (rasterizzazione testo, compose).
        mutex: std.Io.Mutex = .init,

        // Percorso del file corrente: liberato/riassegnato da `applyDecoded`
        // (anche sui thread loader) sotto `mutex`.
        current_file_path: []const u8 = &.{},

        // Variabili Zicro/Loader
        decoded: decoder_mod.Decoded = .{ .text = "" },
        stage_opt: ?loader_mod.GpuStage = null,

        // Variabili di stato rendering
        is_mesh: bool = false,
        is_text: bool = true,
        // Vero per le tabelle (csv/xls/ods...): abilita l'ancoraggio dell'header di
        // colonna durante lo scroll verticale (vedi `composeTextFrame`).
        is_table: bool = false,
        // Barra delle linguette dei fogli (solo workbook multi-foglio).
        tab_bar: TabBarState = .{},
        file_changed: bool = false,
        // Vero mentre il decoder del file iniziale gira su un thread di background:
        // il worker mostra lo spinner di caricamento invece del contenuto.
        loading: bool = false,
        // Incrementato a ogni load: il worker ri-rasterizza il testo solo quando
        // cambiano file, larghezza o zoom — mai per un semplice scroll.
        load_seq: u32 = 1,
        zoom: f32 = 1.0,
        static_rgba: []u8 = &.{},
        static_w: u32 = 0,
        static_h: u32 = 0,
        mesh_center: [3]f32 = .{ 0, 0, 0 },
        mesh_max_size: f32 = 1,
        mesh_material: gpu.Material = .{},
        // Modalità voxel (tasto V): ray-march della griglia voxel invece della mesh.
        voxel_mode: bool = false,
        voxel_bbox_min: [3]f32 = .{ 0, 0, 0 },
        voxel_bbox_size: [3]f32 = .{ 1, 1, 1 },
        voxel_dim: u32 = 0,

        // Rotazione 3D e pan: letti dal renderWorker e AZZERATI da `applyDecoded`
        // sotto `mutex` — incrementi a nudo potrebbero far perdere il reset.
        yaw: f32 = 0,
        pitch: f32 = 0,
        pan_x: f32 = 0,
        pan_y: f32 = 0,
        // Offset di scroll corrente (asse Y e X), rispecchiato dalla primitiva `sc` a
        // ogni frame del worker; i consumatori (compose/selezione/header) leggono questi.
        scroll_y: f32 = 0,
        scroll_x: f32 = 0,
        // Scrollbar flottanti egui (zicro.scroll): proprietarie dell'offset, della
        // kinetica e del drag del thumb. Condivise tra thread finestra (callback input:
        // onWheel/onButton*/onMotion) e worker (setViewport/setContent/tick/draw), quindi
        // ogni accesso è sotto `mutex`.
        sc: zscroll.Scroll = .{},

        // Modalità follow (-f): byte del file già mostrati (offset di lettura del
        // poll di crescita). 0 = non ancora inizializzato (primo poll: len del
        // testo decodificato, che per il decoder testo sono i byte grezzi del file).
        follow_off: u64 = 0,

        // Layout ritenuto del documento testuale (testo/codice/markdown): righe
        // visive + raster glifi. La pittura avviene per viewport a ogni compose
        // (`paintDocViewport`), mai sull'intero documento — `static_rgba` per
        // questi contenuti resta vuoto e `static_w/h` sono le dimensioni LOGICHE
        // del documento (scrollbar/selezione/hit-test ragionano su quelle).
        // Tabelle (csv/workbook) restano sul percorso a bitmap completa.
        text_doc: ?text_render.DocLayout = null,

        // Selezione testo (solo percorso CPU): testo semplice per riga visiva e
        // metriche della griglia monospazio per l'hit-testing; ancora/estremo della
        // selezione in coordinate (riga, colonna).
        text_lines: std.ArrayList([]const u8) = .empty,
        text_metrics: text_render.Metrics = .{ .advance = 1, .line_h = 1, .pad_x = 20, .pad_y = 14 },
        sel_active: bool = false,
        sel_selecting: bool = false,
        sel_a: [2]i32 = .{ 0, 0 },
        sel_b: [2]i32 = .{ 0, 0 },
    };

    /// Thread di caricamento asincrono per la navigazione a cache-miss: decodifica
    /// fuori dal thread finestra così il worker può animare lo spinner (il thread
    /// finestra resta libero di committare). `gen` = latest-wins: il thread
    /// applica solo se la sua generazione è ancora quella corrente.
    /// Tutti i campi sono protetti da `nav.mutex` (l'ex `ld_mutex`).
    pub const Nav = struct {
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        req: ?[]u8 = null, // percorso (posseduto) da caricare, null = nessuna richiesta
        gen: u32 = 0,
        stop: bool = false,
    };

    /// Prefetch dei file adiacenti (navigazione istantanea): un thread di
    /// background decodifica (e stage-a, se mesh) i vicini del file corrente in
    /// `cache`. Alla freccia lo swap è immediato se già in cache; altrimenti si
    /// ricade sul decode sincrono. Il thread NON tocca mai il renderer (solo
    /// decode+stage: CPU/memfd) → nessun accesso Vulkan da più thread.
    /// `applyDecoded` (unico a toccare il renderer) resta sul thread main.
    /// Tutti i campi sono protetti da `pf.mutex` (l'ex `pf_mutex`).
    pub const Pf = struct {
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        cache: std.StringHashMapUnmanaged(Prefetched) = .empty,
        want: [2]?[]u8 = .{ null, null }, // percorsi (posseduti) dei vicini da tenere in cache
        stop: bool = false,
        dirty: bool = false, // richiesta nuova da processare: `want`
        // è uno stato persistente, non una coda, quindi non si può usare per capire
        // se c'è lavoro nuovo — senza questo flag il worker gira a vuoto al 100% di CPU
    };

    // --- Campi senza lock: immutabili post-init o confinati a un thread -------

    gpa: std.mem.Allocator,
    io: std.Io,

    // Finestra zrame, impostata dopo la sua creazione — dal main, PRIMA di
    // `win.run()` (quindi prima che partano callback e worker); da lì in poi
    // solo letta. Serve alla navigazione per ridimensionare (con animazione)
    // la finestra sulla dimensione del contenuto.
    win: ?*zrame.Window = null,

    // Renderer Vulkan offscreen (posseduto): inizializzato dal main solo se
    // `native`, altrimenti resta `undefined` e nessun call site lo tocca (tutti
    // esclusi a comptime). Le chiamate che lo toccano (setMesh/render/
    // setVoxels/renderText/…) sono serializzate da `renderer_mutex`, NON da
    // `shared.mutex`: così il worker può renderizzare la mesh (fence Vulkan di
    // ms) senza tenere il lock condiviso e affamare i callback input.
    // Ordine di lock: chi li prende entrambi acquisisce shared.mutex PRIMA di
    // renderer_mutex (applyDecoded, toggleVoxel, rasterizeTextGpu); nessuno
    // prende shared.mutex tenendo renderer_mutex.
    renderer: gpu.Renderer = undefined,
    renderer_mutex: std.Io.Mutex = .init,
    // Player video nativo (posseduto; player null = nessun video). Lo stato
    // interno del player è condiviso col worker sotto `shared.mutex`
    // (`isActive()` è letto anche senza lock dal thread finestra — storico).
    video: videomod.VideoState = .{},
    // Player MIDI nativo (TinySoundFont; null = nessun MIDI attivo). Il
    // puntatore è protetto da `shared.mutex` (installato/fermato da
    // `applyDecoded`, letto dal key handler); lo stato interno del player
    // usa atomics propri (setPlaying/seek/clock sono thread-safe).
    midi: ?*midi_player.MidiPlayer = null,
    // Motore di resa testo: false = CPU (composizione diretta), true = atlante
    // GPU (ZUER_TEXT_ENGINE=gpu). Stessa resa, percorso diverso. Immutabile post-init.
    text_gpu: bool,
    // Modalità follow (-f, stile tail -f): il worker sorveglia la crescita del
    // file di testo corrente e tiene lo scroll agganciato al fondo se ci si era.
    // Immutabile post-init.
    follow: bool = false,

    // Stato file (lista della cartella): popolata da `initFileList` prima dello
    // spawn dei thread; `current_file_index` è poi mutato solo dal thread
    // finestra (`navigate`) e letto da `schedulePrefetchAround` anche sui
    // thread loader senza lock — comportamento storico.
    file_list: std.ArrayList([]const u8) = .empty,
    current_file_index: ?usize = null,

    // Stato di trascinamento e ultima posizione nota del puntatore: toccati
    // SOLO dal thread finestra (callback input). -1 = puntatore ancora fuori:
    // tiene nascoste le scrollbar flottanti finché il puntatore non entra
    // davvero (0,0 sarebbe già "dentro" e le mostrerebbe subito).
    dragging: bool = false,
    last_x: f32 = -1,
    last_y: f32 = -1,
    // Stato del tasto Ctrl (per Ctrl+C = copia negli appunti). Solo thread finestra.
    ctrl_down: bool = false,
    // Stato del tasto Shift (Shift+rotella = scroll orizzontale). Solo thread finestra.
    shift_down: bool = false,

    // Gruppi di campi per lock (vedi i doc-comment dei rispettivi tipi).
    shared: Shared = .{},
    nav: Nav = .{},
    pf: Pf = .{},

    /// Ricostruisce la geometria dal buffer staging (il vertex buffer GPU: vertici
    /// interleaved pos+normal+uv+tangent a stride 48, poi indici u32) e la
    /// voxelizza. Così la geometria CPU può essere liberata dopo l'upload
    /// (`freeMeshCpuData`) e rigenerata solo quando serve (tasto V). Colore dai
    /// base_color dei submesh (le texture sorgente sono già liberate).
    pub fn voxelizeFromStage(self: *GuiAppState, dim: u32) ?voxel.Grid {
        const stage = self.shared.stage_opt orelse return null;
        if (self.shared.decoded != .mesh) return null;
        const buf = stage.buffer.ptr;
        const stride: usize = 48;
        const vcount = stage.vertex_bytes / stride;
        const icount = stage.index_bytes / 4;
        if (vcount == 0 or icount < 3 or (vcount * stride) > buf.len) return null;

        const rdF = struct {
            fn f(b: []const u8, o: usize) f32 {
                return @bitCast(std.mem.readInt(u32, b[o..][0..4], .little));
            }
        }.f;

        const verts = self.gpa.alloc([3]f32, vcount) catch return null;
        defer self.gpa.free(verts);
        const uvs = self.gpa.alloc([2]f32, vcount) catch return null;
        defer self.gpa.free(uvs);
        var bbmin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
        var bbmax = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
        for (0..vcount) |i| {
            const o = i * stride;
            const p = [3]f32{ rdF(buf, o), rdF(buf, o + 4), rdF(buf, o + 8) };
            verts[i] = p;
            uvs[i] = .{ rdF(buf, o + 24), rdF(buf, o + 28) };
            inline for (0..3) |k| {
                bbmin[k] = @min(bbmin[k], p[k]);
                bbmax[k] = @max(bbmax[k], p[k]);
            }
        }

        const nfaces = icount / 3;
        const faces = self.gpa.alloc(decoder_mod.Face, nfaces) catch return null;
        defer self.gpa.free(faces);
        const ibase = stage.vertex_bytes;
        for (0..nfaces) |f| {
            faces[f] = .{
                .v1 = std.mem.readInt(u32, buf[ibase + (f * 3 + 0) * 4 ..][0..4], .little),
                .v2 = std.mem.readInt(u32, buf[ibase + (f * 3 + 1) * 4 ..][0..4], .little),
                .v3 = std.mem.readInt(u32, buf[ibase + (f * 3 + 2) * 4 ..][0..4], .little),
            };
        }

        var m = self.shared.decoded.mesh; // copia scalari + puntatore submesh (metadati vivi)
        m.vertices = verts;
        m.faces = faces;
        m.uvs = uvs;
        m.bbox_min = bbmin;
        m.bbox_max = bbmax;
        return voxel.voxelize(self.gpa, m, dim);
    }
};

/// Riporta la scrollbar all'origine azzerando offset, kinetica e coda di smoothing.
/// Il chiamante deve già detenere il `mutex`. Usato ai cambi di foglio/file.
pub fn resetScroll(sc: *zscroll.Scroll) void {
    sc.offset = .{ 0, 0 };
    sc.vel = .{ 0, 0 };
    sc.unprocessed = .{ 0, 0 };
}

/// Espande un buffer RGB compatto (`w`×`h`×3) in RGBA opaco (alpha 255).
/// Il chiamante possiede e libera lo slice restituito.
pub fn rgbToRgba(gpa: std.mem.Allocator, pixels: []const u8, w: u32, h: u32) ![]u8 {
    const n: usize = @as(usize, w) * h;
    const rgba = try gpa.alloc(u8, n * 4);
    for (0..n) |i| {
        rgba[i * 4 + 0] = pixels[i * 3 + 0];
        rgba[i * 4 + 1] = pixels[i * 3 + 1];
        rgba[i * 4 + 2] = pixels[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
    }
    return rgba;
}

/// Libera il testo per-riga trattenuto per la selezione.
pub fn freeTextLines(state: *GuiAppState) void {
    for (state.shared.text_lines.items) |l| state.gpa.free(l);
    state.shared.text_lines.clearRetainingCapacity();
}

/// Libera il layout ritenuto del documento testuale (righe + raster glifi).
/// Da chiamare con `state.shared.mutex` acquisito, come `freeTextLines`.
pub fn freeTextDoc(state: *GuiAppState) void {
    if (state.shared.text_doc) |*doc| doc.deinit();
    state.shared.text_doc = null;
}

pub fn isPdfPath(path: []const u8) bool {
    var clean_path = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |hash_idx| {
        clean_path = path[0..hash_idx];
    }
    return std.mem.endsWith(u8, clean_path, ".pdf") or std.mem.endsWith(u8, clean_path, ".PDF");
}

/// Zoom "contain": scala il frame così che stia interamente nella finestra
/// mantenendo l'aspetto (il lato limitante tocca il bordo).
/// Restringe il "vuoto" attorno alla finestra: gutter (margin) più stretto e ombra
/// più contenuta, mantenendo il carattere di ogni preset. Un solo frame di vetro,
/// minimale ed elegante, uguale per ogni tipo di file (immagine, video, pdf, mesh…).
/// Il margin resta abbastanza ampio da ospitare l'ombra senza tagliarla.
pub fn minimalFrame(s: zrame.Style) zrame.Style {
    var out = s;
    // Bordo minimale: gutter stretto che ospita solo un'ombra sottile. Il contenuto
    // riempie il pannello, quindi `margin` è di fatto lo spessore del bordo visibile.
    out.margin = 4;
    // L'ombra deve stare nel gutter: oltre `margin` verrebbe tagliata.
    out.shadow_blur = @min(out.shadow_blur, 4);
    out.shadow_offset_y = @min(out.shadow_offset_y, 2);
    // Vetro noir/fumé: spinge la tinta del preset verso il nero e la rende più
    // coprente, così il testo chiaro stacca sul blur del compositor; della tinta
    // originale resta solo un velo. Lo sheen dà il gradiente "fumo" verticale.
    out.glass = .{ .r = out.glass.r * 0.35, .g = out.glass.g * 0.35, .b = out.glass.b * 0.42, .a = @max(out.glass.a, 0.85) };
    out.sheen = @max(out.sheen, 0.14);
    // Il contenuto sfuma progressivamente verso il bordo del vetro invece di
    // terminare netto: si fonde con la finestra trasparente (px logici).
    const fade: f32 = 12;
    out.content_fade_width = fade;
    // La dissolvenza segue la forma del contenuto: col raggio del pannello sarebbe
    // quasi squadrata agli angoli, quindi il contenuto prende un raggio maggiorato
    // (pannello + 1.5·fade) → la sfumatura fa da vignetta ben ARROTONDATA.
    out.content_radius = out.corner_radius + fade * 1.5;
    return out;
}
