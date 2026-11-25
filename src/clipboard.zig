//! Cross-platform "copy text to the system clipboard", so the GUI stays OS-agnostic.
//!
//! - Windows: `OpenClipboard`/`SetClipboardData(CF_UNICODETEXT)` (UTF-16).
//! - macOS: pipe the text to `pbcopy`; paste reads `pbpaste`.
//! - Linux/other: pipe the text to `wl-copy` (wl-clipboard) — zrame has no Wayland
//!   clipboard of its own to extend yet.
//!
//! The subprocess goes through `proc.runFeed`, bounded by `copy_deadline_ms` (written
//! with poll, reaped or killed at the deadline): `wl-copy` normally detaches at once, but on a compositor
//! without data-control it can sit waiting for focus. `copy` still blocks for up to
//! that long, so the window thread uses `copyAsync`.

const std = @import("std");
const builtin = @import("builtin");
const proc = @import("proc.zig");

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
        fn copy(text: []const u8) void {
            const tool: []const u8 = if (comptime builtin.os.tag.isDarwin()) "pbcopy" else "wl-copy";
            // page_allocator: gira anche sul thread staccato di `copyAsync`.
            _ = proc.runFeed(std.heap.page_allocator, &.{tool}, text, copy_deadline_ms);
        }

        fn pasteAlloc(_: std.mem.Allocator) ?[]u8 {
            return null; // i chiamanti Wayland passano da `wl-paste` (subprocess)
        }
    },
};
