//! Quali codec video la GPU decodifica in hardware, per scegliere il formato di
//! uno stream (yt-dlp) PRIMA di aprirlo: un VP9 o AV1 che la GPU non decodifica
//! finisce in software (CPU piena, a volte non in tempo reale) anche quando lo
//! stesso video esiste, alla stessa risoluzione, in un codec che la GPU sa fare.
//!
//! La domanda va fatta allo stesso dispositivo che userà mpv: col render API e il
//! display Wayland passato a mpv, l'hwdec vaapi apre VA con `vaGetDisplayWl` sulla
//! connessione Wayland, cioè sulla GPU del compositor. Qui si fa lo stesso, su una
//! connessione propria, una volta per processo (~decine di ms, sul thread che apre
//! lo stream). Tutto via dlopen: nessuna dipendenza di build, e senza libva le
//! capacità risultano vuote (= nessun codec in hardware).
//!
//! Su macOS niente rilevamento: H.264 e HEVC, che VideoToolbox decodifica su ogni
//! Mac (vedi `mac_caps`). Su Windows nessuna preferenza.
//!
//! `ZUER_HWDEC_CAPS` sostituisce il rilevamento (diagnostica e test): `none`, oppure
//! un elenco come `h264,hevc` (altezza massima 4320) o `h264:1080,vp9:2160`.

const std = @import("std");
const builtin = @import("builtin");

/// In ordine di efficienza di compressione crescente.
pub const Codec = enum(u2) { h264, hevc, vp9, av1 };

/// Altezza massima decodificabile in hardware, per codec (0 = non decodificato).
pub const Caps = struct {
    max_h: [4]u32 = @splat(0),

    pub fn supports(caps: Caps, k: Codec, height: u32) bool {
        const m = caps.max_h[@backingInt(k)];
        return m > 0 and m >= height;
    }
};

/// Codec da preferire per uno stream alto `height`: il più efficiente che la GPU
/// decodifica a quell'altezza. Senza nessun codec in hardware, H.264: in software
/// è il più leggero da decodificare, e YouTube lo serve fino a 1080p.
///
/// È una PREFERENZA a parità di risoluzione e fps (vedi `ytdlpSort`): non si scende
/// mai di risoluzione per avere un codec in hardware. Sopra 1080p YouTube non ha
/// H.264: lì, senza VP9/AV1 in hardware, resta la decodifica software (scelta
/// consapevole: la qualità richiesta vale più della CPU).
pub fn preferred(caps: Caps, height: u32) Codec {
    for ([_]Codec{ .av1, .vp9, .hevc, .h264 }) |k| if (caps.supports(k, height)) return k;
    return .h264;
}

/// Ordinamento yt-dlp (`-S`): risoluzione e fps prima di tutto (la qualità
/// richiesta), poi il codec. `vcodec:X` in yt-dlp = preferisci X, poi i codec
/// "inferiori" nel suo ordine (av01 > vp9.2 > vp9 > h265 > h264 > …), e quelli
/// superiori per ultimi: con X = il migliore in hardware, i codec che la GPU non
/// decodifica vanno in fondo. (Un buco nell'ordine — VP9 sì, HEVC no — non conta
/// su YouTube, che HEVC non lo serve.)
pub fn ytdlpSort(buf: []u8, caps: Caps, height: u32) []const u8 {
    const name = switch (preferred(caps, height)) {
        .av1 => "av01",
        .vp9 => "vp9",
        .hevc => "h265",
        .h264 => "h264",
    };
    return std.fmt.bufPrint(buf, "res,fps,vcodec:{s}", .{name}) catch "res,fps,vcodec:h264";
}

var cached: Caps = .{};
var state: enum { unknown, ready } = .unknown;
var lock: std.atomic.Mutex = .unlocked;

/// Le capacità della GPU del compositor (rilevate al primo uso, poi in cache).
/// `null` fuori da Linux: lì la decodifica non passa da mpv/VA-API e la scelta
/// del formato resta quella predefinita di yt-dlp.
pub fn get() ?Caps {
    if (comptime builtin.os.tag != .linux) return override() orelse if (comptime builtin.os.tag == .macos) mac_caps else null;
    while (!lock.tryLock()) std.Thread.yield() catch {};
    defer lock.unlock();
    if (state == .ready) return cached;
    cached = if (override()) |o| o else probe();
    state = .ready;
    log(cached);
    return cached;
}

