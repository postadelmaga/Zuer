//! Processi esterni: su Unix l'unico posto da cui Zuer ne lancia (su Windows restano
//! le `ShellExecuteW` di print.zig e crash_report.zig, che non sono processi figli).
//!
//! Tre forme, una per bisogno, tutte con una scadenza:
//!   - `runCapture…`: si cattura lo stdout (pdftoppm, bsdtar, yt-dlp, magick…), con
//!     un tetto sui byte e, a richiesta, un flag di annullamento. Il figlio ha stdin
//!     su /dev/null e un gruppo di processi suo: scadenza, annullamento e uscita
//!     dell'host (`killAll`) terminano il gruppo intero;
//!   - `runDetached`: il programma deve solo partire (`xdg-open`), e gli si lascia
//!     vivo ciò che ha lanciato;
//!   - `runFeed`: gli si scrive lo stdin e lo si lascia andare (`wl-copy`, `pbcopy`).
//! Si passa sempre un argv, mai una riga di comando da interpretare: i dati (nomi di
//! file, titoli, URL) sono argomenti a sé.
//!
//! Niente `std.Io`: `std.process.run` si blocca dentro i plugin dinamici (l'`io`
//! dell'host non attraversa il confine DynLib), e i plugin sono i primi clienti di
//! questo file — lo raggiungono come `decoder.runCapture` e simili, che decoder.zig
//! riesporta. L'implementazione è per sistema: `posix_spawn` + pipe su Unix,
//! `CreateProcessW` + pipe anonima su Windows.

const std = @import("std");
const builtin = @import("builtin");

pub const RunResult = struct {
    stdout: []u8,
    exit_code: u8,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
    }
};

/// Timeout di default per i tool esterni lanciati con `runCapture`.
pub const default_run_timeout_ms: u32 = 60_000;

/// Capacità iniziale del buffer di stdout di `runCapture`. Senza pre-allocazione
/// la cattura di un output grande (il PPM di `pdftoppm` sono decine di MB) parte
/// da zero e paga tutta la catena di realloc+memcpy della crescita geometrica.
/// 1 MB è irrilevante come picco e copre in un colpo solo l'output tipico;
/// `toOwnedSlice` restringe comunque all'esatto alla fine, quindi i tool che
/// stampano quattro byte (pdfinfo, ffprobe) non pagano nulla di permanente.
pub const default_capture_capacity: usize = 1024 * 1024;

/// Tetto sullo stdout catturato da `runCapture`: oltre, il processo viene terminato
/// e si ritorna `error.OutputTooLarge`. Senza, l'unico limite era il timeout: un
/// archivio con milioni di voci (bsdtar), appunti enormi (wl-paste) o un tool
/// impazzito potevano riempire la RAM in 60 secondi. Gli output leciti più grandi
/// sono i pixel grezzi di un'immagine (4096² × 3 = 50 MB).
pub const max_capture_bytes: usize = 512 * 1024 * 1024;

/// Esegue un comando catturandone lo stdout, senza dipendere da `std.Io`
/// (`std.process.run` si blocca dentro i plugin dinamici: l'`io` dell'host non
/// attraversa il confine DynLib). L'implementazione è per-OS: `posix_spawn` +
/// pipe su Unix, `CreateProcessW` + pipe anonima su Windows. Deadline
/// complessiva di `default_run_timeout_ms`: un tool appeso non può bloccare il
/// worker per sempre (vedi `runCaptureTimeout` per un valore esplicito).
pub fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    return capture(allocator, argv, default_run_timeout_ms, default_capture_capacity, null);
}

/// Come `runCapture`, con deadline complessiva esplicita: alla scadenza il
/// processo viene terminato (SIGKILL / TerminateProcess) e ritorna `error.Timeout`.
/// Su Unix il figlio ha un suo gruppo di processi e si termina il gruppo intero,
/// nipoti compresi; su Windows solo il processo lanciato.
pub fn runCaptureTimeout(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32) !RunResult {
    return capture(allocator, argv, timeout_ms, default_capture_capacity, null);
}

/// Come `runCaptureTimeout`, interrompibile: quando `cancel` diventa vero (lo
/// si controlla ogni ~50 ms) il processo viene terminato e ritorna
/// `error.Canceled`.
pub fn runCaptureCancel(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, cancel: *const std.atomic.Value(bool)) !RunResult {
    return capture(allocator, argv, timeout_ms, default_capture_capacity, cancel);
}

/// Come `runCaptureTimeout`, con un hint ESPLICITO di capacità iniziale per lo
/// stdout: chi conosce già l'ordine di grandezza dell'output (es. larghezza ×
/// altezza × 3 di un PPM) evita del tutto le riallocazioni intermedie.
pub fn runCaptureCapacity(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, capacity_hint: usize) !RunResult {
    return capture(allocator, argv, timeout_ms, capacity_hint, null);
}

/// Su Android non si lanciano processi: un telefono non ha gli strumenti che i decoder
/// cercano (magick, bsdtar, pdftoppm…), e `posix_spawn` esiste solo da Android 9 (API
/// 28). Referenziarlo bastava a impedire il caricamento della libreria dell'APK sulle
/// versioni precedenti, che pure dichiara di supportare (minSdk 24): il linker la lega
/// all'avvio (BIND_NOW). Qui il backend non viene nemmeno compilato, e il chiamante
/// riceve `error.CommandNotFound` come per uno strumento che non c'è.
pub const spawn_available = builtin.abi != .android;

