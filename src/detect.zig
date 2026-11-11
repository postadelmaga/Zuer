//! Rilevamento del formato dai byte magici, indipendente dall'estensione.
//!
//! Funzione PURA su un prefisso del file (bastano i primi `probe_bytes`): non
//! apre file, non alloca, non carica né inizializza decoder. Il risultato dice
//! QUALE plugin (per nome di manifest, vedi `plugin_manifest` in decoder.zig)
//! sa aprire il contenuto; il caricamento resta al registro plugin.
//!
//! Solo firme FORTI: una firma debole (2 byte, o testo plausibile) farebbe
//! dirottare un file di testo legittimo su un decoder binario. Dove la firma
//! base è corta (BMP, PE, bzip2) si verifica anche un campo strutturale.

const std = @import("std");

/// Byte di prefisso sufficienti per tutte le firme riconosciute (`%PDF-` può
/// stare entro i primi 1024 byte, `ustar` a offset 257).
pub const probe_bytes = 1024;

pub const Format = enum {
    unknown,
    // immagini
    png,
    jpeg,
    gif,
    bmp,
    webp,
    tiff,
    ico,
    psd,
    hdr,
    avif,
    heif,
    jxl,
    jp2,
    exr,
    dds,
    cr3,
    // documenti
    pdf,
    // archivi
    zip,
    tar,
    gzip,
    sevenz,
    rar,
    xz,
    zstd,
    bzip2,
    // modelli 3D
    glb,
    // audio / video
    mp4,
    matroska,
    avi,
    wav,
    mp3,
    aac,
    flac,
    ogg,
    midi,
    // eseguibili e altro
    elf,
    pe,
    macho,
    wasm,
    sqlite,
};

pub const Detection = struct {
    format: Format = .unknown,
    /// Nome del plugin che sa aprirlo; null = formato riconosciuto ma senza
    /// decoder (o `.unknown`).
    plugin: ?[]const u8 = null,
    mime: []const u8 = "application/octet-stream",
    /// Nome leggibile per i messaggi all'utente.
    label: []const u8 = "sconosciuto",
    /// La firma da sola non basta a garantire che il plugin lo apra (es. gzip:
    /// può essere un tar compresso come no).
    ambiguous: bool = false,
    /// Firma valida ma header più corto del minimo, o lunghezza dichiarata
    /// oltre la fine del file: file incompleto o corrotto.
    truncated: bool = false,

    pub fn known(self: Detection) bool {
        return self.format != .unknown;
    }
};

const Info = struct { plugin: ?[]const u8, mime: []const u8, label: []const u8, min_len: usize = 0 };

