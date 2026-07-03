//! Plugin Office: estrae il testo dai documenti OOXML/OpenDocument
//! (docx, pptx, odt, odp). Sono archivi ZIP con l'XML del contenuto dentro:
//! si legge la central directory, si decomprime l'entry giusta con la flate
//! della std e si spoglia l'XML dai tag. Nessuna dipendenza esterna.

const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;

pub fn decode(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    defer allocator.free(bytes);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    const result = extract(bytes, filename, allocator, w);
    if (result) {
        const text = out.toOwnedSlice() catch {
            const msg = allocator.dupe(u8, "Memoria esaurita durante l'estrazione.") catch "";
            return .{ .err = msg };
        };
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            allocator.free(text);
            const msg = allocator.dupe(u8, "Il documento non contiene testo estraibile.") catch "";
            return .{ .err = msg };
        }
        return .{ .text = text };
    } else |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile estrarre il documento: {s}", .{@errorName(err)}) catch "";
        return .{ .err = msg };
    }
}

fn extract(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator, w: *std.Io.Writer) !void {
    if (hasExtension(filename, ".docx")) {
        const xml = try readZipEntry(bytes, "word/document.xml", allocator);
        defer allocator.free(xml);
        try xmlToText(xml, w);
    } else if (hasExtension(filename, ".pptx")) {
        // Le slide sono entry numerate: ci si ferma alla prima mancante.
        var slide: usize = 1;
        while (slide <= 500) : (slide += 1) {
            var name_buf: [48]u8 = undefined;
            const entry_name = try std.fmt.bufPrint(&name_buf, "ppt/slides/slide{d}.xml", .{slide});
            const xml = readZipEntry(bytes, entry_name, allocator) catch break;
            defer allocator.free(xml);
            try w.print("— Slide {d} —\n", .{slide});
            try xmlToText(xml, w);
            try w.writeAll("\n");
        }
        if (slide == 1) return error.NoSlidesFound;
    } else {
        // odt / odp
        const xml = try readZipEntry(bytes, "content.xml", allocator);
        defer allocator.free(xml);
        try xmlToText(xml, w);
    }
}

fn hasExtension(filename: []const u8, comptime ext: []const u8) bool {
    if (filename.len < ext.len) return false;
    const tail = filename[filename.len - ext.len ..];
    for (tail, ext) |a, b| {
        if (std.ascii.toLower(a) != b) return false;
    }
    return true;
}

// --- ZIP -----------------------------------------------------------------

const eocd_sig = 0x06054b50;
const central_sig = 0x02014b50;
const local_sig = 0x04034b50;

fn readU16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

/// Estrae e decomprime una singola entry dello ZIP cercandola per nome
/// nella central directory. Supporta i metodi stored (0) e deflate (8).
fn readZipEntry(bytes: []const u8, wanted: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (bytes.len < 22) return error.NotAZipFile;

    // End Of Central Directory: si cerca all'indietro (può seguirlo un commento)
    var eocd: ?usize = null;
    const scan_start = if (bytes.len > 22 + 65535) bytes.len - 22 - 65535 else 0;
    var pos = bytes.len - 22;
    while (true) {
        if (readU32(bytes, pos) == eocd_sig) {
            eocd = pos;
            break;
        }
        if (pos == scan_start) break;
        pos -= 1;
    }
    const eocd_off = eocd orelse return error.NotAZipFile;

    const total_entries = readU16(bytes, eocd_off + 10);
    var cd_off: usize = readU32(bytes, eocd_off + 16);

    var i: usize = 0;
    while (i < total_entries) : (i += 1) {
        if (cd_off + 46 > bytes.len or readU32(bytes, cd_off) != central_sig) return error.CorruptZip;
        const method = readU16(bytes, cd_off + 10);
        const comp_size: usize = readU32(bytes, cd_off + 20);
        const uncomp_size: usize = readU32(bytes, cd_off + 24);
        const name_len: usize = readU16(bytes, cd_off + 28);
        const extra_len: usize = readU16(bytes, cd_off + 30);
        const comment_len: usize = readU16(bytes, cd_off + 32);
        const local_off: usize = readU32(bytes, cd_off + 42);
        if (cd_off + 46 + name_len > bytes.len) return error.CorruptZip;
        const name = bytes[cd_off + 46 .. cd_off + 46 + name_len];

        if (std.mem.eql(u8, name, wanted)) {
            if (local_off + 30 > bytes.len or readU32(bytes, local_off) != local_sig) return error.CorruptZip;
            const l_name_len: usize = readU16(bytes, local_off + 26);
            const l_extra_len: usize = readU16(bytes, local_off + 28);
            const data_off = local_off + 30 + l_name_len + l_extra_len;
            if (data_off + comp_size > bytes.len) return error.CorruptZip;
            const comp = bytes[data_off .. data_off + comp_size];

            switch (method) {
                0 => return allocator.dupe(u8, comp),
                8 => return inflateRaw(comp, uncomp_size, allocator),
                else => return error.UnsupportedCompression,
            }
        }

        cd_off += 46 + name_len + extra_len + comment_len;
    }
    return error.EntryNotFound;
}

fn inflateRaw(comp: []const u8, uncomp_size: usize, allocator: std.mem.Allocator) ![]u8 {
    // Tetto di sicurezza contro dichiarazioni assurde nell'header ZIP
    if (uncomp_size > 512 * 1024 * 1024) return error.EntryTooLarge;

    var in: std.Io.Reader = .fixed(comp);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&in, .raw, &window);

    const out = try allocator.alloc(u8, uncomp_size);
    errdefer allocator.free(out);
    try dec.reader.readSliceAll(out);
    return out;
}

// --- XML -------------------------------------------------------------------

/// Riduce l'XML al solo testo: i contenuti si accumulano, la chiusura di un
/// paragrafo (w:p per docx, a:p per pptx, text:p/text:h per ODF) va a capo.
fn xmlToText(xml: []const u8, w: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < xml.len) {
        const c = xml[i];
        if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, xml, i + 1, '>') orelse break;
            const tag = xml[i + 1 .. end];
            if (std.mem.eql(u8, tag, "/w:p") or
                std.mem.eql(u8, tag, "/a:p") or
                std.mem.eql(u8, tag, "/text:p") or
                std.mem.eql(u8, tag, "/text:h"))
            {
                try w.writeByte('\n');
            } else if (std.mem.eql(u8, tag, "w:br/") or std.mem.eql(u8, tag, "text:line-break/")) {
                try w.writeByte('\n');
            } else if (std.mem.eql(u8, tag, "w:tab/") or std.mem.eql(u8, tag, "text:tab/")) {
                try w.writeByte('\t');
            }
            i = end + 1;
        } else if (c == '&') {
            // Entity più comuni; le sconosciute passano letterali
            const entities = [_]struct { name: []const u8, ch: u8 }{
                .{ .name = "&amp;", .ch = '&' },
                .{ .name = "&lt;", .ch = '<' },
                .{ .name = "&gt;", .ch = '>' },
                .{ .name = "&quot;", .ch = '"' },
                .{ .name = "&apos;", .ch = '\'' },
            };
            var matched = false;
            for (entities) |e| {
                if (std.mem.startsWith(u8, xml[i..], e.name)) {
                    try w.writeByte(e.ch);
                    i += e.name.len;
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                try w.writeByte(c);
                i += 1;
            }
        } else {
            try w.writeByte(c);
            i += 1;
        }
    }
}

export fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const path_slice = path.toSlice();
    const filename = std.fs.path.basename(path_slice);
    const decoded = decode(content.toSlice(), filename, allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

const extensions = "docx,pptx,odt,odp";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}
