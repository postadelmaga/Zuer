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
//! full non è cachato (si ridecodifica in background nella 2ª fase). Il bump
//! RTX1→RTX2 invalida i vecchi file full-res (che venivano scritti a 2048²).
//! La directory ha comunque un cap LRU (vedi `evict_cap_bytes`): tanti modelli
//! texture-heavy accumulano file all'infinito senza eviction.

const std = @import("std");
const builtin = @import("builtin");
const dc = @import("decoder").diskcache;

/// Solo Linux: la manutenzione (tetto LRU) esiste solo lì, e senza tetto questa
/// cache crescerebbe senza limite. Sugli altri OS è disattivata (comptime) e il
/// decode procede come prima.
const enabled = builtin.os.tag == .linux;

const magic = "RTX2";
const header_len = 12;

/// Cap LRU della directory `~/.cache/zuer/tex`: oltre questa soglia l'eviction
/// (post-scrittura) cancella i file con mtime più vecchio.
const evict_cap_bytes: u64 = 256 * 1024 * 1024; // 256 MiB

/// Sweep dei tmp orfani fatto al più una volta per processo (alla prima scrittura).
var tmp_sweep_done: std.atomic.Value(bool) = .init(false);

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

/// Legge l'RGBA cachato per `encoded` (hash del contenuto), o null se assente/rotto.
/// Il buffer è allocato con `gpa` (stessa ownership del path di decode).
pub fn read_cached(gpa: std.mem.Allocator, encoded: []const u8, out_w: *usize, out_h: *usize) ?[]u8 {
    if (!enabled) return null;
    const dir = dc.cacheDir(gpa, "tex") orelse return null;
    defer gpa.free(dir);
    const key = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, encoded);
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{x}.rtex", .{ dir, key }, 0) catch return null;
    defer gpa.free(path);

    const fd = dc.openRead(path) orelse return null;
    defer dc.closeH(fd);

    var hdr: [header_len]u8 = undefined;
    if (!dc.readExact(fd, &hdr, 0)) return null;
    if (!std.mem.eql(u8, hdr[0..4], magic)) return null;
    const w = rd32(&hdr, 4);
    const h = rd32(&hdr, 8);
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return null;
    const n = @as(usize, w) * h * 4;
    const buf = gpa.alloc(u8, n) catch return null;
    if (!dc.readExact(fd, buf, header_len)) {
        gpa.free(buf);
        return null;
    }
    // Cache-hit: "touch" dell'mtime così l'eviction LRU non cancella le entry usate.
    dc.touch(fd);
    out_w.* = w;
    out_h.* = h;
    return buf;
}

/// Scrive l'RGBA decodificato in cache (scrittura atomica: `diskcache.AtomicWriter`).
/// Best-effort: ogni errore è silenzioso (la cache è un'ottimizzazione, non deve mai
/// far fallire il decode). Dopo ogni scrittura riuscita si applica il cap LRU della
/// directory (e, una volta per processo, lo sweep dei tmp orfani).
pub fn write_cached(gpa: std.mem.Allocator, encoded: []const u8, w: usize, h: usize, rgba: []const u8) void {
    if (!enabled) return;
    if (rgba.len != w * h * 4) return;
    const dir = dc.cacheDir(gpa, "tex") orelse return;
    defer gpa.free(dir);
    const key = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, encoded);
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{x}.rtex", .{ dir, key }, 0) catch return;
    defer gpa.free(path);

    var hdr: [header_len]u8 = undefined;
    @memcpy(hdr[0..4], magic);
    wr32(&hdr, 4, @intCast(w));
    wr32(&hdr, 8, @intCast(h));
    var out = dc.AtomicWriter.begin(gpa, path) orelse return;
    out.write(&hdr);
    out.write(rgba);
    if (!out.commit()) return;
    dc.maintain(&tmp_sweep_done, dir, evict_cap_bytes);
}
