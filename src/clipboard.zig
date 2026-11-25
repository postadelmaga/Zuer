//! Cross-platform "copy text to the system clipboard", so the GUI stays OS-agnostic.
//!
//! - Windows: `OpenClipboard`/`SetClipboardData(CF_UNICODETEXT)` (UTF-16).
//! - macOS: pipe the text to `pbcopy`; paste reads `pbpaste`.
//! - Linux/other: pipe the text to `wl-copy` (wl-clipboard) — zrame has no Wayland
//!   clipboard of its own to extend yet.
//!
//! The subprocess is bounded by `copy_deadline_ms` (written with poll, reaped or
//! killed at the deadline): `wl-copy` normally detaches at once, but on a compositor
//! without data-control it can sit waiting for focus. `copy` still blocks for up to
//! that long, so the window thread uses `copyAsync`.

const std = @import("std");
const builtin = @import("builtin");

/// Put `text` (UTF-8) on the system clipboard. Best-effort: failures are silent, exactly
/// like the previous behavior (a missing `wl-copy` was already a no-op). May block for
/// up to `copy_deadline_ms`: call it from a worker thread, or use `copyAsync`.
pub fn copy(text: []const u8) void {
    if (text.len == 0) return;
    impl.copy(text);
}

/// Like `copy`, but never blocks the caller: the text is duplicated and the copy runs
/// on its own short-lived thread. For the window thread (Ctrl+C).
pub fn copyAsync(text: []const u8) void {
    if (text.len == 0) return;
    if (comptime builtin.os.tag == .windows) return impl.copy(text); // API call, no subprocess
    const gpa = std.heap.page_allocator;
    const dup = gpa.dupe(u8, text) catch return;
    const t = std.Thread.spawn(.{}, copyThread, .{dup}) catch {
        gpa.free(dup);
        return;
    };
    t.detach();
}

fn copyThread(text: []u8) void {
    impl.copy(text);
    std.heap.page_allocator.free(text);
}

/// Program whose stdout is the clipboard text, for callers that paste through a
/// subprocess (everything but Windows): `pbpaste` on macOS, `wl-paste -n` elsewhere.
pub const paste_argv: []const []const u8 = if (builtin.os.tag.isDarwin()) &.{"pbpaste"} else &.{ "wl-paste", "-n" };

/// Upper bound for the copy subprocess, write included.
pub const copy_deadline_ms: i64 = 3000;

/// Read text (UTF-8, caller frees) from the system clipboard. Windows only:
/// on other OSes returns null and callers keep their own path (the GUI reads
/// the Wayland selection via `wl-paste`, which needs subprocess plumbing).
pub fn pasteAlloc(gpa: std.mem.Allocator) ?[]u8 {
    return impl.pasteAlloc(gpa);
}

