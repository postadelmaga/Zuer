//! Core di decodifica multimediale nativo, basato su libav (ffmpeg): apertura
//! container, decodifica video → RGB24 e (in seguito) audio → PCM. È la
//! fondamenta del player nativo: qui vive tutta l'interazione con ffmpeg,
//! mentre presentazione, audio e controlli overlay stanno altrove.
//!
//! `Player` tiene aperto il container e produce i frame video in sequenza (con
//! il loro PTS in secondi), esponendo durata e seek — il motore che la GUI
//! pilota nel render loop. `firstVideoFrame` è la scorciatoia one-shot usata per
//! il poster/anteprima.

const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libswscale/swscale.h");
});

// Decoder VP9 su GPU compute (libcompute_vp9): Linux-only (la libreria non è portata su
// Windows) e solo con il renderer Vulkan attivo. Altrove `cvp9` è uno struct vuoto e il
// suo @cImport non viene mai analizzato — così player.zig compila senza la libreria, e i
// VP9 li decodifica libav.
const cvp9_enabled = builtin.os.tag == .linux and @import("build_options").gpu;
const cvp9 = if (cvp9_enabled) @import("cvp9.zig") else struct {};

pub const Frame = struct {
    width: usize,
    height: usize,
    /// RGB24 impacchettato (3 byte/pixel, righe contigue senza padding).
    pixels: []u8,
    /// Timestamp di presentazione in secondi (0 se il container non lo fornisce).
    pts_s: f64 = 0,
};

pub const Error = error{
    OpenFailed,
    NoStreamInfo,
    NoVideoStream,
    NoDecoder,
    CodecOpenFailed,
    AllocFailed,
    ScaleInitFailed,
    NoFrameDecoded,
    OutOfMemory,
};

/// Dimensioni scalate mantenendo l'aspect ratio, così che il lato maggiore non
/// superi `max_dim` (mai ingrandito).
fn fitDims(src_w: c_int, src_h: c_int, max_dim: usize) struct { w: c_int, h: c_int } {
    if (src_w <= 0 or src_h <= 0) return .{ .w = 1, .h = 1 };
    const fmax: f64 = @floatFromInt(max_dim);
    const bigger: f64 = @floatFromInt(@max(src_w, src_h));
    const scale = @min(1.0, fmax / bigger);
    const w: c_int = @max(1, @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(src_w)) * scale))));
    const h: c_int = @max(1, @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(src_h)) * scale))));
    return .{ .w = w, .h = h };
}

