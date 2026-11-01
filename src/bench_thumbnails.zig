//! Benchmark headless della pipeline miniature: usa `thumbs.zig`, lo stesso
//! codice dell'esploratore della GUI (fillSizes, claim, decode, cache,
//! installazione), senza finestra.
//!
//! Uno scenario per processo, così RAM massima e thread restano isolati; lo
//! script `scripts/bench-thumbnails.sh` alterna scenari e ripetizioni.
//!
//! Uso: bench-thumbnails <cartella> <scenario> [cache]
//!   scenario: seq           tutto sul thread chiamante, senza scheduler
//!             w<N>          scheduler con N worker e N job (es. w1, w4)
//!             auto          scheduler e job di default (come la GUI)
//!   cache:    none          (default) nessuna cache su disco: solo decode
//!             <percorso>    cache su disco in quella cartella
//!
//! Apertura di un file durante le miniature (la "reattività" misurabile senza
//! finestra): `ZUER_BENCH_FG=<file>` decodifica quel file sul thread
//! principale come fa il loader della GUI (priorità `interactive` e segnale
//! di primo piano), prima da solo e poi `ZUER_BENCH_FG_DELAY_MS` (default 300)
//! dopo l'avvio delle miniature. `ZUER_BENCH_FG_SIGNAL=0` toglie il segnale di
//! primo piano, per misurarne l'effetto.
//!
//! Stampa una riga `chiave=valore` con: tempo reale, CPU utente+sistema (anche
//! dei processi figli, es. pdftoppm), cambi di contesto, RSS massima, thread
//! (picco e creati dallo scheduler), miniature fatte/fallite, hit/miss della
//! cache, tempi per miniatura (media, mediana, p95), attesa in coda e un hash
//! delle miniature prodotte (deve coincidere fra tutti gli scenari).

const std = @import("std");
const decoder = @import("decoder.zig");
const scheduler = @import("scheduler.zig");
const thumbs = @import("thumbs.zig");
const perfcount = @import("perfcount.zig");

const linux = std.os.linux;
extern "c" fn getrusage(who: c_int, usage: *linux.rusage) c_int;

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn tvNs(tv: linux.timeval) u64 {
    return @as(u64, @intCast(tv.sec)) * std.time.ns_per_s + @as(u64, @intCast(tv.usec)) * std.time.ns_per_us;
}

const Usage = struct { cpu_ns: u64, sys_ns: u64, child_cpu_ns: u64, vcsw: u64, ivcsw: u64, minflt: u64, maxrss_kb: u64 };

fn usage() Usage {
    var s: linux.rusage = undefined;
    var c: linux.rusage = undefined;
    _ = getrusage(linux.rusage.SELF, &s);
    _ = getrusage(linux.rusage.CHILDREN, &c);
    return .{
        .cpu_ns = tvNs(s.utime) + tvNs(s.stime),
        .sys_ns = tvNs(s.stime),
        .minflt = @intCast(s.minflt),
        .child_cpu_ns = tvNs(c.utime) + tvNs(c.stime),
        .vcsw = @intCast(s.nvcsw),
        .ivcsw = @intCast(s.nivcsw),
        .maxrss_kb = @intCast(s.maxrss),
    };
}

/// Campiona `Threads:` da /proc/self/status ogni 2 ms (lui escluso).
const Sampler = struct {
    io: std.Io,
    stop: std.atomic.Value(bool) = .init(false),
    peak: usize = 0,

    fn run(self: *Sampler) void {
        while (!self.stop.load(.acquire)) {
            self.sample();
            self.io.sleep(.fromMilliseconds(2), .awake) catch {};
        }
        self.sample();
    }

    fn sample(self: *Sampler) void {
        var buf: [4096]u8 = undefined;
        const data = std.Io.Dir.cwd().readFile(self.io, "/proc/self/status", &buf) catch return;
        const key = "Threads:";
        const i = std.mem.indexOf(u8, data, key) orelse return;
        var rest = std.mem.trimStart(u8, data[i + key.len ..], " \t");
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        rest = rest[0..end];
        const n = std.fmt.parseInt(usize, rest, 10) catch return;
        self.peak = @max(self.peak, n -| 1);
    }
};

const FgTimes = struct {
    /// Fino alla prima resa: il tier coarse se il plugin lo offre (come
    /// `nav.loadWorker`), altrimenti il decode completo.
    first_ns: u64 = 0,
    full_ns: u64 = 0,
};

