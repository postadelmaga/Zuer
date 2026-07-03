//! Core di decodifica multimediale nativo, basato su libav (ffmpeg): apertura
//! container, decodifica video → RGB24 e (in seguito) audio → PCM. È la
//! fondamenta del player nativo: qui vive tutta l'interazione con ffmpeg,
//! mentre presentazione, audio e controlli overlay stanno altrove.
//!
//! Primo tassello: estrazione del primo frame video (poster) a una dimensione
//! massima, così che aprire un video mostri subito un fotogramma reale.

const std = @import("std");

pub const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libswscale/swscale.h");
});

pub const Frame = struct {
    width: usize,
    height: usize,
    /// RGB24 impacchettato (3 byte/pixel, righe contigue senza padding).
    pixels: []u8,
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

/// Decodifica il primo frame video del file e lo restituisce in RGB24 scalato a
/// `max_dim`. Il chiamante possiede `Frame.pixels` (allocato con `allocator`).
pub fn firstVideoFrame(path: [*:0]const u8, max_dim: usize, allocator: std.mem.Allocator) Error!Frame {
    var fmt_ctx: [*c]c.AVFormatContext = null;
    if (c.avformat_open_input(&fmt_ctx, path, null, null) != 0) return Error.OpenFailed;
    defer c.avformat_close_input(&fmt_ctx);

    if (c.avformat_find_stream_info(fmt_ctx, null) < 0) return Error.NoStreamInfo;

    var codec: [*c]const c.AVCodec = null;
    const stream_idx = c.av_find_best_stream(fmt_ctx, c.AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (stream_idx < 0 or codec == null) return Error.NoVideoStream;
    const stream = fmt_ctx.*.streams[@intCast(stream_idx)];

    const codec_ctx = c.avcodec_alloc_context3(codec) orelse return Error.AllocFailed;
    defer {
        var cc: [*c]c.AVCodecContext = codec_ctx;
        c.avcodec_free_context(&cc);
    }
    if (c.avcodec_parameters_to_context(codec_ctx, stream.*.codecpar) < 0) return Error.CodecOpenFailed;
    if (c.avcodec_open2(codec_ctx, codec, null) < 0) return Error.CodecOpenFailed;

    const frame = c.av_frame_alloc() orelse return Error.AllocFailed;
    defer {
        var f: [*c]c.AVFrame = frame;
        c.av_frame_free(&f);
    }
    const packet = c.av_packet_alloc() orelse return Error.AllocFailed;
    defer {
        var p: [*c]c.AVPacket = packet;
        c.av_packet_free(&p);
    }

    // Legge pacchetti finché il decoder non emette il primo frame video.
    var got = false;
    while (!got and c.av_read_frame(fmt_ctx, packet) >= 0) {
        defer c.av_packet_unref(packet);
        if (packet.*.stream_index != stream_idx) continue;
        if (c.avcodec_send_packet(codec_ctx, packet) < 0) continue;
        while (true) {
            const r = c.avcodec_receive_frame(codec_ctx, frame);
            if (r == c.AVERROR(c.EAGAIN) or r == c.AVERROR_EOF) break;
            if (r < 0) return Error.NoFrameDecoded;
            got = true;
            break;
        }
    }
    if (!got) return Error.NoFrameDecoded;

    return scaleToRgb(frame, codec_ctx.*.width, codec_ctx.*.height, max_dim, allocator);
}

/// Converte un AVFrame (qualunque pixel format) in RGB24 impacchettato scalato.
fn scaleToRgb(frame: [*c]c.AVFrame, src_w: c_int, src_h: c_int, max_dim: usize, allocator: std.mem.Allocator) Error!Frame {
    const dims = fitDims(src_w, src_h, max_dim);
    const dst_w = dims.w;
    const dst_h = dims.h;

    const sws = c.sws_getContext(
        src_w,
        src_h,
        frame.*.format,
        dst_w,
        dst_h,
        c.AV_PIX_FMT_RGB24,
        c.SWS_BILINEAR,
        null,
        null,
        null,
    ) orelse return Error.ScaleInitFailed;
    defer c.sws_freeContext(sws);

    const w: usize = @intCast(dst_w);
    const h: usize = @intCast(dst_h);
    const pixels = try allocator.alloc(u8, w * h * 3);
    errdefer allocator.free(pixels);

    // Destinazione a riga contigua (linesize = larghezza*3): swscale scrive
    // direttamente nel buffer del chiamante.
    var dst_data = [_][*c]u8{ pixels.ptr, null, null, null };
    var dst_linesize = [_]c_int{ @intCast(w * 3), 0, 0, 0 };

    _ = c.sws_scale(
        sws,
        &frame.*.data[0],
        &frame.*.linesize[0],
        0,
        src_h,
        &dst_data[0],
        &dst_linesize[0],
    );

    return .{ .width = w, .height = h, .pixels = pixels };
}
