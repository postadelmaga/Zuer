//! Profili colore ICC incorporati nelle immagini: estrazione (JPEG, PNG, TIFF,
//! WebP) e conversione verso sRGB dei profili RGB a matrice e curve (ProPhoto,
//! Adobe RGB, Display P3…), come fanno i visualizzatori con la gestione del colore.
//! Senza conversione un'immagine ProPhoto mostrata come sRGB ha colori spenti e
//! falsati. Puro Zig, senza lcms: i profili a tabelle (solo A2B0), quelli non RGB
//! e quelli già sRGB restano senza conversione, come prima.

const std = @import("std");

/// Voci della tabella lineare → byte sRGB: passo di 1/16384 in luce lineare,
/// cioè al più ~0,2 livelli sRGB vicino al nero, dove la curva è più ripida.
const enc_n = 16385;

/// Conversione pronta di un profilo verso sRGB.
pub const Transform = struct {
    /// Byte del canale → luce lineare (2^24 = 1), con la curva (TRC) del profilo.
    lin: [3][256]i64,
    /// Lineare del profilo → lineare sRGB (entrambi con bianco D50 nel PCS), a 2^20.
    m: [3][3]i64,
    /// Luce lineare in [0, 1] (a passi di 1/(enc_n−1)) → byte sRGB.
    enc: [enc_n]u8,

    /// Converte sul posto pixel RGB a 8 bit. I colori fuori dalla gamma sRGB
    /// si tagliano, come il rendering colorimetrico relativo dei profili a matrice.
    pub fn apply(t: *const Transform, rgb: []u8) void {
        // Virgola fissa: luce lineare a 2^24, matrice a 2^20, somma a 64 bit (i
        // primari validati in `Profile.parse` la tengono lontana dal traboccare),
        // indice di `enc` clampato. Senza controlli di sicurezza: 22 ms per 3,7 MP
        // invece di 108 (stessi byte del float, entro 1 livello da lcms).
        @setRuntimeSafety(false);
        // Matrice in variabili locali: le scritture di byte in `rgb` potrebbero
        // toccare `t` (un u8 può fare alias di tutto), e il compilatore la
        // rileggerebbe a ogni pixel.
        const m = t.m;
        var i: usize = 0;
        while (i + 3 <= rgb.len) : (i += 3) {
            const r = t.lin[0][rgb[i]];
            const g = t.lin[1][rgb[i + 1]];
            const b = t.lin[2][rgb[i + 2]];
            var out: [3]u8 = undefined;
            inline for (0..3) |c| {
                const v = (m[c][0] * r + m[c][1] * g + m[c][2] * b + (1 << 29)) >> 30;
                out[c] = t.enc[@intCast(std.math.clamp(v, 0, enc_n - 1))];
            }
            rgb[i..][0..3].* = out;
        }
    }
};

/// Colori primari di sRGB adattati a D50 (Bradford), come nei profili sRGB comuni.
const srgb_colorants = [3][3]f64{
    .{ 0.436066, 0.222488, 0.013916 }, // rXYZ
    .{ 0.385147, 0.716873, 0.097076 }, // gXYZ
    .{ 0.143066, 0.060608, 0.714096 }, // bXYZ
};

fn srgbToLinear(x: f64) f64 {
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(x: f64) f64 {
    return if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f64, x, 1.0 / 2.4) - 0.055;
}

/// Prepara in `t` la conversione del profilo `profile` verso sRGB. false (e `t`
/// indefinito) se il profilo non si gestisce o è già sRGB: niente da convertire.
pub fn init(t: *Transform, profile: []const u8) bool {
    const p = Profile.parse(profile) orelse return false;
    if (p.isSrgb()) return false;

    // m = S⁻¹ · P: lineare del profilo → XYZ D50 → lineare sRGB.
    var pm: [3][3]f64 = undefined; // righe X, Y, Z; colonne r, g, b
    var sm: [3][3]f64 = undefined;
    for (0..3) |row| for (0..3) |col| {
        pm[row][col] = p.colorants[col][row];
        sm[row][col] = srgb_colorants[col][row];
    };
    const si = invert(sm) orelse return false;
    for (0..3) |row| for (0..3) |col| {
        var s: f64 = 0;
        for (0..3) |k| s += si[row][k] * pm[k][col];
        t.m[row][col] = @intFromFloat(@round(s * (1 << 20)));
    };
    for (0..3) |c| for (0..256) |v| {
        t.lin[c][v] = @intFromFloat(@round(p.curves[c].eval(@as(f64, @floatFromInt(v)) / 255.0) * (1 << 24)));
    };
    for (&t.enc, 0..) |*e, j| {
        const x = @as(f64, @floatFromInt(j)) / (enc_n - 1);
        e.* = @intFromFloat(@round(std.math.clamp(linearToSrgb(x), 0, 1) * 255));
    }
    return true;
}

