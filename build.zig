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
    gui_exe.root_module.linkSystemLibrary("vulkan", .{});
    gui_exe.root_module.linkSystemLibrary("wayland-client", .{});

    b.installArtifact(gui_exe);

    const decoder_mod = b.createModule(.{
        .root_source_file = b.path("src/decoder.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Compile decoders as shared library plugins
    inline for (.{ "text", "csv", "markdown", "mesh", "image", "glb", "archive", "media" }) |name| {
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
        if (comptime std.mem.eql(u8, name, "image")) {
            lib.root_module.addIncludePath(b.path("vendor/stb"));
            lib.root_module.addCSourceFile(.{
                .file = b.path("vendor/stb/stb_image_impl.c"),
                .flags = &.{ "-O2", "-fno-sanitize=undefined" },
            });
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
}
