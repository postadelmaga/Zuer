//! zuer-gui — viewer GPU a finestra basato su zrame.
//!
//! Decodifica il file con gli stessi plugin di zuer, poi presenta in una
//! finestra Wayland zrame: le mesh sono rasterizzate dal renderer Vulkan
//! offscreen condiviso (`gpu_renderer.zig`), le immagini e testi sono
//! compositati a CPU; il frame finale RGBA viene inviato a zrame per la presentazione.

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu_renderer.zig");
const voxel = @import("voxel.zig");
const decoder_mod = @import("decoder.zig");
const loader_mod = @import("loader.zig");
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
const TabBarState = compose.TabBarState;
const max_tabs = compose.max_tabs;
const clipboard = @import("clipboard.zig");
const build_options = @import("build_options");
/// Vulkan mesh/text renderer available (Linux + Windows). Comptime so the GPU code links
/// only when enabled. Distinct from `has_video`: on Windows Vulkan is on but video is off.
const native = build_options.gpu;
/// libav-backed native video player available. Windows + Linux (needs vendored FFmpeg
/// import libs elsewhere). Gates every call into `videomod`'s real player API.
const has_video = build_options.video;
const zrame = @import("zrame");
const zicro = @import("zicro");
const paint = zicro.paint;
const zscroll = zicro.scroll;

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
const KEY_LEFTCTRL: u32 = 29;
const KEY_RIGHTCTRL: u32 = 97;
const KEY_LEFTSHIFT: u32 = 42;
const KEY_RIGHTSHIFT: u32 = 54;

// Il testo viene ri-rasterizzato al pointsize scalato: oltre questi limiti la
// resa degrada (corpo minuscolo) o esplode in memoria (immagini enormi).
const text_zoom_min: f32 = 0.4;
const text_zoom_max: f32 = 6.0;
const scroll_step: f32 = 60.0;

/// Mappa una coordinata finestra in (riga, colonna) sulla griglia del testo,
/// clampata al documento. Da chiamare con `state.mutex` acquisito.
fn textHit(state: *GuiAppState, W: u32, H: u32, mx: f32, my: f32) [2]i32 {
    const m = state.text_metrics.*;
    const geom = compose.textBlitGeom(W, H, state.static_w.*, state.static_h.*, state.scroll_y.*, state.scroll_x.*);
    const sx = @as(i32, @intFromFloat(mx)) - @as(i32, @intCast(geom.x_dst)) + @as(i32, @intCast(geom.x_src));
    const sy = @as(i32, @intFromFloat(my)) + @as(i32, @intCast(geom.off_y));
    const nrows: i32 = @intCast(state.text_lines.items.len);
    var row: i32 = if (m.line_h > 0) @divFloor(sy - m.pad_y, m.line_h) else 0;
    row = std.math.clamp(row, 0, @max(nrows - 1, 0));
    const llen: i32 = if (nrows > 0) compose.cpLen(state.text_lines.items[@intCast(row)]) else 0;
    // Arrotonda alla colonna più vicina (mezza cella) per un aggancio naturale.
    var col: i32 = if (m.advance > 0) @divFloor(sx - m.pad_x + @divTrunc(m.advance, 2), m.advance) else 0;
    col = std.math.clamp(col, 0, llen);
    return .{ row, col };
}

/// Un file già decodificato (e, se mesh, già "staged" su memfd) tenuto in cache
/// dal thread di prefetch, pronto per uno swap istantaneo alla navigazione.
/// Lo staging è pura CPU/memfd (`stageToGpu`), NON tocca il renderer Vulkan.
const Prefetched = struct {
    decoded: decoder_mod.Decoded,
    stage: ?loader_mod.GpuStage = null,

    fn deinit(self: *Prefetched, gpa: std.mem.Allocator) void {
        self.decoded.deinit(gpa);
        if (self.stage) |*s| s.buffer.deinit(gpa);
    }
};