fn capture(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, capacity_hint: usize, cancel: ?*const std.atomic.Value(bool)) !RunResult {
    // Stessi errori del backend vero per gli stessi casi: i chiamanti li smistano
    // con uno `switch` che deve compilare uguale su ogni piattaforma.
    if (comptime !spawn_available) return if (argv.len == 0) error.EmptyArgv else error.CommandNotFound;
    return sub.runCapture(allocator, argv, timeout_ms, capacity_hint, cancel);
}

/// Lancia un programma che deve solo PARTIRE (`xdg-open`): stdout e stderr su
/// /dev/null, e si aspetta la sua uscita per al più `wait_ms`. true se è uscito
/// con 0, o se alla scadenza sta ancora girando.
///
/// Non si usa `runCapture` perché cattura lo stdout con una pipe: se il programma
/// lancia a sua volta un processo che resta vivo (il browser, quando `xdg-open`
/// non ha un desktop a cui delegare), quello eredita la pipe e la fine del flusso
/// non arriva mai. Si aspettava il timeout intero e l'apertura riuscita veniva
/// presa per un fallimento. Solo POSIX: su Windows c'è ShellExecute.
pub fn runDetached(allocator: std.mem.Allocator, argv: []const []const u8, wait_ms: u32) bool {
    if (comptime builtin.os.tag == .windows or !spawn_available) return false;
    return sub.runDetached(allocator, argv, wait_ms) catch false;
}

/// Lancia un programma, gli scrive `input` sullo stdin, chiude e aspetta che esca,
/// tutto entro `deadline_ms`: alla scadenza il processo viene terminato. true se il
/// programma è partito e ha ricevuto tutto l'input.
///
/// Per gli strumenti che prendono il dato e vanno sullo sfondo (`wl-copy`): di norma
/// si staccano subito, ma su un compositor senza data-control possono restare in
/// attesa del focus. La scrittura è non bloccante: uno strumento che non legge
/// terrebbe altrimenti il chiamante fermo su una pipe piena, prima ancora di poterlo
/// aspettare. Solo POSIX: su Windows gli appunti sono una chiamata di sistema.
pub fn runFeed(allocator: std.mem.Allocator, argv: []const []const u8, input: []const u8, deadline_ms: u32) bool {
    if (comptime builtin.os.tag == .windows or !spawn_available) return false;
    return sub.runFeed(allocator, argv, input, deadline_ms) catch false;
}

// ── Gruppi vivi ─────────────────────────────────────────────────────────────
//
// I figli di `runCapture…` stanno in un gruppo (su Linux in una sessione) a sé: il
// Ctrl+C dal terminale e la chiusura della finestra del terminale non li raggiungono
// più. Chi li lancia tiene quindi nota dei gruppi vivi, e l'host li termina quando
// esce o riceve un segnale (`killAll`).
//
// Ogni plugin ha la propria copia di questo file: i suoi gruppi li annota nel
// registro dell'HOST, che gli arriva come coppia di funzioni (`setGroupRegistry`,
// chiamata dalla colla dei plugin con i `HostServices`).

const max_live_groups = 64;
var live_groups: [max_live_groups]std.atomic.Value(c_int) = @splat(.init(0));
var hook_register: ?*const fn (pgid: c_int) callconv(.c) void = null;
var hook_unregister: ?*const fn (pgid: c_int) callconv(.c) void = null;

/// Annota un gruppo vivo nel registro di questo binario. Registro pieno: il gruppo
/// resta fuori (e a un segnale sopravvive all'host), non è un errore.
pub fn registerGroup(pgid: c_int) callconv(.c) void {
    if (pgid <= 0) return;
    for (&live_groups) |*slot| {
        if (slot.cmpxchgStrong(0, pgid, .acq_rel, .acquire) == null) return;
    }
}

pub fn unregisterGroup(pgid: c_int) callconv(.c) void {
    if (pgid <= 0) return;
    for (&live_groups) |*slot| {
        if (slot.cmpxchgStrong(pgid, 0, .acq_rel, .acquire) == null) return;
    }
}

/// In un plugin: d'ora in poi i gruppi si annotano nel registro dell'host.
pub fn setGroupRegistry(register: *const fn (c_int) callconv(.c) void, unregister: *const fn (c_int) callconv(.c) void) void {
    hook_register = register;
    hook_unregister = unregister;
}

fn noteGroup(pgid: c_int) void {
    if (hook_register) |f| f(pgid) else registerGroup(pgid);
}

fn forgetGroup(pgid: c_int) void {
    if (hook_unregister) |f| f(pgid) else unregisterGroup(pgid);
}

/// Termina tutti i gruppi annotati (SIGKILL). Solo letture atomiche e `kill`: si può
/// chiamare da un gestore di segnali. Da chiamare nell'host quando sta per uscire.
pub fn killAll() void {
    if (comptime builtin.os.tag == .windows or !spawn_available) return;
    for (&live_groups) |*slot| {
        const pgid = slot.load(.acquire);
        if (pgid > 0) _ = sub.kill(-pgid, 9);
    }
}

