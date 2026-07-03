const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;

/// Anteprima nativa per file audio/video: legge solo gli header (nessuna
/// decodifica dei sample, nessun processo esterno) ed emette una scheda testuale.
pub fn decode(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    defer allocator.free(bytes);

    const info: MediaInfo = sniff(bytes) orelse {
        const msg = std.fmt.allocPrint(allocator, "Formato multimediale non riconosciuto: {s}", .{filename}) catch "Formato non riconosciuto";
        return .{ .err = msg };
    };

    return .{ .text = render(info, filename, bytes.len, allocator) };
}

const MediaInfo = struct {
    format: []const u8,
    kind: enum { audio, video },
    duration_ms: ?u64 = null,
    sample_rate: ?u32 = null,
    channels: ?u8 = null,
    bits: ?u8 = null,
    bitrate_kbps: ?u32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

fn sniff(b: []const u8) ?MediaInfo {
    if (b.len < 12) return null;
    if (std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "WAVE")) return parseWav(b);
    if (std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "AVI ")) return parseAvi(b);
    if (std.mem.eql(u8, b[0..4], "fLaC")) return parseFlac(b);
    if (std.mem.eql(u8, b[0..4], "OggS")) return parseOgg(b);
    if (std.mem.eql(u8, b[4..8], "ftyp")) return parseMp4(b);
    if (std.mem.eql(u8, b[0..4], &.{ 0x1A, 0x45, 0xDF, 0xA3 })) return parseMkv(b);
    if (std.mem.startsWith(u8, b, "ID3") or (b[0] == 0xFF and (b[1] & 0xE0) == 0xE0)) return parseMp3(b);
    return null;
}

fn parseWav(b: []const u8) ?MediaInfo {
    var info = MediaInfo{ .format = "WAV (RIFF PCM)", .kind = .audio };
    var byte_rate: u32 = 0;
    var data_size: u64 = 0;

    var pos: usize = 12;
    while (pos + 8 <= b.len) {
        const id = b[pos..][0..4];
        const size = std.mem.readInt(u32, b[pos + 4 ..][0..4], .little);
        if (std.mem.eql(u8, id, "fmt ") and pos + 8 + 16 <= b.len) {
            info.channels = @truncate(std.mem.readInt(u16, b[pos + 10 ..][0..2], .little));
            info.sample_rate = std.mem.readInt(u32, b[pos + 12 ..][0..4], .little);
            byte_rate = std.mem.readInt(u32, b[pos + 16 ..][0..4], .little);
            info.bits = @truncate(std.mem.readInt(u16, b[pos + 22 ..][0..2], .little));
        } else if (std.mem.eql(u8, id, "data")) {
            data_size = size;
        }
        pos += 8 + size + (size & 1); // i chunk RIFF sono allineati a 2 byte
    }

    if (byte_rate > 0 and data_size > 0) {
        info.duration_ms = data_size * 1000 / byte_rate;
        info.bitrate_kbps = byte_rate * 8 / 1000;
    }
    return info;
}

fn parseAvi(b: []const u8) ?MediaInfo {
    var info = MediaInfo{ .format = "AVI", .kind = .video };
    // L'header principale avih sta nei primi KB: scansione limitata e lineare.
    const limit = @min(b.len, 64 * 1024);
    if (std.mem.indexOf(u8, b[0..limit], "avih")) |p| {
        if (p + 8 + 40 <= b.len) {
            const us_per_frame = std.mem.readInt(u32, b[p + 8 ..][0..4], .little);
            const total_frames = std.mem.readInt(u32, b[p + 24 ..][0..4], .little);
            info.width = std.mem.readInt(u32, b[p + 40 ..][0..4], .little);
            info.height = std.mem.readInt(u32, b[p + 44 ..][0..4], .little);
            if (us_per_frame > 0 and total_frames > 0) {
                info.duration_ms = @as(u64, total_frames) * us_per_frame / 1000;
            }
        }
    }
    return info;
}

fn parseFlac(b: []const u8) ?MediaInfo {
    // STREAMINFO è sempre il primo metadata block, a offset 4.
    if (b.len < 4 + 4 + 34) return null;
    const si = b[8..];
    const sr_chan_bits = std.mem.readInt(u32, si[10..14], .big);
    const sample_rate: u32 = sr_chan_bits >> 12;
    const channels: u8 = @truncate(((sr_chan_bits >> 9) & 0x7) + 1);
    const bits: u8 = @truncate(((sr_chan_bits >> 4) & 0x1F) + 1);
    const total_hi: u64 = sr_chan_bits & 0xF;
    const total_samples: u64 = (total_hi << 32) | std.mem.readInt(u32, si[14..18], .big);

    var info = MediaInfo{
        .format = "FLAC",
        .kind = .audio,
        .sample_rate = sample_rate,
        .channels = channels,
        .bits = bits,
    };
    if (sample_rate > 0 and total_samples > 0) {
        info.duration_ms = total_samples * 1000 / sample_rate;
    }
    return info;
}

