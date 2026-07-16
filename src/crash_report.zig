//! Report dei crash, al PROSSIMO avvio (mai rete dentro un panic handler):
//! se `crash.log` (vedi crash_log.zig) non è vuoto lo POSTa via curl al
//! receiver PHP su arch_php (server/zuer-crash.php), che deduplica e apre
//! l'issue GitHub col token custodito server-side — NIENTE token nel binario.
//! Il log è rinominato in `crash.log.reported` solo a invio riuscito,
//! altrimenti resta e si riprova all'avvio successivo.
//! Override endpoint: ZUER_CRASH_URL. Opt-out: ZUER_NO_CRASH_REPORT=1.

const std = @import("std");
const builtin = @import("builtin");
const decoder_mod = @import("decoder.zig");
const crash_log = @import("crash_log.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Endpoint di default. DEVE stare sotto un dominio con certificato valido
/// (curl verifica il TLS): l'IP nudo di arch_php non va bene, il path
/// definitivo va deciso col deploy di server/zuer-crash.php.
const default_url = "https://150.230.157.31/zuer-crash.php"; // TODO: dominio reale

/// Da lanciare su un thread all'avvio della GUI: file I/O + curl.
pub fn maybeReport(io: std.Io, gpa: std.mem.Allocator) void {
    if (getenv("ZUER_NO_CRASH_REPORT") != null) return;

    var path_buf: [560]u8 = undefined;
    const log_path = crash_log.logFilePath(&path_buf) orelse return;

    const content = std.Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(1 << 20)) catch return;
    defer gpa.free(content);
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) return;

    if (!postLog(gpa, log_path)) return;

    // Inviato: archivia il log così non si ripropone a ogni avvio.
    var reported_buf: [572]u8 = undefined;
    const reported = std.fmt.bufPrint(&reported_buf, "{s}.reported", .{log_path}) catch return;
    std.Io.Dir.cwd().rename(log_path, std.Io.Dir.cwd(), reported, io) catch {};
}

/// POST del file di log all'endpoint. curl c'è su Linux e su Windows 10+
/// (System32); true solo su HTTP 2xx (`-f`).
fn postLog(gpa: std.mem.Allocator, log_path: []const u8) bool {
    const url: []const u8 = if (getenv("ZUER_CRASH_URL")) |u| std.mem.span(u) else default_url;

    const data_arg = std.fmt.allocPrint(gpa, "--data-binary=@{s}", .{log_path}) catch return false;
    defer gpa.free(data_arg);
    const platform = "X-Zuer-Platform: " ++ @tagName(builtin.os.tag) ++ " " ++ @tagName(builtin.mode);

    var res = decoder_mod.runCaptureTimeout(gpa, &.{
        "curl",   "-fsS",
        "-m",     "15",
        "-H",     "Content-Type: text/plain",
        "-H",     platform,
        data_arg, url,
    }, 20_000) catch return false;
    defer res.deinit(gpa);
    return res.exit_code == 0;
}