/// Per-OS backend. Only the selected arm is analyzed, so the POSIX externs never reach
/// a Windows link and vice-versa.
const sub = switch (builtin.os.tag) {
    .windows => struct {
        const HANDLE = ?*anyopaque;
        const SECURITY_ATTRIBUTES = extern struct { nLength: u32, lpSecurityDescriptor: ?*anyopaque, bInheritHandle: i32 };
        const STARTUPINFOW = extern struct {
            cb: u32,
            lpReserved: ?[*:0]u16 = null,
            lpDesktop: ?[*:0]u16 = null,
            lpTitle: ?[*:0]u16 = null,
            dwX: u32 = 0,
            dwY: u32 = 0,
            dwXSize: u32 = 0,
            dwYSize: u32 = 0,
            dwXCountChars: u32 = 0,
            dwYCountChars: u32 = 0,
            dwFillAttribute: u32 = 0,
            dwFlags: u32 = 0,
            wShowWindow: u16 = 0,
            cbReserved2: u16 = 0,
            lpReserved2: ?*u8 = null,
            hStdInput: HANDLE = null,
            hStdOutput: HANDLE = null,
            hStdError: HANDLE = null,
        };
        const PROCESS_INFORMATION = extern struct { hProcess: HANDLE, hThread: HANDLE, dwProcessId: u32, dwThreadId: u32 };
        extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*const SECURITY_ATTRIBUTES, nSize: u32) callconv(.winapi) i32;
        extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: u32, dwFlags: u32) callconv(.winapi) i32;
        extern "kernel32" fn CreateProcessW(lpApplicationName: ?[*:0]const u16, lpCommandLine: ?[*:0]u16, lpProcessAttributes: ?*anyopaque, lpThreadAttributes: ?*anyopaque, bInheritHandles: i32, dwCreationFlags: u32, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *const STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) i32;
        extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
        extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
        extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *u32) callconv(.winapi) i32;
        extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?[*]u8, nBufferSize: u32, lpBytesRead: ?*u32, lpTotalBytesAvail: ?*u32, lpBytesLeftThisMessage: ?*u32) callconv(.winapi) i32;
        extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) i32;
        extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
        extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        const HANDLE_FLAG_INHERIT: u32 = 0x00000001;
        const STARTF_USESTDHANDLES: u32 = 0x00000100;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        const INVALID_HANDLE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
        const WAIT_OBJECT_0: u32 = 0;
        const WAIT_TIMEOUT: u32 = 0x00000102;

        fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, capacity_hint: usize, cancel: ?*const std.atomic.Value(bool)) !RunResult {
            if (argv.len == 0) return error.EmptyArgv;
            // Build a single, quoted command line (CreateProcess takes a string, not argv).
            // Quoting Win32 (regole di CommandLineToArgvW): le run di backslash che
            // precedono una virgoletta — o la `"` di chiusura dell'argomento — vanno
            // raddoppiate, poi la virgoletta letterale si escapa con un backslash;
            // altrimenti un argomento che termina con `\` fonderebbe i successivi.
            var cmd: std.ArrayList(u8) = .empty;
            defer cmd.deinit(allocator);
            for (argv, 0..) |a, i| {
                if (i != 0) try cmd.append(allocator, ' ');
                try cmd.append(allocator, '"');
                var bs: usize = 0;
                for (a) |ch| {
                    if (ch == '\\') {
                        bs += 1;
                        continue;
                    }
                    if (ch == '"') {
                        // 2n+1 backslash: i letterali raddoppiati + l'escape della virgoletta.
                        try cmd.appendNTimes(allocator, '\\', bs * 2 + 1);
                        try cmd.append(allocator, '"');
                    } else {
                        // Backslash non seguiti da virgoletta: letterali, nessun raddoppio.
                        try cmd.appendNTimes(allocator, '\\', bs);
                        try cmd.append(allocator, ch);
                    }
                    bs = 0;
                }
                // Backslash in coda: raddoppiati, o escaperebbero la `"` di chiusura.
                try cmd.appendNTimes(allocator, '\\', bs * 2);
                try cmd.append(allocator, '"');
            }
            const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd.items);
            defer allocator.free(cmd_w);

            const sa = SECURITY_ATTRIBUTES{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = 1 };
            var h_read: HANDLE = null;
            var h_write: HANDLE = null;
            if (CreatePipe(&h_read, &h_write, &sa, 0) == 0) return error.PipeFailed;
            defer _ = CloseHandle(h_read);
            _ = SetHandleInformation(h_read, HANDLE_FLAG_INHERIT, 0); // parent end not inherited

            // stderr NON sulla stessa pipe dello stdout parsato (un warning del
            // tool romperebbe il parse): con STARTF_USESTDHANDLES un handle null
            // equivale a "nessuno stderr" per il figlio.
            var si = STARTUPINFOW{ .cb = @sizeOf(STARTUPINFOW), .dwFlags = STARTF_USESTDHANDLES, .hStdOutput = h_write, .hStdError = null };
            var pi: PROCESS_INFORMATION = undefined;
            const ok = CreateProcessW(null, cmd_w, null, null, 1, CREATE_NO_WINDOW, null, null, &si, &pi);
            _ = CloseHandle(h_write); // parent keeps only the read end
            if (ok == 0) return error.CommandNotFound;
            defer _ = CloseHandle(pi.hProcess);
            defer _ = CloseHandle(pi.hThread);

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            // Capacità iniziale in UN colpo solo (vedi `default_capture_capacity`).
            if (capacity_hint > 0) try out.ensureTotalCapacityPrecise(allocator, capacity_hint);
            var buf: [65536]u8 = undefined;
            // Lettura con deadline complessiva: una ReadFile bloccante su un figlio
            // appeso non raggiungerebbe mai il wait, quindi si sonda la pipe con
            // PeekNamedPipe e si legge solo quando ci sono byte disponibili; alla
            // scadenza il figlio viene terminato e si ritorna errore.
            const deadline: u64 = GetTickCount64() + timeout_ms;
            while (true) {
                if (cancel) |c| if (c.load(.acquire)) {
                    _ = TerminateProcess(pi.hProcess, 1);
                    _ = WaitForSingleObject(pi.hProcess, 5000);
                    return error.Canceled;
                };
                if (out.items.len > max_capture_bytes) {
                    _ = TerminateProcess(pi.hProcess, 1);
                    _ = WaitForSingleObject(pi.hProcess, 5000);
                    return error.OutputTooLarge;
                }
                var avail: u32 = 0;
                if (PeekNamedPipe(h_read, null, 0, null, &avail, null) == 0) break; // pipe chiusa → EOF
                if (avail > 0) {
                    // Con capacità libera si legge DIRETTAMENTE in coda al buffer:
                    // niente rimbalzo su `buf` + memcpy.
                    const spare = out.capacity - out.items.len;
                    if (spare > 0) {
                        var got_direct: u32 = 0;
                        const want: u32 = @intCast(@min(@as(usize, avail), spare));
                        if (ReadFile(h_read, out.items.ptr + out.items.len, want, &got_direct, null) == 0 or got_direct == 0) break;
                        out.items.len += got_direct;
                        continue;
                    }
                    var got: u32 = 0;
                    if (ReadFile(h_read, &buf, @min(avail, buf.len), &got, null) == 0 or got == 0) break;
                    try out.appendSlice(allocator, buf[0..got]);
                    continue;
                }
                // Niente dati: figlio già uscito → fine; ancora vivo → si controlla
                // la deadline e si attende un attimo prima di risondare.
                if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) break;
                if (GetTickCount64() >= deadline) {
                    _ = TerminateProcess(pi.hProcess, 1);
                    _ = WaitForSingleObject(pi.hProcess, 5000);
                    return error.Timeout;
                }
                Sleep(10);
            }
            // Attesa finale col budget residuo: copre il figlio che ha chiuso lo
            // stdout ma non esce; su WAIT_TIMEOUT lo si termina e si ritorna errore.
            const now = GetTickCount64();
            const wait_ms: u32 = if (deadline > now) @intCast(@min(deadline - now, std.math.maxInt(u32))) else 0;
            if (WaitForSingleObject(pi.hProcess, wait_ms) == WAIT_TIMEOUT) {
                _ = TerminateProcess(pi.hProcess, 1);
                _ = WaitForSingleObject(pi.hProcess, 5000);
                return error.Timeout;
            }
            var code: u32 = 1;
            _ = GetExitCodeProcess(pi.hProcess, &code);
            return .{ .stdout = try out.toOwnedSlice(allocator), .exit_code = @truncate(code) };
        }
    },
    else => struct {
        extern "c" fn pipe(fds: *[2]c_int) c_int;
        extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
        // Variadica come in C: su macOS arm64 gli argomenti variabili passano dallo
        // stack, e dichiarata a tre argomenti fissi il terzo arriverebbe sbagliato.
        extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
        extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
        extern "c" fn close(fd: c_int) c_int;
        extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
        extern "c" fn kill(pid: c_int, sig: c_int) c_int;
        extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;
        extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
        // posix_spawn: fork+exec+ricerca PATH in modo sicuro anche in processi
        // multi-thread (niente malloc nel figlio forkato → niente deadlock).
        extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, file_actions: ?*const anyopaque, attrp: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
        extern "c" fn posix_spawn_file_actions_init(fa: *anyopaque) c_int;
        extern "c" fn posix_spawnattr_init(attr: *anyopaque) c_int;
        extern "c" fn posix_spawnattr_destroy(attr: *anyopaque) c_int;
        extern "c" fn posix_spawnattr_setflags(attr: *anyopaque, flags: c_short) c_int;
        extern "c" fn posix_spawnattr_setpgroup(attr: *anyopaque, pgroup: c_int) c_int;
        /// Uguale su glibc, musl, Bionic e Darwin.
        const POSIX_SPAWN_SETPGROUP: c_short = 0x02;
        // glibc ≥ 2.26 e musl. Non su Android (bionic l'ha solo da API 28) né su
        // macOS (valore diverso, non provato): lì resta il gruppo.
        const POSIX_SPAWN_SETSID: c_short = 0x80;
        const own_session = builtin.os.tag == .linux and builtin.abi != .android;
        extern "c" fn posix_spawn_file_actions_destroy(fa: *anyopaque) c_int;
        extern "c" fn posix_spawn_file_actions_adddup2(fa: *anyopaque, fd: c_int, newfd: c_int) c_int;
        extern "c" fn posix_spawn_file_actions_addclose(fa: *anyopaque, fd: c_int) c_int;
        extern "c" fn posix_spawn_file_actions_addopen(fa: *anyopaque, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
        extern "c" var environ: [*:null]const ?[*:0]const u8;

        const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
        const POLLIN: c_short = 0x001;
        const Timespec = extern struct { sec: c_long, nsec: c_long };
        const CLOCK_MONOTONIC: c_int = if (builtin.os.tag.isDarwin()) 6 else 1;

        /// Millisecondi di clock monotonico via libc (niente `std.Io`, che non
        /// attraversa il confine dei plugin dinamici). Per le deadline.
        fn nowMs() i64 {
            var ts: Timespec = .{ .sec = 0, .nsec = 0 };
            _ = clock_gettime(CLOCK_MONOTONIC, &ts);
            return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
        }

        /// pipe con O_CLOEXEC: senza, un figlio spawnato in parallelo da un ALTRO
        /// thread eredita il write-end e l'EOF sul read-end non arriva finché
        /// anche quello non esce (deadlock del loop di lettura). L'`adddup2` del
        /// figlio giusto azzera CLOEXEC sul fd duplicato, quindi basta questo.
        /// Su Linux `pipe2` è atomica; su Darwin (niente pipe2) fallback
        /// `pipe` + `fcntl(FD_CLOEXEC)`, best-effort.
        fn pipeCloexec(fds: *[2]c_int) c_int {
            if (builtin.os.tag == .linux) {
                return pipe2(fds, 0o2000000); // O_CLOEXEC (Linux)
            } else {
                if (pipe(fds) != 0) return -1;
                _ = fcntl(fds[0], 2, @as(c_int, 1)); // F_SETFD, FD_CLOEXEC
                _ = fcntl(fds[1], 2, @as(c_int, 1));
                return 0;
            }
        }

        fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, capacity_hint: usize, cancel: ?*const std.atomic.Value(bool)) !RunResult {
            if (argv.len == 0) return error.EmptyArgv;

            // argv null-terminato costruito PRIMA della fork: nel figlio non si può
            // allocare in sicurezza (multi-thread → solo funzioni async-signal-safe).
            const argvZ = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
            defer {
                for (argvZ[0..argv.len]) |a| if (a) |p| allocator.free(std.mem.span(p));
                allocator.free(argvZ);
            }
            @memset(argvZ[0..argv.len], null); // il defer libera solo ciò che è stato duplicato
            for (argv, 0..) |a, i| argvZ[i] = (try allocator.dupeSentinel(u8, a, 0)).ptr;

            var fds: [2]c_int = undefined;
            if (pipeCloexec(&fds) != 0) return error.PipeFailed;
            const read_fd = fds[0];
            const write_fd = fds[1];
            var read_fd_open = true;
            defer if (read_fd_open) {
                _ = close(read_fd);
            };

            var fa: [256]u8 align(16) = undefined;
            if (posix_spawn_file_actions_init(&fa) != 0) {
                _ = close(write_fd);
                return error.SpawnInit;
            }
            defer _ = posix_spawn_file_actions_destroy(&fa);
            _ = posix_spawn_file_actions_adddup2(&fa, write_fd, 1);
            // stderr del figlio su /dev/null: il terminale dell'host è in
            // raw-mode e i warning dei tool esterni lo sporcherebbero.
            _ = posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", 1, 0); // O_WRONLY
            _ = posix_spawn_file_actions_addclose(&fa, read_fd);
            // stdin su /dev/null: il figlio non deve leggere dal terminale dell'host
            // (nella TUI gli ruberebbe i tasti; da un gruppo in background verrebbe
            // fermato da SIGTTIN e si aspetterebbe tutta la scadenza).
            _ = posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", 0, 0); // O_RDONLY

            // Gruppo di processi proprio (pgid = pid del figlio), SEMPRE: scadenza,
            // annullamento e tetto sull'output terminano così anche i processi che
            // il figlio ha lanciato a sua volta (deno da yt-dlp, gs da magick).
            // Prima lo aveva solo chi passava `cancel`: alla scadenza moriva il
            // figlio e i nipoti restavano a girare.
            // Su Linux una SESSIONE propria (che è anche un gruppo): senza terminale
            // di controllo, uno strumento che apre /dev/tty per chiedere una password
            // fallisce subito invece di restare fermo fino alla scadenza.
            var attr: [512]u8 align(16) = undefined;
            const use_attr = posix_spawnattr_init(&attr) == 0;
            defer if (use_attr) {
                _ = posix_spawnattr_destroy(&attr);
            };
            if (use_attr) {
                if (comptime own_session) {
                    _ = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
                } else {
                    _ = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
                    _ = posix_spawnattr_setpgroup(&attr, 0);
                }
            }

            var pid: c_int = 0;
            const rc = posix_spawnp(&pid, argvZ[0].?, &fa, if (use_attr) @ptrCast(&attr) else null, argvZ.ptr, environ);
            _ = close(write_fd);
            if (rc != 0) return if (rc == 2) error.CommandNotFound else error.SpawnFailed; // 2 = ENOENT
            // Il gruppo è vivo: l'host deve poterlo terminare se esce prima di noi.
            // Lo si toglie dal registro PRIMA del waitpid: dopo, il pid può essere
            // riusato e `killAll` colpirebbe un gruppo altrui.
            if (use_attr) noteGroup(pid);

            // Da qui il figlio esiste: su OGNI percorso d'errore va reaped (niente
            // zombie). Si chiude prima il read-end e si manda SIGKILL, così il
            // waitpid non può bloccarsi su un figlio che sta ancora scrivendo.
            var reaped = false;
            errdefer if (!reaped) {
                if (read_fd_open) {
                    _ = close(read_fd);
                    read_fd_open = false;
                }
                _ = kill(if (use_attr) -pid else pid, 9); // SIGKILL (al gruppo, se proprio)
                if (use_attr) forgetGroup(pid);
                _ = waitpid(pid, null, 0);
            };

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            // Capacità iniziale in UN colpo solo (vedi `default_capture_capacity`).
            if (capacity_hint > 0) try out.ensureTotalCapacityPrecise(allocator, capacity_hint);
            var buf: [65536]u8 = undefined;
            // Loop di lettura con deadline complessiva via poll(): un tool esterno
            // appeso non può bloccare il worker per sempre — alla scadenza
            // l'errdefer sopra termina e reap-a il figlio.
            const deadline: i64 = nowMs() + timeout_ms;
            var pfd = [1]PollFd{.{ .fd = read_fd, .events = POLLIN, .revents = 0 }};
            while (true) {
                if (cancel) |c| if (c.load(.acquire)) return error.Canceled;
                // L'errdefer sopra termina e reap-a il figlio.
                if (out.items.len > max_capture_bytes) return error.OutputTooLarge;
                const remaining = deadline - nowMs();
                if (remaining <= 0) return error.Timeout;
                // Con un flag d'annullamento il poll dura al più 50 ms.
                const slice: i64 = if (cancel != null) @min(remaining, 50) else remaining;
                const pr = poll(&pfd, 1, @intCast(@min(slice, std.math.maxInt(c_int))));
                if (pr == 0) continue; // scaduto il tratto: si ricontrolla la deadline
                if (pr < 0) continue; // EINTR e simili: la deadline limita comunque il loop
                // Con capacità libera si legge DIRETTAMENTE in coda al buffer:
                // niente rimbalzo su `buf` + memcpy.
                const spare = out.capacity - out.items.len;
                if (spare > 0) {
                    const n = read(read_fd, out.items.ptr + out.items.len, spare);
                    if (n <= 0) break;
                    out.items.len += @intCast(n);
                    continue;
                }
                const n = read(read_fd, &buf, buf.len);
                if (n <= 0) break;
                try out.appendSlice(allocator, buf[0..@intCast(n)]);
            }

            if (use_attr) forgetGroup(pid);
            var status: c_int = 0;
            _ = waitpid(pid, &status, 0);
            reaped = true;
            // WIFEXITED / WEXITSTATUS espansi a mano (glibc): byte basso = segnale.
            const code: u8 = if ((status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else 1;
            return .{ .stdout = try out.toOwnedSlice(allocator), .exit_code = code };
        }

        const WNOHANG: c_int = 1;

        fn runDetached(allocator: std.mem.Allocator, argv: []const []const u8, wait_ms: u32) !bool {
            if (argv.len == 0) return error.EmptyArgv;
            const argvZ = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
            defer {
                for (argvZ[0..argv.len]) |a| if (a) |p| allocator.free(std.mem.span(p));
                allocator.free(argvZ);
            }
            @memset(argvZ[0..argv.len], null);
            for (argv, 0..) |a, i| argvZ[i] = (try allocator.dupeSentinel(u8, a, 0)).ptr;

            var fa: [256]u8 align(16) = undefined;
            if (posix_spawn_file_actions_init(&fa) != 0) return error.SpawnInit;
            defer _ = posix_spawn_file_actions_destroy(&fa);
            _ = posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", 1, 0); // O_WRONLY
            _ = posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", 1, 0);

            var pid: c_int = 0;
            const rc = posix_spawnp(&pid, argvZ[0].?, &fa, null, argvZ.ptr, environ);
            if (rc != 0) return if (rc == 2) error.CommandNotFound else error.SpawnFailed;

            const deadline: i64 = nowMs() + wait_ms;
            var none: [1]PollFd = undefined;
            while (true) {
                var status: c_int = 0;
                const w = waitpid(pid, &status, WNOHANG);
                if (w == pid) return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
                if (w < 0) return false;
                // Ancora vivo alla scadenza: sta tenendo in primo piano ciò che ha
                // lanciato. Lo si lascia girare (resterà uno zombie fino alla nostra
                // uscita, se finisce prima): ucciderlo chiuderebbe il browser.
                if (nowMs() >= deadline) return true;
                _ = poll(&none, 0, 20); // attesa di 20 ms senza `std.Io`
            }
        }

        extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
        const POLLOUT: c_short = 0x004;
        const O_NONBLOCK: c_int = if (builtin.os.tag.isDarwin()) 0x0004 else 0o4000;
        const F_GETFL: c_int = 3;
        const F_SETFL: c_int = 4;

        fn runFeed(allocator: std.mem.Allocator, argv: []const []const u8, input: []const u8, deadline_ms: u32) !bool {
            if (argv.len == 0) return false;
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
            for (argv, 0..) |a, i| argv_z[i] = (try arena.dupeSentinel(u8, a, 0)).ptr;

            // CLOEXEC: senza, un figlio lanciato in parallelo da un altro thread
            // erediterebbe l'estremo di scrittura e questo non vedrebbe mai la fine
            // del flusso. L'adddup2 azzera CLOEXEC sul solo fd duplicato.
            var fds: [2]c_int = undefined;
            if (pipeCloexec(&fds) != 0) return false;
            const rfd = fds[0];
            const wfd = fds[1];

            var fa: [256]u8 align(16) = undefined;
            if (posix_spawn_file_actions_init(&fa) != 0) {
                _ = close(rfd);
                _ = close(wfd);
                return false;
            }
            defer _ = posix_spawn_file_actions_destroy(&fa);
            _ = posix_spawn_file_actions_adddup2(&fa, rfd, 0); // stdin del figlio ← pipe
            _ = posix_spawn_file_actions_addclose(&fa, wfd);

            var pid: c_int = 0;
            const rc = posix_spawnp(&pid, argv_z[0].?, &fa, null, argv_z.ptr, environ);
            _ = close(rfd);
            if (rc != 0) {
                _ = close(wfd);
                return false;
            }

            const deadline = nowMs() + deadline_ms;
            _ = fcntl(wfd, F_SETFL, fcntl(wfd, F_GETFL, @as(c_int, 0)) | O_NONBLOCK);
            var off: usize = 0;
            while (off < input.len) {
                const n = write(wfd, input.ptr + off, input.len - off);
                if (n > 0) {
                    off += @intCast(n);
                    continue;
                }
                const left = deadline - nowMs();
                if (left <= 0) break;
                var pfd = [1]PollFd{.{ .fd = wfd, .events = POLLOUT, .revents = 0 }};
                // Pipe piena (EAGAIN) → si aspetta spazio; lettore sparito (EPIPE) →
                // poll segnala una condizione d'errore e si smette.
                if (poll(&pfd, 1, @intCast(@min(left, 200))) < 0) break;
                if (pfd[0].revents & ~POLLOUT != 0) break;
            }
            _ = close(wfd); // fine del flusso: lo strumento prende il dato e va sullo sfondo
            const fed = off == input.len;

            // Lo si raccoglie, ma non per sempre: oltre la scadenza viene terminato.
            var none: [1]PollFd = undefined;
            while (true) {
                const w = waitpid(pid, null, WNOHANG);
                if (w == pid or w < 0) return fed;
                if (nowMs() >= deadline) break;
                _ = poll(&none, 0, 10);
            }
            _ = kill(pid, 9);
            _ = waitpid(pid, null, 0);
            return fed;
        }
    },
};

test "runDetached: esito, attesa limitata, comando assente" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    try std.testing.expect(runDetached(a, &.{"true"}, 2000));
    try std.testing.expect(!runDetached(a, &.{"false"}, 2000));
    try std.testing.expect(!runDetached(a, &.{"zuer-comando-che-non-esiste"}, 2000));
    // Il caso di xdg-open senza desktop: il lanciatore esce subito ma lascia un
    // processo vivo che ha ereditato il suo stdout. Con una pipe si aspettava
    // quel processo; qui conta solo il lanciatore.
    const t0 = sub.nowMs();
    try std.testing.expect(runDetached(a, &.{ "sh", "-c", "sleep 3 & exit 0" }, 2000));
    try std.testing.expect(sub.nowMs() - t0 < 1500);
    // Lanciatore che resta in primo piano oltre l'attesa: riuscito, e non lo si aspetta.
    const t1 = sub.nowMs();
    try std.testing.expect(runDetached(a, &.{ "sleep", "2" }, 200));
    try std.testing.expect(sub.nowMs() - t1 < 1500);
}

