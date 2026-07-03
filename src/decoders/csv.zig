const std = @import("std");
const decoder = @import("../decoder.zig");
const CsvData = decoder.CsvData;
const Decoded = decoder.Decoded;

pub fn decode(bytes: []const u8, delimiter: u8, allocator: std.mem.Allocator) Decoded {
    defer allocator.free(bytes);

    var rows = std.ArrayList([][]const u8).empty;
    errdefer {
        for (rows.items) |row| {
            for (row) |cell| allocator.free(cell);
            allocator.free(row);
        }
        rows.deinit(allocator);
    }

    var current_row = std.ArrayList([]const u8).empty;
    errdefer {
        for (current_row.items) |cell| allocator.free(cell);
        current_row.deinit(allocator);
    }

    var current_cell = std.ArrayList(u8).empty;
    errdefer current_cell.deinit(allocator);

    var in_quotes = false;
    var i: usize = 0;
    const len = bytes.len;

    while (i < len) {
        const char = bytes[i];
        if (in_quotes) {
            if (char == '"') {
                if (i + 1 < len and bytes[i + 1] == '"') {
                    // Escaped quote
                    current_cell.append(allocator, '"') catch return .{ .err = "Out of memory" };
                    i += 2;
                    continue;
                } else {
                    // Close quote
                    in_quotes = false;
                    i += 1;
                    continue;
                }
            }
            current_cell.append(allocator, char) catch return .{ .err = "Out of memory" };
            i += 1;
        } else {
            if (char == '"') {
                in_quotes = true;
                i += 1;
            } else if (char == delimiter) {
                // End of cell
                const cell_slice = current_cell.toOwnedSlice(allocator) catch return .{ .err = "Out of memory" };
                current_row.append(allocator, cell_slice) catch return .{ .err = "Out of memory" };
                i += 1;
            } else if (char == '\r' or char == '\n') {
                // End of cell and row
                const cell_slice = current_cell.toOwnedSlice(allocator) catch return .{ .err = "Out of memory" };
                current_row.append(allocator, cell_slice) catch return .{ .err = "Out of memory" };

                if (current_row.items.len > 0) {
                    const row_slice = current_row.toOwnedSlice(allocator) catch return .{ .err = "Out of memory" };
                    rows.append(allocator, row_slice) catch return .{ .err = "Out of memory" };
                }

                // Handle \r\n
                if (char == '\r' and i + 1 < len and bytes[i + 1] == '\n') {
                    i += 2;
                } else {
                    i += 1;
                }
            } else {
                current_cell.append(allocator, char) catch return .{ .err = "Out of memory" };
                i += 1;
            }
        }
    }

    // Flush last cell and row if any
    if (current_cell.items.len > 0 or current_row.items.len > 0) {
        const cell_slice = current_cell.toOwnedSlice(allocator) catch return .{ .err = "Out of memory" };
        current_row.append(allocator, cell_slice) catch return .{ .err = "Out of memory" };
        const row_slice = current_row.toOwnedSlice(allocator) catch return .{ .err = "Out of memory" };
        rows.append(allocator, row_slice) catch return .{ .err = "Out of memory" };
    } else {
        current_cell.deinit(allocator);
        current_row.deinit(allocator);
    }

    if (rows.items.len == 0) {
        const msg = allocator.dupe(u8, "Tabella CSV vuota.") catch "CSV vuoto";
        rows.deinit(allocator);
        return .{ .err = msg };
    }

    // The first row is headers
    const headers = rows.orderedRemove(0);
    const final_rows = rows.toOwnedSlice(allocator) catch return .{ .err = "Out of memory" };

    return .{ .csv = .{
        .headers = headers,
        .rows = final_rows,
    } };
}
