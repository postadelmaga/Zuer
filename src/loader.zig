const std = @import("std");
const builtin = @import("builtin");
const zicro = @import("zicro");
const state_mod = @import("state.zig");
const AppAction = state_mod.AppAction;
const decoder_mod = @import("decoder.zig");
const Decoded = decoder_mod.Decoded;

/// Copia GPU-ready di un file decodificato: un `zicro.gpu_memory.Buffer` (memfd)
/// esportabile a un processo/API GPU via `buffer.exportHandle()` senza copie.
/// Layout: immagini = pixel RGB8 raw; mesh = vertici f32 xyz seguiti da indici u32.
pub const GpuStage = struct {
    buffer: zicro.gpu_memory.Buffer,
    vertex_bytes: usize = 0,
    index_bytes: usize = 0,
};

/// Il payload del data-plane `media.latest`: possiede la decodifica, l'eventuale
/// staging GPU e l'allocator con cui liberarli — `deinit()` senza argomenti è il
/// contratto che `media.latest` richiede per rilasciare i valori stale/residui.
pub const LoadedFile = struct {
    gpa: std.mem.Allocator,
    decoded: Decoded,
    gpu: ?GpuStage = null,

    pub fn deinit(self: *LoadedFile) void {
        self.decoded.deinit(self.gpa);
        if (self.gpu) |*stage| {
            stage.buffer.deinit(self.gpa);
        }
    }
};

pub const LoaderModule = struct {
    id_: []const u8,
    gpa: std.mem.Allocator,
    sender: zicro.media.LatestSender(LoadedFile),

    pub fn init(
        id_: []const u8,
        gpa: std.mem.Allocator,
        sender: zicro.media.LatestSender(LoadedFile),
    ) LoaderModule {
        return .{
            .id_ = id_,
            .gpa = gpa,
            .sender = sender,
        };
    }

    pub fn id(self: *LoaderModule) []const u8 {
        return self.id_;
    }

    pub fn subscriptions(_: *LoaderModule) []const []const u8 {
        return &.{state_mod.actions_channel};
    }

    pub fn run(self: *LoaderModule, ctx: *zicro.ModuleCtx) anyerror!void {
        while (!ctx.shouldStop()) {
            const maybe_msg = ctx.recvTimeout(50 * std.time.ns_per_ms) catch break;
            const msg = maybe_msg orelse continue;
            defer msg.deinit();

            const parsed = msg.env().decode(AppAction, ctx.gpa) catch continue;
            defer parsed.deinit();

            switch (parsed.value) {
                .load_file => |path| {
                    var decoded = decoder_mod.decode(path, ctx.io, ctx.gpa);

                    if (decoded == .err) {
                        // Notify that decoding failed
                        const err_action = AppAction{ .decode_failed = decoded.err };
                        try ctx.publishMsg(state_mod.actions_channel, err_action);
                        // We must free the error message since decode_failed copies it
                        decoded.deinit(self.gpa);
                    } else {
                        var loaded = LoadedFile{
                            .gpa = self.gpa,
                            .decoded = decoded,
                            .gpu = stageToGpu(self.gpa, &decoded),
                        };

                        // Send the decoded file to TUI via media/data plane
                        self.sender.send(loaded) catch |err| {
                            // If receiver is gone, cleanup the decoded object
                            loaded.deinit();
                            return err;
                        };

                        // Notify that the file is ready
                        try ctx.publishMsg(state_mod.actions_channel, AppAction{ .file_ready = {} });
                    }
                },
                else => {},
            }
        }
    }
};

/// Stagia il contenuto decodificato in un buffer memfd condivisibile (solo Linux).
/// Fallire qui non è un errore: il viewer TUI funziona comunque, senza copia GPU.
/// Pubblica perché riusata da zuer-gui per alimentare lo stesso renderer.
pub fn stageToGpu(gpa: std.mem.Allocator, decoded: *const Decoded) ?GpuStage {
    if (builtin.os.tag != .linux) return null;

    switch (decoded.*) {
        .image => |img| {
            if (img.pixels.len == 0) return null;
            var buffer = zicro.gpu_memory.Buffer.allocate(gpa, img.pixels.len, "zuer/image-rgb8") catch return null;
            buffer.write(0, img.pixels) catch {
                buffer.deinit(gpa);
                return null;
            };
            return .{ .buffer = buffer };
        },
        .mesh => |m| {
            // Gli indici GPU sono u32: mesh oltre quel limite non sono stageabili
            // (vale anche per il conteggio indici totale, 3 per faccia).
            if (m.vertices.len == 0 or m.vertices.len > std.math.maxInt(u32)) return null;
            if (m.faces.len > std.math.maxInt(u32) / 3) return null;
            const vertex_bytes = std.math.mul(usize, m.vertices.len, 3 * @sizeOf(f32)) catch return null;
            const index_bytes = std.math.mul(usize, m.faces.len, 3 * @sizeOf(u32)) catch return null;
            const total = std.math.add(usize, vertex_bytes, index_bytes) catch return null;
            var buffer = zicro.gpu_memory.Buffer.allocate(gpa, total, "zuer/mesh-vtx-idx") catch return null;

            buffer.write(0, std.mem.sliceAsBytes(m.vertices)) catch {
                buffer.deinit(gpa);
                return null;
            };

            // Gli indici sono `usize` nel decoder e i file possono dichiararne di
            // fuori range: quelli invalidi diventano triangoli degeneri (0,0,0),
            // innocui per qualsiasi consumer GPU (il render TUI già li scarta).
            const dst = buffer.asMut()[vertex_bytes..];
            for (m.faces, 0..) |face, i| {
                const valid = face.v1 < m.vertices.len and face.v2 < m.vertices.len and face.v3 < m.vertices.len;
                const idx: [3]u32 = if (valid)
                    .{ @intCast(face.v1), @intCast(face.v2), @intCast(face.v3) }
                else
                    .{ 0, 0, 0 };
                @memcpy(dst[i * 12 ..][0..12], std.mem.asBytes(&idx));
            }

            return .{ .buffer = buffer, .vertex_bytes = vertex_bytes, .index_bytes = index_bytes };
        },
        else => return null,
    }
}
