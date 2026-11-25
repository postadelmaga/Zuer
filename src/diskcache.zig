//! Le primitive comuni delle cache su disco di Zuer: dove sta la cartella, come si
//! legge e si scrive un file senza passare da `std.Io`, la scrittura atomica e la
//! manutenzione (tetto LRU, pulizia dei temporanei orfani).
//!
//! Le usano la cache delle mesh (meshcache.zig), delle texture decodificate
//! (decoders/texcache.zig), delle pagine PDF (decoders/pdf.zig) e delle tile
//! (vtcache.zig). Prima ognuna aveva la propria copia di open/write/rename, il
//! proprio modo di trovare la cartella e — per stare sia nell'host sia nei plugin —
//! due file gemelli per la manutenzione. Ora il file è uno: i plugin lo raggiungono
//! come `decoder.diskcache`, l'host lo importa direttamente. (Ogni plugin ne ha la
//! propria copia compilata, ma ogni cartella la scrive un binario solo.) La cache d'estrazione (extract_cache.zig) ha un `io` e usa `std.Io`: di
//! qui prende solo la cartella. Le miniature (thumbs.zig) scrivono con `std.Io` ma
//! prendono di qui cartella, `touch` e manutenzione.
//!
//! Niente `std.Io` perché chi scrive queste cache spesso non ne ha uno (il renderer,
//! un thread staccato che sopravvive all'app): un sottile backend per sistema su
//! chiamate grezze, POSIX e Win32. Tutto è best-effort: una cache è
//! un'ottimizzazione, e la sua manutenzione non deve mai far fallire un decode.
//!
//! Cartella: `$HOME/.cache/zuer/<sub>` su Unix, `%LOCALAPPDATA%\zuer\<sub>` su Windows.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const is_win = builtin.os.tag == .windows;

// ── Backend POSIX (libc grezza) ─────────────────────────────────────────────
// Variadica come in C: su macOS arm64 gli argomenti variabili passano dallo stack, e
// dichiarata a tre argomenti fissi il `mode` di O_CREAT arriverebbe sbagliato.
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, off: i64) isize;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
// I valori di Linux non sono quelli di Darwin (dove 0o100 è O_ASYNC e 0o1000 è
// O_CREAT: il file si creava, ma senza troncarlo).
const O_CREAT: c_int = if (builtin.os.tag.isDarwin()) 0x0200 else 0o100;
const O_TRUNC: c_int = if (builtin.os.tag.isDarwin()) 0x0400 else 0o1000;
const SEEK_END: c_int = 2;

// ── Backend Windows (kernel32 grezza) ───────────────────────────────────────
const win = if (is_win) struct {
    const HANDLE = *anyopaque;
    const INVALID: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_SHARE_READ: u32 = 0x1;
    const OPEN_EXISTING: u32 = 3;
    const CREATE_ALWAYS: u32 = 2;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    // Lettura/scrittura posizionale su handle sincrono: OVERLAPPED porta l'offset,
    // la chiamata completa in modo sincrono (nessun FILE_FLAG_OVERLAPPED).
    const OVERLAPPED = extern struct {
        Internal: usize = 0,
        InternalHigh: usize = 0,
        Offset: u32 = 0,
        OffsetHigh: u32 = 0,
        hEvent: ?*anyopaque = null,
    };
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sec: ?*anyopaque, disp: u32, flags: u32, tmpl: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: *u32, ov: ?*OVERLAPPED) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, wrote: *u32, ov: ?*OVERLAPPED) callconv(.winapi) i32;
    extern "kernel32" fn GetFileSizeEx(h: HANDLE, size: *i64) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, sec: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) i32;
} else struct {};

/// PID del processo corrente, per nomi tmp che non collidono tra istanze.
pub fn processId() u32 {
    if (is_win) return win.GetCurrentProcessId();
    return @intCast(getpid());
}

pub const Handle = if (is_win) win.HANDLE else c_int;

/// UTF-8 → UTF-16LE null-terminata in `out` (path corti: cache dir + nome file).
pub fn toW(path: []const u8, out: []u16) ?[*:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], path) catch return null;
    out[n] = 0;
    return @ptrCast(out.ptr);
}

