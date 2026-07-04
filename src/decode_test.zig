//! Tool di sviluppo: chiama decoder.decode() su un file da un THREAD WORKER
//! (come fa la GUI) con timeout, per diagnosticare hang e risultato senza TUI.
//! Uso: zig build decode-test -- <file>

const std = @import("std");
const decoder = @import("decoder.zig");

extern "c" fn usleep(usec: c_uint) c_int;

const Shared = struct {
    path: []const u8,
    io: std.Io,
    gpa: std.mem.Allocator,
    result: decoder.Decoded = .{ .err = "" },
    done: std.atomic.Value(bool) = .init(false),
};

fn worker(s: *Shared) void {
    s.result = decoder.decode(s.path, s.io, s.gpa);
    s.done.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingArg;

    var buf: [512]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &buf);
    const w = &ew.interface;
    try w.print("decode({s}) su thread worker...\n", .{path});
    try w.flush();

    var shared = Shared{ .path = path, .io = io, .gpa = gpa };
    const t = try std.Thread.spawn(.{}, worker, .{&shared});

    // Attesa con timeout ~20s: se il decode si blocca, il thread non finisce.
    var waited: usize = 0;
    while (!shared.done.load(.acquire) and waited < 200) : (waited += 1) {
        _ = usleep(100_000); // 100 ms
    }
    if (!shared.done.load(.acquire)) {
        try w.print("HANG: il decode NON è terminato entro il timeout (thread worker bloccato)\n", .{});
        try w.flush();
        std.process.exit(2);
    }
    t.join();

    switch (shared.result) {
        .image => |img| try w.print("OK IMAGE {d}x{d}\n", .{ img.width, img.height }),
        .text => |txt| try w.print("OK TEXT ({d} byte)\n", .{txt.len}),
        .csv => try w.print("OK CSV\n", .{}),
        .workbook => |wb| try w.print("OK WORKBOOK ({d} fogli)\n", .{wb.sheets.len}),
        .markdown => try w.print("OK MARKDOWN\n", .{}),
        .mesh => try w.print("OK MESH\n", .{}),
        .err => |e| try w.print("ERR: {s}\n", .{e}),
    }
    try w.flush();
    shared.result.deinit(gpa);
    decoder.closePluginCache(gpa);
}
