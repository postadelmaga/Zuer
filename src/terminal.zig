const std = @import("std");
const zicro = @import("zicro");
const Key = zicro.input.Key;
const InputEvent = zicro.input.InputEvent;

pub const Terminal = struct {
    original_termios: std.posix.termios,
    // I byte letti da stdin ma non ancora consumati: una read può consegnare
    // più tasti in un colpo solo (paste, input veloce) e va drenata un evento
    // alla volta, non un byte per read.
    pending: [64]u8 = undefined,
    pending_len: usize = 0,
    pending_pos: usize = 0,

    pub fn init(io: std.Io) !Terminal {
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;

        // Disable canonical mode (line buffering), echo, signals
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Disable software flow control and CR translation
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;

        // Non-blocking read: return immediately if no input is ready
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);

        // Hide cursor and clear screen using std.Io.File
        const stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(io, "\x1B[?25l");

        return .{
            .original_termios = original,
        };
    }

    pub fn deinit(self: *Terminal, io: std.Io) void {
        // Show cursor and restore original termios settings
        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(io, "\x1B[?25h\x1B[0m") catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original_termios) catch {};
    }
    pub fn readInputEvent(self: *Terminal, io: std.Io) !?InputEvent {
        _ = io;
        if (self.pending_pos >= self.pending_len) {
            const n = std.posix.read(std.posix.STDIN_FILENO, &self.pending) catch |err| {
                if (err == error.WouldBlock) return null;
                return err;
            };
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
