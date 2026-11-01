//! Scheduler globale di Zuer: un solo insieme di worker condiviso da tutti i
//! lavori CPU-bound (texture dei GLB, miniature, scritture di cache), con code
//! per priorità al posto dei `Thread.spawn` sparsi.
//!
//! Scelte, in breve:
//! - **Worker pigri e limitati.** Nessun thread finché non arriva lavoro; poi al
//!   massimo `workers` (default: core logici − 1, `ZUER_WORKERS` per forzarlo).
//!   Il thread che chiede un `parallelFor` lavora anche lui, quindi con N worker
//!   girano al più N+1 thread CPU-bound per richiesta.
//! - **Una coda FIFO per priorità, sotto un mutex.** Niente lock-free né work
//!   stealing: i task sono pochi e grossi (una texture, una miniatura), il costo
//!   del lock è trascurabile rispetto al lavoro e il codice resta verificabile.
//! - **Priorità con anti-starvation.** Si prende sempre la coda più alta non
//!   vuota, ma dopo `fairness_window` scelte consecutive che scavalcano lavoro
//!   in attesa si serve una volta la coda più bassa non vuota.
//! - **Niente preemption.** Un task già in esecuzione finisce. Per questo un
//!   `parallelFor` interattivo non dipende mai dai worker: il chiamante drena da
//!   sé gli indici, i worker liberi aiutano solo.
//! - **Ownership esplicita.** I task sono nodi intrusivi forniti dal chiamante:
//!   lo scheduler non alloca per task. Un task si libera solo dopo che
//!   `cancel` ha ritornato true o `wait` è ritornata, oppure, se il task è
//!   "fire-and-forget", dentro il suo `on_done`, che il worker chiama per ultimo.

const std = @import("std");

pub const Priority = enum(u8) {
    /// Serve alla visualizzazione immediata (il frame che l'utente sta guardando).
    critical,
    /// Apertura e decode chiesti dall'utente.
    interactive,
    /// Miniature e lavoro ordinario.
    normal,
    /// Prefetch, scritture di cache, lavoro differibile.
    background,
};

const n_prio = @typeInfo(Priority).@"enum".field_names.len;

pub const State = enum(u8) { idle, queued, running, done, cancelled };

pub const Task = struct {
    run_fn: *const fn (*Task) void,
    priority: Priority = .normal,
    /// Facoltativo: chiamato dal worker DOPO `run_fn` o dopo una cancellazione
    /// allo shutdown, quando lo scheduler non tocca più il task. È il posto
    /// dove un task fire-and-forget si libera. Con `on_done` impostato non si
    /// chiama `wait` (il task può essere già stato liberato).
    on_done: ?*const fn (*Task) void = null,

    next: ?*Task = null,
    state: State = .idle,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    /// Il task in esecuzione può controllarlo per uscire prima.
    pub fn cancelRequested(self: *const Task) bool {
        return self.cancel_flag.load(.monotonic);
    }
};

pub const Config = struct {
    /// Numero massimo di worker; null = core logici − 1 (minimo 1).
    workers: ?usize = null,
    /// Oltre questa soglia `submit` rifiuta i task `normal`/`background`
    /// (backpressure). `critical`/`interactive` passano sempre.
    max_queued: usize = 256,
    /// Scelte consecutive che scavalcano una coda più bassa prima di servirla.
    fairness_window: u32 = 8,
    /// Un worker senza lavoro per questo tempo esce e libera stack e cache di
    /// malloc del thread; il prossimo task ne crea uno nuovo (decine di µs).
    /// 0 = i worker restano vivi fino allo shutdown.
    idle_timeout_ms: u32 = 2000,
};

pub const SubmitError = error{ QueueFull, ShuttingDown };

pub const Stats = struct {
    /// Worker vivi adesso.
    live_workers: usize,
    /// Worker creati dall'avvio (compresi quelli poi ritirati).
    threads_spawned: usize,
    /// Worker usciti per inattività.
    threads_retired: usize,
    tasks_run: usize,
    tasks_cancelled: usize,
    max_workers: usize,
};

const max_threads = 64;

const Fifo = struct {
    head: ?*Task = null,
    tail: ?*Task = null,

    fn push(q: *Fifo, t: *Task) void {
        t.next = null;
        if (q.tail) |tl| tl.next = t else q.head = t;
        q.tail = t;
    }

    fn pop(q: *Fifo) ?*Task {
        const t = q.head orelse return null;
        q.head = t.next;
        if (q.head == null) q.tail = null;
        t.next = null;
        return t;
    }

    fn remove(q: *Fifo, t: *Task) bool {
        var prev: ?*Task = null;
        var cur = q.head;
        while (cur) |c| : ({
            prev = c;
            cur = c.next;
        }) {
            if (c != t) continue;
            if (prev) |p| p.next = c.next else q.head = c.next;
            if (q.tail == c) q.tail = prev;
            c.next = null;
            return true;
        }
        return false;
    }
};

