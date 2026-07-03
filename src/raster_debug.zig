//! Tool di sviluppo (non fa parte della build): rasterizza un file col
//! percorso reale di text_render e scrive il PPM su stdout, per verificare
//! la resa tipografica senza aprire finestre.
//! Uso: zig run -lc src/raster_debug.zig -- <file> [text|md] > out.ppm

const std = @import("std");
const decoder_mod = @import("decoder.zig");
const text_render = @import("text_render.zig");

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

    const content = try std.Io.Dir.cwd().readFileAlloc(io, in_path, gpa, std.Io.Limit.limited(10 * 1024 * 1024));
    var decoded: decoder_mod.Decoded = if (std.mem.eql(u8, kind, "md"))
        .{ .markdown = .{ .content = content } }
    else
        .{ .text = content };
    defer decoded.deinit(gpa);

    var img = try text_render.render(gpa, io, &decoded, std.fs.path.basename(in_path), .{ .width = 1100, .pointsize = 15 });
    defer img.deinit(gpa);

    var stdout_buf: [65536]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const w = &stdout_writer.interface;
    try w.print("P6\n{d} {d}\n255\n", .{ img.width, img.height });
    try w.writeAll(img.pixels);
    try stdout_writer.flush();
}
