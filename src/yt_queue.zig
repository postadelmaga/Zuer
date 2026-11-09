//! Parti pure della coda "guarda dopo" e della qualità automatica degli stream
//! YouTube (testate qui, usate da `yt_search.zig`): il formato del file della
//! coda e la scelta dell'altezza dello stream.

const std = @import("std");
const builtin = @import("builtin");

// ── Qualità automatica ───────────────────────────────────────────────────────

/// Altezze che Auto sceglie (le stesse dei chip fissi).
pub const rungs = [_]u32{ 360, 480, 720, 1080 };

/// Altezza Auto per una vista alta `view_h` pixel: il gradino più alto che non
/// supera la vista di oltre il 10%, mai sotto 720p. Il minimo c'è perché dopo
/// l'apertura la finestra si adatta al video: partendo da una finestra piccola,
/// un video piccolo la terrebbe piccola per sempre.
pub fn autoHeight(view_h: u32) u32 {
    const limit = @as(u64, view_h) * 11 / 10;
    var best: u32 = 720;
    for (rungs) |r| {
        if (r <= limit and r > best) best = r;
    }
    return best;
}

/// Auto alza la qualità dello stream corrente (alto `stream_h`) quando la vista è
/// cresciuta (finestra ingrandita, schermo intero). Non la abbassa mai: ogni
/// cambio riapre lo stream, e rimpicciolire la finestra non lo giustifica.
pub fn shouldRaise(stream_h: u32, view_h: u32) bool {
    return stream_h > 0 and autoHeight(view_h) > stream_h;
}

/// Secondi di vista stabile prima di alzare: il resize della finestra e
/// l'ingresso a schermo intero passano per misure intermedie.
pub const raise_after_s: f32 = 1.5;

// ── File della coda ──────────────────────────────────────────────────────────

/// Prima riga del file: formato e versione.
pub const header = "zuer-ytqueue 1";

/// I campi di una voce, come stanno nel file (slice nella riga letta).
pub const Fields = struct { id: []const u8, title: []const u8, duration: []const u8, channel: []const u8 };

/// Una riga del file: i quattro campi separati da tab, senza tab né a capo nei
/// campi (diventano spazi).
pub fn writeLine(w: *std.Io.Writer, f: Fields) std.Io.Writer.Error!void {
    inline for (.{ f.id, f.title, f.duration, f.channel }, 0..) |field, i| {
        if (i > 0) try w.writeByte('\t');
        for (field) |c| try w.writeByte(if (c == '\t' or c == '\n' or c == '\r') ' ' else c);
    }
    try w.writeByte('\n');
}

/// I campi di una riga, o null se non è una voce valida (id di YouTube di 11
/// caratteri, titolo presente). Le righe malformate si saltano.
pub fn parseLine(line: []const u8) ?Fields {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line, "\r"), '\t');
    const id = it.next() orelse return null;
    const title = it.next() orelse return null;
    const duration = it.next() orelse "";
    const channel = it.next() orelse "";
    if (id.len != 11 or title.len == 0) return null;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return null;
    }
    return .{ .id = id, .title = title, .duration = duration, .channel = channel };
}

/// Percorso del file della coda (posseduto), nella cartella dei dati utente di
/// Zuer come i soundfont: `~/.local/share/zuer` (POSIX) o `%APPDATA%\zuer`.
/// Non in `~/.cache/zuer`, che si svuota da sé.
pub fn filePath(gpa: std.mem.Allocator, home: []const u8) ![]u8 {
    const sub: []const u8 = if (builtin.os.tag == .windows) "zuer" else ".local/share/zuer";
    return std.fs.path.join(gpa, &.{ home, sub, "ytqueue.tsv" });
}

test "autoHeight: gradino per la vista, almeno 720p" {
    try std.testing.expectEqual(@as(u32, 720), autoHeight(0));
    try std.testing.expectEqual(@as(u32, 720), autoHeight(432));
    try std.testing.expectEqual(@as(u32, 720), autoHeight(900)); // finestra 1600×900: 990 < 1080
    try std.testing.expectEqual(@as(u32, 1080), autoHeight(1000));
    try std.testing.expectEqual(@as(u32, 1080), autoHeight(1080)); // schermo intero 1080p
    try std.testing.expectEqual(@as(u32, 1080), autoHeight(2160)); // oltre 1080p non si sale
}

test "shouldRaise: solo verso l'alto, solo con uno stream" {
    try std.testing.expect(shouldRaise(720, 1080));
    try std.testing.expect(!shouldRaise(720, 720));
    try std.testing.expect(!shouldRaise(1080, 400));
    try std.testing.expect(!shouldRaise(0, 1080));
}

test "riga della coda: andata e ritorno, campi ripuliti" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeLine(&w, .{ .id = "8wMlJHuudWQ", .title = "Daitarn\t3\nsigla", .duration = "2:11", .channel = "Canale" });
    const line = w.buffered();
    try std.testing.expectEqualStrings("8wMlJHuudWQ\tDaitarn 3 sigla\t2:11\tCanale\n", line);
    const f = parseLine(line[0 .. line.len - 1]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("8wMlJHuudWQ", f.id);
    try std.testing.expectEqualStrings("Daitarn 3 sigla", f.title);
    try std.testing.expectEqualStrings("2:11", f.duration);
    try std.testing.expectEqualStrings("Canale", f.channel);
}

test "parseLine: righe non valide scartate" {
    try std.testing.expect(parseLine(header) == null);
    try std.testing.expect(parseLine("") == null);
    try std.testing.expect(parseLine("corto\ttitolo") == null);
    try std.testing.expect(parseLine("8wMlJHuudW!\ttitolo") == null);
    try std.testing.expect(parseLine("8wMlJHuudWQ\t") == null);
    const f = parseLine("8wMlJHuudWQ\tsolo titolo\r") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("solo titolo", f.title);
    try std.testing.expectEqualStrings("", f.channel);
}