pub const Scheduler = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// I worker aspettano lavoro qui.
    work_cond: std.Io.Condition = .init,
    /// `wait` aspetta qui la fine di un task.
    done_cond: std.Io.Condition = .init,
    queues: [n_prio]Fifo = @splat(.{}),
    /// Bit `p` = la coda di priorità `p` non è vuota. Scritto sotto `mutex`,
    /// letto SENZA lock dagli helper di `parallelFor` per cedere il worker a
    /// lavoro più urgente (vedi `ParallelFor.drainYielding`): un valore un
    /// attimo vecchio costa al più un indice in più o in meno, mai la correttezza.
    pending_mask: std.atomic.Value(u8) = .init(0),
    queued: usize = 0,
    idle: usize = 0,
    /// Worker vivi (slot `live` a true).
    spawned: usize = 0,
    live: [max_threads]bool = @splat(false),
    total_spawned: usize = 0,
    retired: usize = 0,
    /// Worker ritirati che non hanno ancora finito l'ultimo `unlock` (che
    /// passa ancora da `io` e dal mutex). `deinit` aspetta che torni a 0: dopo
    /// il decremento un worker ritirato non tocca più nulla dello scheduler.
    exiting: std.atomic.Value(u32) = .init(0),
    /// Copia atomica di `stop`, letta senza lock dai task cooperativi.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Worker già svegliati da un `signal` ma non ancora ripartiti: contano in
    /// `idle` finché non riprendono il mutex, e senza questo conto una raffica
    /// di `submit` li crederebbe liberi e non creerebbe mai worker nuovi.
    signals_pending: usize = 0,
    idle_timeout_ms: u32,
    stop: bool = false,
    streak: u32 = 0,
    max_workers: usize,
    max_queued: usize,
    fairness_window: u32,
    threads: [max_threads]std.Thread = undefined,
    tasks_run: usize = 0,
    tasks_cancelled: usize = 0,

    pub fn init(io: std.Io, cfg: Config) Scheduler {
        const cores = std.Thread.getCpuCount() catch 2;
        const want = cfg.workers orelse @max(1, cores -| 1);
        return .{
            .io = io,
            .max_workers = std.math.clamp(want, 1, max_threads),
            .max_queued = cfg.max_queued,
            .fairness_window = cfg.fairness_window,
            .idle_timeout_ms = cfg.idle_timeout_ms,
        };
    }

    /// Ferma lo scheduler: i task ancora in coda vengono cancellati (il loro
    /// `on_done` viene chiamato, così i fire-and-forget si liberano), quelli in
    /// esecuzione finiscono, poi si fa il join di tutti i worker.
    pub fn deinit(self: *Scheduler) void {
        var drained: Fifo = .{};
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.stop = true;
            self.stopping.store(true, .monotonic);
            for (&self.queues) |*q| {
                while (q.pop()) |t| {
                    t.state = .cancelled;
                    self.tasks_cancelled += 1;
                    // Solo i task con `on_done` restano nostri dopo l'unlock.
                    // Gli altri (es. gli helper di `parallelFor`, sullo stack
                    // del chiamante) tornano al proprietario appena rilasciamo
                    // il lock: non vanno più toccati, nemmeno per `next`.
                    if (t.on_done != null) drained.push(t);
                }
            }
            self.queued = 0;
            self.refreshMask();
            self.work_cond.broadcast(self.io);
            self.done_cond.broadcast(self.io);
        }
        while (drained.pop()) |t| if (t.on_done) |f| f(t);
        // Dopo `stop` nessun worker si ritira più (vedi `workerMain`): gli slot
        // `live` sono stabili e sono esattamente i thread da gioinare.
        for (&self.live, &self.threads) |*l, t| {
            if (!l.*) continue;
            t.join();
            l.* = false;
        }
        self.spawned = 0;
        while (self.exiting.load(.acquire) != 0) std.Thread.yield() catch {};
    }

    pub fn submit(self: *Scheduler, task: *Task) SubmitError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stop) return error.ShuttingDown;
        std.debug.assert(task.state != .queued and task.state != .running);
        const urgent = task.priority == .critical or task.priority == .interactive;
        if (!urgent and self.queued >= self.max_queued) return error.QueueFull;
        task.cancel_flag.store(false, .monotonic);
        task.state = .queued;
        self.queues[@backingInt(task.priority)].push(task);
        self.queued += 1;
        self.refreshMask();
        if (self.idle > self.signals_pending) {
            self.signals_pending += 1;
            self.work_cond.signal(self.io);
        } else if (self.spawned < self.max_workers) {
            // Un worker in più solo se nessuno è libero: il lavoro occasionale
            // non crea mai più thread di quanti ne servano.
            const slot = std.mem.indexOfScalar(bool, &self.live, false).?;
            // Il nuovo worker parte bloccato sul mutex che teniamo noi: trova
            // `threads[slot]` già scritto quando gli servirà per il detach.
            if (std.Thread.spawn(.{}, workerMain, .{ self, slot })) |t| {
                self.threads[slot] = t;
                self.live[slot] = true;
                self.spawned += 1;
                self.total_spawned += 1;
            } else |_| {
                // Nessun thread nuovo: il task resta in coda per i worker
                // esistenti. Senza alcun worker non girerebbe mai: errore.
                if (self.spawned == 0) {
                    _ = self.queues[@backingInt(task.priority)].remove(task);
                    self.queued -= 1;
                    self.refreshMask();
                    task.state = .idle;
                    return error.QueueFull;
                }
            }
        }
    }

    /// Toglie dalla coda un task che non è ancora partito. True = non girerà
    /// mai e il chiamante ne riprende subito la proprietà. False = è già in
    /// esecuzione o finito: si chiede l'uscita anticipata e bisogna `wait`.
    pub fn cancel(self: *Scheduler, task: *Task) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (task.state == .queued) {
            const removed = self.queues[@backingInt(task.priority)].remove(task);
            std.debug.assert(removed);
            self.queued -= 1;
            self.refreshMask();
            task.state = .cancelled;
            self.tasks_cancelled += 1;
            return true;
        }
        task.cancel_flag.store(true, .monotonic);
        return task.state == .idle or task.state == .cancelled;
    }

    /// Aspetta che il task sia finito o cancellato. Non per i task con `on_done`.
    pub fn wait(self: *Scheduler, task: *Task) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (task.state == .queued or task.state == .running)
            self.done_cond.waitUncancelable(self.io, &self.mutex);
    }

    /// Con `mutex` acquisito, dopo ogni modifica delle code.
    fn refreshMask(self: *Scheduler) void {
        var m: u8 = 0;
        for (self.queues, 0..) |q, p| {
            if (q.head != null) m |= @as(u8, 1) << @intCast(p);
        }
        self.pending_mask.store(m, .monotonic);
    }

    /// C'è in coda lavoro più urgente di `p`? Senza lock (vedi `pending_mask`).
    pub fn hasPendingAbove(self: *const Scheduler, p: Priority) bool {
        const below: u8 = (@as(u8, 1) << @intCast(@backingInt(p))) - 1;
        return self.pending_mask.load(.monotonic) & below != 0;
    }

    pub fn stats(self: *Scheduler) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .live_workers = self.spawned,
            .threads_spawned = self.total_spawned,
            .threads_retired = self.retired,
            .tasks_run = self.tasks_run,
            .tasks_cancelled = self.tasks_cancelled,
            .max_workers = self.max_workers,
        };
    }

    /// Prossimo task da eseguire, con `mutex` acquisito.
    fn pick(self: *Scheduler) ?*Task {
        var top: ?usize = null;
        var bottom: ?usize = null;
        for (0..n_prio) |p| {
            if (self.queues[p].head == null) continue;
            if (top == null) top = p;
            bottom = p;
        }
        const hi = top orelse return null;
        const lo = bottom.?;
        var chosen = hi;
        if (lo != hi) {
            // C'è lavoro meno urgente che viene scavalcato.
            self.streak += 1;
            if (self.streak > self.fairness_window) {
                chosen = lo;
                self.streak = 0;
            }
        } else {
            self.streak = 0;
        }
        self.queued -= 1;
        const t = self.queues[chosen].pop();
        self.refreshMask();
        return t;
    }

    fn workerMain(self: *Scheduler, slot: usize) void {
        var retiring = false;
        self.mutex.lockUncancelable(self.io);
        while (true) {
            if (self.pick()) |t| {
                t.state = .running;
                self.mutex.unlock(self.io);
                // I `parallelFor` annidati (es. un GLB dentro una miniatura)
                // ereditano la priorità del task, non quella del worker.
                thread_priority = t.priority;
                t.run_fn(t);
                self.mutex.lockUncancelable(self.io);
                t.state = .done;
                self.tasks_run += 1;
                self.done_cond.broadcast(self.io);
                if (t.on_done) |f| {
                    // Fuori dal lock: `on_done` può liberare il task o
                    // sottometterne altri.
                    self.mutex.unlock(self.io);
                    f(t);
                    self.mutex.lockUncancelable(self.io);
                }
                continue;
            }
            if (self.stop) break;
            self.idle += 1;
            const timed_out = if (self.idle_timeout_ms == 0) blk: {
                self.work_cond.waitUncancelable(self.io, &self.mutex);
                break :blk false;
            } else blk: {
                const timeout: std.Io.Timeout = .{ .duration = .{
                    .raw = .fromMilliseconds(self.idle_timeout_ms),
                    .clock = .awake,
                } };
                self.work_cond.waitTimeout(self.io, &self.mutex, timeout) catch break :blk true;
                break :blk false;
            };
            self.idle -= 1;
            // Svegliato da un segnale o scaduto: in entrambi i casi un segnale
            // in volo è stato (o sarà) consumato da un waiter. Il conto può
            // sottostimare di uno, mai bloccare un task: il worker sveglio
            // prende comunque il primo task in coda.
            if (self.signals_pending > 0) self.signals_pending -= 1;
            // Ritiro per inattività: solo a coda vuota (un `submit` arrivato
            // nel frattempo ha incrementato `queued` e va servito) e mai
            // durante lo shutdown (lì deinit fa il join di tutti gli slot vivi).
            // Il thread si stacca da sé: nessuno lo gioinerà.
            if (timed_out and self.queued == 0 and !self.stop) {
                self.live[slot] = false;
                self.spawned -= 1;
                self.retired += 1;
                self.threads[slot].detach();
                _ = self.exiting.fetchAdd(1, .monotonic);
                retiring = true;
                break;
            }
        }
        self.mutex.unlock(self.io);
        // Ultimo accesso allo scheduler di un worker ritirato.
        if (retiring) _ = self.exiting.fetchSub(1, .release);
    }

    /// Esegue `body(ctx, i)` per ogni `i` in `0..n`, distribuendo gli indici fra
    /// il thread chiamante e i worker liberi. Ritorna quando TUTTI gli indici
    /// sono stati eseguiti e nessun worker tocca più `ctx`: `ctx` può stare
    /// sullo stack del chiamante. Senza worker disponibili gira tutto in linea.
    pub fn parallelFor(self: *Scheduler, n: usize, ctx: ?*anyopaque, body: Body, priority: Priority) void {
        var pf: ParallelFor = .{ .n = n, .ctx = ctx, .body = body, .sched = self, .priority = priority };
        if (n <= 1) return pf.drain();
        var helpers: [max_threads]Helper = undefined;
        const want = @min(n - 1, self.max_workers);
        var submitted: usize = 0;
        for (helpers[0..want]) |*h| {
            h.* = .{ .task = .{ .run_fn = Helper.run, .priority = priority }, .pf = &pf };
            self.submit(&h.task) catch break;
            submitted += 1;
        }
        pf.drain();
        // Gli helper non ancora partiti si tolgono dalla coda (non c'è più nulla
        // da fare per loro); quelli partiti si aspettano: finiscono l'indice in
        // corso e trovano il contatore esaurito.
        for (helpers[0..submitted]) |*h| {
            if (!self.cancel(&h.task)) self.wait(&h.task);
        }
    }
};

