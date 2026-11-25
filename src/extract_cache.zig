//! Cache d'estrazione delle voci d'archivio (`archivio.zip#voce`): dove sta, come si
//! chiamano le sue cartelle, quali nomi di voce si possono scrivere su disco e quando
//! si svuota. L'estrazione vera resta in decoder.zig.
//!
//! Disposizione: `<cache>/extract/<chiave>/<voce>`, una cartella per versione di
//! archivio (chiave = percorso + data di modifica). `<cache>` è quella di
//! `vtcache.appCacheDir`: `%LOCALAPPDATA%\zuer` su Windows, `~/.cache/zuer` altrove.
//!
//! Il tetto è per cartella d'archivio, non per file: le voci di uno stesso archivio
//! si aprono insieme (si sfoglia), quindi si buttano insieme. Conta l'uso più
//! recente: l'ultima voce estratta, o l'ultimo riuso, segnato su un file a parte
//! (`<chiave>.used`, accanto alla cartella). La data delle voci non si tocca mai:
//! a valle fa da chiave ad altre cache (pagine PDF, mesh), e cambiarla a ogni
//! riapertura le farebbe rifare tutte.

const std = @import("std");
const builtin = @import("builtin");
const vtcache = @import("vtcache.zig");

/// Tetto della cache su disco. Una voce sola può arrivare a `max_size` (metà della
/// memoria disponibile), quindi può superarlo: la cartella più recente non si butta mai.
pub const cap_bytes: u64 = 2 * 1024 * 1024 * 1024;

/// Byte estratti fra una pulizia e l'altra. La pulizia cammina tutta la cache: farla
/// a ogni voce, sfogliando un archivio di mille file, costerebbe mille camminate.
const sweep_bytes: u64 = cap_bytes / 16;

/// Una cartella toccata da meno di così non si butta: chi l'ha appena estratta, o
/// appena riusata, sta per aprirne il file (anche da un'altra istanza di zuer).
const min_age_ns: i128 = 60 * std.time.ns_per_s;

/// Un `.part` più vecchio di così è di un processo morto a metà estrazione.
const part_max_age_ns: i128 = std.time.ns_per_hour;

/// Cartella della cache (creata se manca), posseduta dal chiamante. null se la
/// variabile d'ambiente di base non c'è.
pub fn rootDir(gpa: std.mem.Allocator) ?[]u8 {
    return vtcache.appCacheDir(gpa, "extract");
}

/// Chiave della cartella di un archivio: cambia quando l'archivio viene modificato,
/// così le voci estratte dalla versione vecchia non si riusano.
pub fn key(base_path: []const u8, mtime: std.Io.Timestamp) u64 {
    var hasher = std.hash.Wyhash.init(0x2571ee7c0de);
    hasher.update(base_path);
    // I nanosecondi sono un i96: i suoi byte in memoria comprendono un riempimento
    // dal valore non definito. Si passa da un i128 scritto byte per byte.
    var mt: [16]u8 = undefined;
    std.mem.writeInt(i128, &mt, mtime.nanoseconds, .little);
    hasher.update(&mt);
    return hasher.final();
}

const used_suffix = ".used";

/// Segna come appena usata la cartella d'archivio `key_name` (figlia di `root`): la
/// pulizia non la considererà vecchia. Riscrive il file `<chiave>.used`, e la sua data
/// va ad adesso da sola: niente `setTimestamps`, che sui percorsi in Windows non è
/// implementata nella std di Zig 0.17 (panic), e niente file della cache aperti in
/// scrittura mentre un plugin li legge.
pub fn markUsed(io: std.Io, root: std.Io.Dir, key_name: []const u8) void {
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}" ++ used_suffix, .{key_name}) catch return;
    var f = root.createFile(io, name, .{}) catch return;
    f.close(io);
}

var part_seq: std.atomic.Value(u64) = .init(0);

/// Lunghezza massima di un nome scritto da `partName`.
pub const part_name_max = ".part".len + 10 + 1 + 20;

