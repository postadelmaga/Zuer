const std = @import("std");
const zicro = @import("zicro");
const state_mod = @import("state.zig");
const AppAction = state_mod.AppAction;
const decoder_mod = @import("decoder.zig");
const Decoded = decoder_mod.Decoded;

pub const LoaderModule = struct {
    id_: []const u8,
    sender: zicro.media.LatestSender(Decoded),

    pub fn init(id_: []const u8, sender: zicro.media.LatestSender(Decoded)) LoaderModule {
        return .{
            .id_ = id_,
            .sender = sender,
        };
    }

    pub fn id(self: *LoaderModule) []const u8 {
        return self.id_;
    }

    pub fn subscriptions(_: *LoaderModule) []const []const u8 {
        return &.{"actions"};
    }

    pub fn run(self: *LoaderModule, ctx: *zicro.ModuleCtx) anyerror!void {
        while (!ctx.shouldStop()) {
            const maybe_msg = ctx.recvTimeout(50 * std.time.ns_per_ms) catch break;
            const msg = maybe_msg orelse continue;
            defer msg.deinit();

            // Only process messages from the "actions" channel
            const parsed = msg.env().decode(AppAction, ctx.gpa) catch continue;
            defer parsed.deinit();

            switch (parsed.value) {
                .load_file => |path| {
                    // Start decoding the file
                    var decoded = decoder_mod.decode(path, ctx.io, ctx.gpa);
                    
                    if (decoded == .err) {
                        // Notify that decoding failed
                        const err_action = AppAction{ .decode_failed = decoded.err };
                        try ctx.publishMsg("actions", err_action);
                        // We must free the error message since decode_failed copies it
                        decoded.deinit();
                    } else {
                        // Send the decoded file to TUI via media/data plane
                        self.sender.send(decoded) catch |err| {
                            // If receiver is gone, cleanup the decoded object
                            decoded.deinit();
                            return err;
                        };

                        // Notify that the file is ready
                        try ctx.publishMsg("actions", AppAction.file_ready);
                    }
                },
                else => {},
            }
        }
    }
};