const GuiAppState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    // Finestra zrame, impostata dopo la sua creazione. Serve alla navigazione per
    // ridimensionare (con animazione) la finestra sulla dimensione del contenuto.
    win: ?*zrame.Window = null,

    // Protegge lo stato condiviso tra thread finestra (callback input,
    // loadFile) e thread di rendering (rasterizzazione testo, compose).
    mutex: *std.Io.Mutex,

    // Stato file
    current_file_path: []const u8,
    file_list: std.ArrayList([]const u8),
    current_file_index: ?usize,

    // Variabili Zicro/Loader
    decoded: *decoder_mod.Decoded,
    stage_opt: *?loader_mod.GpuStage,
    renderer: *gpu.Renderer,
    // Motore di resa testo: false = CPU (composizione diretta), true = atlante
    // GPU (ZUER_TEXT_ENGINE=gpu). Stessa resa, percorso diverso.
    text_gpu: bool,
    // Player video nativo (null = nessun video). Solo il worker tocca il Player.
    video: *videomod.VideoState,

    // Variabili di stato rendering
    is_mesh: *bool,
    is_text: *bool,
    // Vero per le tabelle (csv/xls/ods...): abilita l'ancoraggio dell'header di
    // colonna durante lo scroll verticale (vedi `composeTextFrame`).
    is_table: *bool,
    // Barra delle linguette dei fogli (solo workbook multi-foglio).
    tab_bar: *TabBarState,
    file_changed: *bool,
    // Vero mentre il decoder del file iniziale gira su un thread di background:
    // il worker mostra lo spinner di caricamento invece del contenuto.
    loading: *bool,
    // Thread di caricamento asincrono per la navigazione a cache-miss: decodifica
    // fuori dal thread finestra così il worker può animare lo spinner (il thread
    // finestra resta libero di committare). `ld_gen` = latest-wins: il thread
    // applica solo se la sua generazione è ancora quella corrente. Protetti da ld_mutex.
    ld_mutex: *std.Io.Mutex,
    ld_cond: *std.Io.Condition,
    ld_req: *?[]u8, // percorso (posseduto) da caricare, null = nessuna richiesta
    ld_gen: *u32,
    ld_stop: *bool,
    // Incrementato a ogni load: il worker ri-rasterizza il testo solo quando
    // cambiano file, larghezza o zoom — mai per un semplice scroll.
    load_seq: *u32,
    zoom: *f32,
    static_rgba: *[]u8,
    static_w: *u32,
    static_h: *u32,
    mesh_center: *[3]f32,
    mesh_max_size: *f32,
    mesh_material: *gpu.Material,
    // Modalità voxel (tasto V): ray-march della griglia voxel invece della mesh.
    voxel_mode: *bool,
    voxel_bbox_min: *[3]f32,
    voxel_bbox_size: *[3]f32,
    voxel_dim: *u32,

    // Stato di trascinamento, scroll documento e rotazione 3D
    dragging: *bool,
    yaw: *f32,
    pitch: *f32,
    pan_x: *f32,
    pan_y: *f32,
    // Offset di scroll corrente (asse Y e X), rispecchiato dalla primitiva `sc` a
    // ogni frame del worker; i consumatori (compose/selezione/header) leggono questi.
    scroll_y: *f32,
    scroll_x: *f32,
    // Scrollbar flottanti egui (zicro.scroll): proprietarie dell'offset, della
    // kinetica e del drag del thumb. Condivise tra thread finestra (callback input:
    // onWheel/onButton*/onMotion) e worker (setViewport/setContent/tick/draw), quindi
    // ogni accesso è sotto `mutex`.
    sc: *zscroll.Scroll,
    last_x: *f32,
    last_y: *f32,

    // Selezione testo (solo percorso CPU): testo semplice per riga visiva e
    // metriche della griglia monospazio per l'hit-testing; ancora/estremo della
    // selezione in coordinate (riga, colonna).
    text_lines: *std.ArrayList([]const u8),
    text_metrics: *text_render.Metrics,
    sel_active: *bool,
    sel_selecting: *bool,
    sel_a: *[2]i32,
    sel_b: *[2]i32,
    // Stato del tasto Ctrl (per Ctrl+C = copia negli appunti).
    ctrl_down: *bool,
    // Stato del tasto Shift (Shift+rotella = scroll orizzontale).
    shift_down: *bool,

    // --- Prefetch dei file adiacenti (navigazione istantanea) -----------------
    // Un thread di background decodifica (e stage-a, se mesh) i vicini del file
    // corrente in `pf_cache`. Alla freccia lo swap è immediato se già in cache;
    // altrimenti si ricade sul decode sincrono. Il thread NON tocca mai il
    // renderer (solo decode+stage: CPU/memfd) → nessun accesso Vulkan da più
    // thread. `applyDecoded` (unico a toccare il renderer) resta sul thread main.
    pf_mutex: *std.Io.Mutex,
    pf_cond: *std.Io.Condition,
    pf_cache: *std.StringHashMapUnmanaged(Prefetched),
    pf_want: *[2]?[]u8, // percorsi (posseduti) dei vicini da tenere in cache
    pf_stop: *bool, // protetto da pf_mutex
    pf_dirty: *bool, // richiesta nuova da processare (protetto da pf_mutex): `pf_want`
    // è uno stato persistente, non una coda, quindi non si può usare per capire
    // se c'è lavoro nuovo — senza questo flag il worker gira a vuoto al 100% di CPU

    /// Estrae dalla cache il file già decodificato per `path` (e lo rimuove),
    /// oppure `null` se non pronto. Chiamato dal thread main alla navigazione.
    fn cacheTake(self: *GuiAppState, path: []const u8) ?Prefetched {
        self.pf_mutex.lockUncancelable(self.io);
        defer self.pf_mutex.unlock(self.io);
        if (self.pf_cache.fetchRemove(path)) |kv| {
            self.gpa.free(kv.key);
            return kv.value;
        }
        return null;
    }

    /// Imposta i due vicini da tenere in cache (duplica i percorsi) e sveglia il
    /// thread di prefetch. `null` = nessun vicino su quel lato.
    fn requestPrefetch(self: *GuiAppState, a: ?[]const u8, b: ?[]const u8) void {
        self.pf_mutex.lockUncancelable(self.io);
        for (self.pf_want, [2]?[]const u8{ a, b }) |*slot, want| {
            if (slot.*) |old| self.gpa.free(old);
            slot.* = if (want) |w| (self.gpa.dupe(u8, w) catch null) else null;
        }
        self.pf_dirty.* = true;
        self.pf_mutex.unlock(self.io);
        self.pf_cond.signal(self.io);
    }

    /// Programma il prefetch dei file immediatamente prima/dopo quello corrente
    /// nella lista della cartella. No-op per liste ≤1 o indice ignoto.
    fn schedulePrefetchAround(self: *GuiAppState) void {
        const idx = self.current_file_index orelse return;
        const n = self.file_list.items.len;
        if (n <= 1) return;
        const dir_path = std.fs.path.dirname(self.current_file_path);
        const prev_i = if (idx == 0) n - 1 else idx - 1;
        const next_i = (idx + 1) % n;
        var buf: [2]?[]u8 = .{ null, null };
        for (&buf, [2]usize{ prev_i, next_i }) |*out, i| {
            if (i == idx) continue; // liste di 2: prev==next==self va evitato
            const filename = self.file_list.items[i];
            out.* = if (dir_path) |dp|
                std.fs.path.join(self.gpa, &.{ dp, filename }) catch null
            else
                self.gpa.dupe(u8, filename) catch null;
        }
        defer for (buf) |p| if (p) |x| self.gpa.free(x);
        self.requestPrefetch(buf[0], buf[1]);
    }

    fn loadFile(self: *GuiAppState, new_path: []const u8) !void {
        // 1. Decodifica il nuovo file (fuori dal lock: non tocca stato condiviso)
        var new_decoded = decoder_mod.decode(new_path, self.io, self.gpa);
        if (new_decoded == .err) {
            std.debug.print("Errore nel caricamento del file {s}: {s}\n", .{ new_path, new_decoded.err });
            new_decoded.deinit(self.gpa);
            return;
        }
        try self.applyDecoded(new_decoded, null, new_path);
    }

    /// Posta una richiesta di caricamento asincrono al `loadWorker` e accende lo
    /// spinner. Usata dalla navigazione a cache-miss: il decode avviene fuori dal
    /// thread finestra, che resta libero di committare i frame dello spinner.
    fn postLoad(self: *GuiAppState, new_path: []const u8) void {
        self.ld_mutex.lockUncancelable(self.io);
        if (self.ld_req.*) |old| self.gpa.free(old);
        self.ld_req.* = self.gpa.dupe(u8, new_path) catch null;
        self.ld_gen.* +%= 1;
        self.ld_mutex.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        self.loading.* = true;
        self.file_changed.* = true;
        self.mutex.unlock(self.io);
        self.ld_cond.signal(self.io);
    }

    /// True se una navigazione più recente è arrivata dopo che il worker ha preso
    /// `gen` (spam di frecce): il lavoro in corso è ormai superato e va scartato,
    /// così il worker non spreca coarse+full+upload su modelli già oltrepassati.
    fn navSuperseded(self: *GuiAppState, gen: u32) bool {
        self.ld_mutex.lockUncancelable(self.io);
        defer self.ld_mutex.unlock(self.io);
        return gen != self.ld_gen.*;
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
    fn freeMeshCpuData(self: *GuiAppState) void {
        if (self.decoded.* != .mesh) return;
        const mesh = &self.decoded.mesh;
        const free = struct {
            fn s(gpa: std.mem.Allocator, slice: anytype) @TypeOf(slice) {
                if (slice.len > 0) gpa.free(slice);
                return slice[0..0];
            }
        }.s;
        mesh.vertices = free(self.gpa, mesh.vertices);
        mesh.faces = free(self.gpa, mesh.faces);
        mesh.normals = free(self.gpa, mesh.normals);
        mesh.uvs = free(self.gpa, mesh.uvs);
        mesh.tangents = free(self.gpa, mesh.tangents);
        mesh.tex_pixels = free(self.gpa, mesh.tex_pixels);
        for (mesh.submeshes) |*sm| {
            sm.tex_pixels = free(self.gpa, sm.tex_pixels);
            sm.nrm_tex_pixels = free(self.gpa, sm.nrm_tex_pixels);
        }
    }

    /// Ricostruisce la geometria dal buffer staging (il vertex buffer GPU: vertici
    /// interleaved pos+normal+uv+tangent a stride 48, poi indici u32) e la
    /// voxelizza. Così la geometria CPU può essere liberata dopo l'upload
    /// (`freeMeshCpuData`) e rigenerata solo quando serve (tasto V). Colore dai
    /// base_color dei submesh (le texture sorgente sono già liberate).
    fn voxelizeFromStage(self: *GuiAppState, dim: u32) ?voxel.Grid {
        const stage = self.stage_opt.* orelse return null;
        if (self.decoded.* != .mesh) return null;
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

        var m = self.decoded.mesh; // copia scalari + puntatore submesh (metadati vivi)
        m.vertices = verts;
        m.faces = faces;
        m.uvs = uvs;
        m.bbox_min = bbmin;
        m.bbox_max = bbmax;
        return voxel.voxelize(self.gpa, m, dim);
    }

    /// Installa un contenuto già decodificato nello stato condiviso (swap sotto
    /// lock). Prende possesso di `new_decoded` e, se presente, di `stage_override`
    /// (staging GPU già calcolato dal prefetch: evita di ricalcolarlo qui).
    /// Condiviso da `loadFile`, dal thread di decodifica iniziale (spinner) e dal
    /// percorso di navigazione con cache-hit. DEVE girare sul thread main:
    /// `setMesh` tocca il renderer Vulkan (serializzato con il render worker).
    fn applyDecoded(self: *GuiAppState, new_decoded: decoder_mod.Decoded, stage_override: ?loader_mod.GpuStage, new_path: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Ferma lo spinner: da qui in poi la finestra mostra il contenuto (o
        // l'errore) invece del caricamento. Prima dello staging che può fallire,
        // così lo spinner si ferma comunque.
        self.loading.* = false;

        // Refine progressivo: se il file è lo STESSO (fase full che rimpiazza la
        // coarse), preserva la camera così una rotazione fatta durante la coarse
        // non viene azzerata quando arriva il dettaglio pieno.
        const same_file = std.mem.eql(u8, new_path, self.current_file_path);

        // 2. Libera le vecchie risorse decodificate
        self.decoded.deinit(self.gpa);
        if (self.stage_opt.*) |*s| {
            s.buffer.deinit(self.gpa);
            self.stage_opt.* = null;
        }

        // 3. Aggiorna decoded
        self.decoded.* = new_decoded;

        // 4. Aggiorna percorso file corrente
        self.gpa.free(self.current_file_path);
        self.current_file_path = try self.gpa.dupe(u8, new_path);

        // 5. Aggiorna flag tipo
        self.is_mesh.* = self.decoded.* == .mesh;
        self.is_text.* = (self.decoded.* != .mesh and self.decoded.* != .image);
        self.is_table.* = self.decoded.* == .csv or self.decoded.* == .workbook;

        // Il prefetch prepara lo staging solo per le mesh: se per qualsiasi motivo
        // arriva uno stage per un non-mesh, liberalo qui (solo il ramo mesh lo usa).
        if (!self.is_mesh.*) {
            if (stage_override) |s| {
                var st = s;
                st.buffer.deinit(self.gpa);
            }
        }

        // 6. Aggiorna i dati per GPU/CPU. I contenuti testuali non vengono
        // rasterizzati qui: lo fa il thread di rendering alla larghezza
        // corrente della finestra, per una resa 1:1 nitida.
        if (self.is_mesh.*) {
            const m = self.decoded.mesh;
            // Se il prefetch ha già preparato il buffer, riusalo (niente ricalcolo
            // di normali/tangenti qui, sul thread main): swap istantaneo.
            // stageToGpu is Linux/memfd-only → a mesh cleanly fails to load on a CPU-only
            // build; the GPU upload below is also comptime-excluded when !native.
            self.stage_opt.* = if (stage_override) |s| s else (loader_mod.stageToGpu(self.gpa, self.decoded) orelse return error.StageFailed);
            const stage = &self.stage_opt.*.?;
            if (native) {
                try self.renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
                try self.renderer.setMeshMaterials(&m);
                // Geometria e texture sono ora su GPU (vertex buffer + pool VT) e
                // su disco: libera i duplicati CPU (centinaia di MB su modelli
                // grossi). Il voxel li rigenera on-demand da `voxelizeFromStage`.
                self.freeMeshCpuData();
            }
            self.mesh_center.* = m.center;
            self.mesh_max_size.* = @max(m.bbox_max[0] - m.bbox_min[0], @max(m.bbox_max[1] - m.bbox_min[1], m.bbox_max[2] - m.bbox_min[2]));
            self.mesh_material.* = .{ .base_color = m.base_color, .metallic = m.metallic, .roughness = m.roughness };
            // Nuova mesh: invalida la griglia voxel (verrà rigenerata al tasto V).
            self.voxel_mode.* = false;
            self.voxel_dim.* = 0;
        } else if (self.decoded.* == .image) {
            const img = self.decoded.image;
            self.gpa.free(self.static_rgba.*);
            self.static_rgba.* = &.{};
            self.static_w.* = @intCast(img.width);
            self.static_h.* = @intCast(img.height);
            self.static_rgba.* = try self.gpa.alloc(u8, self.static_w.* * self.static_h.* * 4);
            for (0..self.static_w.* * self.static_h.*) |i| {
                self.static_rgba.*[i * 4 + 0] = img.pixels[i * 3 + 0];
                self.static_rgba.*[i * 4 + 1] = img.pixels[i * 3 + 1];
                self.static_rgba.*[i * 4 + 2] = img.pixels[i * 3 + 2];
                self.static_rgba.*[i * 4 + 3] = 255;
            }
        } else {
            self.gpa.free(self.static_rgba.*);
            self.static_rgba.* = &.{};
            self.static_w.* = 0;
            self.static_h.* = 0;
        }

        if (!same_file) {
            self.zoom.* = 1.0;
            self.yaw.* = 0.0;
            self.pitch.* = 0.0;
            self.pan_x.* = 0.0;
            self.pan_y.* = 0.0;
        }
        self.scroll_y.* = 0.0;
        self.scroll_x.* = 0.0;
        resetScroll(self.sc);
        freeTextLines(self);
        self.sel_active.* = false;
        self.sel_selecting.* = false;
        self.load_seq.* +%= 1;
        self.file_changed.* = true;
    }

    fn initFileList(self: *GuiAppState) !void {
        const dir_path = std.fs.path.dirname(self.current_file_path) orelse ".";
        var dir = try std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true });
        defer dir.close(self.io);

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind == .file) {
                try self.file_list.append(self.gpa, try self.gpa.dupe(u8, entry.name));
            }
        }

        std.mem.sort([]const u8, self.file_list.items, {}, struct {
            fn compare(context: void, a: []const u8, b: []const u8) bool {
                _ = context;
                return std.mem.order(u8, a, b) == .lt;
            }
        }.compare);

        const cur_filename = std.fs.path.basename(self.current_file_path);
        self.current_file_index = null;
        for (self.file_list.items, 0..) |f, idx| {
            if (std.mem.eql(u8, f, cur_filename)) {
                self.current_file_index = idx;
                break;
            }
        }
    }

    fn navigate(self: *GuiAppState, direction: i2) void {
        if (self.file_list.items.len <= 1) return;
        const current_idx = self.current_file_index orelse return;

        var next_idx: usize = 0;
        if (direction > 0) {
            next_idx = (current_idx + 1) % self.file_list.items.len;
        } else {
            if (current_idx == 0) {
                next_idx = self.file_list.items.len - 1;
            } else {
                next_idx = current_idx - 1;
            }
        }

        const dir_path = std.fs.path.dirname(self.current_file_path);
        const filename = self.file_list.items[next_idx];
        const new_path = if (dir_path) |dp|
            std.fs.path.join(self.gpa, &.{ dp, filename }) catch return
        else
            self.gpa.dupe(u8, filename) catch return;
        defer self.gpa.free(new_path);

        self.current_file_index = next_idx;

        // Cache-hit: il vicino è già decodificato (e staged) → swap istantaneo e
        // sincrono (nessuno spinner: è già pronto).
        if (self.cacheTake(new_path)) |pf| {
            self.applyDecoded(pf.decoded, pf.stage, new_path) catch |err|
                std.debug.print("Impossibile applicare il file (cache): {s}\n", .{@errorName(err)});
            // Contenuto nuovo installato: ridimensiona la finestra sulla forma del
            // contenuto (stessa euristica del sizing iniziale) con un'animazione.
            self.resizeToContent();
            // Precarica i nuovi vicini per rendere istantanea la prossima freccia.
            self.schedulePrefetchAround();
        } else {
            // Cache-miss (scroll più veloce del prefetch, o file troppo grande per
            // il prefetch): carica in ASINCRONO col loader thread, così il worker
            // può mostrare lo spinner e il thread finestra resta reattivo. resize +
            // prefetch li fa `loadWorker` dopo l'apply.
            self.postLoad(new_path);
        }
    }

    /// Ridimensiona (con animazione) la finestra sulla forma del contenuto
    /// appena caricato, usando la stessa euristica del sizing iniziale
    /// (`initialWindowSize`): immagini adattate all'aspetto reale con tetto,
    /// tabelle sulla larghezza naturale delle colonne, documenti/mesh con
    /// proporzioni fisse sensate. No-op finché la finestra non esiste.
    fn resizeToContent(self: *GuiAppState) void {
        const win = self.win orelse return;
        // Snapshot delle dimensioni naturali sotto lock (il render worker legge
        // `decoded`/`static_*` concorrentemente): le immagini hanno static_w/h
        // note, le tabelle richiedono la misura naturale della griglia.
        self.mutex.lockUncancelable(self.io);
        const kind = layout.winKindFromDecoded(self.decoded);
        var nat_w: u32 = 0;
        var nat_h: u32 = 0;
        switch (kind) {
            .image => {
                nat_w = self.static_w.*;
                nat_h = self.static_h.*;
            },
            .table => {
                const opts0 = text_render.RenderOpts{ .width = 1280, .pointsize = 15 };
                const csv0: ?decoder_mod.CsvData = switch (self.decoded.*) {
                    .csv => |c| c,
                    .workbook => |w| w.activeCsv(),
                    else => null,
                };
                if (csv0) |c| {
                    if (text_render.tableNaturalSize(self.gpa, c, opts0)) |ns| {
                        nat_w = @intCast(ns.w);
                        nat_h = @intCast(ns.h);
                    } else |_| {}
                }
            },
            // Documenti/mesh/generic: proporzioni fisse (nat_w/h = 0 → default).
            else => {},
        }
        self.mutex.unlock(self.io);

        // Contenuto piccolo → ingrandiscilo un po' e dimensiona la finestra sul
        // contenuto già zoomato (aderente, niente vuoto). Lo zoom pilota il worker.
        const az = layout.autoZoomForContent(kind, nat_w, nat_h);
        self.zoom.* = az;
        const size = layout.initialWindowSize(kind, layout.scaleDim(nat_w, az), layout.scaleDim(nat_h, az));
        // `resizeToContent` gira anche sul loadWorker (navigazione a cache-miss):
        // il resize va differito al thread finestra, le surface Wayland non sono
        // thread-safe (altrimenti `xdg_surface: attached a buffer before configure`).
        win.requestResize(size.w, size.h);
    }
};

