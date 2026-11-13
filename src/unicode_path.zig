//! Percorsi con gli accenti in un'altra forma Unicode.
//!
//! Lo stesso nome si può scrivere con byte diversi: "è" composto (U+00E8, NFC) oppure
//! "e" + accento combinante (U+0065 U+0300, NFD). macOS (APFS, HFS+) apre il file in
//! entrambe le forme; Linux e Windows confrontano i byte, quindi solo la forma con cui
//! il file è stato salvato esiste. Un percorso può arrivare nella forma sbagliata:
//! - da macOS, dove `NSURL fileURLWithPath:` e `fileSystemRepresentation` decompongono
//!   sempre (lo fa anche Darling, che però gira su un filesystem Linux: `open -a` vi
//!   consegna "città" decomposto anche se sul disco è composto);
//! - su Linux, per un file copiato da un Mac (nome decomposto) e scritto a mano o
//!   incollato in forma composta.
//!
//! `findEquivalent` ritrova il percorso che esiste davvero: solo DOPO che quello ricevuto
//! non è stato trovato, solo per i componenti che non esistono e possono avere
//! un'altra forma (byte non ASCII, o ";" "`" "K", vedi `mayHaveOtherForm`), elencando la sola cartella che li contiene (nessuna ricerca ricorsiva). Il
//! nome scelto è quello di una voce della cartella canonicamente equivalente (stessa
//! NFD); se le voci equivalenti sono più d'una non se ne sceglie nessuna.

const std = @import("std");
const data = @import("unicode_nfd_data.zig");

/// Caratteri massimi di un nome decomposto. Un nome di file è al più 255 byte su
/// Linux/macOS, 255 caratteri UTF-16 su Windows (fino a 765 byte UTF-8): ogni
/// carattere si espande al più a `max_decomposition_len`.
const max_nfd = 765 * data.max_decomposition_len;

// --- decomposizione canonica ----------------------------------------------------------

const hangul_s_base: u21 = 0xAC00;
const hangul_l_base: u21 = 0x1100;
const hangul_v_base: u21 = 0x1161;
const hangul_t_base: u21 = 0x11A7;
const hangul_t_count: u21 = 28;
const hangul_n_count: u21 = 21 * hangul_t_count;
const hangul_s_count: u21 = 19 * hangul_n_count;

fn combiningClass(cp: u21) u8 {
    if (cp < 0x300) return 0;
    const ranges = &data.ccc_ranges;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < ranges[mid].first) hi = mid else if (cp > ranges[mid].last) lo = mid + 1 else return ranges[mid].class;
    }
    return 0;
}

fn decomposition(cp: u21) ?[]const u21 {
    if (cp < 0xC0) return null;
    const i = std.sort.binarySearch(u21, &data.decomp_keys, cp, struct {
        fn order(k: u21, item: u21) std.math.Order {
            return std.math.order(k, item);
        }
    }.order) orelse return null;
    return data.decomp_values[data.decomp_offsets[i]..data.decomp_offsets[i + 1]];
}

/// NFD di `s` (UTF-8) in `out`. Null se `s` non è UTF-8 valido o non ci sta.
fn nfd(s: []const u8, out: []u21) ?[]u21 {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return null).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= hangul_s_base and cp < hangul_s_base + hangul_s_count) {
            if (n + 3 > out.len) return null;
            const s_index = cp - hangul_s_base;
            out[n] = hangul_l_base + s_index / hangul_n_count;
            out[n + 1] = hangul_v_base + (s_index % hangul_n_count) / hangul_t_count;
            n += 2;
            const t = s_index % hangul_t_count;
            if (t != 0) {
                out[n] = hangul_t_base + t;
                n += 1;
            }
        } else if (decomposition(cp)) |d| {
            if (n + d.len > out.len) return null;
            @memcpy(out[n..][0..d.len], d);
            n += d.len;
        } else {
            if (n >= out.len) return null;
            out[n] = cp;
            n += 1;
        }
    }
    // Riordino canonico: nelle sequenze di caratteri con classe diversa da zero, ordine
    // stabile per classe (insertion sort: le sequenze sono di pochi caratteri).
    const r = out[0..n];
    var i: usize = 1;
    while (i < r.len) : (i += 1) {
        const c = combiningClass(r[i]);
        if (c == 0) continue;
        var j = i;
        while (j > 0) : (j -= 1) {
            const p = combiningClass(r[j - 1]);
            if (p == 0 or p <= c) break;
            std.mem.swap(u21, &r[j - 1], &r[j]);
        }
    }
    return r;
}

