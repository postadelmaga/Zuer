const std = @import("std");
const builtin = @import("builtin");
const dynlib = @import("dynlib.zig");
const meshcache = @import("meshcache.zig");

pub const CsvData = struct {
    headers: [][]const u8,
    rows: [][][]const u8,

    pub fn deinit(self: *CsvData, allocator: std.mem.Allocator) void {
        for (self.headers) |h| allocator.free(h);
        allocator.free(self.headers);
        for (self.rows) |row| {
            for (row) |cell| allocator.free(cell);
            allocator.free(row);
        }
        allocator.free(self.rows);
    }
};

/// Un singolo foglio di un workbook: nome (per la linguetta) + dati tabellari.
pub const Sheet = struct {
    name: []const u8,
    data: CsvData,

    pub fn deinit(self: *Sheet, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.data.deinit(allocator);
    }
};

/// Foglio di calcolo multi-foglio (xlsx con più sheet). Il foglio mostrato è
/// `active`, un indice di RUNTIME della GUI (non attraversa il confine C-ABI:
/// il plugin restituisce sempre tutti i fogli, la selezione è lato host).
pub const WorkbookData = struct {
    sheets: []Sheet,
    active: usize = 0,

    pub fn deinit(self: *WorkbookData, allocator: std.mem.Allocator) void {
        for (self.sheets) |*s| s.deinit(allocator);
        allocator.free(self.sheets);
    }

    /// Dati del foglio attivo (clampato: `active` è convalidato dalla GUI).
    pub fn activeCsv(self: *const WorkbookData) CsvData {
        return self.sheets[self.active].data;
    }
};

pub const MarkdownData = struct {
    content: []const u8,

    pub fn deinit(self: *MarkdownData, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const Face = struct {
    v1: usize,
    v2: usize,
    v3: usize,
};

/// Un sotto-mesh = un intervallo contiguo dell'index buffer con il proprio
/// materiale e la propria texture. I modelli glTF con più mesh/primitive/
/// materiali producono più submesh sulla stessa geometria fusa; il renderer
/// disegna ogni intervallo con la sua texture.
pub const SubMesh = struct {
    first_index: usize, // offset (in indici) nel buffer indici fuso
    index_count: usize, // numero di indici del submesh (3 × facce)
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    metallic: f32 = 1.0,
    roughness: f32 = 1.0,
    tex_width: usize = 0,
    tex_height: usize = 0,
    tex_pixels: []const u8 = &.{},
    // Normal map tangent-space RGBA8 (dati lineari); vuota se assente.
    nrm_tex_width: usize = 0,
    nrm_tex_height: usize = 0,
    nrm_tex_pixels: []const u8 = &.{},
};

/// Libera le texture dei submesh tenendo conto della condivisione: i glTF
/// spesso riusano lo stesso atlas su molti submesh e il decoder li fa puntare
/// a UN solo buffer (niente N copie da decine di MB) — ogni puntatore va
/// quindi liberato una volta sola, alla sua prima occorrenza.
pub fn freeSubmeshTextures(subs: []const SubMesh, allocator: std.mem.Allocator) void {
    for (subs, 0..) |s, i| {
        if (s.tex_pixels.len > 0 and firstTexOccurrence(subs, i, false, s.tex_pixels.ptr))
            allocator.free(s.tex_pixels);
        if (s.nrm_tex_pixels.len > 0 and firstTexOccurrence(subs, i, true, s.nrm_tex_pixels.ptr))
            allocator.free(s.nrm_tex_pixels);
    }
}

/// True se (i, campo) è la prima occorrenza di `ptr` scandendo i submesh in
/// ordine (per ciascuno: prima baseColor, poi normal map).
fn firstTexOccurrence(subs: []const SubMesh, i: usize, is_nrm: bool, ptr: [*]const u8) bool {
    for (subs[0 .. i + 1], 0..) |p, j| {
        if (p.tex_pixels.len > 0 and p.tex_pixels.ptr == ptr)
            return j == i and !is_nrm;
        if (p.nrm_tex_pixels.len > 0 and p.nrm_tex_pixels.ptr == ptr)
            return j == i and is_nrm;
    }
    return false;
}

pub const MeshData = struct {
    num_vertices: usize,
    num_faces: usize,
    num_normals: usize,
    bbox_min: [3]f32,
    bbox_max: [3]f32,
    center: [3]f32,
    name: []const u8,
    vertices: [][3]f32,
    faces: []Face,
    // Attributi opzionali (len 0 se assenti): normali autorali, UV e tangenti
    // autorali (vec4: xyz + handedness, per il normal mapping).
    normals: [][3]f32 = &.{},
    uvs: [][2]f32 = &.{},
    tangents: [][4]f32 = &.{},
    // Materiale PBR di fallback (glTF metallic-roughness), usato quando non ci
    // sono submesh (es. OBJ/STL). Default: bianco opaco, plastica.
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    metallic: f32 = 1.0,
    roughness: f32 = 1.0,
    // Texture baseColor di fallback RGBA8 (tex_width*tex_height*4); vuota se assente.
    tex_width: usize = 0,
    tex_height: usize = 0,
    tex_pixels: []const u8 = &.{},
    // Sotto-mesh per-materiale (vuoto = si usa il materiale/texture di fallback).
    submeshes: []SubMesh = &.{},

    pub fn deinit(self: *MeshData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.vertices);
        allocator.free(self.faces);
        if (self.normals.len > 0) allocator.free(self.normals);
        if (self.uvs.len > 0) allocator.free(self.uvs);
        if (self.tangents.len > 0) allocator.free(self.tangents);
        if (self.tex_pixels.len > 0) allocator.free(self.tex_pixels);
        freeSubmeshTextures(self.submeshes, allocator);
        if (self.submeshes.len > 0) allocator.free(self.submeshes);
    }
};

pub const ImageData = struct {
    width: usize,
    height: usize,
    pixels: []const u8, // RGB 24-bit
    name: []const u8,
    // Numero totale di pagine del documento sorgente (PDF e simili), in forma
    // STRUTTURATA: la GUI lo usa per la navigazione PgUp/PgDown invece di
    // parsare la label di presentazione ("(pagina N di M)", fragile perché
    // legata a formato/lingua). 0 = non paginato / sconosciuto.
    total_pages: u32 = 0,

    pub fn deinit(self: *ImageData, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        allocator.free(self.name);
    }
};

pub const Decoded = union(enum) {
    text: []const u8,
    csv: CsvData,
    workbook: WorkbookData,
    markdown: MarkdownData,
    mesh: MeshData,
    image: ImageData,
    err: []const u8,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |t| allocator.free(t),
            .csv => |*c| c.deinit(allocator),
            .workbook => |*w| w.deinit(allocator),
            .markdown => |*m| m.deinit(allocator),
            .mesh => |*m| m.deinit(allocator),
            .image => |*i| i.deinit(allocator),
            .err => |e| allocator.free(e),
        }
    }

    pub fn toDecodedC(self: Decoded, allocator: std.mem.Allocator) !DecodedC {
        switch (self) {
            .text => |t| {
                return .{
                    .tag = .text,
                    .payload = .{ .text = SliceC.fromSlice(t) },
                };
            },
            .csv => |c| {
                return .{
                    .tag = .csv,
                    .payload = .{ .csv = try csvToC(allocator, c) },
                };
            },
            .workbook => |w| {
                const sheets_c = try allocator.alloc(SheetC, w.sheets.len);
                for (w.sheets, 0..) |s, i| {
                    sheets_c[i] = .{
                        .name = SliceC.fromSlice(s.name),
                        .data = try csvToC(allocator, s.data),
                    };
                }
                // Il container []Sheet si libera (le leaf name/celle restano vive,
                // ora possedute da DecodedC via i SliceC).
                allocator.free(w.sheets);
                return .{
                    .tag = .workbook,
                    .payload = .{
                        .workbook = .{ .sheets = .{ .ptr = sheets_c.ptr, .len = sheets_c.len } },
                    },
                };
            },
            .markdown => |m| {
                return .{
                    .tag = .markdown,
                    .payload = .{ .markdown = .{ .content = SliceC.fromSlice(m.content) } },
                };
            },
            .mesh => |m| {
                // Converte i submesh in layout C (le texture-leaf restano vive,
                // ora possedute da DecodedC; il container []SubMesh si libera).
                const subs_c = try allocator.alloc(SubMeshC, m.submeshes.len);
                for (m.submeshes, 0..) |s, i| {
                    subs_c[i] = .{
                        .first_index = s.first_index,
                        .index_count = s.index_count,
                        .base_color = s.base_color,
                        .metallic = s.metallic,
                        .roughness = s.roughness,
                        .tex_width = s.tex_width,
                        .tex_height = s.tex_height,
                        .tex_pixels = SliceC.fromSlice(s.tex_pixels),
                        .nrm_tex_width = s.nrm_tex_width,
                        .nrm_tex_height = s.nrm_tex_height,
                        .nrm_tex_pixels = SliceC.fromSlice(s.nrm_tex_pixels),
                    };
                }
                if (m.submeshes.len > 0) allocator.free(m.submeshes);

                return .{
                    .tag = .mesh,
                    .payload = .{
                        .mesh = .{
                            .num_vertices = m.num_vertices,
                            .num_faces = m.num_faces,
                            .num_normals = m.num_normals,
                            .bbox_min = m.bbox_min,
                            .bbox_max = m.bbox_max,
                            .center = m.center,
                            .name = SliceC.fromSlice(m.name),
                            .vertices = .{ .ptr = m.vertices.ptr, .len = m.vertices.len },
                            .faces = .{ .ptr = m.faces.ptr, .len = m.faces.len },
                            .normals = .{ .ptr = m.normals.ptr, .len = m.normals.len },
                            .uvs = .{ .ptr = m.uvs.ptr, .len = m.uvs.len },
                            .tangents = .{ .ptr = m.tangents.ptr, .len = m.tangents.len },
                            .base_color = m.base_color,
                            .metallic = m.metallic,
                            .roughness = m.roughness,
                            .tex_width = m.tex_width,
                            .tex_height = m.tex_height,
                            .tex_pixels = SliceC.fromSlice(m.tex_pixels),
                            .submeshes = .{ .ptr = subs_c.ptr, .len = subs_c.len },
                        },
                    },
                };
            },
            .image => |i| {
                return .{
                    .tag = .image,
                    .payload = .{
                        .image = .{
                            .width = i.width,
                            .height = i.height,
                            .pixels = SliceC.fromSlice(i.pixels),
                            .name = SliceC.fromSlice(i.name),
                            .total_pages = i.total_pages,
                        },
                    },
                };
            },
            .err => |e| {
                return .{
                    .tag = .err,
                    .payload = .{ .err = SliceC.fromSlice(e) },
                };
            },
        }
    }
};

