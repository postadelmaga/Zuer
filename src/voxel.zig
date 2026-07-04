//! Voxelizzazione della mesh: campiona i triangoli in una griglia 3D RGBA8
//! (rgb = albedo campionato dalla texture/base_color, a = occupazione). La
//! griglia è poi caricata come texture 3D e ray-marciata nel fragment shader
//! (`voxel.frag`) per un rendering voxel con ombre/AO tracciate.

const std = @import("std");
const decoder = @import("decoder.zig");
const MeshData = decoder.MeshData;
const SubMesh = decoder.SubMesh;

pub const Grid = struct {
    dim: u32,
    data: []u8, // dim³ × 4 (RGBA); a = 255 se voxel pieno
    bbox_min: [3]f32,
    bbox_size: [3]f32, // estensione per asse (per mappare oggetto→[0,dim))

    pub fn deinit(self: *Grid, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
    }
};

/// Colore albedo di un punto del triangolo: campiona la baseColor texture del
/// submesh alle UV (repeat) se presente, altrimenti usa il fattore base_color.
fn sampleAlbedo(s: SubMesh, u: f32, v: f32) [3]u8 {
    if (s.tex_width > 0 and s.tex_height > 0 and s.tex_pixels.len >= s.tex_width * s.tex_height * 4) {
        const uu = u - @floor(u);
        const vv = v - @floor(v);
        const x = @min(s.tex_width - 1, @as(usize, @intFromFloat(uu * @as(f32, @floatFromInt(s.tex_width)))));
        const y = @min(s.tex_height - 1, @as(usize, @intFromFloat(vv * @as(f32, @floatFromInt(s.tex_height)))));
        const idx = (y * s.tex_width + x) * 4;
        return .{ s.tex_pixels[idx], s.tex_pixels[idx + 1], s.tex_pixels[idx + 2] };
    }
    return .{
        @intFromFloat(std.math.clamp(s.base_color[0], 0, 1) * 255),
        @intFromFloat(std.math.clamp(s.base_color[1], 0, 1) * 255),
        @intFromFloat(std.math.clamp(s.base_color[2], 0, 1) * 255),
    };
}

fn dist(a: [3]f32, b: [3]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

/// Voxelizza `m` in una griglia `dim`³. Ritorna null su OOM o mesh vuota.
pub fn voxelize(gpa: std.mem.Allocator, m: MeshData, dim: u32) ?Grid {
    if (m.vertices.len == 0 or dim == 0) return null;

    const dimf: f32 = @floatFromInt(dim);
    var size = [3]f32{
        m.bbox_max[0] - m.bbox_min[0],
        m.bbox_max[1] - m.bbox_min[1],
        m.bbox_max[2] - m.bbox_min[2],
    };
    inline for (0..3) |k| {
        if (size[k] < 1e-6) size[k] = 1e-6;
    }
    const vox = [3]f32{ size[0] / dimf, size[1] / dimf, size[2] / dimf };
    const min_vox = @max(1e-9, @min(vox[0], @min(vox[1], vox[2])));

    const cells: usize = @as(usize, dim) * dim * dim;
    const data = gpa.alloc(u8, cells * 4) catch return null;
    @memset(data, 0);

    const has_uv = m.uvs.len == m.vertices.len;
    const max_steps: usize = 2 * dim;

    // Se il decoder non ha prodotto submesh (es. OBJ/STL), tratta l'intera mesh
    // come un unico submesh con il materiale/texture di fallback.
    var fallback = [_]SubMesh{.{
        .first_index = 0,
        .index_count = m.faces.len * 3,
        .base_color = m.base_color,
        .tex_width = m.tex_width,
        .tex_height = m.tex_height,
        .tex_pixels = m.tex_pixels,
    }};
    const subs: []const SubMesh = if (m.submeshes.len > 0) m.submeshes else &fallback;

    for (subs) |s| {
        const fs = s.first_index / 3;
        var fe = (s.first_index + s.index_count) / 3;
        if (fe > m.faces.len) fe = m.faces.len;
        if (fs >= fe) continue;

        for (m.faces[fs..fe]) |face| {
            if (face.v1 >= m.vertices.len or face.v2 >= m.vertices.len or face.v3 >= m.vertices.len) continue;
            const p0 = m.vertices[face.v1];
            const p1 = m.vertices[face.v2];
            const p2 = m.vertices[face.v3];
            const t0: [2]f32 = if (has_uv) m.uvs[face.v1] else .{ 0, 0 };
            const t1: [2]f32 = if (has_uv) m.uvs[face.v2] else .{ 0, 0 };
            const t2: [2]f32 = if (has_uv) m.uvs[face.v3] else .{ 0, 0 };

            const maxe = @max(dist(p0, p1), @max(dist(p0, p2), dist(p1, p2)));
            const n: usize = std.math.clamp(@as(usize, @intFromFloat(@ceil(maxe / min_vox))), 1, max_steps);
            const nf: f32 = @floatFromInt(n);

            var i: usize = 0;
            while (i <= n) : (i += 1) {
                const a = @as(f32, @floatFromInt(i)) / nf;
                var j: usize = 0;
                while (i + j <= n) : (j += 1) {
                    const b = @as(f32, @floatFromInt(j)) / nf;
                    const c = 1.0 - a - b;
                    const px = a * p0[0] + b * p1[0] + c * p2[0];
                    const py = a * p0[1] + b * p1[1] + c * p2[1];
                    const pz = a * p0[2] + b * p1[2] + c * p2[2];
                    const cx = @min(dim - 1, @as(u32, @intFromFloat(@max(0.0, (px - m.bbox_min[0]) / size[0] * dimf))));
                    const cy = @min(dim - 1, @as(u32, @intFromFloat(@max(0.0, (py - m.bbox_min[1]) / size[1] * dimf))));
                    const cz = @min(dim - 1, @as(u32, @intFromFloat(@max(0.0, (pz - m.bbox_min[2]) / size[2] * dimf))));
                    const u = a * t0[0] + b * t1[0] + c * t2[0];
                    const v = a * t0[1] + b * t1[1] + c * t2[1];
                    const col = sampleAlbedo(s, u, v);
                    const idx = (@as(usize, (cz * dim + cy)) * dim + cx) * 4;
                    data[idx] = col[0];
                    data[idx + 1] = col[1];
                    data[idx + 2] = col[2];
                    data[idx + 3] = 255;
                }
            }
        }
    }

    return .{ .dim = dim, .data = data, .bbox_min = m.bbox_min, .bbox_size = size };
}
