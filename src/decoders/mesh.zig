const std = @import("std");
const decoder = @import("decoder");
const MeshData = decoder.MeshData;
const Face = decoder.Face;
const Decoded = decoder.Decoded;

pub fn decode(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
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
