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
//! propagare): file, cartella e manutenzione passano da diskcache.zig. Directory
//! cache: `$HOME/.cache/zuer/vt` su Unix, `%LOCALAPPDATA%\zuer\vt` su Windows.
//!
//! Formato "VTC2" (little-endian):
//!   magic[4] "VTC2" | width u32 | height u32 | level_count u32
//!   levels: level_count × (tiles_x u32, tiles_y u32)   — coarse-first
//!   tiles:  Σ tiles_x·tiles_y × 65536 B                — ordine tileIndex del baker

const std = @import("std");
const vtex = @import("vtex.zig");
const dc = @import("diskcache.zig");

// VTC2: i mip sono downsamplati in spazio lineare (VTC1 li aveva in gamma,
// leggermente scuri) → il bump invalida le cache vecchie forzando il re-bake.
const magic = "VTC2";

/// Cap LRU della directory `…/zuer/vt` (~22MB per texture 2K: senza eviction
/// la cache cresce senza limite). Oltre la soglia, dopo ogni scrittura si
/// cancellano i file con mtime più vecchio. Fuori da Linux la manutenzione è
/// no-op (vedi diskcache.zig).
const evict_cap_bytes: u64 = 512 * 1024 * 1024; // 512 MiB

/// Sweep dei tmp orfani fatto al più una volta per processo (alla prima scrittura).
var tmp_sweep_done: std.atomic.Value(bool) = .init(false);

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
    h: dc.Handle,
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
        const n = dc.preadPos(self.h, self.scratch, off);
        if (n < vtex.tile_bytes) @memset(self.scratch[n..], 0); // tile corta/errore: pad a zero
        return self.scratch;
    }

    pub fn deinit(self: *VtcMap) void {
        self.gpa.free(self.scratch);
        self.gpa.free(self.levels);
        dc.closeH(self.h);
    }
};

/// Apre e valida un file VTC per `(w,h)`; tiene l'handle aperto per le letture a
/// tile. Errore se assente/incoerente. Header e livelli sono letti in RAM.
fn openMap(gpa: std.mem.Allocator, path: [:0]const u8, w: u32, h: u32) !VtcMap {
    if (w == 0 or h == 0) return error.BadHeader;
    const handle = dc.openRead(path) orelse return error.OpenFailed;
    errdefer dc.closeH(handle);
    const size = dc.fileSize(handle);
    if (size < 16) return error.TooSmall;

    var hdr: [16]u8 = undefined;
    if (dc.preadPos(handle, &hdr, 0) != 16) return error.ReadFailed;
    if (!std.mem.eql(u8, hdr[0..4], magic)) return error.BadMagic;
    if (rd32(&hdr, 4) != w or rd32(&hdr, 8) != h) return error.Mismatch;
    const lc = rd32(&hdr, 12);
    if (lc == 0 or lc > 32) return error.BadHeader;

    var lvl_buf: [32 * 8]u8 = undefined;
    const lvl_bytes = @as(usize, lc) * 8;
    if (dc.preadPos(handle, lvl_buf[0..lvl_bytes], 16) != lvl_bytes) return error.ReadFailed;

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

/// Bake dell'RGBA in tile e scrittura atomica nel file VTC (vedi
/// `diskcache.AtomicWriter`: un crash a metà non lascia un .vtc parziale).
fn writeVtc(gpa: std.mem.Allocator, path: [:0]const u8, baked: *const vtex.BakedTexture) !void {
    var w = dc.AtomicWriter.begin(gpa, path) orelse return error.CreateFailed;
    w.write(magic);
    w.write(&u32le(baked.width));
    w.write(&u32le(baked.height));
    w.write(&u32le(@intCast(baked.levels.len)));
    for (baked.levels) |d| {
        w.write(&u32le(d.tiles_x));
        w.write(&u32le(d.tiles_y));
    }
    for (baked.pages) |p| w.write(p);
    if (!w.commit()) return error.WriteFailed;
}

/// Ritorna la texture baked mappata da disco per `(rgba,w,h)`: dalla cache se
/// presente (hash del contenuto), altrimenti bake + scrittura + mappa. Il
/// chiamante fa `deinit`.
pub fn openOrBake(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) !VtcMap {
    const dir = dc.cacheDir(gpa, "vt") orelse return error.NoCacheDir;
    defer gpa.free(dir);
    const key = std.hash.Wyhash.hash((@as(u64, w) << 32) | h, rgba);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}{c}{d}x{d}_{x}.vtc", .{ dir, std.fs.path.sep, w, h, key }, 0);
    defer gpa.free(path);

    if (openMap(gpa, path, w, h)) |m| {
        // Cache-hit: "touch" dell'mtime così l'eviction LRU non cancella le
        // entry usate (l'handle resta aperto in VtcMap, quindi si usa quello).
        dc.touch(m.h);
        return m;
    } else |_| {}

    var baked = try vtex.bakeTiles(gpa, rgba, w, h);
    defer baked.deinit();
    try writeVtc(gpa, path, &baked);
    // Manutenzione post-scrittura (best-effort): sweep una-tantum dei tmp
    // orfani + cap LRU della directory.
    dc.maintain(&tmp_sweep_done, dir, evict_cap_bytes);
    return try openMap(gpa, path, w, h);
}

test "VTC: scrittura e rilettura a tile, file troncato rifiutato" {
    if (dc.is_win) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(gpa, ".zig-cache/tmp/{s}/t.vtc", .{tmp.sub_path}, 0);
    defer gpa.free(path);

    const w: u32 = 300;
    const h: u32 = 200;
    const rgba = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(rgba);
    for (rgba, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 9));

    var baked = try vtex.bakeTiles(gpa, rgba, w, h);
    defer baked.deinit();
    try writeVtc(gpa, path, &baked);

    {
        var m = try openMap(gpa, path, w, h);
        defer m.deinit();
        try std.testing.expectEqual(baked.levels.len, m.levels.len);
        // Ogni tile letta da disco è quella uscita dal bake.
        for (baked.pages, 0..) |page, i| {
            try std.testing.expectEqualSlices(u8, page, m.tile(@intCast(i)));
        }
        // Dimensioni diverse da quelle del file: rifiutato.
        try std.testing.expect(if (openMap(gpa, path, w + 1, h)) |_| false else |_| true);
    }

    // Stesso header, corpo più corto di una tile: non deve essere scambiato per valido.
    {
        const hnd = dc.openRead(path).?;
        const size: usize = @intCast(dc.fileSize(hnd));
        const all = try gpa.alloc(u8, size);
        defer gpa.free(all);
        try std.testing.expect(dc.readExact(hnd, all, 0));
        dc.closeH(hnd);
        var out = dc.AtomicWriter.begin(gpa, path).?;
        out.write(all[0 .. size - vtex.tile_bytes]);
        try std.testing.expect(out.commit());
        try std.testing.expectError(error.Truncated, openMap(gpa, path, w, h));
    }
}
