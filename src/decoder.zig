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

    pub fn deinit(self: *MeshData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.vertices);
        allocator.free(self.faces);
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
    markdown: MarkdownData,
    mesh: MeshData,
    image: ImageData,
    err: []const u8,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |t| allocator.free(t),
            .csv => |*c| c.deinit(allocator),
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
                // Free container arrays of the original (the leaves are kept, now owned by DecodedC)
                allocator.free(c.headers);
                for (c.rows) |row| {
                    allocator.free(row);
                }
                allocator.free(c.rows);

                return .{
                    .tag = .csv,
                    .payload = .{
                        .csv = .{
                            .headers = .{ .ptr = headers_c.ptr, .len = headers_c.len },
                            .rows = .{ .ptr = rows_c.ptr, .len = rows_c.len },
                        },
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

pub const MarkdownDataC = extern struct {
    content: SliceC,
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
};

pub const DecodedC = extern struct {
    tag: DecodedTag,
    payload: extern union {
        text: SliceC,
        csv: CsvDataC,
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
                const c = self.payload.csv;
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

                return .{
                    .csv = .{
                        .headers = headers,
                        .rows = rows,
                    },
                };
            },
            .markdown => {
                const m = self.payload.markdown;
                return .{
                    .markdown = .{ .content = m.content.toSlice() },
                };
            },
            .mesh => {
                const m = self.payload.mesh;
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

const LoadedPlugin = struct {
    type_name: []const u8,
    lib: std.DynLib,
    decode_fn: *const fn (
        path: SliceC,
        content: SliceC,
        io_ptr: *const anyopaque,
        allocator_ptr: *const anyopaque,
    ) callconv(.c) DecodedC,
};

var plugin_cache: std.ArrayList(LoadedPlugin) = .empty;
var plugin_cache_mutex: std.atomic.Mutex = .unlocked;

/// Chiude i plugin caricati e libera la cache. Da chiamare a fine processo,
/// dopo il join di tutti i thread che possono decodificare.
pub fn closePluginCache(allocator: std.mem.Allocator) void {
    while (!plugin_cache_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer plugin_cache_mutex.unlock();

    for (plugin_cache.items) |*p| {
        allocator.free(p.type_name);
        p.lib.close();
    }
    plugin_cache.deinit(allocator);
    plugin_cache = .empty;
}

pub fn decode(path: []const u8, io: std.Io, allocator: std.mem.Allocator) Decoded {
    const max_size = 128 * 1024 * 1024;
    const limit = std.Io.Limit.limited(max_size);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile aprire o leggere il file: {s} ({s})", .{ path, @errorName(err) }) catch "";
        return .{ .err = msg };
    };
    errdefer allocator.free(content);

    // Sniff format based on file extension
    const ext = getExtension(path);
    const plugin_type = if (extIn(ext, &.{ "csv", "tsv" }))
        "csv"
    else if (extIn(ext, &.{ "md", "markdown" }))
        "markdown"
    else if (extIn(ext, &.{"obj"}))
        "mesh"
    else if (extIn(ext, &.{"glb"}))
        "glb"
    else if (extIn(ext, &.{ "png", "jpg", "jpeg", "gif", "bmp", "svg" }))
        "image"
    else if (extIn(ext, &.{ "zip", "jar", "apk", "cbz", "epub", "xpi", "whl" }))
        "archive"
    else if (extIn(ext, &.{ "mp3", "wav", "flac", "ogg", "oga", "ogv", "opus", "m4a", "mp4", "m4v", "mov", "mkv", "webm", "avi" }))
        "media"
    else
        "text";

    const lib_name = std.fmt.allocPrint(allocator, "libdecoder_{s}.so", .{plugin_type}) catch return .{ .err = "" };
    defer allocator.free(lib_name);

    // 1. Locate the decoder plugin .so file
    var plugin_path: ?[]const u8 = null;
    if (std.process.executableDirPathAlloc(io, allocator)) |exe_dir| {
        defer allocator.free(exe_dir);
        // Try production path: <exe_dir>/decoders/libdecoder_<type>.so
        const p1 = std.fs.path.join(allocator, &.{ exe_dir, "decoders", lib_name }) catch null;
        if (p1) |p| {
            if (std.Io.Dir.cwd().access(io, p, .{})) |_| {
                plugin_path = p;
            } else |_| {
                allocator.free(p);
            }
        }
        // Try adjacent path: <exe_dir>/libdecoder_<type>.so
        if (plugin_path == null) {
            const p2 = std.fs.path.join(allocator, &.{ exe_dir, lib_name }) catch null;
            if (p2) |p| {
                if (std.Io.Dir.cwd().access(io, p, .{})) |_| {
                    plugin_path = p;
                } else |_| {
                    allocator.free(p);
                }
            }
        }
    } else |_| {}

    // Try relative paths in CWD
    if (plugin_path == null) {
        const rp1 = std.fmt.allocPrint(allocator, "zig-out/lib/{s}", .{lib_name}) catch null;
        const rp2 = std.fmt.allocPrint(allocator, "decoders/{s}", .{lib_name}) catch null;
        defer {
            if (rp1) |p| allocator.free(p);
            if (rp2) |p| allocator.free(p);
        }

        if (rp1) |p| {
            if (std.Io.Dir.cwd().access(io, p, .{})) |_| {
                plugin_path = allocator.dupe(u8, p) catch null;
            } else |_| {}
        }
        if (plugin_path == null and rp2 != null) {
            const p = rp2.?;
            if (std.Io.Dir.cwd().access(io, p, .{})) |_| {
                plugin_path = allocator.dupe(u8, p) catch null;
            } else |_| {}
        }
    }

    const path_val = plugin_path orelse {
        const msg = std.fmt.allocPrint(allocator, "Decoder plugin non trovato per il tipo: {s}", .{plugin_type}) catch "";
        allocator.free(content);
        return .{ .err = msg };
    };
    defer allocator.free(path_val);

    // 2. Load the plugin and get decode function (utilizing thread-safe caching)
    var cached_fn: ?*const fn (
        path: SliceC,
        content: SliceC,
        io_ptr: *const anyopaque,
        allocator_ptr: *const anyopaque,
    ) callconv(.c) DecodedC = null;

    while (!plugin_cache_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    for (plugin_cache.items) |p| {
        if (std.mem.eql(u8, p.type_name, plugin_type)) {
            cached_fn = p.decode_fn;
            break;
        }
    }

    if (cached_fn == null) {
        var lib = std.DynLib.open(path_val) catch |err| {
            plugin_cache_mutex.unlock();
            const msg = std.fmt.allocPrint(allocator, "Impossibile caricare il plugin {s}: {s}", .{ path_val, @errorName(err) }) catch "";
            allocator.free(content);
            return .{ .err = msg };
        };

        const DecodeFn = *const fn (
            path: SliceC,
            content: SliceC,
            io_ptr: *const anyopaque,
            allocator_ptr: *const anyopaque,
        ) callconv(.c) DecodedC;

        const decode_fn = lib.lookup(DecodeFn, "zuer_decode") orelse {
            lib.close();
            plugin_cache_mutex.unlock();
            const msg = std.fmt.allocPrint(allocator, "Simbolo zuer_decode non trovato nel plugin: {s}", .{path_val}) catch "";
            allocator.free(content);
            return .{ .err = msg };
        };

        // Se la registrazione in cache fallisce si decodifica comunque:
        // il plugin resta solo non riutilizzabile (verrà ricaricato).
        if (allocator.dupe(u8, plugin_type)) |type_name_dup| {
            plugin_cache.append(allocator, .{
                .type_name = type_name_dup,
                .lib = lib,
                .decode_fn = decode_fn,
            }) catch allocator.free(type_name_dup);
        } else |_| {}

        cached_fn = decode_fn;
    }
    plugin_cache_mutex.unlock();

    // 3. Perform decoding using the loaded dynamic function
    const decoded_c = cached_fn.?(
        SliceC.fromSlice(path),
        SliceC.fromSlice(content),
        &io,
        &allocator,
    );

    // 4. Convert the C-compatible decoded structure back to Zig union
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

fn extIn(ext: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |e| {
        if (asciiEqualIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn getExtension(path: []const u8) []const u8 {
    const filename = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_index| {
        return filename[dot_index + 1 ..];
    }
    return "";
}
