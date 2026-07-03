const std = @import("std");
const decoder = @import("decoder");
const Face = decoder.Face;
const Decoded = decoder.Decoded;

pub fn decode(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    if (hasExtension(filename, ".stl")) {
        return decodeStl(bytes, filename, allocator);
    }
    return decodeObj(bytes, filename, allocator);
}

fn hasExtension(filename: []const u8, comptime ext: []const u8) bool {
    if (filename.len < ext.len) return false;
    const tail = filename[filename.len - ext.len ..];
    for (tail, ext) |a, b| {
        if (std.ascii.toLower(a) != b) return false;
    }
    return true;
}

fn decodeObj(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    defer allocator.free(bytes);

    var vertices = std.ArrayList([3]f32).empty;
    errdefer vertices.deinit(allocator);

    var faces = std.ArrayList(Face).empty;
    errdefer faces.deinit(allocator);

    var num_normals: usize = 0;
    var bbox_min = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var bbox_max = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };

    var line_it = std.mem.splitScalar(u8, bytes, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var token_it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const prefix = token_it.next() orelse continue;

        if (std.mem.eql(u8, prefix, "v")) {
            const x_str = token_it.next() orelse continue;
            const y_str = token_it.next() orelse continue;
            const z_str = token_it.next() orelse continue;

            const x = std.fmt.parseFloat(f32, x_str) catch continue;
            const y = std.fmt.parseFloat(f32, y_str) catch continue;
            const z = std.fmt.parseFloat(f32, z_str) catch continue;

            vertices.append(allocator, .{ x, y, z }) catch continue;

            bbox_min[0] = @min(bbox_min[0], x);
            bbox_min[1] = @min(bbox_min[1], y);
            bbox_min[2] = @min(bbox_min[2], z);

            bbox_max[0] = @max(bbox_max[0], x);
            bbox_max[1] = @max(bbox_max[1], y);
            bbox_max[2] = @max(bbox_max[2], z);
        } else if (std.mem.eql(u8, prefix, "vn")) {
            num_normals += 1;
        } else if (std.mem.eql(u8, prefix, "f")) {
            var v_indices = std.ArrayList(usize).empty;
            defer v_indices.deinit(allocator);

            while (token_it.next()) |token| {
                var part_it = std.mem.splitScalar(u8, token, '/');
                const idx_str = part_it.next() orelse continue;
                const idx = std.fmt.parseInt(isize, idx_str, 10) catch continue;

                const u_idx: usize = if (idx > 0)
                    @as(usize, @intCast(idx - 1))
                else
                    @as(usize, @intCast(@as(isize, @intCast(vertices.items.len)) + idx));

                v_indices.append(allocator, u_idx) catch {};
            }

            if (v_indices.items.len >= 3) {
                var i: usize = 1;
                while (i < v_indices.items.len - 1) : (i += 1) {
                    faces.append(allocator, .{
                        .v1 = v_indices.items[0],
                        .v2 = v_indices.items[i],
                        .v3 = v_indices.items[i + 1],
                    }) catch {};
                }
            }
        }
    }

    const name = allocator.dupe(u8, filename) catch "unknown_mesh";

    var center = [3]f32{ 0, 0, 0 };
    if (vertices.items.len > 0) {
        center[0] = (bbox_min[0] + bbox_max[0]) / 2.0;
        center[1] = (bbox_min[1] + bbox_max[1]) / 2.0;
        center[2] = (bbox_min[2] + bbox_max[2]) / 2.0;
    } else {
        bbox_min = .{ 0, 0, 0 };
        bbox_max = .{ 0, 0, 0 };
    }

    return .{ .mesh = .{
        .num_vertices = vertices.items.len,
        .num_faces = faces.items.len,
        .num_normals = num_normals,
        .bbox_min = bbox_min,
        .bbox_max = bbox_max,
        .center = center,
        .name = name,
        .vertices = vertices.toOwnedSlice(allocator) catch &.{},
        .faces = faces.toOwnedSlice(allocator) catch &.{},
    } };
}