fn parseOgg(b: []const u8) ?MediaInfo {
    var info = MediaInfo{ .format = "OGG", .kind = .audio };
    var rate: u32 = 0;

    // Il primo packet identifica il codec (a offset 28 nella prima pagina).
    if (b.len > 28 + 16) {
        const pkt = b[28..];
        if (std.mem.startsWith(u8, pkt, "\x01vorbis")) {
            info.format = "OGG Vorbis";
            info.channels = pkt[11];
            rate = std.mem.readInt(u32, pkt[12..16], .little);
            info.sample_rate = rate;
        } else if (std.mem.startsWith(u8, pkt, "OpusHead")) {
            info.format = "OGG Opus";
            info.channels = pkt[9];
            rate = 48000; // Opus lavora sempre a 48 kHz
            info.sample_rate = std.mem.readInt(u32, pkt[12..16], .little);
        } else if (std.mem.startsWith(u8, pkt, "\x80theora")) {
            info.format = "OGG Theora";
            info.kind = .video;
        }
    }

    // Durata = granule position dell'ultima pagina / sample rate.
    if (rate > 0) {
        if (std.mem.lastIndexOf(u8, b, "OggS")) |last| {
            if (last + 14 <= b.len) {
                const granule = std.mem.readInt(u64, b[last + 6 ..][0..8], .little);
                if (granule > 0 and granule != std.math.maxInt(u64)) {
                    info.duration_ms = granule * 1000 / rate;
                }
            }
        }
    }
    return info;
}

fn parseMp4(b: []const u8) ?MediaInfo {
    var info = MediaInfo{ .format = "MP4", .kind = .video };
    if (b.len >= 12) {
        const brand = b[8..12];
        if (std.mem.eql(u8, brand, "M4A ")) {
            info.format = "M4A (audio MP4)";
            info.kind = .audio;
        } else if (std.mem.eql(u8, brand, "qt  ")) {
            info.format = "QuickTime MOV";
        }
    }

    // Cerca moov/mvhd ai primi due livelli di box.
    if (findBox(b, 0, b.len, "moov")) |moov| {
        if (findBox(b, moov.start, moov.end, "mvhd")) |mvhd| {
            const p = b[mvhd.start..mvhd.end];
            if (p.len >= 20) {
                const version = p[0];
                if (version == 0) {
                    const timescale = std.mem.readInt(u32, p[12..16], .big);
                    const duration = std.mem.readInt(u32, p[16..20], .big);
                    if (timescale > 0) info.duration_ms = @as(u64, duration) * 1000 / timescale;
                } else if (version == 1 and p.len >= 32) {
                    const timescale = std.mem.readInt(u32, p[20..24], .big);
                    const duration = std.mem.readInt(u64, p[24..32], .big);
                    if (timescale > 0) info.duration_ms = duration * 1000 / timescale;
                }
            }
        }
        // tkhd della prima traccia video per larghezza/altezza (fixed point 16.16).
        if (findBox(b, moov.start, moov.end, "trak")) |trak| {
            if (findBox(b, trak.start, trak.end, "tkhd")) |tkhd| {
                const p = b[tkhd.start..tkhd.end];
                if (p.len >= 84) {
                    const w = std.mem.readInt(u32, p[p.len - 8 ..][0..4], .big) >> 16;
                    const h = std.mem.readInt(u32, p[p.len - 4 ..][0..4], .big) >> 16;
                    if (w > 0 and h > 0) {
                        info.width = w;
                        info.height = h;
                    }
                }
            }
        }
    }
    return info;
}

const BoxRange = struct { start: usize, end: usize };

/// Cerca un box ISO-BMFF di tipo `name` tra i figli diretti di [start, end).
fn findBox(b: []const u8, start: usize, end: usize, name: *const [4]u8) ?BoxRange {
    var pos = start;
    while (pos + 8 <= end and pos + 8 <= b.len) {
        var size: u64 = std.mem.readInt(u32, b[pos..][0..4], .big);
        var header: usize = 8;
        if (size == 1) {
            if (pos + 16 > b.len) return null;
            size = std.mem.readInt(u64, b[pos + 8 ..][0..8], .big);
            header = 16;
        } else if (size == 0) {
            size = end - pos; // il box si estende fino alla fine
        }
        if (size < header) return null;
        const box_end = pos + (std.math.cast(usize, size) orelse return null);
        if (box_end > b.len or box_end > end) return null;
        if (std.mem.eql(u8, b[pos + 4 ..][0..4], name)) {
            return .{ .start = pos + header, .end = box_end };
        }
        pos = box_end;
    }
    return null;
}