fn applyZoom(app_state: *GuiAppState, factor: f32) void {
    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);
    app_state.zoom.* = std.math.clamp(app_state.zoom.* * factor, 0.1, 20.0);
    app_state.file_changed.* = true;
}

/// Scroll verticale fluido (rotella/tasti): accumula `delta` px nel buffer di
/// smoothing low-pass della primitiva, che il worker applica in `tick` (stesso feel
/// egui della rotella). Il clamp ai limiti del contenuto avviene nel `tick`.
fn scrollText(app_state: *GuiAppState, delta: f32) void {
    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);
    app_state.sc.unprocessed[1] += delta;
    app_state.file_changed.* = true;
}

/// Come `scrollText` ma sull'asse orizzontale (tabelle più larghe della finestra).
fn scrollTextX(app_state: *GuiAppState, delta: f32) void {
    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);
    app_state.sc.unprocessed[0] += delta;
    app_state.file_changed.* = true;
}

/// Scroll immediato (senza smoothing) a una posizione verticale assoluta: per il
/// trascinamento del documento (fallback), dove serve reattività 1:1. Il clamp
/// definitivo ai limiti avviene nel `tick` del worker.
fn scrollTo(app_state: *GuiAppState, y: f32) void {
    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);
    app_state.sc.offset[1] = @max(y, 0);
    app_state.sc.vel[1] = 0;
    app_state.sc.unprocessed[1] = 0;
    app_state.file_changed.* = true;
}

/// Riporta la scrollbar all'origine azzerando offset, kinetica e coda di smoothing.
/// Il chiamante deve già detenere il `mutex`. Usato ai cambi di foglio/file.
fn resetScroll(sc: *zscroll.Scroll) void {
    sc.offset = .{ 0, 0 };
    sc.vel = .{ 0, 0 };
    sc.unprocessed = .{ 0, 0 };
}

fn isPdfPath(path: []const u8) bool {
    var clean_path = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |hash_idx| {
        clean_path = path[0..hash_idx];
    }
    return std.mem.endsWith(u8, clean_path, ".pdf") or std.mem.endsWith(u8, clean_path, ".PDF");
}

