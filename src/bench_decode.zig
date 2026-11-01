//! Benchmark di contesa: un decode "in primo piano" (quello che l'utente ha
//! aperto) mentre N thread "di sfondo" decodificano altri file, come fanno il
//! prefetch e le miniature nella GUI. Misura la latenza del primo piano.
//!
//! Uso: zig build bench-decode -- <fg_file> [bg_file...]
//!   ZUER_BENCH_BG=<n>  thread di sfondo (default 2, come prefetch + miniature)

const std = @import("std");
const decoder = @import("decoder.zig");
const scheduler = @import("scheduler.zig");
const perfcount = @import("perfcount.zig");
const linux = std.os.linux;
extern "c" fn getrusage(who: c_int, usage: *linux.rusage) c_int;

extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const Bg = struct {
    files: []const []const u8,
    io: std.Io,
    gpa: std.mem.Allocator,
    started: std.atomic.Value(bool) = .init(false),
    elapsed_ns: u64 = 0,
};

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn bgWorker(bg: *Bg) void {
    scheduler.setThreadPriority(.background);
    const t0 = now(bg.io);
    bg.started.store(true, .release);
    for (bg.files) |f| {
        var d = decoder.decode(f, bg.io, bg.gpa);
        d.deinit(bg.gpa);
    }
    bg.elapsed_ns = @intCast(now(bg.io) - t0);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Prima di qualunque thread: worker e thread di sfondo li ereditano.
    var pc = perfcount.Counters.open();
    defer pc.close();
    scheduler.initGlobal(io, .{});
    defer decoder.closePluginCache(gpa);
    defer scheduler.deinitGlobal();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const fg = args.next() orelse return error.MissingArg;
    var bg_files: std.ArrayList([]const u8) = .empty;
    defer bg_files.deinit(gpa);
    while (args.next()) |a| try bg_files.append(gpa, a);

    // ZUER_BENCH_HASH=1: stampa un hash dei pixel di tutte le texture del file
    // in primo piano e termina (verifica di equivalenza fra versioni).
    if (getenv("ZUER_BENCH_HASH") != null) {
        var d = decoder.decode(fg, io, gpa);
        defer d.deinit(gpa);
        var h = std.hash.Wyhash.init(0);
        if (d == .mesh) {
            h.update(d.mesh.tex_pixels);
            for (d.mesh.submeshes) |sm| {
                h.update(sm.tex_pixels);
                h.update(sm.nrm_tex_pixels);
            }
        }
        var hb: [128]u8 = undefined;
        var hw = std.Io.File.stdout().writer(io, &hb);
        try hw.interface.print("tex_hash={x} tag={s}\n", .{ h.final(), @tagName(d) });
        try hw.interface.flush();
        return;
    }

    const n_bg: usize = if (getenv("ZUER_BENCH_BG")) |v| std.fmt.parseInt(usize, std.mem.span(v), 10) catch 2 else 2;

    // Riscaldamento: carica i plugin fuori dalla misura (il dlopen non è
    // oggetto del confronto).
    {
        var d = decoder.decode(fg, io, gpa);
        d.deinit(gpa);
    }

    scheduler.setThreadPriority(.interactive);
    const solo_t0 = now(io);
    {
        var d = decoder.decode(fg, io, gpa);
        d.deinit(gpa);
    }
    const solo_ns: u64 = @intCast(now(io) - solo_t0);

    const bgs = try gpa.alloc(Bg, if (bg_files.items.len > 0) n_bg else 0);
    defer gpa.free(bgs);
    const threads = try gpa.alloc(std.Thread, bgs.len);
    defer gpa.free(threads);
    for (bgs, threads, 0..) |*b, *t, i| {
        b.* = .{ .files = bg_files.items, .io = io, .gpa = gpa };
        t.* = std.Thread.spawn(.{}, bgWorker, .{b}) catch |err| {
            // Join dei thread già partiti prima che i defer chiudano scheduler
            // e plugin sotto i loro piedi.
            for (threads[0..i]) |started| started.join();
            return err;
        };
    }
    for (bgs) |*b| while (!b.started.load(.acquire)) {
        _ = usleep(1000);
    };
    _ = usleep(30_000); // lo sfondo è già dentro un decode

    const fg_t0 = now(io);
    {
        var d = decoder.decode(fg, io, gpa);
        d.deinit(gpa);
    }
    const fg_ns: u64 = @intCast(now(io) - fg_t0);
    for (threads) |t| t.join();

    // Join dei worker, poi i contatori (vedi perfcount.zig).
    scheduler.deinitGlobal();
    var ru: linux.rusage = undefined;
    _ = getrusage(linux.rusage.SELF, &ru);
    {
        var pb: [512]u8 = undefined;
        var pw = std.Io.File.stdout().writer(io, &pb);
        try pw.interface.print("perf user_ms={d} sys_ms={d} vcsw={d} ivcsw={d} minflt={d}", .{
            @as(i64, ru.utime.sec) * 1000 + @divTrunc(ru.utime.usec, 1000),
            @as(i64, ru.stime.sec) * 1000 + @divTrunc(ru.stime.usec, 1000),
            ru.nvcsw,
            ru.nivcsw,
            ru.minflt,
        });
        try pc.print(&pw.interface);
        try pw.interface.print("\n", .{});
        try pw.interface.flush();
    }
    var bg_max: u64 = 0;
    for (bgs) |b| bg_max = @max(bg_max, b.elapsed_ns);
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("solo_ms={d} fg_under_load_ms={d} bg_total_ms={d}\n", .{
        solo_ns / std.time.ns_per_ms, fg_ns / std.time.ns_per_ms, bg_max / std.time.ns_per_ms,
    });
    try w.interface.flush();
}
