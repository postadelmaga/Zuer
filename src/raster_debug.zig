//! Tool di sviluppo (step `raster-debug` in build.zig): rende un file col
//! percorso reale di text_render e ne scrive il PPM su stdout, per verificare la
//! resa senza aprire finestre. Con l'argomento `gpu` usa la pipeline ad atlante
//! su GPU (Soluzione B) invece del motore CPU (Soluzione A), per confrontarle.
//! Uso: zig build raster-debug -- <file> [text|md] [cpu|gpu] > out.ppm

const std = @import("std");
const decoder_mod = @import("decoder.zig");
const text_render = @import("text_render.zig");
const gpu = @import("gpu_renderer.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const in_path = args.next() orelse return error.MissingArg;
    const kind = args.next() orelse "text";
    const engine = args.next() orelse "cpu";
    const name = std.fs.path.basename(in_path);
    const opts = text_render.RenderOpts{ .width = 1100, .pointsize = 15 };

    const content = try std.Io.Dir.cwd().readFileAlloc(io, in_path, gpa, std.Io.Limit.limited(10 * 1024 * 1024));
    var decoded: decoder_mod.Decoded = if (std.mem.eql(u8, kind, "md"))
        .{ .markdown = .{ .content = content } }
    else
        .{ .text = content };
    defer decoded.deinit(gpa);

    var stdout_buf: [65536]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    if (std.mem.eql(u8, engine, "gpu")) {
        var renderer = try gpu.Renderer.init(gpa, .{});
        defer renderer.deinit();

        var mesh = try text_render.buildTextMesh(gpa, &decoded, name, opts);
        defer mesh.deinit(gpa);

        const rgba = try renderer.renderText(
            std.mem.sliceAsBytes(mesh.vertices),
            @intCast(mesh.vertices.len),
            mesh.atlas.pixels,
            @intCast(mesh.atlas.w),
            @intCast(mesh.atlas.h),
            @intCast(mesh.width),
            @intCast(mesh.height),
            text_render.clear_bg,
        );

        try w.print("P6\n{d} {d}\n255\n", .{ mesh.width, mesh.height });
        var i: usize = 0;
        const n = mesh.width * mesh.height;
        while (i < n) : (i += 1) {
            try w.writeAll(rgba[i * 4 .. i * 4 + 3]);
        }
        try stdout_writer.flush();
        return;
    }

    var img = try text_render.render(gpa, io, &decoded, name, opts);
    defer img.deinit(gpa);
    try w.print("P6\n{d} {d}\n255\n", .{ img.width, img.height });
    try w.writeAll(img.pixels);
    try stdout_writer.flush();
}
