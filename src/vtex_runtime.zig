//! Runtime di virtual-texturing (core CPU) — port puro (solo `std` + `vtex.zig`)
//! da Zengine (`src/assets/vtex_runtime.zig`). Un pool fisso di slot fisici più
//! un walk d'indirezione che trasforma qualunque richiesta di tile nella tile
//! RESIDENTE più fine che la copre — mai un buco. Il fault di una tile è riempito
//! da una `FillFn` fornita dal chiamante (leggi da archivio, genera, oppure —
//! come qui in zuer — copia da tile già in memoria).
//!
//! Il layout combacia col baker (`vtex.zig`): livelli coarse-first, parent
//! quadtree `(level-1, tx/2, ty/2)` clampato alla griglia più grezza — così il
//! pool tiene tile byte-identiche e un path GPU può copiarle dritte in un array.
//!
//! Rispetto all'originale è rimossa la `PakTileSource` (dipendente da GearPak);
//! al suo posto c'è `MemTileSource`, sopra le pagine di un `vtex.BakedTexture`.

const std = @import("std");
const vtex = @import("vtex.zig");

pub const tile_bytes = vtex.tile_bytes;

/// Indirizzo di una tile virtuale nella piramide coarse-first.
pub const TileId = struct { level: u16, tx: u16, ty: u16 };

/// Produce i texel della tile `(level, tx, ty)` in `out` (esattamente
/// `tile_bytes`); ritorna false se la tile non è producibile (es. pagina non
/// ancora streamata), nel qual caso il runtime tiene un antenato più grezzo.
pub const FillFn = *const fn (ctx: *anyopaque, level: u32, tx: u32, ty: u32, out: []u8) bool;

/// Dove risolve un sample: uno slot fisico più la tile effettivamente trovata
/// (la richiesta, o un antenato più grezzo dopo il fallback).
pub const Resolved = struct { slot: u32, level: u32, tx: u32, ty: u32 };

/// Invocato quando una tile diventa residente in uno slot (dopo un fill
/// riuscito) — la cucitura che un mirror GPU usa per caricare lo stesso slot.
pub const ResidentHook = *const fn (ctx: *anyopaque, tile: TileId, slot: u32) void;