/// Corpo di un `parallelFor`. Convenzione C: lo stesso tipo attraversa il
/// confine dei plugin (`HostServices.parallel_for` in decoder.zig).
pub const Body = *const fn (ctx: ?*anyopaque, index: usize) callconv(.c) void;

const ParallelFor = struct {
    next: std.atomic.Value(usize) = .init(0),
    n: usize,
    ctx: ?*anyopaque,
    body: Body,
    sched: ?*const Scheduler = null,
    priority: Priority = .normal,

    /// Il chiamante: drena fino in fondo, non cede mai.
    fn drain(pf: *ParallelFor) void {
        while (pf.claim()) |i| pf.body(pf.ctx, i);
    }

    /// Un helper: tra un indice e l'altro cede il worker se in coda c'è lavoro
    /// più urgente. Senza questo un helper `background` partito per primo
    /// tiene il worker per TUTTA la fase parallela del suo decode e la
    /// priorità conta solo all'avvio (misurato: il decode in primo piano sotto
    /// carico peggiorava). Gli indici lasciati li finisce il chiamante, che non
    /// cede mai: la correttezza non dipende da questo.
    fn drainYielding(pf: *ParallelFor) void {
        while (true) {
            if (pf.sched) |s| if (s.hasPendingAbove(pf.priority)) return;
            const i = pf.claim() orelse return;
            pf.body(pf.ctx, i);
        }
    }

    fn claim(pf: *ParallelFor) ?usize {
        const i = pf.next.fetchAdd(1, .monotonic);
        return if (i < pf.n) i else null;
    }
};

