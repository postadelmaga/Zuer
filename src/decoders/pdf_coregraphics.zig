//! Rasterizzazione PDF su macOS con CoreGraphics (CGPDFDocument): il motore PDF
//! del sistema, quindi nessuna dipendenza da distribuire (su Linux il plugin usa
//! poppler, che su un Mac non c'è). Solo API C: CoreGraphics e CoreFoundation si
//! aprono a runtime con dlopen alla prima pagina, così il plugin compila anche in
//! cross-compilazione senza SDK e un processo che non apre PDF non le carica.
//!
//! Stessa interfaccia del ramo poppler di pdf.zig: `pageCount` e `render`, pixel
//! RGB 8 bit, errori `NoPagesRendered` per una pagina oltre la fine (il chiamante
//! clampa e riprova). Ogni chiamata apre e rilascia il proprio documento: nessuno
//! stato condiviso fra i thread del plugin, nessun handle trattenuto.

const std = @import("std");

pub const Scale = union(enum) {
    /// Punti per pollice (`-r` di pdftoppm).
    dpi: u32,
    /// Lato lungo della pagina in pixel (`-scale-to` di pdftoppm).
    fit: u32,
};

pub const Raster = struct { width: usize, height: usize, pixels: []u8 };

const CFTypeRef = ?*anyopaque;
const CGFloat = f64;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

const kCGPDFCropBox: c_int = 1;
const kCGImageAlphaNoneSkipLast: u32 = 5; // RGBX, 32 bit per pixel
const kCGRenderingIntentDefault: c_int = 0;

const Api = struct {
    CFURLCreateFromFileSystemRepresentation: *const fn (CFTypeRef, [*]const u8, isize, bool) callconv(.c) CFTypeRef,
    CFRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGPDFDocumentCreateWithURL: *const fn (CFTypeRef) callconv(.c) CFTypeRef,
    CGPDFDocumentRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGPDFDocumentGetNumberOfPages: *const fn (CFTypeRef) callconv(.c) usize,
    CGPDFDocumentIsUnlocked: *const fn (CFTypeRef) callconv(.c) bool,
    CGPDFDocumentGetPage: *const fn (CFTypeRef, usize) callconv(.c) CFTypeRef,
    CGPDFPageGetBoxRect: *const fn (CFTypeRef, c_int) callconv(.c) CGRect,
    CGPDFPageGetRotationAngle: *const fn (CFTypeRef) callconv(.c) c_int,
    CGColorSpaceCreateDeviceRGB: *const fn () callconv(.c) CFTypeRef,
    CGColorSpaceRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGBitmapContextCreate: *const fn (?*anyopaque, usize, usize, usize, usize, CFTypeRef, u32) callconv(.c) CFTypeRef,
    CGContextRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGContextSetRGBFillColor: *const fn (CFTypeRef, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) void,
    CGContextFillRect: *const fn (CFTypeRef, CGRect) callconv(.c) void,
    CGContextScaleCTM: *const fn (CFTypeRef, CGFloat, CGFloat) callconv(.c) void,
    CGContextTranslateCTM: *const fn (CFTypeRef, CGFloat, CGFloat) callconv(.c) void,
    CGContextRotateCTM: *const fn (CFTypeRef, CGFloat) callconv(.c) void,
    CGContextSetRenderingIntent: *const fn (CFTypeRef, c_int) callconv(.c) void,
    CGContextDrawPDFPage: *const fn (CFTypeRef, CFTypeRef) callconv(.c) void,
};

const cf_path = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
const cg_path = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";

var api_lock: std.atomic.Value(bool) = .init(false);
var api: ?Api = null;
var api_failed = false;

