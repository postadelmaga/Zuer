//! Cache su disco delle texture DECODIFICATE (RGBA8, già sotto-campionate a
//! max_tex_dim). Le immagini embeddate nei GLB sono spesso 4K e stbi le decodifica
//! sulla CPU: ~5s per un modello texture-heavy, ad OGNI apertura. La cache VT
//! (.vtc) salta solo il bake, non il decode. Qui si salta il decode stesso: alla
//! prima apertura si scrive l'RGBA decodificato su disco, chiave = hash dei byte
//! CODIFICATI (così si può interrogare senza decodificare); le riaperture leggono
//! l'RGBA pronto (~lettura da page cache).
//!
//! Formato "RTX2": magic[4] | w u32 | h u32 | rgba (w*h*4 byte), little-endian.
//! Ci si tiene solo il tier COARSE (256²): ~192KB/texture → disco minimo. Il tier
//! full non è cachato (si ridecodifica in background nella 2ª fase), così la
//! cartella resta piccola senza bisogno di eviction. Il bump RTX1→RTX2 invalida
//! i vecchi file full-res (che venivano scritti a 2048²).

const std = @import("std");
const builtin = @import("builtin");

/// Solo Linux: usa syscall POSIX (open/read/write/rename/mkdir con flag O_* e
/// mkdir a due argomenti) che non linkerebbero sul CRT Windows. Sugli altri OS la
/// cache è disattivata (comptime), quindi il decode procede come prima.
const enabled = builtin.os.tag == .linux;

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;

const magic = "RTX2";

var tmp_seq: std.atomic.Value(u64) = .init(0);

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
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

/// `$HOME/.cache/zuer/tex`, creando la catena. null se niente HOME. Il chiamante libera.
fn cacheDir(gpa: std.mem.Allocator) ?[]u8 {
    const home_c = getenv("HOME") orelse return null;
    const home = std.mem.span(home_c);
    inline for (.{ "/.cache", "/.cache/zuer", "/.cache/zuer/tex" }) |suffix| {
        const p = std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ home, suffix }, 0) catch return null;
        defer gpa.free(p);
        _ = mkdir(p.ptr, 0o755); // EEXIST ignorato
    }
    return std.fmt.allocPrint(gpa, "{s}/.cache/zuer/tex", .{home}) catch null;
}

/// Legge l'RGBA cachato per `encoded` (hash del contenuto), o null se assente/rotto.
/// Il buffer è allocato con `gpa` (stessa ownership del path di decode).
pub fn read_cached(gpa: std.mem.Allocator, encoded: []const u8, out_w: *usize, out_h: *usize) ?[]u8 {
    if (!enabled) return null;
    const dir = cacheDir(gpa) orelse return null;
    defer gpa.free(dir);
    const key = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, encoded);
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{x}.rtex", .{ dir, key }, 0) catch return null;
    defer gpa.free(path);

    const fd = open(path.ptr, O_RDONLY, 0);
    if (fd < 0) return null;
    defer _ = close(fd);

    var hdr: [12]u8 = undefined;
    if (!readAll(fd, &hdr)) return null;
    if (!std.mem.eql(u8, hdr[0..4], magic)) return null;
    const w = rd32(&hdr, 4);
    const h = rd32(&hdr, 8);
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return null;
    const n = @as(usize, w) * h * 4;
    const buf = gpa.alloc(u8, n) catch return null;
    if (!readAll(fd, buf)) {
        gpa.free(buf);
        return null;
    }
    out_w.* = w;
    out_h.* = h;
    return buf;
}

/// Scrive l'RGBA decodificato in cache (write-to-temp + rename atomico). Best-effort:
/// ogni errore è silenzioso (la cache è un'ottimizzazione, non deve mai far fallire
/// il decode). Dopo la scrittura applica l'eviction se la dir supera il cap.
pub fn write_cached(gpa: std.mem.Allocator, encoded: []const u8, w: usize, h: usize, rgba: []const u8) void {
    if (!enabled) return;
    if (rgba.len != w * h * 4) return;
    const dir = cacheDir(gpa) orelse return;
    defer gpa.free(dir);
    const key = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, encoded);
    const seq = tmp_seq.fetchAdd(1, .monotonic);
    const tmp = std.fmt.allocPrintSentinel(gpa, "{s}/{x}.rtex.tmp{d}", .{ dir, key, seq }, 0) catch return;
    defer gpa.free(tmp);
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{x}.rtex", .{ dir, key }, 0) catch return;
    defer gpa.free(path);

    const fd = open(tmp.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
    if (fd < 0) return;
    var ok = true;
    {
        var hdr: [12]u8 = undefined;
        @memcpy(hdr[0..4], magic);
        wr32(&hdr, 4, @intCast(w));
        wr32(&hdr, 8, @intCast(h));
        ok = writeAll(fd, &hdr) and writeAll(fd, rgba);
    }
    _ = close(fd);
    if (!ok) return;
    _ = rename(tmp.ptr, path.ptr);
}
