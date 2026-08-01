const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;
const DecodedC = decoder.DecodedC;

fn sanitizeToUtf8(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0) {
            try out.append(allocator, ' ');
            i += 1;
        } else if (b < 0x80) {
            try out.append(allocator, b);
            i += 1;
        } else {
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 0;
            if (seq_len > 0 and i + seq_len <= bytes.len) {
                if (std.unicode.utf8ValidateSlice(bytes[i .. i + seq_len])) {
                    try out.appendSlice(allocator, bytes[i .. i + seq_len]);
                    i += seq_len;
                    continue;
                }
            }
            const c1: u8 = 0xC0 | (b >> 6);
            const c2: u8 = 0x80 | (b & 0x3F);
            try out.appendSlice(allocator, &.{ c1, c2 });
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn decode(bytes: []const u8, allocator: std.mem.Allocator) Decoded {
    if (!std.mem.containsAtLeast(u8, bytes, 1, &.{0}) and std.unicode.utf8ValidateSlice(bytes)) {
        return .{ .markdown = .{ .content = bytes } };
    }

    const sanitized = sanitizeToUtf8(bytes, allocator) catch {
        allocator.free(bytes);
        return .{ .err = "Markdown non in formato UTF-8 valido." };
    };
    allocator.free(bytes);
    return .{ .markdown = .{ .content = sanitized } };
}

fn zuer_decode(
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

pub const extensions = "md,markdown";

fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// Versione dell'ABI plugin con cui questo decoder è compilato: l'host la
/// confronta con la propria `decoder.abi_version` e scarta i mismatch.
fn zuer_abi_version() callconv(.c) u32 {
    return decoder.abi_version;
}

// Gli export dell'ABI plugin esistono solo dove i decoder SONO plugin (vedi
// decoder.plugin_abi): su Android sono linkati dentro l'unica libreria dell'APK e i loro
// nomi colliderebbero.
comptime {
    if (decoder.plugin_abi) {
        @export(&zuer_decode, .{ .name = "zuer_decode", .linkage = .strong });
        @export(&zuer_extensions, .{ .name = "zuer_extensions", .linkage = .strong });
        @export(&zuer_abi_version, .{ .name = "zuer_abi_version", .linkage = .strong });
    }
}