/// Converte una CsvData Zig nel layout C: alloca i container SliceC/RowC e
/// libera i container Zig originali (le leaf — header/celle — restano vive,
/// ora possedute dal chiamante via i SliceC).
fn csvToC(allocator: std.mem.Allocator, c: CsvData) !CsvDataC {
    const headers_c = try allocator.alloc(SliceC, c.headers.len);
    for (c.headers, 0..) |h, i| {
        headers_c[i] = SliceC.fromSlice(h);
    }
    const rows_c = try allocator.alloc(RowC, c.rows.len);
    for (c.rows, 0..) |row, r_idx| {
        const row_cells_c = try allocator.alloc(SliceC, row.len);
        for (row, 0..) |cell, c_idx| {
            row_cells_c[c_idx] = SliceC.fromSlice(cell);
        }
        rows_c[r_idx] = .{ .ptr = row_cells_c.ptr, .len = row_cells_c.len };
    }
    allocator.free(c.headers);
    for (c.rows) |row| allocator.free(row);
    allocator.free(c.rows);
    return .{
        .headers = .{ .ptr = headers_c.ptr, .len = headers_c.len },
        .rows = .{ .ptr = rows_c.ptr, .len = rows_c.len },
    };
}

/// Converte un CsvDataC nel layout Zig: ricostruisce i container slice e libera
/// i container C (le leaf restano possedute dal CsvData risultante).
fn csvFromC(allocator: std.mem.Allocator, c: CsvDataC) !CsvData {
    const headers = try allocator.alloc([]const u8, c.headers.len);
    for (c.headers.ptr[0..c.headers.len], 0..) |h, i| {
        headers[i] = h.toSlice();
    }
    allocator.free(c.headers.ptr[0..c.headers.len]);

    const rows = try allocator.alloc([][]const u8, c.rows.len);
    for (c.rows.ptr[0..c.rows.len], 0..) |row_c, r_idx| {
        const row = try allocator.alloc([]const u8, row_c.len);
        for (row_c.ptr[0..row_c.len], 0..) |cell, c_idx| {
            row[c_idx] = cell.toSlice();
        }
        rows[r_idx] = row;
        allocator.free(row_c.ptr[0..row_c.len]);
    }
    allocator.free(c.rows.ptr[0..c.rows.len]);
    return .{ .headers = headers, .rows = rows };
}

// C-compatible Layouts for Plugins
pub const SliceC = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn fromSlice(slice: []const u8) SliceC {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }
    pub fn toSlice(self: SliceC) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const RowC = extern struct {
    ptr: [*]const SliceC,
    len: usize,
};

pub const CsvDataC = extern struct {
    headers: extern struct { ptr: [*]const SliceC, len: usize },
    rows: extern struct { ptr: [*]const RowC, len: usize },
};

pub const SheetC = extern struct {
    name: SliceC,
    data: CsvDataC,
};

pub const WorkbookDataC = extern struct {
    sheets: extern struct { ptr: [*]const SheetC, len: usize },
};

pub const MarkdownDataC = extern struct {
    content: SliceC,
};

pub const SubMeshC = extern struct {
    first_index: usize,
    index_count: usize,
    base_color: [4]f32,
    metallic: f32,
    roughness: f32,
    tex_width: usize,
    tex_height: usize,
    tex_pixels: SliceC,
    nrm_tex_width: usize,
    nrm_tex_height: usize,
    nrm_tex_pixels: SliceC,
};

pub const MeshDataC = extern struct {
    num_vertices: usize,
    num_faces: usize,
    num_normals: usize,
    bbox_min: [3]f32,
    bbox_max: [3]f32,
    center: [3]f32,
    name: SliceC,
    vertices: extern struct { ptr: [*]const [3]f32, len: usize },
    faces: extern struct { ptr: [*]const Face, len: usize },
    normals: extern struct { ptr: [*]const [3]f32, len: usize },
    uvs: extern struct { ptr: [*]const [2]f32, len: usize },
    tangents: extern struct { ptr: [*]const [4]f32, len: usize },
    base_color: [4]f32,
    metallic: f32,
    roughness: f32,
    tex_width: usize,
    tex_height: usize,
    tex_pixels: SliceC,
    submeshes: extern struct { ptr: [*]const SubMeshC, len: usize },
};

pub const ImageDataC = extern struct {
    width: usize,
    height: usize,
    pixels: SliceC,
    name: SliceC,
    // Pagine totali del documento (0 = non paginato/sconosciuto). In CODA alla
    // struct: gli offset dei campi preesistenti non cambiano. Il layout resta
    // comunque una modifica ABI (dimensione della struct) → abi_version bumpata.
    total_pages: u32 = 0,
};

pub const DecodedTag = enum(u32) {
    text = 0,
    csv = 1,
    markdown = 2,
    mesh = 3,
    image = 4,
    err = 5,
    workbook = 6,
};

pub const DecodedC = extern struct {
    tag: DecodedTag,
    payload: extern union {
        text: SliceC,
        csv: CsvDataC,
        workbook: WorkbookDataC,
        markdown: MarkdownDataC,
        mesh: MeshDataC,
        image: ImageDataC,
        err: SliceC,
    },

    pub fn toDecoded(self: DecodedC, allocator: std.mem.Allocator) !Decoded {
        switch (self.tag) {
            .text => {
                const t = self.payload.text;
                return .{ .text = t.toSlice() };
            },
            .csv => {
                return .{ .csv = try csvFromC(allocator, self.payload.csv) };
            },
            .workbook => {
                const w = self.payload.workbook;
                const sheets = try allocator.alloc(Sheet, w.sheets.len);
                for (w.sheets.ptr[0..w.sheets.len], 0..) |s_c, i| {
                    sheets[i] = .{
                        .name = s_c.name.toSlice(),
                        .data = try csvFromC(allocator, s_c.data),
                    };
                }
                allocator.free(w.sheets.ptr[0..w.sheets.len]);
                return .{ .workbook = .{ .sheets = sheets, .active = 0 } };
            },
            .markdown => {
                const m = self.payload.markdown;
                return .{
                    .markdown = .{ .content = m.content.toSlice() },
                };
            },
            .mesh => {
                const m = self.payload.mesh;
                // Ricostruisce i submesh in slice Zig (copia il container C, che
                // poi si libera; le texture-leaf restano possedute dal MeshData).
                const subs = try allocator.alloc(SubMesh, m.submeshes.len);
                for (0..m.submeshes.len) |i| {
                    const s = m.submeshes.ptr[i];
                    subs[i] = .{
                        .first_index = s.first_index,
                        .index_count = s.index_count,
                        .base_color = s.base_color,
                        .metallic = s.metallic,
                        .roughness = s.roughness,
                        .tex_width = s.tex_width,
                        .tex_height = s.tex_height,
                        .tex_pixels = s.tex_pixels.toSlice(),
                        .nrm_tex_width = s.nrm_tex_width,
                        .nrm_tex_height = s.nrm_tex_height,
                        .nrm_tex_pixels = s.nrm_tex_pixels.toSlice(),
                    };
                }
                if (m.submeshes.len > 0) allocator.free(@constCast(m.submeshes.ptr[0..m.submeshes.len]));

                return .{
                    .mesh = .{
                        .num_vertices = m.num_vertices,
                        .num_faces = m.num_faces,
                        .num_normals = m.num_normals,
                        .bbox_min = m.bbox_min,
                        .bbox_max = m.bbox_max,
                        .center = m.center,
                        .name = m.name.toSlice(),
                        .vertices = @constCast(m.vertices.ptr[0..m.vertices.len]),
                        .faces = @constCast(m.faces.ptr[0..m.faces.len]),
                        .normals = @constCast(m.normals.ptr[0..m.normals.len]),
                        .uvs = @constCast(m.uvs.ptr[0..m.uvs.len]),
                        .tangents = @constCast(m.tangents.ptr[0..m.tangents.len]),
                        .base_color = m.base_color,
                        .metallic = m.metallic,
                        .roughness = m.roughness,
                        .tex_width = m.tex_width,
                        .tex_height = m.tex_height,
                        .tex_pixels = m.tex_pixels.toSlice(),
                        .submeshes = subs,
                    },
                };
            },
            .image => {
                const i = self.payload.image;
                return .{
                    .image = .{
                        .width = i.width,
                        .height = i.height,
                        .pixels = i.pixels.toSlice(),
                        .name = i.name.toSlice(),
                        .total_pages = i.total_pages,
                    },
                };
            },
            .err => {
                // I plugin possono restituire messaggi d'errore sia letterali statici
                // sia heap: si duplica al confine ABI e non si libera mai l'originale
                // (un messaggio heap del plugin trapela pochi byte, ma non si può
                // distinguere e un free su un letterale corromperebbe l'allocator).
                const e = self.payload.err;
                return .{ .err = allocator.dupe(u8, e.toSlice()) catch "" };
            },
        }
    }
};

