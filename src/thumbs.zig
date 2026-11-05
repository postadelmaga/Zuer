//! Pipeline delle miniature dell'esploratore file, senza dipendenze dalla GUI:
//! la usa `file_explorer.zig` e, con lo stesso codice, `bench_thumbnails.zig`.
//!
//! Flusso per una cartella (una "generazione" `gen`):
//! 1. `enterDir` (thread finestra) scandisce i nomi, bumpa `fx.gen` e chiama
//!    `start`. Il bump è la cancellazione di tutto il lavoro precedente.
//! 2. Il primo job (task `normal` dello scheduler globale) riempie dimensioni e
//!    mtime (`fillSizes`), poi spazzola la cache su disco e infine decodifica.
//! 3. Ogni job, prima di reclamare una voce, aggiunge job fratelli fino a
//!    `Host.jobs` (fan-out), purché resti lavoro e non ci sia un decode
//!    interattivo in corso. I job si dividono le voci con `claimNext` (claim
//!    sotto `mutex`), partendo dalle card visibili.
//! 4. Con un decode interattivo in corso (`scheduler.foregroundActive`) i job in
//!    più si ritirano: ne resta uno, che cede comunque il worker al lavoro più
//!    urgente in coda. Finito il decode, il fan-out riparte.
//! 5. I worker non toccano mai la GUI: installano la miniatura nella voce sotto
//!    `mutex`, solo se `gen` è ancora la corrente, e alzano `changed`.
//!
//! Limiti di risorse: al più `max_entries` voci, `max_thumb_files` miniature in
//! RAM e altrettanti decode tentati per generazione; nessun file oltre
//! `max_thumb_bytes`; al più `max_heavy_inflight` decode "pesanti" insieme
//! (processi esterni, video, file grandi: vedi `isHeavy`), così un file lento
//! o enorme non occupa tutti i job né moltiplica il picco di RAM; cache su
//! disco con tetto LRU `thumb_cache_cap_bytes`.

const std = @import("std");
const builtin = @import("builtin");
const decoder_mod = @import("decoder.zig");
const scheduler = @import("scheduler.zig");
const layout = @import("layout.zig");
const vtcache = @import("vtcache.zig");
// Copia host dell'helper di manutenzione cache (LRU per mtime + sweep dei tmp).
const evict = @import("cache_evict.zig");
const grid_scroll = @import("grid_scroll.zig");

/// Colonne della griglia: `claimNext` parte dalla prima card visibile.
pub const grid_cols: i32 = 4;

/// Tetto alle voci mostrate (cartelle sterminate) e alle miniature TENUTE IN RAM
/// per generazione: `max_thumb_files` × `thumb_max`² × 4 B ≈ 24 MB nel caso
/// peggiore. Lo stesso tetto limita anche i decode tentati (ognuno è un decode
/// completo su un worker).
pub const max_entries: usize = 512;
pub const max_thumb_files: usize = 96;
/// Oltre questa dimensione niente miniatura (decode lento/pesante in RAM).
pub const max_thumb_bytes: u64 = 256 * 1024 * 1024;
/// Decode pesanti (PDF, video) in corso insieme per generazione.
pub const max_heavy_inflight: u32 = 1;

/// Una voce della cartella (stringhe e miniatura possedute, vedi `freeEntries`).
pub const Entry = struct {
    name: []u8,
    is_dir: bool,
    size: u64 = 0,
    /// mtime della sorgente in ns (riempito da `fillSizes`): con `size` forma la
    /// chiave della cache su disco, che si invalida così da sola.
    mtime_ns: i128 = 0,
    /// Miniatura RGBA (vuota finché un job non la installa).
    thumb_rgba: []align(4) u8 = &.{},
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,
    /// Un job ha già tentato il decode (evita retry sui formati falliti).
    thumb_tried: bool = false,
    /// Un job ha già interrogato la cache su disco per questa voce.
    cache_tried: bool = false,
    /// Lettura dalla cache in corso: il decode la salta (il job che la sta
    /// leggendo passa lui al decode se la cache manca).
    cache_busy: bool = false,
};

pub fn freeEntries(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        gpa.free(e.name);
        gpa.free(e.thumb_rgba);
    }
    gpa.free(entries);
}

/// Stato dell'overlay, dentro `Shared` (ogni accesso sotto `shared.mutex`).
pub const FxState = struct {
    active: bool = false,
    /// Cartella mostrata (posseduta; vuota = mai aperta).
    dir: []u8 = &.{},
    entries: []Entry = &.{},
    /// Card selezionata (-1 = nessuna).
    sel: i32 = -1,
    /// Scroll della griglia in pixel, col passo e l'easing di zicro.
    scroll: grid_scroll.GridScroll = .{},
    /// Prima riga di card visibile, aggiornata dal disegno: i job delle
    /// miniature partono da lì.
    top_row: i32 = 0,
    /// Generazione delle voci: i job installano solo se è ancora la loro.
    gen: u32 = 0,
    /// Miniature installate nella generazione corrente e decode già tentati:
    /// budget condivisi fra i job (tetto su RAM e CPU). Azzerati da
    /// `resetGeneration` (il conteggio riparte da quelle ereditate).
    thumb_installed: u32 = 0,
    thumb_attempts: u32 = 0,
    /// Job vivi della generazione corrente (fan-out e ritiro).
    thumb_jobs: u32 = 0,
    /// Decode pesanti in corso nella generazione corrente.
    heavy_inflight: u32 = 0,
    /// La selezione è appena cambiata da tastiera: lo scroll la insegue.
    follow_sel: bool = false,
    /// Trascinamento del thumb della scrollbar in corso.
    sb_drag: bool = false,
    /// Messaggio di stato (posseduto), sotto l'header. null = nessuno.
    err: ?[]u8 = null,

    /// Nuova generazione: cancella il lavoro in volo. Con il mutex acquisito.
    pub fn bumpGeneration(fx: *FxState) u32 {
        fx.gen +%= 1;
        fx.thumb_jobs = 0;
        fx.heavy_inflight = 0;
        return fx.gen;
    }
};

/// Statistiche facoltative della pipeline (benchmark). Contatori atomici, tempi
/// per voce sotto un mutex proprio: mai il mutex della GUI.
pub const Stats = struct {
    cache_hits: std.atomic.Value(u32) = .init(0),
    cache_misses: std.atomic.Value(u32) = .init(0),
    decoded: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),
    jobs_created: std.atomic.Value(u32) = .init(0),
    jobs_retired: std.atomic.Value(u32) = .init(0),
    max_jobs: std.atomic.Value(u32) = .init(0),
    mutex: std.Io.Mutex = .init,
    /// Tempo per voce decodificata (decode + downscale + scrittura in cache).
    decode_ns: [max_thumb_files]u64 = undefined,
    decode_count: usize = 0,

    fn recordDecode(s: *Stats, io: std.Io, ns: u64) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        if (s.decode_count < s.decode_ns.len) {
            s.decode_ns[s.decode_count] = ns;
            s.decode_count += 1;
        }
    }
};

