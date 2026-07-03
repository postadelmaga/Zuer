//! zuer-gui — viewer GPU a finestra basato su zrame.
//!
//! Decodifica il file con gli stessi plugin di zuer, poi presenta in una
//! finestra Wayland zrame: le mesh sono rasterizzate dal renderer Vulkan
//! offscreen condiviso (`gpu_renderer.zig`), le immagini e testi sono
//! compositati a CPU; il frame finale RGBA viene inviato a zrame per la presentazione.

const std = @import("std");
const gpu = @import("gpu_renderer.zig");
const decoder_mod = @import("decoder.zig");
const loader_mod = @import("loader.zig");
const text_render = @import("text_render.zig");
const zrame = @import("zrame");
const zicro = @import("zicro");

// evdev key codes standard per Linux
const KEY_ESC: u32 = 1;
const KEY_UP: u32 = 103;
const KEY_DOWN: u32 = 108;
const KEY_LEFT: u32 = 105;
const KEY_RIGHT: u32 = 106;
const KEY_1: u32 = 2;
const KEY_2: u32 = 3;
const KEY_3: u32 = 4;
const KEY_4: u32 = 5;

fn composeFrame(
    composited_rgba: []u8,
    W: u32,
    H: u32,
    src_rgba: []const u8,
    src_w: u32,
    src_h: u32,
    is_text: bool,
    zoom: f32,
    pan_x: f32,
    pan_y: f32,
) void {
    // Calcolo dell'aspect ratio per l'adattamento (aspect-fit) a tutto schermo
    const src_aspect = @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(src_h));
    const win_aspect = @as(f32, @floatFromInt(W)) / @as(f32, @floatFromInt(H));

    var fit_w: u32 = 0;
    var fit_h: u32 = 0;
    if (src_aspect > win_aspect) {
        fit_w = W;
        fit_h = @intFromFloat(@round(@as(f32, @floatFromInt(W)) / src_aspect));
    } else {
        fit_h = H;
        fit_w = @intFromFloat(@round(@as(f32, @floatFromInt(H)) * src_aspect));
    }
    fit_w = @max(fit_w, 1);
    fit_h = @max(fit_h, 1);

    const zoomed_w = @as(f32, @floatFromInt(fit_w)) * zoom;
    const zoomed_h = @as(f32, @floatFromInt(fit_h)) * zoom;

    const fit_w_zoomed = @max(@as(u32, @intFromFloat(zoomed_w)), 1);
    const fit_h_zoomed = @max(@as(u32, @intFromFloat(zoomed_h)), 1);

    const fit_x = @divFloor(@as(i32, @intCast(W)) - @as(i32, @intCast(fit_w_zoomed)), 2) + @as(i32, @intFromFloat(pan_x));
    const fit_y = @divFloor(@as(i32, @intCast(H)) - @as(i32, @intCast(fit_h_zoomed)), 2) + @as(i32, @intFromFloat(pan_y));

    var py: u32 = 0;
    while (py < H) : (py += 1) {
        const idx_row = py * W * 4;
        const iy = @as(i32, @intCast(py));
        var px: u32 = 0;
        while (px < W) : (px += 1) {
            const idx = idx_row + px * 4;
            const ix = @as(i32, @intCast(px));

            if (iy >= fit_y and iy < fit_y + @as(i32, @intCast(fit_h_zoomed)) and
                ix >= fit_x and ix < fit_x + @as(i32, @intCast(fit_w_zoomed)))
            {
                const sx = @as(u32, @intCast(@divFloor((ix - fit_x) * @as(i32, @intCast(src_w)), @as(i32, @intCast(fit_w_zoomed)))));
                const sy = @as(u32, @intCast(@divFloor((iy - fit_y) * @as(i32, @intCast(src_h)), @as(i32, @intCast(fit_h_zoomed)))));

                const bounded_sx = @min(sx, src_w - 1);
                const bounded_sy = @min(sy, src_h - 1);
                const s_idx = (bounded_sy * src_w + bounded_sx) * 4;

                const sr = src_rgba[s_idx + 0];
                const sg = src_rgba[s_idx + 1];
                const sb = src_rgba[s_idx + 2];
                var sa = src_rgba[s_idx + 3];

                if (is_text and sr == 8 and sg == 8 and sb == 16) {
                    sa = 0;
                }

                composited_rgba[idx + 0] = sr;
                composited_rgba[idx + 1] = sg;
                composited_rgba[idx + 2] = sb;
                composited_rgba[idx + 3] = sa;
            } else {
                composited_rgba[idx + 0] = 0;
                composited_rgba[idx + 1] = 0;
                composited_rgba[idx + 2] = 0;
                composited_rgba[idx + 3] = 0;
            }
        }
    }
}

