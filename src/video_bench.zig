//! Banco della pipeline video: fa girare lo STESSO codice della GUI (`video.setupVideo`,
//! `advanceVideo`, `deinit`) senza finestra, e misura quello che serve per giudicarla.
//!
//!   zuer-video-bench <file|url> [play S] [pause S] [seek] [cycles N]
//!
//! Fasi, nell'ordine in cui compaiono sulla riga di comando:
//! * `play S`   — riproduce per S secondi a 60 Hz di present: frame presentati, CPU
//!                (utente+sistema) per secondo, context switch volontari/involontari.
//! * `pause S`  — in pausa per S secondi: stessa misura (deve stare vicino a zero).
//! * `seek`     — 6 seek avanti/indietro: latenza fino al primo frame della posizione.
//! * `cycles N` — N aperture+chiusure: fd e thread prima/dopo (non devono crescere).
//! * `cycles-cold N` — come `cycles`, ma chiudendo anche il motore a ogni giro
//!                (tutto ricreato e smontato: verifica il teardown completo).
//! * `cycles-seek N` — come `cycles`, ma chiudendo subito dopo aver chiesto un seek
//!                (chiusura con seek in volo: il motore deve scaricarlo e restare sano).
//! * `detach`   — spegne il video come il tasto `v` (l'audio passa all'AudioPlayer).
//! * `wait S`   — aspetta S secondi senza presentare (con `detach`: suona solo l'audio).
//!
//! Serve una connessione Wayland (mpv crea il suo contesto EGL su di essa): lanciarlo
//! dentro una sessione, anche headless. Righe di risultato con prefisso `bench:`.

const std = @import("std");
const video = @import("video.zig");

const linux = std.os.linux;

fn nowNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
}

fn sleepNs(ns: i64) void {
    if (ns <= 0) return;
    const req = linux.timespec{ .sec = @intCast(@divTrunc(ns, 1_000_000_000)), .nsec = @intCast(@mod(ns, 1_000_000_000)) };
    _ = linux.nanosleep(&req, null);
}

/// Voci in una directory di /proc/self (fd aperti, thread vivi).
fn countDir(path: [*:0]const u8) usize {
    const d = std.c.opendir(path) orelse return 0;
    defer _ = std.c.closedir(d);
    var n: usize = 0;
    while (std.c.readdir(d)) |e| {
        const name: [*:0]const u8 = @ptrCast(&e.name);
        if (name[0] != '.') n += 1;
    }
    return n;
}

/// Un campo in kB di /proc/self/status (`VmRSS`, `VmHWM`).
fn statusKb(comptime key: []const u8) u64 {
    const fd = std.c.open("/proc/self/status", .{});
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    const txt = buf[0..@intCast(n)];
    const at = std.mem.indexOf(u8, txt, key ++ ":") orelse return 0;
    var it = std.mem.tokenizeAny(u8, txt[at + key.len + 1 ..], " \t\n");
    return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
}

const Usage = struct { cpu_ns: i64, vcsw: i64, ivcsw: i64 };

fn usage() Usage {
    var ru: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &ru);
    const tv = struct {
        fn ns(t: linux.timeval) i64 {
            return @as(i64, t.sec) * 1_000_000_000 + @as(i64, t.usec) * 1000;
        }
    };
    return .{ .cpu_ns = tv.ns(ru.utime) + tv.ns(ru.stime), .vcsw = ru.nvcsw, .ivcsw = ru.nivcsw };
}

const Sink = struct {
    rgba: []align(4) u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,

    fn frameSink(self: *Sink, gpa: std.mem.Allocator) video.FrameSink {
        return .{ .gpa = gpa, .rgba = &self.rgba, .w = &self.w, .h = &self.h };
    }
};

/// Durata dell'ultima chiusura di sessione (deinit: stop di mpv compreso).
var last_close_ms: f64 = 0;
/// Tempo passato in buffering (rete) durante le fasi `play`, azzerato da `report`.
var buffering_ns: i64 = 0;