fn invert(a: [3][3]f64) ?[3][3]f64 {
    const det = a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
        a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
        a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
    if (@abs(det) < 1e-9) return null;
    const d = 1 / det;
    return .{
        .{ (a[1][1] * a[2][2] - a[1][2] * a[2][1]) * d, (a[0][2] * a[2][1] - a[0][1] * a[2][2]) * d, (a[0][1] * a[1][2] - a[0][2] * a[1][1]) * d },
        .{ (a[1][2] * a[2][0] - a[1][0] * a[2][2]) * d, (a[0][0] * a[2][2] - a[0][2] * a[2][0]) * d, (a[0][2] * a[1][0] - a[0][0] * a[1][2]) * d },
        .{ (a[1][0] * a[2][1] - a[1][1] * a[2][0]) * d, (a[0][1] * a[2][0] - a[0][0] * a[2][1]) * d, (a[0][0] * a[1][1] - a[0][1] * a[1][0]) * d },
    };
}

// ── Lettura del profilo ──────────────────────────────────────────────────────

fn be16(d: []const u8, off: usize) ?u16 {
    if (off > d.len or d.len - off < 2) return null;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

fn be32(d: []const u8, off: usize) ?u32 {
    if (off > d.len or d.len - off < 4) return null;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

fn s15f16(d: []const u8, off: usize) ?f64 {
    const v = be32(d, off) orelse return null;
    return @as(f64, @floatFromInt(@as(i32, @bitCast(v)))) / 65536.0;
}

/// Curva di risposta (TRC) di un canale: valore del canale in [0, 1] → luce lineare.
const Curve = union(enum) {
    gamma: f64,
    /// Campioni u16 big-endian equispaziati su [0, 1].
    table: []const u8,
    /// parametricCurveType: funzione 0..4, parametri g a b c d e f.
    para: struct { func: u16, g: [7]f64 },

    fn parse(tag: []const u8) ?Curve {
        if (tag.len < 12) return null;
        if (std.mem.eql(u8, tag[0..4], "curv")) {
            const n = be32(tag, 8) orelse return null;
            if (n == 0) return .{ .gamma = 1 };
            if (n == 1) return .{ .gamma = @as(f64, @floatFromInt(be16(tag, 12) orelse return null)) / 256.0 };
            if (12 + @as(u64, n) * 2 > tag.len) return null;
            return .{ .table = tag[12 .. 12 + @as(usize, n) * 2] };
        }
        if (std.mem.eql(u8, tag[0..4], "para")) {
            const func = be16(tag, 8) orelse return null;
            const counts = [_]usize{ 1, 3, 4, 5, 7 };
            if (func >= counts.len) return null;
            var g: [7]f64 = @splat(0);
            for (0..counts[func]) |k| g[k] = s15f16(tag, 12 + 4 * k) orelse return null;
            if (func >= 1 and g[1] == 0) return null; // a = 0: soglia −b/a indefinita
            return .{ .para = .{ .func = func, .g = g } };
        }
        return null;
    }

    fn eval(c: Curve, x: f64) f64 {
        return switch (c) {
            .gamma => |g| std.math.pow(f64, x, g),
            .table => |t| blk: {
                const n = t.len / 2;
                const pos = x * @as(f64, @floatFromInt(n - 1));
                const i: usize = @min(@as(usize, @intFromFloat(@floor(pos))), n - 1);
                const j = @min(i + 1, n - 1);
                const f = pos - @as(f64, @floatFromInt(i));
                const a: f64 = @floatFromInt(std.mem.readInt(u16, t[i * 2 ..][0..2], .big));
                const b: f64 = @floatFromInt(std.mem.readInt(u16, t[j * 2 ..][0..2], .big));
                break :blk (a + (b - a) * f) / 65535.0;
            },
            .para => |p| blk: {
                const g = p.g;
                const y = switch (p.func) {
                    0 => std.math.pow(f64, x, g[0]),
                    1 => if (x >= -g[2] / g[1]) powPos(g[1] * x + g[2], g[0]) else 0,
                    2 => if (x >= -g[2] / g[1]) powPos(g[1] * x + g[2], g[0]) + g[3] else g[3],
                    3 => if (x >= g[4]) powPos(g[1] * x + g[2], g[0]) else g[3] * x,
                    else => if (x >= g[4]) powPos(g[1] * x + g[2], g[0]) + g[5] else g[3] * x + g[6],
                };
                break :blk std.math.clamp(y, 0, 1);
            },
        };
    }
};

fn powPos(base: f64, e: f64) f64 {
    return if (base <= 0) 0 else std.math.pow(f64, base, e);
}

/// Profilo RGB a matrice e curve: colori primari (colonne XYZ D50) e tre TRC.
const Profile = struct {
    colorants: [3][3]f64,
    curves: [3]Curve,

    fn parse(d: []const u8) ?Profile {
        if (d.len < 132) return null;
        const size = be32(d, 0) orelse return null;
        if (size < 132 or size > d.len) return null;
        const p = d[0..size];
        if (!std.mem.eql(u8, p[16..20], "RGB ") or !std.mem.eql(u8, p[20..24], "XYZ ")) return null;
        const n = be32(p, 128) orelse return null;
        if (n > 1024 or 132 + @as(usize, n) * 12 > p.len) return null;

        var out: Profile = undefined;
        const xyz_sigs = [_]*const [4]u8{ "rXYZ", "gXYZ", "bXYZ" };
        const trc_sigs = [_]*const [4]u8{ "rTRC", "gTRC", "bTRC" };
        for (0..3) |c| {
            const t = tag(p, n, xyz_sigs[c]) orelse return null;
            if (t.len < 20 or !std.mem.eql(u8, t[0..4], "XYZ ")) return null;
            for (0..3) |k| {
                const v = s15f16(t, 8 + 4 * k) orelse return null;
                // XYZ di un primario reale: fra 0 e ~1. Fuori da [−1, 2] il profilo
                // è rotto, e la matrice potrebbe far traboccare la somma di `apply`.
                if (!(v >= -1 and v <= 2)) return null;
                out.colorants[c][k] = v;
            }
            out.curves[c] = Curve.parse(tag(p, n, trc_sigs[c]) orelse return null) orelse return null;
        }
        return out;
    }

    fn tag(p: []const u8, n: u32, sig: *const [4]u8) ?[]const u8 {
        for (0..n) |i| {
            const e = 132 + i * 12;
            if (!std.mem.eql(u8, p[e..][0..4], sig)) continue;
            const off = be32(p, e + 4) orelse return null;
            const len = be32(p, e + 8) orelse return null;
            if (@as(u64, off) + len > p.len) return null;
            return p[off..][0..len];
        }
        return null;
    }

    /// Già sRGB (entro arrotondamenti dei profili sRGB comuni, che scartano meno
    /// di 2e-4 sui primari): convertire cambierebbe solo qualche byte per
    /// arrotondamento, e costerebbe tempo.
    fn isSrgb(p: Profile) bool {
        for (0..3) |c| for (0..3) |k| {
            if (@abs(p.colorants[c][k] - srgb_colorants[c][k]) > 0.001) return false;
        };
        for (p.curves) |curve| {
            for (0..256) |v| {
                const x = @as(f64, @floatFromInt(v)) / 255.0;
                // Nello spazio codificato: mezzo livello, cioè nessun byte diverso.
                if (@abs(linearToSrgb(curve.eval(x)) - x) > 0.5 / 255.0) return false;
            }
        }
        return true;
    }
};

// ── Estrazione dai contenitori ───────────────────────────────────────────────

/// Profilo incorporato: una fetta del file oppure (PNG compresso, JPEG in più
/// segmenti) memoria di `gpa` da liberare con `deinit`.
pub const Embedded = struct {
    data: []const u8,
    owned: bool,

    pub fn deinit(e: Embedded, gpa: std.mem.Allocator) void {
        if (e.owned) gpa.free(e.data);
    }
};

/// Tetto sulla dimensione di un profilo: quelli reali stanno sotto il mezzo MB.
const max_profile = 4 << 20;

/// Firma TIFF: la hanno anche molti RAW (DNG, NEF, CR2, ARW…), il cui profilo
/// nella IFD0 descrive l'anteprima, non i pixel che rende il decoder.
pub fn isTiff(bytes: []const u8) bool {
    return bytes.len >= 4 and (std.mem.eql(u8, bytes[0..4], "II*\x00") or std.mem.eql(u8, bytes[0..4], "MM\x00*"));
}

/// Profilo ICC incorporato in un JPEG, PNG, TIFF o WebP, o null (assente,
/// contenitore diverso, struttura non valida, memoria esaurita).
pub fn extract(gpa: std.mem.Allocator, bytes: []const u8) ?Embedded {
    if (bytes.len >= 4 and bytes[0] == 0xFF and bytes[1] == 0xD8) return fromJpeg(gpa, bytes);
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return fromPng(gpa, bytes);
    if (bytes.len >= 8 and isTiff(bytes)) return fromTiff(bytes);
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return fromWebp(bytes);
    return null;
}

/// Segmenti APP2 "ICC_PROFILE\0" + numero + totale: il profilo può essere
/// spezzato su più segmenti (64 KB ciascuno), da riunire in ordine.
fn fromJpeg(gpa: std.mem.Allocator, b: []const u8) ?Embedded {
    const sig = "ICC_PROFILE\x00";
    var parts: [256]?[]const u8 = @splat(null);
    var total: usize = 0;
    var pos: usize = 2;
    while (pos + 4 <= b.len) {
        if (b[pos] != 0xFF) return null;
        const marker = b[pos + 1];
        if (marker == 0xFF) { // riempimento
            pos += 1;
            continue;
        }
        if (marker == 0xD9 or marker == 0xDA) break; // fine immagine / inizio dei dati
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) {
            pos += 2;
            continue;
        }
        const len = be16(b, pos + 2) orelse return null;
        if (len < 2 or pos + 2 + len > b.len) return null;
        const seg = b[pos + 4 .. pos + 2 + len];
        if (marker == 0xE2 and seg.len > sig.len + 2 and std.mem.eql(u8, seg[0..sig.len], sig)) {
            const seq = seg[sig.len];
            const count = seg[sig.len + 1];
            if (seq == 0 or seq > count) return null;
            if (total != 0 and total != count) return null;
            total = count;
            parts[seq] = seg[sig.len + 2 ..];
        }
        pos += 2 + len;
    }
    if (total == 0) return null;
    if (total == 1) return .{ .data = parts[1].?, .owned = false };
    var size: usize = 0;
    for (1..total + 1) |k| size += (parts[k] orelse return null).len;
    if (size > max_profile) return null;
    const out = gpa.alloc(u8, size) catch return null;
    var o: usize = 0;
    for (1..total + 1) |k| {
        @memcpy(out[o..][0..parts[k].?.len], parts[k].?);
        o += parts[k].?.len;
    }
    return .{ .data = out, .owned = true };
}

/// Chunk iCCP: nome, 0, metodo di compressione (0 = zlib), dati zlib.
fn fromPng(gpa: std.mem.Allocator, b: []const u8) ?Embedded {
    var pos: usize = 8;
    while (pos + 12 <= b.len) {
        const len = be32(b, pos) orelse return null;
        const kind = b[pos + 4 .. pos + 8];
        if (@as(u64, pos) + 12 + len > b.len) return null;
        const data = b[pos + 8 .. pos + 8 + len];
        if (std.mem.eql(u8, kind, "IDAT") or std.mem.eql(u8, kind, "IEND")) return null;
        if (std.mem.eql(u8, kind, "iCCP")) {
            const nul = std.mem.indexOfScalar(u8, data[0..@min(data.len, 80)], 0) orelse return null;
            if (nul + 2 > data.len or data[nul + 1] != 0) return null;
            var in: std.Io.Reader = .fixed(data[nul + 2 ..]);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var d: std.compress.flate.Decompress = .init(&in, .zlib, &window);
            const out = d.reader.allocRemaining(gpa, .limited(max_profile)) catch return null;
            return .{ .data = out, .owned = true };
        }
        pos += 12 + @as(usize, len);
    }
    return null;
}

/// Tag 34675 (InterColorProfile) della prima IFD.
fn fromTiff(b: []const u8) ?Embedded {
    const endian: std.builtin.Endian = if (b[0] == 'I') .little else .big;
    // Offset a 64 bit: un IFD a 0xFFFFFFFF non deve traboccare su un target a 32 bit.
    const rd16 = struct {
        fn f(d: []const u8, off: u64, e: std.builtin.Endian) ?u16 {
            if (off > d.len or d.len - off < 2) return null;
            return std.mem.readInt(u16, d[@intCast(off)..][0..2], e);
        }
    }.f;
    const rd32 = struct {
        fn f(d: []const u8, off: u64, e: std.builtin.Endian) ?u32 {
            if (off > d.len or d.len - off < 4) return null;
            return std.mem.readInt(u32, d[@intCast(off)..][0..4], e);
        }
    }.f;
    const ifd = rd32(b, 4, endian) orelse return null;
    const n = rd16(b, ifd, endian) orelse return null;
    for (0..n) |i| {
        const e = @as(u64, ifd) + 2 + @as(u64, i) * 12;
        const tag_id = rd16(b, e, endian) orelse return null;
        if (tag_id != 34675) continue;
        const kind = rd16(b, e + 2, endian) orelse return null;
        if (kind != 1 and kind != 7) return null; // BYTE o UNDEFINED
        const count = rd32(b, e + 4, endian) orelse return null;
        if (count <= 4) return null; // un profilo non sta nei 4 byte del valore
        const off = rd32(b, e + 8, endian) orelse return null;
        if (@as(u64, off) + count > b.len) return null;
        return .{ .data = b[off..][0..count], .owned = false };
    }
    return null;
}

/// Chunk RIFF "ICCP" del WebP esteso (VP8X).
fn fromWebp(b: []const u8) ?Embedded {
    var pos: usize = 12;
    while (pos + 8 <= b.len) {
        const len = std.mem.readInt(u32, b[pos + 4 ..][0..4], .little);
        if (@as(u64, pos) + 8 + len > b.len) return null;
        if (std.mem.eql(u8, b[pos .. pos + 4], "ICCP")) return .{ .data = b[pos + 8 ..][0..len], .owned = false };
        pos += 8 + @as(usize, len) + (len & 1);
    }
    return null;
}

// ── Test ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Profilo RGB a matrice e curve minimale: colori primari `col` e gamma `gamma`
/// (curv con un solo valore), oppure la curva sRGB parametrica se `gamma` è 0.
fn makeProfile(gpa: std.mem.Allocator, col: [3][3]f64, gamma: f64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendNTimes(gpa, 0, 128);
    const tags = 6;
    try buf.appendNTimes(gpa, 0, 4 + tags * 12);
    std.mem.writeInt(u32, buf.items[128..][0..4], tags, .big);
    @memcpy(buf.items[12..16], "mntr");
    @memcpy(buf.items[16..20], "RGB ");
    @memcpy(buf.items[20..24], "XYZ ");
    @memcpy(buf.items[36..40], "acsp");
    const sigs = [_]*const [4]u8{ "rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC" };
    for (sigs, 0..) |sig, i| {
        const off = buf.items.len;
        if (i < 3) {
            try buf.appendSlice(gpa, "XYZ \x00\x00\x00\x00");
            for (0..3) |k| {
                var v: [4]u8 = undefined;
                std.mem.writeInt(i32, &v, @intFromFloat(@round(col[i][k] * 65536)), .big);
                try buf.appendSlice(gpa, &v);
            }
        } else if (gamma > 0) {
            try buf.appendSlice(gpa, "curv\x00\x00\x00\x00\x00\x00\x00\x01");
            var v: [2]u8 = undefined;
            std.mem.writeInt(u16, &v, @intFromFloat(@round(gamma * 256)), .big);
            try buf.appendSlice(gpa, &v);
            try buf.appendSlice(gpa, "\x00\x00");
        } else {
            try buf.appendSlice(gpa, "para\x00\x00\x00\x00\x00\x03\x00\x00");
            for ([_]f64{ 2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045 }) |g| {
                var v: [4]u8 = undefined;
                std.mem.writeInt(i32, &v, @intFromFloat(@round(g * 65536)), .big);
                try buf.appendSlice(gpa, &v);
            }
        }
        const e = 132 + i * 12;
        @memcpy(buf.items[e..][0..4], sig);
        std.mem.writeInt(u32, buf.items[e + 4 ..][0..4], @intCast(off), .big);
        std.mem.writeInt(u32, buf.items[e + 8 ..][0..4], @intCast(buf.items.len - off), .big);
    }
    std.mem.writeInt(u32, buf.items[0..4], @intCast(buf.items.len), .big);
    return buf.toOwnedSlice(gpa);
}

const prophoto = [3][3]f64{ .{ 0.79767, 0.28804, 0.0 }, .{ 0.13519, 0.71188, 0.0 }, .{ 0.03134, 0.00009, 0.82491 } };

test "profilo sRGB: niente da convertire" {
    const p = try makeProfile(testing.allocator, srgb_colorants, 0);
    defer testing.allocator.free(p);
    var t: Transform = undefined;
    try testing.expect(!init(&t, p));
}

test "ProPhoto (gamma 1,8): grigi sulla curva sRGB, bianco e nero fermi" {
    const p = try makeProfile(testing.allocator, prophoto, 1.8);
    defer testing.allocator.free(p);
    const t = try testing.allocator.create(Transform);
    defer testing.allocator.destroy(t);
    try testing.expect(init(t, p));
    var px = [_]u8{ 0, 0, 0, 255, 255, 255, 128, 128, 128, 30, 30, 30 };
    t.apply(&px);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 255 }, px[0..6]);
    // Un grigio resta grigio e cade dove dice la curva: (v/255)^1,8 → sRGB.
    for ([_]u8{ 128, 30 }, 0..) |v, k| {
        const lin = std.math.pow(f64, @as(f64, @floatFromInt(v)) / 255.0, 1.8008); // gamma u8Fixed8
        const want: i32 = @intFromFloat(@round(linearToSrgb(lin) * 255));
        for (0..3) |c| try testing.expect(@abs(@as(i32, px[6 + k * 3 + c]) - want) <= 1);
    }
    // Il rosso ProPhoto puro è fuori gamma sRGB: si taglia a un rosso saturo.
    var red = [_]u8{ 255, 0, 0 };
    t.apply(&red);
    try testing.expectEqual(@as(u8, 255), red[0]);
    try testing.expect(red[1] == 0 and red[2] == 0);
}

