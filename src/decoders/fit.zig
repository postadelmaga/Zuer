//! Riduzione a media per area (box filter) dei pixel decodificati, con alpha
//! composto su bianco e orientamento EXIF, verso un buffer RGB: il cuore di
//! `resizeToFit` del plugin immagini. Puro Zig, senza dipendenze: testato da
//! `zig build test` contro l'implementazione per-pixel di prima, byte per byte.

const std = @import("std");
const exif = @import("exif.zig");

/// Riduce `src` (`src_w`×`src_h`, `ch` = 3 RGB o 4 RGBA) a `dst_w`×`dst_h` (taglia
/// nello spazio della SORGENTE, ≤ di quella sorgente) e scrive in `out` l'immagine
/// già orientata secondo `orient` (1 = nessun orientamento): out_w×out_h×3 byte,
/// con out_w/out_h scambiati per gli orientamenti 5..8.
///
/// Ogni pixel è la media intera (troncata) del blocco sorgente
/// [x0, x1) × [y0, y1), x0 = dx·src_w / dst_w, x1 = max(x0 + 1, (dx + 1)·src_w / dst_w).
/// I bordi dei blocchi si calcolano una volta per colonna e per riga (prima:
/// quattro divisioni a 64 bit per pixel), e a scala 1:1 senza orientamento né
/// alpha la riduzione è una copia.
pub fn boxResize(
    gpa: std.mem.Allocator,
    src: [*]const u8,
    ch: usize,
    src_w: usize,
    src_h: usize,
    orient: u8,
    dst_w: usize,
    dst_h: usize,
    out: []u8,
) error{OutOfMemory}!void {
    std.debug.assert(ch == 3 or ch == 4);
    std.debug.assert(dst_w >= 1 and dst_h >= 1 and dst_w <= src_w and dst_h <= src_h);
    const swap = orient >= 5 and orient <= 8;
    const out_w = if (swap) dst_h else dst_w;
    const out_h = if (swap) dst_w else dst_h;
    std.debug.assert(out.len == out_w * out_h * 3);
    const oriented = orient >= 2 and orient <= 8;

    if (ch == 3 and !oriented and dst_w == src_w and dst_h == src_h) {
        @memcpy(out, src[0 .. src_w * src_h * 3]);
        return;
    }

    const xs = try gpa.alloc(usize, 2 * dst_w);
    defer gpa.free(xs);
    const ys = try gpa.alloc(usize, 2 * dst_h);
    defer gpa.free(ys);
    blockEdges(xs, src_w, dst_w);
    blockEdges(ys, src_h, dst_h);

    switch (ch) {
        inline 3, 4 => |c| if (oriented)
            resizeLoop(c, true, src, src_w, xs, ys, orient, dst_w, dst_h, out_w, out_h, out)
        else
            resizeLoop(c, false, src, src_w, xs, ys, orient, dst_w, dst_h, out_w, out_h, out),
        else => unreachable,
    }
}

/// `edges[2i]`, `edges[2i + 1]` = [inizio, fine) del blocco sorgente della cella i.
fn blockEdges(edges: []usize, src_n: usize, dst_n: usize) void {
    for (0..dst_n) |i| {
        const a = i * src_n / dst_n;
        edges[2 * i] = a;
        edges[2 * i + 1] = @max(a + 1, (i + 1) * src_n / dst_n);
    }
}

