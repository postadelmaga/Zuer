//! Lo scrim (sfumatura scura) sotto i controlli del video. In un file a sé perché
//! dipende solo dal `paint` di zicro: così il suo test entra in `zig build test`.

const std = @import("std");
const paint = @import("zicro").paint;

/// Scrim dei controlli: sfuma da trasparente a scuro verso il basso, una riga alla
/// volta e senza sovrapposizioni (sul piano dmabuf una riga coperta due volte
/// diventava una striscia più scura). Ogni riga ha un colore solo: con il buffer
/// trasparente sotto (`under_clear`) il risultato è un pixel ripetuto, composto
/// una volta con la stessa routine e copiato — era ~12 ms per disegno dei
/// controlli a 1280 px, il grosso del loro costo sul piano dmabuf. Sopra un frame
/// video si compone pixel per pixel (col clip alla riga: senza, `fillRoundedRect`
/// visita anche le righe di antialiasing sopra e sotto).
pub fn draw(canvas: *paint.Canvas, px: []u32, W: u32, H: u32, rows: u32, a: f32, under_clear: bool) void {
    const y_top = H - rows;
    if (under_clear) {
        var one_px = [1]u32{0};
        var one = paint.Canvas.initRgba8(&one_px, 1, 1);
        var i: u32 = 0;
        while (i < rows) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rows));
            one_px[0] = 0;
            one.fillRoundedRect(0, 0, 1, 1, 0, paint.Color.rgba(0, 0, 0, 0.55 * t * t * a));
            const row = @as(usize, y_top + i) * W;
            @memset(px[row .. row + W], one_px[0]);
        }
        return;
    }
    const saved_clip = canvas.clip;
    var i: u32 = 0;
    while (i < rows) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rows));
        _ = canvas.setClip(0, y_top + i, W, 1);
        canvas.fillRoundedRect(0, @floatFromInt(y_top + i), @floatFromInt(W), 1, 0, paint.Color.rgba(0, 0, 0, 0.55 * t * t * a));
    }
    canvas.clip = saved_clip;
}

test "scrim dei controlli: per righe su buffer trasparente = composto pixel per pixel" {
    const W: u32 = 333;
    const H: u32 = 140;
    const gpa = std.testing.allocator;
    for ([_]f32{ 1.0, 0.6, 0.13 }) |a| {
        const ref = try gpa.alloc(u32, W * H);
        defer gpa.free(ref);
        const got = try gpa.alloc(u32, W * H);
        defer gpa.free(got);
        @memset(ref, 0);
        @memset(got, 0);
        var c1 = paint.Canvas.initRgba8(ref, W, H);
        var c2 = paint.Canvas.initRgba8(got, W, H);
        draw(&c1, ref, W, H, 97, a, false);
        draw(&c2, got, W, H, 97, a, true);
        try std.testing.expectEqualSlices(u32, ref, got);
        // Non banale: lo scrim ha davvero scritto qualcosa.
        try std.testing.expect(ref[(H - 1) * W] != 0);
    }
}