/// Versione dell'ABI plugin (layout di `DecodedC` e firma di `DecodeFn`).
/// Va incrementata a ogni modifica incompatibile del contratto C: l'host
/// scarta i plugin compilati contro una versione diversa (un .so stantio con
/// un layout `DecodedC` vecchio corromperebbe la memoria).
/// v2: aggiunto `total_pages: u32` in coda a `ImageDataC`.
pub const abi_version: u32 = 2;

/// True quando i decoder sono compilati come **plugin** caricabili con `dlopen` — il caso
/// del desktop. Su Android no: l'APK porta una libreria sola e i decoder ci finiscono
/// dentro linkati, dove gli export dell'ABI plugin (`zuer_decode`, `zuer_extensions`…)
/// colliderebbero l'uno con l'altro, uno per decoder, senza che nessuno li chiami.
pub const plugin_abi = builtin.abi != .android;

/// Ogni plugin esporta `zuer_abi_version` (ritorna l'`abi_version` con cui è
/// stato compilato); l'host la verifica al caricamento e scarta i mismatch.
pub const AbiVersionFn = *const fn () callconv(.c) u32;

/// Contratto di ownership: il plugin prende possesso di `content` e lo libera
/// lui (con l'allocator passato), anche nei percorsi d'errore.
pub const DecodeFn = *const fn (
    path: SliceC,
    content: SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) DecodedC;

/// Ogni plugin dichiara le estensioni che sa decodificare esportando
/// `zuer_extensions`: una stringa statica di estensioni separate da virgola
/// (es. "csv,tsv"). L'host la interroga una sola volta al caricamento, così
/// aggiungere un formato significa solo installare un nuovo .so.
pub const ExtensionsFn = *const fn () callconv(.c) SliceC;

/// Opzionale: quanti byte di `content` servono davvero al plugin. 0 = solo il
/// percorso (es. pdf: rilegge lui dal path); N = bastano i primi N byte (es.
/// media: header sniffing — un MKV multi-GB non va caricato in RAM per il
/// poster). Assente = l'host passa l'intero file (default storico).
pub const ContentPrefixFn = *const fn () callconv(.c) usize;

const LoadedPlugin = struct {
    type_name: []const u8,
    extensions: []const []const u8,
    lib: dynlib.Lib,
    decode_fn: DecodeFn,
    /// Opzionale: prima fase progressiva (texture al tier coarse). Solo i plugin
    /// che la esportano (es. glb) la offrono; gli altri fanno un decode solo.
    decode_coarse_fn: ?DecodeFn = null,
    /// Byte di contenuto richiesti (vedi ContentPrefixFn); maxInt = file intero.
    content_prefix: usize = std.math.maxInt(usize),
};

var plugin_registry: std.ArrayList(LoadedPlugin) = .empty;
var plugin_registry_scanned = false;
var plugin_cache_mutex: std.atomic.Mutex = .unlocked;

/// Chiude i plugin caricati e libera il registro. Da chiamare a fine processo,
/// dopo il join di tutti i thread che possono decodificare.
pub fn closePluginCache(allocator: std.mem.Allocator) void {
    while (!plugin_cache_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer plugin_cache_mutex.unlock();

    for (plugin_registry.items) |*p| {
        allocator.free(p.type_name);
        for (p.extensions) |e| allocator.free(e);
        allocator.free(p.extensions);
        p.lib.close();
    }
    plugin_registry.deinit(allocator);
    plugin_registry = .empty;
    plugin_registry_scanned = false;
}

// A dynamic library's on-disk name is target-specific: `libdecoder_x.so` on Linux,
// `libdecoder_x.dylib` on macOS, `decoder_x.dll` on Windows (no `lib` prefix). Match the
// naming Zig's build emits so plugin discovery works on every platform.
const plugin_prefix = if (builtin.os.tag == .windows) "decoder_" else "libdecoder_";
const plugin_suffix = switch (builtin.os.tag) {
    .windows => ".dll",
    .macos => ".dylib",
    else => ".so",
};

/// Scansiona una directory alla ricerca di plugin `libdecoder_*.so` e li
/// registra interrogando `zuer_extensions`. Un plugin già registrato con lo
/// stesso nome (da una directory precedente nell'ordine di ricerca) vince.
fn scanPluginDir(dir_path: []const u8, io: std.Io, allocator: std.mem.Allocator) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.startsWith(u8, entry.name, plugin_prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, plugin_suffix)) continue;

        const type_name = entry.name[plugin_prefix.len .. entry.name.len - plugin_suffix.len];
        if (type_name.len == 0) continue;
        if (findPluginByName(type_name) != null) continue;

        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
        defer allocator.free(full_path);

        var lib = dynlib.Lib.open(full_path) catch continue;
        // Verifica dell'ABI: un plugin senza `zuer_abi_version` o compilato
        // contro un'altra versione del contratto C va scartato subito (il
        // layout di `DecodedC` potrebbe non combaciare → corruzione di memoria).
        const abi_ok = if (lib.lookup(AbiVersionFn, "zuer_abi_version")) |abi_fn| blk: {
            const v = abi_fn();
            if (v != abi_version)
                std.debug.print("zuer: plugin {s} ignorato: ABI v{d} != v{d}\n", .{ entry.name, v, abi_version });
            break :blk v == abi_version;
        } else blk: {
            std.debug.print("zuer: plugin {s} ignorato: manca zuer_abi_version (atteso ABI v{d})\n", .{ entry.name, abi_version });
            break :blk false;
        };
        if (!abi_ok) {
            lib.close();
            continue;
        }
        const decode_fn = lib.lookup(DecodeFn, "zuer_decode") orelse {
            lib.close();
            continue;
        };
        const decode_coarse_fn = lib.lookup(DecodeFn, "zuer_decode_coarse");
        const content_prefix: usize = if (lib.lookup(ContentPrefixFn, "zuer_content_prefix")) |f| f() else std.math.maxInt(usize);

        // `zuer_extensions` è opzionale: un plugin senza estensioni dichiarate
        // resta raggiungibile solo come fallback per nome (es. "text").
        var exts: std.ArrayList([]const u8) = .empty;
        if (lib.lookup(ExtensionsFn, "zuer_extensions")) |ext_fn| {
            var tokens = std.mem.tokenizeScalar(u8, ext_fn().toSlice(), ',');
            while (tokens.next()) |tok| {
                const trimmed = std.mem.trim(u8, tok, " \t\r\n");
                if (trimmed.len == 0) continue;
                const lower = allocator.dupe(u8, trimmed) catch continue;
                for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
                exts.append(allocator, lower) catch allocator.free(lower);
            }
        }

        var registered = false;
        defer if (!registered) {
            for (exts.items) |e| allocator.free(e);
            exts.deinit(allocator);
            lib.close();
        };

        const type_name_dup = allocator.dupe(u8, type_name) catch continue;
        const exts_owned = exts.toOwnedSlice(allocator) catch {
            allocator.free(type_name_dup);
            continue;
        };
        plugin_registry.append(allocator, .{
            .type_name = type_name_dup,
            .extensions = exts_owned,
            .lib = lib,
            .decode_fn = decode_fn,
            .decode_coarse_fn = decode_coarse_fn,
            .content_prefix = content_prefix,
        }) catch {
            allocator.free(type_name_dup);
            for (exts_owned) |e| allocator.free(e);
            allocator.free(exts_owned);
            continue;
        };
        registered = true;
    }
}

