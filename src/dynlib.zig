//! Minimal cross-platform dynamic-library loader.
//!
//! This toolchain's `std.DynLib` has no Windows implementation (it `@compileError`s on
//! any non-Unix target), so the decoder-plugin loader can't use it directly. This wraps
//! `std.DynLib` on Unix and `LoadLibraryW`/`GetProcAddress` on Windows behind one small
//! API: `open` / `lookup` / `close`.

const std = @import("std");
const builtin = @import("builtin");

pub const Lib = switch (builtin.os.tag) {
    .windows => struct {
        module: *anyopaque,

        extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn FreeLibrary(hModule: *anyopaque) callconv(.winapi) i32;

        pub fn open(path: []const u8) !Lib {
            var buf: [std.fs.max_path_bytes]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(&buf, path) catch return error.BadPath;
            if (n >= buf.len) return error.NameTooLong;
            buf[n] = 0;
            const m = LoadLibraryW(buf[0..n :0].ptr) orelse return error.FileNotFound;
            return .{ .module = m };
        }

        extern "kernel32" fn LoadLibraryExW(lpLibFileName: [*:0]const u16, hFile: ?*anyopaque, dwFlags: u32) callconv(.winapi) ?*anyopaque;
        const LOAD_LIBRARY_SEARCH_DEFAULT_DIRS: u32 = 0x00001000;

        /// Come `open`, ma per una libreria di SISTEMA cercata per nome: cartella
        /// dell'app, System32 e cartelle utente aggiunte — MAI la cartella corrente
        /// (niente DLL piantate accanto al documento aperto).
        pub fn openSystem(name: []const u8) !Lib {
            var buf: [256]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(&buf, name) catch return error.BadPath;
            if (n >= buf.len) return error.NameTooLong;
            buf[n] = 0;
            const m = LoadLibraryExW(buf[0..n :0].ptr, null, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) orelse return error.FileNotFound;
            return .{ .module = m };
        }

        pub fn lookup(self: *Lib, comptime T: type, name: [:0]const u8) ?T {
            const p = GetProcAddress(self.module, name.ptr) orelse return null;
            return @ptrCast(@alignCast(p));
        }

        pub fn close(self: *Lib) void {
            _ = FreeLibrary(self.module);
        }
    },
    else => struct {
        inner: std.DynLib,

        pub fn open(path: []const u8) !Lib {
            return .{ .inner = try std.DynLib.open(path) };
        }

        /// Libreria di sistema per nome: la ricerca standard di dlopen.
        pub fn openSystem(name: []const u8) !Lib {
            return open(name);
        }

        pub fn lookup(self: *Lib, comptime T: type, name: [:0]const u8) ?T {
            return self.inner.lookup(T, name);
        }

        pub fn close(self: *Lib) void {
            self.inner.close();
        }
    },
};