const impl = switch (builtin.os.tag) {
    .windows => struct {
        const HANDLE = ?*anyopaque;
        extern "user32" fn OpenClipboard(hWndNewOwner: HANDLE) callconv(.winapi) i32;
        extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
        extern "user32" fn SetClipboardData(uFormat: u32, hMem: HANDLE) callconv(.winapi) HANDLE;
        extern "user32" fn GetClipboardData(uFormat: u32) callconv(.winapi) HANDLE;
        extern "user32" fn CloseClipboard() callconv(.winapi) i32;
        extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(.winapi) HANDLE;
        extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) i32;
        extern "kernel32" fn GlobalFree(hMem: HANDLE) callconv(.winapi) HANDLE;
        const CF_UNICODETEXT: u32 = 13;
        const GMEM_MOVEABLE: u32 = 0x0002;

        fn copy(text: []const u8) void {
            const gpa = std.heap.page_allocator;
            const utf16 = std.unicode.utf8ToUtf16LeAllocZ(gpa, text) catch return;
            defer gpa.free(utf16);
            const bytes = (utf16.len + 1) * 2; // include the null terminator
            // The clipboard owns `h` only once SetClipboardData succeeds: every
            // earlier failure path must GlobalFree it or the allocation leaks.
            const h = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return;
            const dst = GlobalLock(h) orelse {
                _ = GlobalFree(h);
                return;
            };
            const d: [*]u16 = @ptrCast(@alignCast(dst));
            @memcpy(d[0..utf16.len], utf16[0..utf16.len]);
            d[utf16.len] = 0;
            _ = GlobalUnlock(h);
            if (OpenClipboard(null) == 0) {
                _ = GlobalFree(h);
                return;
            }
            defer _ = CloseClipboard();
            _ = EmptyClipboard();
            if (SetClipboardData(CF_UNICODETEXT, h) == null) _ = GlobalFree(h);
        }

        fn pasteAlloc(gpa: std.mem.Allocator) ?[]u8 {
            if (OpenClipboard(null) == 0) return null;
            defer _ = CloseClipboard();
            const h = GetClipboardData(CF_UNICODETEXT) orelse return null;
            const p = GlobalLock(h) orelse return null;
            defer _ = GlobalUnlock(h);
            const w: [*:0]const u16 = @ptrCast(@alignCast(p));
            return std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(w)) catch null;
        }
    },
    else => struct {
        extern "c" fn pipe(fds: *[2]c_int) c_int;
        extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
        // Variadica come in C: su macOS arm64 gli argomenti variabili passano
        // dallo stack, e dichiarata a tre argomenti fissi leggerebbe altro.
        extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
        extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
        extern "c" fn close(fd: c_int) c_int;
        extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
        extern "c" fn kill(pid: c_int, sig: c_int) c_int;
        extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;
        extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
        const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
        const POLLOUT: c_short = 0x004;
        const Timespec = extern struct { sec: c_long, nsec: c_long };
        const CLOCK_MONOTONIC: c_int = if (builtin.os.tag.isDarwin()) 6 else 1;
        const O_NONBLOCK: c_int = if (builtin.os.tag.isDarwin()) 0x0004 else 0o4000;
        const WNOHANG: c_int = 1;

        fn nowMs() i64 {
            var ts: Timespec = .{ .sec = 0, .nsec = 0 };
            _ = clock_gettime(CLOCK_MONOTONIC, &ts);
            return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
        }

        extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, file_actions: ?*const anyopaque, attrp: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
        extern "c" fn posix_spawn_file_actions_init(fa: *anyopaque) c_int;
        extern "c" fn posix_spawn_file_actions_destroy(fa: *anyopaque) c_int;
        extern "c" fn posix_spawn_file_actions_adddup2(fa: *anyopaque, fd: c_int, newfd: c_int) c_int;
        extern "c" fn posix_spawn_file_actions_addclose(fa: *anyopaque, fd: c_int) c_int;
        extern "c" var environ: [*:null]const ?[*:0]const u8;

        /// pipe con O_CLOEXEC: senza, un figlio spawnato in parallelo da un altro
        /// thread erediterebbe il write-end e wl-copy non vedrebbe mai l'EOF.
        /// L'adddup2 del figlio giusto azzera CLOEXEC sul fd duplicato.
        /// Su Linux `pipe2` è atomica; altrove fallback `pipe` + `fcntl`.
        fn pipeCloexec(fds: *[2]c_int) c_int {
            if (builtin.os.tag == .linux) {
                return pipe2(fds, 0o2000000); // O_CLOEXEC (Linux)
            } else {
                if (pipe(fds) != 0) return -1;
                _ = fcntl(fds[0], 2, @as(c_int, 1)); // F_SETFD, FD_CLOEXEC
                _ = fcntl(fds[1], 2, @as(c_int, 1));
                return 0;
            }
        }

        fn copy(text: []const u8) void {
            var fds: [2]c_int = undefined;
            if (pipeCloexec(&fds) != 0) return;
            const rfd = fds[0];
            const wfd = fds[1];

            var fa: [256]u8 align(16) = undefined;
            if (posix_spawn_file_actions_init(&fa) != 0) {
                _ = close(rfd);
                _ = close(wfd);
                return;
            }
            defer _ = posix_spawn_file_actions_destroy(&fa);
            _ = posix_spawn_file_actions_adddup2(&fa, rfd, 0); // child stdin ← pipe read end
            _ = posix_spawn_file_actions_addclose(&fa, wfd);

            const tool: [*:0]const u8 = if (comptime builtin.os.tag.isDarwin()) "pbcopy" else "wl-copy";
            var argv = [_:null]?[*:0]const u8{tool};
            var pid: c_int = 0;
            const rc = posix_spawnp(&pid, tool, &fa, null, &argv, environ);
            _ = close(rfd);
            if (rc != 0) {
                _ = close(wfd);
                return;
            }
            // Everything below is bounded by one deadline. The write end is
            // non-blocking: a tool that never reads would otherwise hold us on a
            // full pipe forever, before we even get to wait for it.
            const deadline = nowMs() + copy_deadline_ms;
            _ = fcntl(wfd, 4, fcntl(wfd, 3, @as(c_int, 0)) | O_NONBLOCK); // F_SETFL, F_GETFL
            var off: usize = 0;
            while (off < text.len) {
                const n = write(wfd, text.ptr + off, text.len - off);
                if (n > 0) {
                    off += @intCast(n);
                    continue;
                }
                const left = deadline - nowMs();
                if (left <= 0) break;
                var pfd = [1]PollFd{.{ .fd = wfd, .events = POLLOUT, .revents = 0 }};
                // Pipe full (EAGAIN) → wait for room; reader gone (EPIPE) → poll
                // reports an error condition and the next write fails for good.
                if (poll(&pfd, 1, @intCast(@min(left, 200))) < 0) break;
                if (pfd[0].revents & ~POLLOUT != 0) break;
            }
            _ = close(wfd); // EOF: the tool takes the selection and goes to background
            // Reap it, but not forever: past the deadline it is killed.
            var none: [1]PollFd = undefined;
            while (true) {
                const w = waitpid(pid, null, WNOHANG);
                if (w == pid or w < 0) return;
                if (nowMs() >= deadline) break;
                _ = poll(&none, 0, 10);
            }
            _ = kill(pid, 9);
            _ = waitpid(pid, null, 0);
        }

        fn pasteAlloc(_: std.mem.Allocator) ?[]u8 {
            return null; // i chiamanti Wayland passano da `wl-paste` (subprocess)
        }
    },
};