/// Nome del file temporaneo di un'estrazione, da creare nella cartella dell'archivio:
/// con PID e sequenza, perché due estrazioni della stessa voce (due thread, due
/// istanze) non scrivano nello stesso file. Non dipende dal nome della voce: un
/// suffisso aggiunto a un nome già vicino ai 255 byte non entrerebbe nel filesystem.
pub fn partName(buf: *[part_name_max]u8) []const u8 {
    const seq = part_seq.fetchAdd(1, .monotonic);
    return std.fmt.bufPrint(buf, ".part{d}_{d}", .{ vtcache.processId(), seq }) catch unreachable;
}

/// True per i nomi scritti da `partName`: `.part<cifre>_<cifre>`.
fn isPartName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, ".part")) return false;
    const tail = name[".part".len..];
    const us = std.mem.indexOfScalar(u8, tail, '_') orelse return false;
    return allDigits(tail[0..us]) and allDigits(tail[us + 1 ..]);
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// Nome di voce che si può scrivere sotto la cartella della cache senza uscirne.
pub fn isSafeEntryName(name: []const u8) bool {
    return isSafeEntryNameFor(name, builtin.os.tag == .windows);
}

/// Relativo e senza componenti `..` (zip-slip). Con `windows`, in più: niente `:`
/// (lettera di unità `C:\…` o `C:…`, che ignora la cartella di destinazione, e
/// flussi alternativi `file:flusso`), niente componenti che finiscono con punto o
/// spazio (Win32 li toglie: `.. ` diventerebbe `..`) e niente nomi di dispositivo.
pub fn isSafeEntryNameFor(name: []const u8, windows: bool) bool {
    if (name.len == 0) return false;
    if (name[0] == '/' or name[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    if (windows and std.mem.indexOfScalar(u8, name, ':') != null) return false;
    var it = std.mem.splitAny(u8, name, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
        if (windows and !isSafeWindowsComponent(comp)) return false;
    }
    return true;
}

fn isSafeWindowsComponent(comp: []const u8) bool {
    // Vuoto (`a//b`) e `.` (`./a`, come li scrive tar) sono innocui.
    if (comp.len == 0 or std.mem.eql(u8, comp, ".")) return true;
    const last = comp[comp.len - 1];
    if (last == '.' or last == ' ') return false;
    // `NUL`, `nul.txt`, `COM1.tar.gz`: conta il nome prima del primo punto.
    const stem = std.mem.trimEnd(u8, comp[0 .. std.mem.indexOfScalar(u8, comp, '.') orelse comp.len], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |dev| {
        if (std.ascii.eqlIgnoreCase(stem, dev)) return false;
    }
    if (stem.len >= 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
        const n = stem[3..];
        if (n.len == 1 and std.ascii.isDigit(n[0]) and n[0] != '0') return false;
        // Anche le cifre in apice ¹ ² ³ valgono come numero di porta.
        for ([_][]const u8{ "\xc2\xb9", "\xc2\xb2", "\xc2\xb3" }) |sup| {
            if (std.mem.eql(u8, n, sup)) return false;
        }
    }
    return true;
}

/// Byte estratti dall'ultima pulizia. Parte dalla soglia: la prima estrazione di un
/// processo pulisce sempre (la cache può essere piena da una sessione precedente).
var pending_bytes: std.atomic.Value(u64) = .init(sweep_bytes);
var sweeping: std.atomic.Value(bool) = .init(false);

/// Da chiamare dopo ogni estrazione riuscita, con i byte scritti: ogni `sweep_bytes`
/// riporta la cache sotto il tetto. Mai un errore: la cache è un'ottimizzazione.
pub fn noteExtracted(io: std.Io, gpa: std.mem.Allocator, root_path: []const u8, bytes: u64) void {
    const before = pending_bytes.fetchAdd(bytes, .monotonic);
    if (before +| bytes < sweep_bytes) return;
    // Un solo thread alla volta: gli altri hanno già contribuito al conto.
    if (sweeping.swap(true, .acquire)) return;
    defer sweeping.store(false, .release);
    pending_bytes.store(0, .monotonic);
    evict(io, gpa, root_path, cap_bytes);
}

const Group = struct {
    name: []const u8,
    size: u64,
    /// Uso più recente: la modifica più recente fra i file della cartella, la
    /// cartella stessa (se è vuota) e il suo `.used`.
    newest: i128,

    fn older(_: void, a: Group, b: Group) bool {
        return a.newest < b.newest;
    }
};

/// Butta le cartelle d'archivio usate meno di recente finché la cache rientra in
/// `cap`. Non tocca la più recente né quelle più giovani di `min_age_ns`. Best-effort.
pub fn evict(io: std.Io, gpa: std.mem.Allocator, root_path: []const u8, cap: u64) void {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    const now: i128 = std.Io.Timestamp.now(io, .real).nanoseconds;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var groups: std.ArrayList(Group) = .empty;
    var markers: std.ArrayList([]const u8) = .empty;
    var total: u64 = 0;
    var it = root.iterate();
    while (it.next(io) catch null) |e| {
        // Qui dentro scriviamo solo cartelle e i loro `.used`: il resto non è nostro
        // e resta dov'è. Il tipo dato da readdir non basta: su alcuni filesystem
        // (NFS, FUSE) è sconosciuto, e decide lo stat dentro `measure`.
        if (std.mem.endsWith(u8, e.name, used_suffix)) {
            if (e.kind == .directory) continue;
            markers.append(arena, arena.dupe(u8, e.name) catch return) catch return;
            continue;
        }
        if (e.kind != .directory and e.kind != .unknown) continue;
        const name = arena.dupe(u8, e.name) catch return;
        const g = measure(io, gpa, root, name, now) orelse continue;
        groups.append(arena, g) catch return;
        total +|= g.size;
    }

    // Un `.used` rimasto senza la sua cartella (pulizia di un'altra istanza).
    for (markers.items) |m| {
        const owner = m[0 .. m.len - used_suffix.len];
        for (groups.items) |g| {
            if (std.mem.eql(u8, g.name, owner)) break;
        } else root.deleteFile(io, m) catch {};
    }

    if (total <= cap or groups.items.len < 2) return;

    std.mem.sort(Group, groups.items, {}, Group.older);
    for (groups.items[0 .. groups.items.len - 1]) |g| {
        if (total <= cap) break;
        if (now - g.newest < min_age_ns) break; // in ordine: le successive sono più giovani
        // La misura può essere vecchia di secondi (si sono camminate tutte le altre
        // cartelle): se nel frattempo qualcuno l'ha usata, resta.
        const again = measure(io, gpa, root, g.name, now) orelse continue;
        if (now - again.newest < min_age_ns) continue;
        root.deleteTree(io, g.name) catch continue;
        var buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}" ++ used_suffix, .{g.name})) |m| root.deleteFile(io, m) catch {} else |_| {}
        total -|= g.size;
    }
}

/// Dimensione e uso più recente di una cartella d'archivio; strada facendo toglie i
/// `.part` orfani. null se non è una cartella o non si riesce a leggerla.
fn measure(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, name: []const u8, now: i128) ?Group {
    const own = root.statFile(io, name, .{ .follow_symlinks = false }) catch return null;
    if (own.kind != .directory) return null;
    var g: Group = .{ .name = name, .size = 0, .newest = own.mtime.nanoseconds };

    var buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}" ++ used_suffix, .{name})) |m| {
        if (root.statFile(io, m, .{ .follow_symlinks = false })) |st| {
            g.newest = @max(g.newest, st.mtime.nanoseconds);
        } else |_| {}
    } else |_| {}

    var dir = root.openDir(io, name, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(gpa) catch return null;
    defer walker.deinit();
    while (walker.next(io) catch return null) |e| {
        // Dove readdir non dà il tipo decide lo stat. (Lì il walker non scende nelle
        // sottocartelle: quelle voci sfuggono al conto, non alla cancellazione.)
        if (e.kind != .file and e.kind != .unknown) continue;
        const st = e.dir.statFile(io, e.basename, .{ .follow_symlinks = false }) catch continue;
        if (st.kind != .file) continue;
        const mtime: i128 = st.mtime.nanoseconds;
        if (isPartName(e.basename) and now - mtime > part_max_age_ns) {
            e.dir.deleteFile(io, e.basename) catch {};
            continue;
        }
        g.size +|= st.size;
        g.newest = @max(g.newest, mtime);
    }
    return g;
}

test "nomi di voce: relativi e senza .." {
    const ok = isSafeEntryNameFor;
    try std.testing.expect(ok("a.txt", false));
    try std.testing.expect(ok("dir/sub/a.txt", false));
    try std.testing.expect(ok("./a.txt", false));
    try std.testing.expect(ok("a:b.txt", false)); // su POSIX i due punti sono un carattere qualsiasi
    try std.testing.expect(ok("nul", false));
    try std.testing.expect(!ok("", false));
    try std.testing.expect(!ok("/etc/passwd", false));
    try std.testing.expect(!ok("\\a", false));
    try std.testing.expect(!ok("../a", false));
    try std.testing.expect(!ok("a/../../b", false));
    try std.testing.expect(!ok("a\\..\\b", false));
    try std.testing.expect(!ok("a\x00b", false));
}

test "nomi di voce su Windows: unità, flussi, dispositivi, punti in coda" {
    const ok = isSafeEntryNameFor;
    try std.testing.expect(ok("a.txt", true));
    try std.testing.expect(ok("dir/sub/a.txt", true));
    try std.testing.expect(ok("./dir/a.txt", true));
    try std.testing.expect(ok("console.txt", true));
    try std.testing.expect(ok("com0.txt", true));
    try std.testing.expect(ok("comune/lpt.txt", true));
    try std.testing.expect(!ok("C:\\Windows\\x.dll", true));
    try std.testing.expect(!ok("C:/Windows/x.dll", true));
    try std.testing.expect(!ok("C:x.dll", true));
    try std.testing.expect(!ok("a.txt:flusso", true));
    try std.testing.expect(!ok("dir/.. /a", true));
    try std.testing.expect(!ok("dir/.../a", true));
    try std.testing.expect(!ok("a.txt.", true));
    try std.testing.expect(!ok("a.txt ", true));
    try std.testing.expect(!ok("NUL", true));
    try std.testing.expect(!ok("dir/nul.txt", true));
    try std.testing.expect(!ok("Com1.tar.gz", true));
    try std.testing.expect(!ok("lpt9", true));
    try std.testing.expect(!ok("COM\xc2\xb9", true));
    try std.testing.expect(!ok("lpt\xc2\xb3.txt", true));
    try std.testing.expect(ok("com10", true));
    try std.testing.expect(ok("comò.txt", true));
    try std.testing.expect(!ok("aux .txt", true));
}

test "chiave: stabile, e diversa se cambia l'archivio" {
    const t1: std.Io.Timestamp = .{ .nanoseconds = 1_700_000_000_123_456_789 };
    const t2: std.Io.Timestamp = .{ .nanoseconds = 1_700_000_000_123_456_790 };
    try std.testing.expectEqual(key("/a/b.zip", t1), key("/a/b.zip", t1));
    try std.testing.expect(key("/a/b.zip", t1) != key("/a/b.zip", t2));
    try std.testing.expect(key("/a/b.zip", t1) != key("/a/c.zip", t1));
    const neg: std.Io.Timestamp = .{ .nanoseconds = -5 };
    try std.testing.expectEqual(key("/a/b.zip", neg), key("/a/b.zip", neg));
}

test "nomi temporanei: unici e riconoscibili" {
    var b1: [part_name_max]u8 = undefined;
    var b2: [part_name_max]u8 = undefined;
    const p1 = partName(&b1);
    const p2 = partName(&b2);
    try std.testing.expect(!std.mem.eql(u8, p1, p2));
    try std.testing.expect(isPartName(p1));
    try std.testing.expect(isPartName(".part4294967295_18446744073709551615"));
    try std.testing.expect(".part4294967295_18446744073709551615".len <= part_name_max);
    try std.testing.expect(!isPartName("a.part1_2"));
    try std.testing.expect(!isPartName(".part"));
    try std.testing.expect(!isPartName(".part_3"));
    try std.testing.expect(!isPartName(".part1.rar"));
    try std.testing.expect(!isPartName("a.txt"));
}

test "pulizia: via le cartelle usate meno di recente, mai la più recente né le giovani" {
    // `Dir.setTimestamps`, che qui serve a invecchiare i file, su Windows va in panic.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try std.fs.path.join(a, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    defer a.free(root_path);

    const now = std.Io.Timestamp.now(io, .real);
    const hour: i96 = std.time.ns_per_hour;
    const blob: [1000]u8 = @splat(0);
    const Old = struct {
        fn set(dir: std.Io.Dir, tio: std.Io, path: []const u8, t: i96) !void {
            try dir.setTimestamps(tio, path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = t } } });
        }
    };
    // Quattro archivi da 1000 byte: di quattro, tre e due ore fa, e uno di adesso.
    for ([_]struct { []const u8, i96 }{ .{ "a4", 4 * hour }, .{ "b3", 3 * hour }, .{ "c2", 2 * hour }, .{ "d0", 0 } }) |c| {
        var d = try tmp.dir.createDirPathOpen(io, c[0], .{});
        defer d.close(io);
        var sub = try d.createDirPathOpen(io, "dentro", .{});
        defer sub.close(io);
        try sub.writeFile(io, .{ .sub_path = "voce.bin", .data = &blob });
        try Old.set(sub, io, "voce.bin", now.nanoseconds - c[1]);
        try Old.set(tmp.dir, io, c[0], now.nanoseconds - c[1]);
    }
    // Un `.part` orfano, un `.used` senza cartella e un file che non è nostro.
    try tmp.dir.writeFile(io, .{ .sub_path = "c2/.part77_1", .data = &blob });
    try Old.set(tmp.dir, io, "c2/.part77_1", now.nanoseconds - 2 * hour);
    try Old.set(tmp.dir, io, "c2", now.nanoseconds - 2 * hour);
    try tmp.dir.writeFile(io, .{ .sub_path = "sparita.used", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "estraneo.txt", .data = "x" });

    // Sotto il tetto restano tutte; via il `.part` orfano e il `.used` senza cartella.
    evict(io, a, root_path, 10_000);
    try tmp.dir.access(io, "a4/dentro/voce.bin", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "c2/.part77_1", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "sparita.used", .{}));
    try Old.set(tmp.dir, io, "c2", now.nanoseconds - 2 * hour); // togliere il `.part` l'ha ringiovanita

    // Un riuso segna la più vecchia come appena usata, senza toccare la voce.
    const before = try tmp.dir.statFile(io, "a4/dentro/voce.bin", .{});
    markUsed(io, tmp.dir, "a4");
    const after = try tmp.dir.statFile(io, "a4/dentro/voce.bin", .{});
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);

    // Tetto a 3000: ne va via una, la meno usata — che ora è `b3`, non `a4`.
    evict(io, a, root_path, 3000);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "b3", .{}));
    try tmp.dir.access(io, "a4/dentro/voce.bin", .{});
    try tmp.dir.access(io, "c2/dentro/voce.bin", .{});
    try tmp.dir.access(io, "d0/dentro/voce.bin", .{});

    // Tetto a zero: va via `c2`; `a4` e `d0` sono giovani, e ciò che non è nostro resta.
    evict(io, a, root_path, 0);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "c2", .{}));
    try tmp.dir.access(io, "a4/dentro/voce.bin", .{});
    try tmp.dir.access(io, "d0/dentro/voce.bin", .{});
    try tmp.dir.access(io, "estraneo.txt", .{});

    // `a4` torna vecchia: se ne va col suo `.used`. La più recente resta sempre.
    try Old.set(tmp.dir, io, "a4.used", now.nanoseconds - 4 * hour);
    evict(io, a, root_path, 0);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "a4", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "a4.used", .{}));
    try tmp.dir.access(io, "d0/dentro/voce.bin", .{});
}