fn log(caps: Caps) void {
    var buf: [160]u8 = undefined;
    var n: usize = 0;
    inline for (.{ Codec.h264, Codec.hevc, Codec.vp9, Codec.av1 }) |k| {
        const m = caps.max_h[@backingInt(k)];
        const part = if (m > 0)
            std.fmt.bufPrint(buf[n..], " {s}≤{d}", .{ @tagName(k), m }) catch ""
        else
            std.fmt.bufPrint(buf[n..], " {s}=no", .{@tagName(k)}) catch "";
        n += part.len;
    }
    std.log.info("zuer video: decodifica hardware (VA-API):{s}", .{buf[0..n]});
}

/// macOS: VideoToolbox decodifica H.264 e HEVC su ogni Mac che macOS 11 supporta;
/// AV1 solo da M3 in poi, VP9 non su tutti. Senza dichiararlo yt-dlp sceglierebbe AV1
/// o VP9, che su Intel e M1/M2 finiscono in software (libdav1d: CPU piena).
const mac_caps: Caps = parseOverride("h264,hevc");

fn override() ?Caps {
    const raw = std.c.getenv("ZUER_HWDEC_CAPS") orelse return null;
    return parseOverride(std.mem.span(raw));
}

fn parseOverride(s: []const u8) Caps {
    var caps: Caps = .{};
    var it = std.mem.tokenizeScalar(u8, s, ',');
    while (it.next()) |item| {
        const colon = std.mem.indexOfScalar(u8, item, ':');
        const name = item[0 .. colon orelse item.len];
        const h = if (colon) |i| std.fmt.parseInt(u32, item[i + 1 ..], 10) catch 0 else 4320;
        const k = std.meta.stringToEnum(Codec, name) orelse continue;
        caps.max_h[@backingInt(k)] = h;
    }
    return caps;
}

// ── VA-API (Linux) ──────────────────────────────────────────────────────────

const VAStatus = c_int;
const VAConfigAttrib = extern struct { type: c_int, value: u32 };
const va_attrib_not_supported: u32 = 0x80000000;
const va_entrypoint_vld: c_int = 1;
const va_attrib_max_height: c_int = 19;

/// Profili VA (va.h) che contano per i codec degli stream: H.264 Main/High,
/// HEVC Main, VP9 profilo 0 (8 bit; i 10 bit HDR sono un'altra cosa), AV1 profilo 0.
const profiles = [_]struct { k: Codec, p: c_int }{
    .{ .k = .h264, .p = 6 },
    .{ .k = .h264, .p = 7 },
    .{ .k = .hevc, .p = 17 },
    .{ .k = .vp9, .p = 19 },
    .{ .k = .av1, .p = 32 },
};

