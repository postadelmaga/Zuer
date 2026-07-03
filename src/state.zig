const std = @import("std");
const zicro = @import("zicro");

/// Canali del bus: le uniche stringhe condivise tra i moduli.
pub const actions_channel = "actions";
pub const state_channel = "state";

pub const actions_topic = zicro.Topic(AppAction).init(actions_channel);

pub const AppAction = union(enum) {
    load_file: []const u8,
    file_ready: void,
    decode_failed: []const u8,
    scroll_up: void,
    scroll_down: void,
    scroll_left: void,
    scroll_right: void,
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
    yaw: f32,
    pitch: f32,

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
            .yaw = self.yaw,
            .pitch = self.pitch,
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

pub const initial_state = AppState{
    .file_path = "",
    .loading = false,
    .error_msg = null,
    .scroll_offset = 0,
    .filter_text = "",
    .should_exit = false,
    .history_count = 0,
    .yaw = 0.0,
    .pitch = 0.0,
};

/// Il reducer riceve l'allocator tramite il `reducer_ctx` di `Doc.initDepth`:
/// il puntatore deve restare valido per tutta la vita del Doc (vive nello stack di main).
pub fn reduce(ctx: ?*anyopaque, state: *AppState, action: *const AppAction) anyerror!void {
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(ctx.?))).*;

    switch (action.*) {
        .load_file => |path| {
            // Dup prima di liberare: se il dupe fallisce lo stato resta coerente
            // (Doc applica il reducer su un clone, ma i puntatori liberati
            // resterebbero nel clone scartato e verrebbero liberati di nuovo).
            const new_path = try allocator.dupe(u8, path);
            errdefer allocator.free(new_path);
            const new_filter = try allocator.dupe(u8, "");

            state.loading = true;
            allocator.free(state.file_path);
            state.file_path = new_path;
            if (state.error_msg) |err| {
                allocator.free(err);
                state.error_msg = null;
            }
            state.scroll_offset = 0;
            state.yaw = 0.0;
            state.pitch = 0.0;
            allocator.free(state.filter_text);
            state.filter_text = new_filter;
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
            const new_msg = try allocator.dupe(u8, msg);
            state.loading = false;
            if (state.error_msg) |err| {
                allocator.free(err);
            }
            state.error_msg = new_msg;
        },
        .scroll_up => {
            state.pitch += 0.15;
            if (state.scroll_offset > 0) {
                state.scroll_offset -= 1;
            }
        },
        .scroll_down => {
            state.pitch -= 0.15;
            state.scroll_offset += 1;
        },
        .scroll_left => {
            state.yaw -= 0.15;
        },
        .scroll_right => {
            state.yaw += 0.15;
        },
        .set_filter => |text| {
            const new_filter = try allocator.dupe(u8, text);
            allocator.free(state.filter_text);
            state.filter_text = new_filter;
            state.scroll_offset = 0;
        },
        .exit => {
            state.should_exit = true;
        },
    }
}