pub const VirtualTexture = struct {
    gpa: std.mem.Allocator,
    /// Griglie tile coarse-first (copia posseduta del level chain dell'asset).
    levels: []vtex.LevelDesc,
    width: u32,
    height: u32,

    fill: FillFn,
    ctx: *anyopaque,

    /// Slot fisici: `capacity * tile_bytes` texel, `slot_tile[i]` = quale tile
    /// virtuale vive nello slot i (null = vuoto), `slot_used[i]` = tick LRU.
    capacity: u32,
    pool: []u8,
    slot_tile: []?TileId,
    slot_used: []u64,

    resident: std.AutoHashMapUnmanaged(TileId, u32),
    /// Tile pinnate questo frame (richieste o antenati di una richiesta): mai
    /// evicted fino al prossimo `beginFrame`.
    pinned: std.AutoHashMapUnmanaged(TileId, void),
    tick: u64,
    faults: u64, // fill riusciti dall'init (diagnostica + test)
    /// Hook mirror opzionale (es. carica lo slot su un pool tile GPU).
    on_resident: ?ResidentHook = null,
    resident_ctx: *anyopaque = undefined,

    pub fn init(
        gpa: std.mem.Allocator,
        levels: []const vtex.LevelDesc,
        width: u32,
        height: u32,
        capacity: u32,
        fill: FillFn,
        ctx: *anyopaque,
    ) !VirtualTexture {
        std.debug.assert(capacity >= 1);
        const self = VirtualTexture{
            .gpa = gpa,
            .levels = try gpa.dupe(vtex.LevelDesc, levels),
            .width = width,
            .height = height,
            .fill = fill,
            .ctx = ctx,
            .capacity = capacity,
            .pool = try gpa.alloc(u8, @as(usize, capacity) * tile_bytes),
            .slot_tile = try gpa.alloc(?TileId, capacity),
            .slot_used = try gpa.alloc(u64, capacity),
            .resident = .empty,
            .pinned = .empty,
            .tick = 0,
            .faults = 0,
        };
        @memset(self.slot_tile, null);
        @memset(self.slot_used, 0);
        @memset(self.pool, 0);
        return self;
    }

    pub fn deinit(self: *VirtualTexture) void {
        self.resident.deinit(self.gpa);
        self.pinned.deinit(self.gpa);
        self.gpa.free(self.slot_used);
        self.gpa.free(self.slot_tile);
        self.gpa.free(self.pool);
        self.gpa.free(self.levels);
    }

    /// Il parent quadtree di una tile — byte-per-byte la relazione del baker.
    pub fn parentOf(self: *const VirtualTexture, t: TileId) TileId {
        std.debug.assert(t.level > 0);
        const p = self.levels[t.level - 1];
        return .{
            .level = t.level - 1,
            .tx = @intCast(@min(@as(u32, t.tx) / 2, p.tiles_x - 1)),
            .ty = @intCast(@min(@as(u32, t.ty) / 2, p.tiles_y - 1)),
        };
    }

    /// Inizia un frame: spinna tutto e avanza il clock LRU. Le richieste fatte
    /// dopo sono il working set del frame.
    pub fn beginFrame(self: *VirtualTexture) void {
        self.pinned.clearRetainingCapacity();
        self.tick += 1;
    }

    /// Texel di uno slot residente (read-only) — la cucitura per l'upload GPU
    /// futuro e per il sampler CPU.
    pub fn slotTexels(self: *const VirtualTexture, slot: u32) []const u8 {
        return self.pool[@as(usize, slot) * tile_bytes ..][0..tile_bytes];
    }

    fn touch(self: *VirtualTexture, slot: u32) void {
        self.slot_used[slot] = self.tick;
    }

    /// Assicura che una tile e tutta la sua catena di antenati siano residenti,
    /// pinnandole per questo frame. Il caricamento della catena è coarsest-first,
    /// così un fault fallito costa solo dettaglio. Ritorna la risoluzione per
    /// `(level, tx, ty)`.
    pub fn request(self: *VirtualTexture, level: u32, tx: u32, ty: u32) !Resolved {
        std.debug.assert(level < self.levels.len);
        std.debug.assert(tx < self.levels[level].tiles_x and ty < self.levels[level].tiles_y);
        const want = TileId{ .level = @intCast(level), .tx = @intCast(tx), .ty = @intCast(ty) };

        // Catena di antenati, coarsest → finest.
        var chain: [32]TileId = undefined;
        var n: usize = 0;
        var cur = want;
        while (true) {
            chain[n] = cur;
            n += 1;
            if (cur.level == 0 or n == chain.len) break;
            cur = self.parentOf(cur);
        }
        // Carica prima il più grezzo, così un'eviction non può mai togliere un
        // antenato che serve ancora questo frame (ognuno diventa pinnato).
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            _ = try self.ensureResident(chain[i]);
        }
        return self.resolve(level, tx, ty);
    }

    /// Risolve senza caricare: la tile già residente più fine che copre
    /// `(level, tx, ty)`. Il livello 0 è tenuto residente, quindi termina sempre.
    pub fn resolve(self: *VirtualTexture, level: u32, tx: u32, ty: u32) Resolved {
        var t = TileId{ .level = @intCast(level), .tx = @intCast(tx), .ty = @intCast(ty) };
        while (true) {
            if (self.resident.get(t)) |slot| {
                self.touch(slot);
                return .{ .slot = slot, .level = t.level, .tx = t.tx, .ty = t.ty };
            }
            if (t.level == 0) break;
            t = self.parentOf(t);
        }
        // Livello 0 non ancora residente (prima della prima richiesta): slot 0 è
        // il vertice convenzionale; il chiamante dovrebbe richiederlo.
        return .{ .slot = 0, .level = 0, .tx = 0, .ty = 0 };
    }

    /// Registra un hook mirror che scatta ogni volta che una tile entra in slot.
    pub fn setResidentHook(self: *VirtualTexture, ctx: *anyopaque, hook: ResidentHook) void {
        self.resident_ctx = ctx;
        self.on_resident = hook;
    }

    /// Rende residente una tile, pinnandola per il frame. Fault via `fill` in uno
    /// slot libero o evicted-LRU. Ritorna true se residente dopo.
    fn ensureResident(self: *VirtualTexture, t: TileId) !bool {
        if (self.resident.get(t)) |slot| {
            self.touch(slot);
            try self.pinned.put(self.gpa, t, {});
            return true;
        }
        const slot = self.pickSlot() orelse return false; // tutto pinnato: tieni grezzo
        // Fill prima di committare: un fill fallito lascia lo slot com'era.
        if (!self.fill(self.ctx, t.level, t.tx, t.ty, self.pool[@as(usize, slot) * tile_bytes ..][0..tile_bytes]))
            return false;
        // Sfratta l'occupante precedente, se c'è.
        if (self.slot_tile[slot]) |old| _ = self.resident.remove(old);
        self.slot_tile[slot] = t;
        try self.resident.put(self.gpa, t, slot);
        try self.pinned.put(self.gpa, t, {});
        self.touch(slot);
        self.faults += 1;
        if (self.on_resident) |hook| hook(self.resident_ctx, t, slot);
        return true;
    }

    /// Uno slot libero, altrimenti lo slot UNPINNED meno recente. Null quando
    /// ogni slot è pinnato questo frame (il working set supera il pool).
    fn pickSlot(self: *VirtualTexture) ?u32 {
        var lru_slot: ?u32 = null;
        var lru_tick: u64 = std.math.maxInt(u64);
        for (self.slot_tile, 0..) |occ, s| {
            if (occ == null) return @intCast(s); // slot libero vince subito
            if (self.pinned.contains(occ.?)) continue; // pinnato questo frame
            if (self.slot_used[s] < lru_tick) {
                lru_tick = self.slot_used[s];
                lru_slot = @intCast(s);
            }
        }
        return lru_slot;
    }

    /// Sample nearest-texel della texture virtuale a UV∈[0,1] al `level`,
    /// onorando il fallback residente. Ritorna RGBA8. È il riferimento CPU
    /// (e il fallback software futuro); il path GPU lo rispecchia.
    pub fn sampleNearest(self: *VirtualTexture, u: f32, v: f32, level: u32) [4]u8 {
        const r = self.resolve(level, tileAt(u, self.axisTiles(level, true)), tileAt(v, self.axisTiles(level, false)));
        // Ricalcola il texel locale al livello RISOLTO (il fallback può essere grezzo).
        const lv = r.level;
        const desc = self.levels[lv];
        const uc = std.math.clamp(u, 0, 0.999999);
        const vc = std.math.clamp(v, 0, 0.999999);
        const px: u32 = @intFromFloat(uc * @as(f32, @floatFromInt(desc.tiles_x * vtex.inner)));
        const py: u32 = @intFromFloat(vc * @as(f32, @floatFromInt(desc.tiles_y * vtex.inner)));
        const lx = vtex.gutter + (px % vtex.inner);
        const ly = vtex.gutter + (py % vtex.inner);
        const texels = self.slotTexels(r.slot);
        const o = (ly * vtex.tile_size + lx) * 4;
        return .{ texels[o], texels[o + 1], texels[o + 2], texels[o + 3] };
    }

    fn axisTiles(self: *const VirtualTexture, level: u32, x_axis: bool) u32 {
        const d = self.levels[level];
        return if (x_axis) d.tiles_x else d.tiles_y;
    }
};