/// Cosa serve alla pipeline del suo ospite. Tutti i puntatori devono vivere
/// finché ci sono job: nella GUI puntano dentro `GuiAppState`, che vive fino a
/// dopo `scheduler.deinitGlobal` (che aspetta i job in corso).
pub const Host = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Protegge `fx` e `changed` (nella GUI: `shared.mutex`).
    mutex: *std.Io.Mutex,
    fx: *FxState,
    /// Alzato a ogni miniatura installata (la GUI ridisegna).
    changed: *bool,
    /// Job paralleli massimi per cartella; 0 = automatico (`defaultJobs`).
    jobs: u32 = 0,
    cache: CacheDir = .app,
    /// Segnalata quando l'ultimo job della generazione corrente esce.
    idle_cond: ?*std.Io.Condition = null,
    stats: ?*Stats = null,

    pub const CacheDir = union(enum) {
        /// `…/zuer/thumbs` (vtcache.appCacheDir).
        app,
        none,
        path: []const u8,
    };

    fn maxJobs(h: *const Host) u32 {
        const want = if (h.jobs != 0) h.jobs else defaultJobs();
        const s = scheduler.get() orelse return 1;
        return @intCast(@max(1, @min(want, s.max_workers)));
    }
};

/// Job paralleli di default: `ZUER_THUMB_JOBS` o 2 (vedi README, "Miniature").
pub fn defaultJobs() u32 {
    if (std.c.getenv("ZUER_THUMB_JOBS")) |v| {
        if (std.fmt.parseInt(u32, std.mem.span(v), 10)) |n| {
            if (n > 0) return n;
        } else |_| {}
    }
    return 2;
}

pub fn extEqCi(ext: []const u8, comptime lit: []const u8) bool {
    if (ext.len != lit.len) return false;
    for (ext, lit) |c, l| {
        if (std.ascii.toLower(c) != l) return false;
    }
    return true;
}

/// Formati per cui tentare la miniatura: immagini, video (poster del plugin
/// media) e PDF (prima pagina). Testo/tabelle/mesh restano sul segnaposto.
pub fn thumbable(name: []const u8) bool {
    switch (layout.winKindFromExt(name)) {
        .image, .video => return true,
        else => {},
    }
    return extEqCi(decoder_mod.getExtension(name), "pdf");
}

/// Downscale RGB→RGBA con media per area (campionata) entro `thumb_max`²: le
/// decodifiche GUI arrivano fino a 4096² e a piena risoluzione peserebbero
/// ~64 MB l'una nella griglia.
///
/// 256 e non 512: il pannello è largo al massimo 1080 px su 4 colonne, quindi
/// la card misura ~255×143 px — 256 è già la risoluzione nativa e 512 sprecava
/// 4× la RAM (e 4× la cache su disco) per pixel mai visti.
/// `makeThumb` non fa MAI upscale (`@min(1.0, …)`): una sorgente più piccola
/// della card resta com'è e il blit di `drawOverlay` la ingrandisce in
/// aspect-fit (nearest neighbour, come già accade per le miniature YouTube che
/// arrivano a 320×180); le sorgenti non 16:9 restano in letterbox come oggi.
const thumb_max: usize = 256;

/// Miniatura pronta all'installazione (RGBA allineato a 4: `blitThumb` ci fa
/// sopra un `bytesAsSlice(u32)`).
const ThumbPix = struct { rgba: []align(4) u8, w: u32, h: u32 };

fn makeThumb(gpa: std.mem.Allocator, pixels: []const u8, sw: usize, sh: usize) ?ThumbPix {
    if (sw == 0 or sh == 0 or pixels.len < sw * sh * 3) return null;
    const fw: f32 = @floatFromInt(sw);
    const fh: f32 = @floatFromInt(sh);
    const fmax: f32 = @floatFromInt(thumb_max);
    const s = @min(1.0, @min(fmax / fw, fmax / fh));
    const dw = @max(1, @as(usize, @intFromFloat(@round(fw * s))));
    const dh = @max(1, @as(usize, @intFromFloat(@round(fh * s))));

    const rgba = gpa.alignedAlloc(u8, .@"4", dw * dh * 4) catch return null;
    for (0..dh) |dy| {
        const y0 = dy * sh / dh;
        const y1 = @max(y0 + 1, (dy + 1) * sh / dh);
        const step_y = @max(1, (y1 - y0) / 4); // max ~4 campioni per asse
        for (0..dw) |dx| {
            const x0 = dx * sw / dw;
            const x1 = @max(x0 + 1, (dx + 1) * sw / dw);
            const step_x = @max(1, (x1 - x0) / 4);
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var cnt: u32 = 0;
            var sy = y0;
            while (sy < y1) : (sy += step_y) {
                var sx = x0;
                while (sx < x1) : (sx += step_x) {
                    const o = (sy * sw + sx) * 3;
                    r += pixels[o];
                    g += pixels[o + 1];
                    b += pixels[o + 2];
                    cnt += 1;
                }
            }
            const o = (dy * dw + dx) * 4;
            rgba[o] = @intCast(r / cnt);
            rgba[o + 1] = @intCast(g / cnt);
            rgba[o + 2] = @intCast(b / cnt);
            rgba[o + 3] = 255;
        }
    }
    return .{ .rgba = rgba, .w = @intCast(dw), .h = @intCast(dh) };
}

// ── Cache su disco delle miniature ───────────────────────────────────────────
//
// `…/zuer/thumbs/<hash>-<mtime>-<size>.thumb`, stesso impianto della cache
// `ytthumb` di yt_search.zig: la directory la crea `vtcache.appCacheDir`
// (`$HOME/.cache/zuer/thumbs` su Unix, `%LOCALAPPDATA%\zuer\thumbs` su Windows)
// e la manutenzione la fa `cache_evict` (LRU per mtime, no-op fuori da Linux).
//
// Formato "ZTH1" (little-endian), minimale — nessuna compressione, la lettura
// è una `readFileAlloc` da ~150 KB:
//   magic[4] "ZTH1" | w u32 | h u32 | RGBA raw w·h·4
//
// La chiave contiene mtime e dimensione della SORGENTE: un file modificato
// produce un nome diverso, quindi l'invalidazione è implicita (la entry vecchia
// resta finché l'eviction LRU non la raccoglie). L'hash è sul REALPATH della
// cartella + nome: `fx.dir` può essere relativo (".") e due cwd diversi
// darebbero altrimenti la stessa chiave per file diversi.

const thumb_magic = "ZTH1";
const thumb_header_len: usize = 12;
/// Tetto di lettura: header + la miniatura più grande possibile.
const thumb_file_max: usize = thumb_header_len + thumb_max * thumb_max * 4;
/// Cap LRU della directory `…/zuer/thumbs` (~870 miniature 256×144).
const thumb_cache_cap_bytes: u64 = 128 * 1024 * 1024;

/// Sweep dei tmp orfani fatto al più una volta per processo (alla prima scrittura).
var tmp_sweep_done: std.atomic.Value(bool) = .init(false);
/// Sequenza per i nomi temporanei, unica per-processo (il thread id la rende
/// unica anche fra worker concorrenti).
var tmp_seq: std.atomic.Value(u64) = .init(0);

/// Nome del file di cache per `(realpath cartella, nome, mtime, size)`.
/// Il chiamante libera. null solo in OOM.
fn thumbCacheName(gpa: std.mem.Allocator, real_dir: []const u8, name: []const u8, mtime_ns: i128, size: u64) ?[]u8 {
    var h = std.hash.Wyhash.init(0x7a756572); // "zuer"
    h.update(real_dir);
    h.update("/");
    h.update(name);
    // mtime in ns su 64 bit: basta e avanza come discriminante nel nome.
    const mt: u64 = @bitCast(@as(i64, @truncate(mtime_ns)));
    return std.fmt.allocPrint(gpa, "{x}-{x}-{x}.thumb", .{ h.final(), mt, size }) catch null;
}