fn isAscii(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return false;
    return true;
}

/// Vero se `s` può avere una forma equivalente con byte diversi: contiene byte non
/// ASCII, oppure un carattere ASCII che è la NFD di uno non ASCII (";" di U+037E,
/// "`" di U+1FEF, "K" di U+212A: da macOS o Darling quei nomi arrivano in ASCII).
fn mayHaveOtherForm(s: []const u8) bool {
    for (s) |b| {
        if (b >= 0x80 or std.mem.indexOfScalar(u8, data.ascii_nfd_targets, b) != null) return true;
    }
    return false;
}

/// Vero se `a` e `b` sono lo stesso testo Unicode, anche con byte diversi (stessa NFD).
/// Byte non UTF-8 validi: uguali solo se identici.
pub fn canonicallyEqual(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    // Testo ASCII ha una sola forma: due nomi diversi in ASCII restano diversi.
    if (isAscii(a) and isAscii(b)) return false;
    var buf_a: [max_nfd]u21 = undefined;
    var buf_b: [max_nfd]u21 = undefined;
    const na = nfd(a, &buf_a) orelse return false;
    const nb = nfd(b, &buf_b) orelse return false;
    return std.mem.eql(u21, na, nb);
}

// --- risoluzione del percorso ---------------------------------------------------------

pub const FindError = error{
    /// Nessun file con quel nome, in nessuna forma.
    FileNotFound,
    /// Nella cartella ci sono più nomi equivalenti a quello cercato (su Linux "città"
    /// composto e decomposto possono coesistere come due file): non se ne sceglie uno.
    AmbiguousName,
    OutOfMemory,
    /// Cartella intermedia illeggibile, permessi, ecc.
    Unreadable,
};

/// Il percorso che esiste davvero per `path`, quando `path` non è stato trovato perché
/// qualche nome ha gli accenti in un'altra forma Unicode. Da chiamare SOLO dopo che
/// l'accesso a `path` ha dato FileNotFound. Allocato con `gpa`.
pub fn findEquivalent(io: std.Io, gpa: std.mem.Allocator, path: []const u8) FindError![]u8 {
    // Un percorso tutto ASCII senza ";", "`", "K" ha una sola forma: niente da cercare.
    if (!mayHaveOtherForm(path)) return error.FileNotFound;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // Le cartelle si aprono solo per attraversarle (basta il permesso di ricerca);
    // quella da elencare si riapre con `iterate` in `equivalentEntry`. Mai `cwd()`
    // stesso: non si può elencare, quindi un percorso relativo parte da ".".
    var it = std.fs.path.componentIterator(path);
    const root = it.root();
    if (root) |r| try out.appendSlice(gpa, r);
    var dir = std.Io.Dir.cwd().openDir(io, root orelse ".", .{}) catch return error.Unreadable;
    defer dir.close(io);

    var first = true;
    while (it.next()) |comp| {
        var chosen: []const u8 = comp.name;
        var chosen_owned: ?[]u8 = null;
        defer if (chosen_owned) |c| gpa.free(c);

        if (dir.statFile(io, comp.name, .{})) |_| {} else |err| switch (err) {
            error.FileNotFound => {
                if (!mayHaveOtherForm(comp.name)) return error.FileNotFound;
                chosen_owned = try equivalentEntry(io, gpa, dir, comp.name);
                chosen = chosen_owned.?;
            },
            else => return error.Unreadable,
        }

        if (!first) try out.append(gpa, std.fs.path.sep);
        try out.appendSlice(gpa, chosen);
        first = false;

        if (it.peekNext() != null) {
            const next = dir.openDir(io, chosen, .{}) catch |err| return switch (err) {
                error.FileNotFound, error.NotDir => error.FileNotFound,
                else => error.Unreadable,
            };
            dir.close(io);
            dir = next;
        }
    }
    if (first) return error.FileNotFound; // nessun componente
    return out.toOwnedSlice(gpa);
}