const GuiAppState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    // Stato file
    current_file_path: []const u8,
    file_list: std.ArrayList([]const u8),
    current_file_index: ?usize,

    // Variabili Zicro/Loader
    decoded: *decoder_mod.Decoded,
    stage_opt: *?loader_mod.GpuStage,
    renderer: *gpu.Renderer,

    // Variabili di stato rendering
    is_mesh: *bool,
    is_text: *bool,
    file_changed: *bool,
    zoom: *f32,
    static_rgba: *[]u8,
    static_w: *u32,
    static_h: *u32,
    mesh_center: *[3]f32,
    mesh_max_size: *f32,

    // Stato di trascinamento e rotazione 3D
    dragging: *bool,
    yaw: *f32,
    pitch: *f32,
    pan_x: *f32,
    pan_y: *f32,
    last_x: *f32,
    last_y: *f32,

    fn loadFile(self: *GuiAppState, new_path: []const u8) !void {
        // 1. Decodifica il nuovo file
        var new_decoded = decoder_mod.decode(new_path, self.io, self.gpa);
        if (new_decoded == .err) {
            std.debug.print("Errore nel caricamento del file {s}: {s}\n", .{ new_path, new_decoded.err });
            new_decoded.deinit(self.gpa);
            return;
        }

        // 2. Libera le vecchie risorse decodificate
        self.decoded.deinit(self.gpa);
        if (self.stage_opt.*) |*s| {
            s.buffer.deinit(self.gpa);
            self.stage_opt.* = null;
        }

        // 3. Aggiorna decoded
        self.decoded.* = new_decoded;

        // 4. Aggiorna percorso file corrente
        self.gpa.free(self.current_file_path);
        self.current_file_path = try self.gpa.dupe(u8, new_path);

        // 5. Aggiorna flag tipo
        self.is_mesh.* = self.decoded.* == .mesh;
        self.is_text.* = (self.decoded.* != .mesh and self.decoded.* != .image);

        // 6. Gestione rasterizzazione per formati testuali
        if (self.decoded.* != .mesh and self.decoded.* != .image) {
            const img = try text_render.render(self.gpa, self.io, self.decoded, std.fs.path.basename(self.current_file_path));
            self.decoded.deinit(self.gpa);
            self.decoded.* = .{ .image = img };
        }

        // 7. Aggiorna i dati per GPU/CPU
        if (self.is_mesh.*) {
            const m = self.decoded.mesh;
            self.stage_opt.* = loader_mod.stageToGpu(self.gpa, self.decoded) orelse return error.StageFailed;
            const stage = &self.stage_opt.*.?;
            try self.renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
            self.mesh_center.* = m.center;
            self.mesh_max_size.* = @max(m.bbox_max[0] - m.bbox_min[0], @max(m.bbox_max[1] - m.bbox_min[1], m.bbox_max[2] - m.bbox_min[2]));
        } else {
            const img = self.decoded.image;
            self.gpa.free(self.static_rgba.*);
            self.static_w.* = @intCast(img.width);
            self.static_h.* = @intCast(img.height);
            self.static_rgba.* = try self.gpa.alloc(u8, self.static_w.* * self.static_h.* * 4);
            for (0..self.static_w.* * self.static_h.*) |i| {
                self.static_rgba.*[i * 4 + 0] = img.pixels[i * 3 + 0];
                self.static_rgba.*[i * 4 + 1] = img.pixels[i * 3 + 1];
                self.static_rgba.*[i * 4 + 2] = img.pixels[i * 3 + 2];
                self.static_rgba.*[i * 4 + 3] = 255;
            }
        }

        self.zoom.* = 1.0;
        self.yaw.* = 0.0;
        self.pitch.* = 0.0;
        self.pan_x.* = 0.0;
        self.pan_y.* = 0.0;
        self.file_changed.* = true;
    }

    fn initFileList(self: *GuiAppState) !void {
        const dir_path = std.fs.path.dirname(self.current_file_path) orelse ".";
        var dir = try std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true });
        defer dir.close(self.io);

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind == .file) {
                try self.file_list.append(self.gpa, try self.gpa.dupe(u8, entry.name));
            }
        }

        std.mem.sort([]const u8, self.file_list.items, {}, struct {
            fn compare(context: void, a: []const u8, b: []const u8) bool {
                _ = context;
                return std.mem.order(u8, a, b) == .lt;
            }
        }.compare);

        const cur_filename = std.fs.path.basename(self.current_file_path);
        self.current_file_index = null;
        for (self.file_list.items, 0..) |f, idx| {
            if (std.mem.eql(u8, f, cur_filename)) {
                self.current_file_index = idx;
                break;
            }
        }
    }

    fn navigate(self: *GuiAppState, direction: i2) void {
        if (self.file_list.items.len <= 1) return;
        const current_idx = self.current_file_index orelse return;

        var next_idx: usize = 0;
        if (direction > 0) {
            next_idx = (current_idx + 1) % self.file_list.items.len;
        } else {
            if (current_idx == 0) {
                next_idx = self.file_list.items.len - 1;
            } else {
                next_idx = current_idx - 1;
            }
        }

        const dir_path = std.fs.path.dirname(self.current_file_path);
        const filename = self.file_list.items[next_idx];
        const new_path = if (dir_path) |dp|
            std.fs.path.join(self.gpa, &.{ dp, filename }) catch return
        else
            self.gpa.dupe(u8, filename) catch return;
        defer self.gpa.free(new_path);

        self.loadFile(new_path) catch |err| {
            std.debug.print("Impossibile caricare il file: {s}\n", .{@errorName(err)});
            return;
        };
        self.current_file_index = next_idx;
    }
};

