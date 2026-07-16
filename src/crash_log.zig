//! Crash log per zuer-gui, scritto dal panic handler: su Windows l'exe ha
//! subsystem GUI, quindi un panic NON ha stderr — l'app sparisce senza traccia.
//! Ogni panic appende una riga a `%LOCALAPPDATA%\zuer\crash.log` (Windows) o
//! `~/.cache/zuer/crash.log` (altrove), poi il chiamante prosegue col panic
//! handler di default. Contesto di panic: niente allocatore, niente `std.Io`,
//! solo buffer su stack ed externs grezze (stile vtcache.zig); ogni errore è
//! silenzioso, mai far panicare il panic.

const std = @import("std");
const builtin = @import("builtin");
const is_win = builtin.os.tag == .windows;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn time(t: ?*i64) i64;

const posix = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
    const O_WRONLY: c_int = 0x1;
    const O_CREAT: c_int = 0x40;
    const O_APPEND: c_int = 0x400;
};

const win = struct {
    const HANDLE = ?*anyopaque;
    extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, tmpl: HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: u32, written: ?*u32, ov: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) i32;
    const FILE_APPEND_DATA: u32 = 0x0004;
    const FILE_SHARE_RW: u32 = 0x3;
    const OPEN_ALWAYS: u32 = 4;
    const INVALID: HANDLE = @ptrFromInt(std.math.maxInt(usize));
};

/// Percorso del log in `buf`, con la directory creata best-effort. La dir
/// passa da un buffer proprio: due bufPrintZ sullo stesso buffer si aliasano.
/// null se manca la variabile d'ambiente di base o il path non entra.
fn logPath(buf: []u8) ?[:0]const u8 {
    const base = getenv(if (is_win) "LOCALAPPDATA" else "HOME") orelse return null;
    const sub = if (is_win) "\\zuer" else "/.cache/zuer";
    var dir_buf: [520]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}{s}", .{ std.mem.span(base), sub }) catch return null;
    mkdirOne(dir);
    return std.fmt.bufPrintZ(buf, "{s}{s}", .{ dir, if (is_win) "\\crash.log" else "/crash.log" }) catch null;
}

fn mkdirOne(path: [:0]const u8) void {
    if (is_win) {
        var wbuf: [520]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], path) catch return;
        wbuf[n] = 0;
        _ = win.CreateDirectoryW(wbuf[0..n :0], null);
    } else {
        _ = posix.mkdir(path, 0o755);
    }
}

fn appendLine(path: [:0]const u8, line: []const u8) void {
    if (is_win) {
        var wbuf: [520]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], path) catch return;
        wbuf[n] = 0;
        const h = win.CreateFileW(wbuf[0..n :0], win.FILE_APPEND_DATA, win.FILE_SHARE_RW, null, win.OPEN_ALWAYS, 0, null);
        if (h == win.INVALID or h == null) return;
        defer _ = win.CloseHandle(h);
        var written: u32 = 0;
        _ = win.WriteFile(h, line.ptr, @intCast(line.len), &written, null);
    } else {
        const fd = posix.open(path, posix.O_WRONLY | posix.O_CREAT | posix.O_APPEND, 0o644);
        if (fd < 0) return;
        defer _ = posix.close(fd);
        _ = posix.write(fd, line.ptr, line.len);
    }
}

/// Percorso del crash log (per chi lo legge/archivia, es. crash_report.zig).
pub fn logFilePath(buf: []u8) ?[:0]const u8 {
    return logPath(buf);
}

/// Appende `panic <epoch>s @ 0x<addr>: <msg>` al crash log. Best-effort.
pub fn writeCrash(msg: []const u8, first_trace_addr: ?usize) void {
    var path_buf: [560]u8 = undefined;
    const path = logPath(&path_buf) orelse return;
    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "panic {d}s @ 0x{x}: {s}\n", .{
        time(null), first_trace_addr orelse 0, msg,
    }) catch return;
    appendLine(path, line);
}
