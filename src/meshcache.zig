//! Cache su disco della MESH COARSE già decodificata: geometria (vertici/facce/
//! normali/uv/tangenti) + submesh + texture sotto-campionate a 256². Serve a
//! rendere la RIAPERTURA/ritorno di un modello quasi istantaneo: la fase coarse
//! non ridecodifica nulla (niente parse glTF, niente build geometria, niente
//! lettura del file da decine di MB) — legge il blob e ricostruisce la MeshData.
//! Scritta come effetto collaterale del decode full; letta da `decodeCoarse`.
//!
//! Chiave = hash(realpath); validità = mtime + dimensione del sorgente +
//! checksum del payload (nell'header). Formato nativo (cache locale, si
//! rigenera se il magic cambia). Solo Linux (syscall POSIX). La
//! deserializzazione alloca con `gpa`: la MeshData risultante si libera con il
//! suo `deinit` come una decodificata normale.

const std = @import("std");
const builtin = @import("builtin");
const decoder = @import("decoder.zig");
// Copia host dell'helper di manutenzione cache (la gemella in src/decoders/
// serve texcache nel plugin glb: un file unico apparterrebbe a due moduli).
const evict = @import("cache_evict.zig");
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
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;
const SEEK_END: c_int = 2;

// ZMESHC04: header con checksum Wyhash del payload dopo mtime+dimensione —
// un blob troncato/corrotto con header valido viene scartato in deserialize
// invece di affidarsi alla sola validazione strutturale. Il bump invalida
// pulitamente le cache scritte col formato precedente (ZMESHC03: senza hash).
const magic = "ZMESHC04";
const coarse_dim: usize = 256;

// Layout header: magic | mtime i128 | src_size u64 | payload_hash u64.
// L'hash copre tutto ciò che segue l'header (il payload serializzato).
const hash_off: usize = magic.len + @sizeOf(i128) + @sizeOf(u64);
const header_len: usize = hash_off + @sizeOf(u64);
const hash_seed: u64 = 0x6d657368636b3034; // "meshck04"

/// Cap LRU della directory `~/.cache/zuer/mesh`: la geometria è serializzata a
/// piena risoluzione (centinaia di MB possibili per modello), quindi oltre
/// questa soglia l'eviction post-scrittura cancella i file con mtime più vecchio.
const evict_cap_bytes: u64 = 1024 * 1024 * 1024; // 1 GiB

var tmp_seq: std.atomic.Value(u64) = .init(0);

