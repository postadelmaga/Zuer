//! Pool di tile GPU per il runtime di virtual-texturing (fase 1) — adattamento
//! di Zengine `gpu/vtex_pool.zig` al wrapper Vulkan sottile di zuer (`renderer/vk.zig`).
//!
//! Un'unica image array 2D device-local di `capacity` slot fisici, RGBA8,
//! `tile_size` di lato. `uploadTile` porta una tile (streamata o generata) in uno
//! slot (staging → layer, lasciato in SHADER_READ_ONLY così è subito
//! campionabile dal fragment shader). Il gestore di residenza CPU (la logica di
//! upload per livello in `gpu_renderer.uploadVtLevel`) decide quale tile
//! virtuale vive in quale slot; questo è solo lo store fisico che lo shader
//! campiona come `sampler2DArray`.
//!
//! Rispetto all'originale non dipende dall'astrazione `Gpu` di Zengine: prende
//! gli handle grezzi (device/queue/cmd/fence) e riusa il command buffer + fence
//! del Renderer per un upload sincrono, esattamente come `createSampledTexture`.

const std = @import("std");
const vk = @import("renderer/vk.zig");
const vtex = @import("vtex.zig");

pub const tile_size = vtex.tile_size;
pub const tile_bytes = vtex.tile_bytes;

/// VK_IMAGE_VIEW_TYPE_2D_ARRAY (non aliasato nel wrapper).
const IMAGE_VIEW_TYPE_2D_ARRAY: u32 = 5;

/// Trova un indice memory-type che soddisfa `required` tra i bit ammessi.
fn findMemoryType(mem_props: *const vk.VkPhysicalDeviceMemoryProperties, type_bits: u32, required: u32) ?u32 {
    for (mem_props.memoryTypes[0..mem_props.memoryTypeCount], 0..) |mt, i| {
        const bit = @as(u32, 1) << @intCast(i);
        if (type_bits & bit != 0 and mt.propertyFlags & required == required) return @intCast(i);
    }
    return null;
}

