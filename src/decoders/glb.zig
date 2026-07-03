const std = @import("std");
const decoder = @import("decoder");
const MeshData = decoder.MeshData;
const Face = decoder.Face;
const Decoded = decoder.Decoded;

const GltfAccessor = struct {
    bufferView: ?usize = null,
    byteOffset: ?usize = null,
    componentType: usize,
    count: usize,
    type: []const u8,
};

const GltfBufferView = struct {
    buffer: usize,
    byteOffset: ?usize = null,
    byteLength: usize,
    byteStride: ?usize = null,
};

const GltfPrimitive = struct {
    attributes: std.json.Value,
    indices: ?usize = null,
};

const GltfMesh = struct {
    primitives: []GltfPrimitive,
};

const GltfStructure = struct {
    accessors: ?[]GltfAccessor = null,
    bufferViews: ?[]GltfBufferView = null,
    meshes: ?[]GltfMesh = null,
};

pub fn decode(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    defer allocator.free(bytes);

    if (bytes.len < 20) return .{ .err = "File GLB troppo piccolo" };
    if (!std.mem.eql(u8, bytes[0..4], "glTF")) return .{ .err = "Formato GLB non valido (magic header errato)" };

    const version = std.mem.readInt(u32, bytes[4..8], .little);
    if (version != 2) return .{ .err = "Versione glTF non supportata (solo v2)" };

    // Chunk 0: JSON
    const chunk0_len = std.mem.readInt(u32, bytes[12..16], .little);
    const chunk0_type = std.mem.readInt(u32, bytes[16..20], .little);
    if (chunk0_type != 0x4E4F534A) return .{ .err = "Il primo chunk GLB deve essere JSON" };
    if (20 + chunk0_len > bytes.len) return .{ .err = "JSON chunk fuori dai limiti del file" };
    const json_str = bytes[20 .. 20 + chunk0_len];

    // Chunk 1: BIN
    const chunk1_offset = 20 + chunk0_len;
    if (chunk1_offset + 8 > bytes.len) return .{ .err = "Nessun chunk BIN trovato" };
    const chunk1_len = std.mem.readInt(u32, bytes[chunk1_offset .. chunk1_offset + 4][0..4], .little);
    const chunk1_type = std.mem.readInt(u32, bytes[chunk1_offset + 4 .. chunk1_offset + 8][0..4], .little);
    if (chunk1_type != 0x004E4942) return .{ .err = "Il secondo chunk GLB deve essere BIN" };
    if (chunk1_offset + 8 + chunk1_len > bytes.len) return .{ .err = "BIN chunk fuori dai limiti del file" };
    const bin_data = bytes[chunk1_offset + 8 .. chunk1_offset + 8 + chunk1_len];

    // Parse JSON
    var parsed = std.json.parseFromSlice(GltfStructure, allocator, json_str, .{ .ignore_unknown_fields = true }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Errore parsing JSON glTF: {s}", .{@errorName(err)}) catch "Errore JSON";
        return .{ .err = msg };
    };
    defer parsed.deinit();
    const gltf = parsed.value;

    // Decode meshes to MeshData
    const mesh_data = decodeGltfMesh(gltf, bin_data, filename, allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Errore decodifica modello 3D GLB: {s}", .{@errorName(err)}) catch "Errore GLB";
        return .{ .err = msg };
    };

    return .{ .mesh = mesh_data };
}

