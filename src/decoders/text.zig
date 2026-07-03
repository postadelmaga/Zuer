const std = @import("std");
const Decoded = @import("../decoder.zig").Decoded;

pub fn decode(bytes: []const u8, allocator: std.mem.Allocator) Decoded {
    // Check if the file is binary. A simple heuristic: count null bytes or non-printable chars.
    var null_count: usize = 0;
    for (bytes) |b| {
        if (b == 0) {
            null_count += 1;
        }
    }

    if (null_count > 0 or !std.unicode.utf8ValidateSlice(bytes)) {
        // If it's not valid UTF-8, return an error.
        allocator.free(bytes);
        const msg = allocator.dupe(u8, "Formato non riconosciuto o file binario non UTF-8.") catch "File binario non supportato";
        return .{ .err = msg };
    }

    return .{ .text = bytes };
}
