//! Cache su disco della MESH COARSE già decodificata: geometria (vertici/facce/
//! normali/uv/tangenti) + submesh + texture sotto-campionate a 256². Serve a
//! rendere la RIAPERTURA/ritorno di un modello quasi istantaneo: la fase coarse
//! non ridecodifica nulla (niente parse glTF, niente build geometria, niente
//! lettura del file da decine di MB) — legge il blob e ricostruisce la MeshData.
//! Scritta come effetto collaterale del decode full; letta da `decodeCoarse`.
//!
//! Chiave = hash(path); validità = mtime (nel header). Formato nativo (cache
//! locale, si rigenera se il magic cambia). Solo Linux (syscall POSIX). La
//! deserializzazione alloca con `gpa`: la MeshData risultante si libera con il
//! suo `deinit` come una decodificata normale.

const std = @import("std");
const builtin = @import("builtin");
const decoder = @import("decoder.zig");
const MeshData = decoder.MeshData;
const SubMesh = decoder.SubMesh;

const enabled = builtin.os.tag == .linux;

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;
const SEEK_END: c_int = 2;

const magic = "ZMESHC02";
const coarse_dim: usize = 256;

var tmp_seq: std.atomic.Value(u64) = .init(0);

// --- Serializzazione sequenziale (layout nativo) --------------------------

const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn scalar(self: *Writer, comptime T: type, v: T) !void {
        try self.buf.appendSlice(self.gpa, std.mem.asBytes(&v));
    }
    fn bytes(self: *Writer, b: []const u8) !void {
        try self.scalar(u64, @intCast(b.len));
        try self.buf.appendSlice(self.gpa, b);
    }
    /// Slice di elementi POD scritto come byte grezzi (con conteggio elementi).
    fn slice(self: *Writer, comptime T: type, s: []const T) !void {
        try self.scalar(u64, @intCast(s.len));
        try self.buf.appendSlice(self.gpa, std.mem.sliceAsBytes(s));
    }
};

const Cursor = struct {
    data: []const u8,
    off: usize = 0,

    fn scalar(self: *Cursor, comptime T: type) !T {
        if (self.off + @sizeOf(T) > self.data.len) return error.Truncated;
        var v: T = undefined;
        @memcpy(std.mem.asBytes(&v), self.data[self.off .. self.off + @sizeOf(T)]);
        self.off += @sizeOf(T);
        return v;
    }
    fn bytes(self: *Cursor, gpa: std.mem.Allocator) ![]u8 {
        const n = try self.scalar(u64);
        if (self.off + n > self.data.len) return error.Truncated;
        const out = try gpa.alloc(u8, n);
        @memcpy(out, self.data[self.off .. self.off + n]);
        self.off += n;
        return out;
    }
    /// Alloca e legge uno slice di `T` (conteggio elementi + byte grezzi).
    fn slice(self: *Cursor, comptime T: type, gpa: std.mem.Allocator) ![]T {
        const n = try self.scalar(u64);
        const nbytes = n * @sizeOf(T);
        if (self.off + nbytes > self.data.len) return error.Truncated;
        const out = try gpa.alloc(T, n);
        @memcpy(std.mem.sliceAsBytes(out), self.data[self.off .. self.off + nbytes]);
        self.off += nbytes;
        return out;
    }
};

/// Box-filter di `src` (RGBA) a lato max `max_dim`. Ritorna un nuovo buffer
/// (gpa) e le nuove dimensioni; null se input vuoto/incoerente.
fn downscale(gpa: std.mem.Allocator, src: []const u8, w: usize, h: usize, max_dim: usize, out_w: *usize, out_h: *usize) ?[]u8 {
    if (w == 0 or h == 0 or src.len != w * h * 4) return null;
    const longest = @max(w, h);
    if (longest <= max_dim) {
        // Già piccola: copia diretta.
        const cp = gpa.alloc(u8, src.len) catch return null;
        @memcpy(cp, src);
        out_w.* = w;
        out_h.* = h;
        return cp;
    }
    const scale = @as(f64, @floatFromInt(max_dim)) / @as(f64, @floatFromInt(longest));
    const dw = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale))));
    const dh = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * scale))));
    const dst = gpa.alloc(u8, dw * dh * 4) catch return null;
    // Media a box del blocco sorgente che mappa su ogni texel di destinazione.
    for (0..dh) |dy| {
        const sy0 = dy * h / dh;
        const sy1 = @max(sy0 + 1, (dy + 1) * h / dh);
        for (0..dw) |dx| {
            const sx0 = dx * w / dw;
            const sx1 = @max(sx0 + 1, (dx + 1) * w / dw);
            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            var cnt: u32 = 0;
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const p = (sy * w + sx) * 4;
                    inline for (0..4) |c| acc[c] += src[p + c];
                    cnt += 1;
                }
            }
            const dp = (dy * dw + dx) * 4;
            inline for (0..4) |c| dst[dp + c] = @intCast(acc[c] / @max(1, cnt));
        }
    }
    out_w.* = dw;
    out_h.* = dh;
    return dst;
}

