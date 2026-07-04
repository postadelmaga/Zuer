const std = @import("std");

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
        for (self.submeshes) |s| {
            if (s.tex_pixels.len > 0) allocator.free(s.tex_pixels);
            if (s.nrm_tex_pixels.len > 0) allocator.free(s.nrm_tex_pixels);
        }
        if (self.submeshes.len > 0) allocator.free(self.submeshes);
    }
};

pub const ImageData = struct {
    width: usize,
    height: usize,
    pixels: []const u8, // RGB 24-bit
    name: []const u8,

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

const LoadedPlugin = struct {
    type_name: []const u8,
    extensions: []const []const u8,
    lib: std.DynLib,
    decode_fn: DecodeFn,
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

const plugin_prefix = "libdecoder_";
const plugin_suffix = ".so";

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

        var lib = std.DynLib.open(full_path) catch continue;
        const decode_fn = lib.lookup(DecodeFn, "zuer_decode") orelse {
            lib.close();
            continue;
        };

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

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
// posix_spawn: fork+exec+ricerca PATH in modo sicuro anche in processi
// multi-thread (niente malloc nel figlio forkato → niente deadlock, a
// differenza di fork()+execvp manuale).
extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, file_actions: ?*const anyopaque, attrp: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(fa: *anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_destroy(fa: *anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(fa: *anyopaque, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(fa: *anyopaque, fd: c_int) c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

pub const RunResult = struct {
    stdout: []u8,
    exit_code: u8,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
    }
};

/// Esegue un comando catturandone lo stdout, con fork/exec/pipe diretti — senza
/// dipendere da `std.Io`. `std.process.run` NON funziona dentro i plugin `.so`:
/// l'`io` dell'host non attraversa il confine DynLib e la run si blocca. Questo
/// helper libc-based è invece indipendente dal contesto e va bene nei plugin.
pub fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    if (argv.len == 0) return error.EmptyArgv;

    // argv null-terminato costruito PRIMA della fork: nel figlio non si può
    // allocare in sicurezza (processo multi-thread → solo funzioni async-signal-safe).
    const argvZ = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    defer {
        for (argvZ[0..argv.len]) |a| if (a) |p| allocator.free(std.mem.span(p));
        allocator.free(argvZ);
    }
    for (argv, 0..) |a, i| argvZ[i] = (try allocator.dupeZ(u8, a)).ptr;

    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return error.PipeFailed;
    const read_fd = fds[0];
    const write_fd = fds[1];
    defer _ = close(read_fd);

    // file_actions: stdout del figlio → estremo di scrittura della pipe, e
    // chiusura dell'estremo di lettura. Buffer sovradimensionato per l'opaco
    // posix_spawn_file_actions_t (glibc ~80 byte).
    var fa: [256]u8 align(16) = undefined;
    if (posix_spawn_file_actions_init(&fa) != 0) {
        _ = close(write_fd);
        return error.SpawnInit;
    }
    defer _ = posix_spawn_file_actions_destroy(&fa);
    _ = posix_spawn_file_actions_adddup2(&fa, write_fd, 1);
    _ = posix_spawn_file_actions_addclose(&fa, read_fd);

    var pid: c_int = 0;
    const rc = posix_spawnp(&pid, argvZ[0].?, &fa, null, argvZ.ptr, environ);
    _ = close(write_fd);
    if (rc != 0) return if (rc == 2) error.CommandNotFound else error.SpawnFailed; // 2 = ENOENT
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = read(read_fd, &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    // WIFEXITED / WEXITSTATUS espansi a mano (glibc): byte basso = segnale.
    const code: u8 = if ((status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else 1;
    return .{ .stdout = try out.toOwnedSlice(allocator), .exit_code = code };
}

/// Legge un intero file con open/read/close libc (niente `std.Io`): come
/// runCapture, evita che l'io dell'host — usato dentro un plugin `.so` sul
/// thread worker del loader — si blocchi. Il chiamante possiede il buffer.
pub fn readFileLibc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
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

/// Budget di dimensione file di default, proporzionale alla memoria disponibile:
/// metà di MemAvailable (il file viene letto in RAM e il decoder vi alloca sopra).
/// Fallback a 128 MB se /proc/meminfo non è leggibile.
fn defaultMaxSize(io: std.Io, allocator: std.mem.Allocator) usize {
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
    var clean_path = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |hash_idx| {
        clean_path = path[0..hash_idx];
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

    const stat = std.Io.Dir.cwd().statFile(io, clean_path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile ottenere informazioni sul file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
        return .{ .err = msg };
    };
    if (stat.size > max_size) {
        const msg = std.fmt.allocPrint(allocator, "File troppo grande: {d} MB (limite {d} MB, ~metà della memoria disponibile).\nIl caricamento rischierebbe di esaurire la memoria.", .{ stat.size / (1024 * 1024), max_size / (1024 * 1024) }) catch "";
        return .{ .err = msg };
    }

    const limit = std.Io.Limit.limited(max_size);
    const content = std.Io.Dir.cwd().readFileAlloc(io, clean_path, allocator, limit) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile aprire o leggere il file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
        return .{ .err = msg };
    };
    errdefer allocator.free(content);

    // Risolve il decoder dal registro: prima per estensione dichiarata dai
    // plugin stessi, poi immagine per byte magici, infine "text" come fallback.
    const ext = getExtension(clean_path);

    while (!plugin_cache_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    ensureRegistryLocked(io, allocator);
    var plugin = findPluginByExtension(ext);
    if (plugin == null and guessImageFormat(content)) plugin = findPluginByName("image");
    if (plugin == null) plugin = findPluginByName("text");
    const decode_fn: ?DecodeFn = if (plugin) |p| p.decode_fn else null;
    plugin_cache_mutex.unlock();

    const decode_fn_val = decode_fn orelse {
        const msg = std.fmt.allocPrint(allocator, "Nessun plugin decoder disponibile per '.{s}' (cartella decoders/ vuota o mancante)", .{ext}) catch "";
        allocator.free(content);
        return .{ .err = msg };
    };

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

    return decoded_data;
}

fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn getExtension(path: []const u8) []const u8 {
    const filename = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_index| {
        return filename[dot_index + 1 ..];
    }
    return "";
}
