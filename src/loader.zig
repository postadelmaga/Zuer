const std = @import("std");
const builtin = @import("builtin");
const zicro = @import("zicro");
const state_mod = @import("state.zig");
const AppAction = state_mod.AppAction;
const decoder_mod = @import("decoder.zig");
const Decoded = decoder_mod.Decoded;

const page_align = std.heap.page_size_min;

/// CPU-backed staging buffer for platforms without memfd (Windows). It mirrors the slice
/// of `zicro.gpu_memory.Buffer`'s surface that the loader + renderer use (`ptr`, `asMut`,
/// `write`, `deinit`), so `GpuStage` is source-identical across platforms. The renderer's
/// `setMesh` imports this page-aligned host pointer zero-copy where the driver allows, and
/// otherwise falls back to a one-time copy — no memfd/cross-process sharing needed for the
/// in-process GUI renderer.
const CpuStageBuffer = struct {
    ptr: []align(page_align) u8,

    fn allocate(gpa: std.mem.Allocator, size: usize) !CpuStageBuffer {
        return .{ .ptr = try gpa.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(page_align), size) };
    }
    pub fn asMut(self: *CpuStageBuffer) []u8 {
        return self.ptr;
    }
    pub fn write(self: *CpuStageBuffer, offset: usize, data: []const u8) !void {
        if (offset + data.len > self.ptr.len) return error.WriteOutOfBounds;
        @memcpy(self.ptr[offset .. offset + data.len], data);
    }
    pub fn deinit(self: *CpuStageBuffer, gpa: std.mem.Allocator) void {
        gpa.free(self.ptr);
    }
};

/// memfd (exportable, zero-copy across processes) on Linux; a plain page-aligned CPU
/// allocation on platforms without memfd. Same API on both.
pub const StageBuffer = if (builtin.os.tag == .linux) zicro.gpu_memory.Buffer else CpuStageBuffer;

fn stageAlloc(gpa: std.mem.Allocator, size: usize, name: []const u8) !StageBuffer {
    if (builtin.os.tag == .linux) return zicro.gpu_memory.Buffer.allocate(gpa, size, name);
    return CpuStageBuffer.allocate(gpa, size);
}