/// Scrive un blob texture downscalato a 256²: dims + pixel. Vuoto → dims 0.
fn writeTex(w: *Writer, gpa: std.mem.Allocator, px: []const u8, tw: usize, th: usize) !void {
    if (px.len == 0 or tw == 0 or th == 0) {
        try w.scalar(u64, 0);
        try w.scalar(u64, 0);
        try w.bytes(&.{});
        return;
    }
    var cw: usize = 0;
    var ch: usize = 0;
    if (downscale(gpa, px, tw, th, coarse_dim, &cw, &ch)) |small| {
        defer gpa.free(small);
        try w.scalar(u64, @intCast(cw));
        try w.scalar(u64, @intCast(ch));
        try w.bytes(small);
    } else {
        try w.scalar(u64, 0);
        try w.scalar(u64, 0);
        try w.bytes(&.{});
    }
}

fn readTex(c: *Cursor, gpa: std.mem.Allocator, tw: *usize, th: *usize) ![]u8 {
    tw.* = @intCast(try c.scalar(u64));
    th.* = @intCast(try c.scalar(u64));
    return try c.bytes(gpa);
}

// --- I/O su disco ----------------------------------------------------------

fn cacheDir(gpa: std.mem.Allocator) ?[]u8 {
    const home_c = getenv("HOME") orelse return null;
    const home = std.mem.span(home_c);
    inline for (.{ "/.cache", "/.cache/zuer", "/.cache/zuer/mesh" }) |suffix| {
        const p = std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ home, suffix }, 0) catch return null;
        defer gpa.free(p);
        _ = mkdir(p.ptr, 0o755);
    }
    return std.fmt.allocPrint(gpa, "{s}/.cache/zuer/mesh", .{home}) catch null;
}

fn keyPath(gpa: std.mem.Allocator, dir: []const u8, path: []const u8) ?[:0]u8 {
    const key = std.hash.Wyhash.hash(0x51ed7ea5e5eedbee, path);
    return std.fmt.allocPrintSentinel(gpa, "{s}/{x}.mgeo", .{ dir, key }, 0) catch null;
}