pub const VtexPool = struct {
    device: vk.VkDevice,
    queue: vk.VkQueue,
    cmd: vk.VkCommandBuffer,
    fence: vk.VkFence,
    mem_props: vk.VkPhysicalDeviceMemoryProperties, // copia: serve per ricreare lo staging

    capacity: u32,
    image: vk.VkImage,
    mem: vk.VkDeviceMemory,
    view: vk.VkImageView, // view 2D_ARRAY su tutti gli slot
    sampler: vk.VkSampler, // lineare, clamp-to-edge (i gutter assorbono la cucitura)
    staging: vk.VkBuffer, // `staging_tiles` tile, host-visible, mappato persistente
    staging_mem: vk.VkDeviceMemory,
    staging_ptr: [*]u8,
    staging_tiles: u32, // capienza dello staging, in tile (cresce a richiesta)
    batch_first: u32 = 0, // range slot del batch in corso (uploadTilesBegin/End)
    batch_count: u32 = 0,

    pub fn init(
        device: vk.VkDevice,
        mem_props: *const vk.VkPhysicalDeviceMemoryProperties,
        queue: vk.VkQueue,
        cmd: vk.VkCommandBuffer,
        fence: vk.VkFence,
        capacity: u32,
    ) !VtexPool {
        std.debug.assert(capacity >= 1);

        // Image array device-local: capacity layer, RGBA8, sampled + transfer.
        var image: vk.VkImage = vk.VK_NULL;
        try vk.check(vk.vkCreateImage(device, &.{
            .format = vk.FORMAT_R8G8B8A8_SRGB,
            .extent = .{ .width = tile_size, .height = tile_size, .depth = 1 },
            .arrayLayers = capacity,
            .usage = vk.IMAGE_USAGE_SAMPLED | vk.IMAGE_USAGE_TRANSFER_DST | vk.IMAGE_USAGE_TRANSFER_SRC,
        }, null, &image));
        errdefer vk.vkDestroyImage(device, image, null);

        var req: vk.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(device, image, &req);
        const mt = findMemoryType(mem_props, req.memoryTypeBits, vk.MEM_DEVICE_LOCAL) orelse
            findMemoryType(mem_props, req.memoryTypeBits, 0) orelse return error.NoMemoryType;
        var mem: vk.VkDeviceMemory = vk.VK_NULL;
        try vk.check(vk.vkAllocateMemory(device, &.{ .allocationSize = req.size, .memoryTypeIndex = mt }, null, &mem));
        errdefer vk.vkFreeMemory(device, mem, null);
        try vk.check(vk.vkBindImageMemory(device, image, mem, 0));

        var view: vk.VkImageView = vk.VK_NULL;
        try vk.check(vk.vkCreateImageView(device, &.{
            .image = image,
            .viewType = IMAGE_VIEW_TYPE_2D_ARRAY,
            .format = vk.FORMAT_R8G8B8A8_SRGB,
            .subresourceRange = .{ .aspectMask = vk.ASPECT_COLOR, .layerCount = capacity },
        }, null, &view));
        errdefer vk.vkDestroyImageView(device, view, null);

        var sampler: vk.VkSampler = vk.VK_NULL;
        try vk.check(vk.vkCreateSampler(device, &.{}, null, &sampler));
        errdefer vk.vkDestroySampler(device, sampler, null);

        // Staging di una tile, host-visible/coherent, mappata per tutta la vita.
        var staging: vk.VkBuffer = vk.VK_NULL;
        try vk.check(vk.vkCreateBuffer(device, &.{ .size = tile_bytes, .usage = vk.BUFFER_USAGE_TRANSFER_SRC | vk.BUFFER_USAGE_TRANSFER_DST }, null, &staging));
        errdefer vk.vkDestroyBuffer(device, staging, null);
        var sreq: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(device, staging, &sreq);
        const smt = findMemoryType(mem_props, sreq.memoryTypeBits, vk.MEM_HOST_VISIBLE | vk.MEM_HOST_COHERENT) orelse return error.NoMemoryType;
        var staging_mem: vk.VkDeviceMemory = vk.VK_NULL;
        try vk.check(vk.vkAllocateMemory(device, &.{ .allocationSize = sreq.size, .memoryTypeIndex = smt }, null, &staging_mem));
        errdefer vk.vkFreeMemory(device, staging_mem, null);
        try vk.check(vk.vkBindBufferMemory(device, staging, staging_mem, 0));
        var mapped: *anyopaque = undefined;
        try vk.check(vk.vkMapMemory(device, staging_mem, 0, tile_bytes, 0, &mapped));

        var self = VtexPool{
            .device = device,
            .queue = queue,
            .cmd = cmd,
            .fence = fence,
            .mem_props = mem_props.*,
            .capacity = capacity,
            .image = image,
            .mem = mem,
            .view = view,
            .sampler = sampler,
            .staging = staging,
            .staging_mem = staging_mem,
            .staging_ptr = @ptrCast(mapped),
            .staging_tiles = 1,
        };

        // Porta TUTTI i layer in SHADER_READ_ONLY una volta, così il pool è
        // sempre bindabile e ogni uploadTile parte da un layout noto.
        try self.transitionAll(vk.IMAGE_LAYOUT_UNDEFINED, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, 0, vk.ACCESS_SHADER_READ, vk.STAGE_TOP, vk.STAGE_FRAGMENT_SHADER);
        return self;
    }

    pub fn deinit(self: *VtexPool) void {
        vk.vkDestroySampler(self.device, self.sampler, null);
        vk.vkDestroyImageView(self.device, self.view, null);
        vk.vkDestroyImage(self.device, self.image, null);
        vk.vkFreeMemory(self.device, self.mem, null);
        vk.vkDestroyBuffer(self.device, self.staging, null);
        vk.vkFreeMemory(self.device, self.staging_mem, null);
    }

    /// Descriptor combined-image-sampler per il binding del pool nello shader.
    pub fn imageInfo(self: *const VtexPool) vk.VkDescriptorImageInfo {
        return .{ .sampler = self.sampler, .imageView = self.view, .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    }

    /// Carica una tile (`tile_bytes` RGBA8) nello slot `slot`. Sincrono: riusa il
    /// command buffer + fence del Renderer, come `createSampledTexture`.
    pub fn uploadTile(self: *VtexPool, slot: u32, bytes: []const u8) !void {
        try self.uploadTilesBegin(slot, 1);
        self.uploadTilesStage(0, slot, bytes);
        try self.uploadTilesEnd();
    }

    /// Inizia un upload batched di `count` tile verso gli slot contigui
    /// [first, first+count): un solo command buffer, submit e fence per l'intero
    /// batch (contro un round-trip GPU per tile). Seguire con `uploadTilesStage`
    /// per ogni tile e chiudere con `uploadTilesEnd`.
    pub fn uploadTilesBegin(self: *VtexPool, first: u32, count: u32) !void {
        std.debug.assert(count >= 1 and first + count <= self.capacity);
        try self.ensureStaging(count);
        try vk.check(vk.vkBeginCommandBuffer(self.cmd, &.{}));
        self.barrier(first, count, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.ACCESS_SHADER_READ, vk.ACCESS_TRANSFER_WRITE, vk.STAGE_FRAGMENT_SHADER, vk.STAGE_TRANSFER);
        self.batch_first = first;
        self.batch_count = count;
    }

    /// Registra la tile `i` del batch (staging offset i*tile_bytes) verso `slot`.
    pub fn uploadTilesStage(self: *VtexPool, i: u32, slot: u32, bytes: []const u8) void {
        std.debug.assert(i < self.batch_count);
        std.debug.assert(slot >= self.batch_first and slot < self.batch_first + self.batch_count);
        std.debug.assert(bytes.len == tile_bytes);
        const off = @as(u64, i) * tile_bytes;
        @memcpy(self.staging_ptr[@intCast(off)..][0..tile_bytes], bytes);
        vk.vkCmdCopyBufferToImage(self.cmd, self.staging, self.image, vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &[_]vk.VkBufferImageCopy{.{
            .bufferOffset = off,
            .imageSubresource = .{ .aspectMask = vk.ASPECT_COLOR, .baseArrayLayer = slot, .layerCount = 1 },
            .imageExtent = .{ .width = tile_size, .height = tile_size, .depth = 1 },
        }});
    }

    /// Chiude il batch: barrier di ritorno a SHADER_READ_ONLY e submit sincrono.
    pub fn uploadTilesEnd(self: *VtexPool) !void {
        self.barrier(self.batch_first, self.batch_count, vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.ACCESS_TRANSFER_WRITE, vk.ACCESS_SHADER_READ, vk.STAGE_TRANSFER, vk.STAGE_FRAGMENT_SHADER);
        try self.submitSync();
    }

    /// Rilegge una tile da uno slot (verifica/self-test).
    pub fn readTile(self: *VtexPool, slot: u32, out: []u8) !void {
        std.debug.assert(slot < self.capacity);
        std.debug.assert(out.len == tile_bytes);
        try vk.check(vk.vkBeginCommandBuffer(self.cmd, &.{}));
        self.barrier(slot, 1, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk.ACCESS_SHADER_READ, vk.ACCESS_TRANSFER_READ, vk.STAGE_FRAGMENT_SHADER, vk.STAGE_TRANSFER);
        vk.vkCmdCopyImageToBuffer(self.cmd, self.image, vk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.staging, 1, &[_]vk.VkBufferImageCopy{.{
            .imageSubresource = .{ .aspectMask = vk.ASPECT_COLOR, .baseArrayLayer = slot, .layerCount = 1 },
            .imageExtent = .{ .width = tile_size, .height = tile_size, .depth = 1 },
        }});
        self.barrier(slot, 1, vk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.ACCESS_TRANSFER_READ, vk.ACCESS_SHADER_READ, vk.STAGE_TRANSFER, vk.STAGE_FRAGMENT_SHADER);
        try self.submitSync();
        @memcpy(out, self.staging_ptr[0..tile_bytes]);
    }

    /// Garantisce che lo staging contenga almeno `tiles` tile; se serve lo ricrea
    /// più grande (nessun submit in volo: ogni upload è sincrono via `submitSync`).
    fn ensureStaging(self: *VtexPool, tiles: u32) !void {
        if (self.staging_tiles >= tiles) return;
        const size = @as(u64, tiles) * tile_bytes;
        var buf: vk.VkBuffer = vk.VK_NULL;
        try vk.check(vk.vkCreateBuffer(self.device, &.{ .size = size, .usage = vk.BUFFER_USAGE_TRANSFER_SRC | vk.BUFFER_USAGE_TRANSFER_DST }, null, &buf));
        errdefer vk.vkDestroyBuffer(self.device, buf, null);
        var req: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(self.device, buf, &req);
        const mt = findMemoryType(&self.mem_props, req.memoryTypeBits, vk.MEM_HOST_VISIBLE | vk.MEM_HOST_COHERENT) orelse return error.NoMemoryType;
        var mem: vk.VkDeviceMemory = vk.VK_NULL;
        try vk.check(vk.vkAllocateMemory(self.device, &.{ .allocationSize = req.size, .memoryTypeIndex = mt }, null, &mem));
        errdefer vk.vkFreeMemory(self.device, mem, null);
        try vk.check(vk.vkBindBufferMemory(self.device, buf, mem, 0));
        var mapped: *anyopaque = undefined;
        try vk.check(vk.vkMapMemory(self.device, mem, 0, size, 0, &mapped));

        vk.vkDestroyBuffer(self.device, self.staging, null);
        vk.vkFreeMemory(self.device, self.staging_mem, null);
        self.staging = buf;
        self.staging_mem = mem;
        self.staging_ptr = @ptrCast(mapped);
        self.staging_tiles = tiles;
    }

    fn barrier(self: *VtexPool, first: u32, count: u32, old: u32, new: u32, src_access: u32, dst_access: u32, src_stage: u32, dst_stage: u32) void {
        const b = [_]vk.VkImageMemoryBarrier{.{
            .srcAccessMask = src_access,
            .dstAccessMask = dst_access,
            .oldLayout = old,
            .newLayout = new,
            .image = self.image,
            .subresourceRange = .{ .aspectMask = vk.ASPECT_COLOR, .baseArrayLayer = first, .layerCount = count },
        }};
        vk.vkCmdPipelineBarrier(self.cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &b);
    }

    fn transitionAll(self: *VtexPool, old: u32, new: u32, src_access: u32, dst_access: u32, src_stage: u32, dst_stage: u32) !void {
        try vk.check(vk.vkBeginCommandBuffer(self.cmd, &.{}));
        const b = [_]vk.VkImageMemoryBarrier{.{
            .srcAccessMask = src_access,
            .dstAccessMask = dst_access,
            .oldLayout = old,
            .newLayout = new,
            .image = self.image,
            .subresourceRange = .{ .aspectMask = vk.ASPECT_COLOR, .layerCount = self.capacity },
        }};
        vk.vkCmdPipelineBarrier(self.cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &b);
        try self.submitSync();
    }

    fn submitSync(self: *VtexPool) !void {
        try vk.check(vk.vkEndCommandBuffer(self.cmd));
        try vk.check(vk.vkQueueSubmit(self.queue, 1, &[_]vk.VkSubmitInfo{.{ .pCommandBuffers = @ptrCast(&self.cmd) }}, self.fence));
        try vk.check(vk.vkWaitForFences(self.device, 1, @ptrCast(&self.fence), 1, 2 * std.time.ns_per_s));
        try vk.check(vk.vkResetFences(self.device, 1, @ptrCast(&self.fence)));
    }
};
