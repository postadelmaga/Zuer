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
//!   feature-probe audio-devices         dispositivi di uscita (Windows: WASAPI), "*" = predefinito
//!   feature-probe audio-tone <file> <Hz> [s]  SOLO CI, su un dispositivo VIRTUALE: riproduce
//!                                       il file e cattura in loopback il mix del dispositivo
//!                                       (WASAPI): il tono a <Hz> deve uscire davvero, e
//!                                       l'orologio deve avanzare per <s> secondi (default 3)
//!   feature-probe audio-survive <file> <s>  riproduce per <s> secondi stampando l'orologio
//!                                       ogni secondo: la CI intanto disattiva e riattiva il
//!                                       dispositivo; la riproduzione deve riprendere (ultimi
//!                                       3 s: l'orologio avanza di almeno 2 s)
//!   feature-probe gpu                   init renderer + render offscreen di un cubo
//!   feature-probe pixel <file> <fx> <fy> <r> <g> <b>
//!                                       colore del pixel in (fx, fy) ∈ [0,1]² entro
//!                                       ±48 per canale (ordine dei byte, orientamento)
//!   feature-probe fail <file> <testo>  il decode DEVE fallire con un errore che
//!                                       contiene <testo> (file corrotti, troppo grandi)
//!   feature-probe contains <file> <testo>  il testo/la tabella decodificati contengono <testo>
//!   feature-probe dump <file> <out.ppm> immagine decodificata in un PPM (confronti fra
//!                                       motori, es. poppler contro PDFium)
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
const zicro = @import("zicro");

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
    } else if (std.mem.eql(u8, cmd, "audio-devices")) {
        var buf: [4096]u8 = undefined;
        const n = zicro.audio_device.listOutputs(&buf);
        report(true, "dispositivi audio di uscita: {d}\n{s}", .{ n, std.mem.sliceTo(&buf, 0) });
    } else if (std.mem.eql(u8, cmd, "audio-tone")) {
        const path = args.next() orelse return usage();
        const hz = std.fmt.parseFloat(f64, args.next() orelse return usage()) catch return usage();
        const secs = if (args.next()) |a| std.fmt.parseFloat(f64, a) catch return usage() else 3.0;
        probeTone(io, gpa, path, hz, secs);
    } else if (std.mem.eql(u8, cmd, "audio-survive")) {
        const path = args.next() orelse return usage();
        const secs = std.fmt.parseInt(usize, args.next() orelse return usage(), 10) catch return usage();
        probeSurvive(io, gpa, path, secs);
    } else if (std.mem.eql(u8, cmd, "gpu")) {
        probeGpu(gpa);
    } else if (std.mem.eql(u8, cmd, "pixel")) {
        const path = args.next() orelse return usage();
        var v: [5]f64 = undefined;
        for (&v) |*x| x.* = std.fmt.parseFloat(f64, args.next() orelse return usage()) catch return usage();
        probePixel(io, gpa, path, v);
    } else if (std.mem.eql(u8, cmd, "fail")) {
        const path = args.next() orelse return usage();
        probeFail(io, gpa, path, args.next() orelse return usage());
    } else if (std.mem.eql(u8, cmd, "contains")) {
        const path = args.next() orelse return usage();
        probeContains(io, gpa, path, args.next() orelse return usage());
    } else if (std.mem.eql(u8, cmd, "dump")) {
        const path = args.next() orelse return usage();
        probeDump(io, gpa, path, args.next() orelse return usage());
    } else return usage();
    decoder.closePluginCache(gpa);
    return if (failed) 1 else 0;
}