/// Apre in lettura; null se assente. `path` deve essere null-terminato.
pub fn openRead(path: [:0]const u8) ?Handle {
    if (is_win) {
        var wbuf: [520]u16 = undefined;
        const w = toW(path, &wbuf) orelse return null;
        const h = win.CreateFileW(w, win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
        return if (h == win.INVALID) null else h;
    } else {
        const fd = open(path.ptr, O_RDONLY);
        return if (fd < 0) null else fd;
    }
}

/// Crea/tronca in scrittura; null in errore.
pub fn openWrite(path: [:0]const u8) ?Handle {
    if (is_win) {
        var wbuf: [520]u16 = undefined;
        const w = toW(path, &wbuf) orelse return null;
        const h = win.CreateFileW(w, win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
        return if (h == win.INVALID) null else h;
    } else {
        const fd = open(path.ptr, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
        return if (fd < 0) null else fd;
    }
}

pub fn closeH(h: Handle) void {
    if (is_win) _ = win.CloseHandle(h) else _ = close(h);
}

/// Rename per-OS che sostituisce la destinazione se esiste (atomico su POSIX).
/// false in errore.
pub fn renamePath(from: [:0]const u8, to: [:0]const u8) bool {
    if (is_win) {
        var wf: [520]u16 = undefined;
        var wt: [520]u16 = undefined;
        const f = toW(from, &wf) orelse return false;
        const t = toW(to, &wt) orelse return false;
        return win.MoveFileExW(f, t, win.MOVEFILE_REPLACE_EXISTING) != 0;
    } else {
        return rename(from.ptr, to.ptr) == 0;
    }
}

/// Cancella un file (best-effort: assente o non cancellabile, si ignora).
pub fn deletePath(path: [:0]const u8) void {
    if (is_win) {
        var wbuf: [520]u16 = undefined;
        const w = toW(path, &wbuf) orelse return;
        _ = win.DeleteFileW(w);
    } else {
        _ = unlink(path.ptr);
    }
}

/// Lettura posizionale: byte letti (0 in errore/EOF, senza toccare oltre).
pub fn preadPos(h: Handle, buf: []u8, off: u64) usize {
    if (is_win) {
        var ov = win.OVERLAPPED{ .Offset = @truncate(off), .OffsetHigh = @truncate(off >> 32) };
        var got: u32 = 0;
        if (win.ReadFile(h, buf.ptr, @intCast(buf.len), &got, &ov) == 0) return 0;
        return got;
    } else {
        const n = pread(h, buf.ptr, buf.len, @intCast(off));
        return if (n > 0) @intCast(n) else 0;
    }
}

pub fn writeAll(h: Handle, buf: []const u8) !void {
    var i: usize = 0;
    while (i < buf.len) {
        if (is_win) {
            var wrote: u32 = 0;
            const chunk: u32 = @intCast(@min(buf.len - i, @as(usize, 1) << 30));
            if (win.WriteFile(h, buf.ptr + i, chunk, &wrote, null) == 0 or wrote == 0) return error.WriteFailed;
            i += wrote;
        } else {
            const n = write(h, buf.ptr + i, buf.len - i);
            if (n <= 0) return error.WriteFailed;
            i += @intCast(n);
        }
    }
}

/// Dimensione del file, -1 in errore.
pub fn fileSize(h: Handle) i64 {
    if (is_win) {
        var s: i64 = 0;
        return if (win.GetFileSizeEx(h, &s) == 0) -1 else s;
    } else {
        return lseek(h, 0, SEEK_END);
    }
}

/// Crea la directory `prefix` (già esistente → ignorato). `prefix` non-sentinel.
fn mkdirOne(prefix: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (prefix.len == 0 or prefix.len >= buf.len) return;
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = 0;
    if (is_win) {
        var wbuf: [520]u16 = undefined;
        const w = toW(buf[0..prefix.len], &wbuf) orelse return;
        _ = win.CreateDirectoryW(w, null);
    } else {
        _ = mkdir(@ptrCast(&buf), 0o755);
    }
}

/// Crea la catena di directory di `dir` (best-effort, come `mkdir -p`).
pub fn makeDirs(dir: []const u8) void {
    for (dir, 0..) |c, i| {
        if ((c == '/' or c == '\\') and i > 0) mkdirOne(dir[0..i]);
    }
    mkdirOne(dir);
}

/// Valore di una variabile d'ambiente, duplicato (chiamante libera). null se assente.
pub fn getEnvAlloc(gpa: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
    if (is_win) {
        var wname: [64]u16 = undefined;
        const wn = toW(name, &wname) orelse return null;
        var wval: [1024]u16 = undefined;
        const n = win.GetEnvironmentVariableW(wn, &wval, wval.len);
        if (n == 0 or n >= wval.len) return null;
        return std.unicode.utf16LeToUtf8Alloc(gpa, wval[0..n]) catch null;
    } else {
        const v = getenv(name.ptr) orelse return null;
        return gpa.dupe(u8, std.mem.span(v)) catch null;
    }
}

/// Directory cache per-OS (`…/zuer/<sub>`), creando la catena di directory.
/// `%LOCALAPPDATA%\zuer\<sub>` su Windows, `$HOME/.cache/zuer/<sub>` altrove.
/// null se la variabile d'ambiente di base non è definita (o OOM).
pub fn cacheDir(gpa: std.mem.Allocator, sub: []const u8) ?[]u8 {
    const base = getEnvAlloc(gpa, if (is_win) "LOCALAPPDATA" else "HOME") orelse return null;
    defer gpa.free(base);
    const root = if (is_win) "zuer" else ".cache/zuer";
    const out = std.fmt.allocPrint(gpa, "{s}{c}{s}{c}{s}", .{
        base, std.fs.path.sep, root, std.fs.path.sep, sub,
    }) catch return null;
    // Si creano solo i componenti SOTTO la base: una HOME che non esiste non la si
    // inventa (e la cache resta spenta, perché l'apertura dei file fallirà).
    var i: usize = base.len + 1;
    while (i < out.len) : (i += 1) {
        if (out[i] == '/' or out[i] == '\\') mkdirOne(out[0..i]);
    }
    mkdirOne(out);
    return out;
}

/// Legge esattamente `buf.len` byte a partire da `off`. false su errore o file più
/// corto. Posizionale: non dipende da dove si trova il cursore del file (e
/// `fileSize` su POSIX lo sposta in fondo).
pub fn readExact(h: Handle, buf: []u8, off: u64) bool {
    var done: usize = 0;
    while (done < buf.len) {
        const chunk = @min(buf.len - done, @as(usize, 1) << 30);
        const n = preadPos(h, buf[done..][0..chunk], off + done);
        if (n == 0) return false;
        done += n;
    }
    return true;
}

/// Scrittura atomica di un file di cache: si scrive su un temporaneo dal nome unico
/// (PID e sequenza: due istanze non condividono mai lo stesso) e solo a scrittura
/// completa lo si rinomina sul nome finale. Un crash a metà non lascia mai un file
/// parziale che la lettura successiva scambierebbe per valido; e se la scrittura o
/// il rename falliscono (disco pieno) il temporaneo si toglie subito — lo sweep lo
/// vedrebbe solo fra un'ora, e il tetto LRU i temporanei non li conta.
///
///     var w = diskcache.AtomicWriter.begin(gpa, path) orelse return;
///     w.write(header);
///     w.write(body);
///     if (!w.commit()) return;
pub const AtomicWriter = struct {
    gpa: std.mem.Allocator,
    h: Handle,
    tmp: [:0]u8,
    path: [:0]const u8,
    ok: bool = true,

    var seq: std.atomic.Value(u64) = .init(0);

    /// null se il temporaneo non si può creare. `path` deve restare valido fino a
    /// `commit`.
    pub fn begin(gpa: std.mem.Allocator, path: [:0]const u8) ?AtomicWriter {
        const n = seq.fetchAdd(1, .monotonic);
        const tmp = std.fmt.allocPrintSentinel(gpa, "{s}.tmp{d}_{d}", .{ path, processId(), n }, 0) catch return null;
        const h = openWrite(tmp) orelse {
            gpa.free(tmp);
            return null;
        };
        return .{ .gpa = gpa, .h = h, .tmp = tmp, .path = path };
    }

    /// Accoda `bytes`. Un errore si ricorda e fa fallire `commit`: non serve
    /// controllare ogni chiamata.
    pub fn write(self: *AtomicWriter, bytes: []const u8) void {
        if (!self.ok) return;
        writeAll(self.h, bytes) catch {
            self.ok = false;
        };
    }

    /// Chiude e rinomina. true se il file finale è al suo posto; altrimenti il
    /// temporaneo è già stato tolto. In ogni caso il writer non si usa più.
    pub fn commit(self: *AtomicWriter) bool {
        closeH(self.h); // prima di rinominare o cancellare: su Windows un file aperto non si tocca
        defer self.gpa.free(self.tmp);
        if (self.ok and renamePath(self.tmp, self.path)) return true;
        deletePath(self.tmp);
        return false;
    }
};

/// Dopo una scrittura riuscita in `dir_path`: una volta per processo toglie i
/// temporanei orfani, poi riporta la cartella sotto `cap_bytes` buttando i file
/// usati meno di recente. `swept` vive nel modulo chiamante (uno per cartella).
pub fn maintain(swept: *std.atomic.Value(bool), dir_path: []const u8, cap_bytes: u64) void {
    sweepTmpOnce(swept, dir_path);
    evictLru(dir_path, cap_bytes);
}

// ── Manutenzione ────────────────────────────────────────────────────────────
//
// LRU per mtime, non atime (relatime/noatime lo rendono inaffidabile): chi legge una
// entry con successo chiama `touch` per portarla in cima. Non ricorsiva: si toccano
// solo i file diretti della directory, e mai i `.tmp*` (scritture forse in corso).

/// La manutenzione (touch, sweep, tetto) usa syscall grezze di Linux; altrove è no-op.
const maintained = builtin.os.tag == .linux;

/// Età minima di un `*.tmp*` orfano prima che lo sweep lo rimuova: più
/// giovane potrebbe essere una scrittura ANCORA in corso di un altro processo.
const tmp_max_age_ns: i128 = std.time.ns_per_hour;

/// "Touch" LRU: aggiorna atime+mtime del file aperto a "adesso" (futimens con
/// times null). Da chiamare al cache-hit, best-effort.
pub fn touch(h: Handle) void {
    if (maintained) _ = linux.futimens(h, null);
}

/// Sweep una-tantum per processo dei `*.tmp*` orfani in `dir_path` (writer
/// detached morto a metà scrittura): rimuove quelli con mtime più vecchio di
/// un'ora. `flag` vive nel modulo chiamante (una dir per flag). Best-effort.
pub fn sweepTmpOnce(flag: *std.atomic.Value(bool), dir_path: []const u8) void {
    if (maintained) {
        if (flag.swap(true, .monotonic)) return; // già fatto in questo processo
        sweepTmpLinux(dir_path);
    }
}

/// Eviction LRU per mtime: se la somma delle dimensioni dei file regolari in
/// `dir_path` (esclusi i `.tmp*`) supera `cap_bytes`, cancella i più vecchi
/// finché si rientra nel cap. Da chiamare dopo ogni scrittura riuscita.
/// Best-effort, non ricorsiva.
pub fn evictLru(dir_path: []const u8, cap_bytes: u64) void {
    if (maintained) evictLruLinux(dir_path, cap_bytes);
}

// ── Implementazione Linux ───────────────────────────────────────────────────

const FileInfo = struct {
    name: [:0]const u8,
    mtime_ns: i128,
    size: u64,
};

fn mtimeLess(_: void, a: FileInfo, b: FileInfo) bool {
    return a.mtime_ns < b.mtime_ns;
}

/// Apre `dir_path` come directory fd (O_DIRECTORY). null in errore.
fn openDirFd(dir_path: []const u8) ?linux.fd_t {
    var buf: [1024]u8 = undefined;
    if (dir_path.len == 0 or dir_path.len >= buf.len) return null;
    @memcpy(buf[0..dir_path.len], dir_path);
    buf[dir_path.len] = 0;
    const rc = linux.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// Elenca i file regolari diretti di `dirfd` con mtime e dimensione (statx).
/// `want_tmp` seleziona i `*.tmp*` (per lo sweep) o li esclude (per l'eviction).
/// I nomi sono duplicati in `arena`.
fn listFiles(arena: std.mem.Allocator, dirfd: linux.fd_t, files: *std.ArrayList(FileInfo), want_tmp: bool) !void {
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const rc = linux.getdents64(dirfd, &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS) return error.ReadDirFailed;
        if (rc == 0) break;
        var off: usize = 0;
        while (off < rc) {
            // Come nella std: nessuna assunzione di allineamento sul record.
            const ent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            if (ent.reclen == 0) return error.ReadDirFailed; // paranoia: mai loop infinito
            const name_ptr: [*:0]const u8 = @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_ptr);
            off += ent.reclen;
            if (ent.type != linux.DT.REG and ent.type != linux.DT.UNKNOWN) continue;
            if ((std.mem.indexOf(u8, name, ".tmp") != null) != want_tmp) continue;
            var stx: linux.Statx = undefined;
            const src = linux.statx(dirfd, name_ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &stx);
            if (linux.errno(src) != .SUCCESS) continue; // sparito nel frattempo: pazienza
            if (!stx.mask.TYPE or !stx.mask.SIZE or !stx.mask.MTIME) continue;
            if (stx.mode & linux.S.IFMT != linux.S.IFREG) continue; // copre anche DT.UNKNOWN
            try files.append(arena, .{
                .name = try arena.dupeSentinel(u8, name, 0),
                .mtime_ns = @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec,
                .size = stx.size,
            });
        }
    }
}

fn sweepTmpLinux(dir_path: []const u8) void {
    const dirfd = openDirFd(dir_path) orelse return;
    defer _ = linux.close(dirfd);
    // page_allocator: come le scritture cache, può girare su thread detached
    // che sopravvivono al gpa dell'app.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var files: std.ArrayList(FileInfo) = .empty;
    listFiles(arena_state.allocator(), dirfd, &files, true) catch return;

    var now: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &now)) != .SUCCESS) return;
    const now_ns = @as(i128, now.sec) * std.time.ns_per_s + now.nsec;
    for (files.items) |f| {
        if (now_ns - f.mtime_ns > tmp_max_age_ns)
            _ = linux.unlinkat(dirfd, f.name.ptr, 0);
    }
}

