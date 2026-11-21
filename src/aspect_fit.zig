//! Adattamento di un contenuto (immagine, pagina, video) a un'area mantenendo le
//! proporzioni. Un solo calcolo per comporre il frame, per il mouse (pan, zoom al
//! 100%, rotella sui PDF), per la finestra che segue lo zoom e per il video. Prima
//! c'erano sette copie con arrotondamenti diversi: lo zoom al 100% usciva spesso un
//! pixel più piccolo dell'originale (quindi ricampionato, sfocato) e un PDF a
//! schermo intero un pixel più stretto della finestra.

const std = @import("std");

/// Taglia del contenuto adattato all'area, non arrotondata: il lato che tocca il
/// bordo vale esattamente quello dell'area, l'altro segue le proporzioni della
/// sorgente. null se una dimensione è zero.
pub fn size(src_w: u32, src_h: u32, area_w: f32, area_h: f32) ?[2]f32 {
    if (src_w == 0 or src_h == 0 or !(area_w > 0) or !(area_h > 0)) return null;
    const sa = @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(src_h));
    return if (sa > area_w / area_h) .{ area_w, area_w / sa } else .{ area_h * sa, area_h };
}

/// `size` per un'area in pixel interi.
pub fn sizePx(src_w: u32, src_h: u32, area_w: u32, area_h: u32) ?[2]f32 {
    return size(src_w, src_h, @floatFromInt(area_w), @floatFromInt(area_h));
}

/// Taglia in pixel interi del contenuto adattato `fit` con lo zoom `zoom`:
/// arrotondata, almeno 1. A zoom 1 è `fit` arrotondata; col fattore del 100%
/// (`src_w / fit[0]`) è esattamente la taglia della sorgente, e col fattore della
/// larghezza piena (`area_w / fit[0]`) esattamente la larghezza dell'area.
pub fn pixels(fit: [2]f32, zoom: f32) [2]u32 {
    return .{ px(fit[0] * zoom), px(fit[1] * zoom) };
}

fn px(v: f32) u32 {
    // Prima del cast: uno zoom enorme non deve far traboccare u32 (né un NaN passare).
    return @intFromFloat(std.math.clamp(@round(v), 1, 1 << 24));
}

// ── Test ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "zoom 1: come la composizione di prima, lato pieno esatto" {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    for (0..200_000) |_| {
        const sw = r.intRangeAtMost(u32, 1, 9000);
        const sh = r.intRangeAtMost(u32, 1, 9000);
        const W = r.intRangeAtMost(u32, 1, 4000);
        const H = r.intRangeAtMost(u32, 1, 4000);
        // La formula di compose.composeImage prima di questo modulo, a zoom 1.
        const sa = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(sh));
        const wa = @as(f32, @floatFromInt(W)) / @as(f32, @floatFromInt(H));
        var old: [2]u32 = .{ W, H };
        if (sa > wa) old[1] = @intFromFloat(@round(@as(f32, @floatFromInt(W)) / sa)) else old[0] = @intFromFloat(@round(@as(f32, @floatFromInt(H)) * sa));
        old = .{ @max(old[0], 1), @max(old[1], 1) };
        const got = pixels(sizePx(sw, sh, W, H).?, 1);
        try testing.expectEqual(old, got);
        try testing.expect(got[0] == W or got[1] == H);
    }
}

test "100% e larghezza piena: taglie esatte" {
    var prng = std.Random.DefaultPrng.init(2);
    const r = prng.random();
    for (0..200_000) |_| {
        const sw = r.intRangeAtMost(u32, 16, 9000);
        const sh = r.intRangeAtMost(u32, 16, 9000);
        const W = r.intRangeAtMost(u32, 200, 3840);
        const H = r.intRangeAtMost(u32, 150, 2160);
        const fit = sizePx(sw, sh, W, H).?;
        // Doppio click: 1:1, nessun pixel ricampionato.
        try testing.expectEqual([2]u32{ sw, sh }, pixels(fit, @as(f32, @floatFromInt(sw)) / fit[0]));
        // PDF a schermo intero: larga quanto l'area.
        const wf = @max(1.0, @as(f32, @floatFromInt(W)) / fit[0]);
        try testing.expectEqual(W, pixels(fit, wf)[0]);
    }
}

test "casi limite" {
    try testing.expect(size(0, 10, 100, 100) == null);
    try testing.expect(size(10, 0, 100, 100) == null);
    try testing.expect(size(10, 10, 0, 100) == null);
    try testing.expect(size(10, 10, std.math.nan(f32), 100) == null);
    // Sorgente sottilissima: almeno 1 pixel.
    try testing.expectEqual([2]u32{ 1, 600 }, pixels(sizePx(1, 100_000, 800, 600).?, 1));
    // Zoom enorme o NaN: niente panic.
    _ = pixels(sizePx(4000, 3000, 800, 600).?, 1e30);
    _ = pixels(sizePx(4000, 3000, 800, 600).?, std.math.nan(f32));
}