const Helper = struct {
    task: Task,
    pf: *ParallelFor,

    fn run(t: *Task) void {
        const h: *Helper = @fieldParentPtr("task", t);
        h.pf.drainYielding();
    }
};

// ---------------------------------------------------------------------------
// Istanza globale e priorità per thread

var global_storage: Scheduler = undefined;
var global: ?*Scheduler = null;

/// Da chiamare una volta, all'avvio e prima di ogni thread. `ZUER_WORKERS=<n>`
/// sovrascrive `cfg.workers`.
pub fn initGlobal(io: std.Io, cfg: Config) void {
    std.debug.assert(global == null);
    var c = cfg;
    if (std.c.getenv("ZUER_WORKERS")) |v| {
        if (std.fmt.parseInt(usize, std.mem.span(v), 10)) |n| {
            if (n > 0) c.workers = n;
        } else |_| {}
    }
    global_storage = Scheduler.init(io, c);
    global = &global_storage;
}

/// Ferma lo scheduler globale (no-op se non inizializzato). Solo dopo il join
/// di tutti i thread che possono sottomettere lavoro.
pub fn deinitGlobal() void {
    const s = global orelse return;
    s.deinit();
    global = null;
}

pub fn get() ?*Scheduler {
    return global;
}

/// Priorità del lavoro che il thread corrente chiede allo scheduler: il loader
/// e il decode iniziale la mettono a `interactive`, il prefetch a `background`,
/// le miniature a `normal`. Serve ai `parallelFor` lanciati dentro i plugin,
/// che non sanno chi li ha chiamati.
threadlocal var thread_priority: Priority = .normal;

