//! Decodifica+rendering video via libmpv (render API OpenGL), su un contesto
//! EGL indipendente (pbuffer 1x1, il rendering vero va in un FBO nostro).
//! Percorso Linux/Wayland-only: sostituisce il vecchio tentativo di zero-copy
//! VAAPI custom (ritirato — si scontrava con un comportamento del compositor
//! fuori dal nostro controllo). mpv fa hwdec+color management internamente,
//! già maturo su questo stesso hardware/compositor (verificato più volte).
//!
//! Muto per design: l'audio resta interamente a Zuer (src/audio_player.zig),
//! che continua a essere il clock master a cui il video si sincronizza.

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
    fbo_h: c_int = 0,

    pub fn init() InitError!MpvVideo {
        if (comptime builtin.os.tag != .linux) @compileError("MpvVideo è Linux-only");
        if (!ensureMpv()) return error.MpvLibraryMissing;

        const wl_display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(wl_display);

        const egl_display = c.eglGetPlatformDisplay(c.EGL_PLATFORM_WAYLAND_KHR, wl_display, null) orelse
            return error.EglGetDisplayFailed;
        var egl_major: c.EGLint = 0;
        var egl_minor: c.EGLint = 0;
        if (c.eglInitialize(egl_display, &egl_major, &egl_minor) == c.EGL_FALSE) return error.EglInitializeFailed;
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

        const mpv = api.mpv_create() orelse return error.MpvCreateFailed;
        errdefer api.mpv_terminate_destroy(mpv);
        _ = api.mpv_set_option_string(mpv, "hwdec", "auto");
        _ = api.mpv_set_option_string(mpv, "aid", "no"); // niente audio: lo fa Zuer
        _ = api.mpv_set_option_string(mpv, "terminal", "no");
        _ = api.mpv_set_option_string(mpv, "msg-level", "all=warn");
        _ = api.mpv_set_option_string(mpv, "vo", "libmpv");
        if (api.mpv_initialize(mpv) < 0) return error.MpvInitializeFailed;

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

        return .{
            .wl_display = wl_display,
            .egl_display = egl_display,
            .egl_surface = egl_surface,
            .egl_context = egl_context,
            .egl_config = egl_config,
            .mpv = mpv,
            .render_ctx = render_ctx.?,
        };
    }

    fn getProcAddress(ctx: ?*anyopaque, name: [*c]const u8) callconv(.c) ?*anyopaque {
        _ = ctx;
        return @ptrCast(@constCast(c.eglGetProcAddress(name)));
    }

    pub fn deinit(self: *MpvVideo) void {
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.fbo_tex != 0) c.glDeleteTextures(1, &self.fbo_tex);
        api.mpv_render_context_free(self.render_ctx);
        api.mpv_terminate_destroy(self.mpv);
        _ = c.eglDestroyContext(self.egl_display, self.egl_context);
        _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
        c.wl_display_disconnect(self.wl_display);
        self.* = undefined;
    }

    pub fn loadFile(self: *MpvVideo, path: [:0]const u8) void {
        const args = [_:null]?[*:0]const u8{ "loadfile", path, null };
        _ = api.mpv_command(self.mpv, @ptrCast(@constCast(&args)));
    }

    /// Seek assoluto (mpv fa la propria ricerca del keyframe/decodifica fino
    /// al target — non serve il nostro skip lato produttore come per FFmpeg).
    pub fn seek(self: *MpvVideo, seconds: f64) void {
        var buf: [64]u8 = undefined;
        const target = std.mem.printSentinel(&buf, "{d:.3}", .{@max(0, seconds)}, 0) catch return;
        const args = [_:null]?[*:0]const u8{ "seek", target, "absolute", null };
        _ = api.mpv_command(self.mpv, @ptrCast(@constCast(&args)));
    }

    /// Pausa/riprende la riproduzione INTERNA di mpv (il suo clock di pacing,
    /// indipendente dal nostro). Senza questo, mettere in pausa lato Zuer
    /// (smettere di drenare il ring) non ferma mpv: continua a decodificare e
    /// a considerare "pronti" nuovi frame finché il ring non si riempie, e la
    /// sua posizione interna avanza comunque nel frattempo.
    pub fn setPaused(self: *MpvVideo, paused: bool) void {
        var flag: c_int = if (paused) 1 else 0;
        _ = api.mpv_set_property(self.mpv, "pause", c.MPV_FORMAT_FLAG, &flag);
    }

    pub fn eofReached(self: *MpvVideo) bool {
        var flag: c_int = 0;
        _ = api.mpv_get_property(self.mpv, "eof-reached", c.MPV_FORMAT_FLAG, &flag);
        return flag != 0;
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
    pub fn pollFrame(self: *MpvVideo, out: *std.ArrayList(u8), allocator: std.mem.Allocator, target_w: u32, target_h: u32) !?Frame {
        const flags = api.mpv_render_context_update(self.render_ctx);
        if (flags & c.MPV_RENDER_UPDATE_FRAME == 0) return null;

        var w: i64 = 0;
        var h: i64 = 0;
        _ = api.mpv_get_property(self.mpv, "dwidth", c.MPV_FORMAT_INT64, &w);
        _ = api.mpv_get_property(self.mpv, "dheight", c.MPV_FORMAT_INT64, &h);
        if (w <= 0 or h <= 0) return null;
        var gw: c_int = @intCast(w);
        var gh: c_int = @intCast(h);
        // Taglia di presentazione nota: mpv scala (bene, su GPU) direttamente a
        // quella, così il compositore non ricampiona nearest. Aspect-fit del
        // frame nel box richiesto, ingrandimento ammesso fino a 2×.
        if (target_w > 0 and target_h > 0) {
            const sw: f64 = @floatFromInt(w);
            const sh: f64 = @floatFromInt(h);
            var scale = @min(@as(f64, @floatFromInt(target_w)) / sw, @as(f64, @floatFromInt(target_h)) / sh);
            scale = @min(scale, 2.0);
            gw = @max(1, @as(c_int, @intFromFloat(@round(sw * scale))));
            gh = @max(1, @as(c_int, @intFromFloat(@round(sh * scale))));
        }

        self.ensureFbo(gw, gh);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        var fbo_param = c.mpv_opengl_fbo{ .fbo = @intCast(self.fbo), .w = gw, .h = gh, .internal_format = c.GL_RGBA8 };
        var flip: c_int = 0; // FBO nostro (non il default framebuffer): niente flip
        var block: c_int = 0; // non bloccare sul target time: il pacing lo facciamo noi (Fase 3)
        var render_params = [_]c.mpv_render_param{
            .{ .type = c.MPV_RENDER_PARAM_OPENGL_FBO, .data = &fbo_param },
            .{ .type = c.MPV_RENDER_PARAM_FLIP_Y, .data = &flip },
            .{ .type = c.MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, .data = &block },
            .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        const render_rc = api.mpv_render_context_render(self.render_ctx, &render_params);
        if (render_rc < 0) return null;

        // mpv non promette di lasciare il FRAMEBUFFER BINDING invariato dopo il
        // render (solo viewport/scissor/blend/clear-color sono garantiti come
        // "lasciati standard" — vedi render_gl.h) — ribindare esplicitamente
        // prima di leggere, altrimenti si rischia di leggere dal framebuffer di
        // default (il nostro pbuffer 1x1) invece che dal nostro FBO.
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        const need: usize = @as(usize, @intCast(gw)) * @as(usize, @intCast(gh)) * 4;
        if (out.items.len < need) try out.resize(allocator, need);
        c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
        c.glReadPixels(0, 0, gw, gh, c.GL_RGBA, c.GL_UNSIGNED_BYTE, out.items.ptr);

        var pos: f64 = 0;
        _ = api.mpv_get_property(self.mpv, "time-pos", c.MPV_FORMAT_DOUBLE, &pos);

        return .{ .width = @intCast(gw), .height = @intCast(gh), .pts_s = pos };
    }
};