fn resizeLoop(
    comptime ch: usize,
    comptime oriented: bool,
    src: [*]const u8,
    src_w: usize,
    xs: []const usize,
    ys: []const usize,
    orient: u8,
    dst_w: usize,
    dst_h: usize,
    out_w: usize,
    out_h: usize,
    out: []u8,
) void {
    for (0..out_h) |oy| {
        for (0..out_w) |ox| {
            const sp = if (oriented) exif.srcCoord(orient, dst_w, dst_h, ox, oy) else [2]usize{ ox, oy };
            const x0 = xs[2 * sp[0]];
            const x1 = xs[2 * sp[0] + 1];
            const y0 = ys[2 * sp[1]];
            const y1 = ys[2 * sp[1] + 1];
            var sum = [3]u64{ 0, 0, 0 };
            for (y0..y1) |sy| {
                const row = src + sy * src_w * ch;
                for (x0..x1) |sx| {
                    const s = row + sx * ch;
                    if (ch == 4 and s[3] != 255) {
                        // Composizione su bianco: c·a + 255·(255−a), in unità 1/255.
                        const a: u64 = s[3];
                        inline for (0..3) |c| sum[c] += (@as(u64, s[c]) * a + 255 * (255 - a) + 127) / 255;
                    } else {
                        inline for (0..3) |c| sum[c] += s[c];
                    }
                }
            }
            const count: u64 = @intCast((y1 - y0) * (x1 - x0));
            const d = (oy * out_w + ox) * 3;
            inline for (0..3) |c| out[d + c] = divCount(sum[c], count);
        }
    }
}

/// `sum / count` (troncata), con la divisione a 64 bit solo dove serve: i blocchi
/// di una riduzione sotto 2× sono 1×1, 1×2, 2×1 o 2×2 (potenze di due: uno shift).
inline fn divCount(sum: u64, count: u64) u8 {
    if (count & (count - 1) == 0) return @intCast(sum >> @intCast(@ctz(count)));
    if (sum <= std.math.maxInt(u32) and count <= std.math.maxInt(u32))
        return @intCast(@as(u32, @intCast(sum)) / @as(u32, @intCast(count)));
    return @intCast(sum / count);
}

// ── Test ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// L'implementazione per-pixel di prima (riferimento dei test).
fn reference(src: [*]const u8, ch: usize, src_w: usize, src_h: usize, orient: u8, dst_w: usize, dst_h: usize, out: []u8) void {
    const swap = orient >= 5 and orient <= 8;
    const out_w = if (swap) dst_h else dst_w;
    const out_h = if (swap) dst_w else dst_h;
    for (0..out_h) |oy| {
        for (0..out_w) |ox| {
            const sp = exif.srcCoord(orient, dst_w, dst_h, ox, oy);
            const dx = sp[0];
            const dy = sp[1];
            const y0 = dy * src_h / dst_h;
            const y1 = @max(y0 + 1, (dy + 1) * src_h / dst_h);
            const x0 = dx * src_w / dst_w;
            const x1 = @max(x0 + 1, (dx + 1) * src_w / dst_w);
            var sum = [3]u64{ 0, 0, 0 };
            for (y0..y1) |sy| {
                for (x0..x1) |sx| {
                    const s = (sy * src_w + sx) * ch;
                    if (ch == 4 and src[s + 3] != 255) {
                        const a: u64 = src[s + 3];
                        inline for (0..3) |c| sum[c] += (@as(u64, src[s + c]) * a + 255 * (255 - a) + 127) / 255;
                    } else {
                        inline for (0..3) |c| sum[c] += src[s + c];
                    }
                }
            }
            const count: u64 = @intCast((y1 - y0) * (x1 - x0));
            const d = (oy * out_w + ox) * 3;
            inline for (0..3) |c| out[d + c] = @intCast(sum[c] / count);
        }
    }
}

fn expectSame(gpa: std.mem.Allocator, src: []const u8, ch: usize, sw: usize, sh: usize, orient: u8, dw: usize, dh: usize) !void {
    const want = try gpa.alloc(u8, dw * dh * 3);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, dw * dh * 3);
    defer gpa.free(got);
    reference(src.ptr, ch, sw, sh, orient, dw, dh, want);
    try boxResize(gpa, src.ptr, ch, sw, sh, orient, dw, dh, got);
    testing.expectEqualSlices(u8, want, got) catch |e| {
        std.debug.print("diverso: ch={d} {d}x{d} → {d}x{d} orient={d}\n", .{ ch, sw, sh, dw, dh, orient });
        return e;
    };
}

