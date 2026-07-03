const std = @import("std");
const zicro = @import("zicro");
const state_mod = @import("state.zig");
const AppState = state_mod.AppState;
const AppAction = state_mod.AppAction;
const decoder_mod = @import("decoder.zig");
const Decoded = decoder_mod.Decoded;
const loader_mod = @import("loader.zig");
const LoaderModule = loader_mod.LoaderModule;
const LoadedFile = loader_mod.LoadedFile;
const tui_mod = @import("tui.zig");
const TuiSink = tui_mod.TuiSink;
const input_mod = @import("input_source.zig");
const InputModule = input_mod.InputModule;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Rilasciata per ultima (LIFO), dopo il join di tutti i moduli che decodificano.
    defer decoder_mod.closePluginCache(gpa);

    // 1. Handle command line arguments
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip(); // Skip binary name

    var initial_file_path: ?[]const u8 = null;
    if (args.next()) |first_arg| {
        if (std.mem.eql(u8, first_arg, "--json") or std.mem.eql(u8, first_arg, "-j")) {
            const in_path = args.next() orelse {
                std.debug.print("Missing input path for --json\n", .{});
                std.process.exit(1);
            };
            var decoded = decoder_mod.decode(in_path, io, gpa);
            defer decoded.deinit(gpa);

            var stdout_buf: [4096]u8 = undefined;
            var stdout_file = std.Io.File.stdout();
            var stdout_writer = stdout_file.writer(io, &stdout_buf);
            try dumpJson(decoded, &stdout_writer.interface);
            try stdout_writer.flush();
            return;
        } else {
            initial_file_path = first_arg;
        }
    }

    // 2. Initialize the Zicro App (sources → world → sinks)
    var app = try zicro.App.init(gpa, io);
    defer app.deinit();

    // Actions must never be dropped: apply backpressure instead.
    try app.overflow(state_mod.actions_channel, .block);

    // Latest-wins data plane for decoded files: loader → TUI.
    const tx, const rx = try zicro.media.latest(LoadedFile, gpa, io);
    defer tx.deinit();
    // rx is moved into tui_sink, which closes it in deinit.

    // Module instances live on this frame; their deinit must run AFTER the
    // runtime join below (defers run LIFO: join → tui_sink.deinit → tx.deinit).
    var tui_sink = TuiSink.init(gpa, rx, init.environ_map);
    defer tui_sink.deinit();

    var loader = LoaderModule.init("loader", gpa, tx);
    var input_source = InputModule{};

    // The reducer receives its allocator through Doc's reducer_ctx; the pointee
    // must outlive the world module, so it lives here in main's frame.
    var reducer_gpa: std.mem.Allocator = gpa;

    // From here on, spawned threads are always wound down before the defers above.
    defer {
        var report = app.shutdownAndJoin();
        if (!report.isClean()) {
            std.debug.print("Moduli terminati con errore: {d}\n", .{report.failed.len});
        }
        report.deinit();
    }

    // 3. World: the single source of truth, reduced transactionally with undo depth 100.
    const doc = zicro.Doc(AppState, AppAction).initDepth(
        gpa,
        state_mod.initial_state,
        100,
        state_mod.reduce,
        @ptrCast(&reducer_gpa),
    );
    try app.world(AppState, AppAction, "world", state_mod.actions_channel, state_mod.state_channel, doc);

    // 4. Sources and sinks: they only ever talk through the bus.
    try app.source(zicro.Module.of(LoaderModule, &loader));
    try app.sink(zicro.Module.of(TuiSink, &tui_sink));
    try app.source(zicro.Module.of(InputModule, &input_source));

    // 5. Watch the retained state channel for the exit request.
    var states = try app.bus().subscribe(state_mod.state_channel);
    defer states.deinit();

    if (initial_file_path) |path| {
        try app.bus().publishMsg("main", state_mod.actions_channel, AppAction{ .load_file = path });
    }

    while (true) {
        const maybe_msg = states.recvTimeout(250 * std.time.ns_per_ms) catch break;
        if (maybe_msg) |msg| {
            defer msg.deinit();
            const parsed = msg.env().decode(AppState, gpa) catch continue;
            defer parsed.deinit();
            if (parsed.value.should_exit) break;
        }
        // All modules gone (failure or natural exit): nothing left to wait for.
        if (app.liveCount() == 0) break;
    }
}

fn dumpJson(decoded: Decoded, writer: *std.Io.Writer) !void {
    switch (decoded) {
        .text => |t| {
            try writer.writeAll("{\"type\":\"text\",\"content\":");
            try std.json.fmt(t, .{}).format(writer);
            try writer.writeAll("}");
        },
        .markdown => |m| {
            try writer.writeAll("{\"type\":\"markdown\",\"content\":");
            try std.json.fmt(m.content, .{}).format(writer);
            try writer.writeAll("}");
        },
        .csv => |c| {
            try writer.writeAll("{\"type\":\"csv\",\"headers\":");
            try std.json.fmt(c.headers, .{}).format(writer);
            try writer.writeAll(",\"rows\":");
            try std.json.fmt(c.rows, .{}).format(writer);
            try writer.writeAll("}");
        },
        .mesh => |m| {
            try writer.writeAll("{\"type\":\"mesh\",\"name\":");
            try std.json.fmt(m.name, .{}).format(writer);
            try writer.writeAll(",\"vertices\":[");
            for (m.vertices, 0..) |v, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("[{d},{d},{d}]", .{ v[0], v[1], v[2] });
            }
            try writer.writeAll("],\"faces\":[");
            for (m.faces, 0..) |f, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("[{d},{d},{d}]", .{ f.v1, f.v2, f.v3 });
            }
            const size = @max(m.bbox_max[0] - m.bbox_min[0], @max(m.bbox_max[1] - m.bbox_min[1], m.bbox_max[2] - m.bbox_min[2]));
            try writer.print("],\"center\":[{d},{d},{d}],\"size\":{d}", .{ m.center[0], m.center[1], m.center[2], size });
            try writer.writeAll("}");
        },
        .image => |img| {
            try writer.writeAll("{\"type\":\"image\",\"name\":");
            try std.json.fmt(img.name, .{}).format(writer);
            try writer.print(",\"width\":{d},\"height\":{d}", .{ img.width, img.height });
            try writer.writeAll("}");
        },
        .err => |e| {
            try writer.writeAll("{\"type\":\"error\",\"message\":");
            try std.json.fmt(e, .{}).format(writer);
            try writer.writeAll("}");
        },
    }
}
