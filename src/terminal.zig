const std = @import("std");
const builtin = @import("builtin");
const zicro = @import("zicro");
const InputEvent = zicro.input.InputEvent;

/// Raw-mode terminal input. The byte stream and its ANSI-escape parsing are identical on
/// every platform (Windows Terminal speaks VT sequences once we enable VT input); only the
/// raw-mode setup and the non-blocking read differ per OS.
pub const Terminal = struct {
    saved: RawState,
    // I byte letti da stdin ma non ancora consumati: una read può consegnare più tasti in
    // un colpo solo (paste, input veloce) e va drenata un evento alla volta.
    pending: [64]u8 = undefined,
    pending_len: usize = 0,
    pending_pos: usize = 0,

    const RawState = switch (builtin.os.tag) {
        .windows => struct { in_mode: u32, out_mode: u32 },
        else => std.posix.termios,
    };

    // --- Windows console FFI (only referenced on the Windows path) --------------------
    const win = struct {
        extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn GetConsoleMode(h: ?*anyopaque, mode: *u32) callconv(.winapi) i32;
        extern "kernel32" fn SetConsoleMode(h: ?*anyopaque, mode: u32) callconv(.winapi) i32;
        extern "kernel32" fn ReadFile(h: ?*anyopaque, buf: [*]u8, n: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn WaitForSingleObject(h: ?*anyopaque, ms: u32) callconv(.winapi) u32;
        const STD_INPUT: u32 = 0xFFFFFFF6; // (DWORD)-10
        const STD_OUTPUT: u32 = 0xFFFFFFF5; // (DWORD)-11
        const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
        const ENABLE_LINE_INPUT: u32 = 0x0002;
        const ENABLE_ECHO_INPUT: u32 = 0x0004;
        const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
        const WAIT_OBJECT_0: u32 = 0;
    };

    pub fn init(io: std.Io) !Terminal {
        var self: Terminal = .{ .saved = undefined };
        switch (builtin.os.tag) {
            .windows => {
                const hin = win.GetStdHandle(win.STD_INPUT);
                const hout = win.GetStdHandle(win.STD_OUTPUT);
                var in_mode: u32 = 0;
                var out_mode: u32 = 0;
                _ = win.GetConsoleMode(hin, &in_mode);
                _ = win.GetConsoleMode(hout, &out_mode);
                self.saved = .{ .in_mode = in_mode, .out_mode = out_mode };
                // Raw input: no line buffering, no echo, no Ctrl-C processing; deliver
                // special keys as VT escape sequences so the shared parser handles them.
                const raw_in = (in_mode & ~(win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT | win.ENABLE_PROCESSED_INPUT)) | win.ENABLE_VIRTUAL_TERMINAL_INPUT;
                _ = win.SetConsoleMode(hin, raw_in);
                // Interpret the ANSI escapes zuer writes (cursor, colors).
                _ = win.SetConsoleMode(hout, out_mode | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            },
            else => {
                const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
                var raw = original;
                // Disable canonical mode (line buffering), echo, signals.
                raw.lflag.ICANON = false;
                raw.lflag.ECHO = false;
                raw.lflag.ISIG = false;
                raw.lflag.IEXTEN = false;
                // Disable software flow control and CR translation.
                raw.iflag.IXON = false;
                raw.iflag.ICRNL = false;
                // Non-blocking read: return immediately if no input is ready.
                raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
                raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
                try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
                self.saved = original;
            },
        }

        // Hide cursor.
        const stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(io, "\x1B[?25l");
        return self;
    }

    pub fn deinit(self: *Terminal, io: std.Io) void {
        // Show cursor and reset attributes, then restore the original console/tty mode.
        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(io, "\x1B[?25h\x1B[0m") catch {};
        switch (builtin.os.tag) {
            .windows => {
                _ = win.SetConsoleMode(win.GetStdHandle(win.STD_INPUT), self.saved.in_mode);
                _ = win.SetConsoleMode(win.GetStdHandle(win.STD_OUTPUT), self.saved.out_mode);
            },
            else => std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.saved) catch {},
        }
    }

    /// Read available input bytes into `pending`. Returns the count (0 when nothing is
    /// ready — non-blocking on both platforms).
    fn fillPending(self: *Terminal) !usize {
        switch (builtin.os.tag) {
            .windows => {
                const hin = win.GetStdHandle(win.STD_INPUT);
                if (win.WaitForSingleObject(hin, 0) != win.WAIT_OBJECT_0) return 0;
                var read: u32 = 0;
                if (win.ReadFile(hin, &self.pending, self.pending.len, &read, null) == 0) return 0;
                return read;
            },
            else => {
                return std.posix.read(std.posix.STDIN_FILENO, &self.pending) catch |err| {
                    if (err == error.WouldBlock) return 0;
                    return err;
                };
            },
        }
    }

    pub fn readInputEvent(self: *Terminal, io: std.Io) !?InputEvent {
        _ = io;
        if (self.pending_pos >= self.pending_len) {
            const n = try self.fillPending();
            if (n == 0) return null;
            self.pending_pos = 0;
            self.pending_len = n;
        }

        const buf = self.pending[self.pending_pos..self.pending_len];

        if (buf[0] == 27) { // Escape code
            if (buf.len >= 3 and buf[1] == '[') {
                self.pending_pos += 3;
                switch (buf[2]) {
                    'A' => return .{ .key_down = .up },
                    'B' => return .{ .key_down = .down },
                    'C' => return .{ .key_down = .right },
                    'D' => return .{ .key_down = .left },
                    else => return .{ .key_down = .escape },
                }
            }
            if (buf.len >= 2) {
                // Alt+tasto o sequenza sconosciuta: scarta anche il byte seguente.
                self.pending_pos += 2;
            } else {
                self.pending_pos += 1;
            }
            return .{ .key_down = .escape };
        }

        self.pending_pos += 1;
        switch (buf[0]) {
            10, 13 => return .{ .key_down = .enter },
            127, 8 => return .{ .key_down = .backspace },
            9 => return .{ .key_down = .tab },
            32 => return .{ .key_down = .space },
            else => {
                if (buf[0] >= 32 and buf[0] < 127) {
                    return .{ .key_down = .{ .char = buf[0] } };
                }
            },
        }

        return null;
    }
};