/// Costruisce il registro dei plugin (una sola volta) scandendo, nell'ordine,
/// `<exe_dir>/decoders`, `<exe_dir>`, `zig-out/lib` e `decoders`.
/// Deve essere chiamata con `plugin_cache_mutex` già acquisito.
fn ensureRegistryLocked(io: std.Io, allocator: std.mem.Allocator) void {
    if (plugin_registry_scanned) return;
    plugin_registry_scanned = true;

    if (std.process.executableDirPathAlloc(io, allocator)) |exe_dir| {
        defer allocator.free(exe_dir);
        if (std.fs.path.join(allocator, &.{ exe_dir, "decoders" })) |p| {
            defer allocator.free(p);
            scanPluginDir(p, io, allocator);
        } else |_| {}
        scanPluginDir(exe_dir, io, allocator);
    } else |_| {}
    scanPluginDir("zig-out/lib", io, allocator);
    scanPluginDir("decoders", io, allocator);
}

fn findPluginByName(type_name: []const u8) ?*const LoadedPlugin {
    for (plugin_registry.items) |*p| {
        if (std.mem.eql(u8, p.type_name, type_name)) return p;
    }
    return null;
}

fn findPluginByExtension(ext: []const u8) ?*const LoadedPlugin {
    if (ext.len == 0) return null;
    for (plugin_registry.items) |*p| {
        for (p.extensions) |e| {
            if (asciiEqualIgnoreCase(ext, e)) return p;
        }
    }
    return null;
}

// `getenv` is in the C runtime on every platform we target.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const RunResult = struct {
    stdout: []u8,
    exit_code: u8,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
    }
};

/// Timeout di default per i tool esterni lanciati con `runCapture`.
pub const default_run_timeout_ms: u32 = 60_000;

/// Esegue un comando catturandone lo stdout, senza dipendere da `std.Io`
/// (`std.process.run` si blocca dentro i plugin dinamici: l'`io` dell'host non
/// attraversa il confine DynLib). L'implementazione è per-OS: `posix_spawn` +
/// pipe su Unix, `CreateProcessW` + pipe anonima su Windows. Deadline
/// complessiva di `default_run_timeout_ms`: un tool appeso non può bloccare il
/// worker per sempre (vedi `runCaptureTimeout` per un valore esplicito).
pub fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    return sub.runCapture(allocator, argv, default_run_timeout_ms);
}

/// Come `runCapture`, con deadline complessiva esplicita: alla scadenza il
/// processo viene terminato (SIGKILL / TerminateProcess) e ritorna `error.Timeout`.
pub fn runCaptureTimeout(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32) !RunResult {
    return sub.runCapture(allocator, argv, timeout_ms);
}

/// Legge un intero file senza `std.Io` (open/read/close libc su Unix,
/// CreateFileW/ReadFile su Windows): come runCapture, evita che l'io dell'host
/// si blocchi dentro un plugin dinamico. Il chiamante possiede il buffer.
pub fn readFileLibc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return sub.readFile(allocator, path, max_bytes);
}

/// Legge gli ultimi `n` byte del file (o meno, se è più corto), senza `std.Io`.
/// Per le strutture che i formati mettono in coda (ultima pagina Ogg, `moov`
/// dei MP4 non-faststart) quando l'host ha passato solo un prefisso.
pub fn readFileTailLibc(allocator: std.mem.Allocator, path: []const u8, n: usize) ![]u8 {
    return sub.readFileTail(allocator, path, n);
}

/// Dimensione del file senza `std.Io` (per i plugin che ricevono solo un
/// prefisso di contenuto ma mostrano la dimensione reale).
pub fn fileSizeLibc(allocator: std.mem.Allocator, path: []const u8) ?u64 {
    return sub.fileSize(allocator, path) catch null;
}