/// Legge una miniatura dalla cache. Ritorna null se assente/corrotta/troncata
/// (mai un errore: la cache è solo un'ottimizzazione). Il buffer ritornato è
/// allineato a 4 come quello di `makeThumb`.
/// Voce negativa: header con dimensioni 0×0 e nessun pixel. Ricorda che il
/// decode di QUESTA versione del file (la chiave contiene mtime e dimensione)
/// è fallito, così riaprire la cartella non lo ritenta (misurato: un WebP che
/// i plugin non leggono costava ~1 s di CPU dei processi figli a ogni visita).
/// Vale `failed_ttl_ns` dalla scrittura e non viene "toccata" in lettura: un
/// fallimento dovuto a un plugin mancante si ritenta il giorno dopo.
const failed_marker: ThumbPix = .{ .rgba = &.{}, .w = 0, .h = 0 };
const failed_ttl_ns: i96 = 24 * std.time.ns_per_hour;

const CacheRead = union(enum) { hit: ThumbPix, failed, miss };

fn thumbCacheRead(h: *const Host, cdir: std.Io.Dir, fname: []const u8) CacheRead {
    const raw = cdir.readFileAlloc(h.io, fname, h.gpa, .limited(thumb_file_max)) catch return .miss;
    defer h.gpa.free(raw);
    if (raw.len < thumb_header_len or !std.mem.startsWith(u8, raw, thumb_magic)) return .miss;
    const w = std.mem.readInt(u32, raw[4..][0..4], .little);
    const ht = std.mem.readInt(u32, raw[8..][0..4], .little);
    const result: CacheRead = blk: {
        if (w == 0 and ht == 0 and raw.len == thumb_header_len) {
            const st = cdir.statFile(h.io, fname, .{}) catch return .miss;
            const age = std.Io.Clock.real.now(h.io).nanoseconds - st.mtime.nanoseconds;
            return if (age < failed_ttl_ns) .failed else .miss;
        }
        if (w == 0 or ht == 0 or @as(usize, w) > thumb_max or @as(usize, ht) > thumb_max) return .miss;
        const need = @as(usize, w) * @as(usize, ht) * 4;
        if (raw.len - thumb_header_len < need) return .miss;
        const rgba = h.gpa.alignedAlloc(u8, .@"4", need) catch return .miss;
        @memcpy(rgba, raw[thumb_header_len..][0..need]);
        break :blk .{ .hit = .{ .rgba = rgba, .w = w, .h = ht } };
    };
    // "Touch" LRU: l'entry appena usata torna in cima (cache_evict ordina per
    // mtime, non per atime). Best-effort.
    // (`Dir.setTimestampsNow` di std 0.16 non compila — vtable disallineata —
    // quindi futimens via fd, Linux-only come le altre cache del progetto.)
    if (comptime builtin.os.tag == .linux) {
        if (cdir.openFile(h.io, fname, .{})) |f| {
            evict.touchFd(f.handle);
            f.close(h.io);
        } else |_| {}
    }
    return result;
}

/// Scrive la miniatura in cache in modo ATOMICO: tmp univoco (thread id + seq)
/// e rename sul nome finale, così un crash a metà scrittura non lascia mai un
/// .thumb parziale che la lettura successiva scambierebbe per valido.
/// Best-effort: ogni errore è ignorato (al più si ridecodifica).
fn thumbCacheWrite(h: *const Host, cdir: std.Io.Dir, fname: []const u8, pix: ThumbPix) void {
    const seq = tmp_seq.fetchAdd(1, .monotonic);
    const tmp = std.fmt.allocPrint(h.gpa, "{s}.tmp{d}_{d}", .{ fname, std.Thread.getCurrentId(), seq }) catch return;
    defer h.gpa.free(tmp);

    var hdr: [thumb_header_len]u8 = undefined;
    @memcpy(hdr[0..4], thumb_magic[0..4]);
    std.mem.writeInt(u32, hdr[4..8], pix.w, .little);
    std.mem.writeInt(u32, hdr[8..12], pix.h, .little);

    const wrote = blk: {
        const f = cdir.createFile(h.io, tmp, .{}) catch break :blk false;
        defer f.close(h.io);
        f.writeStreamingAll(h.io, &hdr) catch break :blk false;
        f.writeStreamingAll(h.io, pix.rgba) catch break :blk false;
        break :blk true;
    };
    if (!wrote) {
        cdir.deleteFile(h.io, tmp) catch {};
        return;
    }
    cdir.rename(tmp, cdir, fname, h.io) catch {
        cdir.deleteFile(h.io, tmp) catch {};
    };
}

// ── Thumb worker ─────────────────────────────────────────────────────────────

/// true se `gen` è ancora la generazione corrente. Check di cancellazione da
/// usare nei cicli lunghi (le `statFile` di una cartella da 512 voci).
fn genAlive(h: *const Host, gen: u32) bool {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    return gen == h.fx.gen;
}

/// Fase dimensioni del thumb worker: le `statFile` avvengono qui, fuori dal
/// thread finestra, e i risultati sono installati per indice sotto lock (le
/// voci non cambiano entro la stessa generazione). Va eseguita PRIMA delle
/// miniature: il guard `size > max_thumb_bytes` legge questi valori, e la
/// chiave della cache su disco è fatta di mtime + size.
/// È anche il punto di INVALIDAZIONE delle miniature ereditate da `adoptThumbs`:
/// se il file è cambiato sul disco la miniatura in RAM è stale e si ributta.
fn fillSizes(h: *const Host, gen: u32) void {
    const Pending = struct { idx: usize, name: []u8 };
    var dir_copy: []u8 = &.{};
    var names: std.ArrayList(Pending) = .empty;
    defer {
        for (names.items) |n| h.gpa.free(n.name);
        names.deinit(h.gpa);
        h.gpa.free(dir_copy);
    }
    {
        // Snapshot di cartella e nomi file sotto lock (poche KB, niente I/O).
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const fx = h.fx;
        if (gen != fx.gen) return;
        dir_copy = h.gpa.dupe(u8, fx.dir) catch return;
        for (fx.entries, 0..) |e, i| {
            if (e.is_dir) continue;
            const nm = h.gpa.dupe(u8, e.name) catch return;
            names.append(h.gpa, .{ .idx = i, .name = nm }) catch {
                h.gpa.free(nm);
                return;
            };
        }
    }
    if (names.items.len == 0) return;

    var dir = std.Io.Dir.cwd().openDir(h.io, dir_copy, .{}) catch return;
    defer dir.close(h.io);
    const Meta = struct { size: u64, mtime_ns: i128 };
    const metas = h.gpa.alloc(Meta, names.items.len) catch return;
    defer h.gpa.free(metas);
    for (names.items, metas, 0..) |n, *m, k| {
        // Cancellazione: 512 `statFile` costano (su Windows ognuna apre un
        // handle), quindi si controlla la generazione ogni 32 voci e non solo
        // alla fine — `enterDir` deve poter riciclare il thread in fretta.
        if (k % 32 == 0 and k != 0 and !genAlive(h, gen)) return;
        if (dir.statFile(h.io, n.name, .{})) |st| {
            m.* = .{ .size = st.size, .mtime_ns = @as(i128, st.mtime.nanoseconds) };
        } else |_| {
            m.* = .{ .size = 0, .mtime_ns = 0 };
        }
    }

    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    const fx = h.fx;
    if (gen != fx.gen) return;
    for (names.items, metas) |n, m| {
        if (n.idx >= fx.entries.len) continue;
        const e = &fx.entries[n.idx];
        // Il file è cambiato dall'ultima apertura: la miniatura ereditata da
        // `adoptThumbs` non lo rappresenta più → si butta e si ritenta (anche
        // in cache, dove la chiave mtime+size è ormai un'altra).
        if (e.thumb_w != 0 and (e.size != m.size or e.mtime_ns != m.mtime_ns)) {
            h.gpa.free(e.thumb_rgba);
            e.thumb_rgba = &.{};
            e.thumb_w = 0;
            e.thumb_h = 0;
            e.thumb_tried = false;
            e.cache_tried = false;
            if (fx.thumb_installed > 0) fx.thumb_installed -= 1;
        }
        e.size = m.size;
        e.mtime_ns = m.mtime_ns;
    }
    h.changed.* = true;
}