fn parseMkv(b: []const u8) ?MediaInfo {
    var info = MediaInfo{ .format = "Matroska MKV", .kind = .video };
    const limit = @min(b.len, 4096);
    if (std.mem.indexOf(u8, b[0..limit], "webm")) |_| {
        info.format = "WebM";
    }
    // La durata Matroska richiede il parsing EBML completo: per ora solo formato.
    return info;
}

fn parseMp3(b: []const u8) ?MediaInfo {
    var pos: usize = 0;
    var has_id3 = false;

    if (std.mem.startsWith(u8, b, "ID3") and b.len > 10) {
        has_id3 = true;
        // Dimensione ID3v2 in syncsafe u28.
        const size: u32 = (@as(u32, b[6] & 0x7F) << 21) | (@as(u32, b[7] & 0x7F) << 14) |
            (@as(u32, b[8] & 0x7F) << 7) | (b[9] & 0x7F);
        pos = 10 + size;
    }

    // Cerca il primo header di frame valido (sync a 11 bit).
    const bitrates = [_]u16{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
    const rates = [_]u16{ 44100, 48000, 32000, 0 };
    const scan_end = @min(b.len -| 4, pos + 64 * 1024);
    while (pos < scan_end) : (pos += 1) {
        if (b[pos] != 0xFF or (b[pos + 1] & 0xE0) != 0xE0) continue;
        const version = (b[pos + 1] >> 3) & 0x3; // 3 = MPEG-1
        const layer = (b[pos + 1] >> 1) & 0x3; // 1 = Layer III
        if (version != 3 or layer != 1) continue;
        const br_idx = (b[pos + 2] >> 4) & 0xF;
        const sr_idx = (b[pos + 2] >> 2) & 0x3;
        if (bitrates[br_idx] == 0 or rates[sr_idx] == 0) continue;

        const bitrate: u32 = bitrates[br_idx];
        var info = MediaInfo{
            .format = if (has_id3) "MP3 (MPEG-1 Layer III, tag ID3)" else "MP3 (MPEG-1 Layer III)",
            .kind = .audio,
            .sample_rate = rates[sr_idx],
            .channels = if (((b[pos + 3] >> 6) & 0x3) == 3) 1 else 2,
            .bitrate_kbps = bitrate,
        };
        // Stima CBR: per i VBR è approssimata ma senza costi di scansione.
        info.duration_ms = @as(u64, b.len - pos) * 8 / bitrate;
        return info;
    }
    return null;
}

fn render(info: MediaInfo, filename: []const u8, file_size: usize, allocator: std.mem.Allocator) []const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    w.print("{s}\n\n", .{filename}) catch return fallback(allocator);
    w.print("Tipo:        {s}\n", .{if (info.kind == .audio) "Audio" else "Video"}) catch return fallback(allocator);
    w.print("Formato:     {s}\n", .{info.format}) catch return fallback(allocator);

    if (info.duration_ms) |ms| {
        const total_s = ms / 1000;
        const h = total_s / 3600;
        const m = (total_s % 3600) / 60;
        const s = total_s % 60;
        if (h > 0) {
            w.print("Durata:      {d}:{d:0>2}:{d:0>2}\n", .{ h, m, s }) catch return fallback(allocator);
        } else {
            w.print("Durata:      {d}:{d:0>2}\n", .{ m, s }) catch return fallback(allocator);
        }
    }
    if (info.width) |wd| {
        w.print("Risoluzione: {d}x{d}\n", .{ wd, info.height orelse 0 }) catch return fallback(allocator);
    }
    if (info.sample_rate) |sr| {
        w.print("Campioni:    {d} Hz", .{sr}) catch return fallback(allocator);
        if (info.channels) |ch| {
            const ch_name: []const u8 = switch (ch) {
                1 => "mono",
                2 => "stereo",
                else => "multicanale",
            };
            w.print(", {s}", .{ch_name}) catch return fallback(allocator);
        }
        if (info.bits) |bits| {
            w.print(", {d} bit", .{bits}) catch return fallback(allocator);
        }
        w.print("\n", .{}) catch return fallback(allocator);
    }
    if (info.bitrate_kbps) |br| {
        w.print("Bitrate:     {d} kbps\n", .{br}) catch return fallback(allocator);
    }

    var size_buf: [32]u8 = undefined;
    w.print("Dimensione:  {s}\n", .{formatSize(&size_buf, file_size)}) catch return fallback(allocator);

    return out.toOwnedSlice() catch fallback(allocator);
}

fn fallback(allocator: std.mem.Allocator) []const u8 {
    return allocator.dupe(u8, "anteprima non disponibile") catch "";
}

fn formatSize(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1024.0 and u < units.len - 1) : (u += 1) v /= 1024.0;
    if (u == 0) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "?";
}

export fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const filename = std.fs.path.basename(path.toSlice());

    const decoded = decode(content.toSlice(), filename, allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

const extensions = "mp3,wav,flac,ogg,oga,ogv,opus,m4a,mp4,m4v,mov,mkv,webm,avi";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}
