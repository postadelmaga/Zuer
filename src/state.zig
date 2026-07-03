const std = @import("std");
const decoder = @import("decoder.zig");

pub const AppAction = union(enum) {
    load_file: []const u8,
    file_ready: void,
    decode_failed: []const u8,
    scroll_up: void,
    scroll_down: void,
    set_filter: []const u8,
    exit: void,
};

pub const AppState = struct {
    file_path: []const u8,
    loading: bool,
    error_msg: ?[]const u8,
    scroll_offset: usize,
    filter_text: []const u8,
    should_exit: bool,
    history_count: usize,

    pub fn clone(self: *const AppState, gpa: std.mem.Allocator) !AppState {
        const path = try gpa.dupe(u8, self.file_path);
        errdefer gpa.free(path);

        const filter = try gpa.dupe(u8, self.filter_text);
        errdefer gpa.free(filter);

        var err_msg: ?[]const u8 = null;
        if (self.error_msg) |err| {
            err_msg = try gpa.dupe(u8, err);
        }

        return .{
            .file_path = path,
            .loading = self.loading,
            .error_msg = err_msg,
            .scroll_offset = self.scroll_offset,
            .filter_text = filter,
            .should_exit = self.should_exit,
            .history_count = self.history_count,
        };
    }

    pub fn deinit(self: *AppState, gpa: std.mem.Allocator) void {
        gpa.free(self.file_path);
        gpa.free(self.filter_text);
        if (self.error_msg) |err| {
            gpa.free(err);
        }
    }
};

pub var global_gpa: std.mem.Allocator = undefined;

pub const initial_state = AppState{
    .file_path = "",
    .loading = false,
    .error_msg = null,
    .scroll_offset = 0,
    .filter_text = "",
    .should_exit = false,
    .history_count = 0,
};

pub fn reduce(ctx: ?*anyopaque, state: *AppState, action: *const AppAction) anyerror!void {
    _ = ctx;
    const allocator = global_gpa;

    switch (action.*) {
        .load_file => |path| {
            state.loading = true;
            allocator.free(state.file_path);
            state.file_path = try allocator.dupe(u8, path);
            if (state.error_msg) |err| {
                allocator.free(err);
                state.error_msg = null;
            }
            state.scroll_offset = 0;
            // Clear filter text
            allocator.free(state.filter_text);
            state.filter_text = try allocator.dupe(u8, "");
        },
        .file_ready => {
            state.loading = false;
            if (state.error_msg) |err| {
                allocator.free(err);
                state.error_msg = null;
            }
            state.history_count += 1;
            state.scroll_offset = 0;
        },
        .decode_failed => |msg| {
            state.loading = false;
            if (state.error_msg) |err| {
                allocator.free(err);
            }
            state.error_msg = try allocator.dupe(u8, msg);
        },
        .scroll_up => {
            if (state.scroll_offset > 0) {
                state.scroll_offset -= 1;
            }
        },
        .scroll_down => {
            state.scroll_offset += 1;
        },
        .set_filter => |text| {
            allocator.free(state.filter_text);
            state.filter_text = try allocator.dupe(u8, text);
            state.scroll_offset = 0;
        },
        .exit => {
            state.should_exit = true;
        },
    }
}