const Session = struct {
    vs: video.VideoState = .{},
    sink: Sink = .{},
    gpa: std.mem.Allocator,

    fn open(gpa: std.mem.Allocator, path: []const u8) !Session {
        var s: Session = .{ .gpa = gpa };
        // ZUER_BENCH_AUDIO_URL: traccia audio a parte, come un DASH di YouTube
        // (stesso percorso di `yt_search.openWorker`).
        const first = if (std.c.getenv("ZUER_BENCH_AUDIO_URL")) |a|
            try video.setupStream(&s.vs, path, std.mem.span(a), gpa)
        else
            try video.setupVideo(&s.vs, path, gpa);
        s.sink = .{ .rgba = first.rgba, .w = first.w, .h = first.h };
        if (s.vs.decoder) |d| d.setTargetSize(first.w, first.h);
        return s;
    }

    fn close(s: *Session) void {
        const t0 = nowNs();
        s.vs.deinit();
        last_close_ms = @as(f64, @floatFromInt(nowNs() - t0)) / 1e6;
        if (s.sink.rgba.len > 0) s.gpa.free(s.sink.rgba);
        s.sink = .{};
    }

    /// Present a 60 Hz per `secs` secondi; ritorna i frame presentati.
    fn run(s: *Session, secs: f64) u64 {
        const period: i64 = 16_666_667;
        const end = nowNs() + @as(i64, @intFromFloat(secs * 1e9));
        var last = nowNs();
        var presented: u64 = 0;
        while (nowNs() < end) {
            const t = nowNs();
            const dt: f32 = @floatCast(@as(f64, @floatFromInt(t - last)) / 1e9);
            last = t;
            if (video.advanceVideo(s.sink.frameSink(s.gpa), &s.vs, dt)) presented += 1;
            if (s.vs.decoder) |d| if (d.isBuffering()) {
                buffering_ns += period;
            };
            sleepNs(period - (nowNs() - t));
        }
        return presented;
    }
};

