//! Screenshot headless di una mesh: decodifica un file, lo stagia e lo
//! renderizza offscreen con l'ESATTA pipeline del gui (setMeshMaterials → VT),
//! poi scrive un PPM. Serve a ispezionare i colori/geometria senza display.
//! Uso: `zig build gpu-shot -- <file> <out.ppm> [yaw] [pitch] [zoom]`

const std = @import("std");
const gpu = @import("gpu_renderer.zig");
const loader = @import("loader.zig");
const decoder = @import("decoder.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;

fn writeFile(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const zpath = try gpa.dupeZ(u8, path);
    defer gpa.free(zpath);
    const fd = open(zpath.ptr, 1 | 0o100 | 0o1000, 0o644); // O_WRONLY|O_CREAT|O_TRUNC
    if (fd < 0) return error.CreateFailed;
    defer _ = close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingFile;
    const outpath = args.next() orelse return error.MissingOut;
    const yaw: f32 = if (args.next()) |a| try std.fmt.parseFloat(f32, a) else 0.6;
    const pitch: f32 = if (args.next()) |a| try std.fmt.parseFloat(f32, a) else 0.35;
    const zoom: f32 = if (args.next()) |a| try std.fmt.parseFloat(f32, a) else 1.0;
    const coarse = if (args.next()) |a| std.mem.eql(u8, a, "coarse") else false;

    var decoded = if (coarse)
        (decoder.decodeCoarse(path, io, gpa) orelse {
            std.debug.print("gpu-shot: coarse non disponibile/cache fredda\n", .{});
            return error.NoCoarse;
        })
    else
        decoder.decode(path, io, gpa);
    defer decoded.deinit(gpa);
    defer decoder.closePluginCache(gpa);
    if (decoded != .mesh) {
        std.debug.print("gpu-shot: non è una mesh (è .{s})\n", .{@tagName(decoded)});
        return error.NotAMesh;
    }
    const m = decoded.mesh;

    var stage = loader.stageToGpu(gpa, &decoded) orelse return error.StageFailed;
    defer stage.buffer.deinit(gpa);

    var renderer = try gpu.Renderer.init(gpa, .{});
    defer renderer.deinit();
    defer renderer.releaseMesh();
    try renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
    try renderer.setMeshMaterials(&m);
    renderer.vt_zoom = zoom;

    const w: u32 = 900;
    const h: u32 = 900;
    const max_size = @max(
        m.bbox_max[0] - m.bbox_min[0],
        @max(m.bbox_max[1] - m.bbox_min[1], m.bbox_max[2] - m.bbox_min[2]),
    );
    const pc = gpu.buildPushConstants(m.center, max_size / zoom, yaw, pitch, w, h, .{
        .base_color = m.base_color,
        .metallic = m.metallic,
        .roughness = m.roughness,
    });
    const rgba = try renderer.renderSync(w, h, &pc);

    const npx = @as(usize, w) * h;
    var hbuf: [64]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hbuf, "P6\n{d} {d}\n255\n", .{ w, h });
    const out = try gpa.alloc(u8, hdr.len + npx * 3);
    defer gpa.free(out);
    @memcpy(out[0..hdr.len], hdr);
    var i: usize = 0;
    while (i < npx) : (i += 1) {
        out[hdr.len + i * 3 + 0] = rgba[i * 4 + 0];
        out[hdr.len + i * 3 + 1] = rgba[i * 4 + 1];
        out[hdr.len + i * 3 + 2] = rgba[i * 4 + 2];
    }
    try writeFile(gpa, outpath, out);
    std.debug.print("gpu-shot: scritto {s} ({d}x{d}) metallic={d:.2} roughness={d:.2}\n", .{ outpath, w, h, m.metallic, m.roughness });
}