fn usage() u8 {
    std.debug.print("uso: feature-probe doc <file>... | page <pdf> <N> | video <file> | audio <file> | gpu | pixel <file> <fx> <fy> <r> <g> <b> | fail <file> <testo> | dump <file> <out.ppm>\n", .{});
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
        // Righe di dati + intestazione (la prima riga del foglio): un foglio di una riga
        // sola ha zero righe di dati ma non è vuoto.
        .csv => |c_| report(c_.rows.len > 0 or c_.headers.len > 0, "{s}: tabella, {d} colonne, {d} righe dopo l'intestazione", .{ base, c_.headers.len, c_.rows.len }),
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

fn probePixel(io: std.Io, gpa: std.mem.Allocator, path: []const u8, v: [5]f64) void {
    var d = decoder.decode(path, io, gpa);
    defer d.deinit(gpa);
    const base = std.fs.path.basename(path);
    const im = switch (d) {
        .image => |im| im,
        else => return report(false, "{s}: non è un'immagine", .{base}),
    };
    const x: usize = @intFromFloat(@min(@as(f64, @floatFromInt(im.width - 1)), @max(0, v[0] * @as(f64, @floatFromInt(im.width)))));
    const y: usize = @intFromFloat(@min(@as(f64, @floatFromInt(im.height - 1)), @max(0, v[1] * @as(f64, @floatFromInt(im.height)))));
    const px = im.pixels[(y * im.width + x) * 3 ..][0..3];
    var ok = true;
    for (px, v[2..5]) |got, want| {
        if (@abs(@as(f64, @floatFromInt(got)) - want) > 48) ok = false;
    }
    report(ok, "{s}: pixel ({d},{d}) di {d}x{d} = {d},{d},{d} (atteso {d},{d},{d})", .{ base, x, y, im.width, im.height, px[0], px[1], px[2], v[2], v[3], v[4] });
}

fn probeFail(io: std.Io, gpa: std.mem.Allocator, path: []const u8, want: []const u8) void {
    var d = decoder.decode(path, io, gpa);
    defer d.deinit(gpa);
    const base = std.fs.path.basename(path);
    switch (d) {
        .err => |e| report(std.mem.indexOf(u8, e, want) != null, "{s}: errore atteso \"{s}\" ({s})", .{ base, e, want }),
        else => report(false, "{s}: decodificato, atteso un errore con \"{s}\"", .{ base, want }),
    }
}

fn probeContains(io: std.Io, gpa: std.mem.Allocator, path: []const u8, want: []const u8) void {
    var d = decoder.decode(path, io, gpa);
    defer d.deinit(gpa);
    const base = std.fs.path.basename(path);
    const found = switch (d) {
        .text => |t| std.mem.indexOf(u8, t, want) != null,
        .markdown => |m| std.mem.indexOf(u8, m.content, want) != null,
        .csv => |c_| blk: {
            for (c_.headers) |h| if (std.mem.indexOf(u8, h, want) != null) break :blk true;
            for (c_.rows) |r| for (r) |cell| if (std.mem.indexOf(u8, cell, want) != null) break :blk true;
            break :blk false;
        },
        .workbook => |w| blk: {
            for (w.sheets) |sh| {
                if (std.mem.indexOf(u8, sh.name, want) != null) break :blk true;
                for (sh.data.headers) |h| if (std.mem.indexOf(u8, h, want) != null) break :blk true;
                for (sh.data.rows) |r| for (r) |cell| if (std.mem.indexOf(u8, cell, want) != null) break :blk true;
            }
            break :blk false;
        },
        .err => |e| return report(false, "{s}: errore \"{s}\"", .{ base, e }),
        else => false,
    };
    report(found, "{s}: contiene \"{s}\"", .{ base, want });
}

fn probeDump(io: std.Io, gpa: std.mem.Allocator, path: []const u8, out: []const u8) void {
    var d = decoder.decode(path, io, gpa);
    defer d.deinit(gpa);
    const im = switch (d) {
        .image => |im| im,
        else => return report(false, "{s}: non è un'immagine", .{path}),
    };
    var f = std.Io.Dir.cwd().createFile(io, out, .{}) catch |e| return report(false, "dump: {s}", .{@errorName(e)});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var w = f.writer(io, &buf);
    w.interface.print("P6\n{d} {d}\n255\n", .{ im.width, im.height }) catch return report(false, "dump: scrittura", .{});
    w.interface.writeAll(im.pixels) catch return report(false, "dump: scrittura", .{});
    w.interface.flush() catch return report(false, "dump: scrittura", .{});
    report(true, "dump: {s} → {s} ({d}x{d})", .{ std.fs.path.basename(path), out, im.width, im.height });
}

fn probeVideo(gpa: std.mem.Allocator, path: []const u8) void {
    if (comptime !build_options.video) return report(false, "video non compilato", .{});
    const pz = gpa.dupeSentinel(u8, path, 0) catch return report(false, "memoria", .{});
    defer gpa.free(pz);
    var p = player.Player.openEx(pz.ptr, true) catch |e| return report(false, "video: apertura fallita: {s}", .{@errorName(e)});
    defer p.deinit();
    var frames: usize = 0;
    var last_pts: f64 = -1;
    var max_gap: f64 = 0;
    var went_back = false;
    var w: usize = 0;
    var h: usize = 0;
    while (frames < 60) {
        // null = fine del file: con meno di 60 frame la prova fallisce (non un ciclo infinito).
        const f = (p.nextFrame(1920, gpa, null) catch |e| return report(false, "video: decode fallito dopo {d} frame: {s}", .{ frames, @errorName(e) })) orelse break;
        // Senza `reuse` ogni frame è del chiamante.
        defer if (!p.reuse) gpa.free(f.pixels);
        w = f.width;
        h = f.height;
        if (frames > 0) {
            max_gap = @max(max_gap, f.pts_s - last_pts);
            if (f.pts_s <= last_pts) went_back = true;
        }
        last_pts = f.pts_s;
        frames += 1;
    }
    report(frames == 60 and w > 0 and h > 0, "video: {d} frame {d}x{d}, ultimo pts {d:.3}s, decodifica hardware: {s}", .{ frames, w, h, last_pts, if (p.hw_active) "sì" else "no" });
    // Pts strettamente crescenti e senza buchi oltre 3 frame: anche attraverso un
    // eventuale ripiego hw→sw (ZUER_TEST_HWFAIL_AFTER) la riproduzione è continua.
    report(max_gap < 0.11 and !went_back, "video: pts continui (salto massimo {d:.3}s{s})", .{ max_gap, if (went_back) ", ALL'INDIETRO" else "" });
    // Come la GUI (video_decoder.zig): il seek atterra sul keyframe PRECEDENTE e
    // nextFrame scarta i frame prima del target. Senza la soglia si misurerebbe il
    // keyframe, che nei file con GOP lunghi (uno ogni 3-12 s) sta secondi prima.
    const target = last_pts + 2.0;
    p.seek(target);
    var after: ?f64 = null;
    var tries: usize = 0;
    while (after == null and tries < 200) : (tries += 1) {
        if (p.nextFrame(1920, gpa, target) catch null) |f| {
            after = f.pts_s;
            if (!p.reuse) gpa.free(f.pixels);
        }
    }
    // Primo frame mostrato: quello che copre il target (entro un frame a 24 fps).
    report(after != null and after.? >= target - 0.05 and after.? < target + 1.0, "video: seek a {d:.3}s → primo frame a {d:.3}s", .{ target, after orelse -1 });
}

fn probeAudio(io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
    if (comptime !build_options.video) return report(false, "audio non compilato", .{});
    const pz = gpa.dupeSentinel(u8, path, 0) catch return report(false, "memoria", .{});
    defer gpa.free(pz);
    const ap = audio_player.AudioPlayer.start(pz.ptr, gpa) orelse
        return report(false, "audio: nessun player (libav, stream audio o dispositivo assenti)", .{});
    defer ap.stopAndDestroy();
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    ap.setPlaying(true);
    var t: usize = 0;
    while (t < 30 and ap.clockSeconds() < 0.5) : (t += 1) io.sleep(.fromMilliseconds(100), .awake) catch {};
    const clk = ap.clockSeconds();
    const wall: f64 = @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds - t0)) / 1e9;
    // Latenza riportata dal backend (PipeWire, WASAPI, AudioQueue): null = stima fissa.
    const lat = ap.dev.latencyFrames();
    report(clk >= 0.5, "audio: orologio di riproduzione a {d:.2}s dopo {d:.2}s reali (dispositivo che consuma campioni), latenza dal dispositivo: {?d} frame", .{ clk, wall, lat });
    // Il dispositivo suona in tempo reale: l'orologio (campioni inviati meno latenza)
    // non può superare il tempo trascorso, salvo la latenza hardware non inclusa.
    // Avanti di più = latenza sottostimata = video in anticipo sull'audio.
    if (lat != null) {
        report(clk <= wall + 0.05, "audio: orologio non in anticipo sul tempo reale (scarto {d:.3}s)", .{clk - wall});
    } else if (clk > wall + 0.05) {
        std.debug.print("avviso: orologio in anticipo di {d:.3}s sul tempo reale (backend senza latenza misurata)\n", .{clk - wall});
    }
}

