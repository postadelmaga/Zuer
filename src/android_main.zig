//! Entry point dell'APK di Zuer: NativeActivity + finestra zicro + l'interfaccia mobile
//! (`android_ui.zig`: explorer con pannello laterale e viewer a tutto schermo).
//!
//! Su Android il ciclo di vita è rovesciato — è il framework a possedere il loop e a
//! consegnare la surface in modo asincrono — quindi l'ingresso non è `main` ma
//! `android_main(*android_app)`, chiamato da `native_app_glue` sul thread nativo. Qui si
//! crea la `zicro.window.Window` (che su questo target risolve al backend NDK: surface
//! ANativeWindow + touch attraverso il recognizer condiviso), la si aggancia alla glue e
//! le si passa il loop.
//!
//! Il poco Java necessario (fullscreen immersivo, permesso di accesso ai file) sta in
//! `android_jni.zig` e viene chiamato da qui: la UI non sa che Android esiste, disegna su
//! un canvas e riceve tocchi — esattamente come sul desktop.

const std = @import("std");
const zicro = @import("zicro");
const paint = zicro.paint;
const android = zicro.android;
const jni = @import("android_jni.zig");
const ui = @import("android_ui.zig");

/// Codice del tasto "indietro" di Android (AKEYCODE_BACK), l'unico tasto hardware che
/// conta su un telefono: risale di un livello, e alla radice lascia uscire l'app.
const KEYCODE_BACK: u32 = 4;

extern fn __android_log_print(prio: c_int, tag: [*:0]const u8, fmt: [*:0]const u8, ...) c_int;
/// Traccia dell'avvio: su Android un blocco all'avvio non lascia altro che uno schermo nero
/// (nessun terminale, nessuno stack), quindi i passi di `android_main` si annunciano.
fn log(msg: [*:0]const u8) void {
    _ = __android_log_print(4, "zuer", "%s", msg);
}

const App = struct {
    ui: ui.Ui,
    win: *zicro.window.Window,
    activity: *anyopaque,
    /// Riprova periodica del permesso: l'utente lo concede in una schermata di SISTEMA e
    /// torna indietro senza che ci arrivi alcun evento — ce ne accorgiamo ricontrollando.
    perm_poll: u32 = 0,
    /// Il fullscreen immersivo va riaffermato: alcune interazioni (tastiera, tendina) lo
    /// annullano, quindi lo si ripropone a cadenza bassa invece di fidarsi di una volta sola.
    fs_poll: u32 = 0,
    quit: bool = false,
};

var app_state: ?*App = null;

fn onDraw(canvas: *paint.Canvas, content: zicro.window.Rect, user: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(user orelse return));

    // Permesso: se manca, la UI mostra la scheda; quando l'utente lo concede altrove,
    // ce ne accorgiamo qui (ogni ~mezzo secondo) e ricarichiamo la cartella.
    self.perm_poll +%= 1;
    if (self.ui.need_perm and self.perm_poll % 30 == 0) {
        if (jni.hasAllFilesAccess(self.activity)) {
            self.ui.need_perm = false;
            self.ui.navigate("/sdcard");
        }
    }
    if (self.ui.perm_requested) {
        self.ui.perm_requested = false;
        jni.requestAllFilesAccess(self.activity);
    }

    self.fs_poll +%= 1;
    if (self.fs_poll % 120 == 0) jni.goFullscreen(self.activity);

    // La scala si legge QUI, non alla creazione della Ui: al momento di `init` la surface
    // non esiste ancora (Android la consegna in modo asincrono), quindi `scaleFactor`
    // riporterebbe la densità grezza senza la correzione per la superficie ridotta — e la
    // UI verrebbe disegnata al doppio della misura giusta.
    self.ui.scale = @max(1.0, self.win.scaleFactor());

    self.ui.draw(canvas, @intCast(content.w), @intCast(content.h));

    // Un altro frame SOLO se qualcosa si sta muovendo (animazione, inerzia, anteprime in
    // decodifica) o se il permesso è ancora da concedere (dobbiamo ricontrollarlo). A
    // schermo fermo il loop si zittisce: zero CPU, zero batteria, e i tocchi non devono
    // contendersi il core con un rasterizzatore che ridisegna lo stesso identico frame.
    if (self.ui.animating or self.ui.need_perm) self.win.requestRedraw();
}

