//! Cross-platform "copy text to the system clipboard", so the GUI stays OS-agnostic.
//!
//! - Windows: `OpenClipboard`/`SetClipboardData(CF_UNICODETEXT)` (UTF-16).
//! - Linux/other: pipe the text to `wl-copy` (wl-clipboard) — zrame has no Wayland
//!   clipboard of its own to extend yet.

const std = @import("std");
const builtin = @import("builtin");

/// Put `text` (UTF-8) on the system clipboard. Best-effort: failures are silent, exactly
/// like the previous behavior (a missing `wl-copy` was already a no-op).
pub fn copy(text: []const u8) void {
    if (text.len == 0) return;
    impl.copy(text);
}

const impl = switch (builtin.os.tag) {
    .windows => struct {
        const HANDLE = ?*anyopaque;
        extern "user32" fn OpenClipboard(hWndNewOwner: HANDLE) callconv(.winapi) i32;
        extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
        extern "user32" fn SetClipboardData(uFormat: u32, hMem: HANDLE) callconv(.winapi) HANDLE;
        extern "user32" fn CloseClipboard() callconv(.winapi) i32;
        extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(.winapi) HANDLE;
        extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) i32;
        const CF_UNICODETEXT: u32 = 13;
        const GMEM_MOVEABLE: u32 = 0x0002;

        fn copy(text: []const u8) void {
            const gpa = std.heap.page_allocator;
            const utf16 = std.unicode.utf8ToUtf16LeAllocZ(gpa, text) catch return;
            defer gpa.free(utf16);
            const bytes = (utf16.len + 1) * 2; // include the null terminator
            const h = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return;
            const dst = GlobalLock(h) orelse return;
            const d: [*]u16 = @ptrCast(@alignCast(dst));
            @memcpy(d[0..utf16.len], utf16[0..utf16.len]);
            d[utf16.len] = 0;
            _ = GlobalUnlock(h);
            if (OpenClipboard(null) == 0) return;
            defer _ = CloseClipboard();
            _ = EmptyClipboard();
            // On success the clipboard owns `h` (do not free it).
            _ = SetClipboardData(CF_UNICODETEXT, h);
        }
    },
    else => struct {
        extern "c" fn pipe(fds: *[2]c_int) c_int;
        extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
        extern "c" fn close(fd: c_int) c_int;
        extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
        extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, file_actions: ?*const anyopaque, attrp: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
        extern "c" fn posix_spawn_file_actions_init(fa: *anyopaque) c_int;
        extern "c" fn posix_spawn_file_actions_destroy(fa: *anyopaque) c_int;
        extern "c" fn posix_spawn_file_actions_adddup2(fa: *anyopaque, fd: c_int, newfd: c_int) c_int;
        extern "c" fn posix_spawn_file_actions_addclose(fa: *anyopaque, fd: c_int) c_int;
        extern "c" var environ: [*:null]const ?[*:0]const u8;

        fn copy(text: []const u8) void {
            var fds: [2]c_int = undefined;
            if (pipe(&fds) != 0) return;
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

            const wlcopy: [*:0]const u8 = "wl-copy";
            var argv = [_:null]?[*:0]const u8{wlcopy};
            var pid: c_int = 0;
            const rc = posix_spawnp(&pid, wlcopy, &fa, null, &argv, environ);
            _ = close(rfd);
            if (rc != 0) {
                _ = close(wfd);
                return;
            }
            var off: usize = 0;
            while (off < text.len) {
                const n = write(wfd, text.ptr + off, text.len - off);
                if (n <= 0) break;
                off += @intCast(n);
            }
            _ = close(wfd); // EOF: wl-copy takes the selection and goes to background
            var status: c_int = 0;
            _ = waitpid(pid, &status, 0);
        }
    },
};
