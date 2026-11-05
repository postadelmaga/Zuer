//! Scroll in pixel delle griglie di card degli overlay (YouTube, esplora file).
//! Il passo della rotella e l'easing sono quelli di zicro (`zicro.scroll`), così
//! queste griglie scorrono come ogni altra superficie dello stack: le card a metà
//! escono tagliate dai bordi della banda, la scrollbar si trascina 1:1.

const std = @import("std");
const zscroll = @import("zicro").scroll;

/// Geometria verticale di una griglia: righe alte `card_h` separate da `gap`,
/// mostrate in una banda alta `vis_rows` righe che parte da `grid_y`.
pub const Geom = struct {
    grid_y: i32,
    card_h: i32,
    gap: i32,
    total_rows: i32,
    vis_rows: i32,

    /// Passo verticale tra due righe di card.
    pub fn pitch(g: Geom) i32 {
        return g.card_h + g.gap;
    }

    /// Altezza della banda visibile (le card fuori sono tagliate).
    pub fn bandH(g: Geom) i32 {
        return g.vis_rows * g.pitch() - g.gap;
    }

    /// Altezza di tutte le righe di card.
    pub fn contentH(g: Geom) i32 {
        return @max(0, g.total_rows * g.pitch() - g.gap);
    }

    /// Scroll massimo: l'ultima riga a filo del fondo della banda.
    pub fn maxScroll(g: Geom) f32 {
        return @floatFromInt(@max(0, g.contentH() - g.bandH()));
    }

    /// Y della riga `row` spostata dallo scroll `pos`, o null se nemmeno un pixel
    /// della riga cade nella banda.
    pub fn rowY(g: Geom, pos: f32, row: i32) ?i32 {
        const y = g.grid_y + row * g.pitch() - @as(i32, @intFromFloat(@round(pos)));
        if (y + g.card_h <= g.grid_y or y >= g.grid_y + g.bandH()) return null;
        return y;
    }

    /// La coordinata `y` cade nella banda? (hit-test della parte visibile)
    pub fn inBand(g: Geom, y: f32) bool {
        return y >= @as(f32, @floatFromInt(g.grid_y)) and y < @as(f32, @floatFromInt(g.grid_y + g.bandH()));
    }

    /// Posizione e altezza del thumb della scrollbar (binario `track_y`, alto `track_h`).
    pub fn thumb(g: Geom, track_y: i32, track_h: i32, pos: f32) [2]i32 {
        const th = @min(track_h, @max(@as(i32, 24), @divTrunc(track_h * g.bandH(), @max(g.contentH(), 1))));
        const frac = std.math.clamp(pos / @max(g.maxScroll(), 1.0), 0.0, 1.0);
        return .{ track_y + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(track_h - th)) * frac))), th };
    }

    /// Scroll dalla Y del mouse sul binario (il thumb si centra sul puntatore).
    pub fn scrollFromY(g: Geom, track_y: i32, track_h: i32, my: f32) f32 {
        const th = g.thumb(track_y, track_h, 0)[1];
        const span: f32 = @floatFromInt(@max(track_h - th, 1));
        const rel = (my - @as(f32, @floatFromInt(track_y))) - @as(f32, @floatFromInt(th)) / 2.0;
        return std.math.clamp(rel / span, 0.0, 1.0) * g.maxScroll();
    }
};