test "runCapture: stdout, codice d'uscita, comando assente" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try runCapture(a, &.{ "sh", "-c", "printf ciao; exit 3" });
    defer r.deinit(a);
    try std.testing.expectEqualStrings("ciao", r.stdout);
    try std.testing.expectEqual(@as(u8, 3), r.exit_code);
    // Più del buffer iniziale: la cattura cresce senza perdere byte.
    var big = try runCaptureCapacity(a, &.{ "sh", "-c", "head -c 300000 /dev/zero" }, 10_000, 16);
    defer big.deinit(a);
    try std.testing.expectEqual(@as(usize, 300000), big.stdout.len);
    if (runCapture(a, &.{"zuer-comando-che-non-esiste"})) |*ok| {
        // posix_spawnp può riuscire e il figlio uscire con 127: in ogni caso non è un successo.
        var res = ok.*;
        defer res.deinit(a);
        try std.testing.expect(res.exit_code != 0);
    } else |_| {}
}

const test_c = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
};

/// Aspetta fino a 3 s che `pid` sia morto: sparito, oppure zombie (dopo un SIGKILL
/// resta tale finché chi l'ha adottato non lo raccoglie; in un container senza init
/// anche per sempre). Si legge /proc con la libc grezza: se il processo sparisce a
/// metà lettura è un esito atteso, non un errore da riportare.
fn goneSoon(pid: c_int) bool {
    var none: [1]sub.PollFd = undefined;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        if (sub.kill(pid, 0) != 0) return true;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch return false;
        const fd = test_c.open(path.ptr, @as(c_int, 0));
        if (fd < 0) return true;
        var stat_buf: [512]u8 = undefined;
        const n = test_c.read(fd, &stat_buf, stat_buf.len);
        _ = test_c.close(fd);
        if (n <= 0) return true;
        const st = stat_buf[0..@intCast(n)];
        // Lo stato è il primo campo dopo il nome fra parentesi: `pid (nome) Z …`.
        if (std.mem.lastIndexOfScalar(u8, st, ')')) |rp| {
            if (rp + 2 < st.len and st[rp + 2] == 'Z') return true;
        }
        _ = sub.poll(&none, 0, 10);
    }
    return false;
}

