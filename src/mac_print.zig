//! Dialogo di stampa nativo di macOS: PDFKit (`PDFDocument` →
//! `printOperationForPrintInfo:scalingMode:autoRotate:` → `runOperation`).
//!
//! Va in stampa sempre un PDF: l'originale o quello che `print_pdf` impagina da
//! testo, codice, markdown e immagini. Il pannello è quello del sistema
//! (stampante, copie, pagine, formato, anteprima) e la stampa la fa macOS.
//!
//! Tutto passa dal runtime Objective-C (`objc_msgSend`) come in
//! `zicro.window_cocoa`: niente header dei framework, la cross-build resta senza
//! SDK. PDFKit si carica con `dlopen` al primo uso: se non c'è (o le classi non
//! rispondono) il chiamante torna al pannello di conferma e a `lp`.
//!
//! Il pannello è modale per l'applicazione: `run` va chiamata dal thread
//! principale (quello del ciclo eventi di AppKit), dove arrivano tasti e clic.

const std = @import("std");
const builtin = @import("builtin");

pub const Result = enum { done, cancelled, unavailable, failed };

const id = ?*anyopaque;
const SEL = ?*anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void;

fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

fn send0(obj: id, s: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(obj, sel(s));
}

fn send1(obj: id, s: [*:0]const u8, a: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(obj, sel(s), a);
}

fn sendBool(obj: id, s: [*:0]const u8) bool {
    const f: *const fn (id, SEL) callconv(.c) bool = @ptrCast(&objc_msgSend);
    return f(obj, sel(s));
}

fn sendVoidBool(obj: id, s: [*:0]const u8, v: bool) void {
    const f: *const fn (id, SEL, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(obj, sel(s), v);
}

fn sendVoidInt(obj: id, s: [*:0]const u8, v: i64) void {
    const f: *const fn (id, SEL, i64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(obj, sel(s), v);
}

fn responds(obj: id, s: [*:0]const u8) bool {
    const f: *const fn (id, SEL, SEL) callconv(.c) bool = @ptrCast(&objc_msgSend);
    return f(obj, sel("respondsToSelector:"), sel(s));
}

fn nsString(s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(objc_getClass("NSString"), sel("stringWithUTF8String:"), s);
}

/// PDFKit sta in un framework a sé da macOS 10.13; prima era dentro Quartz.
const pdfkit_paths = [_][*:0]const u8{
    "/System/Library/Frameworks/PDFKit.framework/PDFKit",
    "/System/Library/Frameworks/Quartz.framework/Frameworks/PDFKit.framework/PDFKit",
};

var pdfkit_handle: ?*anyopaque = null;

fn loadPdfKit() bool {
    if (objc_getClass("PDFDocument") != null) return true;
    if (pdfkit_handle == null) {
        for (pdfkit_paths) |p| {
            pdfkit_handle = std.c.dlopen(p, .{ .LAZY = true, .GLOBAL = true });
            if (pdfkit_handle != null) break;
        }
    }
    return objc_getClass("PDFDocument") != null;
}

const op_sel = "printOperationForPrintInfo:scalingMode:autoRotate:";

/// PDFKit c'è e sa stampare: da chiedere prima di impaginare, così senza
/// pannello non si genera un PDF per niente. Falso prima di macOS 10.7 e con lo
/// stub di Darling (classi presenti, `initWithURL:` che dà nil).
pub fn available() bool {
    if (comptime builtin.os.tag != .macos) return false;
    if (!loadPdfKit()) return false;
    const f: *const fn (id, SEL, SEL) callconv(.c) bool = @ptrCast(&objc_msgSend);
    return f(objc_getClass("PDFDocument"), sel("instancesRespondToSelector:"), sel(op_sel));
}

// NSPrintPanelOptions
const panel_copies: i64 = 1 << 0;
const panel_page_range: i64 = 1 << 1;
const panel_paper_size: i64 = 1 << 2;
const panel_orientation: i64 = 1 << 3;
const panel_scaling: i64 = 1 << 4;
const panel_preview: i64 = 1 << 17;
/// kPDFPrintPageScaleDownToFit: le pagine A4 restano a grandezza naturale su A4
/// e si riducono solo su carta più piccola (Letter).
const scale_down_to_fit: i64 = 2;

/// Apre il pannello di stampa di macOS sul PDF in `path` e, se l'utente
/// conferma, lo stampa. Blocca finché il pannello è aperto e la stampa è stata
/// consegnata al sistema. Dal thread principale. Con `.failed` il motivo
/// (se noto) è in `why`.
pub fn run(path: [:0]const u8, title: [:0]const u8, why: *[]const u8) Result {
    if (!available()) return .unavailable;

    const pool = send0(send0(objc_getClass("NSAutoreleasePool"), "alloc"), "init");
    defer _ = send0(pool, "drain");

    const url = send1(objc_getClass("NSURL"), "fileURLWithPath:", nsString(path.ptr));
    if (url == null) return .failed;
    const doc = send1(send0(objc_getClass("PDFDocument"), "alloc"), "initWithURL:", url);
    if (doc == null) {
        why.* = "PDF non leggibile";
        return .failed;
    }
    defer _ = send0(doc, "release");
    if (sendBool(doc, "isLocked")) {
        why.* = "il PDF è protetto da password";
        return .failed;
    }

    // Le impostazioni condivise: il pannello ricorda stampante e formato scelti.
    const info = send0(objc_getClass("NSPrintInfo"), "sharedPrintInfo");
    const opFn: *const fn (id, SEL, id, i64, bool) callconv(.c) id = @ptrCast(&objc_msgSend);
    const op = opFn(doc, sel(op_sel), info, scale_down_to_fit, true);
    if (op == null) return .unavailable;

    sendVoidBool(op, "setShowsPrintPanel:", true);
    sendVoidBool(op, "setShowsProgressPanel:", true);
    if (responds(op, "setJobTitle:")) _ = send1(op, "setJobTitle:", nsString(title.ptr));
    const panel = send0(op, "printPanel");
    if (panel != null and responds(panel, "setOptions:"))
        sendVoidInt(panel, "setOptions:", panel_copies | panel_page_range | panel_paper_size | panel_orientation | panel_scaling | panel_preview);

    // Il pannello compare sopra Zuer anche se un'altra app ha preso il fuoco.
    const app = send0(objc_getClass("NSApplication"), "sharedApplication");
    if (app != null) sendVoidBool(app, "activateIgnoringOtherApps:", true);

    // NO sia per Annulla sia per un errore: AppKit non li distingue, e un
    // errore vero l'ha già mostrato il pannello del sistema.
    return if (sendBool(op, "runOperation")) .done else .cancelled;
}