fn sym(lib: *anyopaque, comptime T: type, name: [:0]const u8) ?T {
    const p = std.c.dlsym(lib, name.ptr) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn probe() Caps {
    if (comptime builtin.os.tag != .linux) return .{};
    var caps: Caps = .{};
    // Le librerie restano caricate (mai dlclose): libwayland-client lo è già
    // comunque, libva la caricherà mpv.
    const wl = std.c.dlopen("libwayland-client.so.0", .{ .NOW = true }) orelse return caps;
    const va = std.c.dlopen("libva.so.2", .{ .NOW = true }) orelse return caps;
    const vaw = std.c.dlopen("libva-wayland.so.2", .{ .NOW = true }) orelse return caps;

    const connect = sym(wl, *const fn (?[*:0]const u8) callconv(.c) ?*anyopaque, "wl_display_connect") orelse return caps;
    const disconnect = sym(wl, *const fn (*anyopaque) callconv(.c) void, "wl_display_disconnect") orelse return caps;
    const get_display = sym(vaw, *const fn (*anyopaque) callconv(.c) ?*anyopaque, "vaGetDisplayWl") orelse return caps;
    const set_info = sym(va, *const fn (*anyopaque, ?*const anyopaque, ?*anyopaque) callconv(.c) ?*const anyopaque, "vaSetInfoCallback");
    const initialize = sym(va, *const fn (*anyopaque, *c_int, *c_int) callconv(.c) VAStatus, "vaInitialize") orelse return caps;
    const terminate = sym(va, *const fn (*anyopaque) callconv(.c) VAStatus, "vaTerminate") orelse return caps;
    const max_profiles = sym(va, *const fn (*anyopaque) callconv(.c) c_int, "vaMaxNumProfiles") orelse return caps;
    const query_profiles = sym(va, *const fn (*anyopaque, [*]c_int, *c_int) callconv(.c) VAStatus, "vaQueryConfigProfiles") orelse return caps;
    const max_entry = sym(va, *const fn (*anyopaque) callconv(.c) c_int, "vaMaxNumEntrypoints") orelse return caps;
    const query_entry = sym(va, *const fn (*anyopaque, c_int, [*]c_int, *c_int) callconv(.c) VAStatus, "vaQueryConfigEntrypoints") orelse return caps;
    const get_attrs = sym(va, *const fn (*anyopaque, c_int, c_int, [*]VAConfigAttrib, c_int) callconv(.c) VAStatus, "vaGetConfigAttributes") orelse return caps;

    const wd = connect(null) orelse return caps;
    defer disconnect(wd);
    const dpy = get_display(wd) orelse return caps;
    // Niente "libva info: VA-API version …" sul terminale a ogni avvio.
    if (set_info) |f| _ = f(dpy, null, null);
    var major: c_int = 0;
    var minor: c_int = 0;
    if (initialize(dpy, &major, &minor) != 0) return caps;
    defer _ = terminate(dpy);

    var plist: [64]c_int = undefined;
    var pn: c_int = 0;
    if (max_profiles(dpy) > @as(c_int, plist.len)) return caps;
    if (query_profiles(dpy, &plist, &pn) != 0) return caps;
    var elist: [32]c_int = undefined;
    if (max_entry(dpy) > @as(c_int, elist.len)) return caps;

    for (profiles) |want| {
        const have = for (plist[0..@intCast(pn)]) |p| {
            if (p == want.p) break true;
        } else false;
        if (!have) continue;
        var en: c_int = 0;
        if (query_entry(dpy, want.p, &elist, &en) != 0) continue;
        const vld = for (elist[0..@intCast(en)]) |e| {
            if (e == va_entrypoint_vld) break true;
        } else false;
        if (!vld) continue;
        // Altezza massima del decoder, se il driver la dichiara; altrimenti si
        // assume che regga quello che uno stream può chiedere.
        var attr = [_]VAConfigAttrib{.{ .type = va_attrib_max_height, .value = 0 }};
        var h: u32 = 4320;
        if (get_attrs(dpy, want.p, va_entrypoint_vld, &attr, 1) == 0 and attr[0].value != va_attrib_not_supported and attr[0].value > 0) h = attr[0].value;
        const i = @backingInt(want.k);
        caps.max_h[i] = @max(caps.max_h[i], h);
    }
    return caps;
}

test "preferred: il codec più efficiente che la GPU decodifica a quell'altezza" {
    const skylake = parseOverride("h264:2160,hevc:2160");
    try std.testing.expectEqual(Codec.hevc, preferred(skylake, 1080));
    const recent = parseOverride("h264,hevc,vp9,av1");
    try std.testing.expectEqual(Codec.av1, preferred(recent, 1080));
    const vp9_only_small = parseOverride("h264:4320,vp9:1080");
    try std.testing.expectEqual(Codec.vp9, preferred(vp9_only_small, 1080));
    try std.testing.expectEqual(Codec.h264, preferred(vp9_only_small, 2160));
    // Niente VA-API: H.264, il più leggero in software.
    try std.testing.expectEqual(Codec.h264, preferred(.{}, 720));
    try std.testing.expectEqual(Codec.h264, preferred(parseOverride("none"), 720));
}

test "macOS: H.264/HEVC dichiarati, yt-dlp evita AV1 e VP9" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqual(Codec.hevc, preferred(mac_caps, 2160));
    try std.testing.expectEqualStrings("res,fps,vcodec:h265", ytdlpSort(&buf, mac_caps, 720));
}

test "ytdlpSort: risoluzione e fps prima del codec" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("res,fps,vcodec:h265", ytdlpSort(&buf, parseOverride("h264,hevc"), 1080));
    try std.testing.expectEqualStrings("res,fps,vcodec:av01", ytdlpSort(&buf, parseOverride("av1,vp9,h264"), 720));
    try std.testing.expectEqualStrings("res,fps,vcodec:h264", ytdlpSort(&buf, .{}, 1080));
}
