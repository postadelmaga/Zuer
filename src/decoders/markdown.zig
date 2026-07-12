const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;
const DecodedC = decoder.DecodedC;

pub fn decode(bytes: []const u8, allocator: std.mem.Allocator) Decoded {
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        allocator.free(bytes);
        const msg = allocator.dupe(u8, "Markdown non in formato UTF-8 valido.") catch "Markdown non valido";
        return .{ .err = msg };
    }

    return .{ .markdown = .{ .content = bytes } };
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

const extensions = "md,markdown";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// Versione dell'ABI plugin con cui questo decoder è compilato: l'host la
/// confronta con la propria `decoder.abi_version` e scarta i mismatch.
export fn zuer_abi_version() callconv(.c) u32 {
    return decoder.abi_version;
}
