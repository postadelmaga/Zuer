//! Manutenzione best-effort delle directory di cache su disco
//! (~/.cache/zuer/{mesh,vt,tex}): eviction LRU con cap per directory, sweep
//! dei file temporanei orfani e "touch" dell'mtime al cache-hit.
//!
//! COPIA GEMELLA di src/cache_evict.zig — tenerle in sync! Questa copia serve
//! il lato plugin (texcache.zig, usato da glb.so il cui module path è
//! src/decoders/); quella in src/ serve l'host (meshcache.zig, vtcache.zig).
//! Un file unico NON è possibile: nella compilazione del plugin glb sarebbe
//! raggiunto sia dal modulo root del plugin (via texcache) sia dal modulo
//! `decoder` (via decoder.zig → meshcache) → errore "file exists in multiple
//! modules". Il re-export da decoder.zig risolverebbe, ma qui si è scelto di
//! non toccare decoder.zig.
//!
//! LRU per mtime, non atime (relatime/noatime lo rendono inaffidabile): chi
//! legge una entry con successo chiama `touchFd` per portarla in cima. Solo
//! Linux (syscall grezze via std.os.linux, coerente coi moduli cache che non
//! propagano std.Io): sugli altri OS le funzioni sono no-op. Tutti gli errori
//! sono ignorati — la cache è un'ottimizzazione, la sua manutenzione non deve
//! mai far fallire un decode. Non ricorsivo: si toccano solo i file diretti
//! della directory, e mai i `.tmp*` (scritture potenzialmente in corso).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const enabled = builtin.os.tag == .linux;

/// Età minima di un `*.tmp*` orfano prima che lo sweep lo rimuova: più
/// giovane potrebbe essere una scrittura ANCORA in corso di un altro processo.
const tmp_max_age_ns: i128 = std.time.ns_per_hour;

/// "Touch" LRU: aggiorna atime+mtime del file aperto a "adesso" (futimens con
/// times null). Da chiamare al cache-hit, best-effort.
pub fn touchFd(fd: i32) void {
    if (enabled) _ = linux.futimens(fd, null);
}

/// Sweep una-tantum per processo dei `*.tmp*` orfani in `dir_path` (writer
/// detached morto a metà scrittura): rimuove quelli con mtime più vecchio di
/// un'ora. `flag` vive nel modulo chiamante (una dir per flag). Best-effort.
pub fn sweepTmpOnce(flag: *std.atomic.Value(bool), dir_path: []const u8) void {
    if (enabled) {
        if (flag.swap(true, .monotonic)) return; // già fatto in questo processo
        sweepTmpLinux(dir_path);
    }
}

/// Eviction LRU per mtime: se la somma delle dimensioni dei file regolari in
/// `dir_path` (esclusi i `.tmp*`) supera `cap_bytes`, cancella i più vecchi
/// finché si rientra nel cap. Da chiamare dopo ogni scrittura riuscita.
/// Best-effort, non ricorsiva.
pub fn evictLru(dir_path: []const u8, cap_bytes: u64) void {
    if (enabled) evictLruLinux(dir_path, cap_bytes);
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
                .name = try arena.dupeZ(u8, name),
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
