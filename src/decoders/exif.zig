//! Orientamento EXIF dei JPEG: il tag Orientation (0x0112) dell'IFD0 nell'APP1
//! "Exif", e la mappa dal pixel dell'immagine orientata al pixel della sorgente.
//! Puro Zig, senza dipendenze: testato da `zig build test`.

const std = @import("std");

/// Tag Orientation (0x0112) dell'IFD0 dell'APP1 Exif di un JPEG: 1..8, 1 se assente.
pub fn orientation(b: []const u8) u8 {
    if (b.len < 4 or b[0] != 0xFF or b[1] != 0xD8) return 1;
    var i: usize = 2;
    while (i + 4 <= b.len and b[i] == 0xFF) {
        const marker = b[i + 1];
        if (marker == 0xDA or marker == 0xD9) break; // inizio dati / fine: niente Exif prima
        const len = std.mem.readInt(u16, b[i + 2 ..][0..2], .big);
        if (len < 2 or i + 2 + len > b.len) break;
        const seg = b[i + 4 .. i + 2 + len];
        if (marker == 0xE1 and seg.len >= 14 and std.mem.eql(u8, seg[0..6], "Exif\x00\x00"))
            return tiffOrientation(seg[6..]);
        i += 2 + len;
    }
    return 1;
}

fn tiffOrientation(t: []const u8) u8 {
    if (t.len < 8) return 1;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, t[0..2], "II")) .little else if (std.mem.eql(u8, t[0..2], "MM")) .big else return 1;
    if (std.mem.readInt(u16, t[2..4], endian) != 42) return 1;
    const ifd = std.mem.readInt(u32, t[4..8], endian);
    if (ifd > t.len or t.len - ifd < 2) return 1;
    const n = std.mem.readInt(u16, t[ifd..][0..2], endian);
    for (0..n) |k| {
        const e = ifd + 2 + k * 12;
        if (e + 12 > t.len) return 1;
        if (std.mem.readInt(u16, t[e..][0..2], endian) != 0x0112) continue;
        const v = std.mem.readInt(u16, t[e + 8 ..][0..2], endian);
        return if (v >= 1 and v <= 8) @intCast(v) else 1;
    }
    return 1;
}

/// Coordinate nella sorgente (w×h) del pixel (x, y) dell'immagine orientata.
pub fn srcCoord(o: u8, w: usize, h: usize, x: usize, y: usize) [2]usize {
    return switch (o) {
        2 => .{ w - 1 - x, y },
        3 => .{ w - 1 - x, h - 1 - y },
        4 => .{ x, h - 1 - y },
        5 => .{ y, x },
        6 => .{ y, h - 1 - x },
        7 => .{ w - 1 - y, h - 1 - x },
        8 => .{ w - 1 - y, x },
        else => .{ x, y },
    };
}

/// APP1 Exif minimale con il solo tag Orientation.
fn jpegWithOrientation(comptime endian: std.builtin.Endian, o: u16) [2 + 2 + 2 + 6 + 8 + 2 + 12 + 4]u8 {
    var b: [2 + 2 + 2 + 6 + 8 + 2 + 12 + 4]u8 = undefined;
    b[0] = 0xFF;
    b[1] = 0xD8;
    b[2] = 0xFF;
    b[3] = 0xE1;
    std.mem.writeInt(u16, b[4..6], b.len - 4, .big);
    @memcpy(b[6..12], "Exif\x00\x00");
    @memcpy(b[12..14], if (endian == .little) "II" else "MM");
    std.mem.writeInt(u16, b[14..16], 42, endian);
    std.mem.writeInt(u32, b[16..20], 8, endian);
    std.mem.writeInt(u16, b[20..22], 1, endian);
    std.mem.writeInt(u16, b[22..24], 0x0112, endian);
    std.mem.writeInt(u16, b[24..26], 3, endian);
    std.mem.writeInt(u32, b[26..30], 1, endian);
    std.mem.writeInt(u16, b[30..32], o, endian);
    std.mem.writeInt(u16, b[32..34], 0, endian);
    std.mem.writeInt(u32, b[34..38], 0, endian);
    return b;
}

test "orientamento EXIF: little e big endian, valori fuori scala, file non JPEG" {
    try std.testing.expectEqual(@as(u8, 6), orientation(&jpegWithOrientation(.big, 6)));
    try std.testing.expectEqual(@as(u8, 8), orientation(&jpegWithOrientation(.little, 8)));
    try std.testing.expectEqual(@as(u8, 1), orientation(&jpegWithOrientation(.little, 9)));
    try std.testing.expectEqual(@as(u8, 1), orientation("\x89PNG\r\n\x1a\n"));
    try std.testing.expectEqual(@as(u8, 1), orientation(""));
    // Troncato a metà dell'IFD: nessuna lettura fuori dai limiti.
    const full = jpegWithOrientation(.big, 6);
    for (0..full.len) |n| _ = orientation(full[0..n]);
}

test "mappa dei pixel: ogni orientamento è una permutazione della sorgente" {
    const w = 3;
    const h = 2;
    for (1..9) |o| {
        const swap = o >= 5;
        const ow: usize = if (swap) h else w;
        const oh: usize = if (swap) w else h;
        var seen: [w * h]bool = @splat(false);
        for (0..oh) |y| for (0..ow) |x| {
            const s = srcCoord(@intCast(o), w, h, x, y);
            try std.testing.expect(s[0] < w and s[1] < h);
            try std.testing.expect(!seen[s[1] * w + s[0]]);
            seen[s[1] * w + s[0]] = true;
        };
    }
    // 6 = rotazione oraria: in alto a sinistra va l'angolo in basso a sinistra.
    try std.testing.expectEqual([2]usize{ 0, h - 1 }, srcCoord(6, w, h, 0, 0));
    // 8 = antioraria: in alto a sinistra va l'angolo in alto a destra.
    try std.testing.expectEqual([2]usize{ w - 1, 0 }, srcCoord(8, w, h, 0, 0));
}