/// Copia GPU-ready di un file decodificato: un `StageBuffer` (memfd su Linux, buffer CPU
/// page-aligned altrove) da cui il renderer carica la geometria.
/// Layout: immagini = pixel RGB8 raw; mesh = vertici f32 xyz seguiti da indici u32.
pub const GpuStage = struct {
    buffer: StageBuffer,
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
        // `StageBuffer.deinit` is per-OS (memfd unmap on Linux, plain free elsewhere); both
        // are safe to call. zicro's gpu_memory already gates its munmap by OS.
        if (self.gpu) |*stage| stage.buffer.deinit(self.gpa);
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
    switch (decoded.*) {
        .image => |img| {
            // Images are GPU-staged only on Linux (the TUI's zero-copy GPU present path).
            // The GUI composites images on the CPU, so there's no need to double them into a
            // staging buffer on Windows.
            if (builtin.os.tag != .linux) return null;
            if (img.pixels.len == 0) return null;
            var buffer = stageAlloc(gpa, img.pixels.len, "zuer/image-rgb8") catch return null;
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
            // Vertice interleaved: pos(vec3)+normal(vec3)+uv(vec2)+tangent(vec4), stride 48.
            const vertex_bytes = std.math.mul(usize, m.vertices.len, 12 * @sizeOf(f32)) catch return null;
            const index_bytes = std.math.mul(usize, m.faces.len, 3 * @sizeOf(u32)) catch return null;
            const total = std.math.add(usize, vertex_bytes, index_bytes) catch return null;

            // Normali: si usano quelle autorali del file se presenti e coerenti col
            // conteggio vertici (rispettano gli smoothing group); altrimenti si
            // ricostruiscono per-vertice come media pesata per area (il prodotto
            // vettoriale non normalizzato scala con l'area della faccia).
            const authored = m.normals.len == m.vertices.len;
            const normals = gpa.alloc([3]f32, m.vertices.len) catch return null;
            defer gpa.free(normals);
            if (authored) {
                @memcpy(normals, m.normals);
            } else {
                @memset(normals, .{ 0, 0, 0 });
                for (m.faces) |face| {
                    if (face.v1 >= m.vertices.len or face.v2 >= m.vertices.len or face.v3 >= m.vertices.len) continue;
                    const a = m.vertices[face.v1];
                    const b = m.vertices[face.v2];
                    const c = m.vertices[face.v3];
                    const e1 = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
                    const e2 = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
                    const fn_ = [3]f32{
                        e1[1] * e2[2] - e1[2] * e2[1],
                        e1[2] * e2[0] - e1[0] * e2[2],
                        e1[0] * e2[1] - e1[1] * e2[0],
                    };
                    inline for (.{ face.v1, face.v2, face.v3 }) |vi| {
                        normals[vi][0] += fn_[0];
                        normals[vi][1] += fn_[1];
                        normals[vi][2] += fn_[2];
                    }
                }
                for (normals) |*nrm| {
                    const len = @sqrt(nrm[0] * nrm[0] + nrm[1] * nrm[1] + nrm[2] * nrm[2]);
                    if (len > 1e-12) {
                        nrm[0] /= len;
                        nrm[1] /= len;
                        nrm[2] /= len;
                    }
                    // Normale nulla lasciata a zero: lo shader ripiega sulla geometrica.
                }
            }

            const has_uv = m.uvs.len == m.vertices.len;

            // Tangenti (vec4: xyz + w handedness) per il normal mapping. Autorali
            // se presenti; altrimenti ricostruite da UV/posizioni (Lengyel) con
            // ortogonalizzazione di Gram-Schmidt rispetto alla normale. Senza UV
            // restano un default innocuo (la normal map comunque non si campiona).
            const tangents = gpa.alloc([4]f32, m.vertices.len) catch return null;
            defer gpa.free(tangents);
            if (m.tangents.len == m.vertices.len) {
                @memcpy(tangents, m.tangents);
            } else if (has_uv) {
                const tan = gpa.alloc([3]f32, m.vertices.len) catch return null;
                defer gpa.free(tan);
                const bit = gpa.alloc([3]f32, m.vertices.len) catch return null;
                defer gpa.free(bit);
                @memset(tan, .{ 0, 0, 0 });
                @memset(bit, .{ 0, 0, 0 });
                for (m.faces) |face| {
                    if (face.v1 >= m.vertices.len or face.v2 >= m.vertices.len or face.v3 >= m.vertices.len) continue;
                    const p0 = m.vertices[face.v1];
                    const p1 = m.vertices[face.v2];
                    const p2 = m.vertices[face.v3];
                    const uv0 = m.uvs[face.v1];
                    const uv1 = m.uvs[face.v2];
                    const uv2 = m.uvs[face.v3];
                    const e1 = [3]f32{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
                    const e2 = [3]f32{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };
                    const du1 = [2]f32{ uv1[0] - uv0[0], uv1[1] - uv0[1] };
                    const du2 = [2]f32{ uv2[0] - uv0[0], uv2[1] - uv0[1] };
                    const denom = du1[0] * du2[1] - du2[0] * du1[1];
                    const r: f32 = if (@abs(denom) > 1e-12) 1.0 / denom else 0.0;
                    const sdir = [3]f32{
                        (e1[0] * du2[1] - e2[0] * du1[1]) * r,
                        (e1[1] * du2[1] - e2[1] * du1[1]) * r,
                        (e1[2] * du2[1] - e2[2] * du1[1]) * r,
                    };
                    const tdir = [3]f32{
                        (e2[0] * du1[0] - e1[0] * du2[0]) * r,
                        (e2[1] * du1[0] - e1[1] * du2[0]) * r,
                        (e2[2] * du1[0] - e1[2] * du2[0]) * r,
                    };
                    inline for (.{ face.v1, face.v2, face.v3 }) |vi| {
                        inline for (0..3) |c| {
                            tan[vi][c] += sdir[c];
                            bit[vi][c] += tdir[c];
                        }
                    }
                }
                for (tangents, 0..) |*out, i| {
                    const n = normals[i];
                    const t = tan[i];
                    // Gram-Schmidt: t' = normalize(t - n·(n·t))
                    const nd = n[0] * t[0] + n[1] * t[1] + n[2] * t[2];
                    var tx = t[0] - n[0] * nd;
                    var ty = t[1] - n[1] * nd;
                    var tz = t[2] - n[2] * nd;
                    const tl = @sqrt(tx * tx + ty * ty + tz * tz);
                    if (tl > 1e-12) {
                        tx /= tl;
                        ty /= tl;
                        tz /= tl;
                    } else {
                        tx = 1;
                        ty = 0;
                        tz = 0;
                    }
                    // Handedness: segno di (n × t')·bitangente accumulata.
                    const cx = n[1] * tz - n[2] * ty;
                    const cy = n[2] * tx - n[0] * tz;
                    const cz = n[0] * ty - n[1] * tx;
                    const hd = cx * bit[i][0] + cy * bit[i][1] + cz * bit[i][2];
                    out.* = .{ tx, ty, tz, if (hd < 0.0) -1.0 else 1.0 };
                }
            } else {
                @memset(tangents, .{ 1, 0, 0, 1 });
            }

            var buffer = stageAlloc(gpa, total, "zuer/mesh-vtx-idx") catch return null;

            // Scrittura interleaved: 12 pos + 12 normale + 8 uv + 16 tangente.
            const vbuf = buffer.asMut();
            for (m.vertices, 0..) |v, i| {
                const off = i * 48;
                @memcpy(vbuf[off..][0..12], std.mem.asBytes(&v));
                @memcpy(vbuf[off + 12 ..][0..12], std.mem.asBytes(&normals[i]));
                const uv: [2]f32 = if (has_uv) m.uvs[i] else .{ 0, 0 };
                @memcpy(vbuf[off + 24 ..][0..8], std.mem.asBytes(&uv));
                @memcpy(vbuf[off + 32 ..][0..16], std.mem.asBytes(&tangents[i]));
            }

            // Gli indici sono `usize` nel decoder e i file possono dichiararne di
            // fuori range: quelli invalidi diventano triangoli degeneri (0,0,0),
            // innocui per qualsiasi consumer GPU (il render TUI già li scarta).
            const dst = vbuf[vertex_bytes..];
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