fn keyCallback(win: *zrame.Window, key: u32, state: u32, user: ?*anyopaque) void {
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    const pressed = (state == 1);
    if (pressed) {
        if (key == KEY_ESC) {
            win.close();
        } else if (key == KEY_RIGHT or key == KEY_DOWN) {
            app_state.navigate(1);
        } else if (key == KEY_LEFT or key == KEY_UP) {
            app_state.navigate(-1);
        } else if (key == KEY_1) {
            win.setStyle(zrame.Style.fluent()) catch {};
        } else if (key == KEY_2) {
            win.setStyle(zrame.Style.macos()) catch {};
        } else if (key == KEY_3) {
            win.setStyle(zrame.Style.aurora()) catch {};
        } else if (key == KEY_4) {
            win.setStyle(zrame.Style.material()) catch {};
        }
    }
}

fn scrollCallback(win: *zrame.Window, axis: u32, value: i32, user: ?*anyopaque) void {
    _ = win;
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    if (axis == 0) {
        const val = @as(f32, @floatFromInt(value)) / 256.0;
        if (val < 0) {
            app_state.zoom.* *= 1.1;
        } else if (val > 0) {
            app_state.zoom.* /= 1.1;
        }

        if (app_state.zoom.* < 0.1) app_state.zoom.* = 0.1;
        if (app_state.zoom.* > 20.0) app_state.zoom.* = 20.0;

        app_state.file_changed.* = true;
    }
}

