const std = @import("std");
const decoder = @import("../decoder.zig");
const MarkdownData = decoder.MarkdownData;
const Decoded = decoder.Decoded;

pub fn decode(bytes: []const u8, allocator: std.mem.Allocator) Decoded {
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        allocator.free(bytes);
        const msg = allocator.dupe(u8, "Markdown non in formato UTF-8 valido.") catch "Markdown non valido";
        return .{ .err = msg };
    }

    return .{ .markdown = .{ .content = bytes } };
}
