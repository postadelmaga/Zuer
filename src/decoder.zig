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

pub const MeshData = struct {
    num_vertices: usize,
    num_faces: usize,
    num_normals: usize,
    bbox_min: [3]f32,
    bbox_max: [3]f32,
    center: [3]f32,
    name: []const u8,

    pub fn deinit(self: *MeshData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const Decoded = union(enum) {
    text: []const u8,
    csv: CsvData,
    markdown: MarkdownData,
    mesh: MeshData,
    err: []const u8,

    pub fn deinit(self: *Decoded) void {
        const allocator = @import("state.zig").global_gpa;
        switch (self.*) {
            .text => |t| allocator.free(t),
            .csv => |*c| c.deinit(allocator),
            .markdown => |*m| m.deinit(allocator),
            .mesh => |*m| m.deinit(allocator),
            .err => |e| allocator.free(e),
        }
    }
};

const text_decoder = @import("decoders/text.zig");
const csv_decoder = @import("decoders/csv.zig");
const markdown_decoder = @import("decoders/markdown.zig");
const mesh_decoder = @import("decoders/mesh.zig");

pub fn decode(path: []const u8, io: std.Io, allocator: std.mem.Allocator) Decoded {
    const max_size = 128 * 1024 * 1024;
    const limit = std.Io.Limit.limited(max_size);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile aprire o leggere il file: {s} ({s})", .{ path, @errorName(err) }) catch "Errore di lettura";
        return .{ .err = msg };
    };
    errdefer allocator.free(content);

    // Sniff format based on file extension
    const ext = getExtension(path);
    if (std.mem.eql(u8, ext, "csv") or std.mem.eql(u8, ext, "tsv")) {
        const delimiter: u8 = if (std.mem.eql(u8, ext, "tsv")) '\t' else ',';
        return csv_decoder.decode(content, delimiter, allocator);
    } else if (std.mem.eql(u8, ext, "md") or std.mem.eql(u8, ext, "markdown")) {
        return markdown_decoder.decode(content, allocator);
    } else if (std.mem.eql(u8, ext, "obj")) {
        return mesh_decoder.decode(content, std.fs.path.basename(path), allocator);
    } else {
        // Fallback to text if it looks like UTF-8
        return text_decoder.decode(content, allocator);
    }
}

fn getExtension(path: []const u8) []const u8 {
    const filename = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_index| {
        return filename[dot_index + 1 ..];
    }
    return "";
}
