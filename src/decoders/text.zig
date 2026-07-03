const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;
const DecodedC = decoder.DecodedC;

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

export fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) DecodedC {
    _ = path;
    _ = io_ptr;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const decoded = decode(content.toSlice(), allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}