fn readAll(fd: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = read(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn writeAll(fd: c_int, buf: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = write(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// True se il file cache esiste già con magic valido e mtime combaciante (letto
/// solo l'header, non l'intero blob).
fn existsFresh(kp: [*:0]const u8, mtime_ns: i128) bool {
    const fd = open(kp, O_RDONLY, 0);
    if (fd < 0) return false;
    defer _ = close(fd);
    var hdr: [magic.len + @sizeOf(i128)]u8 = undefined;
    if (!readAll(fd, &hdr)) return false;
    if (!std.mem.eql(u8, hdr[0..magic.len], magic)) return false;
    var mt: i128 = undefined;
    @memcpy(std.mem.asBytes(&mt), hdr[magic.len..][0..@sizeOf(i128)]);
    return mt == mtime_ns;
}

// --- API pubblica ----------------------------------------------------------

/// Scrive la mesh coarse (texture a 256²) su disco. Best-effort: ogni errore è
/// silenzioso. Chiamata dopo un decode full riuscito.
pub fn writeCoarse(gpa: std.mem.Allocator, path: []const u8, mtime_ns: i128, mesh: *const MeshData) void {
    if (!enabled) return;
    const dir = cacheDir(gpa) orelse return;
    defer gpa.free(dir);
    const kp = keyPath(gpa, dir, path) orelse return;
    defer gpa.free(kp);

    // Già presente e aggiornata (stesso mtime)? evita di ri-downscalare le texture
    // e ri-serializzare i ~20MB ad ogni sharpen (la 2ª fase di ogni apertura fa un
    // decode full). Si scrive solo la prima volta per un dato file.
    if (existsFresh(kp, mtime_ns)) return;

    var w = Writer{ .gpa = gpa };
    defer w.buf.deinit(gpa);
    serialize(&w, gpa, mtime_ns, mesh) catch return;

    const seq = tmp_seq.fetchAdd(1, .monotonic);
    const tmp = std.fmt.allocPrintSentinel(gpa, "{s}.tmp{d}", .{ kp, seq }, 0) catch return;
    defer gpa.free(tmp);
    const fd = open(tmp.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
    if (fd < 0) return;
    const ok = writeAll(fd, w.buf.items);
    _ = close(fd);
    if (ok) _ = rename(tmp.ptr, kp.ptr);
}

/// Legge la mesh coarse se presente e con mtime combaciante. null altrimenti.
pub fn readCoarse(gpa: std.mem.Allocator, path: []const u8, mtime_ns: i128) ?MeshData {
    if (!enabled) return null;
    const dir = cacheDir(gpa) orelse return null;
    defer gpa.free(dir);
    const kp = keyPath(gpa, dir, path) orelse return null;
    defer gpa.free(kp);

    const fd = open(kp.ptr, O_RDONLY, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    const size = lseek(fd, 0, SEEK_END);
    if (size <= 0 or size > 512 * 1024 * 1024) return null;
    if (lseek(fd, 0, 0) < 0) return null;
    const buf = gpa.alloc(u8, @intCast(size)) catch return null;
    defer gpa.free(buf);
    if (!readAll(fd, buf)) return null;

    var c = Cursor{ .data = buf };
    return deserialize(&c, gpa, mtime_ns) catch null;
}

fn serialize(w: *Writer, gpa: std.mem.Allocator, mtime_ns: i128, m: *const MeshData) !void {
    try w.buf.appendSlice(gpa, magic);
    try w.scalar(i128, mtime_ns);
    try w.scalar(u64, @intCast(m.num_vertices));
    try w.scalar(u64, @intCast(m.num_faces));
    try w.scalar(u64, @intCast(m.num_normals));
    try w.scalar([3]f32, m.bbox_min);
    try w.scalar([3]f32, m.bbox_max);
    try w.scalar([3]f32, m.center);
    try w.scalar([4]f32, m.base_color);
    try w.scalar(f32, m.metallic);
    try w.scalar(f32, m.roughness);
    try w.bytes(m.name);
    try w.slice([3]f32, m.vertices);
    try w.slice(decoder.Face, m.faces);
    try w.slice([3]f32, m.normals);
    try w.slice([2]f32, m.uvs);
    try w.slice([4]f32, m.tangents);
    try writeTex(w, gpa, m.tex_pixels, m.tex_width, m.tex_height);
    try w.scalar(u64, @intCast(m.submeshes.len));
    for (m.submeshes) |s| {
        try w.scalar(u64, @intCast(s.first_index));
        try w.scalar(u64, @intCast(s.index_count));
        try w.scalar([4]f32, s.base_color);
        try w.scalar(f32, s.metallic);
        try w.scalar(f32, s.roughness);
        try writeTex(w, gpa, s.tex_pixels, s.tex_width, s.tex_height);
        // Normal map OMESSA nel tier coarse: è un'anteprima sfocata e il normal
        // mapping riappare con lo sharpen full. Risparmia downscale e disco.
        try writeTex(w, gpa, &.{}, 0, 0);
    }
}

fn deserialize(c: *Cursor, gpa: std.mem.Allocator, expect_mtime: i128) !MeshData {
    if (c.data.len < magic.len or !std.mem.eql(u8, c.data[0..magic.len], magic)) return error.BadMagic;
    c.off = magic.len;
    const mtime = try c.scalar(i128);
    if (mtime != expect_mtime) return error.Stale;

    var m: MeshData = .{
        .num_vertices = @intCast(try c.scalar(u64)),
        .num_faces = @intCast(try c.scalar(u64)),
        .num_normals = @intCast(try c.scalar(u64)),
        .bbox_min = try c.scalar([3]f32),
        .bbox_max = try c.scalar([3]f32),
        .center = try c.scalar([3]f32),
        .base_color = try c.scalar([4]f32),
        .metallic = try c.scalar(f32),
        .roughness = try c.scalar(f32),
        // Slice vuote (non undefined): se una lettura fallisce a metà, l'errdefer
        // sotto le libera come no-op invece di liberare puntatori spazzatura.
        .name = &.{},
        .vertices = &.{},
        .faces = &.{},
    };
    // Ownership incrementale: se una lettura fallisce, libera quanto già allocato.
    errdefer m.deinit(gpa);
    m.name = try c.bytes(gpa);
    m.vertices = try c.slice([3]f32, gpa);
    m.faces = try c.slice(decoder.Face, gpa);
    m.normals = try c.slice([3]f32, gpa);
    m.uvs = try c.slice([2]f32, gpa);
    m.tangents = try c.slice([4]f32, gpa);
    m.tex_pixels = try readTex(c, gpa, &m.tex_width, &m.tex_height);

    const nsub: usize = @intCast(try c.scalar(u64));
    if (nsub > 0) {
        const subs = try gpa.alloc(SubMesh, nsub);
        // Inizializza a vuoto così un errore a metà lascia deinit coerente.
        for (subs) |*s| s.* = .{ .first_index = 0, .index_count = 0 };
        m.submeshes = subs;
        for (subs) |*s| {
            s.first_index = @intCast(try c.scalar(u64));
            s.index_count = @intCast(try c.scalar(u64));
            s.base_color = try c.scalar([4]f32);
            s.metallic = try c.scalar(f32);
            s.roughness = try c.scalar(f32);
            s.tex_pixels = try readTex(c, gpa, &s.tex_width, &s.tex_height);
            s.nrm_tex_pixels = try readTex(c, gpa, &s.nrm_tex_width, &s.nrm_tex_height);
        }
    }
    return m;
}