fn evictLruLinux(dir_path: []const u8, cap_bytes: u64) void {
    const dirfd = openDirFd(dir_path) orelse return;
    defer _ = linux.close(dirfd);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var files: std.ArrayList(FileInfo) = .empty;
    listFiles(arena_state.allocator(), dirfd, &files, false) catch return;

    var total: u64 = 0;
    for (files.items) |f| total +|= f.size;
    if (total <= cap_bytes) return;

    // Più vecchi (mtime) per primi; il touch al cache-hit li tiene in coda.
    // Il file più recente (tipicamente quello appena scritto) non si tocca MAI:
    // una entry singola sopra il cap verrebbe altrimenti cancellata subito e
    // riscritta ad ogni apertura (churn) senza mai servire da cache.
    std.mem.sort(FileInfo, files.items, {}, mtimeLess);
    for (files.items[0 .. files.items.len - 1]) |f| {
        if (total <= cap_bytes) break;
        // Se l'unlink fallisce non si scala il totale: si prova col successivo.
        if (linux.errno(linux.unlinkat(dirfd, f.name.ptr, 0)) != .SUCCESS) continue;
        total -|= f.size;
    }
}

test "AtomicWriter: il file compare intero, il temporaneo sparisce" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/voce.bin", .{base}, 0);
    defer gpa.free(path);

    var w = AtomicWriter.begin(gpa, path).?;
    w.write("ciao ");
    // A scrittura in corso il nome finale non esiste ancora.
    try std.testing.expect(openRead(path) == null);
    w.write("mondo");
    try std.testing.expect(w.commit());

    const h = openRead(path).?;
    defer closeH(h);
    try std.testing.expectEqual(@as(i64, 10), fileSize(h));
    var buf: [10]u8 = undefined;
    // `fileSize` ha lasciato il cursore in fondo: la lettura è posizionale.
    try std.testing.expect(readExact(h, &buf, 0));
    try std.testing.expectEqualStrings("ciao mondo", &buf);
    try std.testing.expect(readExact(h, buf[0..5], 5));
    try std.testing.expectEqualStrings("mondo", buf[0..5]);
    // Oltre la fine: false, non una lettura corta spacciata per buona.
    try std.testing.expect(!readExact(h, &buf, 1));

    try std.testing.expectEqual(@as(usize, 1), try countEntries(base));
}

