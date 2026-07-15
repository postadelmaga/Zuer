//! Sonda di sviluppo: apre un file con player.Player e itera tutti i frame
//! video, stampando durata, numero di frame e PTS finale. Verifica headless del
//! motore di streaming. Uso: zig build player-test -- <file>

const std = @import("std");
const player = @import("decoders/player.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingArg;
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    var p = player.Player.open(path_z.ptr) catch |e| {
        std.debug.print("open fallita: {s}\n", .{@errorName(e)});
        return e;
    };
    defer p.deinit();

    std.debug.print("durata: {d:.2}s, time_base: {d:.6}\n", .{ p.duration_s, p.time_base });

    var count: usize = 0;
    var last_pts: f64 = 0;
    var first_dims: [2]usize = .{ 0, 0 };
    // NB: col player live `frame.pixels` è PRESTATO (scratch interno del player,
    // liberato da `p.deinit`): liberarlo qui manderebbe la sws_scale del frame
    // successivo a scrivere su memoria morta (segfault in libswscale).
    while (try p.nextFrame(320, gpa)) |frame| {
        if (count == 0) first_dims = .{ frame.width, frame.height };
        count += 1;
        last_pts = frame.pts_s;
    }
    std.debug.print("frame decodificati: {d}, dimensioni: {d}x{d}, PTS finale: {d:.3}s\n", .{ count, first_dims[0], first_dims[1], last_pts });
}
