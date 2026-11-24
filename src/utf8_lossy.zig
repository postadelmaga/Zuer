//! UTF-8 che può non essere valido: il testo di un documento rotto, il nome di un
//! file su Linux. `std.unicode.Utf8View.initUnchecked` + `nextCodepoint` su byte
//! non validi arriva a `unreachable` (panic in ReleaseSafe, lettura oltre il
//! buffer in ReleaseFast): dove il testo viene da fuori si itera con questo.

const std = @import("std");

pub const replacement: u21 = 0xFFFD;

/// Itera i codepoint; ogni byte che non apre una sequenza valida diventa U+FFFD.
pub const Iterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn next(self: *Iterator) ?u21 {
        if (self.i >= self.bytes.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch return self.bad();
        if (self.i + n > self.bytes.len) return self.bad();
        const cp = std.unicode.utf8Decode(self.bytes[self.i..][0..n]) catch return self.bad();
        self.i += n;
        return cp;
    }

    fn bad(self: *Iterator) u21 {
        self.i += 1;
        return replacement;
    }
};

/// Il codepoint di `bytes` se è esattamente UNA sequenza valida, altrimenti null.
/// `std.unicode.utf8Decode` da sola non basta: su una sequenza tagliata dalla fine
/// del testo (byte iniziale da 3, slice da 2) non dà errore, arriva a un `assert`.
pub fn decode(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (n != bytes.len) return null;
    return std.unicode.utf8Decode(bytes) catch null;
}

pub fn iterate(bytes: []const u8) Iterator {
    return .{ .bytes = bytes };
}

/// Copia di `bytes` con ogni byte non valido sostituito da U+FFFD, o null se
/// `bytes` è già UTF-8 valido (il caso normale: nessuna allocazione).
pub fn sanitized(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, bytes.len + 16);
    var it = iterate(bytes);
    var buf: [4]u8 = undefined;
    while (it.next()) |cp| {
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable; // cp viene da utf8Decode o è U+FFFD
        try out.appendSlice(allocator, buf[0..n]);
    }
    return try out.toOwnedSlice(allocator);
}

test "testo valido: stessi codepoint, nessuna copia" {
    var it = iterate("aè€😀");
    try std.testing.expectEqual(@as(?u21, 'a'), it.next());
    try std.testing.expectEqual(@as(?u21, 0xE8), it.next());
    try std.testing.expectEqual(@as(?u21, 0x20AC), it.next());
    try std.testing.expectEqual(@as(?u21, 0x1F600), it.next());
    try std.testing.expectEqual(@as(?u21, null), it.next());
    try std.testing.expectEqual(@as(?[]u8, null), try sanitized(std.testing.allocator, "aè€😀"));
}

test "decode: una sequenza intera o niente" {
    try std.testing.expectEqual(@as(?u21, 0x20AC), decode("\xe2\x82\xac"));
    try std.testing.expectEqual(@as(?u21, 'a'), decode("a"));
    try std.testing.expectEqual(@as(?u21, null), decode("\xe2\x82")); // tagliata
    try std.testing.expectEqual(@as(?u21, null), decode("\xf0\x9f\x98")); // tagliata
    try std.testing.expectEqual(@as(?u21, null), decode("\x80")); // continuazione orfana
    try std.testing.expectEqual(@as(?u21, null), decode("ab")); // due sequenze
    try std.testing.expectEqual(@as(?u21, null), decode(""));
}

test "byte non validi diventano U+FFFD, uno per byte" {
    // 0xFF isolato, sequenza troncata a fine buffer, continuazione orfana, surrogato.
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "a\xffb", .out = "a\u{FFFD}b" },
        .{ .in = "a\xe2\x82", .out = "a\u{FFFD}\u{FFFD}" },
        .{ .in = "\x80x", .out = "\u{FFFD}x" },
        .{ .in = "\xed\xa0\x80", .out = "\u{FFFD}\u{FFFD}\u{FFFD}" },
        .{ .in = "\xf0\x9f", .out = "\u{FFFD}\u{FFFD}" },
    };
    for (cases) |c| {
        const got = (try sanitized(std.testing.allocator, c.in)).?;
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(c.out, got);
        try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    }
}
