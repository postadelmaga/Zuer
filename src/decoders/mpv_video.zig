//! Decodifica+rendering video via libmpv (render API OpenGL), su un contesto
//! EGL indipendente (pbuffer 1x1, il rendering vero va in un FBO nostro).
//! Percorso Linux/Wayland-only: sostituisce il vecchio tentativo di zero-copy
//! VAAPI custom (ritirato — si scontrava con un comportamento del compositor
//! fuori dal nostro controllo). mpv fa hwdec+color management internamente,
//! già maturo su questo stesso hardware/compositor (verificato più volte).
//!
//! mpv è l'UNICO motore della sessione: apre la sorgente una volta sola e fa
//! demux, decodifica (hw quando c'è), audio, sincronia A/V, seek, loop e rete
//! (riconnessione, cache, tracce DASH separate via `audio-add`). Il suo clock è
//! l'autorità temporale: Zuer lo legge (`time-pos`), non ne tiene un secondo.
//! Niente polling: mpv sveglia il thread di decodifica coi suoi callback
//! (`mpv_set_wakeup_callback` per gli eventi, `..._set_update_callback` per i
//! frame) sulla `Wake` del chiamante.

const std = @import("std");
const builtin = @import("builtin");

// src/c/mpv.h, tradotto dallo step translate-c di `addMpv` in build.zig.
pub const c = @import("mpv_c");

pub const InitError = error{
    MpvLibraryMissing,
    WaylandConnectFailed,
    EglGetDisplayFailed,
    EglInitializeFailed,
    EglBindApiFailed,
    EglChooseConfigFailed,
    EglCreateSurfaceFailed,
    EglCreateContextFailed,
    EglMakeCurrentFailed,
    MpvCreateFailed,
    MpvInitializeFailed,
    MpvRenderContextFailed,
};

// ── libmpv a runtime ─────────────────────────────────────────────────────────
// EGL/GL restano linkati diretti (come Vulkan altrove nel progetto: di fatto
// una dipendenza di qualunque desktop Linux con uno stack grafico funzionante).
// libmpv invece NON è detto sia installata — stesso ruolo di libav in
// player.zig: si carica al primo uso (`ensureMpv`, dlopen) così zuer-gui parte
// anche senza mpv, ripiegando sul decoder FFmpeg esistente in quel caso.
const bo = @import("build_options");
const mpv_dynamic = @hasDecl(bo, "mpv_runtime") and bo.mpv_runtime;

