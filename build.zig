const std = @import("std");
// Zicro's build.zig, for `addTextC` (the C half of its text module): a dependency's
// build.zig is importable, so the step is Zicro's own and cannot drift from it.
const zicro_build = @import("zicro");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Two independent native capabilities, each with its own import-lib requirement:
    //  -Dvulkan: the offscreen Vulkan mesh/text renderer. The loader is opened at runtime
    //            (src/renderer/vk_loader.zig): nothing links against it, so the binaries
    //            start without Vulkan and only the GPU renderer turns off.
    //  -Dffmpeg: the libav-backed native video player. Linux-only until FFmpeg Windows
    //            import libs are vendored (video files just don't open elsewhere).
    // On Windows zuer-gui is otherwise CPU-only (text/csv/image composited in software).
    const os_tag = target.result.os.tag;
    const vulkan_enabled = b.option(bool, "vulkan", "Link the Vulkan mesh/text renderer") orelse
        (os_tag == .linux or os_tag == .windows);
    const ffmpeg_enabled = b.option(bool, "ffmpeg", "Link the libav native video player") orelse
        (os_tag == .linux or os_tag == .windows);
    // libmpv (render API, EGL) per il video hardware-accelerato: percorso
    // Linux/Wayland-only (EGL + wl_display privato, vedi src/decoders/mpv_video.zig).
    const mpv_enabled = b.option(bool, "mpv", "Link libmpv render API for hw video (Linux only)") orelse
        (os_tag == .linux);
    const build_opts = b.addOptions();
    // Versione unica, da build.zig.zon: `zuer --version`, `zuer-gui --version`.
    const version: []const u8 = @import("build.zig.zon").version;
    build_opts.addOption([]const u8, "version", version);
    // gui.zig/player.zig read `gpu` as "Vulkan renderer available"; `video` as "libav available".
    build_opts.addOption(bool, "gpu", vulkan_enabled);
    build_opts.addOption(bool, "video", ffmpeg_enabled);
    build_opts.addOption(bool, "mpv", mpv_enabled);
    // Solo per zuer-gui: i simboli libav si risolvono a runtime (LoadLibrary/dlopen
    // al primo video) invece che dalla import table / DT_NEEDED, su entrambi gli OS
    // — così l'eseguibile non dipende dal soname di FFmpeg installato al momento
    // della build e un file non multimediale non tocca mai libavformat.
    build_opts.addOption(bool, "av_runtime", os_tag == .windows or os_tag == .linux);
    // Solo per zuer-gui: libmpv si risolve a runtime (dlopen al primo video con
    // mpv, vedi ensureMpv in src/decoders/mpv_video.zig) — così l'exe parte
    // anche senza mpv installato, ripiegando sul decoder FFmpeg esistente.
    // EGL/GL restano linkati diretti (vedi commento sul link di gui_exe sotto).
    build_opts.addOption(bool, "mpv_runtime", mpv_enabled and os_tag == .linux);

    // Variante per i consumer che linkano libav DIRETTAMENTE (plugin media,
    // tool player_dbg): per loro gli extern del cImport restano il percorso.
    const build_opts_linked = b.addOptions();
    build_opts_linked.addOption(bool, "gpu", vulkan_enabled);
    build_opts_linked.addOption(bool, "video", ffmpeg_enabled);
    build_opts_linked.addOption(bool, "av_runtime", false);

    // Il loader Vulkan NON si linka più: src/renderer/vk_loader.zig lo apre a
    // runtime (LoadLibrary/dlopen) alla prima init del renderer, così gli
    // eseguibili partono anche senza vulkan-1.dll / libvulkan.so.1 / MoltenVK.

    // Link libav (native video). Linux uses the system FFmpeg (pkg-config names have the
    // `lib` prefix); Windows uses the vendored headers + import libs under vendor/ffmpeg
    // (unversioned names → the versioned runtime DLLs fetched by scripts/fetch-ffmpeg-dlls.sh).
    // zuer-gui NON linka mai le lib/import lib, su nessun OS: player.zig risolve i
    // simboli a RUNTIME (LoadLibrary/dlopen al primo video) così l'exe parte anche
    // senza FFmpeg installato — usare `headersOnly` lì. I plugin (decoder_media) e i
    // tool di sviluppo (player-test) continuano a linkare direttamente.
    const LinkAv = struct {
        fn link(bld: *std.Build, m: *std.Build.Module, tgt: std.Build.ResolvedTarget) void {
            headersOnly(bld, m, tgt);
            if (tgt.result.os.tag == .windows) {
                m.addLibraryPath(bld.path("vendor/ffmpeg/lib"));
                m.linkSystemLibrary("avformat", .{});
                m.linkSystemLibrary("avcodec", .{});
                m.linkSystemLibrary("avutil", .{});
                m.linkSystemLibrary("swscale", .{});
                m.linkSystemLibrary("swresample", .{}); // resample audio → f32 (player audio)
            } else {
                m.linkSystemLibrary("libavformat", .{});
                m.linkSystemLibrary("libavcodec", .{});
                m.linkSystemLibrary("libavutil", .{});
                m.linkSystemLibrary("libswscale", .{});
                m.linkSystemLibrary("libswresample", .{});
            }
        }

        /// Solo gli header (modulo translate-c + include path), niente link. Su Windows sono i vendorati;
        /// su Linux quelli di sistema in /usr/include, già nel default search path del
        /// compilatore (nessun -I esplicito serve: pkg-config qui non è coinvolto).
        fn headersOnly(bld: *std.Build, m: *std.Build.Module, tgt: std.Build.ResolvedTarget) void {
            if (translateC(bld, m, "av_c", "src/c/av.h")) |tc| {
                if (tgt.result.os.tag == .windows) tc.addIncludePath(bld.path("vendor/ffmpeg/include"));
            }
            if (tgt.result.os.tag == .windows) {
                m.addIncludePath(bld.path("vendor/ffmpeg/include"));
            }
        }
    };

    // Obtain the Zicro dependency declared in build.zig.zon
    const dep_zicro = b.dependency("zicro", .{
        .target = target,
        .optimize = optimize,
    });

    // I quattro eseguibili con pipeline Vulkan importano lo stesso set di shader
    // SPIR-V: raccolti in una struct con un helper, per non ripetere gli import.
    const ShaderSpv = struct {
        mesh_vert: std.Build.LazyPath,
        mesh_frag: std.Build.LazyPath,
        text_vert: std.Build.LazyPath,
        text_frag: std.Build.LazyPath,
        shadow_vert: std.Build.LazyPath,
        shadow_frag: std.Build.LazyPath,
        voxel_vert: std.Build.LazyPath,
        voxel_frag: std.Build.LazyPath,

        fn addTo(self: @This(), m: *std.Build.Module) void {
            m.addAnonymousImport("mesh_vert_spv", .{ .root_source_file = self.mesh_vert });
            m.addAnonymousImport("mesh_frag_spv", .{ .root_source_file = self.mesh_frag });
            m.addAnonymousImport("text_vert_spv", .{ .root_source_file = self.text_vert });
            m.addAnonymousImport("text_frag_spv", .{ .root_source_file = self.text_frag });
            m.addAnonymousImport("shadow_vert_spv", .{ .root_source_file = self.shadow_vert });
            m.addAnonymousImport("shadow_frag_spv", .{ .root_source_file = self.shadow_frag });
            m.addAnonymousImport("voxel_vert_spv", .{ .root_source_file = self.voxel_vert });
            m.addAnonymousImport("voxel_frag_spv", .{ .root_source_file = self.voxel_frag });
        }
    };

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

    const shaders = ShaderSpv{
        .mesh_vert = vert_spv,
        .mesh_frag = frag_spv,
        .text_vert = text_vert_spv,
        .text_frag = text_frag_spv,
        .shadow_vert = shadow_vert_spv,
        .shadow_frag = shadow_frag_spv,
        .voxel_vert = voxel_vert_spv,
        .voxel_frag = voxel_frag_spv,
    };

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
    {
        const vopts = b.addOptions();
        vopts.addOption([]const u8, "version", version);
        exe.root_module.addOptions("version_info", vopts);
    }
    shaders.addTo(exe.root_module);
    // TinySoundFont anche nella TUI: costo ~nullo (oggetto C cached) e
    // src/midi_player.zig resta importabile da entrambi i frontend. Il DeviceOut
    // di zicro su Linux richiede ALSA: la TUI è comunque installata solo su Linux.
    addTsf(b, exe.root_module);
    if (os_tag == .linux) exe.root_module.linkSystemLibrary("asound", .{});
    // The TUI pulls the Vulkan renderer through tui.zig (mesh preview).
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

    // `zuer-gui` importa zicro sia direttamente sia (transitivamente) via zrame: zrame
    // è un modulo dello STESSO pacchetto zicro e importa la sua zicro, quindi c'è
    // un'istanza sola (protocol.c di xdg-shell compilato una volta, tipi identici).
    gui_exe.root_module.addImport("zicro", dep_zicro.module("zicro"));
    gui_exe.root_module.addImport("zrame", dep_zicro.module("zrame"));
    gui_exe.root_module.addOptions("build_options", build_opts);
    shaders.addTo(gui_exe.root_module);
    // Vulkan mesh/text renderer: Linux + Windows (vendored import lib). On Windows this
    // presents through zrame's GDI backend after an offscreen render+readback.
    if (ffmpeg_enabled) {
        // Player video nativo: il worker decodifica i frame in tempo reale con libav
        // (src/decoders/player.zig, importato da gui.zig). gui_exe non linka mai ffmpeg
        // (solo gli header, per il @cImport): i simboli si risolvono a runtime al primo
        // video (`ensureAv`, LoadLibrary su Windows/dlopen su Linux) così l'exe parte
        // anche senza FFmpeg installato o con un ffmpeg di sistema più recente/vecchio
        // (soname diverso), e aprire un file non multimediale non tocca mai libavformat.
        LinkAv.headersOnly(b, gui_exe.root_module, target);
        // Decoder VP9 su GPU compute (Vulkan): Linux-only (compute_vp9 non è portato su
        // Windows). Altrove player.zig ripiega sul decoder VP9 di libav (gate cvp9 in player).
        if (os_tag == .linux) {
            gui_exe.root_module.linkSystemLibrary("compute_vp9", .{});
            addCvp9C(b, gui_exe.root_module);
        }
    }
    if (target.result.os.tag == .linux) {
        gui_exe.root_module.linkSystemLibrary("wayland-client", .{});
        gui_exe.root_module.linkSystemLibrary("asound", .{}); // backend audio zicro (ALSA)
    }
    if (mpv_enabled) {
        // src/decoders/mpv_video.zig: decode+render video via libmpv (render API
        // OpenGL) su un contesto EGL indipendente (pbuffer 1x1, rendering vero
        // in un FBO), per il percorso hardware-accelerato. Header di sistema
        // già nel default include path (/usr/include/mpv, /usr/include/EGL,
        // /usr/include/GL) su Linux, niente -I esplicito. EGL/GL linkate dirette
        // (non risolte via dlopen): sono di fatto una dipendenza di qualunque
        // desktop Linux con uno stack grafico funzionante, come Vulkan qui
        // sopra. libmpv invece NON è detto sia installata: zuer-gui non la
        // linka mai (niente `linkSystemLibrary("mpv")`), i simboli si
        // risolvono a runtime al primo video con mpv (`ensureMpv`, dlopen) così
        // l'exe parte anche senza mpv, ripiegando sul decoder FFmpeg esistente.
        gui_exe.root_module.linkSystemLibrary("EGL", .{});
        gui_exe.root_module.linkSystemLibrary("GL", .{});
        gui_exe.root_module.linkSystemLibrary("gbm", .{}); // buffer dmabuf del video (mesa)
        addMpvC(b, gui_exe.root_module);
    }
    // Backend audio zicro su Windows (waveOut/winmm).
    if (target.result.os.tag == .windows) {
        gui_exe.root_module.linkSystemLibrary("winmm", .{});
        // App GUI: senza questo l'exe è "console" e ogni avvio da Explorer/menu
        // Start apre anche un terminale. Gli errori su stdout spariscono, ma
        // sono già invisibili in quel contesto.
        gui_exe.subsystem = .windows;
    }
    // Player MIDI nativo (src/midi_player.zig): synth TinySoundFont + parser
    // TinyMidiLoader, vendorizzati in vendor/tsf.
    addTsf(b, gui_exe.root_module);
    // Motore di testo nativo: stb_truetype rasterizza i glifi Hack (embeddati),
    // sostituendo ImageMagick/Pango. NB: `zuer-gui` linka zrame, che ora compila
    // la propria copia di stb_truetype_impl.c per il suo motore di testo. Per
    // evitare simboli duplicati nel binario, qui aggiungiamo SOLO gli header
    // (servono a glyph.zig): l'implementazione la fornisce zrame.
    addStbTruetypeHeaders(b, gui_exe.root_module);

    b.installArtifact(gui_exe);

    // Step veloce per il dev loop: `zig build gui` compila SOLO la GUI Linux
    // (zuer-gui), saltando la TUI `zuer` e i ~10 plugin decoder (che cambiano di
    // rado e restano in zig-out/bin dalla build completa precedente). Da usare
    // iterando sul codice GUI; per aggiornare i plugin o la TUI usare `zig build`.
    const gui_step = b.step("gui", "Compila solo la GUI Linux (zuer-gui), salta TUI e plugin");
    gui_step.dependOn(&b.addInstallArtifact(gui_exe, .{}).step);

    // Banco della pipeline video (src/video_bench.zig): lo stesso codice della GUI
    // (setupVideo/advanceVideo/deinit) senza finestra — CPU in play e in pausa,
    // latenza dei seek, fd e thread su N aperture/chiusure. Dipendenze come zuer-gui.
    if (ffmpeg_enabled and os_tag == .linux) {
        const vbench = b.addExecutable(.{
            .name = "zuer-video-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/video_bench.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        vbench.root_module.addImport("zicro", dep_zicro.module("zicro"));
        vbench.root_module.addImport("zrame", dep_zicro.module("zrame"));
        vbench.root_module.addOptions("build_options", build_opts);
        LinkAv.headersOnly(b, vbench.root_module, target);
        vbench.root_module.linkSystemLibrary("compute_vp9", .{});
        addCvp9C(b, vbench.root_module);
        vbench.root_module.linkSystemLibrary("wayland-client", .{});
        vbench.root_module.linkSystemLibrary("asound", .{});
        if (mpv_enabled) {
            vbench.root_module.linkSystemLibrary("EGL", .{});
            vbench.root_module.linkSystemLibrary("GL", .{});
            vbench.root_module.linkSystemLibrary("gbm", .{});
            addMpvC(b, vbench.root_module);
        }
        addStbTruetypeHeaders(b, vbench.root_module);
        b.step("video-bench", "Banco della pipeline video (zuer-video-bench)").dependOn(&b.addInstallArtifact(vbench, .{}).step);
    }

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
    // glyph.zig (raggiunto da raster_debug.zig) prende le LUT gamma da zicro.paint:
    // senza questo import lo step non compila — era già così prima di 0.17, lo step
    // semplicemente non veniva mai costruito.
    raster_dbg.root_module.addImport("zicro", dep_zicro.module("zicro"));
    // Solo gli header: l'implementazione di stb_truetype la porta già zicro, e
    // compilarla due volte duplica i simboli (stesso motivo di zuer-gui/zrame).
    addStbTruetypeHeaders(b, raster_dbg.root_module);
    // Anche il percorso GPU (gpu_renderer + shader) per confrontare CPU vs atlante.
    shaders.addTo(raster_dbg.root_module);
    const raster_dbg_run = b.addRunArtifact(raster_dbg);
    raster_dbg_run.addPassthruArgs();
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
    shaders.addTo(gpu_selftest.root_module);
    const gpu_selftest_run = b.addRunArtifact(gpu_selftest);
    b.step("gpu-selftest", "Render headless di un cubo per validare la pipeline mesh").dependOn(&gpu_selftest_run.step);

    // gpu-shot: screenshot headless di una mesh reale (decode+VT) in un PPM,
    // per ispezionare colori/geometria senza display. Stesso cablaggio del selftest.
    const gpu_shot = b.addExecutable(.{
        .name = "gpu-shot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu_shot.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    gpu_shot.root_module.addImport("zicro", dep_zicro.module("zicro"));
    shaders.addTo(gpu_shot.root_module);
    // Niente installArtifact: è un tool di sviluppo, lo step `gpu-shot` lo
    // compila già on demand senza pesare su ogni `zig build`.
    const gpu_shot_run = b.addRunArtifact(gpu_shot);
    gpu_shot_run.addPassthruArgs();
    b.step("gpu-shot", "Screenshot headless PPM di una mesh (decode+VT)").dependOn(&gpu_shot_run.step);

    const decoder_mod = b.createModule(.{
        .root_source_file = b.path("src/decoder.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Compile decoders as shared library plugins
    inline for (.{ "text", "csv", "markdown", "mesh", "image", "glb", "archive", "tar", "media", "pdf", "office" }) |name| {
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
        // reach the link. The core plugins (text/csv/markdown/mesh/image/glb/archive/tar) build
        // everywhere.
        const needs_ffmpeg = comptime std.mem.eql(u8, name, "media");
        const needs_tools = comptime (std.mem.eql(u8, name, "pdf") or std.mem.eql(u8, name, "office"));
        if (needs_ffmpeg) {
            if (ffmpeg_enabled) {
                LinkAv.link(b, lib.root_module, target);
                // media importa player.zig (poster): serve build_options per il
                // gate cvp9 e il link della lib (il poster resta però su libav).
                lib.root_module.addOptions("build_options", build_opts_linked);
                if (os_tag == .linux) {
                    lib.root_module.linkSystemLibrary("compute_vp9", .{});
                    addCvp9C(b, lib.root_module);
                }
                // TinyMidiLoader (vendor/tsf): la scheda MIDI mostra la durata
                // reale parsando il file con tml (vedi parseMidi in media.zig).
                addTsf(b, lib.root_module);
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
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run zuer");
    run_step.dependOn(&run_cmd.step);

    // Test unitari puri (nessuna dipendenza nativa): `zig build test`.
    const test_step = b.step("test", "Esegue i test unitari");
    for ([_][]const u8{ "src/detect.zig", "src/scheduler.zig", "src/thumbs.zig", "src/meshcache.zig", "src/wake.zig", "src/hwdec_caps.zig" }) |src_path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(src_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        t.root_module.addImport("zicro", dep_zicro.module("zicro")); // via card_grid
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        // Lo scroll delle griglie usa il passo e l'easing di zicro.
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/card_grid.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        t.root_module.addImport("zicro", dep_zicro.module("zicro"));
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        // Lo scrim dei controlli video: solo `paint` di zicro.
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/video_scrim.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        t.root_module.addImport("zicro", dep_zicro.module("zicro"));
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Benchmark di contesa: decode in primo piano mentre altri thread
    // decodificano in sfondo (`zig build bench-decode -- <fg> <bg...>`).
    const bench_dbg = b.addExecutable(.{
        .name = "bench-decode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_decode.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // Strumenti solo Linux (getrusage, /proc, perf_event_open): installati
    // solo lì, così la build Windows non li compila.
    if (target.result.os.tag == .linux) b.installArtifact(bench_dbg);
    const bench_run = b.addRunArtifact(bench_dbg);
    bench_run.addPassthruArgs();
    b.step("bench-decode", "Latenza di un decode con altri decode in sfondo").dependOn(&bench_run.step);

    // Benchmark headless della pipeline miniature (stesso codice della GUI):
    // `zig build bench-thumbnails -- <cartella> <seq|w1..w4|auto> [none|<cache>]`.
    const bench_th = b.addExecutable(.{
        .name = "bench-thumbnails",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_thumbnails.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    bench_th.root_module.addImport("zicro", dep_zicro.module("zicro")); // thumbs → card_grid
    // Strumenti solo Linux (getrusage, /proc, perf_event_open): installati
    // solo lì, così la build Windows non li compila.
    if (target.result.os.tag == .linux) b.installArtifact(bench_th);
    const bench_th_run = b.addRunArtifact(bench_th);
    bench_th_run.addPassthruArgs();
    b.step("bench-thumbnails", "Pipeline miniature headless, uno scenario per processo").dependOn(&bench_th_run.step);

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
    decode_run.addPassthruArgs();
    b.step("decode-test", "Decodifica un file e stampa il risultato").dependOn(&decode_run.step);

    // Tool di sviluppo: itera i frame di un video col motore player.zig (libav).
    // Stesso gating di gui_exe: LinkAv sceglie pkg-config (Linux) o vendor/ffmpeg
    // (Windows), compute_vp9 resta Linux-only; senza -Dffmpeg lo step fallisce
    // in configurazione con un messaggio chiaro.
    if (ffmpeg_enabled) {
        const player_dbg = b.addExecutable(.{
            .name = "player-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/player_probe.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        LinkAv.link(b, player_dbg.root_module, target);
        player_dbg.root_module.addOptions("build_options", build_opts_linked);
        if (os_tag == .linux) {
            player_dbg.root_module.linkSystemLibrary("compute_vp9", .{});
            addCvp9C(b, player_dbg.root_module);
        }
        const player_run = b.addRunArtifact(player_dbg);
        player_run.addPassthruArgs();
        b.step("player-test", "Itera i frame video di un file (libav)").dependOn(&player_run.step);
    } else {
        const fail = b.addFail("player-test richiede libav: ricompila senza -Dffmpeg=false");
        b.step("player-test", "Itera i frame video di un file (libav)").dependOn(&fail.step);
    }

    // Tool di sviluppo: verifica isolata del modulo mpv_video.zig (Fase 1 del
    // piano libmpv) — carica un file, pompa qualche frame, logga dimensioni e
    // media colore. Nessun collegamento a VideoDecoder/gui.zig ancora.
    if (mpv_enabled) {
        const mpv_dbg = b.addExecutable(.{
            .name = "mpv-video-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/mpv_video_probe.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        addMpvC(b, mpv_dbg.root_module);
        mpv_dbg.root_module.linkSystemLibrary("mpv", .{});
        mpv_dbg.root_module.linkSystemLibrary("EGL", .{});
        mpv_dbg.root_module.linkSystemLibrary("GL", .{});
        mpv_dbg.root_module.linkSystemLibrary("gbm", .{});
        mpv_dbg.root_module.linkSystemLibrary("wayland-client", .{});
        // Tool a link diretto (non passa da ensureMpv/dlopen): build_options con
        // mpv_runtime=false fa usare a mpv_video.zig la tabella statica.
        const mpv_dbg_opts = b.addOptions();
        mpv_dbg_opts.addOption(bool, "mpv_runtime", false);
        mpv_dbg.root_module.addOptions("build_options", mpv_dbg_opts);
        const mpv_run = b.addRunArtifact(mpv_dbg);
        mpv_run.addPassthruArgs();
        b.step("mpv-video-test", "Verifica isolata del modulo mpv_video.zig").dependOn(&mpv_run.step);
    }

    // `zig build android` — la libreria nativa dell'APK: `libzuer.so` per
    // aarch64-linux-android, caricata da NativeActivity (M1). Contiene il backend
    // finestra NDK di zicro (modulo `zicro_android`: canvas+text+window, senza lo
    // stack Wayland/ALSA che su Android non esiste), il nostro `android_main` e la
    // native_app_glue del NDK, che è ciò che espone `ANativeActivity_onCreate` —
    // il simbolo che il framework cerca nel .so. Impacchettato da
    // scripts/build-android-apk.sh; senza NDK lo step fallisce con un messaggio chiaro.
    {
        const android_step = b.step("android", "Compila libzuer.so per Android (aarch64)");
        // Solo esplicito (-Dndk): la cache di configurazione di Zig 0.17 non vede le
        // variabili d'ambiente — un ANDROID_NDK_HOME cambiato o tolto dopo un build ne
        // riusava la configurazione vecchia (riprodotto). scripts/build-android-apk.sh
        // lo passa come -Dndk.
        const ndk = b.option([]const u8, "ndk", "Percorso dell'Android NDK (richiesto)") orelse "";
        // API 24 (Android 7): la più bassa con tutte le AMotionEvent/ANativeWindow usate.
        const android_target = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .android,
            .android_api_level = 24,
        });
        if (ndk.len == 0) {
            android_step.dependOn(&b.addFail("Android NDK non indicato: passa -Dndk=<path>").step);
        } else {
            const glue_dir = b.pathJoin(&.{ ndk, "sources", "android", "native_app_glue" });
            const sysroot = b.pathJoin(&.{ ndk, "toolchains", "llvm", "prebuilt", "linux-x86_64", "sysroot" });
            const sysroot_inc = b.pathJoin(&.{ sysroot, "usr", "include" });
            const sysroot_lib = b.pathJoin(&.{ sysroot, "usr", "lib", "aarch64-linux-android", "24" });
            const lib = b.addLibrary(.{
                .name = "zuer",
                .linkage = .dynamic,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/android_main.zig"),
                    .target = android_target,
                    // ReleaseFast, non ReleaseSmall: l'interfaccia mobile è rasterizzata
                    // dalla CPU (canvas zicro), e -Os su un rasterizzatore costa più in
                    // frame che non guadagni in KB — l'APK cresce di poco, l'interfaccia
                    // diventa un'altra cosa.
                    .optimize = .ReleaseFast,
                    .link_libc = true,
                }),
            });
            // Zig non porta con sé una bionic: la libc di Android è quella del NDK, indicata
            // con un file libc (header + crt/lib dell'API level scelto). È il modo previsto
            // da Zig per una libc esterna — senza, `zig build-lib` rifiuta il target con
            // "unable to provide libc for target …-android". NB: in Zig 0.17 i campi sono
            // cambiati (`gcc_dir` → `cc_dir`, più `darwin_sdk_dir`): mancarne uno fa
            // fallire il parsing del file.
            const libc_conf = b.addWriteFiles().add("android-libc.conf", b.fmt(
                \\include_dir={s}
                \\sys_include_dir={s}
                \\crt_dir={s}
                \\msvc_lib_dir=
                \\kernel32_lib_dir=
                \\cc_dir={s}
                \\darwin_sdk_dir=
                \\
                // cc_dir è la dir di crtbegin/crtend: su Android (crtbegin_so.o,
                // crtend_so.o) è la stessa di crt_dir. In 0.17 non può più essere
                // vuota per i target linux, Android compreso.
            , .{ sysroot_inc, sysroot_inc, sysroot_lib, sysroot_lib }));
            lib.setLibCFile(libc_conf);
            // Header per-architettura del NDK (asm/*.h, tirati dentro da linux/types.h e
            // poll.h): stanno in una dir a parte che il file libc non copre. Serve a ENTRAMBI
            // i moduli con sorgenti C — il nostro (native_app_glue) e quello di zicro (stb).
            const arch_inc: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sysroot_inc, "aarch64-linux-android" }) };

            // I decoder in Zig puro (testo, CSV, markdown, ZIP, TAR, mesh, GLB, immagini)
            // sono gli stessi del desktop, ma qui LINKATI DENTRO la .so invece che caricati
            // come plugin: un APK carica solo la propria libreria, non c'è nessuna dlopen da
            // fare. Restano fuori solo media (ffmpeg), pdf e office, che dipendono da
            // librerie/eseguibili esterni che su Android non esistono.
            const decoder_android = b.createModule(.{
                .root_source_file = b.path("src/decoder.zig"),
                .target = android_target,
                .optimize = .ReleaseFast,
            });
            lib.root_module.addImport("decoder", decoder_android);

            const zicro_android = dep_zicro.module("zicro_android");
            zicro_android.addIncludePath(arch_inc);
            // Zig 0.17 ha rimosso `@cImport`: il modulo C di text.zig (header tradotti
            // + stb_truetype + HarfBuzz dove c'è) lo attacca `addTextC` di Zicro, sul
            // builder della dipendenza, perché il target di `zicro_android` lo decide
            // il consumatore (qui). Noi aggiungiamo solo ciò che è nostro: il NDK.
            // Include bionic, per-architettura e API level: la stessa funzione di Zicro
            // che usano Zrame e ZenFlow2, non una copia.
            if (!zicro_android.import_table.contains("text_c")) {
                _ = zicro_build.addTextCAndroid(dep_zicro.builder, zicro_android, android_target, .fast, ndk, 24);
            }
            lib.root_module.addImport("zicro", zicro_android);
            lib.root_module.addIncludePath(arch_inc);
            lib.root_module.addIncludePath(.{ .cwd_relative = glue_dir });
            // JNI/NDK per src/android_jni.zig (vedi src/c/android.h).
            if (translateC(b, lib.root_module, "jni_c", "src/c/android.h")) |tc| {
                tc.addIncludePath(arch_inc);
                tc.addIncludePath(.{ .cwd_relative = sysroot_inc });
                tc.defineCMacro("__ANDROID_API__", "24"); // vedi text_c qui sopra
                tc.defineCMacro("__ANDROID_MIN_SDK_VERSION__", "24");
            }
            lib.root_module.addCSourceFile(.{
                .file = .{ .cwd_relative = b.pathJoin(&.{ glue_dir, "android_native_app_glue.c" }) },
                .flags = &.{ "-O2", "-fno-sanitize=undefined" },
            });
            // stb_image: le anteprime e il viewer immagini dell'explorer mobile. Sul
            // desktop sta nel plugin decoder_image (dlopen); qui è linkato dentro la .so —
            // un APK carica solo la propria libreria, niente plugin da cercare.
            lib.root_module.addIncludePath(b.path("vendor/stb"));
            lib.root_module.addCSourceFile(.{
                .file = b.path("vendor/stb/stb_image_impl.c"),
                .flags = &.{ "-O2", "-fno-sanitize=undefined" },
            });
            lib.root_module.addLibraryPath(.{ .cwd_relative = sysroot_lib });
            lib.root_module.linkSystemLibrary("android", .{}); // ANativeWindow, AInputEvent…
            lib.root_module.linkSystemLibrary("log", .{}); // __android_log_* (usato dalla glue)
            // libjnigraphics: legge i pixel di un android.graphics.Bitmap direttamente da
            // nativo — è così che le anteprime prodotte dal framework (fotogramma video,
            // pagina PDF, HEIC) arrivano sul nostro canvas senza passare da un array Java.
            lib.root_module.linkSystemLibrary("jnigraphics", .{});
            const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "android/lib/arm64-v8a" } } });
            android_step.dependOn(&install.step);
        }
    }
}

/// Compila TinySoundFont + TinyMidiLoader (vendor/tsf) nel modulo e ne espone
/// gli header a @cImport. Come stb: -fno-sanitize=undefined perché tsf.h usa
/// il classico offsetof "a mano" su puntatore nullo (UB benigno che UBSan
/// altrimenti intercetterebbe a runtime). tsf usa le funzioni math C → libm
/// esplicita dove non è già dentro libc (su Windows sta nel CRT).
/// Un header C tradotto come modulo Zig.
///
/// Zig 0.17 ha rimosso il builtin `@cImport`: gli header che i sorgenti
/// includevano in-line passano ora da uno step translate-c e si importano per
/// nome. Gli umbrella header stanno in `src/c/` (uno per ogni vecchio blocco
/// `@cImport`). Ritorna lo step perché il chiamante vi aggiunga include path e
/// macro; `null` se il modulo ha già quell'import (gli helper sono chiamati su
/// moduli che a volte si sovrappongono) o se non ha ancora un target risolto.
fn translateC(
    b: *std.Build,
    mod: *std.Build.Module,
    name: []const u8,
    header: []const u8,
) ?*std.Build.Step.TranslateC {
    if (mod.import_table.contains(name)) return null;
    const tgt = mod.resolved_target orelse return null;
    const tc = b.addTranslateC(.{
        .root_source_file = b.path(header),
        .target = tgt,
        .optimize = mod.optimize orelse .debug,
        .link_libc = true,
    });
    mod.addImport(name, tc.createModule());
    return tc;
}

/// compute_vp9 (src/decoders/cvp9.zig): header del decoder VP9 su GPU compute.
fn addCvp9C(b: *std.Build, mod: *std.Build.Module) void {
    _ = translateC(b, mod, "cvp9_c", "src/c/cvp9.h");
}

/// libmpv + EGL + GL (src/decoders/mpv_video.zig): header di sistema, nessun -I.
fn addMpvC(b: *std.Build, mod: *std.Build.Module) void {
    _ = translateC(b, mod, "mpv_c", "src/c/mpv.h");
}

fn addTsf(b: *std.Build, mod: *std.Build.Module) void {
    if (translateC(b, mod, "tsf_c", "src/c/midi.h")) |tc| tc.addIncludePath(b.path("vendor/tsf"));
    mod.addIncludePath(b.path("vendor/tsf"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/tsf/tsf_impl.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
    if (mod.resolved_target) |t| {
        if (t.result.os.tag != .windows) mod.linkSystemLibrary("m", .{});
    }
}

/// Solo gli HEADER di stb_truetype: l'include path più il modulo translate-c
/// (`stb_c`, per glyph.zig). Nessuno dei due consumatori vuole anche
/// `stb_truetype_impl.c`: `zuer-gui` lo riceve da zrame e `raster-debug` da
/// zicro, e compilarlo una seconda volta duplica i simboli nel binario.
fn addStbTruetypeHeaders(b: *std.Build, mod: *std.Build.Module) void {
    if (translateC(b, mod, "stb_c", "src/c/stb.h")) |tc| tc.addIncludePath(b.path("vendor/stb"));
    mod.addIncludePath(b.path("vendor/stb"));
}
