//! Rasterizzazione PDF su Windows con PDFium (il motore PDF di Chromium, BSD-3 /
//! Apache-2.0): Windows non ha né poppler né un motore PDF di sistema con un'API C
//! (Windows.Data.Pdf è WinRT asincrono), quindi `pdfium.dll` viaggia nel pacchetto
//! accanto a zuer-gui.exe, scaricata con hash verificato da scripts/fetch-pdfium.sh.
//!
//! Stessa interfaccia del ramo CoreGraphics (pdf_coregraphics.zig): `pageCount` e
//! `render`, pixel RGB 8 bit, `NoPagesRendered` per una pagina oltre la fine (il
//! chiamante clampa e riprova). La DLL si apre a runtime al primo PDF — un processo
//! che non apre PDF non la carica — e solo dalla cartella dell'app o da System32,
//! mai dalla cartella corrente (LOAD_LIBRARY_SEARCH_DEFAULT_DIRS).
//!
//! PDFium NON è thread-safe (fpdfview.h: "None of the PDFium APIs are thread-safe"):
//! il plugin è chiamato da più worker insieme (pagina corrente, prefetch, miniature),
//! quindi OGNI chiamata passa da un unico SRWLOCK. Ogni operazione apre e chiude il
//! proprio documento: nessun handle sopravvive al lock.

const std = @import("std");

pub const Scale = union(enum) {
    /// Punti per pollice (`-r` di pdftoppm).
    dpi: u32,
    /// Lato lungo della pagina in pixel (`-scale-to` di pdftoppm).
    fit: u32,
};

pub const Raster = struct { width: usize, height: usize, pixels: []u8 };

const FPDF_DOCUMENT = *opaque {};
const FPDF_PAGE = *opaque {};
const FPDF_BITMAP = *opaque {};

/// FPDF_LIBRARY_CONFIG versione 2: niente percorsi font extra (si usano i font di
/// sistema), niente V8 (la build distribuita è senza JavaScript né XFA).
const LibraryConfig = extern struct {
    version: c_int = 2,
    user_font_paths: ?[*]const ?[*:0]const u8 = null,
    isolate: ?*anyopaque = null,
    v8_embedder_slot: c_uint = 0,
};

const FPDF_ERR_PASSWORD: c_ulong = 4;
const FPDF_ERR_SECURITY: c_ulong = 5;
const FPDF_ANNOT: c_int = 0x01;
const FPDF_REVERSE_BYTE_ORDER: c_int = 0x10; // RGB invece del BGR nativo di Windows
const FPDFBitmap_BGR: c_int = 2; // 3 byte per pixel: con REVERSE_BYTE_ORDER è RGB

// FPDF_CALLCONV è __stdcall su Win32, che su x86-64 coincide con la convenzione C.
const Api = struct {
    FPDF_InitLibraryWithConfig: *const fn (*const LibraryConfig) callconv(.c) void,
    FPDF_LoadDocument: *const fn ([*:0]const u8, ?[*:0]const u8) callconv(.c) ?FPDF_DOCUMENT,
    FPDF_GetLastError: *const fn () callconv(.c) c_ulong,
    FPDF_CloseDocument: *const fn (FPDF_DOCUMENT) callconv(.c) void,
    FPDF_GetPageCount: *const fn (FPDF_DOCUMENT) callconv(.c) c_int,
    FPDF_LoadPage: *const fn (FPDF_DOCUMENT, c_int) callconv(.c) ?FPDF_PAGE,
    FPDF_ClosePage: *const fn (FPDF_PAGE) callconv(.c) void,
    FPDF_GetPageWidthF: *const fn (FPDF_PAGE) callconv(.c) f32,
    FPDF_GetPageHeightF: *const fn (FPDF_PAGE) callconv(.c) f32,
    FPDFBitmap_CreateEx: *const fn (c_int, c_int, c_int, ?*anyopaque, c_int) callconv(.c) ?FPDF_BITMAP,
    FPDFBitmap_FillRect: *const fn (FPDF_BITMAP, c_int, c_int, c_int, c_int, c_ulong) callconv(.c) c_int,
    FPDFBitmap_Destroy: *const fn (FPDF_BITMAP) callconv(.c) void,
    FPDF_RenderPageBitmap: *const fn (FPDF_BITMAP, FPDF_PAGE, c_int, c_int, c_int, c_int, c_int, c_int) callconv(.c) void,
};

const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
const LOAD_LIBRARY_SEARCH_DEFAULT_DIRS: u32 = 0x00001000;

/// Serializza TUTTO l'uso di PDFium (caricamento compreso).
var lock: SRWLOCK = .{};
var api: ?Api = null;
var api_failed = false;