fn onMouse(win: *zicro.window.Window, event: zicro.window.MouseEvent, user: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(user orelse return));
    const w: f32 = @floatFromInt(win.width);
    const h: f32 = @floatFromInt(win.height);
    switch (event.kind) {
        .press => self.ui.onPointerDown(event.x, event.y, w, h),
        .motion => self.ui.onPointerMove(event.x, event.y, w, h),
        .release => self.ui.onPointerUp(event.x, event.y, w, h),
        else => {},
    }
}

fn onKey(win: *zicro.window.Window, key: u32, state: u32, user: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(user orelse return));
    if (key != KEYCODE_BACK or state != 1) return;
    // `onBack` consuma un livello (foglio → pannello → viewer → cartella superiore); se non
    // c'era niente da chiudere eravamo alla radice: si esce, come vuole Android.
    if (!self.ui.onBack()) win.requestClose();
}

/// Ingresso nativo chiamato da native_app_glue sul suo thread. `export` (non `pub`): la
/// glue lo risolve per nome nel .so caricato da NativeActivity.
export fn android_main(app: *android.android_app) void {
    log("android_main: entrata");
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();

    // Il backend NDK non usa `io` per la finestra (il loop è quello del framework), ma la
    // UI sì: legge cartelle e file attraverso std.Io.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const activity: *anyopaque = app.activity orelse return;

    const win = zicro.window.Window.init(gpa, io, .{
        .title = "Zuer",
        .on_draw = onDraw,
        .on_mouse = onMouse,
        .on_key = onKey,
        // La superficie è rasterizzata dalla CPU: a 1080×2400 sarebbero 2,6 milioni di
        // pixel per frame. Limitando il lato lungo a 1280 il costo scende a ~⅓ e il
        // display riscala in hardware, gratis — su un telefono in mano la differenza non
        // si vede, quella tra 12 fps e 60 fps sì. `scaleFactor` tiene conto della
        // riduzione, quindi la UI resta della stessa misura fisica.
        .surface_max_dim = 1280,
    }) catch return;
    defer win.deinit();
    log("finestra creata");
    win.attach(app);

    // Fullscreen subito: la prima cosa che l'utente vede è già a tutto schermo, senza il
    // salto della status bar che sparisce dopo un frame.
    jni.goFullscreen(activity);
    log("fullscreen ok");

    const font = win.textFont() catch return;

    var state = App{
        .ui = ui.Ui.init(gpa, io, font, win.scaleFactor()),
        .win = win,
        .activity = activity,
    };
    state.ui.activity = activity;
    state.ui.start(); // thread delle anteprime (decodifica fuori dal frame)
    defer state.ui.deinit();
    app_state = &state;

    // Senza "accesso a tutti i file" (Android 11+) una cartella condivisa non si apre
    // nemmeno in lettura: si parte dalla scheda che lo spiega, non da una griglia vuota.
    state.ui.need_perm = !jni.hasAllFilesAccess(activity);
    log("permesso letto");

    // Aperti da un'altra app ("apri con Zuer") si parte da lì: se è una cartella la si
    // sfoglia, se è un file lo si guarda. Dall'icona, invece, dalla memoria interna.
    if (jni.intentPath(activity, gpa)) |p| {
        defer gpa.free(p);
        state.ui.openPath(p);
    } else state.ui.navigate("/sdcard");
    log("cartella letta");

    // La UI è il `user` di ogni callback: la finestra è già creata, quindi si aggiorna qui
    // (le Options sono per valore).
    win.opts.user = &state;

    log("loop");
    win.run() catch {};
}
