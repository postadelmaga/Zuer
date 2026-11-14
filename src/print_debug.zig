//! Tool di sviluppo (step `print-debug` in build.zig): scrive il PDF che Zuer
//! manderebbe in stampa per un file, senza stampare. Il file è decodificato
//! come nel viewer; un PDF viene stampato com'è e qui non serve.
//! Uso: zig build print-debug -- <file> <out.pdf> [quarti di giro 0-3]

const std = @import("std");
const decoder_mod = @import("decoder.zig");
const print_pdf = @import("print_pdf.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const in_path = args.next() orelse return error.MissingArg;
    const out_path = args.next() orelse return error.MissingArg;
    const rotation = try std.fmt.parseInt(u2, args.next() orelse "0", 10);

    var decoded = decoder_mod.decode(in_path, io, gpa);
    defer decoded.deinit(gpa);
    if (decoded == .err) {
        // Senza plugin (binario nella cache di zig): testo e markdown si leggono
        // da qui; per il resto serve zig-out/bin/print-debug.
        std.debug.print("decode: {s} (letto come testo)\n", .{decoded.err});
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .limited(64 << 20));
        decoded.deinit(gpa);
        const ext = std.fs.path.extension(in_path);
        decoded = if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown"))
            .{ .markdown = .{ .content = bytes } }
        else
            .{ .text = bytes };
    }
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    const pdf = try print_pdf.build(gpa, &decoded, std.fs.path.basename(in_path), rotation);
    defer gpa.free(pdf);
    const ms = @divTrunc(std.Io.Clock.awake.now(io).nanoseconds - t0, std.time.ns_per_ms);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = pdf });
    std.debug.print("{s}: {d} byte in {d} ms\n", .{ out_path, pdf.len, ms });
}