/// Nome della DLL: sovrascrivibile solo per le prove (`ZUER_PDFIUM=none` simula il
/// pacchetto senza PDFium e verifica il messaggio d'errore).
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Da chiamare col lock preso. La DLL resta caricata fino all'uscita del processo
/// (FPDF_DestroyLibrary non serve: le risorse globali muoiono col processo).
fn getApi() !*const Api {
    if (api) |*a| return a;
    if (api_failed) return error.PdfiumUnavailable;
    api_failed = true; // finché non riesce del tutto
    if (getenv("ZUER_PDFIUM")) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "none")) return error.PdfiumUnavailable;
    }
    const name = std.unicode.utf8ToUtf16LeStringLiteral("pdfium.dll");
    const mod = LoadLibraryExW(name, null, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) orelse return error.PdfiumUnavailable;
    var a: Api = undefined;
    inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |fname, T| {
        const p = GetProcAddress(mod, fname) orelse return error.PdfiumUnavailable;
        @field(a, fname) = @as(T, @ptrCast(@alignCast(p)));
    }
    const cfg: LibraryConfig = .{};
    a.FPDF_InitLibraryWithConfig(&cfg);
    api = a;
    api_failed = false;
    return &api.?;
}

const Doc = struct {
    a: *const Api,
    doc: FPDF_DOCUMENT,

    /// `abs_path` in UTF-8 (l'encoding che FPDF_LoadDocument si aspetta).
    fn open(gpa: std.mem.Allocator, abs_path: []const u8) !Doc {
        const a = try getApi();
        const pz = try gpa.dupeSentinel(u8, abs_path, 0);
        defer gpa.free(pz);
        const doc = a.FPDF_LoadDocument(pz.ptr, null) orelse return switch (a.FPDF_GetLastError()) {
            FPDF_ERR_PASSWORD, FPDF_ERR_SECURITY => error.PdfEncrypted,
            else => error.PdfOpenFailed,
        };
        return .{ .a = a, .doc = doc };
    }

    fn close(self: Doc) void {
        self.a.FPDF_CloseDocument(self.doc);
    }
};

pub fn pageCount(gpa: std.mem.Allocator, abs_path: []const u8) !usize {
    AcquireSRWLockExclusive(&lock);
    defer ReleaseSRWLockExclusive(&lock);
    const d = try Doc.open(gpa, abs_path);
    defer d.close();
    const n = d.a.FPDF_GetPageCount(d.doc);
    return if (n <= 0) error.PdfNoPages else @intCast(n);
}

/// Rende la pagina `page` (1-based). `max_bytes` e `max_side` sono i tetti di
/// pdf.zig contro un MediaBox ostile: verificati PRIMA di allocare.
pub fn render(gpa: std.mem.Allocator, abs_path: []const u8, page: usize, scale: Scale, max_side: usize, max_bytes: usize) !Raster {
    AcquireSRWLockExclusive(&lock);
    defer ReleaseSRWLockExclusive(&lock);
    const d = try Doc.open(gpa, abs_path);
    defer d.close();
    const a = d.a;
    const total: usize = @intCast(@max(0, a.FPDF_GetPageCount(d.doc)));
    if (page < 1 or page > total) return error.NoPagesRendered;
    const pg = a.FPDF_LoadPage(d.doc, @intCast(page - 1)) orelse return error.NoPagesRendered;
    defer a.FPDF_ClosePage(pg);

    // Larghezza/altezza in punti GIÀ ruotate secondo /Rotate (CropBox ∩ MediaBox),
    // e FPDF_RenderPageBitmap con rotate=0 applica la /Rotate della pagina: stesso
    // orientamento di pdftoppm e CoreGraphics.
    const ow: f64 = a.FPDF_GetPageWidthF(pg);
    const oh: f64 = a.FPDF_GetPageHeightF(pg);
    if (!(ow > 0 and oh > 0)) return error.PdfBadPage;

    const s: f64 = switch (scale) {
        .dpi => |dpi| @as(f64, @floatFromInt(dpi)) / 72.0,
        .fit => |side| @as(f64, @floatFromInt(side)) / @max(ow, oh),
    };
    // Come pdftoppm (e il ramo CoreGraphics): per eccesso, senza la riga in più
    // dovuta all'errore di arrotondamento (792 × 150/72 = 1650,000…01).
    const wf = @ceil(ow * s - 1e-6);
    const hf = @ceil(oh * s - 1e-6);
    if (!(wf >= 1 and hf >= 1) or wf > @as(f64, @floatFromInt(max_side)) or hf > @as(f64, @floatFromInt(max_side)))
        return error.PdfPageTooLarge;
    const w: usize = @intFromFloat(wf);
    const h: usize = @intFromFloat(hf);
    if (w * h * 3 > max_bytes) return error.PdfPageTooLarge;

    // PDFium disegna DIRETTAMENTE nel buffer finale (RGB, stride w*3): nessuna
    // bitmap di lavoro né conversione.
    const rgb = try gpa.alloc(u8, w * h * 3);
    errdefer gpa.free(rgb);
    const bmp = a.FPDFBitmap_CreateEx(@intCast(w), @intCast(h), FPDFBitmap_BGR, rgb.ptr, @intCast(w * 3)) orelse
        return error.PdfRenderFailed;
    defer a.FPDFBitmap_Destroy(bmp);
    // Fondo bianco: la pagina PDF è trasparente dove non disegna nulla.
    _ = a.FPDFBitmap_FillRect(bmp, 0, 0, @intCast(w), @intCast(h), 0xFFFFFFFF);
    a.FPDF_RenderPageBitmap(bmp, pg, 0, 0, @intCast(w), @intCast(h), 0, FPDF_ANNOT | FPDF_REVERSE_BYTE_ORDER);
    return .{ .width = w, .height = h, .pixels = rgb };
}