/// Potenza (Goertzel) della frequenza `hz` in `x`, normalizzata sulla lunghezza.
fn goertzel(x: []const f32, rate: f64, hz: f64) f64 {
    const w = 2.0 * std.math.pi * hz / rate;
    const k = 2.0 * @cos(w);
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (x) |v| {
        const s0 = @as(f64, v) + k * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    const p = s1 * s1 + s2 * s2 - k * s1 * s2;
    const n: f64 = @floatFromInt(@max(x.len, 1));
    return p / (n * n);
}

fn probeTone(io: std.Io, gpa: std.mem.Allocator, path: []const u8, hz: f64, secs: f64) void {
    if (comptime !build_options.video) return report(false, "audio non compilato", .{});
    var loop = zicro.audio_device.Loopback.open() catch |e| return report(false, "audio-tone: loopback non disponibile: {s}", .{@errorName(e)});
    defer loop.close();
    const rate: f64 = @floatFromInt(loop.rate);
    const cap: usize = @intFromFloat(rate * (secs + 2.0));
    const cap_buf = gpa.alloc(f32, cap) catch return report(false, "memoria", .{});
    defer gpa.free(cap_buf);
    var got: usize = 0;

    const pz = gpa.dupeSentinel(u8, path, 0) catch return report(false, "memoria", .{});
    defer gpa.free(pz);
    const ap = audio_player.AudioPlayer.start(pz.ptr, gpa) orelse
        return report(false, "audio-tone: nessun player (libav, stream audio o dispositivo assenti)", .{});
    defer ap.stopAndDestroy();
    ap.setPlaying(true);
    var last_clk: f64 = 0;
    var steps: usize = 0;
    var lat_max: u32 = 0;
    const total_steps: usize = @intFromFloat(secs * 50);
    while (steps < total_steps) : (steps += 1) {
        io.sleep(.fromMilliseconds(20), .awake) catch {};
        if (got < cap_buf.len) got += loop.read(cap_buf[got..]) orelse 0;
        last_clk = ap.clockSeconds();
        if (ap.dev.latencyFrames()) |l| lat_max = @max(lat_max, l);
    }
    // Analisi sull'ultimo tratto pieno (si salta il primo 0,5 s: avvio del flusso).
    const skip: usize = @min(got, @as(usize, @intFromFloat(rate * 0.5)));
    const x = cap_buf[skip..got];
    var sq: f64 = 0;
    for (x) |v| sq += @as(f64, v) * v;
    const rms = @sqrt(sq / @as(f64, @floatFromInt(@max(x.len, 1))));
    const p_on = goertzel(x, rate, hz);
    const p_off = @max(goertzel(x, rate, hz * 1.37), goertzel(x, rate, hz * 0.73));
    const ratio = p_on / @max(p_off, 1e-20);
    report(x.len > @as(usize, @intFromFloat(rate)) and rms > 0.01 and ratio > 50, "audio-tone: catturati {d} campioni a {d} Hz dal mix, RMS {d:.4}, tono {d} Hz {d:.0}× sopra le frequenze vicine", .{ got, loop.rate, rms, hz, ratio });
    report(last_clk >= secs - 0.6, "audio-tone: orologio a {d:.2}s dopo {d:.1}s, latenza riportata dal dispositivo fino a {d} frame ({d:.0} ms)", .{ last_clk, secs, lat_max, @as(f64, @floatFromInt(lat_max)) * 1000.0 / 48000.0 });
}

fn probeSurvive(io: std.Io, gpa: std.mem.Allocator, path: []const u8, secs: usize) void {
    if (comptime !build_options.video) return report(false, "audio non compilato", .{});
    const pz = gpa.dupeSentinel(u8, path, 0) catch return report(false, "memoria", .{});
    defer gpa.free(pz);
    const ap = audio_player.AudioPlayer.start(pz.ptr, gpa) orelse
        return report(false, "audio-survive: nessun player", .{});
    defer ap.stopAndDestroy();
    ap.setPlaying(true);
    var clocks: [600]f64 = undefined;
    const n = @min(secs, clocks.len);
    for (0..n) |i| {
        io.sleep(.fromSeconds(1), .awake) catch {};
        clocks[i] = ap.clockSeconds();
        std.debug.print("  t={d}s orologio {d:.2}s latenza {?d} frame riaperture {?d}\n", .{ i + 1, clocks[i], ap.dev.latencyFrames(), ap.dev.reopens() });
    }
    if (n < 4) return report(false, "audio-survive: servono almeno 4 s", .{});
    // La rimozione deve essersi VISTA (dove il backend lo dice: WASAPI), altrimenti
    // l'orologio che avanza non prova niente.
    if (ap.dev.reopens()) |r| report(r >= 1, "audio-survive: flusso riaperto {d} volte dopo la rimozione", .{r});
    const tail = clocks[n - 1] - clocks[n - 4];
    report(tail >= 2.0, "audio-survive: negli ultimi 3 s l'orologio è avanzato di {d:.2}s (riproduzione ripresa)", .{tail});
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