/// Fase di un job: prima si spazzola la cache su disco (nessun decode: le
/// cartelle già visitate si riempiono quasi all'istante), poi si decodifica
/// quello che manca.
const Phase = enum { cache, decode };

/// Voce reclamata (nome posseduto + metadati per la chiave di cache).
const Claim = struct {
    name: []u8,
    /// Indice in `fx.entries`: stabile entro la generazione.
    idx: usize,
    mtime_ns: i128,
    size: u64,
    heavy: bool,
};

const ClaimResult = union(enum) {
    claim: Claim,
    /// Generazione superata: uscire senza toccare i contatori.
    stale,
    /// Niente da fare in questa fase. In fase `decode` il job è già stato
    /// tolto da `fx.thumb_jobs`, nello stesso lock in cui ha visto la lista
    /// vuota: così un altro job che sta per ritirarsi sa che non è l'ultimo
    /// solo se lo è davvero (vedi `tryRetire`).
    empty,
    oom,
};

/// Sorgenti oltre questa dimensione sono "pesanti": stb decodifica a piena
/// risoluzione anche nel tier coarse (misurato: un JPEG 9253×5990 da 16 MB
/// porta il processo a 343 MB di RSS e 2,5 s di decode).
pub const heavy_bytes: u64 = 8 * 1024 * 1024;

/// Decode lenti o costosi in RAM: PDF (processo esterno), video (demuxer +
/// decoder), immagini che passano da rsvg/ImageMagick (processi esterni a loro
/// volta multi-thread), file oltre `heavy_bytes`.
fn isHeavy(e: *const Entry) bool {
    if (e.size > heavy_bytes) return true;
    const ext = decoder_mod.getExtension(e.name);
    inline for (.{ "pdf", "svg", "svgz", "tif", "tiff", "avif", "ico" }) |x| {
        if (extEqCi(ext, x)) return true;
    }
    // WebP: su Linux il plugin image lo decodifica in processo con libwebp;
    // altrove passa ancora da ImageMagick.
    if (builtin.os.tag != .linux and extEqCi(ext, "webp")) return true;
    return layout.winKindFromExt(e.name) == .video;
}

/// La voce `e` è da lavorare nella fase `phase`? Con il mutex acquisito.
fn claimable(fx: *const FxState, e: *const Entry, phase: Phase) bool {
    if (e.is_dir or e.thumb_w != 0 or e.size > max_thumb_bytes or !thumbable(e.name)) return false;
    return switch (phase) {
        .cache => !e.cache_tried,
        .decode => !e.thumb_tried and !e.cache_busy and
            !(fx.heavy_inflight >= max_heavy_inflight and isHeavy(e)),
    };
}

/// Toglie il job da `fx.thumb_jobs`. Con il mutex acquisito e `gen` corrente.
fn leaveLocked(h: *const Host, batch: *Batch) void {
    std.debug.assert(!batch.left);
    batch.left = true;
    h.fx.thumb_jobs -= 1;
    if (h.fx.thumb_jobs == 0) if (h.idle_cond) |c| c.broadcast(h.io);
}

/// Reclama sotto lock la prossima voce da lavorare, PARTENDO DALLA PRIMA CARD
/// VISIBILE (`top_row * grid_cols`) e proseguendo circolarmente fino a chiudere
/// il giro: `top_row` è riletto ad OGNI chiamata, quindi lo scroll dell'utente
/// ridirige subito i job sulle card che sta guardando.
/// La marcatura (`cache_tried`/`thumb_tried`) fa da claim: più job sulla stessa
/// generazione non si pestano i piedi.
fn claimNext(h: *const Host, gen: u32, phase: Phase, batch: *Batch) ClaimResult {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    const fx = h.fx;
    // CANCELLAZIONE: questo check sta subito PRIMA di ogni decode, non solo
    // dopo — un `enterDir` concorrente ferma il job entro un decode.
    if (gen != fx.gen) return .stale;
    const found: ?usize = blk: {
        if (@as(usize, fx.thumb_installed) >= max_thumb_files) break :blk null; // tetto RAM
        if (phase == .decode and @as(usize, fx.thumb_attempts) >= max_thumb_files) break :blk null; // tetto CPU
        const n = fx.entries.len;
        if (n == 0) break :blk null;
        const off: usize = @intCast(@max(fx.top_row, 0));
        const first = @min(off *| @as(usize, @intCast(grid_cols)), n - 1);
        for (0..n) |k| {
            const i = (first + k) % n;
            if (claimable(fx, &fx.entries[i], phase)) break :blk i;
        }
        break :blk null;
    };
    const i = found orelse {
        if (phase == .decode) leaveLocked(h, batch);
        return .empty;
    };
    const e = &fx.entries[i];
    const name = h.gpa.dupe(u8, e.name) catch return .oom;
    const heavy = phase == .decode and isHeavy(e);
    switch (phase) {
        .cache => {
            e.cache_tried = true;
            e.cache_busy = true;
        },
        .decode => {
            e.thumb_tried = true;
            fx.thumb_attempts += 1;
            if (heavy) fx.heavy_inflight += 1;
        },
    }
    return .{ .claim = .{ .name = name, .idx = i, .mtime_ns = e.mtime_ns, .size = e.size, .heavy = heavy } };
}

/// Chiude il claim (`cache_busy`, `heavy_inflight`) e, se c'è, installa `pix`.
/// Prende in carico `pix.rgba` (lo libera se non lo installa). Ritorna false se
/// il job deve uscire (generazione superata).
fn finishClaim(h: *const Host, gen: u32, c: Claim, phase: Phase, pix: ?ThumbPix, known_failed: bool) bool {
    h.mutex.lockUncancelable(h.io);
    const fx = h.fx;
    if (gen != fx.gen) {
        h.mutex.unlock(h.io);
        if (pix) |p| h.gpa.free(p.rgba);
        return false;
    }
    const e = &fx.entries[c.idx];
    if (phase == .cache) e.cache_busy = false;
    // Fallimento già noto in cache: niente decode per questa voce.
    if (known_failed) e.thumb_tried = true;
    if (c.heavy) fx.heavy_inflight -= 1;
    var installed = false;
    if (pix) |p| {
        // Con più job il tetto può essere superato di qualche unità fra il
        // claim e qui: si ricontrolla.
        if (e.thumb_w == 0 and @as(usize, fx.thumb_installed) < max_thumb_files) {
            e.thumb_rgba = p.rgba;
            e.thumb_w = p.w;
            e.thumb_h = p.h;
            fx.thumb_installed += 1;
            installed = true;
            h.changed.* = true;
        }
    }
    h.mutex.unlock(h.io);
    if (pix) |p| if (!installed) h.gpa.free(p.rgba);
    return true;
}

/// Un job in più lascia il campo a un decode interattivo, purché non sia
/// l'ultimo della generazione (l'ultimo garantisce che il lavoro finisca).
fn tryRetire(h: *const Host, gen: u32, batch: *Batch) bool {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    if (gen != h.fx.gen) return false;
    if (h.fx.thumb_jobs <= 1) return false;
    leaveLocked(h, batch);
    if (h.stats) |s| _ = s.jobs_retired.fetchAdd(1, .monotonic);
    return true;
}

