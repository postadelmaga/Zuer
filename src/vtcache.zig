//! Cache su disco delle texture baked (tile 128² RGBA8, coarse-first). Abilita
//! l'approccio ibrido "olografico": le tile vivono su disco e si leggono a
//! richiesta con una lettura posizionale (`pread`/`ReadFile+OVERLAPPED`) in un
//! buffer riusabile → l'apertura è istantanea (si carica prima il livello
//! grezzo, poi si raffina) e la RAM di processo resta bassa: le pagine lette
//! finiscono nella page cache dell'OS (condivisa, reclaimable), NON nell'RSS del
//! processo. Le riaperture saltano il bake (page cache calda). Nessuna
//! decompressione: le tile sono grezze.
//!
//! Cross-platform senza dipendere da `std.Io` (il renderer non ha un `io` da
//! propagare): un sottile backend per-OS su syscall grezze. Directory cache:
//! `$HOME/.cache/zuer/vt` su Unix, `%LOCALAPPDATA%\zuer\vt` su Windows.
//!
//! Formato "VTC2" (little-endian):
//!   magic[4] "VTC2" | width u32 | height u32 | level_count u32
//!   levels: level_count × (tiles_x u32, tiles_y u32)   — coarse-first
//!   tiles:  Σ tiles_x·tiles_y × 65536 B                — ordine tileIndex del baker

const std = @import("std");
const builtin = @import("builtin");
const vtex = @import("vtex.zig");
// Copia host dell'helper di manutenzione cache (la gemella in src/decoders/
// serve texcache nel plugin glb: un file unico apparterrebbe a due moduli).
const evict = @import("cache_evict.zig");

const is_win = builtin.os.tag == .windows;

// VTC2: i mip sono downsamplati in spazio lineare (VTC1 li aveva in gamma,
// leggermente scuri) → il bump invalida le cache vecchie forzando il re-bake.
const magic = "VTC2";

/// Cap LRU della directory `…/zuer/vt` (~22MB per texture 2K: senza eviction
/// la cache cresce senza limite). Oltre la soglia, dopo ogni scrittura si
/// cancellano i file con mtime più vecchio. Su Windows la manutenzione è
/// no-op (cache_evict è solo Linux): stessa situazione di prima del fix.
const evict_cap_bytes: u64 = 512 * 1024 * 1024; // 512 MiB

/// Sweep dei tmp orfani fatto al più una volta per processo (alla prima scrittura).
var tmp_sweep_done: std.atomic.Value(bool) = .init(false);

// ── Backend POSIX (libc grezza) ─────────────────────────────────────────────
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, off: i64) isize;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;
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
} else struct {};

/// Sequenza per i nomi temporanei (unica per-processo; il PID li rende unici
/// anche tra processi).
var tmp_seq: std.atomic.Value(u64) = .init(0);

/// PID del processo corrente, per nomi tmp che non collidono tra istanze.
fn processId() u32 {
    if (is_win) return win.GetCurrentProcessId();
    return @intCast(getpid());
}

const Handle = if (is_win) win.HANDLE else c_int;

/// UTF-8 → UTF-16LE null-terminata in `out` (path corti: cache dir + nome file).
fn toW(path: []const u8, out: []u16) ?[*:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], path) catch return null;
    out[n] = 0;
    return @ptrCast(out.ptr);
}

