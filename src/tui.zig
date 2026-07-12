const std = @import("std");
const zicro = @import("zicro");
const state_mod = @import("state.zig");
const AppState = state_mod.AppState;
const decoder_mod = @import("decoder.zig");
const Decoded = decoder_mod.Decoded;
const CsvData = decoder_mod.CsvData;
const loader_mod = @import("loader.zig");
const LoadedFile = loader_mod.LoadedFile;
const gpu_mod = @import("gpu_renderer.zig");

pub const TuiSink = struct {
    gpa: std.mem.Allocator,
    receiver: zicro.media.LatestReceiver(LoadedFile),
    loaded: ?LoadedFile = null,
    stdout: std.Io.File,
    /// Il terminale supporta il kitty graphics protocol (render a piena
    /// risoluzione pixel invece dei mezzi-blocchi).
    kitty: bool,
    kitty_image_shown: bool = false,
    gpu: ?gpu_mod.Renderer = null,
    gpu_failed: bool = false,
    gpu_mesh_loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator, receiver: zicro.media.LatestReceiver(LoadedFile), environ: *const std.process.Environ.Map) TuiSink {
        return .{
            .gpa = gpa,
            .receiver = receiver,
            .stdout = std.Io.File.stdout(),
            .kitty = detectKittyGraphics(environ),
        };
    }

    pub fn deinit(self: *TuiSink) void {
        // Prima il renderer: la memoria Vulkan importata punta alle pagine del
        // memfd di `loaded`, che il deinit successivo munmappa.
        if (self.gpu) |*g| {
            g.deinit();
        }
        if (self.loaded) |*l| {
            l.deinit();
        }
        self.receiver.deinit();
    }

    pub fn id(_: *TuiSink) []const u8 {
        return "tui_sink";
    }

    pub fn subscriptions(_: *TuiSink) []const []const u8 {
        return &.{state_mod.state_channel};
    }

    pub fn run(self: *TuiSink, ctx: *zicro.ModuleCtx) anyerror!void {
        var current_state: ?AppState = null;
        defer {
            if (current_state) |*cs| {
                cs.deinit(self.gpa);
            }
        }

        var spinner_frame: usize = 0;

        while (!ctx.shouldStop()) {
            const maybe_msg = ctx.recvTimeout(50 * std.time.ns_per_ms) catch break;
            if (maybe_msg) |msg| {
                defer msg.deinit();

                const state_parsed = msg.env().decode(AppState, ctx.gpa) catch continue;
                defer state_parsed.deinit();

                if (current_state) |*cs| {
                    cs.deinit(self.gpa);
                }
                current_state = try state_parsed.value.clone(self.gpa);
            }

            // Check if there is a new decoded file waiting
            const taken = self.receiver.tryRecv() catch null;
            if (taken) |new_loaded| {
                if (self.loaded) |*old| {
                    // La geometria importata dalla GPU referenzia il memfd del
                    // vecchio LoadedFile: va rilasciata prima del suo deinit.
                    if (self.gpu) |*g| g.releaseMesh();
                    self.gpu_mesh_loaded = false;
                    old.deinit();
                }
                self.loaded = new_loaded;
            }

            if (current_state) |*state| {
                if (state.loading) {
                    spinner_frame +%= 1;
                    try self.renderWithSpinner(ctx.io, state, spinner_frame);
                } else if (maybe_msg != null) {
                    try self.render(ctx.io, state);
                }
            }
        }
    }

    /// Intestazione comune a tutte le schermate.
    fn drawHeader(writer: anytype) !void {
        try writer.writeAll("\x1B[2J\x1B[H");
        try writer.writeAll("\x1B[1;36m┌──────────────────────────────────────────────────────────────────────────────┐\x1B[0m\r\n");
        const title = "◇ zuer — Zig File Viewer";
        const subtitle = "[ Zicro Bus ]";
        try writer.print("\x1B[1;36m│\x1B[0;1;37m {s:<30}\x1B[0;32m{s:>44}\x1B[0m\x1B[1;36m│\x1B[0m\r\n", .{ title, subtitle });
        try writer.writeAll("\x1B[1;36m└──────────────────────────────────────────────────────────────────────────────┘\x1B[0m\r\n");
    }

    /// Barra di stato in fondo allo schermo; se il file corrente è stato copiato in
    /// un buffer GPU (zicro.gpu_memory) mostra fd e dimensione dello staging.
    fn drawFooter(self: *TuiSink, writer: anytype, rows: u16, state: *const AppState) !void {
        try writer.print("\x1B[{d};1H", .{rows - 2});
        try writer.writeAll("\x1B[90m────────────────────────────────────────────────────────────────────────────────\x1B[0m\r\n");

        const path_str = if (state.file_path.len > 0) state.file_path else "Nessuno";
        const filter_str = if (state.filter_text.len > 0) state.filter_text else "Nessuno";

        try writer.print("\x1B[1;30;47m FILE \x1B[0m \x1B[1m{s:<25}\x1B[0m │ \x1B[1;30;47m FILTRO \x1B[0m \x1B[1m{s:<15}\x1B[0m │ ", .{
            std.fs.path.basename(path_str),
            filter_str,
        });

        if (self.loaded) |loaded| {
            if (loaded.gpu) |stage| {
                // "zc" = geometria importata zero-copy dal memfd; "cp" = copiata.
                const mode = if (self.gpu) |*g|
                    (if (g.meshImported()) "zc" else "cp")
                else
                    "--";
                try writer.print("\x1B[1;30;42m GPU {s} \x1B[0m fd={d} {d} KiB │ ", .{
                    mode,
                    stage.buffer.exportHandle(),
                    stage.buffer.size / 1024,
                });
            }
        }

        try writer.writeAll("\x1B[1m↑/↓\x1B[0m: Scorrimento │ \x1B[1mo\x1B[0m: Apri │ \x1B[1mf\x1B[0m: Filtra │ \x1B[1mq\x1B[0m: Esci");
    }

    fn renderWithSpinner(self: *TuiSink, io: std.Io, state: *const AppState, frame: usize) !void {
        const size = getTerminalSize();
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = self.stdout.writer(io, &stdout_buf);
        const writer = &stdout_writer.interface;

        try drawHeader(writer);

        // Spinner animation frames
        const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
        const sym = spinner[frame % spinner.len];

        try writer.writeAll("\r\n\r\n");
        try writer.print("   \x1B[1;33m{s}\x1B[0m  Caricamento in corso di \x1B[1;37m{s}\x1B[0m...\r\n", .{
            sym,
            std.fs.path.basename(state.file_path),
        });

        // Nice loading animation dots
        try writer.writeAll("   ");
        const dot_count = (frame / 2) % 5;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            if (i < dot_count) {
                try writer.writeAll("\x1B[1;36m● \x1B[0m");
            } else {
                try writer.writeAll("\x1B[90m○ \x1B[0m");
            }
        }
        try writer.writeAll("\r\n");

        try self.drawFooter(writer, size.rows, state);
        try stdout_writer.flush();
    }

    const TermSize = struct {
        rows: u16,
        cols: u16,
        /// Pixel per cella (0 se il terminale non riporta le dimensioni in pixel).
        cell_w: u16 = 0,
        cell_h: u16 = 0,
    };

    fn getTerminalSize() TermSize {
        if (@import("builtin").os.tag == .windows) {
            // GetConsoleScreenBufferInfo: the visible window rect gives rows/cols. The
            // console has no pixel geometry, so cell_w/cell_h stay 0 (half-block path).
            const win = struct {
                const COORD = extern struct { x: i16, y: i16 };
                const SMALL_RECT = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
                const CSBI = extern struct { size: COORD, cursor: COORD, attrs: u16, window: SMALL_RECT, max: COORD };
                extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
                extern "kernel32" fn GetConsoleScreenBufferInfo(h: ?*anyopaque, info: *CSBI) callconv(.winapi) i32;
            };
            var info: win.CSBI = undefined;
            const h = win.GetStdHandle(0xFFFFFFF5); // STD_OUTPUT_HANDLE
            if (win.GetConsoleScreenBufferInfo(h, &info) != 0) {
                const cols: u16 = @intCast(@max(info.window.right - info.window.left + 1, 0));
                const rows: u16 = @intCast(@max(info.window.bottom - info.window.top + 1, 0));
                if (rows >= 8 and cols >= 20) return .{ .rows = rows, .cols = cols, .cell_w = 0, .cell_h = 0 };
            }
            return .{ .rows = 24, .cols = 80 };
        }
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        // Alcuni pty (es. `script`, CI) rispondono con 0×0: si ripiega sul default
        // per non mandare in underflow i calcoli di layout.
        if (rc == 0 and ws.row >= 8 and ws.col >= 20) {
            return .{
                .rows = ws.row,
                .cols = ws.col,
                .cell_w = if (ws.xpixel > 0) ws.xpixel / ws.col else 0,
                .cell_h = if (ws.ypixel > 0) ws.ypixel / ws.row else 0,
            };
        }
        return .{ .rows = 24, .cols = 80 };
    }

    /// Il kitty graphics protocol permette di disegnare bitmap a risoluzione
    /// pixel piena dentro l'area celle: supportato da kitty, Ghostty, WezTerm,
    /// Konsole recenti. Rilevazione via environment, senza query interattive.
    fn detectKittyGraphics(environ: *const std.process.Environ.Map) bool {
        if (environ.get("KITTY_WINDOW_ID") != null) return true;
        if (environ.get("GHOSTTY_RESOURCES_DIR") != null) return true;
        if (environ.get("WEZTERM_PANE") != null) return true;
        if (environ.get("TERM")) |term| {
            if (std.mem.indexOf(u8, term, "kitty") != null) return true;
            if (std.mem.indexOf(u8, term, "ghostty") != null) return true;
        }
        return false;
    }

    /// Trasmette una bitmap col kitty graphics protocol (chunk base64 da 4 KiB),
    /// scalata dal terminale nell'area di `cell_cols`×`cell_rows` celle.
    /// `format` = 24 (RGB) o 32 (RGBA); q=2 sopprime le risposte del terminale.
    fn kittyTransmit(writer: anytype, pixels: []const u8, w: usize, h: usize, format: u8, cell_cols: usize, cell_rows: usize) !void {
        const enc = std.base64.standard.Encoder;
        var first = true;
        var off: usize = 0;
        while (off < pixels.len) {
            const raw = pixels[off..@min(off + 3072, pixels.len)];
            off += raw.len;
            const last = off >= pixels.len;

            var b64_buf: [4096]u8 = undefined;
            const b64 = enc.encode(&b64_buf, raw);

            if (first) {
                try writer.print("\x1B_Ga=T,f={d},s={d},v={d},c={d},r={d},i=1,q=2,m={d};", .{
                    format, w, h, cell_cols, cell_rows, @intFromBool(!last),
                });
                first = false;
            } else {
                try writer.print("\x1B_Gm={d};", .{@intFromBool(!last)});
            }
            try writer.writeAll(b64);
            try writer.writeAll("\x1B\\");
        }
    }

    /// Cancella le immagini kitty precedenti: \x1B[2J non le rimuove.
    fn kittyClear(self: *TuiSink, writer: anytype) !void {
        if (self.kitty_image_shown) {
            try writer.writeAll("\x1B_Ga=d,d=A,q=2\x1B\\");
            self.kitty_image_shown = false;
        }
    }

    /// Stampa una bitmap RGBA come mezzi-blocchi truecolor (2 pixel per cella).
    /// Pixel con alpha 0 = sfondo vuoto.
    fn blitHalfBlocks(writer: anytype, rgba: []const u8, w: usize, h: usize) !void {
        var y: usize = 0;
        while (y < h) : (y += 2) {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const top = rgba[(y * w + x) * 4 ..][0..4];
                const bot: [4]u8 = if (y + 1 < h) rgba[((y + 1) * w + x) * 4 ..][0..4].* else .{ 0, 0, 0, 0 };
                const top_set = top[3] != 0;
                const bot_set = bot[3] != 0;
                if (!top_set and !bot_set) {
                    try writer.writeAll("\x1B[0m ");
                } else if (top_set and !bot_set) {
                    try writer.print("\x1B[0m\x1B[38;2;{d};{d};{d}m▀", .{ top[0], top[1], top[2] });
                } else if (!top_set and bot_set) {
                    try writer.print("\x1B[0m\x1B[38;2;{d};{d};{d}m▄", .{ bot[0], bot[1], bot[2] });
                } else {
                    try writer.print("\x1B[48;2;{d};{d};{d}m\x1B[38;2;{d};{d};{d}m▄", .{
                        top[0], top[1], top[2],
                        bot[0], bot[1], bot[2],
                    });
                }
            }
            try writer.writeAll("\x1B[0m\r\n");
        }
    }

    fn render(self: *TuiSink, io: std.Io, state: *const AppState) !void {
        const size = getTerminalSize();
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = self.stdout.writer(io, &stdout_buf);
        const writer = &stdout_writer.interface;

        try drawHeader(writer);
        try self.kittyClear(writer);

        // Main content area
        const content_height = if (size.rows > 7) size.rows - 7 else 10;

        if (state.loading) {
            try writer.writeAll("\r\n\r\n   \x1B[5;33mCaricamento in corso...\x1B[0m\r\n");
        } else if (state.error_msg) |err| {
            try writer.writeAll("\r\n\r\n   \x1B[1;31mErrore di apertura:\x1B[0m\r\n");
            try writer.print("   \x1B[31m{s}\x1B[0m\r\n", .{err});
        } else if (self.loaded) |loaded| {
            switch (loaded.decoded) {
                .text => |text| {
                    try self.renderText(writer, text, state.scroll_offset, content_height);
                },
                .csv => |csv| {
                    try self.renderCsv(writer, csv, state.scroll_offset, state.filter_text, content_height);
                },
                .workbook => |w| {
                    // TUI: mostra il foglio attivo (default il primo) come tabella.
                    try self.renderCsv(writer, w.activeCsv(), state.scroll_offset, state.filter_text, content_height);
                },
                .markdown => |md| {
                    try self.renderMarkdown(writer, md.content, state.scroll_offset, content_height);
                },
                .mesh => |mesh| {
                    try self.renderMesh(writer, mesh, state, content_height, size.cols);
                },
                .image => |img| {
                    try self.renderImage(writer, img, content_height, size.cols);
                },
                .err => |err| {
                    try writer.print("\r\n   \x1B[1;31mErrore di decodifica:\x1B[0m\r\n   {s}\r\n", .{err});
                },
            }
        } else {
            try writer.writeAll("\r\n\r\n   \x1B[90mNessun file aperto.\x1B[0m\r\n");
            try writer.writeAll("   Premi \x1B[1;32mo\x1B[0m per aprire un file, o inseriscilo come argomento.\r\n");
        }

        try self.drawFooter(writer, size.rows, state);
        try stdout_writer.flush();
    }

    fn renderText(_: *TuiSink, writer: anytype, text: []const u8, offset: usize, height: usize) !void {
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

    fn renderCsv(self: *TuiSink, writer: anytype, csv: CsvData, offset: usize, filter: []const u8, height: usize) !void {
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
                // -| : su terminali minuscoli (height < 2) la sottrazione normale
                // andrebbe in underflow e la guardia non scatterebbe mai.
                if (printed >= height -| 2) break;

                // Color alternate rows for premium look
                const row_color = if (printed % 2 == 0) "" else "\x1B[2m";
                try writer.print("{s} ", .{row_color});

                for (row, 0..) |cell, i| {
                    if (i >= col_widths.len) break;
                    const width = col_widths[i];

                    // Sanifica la cella in un buffer fisso: la larghezza colonna è già
                    // limitata a 30, quindi bastano i primi `width` byte — zero
                    // allocazioni per cella. Il clamp a cell_buf.len è una cintura di
                    // sicurezza se il limite di larghezza dovesse cambiare.
                    var cell_buf: [30]u8 = undefined;
                    const clean_len = @min(cell.len, @min(width, cell_buf.len));
                    for (cell[0..clean_len], cell_buf[0..clean_len]) |c, *out| {
                        out.* = if (c == '\t' or c == '\n' or c == '\r') ' ' else c;
                    }
                    const trimmed = cell_buf[0..clean_len];
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
    }

    fn renderMarkdown(_: *TuiSink, writer: anytype, content: []const u8, offset: usize, height: usize) !void {
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

    fn renderMesh(self: *TuiSink, writer: anytype, mesh: decoder_mod.MeshData, state: *const state_mod.AppState, height: usize, cols: usize) !void {
        // Percorso GPU (Vulkan offscreen sul buffer memfd staged dal loader);
        // qualunque errore disattiva la GPU per la sessione e ripiega sul
        // wireframe CPU sottostante.
        if (!self.gpu_failed) {
            if (self.loaded.?.gpu) |*stage| {
                if (self.renderMeshGpu(writer, mesh, stage, state, height, cols)) {
                    return;
                } else |_| {
                    self.gpu_failed = true;
                    self.gpu_mesh_loaded = false;
                    if (self.gpu) |*g| {
                        g.deinit();
                        self.gpu = null;
                    }
                }
            }
        }

        const W = cols;
        const H = height;
        if (W == 0 or H == 0) return;
        if (mesh.num_vertices == 0) {
            try writer.writeAll("\r\n   Modello 3D vuoto.\r\n");
            return;
        }

        const pw = W;
        const ph = 2 * H;

        const color_grid = try self.gpa.alloc([3]u8, pw * ph);
        defer self.gpa.free(color_grid);
        @memset(color_grid, .{ 0, 0, 0 });

        const depth_grid = try self.gpa.alloc(f32, pw * ph);
        defer self.gpa.free(depth_grid);
        @memset(depth_grid, -std.math.inf(f32));

        const proj_vertices = try self.gpa.alloc(struct { x: i32, y: i32, z: f32 }, mesh.num_vertices);
        defer self.gpa.free(proj_vertices);

        const cos_y = @cos(state.yaw);
        const sin_y = @sin(state.yaw);
        const cos_p = @cos(state.pitch);
        const sin_p = @sin(state.pitch);

        const center = mesh.center;
        const size_x = mesh.bbox_max[0] - mesh.bbox_min[0];
        const size_y = mesh.bbox_max[1] - mesh.bbox_min[1];
        const size_z = mesh.bbox_max[2] - mesh.bbox_min[2];
        const max_size = @max(size_x, @max(size_y, size_z));

        const fit_w = @as(f32, @floatFromInt(pw)) * 0.7;
        const fit_h = @as(f32, @floatFromInt(ph)) * 0.7;
        const fit_dim = @min(fit_w, fit_h);
        const scale = if (max_size > 0.0) fit_dim / max_size else 1.0;

        for (mesh.vertices, 0..) |v, i| {
            const cx = v[0] - center[0];
            const cy = v[1] - center[1];
            const cz = v[2] - center[2];

            const rx = cx * cos_y - cz * sin_y;
            const rz = cx * sin_y + cz * cos_y;

            const ry = cy * cos_p - rz * sin_p;
            const rz2 = cy * sin_p + rz * cos_p;

            const px = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(pw)) / 2.0 + rx * scale)));
            const py = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(ph)) / 2.0 - ry * scale)));

            proj_vertices[i] = .{ .x = px, .y = py, .z = rz2 };
        }

        var min_z = std.math.inf(f32);
        var max_z = -std.math.inf(f32);
        for (proj_vertices) |pv| {
            min_z = @min(min_z, pv.z);
            max_z = @max(max_z, pv.z);
        }
        const span_z = max_z - min_z;

        for (mesh.faces) |face| {
            if (face.v1 >= mesh.num_vertices or face.v2 >= mesh.num_vertices or face.v3 >= mesh.num_vertices) continue;
            drawWireframeLine(color_grid, depth_grid, pw, ph, proj_vertices[face.v1], proj_vertices[face.v2], min_z, span_z);
            drawWireframeLine(color_grid, depth_grid, pw, ph, proj_vertices[face.v2], proj_vertices[face.v3], min_z, span_z);
            drawWireframeLine(color_grid, depth_grid, pw, ph, proj_vertices[face.v3], proj_vertices[face.v1], min_z, span_z);
        }

        var y: usize = 0;
        while (y < H) : (y += 1) {
            try writer.writeAll(" ");
            var x: usize = 0;
            while (x < W) : (x += 1) {
                const y_top = 2 * y;
                const y_bottom = 2 * y + 1;

                const idx_top = y_top * pw + x;
                const idx_bottom = y_bottom * pw + x;

                const z_top = depth_grid[idx_top];
                const z_bottom = depth_grid[idx_bottom];

                const top_set = z_top > -std.math.inf(f32);
                const bottom_set = z_bottom > -std.math.inf(f32);

                if (!top_set and !bottom_set) {
                    try writer.writeByte(' ');
                } else if (top_set and !bottom_set) {
                    const c_top = color_grid[idx_top];
                    try writer.print("\x1B[48;2;{d};{d};{d}m \x1B[0m", .{ c_top[0], c_top[1], c_top[2] });
                } else if (!top_set and bottom_set) {
                    const c_bot = color_grid[idx_bottom];
                    try writer.print("\x1B[38;2;{d};{d};{d}m▄\x1B[0m", .{ c_bot[0], c_bot[1], c_bot[2] });
                } else {
                    const c_top = color_grid[idx_top];
                    const c_bot = color_grid[idx_bottom];
                    try writer.print("\x1B[48;2;{d};{d};{d}m\x1B[38;2;{d};{d};{d}m▄\x1B[0m", .{
                        c_top[0], c_top[1], c_top[2],
                        c_bot[0], c_bot[1], c_bot[2],
                    });
                }
            }
            try writer.writeAll("\r\n");
        }
    }

    fn drawWireframeLine(color_grid: [][3]u8, depth_grid: []f32, W: usize, H: usize, p1: anytype, p2: anytype, min_z: f32, span_z: f32) void {
        const x1 = p1.x;
        const y1 = p1.y;
        const z1 = p1.z;
        const x2 = p2.x;
        const y2 = p2.y;
        const z2 = p2.z;

        const dx = x2 - x1;
        const dy = y2 - y1;
        const steps_i = @max(@abs(dx), @abs(dy));
        if (steps_i == 0) {
            if (x1 >= 0 and x1 < @as(i32, @intCast(W)) and y1 >= 0 and y1 < @as(i32, @intCast(H))) {
                const idx = @as(usize, @intCast(y1)) * W + @as(usize, @intCast(x1));
                if (z1 > depth_grid[idx]) {
                    depth_grid[idx] = z1;
                    const val = if (span_z > 0.0) (z1 - min_z) / span_z else 1.0;
                    color_grid[idx] = .{
                        @as(u8, @intFromFloat(20.0 * (1.0 - val) + 0.0 * val)),
                        @as(u8, @intFromFloat(30.0 * (1.0 - val) + 255.0 * val)),
                        @as(u8, @intFromFloat(100.0 * (1.0 - val) + 255.0 * val)),
                    };
                }
            }
            return;
        }

        const steps = @as(f32, @floatFromInt(steps_i));
        const x_inc = @as(f32, @floatFromInt(dx)) / steps;
        const y_inc = @as(f32, @floatFromInt(dy)) / steps;
        const z_inc = (z2 - z1) / steps;

        var fx = @as(f32, @floatFromInt(x1));
        var fy = @as(f32, @floatFromInt(y1));
        var fz = z1;

        var step: usize = 0;
        while (step <= steps_i) : (step += 1) {
            const px = @as(i32, @intFromFloat(@round(fx)));
            const py = @as(i32, @intFromFloat(@round(fy)));

            if (px >= 0 and px < @as(i32, @intCast(W)) and py >= 0 and py < @as(i32, @intCast(H))) {
                const idx = @as(usize, @intCast(py)) * W + @as(usize, @intCast(px));
                if (fz > depth_grid[idx]) {
                    depth_grid[idx] = fz;
                    const val = if (span_z > 0.0) (fz - min_z) / span_z else 1.0;
                    color_grid[idx] = .{
                        @as(u8, @intFromFloat(20.0 * (1.0 - val) + 0.0 * val)),
                        @as(u8, @intFromFloat(30.0 * (1.0 - val) + 255.0 * val)),
                        @as(u8, @intFromFloat(100.0 * (1.0 - val) + 255.0 * val)),
                    };
                }
            }

            fx += x_inc;
            fy += y_inc;
            fz += z_inc;
        }
    }

    /// Render GPU della mesh: rasterizzazione Vulkan del buffer staged, poi
    /// presentazione a piena risoluzione (kitty) o a mezzi-blocchi.
    fn renderMeshGpu(self: *TuiSink, writer: anytype, mesh: decoder_mod.MeshData, stage: *const loader_mod.GpuStage, state: *const state_mod.AppState, height: usize, cols: usize) !void {
        if (stage.index_bytes == 0 or height == 0 or cols == 0) return error.EmptyMesh;

        if (self.gpu == null) {
            self.gpu = try gpu_mod.Renderer.init(self.gpa, .{});
        }
        const g = &self.gpu.?;

        if (!self.gpu_mesh_loaded) {
            try g.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
            try g.setMeshMaterials(&mesh);
            self.gpu_mesh_loaded = true;
        }

        // Con il kitty graphics protocol si renderizza alla risoluzione pixel
        // reale dell'area; altrimenti 1 pixel per mezzo-blocco (cols × 2·rows).
        const size = getTerminalSize();
        const use_kitty = self.kitty and size.cell_w > 0 and size.cell_h > 0;
        const pw: u32 = if (use_kitty)
            @intCast(@min(cols * size.cell_w, 2048))
        else
            @intCast(cols);
        const ph: u32 = if (use_kitty)
            @intCast(@min(height * size.cell_h, 2048))
        else
            @intCast(height * 2);

        const size_x = mesh.bbox_max[0] - mesh.bbox_min[0];
        const size_y = mesh.bbox_max[1] - mesh.bbox_min[1];
        const size_z = mesh.bbox_max[2] - mesh.bbox_min[2];
        const max_size = @max(size_x, @max(size_y, size_z));

        const pc = gpu_mod.buildPushConstants(mesh.center, max_size, state.yaw, state.pitch, pw, ph, .{
            .base_color = mesh.base_color,
            .metallic = mesh.metallic,
            .roughness = mesh.roughness,
        });
        const rgba = try g.render(pw, ph, &pc);

        if (use_kitty) {
            try kittyTransmit(writer, rgba, pw, ph, 32, cols, height);
            self.kitty_image_shown = true;
        } else {
            try blitHalfBlocks(writer, rgba, pw, ph);
        }
    }

    fn renderImage(self: *TuiSink, writer: anytype, img: decoder_mod.ImageData, height: usize, cols: usize) !void {
        // Con kitty l'immagine viaggia a risoluzione piena e la scala il
        // terminale: niente downsampling a blocchi.
        if (self.kitty and img.width > 0 and img.height > 0) {
            const size = getTerminalSize();
            if (size.cell_w > 0 and size.cell_h > 0) {
                const avail_w_px = (cols -| 2) * size.cell_w;
                const avail_h_px = (height -| 1) * size.cell_h;
                if (avail_w_px > 0 and avail_h_px > 0) {
                    const scale_w = @as(f32, @floatFromInt(avail_w_px)) / @as(f32, @floatFromInt(img.width));
                    const scale_h = @as(f32, @floatFromInt(avail_h_px)) / @as(f32, @floatFromInt(img.height));
                    const scale = @min(scale_w, scale_h);
                    const out_w = @as(f32, @floatFromInt(img.width)) * scale;
                    const out_h = @as(f32, @floatFromInt(img.height)) * scale;
                    const cell_cols = @max(1, @as(usize, @intFromFloat(out_w / @as(f32, @floatFromInt(size.cell_w)))));
                    const cell_rows = @max(1, @as(usize, @intFromFloat(out_h / @as(f32, @floatFromInt(size.cell_h)))));
                    try kittyTransmit(writer, img.pixels, img.width, img.height, 24, cell_cols, cell_rows);
                    self.kitty_image_shown = true;
                    return;
                }
            }
        }

        const W = cols;
        const H = height;
        if (W == 0 or H == 0) return;

        const max_w = W - 2;
        const max_h = 2 * H - 2;

        const scale_w = @as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(img.width));
        const scale_h = @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(img.height));
        const scale = @min(1.0, @min(scale_w, scale_h));

        const render_w = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(img.width)) * scale)));
        const render_h = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(img.height)) * scale)));

        const pad_left = (W - render_w) / 2;

        var y: usize = 0;
        while (y < render_h) : (y += 2) {
            var k: usize = 0;
            while (k < pad_left) : (k += 1) try writer.writeByte(' ');

            var x: usize = 0;
            while (x < render_w) : (x += 1) {
                const src_x = @min(img.width - 1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(x)) / scale))));
                const src_y1 = @min(img.height - 1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(y)) / scale))));

                const r1 = img.pixels[(src_y1 * img.width + src_x) * 3 + 0];
                const g1 = img.pixels[(src_y1 * img.width + src_x) * 3 + 1];
                const b1 = img.pixels[(src_y1 * img.width + src_x) * 3 + 2];

                if (y + 1 < render_h) {
                    const src_y2 = @min(img.height - 1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(y + 1)) / scale))));
                    const r2 = img.pixels[(src_y2 * img.width + src_x) * 3 + 0];
                    const g2 = img.pixels[(src_y2 * img.width + src_x) * 3 + 1];
                    const b2 = img.pixels[(src_y2 * img.width + src_x) * 3 + 2];

                    try writer.print("\x1B[48;2;{d};{d};{d}m\x1B[38;2;{d};{d};{d}m▄", .{ r1, g1, b1, r2, g2, b2 });
                } else {
                    try writer.print("\x1B[48;2;{d};{d};{d}m ", .{ r1, g1, b1 });
                }
            }
            try writer.writeAll("\x1B[0m\r\n");
        }
    }
};
