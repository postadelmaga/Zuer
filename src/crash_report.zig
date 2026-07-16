//! Report dei crash, al PROSSIMO avvio (mai rete dentro un panic handler):
//! se `crash.log` (vedi crash_log.zig) non è vuoto, prova due trasporti in
//! ordine, e archivia il log in `.reported` appena UNO riesce:
//!
//!  1. POST del log al receiver (server/zuer-crash.php), che deduplica e apre
//!     l'issue GitHub col token custodito server-side — NIENTE token nel
//!     binario. Attivo solo se configurato via `ZUER_CRASH_URL` (l'endpoint di
//!     default è un placeholder: senza un dominio con certificato valido curl
//!     rifiuterebbe il TLS, quindi il default non viene nemmeno tentato).
//!  2. Fallback SENZA infrastruttura: apre il browser sulla pagina "new issue"
//!     di GitHub precompilata con titolo + coda del log — l'utente rivede e
//!     clicca Invia. Funziona sempre, ovunque, senza server né token.
//!
//! Fallito tutto, il log resta e si riprova al prossimo avvio.
//! Opt-out totale: ZUER_NO_CRASH_REPORT=1. Solo receiver, niente browser:
//! ZUER_CRASH_NO_BROWSER=1 (utile in CI/headless).

const std = @import("std");
const builtin = @import("builtin");
const decoder_mod = @import("decoder.zig");
const crash_log = @import("crash_log.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const repo_slug = "postadelmaga/Zuer";
/// Coda del log inclusa nell'URL dell'issue (l'URL intero deve stare nei limiti
/// pratici dei browser, ~8 KB dopo il percent-encoding).
const max_body_log = 2500;

/// Da lanciare su un thread all'avvio della GUI: file I/O + curl/browser.
pub fn maybeReport(io: std.Io, gpa: std.mem.Allocator) void {
    if (getenv("ZUER_NO_CRASH_REPORT") != null) return;

    var path_buf: [560]u8 = undefined;
    const log_path = crash_log.logFilePath(&path_buf) orelse return;

    const content = std.Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(1 << 20)) catch return;
    defer gpa.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return;

    // 1) Receiver, se configurato. 2) Browser sulla issue precompilata.
    const sent = postToReceiver(gpa, log_path) or openIssueInBrowser(gpa, trimmed);
    if (!sent) return; // riprova al prossimo avvio

    // Riuscito: archivia il log così non si ripropone a ogni avvio.
    var reported_buf: [572]u8 = undefined;
    const reported = std.fmt.bufPrint(&reported_buf, "{s}.reported", .{log_path}) catch return;
    std.Io.Dir.cwd().rename(log_path, std.Io.Dir.cwd(), reported, io) catch {};
}

/// POST del file di log al receiver `ZUER_CRASH_URL`. Assente = niente receiver
/// (il default è un placeholder: senza dominio+cert curl fallirebbe comunque il
/// TLS). curl c'è su Linux e su Windows 10+ (System32). true solo su HTTP 2xx.
fn postToReceiver(gpa: std.mem.Allocator, log_path: []const u8) bool {
    const url = getenv("ZUER_CRASH_URL") orelse return false;

    const data_arg = std.fmt.allocPrint(gpa, "--data-binary=@{s}", .{log_path}) catch return false;
    defer gpa.free(data_arg);
    const platform = "X-Zuer-Platform: " ++ @tagName(builtin.os.tag) ++ " " ++ @tagName(builtin.mode);

    var res = decoder_mod.runCaptureTimeout(gpa, &.{
        "curl",   "-fsS",
        "-m",     "15",
        "-H",     "Content-Type: text/plain",
        "-H",     platform,
        data_arg, std.mem.span(url),
    }, 20_000) catch return false;
    defer res.deinit(gpa);
    return res.exit_code == 0;
}

/// Fallback: apre il browser sulla pagina "new issue" di GitHub precompilata.
/// true se l'handoff al browser è riuscito. Saltabile con ZUER_CRASH_NO_BROWSER.
fn openIssueInBrowser(gpa: std.mem.Allocator, log: []const u8) bool {
    if (getenv("ZUER_CRASH_NO_BROWSER") != null) return false;
    const url = buildIssueUrl(gpa, log) orelse return false;
    defer gpa.free(url);
    return openBrowser(gpa, url);
}

/// `…/issues/new?title=…&labels=crash&body=…` con titolo dalla prima riga del
/// log e corpo con la coda del log in un fence. Chiamante libera.
fn buildIssueUrl(gpa: std.mem.Allocator, log: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const first_nl = std.mem.indexOfScalar(u8, log, '\n') orelse log.len;
    const title_line = log[0..@min(first_nl, 90)];
    const tail = if (log.len > max_body_log) log[log.len - max_body_log ..] else log;

    out.appendSlice(gpa, "https://github.com/" ++ repo_slug ++ "/issues/new?labels=crash&title=") catch return null;
    appendEnc(&out, gpa, "crash zuer-gui: ") catch return null;
    appendEnc(&out, gpa, title_line) catch return null;
    out.appendSlice(gpa, "&body=") catch return null;
    appendEnc(&out, gpa, "Report automatico dal crash log (") catch return null;
    appendEnc(&out, gpa, @tagName(builtin.os.tag)) catch return null;
    appendEnc(&out, gpa, ", ") catch return null;
    appendEnc(&out, gpa, @tagName(builtin.mode)) catch return null;
    appendEnc(&out, gpa, ").\n\n```\n") catch return null;
    appendEnc(&out, gpa, tail) catch return null;
    appendEnc(&out, gpa, "\n```\n") catch return null;
    return out.toOwnedSlice(gpa) catch null;
}

/// Percent-encoding per query string (RFC 3986: passano solo gli unreserved).
fn appendEnc(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| {
        const unreserved = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(gpa, ch);
        } else {
            var hex: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&hex, "%{X:0>2}", .{ch}) catch unreachable;
            try out.appendSlice(gpa, &hex);
        }
    }
}

const shell = struct {
    extern "shell32" fn ShellExecuteW(hwnd: ?*anyopaque, verb: ?[*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: i32) callconv(.winapi) ?*anyopaque;
};

/// Apre `url` nel browser predefinito. true se l'handoff è riuscito.
fn openBrowser(gpa: std.mem.Allocator, url: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        const url_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, url) catch return false;
        defer gpa.free(url_w);
        const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
        const h = shell.ShellExecuteW(null, verb, url_w, null, null, 1); // SW_SHOWNORMAL
        // Da documentazione ShellExecute: successo se il valore restituito è > 32.
        return @intFromPtr(h) > 32;
    } else if (comptime builtin.os.tag == .macos) {
        var res = decoder_mod.runCaptureTimeout(gpa, &.{ "open", url }, 10_000) catch return false;
        defer res.deinit(gpa);
        return res.exit_code == 0;
    } else {
        var res = decoder_mod.runCaptureTimeout(gpa, &.{ "xdg-open", url }, 10_000) catch return false;
        defer res.deinit(gpa);
        return res.exit_code == 0;
    }
}
