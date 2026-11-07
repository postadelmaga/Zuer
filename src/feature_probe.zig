//! Prova headless delle funzionalità, per la CI di ogni piattaforma (soprattutto
//! macOS, dove la GUI non si può guidare): usa lo STESSO codice di zuer-gui —
//! registro dei plugin, player libav, uscita audio di zicro, renderer Vulkan — e
//! stampa un esito verificabile per ciascuna prova. Exit 0 solo se tutte passano.
//!
//!   feature-probe doc  <file>...        decode via plugin: tipo, dimensioni, pagine
//!   feature-probe page <file.pdf> <N>   pagina N di un PDF (navigazione)
//!   feature-probe video <file>          60 frame, seek a metà, decodifica hardware sì/no
//!   feature-probe audio <file>          audio decodificato e consegnato al dispositivo:
//!                                       SOLO con un file a traccia muta (anullsrc),
//!                                       la prova non deve mai essere udibile
//!   feature-probe gpu                   init renderer + render offscreen di un cubo
//!
//! Va lanciato dove zuer-gui troverebbe plugin e librerie: accanto all'eseguibile
//! del bundle (Contents/MacOS) o nella cartella dell'installazione Windows.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const decoder = @import("decoder.zig");
const player = @import("decoders/player.zig");
const audio_player = @import("audio_player.zig");
const gpu = @import("gpu_renderer.zig");
const loader = @import("loader.zig");

var failed = false;

fn report(ok: bool, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s} " ++ fmt ++ "\n", .{if (ok) "ok:" else "FALLITO:"} ++ args);
    if (!ok) failed = true;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const cmd = args.next() orelse return usage();

    if (std.mem.eql(u8, cmd, "doc")) {
        while (args.next()) |path| probeDoc(io, gpa, path, null);
    } else if (std.mem.eql(u8, cmd, "page")) {
        const path = args.next() orelse return usage();
        const n = std.fmt.parseInt(usize, args.next() orelse return usage(), 10) catch return usage();
        probeDoc(io, gpa, path, n);
    } else if (std.mem.eql(u8, cmd, "video")) {
        probeVideo(gpa, args.next() orelse return usage());
    } else if (std.mem.eql(u8, cmd, "audio")) {
        probeAudio(io, gpa, args.next() orelse return usage());
    } else if (std.mem.eql(u8, cmd, "gpu")) {
        probeGpu(gpa);
    } else return usage();
    decoder.closePluginCache(gpa);
    return if (failed) 1 else 0;
}

fn usage() u8 {
    std.debug.print("uso: feature-probe doc <file>... | page <pdf> <N> | video <file> | audio <file> | gpu\n", .{});
    return 2;
}

fn probeDoc(io: std.Io, gpa: std.mem.Allocator, path: []const u8, page: ?usize) void {
    var buf: [4096]u8 = undefined;
    const full = if (page) |n| std.fmt.bufPrint(&buf, "{s}#page={d}", .{ path, n }) catch path else path;
    var d = decoder.decode(full, io, gpa);
    defer d.deinit(gpa);
    const base = std.fs.path.basename(full);
    switch (d) {
        .err => |e| report(false, "{s}: errore \"{s}\"", .{ base, e }),
        .text => |t| report(t.len > 0, "{s}: testo, {d} byte", .{ base, t.len }),
        .markdown => |m| report(m.content.len > 0, "{s}: markdown, {d} byte", .{ base, m.content.len }),
        .csv => |c_| report(c_.rows.len > 0, "{s}: tabella, {d} righe", .{ base, c_.rows.len }),
        .workbook => |w| report(w.sheets.len > 0, "{s}: cartella di lavoro, {d} fogli", .{ base, w.sheets.len }),
        .mesh => |m| report(m.vertices.len > 0, "{s}: mesh, {d} vertici", .{ base, m.vertices.len }),
        .image => |im| {
            // Pagina PDF/poster: non vuota e non tutta di un colore.
            var lo: u8 = 255;
            var hi: u8 = 0;
            for (im.pixels) |p| {
                lo = @min(lo, p);
                hi = @max(hi, p);
            }
            report(im.width > 0 and im.height > 0 and hi > lo, "{s}: immagine {d}x{d}, pagine {d}, contrasto {d}..{d} ({s})", .{ base, im.width, im.height, im.total_pages, lo, hi, im.name });
        },
    }
}