/// STL binario e ASCII. La discriminazione è per coerenza di dimensione
/// (84 + n*50 ≈ len, con tolleranza per il padding), non per l'header
/// "solid": gli STL binari possono legittimamente iniziare con quel testo.
fn decodeStl(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    defer allocator.free(bytes);

    var vertices = std.ArrayList([3]f32).empty;
    errdefer vertices.deinit(allocator);
    var faces = std.ArrayList(Face).empty;
    errdefer faces.deinit(allocator);

    var num_normals: usize = 0;
    var bbox_min = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var bbox_max = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };

    var is_binary = false;
    if (bytes.len >= 84) {
        const tri_count = std.mem.readInt(u32, bytes[80..84], .little);
        const exact = 84 + @as(u64, tri_count) * 50;
        // Alcuni exporter CAD accodano padding dopo l'ultimo triangolo:
        // si tollera fino a 1 KiB oltre la dimensione dichiarata.
        is_binary = tri_count > 0 and exact <= bytes.len and bytes.len - exact <= 1024;
    }

    if (is_binary) {
        const tri_count = std.mem.readInt(u32, bytes[80..84], .little);
        num_normals = tri_count;
        var i: usize = 0;
        while (i < tri_count) : (i += 1) {
            // 12 byte di normale, poi 3 vertici da 12 byte, poi 2 byte di attributi
            const tri = bytes[84 + i * 50 ..][0..50];
            var v: usize = 0;
            while (v < 3) : (v += 1) {
                const off = 12 + v * 12;
                const x: f32 = @bitCast(std.mem.readInt(u32, tri[off..][0..4], .little));
                const y: f32 = @bitCast(std.mem.readInt(u32, tri[off + 4 ..][0..4], .little));
                const z: f32 = @bitCast(std.mem.readInt(u32, tri[off + 8 ..][0..4], .little));
                vertices.append(allocator, .{ x, y, z }) catch break;
                bbox_min = .{ @min(bbox_min[0], x), @min(bbox_min[1], y), @min(bbox_min[2], z) };
                bbox_max = .{ @max(bbox_max[0], x), @max(bbox_max[1], y), @max(bbox_max[2], z) };
            }
            const base = vertices.items.len;
            if (base >= 3) {
                faces.append(allocator, .{ .v1 = base - 3, .v2 = base - 2, .v3 = base - 1 }) catch {};
            }
        }
    } else {
        // ASCII: ogni "vertex x y z" accumula; ogni 3 vertici chiude un triangolo.
        var pending: usize = 0;
        var line_it = std.mem.splitScalar(u8, bytes, '\n');
        while (line_it.next()) |line| {
            var token_it = std.mem.tokenizeAny(u8, line, " \t\r");
            const prefix = token_it.next() orelse continue;
            if (std.mem.eql(u8, prefix, "facet")) {
                num_normals += 1;
            } else if (std.mem.eql(u8, prefix, "vertex")) {
                const x = std.fmt.parseFloat(f32, token_it.next() orelse continue) catch continue;
                const y = std.fmt.parseFloat(f32, token_it.next() orelse continue) catch continue;
                const z = std.fmt.parseFloat(f32, token_it.next() orelse continue) catch continue;
                vertices.append(allocator, .{ x, y, z }) catch continue;
                bbox_min = .{ @min(bbox_min[0], x), @min(bbox_min[1], y), @min(bbox_min[2], z) };
                bbox_max = .{ @max(bbox_max[0], x), @max(bbox_max[1], y), @max(bbox_max[2], z) };
                pending += 1;
                if (pending == 3) {
                    pending = 0;
                    const base = vertices.items.len;
                    faces.append(allocator, .{ .v1 = base - 3, .v2 = base - 2, .v3 = base - 1 }) catch {};
                }
            }
        }
        if (vertices.items.len == 0) {
            vertices.deinit(allocator);
            faces.deinit(allocator);
            const msg = allocator.dupe(u8, "STL non valido: nessun triangolo trovato.") catch "STL non valido";
            return .{ .err = msg };
        }
    }

    const name = allocator.dupe(u8, filename) catch "unknown_mesh";

    var center = [3]f32{ 0, 0, 0 };
    if (vertices.items.len > 0) {
        center = .{
            (bbox_min[0] + bbox_max[0]) / 2.0,
            (bbox_min[1] + bbox_max[1]) / 2.0,
            (bbox_min[2] + bbox_max[2]) / 2.0,
        };
    } else {
        bbox_min = .{ 0, 0, 0 };
        bbox_max = .{ 0, 0, 0 };
    }

    return .{ .mesh = .{
        .num_vertices = vertices.items.len,
        .num_faces = faces.items.len,
        .num_normals = num_normals,
        .bbox_min = bbox_min,
        .bbox_max = bbox_max,
        .center = center,
        .name = name,
        .vertices = vertices.toOwnedSlice(allocator) catch &.{},
        .faces = faces.toOwnedSlice(allocator) catch &.{},
    } };
}

export fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const path_slice = path.toSlice();
    const content_slice = content.toSlice();
    const filename = std.fs.path.basename(path_slice);
    const decoded = decode(content_slice, filename, allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

const extensions = "obj,stl";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}