pub fn setThreadPriority(p: Priority) void {
    thread_priority = p;
}

pub fn threadPriority() Priority {
    return thread_priority;
}

/// Un task cooperativo di priorità `p` dovrebbe cedere il worker? (C'è in coda
/// lavoro più urgente.) Sempre false senza scheduler globale.
pub fn shouldYield(p: Priority) bool {
    const s = global orelse return false;
    return s.stopping.load(.monotonic) or s.hasPendingAbove(p);
}

/// `parallelFor` sullo scheduler globale con la priorità del thread corrente;
/// in linea se lo scheduler non è inizializzato (tool di sviluppo, test).
pub fn parallelForGlobal(n: usize, ctx: ?*anyopaque, body: Body) void {
    if (global) |s| return s.parallelFor(n, ctx, body, thread_priority);
    for (0..n) |i| body(ctx, i);
}

// ---------------------------------------------------------------------------
// Test

const testing = std.testing;

fn testIo() std.Io.Threaded {
    return .init(testing.allocator, .{});
}

const Counter = struct {
    hits: []std.atomic.Value(u32),
    fn body(ctx: ?*anyopaque, i: usize) callconv(.c) void {
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        _ = self.hits[i].fetchAdd(1, .monotonic);
    }
};

test "parallelFor esegue ogni indice esattamente una volta" {
    var th = testIo();
    defer th.deinit();
    var s = Scheduler.init(th.io(), .{ .workers = 3 });
    defer s.deinit();
    var hits: [1000]std.atomic.Value(u32) = @splat(.init(0));
    var c = Counter{ .hits = &hits };
    for (0..20) |_| s.parallelFor(hits.len, &c, Counter.body, .interactive);
    for (hits) |h| try testing.expectEqual(@as(u32, 20), h.load(.monotonic));
    // Worker riusati: mai più di quelli configurati, per quante chiamate si facciano.
    try testing.expect(s.stats().threads_spawned <= 3);
    try testing.expect(s.stats().live_workers <= 3);
}

test "parallelFor annidato non va in deadlock" {
    var th = testIo();
    defer th.deinit();
    var s = Scheduler.init(th.io(), .{ .workers = 2 });
    defer s.deinit();
    const Outer = struct {
        s: *Scheduler,
        hits: []std.atomic.Value(u32),
        fn body(ctx: ?*anyopaque, i: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            var c = Counter{ .hits = self.hits[i * 10 ..][0..10] };
            self.s.parallelFor(10, &c, Counter.body, .normal);
        }
    };
    var hits: [80]std.atomic.Value(u32) = @splat(.init(0));
    var o = Outer{ .s = &s, .hits = &hits };
    s.parallelFor(8, &o, Outer.body, .normal);
    for (hits) |h| try testing.expectEqual(@as(u32, 1), h.load(.monotonic));
}