test "AtomicWriter: se il rename fallisce il temporaneo non resta" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    // La destinazione è una cartella non vuota: il rename di un file sopra fallisce.
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/occupato", .{base}, 0);
    defer gpa.free(path);
    const inner = try std.fmt.allocPrint(gpa, "{s}/dentro", .{path});
    defer gpa.free(inner);
    makeDirs(inner);

    var w = AtomicWriter.begin(gpa, path).?;
    w.write("dati");
    try std.testing.expect(!w.commit());
    // Resta solo la cartella `occupato`: nessun `.tmp…` orfano.
    try std.testing.expectEqual(@as(usize, 1), try countEntries(base));
}

fn countEntries(dir_path: []const u8) !usize {
    const io = std.testing.io;
    var d = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

/// Crea `name` in `base` con `size` byte e mtime `age_s` secondi fa.
fn putAged(gpa: std.mem.Allocator, base: []const u8, name: []const u8, size: usize, age_s: i64) !void {
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ base, name }, 0);
    defer gpa.free(path);
    const h = openWrite(path) orelse return error.CreateFailed;
    defer closeH(h);
    const fill = try gpa.alloc(u8, size);
    defer gpa.free(fill);
    @memset(fill, 'x');
    try writeAll(h, fill);
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now);
    const t: linux.timespec = .{ .sec = now.sec - age_s, .nsec = 0 };
    const times = [2]linux.timespec{ t, t };
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.futimens(h, &times)));
}