/// L'indice tile lungo un asse per UV `c`∈[0,1] a un livello con `tiles` tile.
fn tileAt(c: f32, tiles: u32) u32 {
    const cc = std.math.clamp(c, 0, 0.999999);
    return @min(@as(u32, @intFromFloat(cc * @as(f32, @floatFromInt(tiles)))), tiles - 1);
}

/// Sorgente `FillFn` sopra le pagine di un `vtex.BakedTexture` già in memoria:
/// il fault copia la tile byte-identica dalla pagina corrispondente (una tile ==
/// una pagina, nell'ordine coarse-first `tileIndex` del baker). È l'analogo
/// in-memory della `PakTileSource` di Zengine, senza archivio su disco.
pub const MemTileSource = struct {
    levels: []const vtex.LevelDesc,
    pages: []const []const u8,

    pub fn init(baked: *const vtex.BakedTexture) MemTileSource {
        return .{ .levels = baked.levels, .pages = baked.pages };
    }

    pub fn fill(ctx: *anyopaque, level: u32, tx: u32, ty: u32, out: []u8) bool {
        const self: *MemTileSource = @ptrCast(@alignCast(ctx));
        const idx = vtex.tileIndex(self.levels, level, tx, ty);
        if (idx >= self.pages.len) return false;
        const page = self.pages[idx];
        if (page.len != out.len) return false;
        @memcpy(out, page);
        return true;
    }
};

// --- test ------------------------------------------------------------------------

const testing = std.testing;