/// Task che resta bloccato finché il test non lo sblocca: tiene occupato
/// l'unico worker per osservare l'ordine della coda.
const Gate = struct {
    task: Task = .{ .run_fn = run, .priority = .critical },
    open: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    fn run(t: *Task) void {
        const g: *Gate = @fieldParentPtr("task", t);
        g.started.store(true, .release);
        while (!g.open.load(.acquire)) std.Thread.yield() catch {};
    }
};

const Recorder = struct {
    task: Task,
    log: *Log,
    id: u8,
    const Log = struct {
        mutex: std.Io.Mutex = .init,
        io: std.Io,
        order: [64]u8 = undefined,
        len: usize = 0,
    };
    fn run(t: *Task) void {
        const r: *Recorder = @fieldParentPtr("task", t);
        r.log.mutex.lockUncancelable(r.log.io);
        defer r.log.mutex.unlock(r.log.io);
        r.log.order[r.log.len] = r.id;
        r.log.len += 1;
    }
};

fn startGate(s: *Scheduler, g: *Gate) !void {
    try s.submit(&g.task);
    while (!g.started.load(.acquire)) std.Thread.yield() catch {};
}

test "priorità: interattivo prima di background, FIFO a parità" {
    var th = testIo();
    defer th.deinit();
    const io = th.io();
    var s = Scheduler.init(io, .{ .workers = 1 });
    defer s.deinit();
    var gate = Gate{};
    try startGate(&s, &gate);

    var log = Recorder.Log{ .io = io };
    var recs: [4]Recorder = undefined;
    const prios = [_]Priority{ .background, .background, .interactive, .normal };
    for (&recs, prios, 0..) |*r, p, i| {
        r.* = .{ .task = .{ .run_fn = Recorder.run, .priority = p }, .log = &log, .id = @intCast(i) };
        try s.submit(&r.task);
    }
    gate.open.store(true, .release);
    for (&recs) |*r| s.wait(&r.task);
    try testing.expectEqualSlices(u8, &.{ 2, 3, 0, 1 }, log.order[0..log.len]);
}

test "fairness: il background non muore di fame" {
    var th = testIo();
    defer th.deinit();
    const io = th.io();
    var s = Scheduler.init(io, .{ .workers = 1, .fairness_window = 2 });
    defer s.deinit();
    var gate = Gate{};
    try startGate(&s, &gate);

    var log = Recorder.Log{ .io = io };
    var recs: [7]Recorder = undefined;
    // id 0 = background, id 1..6 = interattivi accodati dopo.
    for (&recs, 0..) |*r, i| {
        const p: Priority = if (i == 0) .background else .interactive;
        r.* = .{ .task = .{ .run_fn = Recorder.run, .priority = p }, .log = &log, .id = @intCast(i) };
        try s.submit(&r.task);
    }
    gate.open.store(true, .release);
    for (&recs) |*r| s.wait(&r.task);
    // Con finestra 2 il background passa dopo 2 interattivi, non per ultimo.
    try testing.expectEqualSlices(u8, &.{ 1, 2, 0, 3, 4, 5, 6 }, log.order[0..log.len]);
}

test "cancel: un task in coda non gira mai, uno in esecuzione si aspetta" {
    var th = testIo();
    defer th.deinit();
    const io = th.io();
    var s = Scheduler.init(io, .{ .workers = 1 });
    defer s.deinit();
    var gate = Gate{};
    try startGate(&s, &gate);

    var log = Recorder.Log{ .io = io };
    var r = Recorder{ .task = .{ .run_fn = Recorder.run }, .log = &log, .id = 9 };
    try s.submit(&r.task);
    try testing.expect(s.cancel(&r.task));
    try testing.expectEqual(State.cancelled, r.task.state);

    // Il gate è in esecuzione: cancel non può toglierlo, ne chiede l'uscita.
    try testing.expect(!s.cancel(&gate.task));
    try testing.expect(gate.task.cancelRequested());
    gate.open.store(true, .release);
    s.wait(&gate.task);
    try testing.expectEqual(@as(usize, 0), log.len);
    // Un task cancellato si può risottomettere.
    try s.submit(&r.task);
    s.wait(&r.task);
    try testing.expectEqual(@as(usize, 1), log.len);
}

