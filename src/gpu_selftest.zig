//! Self-test headless del percorso GPU mesh: costruisce un cubo, lo stagia con
//! il vero `loader.stageToGpu` (normali smooth + interleave pos/normale) e lo
//! renderizza offscreen con `gpu_renderer` (stride 48, shader PBR-ish). Verifica che il frame abbia copertura e variazione di
//! luminanza non banali — così la pipeline è validabile senza Wayland/display.
//! Uso: `zig build gpu-selftest`. Exit 0 = ok, 1 = fallito.

const std = @import("std");
const gpu = @import("gpu_renderer.zig");
const loader = @import("loader.zig");
const decoder = @import("decoder.zig");
const voxel = @import("voxel.zig");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Cubo unitario centrato nell'origine (8 vertici, 12 triangoli).
    var vertices = [_][3]f32{
        .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 },
        .{ -1, -1, 1 },  .{ 1, -1, 1 },  .{ 1, 1, 1 },  .{ -1, 1, 1 },
    };
    var faces = [_]decoder.Face{
        .{ .v1 = 0, .v2 = 1, .v3 = 2 }, .{ .v1 = 0, .v2 = 2, .v3 = 3 }, // -Z
        .{ .v1 = 4, .v2 = 6, .v3 = 5 }, .{ .v1 = 4, .v2 = 7, .v3 = 6 }, // +Z
        .{ .v1 = 0, .v2 = 4, .v3 = 5 }, .{ .v1 = 0, .v2 = 5, .v3 = 1 }, // -Y
        .{ .v1 = 3, .v2 = 2, .v3 = 6 }, .{ .v1 = 3, .v2 = 6, .v3 = 7 }, // +Y
        .{ .v1 = 0, .v2 = 3, .v3 = 7 }, .{ .v1 = 0, .v2 = 7, .v3 = 4 }, // -X
        .{ .v1 = 1, .v2 = 5, .v3 = 6 }, .{ .v1 = 1, .v2 = 6, .v3 = 2 }, // +X
    };

    const decoded: decoder.Decoded = .{ .mesh = .{
        .num_vertices = vertices.len,
        .num_faces = faces.len,
        .num_normals = 0,
        .bbox_min = .{ -1, -1, -1 },
        .bbox_max = .{ 1, 1, 1 },
        .center = .{ 0, 0, 0 },
        .name = "selftest-cube",
        .vertices = &vertices,
        .faces = &faces,
    } };

    var stage = loader.stageToGpu(gpa, &decoded) orelse {
        std.debug.print("[selftest] stageToGpu ha restituito null (memfd non disponibile?)\n", .{});
        return error.StageFailed;
    };
    defer stage.buffer.deinit(gpa);

    // Verifica il layout atteso: 48 byte/vertice (pos+normal+uv+tangent), 12/triangolo.
    if (stage.vertex_bytes != vertices.len * 48) {
        std.debug.print("[selftest] vertex_bytes={d}, atteso {d}\n", .{ stage.vertex_bytes, vertices.len * 48 });
        return error.BadLayout;
    }

    var renderer = try gpu.Renderer.init(gpa, .{});
    defer renderer.deinit();

    try renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));

    const w: u32 = 256;
    const h: u32 = 256;
    // Vista di tre quarti: yaw e pitch non nulli così tre facce sono visibili
    // con luminanze diverse (prova che le normali funzionano).
    const pc = gpu.buildPushConstants(.{ 0, 0, 0 }, 2.0, 0.6, 0.5, w, h, .{
        .base_color = .{ 0.85, 0.5, 0.2, 1 },
        .metallic = 0.0,
        .roughness = 0.5,
    });
    const rgba = try renderer.renderSync(w, h, &pc);

    var covered: usize = 0;
    var lum_min: f32 = 1e9;
    var lum_max: f32 = -1e9;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        const a = rgba[i + 3];
        if (a == 0) continue;
        covered += 1;
        const r: f32 = @floatFromInt(rgba[i]);
        const g: f32 = @floatFromInt(rgba[i + 1]);
        const b: f32 = @floatFromInt(rgba[i + 2]);
        const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        lum_min = @min(lum_min, lum);
        lum_max = @max(lum_max, lum);
    }

    const total = @as(usize, w) * h;
    const coverage = @as(f32, @floatFromInt(covered)) / @as(f32, @floatFromInt(total));
    std.debug.print("[selftest] copertura={d:.1}% luminanza min={d:.0} max={d:.0} spread={d:.0}\n", .{ coverage * 100.0, lum_min, lum_max, lum_max - lum_min });

    // Il cubo a 3/4 riempie una porzione consistente; le facce devono avere
    // luminanze diverse (spread), altrimenti l'illuminazione per-normale è rotta.
    if (coverage < 0.15) {
        std.debug.print("[selftest] FALLITO: copertura troppo bassa, la mesh non si vede\n", .{});
        return error.NothingRendered;
    }
    if (lum_max - lum_min < 10.0) {
        std.debug.print("[selftest] FALLITO: nessuna variazione di luce tra le facce (normali/shading rotti)\n", .{});
        return error.FlatShading;
    }

    // Secondo passaggio: texture baseColor rossa piena + materiale bianco.
    // Con UV tutte a (0,0) il campionamento legge un texel rosso uniforme, quindi
    // il rosso deve dominare — prova che upload+descriptor+sampling funzionano.
    var red_tex: [2 * 2 * 4]u8 = undefined;
    var t: usize = 0;
    while (t < red_tex.len) : (t += 4) {
        red_tex[t] = 220;
        red_tex[t + 1] = 30;
        red_tex[t + 2] = 30;
        red_tex[t + 3] = 255;
    }
    const pc_white = gpu.buildPushConstants(.{ 0, 0, 0 }, 2.0, 0.6, 0.5, w, h, .{
        .base_color = .{ 1, 1, 1, 1 },
        .metallic = 0.0,
        .roughness = 0.6,
    });
    // Confronto relativo texture-rossa vs texture-bianca sugli stessi pixel: il
    // modello di luce ha rim/fill blu, quindi non si può pretendere R>2·B in
    // assoluto; però la texture rossa deve rendere il render *relativamente*
    // molto più rosso di quello bianco (prova di upload+descriptor+sampling).
    try renderer.setBaseColor(&red_tex, 2, 2);
    const rgba_red = try renderer.renderSync(w, h, &pc_white);
    var rr: u64 = 0;
    var rb: u64 = 0;
    var k: usize = 0;
    while (k < rgba_red.len) : (k += 4) {
        if (rgba_red[k + 3] == 0) continue;
        rr += rgba_red[k];
        rb += rgba_red[k + 2];
    }
    const white_tex = [_]u8{ 220, 220, 220, 255 };
    try renderer.setBaseColor(&white_tex, 1, 1);
    const rgba_white = try renderer.renderSync(w, h, &pc_white);
    var wr: u64 = 0;
    var wb: u64 = 0;
    k = 0;
    while (k < rgba_white.len) : (k += 4) {
        if (rgba_white[k + 3] == 0) continue;
        wr += rgba_white[k];
        wb += rgba_white[k + 2];
    }
    std.debug.print("[selftest] texture rossa: R/B rosso={d}/{d} bianco={d}/{d}\n", .{ rr, rb, wr, wb });
    // (R_red/B_red) ≥ 1.5 × (R_white/B_white) ⇔ rr·wb ≥ 1.5 · wr·rb
    if (rr * wb * 2 < 3 * wr * rb) {
        std.debug.print("[selftest] FALLITO: la texture rossa non sposta il colore (sampling rotto)\n", .{});
        return error.TextureNotSampled;
    }

    // Terzo passaggio: ombre. Un piano base ampio con un box sospeso sopra; la
    // key light (dall'alto) proietta l'ombra del box sul piano. Vista dall'alto.
    // Confronto pixel scuri "base sola" vs "base+box": l'ombra deve aggiungerne.
    const base_dark = try renderCountDark(&renderer, gpa, false, w, h);
    const shad_dark = try renderCountDark(&renderer, gpa, true, w, h);
    std.debug.print("[selftest] pixel scuri base={d} base+box={d}\n", .{ base_dark, shad_dark });
    if (shad_dark <= base_dark + (@as(usize, w) * h) / 100) {
        std.debug.print("[selftest] FALLITO: il box non proietta ombra sul piano\n", .{});
        return error.NoShadow;
    }

    // Quarto passaggio: rendering voxel. Voxelizza il cubo, ray-marcia in una
    // vista di tre quarti, e verifica che ci siano sia pixel-oggetto (chiari)
    // sia pixel-sfondo (gradiente scuro) — cioè il raggio colpisce e manca.
    {
        var grid = voxel.voxelize(gpa, decoded.mesh, 64) orelse {
            std.debug.print("[selftest] voxelize ha restituito null\n", .{});
            return error.VoxelizeFailed;
        };
        defer grid.deinit(gpa);
        try renderer.setVoxels(grid.dim, grid.data);
        const vpc = gpu.buildVoxelPush(.{ 0, 0, 0 }, 2.0, 0.6, 0.5, w, h, grid.bbox_min, grid.bbox_size, grid.dim);
        const vrgba = try renderer.renderVoxel(w, h, &vpc);
        var bright: usize = 0;
        var dark: usize = 0;
        var m: usize = 0;
        while (m < vrgba.len) : (m += 4) {
            const lum = 0.299 * @as(f32, @floatFromInt(vrgba[m])) + 0.587 * @as(f32, @floatFromInt(vrgba[m + 1])) + 0.114 * @as(f32, @floatFromInt(vrgba[m + 2]));
            if (lum > 140) bright += 1 else if (lum < 130) dark += 1;
        }
        std.debug.print("[selftest] voxel: pixel-oggetto={d} pixel-sfondo={d}\n", .{ bright, dark });
        const min_px = (@as(usize, w) * h) / 50;
        if (bright < min_px or dark < min_px) {
            std.debug.print("[selftest] FALLITO: il rendering voxel non distingue oggetto/sfondo\n", .{});
            return error.VoxelRenderBad;
        }
    }

    std.debug.print("[selftest] OK\n", .{});
}