/// Lancia `sh` con un figlio in background che scrive il proprio PID in un file, e
/// ritorna quel PID quando il file c'è.
fn grandchildPid(a: std.mem.Allocator, pid_path: []const u8) !c_int {
    var none: [1]sub.PollFd = undefined;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        if (std.Io.Dir.cwd().readFileAlloc(std.testing.io, pid_path, a, .limited(64))) |txt| {
            defer a.free(txt);
            const t = std.mem.trim(u8, txt, " \n");
            if (t.len > 0) return try std.fmt.parseInt(c_int, t, 10);
        } else |_| {}
        _ = sub.poll(&none, 0, 10);
    }
    return error.NoPidFile;
}

test "runCapture: la scadenza ferma il processo e anche i suoi figli" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // legge /proc
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pid_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/nipote.pid", .{tmp.sub_path});
    defer a.free(pid_path);
    const script = try std.fmt.allocPrint(a, "sleep 30 & echo $! > '{s}'; sleep 30", .{pid_path});
    defer a.free(script);

    const t0 = sub.nowMs();
    try std.testing.expectError(error.Timeout, runCaptureTimeout(a, &.{ "sh", "-c", script }, 500));
    try std.testing.expect(sub.nowMs() - t0 < 3000);
    // Il nipote (lo `sleep` in background) non deve sopravvivere al figlio.
    const nipote = try grandchildPid(a, pid_path);
    try std.testing.expect(goneSoon(nipote));
}

