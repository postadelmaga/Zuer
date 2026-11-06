//! Sveglia tra thread senza polling: un contatore di epoca su cui il thread di
//! decodifica dorme (futex) finché qualcuno non ha qualcosa per lui — un frame
//! pronto in mpv, un evento, un comando (seek/pausa/stop), uno slot liberato dal
//! present. Nessun timeout periodico: in pausa il thread non si sveglia mai.
//!
//! Protocollo: `s = prepare()`, poi controlla lo stato condiviso, poi `wait(s)`.
//! Una `notify` arrivata dopo `prepare` cambia l'epoca e `wait` torna subito: il
//! risveglio non si perde. Chi notifica può essere qualunque thread, anche un
//! callback di libmpv.
//!
//! Fuori da Linux (Windows: solo il decoder FFmpeg di ripiego) `wait` dorme al più
//! `fallback_ms` — lì resta un'attesa a tempo, mai un busy-wait.

const std = @import("std");
const builtin = @import("builtin");

const fallback_ms: u64 = 4;

pub const Wake = struct {
    seq: std.atomic.Value(u32) = .init(0),

    pub fn prepare(w: *const Wake) u32 {
        return w.seq.load(.acquire);
    }

    pub fn notify(w: *Wake) void {
        _ = w.seq.fetchAdd(1, .release);
        if (comptime builtin.os.tag == .linux) {
            const linux = std.os.linux;
            _ = linux.futex_3arg(&w.seq.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
        }
    }

    /// Callback C (libmpv: wakeup ed update) che notifica la `Wake` passata come contesto.
    pub fn notifyC(ctx: ?*anyopaque) callconv(.c) void {
        const w: *Wake = @ptrCast(@alignCast(ctx.?));
        w.notify();
    }

    /// Dorme finché l'epoca è ancora `snapshot` (o fino a `timeout_ns`, se dato).
    pub fn wait(w: *Wake, snapshot: u32, timeout_ns: ?u64) void {
        if (w.seq.load(.acquire) != snapshot) return;
        if (comptime builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var ts: linux.timespec = undefined;
            const tsp: ?*const linux.timespec = if (timeout_ns) |ns| blk: {
                ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
                break :blk &ts;
            } else null;
            _ = linux.futex_4arg(&w.seq.raw, .{ .cmd = .WAIT, .private = true }, snapshot, tsp);
        } else {
            const ms = if (timeout_ns) |ns| @min(fallback_ms, ns / std.time.ns_per_ms) else fallback_ms;
            sleepMs(ms);
        }
    }
};

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

fn sleepMs(ms: u64) void {
    if (comptime builtin.os.tag == .windows) {
        Sleep(@intCast(ms));
    } else {
        const req = std.c.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&req, null);
    }
}

test "una notify dopo prepare non si perde" {
    var w: Wake = .{};
    const s = w.prepare();
    w.notify();
    w.wait(s, null); // tornerebbe solo per timeout se la notify fosse persa: qui non c'è timeout
    try std.testing.expect(w.prepare() != s);
}

test "wait con timeout torna senza notify" {
    var w: Wake = .{};
    const s = w.prepare();
    w.wait(s, 2 * std.time.ns_per_ms);
    try std.testing.expectEqual(s, w.prepare());
}