fn exists(gpa: std.mem.Allocator, base: []const u8, name: []const u8) !bool {
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ base, name }, 0);
    defer gpa.free(path);
    const h = openRead(path) orelse return false;
    closeH(h);
    return true;
}

test "tetto LRU: via i più vecchi, mai il più recente, mai i temporanei" {
    if (!maintained) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);

    try putAged(gpa, base, "vecchio", 1000, 300);
    try putAged(gpa, base, "medio", 1000, 200);
    try putAged(gpa, base, "nuovo", 1000, 100);
    try putAged(gpa, base, "x.tmp1_0", 5000, 400); // scrittura forse in corso: non conta e non si tocca

    // Sotto il tetto: non succede nulla.
    evictLru(base, 3000);
    try std.testing.expect(try exists(gpa, base, "vecchio"));

    // 3000 byte contro un tetto di 2500: basta togliere il più vecchio.
    evictLru(base, 2500);
    try std.testing.expect(!try exists(gpa, base, "vecchio"));
    try std.testing.expect(try exists(gpa, base, "medio"));
    try std.testing.expect(try exists(gpa, base, "nuovo"));
    try std.testing.expect(try exists(gpa, base, "x.tmp1_0"));

    // Un hit porta `medio` in cima: ora il più vecchio è `nuovo`.
    {
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/medio", .{base}, 0);
        defer gpa.free(path);
        const h = openRead(path).?;
        defer closeH(h);
        touch(h);
    }
    evictLru(base, 1500);
    try std.testing.expect(try exists(gpa, base, "medio"));
    try std.testing.expect(!try exists(gpa, base, "nuovo"));

    // Tetto sotto la taglia di un solo file: il più recente resta comunque.
    evictLru(base, 10);
    try std.testing.expect(try exists(gpa, base, "medio"));
}

test "sweep dei temporanei: solo gli orfani oltre un'ora, una volta per processo" {
    if (!maintained) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);

    try putAged(gpa, base, "a.bin.tmp7_0", 10, 2 * 3600); // orfano
    try putAged(gpa, base, "b.bin.tmp7_1", 10, 60); // forse in corso
    try putAged(gpa, base, "c.bin", 10, 2 * 3600); // voce vera, vecchia

    var swept: std.atomic.Value(bool) = .init(false);
    sweepTmpOnce(&swept, base);
    try std.testing.expect(!try exists(gpa, base, "a.bin.tmp7_0"));
    try std.testing.expect(try exists(gpa, base, "b.bin.tmp7_1"));
    try std.testing.expect(try exists(gpa, base, "c.bin"));

    // Seconda chiamata: il flag è già alzato, la cartella non si riguarda.
    try putAged(gpa, base, "d.bin.tmp7_2", 10, 2 * 3600);
    sweepTmpOnce(&swept, base);
    try std.testing.expect(try exists(gpa, base, "d.bin.tmp7_2"));
}