test "boxResize: stessi byte dell'implementazione per-pixel (scale, orientamenti, alpha)" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5a7e);
    const rnd = prng.random();
    for (0..400) |iter| {
        const ch: usize = if (iter % 2 == 0) 3 else 4;
        const sw = rnd.intRangeAtMost(usize, 1, 97);
        const sh = rnd.intRangeAtMost(usize, 1, 97);
        const src = try gpa.alloc(u8, sw * sh * ch);
        defer gpa.free(src);
        rnd.bytes(src);
        // Alpha: un quarto dei casi tutto opaco, uno solo 0 e 255, il resto casuale.
        if (ch == 4) for (0..sw * sh) |i| {
            src[i * 4 + 3] = switch (iter % 8) {
                1 => 255,
                3 => if (rnd.boolean()) 255 else 0,
                else => src[i * 4 + 3],
            };
        };
        const orient: u8 = @intCast(iter % 9); // 0..8: 0 vale come 1
        // 1:1, riduzioni piccole e forti, fino a 1×1.
        const dims = [_][2]usize{ .{ sw, sh }, .{ @max(1, sw * 2 / 3), @max(1, sh * 2 / 3) }, .{ rnd.intRangeAtMost(usize, 1, sw), rnd.intRangeAtMost(usize, 1, sh) }, .{ 1, 1 } };
        for (dims) |d| try expectSame(gpa, src, ch, sw, sh, orient, d[0], d[1]);
    }
}

test "boxResize: blocchi larghi, conteggi che non sono potenze di due" {
    const gpa = testing.allocator;
    const sw = 1000;
    const sh = 3;
    const src = try gpa.alloc(u8, sw * sh * 3);
    defer gpa.free(src);
    for (src, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    for ([_]usize{ 1, 3, 7, 333, 999 }) |dw| try expectSame(gpa, src, 3, sw, sh, 1, dw, 1);
}

test "boxResize: sorgenti di una riga o di una colonna, tutti gli orientamenti" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1b1);
    const rnd = prng.random();
    for ([_][2]usize{ .{ 1, 97 }, .{ 97, 1 }, .{ 1, 1 } }) |sz| {
        for ([_]usize{ 3, 4 }) |ch| {
            const src = try gpa.alloc(u8, sz[0] * sz[1] * ch);
            defer gpa.free(src);
            rnd.bytes(src);
            for (0..9) |o| {
                const orient: u8 = @intCast(o);
                for ([_]usize{ 1, 2 }) |div| {
                    const dw = @max(1, sz[0] / div);
                    const dh = @max(1, sz[1] / div);
                    try expectSame(gpa, src, ch, sz[0], sz[1], orient, dw, dh);
                }
                try expectSame(gpa, src, ch, sz[0], sz[1], orient, 1, 1);
            }
        }
    }
}

test "divCount: come sum / count, anche oltre i 32 bit" {
    const max32: u64 = std.math.maxInt(u32);
    const counts = [_]u64{ 1, 2, 3, 4, 5, 7, 8, 9, 255, 256, 257, 65535, 65536, 65537, max32 - 1, max32, max32 + 1, 1 << 33 };
    for (counts) |count| {
        // Le somme possibili: fino a 255 per elemento del blocco.
        const sums = [_]u64{ 0, 1, count - 1, count, 255 * count / 2, 255 * count - 1, 255 * count };
        for (sums) |sum| {
            if (sum / count > 255) continue;
            try testing.expectEqual(@as(u8, @intCast(sum / count)), divCount(sum, count));
        }
    }
    // Somma oltre i 32 bit con un conteggio che non è una potenza di due: il ramo a 64 bit.
    const big_sum = max32 + 1;
    const big_count = big_sum / 255 + 1;
    try testing.expectEqual(@as(u8, @intCast(big_sum / big_count)), divCount(big_sum, big_count));
}