/// Renderizza dall'alto un piano base (+ box sospeso se `with_caster`) e conta i
/// pixel coperti "in ombra" (luminanza medio-bassa): l'ombra proiettata dal box
/// deve incrementarli sensibilmente rispetto al solo piano illuminato.
fn renderCountDark(renderer: *gpu.Renderer, gpa: std.mem.Allocator, with_caster: bool, w: u32, h: u32) !usize {
    // Piano base nel piano xz a y=0, esteso [-3,3].
    var verts: std.ArrayList([3]f32) = .empty;
    defer verts.deinit(gpa);
    var faces: std.ArrayList(decoder.Face) = .empty;
    defer faces.deinit(gpa);

    try verts.appendSlice(gpa, &.{ .{ -3, 0, -3 }, .{ 3, 0, -3 }, .{ 3, 0, 3 }, .{ -3, 0, 3 } });
    try faces.appendSlice(gpa, &.{ .{ .v1 = 0, .v2 = 1, .v3 = 2 }, .{ .v1 = 0, .v2 = 2, .v3 = 3 } });

    if (with_caster) {
        const b: usize = verts.items.len;
        try verts.appendSlice(gpa, &.{
            .{ -0.7, 1.0, -0.7 }, .{ 0.7, 1.0, -0.7 }, .{ 0.7, 2.0, -0.7 }, .{ -0.7, 2.0, -0.7 },
            .{ -0.7, 1.0, 0.7 },  .{ 0.7, 1.0, 0.7 },  .{ 0.7, 2.0, 0.7 },  .{ -0.7, 2.0, 0.7 },
        });
        const q = [_][3]usize{
            .{ 0, 1, 2 }, .{ 0, 2, 3 }, .{ 4, 6, 5 }, .{ 4, 7, 6 },
            .{ 0, 4, 5 }, .{ 0, 5, 1 }, .{ 3, 2, 6 }, .{ 3, 6, 7 },
            .{ 0, 3, 7 }, .{ 0, 7, 4 }, .{ 1, 5, 6 }, .{ 1, 6, 2 },
        };
        for (q) |f| try faces.append(gpa, .{ .v1 = b + f[0], .v2 = b + f[1], .v3 = b + f[2] });
    }

    const decoded: decoder.Decoded = .{ .mesh = .{
        .num_vertices = verts.items.len,
        .num_faces = faces.items.len,
        .num_normals = 0,
        .bbox_min = .{ -3, 0, -3 },
        .bbox_max = .{ 3, 2, 3 },
        .center = .{ 0, 1, 0 },
        .name = "shadow-scene",
        .vertices = verts.items,
        .faces = faces.items,
    } };

    var stage = loader.stageToGpu(gpa, &decoded) orelse return error.StageFailed;
    defer stage.buffer.deinit(gpa);
    // Rilascia l'import mesh PRIMA di liberare la memoria host di `stage`
    // (LIFO: questo defer gira prima di stage.buffer.deinit): setMesh importa
    // il puntatore host zero-copy, e liberarlo mentre il VkBuffer lo mappa
    // ancora lascerebbe un riferimento pendente nelle page table GPU.
    defer renderer.releaseMesh();
    try renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
    try renderer.setBaseColor(&.{}, 0, 0); // baseColor bianco

    // Vista quasi dall'alto (pitch ripido) per vedere il piano e l'ombra.
    const pc = gpu.buildPushConstants(.{ 0, 1, 0 }, 6.0, 0.0, 1.35, w, h, .{
        .base_color = .{ 0.85, 0.85, 0.85, 1 },
        .metallic = 0.0,
        .roughness = 0.9,
    });
    const rgba = try renderer.renderSync(w, h, &pc);

    // Massimo di luminanza fra i pixel coperti = base pienamente illuminata.
    var maxlum: f32 = 0;
    var covered: usize = 0;
    var sumlum: f64 = 0;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        if (rgba[i + 3] == 0) continue;
        covered += 1;
        const lum = luminance(rgba, i);
        sumlum += lum;
        maxlum = @max(maxlum, lum);
    }
    // Pixel coperti sensibilmente sotto il massimo = zona in ombra.
    const thresh = maxlum * 0.7;
    var dark: usize = 0;
    i = 0;
    while (i < rgba.len) : (i += 4) {
        if (rgba[i + 3] == 0) continue;
        if (luminance(rgba, i) < thresh) dark += 1;
    }
    const avg = if (covered > 0) sumlum / @as(f64, @floatFromInt(covered)) else 0;
    std.debug.print("[selftest]   scena caster={}: coperti={d} max={d:.0} avg={d:.0} soglia={d:.0} sotto-soglia={d}\n", .{ with_caster, covered, maxlum, avg, thresh, dark });
    if (with_caster) dumpAscii(rgba, w, h);
    return dark;
}

/// Mappa ASCII 40×20 della luminanza per ispezionare visivamente l'ombra.
fn dumpAscii(rgba: []const u8, w: u32, h: u32) void {
    const cols = 40;
    const rows = 20;
    const ramp = " .:-=+*#%@";
    var ry: usize = 0;
    while (ry < rows) : (ry += 1) {
        var line: [cols]u8 = undefined;
        var rx: usize = 0;
        while (rx < cols) : (rx += 1) {
            const px = rx * w / cols;
            const py = ry * h / rows;
            const idx = (py * w + px) * 4;
            const ch: u8 = if (rgba[idx + 3] == 0) ' ' else blk: {
                const lum = luminance(rgba, idx);
                const step: usize = @intFromFloat(@min(9.0, lum / 255.0 * 10.0));
                break :blk ramp[step];
            };
            line[rx] = ch;
        }
        std.debug.print("[selftest]   |{s}|\n", .{line});
    }
}

fn luminance(rgba: []const u8, i: usize) f32 {
    const r: f32 = @floatFromInt(rgba[i]);
    const g: f32 = @floatFromInt(rgba[i + 1]);
    const b: f32 = @floatFromInt(rgba[i + 2]);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