/// Fan-out: aggiunge job fino a `Host.maxJobs`, ma solo se resta più lavoro
/// da decodificare che job già vivi e nessun decode interattivo è in corso.
fn growJobs(h: *const Host, gen: u32) void {
    const s = scheduler.get() orelse return;
    const max = h.maxJobs();
    while (true) {
        if (scheduler.foregroundActive()) return;
        {
            h.mutex.lockUncancelable(h.io);
            defer h.mutex.unlock(h.io);
            const fx = h.fx;
            if (gen != fx.gen or fx.thumb_jobs >= max) return;
            // Solo il lavoro che un job nuovo potrebbe reclamare ADESSO: con
            // la cache spenta la fase cache non esiste, e le voci pesanti
            // bloccate dal limite non contano. Contarle creava una catena di
            // job che nascevano, non trovavano nulla e ne creavano un altro
            // (misurato: 17× la CPU su una cartella di WebP).
            const use_cache = h.cache != .none;
            var remaining: usize = 0;
            for (fx.entries) |*e| {
                if (claimable(fx, e, .decode) or (use_cache and claimable(fx, e, .cache))) remaining += 1;
            }
            if (remaining <= fx.thumb_jobs) return;
            fx.thumb_jobs += 1;
            if (h.stats) |st| _ = st.max_jobs.fetchMax(fx.thumb_jobs, .monotonic);
        }
        const j = h.gpa.create(Job) catch return undoJoin(h, gen);
        // Le dimensioni le ha già riempite il job che fa il fan-out.
        j.* = .{ .task = Job.task_init, .host = h.*, .gen = gen, .batch = .{ .cooperative = true, .sizes_done = true } };
        s.submit(&j.task) catch {
            h.gpa.destroy(j);
            return undoJoin(h, gen);
        };
        if (h.stats) |st| _ = st.jobs_created.fetchAdd(1, .monotonic);
    }
}

fn undoJoin(h: *const Host, gen: u32) void {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    if (gen != h.fx.gen) return;
    h.fx.thumb_jobs -= 1;
    if (h.fx.thumb_jobs == 0) if (h.idle_cond) |c| c.broadcast(h.io);
}

/// Un giro della fase `phase` sulle voci della generazione `gen`. Ritorna
/// quando la fase è esaurita, la generazione superata o il job deve cedere
/// (`batch.yielded`) o ritirarsi (`batch.left`).
fn thumbPass(h: *const Host, gen: u32, phase: Phase, dir_copy: []const u8, real_dir: []const u8, cdir: ?std.Io.Dir, batch: *Batch) void {
    while (true) {
        if (batch.cooperative) {
            // Almeno una voce per esecuzione, così il batch avanza anche se
            // lavoro più urgente arriva di continuo; poi cede appena ce n'è.
            if (batch.done_this_run > 0 and scheduler.shouldYield(.normal)) {
                batch.yielded = true;
                return;
            }
            if (scheduler.foregroundActive()) {
                if (tryRetire(h, gen, batch)) return;
            } else growJobs(h, gen);
        }
        const claim = switch (claimNext(h, gen, phase, batch)) {
            .claim => |c| c,
            .stale, .empty, .oom => return,
        };
        batch.done_this_run += 1;
        defer h.gpa.free(claim.name);
        // Chiave di cache: hash(realpath cartella + nome) + mtime + size.
        const key: ?[]u8 = if (cdir != null)
            thumbCacheName(h.gpa, real_dir, claim.name, claim.mtime_ns, claim.size)
        else
            null;
        defer if (key) |k| h.gpa.free(k);
        var known_failed = false;
        const pix: ?ThumbPix = switch (phase) {
            .cache => blk: {
                const r: CacheRead = if (key) |k| thumbCacheRead(h, cdir.?, k) else .miss;
                if (h.stats) |s| _ = (if (r == .miss) &s.cache_misses else &s.cache_hits).fetchAdd(1, .monotonic);
                known_failed = r == .failed;
                break :blk if (r == .hit) r.hit else null;
            },
            .decode => decodeOne(h, dir_copy, claim.name, cdir, key, batch),
        };
        if (!finishClaim(h, gen, claim, phase, pix, known_failed)) return;
    }
}

/// Decode + downscale (+ scrittura in cache) di una voce. null se non è
/// un'immagine o il decode fallisce.
fn decodeOne(h: *const Host, dir_copy: []const u8, name: []const u8, cdir: ?std.Io.Dir, key: ?[]const u8, batch: *Batch) ?ThumbPix {
    const t0 = std.Io.Clock.awake.now(h.io).nanoseconds;
    const th = blk: {
        const full = std.fs.path.join(h.gpa, &.{ dir_copy, name }) catch break :blk null;
        defer h.gpa.free(full);
        // Tier coarse quando il plugin lo offre (immagini: pixel ≤512² invece
        // di 4096², ~64 MB risparmiati a decode); altrimenti il decode pieno.
        var d = decoder_mod.decodeCoarse(full, h.io, h.gpa) orelse
            decoder_mod.decode(full, h.io, h.gpa);
        defer d.deinit(h.gpa);
        if (d != .image) break :blk null;
        break :blk makeThumb(h.gpa, d.image.pixels, d.image.width, d.image.height);
    };
    // In cache PRIMA dell'installazione: anche se la generazione è già
    // cambiata il lavoro fatto non va sprecato.
    if (cdir) |cd| if (key) |k| {
        thumbCacheWrite(h, cd, k, th orelse failed_marker);
        batch.writes += 1;
    };
    if (h.stats) |s| {
        _ = (if (th != null) &s.decoded else &s.failed).fetchAdd(1, .monotonic);
        if (th != null) s.recordDecode(h.io, @intCast(std.Io.Clock.awake.now(h.io).nanoseconds - t0));
    }
    return th;
}

/// Stato di un job che sopravvive alle interruzioni: le voci già tentate sono
/// marcate in `FxState` (`claimNext`), qui resta solo il resto.
const Batch = struct {
    cooperative: bool = false,
    sizes_done: bool = false,
    writes: usize = 0,
    yielded: bool = false,
    /// Il job non conta più in `fx.thumb_jobs`.
    left: bool = false,
    done_this_run: usize = 0,
};

/// Esegue (o riprende) il job. Ritorna true se ha ceduto il worker e va
/// risottomesso; false se ha finito, si è ritirato o la generazione è superata.
fn runBatch(h: *const Host, gen: u32, batch: *Batch) bool {
    batch.yielded = false;
    batch.done_this_run = 0;
    if (!batch.sizes_done) {
        fillSizes(h, gen);
        batch.sizes_done = true;
    }
    // Snapshot della cartella: `fx.dir` non cambia entro la generazione.
    var dir_copy: []u8 = &.{};
    {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        if (gen != h.fx.gen) return false;
        dir_copy = h.gpa.dupe(u8, h.fx.dir) catch return false;
    }
    defer h.gpa.free(dir_copy);
    // Realpath della cartella per la chiave di cache (una sola risoluzione per
    // esecuzione); se non è disponibile si ripiega sul percorso così com'è.
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var real_dir: []const u8 = dir_copy;
    if (std.Io.Dir.cwd().realPathFile(h.io, dir_copy, &real_buf)) |n| {
        real_dir = real_buf[0..n];
    } else |_| {}
    const cdir_path = cacheDirPath(h);
    defer if (cdir_path) |p| h.gpa.free(p);
    const cdir: ?std.Io.Dir = if (cdir_path) |p|
        (std.Io.Dir.cwd().openDir(h.io, p, .{}) catch null)
    else
        null;
    defer if (cdir) |d| d.close(h.io);
    if (cdir != null) thumbPass(h, gen, .cache, dir_copy, real_dir, cdir, batch);
    if (batch.yielded) return true;
    if (batch.left) return false;
    thumbPass(h, gen, .decode, dir_copy, real_dir, cdir, batch);
    return batch.yielded;
}

