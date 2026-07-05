//! Virtual-texturing tile baker — port puro (solo `std`) da Zengine
//! (`src/assets/vtex.zig`, byte-compatibile con gear-vt). Rispetto all'originale
//! qui NON dipendiamo da GearPak/pak.zig: teniamo solo il baker in-memory
//! (`bakeTiles`) e le utility di livello/indice; il packing su archivio e i test
//! che lo usano restano in Zengine.
//!
//! Una texture ha nativamente la "holographic prefix property": la mip più alta
//! è già una texture completa (sfocata) e ogni mip la raffina. Questo baker
//! taglia ogni livello mip in tile 128×128 RGBA8 con gutter di bordo, quadtree-
//! parenta ogni tile alla tile che la copre nel livello più grezzo, ed emette
//! coarse-mip-first — un prefisso qualsiasi dello stream è una texture più
//! grezza completa.
//!
//! Payload di una tile: esattamente 128×128×4 = 65536 byte, pronto per
//! copy_buffer_to_texture senza conversioni.

const std = @import("std");

/// Lato fisico della tile in texel. Deve coincidere col tile array del runtime.
pub const tile_size: u32 = 128;
/// Texel di bordo duplicati dai vicini su ogni lato, così il filtraggio bilineare
/// non legge mai attraverso una cucitura fisica tra tile.
pub const gutter: u32 = 2;
/// Texel unici per lato tile: la texture virtuale è piastrellata su questa griglia.
pub const inner: u32 = tile_size - 2 * gutter;
/// Payload di una tile.
pub const tile_bytes: usize = tile_size * tile_size * 4;

/// Griglia tile di un livello mip.
pub const LevelDesc = struct { tiles_x: u32, tiles_y: u32 };

/// Griglie tile di ogni livello baked, COARSEST FIRST (l'ordine canonico di
/// pagina). Il livello 0 è il vertice quadtree a tile singola; l'ultimo è la
/// risoluzione piena. Le mip seguono floor-halving iterato, fermandosi al primo
/// livello che sta in una tile. Il chiamante libera.
pub fn levelsFor(gpa: std.mem.Allocator, width: u32, height: u32) ![]LevelDesc {
    std.debug.assert(width > 0 and height > 0);
    var list: std.ArrayList(LevelDesc) = .empty;
    errdefer list.deinit(gpa);
    var w = width;
    var h = height;
    while (true) {
        try list.append(gpa, .{
            .tiles_x = std.math.divCeil(u32, w, inner) catch unreachable,
            .tiles_y = std.math.divCeil(u32, h, inner) catch unreachable,
        });
        if (w <= inner and h <= inner) break;
        w = @max(w / 2, 1);
        h = @max(h / 2, 1);
    }
    std.mem.reverse(LevelDesc, list.items);
    return list.toOwnedSlice(gpa);
}

/// Dimensioni in pixel di un livello, per indice coarse-first.
pub fn levelDims(width: u32, height: u32, level: usize, level_count: usize) struct { w: u32, h: u32 } {
    const shift: u5 = @intCast(level_count - 1 - level);
    return .{ .w = @max(width >> shift, 1), .h = @max(height >> shift, 1) };
}

/// Indice tile/pagina piatto di `(tx, ty)` al livello coarse-first `level` —
/// l'ordine canonico condiviso da baker, runtime e tabella d'indirezione.
pub fn tileIndex(levels: []const LevelDesc, level: usize, tx: u32, ty: u32) u32 {
    var base: u32 = 0;
    for (levels[0..level]) |l| base += l.tiles_x * l.tiles_y;
    return base + ty * levels[level].tiles_x + tx;
}

/// Texture baked in payload di pagina: `pages[i]` è una tile (coarse-mip-first,
/// row-major dentro ogni livello).
pub const BakedTexture = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    /// Coarsest first; `levels[0]` è sempre 1×1.
    levels: []LevelDesc,
    pages: [][]u8,

    pub fn deinit(self: *BakedTexture) void {
        for (self.pages) |p| self.gpa.free(p);
        self.gpa.free(self.pages);
        self.gpa.free(self.levels);
    }

    pub fn tileIndexOf(self: *const BakedTexture, level: usize, tx: u32, ty: u32) u32 {
        return tileIndex(self.levels, level, tx, ty);
    }

    pub fn tileCount(self: *const BakedTexture) u32 {
        var n: u32 = 0;
        for (self.levels) |l| n += l.tiles_x * l.tiles_y;
        return n;
    }
};

/// Downsample box 2×2 (dimensioni dispari clampano la seconda riga/colonna) —
/// stessa convenzione floor-halving di `levelDims`, così baker e shader
/// concordano sulla dimensione di ogni livello.
fn downsample(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) !struct { img: []u8, w: u32, h: u32 } {
    const nw = @max(w / 2, 1);
    const nh = @max(h / 2, 1);
    const out = try gpa.alloc(u8, @as(usize, nw) * nh * 4);
    for (0..nh) |y| {
        const y0 = y * 2;
        const y1 = @min(y * 2 + 1, h - 1);
        for (0..nw) |x| {
            const x0 = x * 2;
            const x1 = @min(x * 2 + 1, w - 1);
            for (0..4) |c| {
                const sum = @as(u32, rgba[(y0 * w + x0) * 4 + c]) +
                    rgba[(y0 * w + x1) * 4 + c] +
                    rgba[(y1 * w + x0) * 4 + c] +
                    rgba[(y1 * w + x1) * 4 + c];
                out[(y * nw + x) * 4 + c] = @intCast(sum / 4);
            }
        }
    }
    return .{ .img = out, .w = nw, .h = nh };
}

