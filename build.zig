const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Two independent native capabilities, each with its own import-lib requirement:
    //  -Dvulkan: the offscreen Vulkan mesh/text renderer. Works on Linux (system loader)
    //            and Windows (vendored vulkan-1 import lib → runs on Wine's winevulkan).
    //  -Dffmpeg: the libav-backed native video player. Linux-only until FFmpeg Windows
    //            import libs are vendored (video files just don't open elsewhere).
    // On Windows zuer-gui is otherwise CPU-only (text/csv/image composited in software).
    const os_tag = target.result.os.tag;
    const vulkan_enabled = b.option(bool, "vulkan", "Link the Vulkan mesh/text renderer") orelse
        (os_tag == .linux or os_tag == .windows);
    const ffmpeg_enabled = b.option(bool, "ffmpeg", "Link the libav native video player") orelse
        (os_tag == .linux or os_tag == .windows);
    const build_opts = b.addOptions();
    // gui.zig/player.zig read `gpu` as "Vulkan renderer available"; `video` as "libav available".
    build_opts.addOption(bool, "gpu", vulkan_enabled);
    build_opts.addOption(bool, "video", ffmpeg_enabled);

    // Link the Vulkan loader into a module: system loader on Linux, the vendored
    // vulkan-1 import lib on Windows (vk.zig's `extern "vulkan"` emits `-lvulkan`).
    const LinkVk = struct {
        fn link(bld: *std.Build, m: *std.Build.Module, tgt: std.Build.ResolvedTarget) void {
            if (tgt.result.os.tag == .windows) m.addLibraryPath(bld.path("vendor/vulkan"));
            m.linkSystemLibrary("vulkan", .{});
        }
    };

    // Link libav (native video). Linux uses the system FFmpeg (pkg-config names have the
    // `lib` prefix); Windows uses the vendored headers + import libs under vendor/ffmpeg
    // (unversioned names → the versioned runtime DLLs fetched by scripts/fetch-ffmpeg-dlls.sh).
    const LinkAv = struct {
        fn link(bld: *std.Build, m: *std.Build.Module, tgt: std.Build.ResolvedTarget) void {
            if (tgt.result.os.tag == .windows) {
                m.addIncludePath(bld.path("vendor/ffmpeg/include"));
                m.addLibraryPath(bld.path("vendor/ffmpeg/lib"));
                m.linkSystemLibrary("avformat", .{});
                m.linkSystemLibrary("avcodec", .{});
                m.linkSystemLibrary("avutil", .{});
                m.linkSystemLibrary("swscale", .{});
            } else {
                m.linkSystemLibrary("libavformat", .{});
                m.linkSystemLibrary("libavcodec", .{});
                m.linkSystemLibrary("libavutil", .{});
                m.linkSystemLibrary("libswscale", .{});
            }
        }
    };

    // Obtain the Zicro dependency declared in build.zig.zon
    const dep_zicro = b.dependency("zicro", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_zrame = b.dependency("zrame", .{
        .target = target,
        .optimize = optimize,
    });

    // Shader GLSL → SPIR-V come build step: glslc gira solo quando i sorgenti
    // shader cambiano (output cached), quindi non pesa sulle build incrementali.
    const vert_cmd = b.addSystemCommand(&.{"glslc"});
    vert_cmd.addFileArg(b.path("src/shaders/mesh.vert"));
    vert_cmd.addArg("-o");
    const vert_spv = vert_cmd.addOutputFileArg("mesh.vert.spv");

    const frag_cmd = b.addSystemCommand(&.{"glslc"});
    frag_cmd.addFileArg(b.path("src/shaders/mesh.frag"));
    frag_cmd.addArg("-o");
    const frag_spv = frag_cmd.addOutputFileArg("mesh.frag.spv");

    // Shader della pipeline testo (atlante glifi su GPU).
    const tvert_cmd = b.addSystemCommand(&.{"glslc"});
    tvert_cmd.addFileArg(b.path("src/shaders/text.vert"));
    tvert_cmd.addArg("-o");
    const text_vert_spv = tvert_cmd.addOutputFileArg("text.vert.spv");

    const tfrag_cmd = b.addSystemCommand(&.{"glslc"});
    tfrag_cmd.addFileArg(b.path("src/shaders/text.frag"));
    tfrag_cmd.addArg("-o");
    const text_frag_spv = tfrag_cmd.addOutputFileArg("text.frag.spv");

    // Shader della shadow pass (depth-only dal punto di vista della luce).
    const svert_cmd = b.addSystemCommand(&.{"glslc"});
    svert_cmd.addFileArg(b.path("src/shaders/shadow.vert"));
    svert_cmd.addArg("-o");
    const shadow_vert_spv = svert_cmd.addOutputFileArg("shadow.vert.spv");

    const sfrag_cmd = b.addSystemCommand(&.{"glslc"});
    sfrag_cmd.addFileArg(b.path("src/shaders/shadow.frag"));
    sfrag_cmd.addArg("-o");
    const shadow_frag_spv = sfrag_cmd.addOutputFileArg("shadow.frag.spv");

    const vvert_cmd = b.addSystemCommand(&.{"glslc"});
    vvert_cmd.addFileArg(b.path("src/shaders/voxel.vert"));
    vvert_cmd.addArg("-o");
    const voxel_vert_spv = vvert_cmd.addOutputFileArg("voxel.vert.spv");

    const vfrag_cmd = b.addSystemCommand(&.{"glslc"});
    vfrag_cmd.addFileArg(b.path("src/shaders/voxel.frag"));
    vfrag_cmd.addArg("-o");
    const voxel_frag_spv = vfrag_cmd.addOutputFileArg("voxel.frag.spv");

    const exe = b.addExecutable(.{
        .name = "zuer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // libc è necessaria: senza, std.DynLib usa ElfDynLib (loader minimale
            // senza rilocazioni complete) e i plugin decoder crashano alla chiamata.
            .link_libc = true,
        }),
    });

    // Add Zicro module import
    exe.root_module.addImport("zicro", dep_zicro.module("zicro"));
    exe.root_module.addAnonymousImport("mesh_vert_spv", .{ .root_source_file = vert_spv });
    exe.root_module.addAnonymousImport("mesh_frag_spv", .{ .root_source_file = frag_spv });
    exe.root_module.addAnonymousImport("text_vert_spv", .{ .root_source_file = text_vert_spv });
    exe.root_module.addAnonymousImport("text_frag_spv", .{ .root_source_file = text_frag_spv });
    exe.root_module.addAnonymousImport("shadow_vert_spv", .{ .root_source_file = shadow_vert_spv });
    exe.root_module.addAnonymousImport("shadow_frag_spv", .{ .root_source_file = shadow_frag_spv });
    exe.root_module.addAnonymousImport("voxel_vert_spv", .{ .root_source_file = voxel_vert_spv });
    exe.root_module.addAnonymousImport("voxel_frag_spv", .{ .root_source_file = voxel_frag_spv });
    // The TUI pulls the Vulkan renderer through tui.zig (mesh preview).
    if (vulkan_enabled) LinkVk.link(b, exe.root_module, target);
    // Its GPU present forwards a memfd across processes (Linux kitty graphics protocol),
    // so the TUI is Linux-only for now; on other targets it isn't installed (mesh in the
    // *GUI* still works via a plain CPU staging buffer). Making the TUI cross-platform is
    // a follow-up (gate tui.zig's exportHandle present path).
    if (vulkan_enabled and os_tag == .linux) b.installArtifact(exe);

    const gui_exe = b.addExecutable(.{
        .name = "zuer-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // IMPORTANTE: `zuer-gui` importa zicro sia direttamente sia (transitivamente)
    // via zrame. Se prendessimo l'istanza da `dep_zicro` (builder di zuer) sarebbe
    // un modulo DISTINTO da quello che linka zrame (builder di zrame): il
    // `protocol.c` xdg-shell generato da zicro verrebbe compilato DUE volte →
    // `duplicate symbol xdg_wm_base_interface`. Prendiamo perciò l'unica istanza
    // di zicro dal builder di zrame, così protocol.c si compila una volta sola
    // (e i tipi zicro sono identici tra zuer e zrame).
    const gui_zicro = dep_zrame.builder.dependency("zicro", .{
        .target = target,
        .optimize = optimize,
    }).module("zicro");
    gui_exe.root_module.addImport("zicro", gui_zicro);
    gui_exe.root_module.addImport("zrame", dep_zrame.module("zrame"));
    gui_exe.root_module.addOptions("build_options", build_opts);
    gui_exe.root_module.addAnonymousImport("mesh_vert_spv", .{ .root_source_file = vert_spv });
    gui_exe.root_module.addAnonymousImport("mesh_frag_spv", .{ .root_source_file = frag_spv });
    gui_exe.root_module.addAnonymousImport("text_vert_spv", .{ .root_source_file = text_vert_spv });
    gui_exe.root_module.addAnonymousImport("text_frag_spv", .{ .root_source_file = text_frag_spv });
    gui_exe.root_module.addAnonymousImport("shadow_vert_spv", .{ .root_source_file = shadow_vert_spv });
    gui_exe.root_module.addAnonymousImport("shadow_frag_spv", .{ .root_source_file = shadow_frag_spv });
    gui_exe.root_module.addAnonymousImport("voxel_vert_spv", .{ .root_source_file = voxel_vert_spv });
    gui_exe.root_module.addAnonymousImport("voxel_frag_spv", .{ .root_source_file = voxel_frag_spv });
    // Vulkan mesh/text renderer: Linux + Windows (vendored import lib). On Windows this
    // presents through zrame's GDI backend after an offscreen render+readback.
    if (vulkan_enabled) LinkVk.link(b, gui_exe.root_module, target);
    if (ffmpeg_enabled) {
        // Player video nativo: il worker decodifica i frame in tempo reale con libav
        // (src/decoders/player.zig, importato da gui.zig), quindi il gui_exe linka
        // ffmpeg direttamente (finora era solo nel decoder .so per il poster).
        LinkAv.link(b, gui_exe.root_module, target);
        // Decoder VP9 su GPU compute (Vulkan): Linux-only (compute_vp9 non è portato su
        // Windows). Altrove player.zig ripiega sul decoder VP9 di libav (gate cvp9 in player).
        if (os_tag == .linux) gui_exe.root_module.linkSystemLibrary("compute_vp9", .{});
    }
    if (target.result.os.tag == .linux) gui_exe.root_module.linkSystemLibrary("wayland-client", .{});
    // Motore di testo nativo: stb_truetype rasterizza i glifi Hack (embeddati),
    // sostituendo ImageMagick/Pango. NB: `zuer-gui` linka zrame, che ora compila
    // la propria copia di stb_truetype_impl.c per il suo motore di testo. Per
    // evitare simboli duplicati nel binario, qui aggiungiamo SOLO l'include path
    // (serve al @cImport di glyph.zig): l'implementazione la fornisce zrame.
    gui_exe.root_module.addIncludePath(b.path("vendor/stb"));

    b.installArtifact(gui_exe);

    // Tool di sviluppo: rasterizza un file col percorso reale di text_render e
    // ne scrive il PPM, per verificare la resa headless (zig build raster-debug).
    const raster_dbg = b.addExecutable(.{
        .name = "raster-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/raster_debug.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addStbTruetype(b, raster_dbg.root_module);
    // Anche il percorso GPU (gpu_renderer + shader) per confrontare CPU vs atlante.
    raster_dbg.root_module.addAnonymousImport("mesh_vert_spv", .{ .root_source_file = vert_spv });
    raster_dbg.root_module.addAnonymousImport("mesh_frag_spv", .{ .root_source_file = frag_spv });
    raster_dbg.root_module.addAnonymousImport("text_vert_spv", .{ .root_source_file = text_vert_spv });
    raster_dbg.root_module.addAnonymousImport("text_frag_spv", .{ .root_source_file = text_frag_spv });
    raster_dbg.root_module.addAnonymousImport("shadow_vert_spv", .{ .root_source_file = shadow_vert_spv });
    raster_dbg.root_module.addAnonymousImport("shadow_frag_spv", .{ .root_source_file = shadow_frag_spv });
    raster_dbg.root_module.addAnonymousImport("voxel_vert_spv", .{ .root_source_file = voxel_vert_spv });
    raster_dbg.root_module.addAnonymousImport("voxel_frag_spv", .{ .root_source_file = voxel_frag_spv });
    LinkVk.link(b, raster_dbg.root_module, target);
    const raster_dbg_run = b.addRunArtifact(raster_dbg);
    if (b.args) |args| raster_dbg_run.addArgs(args);
    b.step("raster-debug", "Rasterizza un file su PPM (stdout)").dependOn(&raster_dbg_run.step);

    // Self-test headless del percorso GPU mesh (normali + shading PBR-ish):
    // renderizza un cubo offscreen e verifica copertura/variazione di luce.
    const gpu_selftest = b.addExecutable(.{
        .name = "gpu-selftest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu_selftest.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    gpu_selftest.root_module.addImport("zicro", dep_zicro.module("zicro"));
    gpu_selftest.root_module.addAnonymousImport("mesh_vert_spv", .{ .root_source_file = vert_spv });
    gpu_selftest.root_module.addAnonymousImport("mesh_frag_spv", .{ .root_source_file = frag_spv });
    gpu_selftest.root_module.addAnonymousImport("text_vert_spv", .{ .root_source_file = text_vert_spv });
    gpu_selftest.root_module.addAnonymousImport("text_frag_spv", .{ .root_source_file = text_frag_spv });
    gpu_selftest.root_module.addAnonymousImport("shadow_vert_spv", .{ .root_source_file = shadow_vert_spv });
    gpu_selftest.root_module.addAnonymousImport("shadow_frag_spv", .{ .root_source_file = shadow_frag_spv });
    gpu_selftest.root_module.addAnonymousImport("voxel_vert_spv", .{ .root_source_file = voxel_vert_spv });
    gpu_selftest.root_module.addAnonymousImport("voxel_frag_spv", .{ .root_source_file = voxel_frag_spv });
    LinkVk.link(b, gpu_selftest.root_module, target);
    const gpu_selftest_run = b.addRunArtifact(gpu_selftest);
    b.step("gpu-selftest", "Render headless di un cubo per validare la pipeline mesh").dependOn(&gpu_selftest_run.step);

    const decoder_mod = b.createModule(.{
        .root_source_file = b.path("src/decoder.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Compile decoders as shared library plugins
    inline for (.{ "text", "csv", "markdown", "mesh", "image", "glb", "archive", "media", "pdf", "office" }) |name| {
        const lib = b.addLibrary(.{
            .name = "decoder_" ++ name,
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/decoders/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "decoder", .module = decoder_mod },
                },
            }),
        });
        // stb_image è compilato dentro il plugin immagini: decodifica nativa di
        // PNG/JPEG/GIF/BMP senza dipendere da ImageMagick. -fno-sanitize=undefined
        // perché zig cc abilita UBSan di default e stb_image contiene UB benigno.
        if (comptime (std.mem.eql(u8, name, "image") or std.mem.eql(u8, name, "glb"))) {
            lib.root_module.addIncludePath(b.path("vendor/stb"));
            lib.root_module.addCSourceFile(.{
                .file = b.path("vendor/stb/stb_image_impl.c"),
                .flags = &.{ "-O2", "-fno-sanitize=undefined" },
            });
        }
        // The media decoder needs FFmpeg (+ compute_vp9); pdf/office shell out to external
        // tools and use POSIX temp dirs (mkdtemp). Both groups are Linux-only for now — on
        // a CPU-only target they're simply not installed, so their libav/POSIX deps never
        // reach the link. The core plugins (text/csv/markdown/mesh/image/glb/archive) build
        // everywhere.
        const needs_ffmpeg = comptime std.mem.eql(u8, name, "media");
        const needs_tools = comptime (std.mem.eql(u8, name, "pdf") or std.mem.eql(u8, name, "office"));
        if (needs_ffmpeg) {
            if (ffmpeg_enabled) {
                LinkAv.link(b, lib.root_module, target);
                // media importa player.zig (poster): serve build_options per il
                // gate cvp9 e il link della lib (il poster resta però su libav).
                lib.root_module.addOptions("build_options", build_opts);
                if (os_tag == .linux) lib.root_module.linkSystemLibrary("compute_vp9", .{});
                b.installArtifact(lib);
            }
        } else if (needs_tools) {
            if (os_tag == .linux) b.installArtifact(lib);
        } else {
            b.installArtifact(lib);
        }
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zuer");
    run_step.dependOn(&run_cmd.step);

    // Tool di sviluppo: chiama decoder.decode() su un file e stampa il risultato.
    const decode_dbg = b.addExecutable(.{
        .name = "decode-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decode_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const decode_run = b.addRunArtifact(decode_dbg);
    if (b.args) |args| decode_run.addArgs(args);
    b.step("decode-test", "Decodifica un file e stampa il risultato").dependOn(&decode_run.step);

    // Tool di sviluppo: itera i frame di un video col motore player.zig (libav).
    const player_dbg = b.addExecutable(.{
        .name = "player-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player_probe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    player_dbg.root_module.linkSystemLibrary("libavformat", .{});
    player_dbg.root_module.linkSystemLibrary("libavcodec", .{});
    player_dbg.root_module.linkSystemLibrary("libavutil", .{});
    player_dbg.root_module.linkSystemLibrary("libswscale", .{});
    player_dbg.root_module.addOptions("build_options", build_opts);
    player_dbg.root_module.linkSystemLibrary("compute_vp9", .{});
    const player_run = b.addRunArtifact(player_dbg);
    if (b.args) |args| player_run.addArgs(args);
    b.step("player-test", "Itera i frame video di un file (libav)").dependOn(&player_run.step);
}

/// Compila stb_truetype nel modulo e ne espone gli header a @cImport.
fn addStbTruetype(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor/stb"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_truetype_impl.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
}