/// Directory della cache su disco (posseduta) o null se disattivata.
fn cacheDirPath(h: *const Host) ?[]u8 {
    return switch (h.cache) {
        // `appCacheDir` crea già la catena: niente subprocess, su Windows
        // `mkdir` non esiste come eseguibile.
        .app => vtcache.appCacheDir(h.gpa, "thumbs"),
        .none => null,
        .path => |p| h.gpa.dupe(u8, p) catch null,
    };
}

/// Una sola manutenzione della cache alla volta per processo.
var maint_busy: std.atomic.Value(bool) = .init(false);

/// Manutenzione best-effort, una volta per job che ha scritto (non a ogni
/// scrittura: è una scansione della directory): sweep dei tmp orfani + cap LRU.
fn maintainCache(h: *const Host) void {
    if (maint_busy.swap(true, .acquire)) return;
    defer maint_busy.store(false, .release);
    const p = cacheDirPath(h) orelse return;
    defer h.gpa.free(p);
    evict.sweepTmpOnce(&tmp_sweep_done, p);
    evict.evictLru(p, thumb_cache_cap_bytes);
}

/// Un job della pipeline: task `normal` dello scheduler globale, si libera da
/// sé in `on_done`. Cooperativo: tra una miniatura e l'altra cede il worker se
/// in coda c'è lavoro più urgente, e si risottomette riprendendo da dove era.
const Job = struct {
    task: scheduler.Task,
    host: Host,
    gen: u32,
    batch: Batch,
    again: bool = false,

    const task_init: scheduler.Task = .{ .run_fn = run, .on_done = done, .priority = .normal };

    fn run(t: *scheduler.Task) void {
        const j: *Job = @fieldParentPtr("task", t);
        j.again = runBatch(&j.host, j.gen, &j.batch);
    }

    fn done(t: *scheduler.Task) void {
        const j: *Job = @fieldParentPtr("task", t);
        const h = &j.host;
        if (t.state == .done and j.again) {
            j.again = false;
            if (scheduler.get()) |s| {
                if (s.submit(&j.task)) |_| return else |err| if (err == error.QueueFull) {
                    // Coda piena: si finisce qui, senza più cedere.
                    j.batch.cooperative = false;
                    _ = runBatch(h, j.gen, &j.batch);
                }
            }
        }
        // Uscita per generazione superata, shutdown o errore: il job esce dal
        // conto se non l'ha già fatto (con generazione superata il conto è già
        // stato azzerato da `bumpGeneration`).
        if (!j.batch.left) {
            h.mutex.lockUncancelable(h.io);
            if (j.gen == h.fx.gen) leaveLocked(h, &j.batch);
            h.mutex.unlock(h.io);
        }
        if (j.batch.writes > 0) maintainCache(h);
        h.gpa.destroy(j);
    }
};

/// Avvia la pipeline per la generazione `gen` (appena creata con
/// `bumpGeneration`). Non blocca: tutto il lavoro gira sui worker. Senza
/// scheduler globale (o se lo scheduler è in chiusura) non fa nulla.
pub fn start(host: Host, gen: u32) void {
    const s = scheduler.get() orelse return;
    {
        host.mutex.lockUncancelable(host.io);
        defer host.mutex.unlock(host.io);
        if (gen != host.fx.gen) return;
        host.fx.thumb_jobs += 1;
        if (host.stats) |st| _ = st.max_jobs.fetchMax(host.fx.thumb_jobs, .monotonic);
    }
    const j = host.gpa.create(Job) catch return undoJoin(&host, gen);
    j.* = .{ .task = Job.task_init, .host = host, .gen = gen, .batch = .{ .cooperative = true } };
    s.submit(&j.task) catch {
        host.gpa.destroy(j);
        return undoJoin(&host, gen);
    };
    if (host.stats) |st| _ = st.jobs_created.fetchAdd(1, .monotonic);
}

/// Esegue tutta la pipeline della generazione `gen` sul thread chiamante, un
/// solo job, senza scheduler (modalità sequenziale del benchmark).
pub fn runInline(host: *const Host, gen: u32) void {
    {
        host.mutex.lockUncancelable(host.io);
        defer host.mutex.unlock(host.io);
        if (gen != host.fx.gen) return;
        host.fx.thumb_jobs += 1;
    }
    var batch: Batch = .{};
    _ = runBatch(host, gen, &batch);
    if (!batch.left) {
        host.mutex.lockUncancelable(host.io);
        if (gen == host.fx.gen) leaveLocked(host, &batch);
        host.mutex.unlock(host.io);
    }
    if (batch.writes > 0) maintainCache(host);
}

// ---------------------------------------------------------------------------
// Test: niente plugin (i decode falliscono), le miniature arrivano dalla cache
// su disco preparata dal test. Così claim, generazioni, fan-out e
// installazione sono deterministici e verificabili.

const testing = std.testing;

/// Task che occupa un worker finché il test non lo apre.
const Block = struct {
    task: scheduler.Task = .{ .run_fn = run, .priority = .normal },
    started: std.atomic.Value(bool) = .init(false),
    open: std.atomic.Value(bool) = .init(false),
    fn run(t: *scheduler.Task) void {
        const b: *@This() = @fieldParentPtr("task", t);
        b.started.store(true, .release);
        while (!b.open.load(.acquire)) std.Thread.yield() catch {};
    }
};

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    src: []u8,
    cache: []u8,
    mutex: std.Io.Mutex = .init,
    idle: std.Io.Condition = .init,
    changed: bool = false,
    fx: FxState = .{},
    stats: Stats = .{},

    /// `on_disk = false`: le voci esistono solo in `fx` (un decode che parte
    /// comunque fallisce nell'host, senza passare dai plugin).
    fn init(io: std.Io, names: []const []const u8, on_disk: bool) !*TestEnv {
        const gpa = testing.allocator;
        const env = try gpa.create(TestEnv);
        errdefer gpa.destroy(env);
        env.* = .{ .tmp = std.testing.tmpDir(.{}), .root = undefined, .src = undefined, .cache = undefined };
        env.root = try std.fs.path.join(gpa, &.{ std.testing.TmpDir.parent_dir_path, &env.tmp.sub_path });
        env.src = try std.fs.path.join(gpa, &.{ env.root, "src" });
        env.cache = try std.fs.path.join(gpa, &.{ env.root, "cache" });
        try env.tmp.dir.createDir(io, "src", .default_dir);
        try env.tmp.dir.createDir(io, "cache", .default_dir);
        const entries = try gpa.alloc(Entry, names.len);
        for (names, entries) |n, *e| {
            const p = try std.fs.path.join(gpa, &.{ "src", n });
            defer gpa.free(p);
            if (on_disk) try env.tmp.dir.writeFile(io, .{ .sub_path = p, .data = n });
            e.* = .{ .name = try gpa.dupe(u8, n), .is_dir = false };
        }
        env.fx.entries = entries;
        env.fx.dir = try gpa.dupe(u8, env.src);
        return env;
    }

    fn host(env: *TestEnv, io: std.Io, jobs: u32) Host {
        return .{
            .io = io,
            .gpa = testing.allocator,
            .mutex = &env.mutex,
            .fx = &env.fx,
            .changed = &env.changed,
            .jobs = jobs,
            .cache = .{ .path = env.cache },
            .idle_cond = &env.idle,
            .stats = &env.stats,
        };
    }

    /// Scrive in cache una miniatura 2×1 riconoscibile per ogni voce `which`.
    fn seedCache(env: *TestEnv, io: std.Io, which: []const usize) !void {
        const h = env.host(io, 1);
        fillSizes(&h, env.fx.gen);
        var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(io, env.src, &real_buf);
        var cdir = try std.Io.Dir.cwd().openDir(io, env.cache, .{});
        defer cdir.close(io);
        for (which) |i| {
            const e = env.fx.entries[i];
            const key = thumbCacheName(testing.allocator, real_buf[0..n], e.name, e.mtime_ns, e.size).?;
            defer testing.allocator.free(key);
            var px: [8]u8 align(4) = .{ @intCast(i), 1, 2, 255, @intCast(i), 3, 4, 255 };
            thumbCacheWrite(&h, cdir, key, .{ .rgba = &px, .w = 2, .h = 1 });
        }
    }

    fn waitIdle(env: *TestEnv, io: std.Io) void {
        env.mutex.lockUncancelable(io);
        defer env.mutex.unlock(io);
        while (env.fx.thumb_jobs != 0) env.idle.waitUncancelable(io, &env.mutex);
    }

    /// Dopo `scheduler.deinitGlobal` (i defer girano al contrario): un job
    /// arrivato al decode può aver caricato un plugin, e il registro dei plugin
    /// è globale.
    fn deinit(env: *TestEnv) void {
        const gpa = testing.allocator;
        decoder_mod.closePluginCache(gpa);
        freeEntries(gpa, env.fx.entries);
        gpa.free(env.fx.dir);
        gpa.free(env.cache);
        gpa.free(env.src);
        gpa.free(env.root);
        env.tmp.cleanup();
        gpa.destroy(env);
    }
};

