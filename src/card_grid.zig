//! Griglie di card degli overlay (YouTube, esplora file): dove stanno le righe e
//! come si aggancia lo scroll. Lo scroll è `zicro.scroll.Scroll`, lo stesso del
//! testo: passo e easing della rotella, scrollbar flottante, drag del thumb. Qui
//! c'è solo la geometria che gli serve e il tempo tra un disegno e l'altro.

const std = @import("std");
const zscroll = @import("zicro").scroll;

/// Geometria di una griglia: righe alte `card_h` separate da `gap`, mostrate in
/// una banda alta `vis_rows` righe che parte da `grid_y`. La scrollbar sta sul
/// bordo destro della banda, a `right`.
pub const Geom = struct {
    grid_x: i32,
    grid_y: i32,
    right: i32,
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
};

/// Lo scroll di una griglia: lo `Scroll` di zicro più l'istante dell'ultimo tick
/// (gli overlay si ridisegnano a frame rate variabile).
pub const GridScroll = struct {
    sc: zscroll.Scroll = .{},
    last_ms: i64 = 0,

    pub fn reset(s: *GridScroll) void {
        s.* = .{};
    }

    /// Scroll corrente in pixel.
    pub fn pos(s: *const GridScroll) f32 {
        return s.sc.scrollY();
    }

    /// Allinea viewport e contenuto dello `Scroll` alla geometria di adesso: va
    /// chiamata prima di passargli input o di disegnarlo.
    pub fn sync(s: *GridScroll, g: Geom) void {
        s.sc.setViewport(.{
            .x = @floatFromInt(g.grid_x),
            .y = @floatFromInt(g.grid_y),
            .w = @floatFromInt(g.right - g.grid_x),
            .h = @floatFromInt(g.bandH()),
        });
        s.sc.setContent(@floatFromInt(g.right - g.grid_x), @floatFromInt(g.contentH()));
    }

    /// Puntatore mosso: hover e drag della scrollbar. `consumed` = il moto è
    /// della scrollbar (niente hover sulle card); `redraw` = serve un frame.
    pub fn onMotion(s: *GridScroll, g: Geom, x: f32, y: f32) struct { consumed: bool, redraw: bool } {
        s.sync(g);
        const area = s.sc.in_area;
        const bar = s.sc.over_bar;
        const consumed = s.sc.onMotion(x, y);
        const changed = area != s.sc.in_area or bar[0] != s.sc.over_bar[0] or bar[1] != s.sc.over_bar[1];
        return .{ .consumed = consumed, .redraw = consumed or changed };
    }

    /// Tasto sinistro premuto: true se ha preso la scrollbar (inizio drag).
    pub fn onPress(s: *GridScroll, g: Geom, x: f32, y: f32) bool {
        s.sync(g);
        return s.sc.onButtonDown(x, y);
    }

    /// Tasto rilasciato (o overlay chiuso): fine dell'eventuale drag.
    pub fn onRelease(s: *GridScroll) bool {
        return s.sc.onButtonUp();
    }

    /// Porta la riga `row` tutta dentro la banda (selezione da tastiera).
    pub fn revealRow(s: *GridScroll, g: Geom, row: i32) void {
        s.sync(g);
        const top: f32 = @floatFromInt(row * g.pitch());
        s.sc.reveal(.vertical, top, top + @as(f32, @floatFromInt(g.card_h)));
    }

    /// Avanza easing e dissolvenze della scrollbar all'istante `now_ms`.
    /// Ritorna true se serve un altro frame.
    pub fn tick(s: *GridScroll, g: Geom, now_ms: i64) bool {
        s.sync(g);
        const dt: f32 = if (s.last_ms == 0) 1.0 / 60.0 else std.math.clamp(@as(f32, @floatFromInt(now_ms - s.last_ms)) / 1000.0, 0, 0.1);
        const more = s.sc.tick(dt);
        s.last_ms = if (!more) 0 else if (now_ms == 0) 1 else now_ms;
        return more;
    }

    /// Prima riga almeno in parte visibile.
    pub fn topRow(s: *const GridScroll, g: Geom) i32 {
        return @intFromFloat(@floor(s.pos() / @as(f32, @floatFromInt(@max(g.pitch(), 1)))));
    }
};

const test_geom: Geom = .{ .grid_x = 0, .grid_y = 100, .right = 400, .card_h = 90, .gap = 10, .total_rows = 10, .vis_rows = 3 };

test "geom: banda e contenuto" {
    try std.testing.expectEqual(@as(i32, 290), test_geom.bandH());
    try std.testing.expectEqual(@as(i32, 990), test_geom.contentH());
}

test "rowY: le righe a metà restano, quelle fuori banda no" {
    try std.testing.expectEqual(@as(?i32, 100), test_geom.rowY(0, 0));
    try std.testing.expectEqual(@as(?i32, 55), test_geom.rowY(45, 0)); // tagliata in alto
    try std.testing.expectEqual(@as(?i32, null), test_geom.rowY(100, 0)); // uscita del tutto
    try std.testing.expectEqual(@as(?i32, 355), test_geom.rowY(45, 3)); // spunta dal fondo
    try std.testing.expectEqual(@as(?i32, null), test_geom.rowY(0, 3));
}

test "GridScroll: la rotella e il reveal passano dallo Scroll di zicro" {
    var s: GridScroll = .{};
    s.sync(test_geom);
    s.sc.wheel(.vertical, 15);
    var now: i64 = 1000;
    while (s.tick(test_geom, now)) now += 16;
    try std.testing.expectApproxEqAbs(15 * zscroll.wheel_gain, s.pos(), 0.01);
    s.revealRow(test_geom, 9); // ultima riga: lo scroll arriva in fondo
    while (s.tick(test_geom, now)) now += 16;
    try std.testing.expectApproxEqAbs(@as(f32, 990 - 290), s.pos(), 0.01);
    try std.testing.expectEqual(@as(i32, 7), s.topRow(test_geom));
}