test "backpressure: coda piena rifiuta normal/background, non interactive" {
    var th = testIo();
    defer th.deinit();
    const io = th.io();
    var s = Scheduler.init(io, .{ .workers = 1, .max_queued = 2 });
    defer s.deinit();
    var gate = Gate{};
    try startGate(&s, &gate);

    var log = Recorder.Log{ .io = io };
    var recs: [4]Recorder = undefined;
    for (&recs, 0..) |*r, i| r.* = .{ .task = .{ .run_fn = Recorder.run }, .log = &log, .id = @intCast(i) };
    try s.submit(&recs[0].task);
    try s.submit(&recs[1].task);
    try testing.expectError(error.QueueFull, s.submit(&recs[2].task));
    recs[3].task.priority = .interactive;
    try s.submit(&recs[3].task);
    gate.open.store(true, .release);
    for ([_]usize{ 0, 1, 3 }) |i| s.wait(&recs[i].task);
    try testing.expectEqual(@as(usize, 3), log.len);
}

const Owned = struct {
    task: Task,
    gpa: std.mem.Allocator,
    ran: *std.atomic.Value(u32),
    freed: *std.atomic.Value(u32),
    fn run(t: *Task) void {
        const o: *Owned = @fieldParentPtr("task", t);
        _ = o.ran.fetchAdd(1, .monotonic);
    }
    fn done(t: *Task) void {
        const o: *Owned = @fieldParentPtr("task", t);
        _ = o.freed.fetchAdd(1, .monotonic);
        o.gpa.destroy(o);
    }
};

test "shutdown con task in coda: cancellati e liberati, niente leak" {
    var th = testIo();
    defer th.deinit();
    const io = th.io();
    var s = Scheduler.init(io, .{ .workers = 1 });
    var gate = Gate{};
    try startGate(&s, &gate);

    var ran: std.atomic.Value(u32) = .init(0);
    var freed: std.atomic.Value(u32) = .init(0);
    for (0..10) |_| {
        const o = try testing.allocator.create(Owned);
        o.* = .{ .task = .{ .run_fn = Owned.run, .on_done = Owned.done, .priority = .background }, .gpa = testing.allocator, .ran = &ran, .freed = &freed };
        try s.submit(&o.task);
    }
    // Lo shutdown parte con il gate ancora in esecuzione: deinit deve
    // cancellare i 10 in coda e poi aspettare il gate.
    // Il gate si apre solo quando deinit ha già svuotato le code (stop
    // impostato sotto lock nello stesso passo): ordine deterministico.
    const Opener = struct {
        fn run(sch: *Scheduler, g: *Gate) void {
            while (true) {
                sch.mutex.lockUncancelable(sch.io);
                const stopped = sch.stop;
                sch.mutex.unlock(sch.io);
                if (stopped) break;
                std.Thread.yield() catch {};
            }
            g.open.store(true, .release);
        }
    };
    const opener = try std.Thread.spawn(.{}, Opener.run, .{ &s, &gate });
    s.deinit();
    opener.join();
    try testing.expectEqual(@as(u32, 10), freed.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), ran.load(.monotonic));
    try testing.expectError(error.ShuttingDown, s.submit(&gate.task));
}

test "un parallelFor background cede il worker a un task interattivo" {
    var th = testIo();
    defer th.deinit();
    const io = th.io();
    var s = Scheduler.init(io, .{ .workers = 1 });
    defer s.deinit();

    const Bg = struct {
        io: std.Io,
        s: *Scheduler,
        caller: std.Thread.Id = undefined,
        helper_started: std.atomic.Value(bool) = .init(false),
        executed: std.atomic.Value(usize) = .init(0),

        fn body(ctx: ?*anyopaque, _: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (std.Thread.getCurrentId() != self.caller) self.helper_started.store(true, .release);
            // ~1 ms di lavoro per indice.
            const t0 = std.Io.Clock.awake.now(self.io).nanoseconds;
            while (std.Io.Clock.awake.now(self.io).nanoseconds - t0 < std.time.ns_per_ms) {}
            _ = self.executed.fetchAdd(1, .monotonic);
        }

        fn run(self: *@This()) void {
            self.caller = std.Thread.getCurrentId();
            self.s.parallelFor(200, self, body, .background);
        }
    };
    var bg = Bg{ .io = io, .s = &s };
    const t = try std.Thread.spawn(.{}, Bg.run, .{&bg});
    defer t.join();
    // Aspetta che l'unico worker sia occupato da un helper background.
    while (!bg.helper_started.load(.acquire)) std.Thread.yield() catch {};

    const Probe = struct {
        task: Task = .{ .run_fn = run, .priority = .interactive },
        bg: *Bg,
        executed_then: usize = 0,
        fn run(tk: *Task) void {
            const p: *@This() = @fieldParentPtr("task", tk);
            p.executed_then = p.bg.executed.load(.monotonic);
        }
    };
    var probe = Probe{ .bg = &bg };
    try s.submit(&probe.task);
    s.wait(&probe.task);
    // Il task interattivo è girato a metà del parallelFor background: l'helper
    // ha ceduto il worker. Senza cessione partirebbe solo dopo l'ultimo indice
    // (executed == 200), perché l'helper terrebbe il worker fino alla fine.
    try testing.expect(probe.executed_then < 150);
}

