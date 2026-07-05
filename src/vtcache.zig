//! Cache su disco delle texture baked (tile 128² RGBA8, coarse-first). Abilita
//! l'approccio ibrido "olografico": le tile vivono su disco e si leggono a
//! richiesta con `pread` in un buffer riusabile → l'apertura è istantanea (si
//! carica prima il livello grezzo, poi si raffina) e la RAM di processo resta
//! bassa: le pagine lette finiscono nella page cache dell'OS (condivisa,
//! reclaimable), NON nell'RSS del processo. Le riaperture saltano il bake
//! (page cache calda). Nessuna decompressione: le tile sono grezze.
//!
//! Formato "VTC1" (little-endian):
//!   magic[4] "VTC1" | width u32 | height u32 | level_count u32
//!   levels: level_count × (tiles_x u32, tiles_y u32)   — coarse-first
//!   tiles:  Σ tiles_x·tiles_y × 65536 B                — ordine tileIndex del baker

const std = @import("std");
const vtex = @import("vtex.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, off: i64) isize;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;
const SEEK_END: c_int = 2;

// VTC2: i mip sono ora downsamplati in spazio lineare (VTC1 li aveva in gamma,
// leggermente scuri) → il bump invalida le cache vecchie forzando il re-bake.
const magic = "VTC2";

/// Texture baked su disco, letta a tile via `pread`. Tiene aperto l'fd + un
/// buffer scratch da una tile; header/livelli sono in RAM (piccoli). RAM di
/// processo ~ scratch (64KB) + levels: i byte delle tile non entrano nell'RSS.
pub const VtcMap = struct {
    fd: c_int,
    width: u32,
    height: u32,
    levels: []vtex.LevelDesc,
    tiles_off: usize,
    scratch: []u8,
    gpa: std.mem.Allocator,

    /// Legge la tile `idx` nel buffer scratch (riusato) e lo ritorna. Il
    /// chiamante deve consumarlo prima della lettura successiva (upload seriale).
    pub fn tile(self: *const VtcMap, idx: u32) []const u8 {
        const off: i64 = @intCast(self.tiles_off + @as(usize, idx) * vtex.tile_bytes);
        const n = pread(self.fd, self.scratch.ptr, vtex.tile_bytes, off);
        if (n < @as(isize, @intCast(vtex.tile_bytes))) {
            const got: usize = if (n > 0) @intCast(n) else 0;
            @memset(self.scratch[got..], 0); // tile corta/errore: pad a zero (nessun garbage)
        }
        return self.scratch;
    }

    pub fn deinit(self: *VtcMap) void {
        self.gpa.free(self.scratch);
        self.gpa.free(self.levels);
        _ = close(self.fd);
    }
};

fn u32le(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

fn rd32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

fn writeAll(fd: c_int, buf: []const u8) !void {
    var i: usize = 0;
    while (i < buf.len) {
        const n = write(fd, buf.ptr + i, buf.len - i);
        if (n <= 0) return error.WriteFailed;
        i += @intCast(n);
    }
}

/// `$HOME/.cache/zuer/vt`, creando la catena di directory. null se niente HOME.
fn cacheDir(gpa: std.mem.Allocator) !?[]u8 {
    const home_c = getenv("HOME") orelse return null;
    const home = std.mem.span(home_c);
    inline for (.{ "/.cache", "/.cache/zuer", "/.cache/zuer/vt" }) |suffix| {
        const p = try std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ home, suffix }, 0);
        defer gpa.free(p);
        _ = mkdir(p.ptr, 0o755); // EEXIST ignorato: se fallisce davvero, open a valle fallisce
    }
    return try std.fmt.allocPrint(gpa, "{s}/.cache/zuer/vt", .{home});
}

/// Apre e valida un file VTC per `(w,h)`; tiene l'fd aperto per le letture a
/// tile. Errore se assente/incoerente. Header e livelli sono letti in RAM.
fn openMap(gpa: std.mem.Allocator, path: [*:0]const u8, w: u32, h: u32) !VtcMap {
    const fd = open(path, O_RDONLY, 0);
    if (fd < 0) return error.OpenFailed;
    errdefer _ = close(fd);
    const size = lseek(fd, 0, SEEK_END);
    if (size < 16) return error.TooSmall;

    var hdr: [16]u8 = undefined;
    if (pread(fd, &hdr, 16, 0) != 16) return error.ReadFailed;
    if (!std.mem.eql(u8, hdr[0..4], magic)) return error.BadMagic;
    if (rd32(&hdr, 4) != w or rd32(&hdr, 8) != h) return error.Mismatch;
    const lc = rd32(&hdr, 12);
    if (lc == 0 or lc > 32) return error.BadHeader;

    var lvl_buf: [32 * 8]u8 = undefined;
    const lvl_bytes = @as(usize, lc) * 8;
    if (pread(fd, &lvl_buf, lvl_bytes, 16) != @as(isize, @intCast(lvl_bytes))) return error.ReadFailed;

    const levels = try gpa.alloc(vtex.LevelDesc, lc);
    errdefer gpa.free(levels);
    var tile_count: usize = 0;
    for (0..lc) |i| {
        const tx = rd32(&lvl_buf, i * 8);
        const ty = rd32(&lvl_buf, i * 8 + 4);
        levels[i] = .{ .tiles_x = tx, .tiles_y = ty };
        tile_count += @as(usize, tx) * ty;
    }
    const tiles_off = 16 + lvl_bytes;
    if (size < @as(i64, @intCast(tiles_off + tile_count * vtex.tile_bytes))) return error.Truncated;

    const scratch = try gpa.alloc(u8, vtex.tile_bytes);
    errdefer gpa.free(scratch);
    return .{ .fd = fd, .width = w, .height = h, .levels = levels, .tiles_off = tiles_off, .scratch = scratch, .gpa = gpa };
}

/// Bake dell'RGBA in tile e scrittura nel file VTC.
fn writeVtc(path: [*:0]const u8, baked: *const vtex.BakedTexture) !void {
    const fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
    if (fd < 0) return error.CreateFailed;
    defer _ = close(fd);
    try writeAll(fd, magic);
    try writeAll(fd, &u32le(baked.width));
    try writeAll(fd, &u32le(baked.height));
    try writeAll(fd, &u32le(@intCast(baked.levels.len)));
    for (baked.levels) |d| {
        try writeAll(fd, &u32le(d.tiles_x));
        try writeAll(fd, &u32le(d.tiles_y));
    }
    for (baked.pages) |p| try writeAll(fd, p);
}

/// Ritorna la texture baked mappata da disco per `(rgba,w,h)`: dalla cache se
/// presente (hash del contenuto), altrimenti bake + scrittura + mappa. Il
/// chiamante fa `deinit`.
pub fn openOrBake(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) !VtcMap {
    const dir = (try cacheDir(gpa)) orelse return error.NoCacheDir;
    defer gpa.free(dir);
    const key = std.hash.Wyhash.hash((@as(u64, w) << 32) | h, rgba);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{d}x{d}_{x}.vtc", .{ dir, w, h, key }, 0);
    defer gpa.free(path);

    if (openMap(gpa, path.ptr, w, h)) |m| return m else |_| {}

    var baked = try vtex.bakeTiles(gpa, rgba, w, h);
    defer baked.deinit();
    try writeVtc(path.ptr, &baked);
    return try openMap(gpa, path.ptr, w, h);
}