fn probeVideo(gpa: std.mem.Allocator, path: []const u8) void {
    if (comptime !build_options.video) return report(false, "video non compilato", .{});
    const pz = gpa.dupeSentinel(u8, path, 0) catch return report(false, "memoria", .{});
    defer gpa.free(pz);
    var p = player.Player.openEx(pz.ptr, true) catch |e| return report(false, "video: apertura fallita: {s}", .{@errorName(e)});
    defer p.deinit();
    var frames: usize = 0;
    var last_pts: f64 = -1;
    var w: usize = 0;
    var h: usize = 0;
    while (frames < 60) {
        const f = (p.nextFrame(1920, gpa, null) catch |e| return report(false, "video: decode fallito dopo {d} frame: {s}", .{ frames, @errorName(e) })) orelse continue;
        w = f.width;
        h = f.height;
        last_pts = f.pts_s;
        frames += 1;
    }
    report(frames == 60 and w > 0 and h > 0, "video: {d} frame {d}x{d}, ultimo pts {d:.3}s, decodifica hardware: {s}", .{ frames, w, h, last_pts, if (p.hw_active) "sì" else "no" });
    p.seek(last_pts + 2.0);
    var after: ?f64 = null;
    var tries: usize = 0;
    while (after == null and tries < 200) : (tries += 1) {
        if (p.nextFrame(1920, gpa, null) catch null) |f| after = f.pts_s;
    }
    report(after != null and after.? >= last_pts + 1.0, "video: seek a {d:.3}s → primo frame a {d:.3}s", .{ last_pts + 2.0, after orelse -1 });
}

fn probeAudio(io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
    if (comptime !build_options.video) return report(false, "audio non compilato", .{});
    const pz = gpa.dupeSentinel(u8, path, 0) catch return report(false, "memoria", .{});
    defer gpa.free(pz);
    const ap = audio_player.AudioPlayer.start(pz.ptr, gpa) orelse
        return report(false, "audio: nessun player (libav, stream audio o dispositivo assenti)", .{});
    defer ap.stopAndDestroy();
    ap.setPlaying(true);
    var t: usize = 0;
    while (t < 30 and ap.clockSeconds() < 0.5) : (t += 1) io.sleep(.fromMilliseconds(100), .awake) catch {};
    const clk = ap.clockSeconds();
    report(clk >= 0.5, "audio: orologio di riproduzione a {d:.2}s dopo {d} ms (dispositivo che consuma campioni)", .{ clk, t * 100 });
}

fn probeGpu(gpa: std.mem.Allocator) void {
    if (comptime !build_options.gpu) return report(false, "renderer GPU non compilato", .{});
    var renderer = gpu.Renderer.init(gpa, .{}) catch |e| return report(false, "gpu: init fallita: {s}", .{@errorName(e)});
    defer renderer.deinit();
    var vertices = [_][3]f32{
        .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 },
        .{ -1, -1, 1 },  .{ 1, -1, 1 },  .{ 1, 1, 1 },  .{ -1, 1, 1 },
    };
    var faces = [_]decoder.Face{
        .{ .v1 = 0, .v2 = 1, .v3 = 2 }, .{ .v1 = 0, .v2 = 2, .v3 = 3 },
        .{ .v1 = 4, .v2 = 6, .v3 = 5 }, .{ .v1 = 4, .v2 = 7, .v3 = 6 },
        .{ .v1 = 0, .v2 = 4, .v3 = 5 }, .{ .v1 = 0, .v2 = 5, .v3 = 1 },
        .{ .v1 = 3, .v2 = 2, .v3 = 6 }, .{ .v1 = 3, .v2 = 6, .v3 = 7 },
        .{ .v1 = 0, .v2 = 3, .v3 = 7 }, .{ .v1 = 0, .v2 = 7, .v3 = 4 },
        .{ .v1 = 1, .v2 = 5, .v3 = 6 }, .{ .v1 = 1, .v2 = 6, .v3 = 2 },
    };
    const decoded: decoder.Decoded = .{ .mesh = .{
        .num_vertices = vertices.len,
        .num_faces = faces.len,
        .num_normals = 0,
        .bbox_min = .{ -1, -1, -1 },
        .bbox_max = .{ 1, 1, 1 },
        .center = .{ 0, 0, 0 },
        .name = "probe-cube",
        .vertices = &vertices,
        .faces = &faces,
    } };
    var stage = loader.stageToGpu(gpa, &decoded) orelse return report(false, "gpu: staging fallito", .{});
    defer stage.buffer.deinit(gpa);
    renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32))) catch |e|
        return report(false, "gpu: setMesh: {s}", .{@errorName(e)});
    const pc = gpu.buildPushConstants(.{ 0, 0, 0 }, 2.0, 0.6, 0.5, 256, 256, .{
        .base_color = .{ 0.85, 0.5, 0.2, 1 },
        .metallic = 0.0,
        .roughness = 0.5,
    });
    const rgba = renderer.renderSync(256, 256, &pc) catch |e| return report(false, "gpu: render: {s}", .{@errorName(e)});
    var covered: usize = 0;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        if (rgba[i + 3] != 0) covered += 1;
    }
    report(covered > 256 * 256 / 20, "gpu: cubo renderizzato offscreen, {d} pixel coperti su {d}", .{ covered, 256 * 256 });
}