fn changePdfPage(app_state: *GuiAppState, direction: i32) void {
    app_state.mutex.lockUncancelable(app_state.io);
    const path = app_state.gpa.dupe(u8, app_state.current_file_path) catch {
        app_state.mutex.unlock(app_state.io);
        return;
    };
    const is_image = (app_state.decoded.* == .image);
    var name_dup: ?[]const u8 = null;
    if (is_image) {
        name_dup = app_state.gpa.dupe(u8, app_state.decoded.image.name) catch null;
    }
    app_state.mutex.unlock(app_state.io);
    defer app_state.gpa.free(path);
    defer if (name_dup) |n| app_state.gpa.free(n);

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

    var total_pages: usize = 99999;
    if (name_dup) |name| {
        if (std.mem.lastIndexOf(u8, name, " di ")) |di_idx| {
            const after_di = name[di_idx + " di ".len ..];
            if (std.mem.indexOfScalar(u8, after_di, ')')) |paren_idx| {
                const total_str = after_di[0..paren_idx];
                total_pages = std.fmt.parseInt(usize, total_str, 10) catch 99999;
            }
        }
    }

    var new_page = current_page;
    if (direction > 0) {
        if (current_page < total_pages) {
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

    app_state.loadFile(new_path) catch |err| {
        std.debug.print("Impossibile caricare pagina PDF: {s}\n", .{@errorName(err)});
    };
}

/// Alterna la modalità voxel. Alla prima attivazione voxelizza la mesh corrente
/// (griglia 96³) e la carica nel renderer; le attivazioni successive riusano la
/// griglia già caricata. Tiene il mutex: il thread di render usa lo stesso renderer.
fn toggleVoxel(app_state: *GuiAppState) void {
    if (!native) return; // voxel view is a GPU-only feature
    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);

    if (!app_state.voxel_mode.* and app_state.voxel_dim.* == 0 and app_state.decoded.* == .mesh) {
        var grid = app_state.voxelizeFromStage(96) orelse {
            std.debug.print("[voxel] voxelizzazione fallita\n", .{});
            return;
        };
        defer grid.deinit(app_state.gpa);
        app_state.renderer.setVoxels(grid.dim, grid.data) catch |e| {
            std.debug.print("[voxel] setVoxels: {s}\n", .{@errorName(e)});
            return;
        };
        app_state.voxel_bbox_min.* = grid.bbox_min;
        app_state.voxel_bbox_size.* = grid.bbox_size;
        app_state.voxel_dim.* = grid.dim;
    }
    // Il path mesh `render()` è pipelined (fence ping-pong), il voxel è slot 0
    // sincrono: risincronizza il double-buffer a ogni cambio di modalità.
    app_state.renderer.resetFrameSync();
    app_state.voxel_mode.* = !app_state.voxel_mode.*;
    app_state.file_changed.* = true; // forza un re-render
}

fn keyCallback(win: *zrame.Window, key: u32, state: u32, user: ?*anyopaque) void {
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    const pressed = (state == 1);
    if (key == KEY_LEFTSHIFT or key == KEY_RIGHTSHIFT) {
        app_state.shift_down.* = pressed;
    }
    if (key == KEY_LEFTCTRL or key == KEY_RIGHTCTRL) {
        app_state.ctrl_down.* = pressed;
        return;
    }
    if (pressed) {
        const is_text = app_state.is_text.*;
        // Video: Spazio = play/pausa, ←/→ = seek ∓5 s (stile YouTube). ESC/F
        // cadono al comportamento comune (chiudi / fullscreen).
        if (app_state.video.isActive()) {
            const vid = app_state.video;
            if (key == KEY_SPACE) {
                app_state.mutex.lockUncancelable(app_state.io);
                vid.playing = !vid.playing;
                vid.idle_s = 0;
                app_state.mutex.unlock(app_state.io);
                return;
            } else if (key == KEY_RIGHT or key == KEY_LEFT) {
                app_state.mutex.lockUncancelable(app_state.io);
                var t = vid.pos_s + (if (key == KEY_RIGHT) @as(f64, 5) else -5);
                if (t < 0) t = 0;
                if (vid.dur_s > 0 and t > vid.dur_s - 0.1) t = vid.dur_s - 0.1;
                vid.seek_to = t;
                vid.idle_s = 0;
                app_state.mutex.unlock(app_state.io);
                return;
            }
        }
        // Ctrl+C: copia la selezione negli appunti.
        if (key == KEY_C and app_state.ctrl_down.* and is_text) {
            app_state.mutex.lockUncancelable(app_state.io);
            const sel = buildSelectedText(app_state, app_state.gpa);
            app_state.mutex.unlock(app_state.io);
            if (sel) |txt| {
                clipboard.copy(txt);
                app_state.gpa.free(txt);
            }
            return;
        }
        if (key == KEY_ESC) {
            win.close();
        } else if (is_text and (key == KEY_UP or key == KEY_DOWN)) {
            // Nei documenti le frecce verticali scorrono; ← → restano
            // la navigazione tra i file della cartella (parità con viewer).
            scrollText(app_state, if (key == KEY_DOWN) scroll_step else -scroll_step);
        } else if (is_text and (key == KEY_PGUP or key == KEY_PGDOWN)) {
            scrollText(app_state, if (key == KEY_PGDOWN) scroll_step * 10 else -scroll_step * 10);
        } else if (isPdfPath(app_state.current_file_path) and (key == KEY_UP or key == KEY_DOWN or key == KEY_PGUP or key == KEY_PGDOWN)) {
            const dir: i32 = if (key == KEY_DOWN or key == KEY_PGDOWN) 1 else -1;
            changePdfPage(app_state, dir);
        } else if (key == KEY_RIGHT or key == KEY_DOWN) {
            app_state.navigate(1);
        } else if (key == KEY_LEFT or key == KEY_UP) {
            app_state.navigate(-1);
        } else if (key == KEY_EQUAL) {
            applyZoom(app_state, 1.1);
        } else if (key == KEY_MINUS) {
            applyZoom(app_state, 1.0 / 1.1);
        } else if (key == KEY_F) {
            win.toggleFullscreen();
        } else if (key == KEY_V and app_state.is_mesh.*) {
            toggleVoxel(app_state);
        } else if (key == KEY_1) {
            win.setStyle(zrame.Style.fluent()) catch {};
        } else if (key == KEY_2) {
            win.setStyle(zrame.Style.macos()) catch {};
        } else if (key == KEY_3) {
            win.setStyle(zrame.Style.aurora()) catch {};
        } else if (key == KEY_4) {
            win.setStyle(zrame.Style.material()) catch {};
        } else if (key == KEY_5) {
            win.setStyle(zrame.Style.psy()) catch {};
        }
    }
}

fn scrollCallback(win: *zrame.Window, axis: u32, value: i32, user: ?*anyopaque) void {
    _ = win;
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    if (axis == 1) {
        // Asse orizzontale (trackpad/tilt-wheel): scorre le tabelle larghe.
        if (app_state.is_text.*) {
            const val = @as(f32, @floatFromInt(value)) / 256.0;
            scrollTextX(app_state, val * 5.0);
        }
        return;
    }
    if (axis == 0) {
        const val = @as(f32, @floatFromInt(value)) / 256.0;
        if (app_state.is_text.*) {
            // Shift+rotella = scroll orizzontale (per chi non ha rotella orizzontale).
            if (app_state.shift_down.*) {
                scrollTextX(app_state, val * 5.0);
                return;
            }
            // Documento: la rotella scorre (lo zoom testo resta su +/-)
            scrollText(app_state, val * 5.0);
            return;
        }
        if (val < 0) {
            applyZoom(app_state, 1.1);
        } else if (val > 0) {
            applyZoom(app_state, 1.0 / 1.1);
        }
    }
}

/// Ritorna true se zuer ha "consumato" l'evento: zrame allora salta le sue azioni
/// di default (spostamento/ridimensionamento finestra dal bordo, senza titlebar).
/// Così un click sulla scrollbar afferra il thumb invece di spostare la finestra.
fn mouseCallback(win: *zrame.Window, event: zrame.MouseEvent, user: ?*anyopaque) bool {
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return false));
    switch (event) {
        .button => |btn| {
            // 0x110 = BTN_LEFT (click sinistro), 0x111 = BTN_RIGHT (click destro)
            if (btn.button != 0x110 and btn.button != 0x111) return false;
            const down = (btn.state == 1);
            // Video: controlli overlay. Click sinistro su play/pausa o timeline;
            // il rilascio termina lo scrubbing. Click sul corpo → non consumato
            // (zrame muove/ridimensiona la finestra come al solito).
            if (app_state.video.isActive() and btn.button == 0x110) {
                const vid = app_state.video;
                if (!down) {
                    if (vid.scrubbing) {
                        app_state.mutex.lockUncancelable(app_state.io);
                        vid.scrubbing = false;
                        vid.idle_s = 0;
                        app_state.mutex.unlock(app_state.io);
                        return true;
                    }
                } else switch (videomod.videoControlsHit(win.panel_w, win.panel_h, app_state.last_x.*, app_state.last_y.*)) {
                    .toggle => {
                        app_state.mutex.lockUncancelable(app_state.io);
                        vid.playing = !vid.playing;
                        vid.idle_s = 0;
                        app_state.mutex.unlock(app_state.io);
                        return true;
                    },
                    .timeline => {
                        app_state.mutex.lockUncancelable(app_state.io);
                        vid.scrubbing = true;
                        vid.seek_to = videomod.videoTimelineFrac(win.panel_w, app_state.last_x.*) * (if (vid.dur_s > 0) vid.dur_s else 0);
                        vid.idle_s = 0;
                        app_state.mutex.unlock(app_state.io);
                        return true;
                    },
                    .none => {},
                }
            }
            if (!down) {
                app_state.mutex.lockUncancelable(app_state.io);
                _ = app_state.sc.onButtonUp();
                app_state.sel_selecting.* = false;
                // Click senza trascinamento (ancora == estremo) → deseleziona.
                if (app_state.sel_a.*[0] == app_state.sel_b.*[0] and app_state.sel_a.*[1] == app_state.sel_b.*[1]) {
                    app_state.sel_active.* = false;
                    app_state.file_changed.* = true;
                }
                app_state.dragging.* = false;
                app_state.mutex.unlock(app_state.io);
                return true;
            }
            // Click sinistro sulla barra delle linguette (in fondo): cambia foglio.
            if (btn.button == 0x110 and app_state.is_table.* and app_state.tab_bar.count > 0) {
                const H = win.panel_h;
                const tb = app_state.tab_bar;
                if (tb.h <= H and app_state.last_y.* >= @as(f32, @floatFromInt(H - tb.h))) {
                    const mx: u32 = @intFromFloat(@max(app_state.last_x.*, 0));
                    var idx: usize = 0;
                    while (idx < tb.count and mx >= tb.bounds[idx]) : (idx += 1) {}
                    if (idx < tb.count) {
                        app_state.mutex.lockUncancelable(app_state.io);
                        if (app_state.decoded.* == .workbook and app_state.decoded.workbook.active != idx) {
                            app_state.decoded.workbook.active = idx;
                            // Nuovo foglio: riparti dall'alto/sinistra e ri-rasterizza.
                            app_state.scroll_y.* = 0;
                            app_state.scroll_x.* = 0;
                            resetScroll(app_state.sc);
                            app_state.load_seq.* +%= 1;
                            app_state.file_changed.* = true;
                        }
                        app_state.mutex.unlock(app_state.io);
                    }
                    return true; // click sulla barra consumato (niente selezione)
                }
            }
            // Click sinistro: prima offri la pressione alla scrollbar (afferra il
            // thumb o salta sotto il cursore); se la consuma, niente selezione/drag.
            if (btn.button == 0x110) {
                app_state.mutex.lockUncancelable(app_state.io);
                const grabbed = app_state.sc.onButtonDown(app_state.last_x.*, app_state.last_y.*);
                if (grabbed) app_state.file_changed.* = true;
                app_state.mutex.unlock(app_state.io);
                if (grabbed) return true;
            }
            // Pressione sinistra sul testo: avvia la selezione — ma non troppo vicino al
            // bordo, dove (se il thumb non ha già afferrato sopra) lasciamo a zrame il
            // ridimensionamento della finestra. Senza questo, ogni click sul contenuto
            // consuma l'evento e la finestra risulta "fissa".
            if (btn.button == 0x110 and app_state.is_text.*) {
                const W = win.panel_w;
                const H = win.panel_h;
                const eb: f32 = 8.0; // banda resize di zrame (resizeEdgeAt)
                const rx = app_state.last_x.*;
                const ry = app_state.last_y.*;
                const near_edge = rx < eb or ry < eb or
                    rx > @as(f32, @floatFromInt(W)) - eb or
                    ry > @as(f32, @floatFromInt(H)) - eb;
                if (near_edge) {
                    app_state.dragging.* = down;
                    return false; // bordo libero: zrame ridimensiona
                }
                app_state.mutex.lockUncancelable(app_state.io);
                if (app_state.text_lines.items.len > 0) {
                    const hit = textHit(app_state, W, H, app_state.last_x.*, app_state.last_y.*);
                    app_state.sel_a.* = hit;
                    app_state.sel_b.* = hit;
                    app_state.sel_active.* = true;
                    app_state.sel_selecting.* = true;
                    app_state.file_changed.* = true;
                    app_state.mutex.unlock(app_state.io);
                    return true;
                }
                app_state.mutex.unlock(app_state.io);
            }
            app_state.dragging.* = down;
            // Non consumato: click nel contenuto senza elemento interattivo — lascia a
            // zrame l'eventuale move/resize dal bordo (comportamento di default).
            return false;
        },
        .motion => |mot| {
            // Video: ogni movimento rivela i controlli (azzera l'idle); durante lo
            // scrubbing il movimento cerca sulla timeline. Consuma solo mentre
            // scrubba, così sul corpo la finestra resta trascinabile/ridimensionabile.
            if (app_state.video.isActive()) {
                const vid = app_state.video;
                app_state.mutex.lockUncancelable(app_state.io);
                vid.idle_s = 0;
                const scrub = vid.scrubbing;
                if (scrub) vid.seek_to = videomod.videoTimelineFrac(win.panel_w, mot.x) * (if (vid.dur_s > 0) vid.dur_s else 0);
                app_state.mutex.unlock(app_state.io);
                app_state.last_x.* = mot.x;
                app_state.last_y.* = mot.y;
                return scrub;
            }
            // La scrollbar vede sempre il movimento: aggiorna hover/thumb e, se sta
            // trascinando il cursore, muove l'offset. Se lo consuma (sopra la barra o
            // in drag), non facciamo selezione/pan.
            app_state.mutex.lockUncancelable(app_state.io);
            const sc_consumed = app_state.sc.onMotion(mot.x, mot.y);
            if (sc_consumed) app_state.file_changed.* = true;
            app_state.mutex.unlock(app_state.io);
            if (sc_consumed) {
                app_state.last_x.* = mot.x;
                app_state.last_y.* = mot.y;
                return true;
            }
            if (app_state.sel_selecting.*) {
                app_state.mutex.lockUncancelable(app_state.io);
                app_state.sel_b.* = textHit(app_state, win.panel_w, win.panel_h, mot.x, mot.y);
                app_state.file_changed.* = true;
                app_state.mutex.unlock(app_state.io);
            } else if (app_state.dragging.*) {
                const dx = mot.x - app_state.last_x.*;
                const dy = mot.y - app_state.last_y.*;
                if (app_state.is_mesh.*) {
                    app_state.yaw.* += dx * 0.01;
                    app_state.pitch.* += dy * 0.01;
                } else if (app_state.is_text.*) {
                    // Fallback (testo senza righe selezionabili, es. percorso GPU):
                    // il trascinamento scorre il documento.
                    scrollTo(app_state, app_state.scroll_y.* - dy);
                } else {
                    app_state.mutex.lockUncancelable(app_state.io);
                    app_state.pan_x.* += dx;
                    app_state.pan_y.* += dy;
                    app_state.file_changed.* = true;
                    app_state.mutex.unlock(app_state.io);
                }
            }
            app_state.last_x.* = mot.x;
            app_state.last_y.* = mot.y;
            // Consuma il movimento mentre selezioni/trascini, così zrame non mostra il
            // cursore di resize sul bordo durante l'interazione.
            return app_state.sel_selecting.* or app_state.dragging.*;
        },
        .leave => {
            // Puntatore fuori dalla finestra: spegni l'hover della scrollbar (fade)
            // e dimentica l'ultima posizione così un click successivo non parte da
            // coordinate stantie.
            app_state.mutex.lockUncancelable(app_state.io);
            app_state.sc.onLeave();
            app_state.file_changed.* = true;
            app_state.mutex.unlock(app_state.io);
            app_state.last_x.* = -1;
            app_state.last_y.* = -1;
            return false;
        },
    }
}

