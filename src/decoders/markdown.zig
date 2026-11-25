const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;
const DecodedC = decoder.DecodedC;

fn needsSanitization(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0x1B or b < 0x20 or b == 0x7F) {
            if (b == '\n' or b == '\t') {
                i += 1;
                continue;
            }
            return true;
        }
        if (b >= 0x80) {
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch return true;
            if (seq_len == 0 or i + seq_len > bytes.len) return true;
            if (!std.unicode.utf8ValidateSlice(bytes[i .. i + seq_len])) return true;
            i += seq_len;
            continue;
        }
        i += 1;
    }
    return false;
}

fn sanitizeToUtf8(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];

        if (b == 0x1B) {
            if (i + 1 < bytes.len) {
                const next = bytes[i + 1];
                if (next == '[') {
                    var j: usize = i + 2;
                    while (j < bytes.len) : (j += 1) {
                        const cb = bytes[j];
                        if (cb >= 0x40 and cb <= 0x7E) {
                            j += 1;
                            break;
                        }
                        if (cb < 0x20 or cb > 0x7E) {
                            break;
                        }
                    }
                    i = j;
                    continue;
                } else if (next == ']') {
                    var j: usize = i + 2;
                    while (j < bytes.len) : (j += 1) {
                        if (bytes[j] == 0x07) {
                            j += 1;
                            break;
                        }
                        if (bytes[j] == 0x1B and j + 1 < bytes.len and bytes[j + 1] == '\\') {
                            j += 2;
                            break;
                        }
                    }
                    i = j;
                    continue;
                } else if (next >= 0x40 and next <= 0x5F) {
                    i += 2;
                    continue;
                }
            }
            i += 1;
            continue;
        }

        if (b < 0x20) {
            if (b == '\n' or b == '\t') {
                try out.append(allocator, b);
            } else if (b == '\r') {
                if (i + 1 >= bytes.len or bytes[i + 1] != '\n') {
                    try out.append(allocator, '\n');
                }
            }
            i += 1;
            continue;
        }

        if (b == 0x7F) {
            i += 1;
            continue;
        }

        if (b < 0x80) {
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
    if (!needsSanitization(bytes)) {
        return .{ .markdown = .{ .content = bytes } };
    }

    const sanitized = sanitizeToUtf8(bytes, allocator) catch {
        allocator.free(bytes);
        return decoder.pluginError(allocator, "Markdown non in formato UTF-8 valido.", .{});
    };
    allocator.free(bytes);
    return .{ .markdown = .{ .content = sanitized } };
}

pub const plugin_name = "markdown";

pub fn pluginDecode(req: decoder.PluginRequest) decoder.Decoded {
    return decode(req.content, req.allocator);
}

comptime {
    decoder.exportPlugin(@This());
}

test "decode: nessuna perdita se un'allocazione fallisce" {
    const Case = struct {
        fn run(text: []const u8, a: std.mem.Allocator) void {
            // `decode` prende possesso dei byte, come nel plugin.
            const bytes = a.dupe(u8, text) catch return;
            var d = decode(bytes, a);
            d.deinit(a);
        }
    };
    try decoder.expectNoLeakOnAllocFailure(@as([]const u8, "# Titolo\n\ntesto *pulito*\n"), Case.run);
    try decoder.expectNoLeakOnAllocFailure(@as([]const u8, "# byte non validi \xff\xfe\n\ne un \xc3\x28\n"), Case.run);
    try decoder.expectNoLeakOnAllocFailure(@as([]const u8, ""), Case.run);
}