/// Tabella delle funzioni libmpv usate in questo file.
pub const MpvApi = struct {
    mpv_create: *const fn () callconv(.c) ?*c.struct_mpv_handle,
    mpv_set_option_string: *const fn (?*c.struct_mpv_handle, [*c]const u8, [*c]const u8) callconv(.c) c_int,
    mpv_initialize: *const fn (?*c.struct_mpv_handle) callconv(.c) c_int,
    mpv_terminate_destroy: *const fn (?*c.struct_mpv_handle) callconv(.c) void,
    mpv_render_context_create: *const fn ([*c]?*c.struct_mpv_render_context, ?*c.struct_mpv_handle, [*c]c.struct_mpv_render_param) callconv(.c) c_int,
    mpv_render_context_free: *const fn (?*c.struct_mpv_render_context) callconv(.c) void,
    mpv_render_context_update: *const fn (?*c.struct_mpv_render_context) callconv(.c) u64,
    mpv_render_context_render: *const fn (?*c.struct_mpv_render_context, [*c]c.struct_mpv_render_param) callconv(.c) c_int,
    mpv_command: *const fn (?*c.struct_mpv_handle, [*c][*c]const u8) callconv(.c) c_int,
    mpv_get_property: *const fn (?*c.struct_mpv_handle, [*c]const u8, c_uint, ?*anyopaque) callconv(.c) c_int,
    mpv_set_property: *const fn (?*c.struct_mpv_handle, [*c]const u8, c_uint, ?*anyopaque) callconv(.c) c_int,
    mpv_command_async: *const fn (?*c.struct_mpv_handle, u64, [*c][*c]const u8) callconv(.c) c_int,
    mpv_set_property_async: *const fn (?*c.struct_mpv_handle, u64, [*c]const u8, c_uint, ?*anyopaque) callconv(.c) c_int,
    mpv_wait_event: *const fn (?*c.struct_mpv_handle, f64) callconv(.c) [*c]c.struct_mpv_event,
    mpv_observe_property: *const fn (?*c.struct_mpv_handle, u64, [*c]const u8, c_uint) callconv(.c) c_int,
    mpv_set_wakeup_callback: *const fn (?*c.struct_mpv_handle, ?*const fn (?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) void,
    mpv_render_context_set_update_callback: *const fn (?*c.struct_mpv_render_context, ?*const fn (?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) void,
};

// Le firme qui sopra sono scritte a mano invece di `*const @TypeOf(c.x)`: il
// backend self-hosted (build Debug / install.sh --fast) emette DWARF per ogni
// `extern fn` anche solo referenziata a comptime, con una reloc al simbolo → il
// link di zuer-gui (che NON linka libmpv) fallisce con "undefined symbol …
// referenced by .debug_info". Con LLVM il riferimento è gratis: lì si verifica
// a comptime che ogni firma combaci con gli header, così restano allineate.
comptime {
    if (builtin.zig_backend == .stage2_llvm) {
        // 0.17 ha sostituito `fields` con liste parallele (`field_names`/`field_types`).
        const info = @typeInfo(MpvApi).@"struct";
        for (info.field_names, info.field_types) |fname, FieldType| {
            const Expected = *const @TypeOf(@field(c, fname));
            if (FieldType != Expected) @compileError("MpvApi." ++ fname ++ ": firma diversa dagli header, attesa " ++ @typeName(Expected));
        }
    }
}

const mpv_static: MpvApi = if (mpv_dynamic) undefined else blk: {
    var t: MpvApi = undefined;
    for (@typeInfo(MpvApi).@"struct".field_names) |fname| {
        @field(t, fname) = &@field(c, fname);
    }
    break :blk t;
};

var mpv_runtime_table: MpvApi = undefined;
var mpv_state: enum { unloaded, ok, failed } = if (mpv_dynamic) .unloaded else .ok;
var mpv_mutex: std.atomic.Mutex = .unlocked;

/// Le funzioni libmpv, pronte all'uso DOPO un `ensureMpv()` riuscito.
const api: *const MpvApi = if (mpv_dynamic) &mpv_runtime_table else &mpv_static;

/// true se libmpv è utilizzabile: carica `libmpv.so.2` al primo uso (dlopen) e
/// risolve la tabella; un fallimento è ricordato (non si ritenta), il chiamante
/// ripiega sul decoder FFmpeg esistente.
fn ensureMpv() bool {
    if (comptime !mpv_dynamic) return true;
    return ensureMpvRuntime();
}

fn ensureMpvRuntime() bool {
    while (!mpv_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer mpv_mutex.unlock();
    switch (mpv_state) {
        .ok => return true,
        .failed => return false,
        .unloaded => {},
    }
    mpv_state = .failed;

    const lib = std.c.dlopen("libmpv.so.2", .{ .NOW = true }) orelse {
        std.debug.print("zuer: libmpv non disponibile (libmpv.so.2 mancante): video hw via mpv disattivato\n", .{});
        return false;
    };
    // La libreria resta caricata per la vita del processo (mai dlclose): i
    // puntatori della tabella vivono dentro di lei.
    inline for (@typeInfo(MpvApi).@"struct".field_names) |fname| {
        const sym = std.c.dlsym(lib, fname) orelse {
            std.debug.print("zuer: simbolo libmpv mancante: {s}\n", .{fname});
            return false;
        };
        @field(mpv_runtime_table, fname) = @ptrCast(@alignCast(sym));
    }
    mpv_state = .ok;
    return true;
}

/// `ZUER_MPV_OPTS="chiave=valore,chiave=valore"`: opzioni mpv in più, applicate
/// dopo le nostre (diagnostica e messa a punto senza ricompilare).
fn applyUserOptions(mpv: *c.mpv_handle) void {
    const raw = std.c.getenv("ZUER_MPV_OPTS") orelse return;
    var it = std.mem.tokenizeScalar(u8, std.mem.span(raw), ',');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        var kb: [64]u8 = undefined;
        var vb: [256]u8 = undefined;
        const k = std.fmt.bufPrintSentinel(&kb, "{s}", .{kv[0..eq]}, 0) catch continue;
        const v = std.fmt.bufPrintSentinel(&vb, "{s}", .{kv[eq + 1 ..]}, 0) catch continue;
        if (api.mpv_set_option_string(mpv, k.ptr, v.ptr) < 0) std.log.warn("zuer video: opzione mpv rifiutata: {s}", .{kv});
    }
}

fn trace(comptime what: []const u8) void {
    if (std.c.getenv("ZUER_TRACE") == null) return;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const ms = @as(f64, @floatFromInt(@mod(@as(i64, ts.sec), 100))) * 1000.0 + @as(f64, @floatFromInt(ts.nsec)) / 1e6;
    std.debug.print("[trace {d:.1}] " ++ what ++ "\n", .{ms});
}

// ── Bersagli GPU (dmabuf) ────────────────────────────────────────────────────
// mpv rende RGB (con la sua gestione colore) direttamente in un buffer GBM
// condiviso col compositor: il frame va a schermo come un subsurface, senza
// readback né copie CPU. LINEAR + XBGR8888 perché ogni compositor li accetta
// (una creazione di wl_buffer rifiutata è un errore di protocollo, fatale):
// è anche un'immagine RGB come una wl_shm, quindi niente rappresentazione YUV
// da negoziare (il tentativo VAAPI di agosto si era arenato proprio lì).

/// DRM_FORMAT_XBGR8888 ('XB24'): byte R,G,B,X in memoria, come GL_RGBA8.
pub const drm_xbgr8888: u32 = 0x34324258;
pub const drm_mod_linear: u64 = 0;
const GBM_BO_USE_RENDERING: u32 = 1 << 2;
const GBM_BO_USE_LINEAR: u32 = 1 << 4;

/// Slot che ruotano: il compositor legge l'ultimo presentato mentre mpv scrive
/// il prossimo. Quattro coprono il frame a schermo più quelli in volo.
pub const gpu_slots = 4;

/// Un frame pronto nel suo dmabuf, da passare a `presentDmabuf`.
pub const GpuFrame = struct { slot: u8, fd: i32, width: u32, height: u32, stride: u32, fourcc: u32, modifier: u64 };

const GpuSlot = struct {
    bo: ?*c.gbm_bo = null,
    fd: c_int = -1,
    stride: u32 = 0,
    image: c.EGLImageKHR = null,
    tex: c.GLuint = 0,
    fbo: c.GLuint = 0,
    /// Per i buffer in pensione dopo un resize: liberabile da questo conteggio di
    /// presentazioni in poi (il compositor può averlo ancora in lettura).
    retire_at: u64 = 0,
};

const EglExt = struct {
    create_image: *const fn (c.EGLDisplay, c.EGLContext, c.EGLenum, c.EGLClientBuffer, [*c]const c.EGLint) callconv(.c) c.EGLImageKHR,
    destroy_image: *const fn (c.EGLDisplay, c.EGLImageKHR) callconv(.c) c.EGLBoolean,
    image_target_tex: *const fn (c.GLenum, ?*anyopaque) callconv(.c) void,
    query_display_attrib: *const fn (c.EGLDisplay, c.EGLint, *c.EGLAttrib) callconv(.c) c.EGLBoolean,
    query_device_string: *const fn (?*anyopaque, c.EGLint) callconv(.c) [*c]const u8,

    fn load() ?EglExt {
        var e: EglExt = undefined;
        inline for (.{
            .{ "create_image", "eglCreateImageKHR" },
            .{ "destroy_image", "eglDestroyImageKHR" },
            .{ "image_target_tex", "glEGLImageTargetTexture2DOES" },
            .{ "query_display_attrib", "eglQueryDisplayAttribEXT" },
            .{ "query_device_string", "eglQueryDeviceStringEXT" },
        }) |pair| {
            const f = c.eglGetProcAddress(pair[1]) orelse return null;
            @field(e, pair[0]) = @ptrCast(f);
        }
        return e;
    }
};

const GpuTargets = struct {
    ext: EglExt,
    drm_fd: c_int,
    gbm: *c.gbm_device,
    slots: [gpu_slots]GpuSlot = @splat(.{}),
    w: u32 = 0,
    h: u32 = 0,
    next: u8 = 0,
    presents: u64 = 0,
    retired: [2 * gpu_slots]GpuSlot = @splat(.{}),
    /// `glFinish` invece di `glFlush` prima di consegnare un frame (vedi `syncMode`).
    finish: bool = false,

    /// Il dispositivo GBM sulla stessa GPU del display EGL (quella del compositor).
    fn init(egl_display: c.EGLDisplay) !GpuTargets {
        const ext = EglExt.load() orelse return error.EglExtMissing;
        var dev: c.EGLAttrib = 0;
        if (ext.query_display_attrib(egl_display, c.EGL_DEVICE_EXT, &dev) == c.EGL_FALSE or dev == 0) return error.EglDeviceUnknown;
        const node = ext.query_device_string(@ptrFromInt(@as(usize, @intCast(dev))), c.EGL_DRM_RENDER_NODE_FILE_EXT);
        if (node == null) return error.NoRenderNode;
        const fd = std.c.open(node, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (fd < 0) return error.RenderNodeOpen;
        errdefer _ = std.c.close(fd);
        const gbm = c.gbm_create_device(fd) orelse return error.GbmDevice;
        trace("dmabuf: GBM pronto");
        const finish = syncMode();
        std.log.info("zuer video: dmabuf su {s} ({s}), consegna: {s}", .{
            glString(c.GL_RENDERER), std.mem.span(node), if (finish) "glFinish (driver senza sincronia implicita garantita)" else "glFlush + sincronia implicita (Mesa)",
        });
        return .{ .ext = ext, .drm_fd = fd, .gbm = gbm, .finish = finish };
    }

    /// Chi garantisce che il compositor non legga un frame a metà, e che mpv non
    /// riscriva un buffer che il compositor sta ancora campionando? Con Mesa la
    /// sincronia implicita del dmabuf: il lavoro GPU sottomesso (glFlush) lascia
    /// il suo fence sul buffer, la lettura del compositor lo attende, e la nostra
    /// scrittura successiva attende le sue letture. I driver non Mesa (NVIDIA
    /// proprietario) non la garantiscono: lì si consegna solo a GPU finita
    /// (glFinish). La scrittura dopo `wl_buffer.release` resta coperta solo dal
    /// rilascio stesso — senza fence espliciti (linux-drm-syncobj) è il massimo.
    /// `ZUER_VIDEO_SYNC=finish|flush` forza la scelta (diagnostica).
    fn syncMode() bool {
        if (std.c.getenv("ZUER_VIDEO_SYNC")) |v| return std.mem.eql(u8, std.mem.span(v), "finish");
        return std.mem.indexOf(u8, glString(c.GL_VERSION), "Mesa") == null;
    }

    fn glString(name: c.GLenum) []const u8 {
        const p = c.glGetString(name) orelse return "?";
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    }

    fn createSlot(t: *GpuTargets, display: c.EGLDisplay, w: u32, h: u32) !GpuSlot {
        var sl: GpuSlot = .{};
        errdefer t.freeSlot(display, &sl);
        sl.bo = c.gbm_bo_create(t.gbm, w, h, drm_xbgr8888, GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR) orelse return error.GbmAlloc;
        sl.fd = c.gbm_bo_get_fd(sl.bo);
        if (sl.fd < 0) return error.GbmExport;
        sl.stride = c.gbm_bo_get_stride(sl.bo);
        const attrs = [_]c.EGLint{
            c.EGL_WIDTH,                          @intCast(w),
            c.EGL_HEIGHT,                         @intCast(h),
            c.EGL_LINUX_DRM_FOURCC_EXT,           @bitCast(drm_xbgr8888),
            c.EGL_DMA_BUF_PLANE0_FD_EXT,          sl.fd,
            c.EGL_DMA_BUF_PLANE0_OFFSET_EXT,      0,
            c.EGL_DMA_BUF_PLANE0_PITCH_EXT,       @intCast(sl.stride),
            c.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, 0,
            c.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, 0,
            c.EGL_NONE,
        };
        sl.image = t.ext.create_image(display, c.EGL_NO_CONTEXT, c.EGL_LINUX_DMA_BUF_EXT, null, &attrs);
        if (sl.image == c.EGL_NO_IMAGE_KHR) return error.EglImport;
        c.glGenTextures(1, &sl.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, sl.tex);
        t.ext.image_target_tex(c.GL_TEXTURE_2D, sl.image);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glGenFramebuffers(1, &sl.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, sl.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, sl.tex, 0);
        if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) return error.FboIncomplete;
        return sl;
    }

    fn freeSlot(t: *GpuTargets, display: c.EGLDisplay, sl: *GpuSlot) void {
        if (sl.fbo != 0) c.glDeleteFramebuffers(1, &sl.fbo);
        if (sl.tex != 0) c.glDeleteTextures(1, &sl.tex);
        if (sl.image != null and sl.image != c.EGL_NO_IMAGE_KHR) _ = t.ext.destroy_image(display, sl.image);
        if (sl.fd >= 0) _ = std.c.close(sl.fd);
        if (sl.bo) |b| c.gbm_bo_destroy(b);
        sl.* = .{};
    }

    /// Cambio di taglia: i buffer vecchi vanno in pensione (il compositor può
    /// ancora leggerne uno) e si liberano dopo qualche presentazione.
    fn resize(t: *GpuTargets, display: c.EGLDisplay, w: u32, h: u32) void {
        for (&t.slots) |*sl| {
            if (sl.bo == null) continue;
            var placed = false;
            for (&t.retired) |*r| if (r.bo == null) {
                r.* = sl.*;
                r.retire_at = t.presents + 2 * gpu_slots;
                placed = true;
                break;
            };
            if (!placed) t.freeSlot(display, sl);
            sl.* = .{};
        }
        t.w = w;
        t.h = h;
        t.next = 0;
    }

    fn reap(t: *GpuTargets, display: c.EGLDisplay, all: bool) void {
        for (&t.retired) |*r| if (r.bo != null and (all or r.retire_at <= t.presents)) t.freeSlot(display, r);
    }

    fn deinit(t: *GpuTargets, display: c.EGLDisplay) void {
        for (&t.slots) |*sl| t.freeSlot(display, sl);
        t.reap(display, true);
        c.gbm_device_destroy(t.gbm);
        _ = std.c.close(t.drm_fd);
    }
};

/// Chiamate GL/EGL/mpv-render fatte da un thread diverso da quello che ha creato
/// il contesto (dovrebbe restare 0: lo legge il banco video).
pub var wrong_thread_calls: std.atomic.Value(u32) = .init(0);

fn checkThread(owner: std.Thread.Id, comptime what: []const u8) void {
    if (std.Thread.getCurrentId() == owner) return;
    _ = wrong_thread_calls.fetchAdd(1, .monotonic);
    std.log.err("zuer video: " ++ what ++ " fuori dal thread del contesto EGL", .{});
}

/// Frame RGBA appena letto dall'FBO — di proprietà del chiamante (slice in un
/// buffer passato da lui), valido solo fino alla prossima `renderFrame`.
pub const Frame = struct {
    width: u32,
    height: u32,
    pts_s: f64,
};

pub const MpvVideo = struct {
    wl_display: *c.wl_display,
    egl_display: c.EGLDisplay,
    egl_surface: c.EGLSurface,
    egl_context: c.EGLContext,
    egl_config: c.EGLConfig,
    mpv: *c.mpv_handle,
    render_ctx: *c.mpv_render_context,
    fbo: c.GLuint = 0,
    fbo_tex: c.GLuint = 0,
    fbo_w: c_int = 0,
    /// Pixel buffer object della lettura (vedi `readInto`) e la sua taglia in byte.
    pbo: c.GLuint = 0,
    pbo_size: usize = 0,
    fbo_h: c_int = 0,
    audio_url: ?[:0]const u8 = null,
    /// Il thread che ha creato il contesto EGL: l'unico che può usarlo e smontarlo.
    owner: std.Thread.Id,
    /// Bersagli dmabuf, creati al primo `renderGpu`; `gpu_off` dopo un fallimento.
    gpu: ?GpuTargets = null,
    gpu_off: bool = false,
    // Stato osservato (aggiornato da `pollEvents`, mai letto con chiamate sincrone).
    disp_w: i64 = 0,
    disp_h: i64 = 0,
    fps: f64 = 0,
    pos: f64 = 0,
    hwdec_buf: [32]u8 = undefined,
    hwdec_len: usize = 0,
    /// Un file è caricato e il suo END_FILE non è ancora arrivato: chi chiude
    /// aspetta l'END_FILE solo se è vero (dopo una fine o un errore non ne arriva
    /// un altro).
    file_active: bool = false,
    /// Il loop è stato spento per la sessione corrente (`setLoop(false)`).
    loop_off: bool = false,
    video_id: ?i64 = null,
    audio_id: ?i64 = null,
    /// Contatori mpv della sessione (vedi `observeAll`); `avsync_max` = |scarto
    /// audio−video| massimo visto, in secondi.
    drops: i64 = 0,
    delayed: i64 = 0,
    avsync_max: f64 = 0,
    /// Massimo |scarto A/V| dall'ultima lettura di `takeAvsyncWindow` (diagnostica a tempo).
    avsync_win: f64 = 0,

    /// Come la sessione usa mpv. `audio`: false solo per chi vuole il video muto
    /// (la riaccensione del video col 'v' mentre l'audio gira altrove).
    pub const Options = struct {
        audio: bool = true,
        /// Traccia audio in un URL separato (DASH di YouTube): aggiunta a file
        /// caricato con `audio-add`, così mpv la sincronizza come una traccia sua.
        audio_url: ?[:0]const u8 = null,
        /// Notificata (da thread di mpv) a ogni evento e a ogni nuovo frame.
        wake_ctx: ?*anyopaque = null,
        wake_fn: ?*const fn (?*anyopaque) callconv(.c) void = null,
    };

    pub fn init(opts: Options) InitError!MpvVideo {
        if (comptime builtin.os.tag != .linux) @compileError("MpvVideo è Linux-only");
        if (!ensureMpv()) return error.MpvLibraryMissing;

        trace("mpv libreria");
        const wl_display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(wl_display);

        const egl_display = c.eglGetPlatformDisplay(c.EGL_PLATFORM_WAYLAND_KHR, wl_display, null) orelse
            return error.EglGetDisplayFailed;
        var egl_major: c.EGLint = 0;
        var egl_minor: c.EGLint = 0;
        if (c.eglInitialize(egl_display, &egl_major, &egl_minor) == c.EGL_FALSE) return error.EglInitializeFailed;
        errdefer _ = c.eglTerminate(egl_display);
        if (c.eglBindAPI(c.EGL_OPENGL_API) == c.EGL_FALSE) return error.EglBindApiFailed;

        const config_attribs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_PBUFFER_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_NONE,
        };
        var egl_config: c.EGLConfig = undefined;
        var num_configs: c.EGLint = 0;
        if (c.eglChooseConfig(egl_display, &config_attribs, &egl_config, 1, &num_configs) == c.EGL_FALSE or num_configs == 0) {
            return error.EglChooseConfigFailed;
        }

        const pbuffer_attribs = [_]c.EGLint{ c.EGL_WIDTH, 1, c.EGL_HEIGHT, 1, c.EGL_NONE };
        const egl_surface = c.eglCreatePbufferSurface(egl_display, egl_config, &pbuffer_attribs);
        if (egl_surface == c.EGL_NO_SURFACE) return error.EglCreateSurfaceFailed;
        errdefer _ = c.eglDestroySurface(egl_display, egl_surface);

        const context_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION,       3,
            c.EGL_CONTEXT_MINOR_VERSION,       3,
            c.EGL_CONTEXT_OPENGL_PROFILE_MASK, c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            c.EGL_NONE,
        };
        const egl_context = c.eglCreateContext(egl_display, egl_config, c.EGL_NO_CONTEXT, &context_attribs);
        if (egl_context == c.EGL_NO_CONTEXT) return error.EglCreateContextFailed;
        errdefer _ = c.eglDestroyContext(egl_display, egl_context);

        if (c.eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context) == c.EGL_FALSE) {
            return error.EglMakeCurrentFailed;
        }

        trace("EGL pronto");
        const mpv = api.mpv_create() orelse return error.MpvCreateFailed;
        errdefer api.mpv_terminate_destroy(mpv);
        // auto-safe: solo gli hwdec che mpv considera affidabili, con ripiego
        // software automatico (anche a metà file, se il driver sbaglia un frame).
        _ = api.mpv_set_option_string(mpv, "hwdec", "auto-safe");
        _ = api.mpv_set_option_string(mpv, "aid", if (opts.audio) "auto" else "no");
        // Gli script Lua integrati (console, stats, menu…) partirebbero a ogni
        // istanza: in un'anteprima embedded non servono.
        _ = api.mpv_set_option_string(mpv, "load-scripts", "no");
        _ = api.mpv_set_option_string(mpv, "load-stats-overlay", "no");
        _ = api.mpv_set_option_string(mpv, "load-console", "no");
        _ = api.mpv_set_option_string(mpv, "load-select", "no");
        _ = api.mpv_set_option_string(mpv, "load-context-menu", "no");
        _ = api.mpv_set_option_string(mpv, "load-positioning", "no");
        _ = api.mpv_set_option_string(mpv, "load-commands", "no");
        _ = api.mpv_set_option_string(mpv, "load-auto-profiles", "no");
        _ = api.mpv_set_option_string(mpv, "osc", "no");
        _ = api.mpv_set_option_string(mpv, "ao", "pipewire,pulse,alsa");
        _ = api.mpv_set_option_string(mpv, "audio-client-name", "zuer");
        // La copertina di un mp3 non è un video: niente traccia video → il
        // chiamante ripiega sul visualizzatore audio di Zuer.
        _ = api.mpv_set_option_string(mpv, "audio-display", "no");
        // Il loop lo fa mpv (demuxer riavvolto, niente riapertura né seek esterni).
        _ = api.mpv_set_option_string(mpv, "loop-file", "inf");
        _ = api.mpv_set_option_string(mpv, "idle", "yes");
        _ = api.mpv_set_option_string(mpv, "ytdl", "no"); // gli URL arrivano già risolti
        _ = api.mpv_set_option_string(mpv, "network-timeout", "15");
        _ = api.mpv_set_option_string(mpv, "input-default-bindings", "no");
        _ = api.mpv_set_option_string(mpv, "terminal", "no");
        _ = api.mpv_set_option_string(mpv, "msg-level", "all=warn");
        _ = api.mpv_set_option_string(mpv, "vo", "libmpv");
        applyUserOptions(mpv);
        trace("mpv opzioni");
        if (api.mpv_initialize(mpv) < 0) return error.MpvInitializeFailed;
        trace("mpv_initialize");
        observeAll(mpv);
        if (opts.wake_fn) |f| api.mpv_set_wakeup_callback(mpv, f, opts.wake_ctx);

        var init_params = c.mpv_opengl_init_params{
            .get_proc_address = getProcAddress,
            .get_proc_address_ctx = null,
        };
        var params = [_]c.mpv_render_param{
            .{ .type = c.MPV_RENDER_PARAM_API_TYPE, .data = @ptrCast(@constCast("opengl")) },
            .{ .type = c.MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, .data = &init_params },
            .{ .type = c.MPV_RENDER_PARAM_WL_DISPLAY, .data = wl_display },
            .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        var render_ctx: ?*c.mpv_render_context = null;
        if (api.mpv_render_context_create(&render_ctx, mpv, &params) < 0) return error.MpvRenderContextFailed;
        trace("mpv_render_context_create");
        if (opts.wake_fn) |f| api.mpv_render_context_set_update_callback(render_ctx.?, f, opts.wake_ctx);

        return .{
            .wl_display = wl_display,
            .egl_display = egl_display,
            .egl_surface = egl_surface,
            .egl_context = egl_context,
            .egl_config = egl_config,
            .mpv = mpv,
            .render_ctx = render_ctx.?,
            .audio_url = opts.audio_url,
            .owner = std.Thread.getCurrentId(),
        };
    }

    fn getProcAddress(ctx: ?*anyopaque, name: [*c]const u8) callconv(.c) ?*anyopaque {
        _ = ctx;
        return @ptrCast(@constCast(c.eglGetProcAddress(name)));
    }

    /// Da chiamare sul thread che ha fatto `init` (il contesto EGL è corrente lì):
    /// la pulizia GL e quella del render context di mpv lo richiedono. Rilascia
    /// anche il display EGL (e con lui il fd DRM) prima di chiudere la connessione.
    pub fn deinit(self: *MpvVideo) void {
        checkThread(self.owner, "deinit");
        if (self.gpu) |*g| g.deinit(self.egl_display);
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.fbo_tex != 0) c.glDeleteTextures(1, &self.fbo_tex);
        if (self.pbo != 0) c.glDeleteBuffers(1, &self.pbo);
        api.mpv_render_context_set_update_callback(self.render_ctx, null, null);
        api.mpv_render_context_free(self.render_ctx);
        api.mpv_set_wakeup_callback(self.mpv, null, null);
        api.mpv_terminate_destroy(self.mpv);
        _ = c.eglMakeCurrent(self.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        _ = c.eglDestroyContext(self.egl_display, self.egl_context);
        _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
        _ = c.eglTerminate(self.egl_display);
        _ = c.eglReleaseThread();
        c.wl_display_disconnect(self.wl_display);
        self.* = undefined;
    }

    // Dal thread di render NIENTE chiamate sincrone verso il core di mpv
    // (`mpv_command`, `mpv_get/set_property`): il core può star aspettando il VO,
    // che aspetta il nostro render — stallo sciolto solo dal timeout di 200 ms del
    // VO (log: "mpv_render_context_render() not being called or stuck"). Comandi
    // e scritture vanno asincroni, le letture arrivano come proprietà osservate.

    fn commandAsync(self: *MpvVideo, args: []const ?[*:0]const u8) void {
        _ = api.mpv_command_async(self.mpv, 0, @ptrCast(@constCast(args.ptr)));
    }

    /// Scarica la sorgente corrente: mpv torna inattivo (istanza, contesto e
    /// shader restano pronti per la prossima `loadFile`).
    pub fn stopPlayback(self: *MpvVideo) void {
        self.commandAsync(&.{ "stop", null });
    }

    /// Carica `path` in pausa (il primo frame diventa il poster; si riparte con
    /// `setPaused(false)`), con l'audio acceso o spento per questa sorgente.
    pub fn loadFile(self: *MpvVideo, path: [:0]const u8, audio: bool, start_s: f64) void {
        self.resetObserved();
        // `start` solo se serve: anche `start=0` è un seek preciso, e su un TS
        // senza indice (troncato, corrotto) mpv ne esce col video già a fine
        // stream e nessun frame. Senza, parte dal primo pacchetto.
        if (self.loop_off) self.setLoop(true); // vale per una sessione sola
        var buf: [64]u8 = undefined;
        const aid = if (audio) "auto" else "no";
        const opts = (if (start_s > 0)
            std.mem.printSentinel(&buf, "pause=yes,aid={s},start={d:.3}", .{ aid, start_s }, 0)
        else
            std.mem.printSentinel(&buf, "pause=yes,aid={s}", .{aid}, 0)) catch unreachable;
        self.commandAsync(&.{ "loadfile", path, "replace", "-1", opts, null });
        self.file_active = true;
    }

    /// Seek assoluto ed esatto (mpv decodifica dal keyframe fino al target).
    /// Finito quando arriva `playback_restart` da `pollEvents`: i frame resi
    /// prima appartengono ancora alla posizione vecchia.
    pub fn seek(self: *MpvVideo, seconds: f64) void {
        var buf: [64]u8 = undefined;
        const target = std.mem.printSentinel(&buf, "{d:.3}", .{@max(0, seconds)}, 0) catch return;
        self.commandAsync(&.{ "seek", target, "absolute+exact", null });
    }

    /// Loop del file (il default) o fermo sull'ultimo frame alla fine.
    pub fn setLoop(self: *MpvVideo, on: bool) void {
        _ = api.mpv_set_property_async(self.mpv, 0, "loop-file", c.MPV_FORMAT_STRING, @ptrCast(@constCast(&@as([*:0]const u8, if (on) "inf" else "no"))));
        _ = api.mpv_set_property_async(self.mpv, 0, "keep-open", c.MPV_FORMAT_STRING, @ptrCast(@constCast(&@as([*:0]const u8, if (on) "no" else "yes"))));
        self.loop_off = !on;
    }

    /// Pausa/riprende la riproduzione di mpv (audio, clock e video insieme).
    pub fn setPaused(self: *MpvVideo, paused: bool) void {
        var flag: c_int = if (paused) 1 else 0;
        _ = api.mpv_set_property_async(self.mpv, 0, "pause", c.MPV_FORMAT_FLAG, &flag);
    }

    pub const prop_time_pos: u64 = 1;
    pub const prop_duration: u64 = 2;
    pub const prop_buffering: u64 = 3;
    pub const prop_dwidth: u64 = 4;
    pub const prop_dheight: u64 = 5;
    pub const prop_fps: u64 = 6;
    pub const prop_hwdec: u64 = 7;
    pub const prop_video_id: u64 = 8;
    pub const prop_audio_id: u64 = 9;
    pub const prop_drops: u64 = 10;
    pub const prop_delayed: u64 = 11;
    pub const prop_avsync: u64 = 12;

    fn observeAll(mpv: *c.mpv_handle) void {
        _ = api.mpv_observe_property(mpv, prop_time_pos, "time-pos", c.MPV_FORMAT_DOUBLE);
        _ = api.mpv_observe_property(mpv, prop_duration, "duration", c.MPV_FORMAT_DOUBLE);
        _ = api.mpv_observe_property(mpv, prop_buffering, "paused-for-cache", c.MPV_FORMAT_FLAG);
        _ = api.mpv_observe_property(mpv, prop_dwidth, "dwidth", c.MPV_FORMAT_INT64);
        _ = api.mpv_observe_property(mpv, prop_dheight, "dheight", c.MPV_FORMAT_INT64);
        _ = api.mpv_observe_property(mpv, prop_fps, "container-fps", c.MPV_FORMAT_DOUBLE);
        _ = api.mpv_observe_property(mpv, prop_hwdec, "hwdec-current", c.MPV_FORMAT_STRING);
        _ = api.mpv_observe_property(mpv, prop_video_id, "current-tracks/video/id", c.MPV_FORMAT_INT64);
        _ = api.mpv_observe_property(mpv, prop_audio_id, "current-tracks/audio/id", c.MPV_FORMAT_INT64);
        // Diagnostica di fine sessione: frame persi dal decoder, frame resi in
        // ritardo dal VO, scarto audio−video (s) secondo mpv.
        _ = api.mpv_observe_property(mpv, prop_drops, "frame-drop-count", c.MPV_FORMAT_INT64);
        _ = api.mpv_observe_property(mpv, prop_delayed, "vo-delayed-frame-count", c.MPV_FORMAT_INT64);
        _ = api.mpv_observe_property(mpv, prop_avsync, "avsync", c.MPV_FORMAT_DOUBLE);
    }

    fn resetObserved(self: *MpvVideo) void {
        self.disp_w = 0;
        self.disp_h = 0;
        self.fps = 0;
        self.pos = 0;
        self.hwdec_len = 0;
        self.video_id = null;
        self.audio_id = null;
        self.drops = 0;
        self.delayed = 0;
        self.avsync_max = 0;
        self.avsync_win = 0;
    }

    /// Ciò che è successo dall'ultima chiamata (eventi svuotati senza attendere).
    /// Lo stato osservato (taglia, fps, tracce, hwdec) resta nei campi.
    pub const Events = struct {
        pos_s: ?f64 = null,
        duration_s: ?f64 = null,
        buffering: ?bool = null,
        file_loaded: bool = false,
        /// Seek (o avvio) completato: da qui i frame sono della posizione nuova.
        playback_restart: bool = false,
        /// Il file non si apre / lo stream è caduto senza ripresa.
        failed: bool = false,
        /// La sorgente è stata scaricata (fine, errore o `stopPlayback`).
        ended: bool = false,
        /// mpv è passato dalla decodifica hardware a quella software durante la
        /// riproduzione (il decoder hw ha fallito, es. un profilo che non regge).
        hw_to_sw: bool = false,
    };

    pub fn pollEvents(self: *MpvVideo) Events {
        var ev: Events = .{};
        while (true) {
            const e = api.mpv_wait_event(self.mpv, 0);
            switch (e.*.event_id) {
                c.MPV_EVENT_NONE => break,
                c.MPV_EVENT_PROPERTY_CHANGE => {
                    const p: *c.mpv_event_property = @ptrCast(@alignCast(e.*.data));
                    const none = p.format == c.MPV_FORMAT_NONE or p.data == null;
                    switch (e.*.reply_userdata) {
                        prop_video_id => self.video_id = if (none) null else @as(*const i64, @ptrCast(@alignCast(p.data))).*,
                        prop_audio_id => self.audio_id = if (none) null else @as(*const i64, @ptrCast(@alignCast(p.data))).*,
                        else => {},
                    }
                    if (none) continue;
                    switch (e.*.reply_userdata) {
                        prop_time_pos => {
                            self.pos = @as(*const f64, @ptrCast(@alignCast(p.data))).*;
                            ev.pos_s = self.pos;
                        },
                        prop_duration => ev.duration_s = @as(*const f64, @ptrCast(@alignCast(p.data))).*,
                        prop_buffering => ev.buffering = @as(*const c_int, @ptrCast(@alignCast(p.data))).* != 0,
                        prop_dwidth => self.disp_w = @as(*const i64, @ptrCast(@alignCast(p.data))).*,
                        prop_dheight => self.disp_h = @as(*const i64, @ptrCast(@alignCast(p.data))).*,
                        prop_fps => self.fps = @as(*const f64, @ptrCast(@alignCast(p.data))).*,
                        prop_drops => self.drops = @as(*const i64, @ptrCast(@alignCast(p.data))).*,
                        prop_delayed => self.delayed = @as(*const i64, @ptrCast(@alignCast(p.data))).*,
                        prop_avsync => {
                            const a = @abs(@as(*const f64, @ptrCast(@alignCast(p.data))).*);
                            self.avsync_max = @max(self.avsync_max, a);
                            self.avsync_win = @max(self.avsync_win, a);
                        },
                        prop_hwdec => {
                            const str = std.mem.span(@as(*const [*:0]const u8, @ptrCast(@alignCast(p.data))).*);
                            const was = self.hwdec();
                            if (was.len > 0 and !std.mem.eql(u8, was, "no") and std.mem.eql(u8, str, "no")) ev.hw_to_sw = true;
                            const n = @min(str.len, self.hwdec_buf.len);
                            @memcpy(self.hwdec_buf[0..n], str[0..n]);
                            self.hwdec_len = n;
                        },
                        else => {},
                    }
                },
                c.MPV_EVENT_FILE_LOADED => {
                    ev.file_loaded = true;
                    if (self.audio_url) |u| self.commandAsync(&.{ "audio-add", u, "select", null });
                },
                c.MPV_EVENT_PLAYBACK_RESTART => ev.playback_restart = true,
                c.MPV_EVENT_END_FILE => {
                    const ef: *c.mpv_event_end_file = @ptrCast(@alignCast(e.*.data));
                    if (ef.reason == c.MPV_END_FILE_REASON_ERROR) ev.failed = true;
                    ev.ended = true;
                    self.file_active = false;
                },
                c.MPV_EVENT_SHUTDOWN => {
                    ev.failed = true;
                    break;
                },
                else => {},
            }
        }
        return ev;
    }

    /// True se mpv ha un nuovo frame da rendere (azzera il flag in mpv).
    pub fn frameDue(self: *MpvVideo) bool {
        return api.mpv_render_context_update(self.render_ctx) & c.MPV_RENDER_UPDATE_FRAME != 0;
    }

    /// La sorgente ha una traccia video vera (non la copertina di un audio).
    pub fn hasVideo(self: *const MpvVideo) bool {
        return self.video_id != null;
    }

    pub fn hasAudio(self: *const MpvVideo) bool {
        return self.audio_id != null;
    }

    /// Dimensione di visualizzazione (aspect applicato), null finché ignota.
    pub fn displaySize(self: *const MpvVideo) ?[2]u32 {
        if (self.disp_w <= 0 or self.disp_h <= 0) return null;
        return .{ @intCast(self.disp_w), @intCast(self.disp_h) };
    }

    /// Fotogrammi al secondo del contenitore (0 se ignoti).
    pub fn frameRate(self: *const MpvVideo) f64 {
        return self.fps;
    }

    /// Decodifica hardware in uso ("" o "no" se software).
    pub fn hwdec(self: *const MpvVideo) []const u8 {
        return self.hwdec_buf[0..self.hwdec_len];
    }

    fn ensureFbo(self: *MpvVideo, w: c_int, h: c_int) void {
        if (self.fbo != 0 and self.fbo_w == w and self.fbo_h == h) return;
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.fbo_tex != 0) c.glDeleteTextures(1, &self.fbo_tex);

        c.glGenTextures(1, &self.fbo_tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.fbo_tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

        c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.fbo_tex, 0);
        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        if (status != c.GL_FRAMEBUFFER_COMPLETE) {
            std.log.warn("zuer video: FBO mpv incompleto ({x}x{d}x{d})", .{ status, w, h });
        }

        self.fbo_w = w;
        self.fbo_h = h;
    }

    /// Pompa l'update loop di mpv: se c'è un nuovo frame lo rende nel nostro
    /// FBO e lo scarica in `out` (RGBA stretto, w*h*4 byte, allocato/riusato
    /// dal chiamante). Ritorna `null` se non c'era nulla di nuovo da mostrare
    /// (nessun nuovo frame dall'ultima chiamata) — il chiamante tiene l'ultimo
    /// frame presentato, stesso contratto di `VideoDecoder.pickInto` di oggi.
    /// Taglia a cui rendere il frame: aspect-fit della taglia di visualizzazione
    /// nel box di presentazione (ingrandimento fino a 2×), o la nativa limitata a
    /// `max_dim` sul lato lungo se il box è ignoto.
    pub fn fitSize(disp: [2]u32, target_w: u32, target_h: u32, max_dim: u32) [2]u32 {
        const sw: f64 = @floatFromInt(disp[0]);
        const sh: f64 = @floatFromInt(disp[1]);
        var scale: f64 = 1.0;
        if (target_w > 0 and target_h > 0) {
            scale = @min(@min(@as(f64, @floatFromInt(target_w)) / sw, @as(f64, @floatFromInt(target_h)) / sh), 2.0);
        } else if (max_dim > 0) {
            scale = @min(1.0, @as(f64, @floatFromInt(max_dim)) / @max(sw, sh));
        }
        return .{ @max(1, @as(u32, @intFromFloat(@round(sw * scale)))), @max(1, @as(u32, @intFromFloat(@round(sh * scale)))) };
    }

    /// Rende il frame corrente di mpv nel framebuffer `fbo` (w×h). false se mpv rifiuta.
    pub fn renderTo(self: *MpvVideo, fbo: c.GLuint, w: u32, h: u32) bool {
        checkThread(self.owner, "render");
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        var fbo_param = c.mpv_opengl_fbo{ .fbo = @intCast(fbo), .w = @intCast(w), .h = @intCast(h), .internal_format = c.GL_RGBA8 };
        var flip: c_int = 0; // FBO nostro (non il default framebuffer): niente flip
        // Non bloccare sul target time: mpv sveglia il thread quando il frame è
        // dovuto (update callback), il pacing è già il suo.
        var block: c_int = 0;
        var render_params = [_]c.mpv_render_param{
            .{ .type = c.MPV_RENDER_PARAM_OPENGL_FBO, .data = &fbo_param },
            .{ .type = c.MPV_RENDER_PARAM_FLIP_Y, .data = &flip },
            .{ .type = c.MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, .data = &block },
            .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        return api.mpv_render_context_render(self.render_ctx, &render_params) >= 0;
    }

    pub const GpuResult = union(enum) {
        frame: GpuFrame,
        /// Tutti gli slot sono ancora del compositor (o in coda): niente render.
        busy,
        /// Il percorso GPU non va: readback per il resto della vita del motore.
        unavailable,
    };

    /// Rende il frame corrente a w×h nel primo slot dmabuf libero (`slot_free`:
    /// il compositor l'ha rilasciato e non è in coda) e lo restituisce, pronto per
    /// il compositor. Mai in uno slot che il compositor può ancora leggere.
    pub fn renderGpu(self: *MpvVideo, w: u32, h: u32, ctx: *anyopaque, slot_free: *const fn (*anyopaque, u8) bool) GpuResult {
        if (self.gpu_off) return .unavailable;
        if (self.gpu == null) {
            self.gpu = GpuTargets.init(self.egl_display) catch |e| {
                std.log.warn("zuer video: percorso dmabuf non disponibile ({s}), readback CPU", .{@errorName(e)});
                self.gpu_off = true;
                return .unavailable;
            };
        }
        const t = &self.gpu.?;
        if (t.w != w or t.h != h) t.resize(self.egl_display, w, h);
        const i: u8 = for (0..gpu_slots) |k| {
            const s: u8 = @intCast((t.next + k) % gpu_slots);
            if (slot_free(ctx, s)) break s;
        } else return .busy;
        if (t.slots[i].bo == null) {
            t.slots[i] = t.createSlot(self.egl_display, w, h) catch |e| {
                std.log.warn("zuer video: buffer dmabuf {d}x{d} non creato ({s}), readback CPU", .{ w, h, @errorName(e) });
                self.gpu_off = true;
                return .unavailable;
            };
        }
        const sl = &t.slots[i];
        if (!self.renderTo(sl.fbo, w, h)) return .busy;
        // Consegna: sottomesso (Mesa, sincronia implicita) o finito (vedi `syncMode`).
        if (t.finish) c.glFinish() else c.glFlush();
        t.next = @intCast((i + 1) % gpu_slots);
        t.presents += 1;
        t.reap(self.egl_display, false);
        return .{ .frame = .{ .slot = i, .fd = sl.fd, .width = w, .height = h, .stride = sl.stride, .fourcc = drm_xbgr8888, .modifier = drm_mod_linear } };
    }

    /// Il percorso GPU ha fallito e non verrà ritentato.
    pub fn gpuDisabled(self: *const MpvVideo) bool {
        return self.gpu_off;
    }

    /// Spegne il percorso GPU (il presenter l'ha rifiutato): da qui readback.
    pub fn disableGpu(self: *MpvVideo) void {
        self.gpu_off = true;
    }

    /// Rende il frame dovuto e lo butta: tiene vivo il ciclo di mpv (che attende
    /// il disegno per chiudere un seek) senza readback. Alla taglia corrente: una
    /// taglia diversa cambierebbe gli scaler e costerebbe una compilazione di
    /// shader proprio durante il seek.
    pub fn renderDiscard(self: *MpvVideo, w: u32, h: u32) void {
        self.ensureFbo(@intCast(w), @intCast(h));
        _ = self.renderTo(self.fbo, w, h);
    }

    /// Rende il frame corrente a w×h nel FBO interno e lo scarica in `out` (RGBA
    /// stretto). Percorso CPU: il poster, e quando il compositor non accetta il
    /// piano dmabuf.
    pub fn renderReadback(self: *MpvVideo, out: *std.ArrayList(u8), allocator: std.mem.Allocator, w: u32, h: u32) !?Frame {
        const gw: c_int = @intCast(w);
        const gh: c_int = @intCast(h);
        self.ensureFbo(gw, gh);
        if (!self.renderTo(self.fbo, w, h)) return null;

        // mpv non promette di lasciare il FRAMEBUFFER BINDING invariato dopo il
        // render (solo viewport/scissor/blend/clear-color sono garantiti come
        // "lasciati standard" — vedi render_gl.h) — ribindare esplicitamente
        // prima di leggere, altrimenti si rischia di leggere dal framebuffer di
        // default (il nostro pbuffer 1x1) invece che dal nostro FBO.
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        const need: usize = @as(usize, @intCast(gw)) * @as(usize, @intCast(gh)) * 4;
        if (out.items.len < need) try out.resize(allocator, need);
        self.readInto(out.items[0..need], w, h);
        return .{ .width = w, .height = h, .pts_s = self.pos };
    }

    /// Come `renderReadback`, ma legge direttamente in `dst` (w×h×4 byte): il
    /// chiamante ci passa lo slot della coda, senza un buffer intermedio da copiare.
    pub fn renderReadbackTo(self: *MpvVideo, dst: []u8, w: u32, h: u32) ?Frame {
        std.debug.assert(dst.len >= @as(usize, w) * h * 4);
        self.ensureFbo(@intCast(w), @intCast(h));
        if (!self.renderTo(self.fbo, w, h)) return null;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo); // vedi `renderReadback`
        self.readInto(dst, w, h);
        return .{ .width = w, .height = h, .pts_s = self.pos };
    }

    /// Legge l'FBO in `dst` passando da un pixel buffer object: la GPU copia il
    /// frame in un buffer lineare, la CPU lo mappa (attesa della GPU, il thread
    /// dorme) e lo copia una volta. `glReadPixels` diretto in memoria del processo
    /// costava ~20 ms per 1280×720 su Intel HD 520 — oltre il budget di un frame a
    /// 60 fps, con mpv che scartava un frame su tre; col PBO ~10 ms, di cui 0,9 di
    /// copia. Se la mappa fallisce: lettura diretta.
    fn readInto(self: *MpvVideo, dst: []u8, w: u32, h: u32) void {
        const need: usize = @as(usize, w) * h * 4;
        c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
        if (self.pbo == 0) c.glGenBuffers(1, &self.pbo);
        c.glBindBuffer(c.GL_PIXEL_PACK_BUFFER, self.pbo);
        defer c.glBindBuffer(c.GL_PIXEL_PACK_BUFFER, 0);
        if (self.pbo_size != need) {
            c.glBufferData(c.GL_PIXEL_PACK_BUFFER, @intCast(need), null, c.GL_STREAM_READ);
            self.pbo_size = need;
        }
        c.glReadPixels(0, 0, @intCast(w), @intCast(h), c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        if (c.glMapBufferRange(c.GL_PIXEL_PACK_BUFFER, 0, @intCast(need), c.GL_MAP_READ_BIT)) |p| {
            const src: [*]const u8 = @ptrCast(p);
            @memcpy(dst[0..need], src[0..need]);
            _ = c.glUnmapBuffer(c.GL_PIXEL_PACK_BUFFER);
            return;
        }
        c.glBindBuffer(c.GL_PIXEL_PACK_BUFFER, 0);
        c.glReadPixels(0, 0, @intCast(w), @intCast(h), c.GL_RGBA, c.GL_UNSIGNED_BYTE, dst.ptr);
    }
};