test "claim: un solo decode pesante alla volta, l'ultimo job non si ritira" {
    var th: std.Io.Threaded = .init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();
    const env = try TestEnv.init(io, &.{ "a.pdf", "b.pdf", "c.png" }, false);
    defer env.deinit();
    const h = env.host(io, 2);
    const gen = env.fx.bumpGeneration();
    env.fx.thumb_jobs = 2;
    var b1: Batch = .{};
    var b2: Batch = .{};
    const c1 = claimNext(&h, gen, .decode, &b1).claim;
    defer testing.allocator.free(c1.name);
    try testing.expectEqualStrings("a.pdf", c1.name);
    try testing.expect(c1.heavy);
    // b.pdf è bloccato dal limite: il secondo job prende c.png.
    const c2 = claimNext(&h, gen, .decode, &b2).claim;
    defer testing.allocator.free(c2.name);
    try testing.expectEqualStrings("c.png", c2.name);
    try testing.expect(finishClaim(&h, gen, c2, .decode, null, false));
    // Il secondo job non trova altro: esce dal conto nello stesso lock.
    try testing.expect(claimNext(&h, gen, .decode, &b2) == .empty);
    try testing.expect(b2.left);
    try testing.expectEqual(@as(u32, 1), env.fx.thumb_jobs);
    // Il primo è rimasto l'ultimo: non può ritirarsi, e prende b.pdf.
    try testing.expect(!tryRetire(&h, gen, &b1));
    try testing.expect(finishClaim(&h, gen, c1, .decode, null, false));
    const c3 = claimNext(&h, gen, .decode, &b1).claim;
    defer testing.allocator.free(c3.name);
    try testing.expectEqualStrings("b.pdf", c3.name);
}

test "claim: il decode salta una voce con lettura dalla cache in corso" {
    var th: std.Io.Threaded = .init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();
    const env = try TestEnv.init(io, &.{ "a.png", "b.png" }, false);
    defer env.deinit();
    const h = env.host(io, 2);
    const gen = env.fx.bumpGeneration();
    env.fx.thumb_jobs = 2;
    var b1: Batch = .{};
    var b2: Batch = .{};
    const r1 = claimNext(&h, gen, .cache, &b1).claim; // a.png in lettura
    defer testing.allocator.free(r1.name);
    const r2 = claimNext(&h, gen, .cache, &b1).claim; // b.png in lettura
    defer testing.allocator.free(r2.name);
    try testing.expect(finishClaim(&h, gen, r2, .cache, null, false)); // b.png: miss
    // Un altro job in fase decode: a.png è ancora in lettura, solo b.png.
    const d = claimNext(&h, gen, .decode, &b2).claim;
    defer testing.allocator.free(d.name);
    try testing.expectEqualStrings("b.png", d.name);
}

test "pipeline parallela e sequenziale producono le stesse miniature" {
    var th: std.Io.Threaded = .init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();
    var names: [40][]const u8 = undefined;
    var name_buf: [40][8]u8 = undefined;
    for (&names, &name_buf, 0..) |*n, *b, i| n.* = std.fmt.bufPrint(b, "f{d:0>2}.png", .{i}) catch unreachable;
    var hashes: [2]u64 = undefined;
    for (0..2) |mode| {
        const env = try TestEnv.init(io, &names, true);
        defer env.deinit();
        // In cache solo le voci pari: le dispari tentano il decode e falliscono.
        var even: [20]usize = undefined;
        for (&even, 0..) |*x, i| x.* = i * 2;
        try env.seedCache(io, &even);
        // Le dispari spariscono dal disco: il decode fallisce nell'host (file
        // illeggibile), senza passare dai plugin.
        for (names, 0..) |n, i| if (i % 2 == 1) {
            const p = try std.fs.path.join(testing.allocator, &.{ "src", n });
            defer testing.allocator.free(p);
            try env.tmp.dir.deleteFile(io, p);
        };
        // Si riparte da zero: le marcature di fillSizes valgono per la gen nuova.
        for (env.fx.entries) |*e| e.* = .{ .name = e.name, .is_dir = false };
        const gen = env.fx.bumpGeneration();
        if (mode == 0) {
            const h = env.host(io, 1);
            runInline(&h, gen);
        } else {
            scheduler.initGlobal(io, .{ .workers = 3 });
            defer scheduler.deinitGlobal();
            start(env.host(io, 3), gen);
            env.waitIdle(io);
        }
        var hs = std.hash.Wyhash.init(0);
        var made: usize = 0;
        for (env.fx.entries, 0..) |e, i| {
            if (e.thumb_w == 0) continue;
            try testing.expect(i % 2 == 0);
            try testing.expectEqual(@as(u8, @intCast(i)), e.thumb_rgba[0]);
            hs.update(e.name);
            hs.update(e.thumb_rgba);
            made += 1;
        }
        try testing.expectEqual(@as(usize, 20), made);
        try testing.expectEqual(@as(u32, 20), env.stats.cache_hits.load(.monotonic));
        try testing.expectEqual(@as(u32, 20), env.stats.failed.load(.monotonic));
        try testing.expectEqual(@as(u32, 0), env.fx.thumb_jobs);
        try testing.expectEqual(@as(u32, 0), env.fx.heavy_inflight);
        hashes[mode] = hs.final();
    }
    try testing.expectEqual(hashes[0], hashes[1]);
}

