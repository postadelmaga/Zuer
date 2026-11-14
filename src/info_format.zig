//! Formattazione dei valori della scheda informazioni (`info_popup.zig`), all'italiana:
//! migliaia col punto, decimali con la virgola, nomi lunghi accorciati nel mezzo.
//! Funzioni pure, senza dipendenze dalla GUI (testate da `zig build test`).

const std = @import("std");

/// Intero con i punti delle migliaia, all'italiana: 1.234.567.
pub fn grouped(buf: []u8, v: u64) []const u8 {
    var tmp: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return "?";
    var o: usize = 0;
    for (digits, 0..) |ch, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) {
            buf[o] = '.';
            o += 1;
        }
        buf[o] = ch;
        o += 1;
    }
    return buf[0..o];
}

/// Un decimale con la virgola (2,4); senza decimale da 100 in su.
pub fn decimal(buf: []u8, v: f64) []const u8 {
    if (v >= 100) return std.fmt.bufPrint(buf, "{d}", .{@as(u64, @intFromFloat(@round(v)))}) catch "?";
    const s = std.fmt.bufPrint(buf, "{d:.1}", .{v}) catch return "?";
    if (std.mem.indexOfScalar(u8, s, '.')) |i| buf[i] = ',';
    return s;
}

/// Peso in unità decimali (come Finder e i file manager): 2,4 MB.
pub fn humanSize(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "kB", "MB", "GB", "TB" };
    var v: f64 = @as(f64, @floatFromInt(n)) / 1000.0;
    var u: usize = 0;
    while (v >= 1000.0 and u < units.len - 1) : (u += 1) v /= 1000.0;
    var num: [16]u8 = undefined;
    const d = decimal(&num, v);
    return std.fmt.bufPrint(buf, "{s} {s}", .{ d, units[u] }) catch "?";
}

/// Lunghezza del prefisso di `s` che finisce su un carattere UTF-8 intero.
pub fn utf8Floor(s: []const u8) usize {
    var i = s.len;
    while (i > 0 and (s[i - 1] & 0xC0) == 0x80) i -= 1;
    if (i == 0) return 0;
    const lead = s[i - 1];
    const need: usize = std.unicode.utf8ByteSequenceLength(lead) catch return i - 1;
    return if (s.len - (i - 1) >= need) s.len else i - 1;
}

/// `s` in al più `cols` caratteri: se è più lungo, con "…" in mezzo (il nome di un
/// file conta all'inizio e alla fine, dove c'è l'estensione).
pub fn ellipsize(buf: []u8, s: []const u8, cols: usize) []const u8 {
    const n = std.unicode.utf8CountCodepoints(s) catch return s;
    if (n <= cols or cols < 5) return s;
    const keep_tail = (cols - 1) / 2;
    const keep_head = cols - 1 - keep_tail;
    const head_end = cpOffset(s, keep_head);
    const tail_start = cpOffset(s, n - keep_tail);
    const ell = "…";
    if (head_end + ell.len + (s.len - tail_start) > buf.len) return s[0..head_end];
    @memcpy(buf[0..head_end], s[0..head_end]);
    @memcpy(buf[head_end..][0..ell.len], ell);
    @memcpy(buf[head_end + ell.len ..][0 .. s.len - tail_start], s[tail_start..]);
    return buf[0 .. head_end + ell.len + s.len - tail_start];
}

/// Offset in byte del `cp`-esimo carattere di `s`.
fn cpOffset(s: []const u8, cp: usize) usize {
    var i: usize = 0;
    var k: usize = 0;
    while (i < s.len and k < cp) : (k += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(@as(usize, len), s.len - i);
    }
    return i;
}

test "grouped e decimal all'italiana" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.234.567", grouped(&b, 1234567));
    try std.testing.expectEqualStrings("999", grouped(&b, 999));
    try std.testing.expectEqualStrings("2,4", decimal(&b, 2.4));
    try std.testing.expectEqualStrings("2,4 MB", humanSize(&b, 2_400_000));
}
test "ellipsize tiene inizio e fine" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abc…xyz", ellipsize(&b, "abcdefghijklmnopqrstuvwxyz", 7));
    try std.testing.expectEqualStrings("corto.txt", ellipsize(&b, "corto.txt", 20));
}
