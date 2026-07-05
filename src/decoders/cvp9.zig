//! Binding minimale per `libcompute_vp9` — decoder VP9 su GPU compute (Vulkan) +
//! VA-API. Isolato in questo file così che l'`@cImport(compute_vp9/decoder.h)`
//! e il link della libreria vengano compilati SOLO quando serve (`build_options.gpu`
//! su Linux): player.zig importa questo modulo dietro un gate comptime, quindi su
//! Windows / build CPU-only nulla di tutto ciò viene analizzato.
//!
//! Espone solo il percorso a piani CPU (I420): si sottomettono i packet VP9 grezzi
//! (dal demux avformat) e si raccolgono i frame decodificati come Y/U/V, che
//! player.zig converte poi in RGB con swscale. Il path DMA-BUF zero-copy della
//! libreria resta un'ottimizzazione futura (il compositor di zuer è ancora CPU).

const std = @import("std");

pub const c = @cImport({
    @cInclude("compute_vp9/decoder.h");
});

/// Esito di un tentativo di prelievo frame.
pub const Status = enum { ok, again, none };

/// Frame decodificato in I420, con puntatori ai piani posseduti dal decoder
/// (validi almeno fino alle 2 successive `decode`).
pub const Frame = struct {
    width: u32,
    height: u32,
    stride_y: u32,
    stride_uv: u32,
    y: [*c]u8,
    u: [*c]u8,
    v: [*c]u8,
    pts: i64,
};

/// Handle di contesto decoder (wrappa il puntatore opaco cvp9).
pub const Ctx = struct {
    ptr: *c.cvp9_ctx_t,

    /// Crea un contesto col backend auto (Vulkan se disponibile). `null` se la
    /// libreria non riesce a inizializzare alcun backend.
    pub fn create() ?Ctx {
        var p: ?*c.cvp9_ctx_t = null;
        // config NULL ⇒ default (backend auto, thread entropy = auto).
        if (c.cvp9_create(null, &p) != c.CVP9_OK or p == null) return null;
        return .{ .ptr = p.? };
    }

    pub fn destroy(self: Ctx) void {
        c.cvp9_destroy(self.ptr);
    }

    /// Sottomette un packet VP9 grezzo (una AVPacket del demux).
    pub fn decode(self: Ctx, data: [*c]const u8, size: usize, pts: i64) void {
        _ = c.cvp9_decode(self.ptr, data, size, pts);
    }

    /// Preleva il prossimo frame pronto (non bloccante). `.again` = un frame è in
    /// volo ma non ancora pronto; `.none` = niente in coda.
    pub fn getFrame(self: Ctx, out: *Frame) Status {
        var i: c.cvp9_frame_info_t = undefined;
        return mapStatus(c.cvp9_get_frame(self.ptr, &i), &i, out);
    }

    /// Nome del backend attivo (per log/diagnostica).
    pub fn backendName(self: Ctx) []const u8 {
        return switch (c.cvp9_active_backend(self.ptr)) {
            c.CVP9_BACKEND_VULKAN => "Vulkan",
            c.CVP9_BACKEND_OPENCL => "OpenCL",
            c.CVP9_BACKEND_CPU => "CPU",
            else => "auto",
        };
    }
};

fn mapStatus(rc: c.cvp9_err_t, i: *const c.cvp9_frame_info_t, out: *Frame) Status {
    if (rc == c.CVP9_OK) {
        out.* = .{
            .width = i.width,
            .height = i.height,
            .stride_y = i.stride_y,
            .stride_uv = i.stride_uv,
            .y = i.plane_y,
            .u = i.plane_u,
            .v = i.plane_v,
            .pts = i.pts,
        };
        return .ok;
    }
    if (rc == c.CVP9_ERR_AGAIN) return .again;
    return .none;
}