/// La sola voce di `dir` canonicamente equivalente a `name`, allocata con `gpa`. La NFD
/// di `name` si calcola una volta; una voce tutta ASCII è già in NFD e si confronta
/// senza decomporla.
fn equivalentEntry(io: std.Io, gpa: std.mem.Allocator, parent: std.Io.Dir, name: []const u8) FindError![]u8 {
    var dir = parent.openDir(io, ".", .{ .iterate = true }) catch return error.Unreadable;
    defer dir.close(io);
    var want_buf: [max_nfd]u21 = undefined;
    const want = nfd(name, &want_buf) orelse return error.FileNotFound;
    var entry_buf: [max_nfd]u21 = undefined;

    var found: ?[]u8 = null;
    errdefer if (found) |f| gpa.free(f);
    var it = dir.iterate();
    while (it.next(io) catch return error.Unreadable) |entry| {
        const same = if (isAscii(entry.name))
            entry.name.len == want.len and for (entry.name, want) |b, c| {
                if (b != c) break false;
            } else true
        else if (nfd(entry.name, &entry_buf)) |got| std.mem.eql(u21, got, want) else false;
        if (!same) continue;
        if (found != null) return error.AmbiguousName;
        found = try gpa.dupe(u8, entry.name);
    }
    return found orelse error.FileNotFound;
}

// --- test -----------------------------------------------------------------------------

const nfc_e = "\xc3\xa8"; // è, U+00E8
const nfd_e = "e\xcc\x80"; // e + U+0300

test "canonicallyEqual: composto e decomposto" {
    try std.testing.expect(canonicallyEqual("citt\xc3\xa0", "citta\xcc\x80"));
    try std.testing.expect(canonicallyEqual("perch" ++ "\xc3\xa9" ++ " " ++ nfc_e, "perche\xcc\x81 " ++ nfd_e));
    try std.testing.expect(!canonicallyEqual("citt\xc3\xa0", "citt\xc3\xa1")); // à ≠ á
    try std.testing.expect(!canonicallyEqual("citta", "citta\xcc\x80")); // l'accento conta
    try std.testing.expect(!canonicallyEqual("a.txt", "b.txt"));
    // Più accenti combinanti in ordine diverso: ậ = a + U+0323 (classe 220) + U+0302 (230).
    try std.testing.expect(canonicallyEqual("a\xcc\xa3\xcc\x82", "a\xcc\x82\xcc\xa3"));
    try std.testing.expect(canonicallyEqual("\xe1\xba\xad", "a\xcc\x82\xcc\xa3")); // U+1EAD
    // Hangul: 한 (U+D55C) = ᄒ ᅡ ᆫ.
    try std.testing.expect(canonicallyEqual("\xed\x95\x9c", "\xe1\x84\x92\xe1\x85\xa1\xe1\x86\xab"));
    // Non latino senza decomposizione: solo per byte.
    try std.testing.expect(canonicallyEqual("\xe6\x97\xa5\xe6\x9c\xac", "\xe6\x97\xa5\xe6\x9c\xac"));
    try std.testing.expect(!canonicallyEqual("\xe6\x97\xa5", "\xe6\x9c\xac"));
    // Greco con due segni: ᾅ (U+1F85) = α + U+0314 + U+0301 + U+0345.
    try std.testing.expect(canonicallyEqual("\xe1\xbe\x85", "\xce\xb1\xcc\x94\xcc\x81\xcd\x85"));
    // Byte non UTF-8: nessuna equivalenza inventata.
    try std.testing.expect(!canonicallyEqual("\xff" ++ nfc_e, "\xff" ++ nfd_e));
    try std.testing.expect(canonicallyEqual("\xff", "\xff"));
}