fn info(f: Format) Info {
    return switch (f) {
        .unknown => .{ .plugin = null, .mime = "application/octet-stream", .label = "sconosciuto" },
        .png => .{ .plugin = "image", .mime = "image/png", .label = "PNG", .min_len = 33 },
        .jpeg => .{ .plugin = "image", .mime = "image/jpeg", .label = "JPEG", .min_len = 4 },
        .gif => .{ .plugin = "image", .mime = "image/gif", .label = "GIF", .min_len = 13 },
        .bmp => .{ .plugin = "image", .mime = "image/bmp", .label = "BMP", .min_len = 26 },
        .webp => .{ .plugin = "image", .mime = "image/webp", .label = "WebP", .min_len = 16 },
        .tiff => .{ .plugin = "image", .mime = "image/tiff", .label = "TIFF", .min_len = 8 },
        .ico => .{ .plugin = "image", .mime = "image/vnd.microsoft.icon", .label = "ICO", .min_len = 22 },
        .psd => .{ .plugin = "image", .mime = "image/vnd.adobe.photoshop", .label = "PSD", .min_len = 26 },
        .hdr => .{ .plugin = "image", .mime = "image/vnd.radiance", .label = "Radiance HDR" },
        .avif => .{ .plugin = "image", .mime = "image/avif", .label = "AVIF" },
        // HEIF/HEIC: nessun codec in processo, decide il codec di sistema del plugin
        // immagini (ImageIO su macOS, WIC su Windows, ImageMagick su Linux).
        .heif => .{ .plugin = "image", .mime = "image/heif", .label = "HEIF/HEIC" },
        // Senza codec in processo anche questi: codec di sistema del plugin immagini
        // (ImageIO li apre tutti su macOS; WIC/ImageMagick secondo i codec installati).
        .jxl => .{ .plugin = "image", .mime = "image/jxl", .label = "JPEG XL" },
        .jp2 => .{ .plugin = "image", .mime = "image/jp2", .label = "JPEG 2000" },
        .exr => .{ .plugin = "image", .mime = "image/x-exr", .label = "OpenEXR" },
        .dds => .{ .plugin = "image", .mime = "image/vnd-ms.dds", .label = "DirectDraw Surface", .min_len = 128 },
        .cr3 => .{ .plugin = "image", .mime = "image/x-canon-cr3", .label = "Canon RAW (CR3)" },
        .pdf => .{ .plugin = "pdf", .mime = "application/pdf", .label = "PDF" },
        .zip => .{ .plugin = "archive", .mime = "application/zip", .label = "ZIP" },
        .tar => .{ .plugin = "tar", .mime = "application/x-tar", .label = "tar" },
        .gzip => .{ .plugin = "tar", .mime = "application/gzip", .label = "gzip" },
        // 7z, RAR e i tar compressi non-gzip: li elenca bsdtar (vedi tar.zig).
        .sevenz => .{ .plugin = "tar", .mime = "application/x-7z-compressed", .label = "7-Zip" },
        .rar => .{ .plugin = "tar", .mime = "application/vnd.rar", .label = "RAR" },
        .xz => .{ .plugin = "tar", .mime = "application/x-xz", .label = "xz" },
        .zstd => .{ .plugin = "tar", .mime = "application/zstd", .label = "Zstandard" },
        .bzip2 => .{ .plugin = "tar", .mime = "application/x-bzip2", .label = "bzip2" },
        .glb => .{ .plugin = "glb", .mime = "model/gltf-binary", .label = "glTF binario", .min_len = 20 },
        .mp4 => .{ .plugin = "media", .mime = "video/mp4", .label = "MP4/QuickTime" },
        .matroska => .{ .plugin = "media", .mime = "video/x-matroska", .label = "Matroska/WebM" },
        .avi => .{ .plugin = "media", .mime = "video/x-msvideo", .label = "AVI" },
        .wav => .{ .plugin = "media", .mime = "audio/wav", .label = "WAV" },
        .mp3 => .{ .plugin = "media", .mime = "audio/mpeg", .label = "MP3" },
        .aac => .{ .plugin = "media", .mime = "audio/aac", .label = "AAC (ADTS)" },
        .flac => .{ .plugin = "media", .mime = "audio/flac", .label = "FLAC" },
        .ogg => .{ .plugin = "media", .mime = "audio/ogg", .label = "Ogg" },
        .midi => .{ .plugin = "media", .mime = "audio/midi", .label = "MIDI", .min_len = 14 },
        .elf => .{ .plugin = null, .mime = "application/x-executable", .label = "eseguibile ELF" },
        .pe => .{ .plugin = null, .mime = "application/vnd.microsoft.portable-executable", .label = "eseguibile Windows (PE)" },
        .macho => .{ .plugin = null, .mime = "application/x-mach-binary", .label = "eseguibile Mach-O" },
        .wasm => .{ .plugin = null, .mime = "application/wasm", .label = "WebAssembly" },
        .sqlite => .{ .plugin = null, .mime = "application/vnd.sqlite3", .label = "database SQLite" },
    };
}

fn at(bytes: []const u8, off: usize, sig: []const u8) bool {
    return bytes.len >= off + sig.len and std.mem.eql(u8, bytes[off..][0..sig.len], sig);
}

