const std = @import("std");
const decoder = @import("../decoder.zig");
const MeshData = decoder.MeshData;
const Decoded = decoder.Decoded;

pub fn decode(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    defer allocator.free(bytes);

    var num_vertices: usize = 0;
    var num_faces: usize = 0;
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
            num_vertices += 1;
            const x_str = token_it.next() orelse continue;
            const y_str = token_it.next() orelse continue;
            const z_str = token_it.next() orelse continue;

            const x = std.fmt.parseFloat(f32, x_str) catch continue;
            const y = std.fmt.parseFloat(f32, y_str) catch continue;
            const z = std.fmt.parseFloat(f32, z_str) catch continue;

            bbox_min[0] = @min(bbox_min[0], x);
            bbox_min[1] = @min(bbox_min[1], y);
            bbox_min[2] = @min(bbox_min[2], z);

            bbox_max[0] = @max(bbox_max[0], x);
            bbox_max[1] = @max(bbox_max[1], y);
            bbox_max[2] = @max(bbox_max[2], z);
        } else if (std.mem.eql(u8, prefix, "vn")) {
            num_normals += 1;
        } else if (std.mem.eql(u8, prefix, "f")) {
            num_faces += 1;
        }
    }

    const name = allocator.dupe(u8, filename) catch "unknown_mesh";

    var center = [3]f32{ 0, 0, 0 };
    if (num_vertices > 0) {
        center[0] = (bbox_min[0] + bbox_max[0]) / 2.0;
        center[1] = (bbox_min[1] + bbox_max[1]) / 2.0;
        center[2] = (bbox_min[2] + bbox_max[2]) / 2.0;
    } else {
        bbox_min = .{ 0, 0, 0 };
        bbox_max = .{ 0, 0, 0 };
    }

    return .{ .mesh = .{
        .num_vertices = num_vertices,
        .num_faces = num_faces,
        .num_normals = num_normals,
        .bbox_min = bbox_min,
        .bbox_max = bbox_max,
        .center = center,
        .name = name,
    } };
}
