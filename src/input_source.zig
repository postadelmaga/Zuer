const std = @import("std");
const zicro = @import("zicro");
const state_mod = @import("state.zig");
const AppAction = state_mod.AppAction;
const terminal_mod = @import("terminal.zig");
const Terminal = terminal_mod.Terminal;

fn mapAction(event: *const zicro.input.InputEvent) ?AppAction {
    return switch (event.*) {
        .key_down => |key| switch (key) {
            .up => .scroll_up,
            .down => .scroll_down,
            .left => .scroll_left,
            .right => .scroll_right,
            .escape => .exit,
            .char => |c| switch (c) {
                'q' => .exit,
                'k' => .scroll_up,
                'j' => .scroll_down,
                'h' => .scroll_left,
                'l' => .scroll_right,
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

const Prompt = enum { open, filter };

fn promptFor(event: *const zicro.input.InputEvent) ?Prompt {
    return switch (event.*) {
        .key_down => |key| switch (key) {
            .char => |c| switch (c) {
                'o' => .open,
                'f' => .filter,
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

/// Source zicro: possiede il terminale raw, traduce i tasti in `AppAction` sul
/// canale actions tramite `zicro.input.InputMapper`, e gestisce localmente i due
/// prompt di linea (apri file / filtro) che richiedono di uscire dal raw mode.
pub const InputModule = struct {
    pub fn id(_: *InputModule) []const u8 {
        return "input";
    }

    pub fn run(_: *InputModule, ctx: *zicro.ModuleCtx) anyerror!void {
        var terminal = try Terminal.init(ctx.io);
        defer terminal.deinit(ctx.io);

        const mapper = zicro.input.InputMapper(AppAction).init(
            ctx.bus(),
            "input",
            state_mod.actions_topic,
            mapAction,
        );

        while (!ctx.shouldStop()) {
            if (try terminal.readInputEvent(ctx.io)) |event| {
                if (promptFor(&event)) |prompt| {
                    try runPrompt(ctx, &terminal, prompt);
                } else {
                    mapper.feed(&event) catch break;
                }
            }

            // Il read è non-bloccante (VMIN=0): un piccolo sleep evita il busy-loop.
            std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(15), .awake) catch {};
        }
    }

    /// Legge una riga (restando in raw mode) e pubblica l'azione risultante.
    fn runPrompt(ctx: *zicro.ModuleCtx, terminal: *Terminal, prompt: Prompt) !void {
        var buf: [256]u8 = undefined;
        const line = promptLine(ctx, terminal, prompt, &buf) orelse return;

        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        switch (prompt) {
            .open => {
                if (trimmed.len == 0) return;
                try ctx.publishMsg(state_mod.actions_channel, AppAction{ .load_file = trimmed });
            },
            .filter => {
                // Filtro vuoto = rimuovi il filtro: va pubblicato comunque.
                try ctx.publishMsg(state_mod.actions_channel, AppAction{ .set_filter = trimmed });
            },
        }
    }

    /// Line-editor minimale che resta in raw mode: niente read bloccante su stdin,
    /// così lo shutdown non resta mai appeso al join di questo thread. Invio conferma,
    /// Esc annulla, Backspace cancella. Errori di I/O valgono come "nessun input".
    fn promptLine(ctx: *zicro.ModuleCtx, terminal: *Terminal, prompt: Prompt, buf: []u8) ?[]const u8 {
        const label = switch (prompt) {
            .open => "\x1B[?25h\r\n\x1B[K\x1B[1;32m📂 Inserisci percorso file:\x1B[0m ",
            .filter => "\x1B[?25h\r\n\x1B[K\x1B[1;33m🔍 Inserisci filtro:\x1B[0m ",
        };
        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(ctx.io, label) catch return null;
        defer stdout.writeStreamingAll(ctx.io, "\x1B[?25l") catch {};

        var len: usize = 0;
        while (!ctx.shouldStop()) {
            const maybe_event = terminal.readInputEvent(ctx.io) catch return null;
            const event = maybe_event orelse {
                std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                continue;
            };
            switch (event) {
                .key_down => |key| switch (key) {
                    .enter => return buf[0..len],
                    .escape => return null,
                    .backspace => if (len > 0) {
                        len -= 1;
                        stdout.writeStreamingAll(ctx.io, "\x08 \x08") catch {};
                    },
                    .space => appendChar(ctx.io, stdout, buf, &len, ' '),
                    .tab => {},
                    .char => |c| if (c < 128) appendChar(ctx.io, stdout, buf, &len, @intCast(c)),
                    else => {},
                },
                else => {},
            }
        }
        return null;
    }

    fn appendChar(io: std.Io, stdout: std.Io.File, buf: []u8, len: *usize, c: u8) void {
        if (len.* >= buf.len) return;
        buf[len.*] = c;
        len.* += 1;
        stdout.writeStreamingAll(io, buf[len.* - 1 .. len.*]) catch {};
    }
};