test "profili non gestiti: niente conversione, niente panic" {
    var t: Transform = undefined;
    try testing.expect(!init(&t, ""));
    try testing.expect(!init(&t, &@as([200]u8, @splat(0xff))));
    const p = try makeProfile(testing.allocator, prophoto, 1.8);
    defer testing.allocator.free(p);
    // Tronchi a ogni lunghezza (la dimensione dichiarata supera i dati).
    for (0..p.len) |n| try testing.expect(!init(&t, p[0..n]));
    // Primari assurdi (s15Fixed16 al massimo): rifiutati prima della matrice.
    const huge = try testing.allocator.dupe(u8, p);
    defer testing.allocator.free(huge);
    const rxyz = Profile.tag(huge, 6, "rXYZ").?;
    const off = @intFromPtr(rxyz.ptr) - @intFromPtr(huge.ptr);
    std.mem.writeInt(u32, huge[off + 8 ..][0..4], 0x7fffffff, .big);
    try testing.expect(!init(&t, huge));
    // CMYK invece di RGB.
    const cmyk = try testing.allocator.dupe(u8, p);
    defer testing.allocator.free(cmyk);
    @memcpy(cmyk[16..20], "CMYK");
    try testing.expect(!init(&t, cmyk));
}

test "curve: tabella e parametriche" {
    // Tabella di 3 campioni: 0, metà, pieno → lineare.
    const tbl = "curv\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x7f\xff\xff\xff";
    const c = Curve.parse(tbl).?;
    try testing.expectApproxEqAbs(@as(f64, 0.25), c.eval(0.25), 1e-4);
    // para tipo 3 = curva sRGB.
    const p = try makeProfile(testing.allocator, srgb_colorants, 0);
    defer testing.allocator.free(p);
    const prof = Profile.parse(p).?;
    for ([_]f64{ 0, 0.02, 0.04045, 0.2, 0.5, 1 }) |x| try testing.expectApproxEqAbs(srgbToLinear(x), prof.curves[0].eval(x), 1e-4);
}

