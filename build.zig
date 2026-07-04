const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    exe.root_module.linkSystemLibrary("vulkan", .{});

    b.installArtifact(exe);

    const gui_exe = b.addExecutable(.{
        .name = "zuer-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    gui_exe.root_module.addImport("zicro", dep_zicro.module("zicro"));
    gui_exe.root_module.addImport("zrame", dep_zrame.module("zrame"));
    gui_exe.root_module.addAnonymousImport("mesh_vert_spv", .{ .root_source_file = vert_spv });
    gui_exe.root_module.addAnonymousImport("mesh_frag_spv", .{ .root_source_file = frag_spv });
    gui_exe.root_module.addAnonymousImport("text_vert_spv", .{ .root_source_file = text_vert_spv });
    gui_exe.root_module.addAnonymousImport("text_frag_spv", .{ .root_source_file = text_frag_spv });
    gui_exe.root_module.addAnonymousImport("shadow_vert_spv", .{ .root_source_file = shadow_vert_spv });
    gui_exe.root_module.addAnonymousImport("shadow_frag_spv", .{ .root_source_file = shadow_frag_spv });
    gui_exe.root_module.addAnonymousImport("voxel_vert_spv", .{ .root_source_file = voxel_vert_spv });
    gui_exe.root_module.addAnonymousImport("voxel_frag_spv", .{ .root_source_file = voxel_frag_spv });
    gui_exe.root_module.linkSystemLibrary("vulkan", .{});
    gui_exe.root_module.linkSystemLibrary("wayland-client", .{});
    // Motore di testo nativo: stb_truetype rasterizza i glifi Hack (embeddati),
    // sostituendo ImageMagick/Pango. -fno-sanitize=undefined come per stb_image.
    addStbTruetype(b, gui_exe.root_module);

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
    raster_dbg.root_module.linkSystemLibrary("vulkan", .{});
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
    gpu_selftest.root_module.linkSystemLibrary("vulkan", .{});
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
        // Il plugin media decodifica video/audio nativamente con libav (ffmpeg):
        // primo frame come poster, e in prospettiva riproduzione completa.
        if (comptime std.mem.eql(u8, name, "media")) {
            lib.root_module.linkSystemLibrary("libavformat", .{});
            lib.root_module.linkSystemLibrary("libavcodec", .{});
            lib.root_module.linkSystemLibrary("libavutil", .{});
            lib.root_module.linkSystemLibrary("libswscale", .{});
        }
        b.installArtifact(lib);
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