fn tmpRealPath(io: std.Io, tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

test "findEquivalent: file e cartella con l'accento nell'altra forma" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Su disco: cartella e file composti (NFC).
    try tmp.dir.createDirPath(io, "prova " ++ nfc_e);
    try tmp.dir.writeFile(io, .{ .sub_path = "prova " ++ nfc_e ++ "/perch" ++ nfc_e ++ ".txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ascii.txt", .data = "a" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpRealPath(io, &tmp, &buf);

    // Ricevuto decomposto (NFD), come lo consegna `open -a` sotto Darling.
    const asked = try std.fs.path.join(gpa, &.{ base, "prova " ++ nfd_e, "perch" ++ nfd_e ++ ".txt" });
    defer gpa.free(asked);
    const want = try std.fs.path.join(gpa, &.{ base, "prova " ++ nfc_e, "perch" ++ nfc_e ++ ".txt" });
    defer gpa.free(want);
    const got = try findEquivalent(io, gpa, asked);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);

    // Il caso inverso: su disco decomposto, chiesto composto.
    try tmp.dir.writeFile(io, .{ .sub_path = "caff" ++ nfd_e, .data = "d" });
    const asked2 = try std.fs.path.join(gpa, &.{ base, "caff" ++ nfc_e });
    defer gpa.free(asked2);
    const got2 = try findEquivalent(io, gpa, asked2);
    defer gpa.free(got2);
    try std.testing.expectEqualStrings("caff" ++ nfd_e, std.fs.path.basename(got2));
}

test "findEquivalent: percorso relativo, componente mancante per primo" {
    // Cambiare la cartella corrente del processo di test non riesce sotto Wine
    // (BadPathName): il test gira su Linux e macOS.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "citt\xc3\xa0.png", .data = "x" });
    // Il primo componente è quello da cercare: si elenca la cartella corrente.
    var prev_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prev = prev_buf[0..try std.Io.Dir.cwd().realPath(io, &prev_buf)];
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.process.setCurrentPath(io, try tmpRealPath(io, &tmp, &buf));
    defer std.process.setCurrentPath(io, prev) catch {};
    const got = try findEquivalent(io, gpa, "citta\xcc\x80.png");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("citt\xc3\xa0.png", got);
}

test "findEquivalent: inesistente, ASCII, nome davvero diverso, ambiguo" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "citt\xc3\xa0.png", .data = "x" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpRealPath(io, &tmp, &buf);

    for ([_][]const u8{
        "manca.png", // tutto ASCII: nessuna ricerca
        "citt\xc3\xa1.png", // á, non à: un nome davvero diverso
        "manca " ++ nfd_e,
    }) |name| {
        const p = try std.fs.path.join(gpa, &.{ base, name });
        defer gpa.free(p);
        try std.testing.expectError(error.FileNotFound, findEquivalent(io, gpa, p));
    }

    // Su Linux due forme equivalenti possono essere due file distinti. Chiesta una
    // terza forma (accenti combinanti in ordine non canonico), nessuna coincide coi
    // byte e le equivalenti sono due: non se ne sceglie nessuna.
    try tmp.dir.writeFile(io, .{ .sub_path = "x a\xcc\xa3\xcc\x82", .data = "1" }); // a + U+0323 + U+0302 (NFD)
    try tmp.dir.writeFile(io, .{ .sub_path = "x \xe1\xba\xad", .data = "2" }); // U+1EAD (NFC)
    const amb = try std.fs.path.join(gpa, &.{ base, "x a\xcc\x82\xcc\xa3" });
    defer gpa.free(amb);
    try std.testing.expectError(error.AmbiguousName, findEquivalent(io, gpa, amb));

    // Un nome non ASCII può equivalere a uno ASCII: il segno Kelvin (U+212A) è "K".
    try tmp.dir.writeFile(io, .{ .sub_path = "K.txt", .data = "k" });
    const kelvin = try std.fs.path.join(gpa, &.{ base, "\xe2\x84\xaa.txt" });
    defer gpa.free(kelvin);
    const got_k = try findEquivalent(io, gpa, kelvin);
    defer gpa.free(got_k);
    try std.testing.expectEqualStrings("K.txt", std.fs.path.basename(got_k));

    // E al contrario: sul disco il carattere non ASCII, chiesto nella sua NFD ASCII
    // (come lo manda macOS/Darling per U+037E, il punto interrogativo greco).
    try tmp.dir.writeFile(io, .{ .sub_path = "perch\xcd\xbe.txt", .data = "q" }); // U+037E
    const greek = try std.fs.path.join(gpa, &.{ base, "perch;.txt" });
    defer gpa.free(greek);
    const got_q = try findEquivalent(io, gpa, greek);
    defer gpa.free(got_q);
    try std.testing.expectEqualStrings("perch\xcd\xbe.txt", std.fs.path.basename(got_q));
    // Un nome ASCII senza quei caratteri non ha altre forme: nessuna ricerca.
    try std.testing.expect(!mayHaveOtherForm("manca.png"));
    try std.testing.expect(mayHaveOtherForm("Kelvin.png"));

    // Un componente intermedio che non è una cartella.
    const through = try std.fs.path.join(gpa, &.{ base, "citt\xc3\xa0.png", "dentro " ++ nfd_e });
    defer gpa.free(through);
    try std.testing.expectError(error.FileNotFound, findEquivalent(io, gpa, through));
}