test "estrazione: TIFF, JPEG a più segmenti, PNG compresso, WebP" {
    const gpa = testing.allocator;
    const prof = "profilo-di-prova-0123456789";
    // TIFF little-endian: IFD a 8 con una voce 34675 che punta al profilo.
    {
        var t: [8 + 2 + 12 + 4 + prof.len]u8 = undefined;
        @memcpy(t[0..4], "II*\x00");
        std.mem.writeInt(u32, t[4..8], 8, .little);
        std.mem.writeInt(u16, t[8..10], 1, .little);
        std.mem.writeInt(u16, t[10..12], 34675, .little);
        std.mem.writeInt(u16, t[12..14], 7, .little);
        std.mem.writeInt(u32, t[14..18], prof.len, .little);
        std.mem.writeInt(u32, t[18..22], 26, .little);
        @memset(t[22..26], 0);
        @memcpy(t[26..], prof);
        const e = extract(gpa, &t).?;
        defer e.deinit(gpa);
        try testing.expectEqualStrings(prof, e.data);
    }
    // JPEG: due segmenti APP2 in ordine inverso, poi SOS.
    {
        var j: std.ArrayList(u8) = .empty;
        defer j.deinit(gpa);
        try j.appendSlice(gpa, "\xff\xd8");
        const halves = [_][]const u8{ prof[13..], prof[0..13] };
        for (halves, [_]u8{ 2, 1 }) |h, seq| {
            try j.appendSlice(gpa, "\xff\xe2");
            var l: [2]u8 = undefined;
            std.mem.writeInt(u16, &l, @intCast(2 + 12 + 2 + h.len), .big);
            try j.appendSlice(gpa, &l);
            try j.appendSlice(gpa, "ICC_PROFILE\x00");
            try j.appendSlice(gpa, &.{ seq, 2 });
            try j.appendSlice(gpa, h);
        }
        try j.appendSlice(gpa, "\xff\xda\x00\x02");
        const e = extract(gpa, j.items).?;
        defer e.deinit(gpa);
        try testing.expectEqualStrings(prof, e.data);
    }
    // PNG: IHDR finto, iCCP con il profilo compresso zlib, IDAT.
    {
        var z = try std.Io.Writer.Allocating.initCapacity(gpa, 64);
        defer z.deinit();
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var comp = try std.compress.flate.Compress.init(&z.writer, window, .zlib, .level_1);
        try comp.writer.writeAll(prof);
        try comp.finish();
        var png: std.ArrayList(u8) = .empty;
        defer png.deinit(gpa);
        try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
        const chunks = [_]struct { k: []const u8, d: []const u8 }{
            .{ .k = "IHDR", .d = &@as([13]u8, @splat(0)) },
            .{ .k = "iCCP", .d = "" },
            .{ .k = "IDAT", .d = "x" },
        };
        for (chunks) |ch| {
            var data: std.ArrayList(u8) = .empty;
            defer data.deinit(gpa);
            if (std.mem.eql(u8, ch.k, "iCCP")) {
                try data.appendSlice(gpa, "ICC\x00\x00");
                try data.appendSlice(gpa, z.written());
            } else try data.appendSlice(gpa, ch.d);
            var l: [4]u8 = undefined;
            std.mem.writeInt(u32, &l, @intCast(data.items.len), .big);
            try png.appendSlice(gpa, &l);
            try png.appendSlice(gpa, ch.k);
            try png.appendSlice(gpa, data.items);
            try png.appendSlice(gpa, "\x00\x00\x00\x00"); // CRC non controllato
        }
        const e = extract(gpa, png.items).?;
        defer e.deinit(gpa);
        try testing.expectEqualStrings(prof, e.data);
    }
    // WebP esteso: VP8X poi ICCP (lunghezza dispari: c'è il byte di riempimento).
    {
        var w: std.ArrayList(u8) = .empty;
        defer w.deinit(gpa);
        try w.appendSlice(gpa, "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00");
        try w.appendNTimes(gpa, 0, 10);
        try w.appendSlice(gpa, "ICCP");
        var l: [4]u8 = undefined;
        std.mem.writeInt(u32, &l, prof.len, .little);
        try w.appendSlice(gpa, &l);
        try w.appendSlice(gpa, prof);
        const e = extract(gpa, w.items).?;
        defer e.deinit(gpa);
        try testing.expectEqualStrings(prof, e.data);
    }
    // Contenitori senza profilo o rotti: null, mai un panic.
    try testing.expect(extract(gpa, "\xff\xd8\xff\xda") == null);
    try testing.expect(extract(gpa, "GIF89a") == null);
    try testing.expect(extract(gpa, "II*\x00\xff\xff\xff\xff") == null);
    try testing.expect(extract(gpa, "\xff\xd8\xff\xe2\xff\xff") == null);
}