fn decodeGltfMesh(gltf: GltfStructure, bin_data: []const u8, filename: []const u8, allocator: std.mem.Allocator) !MeshData {
    const meshes = gltf.meshes orelse return error.NoMeshes;
    if (meshes.len == 0) return error.NoMeshes;
    const mesh = meshes[0];
    if (mesh.primitives.len == 0) return error.NoPrimitives;
    const prim = mesh.primitives[0];

    const position_accessor_idx = switch (prim.attributes) {
        .object => |obj| if (obj.get("POSITION")) |pos_val| switch (pos_val) {
            .integer => |idx| @as(usize, @intCast(idx)),
            else => return error.InvalidPositionAttribute,
        } else return error.NoPositionAttribute,
        else => return error.InvalidAttributes,
    };

    const accessors = gltf.accessors orelse return error.NoAccessors;
    const bufferViews = gltf.bufferViews orelse return error.NoBufferViews;

    if (position_accessor_idx >= accessors.len) return error.AccessorOutOfBounds;
    const pos_accessor = accessors[position_accessor_idx];
    if (!std.mem.eql(u8, pos_accessor.type, "VEC3")) return error.UnsupportedPositionType;
    if (pos_accessor.componentType != 5126) return error.UnsupportedPositionComponentType;

    const pos_bv_idx = pos_accessor.bufferView orelse return error.NoBufferViewForPosition;
    if (pos_bv_idx >= bufferViews.len) return error.BufferViewOutOfBounds;
    const pos_bv = bufferViews[pos_bv_idx];

    const pos_offset = (pos_bv.byteOffset orelse 0) + (pos_accessor.byteOffset orelse 0);
    const pos_stride = pos_bv.byteStride orelse 12;

    var vertices = std.ArrayList([3]f32).empty;
    errdefer vertices.deinit(allocator);

    var bbox_min = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var bbox_max = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };

    var i: usize = 0;
    while (i < pos_accessor.count) : (i += 1) {
        const idx = pos_offset + i * pos_stride;
        if (idx + 12 > bin_data.len) return error.BufferOutOfBounds;

        const x = @as(f32, @bitCast(std.mem.readInt(u32, bin_data[idx + 0 .. idx + 4][0..4], .little)));
        const y = @as(f32, @bitCast(std.mem.readInt(u32, bin_data[idx + 4 .. idx + 8][0..4], .little)));
        const z = @as(f32, @bitCast(std.mem.readInt(u32, bin_data[idx + 8 .. idx + 12][0..4], .little)));

        try vertices.append(allocator, .{ x, y, z });
        bbox_min[0] = @min(bbox_min[0], x);
        bbox_min[1] = @min(bbox_min[1], y);
        bbox_min[2] = @min(bbox_min[2], z);

        bbox_max[0] = @max(bbox_max[0], x);
        bbox_max[1] = @max(bbox_max[1], y);
        bbox_max[2] = @max(bbox_max[2], z);
    }

    var faces = std.ArrayList(Face).empty;
    errdefer faces.deinit(allocator);

    if (prim.indices) |indices_accessor_idx| {
        if (indices_accessor_idx >= accessors.len) return error.AccessorOutOfBounds;
        const ind_accessor = accessors[indices_accessor_idx];
        const ind_bv_idx = ind_accessor.bufferView orelse return error.NoBufferViewForIndices;
        if (ind_bv_idx >= bufferViews.len) return error.BufferViewOutOfBounds;
        const ind_bv = bufferViews[ind_bv_idx];

        const ind_offset = (ind_bv.byteOffset orelse 0) + (ind_accessor.byteOffset orelse 0);
        const num_indices = ind_accessor.count;

        var j: usize = 0;
        while (j + 2 < num_indices) : (j += 3) {
            const v1 = try readIndex(bin_data, ind_offset, j, ind_accessor.componentType);
            const v2 = try readIndex(bin_data, ind_offset, j + 1, ind_accessor.componentType);
            const v3 = try readIndex(bin_data, ind_offset, j + 2, ind_accessor.componentType);
            try faces.append(allocator, .{ .v1 = v1, .v2 = v2, .v3 = v3 });
        }
    } else {
        var j: usize = 0;
        while (j + 2 < pos_accessor.count) : (j += 3) {
            try faces.append(allocator, .{ .v1 = j, .v2 = j + 1, .v3 = j + 2 });
        }
    }

    const name = try allocator.dupe(u8, filename);
    errdefer allocator.free(name);

    var center = [3]f32{ 0, 0, 0 };
    if (vertices.items.len > 0) {
        center[0] = (bbox_min[0] + bbox_max[0]) / 2.0;
        center[1] = (bbox_min[1] + bbox_max[1]) / 2.0;
        center[2] = (bbox_min[2] + bbox_max[2]) / 2.0;
    } else {
        bbox_min = .{ 0, 0, 0 };
        bbox_max = .{ 0, 0, 0 };
    }

    return .{
        .num_vertices = vertices.items.len,
        .num_faces = faces.items.len,
        .num_normals = 0,
        .bbox_min = bbox_min,
        .bbox_max = bbox_max,
        .center = center,
        .name = name,
        .vertices = try vertices.toOwnedSlice(allocator),
        .faces = try faces.toOwnedSlice(allocator),
    };
}

fn readIndex(bin_data: []const u8, offset: usize, index: usize, component_type: usize) !usize {
    switch (component_type) {
        5121 => { // u8
            const idx = offset + index;
            if (idx >= bin_data.len) return error.OutOfBounds;
            return bin_data[idx];
        },
        5123 => { // u16
            const idx = offset + index * 2;
            if (idx + 2 > bin_data.len) return error.OutOfBounds;
            return std.mem.readInt(u16, bin_data[idx .. idx + 2][0..2], .little);
        },
        5125 => { // u32
            const idx = offset + index * 4;
            if (idx + 4 > bin_data.len) return error.OutOfBounds;
            return std.mem.readInt(u32, bin_data[idx .. idx + 4][0..4], .little);
        },
        else => return error.UnsupportedIndexType,
    }
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
