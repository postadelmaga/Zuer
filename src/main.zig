const std = @import("std");
const zicro = @import("zicro");
const state_mod = @import("state.zig");
const AppState = state_mod.AppState;
const AppAction = state_mod.AppAction;
const decoder_mod = @import("decoder.zig");
const Decoded = decoder_mod.Decoded;
const terminal_mod = @import("terminal.zig");
const Terminal = terminal_mod.Terminal;
const loader_mod = @import("loader.zig");
const LoaderModule = loader_mod.LoaderModule;
const tui_mod = @import("tui.zig");
const TuiSink = tui_mod.TuiSink;

const ActionOrPrompt = union(enum) {
    action: AppAction,
    prompt_open,
    prompt_filter,
};

fn mapInput(event: *const zicro.input.InputEvent) ?ActionOrPrompt {
    return switch (event.*) {
        .key_down => |key| switch (key) {
            .up => .{ .action = .scroll_up },
            .down => .{ .action = .scroll_down },
            .escape => .{ .action = .exit },
            .char => |c| switch (c) {
                'q' => .{ .action = .exit },
                'o' => .prompt_open,
                'f' => .prompt_filter,
                'k' => .{ .action = .scroll_up },
                'j' => .{ .action = .scroll_down },
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    state_mod.global_gpa = gpa;

    // 1. Handle command line arguments
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip(); // Skip binary name
    const initial_file_path = args.next();

    // 2. Set up raw terminal mode
    var terminal = try Terminal.init(io);
    defer terminal.deinit(io);

    // 3. Initialize Zicro App
    var app = try zicro.App.init(gpa, io);
    defer app.deinit();

    // Create the latest-wins data plane channel for decoded files
    const tx, const rx = try zicro.media.latest(Decoded, gpa, io);
    // Since latest() allocates the triple buffer inner, we close them in main or defer
    defer tx.deinit();
    // note: rx is moved into tui_sink, which closes it in deinit.

    // 4. Register the stateful World node
    const doc = zicro.Doc(AppState, AppAction).initDepth(gpa, state_mod.initial_state, 100, state_mod.reduce, null);
    try app.world(AppState, AppAction, "world", "actions", "state", doc);

    // 5. Register the Background File Loader (Source/Worker)
    var loader = LoaderModule.init("loader", tx);
    try app.source(zicro.Module.of(LoaderModule, &loader));

    // 6. Register the TUI Renderer (Sink)
    var tui_sink = TuiSink.init(gpa, rx);
    defer tui_sink.deinit();
    try app.sink(zicro.Module.of(TuiSink, &tui_sink));

    // Subscribe to state channel to monitor exit requests
    var states = try app.bus().subscribe("state");
    defer states.deinit();

    // 7. If an initial file was specified, load it
    if (initial_file_path) |path| {
        try app.bus().publishMsg("main", "actions", AppAction{ .load_file = path });
    }

    // 8. Main non-blocking input loop
    main_loop: while (true) {
        // Read terminal input events
        if (try terminal.readInputEvent(io)) |event| {
            if (mapInput(&event)) |action_choice| {
                switch (action_choice) {
                    .action => |act| {
                        try app.bus().publishMsg("main", "actions", act);
                    },
                    .prompt_open => {
                        // Temporarily disable raw mode to get line input
                        terminal.deinit(io);
                        
                        const stdout = std.Io.File.stdout();
                        try stdout.writeStreamingAll(io, "\x1B[?25h\r\n\x1B[K\x1B[1;32m📂 Inserisci percorso file:\x1B[0m ");
                        
                        var buf: [256]u8 = undefined;
                        var slices = [_][]u8{&buf};
                        const bytes_read = try std.Io.File.stdin().readStreaming(io, &slices);
                        if (bytes_read > 0) {
                            const line = buf[0..bytes_read];
                            const trimmed = std.mem.trim(u8, line, " \r\n\t");
                            if (trimmed.len > 0) {
                                // Re-enable raw mode
                                terminal = try Terminal.init(io);
                                try app.bus().publishMsg("main", "actions", AppAction{ .load_file = trimmed });
                                continue :main_loop;
                            }
                        }
                        
                        // Re-enable raw mode if empty/error
                        terminal = try Terminal.init(io);
                    },
                    .prompt_filter => {
                        // Temporarily disable raw mode to get line input
                        terminal.deinit(io);
                        
                        const stdout = std.Io.File.stdout();
                        try stdout.writeStreamingAll(io, "\x1B[?25h\r\n\x1B[K\x1B[1;33m🔍 Inserisci filtro:\x1B[0m ");
                        
                        var buf: [256]u8 = undefined;
                        var slices = [_][]u8{&buf};
                        const bytes_read = try std.Io.File.stdin().readStreaming(io, &slices);
                        if (bytes_read > 0) {
                            const line = buf[0..bytes_read];
                            const trimmed = std.mem.trim(u8, line, " \r\n\t");
                            // Re-enable raw mode
                            terminal = try Terminal.init(io);
                            try app.bus().publishMsg("main", "actions", AppAction{ .set_filter = trimmed });
                            continue :main_loop;
                        }
                        
                        // Re-enable raw mode if empty/error
                        terminal = try Terminal.init(io);
                    },
                }
            }
        }

        // Process bus state messages to check for exit
        while (try states.tryRecv()) |msg| {
            defer msg.deinit();
            const parsed = try msg.env().decode(AppState, gpa);
            defer parsed.deinit();
            if (parsed.value.should_exit) {
                break :main_loop;
            }
        }

        // Throttle loop to prevent 100% CPU usage
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(15), .awake) catch {};
    }

    // 9. Shutdown and cleanup Zicro app modules
    var report = app.shutdownAndJoin();
    defer report.deinit();
}
