//! L'interfaccia mobile di Zuer: **explorer** (griglia di file con pannello laterale) e
//! **viewer** (contenuto a tutto schermo). Due modalità, una sola macchina di stato.
//!
//! Le regole che la guidano — mobile, non un desktop rimpicciolito:
//!   * **Il pollice comanda.** Nessun bersaglio sotto i 44 dp, scroll con inerzia, il
//!     pannello laterale si apre col trascinamento dal bordo (dove il pollice arriva).
//!   * **Un livello alla volta.** Explorer → viewer è un passaggio secco a tutto schermo;
//!     "indietro" (tasto di sistema o gesto) risale sempre di un livello: viewer → explorer
//!     → cartella superiore. Nessuna gerarchia di finestre da ricordare.
//!   * **Il contenuto è la UI.** Cromo scuro e sottile, anteprime vere (non icone
//!     generiche) dove il file le può dare: è la miniatura a dire cos'è il file.
//!
//! Il disegno è tutto sul canvas CPU di zicro (`paint.Canvas`), lo stesso del desktop:
//! nessuna View Android, nessun layout XML. Le anteprime immagine passano da stb_image,
//! decodificate poche per frame (`thumb_budget`) così lo scroll non singhiozza mai.

const std = @import("std");
const zicro = @import("zicro");
const dec = @import("android_decode.zig");
const jni = @import("android_jni.zig");
const paint = zicro.paint;
const text = zicro.text;
const Color = paint.Color;

// stb_image (vendor/stb, compilato nella .so): decodifica PNG/JPEG/GIF/BMP dai byte.
extern fn stbi_load_from_memory(buf: [*]const u8, len: c_int, x: *c_int, y: *c_int, ch: *c_int, want: c_int) ?[*]u8;
extern fn stbi_image_free(p: ?*anyopaque) void;
extern fn __android_log_print(prio: c_int, tag: [*:0]const u8, fmt: [*:0]const u8, ...) c_int;

fn nowNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
}

/// Orologio monotono in millisecondi (std.time non espone più i timestamp; la syscall sì).
/// Serve solo alla pressione prolungata.
fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// ── Palette ────────────────────────────────────────────────────────────────────
// I colori non sono più scritti qui: vengono dai token di `zicro.theme` (ruoli di
// superficie alla Material 3, accenti di sistema alla iOS). Gli alias sotto tengono corto
// il codice di disegno senza reintrodurre numeri magici — cambiare `t` cambia tutta l'app.
const tk = zicro.theme.dark;
const alphaOf = zicro.theme.alpha;
const bg_top = tk.surface;
const bg_bot = tk.surface_tint;
const surface = tk.surface_1; // tessere, barre
const surface_hi = tk.surface_3; // premuto
const accent = tk.primary;
const fg = tk.on_surface;
const fg_dim = tk.on_surface_var;
const scrim = tk.scrim;