/// Libera il testo per-riga trattenuto per la selezione.
fn freeTextLines(state: *GuiAppState) void {
    for (state.text_lines.items) |l| state.gpa.free(l);
    state.text_lines.clearRetainingCapacity();
}

/// Rasterizza il contenuto testuale corrente alla larghezza richiesta e al
/// corpo scalato dallo zoom, sostituendo il buffer statico RGBA.
/// Da chiamare con `state.mutex` già acquisito.
fn rasterizeText(state: *GuiAppState, width: u32, text_zoom: f32) void {
    const pointsize: usize = @intFromFloat(@round(15.0 * text_zoom));
    const opts = text_render.RenderOpts{ .width = @max(width, 64), .pointsize = @max(pointsize, 6) };
    const name = std.fs.path.basename(state.current_file_path);

    if (native and state.text_gpu) {
        rasterizeTextGpu(state, name, opts);
        return;
    }

    // La geometria (wrapping) cambia con larghezza/zoom: la vecchia selezione
    // non è più valida.
    freeTextLines(state);
    state.sel_active.* = false;
    state.sel_selecting.* = false;

    var img = text_render.renderDoc(state.gpa, state.decoded, name, opts, state.text_lines, state.text_metrics) catch |err| {
        std.debug.print("Impossibile rasterizzare il testo: {s}\n", .{@errorName(err)});
        return;
    };
    defer img.deinit(state.gpa);

    const w: u32 = @intCast(img.width);
    const h: u32 = @intCast(img.height);
    const rgba = state.gpa.alloc(u8, @as(usize, w) * h * 4) catch return;
    for (0..@as(usize, w) * h) |i| {
        rgba[i * 4 + 0] = img.pixels[i * 3 + 0];
        rgba[i * 4 + 1] = img.pixels[i * 3 + 1];
        rgba[i * 4 + 2] = img.pixels[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
    }

    state.gpa.free(state.static_rgba.*);
    state.static_rgba.* = rgba;
    state.static_w.* = w;
    state.static_h.* = h;

    rasterizeTabBar(state, width);
}

/// (Ri)genera la barra delle linguette per un workbook, alla larghezza corrente.
/// Non-workbook → azzera la barra (nessuna linguetta). Immagine RGB → RGBA opaca.
/// Da chiamare con `state.mutex` acquisito (come `rasterizeText`).
fn rasterizeTabBar(state: *GuiAppState, width: u32) void {
    const tb = state.tab_bar;
    if (state.decoded.* != .workbook) {
        tb.count = 0;
        return;
    }
    const wb = &state.decoded.workbook;
    var img = text_render.renderTabBar(state.gpa, wb.sheets, wb.active, @max(width, 64), &tb.bounds) catch {
        tb.count = 0;
        return;
    };
    defer img.deinit(state.gpa);

    const tw: u32 = @intCast(img.width);
    const th: u32 = @intCast(img.height);
    const rgba = state.gpa.alloc(u8, @as(usize, tw) * th * 4) catch {
        tb.count = 0;
        return;
    };
    for (0..@as(usize, tw) * th) |i| {
        rgba[i * 4 + 0] = img.pixels[i * 3 + 0];
        rgba[i * 4 + 1] = img.pixels[i * 3 + 1];
        rgba[i * 4 + 2] = img.pixels[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
    }
    state.gpa.free(tb.rgba);
    tb.rgba = rgba;
    tb.w = tw;
    tb.h = th;
    tb.count = @min(wb.sheets.len, max_tabs);
}

/// Percorso GPU (Soluzione B): costruisce i quad glifo + atlante e li renderizza
/// con la pipeline testo Vulkan, poi copia i pixel RGBA nel buffer statico.
fn rasterizeTextGpu(state: *GuiAppState, name: []const u8, opts: text_render.RenderOpts) void {
    var mesh = text_render.buildTextMesh(state.gpa, state.decoded, name, opts) catch |err| {
        std.debug.print("Impossibile costruire i quad del testo: {s}\n", .{@errorName(err)});
        return;
    };
    defer mesh.deinit(state.gpa);

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
        std.debug.print("Render testo GPU fallito: {s}\n", .{@errorName(err)});
        return;
    };

    // Il readback è riusato dalla chiamata successiva: copiane una proprietà.
    const rgba = state.gpa.dupe(u8, rgba_src) catch return;
    state.gpa.free(state.static_rgba.*);
    state.static_rgba.* = rgba;
    state.static_w.* = @intCast(mesh.width);
    state.static_h.* = @intCast(mesh.height);
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

/// Zoom "contain": scala il frame così che stia interamente nella finestra
/// mantenendo l'aspetto (il lato limitante tocca il bordo).
fn fitZoom(cw: u32, ch: u32, sw: u32, sh: u32) f32 {
    if (sw == 0 or sh == 0) return 1.0;
    const fcw: f32 = @floatFromInt(cw);
    const fch: f32 = @floatFromInt(ch);
    return @min(fcw / @as(f32, @floatFromInt(sw)), fch / @as(f32, @floatFromInt(sh)));
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
    yaw: *const f32,
    pitch: *const f32,
    zoom: *const f32,
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

    // La primitiva scrollbar `state.sc` è condivisa coi callback input: qui la si usa
    // solo entro il lock del mutex (già preso attorno alla sezione compose).
    // Secondi trascorsi dall'ultimo frame presentato (dal Pacer a fine loop); guida
    // fade/hover/kinetica delle scrollbar. Primo giro: stima a 1/60.
    var frame_dt: f32 = 1.0 / 60.0;

    while (!win.closed) {
        const cur_w = win.panel_w;
        const cur_h = win.panel_h;
        if (cur_w == 0 or cur_h == 0) {
            // Clamp: alternando pacer_60/pacer_20 quello inattivo ha `last` vecchio e
            // restituisce un dt enorme al primo tick → il fade delle barre scatterebbe.
            frame_dt = @min(0.1, @as(f32, @floatCast(pacer_20.tick())));
            continue;
        }

        state.mutex.lockUncancelable(state.io);

        // Traccia da quanto dura il caricamento per la soglia anti-flash.
        const now_loading = state.loading.*;
        if (now_loading and !was_loading) load_elapsed = 0;
        load_elapsed = if (now_loading) load_elapsed + frame_dt else 0;
        was_loading = now_loading;

        // Caricamento in corso da oltre la soglia: anima lo spinner a 60 Hz finché
        // `applyDecoded` non azzera il flag. Sotto soglia si prosegue mostrando il
        // contenuto precedente (niente lampeggio del loader sui file veloci).
        if (now_loading and load_elapsed >= 0.12) {
            if (composited_rgba.len < cur_w * cur_h * 4) {
                state.gpa.free(composited_rgba.*);
                // 4-byte aligned: la fase di compose lo rilegge come []u32 per il
                // Canvas straight di zicro (scrollbar).
                composited_rgba.* = state.gpa.alignedAlloc(u8, .@"4", cur_w * cur_h * 4) catch {
                    state.mutex.unlock(state.io);
                    break;
                };
            }
            drawLoader(composited_rgba.*, cur_w, cur_h, spin_frame);
            win.presentRgba(cur_w, cur_h, composited_rgba.*);
            state.mutex.unlock(state.io);
            spin_frame +%= 1;
            _ = pacer_60.tick();
            continue;
        }

        // Video: percorso a sé (come lo spinner). Guida la riproduzione in tempo
        // reale (accumulo di `frame_dt`), compone il frame corrente e vi disegna
        // sopra i controlli overlay stile YouTube, poi presenta e ricomincia.
        // `has_video` only: the player is libav-backed, gated out when video is off.
        if (has_video and state.video.isActive()) {
            const vs = state.video;
            if (composited_rgba.len < cur_w * cur_h * 4) {
                state.gpa.free(composited_rgba.*);
                composited_rgba.* = state.gpa.alignedAlloc(u8, .@"4", cur_w * cur_h * 4) catch {
                    state.mutex.unlock(state.io);
                    break;
                };
            }
            const new_frame = videomod.advanceVideo(.{
                .gpa = state.gpa,
                .rgba = state.static_rgba,
                .w = state.static_w,
                .h = state.static_h,
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
            const size_ch = (cur_w != vid_pw or cur_h != vid_ph);
            const ctrl_ch = @abs(vs.controls - vid_prev_ctrl) > 0.002;
            if (new_frame or size_ch or ctrl_ch or vs.scrubbing) {
                // Letterbox trasparente (vetro) + frame scalato per adattarsi.
                @memset(composited_rgba.*[0 .. @as(usize, cur_w) * cur_h * 4], 0);
                const fit = fitZoom(cur_w, cur_h, state.static_w.*, state.static_h.*);
                compose.composeFrame(composited_rgba.*, cur_w, cur_h, state.static_rgba.*, state.static_w.*, state.static_h.*, false, fit, 0.0, 0.0);
                if (vs.controls > 0.01) videomod.drawVideoControls(composited_rgba.*, cur_w, cur_h, vs);
                if (name_raster) |*r| drawFilenameLabel(composited_rgba.*, cur_w, cur_h, r, std.fs.path.basename(state.current_file_path));
                win.presentRgba(cur_w, cur_h, composited_rgba.*);
                vid_pw = cur_w;
                vid_ph = cur_h;
                vid_prev_ctrl = vs.controls;
            }
            state.mutex.unlock(state.io);
            // 60 Hz mentre riproduce, scrubba o l'alpha dei controlli anima; a
            // riposo (in pausa, controlli fermi) 20 Hz per non scaldare la CPU.
            const busy = vs.playing or vs.scrubbing or ctrl_ch;
            frame_dt = @min(0.1, @as(f32, @floatCast(if (busy) pacer_60.tick() else pacer_20.tick())));
            continue;
        }

        const size_changed = (cur_w != last_w or cur_h != last_h);
        // La mesh va ridisegnata solo se la camera è cambiata (drag/zoom).
        const mesh_moved = state.is_mesh.* and
            (yaw.* != last_yaw or pitch.* != last_pitch or zoom.* != last_zoom);
        var need_render = size_changed or state.file_changed.* or mesh_moved;
        // Un cambio contenuto arma qualche present di rinforzo (vedi present_pulse).
        if (state.file_changed.*) present_pulse = 4;
        if (present_pulse > 0) need_render = true;
        var text_animating = false;

        if (state.is_text.*) {
            // (Ri)compone il testo quando cambiano larghezza finestra, zoom o
            // file: un solo tentativo per cambio di parametri (evita di ripetere
            // il layout a 20 Hz se qualcosa fallisce in modo persistente).
            const tz = std.math.clamp(zoom.*, text_zoom_min, text_zoom_max);
            if (last_text_w != cur_w or last_text_zoom != tz or last_seq != state.load_seq.*) {
                rasterizeText(state, cur_w, tz);
                last_text_w = cur_w;
                last_text_zoom = tz;
                last_seq = state.load_seq.*;
                need_render = true;
            }
            // La scrollbar flottante egui possiede l'offset di scroll: la geometria
            // viene da viewport (finestra) e contenuto (testo rasterizzato); `tick`
            // applica rotella/tasti smussati + fade + kinetica di `dt` e clampa. Poi
            // rispecchiamo l'offset in scroll_y/scroll_x per compose/selezione/header.
            // Wheel/click/motion sono instradati alla primitiva dai callback (sotto lock).
            state.sc.setViewport(.{ .x = 0, .y = 0, .w = @floatFromInt(cur_w), .h = @floatFromInt(cur_h) });
            state.sc.setContent(@floatFromInt(state.static_w.*), @floatFromInt(state.static_h.*));
            if (state.sc.tick(frame_dt)) {
                need_render = true;
                text_animating = true;
            }
            state.scroll_y.* = state.sc.scrollY();
            state.scroll_x.* = state.sc.scrollX();
        }

        if (need_render) {
            state.file_changed.* = false;
            last_w = cur_w;
            last_h = cur_h;

            if (composited_rgba.len < cur_w * cur_h * 4) {
                state.gpa.free(composited_rgba.*);
                // 4-byte aligned: rilettura come []u32 per il Canvas straight (scrollbar).
                composited_rgba.* = state.gpa.alignedAlloc(u8, .@"4", cur_w * cur_h * 4) catch {
                    state.mutex.unlock(state.io);
                    break;
                };
            }

            if (native and state.is_mesh.*) {
                // Modalità voxel (tasto V): ray-march della griglia invece della
                // mesh triangolata. Altrimenti pipeline PBR normale.
                const mesh_rgba = if (state.voxel_mode.* and state.renderer.hasVoxels()) rv: {
                    const vpc = gpu.buildVoxelPush(state.mesh_center.*, state.mesh_max_size.* / zoom.*, yaw.*, pitch.*, cur_w, cur_h, state.voxel_bbox_min.*, state.voxel_bbox_size.*, state.voxel_dim.*);
                    break :rv state.renderer.renderVoxel(cur_w, cur_h, &vpc) catch {
                        state.mutex.unlock(state.io);
                        break;
                    };
                } else rm: {
                    state.renderer.vt_zoom = zoom.*; // pilota il mip dinamico delle texture virtuali
                    const pc = gpu.buildPushConstants(state.mesh_center.*, state.mesh_max_size.* / zoom.*, yaw.*, pitch.*, cur_w, cur_h, state.mesh_material.*);
                    break :rm state.renderer.render(cur_w, cur_h, &pc) catch {
                        state.mutex.unlock(state.io);
                        break;
                    };
                };
                compose.composeFrame(composited_rgba.*, cur_w, cur_h, mesh_rgba, cur_w, cur_h, false, 1.0, 0.0, 0.0);
                last_yaw = yaw.*;
                last_pitch = pitch.*;
                last_zoom = zoom.*;
            } else if (state.is_text.*) {
                // Tabelle: àncora la banda header (top padding + riga intestazione)
                // in cima durante lo scroll verticale. Clampata all'altezza finestra.
                const header_band: u32 = if (state.is_table.*) blk: {
                    const m = state.text_metrics.*;
                    const hb = m.pad_y + m.line_h;
                    break :blk if (hb > 0) @min(@as(u32, @intCast(hb)), cur_h) else 0;
                } else 0;
                compose.composeTextFrame(composited_rgba.*, cur_w, cur_h, state.static_rgba.*, state.static_w.*, state.static_h.*, state.scroll_y.*, state.scroll_x.*, header_band);
                if (state.sel_active.*) {
                    compose.drawTextSelection(composited_rgba.*, cur_w, cur_h, state.static_w.*, state.static_h.*, state.scroll_y.*, state.scroll_x.*, state.text_metrics.*, state.text_lines.items, state.sel_a.*, state.sel_b.*);
                }
                // Scrollbar flottanti egui, disegnate dal Canvas straight di zicro
                // direttamente sul frame RGBA8 (rilettura []u8 → []u32 aliasata).
                const buf = composited_rgba.*;
                const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
                var sc_canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, cur_w) * cur_h], cur_w, cur_h);
                state.sc.draw(&sc_canvas);
                // Barra delle linguette in fondo (workbook multi-foglio), sopra tutto.
                compose.blitTabBar(composited_rgba.*, cur_w, cur_h, state.tab_bar);
            } else {
                compose.composeFrame(composited_rgba.*, cur_w, cur_h, state.static_rgba.*, state.static_w.*, state.static_h.*, false, zoom.*, state.pan_x.*, state.pan_y.*);
            }

            // Nome file in alto a destra (monospazio), sopra ogni contenuto.
            if (name_raster) |*r| drawFilenameLabel(composited_rgba.*, cur_w, cur_h, r, std.fs.path.basename(state.current_file_path));

            win.presentRgba(cur_w, cur_h, composited_rgba.*);
            if (present_pulse > 0) present_pulse -= 1;
        }

        state.mutex.unlock(state.io);

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

/// Costruisce il testo selezionato (righe unite da '\n'). Con `state.mutex`
/// acquisito. Ritorna null se non c'è selezione; il chiamante libera il buffer.
fn buildSelectedText(state: *GuiAppState, gpa: std.mem.Allocator) ?[]u8 {
    if (!state.sel_active.*) return null;
    const lines = state.text_lines.items;
    if (lines.len == 0) return null;
    var a = state.sel_a.*;
    var b = state.sel_b.*;
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

/// Risolve l'argomento iniziale in un percorso di file. Se `arg` è una CARTELLA,
/// restituisce il primo file al suo interno (ordine alfabetico) — così invocando
/// zuer su una cartella si apre una preview navigabile con le frecce (initFileList
/// popola la lista con gli altri file). Se `arg` è già un file, lo duplica. Il
/// chiamante possiede e libera la stringa restituita.
fn resolveInitialFile(io: std.Io, gpa: std.mem.Allocator, arg: []const u8) !?[]u8 {
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Comunica ai plugin decoder che siamo in modalità GUI (quindi vogliamo la massima risoluzione possibile)
    setEnvVar("ZUER_GUI", "1");

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    defer decoder_mod.closePluginCache(gpa);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const arg_path = args.next() orelse {
        std.debug.print("Uso: zuer-gui <file|cartella>\n", .{});
        std.process.exit(1);
    };
    // Se l'argomento è una cartella, apri il primo file: la navigazione con le
    // frecce (e il prefetch) permette di sfogliare tutti i file della cartella.
    const file_path = (resolveInitialFile(io, gpa, arg_path) catch |e| {
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
    var loading = isPdfPath(file_path);
    if (std.Io.Dir.cwd().statFile(io, clean_path, .{})) |st| {
        if (st.size >= loader_threshold_mb * 1024 * 1024) loading = true;
    } else |_| {}

    // Contenuto decodificato: parte come testo vuoto (placeholder, deinit no-op)
    // e viene sostituito da `applyDecoded` — sul thread di decodifica o qui sotto.
    var decoded: decoder_mod.Decoded = .{ .text = "" };
    defer decoded.deinit(gpa);
    var is_text = true;
    var is_mesh = false;
    var is_table = false;
    var tab_bar: TabBarState = .{};
    defer gpa.free(tab_bar.rgba);

    var stage_opt: ?loader_mod.GpuStage = null;
    defer if (stage_opt) |*s| s.buffer.deinit(gpa);

    // Renderer Vulkan Offscreen (nessuna estensione swapchain WSI richiesta). Solo con
    // rendering nativo: su build CPU-only resta `undefined` e non viene mai usato (tutti
    // i suoi call site sono esclusi a comptime da `native`).
    var renderer: gpu.Renderer = undefined;
    if (native) renderer = try gpu.Renderer.init(gpa, .{});
    defer if (native) renderer.deinit();

    var mesh_center: [3]f32 = .{ 0, 0, 0 };
    var mesh_max_size: f32 = 1;
    var mesh_material: gpu.Material = .{};
    var voxel_mode = false;
    var voxel_bbox_min: [3]f32 = .{ 0, 0, 0 };
    var voxel_bbox_size: [3]f32 = .{ 1, 1, 1 };
    var voxel_dim: u32 = 0;

    var static_rgba: []u8 = &.{};
    defer gpa.free(static_rgba);
    var static_w: u32 = 0;
    var static_h: u32 = 0;

    var video: videomod.VideoState = .{};
    defer if (has_video) video.deinit();

    var state_mutex: std.Io.Mutex = .init;
    var load_seq: u32 = 1;
    var file_changed = false;
    var zoom: f32 = 1.0;
    var yaw: f32 = 0;
    var pitch: f32 = 0;
    var pan_x: f32 = 0;
    var pan_y: f32 = 0;
    var scroll_y: f32 = 0;
    var scroll_x: f32 = 0;
    // Scrollbar flottanti egui: proprietarie di offset/kinetica/drag (vedi GuiAppState.sc).
    var sc_scroll: zscroll.Scroll = .{};
    var dragging = false;
    // -1 = puntatore ancora fuori: tiene nascoste le scrollbar flottanti finché il
    // puntatore non entra davvero (0,0 sarebbe già "dentro" e le mostrerebbe subito).
    var last_x: f32 = -1;
    var last_y: f32 = -1;
    var text_lines: std.ArrayList([]const u8) = .empty;
    var text_metrics: text_render.Metrics = .{ .advance = 1, .line_h = 1, .pad_x = 20, .pad_y = 14 };
    var sel_active = false;
    var sel_selecting = false;
    var sel_a: [2]i32 = .{ 0, 0 };
    var sel_b: [2]i32 = .{ 0, 0 };
    var ctrl_down = false;
    var shift_down = false;

    // Stato del prefetch dei file adiacenti (vedi prefetchWorker).
    var pf_mutex: std.Io.Mutex = .init;
    var pf_cond: std.Io.Condition = .init;
    var pf_cache: std.StringHashMapUnmanaged(Prefetched) = .empty;
    var pf_want: [2]?[]u8 = .{ null, null };
    var pf_stop: bool = false;
    var pf_dirty: bool = false;

    // Stato del loader thread della navigazione async (vedi loadWorker/postLoad).
    var ld_mutex: std.Io.Mutex = .init;
    var ld_cond: std.Io.Condition = .init;
    var ld_req: ?[]u8 = null;
    var ld_gen: u32 = 0;
    var ld_stop: bool = false;

    var gui_state = GuiAppState{
        .gpa = gpa,
        .io = io,
        .mutex = &state_mutex,
        .current_file_path = try gpa.dupe(u8, file_path),
        .file_list = .empty,
        .current_file_index = null,
        .decoded = &decoded,
        .stage_opt = &stage_opt,
        .renderer = &renderer,
        .text_gpu = text_gpu: {
            if (!native) break :text_gpu false; // GPU text needs the Vulkan renderer
            if (getenv("ZUER_TEXT_ENGINE")) |v| break :text_gpu std.mem.eql(u8, std.mem.span(v), "gpu");
            break :text_gpu false;
        },
        .video = &video,
        .is_mesh = &is_mesh,
        .is_text = &is_text,
        .is_table = &is_table,
        .tab_bar = &tab_bar,
        .file_changed = &file_changed,
        .loading = &loading,
        .load_seq = &load_seq,
        .zoom = &zoom,
        .static_rgba = &static_rgba,
        .static_w = &static_w,
        .static_h = &static_h,
        .mesh_center = &mesh_center,
        .mesh_max_size = &mesh_max_size,
        .mesh_material = &mesh_material,
        .voxel_mode = &voxel_mode,
        .voxel_bbox_min = &voxel_bbox_min,
        .voxel_bbox_size = &voxel_bbox_size,
        .voxel_dim = &voxel_dim,
        .dragging = &dragging,
        .yaw = &yaw,
        .pitch = &pitch,
        .pan_x = &pan_x,
        .pan_y = &pan_y,
        .scroll_y = &scroll_y,
        .scroll_x = &scroll_x,
        .sc = &sc_scroll,
        .last_x = &last_x,
        .last_y = &last_y,
        .text_lines = &text_lines,
        .text_metrics = &text_metrics,
        .sel_active = &sel_active,
        .sel_selecting = &sel_selecting,
        .sel_a = &sel_a,
        .sel_b = &sel_b,
        .ctrl_down = &ctrl_down,
        .shift_down = &shift_down,
        .pf_mutex = &pf_mutex,
        .pf_cond = &pf_cond,
        .pf_cache = &pf_cache,
        .pf_want = &pf_want,
        .pf_stop = &pf_stop,
        .pf_dirty = &pf_dirty,
        .ld_mutex = &ld_mutex,
        .ld_cond = &ld_cond,
        .ld_req = &ld_req,
        .ld_gen = &ld_gen,
        .ld_stop = &ld_stop,
    };
    defer {
        gpa.free(gui_state.current_file_path);
        for (gui_state.file_list.items) |f| gpa.free(f);
        gui_state.file_list.deinit(gpa);
        for (text_lines.items) |l| gpa.free(l);
        text_lines.deinit(gpa);
        // Svuota la cache di prefetch e i percorsi desiderati.
        var pit = pf_cache.iterator();
        while (pit.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        pf_cache.deinit(gpa);
        for (pf_want) |w| if (w) |x| gpa.free(x);
    }
    try gui_state.initFileList();

    // File piccolo: decodifica sincrona prima di creare la finestra, così può
    // dimensionarsi sull'immagine. I file grandi restano placeholder (spinner)
    // e vengono decodificati sul thread di background più sotto.
    if (!loading) {
        var d = decoder_mod.decode(file_path, io, gpa);
        if (d == .err) {
            std.debug.print("Errore: {s}\n", .{d.err});
            d.deinit(gpa);
            std.process.exit(1);
        }
        gui_state.applyDecoded(d, null, file_path) catch |e| {
            std.debug.print("Errore inizializzazione file: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
    }

    var composited_rgba: []u8 = &.{};
    defer gpa.free(composited_rgba);

    // Proporzioni intelligenti per tipo di contenuto: nel percorso sincrono il
    // tipo è già noto dal decoded; in quello async (spinner) si stima
    // dall'estensione, così la finestra nasce già con la forma giusta.
    const win_kind: WinKind = if (loading) layout.winKindFromExt(file_path) else layout.winKindFromDecoded(&decoded);

    // Video: apri il player nativo (libav) e usa il primo frame come poster
    // iniziale. Niente decode async/spinner — aprire il container è veloce — così
    // il worker parte già in riproduzione. `static_rgba` diventa il frame corrente
    // che il worker aggiorna nel tempo (vedi il ramo video di renderWorker).
    if (has_video and win_kind == .video) {
        loading = false;
        is_text = false;
        if (videomod.setupVideo(&video, file_path, gpa)) |first| {
            static_rgba = first.rgba;
            static_w = first.w;
            static_h = first.h;
        } else |e| {
            std.debug.print("Video non apribile ({s})\n", .{@errorName(e)});
        }
    }
    // Per le tabelle (percorso sincrono) la finestra si dimensiona sulla larghezza
    // reale delle colonne, non su un valore fisso.
    var tbl_w: u32 = 0;
    var tbl_h: u32 = 0;
    if (!loading and (decoded == .csv or decoded == .workbook)) {
        const opts0 = text_render.RenderOpts{ .width = 1280, .pointsize = 15 };
        const csv0 = switch (decoded) {
            .csv => |c| c,
            .workbook => |w| w.activeCsv(),
            else => unreachable,
        };
        if (text_render.tableNaturalSize(gpa, csv0, opts0)) |ns| {
            tbl_w = @intCast(ns.w);
            tbl_h = @intCast(ns.h);
        } else |_| {}
    }
    const size_w = if (win_kind == .table) tbl_w else static_w;
    const size_h = if (win_kind == .table) tbl_h else static_h;
    // Contenuto piccolo → zoom iniziale un po' più grande, finestra aderente al
    // contenuto zoomato (stessa euristica della navigazione).
    zoom = layout.autoZoomForContent(win_kind, size_w, size_h);
    const win_size = layout.initialWindowSize(win_kind, layout.scaleDim(size_w, zoom), layout.scaleDim(size_h, zoom));
    const win = try zrame.Window.init(gpa, .{
        .title = "zuer-gui",
        .app_id = "it.zuer.gui",
        .width = win_size.w,
        .height = win_size.h,
        .on_key = keyCallback,
        .on_scroll = scrollCallback,
        .on_mouse = mouseCallback,
        .user = &gui_state,
        .style = zrame.Style.fluent(),
    });
    defer win.deinit();
    // La navigazione con le frecce usa la finestra per animare il resize sul
    // contenuto. Impostata prima di `win.run()` (dove partono le callback).
    gui_state.win = win;

    // Spawna il thread lavoratore per il rendering offscreen e compositing
    const thread = try std.Thread.spawn(.{}, renderWorker, .{ win, &gui_state, &composited_rgba, &yaw, &pitch, &zoom });
    defer thread.join();

    // File grande/PDF iniziale: decodifica su un thread di background mentre il
    // worker mostra lo spinner. Va gioinato prima dei defer che liberano lo stato.
    var decode_thread: ?std.Thread = null;
    if (loading) {
        decode_thread = try std.Thread.spawn(.{}, decodeInitial, .{ &gui_state, file_path });
    }
    defer if (decode_thread) |t| t.join();

    // Thread di prefetch dei file adiacenti (navigazione istantanea). Il suo
    // defer è registrato DOPO quello che libera la cache → viene eseguito PRIMA:
    // il thread è fermato e gioinato prima che la cache venga distrutta.
    const prefetch_thread = try std.Thread.spawn(.{}, prefetchWorker, .{&gui_state});
    defer {
        pf_mutex.lockUncancelable(io);
        pf_stop = true;
        pf_mutex.unlock(io);
        pf_cond.signal(io);
        prefetch_thread.join();
    }

    // Loader thread della navigazione async (cache-miss): fermato e gioinato prima
    // che lo stato condiviso venga distrutto (defer registrato dopo → esegue prima).
    const load_thread = try std.Thread.spawn(.{}, loadWorker, .{&gui_state});
    defer {
        ld_mutex.lockUncancelable(io);
        ld_stop = true;
        ld_mutex.unlock(io);
        ld_cond.signal(io);
        load_thread.join();
        if (ld_req) |x| gpa.free(x);
    }
    // Percorso sincrono: il file iniziale è già pronto → precarica subito i
    // vicini. (Nel percorso async lo fa `decodeInitial` dopo aver installato
    // il contenuto, per non decodificare in parallelo al decode iniziale.)
    if (!loading) gui_state.schedulePrefetchAround();

    try win.run();
}

/// Thread loader: attende richieste (`postLoad`) e decodifica il file più recente
/// (latest-wins) fuori dal thread di input, installandolo con `applyDecoded`
/// (che spegne lo spinner). Sugli errori mostra il messaggio come testo.
/// Decodifica il file iniziale su un thread di background e lo installa nello
/// stato quando è pronto (azzerando lo spinner via `applyDecoded`). Sugli errori
/// mostra il messaggio come testo nella finestra invece di terminare il processo.
fn decodeInitial(state: *GuiAppState, path: []const u8) void {
    // Fase 1 (progressiva): se la cache texture coarse è calda (riapertura), una
    // resa a bassa risoluzione quasi istantanea; poi la fase 2 raffina a pieno.
    // decodeCoarse ritorna null se il formato non la supporta, o .err se la cache
    // è fredda (prima apertura) → in entrambi i casi si salta alla fase full.
    if (decoder_mod.decodeCoarse(path, state.io, state.gpa)) |coarse| {
        if (coarse == .mesh)
            state.applyDecoded(coarse, null, path) catch |e|
                std.debug.print("apply coarse: {s}\n", .{@errorName(e)})
        else {
            var c = coarse;
            c.deinit(state.gpa);
        }
    }

    var d = decoder_mod.decode(path, state.io, state.gpa);
    if (d == .err) {
        const msg: []const u8 = std.fmt.allocPrint(state.gpa, "Errore nel caricamento del file:\n{s}", .{d.err}) catch "";
        d.deinit(state.gpa);
        state.applyDecoded(.{ .text = msg }, null, path) catch {};
        return;
    }
    state.applyDecoded(d, null, path) catch |e|
        std.debug.print("Impossibile applicare il file decodificato: {s}\n", .{@errorName(e)});
    // Contenuto iniziale pronto: precarica i vicini per una navigazione fluida.
    state.schedulePrefetchAround();
}

/// Thread di caricamento asincrono della navigazione: attende le richieste di
/// `postLoad` (cache-miss), decodifica fuori dal thread finestra e installa il
/// risultato con `applyDecoded` (che spegne lo spinner) + resize + prefetch.
/// Latest-wins: se nel frattempo è arrivata una richiesta più recente (`ld_gen`
/// cambiato) scarta il risultato — la nuova verrà processata al giro dopo.
fn loadWorker(state: *GuiAppState) void {
    const io = state.io;
    const gpa = state.gpa;
    while (true) {
        state.ld_mutex.lockUncancelable(io);
        while (!state.ld_stop.* and state.ld_req.* == null)
            state.ld_cond.waitUncancelable(io, state.ld_mutex);
        if (state.ld_stop.*) {
            state.ld_mutex.unlock(io);
            break;
        }
        const path = state.ld_req.*.?;
        state.ld_req.* = null;
        const gen = state.ld_gen.*;
        state.ld_mutex.unlock(io);
        defer gpa.free(path);

        // Spam di frecce: se è GIÀ arrivata una navigazione più recente, salta
        // questa per intero (niente decode né upload) → la più recente verrà presa
        // al giro dopo. Evita di impegnare il worker su modelli oltrepassati.
        if (state.navSuperseded(gen)) continue;

        // Fase 1 progressiva: se la cache mesh coarse è calda (già visto), una resa
        // blurry quasi istantanea → tornando a un modello con le frecce lo spinner
        // si ferma subito invece di attendere il decode full. Se superata nel
        // frattempo o non disponibile, si scarta.
        if (decoder_mod.decodeCoarse(path, io, gpa)) |coarse| {
            if (!state.navSuperseded(gen) and coarse == .mesh)
                state.applyDecoded(coarse, null, path) catch |e|
                    std.debug.print("apply coarse (async): {s}\n", .{@errorName(e)})
            else {
                var c = coarse;
                c.deinit(gpa);
            }
        }

        // Prima del full decode (l'operazione più costosa, ~secondi): se nel
        // frattempo l'utente ha già navigato oltre, saltalo e vai alla più recente.
        // È qui che si evita il "si impalla" dello spam frecce.
        if (state.navSuperseded(gen)) continue;

        // Decode CPU fuori da ogni lock.
        var d = decoder_mod.decode(path, io, gpa);

        // Superseded da una navigazione più recente? scarta (la più nuova arriverà).
        if (state.navSuperseded(gen)) {
            d.deinit(gpa);
            continue;
        }

        if (d == .err) {
            const msg: []const u8 = std.fmt.allocPrint(gpa, "Errore nel caricamento del file:\n{s}", .{d.err}) catch "";
            d.deinit(gpa);
            state.applyDecoded(.{ .text = msg }, null, path) catch {};
        } else {
            state.applyDecoded(d, null, path) catch |e|
                std.debug.print("Impossibile applicare il file (async): {s}\n", .{@errorName(e)});
        }
        state.resizeToContent();
        state.schedulePrefetchAround();
    }
}

/// Thread di prefetch: decodifica (e stage-a, se mesh) i file vicini indicati da
/// `pf_want` nella cache `pf_cache`, evitando quelli già presenti ed evincendo
/// quelli non più desiderati (cache limitata ai 2 vicini). Fa SOLO decode+stage
/// (CPU/memfd): non tocca mai il renderer né lo stato condiviso della finestra.
fn prefetchWorker(state: *GuiAppState) void {
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
        state.pf_mutex.lockUncancelable(io);
        // Attende una richiesta NUOVA (pf_dirty), non la semplice presenza di
        // vicini desiderati: pf_want è persistente e resterebbe sempre non-null,
        // facendo girare il worker a vuoto. Consuma il flag qui sotto il lock.
        while (!state.pf_stop.* and !state.pf_dirty.*)
            state.pf_cond.waitUncancelable(io, state.pf_mutex);
        if (state.pf_stop.*) {
            state.pf_mutex.unlock(io);
            break;
        }
        state.pf_dirty.* = false;
        var want: [2]?[]u8 = .{ null, null };
        for (&want, state.pf_want) |*w, src| w.* = if (src) |s| (gpa.dupe(u8, s) catch null) else null;
        // Evince dalla cache tutto ciò che non è più tra i vicini desiderati.
        var it = state.pf_cache.iterator();
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
            if (state.pf_cache.fetchRemove(k)) |kv| {
                var v = kv.value;
                v.deinit(gpa);
                gpa.free(kv.key);
            }
        }
        state.pf_mutex.unlock(io);
        defer for (want) |w| if (w) |x| gpa.free(x);

        // Decodifica (fuori dal lock) i vicini mancanti.
        for (want) |maybe_path| {
            const path = maybe_path orelse continue;
            state.pf_mutex.lockUncancelable(io);
            const already = state.pf_cache.contains(path) or state.pf_stop.*;
            state.pf_mutex.unlock(io);
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
            state.pf_mutex.lockUncancelable(io);
            const still_wanted = wantContains(state.pf_want, path) and !state.pf_stop.* and !state.pf_cache.contains(path);
            if (still_wanted) {
                const key = gpa.dupe(u8, path) catch {
                    state.pf_mutex.unlock(io);
                    pf.deinit(gpa);
                    continue;
                };
                state.pf_cache.put(gpa, key, pf) catch {
                    gpa.free(key);
                    state.pf_mutex.unlock(io);
                    pf.deinit(gpa);
                    continue;
                };
                state.pf_mutex.unlock(io);
            } else {
                state.pf_mutex.unlock(io);
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
