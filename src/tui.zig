const std = @import("std");
const zicro = @import("zicro");
const state_mod = @import("state.zig");
const AppState = state_mod.AppState;
const decoder_mod = @import("decoder.zig");
const Decoded = decoder_mod.Decoded;
const CsvData = decoder_mod.CsvData;
const MeshData = decoder_mod.MeshData;

pub const TuiSink = struct {
    gpa: std.mem.Allocator,
    receiver: zicro.media.LatestReceiver(Decoded),
    decoded: ?Decoded = null,
    stdout: std.Io.File,

    pub fn init(gpa: std.mem.Allocator, receiver: zicro.media.LatestReceiver(Decoded)) TuiSink {
        return .{
            .gpa = gpa,
            .receiver = receiver,
            .stdout = std.Io.File.stdout(),
        };
    }

    pub fn deinit(self: *TuiSink) void {
        if (self.decoded) |*d| {
            d.deinit();
        }
        self.receiver.deinit();
    }

    pub fn id(_: *TuiSink) []const u8 {
        return "tui_sink";
    }

    pub fn subscriptions(_: *TuiSink) []const []const u8 {
        return &.{"state"};
    }

    pub fn run(self: *TuiSink, ctx: *zicro.ModuleCtx) anyerror!void {
        while (!ctx.shouldStop()) {
            const maybe_msg = ctx.recvTimeout(50 * std.time.ns_per_ms) catch break;
            const msg = maybe_msg orelse continue;
            defer msg.deinit();

            const state_parsed = msg.env().decode(AppState, ctx.gpa) catch continue;
            defer state_parsed.deinit();
            const state = state_parsed.value;

            // Check if there is a new decoded file waiting
            const taken = self.receiver.tryRecv() catch null;
            if (taken) |new_decoded| {
                if (self.decoded) |*old| {
                    old.deinit();
                }
                self.decoded = new_decoded;
            }

            try self.render(ctx.io, &state);
        }
    }

    fn getTerminalSize() struct { rows: u16, cols: u16 } {
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0) {
            return .{ .rows = ws.row, .cols = ws.col };
        }
        return .{ .rows = 24, .cols = 80 };
    }

    fn render(self: *TuiSink, io: std.Io, state: *const AppState) !void {
        const size = getTerminalSize();
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = self.stdout.writer(io, &stdout_buf);
        const writer = &stdout_writer.interface;

        // Clear screen and move cursor to home position
        try writer.writeAll("\x1B[2J\x1B[H");

        // Header (frosted blue accent styling)
        try writer.writeAll("\x1B[1;36m┌──────────────────────────────────────────────────────────────────────────────┐\x1B[0m\r\n");
        const title = "◇ zuer — Zig File Viewer";
        const subtitle = "[ Zicro Bus ]";
        try writer.print("\x1B[1;36m│\x1B[0;1;37m {s:<30}\x1B[0;32m{s:>44}\x1B[0m\x1B[1;36m│\x1B[0m\r\n", .{ title, subtitle });
        try writer.writeAll("\x1B[1;36m└──────────────────────────────────────────────────────────────────────────────┘\x1B[0m\r\n");

        // Main content area
        const content_height = if (size.rows > 7) size.rows - 7 else 10;
        
        if (state.loading) {
            try writer.writeAll("\r\n\r\n   \x1B[5;33mCaricamento in corso...\x1B[0m\r\n");
        } else if (state.error_msg) |err| {
            try writer.writeAll("\r\n\r\n   \x1B[1;31mErrore di apertura:\x1B[0m\r\n");
            try writer.print("   \x1B[31m{s}\x1B[0m\r\n", .{err});
        } else if (self.decoded) |decoded| {
            switch (decoded) {
                .text => |text| {
                    try self.renderText(writer, text, state.scroll_offset, content_height);
                },
                .csv => |csv| {
                    try self.renderCsv(writer, csv, state.scroll_offset, state.filter_text, content_height, size.cols);
                },
                .markdown => |md| {
                    try self.renderMarkdown(writer, md.content, state.scroll_offset, content_height);
                },
                .mesh => |mesh| {
                    try self.renderMesh(writer, mesh);
                },
                .err => |err| {
                    try writer.print("\r\n   \x1B[1;31mErrore di decodifica:\x1B[0m\r\n   {s}\r\n", .{err});
                },
            }
        } else {
            try writer.writeAll("\r\n\r\n   \x1B[90mNessun file aperto.\x1B[0m\r\n");
            try writer.writeAll("   Premi \x1B[1;32mo\x1B[0m per aprire un file, o inseriscilo come argomento.\r\n");
        }

        // Fill empty rows to push footer to bottom
        // we can position cursor directly, but simple spacing works
        
        // Footer (status and help bar)
        // Position cursor at bottom
        try writer.print("\x1B[{d};1H", .{size.rows - 2});
        try writer.writeAll("\x1B[90m────────────────────────────────────────────────────────────────────────────────\x1B[0m\r\n");
        
        const path_str = if (state.file_path.len > 0) state.file_path else "Nessuno";
        const filter_str = if (state.filter_text.len > 0) state.filter_text else "Nessuno";
        
        try writer.print("\x1B[1;30;47m FILE \x1B[0m \x1B[1m{s:<25}\x1B[0m │ \x1B[1;30;47m FILTRO \x1B[0m \x1B[1m{s:<15}\x1B[0m │ \x1B[1m↑/↓\x1B[0m: Scorrimento │ \x1B[1mo\x1B[0m: Apri │ \x1B[1mf\x1B[0m: Filtra │ \x1B[1mq\x1B[0m: Esci", .{
            std.fs.path.basename(path_str),
            filter_str,
        });
        try stdout_writer.flush();
    }

    fn renderText(self: *TuiSink, writer: anytype, text: []const u8, offset: usize, height: usize) !void {
        _ = self;
        var line_it = std.mem.splitScalar(u8, text, '\n');
        var line_idx: usize = 0;
        var printed: usize = 0;

        while (line_it.next()) |line| {
            if (line_idx >= offset) {
                if (printed >= height) break;
                // Render line number
                try writer.print(" \x1B[90m{d:>5} │\x1B[0m {s}\r\n", .{ line_idx + 1, line });
                printed += 1;
            }
            line_idx += 1;
        }
    }

    fn renderCsv(self: *TuiSink, writer: anytype, csv: CsvData, offset: usize, filter: []const u8, height: usize, term_width: usize) !void {
        // Compute column widths
        var col_widths = try self.gpa.alloc(usize, csv.headers.len);
        defer self.gpa.free(col_widths);

        for (csv.headers, 0..) |h, i| {
            col_widths[i] = @max(h.len, 4);
        }

        // Scan first 100 rows to adjust widths
        const scan_limit = @min(csv.rows.len, 100);
        for (csv.rows[0..scan_limit]) |row| {
            for (row, 0..) |cell, i| {
                if (i >= col_widths.len) break;
                col_widths[i] = @max(col_widths[i], cell.len);
            }
        }

        // Limit column width to prevent overflow
        for (col_widths) |*w| {
            w.* = @min(w.*, 30);
        }

        // Render header
        try writer.writeAll(" ");
        for (csv.headers, 0..) |h, i| {
            const width = col_widths[i];
            const trimmed = if (h.len > width) h[0..width] else h;
            try writer.print("\x1B[1;36m{s}\x1B[0m", .{trimmed});
            if (trimmed.len < width) {
                var k: usize = 0;
                while (k < (width - trimmed.len)) : (k += 1) {
                    try writer.writeByte(' ');
                }
            }
            try writer.writeAll(" │ ");
        }
        try writer.writeAll("\r\n");

        // Separator line
        try writer.writeAll(" ");
        for (col_widths) |w| {
            var k: usize = 0;
            while (k < w) : (k += 1) try writer.writeAll("─");
            try writer.writeAll("─┼─");
        }
        try writer.writeAll("\r\n");

        // Render rows (with filtering and virtualization)
        var printed: usize = 0;
        var matched_rows: usize = 0;

        for (csv.rows) |row| {
            // Apply live filter
            if (filter.len > 0) {
                var matches = false;
                for (row) |cell| {
                    if (std.ascii.indexOfIgnoreCase(cell, filter) != null) {
                        matches = true;
                        break;
                    }
                }
                if (!matches) continue;
            }

            if (matched_rows >= offset) {
                if (printed >= height - 2) break;

                // Color alternate rows for premium look
                const row_color = if (printed % 2 == 0) "" else "\x1B[2m";
                try writer.print("{s} ", .{row_color});

                for (row, 0..) |cell, i| {
                    if (i >= col_widths.len) break;
                    const width = col_widths[i];
                    
                    var cell_buf = std.ArrayList(u8).empty;
                    defer cell_buf.deinit(self.gpa);

                    // Replace tabs/newlines in cells
                    for (cell) |c| {
                        if (c == '\t' or c == '\n' or c == '\r') {
                            try cell_buf.append(self.gpa, ' ');
                        } else {
                            try cell_buf.append(self.gpa, c);
                        }
                    }

                    const clean_cell = cell_buf.items;
                    const trimmed = if (clean_cell.len > width) clean_cell[0..width] else clean_cell;
                    try writer.print("{s}", .{trimmed});
                    if (trimmed.len < width) {
                        var k: usize = 0;
                        while (k < (width - trimmed.len)) : (k += 1) {
                            try writer.writeByte(' ');
                        }
                    }
                    try writer.print("\x1B[0m │ {s}", .{row_color});
                }
                try writer.writeAll("\r\n");
                printed += 1;
            }
            matched_rows += 1;
        }

        if (printed == 0) {
            try writer.writeAll("\r\n   \x1B[90m(Nessuna riga corrispondente al filtro)\x1B[0m\r\n");
        }

        _ = term_width;
    }

    fn renderMarkdown(self: *TuiSink, writer: anytype, content: []const u8, offset: usize, height: usize) !void {
        _ = self;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        var line_idx: usize = 0;
        var printed: usize = 0;
        var in_code_block = false;

        while (line_it.next()) |line| {
            if (line_idx >= offset) {
                if (printed >= height) break;

                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (std.mem.startsWith(u8, trimmed, "```")) {
                    in_code_block = !in_code_block;
                    try writer.print(" \x1B[90m│\x1B[0m \x1B[33m{s}\x1B[0m\r\n", .{line});
                } else if (in_code_block) {
                    try writer.print(" \x1B[90m│\x1B[0m \x1B[2;37m{s}\x1B[0m\r\n", .{line});
                } else if (std.mem.startsWith(u8, trimmed, "# ")) {
                    // Header 1 (Cyan Bold)
                    try writer.print(" \x1B[90m│\x1B[0m \x1B[1;36m{s}\x1B[0m\r\n", .{line});
                } else if (std.mem.startsWith(u8, trimmed, "## ")) {
                    // Header 2 (Blue Bold)
                    try writer.print(" \x1B[90m│\x1B[0m \x1B[1;34m{s}\x1B[0m\r\n", .{line});
                } else if (std.mem.startsWith(u8, trimmed, "### ")) {
                    // Header 3 (Magenta Bold)
                    try writer.print(" \x1B[90m│\x1B[0m \x1B[1;35m{s}\x1B[0m\r\n", .{line});
                } else if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
                    // List item
                    try writer.print(" \x1B[90m│\x1B[0m  \x1B[1;32m•\x1B[0m {s}\r\n", .{trimmed[2..]});
                } else {
                    try writer.print(" \x1B[90m│\x1B[0m {s}\r\n", .{line});
                }

                printed += 1;
            }
            line_idx += 1;
        }
    }

    fn renderMesh(self: *TuiSink, writer: anytype, mesh: MeshData) !void {
        _ = self;
        try writer.writeAll("\r\n");
        try writer.writeAll("   \x1B[1;35m◇ MODELLO 3D (Wavefront OBJ) DETTAGLI:\x1B[0m\r\n\r\n");
        try writer.print("   \x1B[1mNome:\x1B[0m             {s}\r\n", .{mesh.name});
        try writer.print("   \x1B[1mVertici:\x1B[0m          {d}\r\n", .{mesh.num_vertices});
        try writer.print("   \x1B[1mFacce:\x1B[0m            {d}\r\n", .{mesh.num_faces});
        try writer.print("   \x1B[1mNormali:\x1B[0m          {d}\r\n", .{mesh.num_normals});
        try writer.writeAll("\r\n");
        try writer.writeAll("   \x1B[1;36mBounding Box:\x1B[0m\r\n");
        try writer.print("     \x1B[1mMinimo:\x1B[0m         [ {d:.4}, {d:.4}, {d:.4} ]\r\n", .{ mesh.bbox_min[0], mesh.bbox_min[1], mesh.bbox_min[2] });
        try writer.print("     \x1B[1mMassimo:\x1B[0m        [ {d:.4}, {d:.4}, {d:.4} ]\r\n", .{ mesh.bbox_max[0], mesh.bbox_max[1], mesh.bbox_max[2] });
        try writer.print("     \x1B[1mDimensioni:\x1B[0m     Larghezza: {d:.4} | Altezza: {d:.4} | Profondità: {d:.4}\r\n", .{
            mesh.bbox_max[0] - mesh.bbox_min[0],
            mesh.bbox_max[1] - mesh.bbox_min[1],
            mesh.bbox_max[2] - mesh.bbox_min[2],
        });
        try writer.print("     \x1B[1mCentro:\x1B[0m         [ {d:.4}, {d:.4}, {d:.4} ]\r\n", .{ mesh.center[0], mesh.center[1], mesh.center[2] });
    }
};