fn report(label: []const u8, secs: f64, ua: Usage, ub: Usage, frames: u64) void {
    const cpu_pct = @as(f64, @floatFromInt(ub.cpu_ns - ua.cpu_ns)) / (secs * 1e9) * 100.0;
    std.debug.print("bench: {s} secs={d:.1} frames={d} fps={d:.1} cpu={d:.1}% vcsw/s={d:.0} ivcsw/s={d:.0} rss_mb={d} buffering_s={d:.1}\n", .{
        label,                                               secs,                     frames,
        @as(f64, @floatFromInt(frames)) / secs,              cpu_pct,                  @as(f64, @floatFromInt(ub.vcsw - ua.vcsw)) / secs,
        @as(f64, @floatFromInt(ub.ivcsw - ua.ivcsw)) / secs, statusKb("VmRSS") / 1024, @as(f64, @floatFromInt(buffering_ns)) / 1e9,
    });
    buffering_ns = 0;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("uso: zuer-video-bench <file|url> [play S] [pause S] [seek] [cycles N]\n", .{});
        return error.MissingArg;
    };

    const fd0 = countDir("/proc/self/fd");
    const th0 = countDir("/proc/self/task");
    std.debug.print("bench: start fds={d} threads={d}\n", .{ fd0, th0 });

    const t_open = nowNs();
    var s = Session.open(gpa, path) catch |e| {
        // Sorgente che non si apre (rete giù, server muto): conta quanto ci mette
        // a dirlo e che non resti niente aperto.
        std.debug.print("bench: open fallita ms={d:.1} err={s}\n", .{ @as(f64, @floatFromInt(nowNs() - t_open)) / 1e6, @errorName(e) });
        if (@hasDecl(video, "shutdownEngines")) video.shutdownEngines();
        const t_wait = nowNs();
        while (countDir("/proc/self/task") > th0 and nowNs() - t_wait < 2 * std.time.ns_per_s) sleepNs(10 * std.time.ns_per_ms);
        std.debug.print("bench: end fds={d} threads={d}\n", .{ countDir("/proc/self/fd"), countDir("/proc/self/task") });
        return;
    };
    std.debug.print("bench: open ms={d:.1} size={d}x{d} dur={d:.2}s fds={d} threads={d}\n", .{
        @as(f64, @floatFromInt(nowNs() - t_open)) / 1e6, s.sink.w, s.sink.h, s.vs.dur_s, countDir("/proc/self/fd"), countDir("/proc/self/task"),
    });

    while (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "play") or std.mem.eql(u8, cmd, "pause")) {
            const secs = try std.fmt.parseFloat(f64, args.next() orelse "5");
            s.vs.playing = std.mem.eql(u8, cmd, "play");
            _ = s.run(0.3); // lascia assestare lo stato (pausa propagata al backend)
            const ua = usage();
            const frames = s.run(secs);
            report(cmd, secs, ua, usage(), frames);
        } else if (std.mem.eql(u8, cmd, "detach")) {
            // Come il tasto `v`: il video si spegne, l'audio passa all'AudioPlayer
            // (FFmpeg, uscita audio di Zicro) sulla stessa sorgente.
            const t0 = nowNs();
            const ok = video.detachVideo(&s.vs, gpa);
            std.debug.print("bench: detach ok={} ms={d:.1} audio_player={}\n", .{ ok, @as(f64, @floatFromInt(nowNs() - t0)) / 1e6, s.vs.audio != null });
        } else if (std.mem.eql(u8, cmd, "wait")) {
            const secs = try std.fmt.parseFloat(f64, args.next() orelse "1");
            sleepNs(@intFromFloat(secs * 1e9));
        } else if (std.mem.eql(u8, cmd, "seek")) {
            s.vs.playing = true;
            const dur = if (s.vs.dur_s > 0) s.vs.dur_s else 10.0;
            const targets = [_]f64{ 0.6, 0.2, 0.8, 0.1, 0.5, 0.3 };
            for (targets) |f| {
                const target = dur * f;
                s.vs.seek_to = target;
                const t0 = nowNs();
                var got = false;
                var last = nowNs();
                while (nowNs() - t0 < 3_000_000_000) {
                    const t = nowNs();
                    const dt: f32 = @floatCast(@as(f64, @floatFromInt(t - last)) / 1e9);
                    last = t;
                    if (video.advanceVideo(s.sink.frameSink(gpa), &s.vs, dt)) {
                        got = true;
                        break;
                    }
                    sleepNs(2_000_000);
                }
                std.debug.print("bench: seek to={d:.2} ms={d:.1} pos={d:.2} ok={}\n", .{ target, @as(f64, @floatFromInt(nowNs() - t0)) / 1e6, s.vs.pos_s, got });
                _ = s.run(0.4);
            }
        } else if (std.mem.eql(u8, cmd, "cycles") or std.mem.eql(u8, cmd, "cycles-cold") or std.mem.eql(u8, cmd, "cycles-seek")) {
            const cold = std.mem.eql(u8, cmd, "cycles-cold");
            const seek_close = std.mem.eql(u8, cmd, "cycles-seek");
            const n = try std.fmt.parseInt(u32, args.next() orelse "20", 10);
            s.close();
            if (cold) if (@hasDecl(video, "shutdownEngines")) video.shutdownEngines();
            const fa = countDir("/proc/self/fd");
            const ta = countDir("/proc/self/task");
            var i: u32 = 0;
            var open_ns: i64 = 0;
            var max_close: f64 = 0;
            while (i < n) : (i += 1) {
                const t0 = nowNs();
                s = try Session.open(gpa, path);
                open_ns += nowNs() - t0;
                if (seek_close) {
                    _ = s.run(0.05);
                    s.vs.seek_to = if (s.vs.dur_s > 0) s.vs.dur_s * (0.2 + 0.6 * @as(f64, @floatFromInt(i % 7)) / 7.0) else 1.0;
                    _ = s.run(0.02); // il seek parte, la chiusura lo trova in volo
                } else _ = s.run(0.15);
                s.close();
                max_close = @max(max_close, last_close_ms);
                if (cold) if (@hasDecl(video, "shutdownEngines")) video.shutdownEngines();
                if (i % 10 == 9 or i + 1 == n) std.debug.print("bench: cycle {d} fds={d} threads={d}\n", .{ i + 1, countDir("/proc/self/fd"), countDir("/proc/self/task") });
            }
            std.debug.print("bench: {s} n={d} fds {d}->{d} threads {d}->{d} avg_open_ms={d:.1} max_close_ms={d:.1}\n", .{
                cmd, n, fa, countDir("/proc/self/fd"), ta, countDir("/proc/self/task"), @as(f64, @floatFromInt(open_ns)) / @as(f64, @floatFromInt(n)) / 1e6, max_close,
            });
            s = try Session.open(gpa, path);
        } else {
            std.debug.print("bench: comando ignoto '{s}'\n", .{cmd});
        }
    }
    s.close();
    std.debug.print("bench: close ms={d:.1}\n", .{last_close_ms});
    const fe = countDir("/proc/self/fd");
    const te = countDir("/proc/self/task");
    if (@hasDecl(video, "shutdownEngines")) video.shutdownEngines();
    std.debug.print("bench: closed fds={d} threads={d} (motore inattivo nel pool)\n", .{ fe, te });
    std.debug.print("bench: peak_rss_mb={d}\n", .{statusKb("VmHWM") / 1024});
    // Thread di librerie (mesa, pipewire) che escono un attimo dopo il teardown:
    // conta solo se tornano al valore di partenza.
    const t_wait = nowNs();
    while (countDir("/proc/self/task") > th0 and nowNs() - t_wait < 2 * std.time.ns_per_s) sleepNs(10 * std.time.ns_per_ms);
    if (@hasDecl(video, "wrongThreadCalls")) std.debug.print("bench: wrong_thread_calls={d}\n", .{video.wrongThreadCalls()});
    std.debug.print("bench: settle_ms={d:.0}\n", .{@as(f64, @floatFromInt(nowNs() - t_wait)) / 1e6});
    std.debug.print("bench: end fds={d} threads={d}\n", .{ countDir("/proc/self/fd"), countDir("/proc/self/task") });
}