/// Famiglia del file, dedotta dall'estensione: decide icona, colore e cosa sa fare il
/// viewer. Le famiglie che su Android non hanno ancora un decoder (M4) restano dichiarate
/// — il viewer le mostra come scheda informativa invece di fingere un'anteprima.
pub const Kind = enum {
    folder,
    image,
    text,
    audio,
    video,
    mesh,
    archive,
    doc,
    other,

    pub fn of(name: []const u8) Kind {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .other;
        var buf: [16]u8 = undefined;
        const raw = name[dot + 1 ..];
        if (raw.len == 0 or raw.len > buf.len) return .other;
        const ext = std.ascii.lowerString(buf[0..raw.len], raw);
        const groups = .{
            .{ Kind.image, [_][]const u8{ "png", "jpg", "jpeg", "gif", "bmp", "tga", "webp", "tif", "tiff", "ico", "svg", "psd", "hdr", "pnm", "ppm", "pgm", "avif" } },
            .{ Kind.text, [_][]const u8{ "txt", "md", "markdown", "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "csv", "tsv", "log", "xml", "html", "css", "js", "ts", "py", "zig", "c", "h", "cpp", "rs", "go", "java", "kt", "sh", "swift", "lua", "sql", "rb", "php" } },
            .{ Kind.audio, [_][]const u8{ "mp3", "wav", "flac", "ogg", "oga", "opus", "m4a", "mid", "midi" } },
            .{ Kind.video, [_][]const u8{ "mp4", "m4v", "mkv", "webm", "avi", "mov", "ogv" } },
            .{ Kind.mesh, [_][]const u8{ "obj", "stl", "glb", "gltf" } },
            .{ Kind.archive, [_][]const u8{ "zip", "tar", "gz", "tgz", "jar", "apk", "cbz", "epub", "7z", "rar" } },
            .{ Kind.doc, [_][]const u8{ "pdf", "xlsx", "docx", "pptx", "odt", "ods" } },
        };
        inline for (groups) |grp| {
            for (grp[1]) |e| if (std.mem.eql(u8, ext, e)) return grp[0];
        }
        return .other;
    }

    /// Etichetta breve sul badge quando non c'è un'anteprima da mostrare.
    fn badge(self: Kind) []const u8 {
        return switch (self) {
            .folder => "DIR",
            .image => "IMG",
            .text => "TXT",
            .audio => "AUD",
            .video => "VID",
            .mesh => "3D",
            .archive => "ZIP",
            .doc => "DOC",
            .other => "•",
        };
    }

    /// L'accento della famiglia, dalla palette di sistema: un colore per *categoria*, così
    /// una cartella di foto si legge a colpo d'occhio senza leggere una sola estensione.
    fn color(self: Kind) Color {
        const a = tk.accent;
        return switch (self) {
            .folder => a.blue,
            .image => a.green,
            .text => a.gray,
            .audio => a.purple,
            .video => a.pink,
            .mesh => a.orange,
            .archive => a.yellow,
            .doc => a.teal,
            .other => a.gray,
        };
    }
};

const Entry = struct {
    name: []u8, // posseduto
    kind: Kind,
    size: u64,
    /// Anteprima RGBA (thumb_px × h), null finché non decodificata. `tried` evita di
    /// ritentare all'infinito un'immagine che stb non sa leggere (es. SVG).
    thumb: ?[]u8 = null,
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,
    tried: bool = false,
};

const Shortcut = struct { label: []const u8, path: []const u8 };

/// Le scorciatoie del pannello laterale: le cartelle che su un telefono contano davvero.
const shortcuts = [_]Shortcut{
    .{ .label = "Memoria interna", .path = "/sdcard" },
    .{ .label = "Download", .path = "/sdcard/Download" },
    .{ .label = "Immagini", .path = "/sdcard/Pictures" },
    .{ .label = "Fotocamera", .path = "/sdcard/DCIM" },
    .{ .label = "Documenti", .path = "/sdcard/Documents" },
    .{ .label = "Musica", .path = "/sdcard/Music" },
    .{ .label = "Video", .path = "/sdcard/Movies" },
    .{ .label = "Radice", .path = "/" },
};

const Mode = enum { explorer, viewer };

/// Azione scelta nel foglio che appare toccando una cartella (punto 3 del brief:
/// una cartella si può *sfogliare* o *guardare*).
const SheetAction = enum { open, preview };

pub const Ui = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    font: *text.Font,
    scale: f32 = 2.75,
    /// L'ANativeActivity, che serve a chiedere ad Android le anteprime che i decoder in Zig
    /// non coprono (copertine, fotogrammi, PDF). Null = nessuna chiamata JNI: la UI resta
    /// compilabile e testabile senza un telefono sotto.
    activity: ?*anyopaque = null,

    mode: Mode = .explorer,
    cwd: std.ArrayListUnmanaged(u8) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Messaggio al posto della griglia (cartella vuota, permesso mancante, errore).
    notice: ?[]const u8 = null,
    /// True quando manca l'accesso a tutti i file: la griglia lascia il posto a una
    /// scheda che spiega e offre il pulsante per la schermata di sistema.
    need_perm: bool = false,
    /// Alzato dal tap sulla scheda del permesso; `android_main` lo osserva e apre la
    /// schermata di sistema — la chiamata JNI non deve entrare nella UI.
    perm_requested: bool = false,

    scroll: f32 = 0,
    scroll_v: f32 = 0, // inerzia (px/frame)
    content_h: f32 = 0,

    drawer: f32 = 0, // 0 chiuso … 1 aperto (animato)
    drawer_open: bool = false,
    sheet: ?usize = null, // indice della cartella in attesa di scelta
    sheet_a: f32 = 0, // animazione del foglio

    // Viewer
    view_idx: usize = 0,
    view_img: ?[]u8 = null,
    view_w: u32 = 0,
    view_h: u32 = 0,
    view_text: ?[]u8 = null,
    /// Il risultato dei decoder Zig puri (CSV, listato di un archivio, markdown, mesh):
    /// la UI lo possiede e lo libera con `Decoded.deinit`. Le immagini restano sul percorso
    /// stb dedicato (RGBA diretto, niente conversione).
    view_doc: ?dec.Decoded = null,
    view_scroll: f32 = 0,
    chrome: f32 = 1, // alpha della barra col nome (si dissolve da sola)

    // Tocco
    down: bool = false,
    down_x: f32 = 0,
    down_y: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    moved: bool = false,
    edge_drag: bool = false, // trascinamento dal bordo sinistro → pannello
    press_idx: ?usize = null, // tessera premuta (feedback visivo)
    /// Istante della pressione (ms) e "il lungo ha già sparato": una pressione prolungata su
    /// una cartella apre le opzioni, il tap secco ci entra dentro — la convenzione di
    /// qualunque file manager, dove l'azione frequente non deve costare una scelta.
    down_ms: i64 = 0,
    long_fired: bool = false,

    /// Alzato da `draw` quando qualcosa è ancora in movimento (animazione, inerzia,
    /// anteprime da decodificare): il chiamante chiede allora un altro frame. Quando torna
    /// false il loop si ferma e l'app smette di consumare CPU — a schermo fermo, zero lavoro.
    animating: bool = false,
    /// Nanosecondi spesi nella decodifica anteprime nel frame corrente (solo profilo).
    thumb_ns: i64 = 0,
    prof_frames: u32 = 0,
    t_fill: i64 = 0,
    t_blit: i64 = 0,
    t_text: i64 = 0,

    /// Generazione della cartella: sale a ogni `navigate`. Una miniatura che torna dal thread
    /// con una generazione vecchia è roba di una cartella che l'utente ha già lasciato — si
    /// butta, invece di finire (magari all'indice giusto) sulla tessera sbagliata.
    gen: u32 = 0,
    worker: Worker = .{},
    worker_thread: ?std.Thread = null,

    const thumb_px: u32 = 256;

    const Job = struct { gen: u32, idx: usize, kind: Kind, path: []u8 };
    const Res = struct { gen: u32, idx: usize, pixels: ?[]u8 };

    /// Il canale fra la UI e il thread delle anteprime: un lavoro in volo e un risultato da
    /// ritirare, sotto lo stesso lock. Non serve una coda — la coda è ciò che si vede: se
    /// l'utente scorre via, le tessere che non guarda più semplicemente non vengono ordinate.
    const Worker = struct {
        // In Zig 0.16 mutex e condition vivono in `std.Io` e prendono l'io del chiamante:
        // la sincronizzazione è parte dell'interfaccia di I/O, non un primitivo a sé.
        mu: std.Io.Mutex = .init,
        cv: std.Io.Condition = .init,
        job: ?Job = null,
        done: ?Res = null,
        quit: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, font: *text.Font, scale: f32) Ui {
        return .{ .gpa = gpa, .io = io, .font = font, .scale = @max(1.0, scale) };
    }

    /// Avvia il thread delle anteprime. Separato da `init` perché il thread prende un
    /// puntatore a `self`: la Ui deve essere già al suo posto definitivo, non ancora un
    /// valore di ritorno che il chiamante copierà altrove.
    pub fn start(self: *Ui) void {
        self.worker_thread = std.Thread.spawn(.{}, thumbWorker, .{self}) catch null;
    }

    pub fn deinit(self: *Ui) void {
        if (self.worker_thread) |t| {
            self.worker.mu.lockUncancelable(self.io);
            self.worker.quit = true;
            self.worker.mu.unlock(self.io);
            self.worker.cv.signal(self.io);
            t.join();
        }
        self.worker.mu.lockUncancelable(self.io);
        if (self.worker.job) |j| self.gpa.free(j.path);
        if (self.worker.done) |r| if (r.pixels) |p| self.gpa.free(p);
        self.worker.mu.unlock(self.io);

        self.clearEntries();
        self.entries.deinit(self.gpa);
        self.cwd.deinit(self.gpa);
        self.closeFile();
    }

    fn clearEntries(self: *Ui) void {
        for (self.entries.items) |*e| {
            self.gpa.free(e.name);
            if (e.thumb) |t| self.gpa.free(t);
        }
        self.entries.clearRetainingCapacity();
    }

    fn closeFile(self: *Ui) void {
        if (self.view_img) |p| self.gpa.free(p);
        self.view_img = null;
        if (self.view_text) |t| self.gpa.free(t);
        self.view_text = null;
        if (self.view_doc) |*d| d.deinit(self.gpa);
        self.view_doc = null;
    }

    // ── Navigazione ────────────────────────────────────────────────────────────

    /// Entra in `path`: rilegge la cartella, azzera scroll e anteprime. Le voci sono
    /// ordinate cartelle-prima-e-poi-nome, l'ordine che un file manager deve avere.
    pub fn navigate(self: *Ui, path: []const u8) void {
        self.gen +%= 1; // le anteprime ancora in volo per la cartella precedente non valgono più
        self.cwd.clearRetainingCapacity();
        self.cwd.appendSlice(self.gpa, path) catch return;
        self.clearEntries();
        self.scroll = 0;
        self.scroll_v = 0;
        self.notice = null;

        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch {
            // Su Android 11+ una cartella condivisa senza "accesso a tutti i file" non si
            // apre nemmeno: è il caso più probabile, e va spiegato invece di mostrare vuoto.
            self.notice = if (self.need_perm) "Serve l'accesso ai file" else "Cartella non accessibile";
            return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |ent| {
            if (ent.name.len == 0 or ent.name[0] == '.') continue; // niente file nascosti
            const kind: Kind = if (ent.kind == .directory) .folder else Kind.of(ent.name);
            const name = self.gpa.dupe(u8, ent.name) catch continue;
            var size: u64 = 0;
            if (kind != .folder) {
                if (dir.statFile(self.io, ent.name, .{})) |st| size = st.size else |_| {}
            }
            self.entries.append(self.gpa, .{ .name = name, .kind = kind, .size = size }) catch {
                self.gpa.free(name);
                continue;
            };
        }
        std.mem.sort(Entry, self.entries.items, {}, lessThan);
        if (self.entries.items.len == 0 and self.notice == null) self.notice = "Cartella vuota";
    }

    /// Apre un percorso qualunque: se è una cartella la si sfoglia, se è un file lo si guarda
    /// a tutto schermo — con la sua cartella già caricata dietro, così "indietro" porta dove
    /// l'utente si aspetta (la cartella del file) e lo swipe scorre i file vicini.
    pub fn openPath(self: *Ui, path: []const u8) void {
        const is_dir = if (std.Io.Dir.cwd().statFile(self.io, path, .{})) |st| st.kind == .directory else |_| false;
        if (is_dir) return self.navigate(path);

        const parent = std.fs.path.dirname(path) orelse return self.navigate("/sdcard");
        self.navigate(parent);
        const name = std.fs.path.basename(path);
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return self.openFile(i);
        }
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        const a_dir = a.kind == .folder;
        const b_dir = b.kind == .folder;
        if (a_dir != b_dir) return a_dir; // cartelle in cima
        return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
    }

    /// Risale alla cartella superiore. False se siamo già alla radice (il chiamante allora
    /// lascia che "indietro" chiuda l'app, come si aspetta chiunque su Android).
    pub fn goUp(self: *Ui) bool {
        const cur = self.cwd.items;
        if (cur.len <= 1) return false;
        const parent = std.fs.path.dirname(cur) orelse return false;
        var buf: [512]u8 = undefined;
        if (parent.len >= buf.len) return false;
        @memcpy(buf[0..parent.len], parent);
        self.navigate(buf[0..parent.len]);
        return true;
    }

    /// Percorso completo di una voce, in un buffer del chiamante.
    fn pathOf(self: *Ui, idx: usize, buf: []u8) ?[]const u8 {
        const e = self.entries.items[idx];
        const sep: []const u8 = if (std.mem.endsWith(u8, self.cwd.items, "/")) "" else "/";
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ self.cwd.items, sep, e.name }) catch null;
    }

    /// Apre il file `idx` nel viewer a tutto schermo.
    fn openFile(self: *Ui, idx: usize) void {
        self.closeFile();
        self.mode = .viewer;
        self.view_idx = idx;
        self.view_scroll = 0;
        self.chrome = 1;

        var buf: [512]u8 = undefined;
        const path = self.pathOf(idx, &buf) orelse return;
        const e = self.entries.items[idx];
        switch (e.kind) {
            // Tutto ciò che si guarda come un'immagine — una foto, la copertina di un MP3, il
            // fotogramma di un video, la prima pagina di un PDF — passa da qui: un percorso
            // solo, e la sorgente (stb o il framework) la sceglie `rasterize`.
            .image, .audio, .video, .doc => {
                const img = self.rasterize(path, e.kind, 0) orelse return;
                self.view_img = img.pixels;
                self.view_w = img.w;
                self.view_h = img.h;
            },
            // Tutto il resto passa dai decoder veri (gli stessi del desktop, qui linkati
            // nella .so): testo, markdown, CSV/TSV, il listato di uno ZIP o di un TAR, le
            // statistiche di una mesh. Se per quel tipo non c'è decoder — audio, video, PDF,
            // Office — `decode` torna null e la UI mostra la scheda informativa, che dice
            // cosa c'è invece di fingere un'anteprima.
            else => {
                var d = dec.decode(self.io, self.gpa, path) orelse return;
                switch (d) {
                    // Un decoder che ha prodotto testo alimenta il visualizzatore di testo
                    // già esistente: nessun secondo percorso da mantenere.
                    .text => |txt| {
                        self.view_text = self.gpa.dupe(u8, txt) catch null;
                        d.deinit(self.gpa);
                    },
                    .markdown => |md| {
                        self.view_text = self.gpa.dupe(u8, md.content) catch null;
                        d.deinit(self.gpa);
                    },
                    else => self.view_doc = d, // csv (anche i listati d'archivio), mesh, errori
                }
            },
        }
    }

    /// File successivo/precedente nella cartella, saltando le sottocartelle: nel viewer si
    /// scorre la cartella con uno swipe orizzontale, come le frecce sul desktop.
    fn viewStep(self: *Ui, dir: i32) void {
        const n = self.entries.items.len;
        if (n == 0) return;
        var i: i64 = @intCast(self.view_idx);
        var guard: usize = 0;
        while (guard < n) : (guard += 1) {
            i += dir;
            if (i < 0 or i >= @as(i64, @intCast(n))) return; // ai bordi non si avvolge
            if (self.entries.items[@intCast(i)].kind != .folder) {
                self.openFile(@intCast(i));
                return;
            }
        }
    }

    // ── Anteprime ──────────────────────────────────────────────────────────────

    const Raster = struct { pixels: []u8, w: u32, h: u32 };

    /// Da un file a dei pixel RGBA, chiunque li sappia produrre. L'ordine non è casuale:
    ///
    ///   * **stb_image** per le immagini che conosce — è dentro la .so, non costa una
    ///     chiamata JNI e non alloca nulla in Java;
    ///   * **BitmapFactory** per le altre (HEIC, AVIF, WEBP recenti): il telefono le
    ///     decodifica in hardware, noi ci porteremmo dietro megabyte di codec per fare peggio;
    ///   * **MediaMetadataRetriever** per la copertina di un audio (i byte del tag, poi stb)
    ///     e per il fotogramma di apertura di un video;
    ///   * **PdfRenderer** per la prima pagina di un PDF.
    ///
    /// `max_px` limita il lato lungo (0 = nessun limite): per una miniatura non ha senso
    /// rasterizzare un A4 a piena risoluzione.
    fn rasterize(self: *Ui, path: []const u8, kind: Kind, max_px: u32) ?Raster {
        const activity = self.activity;
        switch (kind) {
            .image => {
                if (self.rasterizeStb(path)) |r| return r;
                if (activity) |a| if (jni.decodeImageFile(a, self.gpa, path)) |img|
                    return .{ .pixels = img.pixels, .w = img.w, .h = img.h };
                return null;
            },
            .audio => {
                const a = activity orelse return null;
                const art = jni.embeddedArt(a, self.gpa, path) orelse return null;
                defer self.gpa.free(art);
                return self.rasterizeBytes(art);
            },
            .video => {
                const a = activity orelse return null;
                const img = jni.videoFrame(a, self.gpa, path) orelse return null;
                return .{ .pixels = img.pixels, .w = img.w, .h = img.h };
            },
            .doc => {
                const a = activity orelse return null;
                const img = jni.pdfPage(a, self.gpa, path, if (max_px == 0) 2048 else max_px) orelse return null;
                return .{ .pixels = img.pixels, .w = img.w, .h = img.h };
            },
            else => return null,
        }
    }

    fn rasterizeStb(self: *Ui, path: []const u8) ?Raster {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, std.Io.Limit.limited(64 << 20)) catch return null;
        defer self.gpa.free(bytes);
        return self.rasterizeBytes(bytes);
    }

    fn rasterizeBytes(self: *Ui, bytes: []const u8) ?Raster {
        var w: c_int = 0;
        var h: c_int = 0;
        var ch: c_int = 0;
        const px = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &ch, 4) orelse return null;
        defer stbi_image_free(px);
        if (w <= 0 or h <= 0) return null;
        const n: usize = @intCast(w * h * 4);
        const copy = self.gpa.alloc(u8, n) catch return null;
        @memcpy(copy, px[0..n]);
        return .{ .pixels = copy, .w = @intCast(w), .h = @intCast(h) };
    }

    /// Ritira la miniatura pronta (se c'è) e ne ordina un'altra fra le tessere VISIBILI.
    ///
    /// La decodifica NON avviene qui. Estrarre il fotogramma di un video o rasterizzare una
    /// pagina PDF costa centinaia di millisecondi: farlo dentro il frame significa un
    /// fotogramma perso ogni volta che una tessera nuova entra in vista — esattamente lo
    /// scatto che si vede scorrendo. Il lavoro sta su un thread; questo frame si limita a
    /// prendere quel che è pronto e a lasciare un ordine per il prossimo.
    fn pumpThumbs(self: *Ui, first: usize, last: usize) void {
        const t_in = nowNs();
        defer self.thumb_ns += nowNs() - t_in;

        self.worker.mu.lockUncancelable(self.io);
        // 1. Ritiro: una miniatura pronta appartiene a questa cartella solo se la generazione
        //    combacia — altrimenti l'utente ha già navigato altrove e il risultato si butta.
        if (self.worker.done) |res| {
            self.worker.done = null;
            if (res.gen == self.gen and res.idx < self.entries.items.len and res.pixels != null) {
                const e = &self.entries.items[res.idx];
                if (e.thumb == null) {
                    e.thumb = res.pixels;
                    e.thumb_w = thumb_px;
                    e.thumb_h = thumb_px;
                } else self.gpa.free(res.pixels.?);
            } else if (res.pixels) |p| self.gpa.free(p);
            self.animating = true; // un altro frame: la griglia si sta popolando
        }

        // 2. Ordine: la prima tessera visibile che può avere un'anteprima e non ce l'ha.
        if (self.worker.job == null) {
            var i = first;
            while (i <= last and i < self.entries.items.len) : (i += 1) {
                const e = &self.entries.items[i];
                switch (e.kind) {
                    .image, .audio, .video, .doc => {},
                    else => continue,
                }
                // `tried`: un file senza copertina (o che il sistema non sa aprire) non deve
                // essere ritentato a ogni frame — costerebbe una chiamata JNI per sempre.
                if (e.tried or e.thumb != null) continue;
                var buf: [512]u8 = undefined;
                const path = self.pathOf(i, &buf) orelse continue;
                const owned = self.gpa.dupe(u8, path) catch continue;
                e.tried = true;
                self.worker.job = .{ .gen = self.gen, .idx = i, .kind = e.kind, .path = owned };
                self.animating = true;
                break;
            }
        }
        const busy = self.worker.job != null;
        self.worker.mu.unlock(self.io);
        self.worker.cv.signal(self.io);
        // Finché c'è un lavoro in volo il loop resta vivo: è l'unico modo che ha il thread
        // della UI di accorgersi che il risultato è arrivato (non lo sveglia nessuno, e a
        // schermo fermo si fermerebbe). Un frame ora costa pochi millisecondi: si può.
        if (busy) self.animating = true;
    }

    /// Il thread delle anteprime: dorme finché non c'è un lavoro, decodifica, deposita.
    /// Uno solo, e un lavoro alla volta: la coda naturale è ciò che si vede: quando l'utente
    /// scorre via, le tessere non più visibili semplicemente non vengono più ordinate.
    fn thumbWorker(self: *Ui) void {
        // Questo thread chiama JNI (copertine, fotogrammi, PDF) e quindi si aggancia alla JVM:
        // deve sganciarsi prima di morire, o la ART abbatte il processo.
        defer if (self.activity) |a| jni.detach(a);
        while (true) {
            self.worker.mu.lockUncancelable(self.io);
            while (self.worker.job == null and !self.worker.quit) self.worker.cv.waitUncancelable(self.io, &self.worker.mu);
            if (self.worker.quit) {
                self.worker.mu.unlock(self.io);
                return;
            }
            const job = self.worker.job.?;
            self.worker.mu.unlock(self.io);

            // Fuori dal lock: qui si sta anche mezzo secondo, e il thread della UI non deve
            // aspettare un fotogramma video per disegnare il suo.
            var pixels: ?[]u8 = null;
            if (self.rasterize(job.path, job.kind, 512)) |r| {
                defer self.gpa.free(r.pixels);
                pixels = self.scaleThumb(r.pixels.ptr, r.w, r.h);
            }
            self.gpa.free(job.path);

            self.worker.mu.lockUncancelable(self.io);
            self.worker.job = null;
            // Se la UI non ha ancora ritirato il risultato precedente, quello nuovo lo
            // sostituisce (era comunque per una tessera che ora è pronta o sparita).
            if (self.worker.done) |old| if (old.pixels) |p| self.gpa.free(p);
            self.worker.done = .{ .gen = job.gen, .idx = job.idx, .pixels = pixels };
            self.worker.mu.unlock(self.io);
        }
    }

    /// Riduce l'immagine a una miniatura quadrata `thumb_px`, RITAGLIANDO al centro: in una
    /// griglia le tessere devono avere tutte la stessa forma, e una foto schiacciata per
    /// entrare nel riquadro si nota subito. Campionamento nearest: è una miniatura.
    fn scaleThumb(self: *Ui, src: [*]const u8, sw: u32, sh: u32) ?[]u8 {
        if (sw == 0 or sh == 0) return null;
        const side = @min(sw, sh); // quadrato centrale della sorgente
        const ox = (sw - side) / 2;
        const oy = (sh - side) / 2;
        const t = thumb_px;
        const dst = self.gpa.alloc(u8, t * t * 4) catch return null;
        var y: u32 = 0;
        while (y < t) : (y += 1) {
            const sy = oy + y * side / t;
            var x: u32 = 0;
            while (x < t) : (x += 1) {
                const sx = ox + x * side / t;
                const s = (@as(usize, sy) * sw + sx) * 4;
                const d = (@as(usize, y) * t + x) * 4;
                @memcpy(dst[d .. d + 4], src[s .. s + 4]);
            }
        }
        return dst;
    }

    // ── Geometria ──────────────────────────────────────────────────────────────

    /// Fascia intoccabile in cima: a tutto schermo la finestra arriva sotto la status bar e
    /// sotto la fotocamera a foro, che su questo telefono sta in alto a sinistra — proprio
    /// dove finirebbe il ☰. Niente ci va disegnato sopra.
    fn safeTop(self: *const Ui) f32 {
        return 28 * self.scale;
    }
    fn topBarH(self: *const Ui) f32 {
        return self.safeTop() + 56 * self.scale;
    }
    fn drawerW(self: *const Ui, w: f32) f32 {
        return @min(300 * self.scale, w * 0.8);
    }
    /// Colonne: tessere di ~108 dp → tre su un telefono in verticale, di più su schermi
    /// larghi. Tre è il passo giusto: la miniatura resta leggibile e lo sguardo prende
    /// l'intera cartella in un colpo, senza il "muro di icone" delle griglie fitte.
    fn cols(self: *const Ui, w: f32) u32 {
        return @max(2, @min(6, @as(u32, @intFromFloat(w / (108 * self.scale)))));
    }
    const Grid = struct { cols: u32, tile: f32, gap: f32, x0: f32, y0: f32, cell_h: f32 };
    fn grid(self: *const Ui, w: f32) Grid {
        const n = self.cols(w);
        const gap = 12 * self.scale;
        const pad = 14 * self.scale;
        const tile = (w - pad * 2 - gap * @as(f32, @floatFromInt(n - 1))) / @as(f32, @floatFromInt(n));
        return .{
            .cols = n,
            .tile = tile,
            .gap = gap,
            .x0 = pad,
            .y0 = self.topBarH() + 8 * self.scale,
            .cell_h = tile + 30 * self.scale, // tessera + riga del nome
        };
    }

    // ── Input ──────────────────────────────────────────────────────────────────

    pub fn onPointerDown(self: *Ui, x: f32, y: f32, w: f32, h: f32) void {
        _ = h;
        self.down = true;
        self.moved = false;
        self.down_x = x;
        self.down_y = y;
        self.last_x = x;
        self.last_y = y;
        self.scroll_v = 0;
        self.down_ms = nowMs();
        self.long_fired = false;
        self.edge_drag = self.mode == .explorer and !self.drawer_open and x < 28 * self.scale;
        self.press_idx = if (self.mode == .explorer and self.sheet == null and !self.drawer_open)
            self.hitTile(x, y, w)
        else
            null;
    }

    /// Durata della pressione prolungata. 420 ms: abbastanza da non scattare per sbaglio
    /// durante uno scroll, abbastanza poco da non far dubitare che sia successo qualcosa.
    const long_press_ms: i64 = 420;

    /// Chiamata a ogni frame: fa scattare la pressione prolungata sulle CARTELLE (apre il
    /// foglio delle opzioni) senza bisogno di timer o thread — è il frame stesso l'orologio.
    fn pumpLongPress(self: *Ui) void {
        if (!self.down or self.moved or self.long_fired or self.mode != .explorer) return;
        const idx = self.press_idx orelse return;
        if (self.entries.items[idx].kind != .folder) return;
        self.animating = true; // servono frame finché il timer non matura
        if (nowMs() - self.down_ms < long_press_ms) return;
        self.long_fired = true;
        self.sheet = idx;
        self.press_idx = null;
    }

    pub fn onPointerMove(self: *Ui, x: f32, y: f32, w: f32, h: f32) void {
        _ = h;
        if (!self.down) return;
        const dx = x - self.last_x;
        const dy = y - self.last_y;
        if (@abs(x - self.down_x) > 8 * self.scale or @abs(y - self.down_y) > 8 * self.scale) {
            self.moved = true;
            self.press_idx = null;
        }
        self.last_x = x;
        self.last_y = y;

        if (self.edge_drag) { // il pannello segue il dito
            self.drawer = std.math.clamp(self.drawer + dx / self.drawerW(w), 0, 1);
            return;
        }
        if (self.drawer_open) return; // col pannello aperto la griglia non scorre
        if (self.mode == .explorer) {
            self.scroll -= dy;
            self.scroll_v = -dy;
        } else if (self.view_text != null) {
            self.view_scroll = @max(0, self.view_scroll - dy);
        }
    }

    pub fn onPointerUp(self: *Ui, x: f32, y: f32, w: f32, h: f32) void {
        defer {
            self.down = false;
            self.edge_drag = false;
            self.press_idx = null;
        }
        if (!self.down) return;

        if (self.edge_drag) { // oltre metà corsa il pannello si apre, altrimenti torna
            self.drawer_open = self.drawer > 0.5;
            return;
        }
        if (self.moved) {
            // Swipe orizzontale nel viewer → file precedente/successivo.
            if (self.mode == .viewer and self.view_text == null) {
                const dx = x - self.down_x;
                if (@abs(dx) > 60 * self.scale and @abs(dx) > @abs(y - self.down_y)) {
                    self.viewStep(if (dx < 0) 1 else -1);
                }
            }
            return; // trascinamento: niente tap
        }
        if (self.long_fired) return; // la pressione prolungata ha già agito: il rilascio non fa altro
        self.tap(x, y, w, h);
    }

    fn tap(self: *Ui, x: f32, y: f32, w: f32, h: f32) void {
        // 1) Foglio delle azioni sulla cartella (ha la precedenza su tutto).
        if (self.sheet) |idx| {
            if (self.sheetHit(x, y, w, h)) |action| {
                var buf: [512]u8 = undefined;
                const path = self.pathOf(idx, &buf);
                self.sheet = null;
                if (path) |p| switch (action) {
                    .open => self.navigate(p),
                    .preview => {
                        // "Anteprima": si entra e si apre subito il primo file → il viewer
                        // a tutto schermo, da cui si sfoglia con lo swipe.
                        self.navigate(p);
                        for (self.entries.items, 0..) |e, i| {
                            if (e.kind != .folder) {
                                self.openFile(i);
                                break;
                            }
                        }
                    },
                };
            } else self.sheet = null; // tap fuori → chiudi
            return;
        }

        // 2) Pannello laterale aperto: scorciatoia o chiusura.
        if (self.drawer_open) {
            const dw = self.drawerW(w);
            if (x < dw) {
                const item_h = 56 * self.scale;
                const y0 = self.topBarH() + 12 * self.scale;
                if (y >= y0) {
                    const i: usize = @intFromFloat((y - y0) / item_h);
                    if (i < shortcuts.len) {
                        self.navigate(shortcuts[i].path);
                        self.drawer_open = false;
                    }
                }
            } else self.drawer_open = false; // tap sullo scrim
            return;
        }

        // 3) Viewer: il tap fa riapparire/sparire la barra col nome.
        if (self.mode == .viewer) {
            self.chrome = if (self.chrome > 0.5) 0 else 1;
            return;
        }

        // 4) Barra superiore: ☰ apre il pannello, il resto (percorso) risale di un livello.
        if (y < self.topBarH()) {
            if (x < 64 * self.scale) self.drawer_open = true else _ = self.goUp();
            return;
        }

        // 5) Scheda del permesso: il pulsante è largo tutta la scheda.
        if (self.need_perm) {
            self.perm_requested = true; // il chiamante apre la schermata di sistema
            return;
        }

        // 6) Griglia. Il tap fa la cosa OVVIA — entra nella cartella, apre il file — perché
        // è quella che si fa cento volte; le alternative (anteprima della cartella) stanno
        // sotto la pressione prolungata, dove non intralciano.
        if (self.hitTile(x, y, w)) |idx| {
            const e = self.entries.items[idx];
            if (e.kind == .folder) {
                var buf: [512]u8 = undefined;
                if (self.pathOf(idx, &buf)) |p| self.navigate(p);
            } else self.openFile(idx);
        }
    }

    fn hitTile(self: *Ui, x: f32, y: f32, w: f32) ?usize {
        if (y < self.topBarH()) return null;
        const g = self.grid(w);
        const gy = y + self.scroll - g.y0;
        if (gy < 0) return null;
        const row: usize = @intFromFloat(gy / g.cell_h);
        const gx = x - g.x0;
        if (gx < 0) return null;
        const col: usize = @intFromFloat(gx / (g.tile + g.gap));
        if (col >= g.cols) return null;
        const idx = row * g.cols + col;
        return if (idx < self.entries.items.len) idx else null;
    }

    /// Il foglio ha due bottoni impilati: sopra "Apri", sotto "Anteprima".
    fn sheetHit(self: *Ui, x: f32, y: f32, w: f32, h: f32) ?SheetAction {
        _ = x;
        _ = w;
        const bh = 64 * self.scale;
        const sheet_h = 24 * self.scale + bh * 2 + 24 * self.scale;
        const top = h - sheet_h;
        if (y < top) return null;
        const y0 = top + 20 * self.scale;
        if (y < y0 + bh) return .open;
        if (y < y0 + bh * 2 + 8 * self.scale) return .preview;
        return null;
    }

    /// Tasto "indietro" di sistema. False = non c'era niente da chiudere → esci dall'app.
    pub fn onBack(self: *Ui) bool {
        if (self.sheet != null) {
            self.sheet = null;
            return true;
        }
        if (self.drawer_open) {
            self.drawer_open = false;
            return true;
        }
        if (self.mode == .viewer) {
            self.closeFile();
            self.mode = .explorer;
            return true;
        }
        return self.goUp();
    }

    // ── Disegno ────────────────────────────────────────────────────────────────

    pub fn draw(self: *Ui, canvas: *paint.Canvas, w_px: u32, h_px: u32) void {
        const w: f32 = @floatFromInt(w_px);
        const h: f32 = @floatFromInt(h_px);
        self.animating = false;

        // Animazioni: pannello e foglio inseguono il proprio stato; l'inerzia dello scroll
        // si smorza. Tutto qui, un posto solo, così il frame è sempre coerente — e ognuna
        // dichiara se ha ancora strada da fare (`animating`), che è ciò che tiene vivo il
        // loop esattamente finché serve.
        if (!self.edge_drag) {
            const want: f32 = if (self.drawer_open) 1 else 0;
            if (@abs(want - self.drawer) < 0.005) self.drawer = want else {
                self.drawer += (want - self.drawer) * 0.40;
                self.animating = true;
            }
        }
        const want_sheet: f32 = if (self.sheet != null) 1 else 0;
        if (@abs(want_sheet - self.sheet_a) < 0.005) self.sheet_a = want_sheet else {
            self.sheet_a += (want_sheet - self.sheet_a) * 0.45;
            self.animating = true;
        }
        if (self.mode == .explorer and !self.down and @abs(self.scroll_v) > 0.1) {
            self.scroll += self.scroll_v;
            self.scroll_v *= 0.92;
            self.animating = true;
        }
        if (self.mode == .viewer and self.chrome > 0) {
            self.chrome = @max(0, self.chrome - 0.004);
            self.animating = true;
        }
        if (self.scroll < 0 or (self.content_h > h and self.scroll > self.content_h - h)) self.animating = true; // rimbalzo
        self.pumpLongPress();

        const p0 = nowNs();
        canvas.fillRoundedRectVGradient(0, 0, w, h, 0, bg_top, bg_bot);
        const p1 = nowNs();
        if (self.mode == .viewer) {
            self.drawViewer(canvas, w, h);
            return;
        }
        self.drawExplorer(canvas, w, h);
        const p2 = nowNs();
        if (self.sheet_a > 0.01) self.drawSheet(canvas, w, h);
        if (self.drawer > 0.01) self.drawDrawer(canvas, w, h);
        const p3 = nowNs();
        // Profilo per sezione, una riga ogni 30 frame: è così che si è scoperto che lo
        // sfondo costava 72 ms (SDF + blend per pixel su un riempimento opaco). Una riga
        // per frame allagherebbe logcat e falserebbe la misura.
        self.prof_frames +%= 1;
        if (self.prof_frames <= 20 or self.prof_frames % 30 == 0) {
            _ = __android_log_print(4, "zuer", "ui: bg %.1f · grid %.1f [fill %.1f blit %.1f text %.1f] · chrome %.1f ms", @as(f64, @floatFromInt(p1 - p0)) / 1e6, @as(f64, @floatFromInt(p2 - p1)) / 1e6, @as(f64, @floatFromInt(self.t_fill)) / 1e6, @as(f64, @floatFromInt(self.t_blit)) / 1e6, @as(f64, @floatFromInt(self.t_text)) / 1e6, @as(f64, @floatFromInt(p3 - p2)) / 1e6);
        }
        self.thumb_ns = 0;
        self.t_fill = 0;
        self.t_blit = 0;
        self.t_text = 0;
    }

    fn drawExplorer(self: *Ui, canvas: *paint.Canvas, w: f32, h: f32) void {
        const g = self.grid(w);
        const rows = (self.entries.items.len + g.cols - 1) / g.cols;
        self.content_h = g.y0 + @as(f32, @floatFromInt(rows)) * g.cell_h + 24 * self.scale;
        const max_scroll = @max(0, self.content_h - h);
        // Rimbalzo morbido ai capi invece di un fermo secco.
        if (self.scroll < 0) {
            self.scroll *= 0.75;
            self.scroll_v = 0;
        }
        if (self.scroll > max_scroll) {
            self.scroll = max_scroll + (self.scroll - max_scroll) * 0.75;
            self.scroll_v = 0;
        }

        if (self.need_perm) {
            self.drawPermCard(canvas, w, h);
        } else if (self.notice) |msg| {
            self.centerMsg(canvas, w, h, msg);
        } else {
            // Solo le righe visibili: una cartella con 5000 foto disegna comunque una schermata.
            const first_row: usize = @intFromFloat(@max(0, (self.scroll - g.y0) / g.cell_h));
            const last_row: usize = @intFromFloat(@max(0, (self.scroll + h - g.y0) / g.cell_h));
            const first = first_row * g.cols;
            const last = @min(self.entries.items.len, (last_row + 1) * g.cols + g.cols);
            self.pumpThumbs(first, if (last > 0) last - 1 else 0);

            var i = first;
            while (i < last) : (i += 1) {
                const row = i / g.cols;
                const col = i % g.cols;
                const x = g.x0 + @as(f32, @floatFromInt(col)) * (g.tile + g.gap);
                const y = g.y0 + @as(f32, @floatFromInt(row)) * g.cell_h - self.scroll;
                self.drawTile(canvas, i, x, y, g.tile);
            }
        }
        self.drawTopBar(canvas, w);
    }

    fn drawTile(self: *Ui, canvas: *paint.Canvas, idx: usize, x: f32, y: f32, tile: f32) void {
        const e = self.entries.items[idx];
        const r = tk.radius.lg * self.scale;
        const pressed = self.press_idx == idx;
        const tf0 = nowNs();
        canvas.fillRoundedRect(x, y, tile, tile, r, if (pressed) surface_hi else surface);
        self.t_fill += nowNs() - tf0;
        const tb0 = nowNs();

        if (e.thumb) |th| {
            // L'anteprima riempie la tessera, con gli STESSI angoli della tessera: un
            // quadrato dentro un rettangolo tondo si vede subito, ed è la differenza fra una
            // griglia disegnata e una incollata.
            canvas.blitImageRounded(
                @intFromFloat(x),
                @intFromFloat(y),
                @intFromFloat(tile),
                @intFromFloat(tile),
                th,
                e.thumb_w,
                e.thumb_h,
                r,
            );
            // Un file multimediale con l'anteprima è comunque un video, non una foto: una
            // pastiglia piccola in basso a destra lo dice senza coprire l'immagine.
            if (e.kind != .image) {
                const c = e.kind.color();
                const bs: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.caption)) * self.scale);
                const label = e.kind.badge();
                const lw: f32 = @floatFromInt(self.font.measure(bs, .bold, label));
                const pw = lw + 12 * self.scale;
                const ph = 18 * self.scale;
                const px = x + tile - pw - 6 * self.scale;
                const py = y + tile - ph - 6 * self.scale;
                canvas.fillRoundedRect(px, py, pw, ph, tk.radius.xs * self.scale, alphaOf(tk.surface, 0.78));
                canvas.drawText(self.font, @intFromFloat(px + 6 * self.scale), @intFromFloat(py + ph - 5 * self.scale), label, .{ .size = bs, .style = .bold, .color = c });
            }
        } else if (e.kind == .folder) {
            // Cartella: una forma, non una lettera — si riconosce al volo scorrendo. La
            // linguetta è più stretta del corpo e leggermente più chiara: bastano due
            // rettangoli arrotondati perché l'occhio legga "cartella" senza pensarci.
            const c = Kind.folder.color();
            const fw = tile * 0.44;
            const fh = tile * 0.34;
            const fx = x + (tile - fw) / 2;
            const fy = y + (tile - fh) / 2 + fh * 0.10;
            const tab_h = fh * 0.20;
            canvas.fillRoundedRect(fx, fy - tab_h * 0.9, fw * 0.42, tab_h * 1.6, 3 * self.scale, c.shade(0.25));
            canvas.fillRoundedRect(fx, fy, fw, fh, tk.radius.xs * self.scale, c);
        } else {
            // Pastiglia tinta dell'accento della famiglia: il colore lo dà la categoria, la
            // superficie resta neutra. Il pieno saturo in una griglia di 30 tessere
            // stancherebbe; una tinta al 18% con la sigla nel colore pieno si legge e basta.
            const c = e.kind.color();
            const bw = tile * 0.46;
            const bh = tile * 0.32;
            const bx = x + (tile - bw) / 2;
            const by = y + (tile - bh) / 2;
            canvas.fillRoundedRect(bx, by, bw, bh, tk.radius.sm * self.scale, alphaOf(c, 0.18));
            const size: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.label)) * self.scale);
            const label = e.kind.badge();
            const tw: f32 = @floatFromInt(self.font.measure(size, .bold, label));
            canvas.drawText(
                self.font,
                @intFromFloat(bx + (bw - tw) / 2),
                @intFromFloat(by + bh / 2 + 5 * self.scale),
                label,
                .{ .size = size, .style = .bold, .color = c },
            );
        }

        self.t_blit += nowNs() - tb0;
        const tt0 = nowNs();
        defer self.t_text += nowNs() - tt0;
        // Nome: una riga, troncata con l'ellissi (mai a capo: la griglia deve restare a passo).
        const size: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.caption)) * self.scale);
        var buf: [96]u8 = undefined;
        const label = self.ellipsize(e.name, tile, size, &buf);
        const tw: f32 = @floatFromInt(self.font.measure(size, .regular, label));
        canvas.drawText(
            self.font,
            @intFromFloat(x + @max(0, (tile - tw) / 2)),
            @intFromFloat(y + tile + 20 * self.scale),
            label,
            .{ .size = size, .color = fg },
        );
    }

    /// Tronca `s` con "…" perché stia in `max_w`. Il buffer è del chiamante.
    fn ellipsize(self: *Ui, s: []const u8, max_w: f32, size: u16, buf: []u8) []const u8 {
        if (@as(f32, @floatFromInt(self.font.measure(size, .regular, s))) <= max_w) {
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return buf[0..n];
        }
        var n: usize = @min(s.len, buf.len - 3);
        while (n > 1) : (n -= 1) {
            // Non spezzare a metà di una sequenza UTF-8 (i nomi con accenti sono la norma).
            if (n < s.len and (s[n] & 0xC0) == 0x80) continue;
            @memcpy(buf[0..n], s[0..n]);
            @memcpy(buf[n .. n + 3], "…");
            const out = buf[0 .. n + 3];
            if (@as(f32, @floatFromInt(self.font.measure(size, .regular, out))) <= max_w) return out;
        }
        return buf[0..0];
    }

    fn drawTopBar(self: *Ui, canvas: *paint.Canvas, w: f32) void {
        const bh = self.topBarH();
        canvas.fillRoundedRect(0, 0, w, bh, 0, alphaOf(tk.surface, 0.96));
        canvas.fillRoundedRect(0, bh - 1, w, 1, 0, tk.outline); // capello di separazione
        // Il contenuto della barra vive SOTTO la fascia sicura (vedi safeTop).
        const cy = self.safeTop() + 28 * self.scale;

        // ☰ : tre barrette, disegnate (nessuna dipendenza da un font di icone).
        const bx = 22 * self.scale;
        const by = cy - 7 * self.scale;
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            canvas.fillRoundedRect(bx, by + @as(f32, @floatFromInt(i)) * 7 * self.scale, 22 * self.scale, 2.5 * self.scale, 2 * self.scale, fg);
        }

        // Percorso: solo la cartella corrente in chiaro — un breadcrumb completo su un
        // telefono non ci sta e non serve.
        const size: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.headline)) * self.scale);
        const name = if (self.cwd.items.len <= 1) "/" else std.fs.path.basename(self.cwd.items);
        canvas.drawText(self.font, @intFromFloat(64 * self.scale), @intFromFloat(cy + 6 * self.scale), name, .{ .size = size, .style = .bold, .color = fg });
    }

    fn drawDrawer(self: *Ui, canvas: *paint.Canvas, w: f32, h: f32) void {
        const dw = self.drawerW(w);
        canvas.fillRoundedRect(0, 0, w, h, 0, alphaOf(scrim, scrim.a * self.drawer));
        const x = -dw * (1 - self.drawer);
        // Il pannello è un piano "alzato": superficie più chiara del fondo, non una tinta a caso.
        canvas.fillRoundedRect(x, 0, dw, h, 0, tk.surface_2);
        canvas.fillRoundedRect(x + dw - 1, 0, 1, h, 0, tk.outline);

        const size: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.body)) * self.scale);
        const title: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.title)) * self.scale);
        canvas.drawText(self.font, @intFromFloat(x + 22 * self.scale), @intFromFloat(self.safeTop() + 34 * self.scale), "Zuer", .{ .size = title, .style = .bold, .color = fg });

        const item_h = 56 * self.scale;
        const y0 = self.topBarH() + 12 * self.scale;
        for (shortcuts, 0..) |sc, i| {
            const y = y0 + @as(f32, @floatFromInt(i)) * item_h;
            const active = std.mem.eql(u8, self.cwd.items, sc.path);
            // La voce attiva è una pillola tonale (non un blocco pieno): segnala senza gridare.
            if (active) canvas.fillRoundedRect(x + 10 * self.scale, y + 4 * self.scale, dw - 20 * self.scale, item_h - 8 * self.scale, tk.radius.pill, alphaOf(accent, 0.20));
            // Pastiglia colorata al posto di un'icona: leggibile, e costa una fillRect.
            canvas.fillRoundedRect(x + 22 * self.scale, y + item_h / 2 - 8 * self.scale, 16 * self.scale, 16 * self.scale, tk.radius.xs * self.scale, if (active) accent else fg_dim);
            canvas.drawText(
                self.font,
                @intFromFloat(x + 52 * self.scale),
                @intFromFloat(y + item_h / 2 + 6 * self.scale),
                sc.label,
                .{ .size = size, .style = if (active) .bold else .regular, .color = if (active) fg else fg_dim },
            );
        }
    }

    /// Foglio inferiore con le due azioni della cartella (punto 3 del brief).
    fn drawSheet(self: *Ui, canvas: *paint.Canvas, w: f32, h: f32) void {
        const idx = self.sheet orelse return;
        const bh = 64 * self.scale;
        const sheet_h = 24 * self.scale + bh * 2 + 24 * self.scale + 40 * self.scale;
        const top = h - sheet_h * self.sheet_a;

        canvas.fillRoundedRect(0, 0, w, h, 0, alphaOf(scrim, scrim.a * self.sheet_a));
        canvas.fillRoundedRect(0, top, w, sheet_h + 40 * self.scale, tk.radius.xl * self.scale, tk.surface_2);
        // Maniglia
        canvas.fillRoundedRect(w / 2 - 20 * self.scale, top + 10 * self.scale, 40 * self.scale, 4 * self.scale, tk.radius.pill, fg_dim);

        const name = self.entries.items[idx].name;
        const nsize: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.body)) * self.scale);
        var nbuf: [96]u8 = undefined;
        const label = self.ellipsize(name, w - 48 * self.scale, nsize, &nbuf);
        canvas.drawText(self.font, @intFromFloat(24 * self.scale), @intFromFloat(top + 40 * self.scale), label, .{ .size = nsize, .style = .bold, .color = fg });

        const y0 = top + 60 * self.scale;
        self.sheetButton(canvas, w, y0, bh, "Apri nell'explorer", "sfoglia il contenuto", true);
        self.sheetButton(canvas, w, y0 + bh + 8 * self.scale, bh, "Anteprima", "apri i file a tutto schermo", false);
    }

    /// Azione del foglio. La primaria è PIENA (primary su on_primary): in un foglio con due
    /// scelte, quale sia quella attesa deve vedersi prima di leggere le parole.
    fn sheetButton(self: *Ui, canvas: *paint.Canvas, w: f32, y: f32, bh: f32, title: []const u8, sub: []const u8, primary: bool) void {
        const x = 20 * self.scale;
        const bw = w - x * 2;
        canvas.fillRoundedRect(x, y, bw, bh, tk.radius.md * self.scale, if (primary) tk.primary else tk.surface_3);
        const ts: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.body)) * self.scale);
        const ss: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.caption)) * self.scale);
        const c_title = if (primary) tk.on_primary else fg;
        const c_sub = if (primary) alphaOf(tk.on_primary, 0.75) else fg_dim;
        canvas.drawText(self.font, @intFromFloat(x + 20 * self.scale), @intFromFloat(y + bh / 2 - 2 * self.scale), title, .{ .size = ts, .style = .bold, .color = c_title });
        canvas.drawText(self.font, @intFromFloat(x + 20 * self.scale), @intFromFloat(y + bh / 2 + 16 * self.scale), sub, .{ .size = ss, .color = c_sub });
    }

    fn centerMsg(self: *Ui, canvas: *paint.Canvas, w: f32, h: f32, msg: []const u8) void {
        const size: u16 = @intFromFloat(15 * self.scale);
        const tw: f32 = @floatFromInt(self.font.measure(size, .regular, msg));
        canvas.drawText(self.font, @intFromFloat((w - tw) / 2), @intFromFloat(h / 2), msg, .{ .size = size, .color = fg_dim });
    }

    /// Scheda "serve il permesso": su Android 11+ un file manager senza "accesso a tutti i
    /// file" non vede nulla, e mostrare una griglia vuota sarebbe una bugia.
    fn drawPermCard(self: *Ui, canvas: *paint.Canvas, w: f32, h: f32) void {
        const cw = @min(w - 40 * self.scale, 380 * self.scale);
        const ch = 200 * self.scale;
        const x = (w - cw) / 2;
        const y = (h - ch) / 2;
        canvas.fillRoundedRect(x, y, cw, ch, tk.radius.xl * self.scale, tk.surface_2);
        const ts: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.headline)) * self.scale);
        const bs: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.label)) * self.scale);
        canvas.drawText(self.font, @intFromFloat(x + 24 * self.scale), @intFromFloat(y + 44 * self.scale), "Accesso ai file", .{ .size = ts, .style = .bold, .color = fg });
        canvas.drawText(self.font, @intFromFloat(x + 24 * self.scale), @intFromFloat(y + 76 * self.scale), "Zuer ha bisogno del permesso", .{ .size = bs, .color = fg_dim });
        canvas.drawText(self.font, @intFromFloat(x + 24 * self.scale), @intFromFloat(y + 98 * self.scale), "per sfogliare la memoria.", .{ .size = bs, .color = fg_dim });
        const bh = 52 * self.scale;
        const by = y + ch - bh - 20 * self.scale;
        canvas.fillRoundedRect(x + 24 * self.scale, by, cw - 48 * self.scale, bh, tk.radius.md * self.scale, tk.primary);
        const label = "Concedi il permesso";
        const lw: f32 = @floatFromInt(self.font.measure(bs, .bold, label));
        canvas.drawText(self.font, @intFromFloat(x + (cw - lw) / 2), @intFromFloat(by + bh / 2 + 5 * self.scale), label, .{ .size = bs, .style = .bold, .color = tk.on_primary });
    }

    // ── Viewer ─────────────────────────────────────────────────────────────────

    fn drawViewer(self: *Ui, canvas: *paint.Canvas, w: f32, h: f32) void {
        canvas.fillRoundedRect(0, 0, w, h, 0, Color.rgba(0, 0, 0, 1.0)); // il contenuto merita nero pieno
        const e = self.entries.items[self.view_idx];

        if (self.view_img) |img| {
            // Aspect-fit: l'immagine intera, mai ritagliata, centrata.
            const iw: f32 = @floatFromInt(self.view_w);
            const ih: f32 = @floatFromInt(self.view_h);
            const s = @min(w / iw, h / ih);
            const dw = iw * s;
            const dh = ih * s;
            canvas.blitImage(
                @intFromFloat((w - dw) / 2),
                @intFromFloat((h - dh) / 2),
                @intFromFloat(dw),
                @intFromFloat(dh),
                img,
                self.view_w,
                self.view_h,
            );
        } else if (self.view_text) |txt| {
            self.drawText(canvas, txt, w, h);
        } else if (self.view_doc) |d| switch (d) {
            .csv => |table| self.drawTable(canvas, table, w, h),
            .mesh => |m| self.drawMeshCard(canvas, w, h, e, m),
            .err => |msg| self.centerMsg(canvas, w, h, msg),
            else => self.drawInfoCard(canvas, w, h, e),
        } else {
            self.drawInfoCard(canvas, w, h, e);
        }

        // Barra col nome: appare al tap e si dissolve da sola (il contenuto è il re).
        if (self.chrome > 0.01) {
            const bh = self.topBarH();
            canvas.fillRoundedRect(0, 0, w, bh, 0, Color.rgba(0, 0, 0, 0.6 * self.chrome));
            const size: u16 = @intFromFloat(15 * self.scale);
            var buf: [96]u8 = undefined;
            const label = self.ellipsize(e.name, w - 40 * self.scale, size, &buf);
            canvas.drawText(self.font, @intFromFloat(20 * self.scale), @intFromFloat(self.safeTop() + 34 * self.scale), label, .{
                .size = size,
                .style = .bold,
                .color = Color.rgba(255, 255, 255, self.chrome),
            });
        }
    }

    fn drawText(self: *Ui, canvas: *paint.Canvas, txt: []const u8, w: f32, h: f32) void {
        const size: u16 = @intFromFloat(13 * self.scale);
        const line_h = 20 * self.scale;
        const x = 18 * self.scale;
        const top = self.topBarH();
        var y = top + line_h - self.view_scroll;

        var it = std.mem.splitScalar(u8, txt, '\n');
        var count: usize = 0;
        while (it.next()) |raw| : (count += 1) {
            if (y > h) break; // fuori dallo schermo: smetti di disegnare
            if (y >= top - line_h) {
                // Tronca le righe lunghissime invece di mandarle a capo: un sorgente resta
                // leggibile e il costo per riga resta costante.
                const line = if (raw.len > 200) raw[0..200] else raw;
                canvas.drawText(self.font, @intFromFloat(x), @intFromFloat(y), line, .{ .size = size, .color = fg });
            }
            y += line_h;
            if (count > 20000) break;
        }
        const total = @as(f32, @floatFromInt(count)) * line_h;
        const max_scroll = @max(0, total - h + top);
        if (self.view_scroll > max_scroll) self.view_scroll = max_scroll;
        _ = w;
    }

    /// Tabella: serve al CSV/TSV **e** al listato di un archivio (il decoder ZIP/TAR
    /// restituisce esattamente una tabella nome/dimensione — un solo renderer, tre tipi di
    /// file). Colonne a larghezza proporzionale al peso della prima riga di dati: un
    /// layout misurato sul contenuto costa una passata, uno "auto" costerebbe tutte le righe.
    /// Su un telefono largo 5 cm, N colonne allineate sono illeggibili: si stringono fino a
    /// diventare monconi troncati. Quindi non si disegnano colonne — si disegnano **righe**:
    /// il primo campo (il nome) grande a sinistra, gli altri riassunti in piccolo sotto o a
    /// destra. È la stessa scelta di ogni app di file su mobile, ed è il motivo per cui una
    /// lista si legge in diagonale e una tabella no.
    fn drawTable(self: *Ui, canvas: *paint.Canvas, table: dec.CsvData, w: f32, h: f32) void {
        const name_size: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.body)) * self.scale);
        const meta_size: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.caption)) * self.scale);
        const row_h = 54 * self.scale; // sopra i 44 dp: una riga resta toccabile
        const pad = 18 * self.scale;
        const top = self.topBarH();
        if (table.headers.len == 0) return;

        var y = top + 8 * self.scale - self.view_scroll;
        for (table.rows) |row| {
            if (y > h) break;
            if (y > top - row_h and row.len > 0) {
                // Zebratura appena accennata: separa le righe senza disegnare una griglia.
                canvas.fillRoundedRect(pad / 2, y, w - pad, row_h - 4 * self.scale, tk.radius.md * self.scale, tk.surface_1);

                var nbuf: [128]u8 = undefined;
                canvas.drawText(self.font, @intFromFloat(pad), @intFromFloat(y + 22 * self.scale), self.ellipsize(row[0], w - pad * 2, name_size, &nbuf), .{ .size = name_size, .color = fg });

                // Tutti i campi restanti (dimensione, data, metodo…) su una riga sola in
                // piccolo: l'informazione c'è, ma non compete col nome.
                var mbuf: [160]u8 = undefined;
                var n: usize = 0;
                for (row[1..], 1..) |cell, ci| {
                    if (ci >= table.headers.len or cell.len == 0) continue;
                    const sep: []const u8 = if (n == 0) "" else " · ";
                    const piece = std.fmt.bufPrint(mbuf[n..], "{s}{s}", .{ sep, cell }) catch break;
                    n += piece.len;
                }
                if (n > 0) {
                    var ebuf: [160]u8 = undefined;
                    canvas.drawText(self.font, @intFromFloat(pad), @intFromFloat(y + 42 * self.scale), self.ellipsize(mbuf[0..n], w - pad * 2, meta_size, &ebuf), .{ .size = meta_size, .color = fg_dim });
                }
            }
            y += row_h;
        }

        const total = @as(f32, @floatFromInt(table.rows.len)) * row_h;
        const max_scroll = @max(0, total - h + top + row_h);
        if (self.view_scroll > max_scroll) self.view_scroll = max_scroll;
        if (self.view_scroll < 0) self.view_scroll = 0;
    }

    /// Scheda di una mesh: il modello 3D non è ancora rasterizzato sul telefono, ma il
    /// decoder gira già — quindi invece di "anteprima non disponibile" si dicono le cose
    /// vere che sappiamo del file (vertici, facce, ingombro).
    fn drawMeshCard(self: *Ui, canvas: *paint.Canvas, w: f32, h: f32, e: Entry, m: dec.MeshData) void {
        self.drawInfoCard(canvas, w, h, e);
        const size: u16 = @intFromFloat(@as(f32, @floatFromInt(tk.type.label)) * self.scale);
        var buf: [96]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "{d} vertici · {d} facce", .{ m.num_vertices, m.num_faces }) catch return;
        const tw: f32 = @floatFromInt(self.font.measure(size, .regular, txt));
        canvas.drawText(self.font, @intFromFloat((w - tw) / 2), @intFromFloat(h / 2 + 130 * self.scale), txt, .{ .size = size, .color = tk.accent.orange });
    }

    /// Tipi che il viewer mobile non sa ancora aprire (audio/video/PDF/Office): invece di
    /// una schermata vuota, una scheda che dice cosa c'è e quanto è grande — e lo dice
    /// onestamente, senza fingere un'anteprima.
    fn drawInfoCard(self: *Ui, canvas: *paint.Canvas, w: f32, h: f32, e: Entry) void {
        const cw = @min(w - 48 * self.scale, 360 * self.scale);
        const ch = 220 * self.scale;
        const x = (w - cw) / 2;
        const y = (h - ch) / 2;
        canvas.fillRoundedRect(x, y, cw, ch, tk.radius.xl * self.scale, tk.surface_2);

        const c = e.kind.color();
        const bw = 84 * self.scale;
        const bh = 56 * self.scale;
        const bx = x + (cw - bw) / 2;
        const by = y + 28 * self.scale;
        canvas.fillRoundedRect(bx, by, bw, bh, tk.radius.md * self.scale, alphaOf(c, 0.18));
        const bs: u16 = @intFromFloat(18 * self.scale);
        const badge = e.kind.badge();
        const bwid: f32 = @floatFromInt(self.font.measure(bs, .bold, badge));
        canvas.drawText(self.font, @intFromFloat(bx + (bw - bwid) / 2), @intFromFloat(by + bh / 2 + 7 * self.scale), badge, .{ .size = bs, .style = .bold, .color = c });

        var buf: [96]u8 = undefined;
        const ns: u16 = @intFromFloat(15 * self.scale);
        const label = self.ellipsize(e.name, cw - 40 * self.scale, ns, &buf);
        const lw: f32 = @floatFromInt(self.font.measure(ns, .bold, label));
        canvas.drawText(self.font, @intFromFloat(x + (cw - lw) / 2), @intFromFloat(by + bh + 40 * self.scale), label, .{ .size = ns, .style = .bold, .color = fg });

        var sbuf: [64]u8 = undefined;
        const size_txt = humanSize(e.size, &sbuf);
        const ss: u16 = @intFromFloat(13 * self.scale);
        const sw: f32 = @floatFromInt(self.font.measure(ss, .regular, size_txt));
        canvas.drawText(self.font, @intFromFloat(x + (cw - sw) / 2), @intFromFloat(by + bh + 70 * self.scale), size_txt, .{ .size = ss, .color = fg_dim });

        const msg = "Anteprima non ancora disponibile";
        const mw: f32 = @floatFromInt(self.font.measure(ss, .regular, msg));
        canvas.drawText(self.font, @intFromFloat(x + (cw - mw) / 2), @intFromFloat(y + ch - 26 * self.scale), msg, .{ .size = ss, .color = Color.rgba(100, 116, 139, 1.0) });
    }
};

fn humanSize(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "";
}