/// Per-OS subprocess + raw file-read backend. Only the selected arm is analyzed, so the
/// POSIX externs never reach a Windows link and vice-versa.
const sub = switch (builtin.os.tag) {
    .windows => struct {
        const HANDLE = ?*anyopaque;
        const SECURITY_ATTRIBUTES = extern struct { nLength: u32, lpSecurityDescriptor: ?*anyopaque, bInheritHandle: i32 };
        const STARTUPINFOW = extern struct {
            cb: u32,
            lpReserved: ?[*:0]u16 = null,
            lpDesktop: ?[*:0]u16 = null,
            lpTitle: ?[*:0]u16 = null,
            dwX: u32 = 0,
            dwY: u32 = 0,
            dwXSize: u32 = 0,
            dwYSize: u32 = 0,
            dwXCountChars: u32 = 0,
            dwYCountChars: u32 = 0,
            dwFillAttribute: u32 = 0,
            dwFlags: u32 = 0,
            wShowWindow: u16 = 0,
            cbReserved2: u16 = 0,
            lpReserved2: ?*u8 = null,
            hStdInput: HANDLE = null,
            hStdOutput: HANDLE = null,
            hStdError: HANDLE = null,
        };
        const PROCESS_INFORMATION = extern struct { hProcess: HANDLE, hThread: HANDLE, dwProcessId: u32, dwThreadId: u32 };
        extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*const SECURITY_ATTRIBUTES, nSize: u32) callconv(.winapi) i32;
        extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: u32, dwFlags: u32) callconv(.winapi) i32;
        extern "kernel32" fn CreateProcessW(lpApplicationName: ?[*:0]const u16, lpCommandLine: ?[*:0]u16, lpProcessAttributes: ?*anyopaque, lpThreadAttributes: ?*anyopaque, bInheritHandles: i32, dwCreationFlags: u32, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *const STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) i32;
        extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
        extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
        extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *u32) callconv(.winapi) i32;
        extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?[*]u8, nBufferSize: u32, lpBytesRead: ?*u32, lpTotalBytesAvail: ?*u32, lpBytesLeftThisMessage: ?*u32) callconv(.winapi) i32;
        extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) i32;
        extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
        extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: HANDLE) callconv(.winapi) HANDLE;
        const HANDLE_FLAG_INHERIT: u32 = 0x00000001;
        const STARTF_USESTDHANDLES: u32 = 0x00000100;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        const GENERIC_READ: u32 = 0x80000000;
        const FILE_SHARE_READ: u32 = 0x00000001;
        const OPEN_EXISTING: u32 = 3;
        const INVALID_HANDLE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
        const WAIT_OBJECT_0: u32 = 0;
        const WAIT_TIMEOUT: u32 = 0x00000102;

        fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32) !RunResult {
            if (argv.len == 0) return error.EmptyArgv;
            // Build a single, quoted command line (CreateProcess takes a string, not argv).
            // Quoting Win32 (regole di CommandLineToArgvW): le run di backslash che
            // precedono una virgoletta — o la `"` di chiusura dell'argomento — vanno
            // raddoppiate, poi la virgoletta letterale si escapa con un backslash;
            // altrimenti un argomento che termina con `\` fonderebbe i successivi.
            var cmd: std.ArrayList(u8) = .empty;
            defer cmd.deinit(allocator);
            for (argv, 0..) |a, i| {
                if (i != 0) try cmd.append(allocator, ' ');
                try cmd.append(allocator, '"');
                var bs: usize = 0;
                for (a) |ch| {
                    if (ch == '\\') {
                        bs += 1;
                        continue;
                    }
                    if (ch == '"') {
                        // 2n+1 backslash: i letterali raddoppiati + l'escape della virgoletta.
                        try cmd.appendNTimes(allocator, '\\', bs * 2 + 1);
                        try cmd.append(allocator, '"');
                    } else {
                        // Backslash non seguiti da virgoletta: letterali, nessun raddoppio.
                        try cmd.appendNTimes(allocator, '\\', bs);
                        try cmd.append(allocator, ch);
                    }
                    bs = 0;
                }
                // Backslash in coda: raddoppiati, o escaperebbero la `"` di chiusura.
                try cmd.appendNTimes(allocator, '\\', bs * 2);
                try cmd.append(allocator, '"');
            }
            const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd.items);
            defer allocator.free(cmd_w);

            const sa = SECURITY_ATTRIBUTES{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = 1 };
            var h_read: HANDLE = null;
            var h_write: HANDLE = null;
            if (CreatePipe(&h_read, &h_write, &sa, 0) == 0) return error.PipeFailed;
            defer _ = CloseHandle(h_read);
            _ = SetHandleInformation(h_read, HANDLE_FLAG_INHERIT, 0); // parent end not inherited

            // stderr NON sulla stessa pipe dello stdout parsato (un warning del
            // tool romperebbe il parse): con STARTF_USESTDHANDLES un handle null
            // equivale a "nessuno stderr" per il figlio.
            var si = STARTUPINFOW{ .cb = @sizeOf(STARTUPINFOW), .dwFlags = STARTF_USESTDHANDLES, .hStdOutput = h_write, .hStdError = null };
            var pi: PROCESS_INFORMATION = undefined;
            const ok = CreateProcessW(null, cmd_w, null, null, 1, CREATE_NO_WINDOW, null, null, &si, &pi);
            _ = CloseHandle(h_write); // parent keeps only the read end
            if (ok == 0) return error.CommandNotFound;
            defer _ = CloseHandle(pi.hProcess);
            defer _ = CloseHandle(pi.hThread);

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            var buf: [65536]u8 = undefined;
            // Lettura con deadline complessiva: una ReadFile bloccante su un figlio
            // appeso non raggiungerebbe mai il wait, quindi si sonda la pipe con
            // PeekNamedPipe e si legge solo quando ci sono byte disponibili; alla
            // scadenza il figlio viene terminato e si ritorna errore.
            const deadline: u64 = GetTickCount64() + timeout_ms;
            while (true) {
                var avail: u32 = 0;
                if (PeekNamedPipe(h_read, null, 0, null, &avail, null) == 0) break; // pipe chiusa → EOF
                if (avail > 0) {
                    var got: u32 = 0;
                    if (ReadFile(h_read, &buf, @min(avail, buf.len), &got, null) == 0 or got == 0) break;
                    try out.appendSlice(allocator, buf[0..got]);
                    continue;
                }
                // Niente dati: figlio già uscito → fine; ancora vivo → si controlla
                // la deadline e si attende un attimo prima di risondare.
                if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) break;
                if (GetTickCount64() >= deadline) {
                    _ = TerminateProcess(pi.hProcess, 1);
                    _ = WaitForSingleObject(pi.hProcess, 5000);
                    return error.Timeout;
                }
                Sleep(10);
            }
            // Attesa finale col budget residuo: copre il figlio che ha chiuso lo
            // stdout ma non esce; su WAIT_TIMEOUT lo si termina e si ritorna errore.
            const now = GetTickCount64();
            const wait_ms: u32 = if (deadline > now) @intCast(@min(deadline - now, std.math.maxInt(u32))) else 0;
            if (WaitForSingleObject(pi.hProcess, wait_ms) == WAIT_TIMEOUT) {
                _ = TerminateProcess(pi.hProcess, 1);
                _ = WaitForSingleObject(pi.hProcess, 5000);
                return error.Timeout;
            }
            var code: u32 = 1;
            _ = GetExitCodeProcess(pi.hProcess, &code);
            return .{ .stdout = try out.toOwnedSlice(allocator), .exit_code = @truncate(code) };
        }

        fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
            const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(path_w);
            const h = CreateFileW(path_w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
            if (h == INVALID_HANDLE) return error.OpenFailed;
            defer _ = CloseHandle(h);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            var buf: [65536]u8 = undefined;
            while (out.items.len < max_bytes) {
                var got: u32 = 0;
                if (ReadFile(h, &buf, buf.len, &got, null) == 0) return error.ReadFailed;
                if (got == 0) break;
                try out.appendSlice(allocator, buf[0..got]);
            }
            return out.toOwnedSlice(allocator);
        }

        extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) i32;
        extern "kernel32" fn SetFilePointerEx(hFile: HANDLE, liDistanceToMove: i64, lpNewFilePointer: ?*i64, dwMoveMethod: u32) callconv(.winapi) i32;

        fn fileSize(allocator: std.mem.Allocator, path: []const u8) !u64 {
            const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(path_w);
            const h = CreateFileW(path_w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
            if (h == INVALID_HANDLE) return error.OpenFailed;
            defer _ = CloseHandle(h);
            var size: i64 = 0;
            if (GetFileSizeEx(h, &size) == 0 or size < 0) return error.ReadFailed;
            return @intCast(size);
        }

        fn readFileTail(allocator: std.mem.Allocator, path: []const u8, n: usize) ![]u8 {
            const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(path_w);
            const h = CreateFileW(path_w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
            if (h == INVALID_HANDLE) return error.OpenFailed;
            defer _ = CloseHandle(h);
            var size: i64 = 0;
            if (GetFileSizeEx(h, &size) == 0 or size < 0) return error.ReadFailed;
            const want: usize = @min(n, @as(usize, @intCast(size)));
            if (SetFilePointerEx(h, size - @as(i64, @intCast(want)), null, 0) == 0) return error.ReadFailed; // FILE_BEGIN
            const buf = try allocator.alloc(u8, want);
            errdefer allocator.free(buf);
            var off: usize = 0;
            while (off < want) {
                var got: u32 = 0;
                const chunk: u32 = @intCast(@min(want - off, 1 << 20));
                if (ReadFile(h, buf.ptr + off, chunk, &got, null) == 0 or got == 0) return error.ReadFailed;
                off += got;
            }
            return buf;
        }
    },
    else => struct {
        extern "c" fn pipe(fds: *[2]c_int) c_int;
        extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
        extern "c" fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;
        extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
        extern "c" fn close(fd: c_int) c_int;
        extern "c" fn open(path: [*:0]const u8, flags: c_int) c_int;
        extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
        extern "c" fn kill(pid: c_int, sig: c_int) c_int;
        extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;
        extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
        // posix_spawn: fork+exec+ricerca PATH in modo sicuro anche in processi
        // multi-thread (niente malloc nel figlio forkato → niente deadlock).
        extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, file_actions: ?*const anyopaque, attrp: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
        extern "c" fn posix_spawn_file_actions_init(fa: *anyopaque) c_int;
        extern "c" fn posix_spawn_file_actions_destroy(fa: *anyopaque) c_int;
        extern "c" fn posix_spawn_file_actions_adddup2(fa: *anyopaque, fd: c_int, newfd: c_int) c_int;
        extern "c" fn posix_spawn_file_actions_addclose(fa: *anyopaque, fd: c_int) c_int;
        extern "c" fn posix_spawn_file_actions_addopen(fa: *anyopaque, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
        extern "c" var environ: [*:null]const ?[*:0]const u8;

        const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
        const POLLIN: c_short = 0x001;
        const Timespec = extern struct { sec: c_long, nsec: c_long };
        const CLOCK_MONOTONIC: c_int = if (builtin.os.tag.isDarwin()) 6 else 1;

        /// Millisecondi di clock monotonico via libc (niente `std.Io`, che non
        /// attraversa il confine dei plugin dinamici). Per le deadline.
        fn nowMs() i64 {
            var ts: Timespec = .{ .sec = 0, .nsec = 0 };
            _ = clock_gettime(CLOCK_MONOTONIC, &ts);
            return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
        }

        /// pipe con O_CLOEXEC: senza, un figlio spawnato in parallelo da un ALTRO
        /// thread eredita il write-end e l'EOF sul read-end non arriva finché
        /// anche quello non esce (deadlock del loop di lettura). L'`adddup2` del
        /// figlio giusto azzera CLOEXEC sul fd duplicato, quindi basta questo.
        /// Su Linux `pipe2` è atomica; su Darwin (niente pipe2) fallback
        /// `pipe` + `fcntl(FD_CLOEXEC)`, best-effort.
        fn pipeCloexec(fds: *[2]c_int) c_int {
            if (builtin.os.tag == .linux) {
                return pipe2(fds, 0o2000000); // O_CLOEXEC (Linux)
            } else {
                if (pipe(fds) != 0) return -1;
                _ = fcntl(fds[0], 2, 1); // F_SETFD, FD_CLOEXEC
                _ = fcntl(fds[1], 2, 1);
                return 0;
            }
        }

        fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32) !RunResult {
            if (argv.len == 0) return error.EmptyArgv;

            // argv null-terminato costruito PRIMA della fork: nel figlio non si può
            // allocare in sicurezza (multi-thread → solo funzioni async-signal-safe).
            const argvZ = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
            defer {
                for (argvZ[0..argv.len]) |a| if (a) |p| allocator.free(std.mem.span(p));
                allocator.free(argvZ);
            }
            for (argv, 0..) |a, i| argvZ[i] = (try allocator.dupeZ(u8, a)).ptr;

            var fds: [2]c_int = undefined;
            if (pipeCloexec(&fds) != 0) return error.PipeFailed;
            const read_fd = fds[0];
            const write_fd = fds[1];
            var read_fd_open = true;
            defer if (read_fd_open) {
                _ = close(read_fd);
            };

            var fa: [256]u8 align(16) = undefined;
            if (posix_spawn_file_actions_init(&fa) != 0) {
                _ = close(write_fd);
                return error.SpawnInit;
            }
            defer _ = posix_spawn_file_actions_destroy(&fa);
            _ = posix_spawn_file_actions_adddup2(&fa, write_fd, 1);
            // stderr del figlio su /dev/null: il terminale dell'host è in
            // raw-mode e i warning dei tool esterni lo sporcherebbero.
            _ = posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", 1, 0); // O_WRONLY
            _ = posix_spawn_file_actions_addclose(&fa, read_fd);

            var pid: c_int = 0;
            const rc = posix_spawnp(&pid, argvZ[0].?, &fa, null, argvZ.ptr, environ);
            _ = close(write_fd);
            if (rc != 0) return if (rc == 2) error.CommandNotFound else error.SpawnFailed; // 2 = ENOENT

            // Da qui il figlio esiste: su OGNI percorso d'errore va reaped (niente
            // zombie). Si chiude prima il read-end e si manda SIGKILL, così il
            // waitpid non può bloccarsi su un figlio che sta ancora scrivendo.
            var reaped = false;
            errdefer if (!reaped) {
                if (read_fd_open) {
                    _ = close(read_fd);
                    read_fd_open = false;
                }
                _ = kill(pid, 9); // SIGKILL
                _ = waitpid(pid, null, 0);
            };

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            var buf: [65536]u8 = undefined;
            // Loop di lettura con deadline complessiva via poll(): un tool esterno
            // appeso non può bloccare il worker per sempre — alla scadenza
            // l'errdefer sopra termina e reap-a il figlio.
            const deadline: i64 = nowMs() + timeout_ms;
            var pfd = [1]PollFd{.{ .fd = read_fd, .events = POLLIN, .revents = 0 }};
            while (true) {
                const remaining = deadline - nowMs();
                if (remaining <= 0) return error.Timeout;
                const pr = poll(&pfd, 1, @intCast(@min(remaining, std.math.maxInt(c_int))));
                if (pr == 0) continue; // scaduto il tratto: si ricontrolla la deadline
                if (pr < 0) continue; // EINTR e simili: la deadline limita comunque il loop
                const n = read(read_fd, &buf, buf.len);
                if (n <= 0) break;
                try out.appendSlice(allocator, buf[0..@intCast(n)]);
            }

            var status: c_int = 0;
            _ = waitpid(pid, &status, 0);
            reaped = true;
            // WIFEXITED / WEXITSTATUS espansi a mano (glibc): byte basso = segnale.
            const code: u8 = if ((status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else 1;
            return .{ .stdout = try out.toOwnedSlice(allocator), .exit_code = code };
        }

        fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
            const path_z = try allocator.dupeZ(u8, path);
            defer allocator.free(path_z);

            const fd = open(path_z.ptr, 0); // O_RDONLY
            if (fd < 0) return error.OpenFailed;
            defer _ = close(fd);

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            var buf: [65536]u8 = undefined;
            while (out.items.len < max_bytes) {
                const n = read(fd, &buf, buf.len);
                if (n < 0) return error.ReadFailed;
                if (n == 0) break;
                try out.appendSlice(allocator, buf[0..@intCast(n)]);
            }
            return out.toOwnedSlice(allocator);
        }

        extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;

        fn fileSize(allocator: std.mem.Allocator, path: []const u8) !u64 {
            const path_z = try allocator.dupeZ(u8, path);
            defer allocator.free(path_z);
            const fd = open(path_z.ptr, 0);
            if (fd < 0) return error.OpenFailed;
            defer _ = close(fd);
            const size = lseek(fd, 0, 2); // SEEK_END
            if (size < 0) return error.ReadFailed;
            return @intCast(size);
        }

        fn readFileTail(allocator: std.mem.Allocator, path: []const u8, n: usize) ![]u8 {
            const path_z = try allocator.dupeZ(u8, path);
            defer allocator.free(path_z);
            const fd = open(path_z.ptr, 0);
            if (fd < 0) return error.OpenFailed;
            defer _ = close(fd);
            const size = lseek(fd, 0, 2); // SEEK_END
            if (size < 0) return error.ReadFailed;
            const want: usize = @min(n, @as(usize, @intCast(size)));
            if (lseek(fd, size - @as(i64, @intCast(want)), 0) < 0) return error.ReadFailed; // SEEK_SET
            const buf = try allocator.alloc(u8, want);
            errdefer allocator.free(buf);
            var off: usize = 0;
            while (off < want) {
                const r = read(fd, buf.ptr + off, want - off);
                if (r <= 0) return error.ReadFailed;
                off += @intCast(r);
            }
            return buf;
        }
    },
};

/// Cache pigra di `defaultMaxSize`: 0 = non ancora calcolato. Evita di aprire
/// e analizzare /proc/meminfo a OGNI decode (×2 per navigazione + prefetch).
var default_max_size_cache: std.atomic.Value(usize) = .init(0);

/// Budget di dimensione file di default, proporzionale alla memoria disponibile:
/// metà di MemAvailable (il file viene letto in RAM e il decoder vi alloca sopra).
/// Fallback a 128 MB se /proc/meminfo non è leggibile. Calcolato una sola volta.
fn defaultMaxSize(io: std.Io, allocator: std.mem.Allocator) usize {
    const cached = default_max_size_cache.load(.monotonic);
    if (cached != 0) return cached;
    const computed = computeDefaultMaxSize(io, allocator);
    default_max_size_cache.store(computed, .monotonic);
    return computed;
}

fn computeDefaultMaxSize(io: std.Io, allocator: std.mem.Allocator) usize {
    const fallback: usize = 128 * 1024 * 1024;
    // /proc/meminfo riporta dimensione 0 in stat, quindi un reader posizionale
    // (readFileAlloc) legge zero byte e si finisce sempre nel fallback: serve un
    // reader in streaming che legga fino all'EOF reale.
    var file = std.Io.Dir.cwd().openFile(io, "/proc/meminfo", .{}) catch return fallback;
    defer file.close(io);
    var buf: [8 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const data = reader.interface.allocRemaining(allocator, std.Io.Limit.limited(64 * 1024)) catch return fallback;
    defer allocator.free(data);
    const key = "MemAvailable:";
    const start = std.mem.indexOf(u8, data, key) orelse return fallback;
    var tokens = std.mem.tokenizeAny(u8, data[start + key.len ..], " \t\n");
    const num = tokens.next() orelse return fallback;
    const kb = std.fmt.parseInt(usize, num, 10) catch return fallback;
    return (kb * 1024) / 2;
}

/// Riconosce i formati immagine comuni dai byte magici, per instradare al plugin
/// immagini i file con estensione errata o assente (quando nessun plugin è
/// stato risolto per estensione nel registro).
fn guessImageFormat(bytes: []const u8) bool {
    if (bytes.len >= 4) {
        if (std.mem.eql(u8, bytes[0..4], &.{ 0x89, 0x50, 0x4E, 0x47 })) return true; // PNG
        if (std.mem.eql(u8, bytes[0..4], "GIF8")) return true; // GIF
        if (bytes[0] == 'B' and bytes[1] == 'M') return true; // BMP
    }
    if (bytes.len >= 3) {
        if (std.mem.eql(u8, bytes[0..3], &.{ 0xFF, 0xD8, 0xFF })) return true; // JPEG
    }
    if (bytes.len >= 12) {
        if (std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return true; // WebP
    }
    return false;
}

pub fn decode(path: []const u8, io: std.Io, allocator: std.mem.Allocator) Decoded {
    // Il messaggio va duplicato sull'allocator: `Decoded.deinit` libera `err`
    // incondizionatamente e un free su un letterale statico è UB.
    return decodeImpl(path, io, allocator, false) orelse .{ .err = allocator.dupe(u8, "decode fallito") catch "" };
}

/// Prima fase del caricamento progressivo: texture al tier coarse (256², da cache
/// se presente → resa quasi istantanea alla riapertura). Ritorna null se il plugin
/// risolto non offre `zuer_decode_coarse` (l'host allora fa solo `decode`).
pub fn decodeCoarse(path: []const u8, io: std.Io, allocator: std.mem.Allocator) ?Decoded {
    return decodeImpl(path, io, allocator, true);
}

/// Estensioni degli archivi "navigabili" dentro (anteprima delle voci). Deve
/// restare allineata alle estensioni dichiarate da archive.zig e tar.zig.
pub fn isArchiveExt(ext: []const u8) bool {
    const list = [_][]const u8{ "zip", "jar", "apk", "cbz", "epub", "xpi", "whl", "tar", "tgz", "tar.gz" };
    for (list) |e| {
        if (asciiEqualIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn isTarExt(ext: []const u8) bool {
    return asciiEqualIgnoreCase(ext, "tar") or
        asciiEqualIgnoreCase(ext, "tgz") or
        asciiEqualIgnoreCase(ext, "tar.gz");
}

/// Nome voce sicuro = relativo e senza componenti `..` (anti path-traversal /
/// zip-slip quando lo si materializza su disco).
fn isSafeEntryName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/' or name[0] == '\\') return false;
    var it = std.mem.splitAny(u8, name, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

/// Apre un file DENTRO un archivio (`archivio.zip#voce`): estrae la voce in
/// `~/.cache/zuer/extract/<hash>/<voce>` in streaming (memoria costante, cap =
/// `max_size` sulla dimensione decompressa) e la ridecodifica col decoder giusto
/// per la sua estensione, riusando l'intera pipeline. Riaperture della stessa
/// voce riusano il file già estratto (chiave = path archivio + mtime).
fn decodeArchiveEntry(base_path: []const u8, entry: []const u8, io: std.Io, allocator: std.mem.Allocator, max_size: usize) ?Decoded {
    const extracted = extractArchiveEntry(base_path, entry, io, allocator, max_size) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile aprire '{s}' dentro l'archivio: {s}", .{ entry, @errorName(err) }) catch "";
        return .{ .err = msg };
    };
    defer allocator.free(extracted);
    // Ridecodifica il file materializzato: senza frammento → dispatch normale per
    // estensione, nessuna ricorsione nel ramo archivio.
    return decodeImpl(extracted, io, allocator, false);
}

/// Materializza la voce dell'archivio su disco e ne ritorna il path assoluto
/// (posseduto dal chiamante). Riusa il file se già estratto per questa versione.
fn extractArchiveEntry(base_path: []const u8, entry: []const u8, io: std.Io, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    if (!isSafeEntryName(entry)) return error.UnsafeEntryName;

    const home_c = getenv("HOME") orelse return error.NoHomeDir;
    const home = std.mem.span(home_c);

    // Chiave cache = hash(path archivio + mtime): un archivio modificato cambia
    // chiave → riestrazione automatica.
    const bstat = try std.Io.Dir.cwd().statFile(io, base_path, .{});
    var hasher = std.hash.Wyhash.init(0x2571ee7c0de);
    hasher.update(base_path);
    hasher.update(std.mem.asBytes(&bstat.mtime.nanoseconds));
    const key = hasher.final();

    const rel_dir = try std.fmt.allocPrint(allocator, ".cache/zuer/extract/{x}", .{key});
    defer allocator.free(rel_dir);
    const rel_out = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_dir, entry });
    defer allocator.free(rel_out);
    const out_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, rel_out });
    errdefer allocator.free(out_abs);

    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    defer home_dir.close(io);

    // Già estratta (stessa versione dell'archivio)? Riusa senza rileggere.
    if (home_dir.statFile(io, rel_out, .{})) |_| return out_abs else |_| {}

    var dest = try home_dir.createDirPathOpen(io, rel_dir, .{});
    defer dest.close(io);

    // Estrazione ATOMICA: scrivi su `<voce>.part` e rinomina solo a estrazione
    // completa. La statFile di riuso sopra cerca `entry` (mai `.part`), quindi un
    // file parziale lasciato da un crash duro (SIGKILL, kernel panic) non viene mai
    // riusato come cache valida: alla riapertura manca `entry` → riestrazione.
    const tmp_name = try std.fmt.allocPrint(allocator, "{s}.part", .{entry});
    defer allocator.free(tmp_name);

    const ext = getExtension(base_path);
    (if (isTarExt(ext))
        extractTarEntry(base_path, entry, tmp_name, io, dest, max_size)
    else
        extractZipEntry(base_path, entry, tmp_name, io, dest, allocator, max_size)) catch |err| {
        // Estrazione fallita a metà (disco pieno, archivio corrotto…): rimuovi il
        // parziale così non resta a sporcare la cache.
        dest.deleteFile(io, tmp_name) catch {};
        return err;
    };
    dest.rename(tmp_name, dest, entry, io) catch |err| {
        dest.deleteFile(io, tmp_name) catch {};
        return err;
    };

    return out_abs;
}

fn extractZipEntry(base_path: []const u8, entry: []const u8, out_name: []const u8, io: std.Io, dest: std.Io.Dir, allocator: std.mem.Allocator, max_size: usize) !void {
    var file = try std.Io.Dir.cwd().openFile(io, base_path, .{});
    defer file.close(io);
    var rbuf: [8192]u8 = undefined;
    var reader = file.reader(io, &rbuf);

    // Localizza la central directory col seeking (EOCD/ZIP64) SENZA iterare le
    // voci: `Iterator.next()` abortirebbe su una entry cifrata/multi-disk anche se
    // non è quella cercata. Poi scan lenient della CD, coerente col listato — usa
    // il nome della CENTRAL directory, così il file estratto combacia con `out_abs`.
    const iter = try std.zip.Iterator.init(&reader);
    const cd_read: usize = @intCast(@min(iter.cd_size, @as(u64, 256 * 1024 * 1024)));
    const cd = try allocator.alloc(u8, cd_read);
    defer allocator.free(cd);
    try reader.seekTo(iter.cd_zip_offset);
    reader.interface.readSliceAll(cd) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return error.ZipReadFailed,
    };

    const max32 = std.math.maxInt(u32);
    var pos: usize = 0;
    while (pos + 46 <= cd.len) {
        if (!std.mem.eql(u8, cd[pos..][0..4], &std.zip.central_file_header_sig)) break;
        const method = std.mem.readInt(u16, cd[pos + 10 ..][0..2], .little);
        var comp_size: u64 = std.mem.readInt(u32, cd[pos + 20 ..][0..4], .little);
        var unc_size: u64 = std.mem.readInt(u32, cd[pos + 24 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, cd[pos + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, cd[pos + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, cd[pos + 32 ..][0..2], .little);
        var local_off: u64 = std.mem.readInt(u32, cd[pos + 42 ..][0..4], .little);

        const entry_end = pos + 46 + @as(usize, name_len) + extra_len + comment_len;
        if (entry_end > cd.len) break;
        const name = cd[pos + 46 ..][0..name_len];

        // ZIP64: campi saturati → valori reali nell'extra 0x0001, nell'ordine
        // uncompressed, compressed, local_header_offset (solo quelli saturati).
        if (unc_size == max32 or comp_size == max32 or local_off == max32) {
            var extra = cd[pos + 46 + name_len ..][0..extra_len];
            while (extra.len >= 4) {
                const id = std.mem.readInt(u16, extra[0..2], .little);
                const sz = std.mem.readInt(u16, extra[2..4], .little);
                if (4 + @as(usize, sz) > extra.len) break;
                if (id == 0x0001) {
                    var f = extra[4 .. 4 + sz];
                    if (unc_size == max32 and f.len >= 8) {
                        unc_size = std.mem.readInt(u64, f[0..8], .little);
                        f = f[8..];
                    }
                    if (comp_size == max32 and f.len >= 8) {
                        comp_size = std.mem.readInt(u64, f[0..8], .little);
                        f = f[8..];
                    }
                    if (local_off == max32 and f.len >= 8) {
                        local_off = std.mem.readInt(u64, f[0..8], .little);
                    }
                    break;
                }
                extra = extra[4 + sz ..];
            }
        }

        if (std.mem.eql(u8, name, entry)) {
            if (unc_size > max_size) return error.EntryTooLarge;
            return extractZipData(&reader, dest, io, out_name, method, unc_size, local_off);
        }
        pos = entry_end;
    }
    return error.EntryNotFound;
}

/// Decomprime una singola entry ZIP (store/deflate) dallo stream posizionato,
/// leggendo il local header per l'offset dei dati e scrivendo `entry` sotto `dest`.
fn extractZipData(reader: *std.Io.File.Reader, dest: std.Io.Dir, io: std.Io, out_name: []const u8, method: u16, unc_size: u64, local_off: u64) !void {
    try reader.seekTo(local_off);
    var lfh: [30]u8 = undefined;
    try reader.interface.readSliceAll(&lfh);
    if (!std.mem.eql(u8, lfh[0..4], &std.zip.local_file_header_sig)) return error.ZipBadFileOffset;
    const l_name = std.mem.readInt(u16, lfh[26..][0..2], .little);
    const l_extra = std.mem.readInt(u16, lfh[28..][0..2], .little);
    const data_off = local_off + 30 + @as(u64, l_name) + @as(u64, l_extra);

    var out = try createDestFile(dest, io, out_name);
    defer out.close(io);
    var obuf: [8192]u8 = undefined;
    var fw = out.writer(io, &obuf);

    try reader.seekTo(data_off);
    switch (method) {
        0 => try reader.interface.streamExact64(&fw.interface, unc_size),
        8 => {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var dc = std.compress.flate.Decompress.init(&reader.interface, .raw, &window);
            try dc.reader.streamExact64(&fw.interface, unc_size);
        },
        else => return error.UnsupportedCompressionMethod,
    }
    try fw.end();
}

fn extractTarEntry(base_path: []const u8, entry: []const u8, out_name: []const u8, io: std.Io, dest: std.Io.Dir, max_size: usize) !void {
    var file = try std.Io.Dir.cwd().openFile(io, base_path, .{});
    defer file.close(io);
    var rbuf: [8192]u8 = undefined;
    var reader = file.reader(io, &rbuf);

    var magic: [2]u8 = .{ 0, 0 };
    _ = try file.readPositionalAll(io, &magic, 0);
    const is_gzip = magic[0] == 0x1f and magic[1] == 0x8b;

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = undefined;
    var src: *std.Io.Reader = &reader.interface;
    if (is_gzip) {
        dec = std.compress.flate.Decompress.init(&reader.interface, .gzip, &window);
        src = &dec.reader;
    }

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(src, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });
    while (try it.next()) |f| {
        if (f.kind != .file) continue;
        if (!std.mem.eql(u8, f.name, entry)) continue;
        if (f.size > max_size) return error.EntryTooLarge;

        var out_file = try createDestFile(dest, io, out_name);
        defer out_file.close(io);
        var obuf: [8192]u8 = undefined;
        var fw = out_file.writer(io, &obuf);
        try it.streamRemaining(f, &fw.interface);
        try fw.end();
        return;
    }
    return error.EntryNotFound;
}

/// Crea (con eventuali sottocartelle) e apre in scrittura il file di output per
/// una voce, sotto `dest`.
fn createDestFile(dest: std.Io.Dir, io: std.Io, name: []const u8) !std.Io.File {
    if (std.fs.path.dirname(name)) |dn| {
        var parent = try dest.createDirPathOpen(io, dn, .{});
        defer parent.close(io);
        return parent.createFile(io, std.fs.path.basename(name), .{});
    }
    return dest.createFile(io, name, .{});
}

fn decodeImpl(path: []const u8, io: std.Io, allocator: std.mem.Allocator, coarse: bool) ?Decoded {
    var clean_path = path;
    var fragment: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, path, '#')) |hash_idx| {
        clean_path = path[0..hash_idx];
        if (hash_idx + 1 < path.len) fragment = path[hash_idx + 1 ..];
    }

    // Limite di dimensione proporzionale alla memoria disponibile; ZUER_MAX_MB lo
    // forza a un valore assoluto. Pre-check via stat per rifiutare i file troppo
    // grandi prima di allocarli.
    var max_size: usize = defaultMaxSize(io, allocator);
    if (getenv("ZUER_MAX_MB")) |val| {
        if (std.fmt.parseInt(usize, std.mem.span(val), 10)) |mb| {
            max_size = mb * 1024 * 1024;
        } else |_| {}
    }

    // Anteprima di un file DENTRO un archivio: `archivio.zip#voce`. Gate sull'ext
    // dell'archivio così lo `#N` dei PDF e lo `#foglio` degli XLSX restano ai loro
    // plugin. La voce viene estratta in cache (streaming) e ridecodificata dal
    // decoder giusto per la sua estensione → immagini/testo/pdf/… interni si aprono
    // col loro viewer nativo. In fase coarse si salta: l'host farà il full decode.
    if (!coarse) {
        if (fragment) |entry| {
            if (entry.len > 0 and isArchiveExt(getExtension(clean_path)))
                return decodeArchiveEntry(clean_path, entry, io, allocator, max_size);
        }
    }

    const stat = std.Io.Dir.cwd().statFile(io, clean_path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile ottenere informazioni sul file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
        return .{ .err = msg };
    };
    // Il limite di dimensione NON viene applicato qui su `stat.size`: un plugin
    // path-based (`zuer_content_prefix = 0`, es. archivi grandi) non carica il
    // file in RAM e deve poter aprire anche archivi da molti GB. Il tetto viene
    // verificato più sotto su `to_read` — i byte che si allocheranno davvero —
    // così i plugin whole-file restano protetti mentre quelli streaming no.

    const mtime_ns: i128 = stat.mtime.nanoseconds;

    // Fase coarse: se esiste una mesh coarse cachata (geometria + texture 256²)
    // valida per questo file (mtime combaciante), ricostruiscila senza leggere né
    // ridecodificare i decine di MB del sorgente → ritorno quasi istantaneo. Miss
    // → si prosegue col decode coarse normale (che popolerà anche questa cache).
    if (coarse) {
        if (meshcache.readCoarse(allocator, clean_path, mtime_ns)) |m|
            return .{ .mesh = m };
    }

    // Risolve il decoder dal registro PRIMA di leggere il contenuto: prima per
    // estensione dichiarata dai plugin stessi, poi immagine per byte magici
    // (basta un piccolo prefisso), infine "text" come fallback. Così la fase
    // coarse di un plugin senza `zuer_decode_coarse` ritorna subito null senza
    // pagare la lettura dell'intero file, e la lettura completa avviene solo
    // quando un decode verrà davvero eseguito.
    const ext = getExtension(clean_path);

    var ext_fn: ?DecodeFn = null;
    var ext_found = false;
    var ext_prefix: usize = std.math.maxInt(usize);
    var image_fn: ?DecodeFn = null;
    var image_found = false;
    var image_prefix: usize = std.math.maxInt(usize);
    var text_fn: ?DecodeFn = null;
    {
        while (!plugin_cache_mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer plugin_cache_mutex.unlock();
        ensureRegistryLocked(io, allocator);
        if (findPluginByExtension(ext)) |p| {
            ext_found = true;
            ext_fn = if (coarse) p.decode_coarse_fn else p.decode_fn;
            ext_prefix = p.content_prefix;
        } else {
            if (findPluginByName("image")) |p| {
                image_found = true;
                image_fn = if (coarse) p.decode_coarse_fn else p.decode_fn;
                image_prefix = p.content_prefix;
            }
            if (findPluginByName("text")) |p| {
                text_fn = if (coarse) p.decode_coarse_fn else p.decode_fn;
            }
        }
    }

    // Fase coarse senza alcun candidato con `zuer_decode_coarse` → null subito,
    // senza toccare il file: l'host farà solo il decode full.
    if (coarse and ext_fn == null and image_fn == null and text_fn == null) return null;

    var decode_fn: ?DecodeFn = ext_fn;
    var content_prefix: usize = ext_prefix;
    if (!ext_found) {
        // Estensione ignota al registro: servono i primi byte per riconoscere
        // un'immagine con nome sbagliato/assente. Prefisso, non l'intero file.
        var probe_buf: [16]u8 = undefined;
        var probe_len: usize = 0;
        {
            var file = std.Io.Dir.cwd().openFile(io, clean_path, .{}) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "Impossibile aprire o leggere il file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
                return .{ .err = msg };
            };
            defer file.close(io);
            var rbuf: [64]u8 = undefined;
            var reader = file.readerStreaming(io, &rbuf);
            probe_len = reader.interface.readSliceShort(&probe_buf) catch 0;
        }
        if (image_found and guessImageFormat(probe_buf[0..probe_len])) {
            decode_fn = image_fn;
            content_prefix = image_prefix;
        } else {
            decode_fn = text_fn;
            content_prefix = std.math.maxInt(usize);
        }
    }

    // In fase coarse un plugin senza `zuer_decode_coarse` → null: l'host farà il full.
    if (coarse and decode_fn == null) return null;
    const decode_fn_val = decode_fn orelse {
        const msg = std.fmt.allocPrint(allocator, "Nessun plugin decoder disponibile per '.{s}' (cartella decoders/ vuota o mancante)", .{ext}) catch "";
        return .{ .err = msg };
    };

    // Legge solo quanto dichiarato dal plugin (`zuer_content_prefix`): 0 = il
    // plugin lavora dal path (pdf), N = bastano i primi N byte (media: header
    // sniffing — un video multi-GB non va caricato in RAM per il poster).
    // Default (nessun export): file intero, comportamento storico.
    const file_size: usize = @intCast(stat.size);
    const to_read = @min(content_prefix, file_size);
    // Il limite si applica QUI, su ciò che verrà davvero allocato (`to_read`), non
    // sulla dimensione del file su disco: un plugin path-based (`content_prefix=0`,
    // `to_read=0`, es. archivi) apre qualsiasi dimensione senza rischio di OOM,
    // mentre i plugin whole-file (`content_prefix=maxInt`, `to_read=file_size`)
    // restano protetti esattamente come prima.
    if (to_read > max_size) {
        const msg = std.fmt.allocPrint(allocator, "File troppo grande: {d} MB (limite {d} MB, ~metà della memoria disponibile).\nIl caricamento rischierebbe di esaurire la memoria.", .{ to_read / (1024 * 1024), max_size / (1024 * 1024) }) catch "";
        return .{ .err = msg };
    }
    const content: []u8 = if (to_read == 0) &.{} else if (to_read < file_size) blk: {
        // Prefisso parziale: si legge esattamente to_read byte dall'inizio.
        const buf = allocator.alloc(u8, to_read) catch return .{ .err = "Out of memory" };
        var file = std.Io.Dir.cwd().openFile(io, clean_path, .{}) catch |err| {
            allocator.free(buf);
            const msg = std.fmt.allocPrint(allocator, "Impossibile aprire o leggere il file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
            return .{ .err = msg };
        };
        defer file.close(io);
        var rbuf: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &rbuf);
        reader.interface.readSliceAll(buf) catch |err| {
            // File cambiato/troncato tra stat e read: errore pulito, niente prefisso a metà.
            allocator.free(buf);
            const msg = std.fmt.allocPrint(allocator, "Impossibile leggere il file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
            return .{ .err = msg };
        };
        break :blk buf;
    } else std.Io.Dir.cwd().readFileAlloc(io, clean_path, allocator, std.Io.Limit.limited(max_size)) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile aprire o leggere il file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
        return .{ .err = msg };
    };
    // Da qui in poi `content` appartiene al plugin (vedi contratto in DecodeFn):
    // lo libera lui, anche in caso di errore.

    const decoded_c = decode_fn_val(
        SliceC.fromSlice(path),
        SliceC.fromSlice(content),
        &io,
        &allocator,
    );

    // Convert the C-compatible decoded structure back to Zig union
    const decoded_data = decoded_c.toDecoded(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Errore conversione struttura C in plugin: {s}", .{@errorName(err)}) catch "";
        return .{ .err = msg };
    };

    // Popola/aggiorna la cache mesh coarse dal decode full (texture downscalate a
    // 256²) → la prossima apertura/ritorno usa il fast-path sopra, senza toccare
    // il file né il decoder. Best-effort, non blocca il ritorno.
    if (!coarse and decoded_data == .mesh)
        meshcache.writeCoarse(allocator, clean_path, mtime_ns, &decoded_data.mesh);

    return decoded_data;
}

fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

pub fn getExtension(path: []const u8) []const u8 {
    const filename = std.fs.path.basename(path);
    // Doppio suffisso `.tar.gz`: l'estensione utile è "tar.gz", non "gz" (un `.gz`
    // semplice resta invece "gz", non dirottato sul decoder tar).
    if (filename.len >= 7 and asciiEqualIgnoreCase(filename[filename.len - 7 ..], ".tar.gz"))
        return "tar.gz";
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_index| {
        return filename[dot_index + 1 ..];
    }
    return "";
}