pub const Player = struct {
    fmt_ctx: [*c]c.AVFormatContext,
    codec_ctx: [*c]c.AVCodecContext,
    frame: [*c]c.AVFrame,
    packet: [*c]c.AVPacket,
    video_stream: c_int,
    time_base: f64, // secondi per unità di PTS dello stream video
    duration_s: f64, // durata del container in secondi (0 se ignota)

    // Contesto di scaling riusato tra i frame; ricreato se cambiano le dimensioni.
    sws: ?*c.struct_SwsContext = null,
    sws_src_w: c_int = 0,
    sws_src_h: c_int = 0,
    sws_src_fmt: c_int = -1,
    sws_dst_w: c_int = 0,
    sws_dst_h: c_int = 0,

    // Decoder VP9 su GPU (libcompute_vp9). `is_vp9` = stiamo instradando i packet a
    // cvp9 invece che a libavcodec. Il contesto avcodec resta comunque aperto come
    // fallback (es. se un seek non riesce a ricreare il contesto cvp9).
    cvp9_ctx: if (cvp9_enabled) ?cvp9.Ctx else void = if (cvp9_enabled) null else {},
    is_vp9: bool = false,

    pub fn open(path: [*:0]const u8) Error!Player {
        return openEx(path, true);
    }

    /// `allow_cvp9` = consenti il decoder GPU per gli stream VP9. Il poster
    /// (`firstVideoFrame`) passa false: un solo frame non giustifica un contesto GPU.
    pub fn openEx(path: [*:0]const u8, allow_cvp9: bool) Error!Player {
        var fmt_ctx: [*c]c.AVFormatContext = null;
        if (c.avformat_open_input(&fmt_ctx, path, null, null) != 0) return Error.OpenFailed;
        errdefer c.avformat_close_input(&fmt_ctx);

        if (c.avformat_find_stream_info(fmt_ctx, null) < 0) return Error.NoStreamInfo;

        var codec: [*c]const c.AVCodec = null;
        const stream_idx = c.av_find_best_stream(fmt_ctx, c.AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
        if (stream_idx < 0 or codec == null) return Error.NoVideoStream;
        const stream = fmt_ctx.*.streams[@intCast(stream_idx)];

        const codec_ctx = c.avcodec_alloc_context3(codec) orelse return Error.AllocFailed;
        errdefer {
            var cc: [*c]c.AVCodecContext = codec_ctx;
            c.avcodec_free_context(&cc);
        }
        if (c.avcodec_parameters_to_context(codec_ctx, stream.*.codecpar) < 0) return Error.CodecOpenFailed;
        if (c.avcodec_open2(codec_ctx, codec, null) < 0) return Error.CodecOpenFailed;

        const frame = c.av_frame_alloc() orelse return Error.AllocFailed;
        errdefer {
            var f: [*c]c.AVFrame = frame;
            c.av_frame_free(&f);
        }
        const packet = c.av_packet_alloc() orelse return Error.AllocFailed;
        errdefer {
            var p: [*c]c.AVPacket = packet;
            c.av_packet_free(&p);
        }

        const tb = stream.*.time_base;
        const time_base: f64 = if (tb.den != 0)
            @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(tb.den))
        else
            0;

        var duration_s: f64 = 0;
        if (fmt_ctx.*.duration != c.AV_NOPTS_VALUE and fmt_ctx.*.duration > 0) {
            duration_s = @as(f64, @floatFromInt(fmt_ctx.*.duration)) / @as(f64, c.AV_TIME_BASE);
        } else if (stream.*.duration != c.AV_NOPTS_VALUE and stream.*.duration > 0) {
            duration_s = @as(f64, @floatFromInt(stream.*.duration)) * time_base;
        }

        // VP9 → prova il decoder GPU compute; se il backend non parte, resta libav.
        var cvp9_ctx: if (cvp9_enabled) ?cvp9.Ctx else void = if (cvp9_enabled) null else {};
        var is_vp9 = false;
        if (comptime cvp9_enabled) {
            const is_vp9_stream = stream.*.codecpar.*.codec_id == c.AV_CODEC_ID_VP9;
            const forced_libav = std.c.getenv("ZUER_VP9_LIBAV") != null;
            if (allow_cvp9 and is_vp9_stream and !forced_libav) {
                if (cvp9.Ctx.create()) |cx| {
                    cvp9_ctx = cx;
                    is_vp9 = true;
                    std.log.info("[cvp9] VP9 via GPU compute, backend {s}", .{cx.backendName()});
                } else {
                    std.log.warn("[cvp9] init fallita, VP9 via libav (libvpx)", .{});
                }
            }
        }

        return .{
            .fmt_ctx = fmt_ctx,
            .codec_ctx = codec_ctx,
            .frame = frame,
            .packet = packet,
            .video_stream = stream_idx,
            .time_base = time_base,
            .duration_s = duration_s,
            .cvp9_ctx = cvp9_ctx,
            .is_vp9 = is_vp9,
        };
    }

    pub fn deinit(self: *Player) void {
        if (comptime cvp9_enabled) {
            if (self.cvp9_ctx) |cx| cx.destroy();
        }
        if (self.sws) |s| c.sws_freeContext(s);
        var p: [*c]c.AVPacket = self.packet;
        c.av_packet_free(&p);
        var f: [*c]c.AVFrame = self.frame;
        c.av_frame_free(&f);
        var cc: [*c]c.AVCodecContext = self.codec_ctx;
        c.avcodec_free_context(&cc);
        c.avformat_close_input(&self.fmt_ctx);
    }

    fn ptsSeconds(self: *Player) f64 {
        const ts = self.frame.*.best_effort_timestamp;
        if (ts == c.AV_NOPTS_VALUE) return 0;
        return @as(f64, @floatFromInt(ts)) * self.time_base;
    }

    /// Secondi da un timestamp grezzo nella time_base dello stream (per i frame cvp9,
    /// il cui PTS è quello del packet che abbiamo sottomesso).
    fn rawPtsSeconds(self: *Player, ts: i64) f64 {
        if (ts == c.AV_NOPTS_VALUE) return 0;
        return @as(f64, @floatFromInt(ts)) * self.time_base;
    }

    /// Decodifica il prossimo frame video, scalato a `max_dim`, con il suo PTS.
    /// Ritorna `null` a fine stream. Il chiamante possiede `Frame.pixels`.
    pub fn nextFrame(self: *Player, max_dim: usize, allocator: std.mem.Allocator) Error!?Frame {
        if (comptime cvp9_enabled) {
            if (self.is_vp9) return self.nextFrameCvp9(max_dim, allocator);
        }
        while (true) {
            const rr = c.av_read_frame(self.fmt_ctx, self.packet);
            if (rr < 0) {
                // Fine file: svuota il decoder con un packet nullo.
                _ = c.avcodec_send_packet(self.codec_ctx, null);
                const r = c.avcodec_receive_frame(self.codec_ctx, self.frame);
                if (r < 0) return null;
                return try self.scaleCurrent(max_dim, allocator);
            }
            defer c.av_packet_unref(self.packet);
            if (self.packet.*.stream_index != self.video_stream) continue;
            if (c.avcodec_send_packet(self.codec_ctx, self.packet) < 0) continue;
            const r = c.avcodec_receive_frame(self.codec_ctx, self.frame);
            if (r == c.AVERROR(c.EAGAIN)) continue; // servono altri packet
            if (r == c.AVERROR_EOF) return null;
            if (r < 0) return Error.NoFrameDecoded;
            return try self.scaleCurrent(max_dim, allocator);
        }
    }

    /// Percorso VP9 su GPU: sottomette i packet grezzi a cvp9 e raccoglie i frame
    /// I420 in ordine di presentazione (pipeline: alcuni frame possono essere in
    /// volo). A fine stream drena i frame residui in modo bloccante.
    fn nextFrameCvp9(self: *Player, max_dim: usize, allocator: std.mem.Allocator) Error!?Frame {
        var f: cvp9.Frame = undefined;
        while (true) {
            // Un frame potrebbe essere già pronto dalla pipeline.
            if (self.cvp9_ctx.?.getFrame(&f) == .ok) return try self.scaleI420(f, max_dim, allocator);
            const rr = c.av_read_frame(self.fmt_ctx, self.packet);
            if (rr < 0) {
                // Fine file: drena i frame ancora in volo (pipeline poco profonda),
                // con un tetto di tentativi così un frame bloccato non appende il worker.
                var tries: u32 = 0;
                while (tries < 256) : (tries += 1) {
                    switch (self.cvp9_ctx.?.getFrame(&f)) {
                        .ok => return try self.scaleI420(f, max_dim, allocator),
                        .none => return null,
                        .again => std.Thread.yield() catch {},
                    }
                }
                return null;
            }
            defer c.av_packet_unref(self.packet);
            if (self.packet.*.stream_index != self.video_stream) continue;
            self.cvp9_ctx.?.decode(self.packet.*.data, @intCast(self.packet.*.size), self.packet.*.pts);
        }
    }

    /// Converte un frame I420 di cvp9 in RGB24 impacchettato scalato a `max_dim`.
    fn scaleI420(self: *Player, f: cvp9.Frame, max_dim: usize, allocator: std.mem.Allocator) Error!Frame {
        const src_w: c_int = @intCast(f.width);
        const src_h: c_int = @intCast(f.height);
        const dims = fitDims(src_w, src_h, max_dim);
        try self.ensureSws(src_w, src_h, c.AV_PIX_FMT_YUV420P, dims.w, dims.h);

        const w: usize = @intCast(dims.w);
        const h: usize = @intCast(dims.h);
        const pixels = try allocator.alloc(u8, w * h * 3);
        errdefer allocator.free(pixels);

        var src_data = [_][*c]u8{ f.y, f.u, f.v, null };
        var src_linesize = [_]c_int{ @intCast(f.stride_y), @intCast(f.stride_uv), @intCast(f.stride_uv), 0 };
        var dst_data = [_][*c]u8{ pixels.ptr, null, null, null };
        var dst_linesize = [_]c_int{ @intCast(w * 3), 0, 0, 0 };
        _ = c.sws_scale(self.sws, &src_data[0], &src_linesize[0], 0, src_h, &dst_data[0], &dst_linesize[0]);

        return .{ .width = w, .height = h, .pixels = pixels, .pts_s = self.rawPtsSeconds(f.pts) };
    }

    /// (Ri)crea il contesto swscale se dimensioni/formato sorgente o la
    /// destinazione sono cambiati.
    fn ensureSws(self: *Player, src_w: c_int, src_h: c_int, src_fmt: c_int, dst_w: c_int, dst_h: c_int) Error!void {
        if (self.sws != null and src_w == self.sws_src_w and src_h == self.sws_src_h and
            src_fmt == self.sws_src_fmt and dst_w == self.sws_dst_w and dst_h == self.sws_dst_h)
        {
            return;
        }
        if (self.sws) |s| {
            c.sws_freeContext(s);
            self.sws = null;
        }
        const sws = c.sws_getContext(src_w, src_h, src_fmt, dst_w, dst_h, c.AV_PIX_FMT_RGB24, c.SWS_BILINEAR, null, null, null) orelse return Error.ScaleInitFailed;
        self.sws = sws;
        self.sws_src_w = src_w;
        self.sws_src_h = src_h;
        self.sws_src_fmt = src_fmt;
        self.sws_dst_w = dst_w;
        self.sws_dst_h = dst_h;
    }

    /// Converte `self.frame` in RGB24 impacchettato scalato a `max_dim`.
    fn scaleCurrent(self: *Player, max_dim: usize, allocator: std.mem.Allocator) Error!Frame {
        const src_w = self.frame.*.width;
        const src_h = self.frame.*.height;
        const dims = fitDims(src_w, src_h, max_dim);
        try self.ensureSws(src_w, src_h, self.frame.*.format, dims.w, dims.h);

        const w: usize = @intCast(dims.w);
        const h: usize = @intCast(dims.h);
        const pixels = try allocator.alloc(u8, w * h * 3);
        errdefer allocator.free(pixels);

        var dst_data = [_][*c]u8{ pixels.ptr, null, null, null };
        var dst_linesize = [_]c_int{ @intCast(w * 3), 0, 0, 0 };
        _ = c.sws_scale(self.sws, &self.frame.*.data[0], &self.frame.*.linesize[0], 0, src_h, &dst_data[0], &dst_linesize[0]);

        return .{ .width = w, .height = h, .pixels = pixels, .pts_s = self.ptsSeconds() };
    }

    /// Riposiziona la riproduzione a `seconds` (approssimato al keyframe più
    /// vicino) e svuota i buffer del decoder.
    pub fn seek(self: *Player, seconds: f64) void {
        const ts: i64 = if (self.time_base > 0)
            @intFromFloat(seconds / self.time_base)
        else
            @intFromFloat(seconds * @as(f64, c.AV_TIME_BASE));
        _ = c.av_seek_frame(self.fmt_ctx, self.video_stream, ts, c.AVSEEK_FLAG_BACKWARD);
        if (comptime cvp9_enabled) {
            if (self.is_vp9) {
                // cvp9 non ha una flush: ricrea il contesto per azzerare i frame di
                // riferimento (dal keyframe il decode riparte pulito). Se la ricreazione
                // fallisce, ripiega su libav (il contesto avcodec è già aperto).
                if (self.cvp9_ctx) |cx| cx.destroy();
                self.cvp9_ctx = cvp9.Ctx.create();
                if (self.cvp9_ctx == null) {
                    self.is_vp9 = false;
                    c.avcodec_flush_buffers(self.codec_ctx);
                }
                return;
            }
        }
        c.avcodec_flush_buffers(self.codec_ctx);
    }
};

/// Scorciatoia one-shot: primo frame video del file in RGB24 scalato a
/// `max_dim`. Usata per poster/anteprima.
pub fn firstVideoFrame(path: [*:0]const u8, max_dim: usize, allocator: std.mem.Allocator) Error!Frame {
    // Poster via libav (allow_cvp9 = false): un singolo frame non giustifica il
    // costo di un contesto GPU cvp9.
    var player = try Player.openEx(path, false);
    defer player.deinit();
    return (try player.nextFrame(max_dim, allocator)) orelse Error.NoFrameDecoded;
}