fn readU32Le(bytes: []const u8, off: usize) ?u32 {
    if (bytes.len < off + 4) return null;
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

/// Identifica il formato da `prefix` (i primi byte del file, almeno
/// `probe_bytes` se disponibili) e dalla dimensione totale `file_size`.
pub fn detect(prefix: []const u8, file_size: u64) Detection {
    const f = classify(prefix);
    if (f == .unknown) return .{};
    const i = info(f);
    var d = Detection{
        .format = f,
        .plugin = i.plugin,
        .mime = i.mime,
        .label = i.label,
        .ambiguous = f == .gzip,
    };
    // Header più corto del minimo: il prefisso È il file intero (non ci sono
    // altri byte da leggere), quindi il decode fallirebbe comunque.
    if (prefix.len < i.min_len and file_size <= prefix.len) d.truncated = true;
    // glb dichiara la lunghezza totale nell'header (byte 8..12).
    if (f == .glb) {
        if (readU32Le(prefix, 8)) |declared| {
            if (declared > file_size) d.truncated = true;
        }
    }
    return d;
}

fn classify(b: []const u8) Format {
    // --- immagini
    if (at(b, 0, "\x89PNG\r\n\x1a\n")) return .png;
    if (at(b, 0, "\xff\xd8\xff")) return .jpeg;
    if (at(b, 0, "GIF87a") or at(b, 0, "GIF89a")) return .gif;
    if (at(b, 0, "BM") and isBmpDib(b)) return .bmp;
    if (at(b, 0, "RIFF") and b.len >= 12) {
        if (at(b, 8, "WEBP")) return .webp;
        if (at(b, 8, "AVI ")) return .avi;
        if (at(b, 8, "WAVE")) return .wav;
    }
    if (at(b, 0, "II*\x00") or at(b, 0, "MM\x00*")) return .tiff;
    if (at(b, 0, "8BPS")) return .psd;
    if (at(b, 0, "#?RADIANCE") or at(b, 0, "#?RGBE")) return .hdr;
    if (isIco(b)) return .ico;
    // JPEG XL: contenitore ISO-BMFF dedicato o codestream nudo (0xFF non è UTF-8).
    if (at(b, 0, "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a") or at(b, 0, "\xff\x0a")) return .jxl;
    // JPEG 2000: contenitore JP2 o codestream J2K (SOC + SIZ).
    if (at(b, 0, "\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0a") or at(b, 0, "\xff\x4f\xff\x51")) return .jp2;
    if (at(b, 0, "\x76\x2f\x31\x01")) return .exr;
    // DDS: magic + dimensione dell'header (sempre 124).
    if (at(b, 0, "DDS \x7c\x00\x00\x00")) return .dds;
    if (at(b, 4, "ftyp")) return classifyFtyp(b);

    // --- documenti: la specifica PDF ammette spazzatura prima di `%PDF-`
    // entro i primi 1024 byte.
    if (std.mem.indexOf(u8, b[0..@min(b.len, 1024)], "%PDF-") != null) return .pdf;

    // --- archivi
    if (at(b, 0, "PK\x03\x04") or at(b, 0, "PK\x05\x06")) return .zip;
    if (at(b, 257, "ustar")) return .tar;
    if (at(b, 0, "\x1f\x8b\x08")) return .gzip;
    if (at(b, 0, "7z\xbc\xaf\x27\x1c")) return .sevenz;
    if (at(b, 0, "Rar!\x1a\x07")) return .rar;
    if (at(b, 0, "\xfd7zXZ\x00")) return .xz;
    if (at(b, 0, "\x28\xb5\x2f\xfd")) return .zstd;
    // "BZh" + livello 1-9 + magic del primo blocco (cifre di pi): "BZh" da solo
    // è un inizio di testo plausibile.
    if (at(b, 0, "BZh") and b.len >= 10 and b[3] >= '1' and b[3] <= '9' and at(b, 4, "\x31\x41\x59\x26\x53\x59")) return .bzip2;

    // --- modelli 3D
    if (at(b, 0, "glTF") and (readU32Le(b, 4) orelse 0) == 2) return .glb;

    // --- audio / video
    if (at(b, 0, "\x1a\x45\xdf\xa3")) return .matroska;
    if (at(b, 0, "fLaC")) return .flac;
    if (at(b, 0, "OggS")) return .ogg;
    if (at(b, 0, "MThd") and (readU32BeOpt(b, 4) orelse 0) == 6) return .midi;
    if (at(b, 0, "ID3")) return .mp3;
    if (b.len >= 2 and b[0] == 0xff) {
        // Frame sync MPEG audio: solo le combinazioni comuni, per non
        // collidere con altri formati che iniziano per 0xFF.
        switch (b[1]) {
            0xfb, 0xfa, 0xf3, 0xf2, 0xe3 => return .mp3,
            0xf1, 0xf9 => return .aac,
            else => {},
        }
    }

    // --- eseguibili e altro
    if (at(b, 0, "\x7fELF")) return .elf;
    if (at(b, 0, "MZ") and isPe(b)) return .pe;
    if (at(b, 0, "\xcf\xfa\xed\xfe") or at(b, 0, "\xce\xfa\xed\xfe") or
        at(b, 0, "\xfe\xed\xfa\xcf") or at(b, 0, "\xfe\xed\xfa\xce")) return .macho;
    if (at(b, 0, "\x00asm")) return .wasm;
    if (at(b, 0, "SQLite format 3\x00")) return .sqlite;

    return .unknown;
}

fn readU32BeOpt(bytes: []const u8, off: usize) ?u32 {
    if (bytes.len < off + 4) return null;
    return std.mem.readInt(u32, bytes[off..][0..4], .big);
}

/// "BM" sono due byte ASCII: si conferma con la dimensione del DIB header
/// (offset 14), che ha solo pochi valori validi.
fn isBmpDib(b: []const u8) bool {
    const dib = readU32Le(b, 14) orelse return false;
    return switch (dib) {
        12, 40, 52, 56, 64, 108, 124 => true,
        else => false,
    };
}

/// ICO: reserved=0, type=1, 1..255 immagini, e il byte riservato della prima
/// voce della directory a zero.
fn isIco(b: []const u8) bool {
    if (!at(b, 0, "\x00\x00\x01\x00") or b.len < 22) return false;
    const count = std.mem.readInt(u16, b[4..6], .little);
    return count >= 1 and count <= 255 and b[6 + 3] == 0;
}

/// PE: "MZ" + `e_lfanew` (offset 0x3c) che punta a "PE\0\0" DENTRO il
/// prefisso (nei linker reali è 0x40-0x200). Senza conferma "MZ" resta testo.
fn isPe(b: []const u8) bool {
    const lfanew = readU32Le(b, 0x3c) orelse return false;
    return lfanew <= b.len and at(b, lfanew, "PE\x00\x00");
}

/// ISO-BMFF (`....ftyp<brand>`): AVIF e HEIF condividono il contenitore con
/// MP4/MOV; si guardano major brand e compatible brands.
fn classifyFtyp(b: []const u8) Format {
    const box_len = readU32BeOpt(b, 0) orelse return .mp4;
    const end = @min(b.len, @max(@as(usize, box_len), 16));
    var off: usize = 8;
    var heif = false;
    while (off + 4 <= end) : (off += 4) {
        if (off == 12) continue; // minor_version, non un brand
        const brand = b[off..][0..4];
        if (off == 8 and std.mem.eql(u8, brand, "crx ")) return .cr3;
        if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return .avif;
        for ([_]*const [4]u8{ "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1" }) |h| {
            if (std.mem.eql(u8, brand, h)) heif = true;
        }
    }
    return if (heif) .heif else .mp4;
}

// ---------------------------------------------------------------------------
// Test

fn expectFormat(bytes: []const u8, f: Format) !void {
    try std.testing.expectEqual(f, detect(bytes, bytes.len).format);
}

test "firme immagine dei codec di sistema" {
    try expectFormat("\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a\x00\x00", .jxl);
    try expectFormat("\xff\x0a\xfa\x7f", .jxl);
    try expectFormat("\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0a\x00\x00", .jp2);
    try expectFormat("\xff\x4f\xff\x51\x00\x2f", .jp2);
    try expectFormat("\x76\x2f\x31\x01\x02\x00\x00\x00", .exr);
    try expectFormat("DDS \x7c\x00\x00\x00\x07\x10", .dds);
    try expectFormat("\x00\x00\x00\x18ftypcrx \x00\x00\x00\x01crx isom", .cr3);
    try std.testing.expectEqualStrings("image", detect("\x00\x00\x00\x18ftypcrx \x00\x00\x00\x01crx isom", 24).plugin.?);
}

test "firme immagine" {
    try expectFormat("\x89PNG\r\n\x1a\n" ++ &@as([25]u8, @splat(0)), .png);
    try expectFormat("\xff\xd8\xff\xe0\x00\x10JFIF", .jpeg);
    try expectFormat("GIF89a\x01\x00\x01\x00\x00\x00\x00", .gif);
    try expectFormat("RIFF\x00\x00\x00\x00WEBPVP8 ", .webp);
    try expectFormat("II*\x00\x08\x00\x00\x00", .tiff);
    var bmp: [54]u8 = @splat(0);
    bmp[0] = 'B';
    bmp[1] = 'M';
    bmp[14] = 40;
    try expectFormat(&bmp, .bmp);
}

test "testo che inizia come una firma debole resta testo" {
    try expectFormat("BMW e Audi sono marche tedesche, non bitmap.\n", .unknown);
    try expectFormat("MZ: appunti sul formato DOS, senza header vero e proprio.....\n", .unknown);
    try expectFormat("BZh, questa non e' una bzip2\n", .unknown);
    try expectFormat("ciao mondo\n", .unknown);
    try expectFormat("", .unknown);
}

test "contenitori ftyp: mp4, avif, heic" {
    try expectFormat("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2", .mp4);
    try expectFormat("\x00\x00\x00\x1cftypavif\x00\x00\x00\x00avifmif1miaf", .avif);
    // AVIF con major brand mif1: decide il compatible brand.
    try expectFormat("\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00mif1avif", .avif);
    try expectFormat("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic", .heif);
    try std.testing.expectEqualStrings("image", detect("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic", 24).plugin.?);
}

test "documenti, archivi, media" {
    try expectFormat("%PDF-1.7\n", .pdf);
    try expectFormat("\xef\xbb\xbf  \n%PDF-1.4", .pdf);
    try expectFormat("PK\x03\x04\x14\x00", .zip);
    try expectFormat("\x1f\x8b\x08\x00", .gzip);
    try std.testing.expect(detect("\x1f\x8b\x08\x00", 4).ambiguous);
    try expectFormat("\x1a\x45\xdf\xa3\x9f\x42\x86\x81", .matroska);
    try expectFormat("fLaC\x00\x00\x00\x22", .flac);
    try expectFormat("OggS\x00\x02", .ogg);
    try expectFormat("ID3\x04\x00", .mp3);
    try expectFormat("MThd\x00\x00\x00\x06\x00\x01\x00\x02\x01\xe0", .midi);
    var tar: [512]u8 = @splat(0);
    @memcpy(tar[257..262], "ustar");
    try expectFormat(&tar, .tar);
}

test "eseguibili riconosciuti ma senza plugin" {
    const d = detect("\x7fELF\x02\x01\x01\x00", 8);
    try std.testing.expectEqual(Format.elf, d.format);
    try std.testing.expect(d.plugin == null);
    try std.testing.expect(d.known());
}

test "file troncati" {
    // PNG di soli 8 byte: firma senza IHDR.
    try std.testing.expect(detect("\x89PNG\r\n\x1a\n", 8).truncated);
    // Stesso prefisso ma file più lungo: il probe è solo corto, non il file.
    try std.testing.expect(!detect("\x89PNG\r\n\x1a\n", 4096).truncated);
    // glb che dichiara 1000 byte ma il file ne ha 20.
    const glb = "glTF\x02\x00\x00\x00\xe8\x03\x00\x00" ++ &@as([8]u8, @splat(0));
    try std.testing.expect(detect(glb, glb.len).truncated);
    try std.testing.expect(!detect(glb, 1000).truncated);
}