/// Sorgente sintetica: i texel di una tile codificano il proprio (level, tx, ty)
/// nel primo pixel, così un sample prova da quale tile fisica provengono.
const Synth = struct {
    fills: u32 = 0,
    avail_level: u32 = 255,

    fn fill(ctx: *anyopaque, level: u32, tx: u32, ty: u32, out: []u8) bool {
        const self: *Synth = @ptrCast(@alignCast(ctx));
        if (level > self.avail_level) return false;
        self.fills += 1;
        var i: usize = 0;
        while (i < out.len) : (i += 4) {
            out[i] = @intCast(level & 0xFF);
            out[i + 1] = @intCast(tx & 0xFF);
            out[i + 2] = @intCast(ty & 0xFF);
            out[i + 3] = 255;
        }
        return true;
    }
};

test "runtime resolves the finest resident tile and never a hole" {
    const gpa = testing.allocator;
    const levels = try vtex.levelsFor(gpa, 4096, 4096);
    defer gpa.free(levels);

    var src = Synth{};
    var vt = try VirtualTexture.init(gpa, levels, 4096, 4096, 64, Synth.fill, &src);
    defer vt.deinit();

    const fine: u32 = @intCast(levels.len - 1);

    vt.beginFrame();
    const r = try vt.request(fine, 3, 5);
    try testing.expectEqual(@as(u32, fine), r.level);
    const px = vt.slotTexels(r.slot);
    try testing.expectEqual(@as(u8, @intCast(fine & 0xFF)), px[0]);
    try testing.expectEqual(@as(u8, 3), px[1]);
    try testing.expectEqual(@as(u8, 5), px[2]);
    try testing.expectEqual(@as(u32, @intCast(levels.len)), src.fills);
}

test "an 8K-equivalent texture materializes only the tiles sampled" {
    const gpa = testing.allocator;
    const levels = try vtex.levelsFor(gpa, 8192, 8192);
    defer gpa.free(levels);
    var total: u32 = 0;
    for (levels) |l| total += l.tiles_x * l.tiles_y;
    try testing.expect(total > 1000);

    var src = Synth{};
    var vt = try VirtualTexture.init(gpa, levels, 8192, 8192, 64, Synth.fill, &src);
    defer vt.deinit();
    const fine: u32 = @intCast(levels.len - 1);

    vt.beginFrame();
    _ = try vt.request(fine, 0, 0);
    _ = try vt.request(fine, 1, 0);
    try testing.expect(src.fills <= @as(u32, @intCast(levels.len)) + 1);
    try testing.expect(vt.faults <= vt.capacity);
}

test "MemTileSource: bake -> runtime round-trips a fine tile byte-identically" {
    const gpa = testing.allocator;
    const w: u32 = vtex.inner * 4;
    const h: u32 = vtex.inner * 2;
    const img = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(img);
    for (0..h) |y| for (0..w) |x| {
        const o = (y * w + x) * 4;
        img[o] = @intCast(x & 0xFF);
        img[o + 1] = @intCast(y & 0xFF);
        img[o + 2] = @intCast((x ^ y) & 0xFF);
        img[o + 3] = 255;
    };
    var baked = try vtex.bakeTiles(gpa, img, w, h);
    defer baked.deinit();

    var src = MemTileSource.init(&baked);
    var vt = try VirtualTexture.init(gpa, baked.levels, w, h, 32, MemTileSource.fill, &src);
    defer vt.deinit();
    const fine: u32 = @intCast(baked.levels.len - 1);

    vt.beginFrame();
    const r = try vt.request(fine, 1, 1);
    try testing.expectEqual(fine, r.level);
    // Lo slot residente combacia byte-per-byte con la pagina baked di quella tile.
    const local = vtex.tileIndex(baked.levels, fine, 1, 1);
    try testing.expectEqualSlices(u8, baked.pages[local], vt.slotTexels(r.slot));

    // Con solo il prefisso grezzo disponibile (nessun fine), una richiesta fine
    // risolve al vertice residente — mai un buco.
    var src2 = MemTileSource{ .levels = baked.levels, .pages = baked.pages[0..1] };
    var vt2 = try VirtualTexture.init(gpa, baked.levels, w, h, 32, MemTileSource.fill, &src2);
    defer vt2.deinit();
    vt2.beginFrame();
    const coarse = try vt2.request(fine, 1, 1);
    try testing.expectEqual(@as(u32, 0), coarse.level);
}
