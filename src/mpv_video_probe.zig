//! Tool di sviluppo (Fase 1, piano libmpv): verifica isolata di mpv_video.zig
//! senza collegarlo a VideoDecoder/gui.zig. `zig build mpv-video-test -- <file>`.

const std = @import("std");
const mpv_video = @import("decoders/mpv_video.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("uso: mpv-video-test <file>\n", .{});
        return error.MissingArg;
    };
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    var mv = mpv_video.MpvVideo.init() catch |e| {
        std.debug.print("init fallita: {}\n", .{e});
        return e;
    };
    defer mv.deinit();
    std.debug.print("mpv_video: init ok\n", .{});

    mv.loadFile(path_z);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var got: u32 = 0;
    var tries: u32 = 0;
    while (got < 10 and tries < 2000) : (tries += 1) {
        const fr = mv.pollFrame(&out, gpa) catch |e| {
            std.debug.print("pollFrame errore: {}\n", .{e});
            continue;
        };
        if (fr) |f| {
            got += 1;
            // media RGBA grezza, giusto per verificare che non sia tutto nero/spazzatura
            var sum: u64 = 0;
            var n: u64 = 0;
            var i: usize = 0;
            const need: usize = @as(usize, f.width) * @as(usize, f.height) * 4;
            while (i < need) : (i += 40) {
                sum += out.items[i];
                n += 1;
            }
            const mean: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));
            std.debug.print("frame {d}: {d}x{d} pts={d:.3} mean~={d:.2}\n", .{ got, f.width, f.height, f.pts_s, mean });
        } else {
            const req = std.c.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&req, null);
        }
    }
    if (got == 0) {
        std.debug.print("nessun frame estratto dopo {d} tentativi\n", .{tries});
        return error.NoFrames;
    }
    std.debug.print("ok: {d} frame estratti\n", .{got});
}