/// Ritaglia una tile 128×128 (gutter incluso) da un'immagine di livello,
/// clampando le letture al bordo (texel replicati — riempiono anche lo slack
/// dell'ultima tile parziale).
fn extractTile(rgba: []const u8, w: u32, h: u32, tx: u32, ty: u32, out: []u8) void {
    std.debug.assert(out.len == tile_bytes);
    const x0 = @as(i64, tx) * inner - gutter;
    const y0 = @as(i64, ty) * inner - gutter;
    var o: usize = 0;
    for (0..tile_size) |y| {
        const sy: usize = @intCast(std.math.clamp(y0 + @as(i64, @intCast(y)), 0, @as(i64, h) - 1));
        for (0..tile_size) |x| {
            const sx: usize = @intCast(std.math.clamp(x0 + @as(i64, @intCast(x)), 0, @as(i64, w) - 1));
            const p = (sy * w + sx) * 4;
            @memcpy(out[o..][0..4], rgba[p..][0..4]);
            o += 4;
        }
    }
}

/// Bake di un'immagine RGBA8 in payload di tile (il gemello in-memory di
/// `packTexture` di Zengine — stessi byte, stesso ordine).
pub fn bakeTiles(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) !BakedTexture {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);
    const levels = try levelsFor(gpa, width, height);
    errdefer gpa.free(levels);
    const n = levels.len;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Immagini mip fine→coarse, poi le si percorre coarse→fine emettendo tile.
    const Mip = struct { img: []const u8, w: u32, h: u32 };
    const mips = try arena.alloc(Mip, n);
    mips[0] = .{ .img = rgba, .w = width, .h = height };
    for (1..n) |i| {
        const d = try downsample(arena, mips[i - 1].img, mips[i - 1].w, mips[i - 1].h);
        mips[i] = .{ .img = d.img, .w = d.w, .h = d.h };
    }

    var pages: std.ArrayList([]u8) = .empty;
    errdefer {
        for (pages.items) |p| gpa.free(p);
        pages.deinit(gpa);
    }
    for (levels, 0..) |desc, level| {
        const m = mips[n - 1 - level];
        for (0..desc.tiles_y) |ty| {
            for (0..desc.tiles_x) |tx| {
                const tile = try gpa.alloc(u8, tile_bytes);
                errdefer gpa.free(tile);
                extractTile(m.img, m.w, m.h, @intCast(tx), @intCast(ty), tile);
                try pages.append(gpa, tile);
            }
        }
    }

    return .{
        .gpa = gpa,
        .width = width,
        .height = height,
        .levels = levels,
        .pages = try pages.toOwnedSlice(gpa),
    };
}

// --- test (puri, nessuna dipendenza esterna) ------------------------------------

const testing = std.testing;

fn checker(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const v = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| {
        for (0..w) |x| {
            const on = ((x / 32) + (y / 32)) % 2 == 0;
            const c: u8 = if (on) 230 else 40;
            const o = (y * w + x) * 4;
            v[o] = c;
            v[o + 1] = c;
            v[o + 2] = c;
            v[o + 3] = 255;
        }
    }
    return v;
}

test "level chain: 1x1 top, covering fine level, monotonic in between" {
    const gpa = testing.allocator;
    const levels = try levelsFor(gpa, 1000, 500);
    defer gpa.free(levels);
    try testing.expectEqual(LevelDesc{ .tiles_x = 1, .tiles_y = 1 }, levels[0]);
    const fine = levels[levels.len - 1];
    try testing.expectEqual(std.math.divCeil(u32, 1000, inner) catch unreachable, fine.tiles_x);
    try testing.expectEqual(std.math.divCeil(u32, 500, inner) catch unreachable, fine.tiles_y);
    for (0..levels.len - 1) |i| {
        try testing.expect(levels[i].tiles_x <= levels[i + 1].tiles_x);
        try testing.expect(levels[i].tiles_y <= levels[i + 1].tiles_y);
    }

    const single = try levelsFor(gpa, 100, 60);
    defer gpa.free(single);
    try testing.expectEqual(@as(usize, 1), single.len);
}

test "tiles carry seam-free gutters" {
    const gpa = testing.allocator;
    const w = inner * 2;
    const h = inner;
    const img = try checker(gpa, w, h);
    defer gpa.free(img);
    var baked = try bakeTiles(gpa, img, w, h);
    defer baked.deinit();

    const fine = baked.levels.len - 1;
    try testing.expectEqual(LevelDesc{ .tiles_x = 2, .tiles_y = 1 }, baked.levels[fine]);
    for (baked.pages) |p| try testing.expectEqual(tile_bytes, p.len);

    // Il gutter sinistro della tile 1 replica i texel interni destri della tile 0.
    const t0 = baked.pages[baked.tileIndexOf(fine, 0, 0)];
    const t1 = baked.pages[baked.tileIndexOf(fine, 1, 0)];
    var y: usize = gutter;
    while (y < gutter + 8) : (y += 3) {
        for (0..gutter) |g| {
            const src_x = gutter + inner - gutter + g;
            const a = t0[(y * tile_size + src_x) * 4 ..][0..4];
            const b = t1[(y * tile_size + g) * 4 ..][0..4];
            try testing.expectEqualSlices(u8, a, b);
        }
    }
}