/// Apre in lettura; null se assente. `path` deve essere null-terminato.
fn openRead(path: [:0]const u8) ?Handle {
    if (is_win) {
        var wbuf: [520]u16 = undefined;
        const w = toW(path, &wbuf) orelse return null;
        const h = win.CreateFileW(w, win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
        return if (h == win.INVALID) null else h;
    } else {
        const fd = open(path.ptr, O_RDONLY, 0);
        return if (fd < 0) null else fd;
    }
}

/// Crea/tronca in scrittura; null in errore.
fn openWrite(path: [:0]const u8) ?Handle {
    if (is_win) {
        var wbuf: [520]u16 = undefined;
        const w = toW(path, &wbuf) orelse return null;
        const h = win.CreateFileW(w, win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
        return if (h == win.INVALID) null else h;
    } else {
        const fd = open(path.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        return if (fd < 0) null else fd;
    }
}

fn closeH(h: Handle) void {
    if (is_win) _ = win.CloseHandle(h) else _ = close(h);
}

/// Rename per-OS che sostituisce la destinazione se esiste (atomico su POSIX).
/// false in errore.
fn renamePath(from: [:0]const u8, to: [:0]const u8) bool {
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

/// Lettura posizionale: byte letti (0 in errore/EOF, senza toccare oltre).
fn preadPos(h: Handle, buf: []u8, off: u64) usize {
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

fn writeAll(h: Handle, buf: []const u8) !void {
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
fn fileSize(h: Handle) i64 {
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
fn makeDirs(dir: []const u8) void {
    for (dir, 0..) |c, i| {
        if ((c == '/' or c == '\\') and i > 0) mkdirOne(dir[0..i]);
    }
    mkdirOne(dir);
}

/// Valore di una variabile d'ambiente, duplicato (chiamante libera). null se assente.
fn getEnvAlloc(gpa: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
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

fn u32le(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

fn rd32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

/// Texture baked su disco, letta a tile via lettura posizionale. Tiene aperto
/// l'handle + un buffer scratch da una tile; header/livelli sono in RAM
/// (piccoli). RAM di processo ~ scratch (64KB) + levels: i byte delle tile non
/// entrano nell'RSS.
pub const VtcMap = struct {
    h: Handle,
    width: u32,
    height: u32,
    levels: []vtex.LevelDesc,
    tiles_off: u64,
    scratch: []u8,
    gpa: std.mem.Allocator,

    /// Legge la tile `idx` nel buffer scratch (riusato) e lo ritorna. Il
    /// chiamante deve consumarlo prima della lettura successiva (upload seriale).
    pub fn tile(self: *const VtcMap, idx: u32) []const u8 {
        const off: u64 = self.tiles_off + @as(u64, idx) * vtex.tile_bytes;
        const n = preadPos(self.h, self.scratch, off);
        if (n < vtex.tile_bytes) @memset(self.scratch[n..], 0); // tile corta/errore: pad a zero
        return self.scratch;
    }

    pub fn deinit(self: *VtcMap) void {
        self.gpa.free(self.scratch);
        self.gpa.free(self.levels);
        closeH(self.h);
    }
};

/// Directory cache per-OS (`…/zuer/vt`), creando la catena di directory.
/// null se la variabile d'ambiente di base non è definita.
fn cacheDir(gpa: std.mem.Allocator) !?[]u8 {
    // `%LOCALAPPDATA%\zuer\vt` su Windows, `$HOME/.cache/zuer/vt` altrove.
    const base = getEnvAlloc(gpa, if (is_win) "LOCALAPPDATA" else "HOME") orelse return null;
    defer gpa.free(base);
    const sub = if (is_win) "zuer\\vt" else ".cache/zuer/vt";
    const dir = try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ base, std.fs.path.sep, sub });
    makeDirs(dir);
    return dir;
}

/// Apre e valida un file VTC per `(w,h)`; tiene l'handle aperto per le letture a
/// tile. Errore se assente/incoerente. Header e livelli sono letti in RAM.
fn openMap(gpa: std.mem.Allocator, path: [:0]const u8, w: u32, h: u32) !VtcMap {
    if (w == 0 or h == 0) return error.BadHeader;
    const handle = openRead(path) orelse return error.OpenFailed;
    errdefer closeH(handle);
    const size = fileSize(handle);
    if (size < 16) return error.TooSmall;

    var hdr: [16]u8 = undefined;
    if (preadPos(handle, &hdr, 0) != 16) return error.ReadFailed;
    if (!std.mem.eql(u8, hdr[0..4], magic)) return error.BadMagic;
    if (rd32(&hdr, 4) != w or rd32(&hdr, 8) != h) return error.Mismatch;
    const lc = rd32(&hdr, 12);
    if (lc == 0 or lc > 32) return error.BadHeader;

    var lvl_buf: [32 * 8]u8 = undefined;
    const lvl_bytes = @as(usize, lc) * 8;
    if (preadPos(handle, lvl_buf[0..lvl_bytes], 16) != lvl_bytes) return error.ReadFailed;

    // I livelli dichiarati dal file devono corrispondere ESATTAMENTE alla
    // piramide attesa per (w,h): chi consuma la mappa (chooseVtLevel,
    // l'indirezione SSBO) si fida di questi valori, e un file corrotto/ostile
    // con livelli arbitrari produrrebbe indici oltre budget → scritture OOB in
    // release. Con livelli validati anche le somme restano sane, ma si usa
    // comunque aritmetica controllata.
    const expected = vtex.levelsFor(gpa, w, h) catch return error.BadHeader;
    defer gpa.free(expected);
    if (expected.len != lc) return error.Mismatch;

    const levels = try gpa.alloc(vtex.LevelDesc, lc);
    errdefer gpa.free(levels);
    var tile_count: usize = 0;
    for (0..lc) |i| {
        const tx = rd32(&lvl_buf, i * 8);
        const ty = rd32(&lvl_buf, i * 8 + 4);
        if (tx != expected[i].tiles_x or ty != expected[i].tiles_y) return error.Mismatch;
        levels[i] = .{ .tiles_x = tx, .tiles_y = ty };
        const n = std.math.mul(usize, @as(usize, tx), ty) catch return error.BadHeader;
        tile_count = std.math.add(usize, tile_count, n) catch return error.BadHeader;
    }
    const tiles_off: u64 = 16 + lvl_bytes;
    const tiles_bytes = std.math.mul(u64, @as(u64, tile_count), vtex.tile_bytes) catch return error.BadHeader;
    const total = std.math.add(u64, tiles_off, tiles_bytes) catch return error.BadHeader;
    const total_i64 = std.math.cast(i64, total) orelse return error.BadHeader;
    if (size < total_i64) return error.Truncated;

    const scratch = try gpa.alloc(u8, vtex.tile_bytes);
    errdefer gpa.free(scratch);
    return .{ .h = handle, .width = w, .height = h, .levels = levels, .tiles_off = tiles_off, .scratch = scratch, .gpa = gpa };
}

/// Bake dell'RGBA in tile e scrittura nel file VTC. Scrittura ATOMICA: si
/// scrive su un tmp univoco (PID + seq: due istanze concorrenti non condividono
/// mai lo stesso tmp) e poi rename sul path finale — un crash a metà scrittura
/// non lascia mai un .vtc parziale che le aperture successive scambierebbero
/// per valido.
fn writeVtc(gpa: std.mem.Allocator, path: [:0]const u8, baked: *const vtex.BakedTexture) !void {
    const seq = tmp_seq.fetchAdd(1, .monotonic);
    const tmp = try std.fmt.allocPrintSentinel(gpa, "{s}.tmp{d}_{d}", .{ path, processId(), seq }, 0);
    defer gpa.free(tmp);

    const handle = openWrite(tmp) orelse return error.CreateFailed;
    var closed = false;
    errdefer if (!closed) closeH(handle);
    try writeAll(handle, magic);
    try writeAll(handle, &u32le(baked.width));
    try writeAll(handle, &u32le(baked.height));
    try writeAll(handle, &u32le(@intCast(baked.levels.len)));
    for (baked.levels) |d| {
        try writeAll(handle, &u32le(d.tiles_x));
        try writeAll(handle, &u32le(d.tiles_y));
    }
    for (baked.pages) |p| try writeAll(handle, p);
    closeH(handle);
    closed = true;
    if (!renamePath(tmp, path)) return error.RenameFailed;
}

/// Ritorna la texture baked mappata da disco per `(rgba,w,h)`: dalla cache se
/// presente (hash del contenuto), altrimenti bake + scrittura + mappa. Il
/// chiamante fa `deinit`.
pub fn openOrBake(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) !VtcMap {
    const dir = (try cacheDir(gpa)) orelse return error.NoCacheDir;
    defer gpa.free(dir);
    const key = std.hash.Wyhash.hash((@as(u64, w) << 32) | h, rgba);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}{c}{d}x{d}_{x}.vtc", .{ dir, std.fs.path.sep, w, h, key }, 0);
    defer gpa.free(path);

    if (openMap(gpa, path, w, h)) |m| {
        // Cache-hit: "touch" dell'mtime così l'eviction LRU non cancella le
        // entry usate (l'handle resta aperto in VtcMap, quindi si usa quello).
        if (!is_win) evict.touchFd(m.h);
        return m;
    } else |_| {}

    var baked = try vtex.bakeTiles(gpa, rgba, w, h);
    defer baked.deinit();
    try writeVtc(gpa, path, &baked);
    // Manutenzione post-scrittura (best-effort): sweep una-tantum dei tmp
    // orfani + cap LRU della directory.
    evict.sweepTmpOnce(&tmp_sweep_done, dir);
    evict.evictLru(dir, evict_cap_bytes);
    return try openMap(gpa, path, w, h);
}