test "killAll: l'host che esce termina i gruppi ancora vivi, nipoti compresi" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // legge /proc
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pid_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/nipote.pid", .{tmp.sub_path});
    defer a.free(pid_path);
    const script = try std.fmt.allocPrint(a, "sleep 30 & echo $! > '{s}'; sleep 30", .{pid_path});
    defer a.free(script);

    const Runner = struct {
        fn run(alloc: std.mem.Allocator, sh: []const u8, elapsed_ms: *i64) void {
            const t0 = sub.nowMs();
            // Scadenza lunga: a fermarlo dev'essere `killAll`, non il tempo.
            if (runCaptureTimeout(alloc, &.{ "sh", "-c", sh }, 20_000)) |*ok| {
                var res = ok.*;
                res.deinit(alloc);
            } else |_| {}
            elapsed_ms.* = sub.nowMs() - t0;
        }
    };
    var elapsed: i64 = 0;
    const t = try std.Thread.spawn(.{}, Runner.run, .{ a, script, &elapsed });
    const nipote = try grandchildPid(a, pid_path);
    killAll();
    t.join();
    try std.testing.expect(elapsed < 5000);
    try std.testing.expect(goneSoon(nipote));
    // A processo raccolto il registro è di nuovo vuoto.
    for (&live_groups) |*slot| try std.testing.expectEqual(@as(c_int, 0), slot.load(.acquire));
}