test "i worker inattivi si ritirano e vengono ricreati al bisogno" {
    var th = testIo();
    defer th.deinit();
    const io = th.io();
    var s = Scheduler.init(io, .{ .workers = 2, .idle_timeout_ms = 30 });
    defer s.deinit();
    var hits: [64]std.atomic.Value(u32) = @splat(.init(0));
    var c = Counter{ .hits = &hits };
    s.parallelFor(hits.len, &c, Counter.body, .normal);
    const first = s.stats();
    try testing.expect(first.threads_spawned >= 1);
    // Attesa attiva del ritiro (timeout 30 ms), al più ~5 s.
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    while (s.stats().live_workers != 0) {
        if (std.Io.Clock.awake.now(io).nanoseconds - t0 > 5 * std.time.ns_per_s) return error.TestUnexpectedResult;
        std.Thread.yield() catch {};
    }
    try testing.expectEqual(first.threads_spawned, s.stats().threads_retired);
    // Nuovo lavoro dopo il ritiro: worker ricreati, risultato corretto.
    s.parallelFor(hits.len, &c, Counter.body, .normal);
    for (hits) |h| try testing.expectEqual(@as(u32, 2), h.load(.monotonic));
    try testing.expect(s.stats().threads_spawned > first.threads_spawned);
}

test "ritiro e submit in corsa: due chiamanti, timeout 1 ms" {
    var th = testIo();
    defer th.deinit();
    const io = th.io();
    var s = Scheduler.init(io, .{ .workers = 3, .idle_timeout_ms = 1 });
    defer s.deinit();
    const Caller = struct {
        fn run(sch: *Scheduler, sio: std.Io, hits: []std.atomic.Value(u32), seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            var c = Counter{ .hits = hits };
            for (0..150) |_| {
                sch.parallelFor(hits.len, &c, Counter.body, .normal);
                // Pause irregolari 0-3 ms: alcune lasciano scadere i worker.
                const ns = prng.random().uintLessThan(u64, 3 * std.time.ns_per_ms);
                const t0 = std.Io.Clock.awake.now(sio).nanoseconds;
                while (std.Io.Clock.awake.now(sio).nanoseconds - t0 < ns) std.Thread.yield() catch {};
            }
        }
    };
    var a: [32]std.atomic.Value(u32) = @splat(.init(0));
    var b: [32]std.atomic.Value(u32) = @splat(.init(0));
    const ta = try std.Thread.spawn(.{}, Caller.run, .{ &s, io, &a, 1 });
    const tb = try std.Thread.spawn(.{}, Caller.run, .{ &s, io, &b, 2 });
    ta.join();
    tb.join();
    for (a, b) |x, y| {
        try testing.expectEqual(@as(u32, 150), x.load(.monotonic));
        try testing.expectEqual(@as(u32, 150), y.load(.monotonic));
    }
    try testing.expect(s.stats().threads_retired > 0);
}

test "una raffica di submit fa crescere il pool anche con un worker inattivo" {
    var th = testIo();
    defer th.deinit();
    const io = th.io();
    var s = Scheduler.init(io, .{ .workers = 4, .idle_timeout_ms = 0 });
    defer s.deinit();
    // Un worker vivo e inattivo.
    var warm = Gate{};
    warm.open.store(true, .release);
    try s.submit(&warm.task);
    s.wait(&warm.task);
    while (true) {
        s.mutex.lockUncancelable(io);
        const idle = s.idle;
        s.mutex.unlock(io);
        if (idle == 1) break;
        std.Thread.yield() catch {};
    }
    // 4 task che restano in esecuzione finché non li apriamo: girano insieme
    // solo se il pool è cresciuto a 4 worker.
    var gates: [4]Gate = @splat(.{});
    for (&gates) |*g| try s.submit(&g.task);
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    var all_started = false;
    while (std.Io.Clock.awake.now(io).nanoseconds - t0 < 2 * std.time.ns_per_s) {
        all_started = true;
        for (&gates) |*g| all_started = all_started and g.started.load(.acquire);
        if (all_started) break;
        std.Thread.yield() catch {};
    }
    for (&gates) |*g| g.open.store(true, .release);
    for (&gates) |*g| s.wait(&g.task);
    try testing.expect(all_started);
}
