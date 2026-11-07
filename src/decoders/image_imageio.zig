//! Codec immagine di sistema su macOS (ImageIO): il ripiego per i formati che
//! stb_image, libwebp e nanosvg non coprono (TIFF, HEIC, AVIF, JPEG 2000, ICNS…),
//! lo stesso ruolo di ImageMagick su Linux e di WIC su Windows. Solo API C:
//! ImageIO, CoreGraphics e CoreFoundation si aprono a runtime alla prima immagine
//! (come in pdf_coregraphics.zig), quindi nessun link e nessun SDK in cross-build.
//!
//! I pixel escono già composti su bianco (la bitmap è riempita di bianco prima di
//! disegnarci l'immagine): RGBA con alpha 255, allocati con `gpa`.

const std = @import("std");

pub const Raster = struct { width: usize, height: usize, rgba: []u8 };

const CFTypeRef = ?*anyopaque;
const CGFloat = f64;
const CGRect = extern struct { x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat };
const kCGImageAlphaPremultipliedLast: u32 = 1;

const Api = struct {
    CFDataCreate: *const fn (CFTypeRef, [*]const u8, isize) callconv(.c) CFTypeRef,
    CFRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGImageSourceCreateWithData: *const fn (CFTypeRef, CFTypeRef) callconv(.c) CFTypeRef,
    CGImageSourceGetCount: *const fn (CFTypeRef) callconv(.c) usize,
    CGImageSourceCreateImageAtIndex: *const fn (CFTypeRef, usize, CFTypeRef) callconv(.c) CFTypeRef,
    CGImageGetWidth: *const fn (CFTypeRef) callconv(.c) usize,
    CGImageGetHeight: *const fn (CFTypeRef) callconv(.c) usize,
    CGImageRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGColorSpaceCreateDeviceRGB: *const fn () callconv(.c) CFTypeRef,
    CGColorSpaceRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGBitmapContextCreate: *const fn (?*anyopaque, usize, usize, usize, usize, CFTypeRef, u32) callconv(.c) CFTypeRef,
    CGContextRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGContextSetRGBFillColor: *const fn (CFTypeRef, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) void,
    CGContextFillRect: *const fn (CFTypeRef, CGRect) callconv(.c) void,
    CGContextDrawImage: *const fn (CFTypeRef, CGRect, CFTypeRef) callconv(.c) void,
};

const libs = [_][]const u8{
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
    "/System/Library/Frameworks/ImageIO.framework/ImageIO",
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
};

var api_lock: std.atomic.Value(bool) = .init(false);
var api: ?Api = null;
var api_failed = false;

fn getApi() !*const Api {
    while (api_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer api_lock.store(false, .release);
    if (api) |*a| return a;
    if (api_failed) return error.ImageIoUnavailable;
    api_failed = true;
    var handles: [libs.len]std.DynLib = undefined;
    for (libs, 0..) |p, i| handles[i] = std.DynLib.open(p) catch return error.ImageIoUnavailable;
    var a: Api = undefined;
    inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |name, T| {
        const lib = if (comptime std.mem.startsWith(u8, name, "CF"))
            &handles[0]
        else if (comptime std.mem.startsWith(u8, name, "CGImageSource"))
            &handles[1]
        else
            &handles[2];
        @field(a, name) = lib.lookup(T, name) orelse return error.ImageIoUnavailable;
    }
    api = a;
    api_failed = false;
    return &api.?;
}

/// Primo fotogramma di `bytes`. `max_pixels` è verificato PRIMA di allocare.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, max_pixels: usize) !Raster {
    const a = try getApi();
    const data = a.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
    defer a.CFRelease(data);
    const src = a.CGImageSourceCreateWithData(data, null) orelse return error.UnsupportedImageFormat;
    defer a.CFRelease(src);
    if (a.CGImageSourceGetCount(src) == 0) return error.UnsupportedImageFormat;
    const img = a.CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.UnsupportedImageFormat;
    defer a.CGImageRelease(img);
    const w = a.CGImageGetWidth(img);
    const h = a.CGImageGetHeight(img);
    if (w == 0 or h == 0) return error.InvalidImageSize;
    if (w * h > max_pixels) return error.ImageTooLarge;

    const rgba = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(rgba);
    const cs = a.CGColorSpaceCreateDeviceRGB() orelse return error.ImageIoFailed;
    defer a.CGColorSpaceRelease(cs);
    const ctx = a.CGBitmapContextCreate(rgba.ptr, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast) orelse
        return error.ImageIoFailed;
    defer a.CGContextRelease(ctx);
    const rect: CGRect = .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    a.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    a.CGContextFillRect(ctx, rect);
    a.CGContextDrawImage(ctx, rect, img);
    return .{ .width = w, .height = h, .rgba = rgba };
}
