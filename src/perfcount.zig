//! Contatori hardware e software del processo via `perf_event_open`, per i
//! benchmark: `perf` non serve (e su questa macchina non c'è). Con
//! `perf_event_paranoid` ≤ 2 un processo può misurare se stesso in user space.
//!
//! `inherit`: contano anche i thread creati DOPO `open`, ma il loro conto
//! confluisce nel totale solo quando escono. Si legge quindi dopo il join di
//! tutti i thread (per lo scheduler: dopo `deinitGlobal`).
//! `inherit` segue anche i processi figli (fork): nei conti entrano pdftoppm,
//! ImageMagick e simili, come in `child_cpu_ms` dei benchmark.
//! Solo Linux; altrove, o se il kernel rifiuta, i valori restano null.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Kind = enum { cycles, instructions, cache_misses, context_switches, cpu_migrations, task_clock_ns };

pub const Counters = struct {
    fds: [n]?i32 = @splat(null),

    const n = @typeInfo(Kind).@"enum".field_names.len;

    pub fn open() Counters {
        var c: Counters = .{};
        if (builtin.os.tag != .linux) return c;
        inline for (@typeInfo(Kind).@"enum".field_names, 0..) |name, i| {
            const k: Kind = @field(Kind, name);
            var attr: linux.perf_event_attr = .{
                .type = switch (k) {
                    .cycles, .instructions, .cache_misses => .HARDWARE,
                    else => .SOFTWARE,
                },
                .config = switch (k) {
                    .cycles => @backingInt(linux.PERF.COUNT.HW.CPU_CYCLES),
                    .instructions => @backingInt(linux.PERF.COUNT.HW.INSTRUCTIONS),
                    .cache_misses => @backingInt(linux.PERF.COUNT.HW.CACHE_MISSES),
                    .context_switches => @backingInt(linux.PERF.COUNT.SW.CONTEXT_SWITCHES),
                    .cpu_migrations => @backingInt(linux.PERF.COUNT.SW.CPU_MIGRATIONS),
                    .task_clock_ns => @backingInt(linux.PERF.COUNT.SW.TASK_CLOCK),
                },
                // Hardware: solo user space (con paranoid 2 il kernel è
                // vietato). Software: cambi di contesto e migrazioni AVVENGONO
                // nel kernel, escluderlo li azzererebbe; se il kernel rifiuta,
                // il contatore resta non disponibile invece di dare 0.
                .flags = .{ .inherit = true, .exclude_kernel = attrIsHw(k), .exclude_hv = true },
            };
            const rc = linux.perf_event_open(&attr, 0, -1, -1, linux.PERF.FLAG.FD_CLOEXEC);
            if (linux.errno(rc) == .SUCCESS) c.fds[i] = @intCast(rc);
        }
        return c;
    }

    fn attrIsHw(k: Kind) bool {
        return switch (k) {
            .cycles, .instructions, .cache_misses, .task_clock_ns => true,
            // Con paranoid 2 il kernel li rifiuta: restano non disponibili
            // (i cambi di contesto del processo li dà `getrusage`).
            .context_switches, .cpu_migrations => false,
        };
    }

    pub fn read(c: *const Counters, k: Kind) ?u64 {
        const fd = c.fds[@backingInt(k)] orelse return null;
        var v: u64 = 0;
        const rc = linux.read(fd, std.mem.asBytes(&v), @sizeOf(u64));
        if (linux.errno(rc) != .SUCCESS or rc != @sizeOf(u64)) return null;
        return v;
    }

    pub fn close(c: *Counters) void {
        for (&c.fds) |*fd| if (fd.*) |f| {
            _ = linux.close(f);
            fd.* = null;
        };
    }

    /// `chiave=valore` per ogni contatore (`-` se non disponibile).
    pub fn print(c: *const Counters, w: *std.Io.Writer) !void {
        inline for (@typeInfo(Kind).@"enum".field_names) |name| {
            if (c.read(@field(Kind, name))) |v| try w.print(" {s}={d}", .{ name, v }) else try w.print(" {s}=-", .{name});
        }
    }
};
