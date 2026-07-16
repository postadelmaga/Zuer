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
                m.linkSystemLibrary("swresample", .{}); // resample audio → f32 (player audio)
            } else {
                m.linkSystemLibrary("libavformat", .{});
                m.linkSystemLibrary("libavcodec", .{});
                m.linkSystemLibrary("libavutil", .{});
                m.linkSystemLibrary("libswscale", .{});
                m.linkSystemLibrary("libswresample", .{});
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
    shaders.addTo(exe.root_module);
    // TinySoundFont anche nella TUI: costo ~nullo (oggetto C cached) e
    // src/midi_player.zig resta importabile da entrambi i frontend. Il DeviceOut
    // di zicro su Linux richiede ALSA: la TUI è comunque installata solo su Linux.
    addTsf(b, exe.root_module);
    if (os_tag == .linux) exe.root_module.linkSystemLibrary("asound", .{});
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
    shaders.addTo(gui_exe.root_module);
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
    if (target.result.os.tag == .linux) {
        gui_exe.root_module.linkSystemLibrary("wayland-client", .{});
        gui_exe.root_module.linkSystemLibrary("asound", .{}); // backend audio zicro (ALSA)
    }
    // Backend audio zicro su Windows (waveOut/winmm).
    if (target.result.os.tag == .windows) {
        gui_exe.root_module.linkSystemLibrary("winmm", .{});
        // App GUI: senza questo l'exe è "console" e ogni avvio da Explorer/menu
        // Start apre anche un terminale. Gli errori su stdout spariscono, ma
        // sono già invisibili in quel contesto.
        gui_exe.subsystem = .Windows;
    }
    // Player MIDI nativo (src/midi_player.zig): synth TinySoundFont + parser
    // TinyMidiLoader, vendorizzati in vendor/tsf.
    addTsf(b, gui_exe.root_module);
    // Motore di testo nativo: stb_truetype rasterizza i glifi Hack (embeddati),
    // sostituendo ImageMagick/Pango. NB: `zuer-gui` linka zrame, che ora compila
    // la propria copia di stb_truetype_impl.c per il suo motore di testo. Per
    // evitare simboli duplicati nel binario, qui aggiungiamo SOLO l'include path
    // (serve al @cImport di glyph.zig): l'implementazione la fornisce zrame.
    gui_exe.root_module.addIncludePath(b.path("vendor/stb"));

    b.installArtifact(gui_exe);

    // Step veloce per il dev loop: `zig build gui` compila SOLO la GUI Linux
    // (zuer-gui), saltando la TUI `zuer` e i ~10 plugin decoder (che cambiano di
    // rado e restano in zig-out/bin dalla build completa precedente). Da usare
    // iterando sul codice GUI; per aggiornare i plugin o la TUI usare `zig build`.
    const gui_step = b.step("gui", "Compila solo la GUI Linux (zuer-gui), salta TUI e plugin");
    gui_step.dependOn(&b.addInstallArtifact(gui_exe, .{}).step);

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
    shaders.addTo(raster_dbg.root_module);
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
    shaders.addTo(gpu_selftest.root_module);
    LinkVk.link(b, gpu_selftest.root_module, target);
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
    LinkVk.link(b, gpu_shot.root_module, target);
    // Niente installArtifact: è un tool di sviluppo, lo step `gpu-shot` lo
    // compila già on demand senza pesare su ogni `zig build`.
    const gpu_shot_run = b.addRunArtifact(gpu_shot);
    if (b.args) |a| gpu_shot_run.addArgs(a);
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
                lib.root_module.addOptions("build_options", build_opts);
                if (os_tag == .linux) lib.root_module.linkSystemLibrary("compute_vp9", .{});
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
        player_dbg.root_module.addOptions("build_options", build_opts);
        if (os_tag == .linux) player_dbg.root_module.linkSystemLibrary("compute_vp9", .{});
        const player_run = b.addRunArtifact(player_dbg);
        if (b.args) |args| player_run.addArgs(args);
        b.step("player-test", "Itera i frame video di un file (libav)").dependOn(&player_run.step);
    } else {
        const fail = b.addFail("player-test richiede libav: ricompila senza -Dffmpeg=false");
        b.step("player-test", "Itera i frame video di un file (libav)").dependOn(&fail.step);
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
        const ndk = b.option([]const u8, "ndk", "Percorso dell'Android NDK (default: $ANDROID_NDK_HOME)") orelse
            b.graph.environ_map.get("ANDROID_NDK_HOME") orelse "";
        // API 24 (Android 7): la più bassa con tutte le AMotionEvent/ANativeWindow usate.
        const android_target = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .android,
            .android_api_level = 24,
        });
        if (ndk.len == 0) {
            android_step.dependOn(&b.addFail("Android NDK non trovato: passa -Dndk=<path> o esporta ANDROID_NDK_HOME").step);
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
            // "unable to provide libc for target …-android".
            const libc_conf = b.addWriteFiles().add("android-libc.conf", b.fmt(
                \\include_dir={s}
                \\sys_include_dir={s}
                \\crt_dir={s}
                \\msvc_lib_dir=
                \\kernel32_lib_dir=
                \\gcc_dir=
                \\
            , .{ sysroot_inc, sysroot_inc, sysroot_lib }));
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
            lib.root_module.addImport("zicro", zicro_android);
            lib.root_module.addIncludePath(arch_inc);
            lib.root_module.addIncludePath(.{ .cwd_relative = glue_dir });
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
fn addTsf(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor/tsf"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/tsf/tsf_impl.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
    if (mod.resolved_target) |t| {
        if (t.result.os.tag != .windows) mod.linkSystemLibrary("m", .{});
    }
}

/// Compila stb_truetype nel modulo e ne espone gli header a @cImport.
fn addStbTruetype(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor/stb"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_truetype_impl.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
}