/// Sweep dei tmp orfani fatto al più una volta per processo (alla prima scrittura).
var tmp_sweep_done: std.atomic.Value(bool) = .init(false);

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
        // Conteggi letti dal file (u64 ostili): aritmetica controllata, così un
        // blob di cache corrotto produce Truncated (→ fallback al decode full)
        // e mai un overflow/panic.
        const n = std.math.cast(usize, try self.scalar(u64)) orelse return error.Truncated;
        const end = std.math.add(usize, self.off, n) catch return error.Truncated;
        if (end > self.data.len) return error.Truncated;
        const out = try gpa.alloc(u8, n);
        @memcpy(out, self.data[self.off..end]);
        self.off = end;
        return out;
    }
    /// Alloca e legge uno slice di `T` (conteggio elementi + byte grezzi).
    fn slice(self: *Cursor, comptime T: type, gpa: std.mem.Allocator) ![]T {
        const n = std.math.cast(usize, try self.scalar(u64)) orelse return error.Truncated;
        const nbytes = std.math.mul(usize, n, @sizeOf(T)) catch return error.Truncated;
        const end = std.math.add(usize, self.off, nbytes) catch return error.Truncated;
        if (end > self.data.len) return error.Truncated;
        const out = try gpa.alloc(T, n);
        @memcpy(std.mem.sliceAsBytes(out), self.data[self.off..end]);
        self.off = end;
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

const CoarseTex = struct { px: []u8, w: usize, h: usize };
const TexMemo = std.AutoHashMapUnmanaged(usize, CoarseTex);

/// Come `writeTex` ma memoizzato per puntatore sorgente: i submesh possono
/// condividere lo stesso atlas (dedup del decoder glTF) e il box-filter dei
/// ~16 MB non va ripetuto N volte. Il memo possiede i downscale (liberati dal
/// chiamante a fine serialize).
fn writeTexMemo(w: *Writer, gpa: std.mem.Allocator, memo: *TexMemo, px: []const u8, tw: usize, th: usize) !void {
    if (px.len == 0 or tw == 0 or th == 0) return writeTex(w, gpa, px, tw, th);
    const key = @intFromPtr(px.ptr);
    if (memo.get(key)) |c| {
        try w.scalar(u64, @intCast(c.w));
        try w.scalar(u64, @intCast(c.h));
        try w.bytes(c.px);
        return;
    }
    var cw: usize = 0;
    var ch: usize = 0;
    if (downscale(gpa, px, tw, th, coarse_dim, &cw, &ch)) |small| {
        var keep = false;
        defer if (!keep) gpa.free(small);
        try w.scalar(u64, @intCast(cw));
        try w.scalar(u64, @intCast(ch));
        try w.bytes(small);
        memo.put(gpa, key, .{ .px = small, .w = cw, .h = ch }) catch return; // niente memo: solo meno riuso
        keep = true;
    } else {
        try w.scalar(u64, 0);
        try w.scalar(u64, 0);
        try w.bytes(&.{});
    }
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
    const w = std.math.cast(usize, try c.scalar(u64)) orelse return error.Truncated;
    const h = std.math.cast(usize, try c.scalar(u64)) orelse return error.Truncated;
    const px = try c.bytes(gpa);
    errdefer gpa.free(px);
    // Coerenza dims↔pixel: una texture di lunghezza sbagliata (blob corrotto)
    // non deve raggiungere il renderer.
    const wh = std.math.mul(usize, w, h) catch return error.Truncated;
    const expected = std.math.mul(usize, wh, 4) catch return error.Truncated;
    if (px.len != expected) return error.Truncated;
    tw.* = w;
    th.* = h;
    return px;
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

/// Canonicalizza `path` con realpath(3): `zuer model.glb` aperto da directory
/// diverse deve produrre la STESSA chiave cache (il path as-given "model.glb"
/// collideva tra file diversi). Fallback al path così com'è se la risoluzione
/// fallisce (file sparito, path troppo lungo…). Il chiamante libera.
fn canonPath(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pz = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(pz);
    var buf: [4096]u8 = undefined; // PATH_MAX
    if (realpath(pz.ptr, &buf)) |res|
        return gpa.dupe(u8, std.mem.span(res)) catch null;
    return gpa.dupe(u8, path) catch null;
}

fn keyPath(gpa: std.mem.Allocator, dir: []const u8, path: []const u8) ?[:0]u8 {
    const canon = canonPath(gpa, path) orelse return null;
    defer gpa.free(canon);
    const key = std.hash.Wyhash.hash(0x51ed7ea5e5eedbee, canon);
    return std.fmt.allocPrintSentinel(gpa, "{s}/{x}.mgeo", .{ dir, key }, 0) catch null;
}

/// Dimensione in byte del file sorgente (per la validazione della cache accanto
/// al mtime: due file diversi con lo stesso mtime — zip estratti, `cp -p` — non
/// devono più collidere). null se il file non è apribile/misurabile.
fn srcSize(gpa: std.mem.Allocator, path: []const u8) ?u64 {
    const pz = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(pz);
    const fd = open(pz.ptr, O_RDONLY, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    const sz = lseek(fd, 0, SEEK_END);
    if (sz < 0) return null;
    return @intCast(sz);
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

/// True se il file cache esiste già con magic valido e mtime+dimensione
/// combacianti (letto solo l'header, non l'intero blob).
fn existsFresh(kp: [*:0]const u8, mtime_ns: i128, src_size: u64) bool {
    const fd = open(kp, O_RDONLY, 0);
    if (fd < 0) return false;
    defer _ = close(fd);
    var hdr: [magic.len + @sizeOf(i128) + @sizeOf(u64)]u8 = undefined;
    if (!readAll(fd, &hdr)) return false;
    if (!std.mem.eql(u8, hdr[0..magic.len], magic)) return false;
    var mt: i128 = undefined;
    @memcpy(std.mem.asBytes(&mt), hdr[magic.len..][0..@sizeOf(i128)]);
    var sz: u64 = undefined;
    @memcpy(std.mem.asBytes(&sz), hdr[magic.len + @sizeOf(i128) ..][0..@sizeOf(u64)]);
    return mt == mtime_ns and sz == src_size;
}

// --- API pubblica ----------------------------------------------------------

/// Scrive la mesh coarse (texture a 256²) su disco. Best-effort: ogni errore è
/// silenzioso. Chiamata dopo un decode full riuscito. La serializzazione (che
/// legge `mesh`, di proprietà del chiamante) avviene qui in modo sincrono; la
/// scrittura su disco — la parte a latenza variabile — va su un thread detached
/// che possiede il blob, così il decode ritorna senza aspettare l'I/O.
pub fn writeCoarse(gpa: std.mem.Allocator, path: []const u8, mtime_ns: i128, mesh: *const MeshData) void {
    if (!enabled) return;
    const dir = cacheDir(gpa) orelse return;
    defer gpa.free(dir);
    const kp = keyPath(gpa, dir, path) orelse return;
    defer gpa.free(kp);
    // Senza la dimensione del sorgente non si può validare la cache: niente scrittura.
    const src_size = srcSize(gpa, path) orelse return;

    // Già presente e aggiornata (stesso mtime e stessa dimensione)? evita di
    // ri-downscalare le texture e ri-serializzare i ~20MB ad ogni sharpen (la 2ª
    // fase di ogni apertura fa un decode full). Si scrive solo la prima volta.
    if (existsFresh(kp, mtime_ns, src_size)) return;

    // Tutto ciò che passa al thread usa page_allocator: il thread detached può
    // sopravvivere al teardown (e al leak-check) del gpa dell'app senza toccarlo.
    const pa = std.heap.page_allocator;
    var w = Writer{ .gpa = pa };
    serialize(&w, pa, mtime_ns, src_size, mesh) catch {
        w.buf.deinit(pa);
        return;
    };
    const blob = w.buf.toOwnedSlice(pa) catch {
        w.buf.deinit(pa);
        return;
    };
    const kp_owned = pa.dupeZ(u8, kp) catch {
        pa.free(blob);
        return;
    };

    // Il thread prende possesso di kp_owned e blob e li libera lui. Se lo spawn
    // fallisce, si scrive in linea (comportamento precedente).
    const t = std.Thread.spawn(.{}, writeBlob, .{ kp_owned, blob }) catch {
        writeBlob(kp_owned, blob);
        return;
    };
    t.detach();
}

/// Corpo della scrittura (thread detached): tmp + rename atomico, poi libera
/// blob e percorso. Usa solo page_allocator: nessuna dipendenza dal gpa dell'app.
fn writeBlob(kp: [:0]u8, blob: []u8) void {
    const pa = std.heap.page_allocator;
    defer pa.free(kp);
    defer pa.free(blob);
    // Nome tmp univoco anche TRA processi (PID + seq): due istanze di zuer che
    // scrivono la stessa chiave non devono interleave-arsi sullo stesso tmp.
    const seq = tmp_seq.fetchAdd(1, .monotonic);
    const tmp = std.fmt.allocPrintSentinel(pa, "{s}.tmp{d}_{d}", .{ kp, std.os.linux.getpid(), seq }, 0) catch return;
    defer pa.free(tmp);
    const fd = open(tmp.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
    if (fd < 0) return;
    const ok = writeAll(fd, blob);
    _ = close(fd);
    if (!ok) return;
    if (rename(tmp.ptr, kp.ptr) != 0) return;
    // Manutenzione post-scrittura (best-effort, siamo già su un thread detached):
    // sweep una-tantum dei tmp orfani + cap LRU della directory.
    if (std.fs.path.dirname(kp)) |dir| {
        evict.sweepTmpOnce(&tmp_sweep_done, dir);
        evict.evictLru(dir, evict_cap_bytes);
    }
}

/// Legge la mesh coarse se presente e con mtime+dimensione combacianti. null altrimenti.
pub fn readCoarse(gpa: std.mem.Allocator, path: []const u8, mtime_ns: i128) ?MeshData {
    if (!enabled) return null;
    const dir = cacheDir(gpa) orelse return null;
    defer gpa.free(dir);
    const kp = keyPath(gpa, dir, path) orelse return null;
    defer gpa.free(kp);
    const src_size = srcSize(gpa, path) orelse return null;

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
    const m = deserialize(&c, gpa, mtime_ns, src_size) catch return null;
    // Cache-hit: "touch" dell'mtime così l'eviction LRU non cancella le entry usate.
    evict.touchFd(fd);
    return m;
}

fn serialize(w: *Writer, gpa: std.mem.Allocator, mtime_ns: i128, src_size: u64, m: *const MeshData) !void {
    try w.buf.appendSlice(gpa, magic);
    try w.scalar(i128, mtime_ns);
    try w.scalar(u64, src_size);
    try w.scalar(u64, 0); // placeholder: checksum del payload, patchato a fine serialize
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
    var memo: TexMemo = .empty;
    defer {
        var it = memo.valueIterator();
        while (it.next()) |v| gpa.free(v.px);
        memo.deinit(gpa);
    }
    for (m.submeshes) |s| {
        try w.scalar(u64, @intCast(s.first_index));
        try w.scalar(u64, @intCast(s.index_count));
        try w.scalar([4]f32, s.base_color);
        try w.scalar(f32, s.metallic);
        try w.scalar(f32, s.roughness);
        try writeTexMemo(w, gpa, &memo, s.tex_pixels, s.tex_width, s.tex_height);
        // Normal map OMESSA nel tier coarse: è un'anteprima sfocata e il normal
        // mapping riappare con lo sharpen full. Risparmia downscale e disco.
        try writeTex(w, gpa, &.{}, 0, 0);
    }
    // Checksum del payload (tutto ciò che segue l'header), calcolato a
    // serializzazione completa e patchato nel placeholder — scritto come gli
    // altri scalari, in byte nativi.
    const hash = std.hash.Wyhash.hash(hash_seed, w.buf.items[header_len..]);
    @memcpy(w.buf.items[hash_off..][0..@sizeOf(u64)], std.mem.asBytes(&hash));
}

fn deserialize(c: *Cursor, gpa: std.mem.Allocator, expect_mtime: i128, expect_size: u64) !MeshData {
    if (c.data.len < magic.len or !std.mem.eql(u8, c.data[0..magic.len], magic)) return error.BadMagic;
    c.off = magic.len;
    const mtime = try c.scalar(i128);
    if (mtime != expect_mtime) return error.Stale;
    const src_size = try c.scalar(u64);
    if (src_size != expect_size) return error.Stale;
    const stored_hash = try c.scalar(u64);
    // Integrità verificata PRIMA di parsare: un blob corrotto con header valido
    // (bit-rot, byte alterati che i soli check strutturali non coprono) viene
    // scartato qui; il chiamante lo tratta da cache-miss e rigenera.
    if (std.hash.Wyhash.hash(hash_seed, c.data[c.off..]) != stored_hash) return error.Corrupt;

    var m: MeshData = .{
        .num_vertices = std.math.cast(usize, try c.scalar(u64)) orelse return error.Truncated,
        .num_faces = std.math.cast(usize, try c.scalar(u64)) orelse return error.Truncated,
        .num_normals = std.math.cast(usize, try c.scalar(u64)) orelse return error.Truncated,
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

    // I contatori dell'header devono combaciare con le lunghezze reali delle
    // slice: consumatori diversi usano gli uni o le altre come bound (es. la TUI
    // alloca per num_vertices e indicizza per faces) — una divergenza in un blob
    // corrotto diventerebbe un accesso OOB.
    if (m.num_vertices != m.vertices.len) return error.Truncated;
    if (m.num_faces != m.faces.len) return error.Truncated;
    if (m.num_normals != m.normals.len) return error.Truncated;
    // Gli indici delle facce finiscono nell'index buffer GPU: un indice oltre i
    // vertici reali sarebbe una vertex fetch OOB. Il checksum copre la corruzione
    // su disco ma non un blob scritto già incoerente: si valida comunque qui
    // (scansione sequenziale, costo trascurabile).
    for (m.faces) |f| {
        if (f.v1 >= m.vertices.len or f.v2 >= m.vertices.len or f.v3 >= m.vertices.len)
            return error.Truncated;
    }
    // Bound per i draw range delle submesh: indici totali reali (3 per faccia).
    const total_indices = std.math.mul(usize, m.faces.len, 3) catch return error.Truncated;

    const nsub = std.math.cast(usize, try c.scalar(u64)) orelse return error.Truncated;
    // Un conteggio ostile non deve poter chiedere un'allocazione enorme: ogni
    // submesh serializzata occupa ALMENO 88 byte (2×u64 + [4]f32 + 2×f32 + due
    // texture vuote da 24 byte l'una), quindi nsub è limitato dai byte restanti.
    if (nsub > (c.data.len - c.off) / 88) return error.Truncated;
    if (nsub > 0) {
        const subs = try gpa.alloc(SubMesh, nsub);
        // Inizializza a vuoto così un errore a metà lascia deinit coerente.
        for (subs) |*s| s.* = .{ .first_index = 0, .index_count = 0 };
        m.submeshes = subs;
        for (subs) |*s| {
            s.first_index = std.math.cast(usize, try c.scalar(u64)) orelse return error.Truncated;
            s.index_count = std.math.cast(usize, try c.scalar(u64)) orelse return error.Truncated;
            // Range dentro l'index buffer reale (somma controllata: un blob
            // corrotto non deve né overfloware né produrre un draw OOB in GPU).
            const end = std.math.add(usize, s.first_index, s.index_count) catch return error.Truncated;
            if (end > total_indices) return error.Truncated;
            s.base_color = try c.scalar([4]f32);
            s.metallic = try c.scalar(f32);
            s.roughness = try c.scalar(f32);
            s.tex_pixels = try readTex(c, gpa, &s.tex_width, &s.tex_height);
            s.nrm_tex_pixels = try readTex(c, gpa, &s.nrm_tex_width, &s.nrm_tex_height);
        }
    }
    return m;
}