test "runCapture: lo stdin del figlio è /dev/null, non quello dell'host" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // `cat` senza argomenti copia lo stdin: con /dev/null esce subito, a vuoto.
    var r = try runCaptureTimeout(a, &.{"cat"}, 5000);
    defer r.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
}

test "runCapture: l'annullamento ferma il processo" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var cancel: std.atomic.Value(bool) = .init(true);
    const t1 = sub.nowMs();
    try std.testing.expectError(error.Canceled, runCaptureCancel(a, &.{ "sleep", "30" }, 20_000, &cancel));
    try std.testing.expect(sub.nowMs() - t1 < 3000);
}

test "runFeed: l'input arriva intero, chi non legge non blocca oltre la scadenza" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer a.free(out);
    const script = try std.fmt.allocPrint(a, "cat > '{s}'", .{out});
    defer a.free(script);

    // Più della capacità di una pipe (64 KiB): passa dal ramo «pipe piena».
    const input = try a.alloc(u8, 200_000);
    defer a.free(input);
    for (input, 0..) |*b, i| b.* = @truncate(i *% 7);
    try std.testing.expect(runFeed(a, &.{ "sh", "-c", script }, input, 5000));
    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out, a, .limited(1 << 20));
    defer a.free(got);
    try std.testing.expectEqualSlices(u8, input, got);

    // Uno strumento che non legge mai: si torna alla scadenza, con false.
    const t0 = sub.nowMs();
    try std.testing.expect(!runFeed(a, &.{ "sleep", "30" }, input, 300));
    try std.testing.expect(sub.nowMs() - t0 < 3000);
    // Comando assente.
    try std.testing.expect(!runFeed(a, &.{"zuer-comando-che-non-esiste"}, "x", 300));
}