test "file troncati o corrotti: niente panic" {
    const gpa = testing.allocator;
    const prof = try makeProfile(gpa, prophoto, 1.8);
    defer gpa.free(prof);
    // Contenitori veri con dentro un profilo vero: JPEG (un segmento), TIFF, PNG, WebP.
    var jpg: std.ArrayList(u8) = .empty;
    defer jpg.deinit(gpa);
    try jpg.appendSlice(gpa, "\xff\xd8\xff\xe2");
    var l: [2]u8 = undefined;
    std.mem.writeInt(u16, &l, @intCast(2 + 14 + prof.len), .big);
    try jpg.appendSlice(gpa, &l);
    try jpg.appendSlice(gpa, "ICC_PROFILE\x00\x01\x01");
    try jpg.appendSlice(gpa, prof);
    try jpg.appendSlice(gpa, "\xff\xda\x00\x02");
    var tif: std.ArrayList(u8) = .empty;
    defer tif.deinit(gpa);
    try tif.appendSlice(gpa, "MM\x00*\x00\x00\x00\x08\x00\x01\x87\x73\x00\x07");
    var c4: [4]u8 = undefined;
    std.mem.writeInt(u32, &c4, @intCast(prof.len), .big);
    try tif.appendSlice(gpa, &c4);
    try tif.appendSlice(gpa, "\x00\x00\x00\x1a\x00\x00\x00\x00");
    try tif.appendSlice(gpa, prof);

    // PNG: iCCP col profilo compresso zlib (passa dall'inflate di std).
    var z = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
    defer z.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var comp = try std.compress.flate.Compress.init(&z.writer, window, .zlib, .level_1);
    try comp.writer.writeAll(prof);
    try comp.finish();
    var png: std.ArrayList(u8) = .empty;
    defer png.deinit(gpa);
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, &c4, @intCast(5 + z.written().len), .big);
    try png.appendSlice(gpa, &c4);
    try png.appendSlice(gpa, "iCCPICC\x00\x00");
    try png.appendSlice(gpa, z.written());
    try png.appendSlice(gpa, "\x00\x00\x00\x00\x00\x00\x00\x00IDAT\x00\x00\x00\x00");
    // WebP esteso: VP8X poi ICCP.
    var webp: std.ArrayList(u8) = .empty;
    defer webp.deinit(gpa);
    try webp.appendSlice(gpa, "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00");
    try webp.appendNTimes(gpa, 0, 10);
    try webp.appendSlice(gpa, "ICCP");
    std.mem.writeInt(u32, &c4, @intCast(prof.len), .little);
    try webp.appendSlice(gpa, &c4);
    try webp.appendSlice(gpa, prof);

    const t = try gpa.create(Transform);
    defer gpa.destroy(t);
    var px = [_]u8{ 10, 200, 30 };
    for ([_][]const u8{ jpg.items, tif.items, png.items, webp.items }) |file| {
        // Integro: il profilo si estrae e si converte.
        const e = extract(gpa, file).?;
        try testing.expect(init(t, e.data));
        e.deinit(gpa);
        // Ogni troncamento.
        for (0..file.len) |n| if (extract(gpa, file[0..n])) |x| {
            if (init(t, x.data)) t.apply(&px);
            x.deinit(gpa);
        };
        // Byte a caso in posizioni a caso.
        const buf = try gpa.dupe(u8, file);
        defer gpa.free(buf);
        var prng = std.Random.DefaultPrng.init(0x1cc);
        const rnd = prng.random();
        for (0..3000) |_| {
            @memcpy(buf, file);
            for (0..rnd.intRangeAtMost(usize, 1, 4)) |_| buf[rnd.uintLessThan(usize, buf.len)] = rnd.int(u8);
            if (extract(gpa, buf)) |x| {
                if (init(t, x.data)) t.apply(&px);
                x.deinit(gpa);
            }
        }
    }
}