/// Le due librerie restano aperte fino all'uscita: sono framework di sistema già
/// mappati dalla shared cache di dyld, chiuderli non libererebbe nulla.
fn getApi() !*const Api {
    while (api_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer api_lock.store(false, .release);
    if (api) |*a| return a;
    if (api_failed) return error.CoreGraphicsUnavailable;
    var cf = std.DynLib.open(cf_path) catch {
        api_failed = true;
        return error.CoreGraphicsUnavailable;
    };
    var cg = std.DynLib.open(cg_path) catch {
        cf.close();
        api_failed = true;
        return error.CoreGraphicsUnavailable;
    };
    var a: Api = undefined;
    inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |name, T| {
        const lib = if (comptime std.mem.startsWith(u8, name, "CF")) &cf else &cg;
        @field(a, name) = lib.lookup(T, name) orelse {
            api_failed = true;
            return error.CoreGraphicsUnavailable;
        };
    }
    api = a;
    return &api.?;
}

const Doc = struct {
    a: *const Api,
    doc: CFTypeRef,

    fn open(abs_path: []const u8) !Doc {
        const a = try getApi();
        const url = a.CFURLCreateFromFileSystemRepresentation(null, abs_path.ptr, @intCast(abs_path.len), false) orelse
            return error.PdfOpenFailed;
        defer a.CFRelease(url);
        const doc = a.CGPDFDocumentCreateWithURL(url) orelse return error.PdfOpenFailed;
        // Cifrato con password utente: CoreGraphics non lo apre senza.
        if (!a.CGPDFDocumentIsUnlocked(doc)) {
            a.CGPDFDocumentRelease(doc);
            return error.PdfEncrypted;
        }
        return .{ .a = a, .doc = doc };
    }

    fn close(self: Doc) void {
        self.a.CGPDFDocumentRelease(self.doc);
    }
};

pub fn pageCount(abs_path: []const u8) !usize {
    const d = try Doc.open(abs_path);
    defer d.close();
    const n = d.a.CGPDFDocumentGetNumberOfPages(d.doc);
    return if (n == 0) error.PdfNoPages else n;
}

/// Rende la pagina `page` (1-based). `max_bytes` e `max_side` sono i tetti di
/// pdf.zig contro un MediaBox ostile: verificati PRIMA di allocare.
pub fn render(gpa: std.mem.Allocator, abs_path: []const u8, page: usize, scale: Scale, max_side: usize, max_bytes: usize) !Raster {
    const d = try Doc.open(abs_path);
    defer d.close();
    const a = d.a;
    const total = a.CGPDFDocumentGetNumberOfPages(d.doc);
    if (page < 1 or page > total) return error.NoPagesRendered;
    const pg = a.CGPDFDocumentGetPage(d.doc, page) orelse return error.NoPagesRendered;

    const box = a.CGPDFPageGetBoxRect(pg, kCGPDFCropBox);
    const bw = box.size.width;
    const bh = box.size.height;
    if (!(bw > 0 and bh > 0)) return error.PdfBadPage;
    // /Rotate: multiplo di 90, in senso orario.
    const rot: u32 = @intCast(@mod(a.CGPDFPageGetRotationAngle(pg), 360));
    const swap = rot == 90 or rot == 270;
    const ow = if (swap) bh else bw; // in punti
    const oh = if (swap) bw else bh;

    const s: f64 = switch (scale) {
        .dpi => |dpi| @as(f64, @floatFromInt(dpi)) / 72.0,
        .fit => |side| @as(f64, @floatFromInt(side)) / @max(ow, oh),
    };
    // Come pdftoppm: per eccesso, ma senza che l'errore di arrotondamento di
    // 792 × 150/72 = 1650,000…01 aggiunga una riga (1651).
    const wf = @ceil(ow * s - 1e-6);
    const hf = @ceil(oh * s - 1e-6);
    if (!(wf >= 1 and hf >= 1) or wf > @as(f64, @floatFromInt(max_side)) or hf > @as(f64, @floatFromInt(max_side)))
        return error.PdfPageTooLarge;
    const w: usize = @intFromFloat(wf);
    const h: usize = @intFromFloat(hf);
    if (w * h * 3 > max_bytes) return error.PdfPageTooLarge;

    // Bitmap RGBX di lavoro, poi compattata in RGB nel buffer finale.
    const stride = w * 4;
    const rgbx = try gpa.alloc(u8, stride * h);
    defer gpa.free(rgbx);
    const cs = a.CGColorSpaceCreateDeviceRGB() orelse return error.PdfRenderFailed;
    defer a.CGColorSpaceRelease(cs);
    const ctx = a.CGBitmapContextCreate(rgbx.ptr, w, h, 8, stride, cs, kCGImageAlphaNoneSkipLast) orelse
        return error.PdfRenderFailed;
    defer a.CGContextRelease(ctx);

    // Fondo bianco (la pagina PDF è trasparente dove non disegna nulla).
    a.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    a.CGContextFillRect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = wf, .height = hf } });
    a.CGContextSetRenderingIntent(ctx, kCGRenderingIntentDefault);

    // Spazio pagina → pixel (CoreGraphics ha l'asse y verso l'alto e applica per
    // prima l'ULTIMA trasformazione): origine del CropBox in (0,0), rotazione
    // oraria di /Rotate riportata nel quadrante positivo, poi la scala.
    a.CGContextScaleCTM(ctx, s, s);
    switch (rot) {
        90 => {
            a.CGContextTranslateCTM(ctx, 0, bw);
            a.CGContextRotateCTM(ctx, -std.math.pi / 2.0);
        },
        180 => {
            a.CGContextTranslateCTM(ctx, bw, bh);
            a.CGContextRotateCTM(ctx, -std.math.pi);
        },
        270 => {
            a.CGContextTranslateCTM(ctx, bh, 0);
            a.CGContextRotateCTM(ctx, -3.0 * std.math.pi / 2.0);
        },
        else => {},
    }
    a.CGContextTranslateCTM(ctx, -box.origin.x, -box.origin.y);
    a.CGContextDrawPDFPage(ctx, pg);

    // La riga 0 del buffer di un bitmap context è il bordo SUPERIORE dell'immagine.
    const rgb = try gpa.alloc(u8, w * h * 3);
    for (0..w * h) |i| {
        rgb[i * 3 + 0] = rgbx[i * 4 + 0];
        rgb[i * 3 + 1] = rgbx[i * 4 + 1];
        rgb[i * 3 + 2] = rgbx[i * 4 + 2];
    }
    return .{ .width = w, .height = h, .pixels = rgb };
}