/// Decode del file aperto dall'utente, nello stesso ordine di `nav.loadWorker`:
/// segnale di primo piano, coarse, poi completo. Il decode parte subito: il
/// loader ha un thread suo, non passa da una coda.
fn timedForeground(io: std.Io, gpa: std.mem.Allocator, path: []const u8, signal: bool) FgTimes {
    if (signal) scheduler.beginForeground();
    defer if (signal) scheduler.endForeground();
    var r: FgTimes = .{};
    const t0 = now(io);
    if (decoder.decodeCoarse(path, io, gpa)) |c| {
        var cc = c;
        if (cc != .err) r.first_ns = @intCast(now(io) - t0);
        cc.deinit(gpa);
    }
    var d = decoder.decode(path, io, gpa);
    d.deinit(gpa);
    r.full_ns = @intCast(now(io) - t0);
    if (r.first_ns == 0) r.first_ns = r.full_ns;
    return r;
}

fn lessEntry(_: void, a: thumbs.Entry, b: thumbs.Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Le voci della cartella come le prepara `enterDir` (nomi, niente stat).
fn scanDir(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]thumbs.Entry {
    var list: std.ArrayList(thumbs.Entry) = .empty;
    errdefer thumbs.freeEntries(gpa, list.items);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.name.len == 0 or e.name[0] == '.') continue;
        if (e.kind != .file and e.kind != .sym_link and e.kind != .directory) continue;
        if (list.items.len >= thumbs.max_entries) break;
        try list.append(gpa, .{ .name = try gpa.dupe(u8, e.name), .is_dir = e.kind == .directory });
    }
    std.mem.sort(thumbs.Entry, list.items, {}, lessEntry);
    return list.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const dir_path = args.next() orelse return error.MissingArg;
    const scenario = args.next() orelse return error.MissingArg;
    const cache_arg = args.next() orelse "none";

    var workers: ?usize = null;
    var jobs: u32 = 0;
    const sequential = std.mem.eql(u8, scenario, "seq");
    if (!sequential and !std.mem.eql(u8, scenario, "auto")) {
        if (scenario.len < 2 or scenario[0] != 'w') return error.BadScenario;
        const n = try std.fmt.parseInt(u32, scenario[1..], 10);
        workers = n;
        jobs = n;
    }
    if (!sequential) scheduler.initGlobal(io, .{ .workers = workers });
    defer decoder.closePluginCache(gpa);
    defer scheduler.deinitGlobal();

    var mutex: std.Io.Mutex = .init;
    var idle: std.Io.Condition = .init;
    var changed = false;
    var stats: thumbs.Stats = .{};
    var fx: thumbs.FxState = .{};
    defer {
        thumbs.freeEntries(gpa, fx.entries);
        gpa.free(fx.dir);
    }
    fx.entries = try scanDir(io, gpa, dir_path);
    fx.dir = try gpa.dupe(u8, dir_path);

    const host: thumbs.Host = .{
        .io = io,
        .gpa = gpa,
        .mutex = &mutex,
        .fx = &fx,
        .changed = &changed,
        .jobs = jobs,
        .cache = if (std.mem.eql(u8, cache_arg, "none")) .none else .{ .path = cache_arg },
        .idle_cond = &idle,
        .stats = &stats,
    };

    // Riscaldamento: carica una volta i plugin dei formati presenti (il dlopen
    // non è oggetto della misura). Decode coarse del primo file per estensione.
    {
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(gpa);
        for (fx.entries) |e| {
            if (e.is_dir or !thumbs.thumbable(e.name)) continue;
            const ext = decoder.getExtension(e.name);
            var dup = false;
            for (seen.items) |x| dup = dup or std.ascii.eqlIgnoreCase(x, ext);
            if (dup) continue;
            try seen.append(gpa, ext);
            const full = try std.fs.path.join(gpa, &.{ dir_path, e.name });
            defer gpa.free(full);
            // Carica il plugin; il risultato si butta (fuori dalla misura).
            if (decoder.decodeCoarse(full, io, gpa)) |d| {
                var dd = d;
                dd.deinit(gpa);
            }
        }
    }

    // Decode in primo piano da solo (riferimento), plugin già caldo.
    const fg_path: ?[]const u8 = if (std.c.getenv("ZUER_BENCH_FG")) |v| std.mem.span(v) else null;
    const fg_delay_ms: u64 = if (std.c.getenv("ZUER_BENCH_FG_DELAY_MS")) |v| std.fmt.parseInt(u64, std.mem.span(v), 10) catch 300 else 300;
    const fg_signal = if (std.c.getenv("ZUER_BENCH_FG_SIGNAL")) |v| !std.mem.eql(u8, std.mem.span(v), "0") else true;
    var fg_alone: FgTimes = .{};
    var fg_during: FgTimes = .{};
    if (fg_path) |p| {
        scheduler.setThreadPriority(.interactive);
        var d0 = decoder.decode(p, io, gpa);
        d0.deinit(gpa);
        fg_alone = timedForeground(io, gpa, p, fg_signal);
    }

    var sampler = Sampler{ .io = io };
    const sampler_thread = try std.Thread.spawn(.{}, Sampler.run, .{&sampler});

    // Contatori aperti dopo il campionatore (che così non conta) e prima dei
    // worker, creati pigramente dal primo submit: li ereditano tutti.
    var pc = perfcount.Counters.open();
    defer pc.close();
    const us0 = usage();
    const t0 = now(io);
    mutex.lockUncancelable(io);
    const gen = fx.bumpGeneration();
    mutex.unlock(io);
    if (sequential) {
        thumbs.runInline(&host, gen);
    } else {
        thumbs.start(host, gen);
        if (fg_path) |p| {
            io.sleep(.fromMilliseconds(@intCast(fg_delay_ms)), .awake) catch {};
            fg_during = timedForeground(io, gpa, p, fg_signal);
        }
        mutex.lockUncancelable(io);
        while (fx.thumb_jobs != 0) idle.waitUncancelable(io, &mutex);
        mutex.unlock(io);
    }
    const wall_ns: u64 = @intCast(now(io) - t0);
    const us1 = usage();
    const sst: ?scheduler.Stats = if (scheduler.get()) |s| s.stats() else null;
    sampler.stop.store(true, .release);
    sampler_thread.join();
    // Join di tutti i worker: solo allora i loro contatori confluiscono.
    scheduler.deinitGlobal();

    // Hash delle miniature installate, in ordine di nome.
    var h = std.hash.Wyhash.init(0);
    var made: usize = 0;
    for (fx.entries) |e| {
        if (e.thumb_w == 0) continue;
        made += 1;
        h.update(e.name);
        h.update(std.mem.asBytes(&e.thumb_w));
        h.update(std.mem.asBytes(&e.thumb_h));
        h.update(e.thumb_rgba);
    }

    const times = stats.decode_ns[0..stats.decode_count];
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (times) |t| sum += t;
    const ms = std.time.ns_per_ms;
    const n = times.len;
    const mean = if (n > 0) sum / n else 0;
    const median = if (n > 0) times[n / 2] else 0;
    const p95 = if (n > 0) times[@min(n - 1, (n * 95 + 99) / 100 - 1)] else 0;
    const thr_x100 = if (wall_ns > 0) made * 100 * std.time.ns_per_s / wall_ns else 0;

    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(
        "scenario={s} wall_ms={d} cpu_ms={d} sys_ms={d} minflt={d} child_cpu_ms={d} thumbs={d} failed={d} " ++
            "thr_per_s={d}.{d:0>2} mean_ms={d} median_ms={d} p95_ms={d} " ++
            "cache_hit={d} cache_miss={d} vcsw={d} ivcsw={d} maxrss_mb={d} " ++
            "threads_peak={d} threads_spawned={d} jobs_max={d} jobs_retired={d} " ++
            "qwait_mean_us={d} qwait_max_us={d} fg_alone_first_ms={d} fg_alone_ms={d} fg_during_first_ms={d} fg_during_ms={d} hash={x}\n",
        .{
            scenario,                                                                                                           wall_ns / ms,
            (us1.cpu_ns - us0.cpu_ns) / ms,                                                                                     (us1.sys_ns - us0.sys_ns) / ms,
            us1.minflt - us0.minflt,                                                                                            (us1.child_cpu_ns - us0.child_cpu_ns) / ms,
            made,                                                                                                               stats.failed.load(.monotonic),
            thr_x100 / 100,                                                                                                     thr_x100 % 100,
            mean / ms,                                                                                                          median / ms,
            p95 / ms,                                                                                                           stats.cache_hits.load(.monotonic),
            stats.cache_misses.load(.monotonic),                                                                                us1.vcsw - us0.vcsw,
            us1.ivcsw - us0.ivcsw,                                                                                              us1.maxrss_kb / 1024,
            sampler.peak,                                                                                                       if (sst) |s| s.threads_spawned else 0,
            stats.max_jobs.load(.monotonic),                                                                                    stats.jobs_retired.load(.monotonic),
            if (sst) |s| (if (s.tasks_started > 0) s.queue_wait_ns_total / s.tasks_started / std.time.ns_per_us else 0) else 0, if (sst) |s| s.queue_wait_ns_max / std.time.ns_per_us else 0,
            fg_alone.first_ns / ms,                                                                                             fg_alone.full_ns / ms,
            fg_during.first_ns / ms,                                                                                            fg_during.full_ns / ms,
            h.final(),
        },
    );
    try w.interface.flush();
    var buf2: [512]u8 = undefined;
    var w2 = std.Io.File.stdout().writer(io, &buf2);
    try w2.interface.print("perf scenario={s}", .{scenario});
    try pc.print(&w2.interface);
    try w2.interface.print("\n", .{});
    try w2.interface.flush();
}