test "cambio cartella: i job della generazione vecchia non installano nella nuova" {
    var th: std.Io.Threaded = .init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();
    const env = try TestEnv.init(io, &.{ "a.png", "b.png", "c.png" }, true);
    defer env.deinit();
    try env.seedCache(io, &.{ 0, 1, 2 });
    for (env.fx.entries) |*e| e.* = .{ .name = e.name, .is_dir = false };

    scheduler.initGlobal(io, .{ .workers = 1 });
    defer scheduler.deinitGlobal();
    // L'unico worker è occupato: il job della generazione vecchia resta in coda.
    var block = Block{};
    try scheduler.get().?.submit(&block.task);
    while (!block.started.load(.acquire)) std.Thread.yield() catch {};

    env.mutex.lockUncancelable(io);
    const old_gen = env.fx.bumpGeneration();
    env.mutex.unlock(io);
    start(env.host(io, 1), old_gen);

    // "enterDir" su un'altra cartella: voci nuove con gli STESSI nomi (il caso
    // peggiore per un riaggancio per nome) e generazione nuova.
    env.mutex.lockUncancelable(io);
    const new_gen = env.fx.bumpGeneration();
    const fresh = try testing.allocator.alloc(Entry, env.fx.entries.len);
    for (fresh, env.fx.entries) |*f, e| f.* = .{ .name = try testing.allocator.dupe(u8, e.name), .is_dir = false };
    freeEntries(testing.allocator, env.fx.entries);
    env.fx.entries = fresh;
    env.mutex.unlock(io);

    block.open.store(true, .release);
    scheduler.get().?.wait(&block.task);
    // Il job vecchio gira adesso e deve uscire subito. Lo scheduler lo ha
    // eseguito quando la coda torna vuota e i task partiti sono 2.
    while (scheduler.get().?.stats().tasks_run < 2) std.Thread.yield() catch {};
    env.mutex.lockUncancelable(io);
    for (env.fx.entries) |e| try testing.expectEqual(@as(u32, 0), e.thumb_w);
    try testing.expectEqual(@as(u32, 0), env.fx.thumb_jobs);
    try testing.expectEqual(@as(u32, 0), env.fx.thumb_installed);
    env.mutex.unlock(io);
    try testing.expectEqual(@as(u32, 0), env.stats.cache_hits.load(.monotonic));

    // La generazione nuova lavora normalmente.
    start(env.host(io, 1), new_gen);
    env.waitIdle(io);
    for (env.fx.entries) |e| try testing.expect(e.thumb_w != 0);
}

test "tetto RAM: oltre max_thumb_files non si installa" {
    var th: std.Io.Threaded = .init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();
    const env = try TestEnv.init(io, &.{"a.png"}, false);
    defer env.deinit();
    const h = env.host(io, 1);
    const gen = env.fx.bumpGeneration();
    env.fx.thumb_jobs = 1;
    var b: Batch = .{};
    const c = claimNext(&h, gen, .decode, &b).claim;
    defer testing.allocator.free(c.name);
    env.fx.thumb_installed = max_thumb_files; // altri job hanno riempito il tetto
    const px = try testing.allocator.alignedAlloc(u8, .@"4", 4);
    try testing.expect(finishClaim(&h, gen, c, .decode, .{ .rgba = px, .w = 1, .h = 1 }, false));
    try testing.expectEqual(@as(u32, 0), env.fx.entries[0].thumb_w); // e px liberato (niente leak)
}

test "fan-out: nessun job nuovo se resta solo lavoro pesante bloccato" {
    // Regressione: con la cache spenta e un decode pesante in corso, il
    // fan-out contava le voci pesanti bloccate (e la fase cache inesistente)
    // come lavoro: ogni job nuovo ne creava un altro e usciva, all'infinito.
    var th: std.Io.Threaded = .init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();
    const env = try TestEnv.init(io, &.{ "a.pdf", "b.pdf", "c.pdf" }, false);
    defer env.deinit();
    scheduler.initGlobal(io, .{ .workers = 4 });
    defer scheduler.deinitGlobal();
    var h = env.host(io, 4);
    h.cache = .none;
    const gen = env.fx.bumpGeneration();
    env.fx.thumb_jobs = 1;
    var b: Batch = .{};
    const c = claimNext(&h, gen, .decode, &b).claim; // a.pdf in decode
    defer testing.allocator.free(c.name);
    growJobs(&h, gen);
    try testing.expectEqual(@as(u32, 1), env.fx.thumb_jobs);
    try testing.expectEqual(@as(u32, 0), env.stats.jobs_created.load(.monotonic));
    // Con la cache accesa le voci non ancora lette dalla cache contano.
    h.cache = .{ .path = env.cache };
    env.fx.thumb_jobs = 1;
    growJobs(&h, gen);
    try testing.expect(env.stats.jobs_created.load(.monotonic) > 0);
    // I job creati trovano la generazione superata e escono.
    env.mutex.lockUncancelable(io);
    _ = env.fx.bumpGeneration();
    env.mutex.unlock(io);
}

test "cache negativa: un decode fallito non si ritenta alla visita successiva" {
    var th: std.Io.Threaded = .init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();
    const env = try TestEnv.init(io, &.{"gone.png"}, false);
    defer env.deinit();
    const h = env.host(io, 1);
    for (0..2) |visit| {
        for (env.fx.entries) |*e| e.* = .{ .name = e.name, .is_dir = false };
        const gen = env.fx.bumpGeneration();
        runInline(&h, gen);
        // Prima visita: un decode fallito; seconda: nessun decode, voce
        // negativa trovata in cache.
        try testing.expectEqual(@as(u32, 1), env.stats.failed.load(.monotonic));
        try testing.expectEqual(@as(u32, @intCast(visit)), env.stats.cache_hits.load(.monotonic));
    }
}

test "decode interattivo in corso: i job in più si ritirano, l'ultimo resta" {
    var th: std.Io.Threaded = .init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();
    const env = try TestEnv.init(io, &.{ "a.png", "b.png", "c.png", "d.png" }, false);
    defer env.deinit();
    scheduler.initGlobal(io, .{ .workers = 3 });
    defer scheduler.deinitGlobal();
    var h = env.host(io, 3);
    h.cache = .none;
    const gen = env.fx.bumpGeneration();
    env.fx.thumb_jobs = 3;
    var batches: [3]Batch = @splat(.{});
    scheduler.beginForeground();
    try testing.expect(scheduler.foregroundActive());
    // Con il loader al lavoro nessun job nuovo...
    growJobs(&h, gen);
    try testing.expectEqual(@as(u32, 3), env.fx.thumb_jobs);
    // ...e due dei tre si ritirano; il terzo no.
    try testing.expect(tryRetire(&h, gen, &batches[0]));
    try testing.expect(tryRetire(&h, gen, &batches[1]));
    try testing.expect(!tryRetire(&h, gen, &batches[2]));
    try testing.expectEqual(@as(u32, 1), env.fx.thumb_jobs);
    scheduler.endForeground();
    try testing.expect(!scheduler.foregroundActive());
    // Finito il decode il fan-out riparte (c'è più lavoro che job). Worker
    // occupati: i job creati restano in coda e il conto non cambia sotto i
    // piedi del test.
    var blocks: [3]Block = @splat(.{});
    for (&blocks) |*b| try scheduler.get().?.submit(&b.task);
    for (&blocks) |*b| while (!b.started.load(.acquire)) std.Thread.yield() catch {};
    growJobs(&h, gen);
    try testing.expectEqual(@as(u32, 3), env.fx.thumb_jobs);
    env.mutex.lockUncancelable(io);
    _ = env.fx.bumpGeneration(); // i job creati escono appena partono
    env.mutex.unlock(io);
    for (&blocks) |*b| b.open.store(true, .release);
}