/// Stato dello scroll: `pos` è quello disegnato, `target` quello voluto (rotella,
/// tastiera); `pos` insegue `target` con `zicro.scroll.wheelBlend`.
pub const GridScroll = struct {
    pos: f32 = 0,
    target: f32 = 0,
    /// Istante (ms) dell'ultimo passo dell'easing; 0 = fermo.
    ms: i64 = 0,

    pub fn reset(s: *GridScroll) void {
        s.* = .{};
    }

    /// Un evento rotella in unità d'asse (positivo = giù): sposta il target del
    /// passo di zicro. Ritorna true se il target è cambiato (serve un frame).
    pub fn wheel(s: *GridScroll, g: Geom, value: f32) bool {
        const t = std.math.clamp(s.target + value * zscroll.wheel_gain, 0, g.maxScroll());
        if (t == s.target) return false;
        s.target = t;
        return true;
    }

    /// Salto senza easing (drag e click della scrollbar). True se è cambiato.
    pub fn jump(s: *GridScroll, to: f32) bool {
        if (to == s.pos and to == s.target) return false;
        s.pos = to;
        s.target = to;
        s.ms = 0;
        return true;
    }

    /// Porta la riga `row` tutta dentro la banda (selezione da tastiera).
    pub fn follow(s: *GridScroll, g: Geom, row: i32) void {
        const top: f32 = @floatFromInt(row * g.pitch());
        const bottom = top + @as(f32, @floatFromInt(g.card_h));
        const band: f32 = @floatFromInt(g.bandH());
        if (top < s.target) s.target = top;
        if (bottom > s.target + band) s.target = bottom - band;
    }

    /// Un passo dell'easing all'istante `now_ms` (90% della strada in 0.1 s, come
    /// ogni scroll dello stack). Ritorna true se serve un altro frame.
    pub fn step(s: *GridScroll, g: Geom, now_ms: i64) bool {
        const max_s = g.maxScroll();
        s.target = std.math.clamp(s.target, 0, max_s);
        const diff = s.target - s.pos;
        if (@abs(diff) < 0.5) {
            s.pos = s.target;
            s.ms = 0;
            return false;
        }
        const dt: f32 = if (s.ms == 0) 1.0 / 60.0 else std.math.clamp(@as(f32, @floatFromInt(now_ms - s.ms)) / 1000.0, 0, 0.1);
        s.ms = if (now_ms == 0) 1 else now_ms;
        s.pos = std.math.clamp(s.pos + diff * zscroll.wheelBlend(dt), 0, max_s);
        return true;
    }

    /// Prima riga almeno in parte visibile.
    pub fn topRow(s: GridScroll, g: Geom) i32 {
        return @intFromFloat(@floor(s.pos / @as(f32, @floatFromInt(@max(g.pitch(), 1)))));
    }
};

const test_geom: Geom = .{ .grid_y = 100, .card_h = 90, .gap = 10, .total_rows = 10, .vis_rows = 3 };

test "geom: banda, contenuto e scroll massimo" {
    try std.testing.expectEqual(@as(i32, 290), test_geom.bandH());
    try std.testing.expectEqual(@as(i32, 990), test_geom.contentH());
    try std.testing.expectEqual(@as(f32, 700), test_geom.maxScroll());
}

test "rowY: le righe a metà restano, quelle fuori banda no" {
    try std.testing.expectEqual(@as(?i32, 100), test_geom.rowY(0, 0));
    try std.testing.expectEqual(@as(?i32, 55), test_geom.rowY(45, 0)); // tagliata in alto
    try std.testing.expectEqual(@as(?i32, null), test_geom.rowY(100, 0)); // uscita del tutto
    try std.testing.expectEqual(@as(?i32, 355), test_geom.rowY(45, 3)); // spunta dal fondo
    try std.testing.expectEqual(@as(?i32, null), test_geom.rowY(0, 3));
}

test "wheel: il passo è quello di zicro, fermato ai bordi" {
    var s: GridScroll = .{};
    try std.testing.expect(s.wheel(test_geom, 15));
    try std.testing.expectEqual(15 * zscroll.wheel_gain, s.target);
    _ = s.wheel(test_geom, -1000);
    try std.testing.expectEqual(@as(f32, 0), s.target);
    try std.testing.expect(!s.wheel(test_geom, -15)); // già in cima
    _ = s.wheel(test_geom, 100_000);
    try std.testing.expectEqual(test_geom.maxScroll(), s.target);
}

test "step: l'easing arriva come quello di zicro e poi si ferma" {
    var s: GridScroll = .{};
    _ = s.wheel(test_geom, 15);
    var now: i64 = 1000;
    var frames: usize = 0;
    while (s.step(test_geom, now)) : (frames += 1) now += 16;
    try std.testing.expectEqual(s.target, s.pos);
    try std.testing.expectEqual(@as(i64, 0), s.ms);
    try std.testing.expect(frames > 3 and frames < 30);
}

test "follow: la riga scelta entra intera nella banda" {
    var s: GridScroll = .{};
    s.follow(test_geom, 5);
    try std.testing.expectEqual(@as(f32, 5 * 100 + 90 - 290), s.target);
    s.follow(test_geom, 1);
    try std.testing.expectEqual(@as(f32, 100), s.target);
}

test "scrollbar: thumb e drag sono inversi agli estremi" {
    const top = test_geom.thumb(100, 290, 0);
    const bot = test_geom.thumb(100, 290, test_geom.maxScroll());
    try std.testing.expectEqual(@as(i32, 100), top[0]);
    try std.testing.expectEqual(@as(i32, 100 + 290), bot[0] + bot[1]);
    try std.testing.expectEqual(@as(f32, 0), test_geom.scrollFromY(100, 290, 0));
    try std.testing.expectEqual(test_geom.maxScroll(), test_geom.scrollFromY(100, 290, 10_000));
}