fn mouseCallback(win: *zrame.Window, event: zrame.MouseEvent, user: ?*anyopaque) void {
    _ = win;
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    switch (event) {
        .button => |btn| {
            // 0x110 = BTN_LEFT (click sinistro), 0x111 = BTN_RIGHT (click destro)
            if (btn.button == 0x110 or btn.button == 0x111) {
                app_state.dragging.* = (btn.state == 1);
            }
        },
        .motion => |mot| {
            if (app_state.dragging.*) {
                const dx = mot.x - app_state.last_x.*;
                const dy = mot.y - app_state.last_y.*;
                if (app_state.is_mesh.*) {
                    app_state.yaw.* += dx * 0.01;
                    app_state.pitch.* += dy * 0.01;
                } else {
                    app_state.pan_x.* += dx;
                    app_state.pan_y.* += dy;
                    app_state.file_changed.* = true;
                }
            }
            app_state.last_x.* = mot.x;
            app_state.last_y.* = mot.y;
        },
    }
}

fn renderWorker(
    win: *zrame.Window,
    state: *GuiAppState,
    composited_rgba: *[]u8,
    yaw: *const f32,
    pitch: *const f32,
    zoom: *const f32,
) void {
    var last_w: u32 = 0;
    var last_h: u32 = 0;

    var pacer_60 = zicro.time.Pacer.hz(state.io, 60.0);
    var pacer_20 = zicro.time.Pacer.hz(state.io, 20.0);

    while (!win.closed) {
        const cur_w = win.panel_w;
        const cur_h = win.panel_h;
        if (cur_w == 0 or cur_h == 0) {
            _ = pacer_20.tick();
            continue;
        }

        const size_changed = (cur_w != last_w or cur_h != last_h);
        const need_render = size_changed or state.file_changed.* or state.is_mesh.*;

        if (need_render) {
            state.file_changed.* = false;
            last_w = cur_w;
            last_h = cur_h;

            if (composited_rgba.len < cur_w * cur_h * 4) {
                state.gpa.free(composited_rgba.*);
                composited_rgba.* = state.gpa.alloc(u8, cur_w * cur_h * 4) catch break;
            }

            if (state.is_mesh.*) {
                const pc = gpu.buildPushConstants(state.mesh_center.*, state.mesh_max_size.* / zoom.*, yaw.*, pitch.*, cur_w, cur_h);
                const mesh_rgba = state.renderer.render(cur_w, cur_h, &pc) catch break;
                composeFrame(composited_rgba.*, cur_w, cur_h, mesh_rgba, cur_w, cur_h, false, 1.0, 0.0, 0.0);
            } else {
                composeFrame(composited_rgba.*, cur_w, cur_h, state.static_rgba.*, state.static_w.*, state.static_h.*, state.is_text.*, zoom.*, state.pan_x.*, state.pan_y.*);
            }

            win.presentRgba(cur_w, cur_h, composited_rgba.*);
        }

        if (state.is_mesh.*) {
            _ = pacer_60.tick();
        } else {
            _ = pacer_20.tick();
        }
    }
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Comunica ai plugin decoder che siamo in modalità GUI (quindi vogliamo la massima risoluzione possibile)
    _ = setenv("ZUER_GUI", "1", 1);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    defer decoder_mod.closePluginCache(gpa);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const file_path = args.next() orelse {
        std.debug.print("Uso: zuer-gui <file>\n", .{});
        std.process.exit(1);
    };

    var decoded = decoder_mod.decode(file_path, io, gpa);
    defer decoded.deinit(gpa);
    if (decoded == .err) {
        std.debug.print("Errore: {s}\n", .{decoded.err});
        std.process.exit(1);
    }
    var is_text = (decoded != .mesh and decoded != .image);
    if (decoded != .mesh and decoded != .image) {
        const img = text_render.render(gpa, io, &decoded, std.fs.path.basename(file_path)) catch |err| {
            std.debug.print("Impossibile visualizzare il contenuto: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        decoded.deinit(gpa);
        decoded = .{ .image = img };
    }

    var stage_opt: ?loader_mod.GpuStage = null;
    defer if (stage_opt) |*s| s.buffer.deinit(gpa);

    // Renderer Vulkan Offscreen (nessuna estensione swapchain WSI richiesta)
    var renderer = try gpu.Renderer.init(gpa, .{});
    defer renderer.deinit();

    var mesh_center: [3]f32 = .{ 0, 0, 0 };
    var mesh_max_size: f32 = 1;
    var is_mesh = decoded == .mesh;

    var static_rgba: []u8 = &.{};
    defer gpa.free(static_rgba);
    var static_w: u32 = 0;
    var static_h: u32 = 0;

    if (is_mesh) {
        const m = decoded.mesh;
        stage_opt = loader_mod.stageToGpu(gpa, &decoded) orelse return error.StageFailed;
        const stage = &stage_opt.?;
        try renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
        mesh_center = m.center;
        mesh_max_size = @max(m.bbox_max[0] - m.bbox_min[0], @max(m.bbox_max[1] - m.bbox_min[1], m.bbox_max[2] - m.bbox_min[2]));
    } else {
        const img = decoded.image;
        static_w = @intCast(img.width);
        static_h = @intCast(img.height);
        static_rgba = try gpa.alloc(u8, static_w * static_h * 4);
        for (0..static_w * static_h) |i| {
            static_rgba[i * 4 + 0] = img.pixels[i * 3 + 0];
            static_rgba[i * 4 + 1] = img.pixels[i * 3 + 1];
            static_rgba[i * 4 + 2] = img.pixels[i * 3 + 2];
            static_rgba[i * 4 + 3] = 255;
        }
    }

    var file_changed = false;
    var zoom: f32 = 1.0;
    var yaw: f32 = 0;
    var pitch: f32 = 0;
    var pan_x: f32 = 0;
    var pan_y: f32 = 0;
    var dragging = false;
    var last_x: f32 = 0;
    var last_y: f32 = 0;

    var gui_state = GuiAppState{
        .gpa = gpa,
        .io = io,
        .current_file_path = try gpa.dupe(u8, file_path),
        .file_list = .empty,
        .current_file_index = null,
        .decoded = &decoded,
        .stage_opt = &stage_opt,
        .renderer = &renderer,
        .is_mesh = &is_mesh,
        .is_text = &is_text,
        .file_changed = &file_changed,
        .zoom = &zoom,
        .static_rgba = &static_rgba,
        .static_w = &static_w,
        .static_h = &static_h,
        .mesh_center = &mesh_center,
        .mesh_max_size = &mesh_max_size,
        .dragging = &dragging,
        .yaw = &yaw,
        .pitch = &pitch,
        .pan_x = &pan_x,
        .pan_y = &pan_y,
        .last_x = &last_x,
        .last_y = &last_y,
    };
    defer {
        gpa.free(gui_state.current_file_path);
        for (gui_state.file_list.items) |f| gpa.free(f);
        gui_state.file_list.deinit(gpa);
    }
    try gui_state.initFileList();

    var composited_rgba: []u8 = &.{};
    defer gpa.free(composited_rgba);

    const win = try zrame.Window.init(gpa, .{
        .title = "zuer-gui",
        .app_id = "it.zuer.gui",
        .width = 1280,
        .height = 720,
        .on_key = keyCallback,
        .on_scroll = scrollCallback,
        .on_mouse = mouseCallback,
        .user = &gui_state,
        .style = zrame.Style.fluent(),
    });
    defer win.deinit();

    // Spawna il thread lavoratore per il rendering offscreen e compositing
    const thread = try std.Thread.spawn(.{}, renderWorker, .{ win, &gui_state, &composited_rgba, &yaw, &pitch, &zoom });
    defer thread.join();

    try win.run();
}
