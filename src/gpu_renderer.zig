//! Renderer Vulkan offscreen per le mesh di zuer.
//!
//! Binding scritti a mano per il solo sottoinsieme necessario (compilano in un
//! attimo, niente generatori). Il buffer staged dal loader (memfd di
//! `zicro.gpu_memory`) viene importato zero-copy con VK_EXT_external_memory_host
//! quando il driver lo permette, altrimenti copiato una volta sola.
//!
//! Due presentazioni sopra lo stesso core:
//!  - TUI: `render()` → pixel RGBA in un buffer host-visible (readback);
//!  - zuer-gui: `renderToImage()` lascia il frame pronto, presentato da zrame.

const std = @import("std");
const builtin = @import("builtin");
const decoder = @import("decoder.zig");

const vk = @import("renderer/vk.zig");

// libc getenv, portable across Linux/Windows (std.posix.getenv is Linux-only here) — used to
// read the ZUER_GPU device override.
extern fn getenv([*:0]const u8) ?[*:0]const u8;

/// True when `needle` occurs in `haystack`, ASCII case-insensitive. Small (device names,
/// short override strings), so the naive O(n·m) scan is fine.
fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) continue :outer;
        }
        return true;
    }
    return false;
}

const vert_spv = @embedFile("mesh_vert_spv");
const frag_spv = @embedFile("mesh_frag_spv");
const shadow_vert_spv = @embedFile("shadow_vert_spv");
const shadow_frag_spv = @embedFile("shadow_frag_spv");
const voxel_vert_spv = @embedFile("voxel_vert_spv");
const voxel_frag_spv = @embedFile("voxel_frag_spv");

pub const SHADOW_SIZE: u32 = 1024;

pub const PushConstants = extern struct {
    mvp: [16]f32,
    nrm0: [4]f32,
    nrm1: [4]f32,
    nrm2: [4]f32,
    material: [4]f32,
    light_vp: [16]f32,
    light_dir_cam: [4]f32,
};

pub const ShadowPush = extern struct {
    light_vp: [16]f32,
};

pub const VoxelPush = extern struct {
    origin: [4]f32,
    right: [4]f32,
    up: [4]f32,
    dir: [4]f32,
    light_g: [4]f32,
    light_obj: [4]f32,
};

pub const InitOptions = struct {
    instance_extensions: []const [*:0]const u8 = &.{},
    device_extensions: []const [*:0]const u8 = &.{},
};

const ACCESS_COLOR_WRITE = vk.ACCESS_COLOR_WRITE;
const ACCESS_DEPTH_WRITE = vk.ACCESS_DEPTH_WRITE;
const ACCESS_HOST_READ = vk.ACCESS_HOST_READ;
const ACCESS_SHADER_READ = vk.ACCESS_SHADER_READ;
const ACCESS_TRANSFER_READ = vk.ACCESS_TRANSFER_READ;
const ACCESS_TRANSFER_WRITE = vk.ACCESS_TRANSFER_WRITE;
const ASPECT_COLOR = vk.ASPECT_COLOR;
const ASPECT_DEPTH = vk.ASPECT_DEPTH;
const BLEND_FACTOR_ONE_MINUS_SRC_ALPHA = vk.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
const BLEND_FACTOR_SRC_ALPHA = vk.BLEND_FACTOR_SRC_ALPHA;
const BUFFER_USAGE_INDEX = vk.BUFFER_USAGE_INDEX;
const BUFFER_USAGE_STORAGE = vk.BUFFER_USAGE_STORAGE;
const BUFFER_USAGE_TRANSFER_DST = vk.BUFFER_USAGE_TRANSFER_DST;
const BUFFER_USAGE_TRANSFER_SRC = vk.BUFFER_USAGE_TRANSFER_SRC;
const BUFFER_USAGE_VERTEX = vk.BUFFER_USAGE_VERTEX;
const COLOR_WRITE_RGB = vk.COLOR_WRITE_RGB;
const DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
const DESCRIPTOR_TYPE_STORAGE_BUFFER = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER;
const VkDescriptorBufferInfo = vk.VkDescriptorBufferInfo;
const EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT = vk.EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
const FORMAT_D32_SFLOAT = vk.FORMAT_D32_SFLOAT;
const FORMAT_R32G32B32A32_SFLOAT = vk.FORMAT_R32G32B32A32_SFLOAT;
const FORMAT_R32G32B32_SFLOAT = vk.FORMAT_R32G32B32_SFLOAT;
const FORMAT_R32G32_SFLOAT = vk.FORMAT_R32G32_SFLOAT;
const FORMAT_R8G8B8A8_SRGB = vk.FORMAT_R8G8B8A8_SRGB;
const FORMAT_R8G8B8A8_UNORM = vk.FORMAT_R8G8B8A8_UNORM;
const FORMAT_R8_UNORM = vk.FORMAT_R8_UNORM;
const IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
const IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
const IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL = vk.IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
const IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
const IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL = vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
const IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL = vk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
const IMAGE_LAYOUT_UNDEFINED = vk.IMAGE_LAYOUT_UNDEFINED;
const IMAGE_USAGE_COLOR_ATTACHMENT = vk.IMAGE_USAGE_COLOR_ATTACHMENT;
const IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT = vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT;
const IMAGE_USAGE_SAMPLED = vk.IMAGE_USAGE_SAMPLED;
const IMAGE_USAGE_TRANSFER_DST = vk.IMAGE_USAGE_TRANSFER_DST;
const IMAGE_USAGE_TRANSFER_SRC = vk.IMAGE_USAGE_TRANSFER_SRC;
const MEM_DEVICE_LOCAL = vk.MEM_DEVICE_LOCAL;
const MEM_HOST_COHERENT = vk.MEM_HOST_COHERENT;
const MEM_HOST_VISIBLE = vk.MEM_HOST_VISIBLE;
const PfnGetMemoryHostPointerProperties = vk.PfnGetMemoryHostPointerProperties;
const QUEUE_GRAPHICS = vk.QUEUE_GRAPHICS;
const SHADER_STAGE_FRAGMENT = vk.SHADER_STAGE_FRAGMENT;
const SHADER_STAGE_VERTEX = vk.SHADER_STAGE_VERTEX;
const STAGE_COLOR_ATTACHMENT_OUTPUT = vk.STAGE_COLOR_ATTACHMENT_OUTPUT;
const STAGE_EARLY_FRAGMENT_TESTS = vk.STAGE_EARLY_FRAGMENT_TESTS;
const STAGE_FRAGMENT_SHADER = vk.STAGE_FRAGMENT_SHADER;
const STAGE_HOST = vk.STAGE_HOST;
const STAGE_LATE_FRAGMENT_TESTS = vk.STAGE_LATE_FRAGMENT_TESTS;
const STAGE_TOP = vk.STAGE_TOP;
const STAGE_TRANSFER = vk.STAGE_TRANSFER;
const ST_APPLICATION_INFO = vk.ST_APPLICATION_INFO;
const ST_BUFFER_CREATE_INFO = vk.ST_BUFFER_CREATE_INFO;
const ST_BUFFER_MEMORY_BARRIER = vk.ST_BUFFER_MEMORY_BARRIER;
const ST_COMMAND_BUFFER_ALLOCATE_INFO = vk.ST_COMMAND_BUFFER_ALLOCATE_INFO;
const ST_COMMAND_BUFFER_BEGIN_INFO = vk.ST_COMMAND_BUFFER_BEGIN_INFO;
const ST_COMMAND_POOL_CREATE_INFO = vk.ST_COMMAND_POOL_CREATE_INFO;
const ST_DESCRIPTOR_POOL_CREATE_INFO = vk.ST_DESCRIPTOR_POOL_CREATE_INFO;
const ST_DESCRIPTOR_SET_ALLOCATE_INFO = vk.ST_DESCRIPTOR_SET_ALLOCATE_INFO;
const ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = vk.ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
const ST_DEVICE_CREATE_INFO = vk.ST_DEVICE_CREATE_INFO;
const ST_DEVICE_QUEUE_CREATE_INFO = vk.ST_DEVICE_QUEUE_CREATE_INFO;
const ST_FENCE_CREATE_INFO = vk.ST_FENCE_CREATE_INFO;
const ST_FRAMEBUFFER_CREATE_INFO = vk.ST_FRAMEBUFFER_CREATE_INFO;
const ST_GRAPHICS_PIPELINE_CREATE_INFO = vk.ST_GRAPHICS_PIPELINE_CREATE_INFO;
const ST_IMAGE_CREATE_INFO = vk.ST_IMAGE_CREATE_INFO;
const ST_IMAGE_MEMORY_BARRIER = vk.ST_IMAGE_MEMORY_BARRIER;
const ST_IMAGE_VIEW_CREATE_INFO = vk.ST_IMAGE_VIEW_CREATE_INFO;
const ST_IMPORT_MEMORY_HOST_POINTER_INFO_EXT = vk.ST_IMPORT_MEMORY_HOST_POINTER_INFO_EXT;
const ST_INSTANCE_CREATE_INFO = vk.ST_INSTANCE_CREATE_INFO;
const ST_MEMORY_ALLOCATE_INFO = vk.ST_MEMORY_ALLOCATE_INFO;
const ST_MEMORY_HOST_POINTER_PROPERTIES_EXT = vk.ST_MEMORY_HOST_POINTER_PROPERTIES_EXT;
const ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO = vk.ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
const ST_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO = vk.ST_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
const ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO = vk.ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
const ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO = vk.ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
const ST_PIPELINE_LAYOUT_CREATE_INFO = vk.ST_PIPELINE_LAYOUT_CREATE_INFO;
const ST_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO = vk.ST_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
const ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO = vk.ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
const ST_PIPELINE_SHADER_STAGE_CREATE_INFO = vk.ST_PIPELINE_SHADER_STAGE_CREATE_INFO;
const ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO = vk.ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
const ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO = vk.ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
const ST_RENDER_PASS_BEGIN_INFO = vk.ST_RENDER_PASS_BEGIN_INFO;
const ST_RENDER_PASS_CREATE_INFO = vk.ST_RENDER_PASS_CREATE_INFO;
const ST_SAMPLER_CREATE_INFO = vk.ST_SAMPLER_CREATE_INFO;
const ST_SHADER_MODULE_CREATE_INFO = vk.ST_SHADER_MODULE_CREATE_INFO;
const ST_SUBMIT_INFO = vk.ST_SUBMIT_INFO;
const ST_WRITE_DESCRIPTOR_SET = vk.ST_WRITE_DESCRIPTOR_SET;
const SUBPASS_EXTERNAL = vk.SUBPASS_EXTERNAL;
const VK_NULL = vk.VK_NULL;
const VK_SUCCESS = vk.VK_SUCCESS;
const VkApplicationInfo = vk.VkApplicationInfo;
const VkAttachmentDescription = vk.VkAttachmentDescription;
const VkAttachmentReference = vk.VkAttachmentReference;
const VkBuffer = vk.VkBuffer;
const VkBufferCreateInfo = vk.VkBufferCreateInfo;
const VkBufferImageCopy = vk.VkBufferImageCopy;
const VkBufferMemoryBarrier = vk.VkBufferMemoryBarrier;
const VkClearValue = vk.VkClearValue;
const VkCommandBuffer = vk.VkCommandBuffer;
const VkCommandBufferAllocateInfo = vk.VkCommandBufferAllocateInfo;
const VkCommandBufferBeginInfo = vk.VkCommandBufferBeginInfo;
const VkCommandPool = vk.VkCommandPool;
const VkCommandPoolCreateInfo = vk.VkCommandPoolCreateInfo;
const VkComponentMapping = vk.VkComponentMapping;
const VkDescriptorImageInfo = vk.VkDescriptorImageInfo;
const VkDescriptorPool = vk.VkDescriptorPool;
const VkDescriptorPoolCreateInfo = vk.VkDescriptorPoolCreateInfo;
const VkDescriptorPoolSize = vk.VkDescriptorPoolSize;
const VkDescriptorSet = vk.VkDescriptorSet;
const VkDescriptorSetAllocateInfo = vk.VkDescriptorSetAllocateInfo;
const VkDescriptorSetLayout = vk.VkDescriptorSetLayout;
const VkDescriptorSetLayoutBinding = vk.VkDescriptorSetLayoutBinding;
const VkDescriptorSetLayoutCreateInfo = vk.VkDescriptorSetLayoutCreateInfo;
const VkDevice = vk.VkDevice;
const VkDeviceCreateInfo = vk.VkDeviceCreateInfo;
const VkDeviceMemory = vk.VkDeviceMemory;
const VkDeviceQueueCreateInfo = vk.VkDeviceQueueCreateInfo;
const VkExtensionProperties = vk.VkExtensionProperties;
const VkExtent2D = vk.VkExtent2D;
const VkExtent3D = vk.VkExtent3D;
const VkExternalMemoryBufferCreateInfo = vk.VkExternalMemoryBufferCreateInfo;
const VkFence = vk.VkFence;
const VkFenceCreateInfo = vk.VkFenceCreateInfo;
const VkFramebuffer = vk.VkFramebuffer;
const VkFramebufferCreateInfo = vk.VkFramebufferCreateInfo;
const VkGraphicsPipelineCreateInfo = vk.VkGraphicsPipelineCreateInfo;
const VkImage = vk.VkImage;
const VkImageCreateInfo = vk.VkImageCreateInfo;
const VkImageMemoryBarrier = vk.VkImageMemoryBarrier;
const VkImageSubresourceLayers = vk.VkImageSubresourceLayers;
const VkImageSubresourceRange = vk.VkImageSubresourceRange;
const VkImageView = vk.VkImageView;
const VkImageViewCreateInfo = vk.VkImageViewCreateInfo;
const VkImportMemoryHostPointerInfoEXT = vk.VkImportMemoryHostPointerInfoEXT;
const VkInstance = vk.VkInstance;
const VkInstanceCreateInfo = vk.VkInstanceCreateInfo;
const VkMemoryAllocateInfo = vk.VkMemoryAllocateInfo;
const VkMemoryHeap = vk.VkMemoryHeap;
const VkMemoryHostPointerPropertiesEXT = vk.VkMemoryHostPointerPropertiesEXT;
const VkMemoryRequirements = vk.VkMemoryRequirements;
const VkMemoryType = vk.VkMemoryType;
const VkOffset2D = vk.VkOffset2D;
const VkOffset3D = vk.VkOffset3D;
const VkPhysicalDevice = vk.VkPhysicalDevice;
const VkPhysicalDeviceMemoryProperties = vk.VkPhysicalDeviceMemoryProperties;
const VkPipeline = vk.VkPipeline;
const VkPipelineColorBlendAttachmentState = vk.VkPipelineColorBlendAttachmentState;
const VkPipelineColorBlendStateCreateInfo = vk.VkPipelineColorBlendStateCreateInfo;
const VkPipelineDepthStencilStateCreateInfo = vk.VkPipelineDepthStencilStateCreateInfo;
const VkPipelineDynamicStateCreateInfo = vk.VkPipelineDynamicStateCreateInfo;
const VkPipelineInputAssemblyStateCreateInfo = vk.VkPipelineInputAssemblyStateCreateInfo;
const VkPipelineLayout = vk.VkPipelineLayout;
const VkPipelineLayoutCreateInfo = vk.VkPipelineLayoutCreateInfo;
const VkPipelineMultisampleStateCreateInfo = vk.VkPipelineMultisampleStateCreateInfo;
const VkPipelineRasterizationStateCreateInfo = vk.VkPipelineRasterizationStateCreateInfo;
const VkPipelineShaderStageCreateInfo = vk.VkPipelineShaderStageCreateInfo;
const VkPipelineVertexInputStateCreateInfo = vk.VkPipelineVertexInputStateCreateInfo;
const VkPipelineViewportStateCreateInfo = vk.VkPipelineViewportStateCreateInfo;
const VkPushConstantRange = vk.VkPushConstantRange;
const VkQueue = vk.VkQueue;
const VkQueueFamilyProperties = vk.VkQueueFamilyProperties;
const VkRect2D = vk.VkRect2D;
const VkRenderPass = vk.VkRenderPass;
const VkRenderPassBeginInfo = vk.VkRenderPassBeginInfo;
const VkRenderPassCreateInfo = vk.VkRenderPassCreateInfo;
const VkResult = vk.VkResult;
const VkSampler = vk.VkSampler;
const VkSamplerCreateInfo = vk.VkSamplerCreateInfo;
const VkShaderModule = vk.VkShaderModule;
const VkShaderModuleCreateInfo = vk.VkShaderModuleCreateInfo;
const VkStencilOpState = vk.VkStencilOpState;
const VkStructureType = vk.VkStructureType;
const VkSubmitInfo = vk.VkSubmitInfo;
const VkSubpassDependency = vk.VkSubpassDependency;
const VkSubpassDescription = vk.VkSubpassDescription;
const VkVertexInputAttributeDescription = vk.VkVertexInputAttributeDescription;
const VkVertexInputBindingDescription = vk.VkVertexInputBindingDescription;
const VkViewport = vk.VkViewport;
const VkWriteDescriptorSet = vk.VkWriteDescriptorSet;
const check = vk.check;
const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers;
const vkAllocateDescriptorSets = vk.vkAllocateDescriptorSets;
const vkAllocateMemory = vk.vkAllocateMemory;
const vkBeginCommandBuffer = vk.vkBeginCommandBuffer;
const vkBindBufferMemory = vk.vkBindBufferMemory;
const vkBindImageMemory = vk.vkBindImageMemory;
const vkCmdBeginRenderPass = vk.vkCmdBeginRenderPass;
const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets;
const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer;
const vkCmdBindPipeline = vk.vkCmdBindPipeline;
const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers;
const vkCmdCopyBufferToImage = vk.vkCmdCopyBufferToImage;
const vkCmdCopyImageToBuffer = vk.vkCmdCopyImageToBuffer;
const vkCmdDraw = vk.vkCmdDraw;
const vkCmdDrawIndexed = vk.vkCmdDrawIndexed;
const vkCmdEndRenderPass = vk.vkCmdEndRenderPass;
const vkCmdPipelineBarrier = vk.vkCmdPipelineBarrier;
const vkCmdPushConstants = vk.vkCmdPushConstants;
const vkCmdSetScissor = vk.vkCmdSetScissor;
const vkCmdSetViewport = vk.vkCmdSetViewport;
const vkCreateBuffer = vk.vkCreateBuffer;
const vkCreateCommandPool = vk.vkCreateCommandPool;
const vkCreateDescriptorPool = vk.vkCreateDescriptorPool;
const vkCreateDescriptorSetLayout = vk.vkCreateDescriptorSetLayout;
const vkCreateDevice = vk.vkCreateDevice;
const vkCreateFence = vk.vkCreateFence;
const vkCreateFramebuffer = vk.vkCreateFramebuffer;
const vkCreateGraphicsPipelines = vk.vkCreateGraphicsPipelines;
const vkCreateImage = vk.vkCreateImage;
const vkCreateImageView = vk.vkCreateImageView;
const vkCreateInstance = vk.vkCreateInstance;
const vkCreatePipelineLayout = vk.vkCreatePipelineLayout;
const vkCreateRenderPass = vk.vkCreateRenderPass;
const vkCreateSampler = vk.vkCreateSampler;
const vkCreateShaderModule = vk.vkCreateShaderModule;
const vkDestroyBuffer = vk.vkDestroyBuffer;
const vkDestroyCommandPool = vk.vkDestroyCommandPool;
const vkDestroyDescriptorPool = vk.vkDestroyDescriptorPool;
const vkDestroyDescriptorSetLayout = vk.vkDestroyDescriptorSetLayout;
const vkDestroyDevice = vk.vkDestroyDevice;
const vkDestroyFence = vk.vkDestroyFence;
const vkDestroyFramebuffer = vk.vkDestroyFramebuffer;
const vkDestroyImage = vk.vkDestroyImage;
const vkDestroyImageView = vk.vkDestroyImageView;
const vkDestroyInstance = vk.vkDestroyInstance;
const vkDestroyPipeline = vk.vkDestroyPipeline;
const vkDestroyPipelineLayout = vk.vkDestroyPipelineLayout;
const vkDestroyRenderPass = vk.vkDestroyRenderPass;
const vkDestroySampler = vk.vkDestroySampler;
const vkDestroyShaderModule = vk.vkDestroyShaderModule;
const vkDeviceWaitIdle = vk.vkDeviceWaitIdle;
const vkEndCommandBuffer = vk.vkEndCommandBuffer;
const vkEnumerateDeviceExtensionProperties = vk.vkEnumerateDeviceExtensionProperties;
const vkEnumeratePhysicalDevices = vk.vkEnumeratePhysicalDevices;
const vkFreeMemory = vk.vkFreeMemory;
const vkGetBufferMemoryRequirements = vk.vkGetBufferMemoryRequirements;
const vkGetDeviceProcAddr = vk.vkGetDeviceProcAddr;
const vkGetDeviceQueue = vk.vkGetDeviceQueue;
const vkGetImageMemoryRequirements = vk.vkGetImageMemoryRequirements;
const vkGetPhysicalDeviceMemoryProperties = vk.vkGetPhysicalDeviceMemoryProperties;
const vkGetPhysicalDeviceProperties = vk.vkGetPhysicalDeviceProperties;
const vkGetPhysicalDeviceQueueFamilyProperties = vk.vkGetPhysicalDeviceQueueFamilyProperties;
const vkMapMemory = vk.vkMapMemory;
const vkQueueSubmit = vk.vkQueueSubmit;
const vkResetFences = vk.vkResetFences;
const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets;
const vkWaitForFences = vk.vkWaitForFences;

const text_vert_spv = @embedFile("text_vert_spv");
const text_frag_spv = @embedFile("text_frag_spv");

/// Push constant della pipeline testo: dimensione del viewport in pixel.
const TextPush = extern struct { viewport: [2]f32 };

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    instance: VkInstance,
    physical: VkPhysicalDevice,
    device: VkDevice,
    queue: VkQueue,
    queue_family: u32,
    mem_props: VkPhysicalDeviceMemoryProperties,
    get_host_ptr_props: ?PfnGetMemoryHostPointerProperties,

    cmd_pool: VkCommandPool,
    cmd: VkCommandBuffer,
    fence: VkFence,

    render_pass: VkRenderPass,
    pipeline_layout: VkPipelineLayout,
    pipeline: VkPipeline,
    vert_module: VkShaderModule,
    frag_module: VkShaderModule,

    // Target offscreen (ricreato al cambio di dimensione)
    width: u32 = 0,
    height: u32 = 0,
    color_image: VkImage = VK_NULL,
    color_mem: VkDeviceMemory = VK_NULL,
    color_view: VkImageView = VK_NULL,
    depth_image: VkImage = VK_NULL,
    depth_mem: VkDeviceMemory = VK_NULL,
    depth_view: VkImageView = VK_NULL,
    framebuffer: VkFramebuffer = VK_NULL,
    readback_buf: VkBuffer = VK_NULL,
    readback_mem: VkDeviceMemory = VK_NULL,
    readback_ptr: ?[*]u8 = null,

    // Supporto per double-buffering dell'asynchronous readback
    frame_cmds: [2]VkCommandBuffer = .{ null, null },
    frame_fences: [2]VkFence = .{ VK_NULL, VK_NULL },
    frame_index: u64 = 0,
    readback_bufs: [2]VkBuffer = .{ VK_NULL, VK_NULL },
    readback_mems: [2]VkDeviceMemory = .{ VK_NULL, VK_NULL },
    readback_ptrs: [2]?[*]u8 = .{ null, null },

    // Geometria corrente (import zero-copy del memfd o copia una tantum)
    mesh_buf: VkBuffer = VK_NULL,
    mesh_mem: VkDeviceMemory = VK_NULL,
    mesh_vertex_bytes: u64 = 0,
    mesh_index_count: u32 = 0,
    mesh_imported: bool = false,

    // Materiali/texture per sotto-mesh (combined image sampler, set 0). Ogni
    // submesh ha il proprio descriptor set (bind 0 = baseColor, bind 1 = shadow
    // map). Modelli multi-materiale → più submesh sulla stessa geometria fusa.
    // La texture 1×1 bianca è condivisa per i submesh senza texture propria.
    mesh_sampler: VkSampler = VK_NULL,
    mesh_dsl: VkDescriptorSetLayout = VK_NULL,
    mesh_dpool: VkDescriptorPool = VK_NULL,
    white_tex: ImageBundle = .{ .image = VK_NULL, .mem = VK_NULL, .view = VK_NULL },
    flat_normal_tex: ImageBundle = .{ .image = VK_NULL, .mem = VK_NULL, .view = VK_NULL },
    submeshes: []SubMeshGpu = &.{},

    // Ombre (shadow map depth della key light), inizializzate pigramente.
    shadow_ready: bool = false,
    shadow_pass: VkRenderPass = VK_NULL,
    shadow_depth: ImageBundle = .{ .image = VK_NULL, .mem = VK_NULL, .view = VK_NULL },
    shadow_fb: VkFramebuffer = VK_NULL,
    shadow_sampler: VkSampler = VK_NULL,
    shadow_pipeline_layout: VkPipelineLayout = VK_NULL,
    shadow_pipeline: VkPipeline = VK_NULL,
    shadow_vert_module: VkShaderModule = VK_NULL,
    shadow_frag_module: VkShaderModule = VK_NULL,

    // Rendering voxel (ray-march), inizializzato pigramente. La griglia vive in
    // uno storage buffer host-visible (un uint RGBA8-packed per voxel), non in
    // una texture 3D: alcuni driver (Intel/NVIDIA su questo laptop) vanno in
    // device-lost sull'upload di immagini 3D. Lo SSBO è memoria lineare che lo
    // shader indicizza a mano, aggirando del tutto formati/tiling/layout 3D.
    voxel_ready: bool = false, // pipeline/risorse statiche create
    voxel_dsl: VkDescriptorSetLayout = VK_NULL,
    voxel_dpool: VkDescriptorPool = VK_NULL,
    voxel_dset: VkDescriptorSet = VK_NULL,
    voxel_pipeline_layout: VkPipelineLayout = VK_NULL,
    voxel_pipeline: VkPipeline = VK_NULL,
    voxel_vert_module: VkShaderModule = VK_NULL,
    voxel_frag_module: VkShaderModule = VK_NULL,
    voxel_buf: VkBuffer = VK_NULL,
    voxel_mem: VkDeviceMemory = VK_NULL,
    voxel_dim: u32 = 0, // >0 se una griglia è caricata

    // Texture immagine (per zuer-gui: blit diretto sulla swapchain)

    // Pipeline testo (atlante glifi su GPU), inizializzata pigramente.
    text_ready: bool = false,
    text_sampler: VkSampler = VK_NULL,
    text_dsl: VkDescriptorSetLayout = VK_NULL,
    text_dpool: VkDescriptorPool = VK_NULL,
    text_dset: VkDescriptorSet = VK_NULL,
    text_pipeline_layout: VkPipelineLayout = VK_NULL,
    text_pipeline: VkPipeline = VK_NULL,
    text_vert_module: VkShaderModule = VK_NULL,
    text_frag_module: VkShaderModule = VK_NULL,
    text_atlas: ImageBundle = .{ .image = VK_NULL, .mem = VK_NULL, .view = VK_NULL },
    text_atlas_w: u32 = 0,
    text_atlas_h: u32 = 0,
    text_vbuf: VkBuffer = VK_NULL,
    text_vmem: VkDeviceMemory = VK_NULL,
    text_vbuf_cap: u64 = 0,
    text_vptr: ?[*]u8 = null,

    pub fn init(gpa: std.mem.Allocator, opts: InitOptions) !Renderer {
        const app_info = VkApplicationInfo{
            .pApplicationName = "zuer",
            .apiVersion = (1 << 22) | (1 << 12), // 1.1
        };
        var instance: VkInstance = null;
        try check(vkCreateInstance(&.{
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = @intCast(opts.instance_extensions.len),
            .ppEnabledExtensionNames = if (opts.instance_extensions.len > 0) opts.instance_extensions.ptr else null,
        }, null, &instance));
        errdefer vkDestroyInstance(instance, null);

        // Primo device fisico con una queue family grafica; l'import host-pointer
        // è un plus, non un requisito.
        var dev_count: u32 = 8;
        var devices: [8]VkPhysicalDevice = @splat(null);
        const enum_result = vkEnumeratePhysicalDevices(instance, &dev_count, &devices);
        // VK_INCOMPLETE (5) va bene: più di 8 device, ne bastano i primi.
        if (enum_result != VK_SUCCESS and enum_result != 5) return error.NoGpu;
        if (dev_count == 0) return error.NoGpu;

        // Pick the physical device with a graphics queue. The default *preference* differs by
        // present path: this renderer draws offscreen and, off Linux, reads the frame back to
        // CPU and composites it in software (UpdateLayeredWindow) — for that, an INTEGRATED GPU
        // (memory shared with the CPU) makes the readback nearly free and beats a discrete GPU
        // whose readback crosses PCIe (dreadful under Wine + Optimus). On Linux the frame goes
        // out zero-copy as a dmabuf, so the stronger DISCRETE GPU wins. `ZUER_GPU` overrides:
        // a decimal index picks that enumerated device; any other value is matched (case-
        // insensitively) as a substring of the device name (e.g. `ZUER_GPU=intel`).
        const prefer_integrated = builtin.os.tag != .linux;
        const override: ?[]const u8 = if (getenv("ZUER_GPU")) |p| std.mem.sliceTo(p, 0) else null;
        const forced_index: ?u32 = if (override) |o| std.fmt.parseInt(u32, o, 10) catch null else null;

        var physical: VkPhysicalDevice = null;
        var queue_family: u32 = 0;
        var has_host_import = false;
        var best_score: i32 = std.math.minInt(i32);
        for (devices[0..dev_count], 0..) |pd, idx| {
            var qf_count: u32 = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, null);
            var qfs: [16]VkQueueFamilyProperties = undefined;
            qf_count = @min(qf_count, 16);
            vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, &qfs);
            const family = for (qfs[0..qf_count], 0..) |qf, i| {
                if (qf.queueFlags & QUEUE_GRAPHICS != 0) break @as(u32, @intCast(i));
            } else continue;

            var props: vk.VkPhysicalDeviceProperties = undefined;
            vkGetPhysicalDeviceProperties(pd, &props);
            const name = std.mem.sliceTo(&props.deviceName, 0);
            const integrated = props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU;
            const discrete = props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
            std.log.info("zuer gpu: [{d}] {s} (type {d})", .{ idx, name, props.deviceType });

            // Score: explicit override wins outright; otherwise prefer the type that fits the
            // present path, then break ties toward a real GPU over a software rasterizer.
            var score: i32 = 0;
            if (forced_index) |fi| {
                if (idx == fi) score += 10_000;
            } else if (override) |o| {
                if (asciiContainsIgnoreCase(name, o)) score += 10_000;
            }
            // Off Linux (CPU-readback present) bias toward integrated. On Linux the frame
            // goes out zero-copy as a dmabuf that must be importable by the compositor (itself
            // usually on the integrated GPU), so DON'T bias by type — keep the enumeration
            // order (first candidate wins on the score==0 tie), preserving prior behavior.
            if (prefer_integrated) {
                if (integrated) score += 100 else if (discrete) score += 50;
            }

            if (physical == null or score > best_score) {
                physical = pd;
                queue_family = family;
                has_host_import = deviceHasExtension(gpa, pd, "VK_EXT_external_memory_host");
                best_score = score;
            }
        }
        if (physical == null) return error.NoGpu;
        {
            var props: vk.VkPhysicalDeviceProperties = undefined;
            vkGetPhysicalDeviceProperties(physical, &props);
            std.log.info("zuer gpu: using {s}", .{std.mem.sliceTo(&props.deviceName, 0)});
        }

        var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
        vkGetPhysicalDeviceMemoryProperties(physical, &mem_props);

        const priority = [_]f32{1.0};
        var dev_exts: std.ArrayList([*:0]const u8) = .empty;
        defer dev_exts.deinit(gpa);
        if (has_host_import) try dev_exts.append(gpa, "VK_EXT_external_memory_host");
        try dev_exts.appendSlice(gpa, opts.device_extensions);

        var device: VkDevice = null;
        try check(vkCreateDevice(physical, &.{
            .pQueueCreateInfos = &.{ .queueFamilyIndex = queue_family, .pQueuePriorities = &priority },
            .enabledExtensionCount = @intCast(dev_exts.items.len),
            .ppEnabledExtensionNames = if (dev_exts.items.len > 0) dev_exts.items.ptr else null,
        }, null, &device));
        errdefer vkDestroyDevice(device, null);

        var queue: VkQueue = null;
        vkGetDeviceQueue(device, queue_family, 0, &queue);

        const get_host_ptr_props: ?PfnGetMemoryHostPointerProperties = if (has_host_import)
            @ptrCast(vkGetDeviceProcAddr(device, "vkGetMemoryHostPointerPropertiesEXT"))
        else
            null;

        var cmd_pool: VkCommandPool = VK_NULL;
        try check(vkCreateCommandPool(device, &.{ .queueFamilyIndex = queue_family }, null, &cmd_pool));
        errdefer vkDestroyCommandPool(device, cmd_pool, null);

        var cmd: VkCommandBuffer = null;
        try check(vkAllocateCommandBuffers(device, &.{ .commandPool = cmd_pool }, @ptrCast(&cmd)));

        var fence: VkFence = VK_NULL;
        try check(vkCreateFence(device, &.{}, null, &fence));
        errdefer vkDestroyFence(device, fence, null);

        var frame_cmds: [2]VkCommandBuffer = .{ null, null };
        try check(vkAllocateCommandBuffers(device, &.{ .commandPool = cmd_pool, .commandBufferCount = 2 }, @ptrCast(&frame_cmds)));

        var frame_fences: [2]VkFence = .{ VK_NULL, VK_NULL };
        try check(vkCreateFence(device, &.{}, null, &frame_fences[0]));
        errdefer vkDestroyFence(device, frame_fences[0], null);
        try check(vkCreateFence(device, &.{}, null, &frame_fences[1]));
        errdefer vkDestroyFence(device, frame_fences[1], null);

        const render_pass = try createRenderPass(device);
        errdefer vkDestroyRenderPass(device, render_pass, null);

        const vert_module = try createShaderModule(gpa, device, vert_spv);
        errdefer vkDestroyShaderModule(device, vert_module, null);
        const frag_module = try createShaderModule(gpa, device, frag_spv);
        errdefer vkDestroyShaderModule(device, frag_module, null);

        // Descriptor set 0: texture baseColor (combined image sampler) per la
        // mesh. Creato qui perché il pipeline layout lo referenzia.
        var mesh_sampler: VkSampler = VK_NULL;
        try check(vkCreateSampler(device, &.{}, null, &mesh_sampler));
        errdefer vkDestroySampler(device, mesh_sampler, null);

        // Binding 0 = texture baseColor, binding 1 = shadow map depth. Le risorse
        // effettive sono create pigramente; il DSL però è definitivo qui perché
        // il pipeline layout (e quindi la pipeline) lo referenzia.
        // binding 0 = baseColor, 1 = shadow map, 2 = normal map.
        const tex_bindings = [_]VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = SHADER_STAGE_FRAGMENT },
            .{ .binding = 1, .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = SHADER_STAGE_FRAGMENT },
            .{ .binding = 2, .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = SHADER_STAGE_FRAGMENT },
        };
        var mesh_dsl: VkDescriptorSetLayout = VK_NULL;
        try check(vkCreateDescriptorSetLayout(device, &.{
            .bindingCount = tex_bindings.len,
            .pBindings = &tex_bindings,
        }, null, &mesh_dsl));
        errdefer vkDestroyDescriptorSetLayout(device, mesh_dsl, null);

        const tex_pool_size = VkDescriptorPoolSize{ .type = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 2 };
        var mesh_dpool: VkDescriptorPool = VK_NULL;
        try check(vkCreateDescriptorPool(device, &.{
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = @ptrCast(&tex_pool_size),
        }, null, &mesh_dpool));
        errdefer vkDestroyDescriptorPool(device, mesh_dpool, null);

        const push_range = VkPushConstantRange{
            .stageFlags = SHADER_STAGE_VERTEX | SHADER_STAGE_FRAGMENT,
            .offset = 0,
            .size = @sizeOf(PushConstants),
        };
        var pipeline_layout: VkPipelineLayout = VK_NULL;
        try check(vkCreatePipelineLayout(device, &.{
            .setLayoutCount = 1,
            .pSetLayouts = @ptrCast(&mesh_dsl),
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = @ptrCast(&push_range),
        }, null, &pipeline_layout));
        errdefer vkDestroyPipelineLayout(device, pipeline_layout, null);

        const pipeline = try createPipeline(device, render_pass, pipeline_layout, vert_module, frag_module);
        errdefer vkDestroyPipeline(device, pipeline, null);

        return .{
            .gpa = gpa,
            .instance = instance,
            .physical = physical,
            .device = device,
            .queue = queue,
            .queue_family = queue_family,
            .mem_props = mem_props,
            .get_host_ptr_props = get_host_ptr_props,
            .cmd_pool = cmd_pool,
            .cmd = cmd,
            .fence = fence,
            .frame_cmds = frame_cmds,
            .frame_fences = frame_fences,
            .render_pass = render_pass,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .vert_module = vert_module,
            .frag_module = frag_module,
            .mesh_sampler = mesh_sampler,
            .mesh_dsl = mesh_dsl,
            .mesh_dpool = mesh_dpool,
        };
    }

    pub fn deinit(self: *Renderer) void {
        _ = vkDeviceWaitIdle(self.device);
        self.releaseMesh();
        if (self.shadow_ready) {
            vkDestroyPipeline(self.device, self.shadow_pipeline, null);
            vkDestroyPipelineLayout(self.device, self.shadow_pipeline_layout, null);
            vkDestroyShaderModule(self.device, self.shadow_vert_module, null);
            vkDestroyShaderModule(self.device, self.shadow_frag_module, null);
            vkDestroyFramebuffer(self.device, self.shadow_fb, null);
            self.destroyImage(self.shadow_depth);
            vkDestroyRenderPass(self.device, self.shadow_pass, null);
            vkDestroySampler(self.device, self.shadow_sampler, null);
        }
        if (self.voxel_ready) {
            vkDestroyPipeline(self.device, self.voxel_pipeline, null);
            vkDestroyPipelineLayout(self.device, self.voxel_pipeline_layout, null);
            vkDestroyShaderModule(self.device, self.voxel_vert_module, null);
            vkDestroyShaderModule(self.device, self.voxel_frag_module, null);
            vkDestroyDescriptorPool(self.device, self.voxel_dpool, null);
            vkDestroyDescriptorSetLayout(self.device, self.voxel_dsl, null);
        }
        if (self.voxel_buf != VK_NULL) {
            vkDestroyBuffer(self.device, self.voxel_buf, null);
            vkFreeMemory(self.device, self.voxel_mem, null);
        }
        self.releaseSubmeshes();
        if (self.white_tex.image != VK_NULL) self.destroyImage(self.white_tex);
        if (self.flat_normal_tex.image != VK_NULL) self.destroyImage(self.flat_normal_tex);
        vkDestroyDescriptorPool(self.device, self.mesh_dpool, null);
        vkDestroyDescriptorSetLayout(self.device, self.mesh_dsl, null);
        vkDestroySampler(self.device, self.mesh_sampler, null);
        self.destroyTextPipe();
        self.destroyTarget();
        vkDestroyPipeline(self.device, self.pipeline, null);
        vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        vkDestroyShaderModule(self.device, self.vert_module, null);
        vkDestroyShaderModule(self.device, self.frag_module, null);
        vkDestroyRenderPass(self.device, self.render_pass, null);
        vkDestroyFence(self.device, self.frame_fences[0], null);
        vkDestroyFence(self.device, self.frame_fences[1], null);
        vkDestroyFence(self.device, self.fence, null);
        vkDestroyCommandPool(self.device, self.cmd_pool, null);
        vkDestroyDevice(self.device, null);
        vkDestroyInstance(self.instance, null);
    }

    /// Carica la geometria (layout: vertici f32x3 compatti, poi indici u32 —
    /// esattamente il contenuto del GpuStage del loader). `data` deve restare
    /// mappato finché la mesh non viene rilasciata: con l'import host-pointer
    /// la GPU legge direttamente quelle pagine.
    pub fn setMesh(self: *Renderer, data: []align(std.heap.page_size_min) const u8, vertex_bytes: usize, index_count: u32) !void {
        self.releaseMesh();
        if (index_count == 0 or vertex_bytes == 0) return error.EmptyMesh;
        const usage = BUFFER_USAGE_VERTEX | BUFFER_USAGE_INDEX | BUFFER_USAGE_TRANSFER_DST;

        // Tentativo zero-copy: import del puntatore host del memfd. Qualsiasi
        // fallimento ripiega in silenzio sulla copia (comunque una sola).
        if (self.tryImportMesh(data, usage, vertex_bytes, index_count)) return;

        // Fallback: buffer ordinario host-visible con una copia.
        var buf: VkBuffer = VK_NULL;
        try check(vkCreateBuffer(self.device, &.{ .size = data.len, .usage = usage }, null, &buf));
        errdefer vkDestroyBuffer(self.device, buf, null);

        var req: VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, buf, &req);
        const mem_type = self.findMemoryType(req.memoryTypeBits, MEM_HOST_VISIBLE | MEM_HOST_COHERENT) orelse return error.NoMemoryType;
        var mem: VkDeviceMemory = VK_NULL;
        try check(vkAllocateMemory(self.device, &.{
            .allocationSize = req.size,
            .memoryTypeIndex = mem_type,
        }, null, &mem));
        errdefer vkFreeMemory(self.device, mem, null);
        try check(vkBindBufferMemory(self.device, buf, mem, 0));
        var mapped: *anyopaque = undefined;
        try check(vkMapMemory(self.device, mem, 0, data.len, 0, &mapped));
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..data.len], data);

        self.mesh_buf = buf;
        self.mesh_mem = mem;
        self.mesh_vertex_bytes = vertex_bytes;
        self.mesh_index_count = index_count;
        self.mesh_imported = false;
    }

    /// Import zero-copy del puntatore host: il buffer dichiara l'handle type
    /// esterno (VUID 02985) e la memoria deve essere HOST_COHERENT perché la
    /// mappatura non passa da vkMapMemory (nessun flush possibile).
    /// Ritorna false su qualsiasi fallimento, senza leak (cleanup espliciti:
    /// errdefer non scatta sui return non-error).
    fn tryImportMesh(self: *Renderer, data: []align(std.heap.page_size_min) const u8, usage: u32, vertex_bytes: usize, index_count: u32) bool {
        const get_props = self.get_host_ptr_props orelse return false;

        const external_info = VkExternalMemoryBufferCreateInfo{};
        var buf: VkBuffer = VK_NULL;
        if (vkCreateBuffer(self.device, &.{
            .pNext = &external_info,
            .size = data.len,
            .usage = usage,
        }, null, &buf) != VK_SUCCESS) return false;

        var req: VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, buf, &req);

        const aligned_size = std.mem.alignForward(usize, data.len, std.heap.page_size_min);
        var props = VkMemoryHostPointerPropertiesEXT{};
        const host_ptr: *anyopaque = @ptrCast(@constCast(data.ptr));
        if (req.size > aligned_size or
            get_props(self.device, EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, host_ptr, &props) != VK_SUCCESS)
        {
            vkDestroyBuffer(self.device, buf, null);
            return false;
        }

        const type_bits = props.memoryTypeBits & req.memoryTypeBits;
        const mem_type = self.findMemoryType(type_bits, MEM_HOST_VISIBLE | MEM_HOST_COHERENT) orelse {
            vkDestroyBuffer(self.device, buf, null);
            return false;
        };

        const import_info = VkImportMemoryHostPointerInfoEXT{ .pHostPointer = host_ptr };
        var mem: VkDeviceMemory = VK_NULL;
        if (vkAllocateMemory(self.device, &.{
            .pNext = &import_info,
            .allocationSize = aligned_size,
            .memoryTypeIndex = mem_type,
        }, null, &mem) != VK_SUCCESS) {
            vkDestroyBuffer(self.device, buf, null);
            return false;
        }

        if (vkBindBufferMemory(self.device, buf, mem, 0) != VK_SUCCESS) {
            vkFreeMemory(self.device, mem, null);
            vkDestroyBuffer(self.device, buf, null);
            return false;
        }

        self.mesh_buf = buf;
        self.mesh_mem = mem;
        self.mesh_vertex_bytes = vertex_bytes;
        self.mesh_index_count = index_count;
        self.mesh_imported = true;
        return true;
    }

    /// True se la mesh corrente è importata zero-copy dal memfd.
    pub fn meshImported(self: *const Renderer) bool {
        return self.mesh_imported;
    }

    /// Rilascia la geometria. Va chiamato PRIMA che il memfd importato venga
    /// munmappato (cioè prima del deinit del LoadedFile corrente).
    pub fn releaseMesh(self: *Renderer) void {
        if (self.mesh_buf == VK_NULL) return;
        _ = vkDeviceWaitIdle(self.device);
        vkDestroyBuffer(self.device, self.mesh_buf, null);
        vkFreeMemory(self.device, self.mesh_mem, null);
        self.mesh_buf = VK_NULL;
        self.mesh_mem = VK_NULL;
        self.mesh_index_count = 0;
        self.mesh_imported = false;
    }

    /// Imposta la texture baseColor del modello corrente. Pixel RGBA8 in spazio
    /// sRGB, `w`×`h`. Con pixel vuoti/incoerenti associa una 1×1 bianca (così il
    /// materiale resta il solo colore-fattore). Da chiamare al cambio di mesh.
    pub fn setBaseColor(self: *Renderer, pixels: []const u8, w: u32, h: u32) !void {
        var sub = decoder.SubMesh{ .first_index = 0, .index_count = self.mesh_index_count };
        if (w > 0 and h > 0 and pixels.len >= @as(usize, w) * h * 4) {
            sub.tex_width = w;
            sub.tex_height = h;
            sub.tex_pixels = pixels;
        }
        try self.setSubmeshes(&[_]decoder.SubMesh{sub});
    }

    /// Configura i materiali/texture del modello a partire dai suoi submesh
    /// (glTF multi-materiale). Se il decoder non ne ha prodotti (es. OBJ/STL),
    /// sintetizza un submesh unico sui campi materiale di fallback della mesh.
    pub fn setMeshMaterials(self: *Renderer, mesh: *const decoder.MeshData) !void {
        if (mesh.submeshes.len > 0) {
            try self.setSubmeshes(mesh.submeshes);
        } else {
            const one = decoder.SubMesh{
                .first_index = 0,
                .index_count = mesh.faces.len * 3,
                .base_color = mesh.base_color,
                .metallic = mesh.metallic,
                .roughness = mesh.roughness,
                .tex_width = mesh.tex_width,
                .tex_height = mesh.tex_height,
                .tex_pixels = mesh.tex_pixels,
            };
            try self.setSubmeshes(&[_]decoder.SubMesh{one});
        }
    }

    /// Carica su GPU i submesh del modello corrente: per ciascuno un descriptor
    /// set con la propria texture baseColor (bind 0) e la shadow map (bind 1).
    /// Il pool descriptor viene ricreato dimensionato al numero di submesh.
    /// `subs` vuoto ⇒ un submesh unico bianco sull'intera geometria.
    pub fn setSubmeshes(self: *Renderer, subs: []const decoder.SubMesh) !void {
        _ = vkDeviceWaitIdle(self.device);
        self.releaseSubmeshes();
        try self.ensureWhiteTexture();
        try self.ensureFlatNormal();
        try self.ensureShadow(); // la shadow map serve al binding 1 di ogni set

        const count: u32 = if (subs.len == 0) 1 else @intCast(subs.len);

        // Ricrea il pool dimensionato per `count` set (3 sampler ciascuno:
        // baseColor + shadow map + normal map).
        vkDestroyDescriptorPool(self.device, self.mesh_dpool, null);
        self.mesh_dpool = VK_NULL;
        const pool_size = VkDescriptorPoolSize{ .type = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 3 * count };
        try check(vkCreateDescriptorPool(self.device, &.{
            .maxSets = count,
            .poolSizeCount = 1,
            .pPoolSizes = @ptrCast(&pool_size),
        }, null, &self.mesh_dpool));

        const out = try self.gpa.alloc(SubMeshGpu, count);
        errdefer self.gpa.free(out);

        for (0..count) |i| {
            var g = SubMeshGpu{
                .first_index = 0,
                .index_count = self.mesh_index_count,
                .base_color = .{ 1, 1, 1, 1 },
                .metallic = 1,
                .roughness = 1,
                .tex = self.white_tex,
                .owns_tex = false,
                .nrm_tex = self.flat_normal_tex,
                .owns_nrm_tex = false,
                .dset = VK_NULL,
            };
            if (subs.len > 0) {
                const s = subs[i];
                g.first_index = @intCast(s.first_index);
                g.index_count = @intCast(s.index_count);
                g.base_color = s.base_color;
                g.metallic = s.metallic;
                g.roughness = s.roughness;
                if (s.tex_width > 0 and s.tex_height > 0 and s.tex_pixels.len >= s.tex_width * s.tex_height * 4) {
                    g.tex = try self.createSampledTexture(s.tex_pixels, @intCast(s.tex_width), @intCast(s.tex_height), true);
                    g.owns_tex = true;
                }
                if (s.nrm_tex_width > 0 and s.nrm_tex_height > 0 and s.nrm_tex_pixels.len >= s.nrm_tex_width * s.nrm_tex_height * 4) {
                    // Normal map = dati lineari (non sRGB).
                    g.nrm_tex = try self.createSampledTexture(s.nrm_tex_pixels, @intCast(s.nrm_tex_width), @intCast(s.nrm_tex_height), false);
                    g.owns_nrm_tex = true;
                }
            }
            errdefer {
                if (g.owns_tex) self.destroyImage(g.tex);
                if (g.owns_nrm_tex) self.destroyImage(g.nrm_tex);
            }

            try check(vkAllocateDescriptorSets(self.device, &.{
                .descriptorPool = self.mesh_dpool,
                .pSetLayouts = @ptrCast(&self.mesh_dsl),
            }, &g.dset));
            self.writeSubmeshDescriptors(g.dset, g.tex.view, g.nrm_tex.view);

            out[i] = g;
        }

        self.submeshes = out;
    }

    /// Distrugge le texture possedute dai submesh e libera l'array. I descriptor
    /// set si liberano con la ricreazione del pool (fatta dal chiamante).
    fn releaseSubmeshes(self: *Renderer) void {
        for (self.submeshes) |sm| {
            if (sm.owns_tex and sm.tex.image != VK_NULL) self.destroyImage(sm.tex);
            if (sm.owns_nrm_tex and sm.nrm_tex.image != VK_NULL) self.destroyImage(sm.nrm_tex);
        }
        if (self.submeshes.len > 0) self.gpa.free(self.submeshes);
        self.submeshes = &.{};
    }

    /// Texture 1×1 bianca condivisa (per i submesh senza baseColor propria).
    fn ensureWhiteTexture(self: *Renderer) !void {
        if (self.white_tex.image != VK_NULL) return;
        const white = [_]u8{ 255, 255, 255, 255 };
        self.white_tex = try self.createSampledTexture(&white, 1, 1, true);
    }

    /// Normal map 1×1 "piatta" (+Z = (0.5,0.5,1.0)) condivisa: per i submesh senza
    /// normal map propria, il campionamento restituisce la normale geometrica.
    fn ensureFlatNormal(self: *Renderer) !void {
        if (self.flat_normal_tex.image != VK_NULL) return;
        const flat = [_]u8{ 128, 128, 255, 255 };
        self.flat_normal_tex = try self.createSampledTexture(&flat, 1, 1, false);
    }

    /// Collega al descriptor set baseColor (bind 0), shadow map (bind 1) e
    /// normal map (bind 2), in una sola update.
    fn writeSubmeshDescriptors(self: *Renderer, dset: VkDescriptorSet, tex_view: VkImageView, nrm_view: VkImageView) void {
        const infos = [_]VkDescriptorImageInfo{
            .{ .sampler = self.mesh_sampler, .imageView = tex_view, .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
            .{ .sampler = self.shadow_sampler, .imageView = self.shadow_depth.view, .imageLayout = IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL },
            .{ .sampler = self.mesh_sampler, .imageView = nrm_view, .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        };
        const writes = [_]VkWriteDescriptorSet{
            .{ .dstSet = dset, .dstBinding = 0, .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &infos[0] },
            .{ .dstSet = dset, .dstBinding = 1, .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &infos[1] },
            .{ .dstSet = dset, .dstBinding = 2, .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &infos[2] },
        };
        vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }

    /// Carica pixel RGBA come texture campionabile (sRGB se `srgb`, altrimenti
    /// lineare per le normal map) e ritorna l'ImageBundle in layout
    /// SHADER_READ_ONLY. Il chiamante ne assume la proprietà.
    fn createSampledTexture(self: *Renderer, pixels: []const u8, w: u32, h: u32, srgb: bool) !ImageBundle {
        const size: u64 = @as(u64, w) * h * 4;
        if (size == 0 or pixels.len < size) return error.BadTexture;

        const fmt: u32 = if (srgb) FORMAT_R8G8B8A8_SRGB else FORMAT_R8G8B8A8_UNORM;
        const tex = try self.createImage(w, h, fmt, IMAGE_USAGE_SAMPLED | IMAGE_USAGE_TRANSFER_DST, ASPECT_COLOR, true);
        errdefer self.destroyImage(tex);

        var staging: VkBuffer = VK_NULL;
        try check(vkCreateBuffer(self.device, &.{ .size = size, .usage = BUFFER_USAGE_TRANSFER_SRC }, null, &staging));
        defer vkDestroyBuffer(self.device, staging, null);
        var req: VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, staging, &req);
        const mt = self.findMemoryType(req.memoryTypeBits, MEM_HOST_VISIBLE | MEM_HOST_COHERENT) orelse return error.NoMemoryType;
        var smem: VkDeviceMemory = VK_NULL;
        try check(vkAllocateMemory(self.device, &.{ .allocationSize = req.size, .memoryTypeIndex = mt }, null, &smem));
        defer vkFreeMemory(self.device, smem, null);
        try check(vkBindBufferMemory(self.device, staging, smem, 0));
        var mapped: *anyopaque = undefined;
        try check(vkMapMemory(self.device, smem, 0, size, 0, &mapped));
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..@intCast(size)], pixels[0..@intCast(size)]);

        try check(vkBeginCommandBuffer(self.cmd, &.{}));
        const to_dst = [_]VkImageMemoryBarrier{.{
            .srcAccessMask = 0,
            .dstAccessMask = ACCESS_TRANSFER_WRITE,
            .oldLayout = IMAGE_LAYOUT_UNDEFINED,
            .newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .image = tex.image,
            .subresourceRange = .{ .aspectMask = ASPECT_COLOR },
        }};
        vkCmdPipelineBarrier(self.cmd, STAGE_TOP, STAGE_TRANSFER, 0, 0, null, 0, null, 1, &to_dst);
        vkCmdCopyBufferToImage(self.cmd, staging, tex.image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &[_]VkBufferImageCopy{.{
            .imageSubresource = .{ .aspectMask = ASPECT_COLOR },
            .imageExtent = .{ .width = w, .height = h, .depth = 1 },
        }});
        const to_read = [_]VkImageMemoryBarrier{.{
            .srcAccessMask = ACCESS_TRANSFER_WRITE,
            .dstAccessMask = ACCESS_SHADER_READ,
            .oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .image = tex.image,
            .subresourceRange = .{ .aspectMask = ASPECT_COLOR },
        }};
        vkCmdPipelineBarrier(self.cmd, STAGE_TRANSFER, STAGE_FRAGMENT_SHADER, 0, 0, null, 0, null, 1, &to_read);
        try check(vkEndCommandBuffer(self.cmd));
        try check(vkQueueSubmit(self.queue, 1, &[_]VkSubmitInfo{.{ .pCommandBuffers = @ptrCast(&self.cmd) }}, self.fence));
        try check(vkWaitForFences(self.device, 1, @ptrCast(&self.fence), 1, 2 * std.time.ns_per_s));
        try check(vkResetFences(self.device, 1, @ptrCast(&self.fence)));

        return tex;
    }

    /// Crea (una sola volta) le risorse per le ombre: render pass depth-only,
    /// shadow map campionabile, framebuffer, pipeline della shadow pass, e
    /// aggancia la shadow map al binding 1 del descriptor set mesh.
    fn ensureShadow(self: *Renderer) !void {
        if (self.shadow_ready) return;

        try check(vkCreateSampler(self.device, &.{}, null, &self.shadow_sampler));
        self.shadow_pass = try createShadowRenderPass(self.device);
        self.shadow_depth = try self.createImage(SHADOW_SIZE, SHADOW_SIZE, FORMAT_D32_SFLOAT, IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | IMAGE_USAGE_SAMPLED, ASPECT_DEPTH, true);
        try check(vkCreateFramebuffer(self.device, &.{
            .renderPass = self.shadow_pass,
            .attachmentCount = 1,
            .pAttachments = &[_]VkImageView{self.shadow_depth.view},
            .width = SHADOW_SIZE,
            .height = SHADOW_SIZE,
        }, null, &self.shadow_fb));

        const push = VkPushConstantRange{ .stageFlags = SHADER_STAGE_VERTEX, .offset = 0, .size = @sizeOf(ShadowPush) };
        try check(vkCreatePipelineLayout(self.device, &.{
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = @ptrCast(&push),
        }, null, &self.shadow_pipeline_layout));

        self.shadow_vert_module = try createShaderModule(self.gpa, self.device, shadow_vert_spv);
        self.shadow_frag_module = try createShaderModule(self.gpa, self.device, shadow_frag_spv);
        self.shadow_pipeline = try createShadowPipeline(self.device, self.shadow_pass, self.shadow_pipeline_layout, self.shadow_vert_module, self.shadow_frag_module);

        // La shadow map viene collegata al binding 1 di ogni descriptor set dei
        // submesh in setSubmeshes (writeSubmeshDescriptors).
        self.shadow_ready = true;
    }

    /// Renderizza la mesh corrente su un target `width`×`height` e ne fa il
    /// readback: ritorna i pixel RGBA (validi fino alla prossima chiamata).
    /// Ottimizzato con double buffering per non bloccare la CPU (asynchronous readback).
    pub fn render(self: *Renderer, width: u32, height: u32, pc: *const PushConstants) ![]const u8 {
        const slot = self.frame_index % 2;
        const prev_slot = (self.frame_index + 1) % 2;

        if (self.frame_index >= 2) {
            try check(vkWaitForFences(self.device, 1, @ptrCast(&self.frame_fences[slot]), 1, 2 * std.time.ns_per_s));
            try check(vkResetFences(self.device, 1, @ptrCast(&self.frame_fences[slot])));
        }

        try self.recordAndSubmitFrame(slot, width, height, pc);

        if (self.frame_index == 0) {
            try check(vkWaitForFences(self.device, 1, @ptrCast(&self.frame_fences[0]), 1, 2 * std.time.ns_per_s));
            self.frame_index += 1;
            return self.readback_ptrs[0].?[0 .. @as(usize, width) * height * 4];
        }

        try check(vkWaitForFences(self.device, 1, @ptrCast(&self.frame_fences[prev_slot]), 1, 2 * std.time.ns_per_s));
        self.frame_index += 1;
        return self.readback_ptrs[prev_slot].?[0 .. @as(usize, width) * height * 4];
    }

    /// Render sincrono a singolo frame: invia e attende, restituendo i pixel del
    /// frame *corrente* (a differenza di `render()`, che è pipelined e ritorna il
    /// frame precedente). Per selftest/screenshot headless dove serve leggere
    /// subito lo stato appena impostato. Usa lo slot 0: non mescolare con
    /// `render()` nella stessa sessione senza un `vkDeviceWaitIdle` in mezzo.
    pub fn renderSync(self: *Renderer, width: u32, height: u32, pc: *const PushConstants) ![]const u8 {
        try self.recordAndSubmitFrame(0, width, height, pc);
        try check(vkWaitForFences(self.device, 1, @ptrCast(&self.frame_fences[0]), 1, 2 * std.time.ns_per_s));
        try check(vkResetFences(self.device, 1, @ptrCast(&self.frame_fences[0])));
        return self.readback_ptrs[0].?[0 .. @as(usize, width) * height * 4];
    }

    fn recordAndSubmitFrame(self: *Renderer, slot: usize, width: u32, height: u32, pc: *const PushConstants) !void {
        if (self.mesh_buf == VK_NULL) return error.NoMesh;
        if (width == 0 or height == 0) return error.EmptyTarget;
        try self.ensureTarget(width, height);
        try self.ensureShadow();
        if (self.submeshes.len == 0) try self.setSubmeshes(&[_]decoder.SubMesh{});

        const cmd = self.frame_cmds[slot];
        const fence = self.frame_fences[slot];
        const readback_buf = self.readback_bufs[slot];

        try check(vkBeginCommandBuffer(cmd, &.{}));

        // --- Shadow pass: depth della scena dal punto di vista della key light.
        const shadow_clear = [_]VkClearValue{.{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } }};
        vkCmdBeginRenderPass(cmd, &.{
            .renderPass = self.shadow_pass,
            .framebuffer = self.shadow_fb,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = SHADOW_SIZE, .height = SHADOW_SIZE } },
            .clearValueCount = 1,
            .pClearValues = &shadow_clear,
        }, 0);
        vkCmdBindPipeline(cmd, 0, self.shadow_pipeline);
        vkCmdSetViewport(cmd, 0, 1, &[_]VkViewport{.{ .x = 0, .y = 0, .width = @floatFromInt(SHADOW_SIZE), .height = @floatFromInt(SHADOW_SIZE) }});
        vkCmdSetScissor(cmd, 0, 1, &[_]VkRect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = SHADOW_SIZE, .height = SHADOW_SIZE } }});
        const shadow_push = ShadowPush{ .light_vp = pc.light_vp };
        vkCmdPushConstants(cmd, self.shadow_pipeline_layout, SHADER_STAGE_VERTEX, 0, @sizeOf(ShadowPush), &shadow_push);
        vkCmdBindVertexBuffers(cmd, 0, 1, &[_]VkBuffer{self.mesh_buf}, &[_]u64{0});
        vkCmdBindIndexBuffer(cmd, self.mesh_buf, self.mesh_vertex_bytes, 1);
        vkCmdDrawIndexed(cmd, self.mesh_index_count, 1, 0, 0, 0);
        vkCmdEndRenderPass(cmd);

        const clears = [_]VkClearValue{
            .{ .color = .{ 0, 0, 0, 0 } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        vkCmdBeginRenderPass(cmd, &.{
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } },
            .clearValueCount = clears.len,
            .pClearValues = &clears,
        }, 0);

        vkCmdBindPipeline(cmd, 0, self.pipeline);
        vkCmdSetViewport(cmd, 0, 1, &[_]VkViewport{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        }});
        vkCmdSetScissor(cmd, 0, 1, &[_]VkRect2D{.{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = width, .height = height },
        }});
        vkCmdBindVertexBuffers(cmd, 0, 1, &[_]VkBuffer{self.mesh_buf}, &[_]u64{0});
        vkCmdBindIndexBuffer(cmd, self.mesh_buf, self.mesh_vertex_bytes, 1); // UINT32

        for (self.submeshes) |sm| {
            var lpc = pc.*;
            lpc.material = sm.base_color;
            lpc.nrm0[3] = sm.roughness;
            lpc.nrm1[3] = sm.metallic;
            vkCmdPushConstants(cmd, self.pipeline_layout, SHADER_STAGE_VERTEX | SHADER_STAGE_FRAGMENT, 0, @sizeOf(PushConstants), &lpc);
            vkCmdBindDescriptorSets(cmd, 0, self.pipeline_layout, 0, 1, &[_]VkDescriptorSet{sm.dset}, 0, null);
            vkCmdDrawIndexed(cmd, sm.index_count, 1, sm.first_index, 0, 0);
        }
        vkCmdEndRenderPass(cmd);

        vkCmdCopyImageToBuffer(cmd, self.color_image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback_buf, 1, &[_]VkBufferImageCopy{.{
            .imageSubresource = .{ .aspectMask = ASPECT_COLOR },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        }});
        const host_barrier = [_]VkBufferMemoryBarrier{.{
            .srcAccessMask = ACCESS_TRANSFER_WRITE,
            .dstAccessMask = ACCESS_HOST_READ,
            .buffer = readback_buf,
            .size = @as(u64, width) * height * 4,
        }};
        vkCmdPipelineBarrier(cmd, STAGE_TRANSFER, STAGE_HOST, 0, 0, null, 1, &host_barrier, 0, null);

        try check(vkEndCommandBuffer(cmd));
        try check(vkQueueSubmit(self.queue, 1, &[_]VkSubmitInfo{.{ .pCommandBuffers = @ptrCast(&cmd) }}, fence));
    }

    /// Come `render()` ma senza readback: lascia l'immagine color in layout
    /// TRANSFER_SRC_OPTIMAL per il blit su swapchain (zuer-gui).
    pub fn renderToImage(self: *Renderer, width: u32, height: u32, pc: *const PushConstants) !void {
        try self.recordAndSubmit(width, height, pc, false);
    }

    fn recordAndSubmit(self: *Renderer, width: u32, height: u32, pc: *const PushConstants, do_readback: bool) !void {
        if (self.mesh_buf == VK_NULL) return error.NoMesh;
        if (width == 0 or height == 0) return error.EmptyTarget;
        try self.ensureTarget(width, height);
        try self.ensureShadow();
        // Rete di sicurezza: senza submesh non verrebbe disegnato nulla. Ne
        // sintetizza uno bianco sull'intera geometria (materiale di default).
        if (self.submeshes.len == 0) try self.setSubmeshes(&[_]decoder.SubMesh{});

        try check(vkBeginCommandBuffer(self.cmd, &.{}));

        // --- Shadow pass: depth della scena dal punto di vista della key light.
        const shadow_clear = [_]VkClearValue{.{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } }};
        vkCmdBeginRenderPass(self.cmd, &.{
            .renderPass = self.shadow_pass,
            .framebuffer = self.shadow_fb,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = SHADOW_SIZE, .height = SHADOW_SIZE } },
            .clearValueCount = 1,
            .pClearValues = &shadow_clear,
        }, 0);
        vkCmdBindPipeline(self.cmd, 0, self.shadow_pipeline);
        vkCmdSetViewport(self.cmd, 0, 1, &[_]VkViewport{.{ .x = 0, .y = 0, .width = @floatFromInt(SHADOW_SIZE), .height = @floatFromInt(SHADOW_SIZE) }});
        vkCmdSetScissor(self.cmd, 0, 1, &[_]VkRect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = SHADOW_SIZE, .height = SHADOW_SIZE } }});
        const shadow_push = ShadowPush{ .light_vp = pc.light_vp };
        vkCmdPushConstants(self.cmd, self.shadow_pipeline_layout, SHADER_STAGE_VERTEX, 0, @sizeOf(ShadowPush), &shadow_push);
        vkCmdBindVertexBuffers(self.cmd, 0, 1, &[_]VkBuffer{self.mesh_buf}, &[_]u64{0});
        vkCmdBindIndexBuffer(self.cmd, self.mesh_buf, self.mesh_vertex_bytes, 1);
        vkCmdDrawIndexed(self.cmd, self.mesh_index_count, 1, 0, 0, 0);
        vkCmdEndRenderPass(self.cmd);

        const clears = [_]VkClearValue{
            .{ .color = .{ 0, 0, 0, 0 } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        vkCmdBeginRenderPass(self.cmd, &.{
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } },
            .clearValueCount = clears.len,
            .pClearValues = &clears,
        }, 0);

        vkCmdBindPipeline(self.cmd, 0, self.pipeline);
        vkCmdSetViewport(self.cmd, 0, 1, &[_]VkViewport{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        }});
        vkCmdSetScissor(self.cmd, 0, 1, &[_]VkRect2D{.{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = width, .height = height },
        }});
        vkCmdBindVertexBuffers(self.cmd, 0, 1, &[_]VkBuffer{self.mesh_buf}, &[_]u64{0});
        vkCmdBindIndexBuffer(self.cmd, self.mesh_buf, self.mesh_vertex_bytes, 1); // UINT32

        // Un draw per submesh: stessa geometria, ma materiale (baseColor factor,
        // roughness, metallic nei .w) e texture propri, iniettati per intervallo.
        for (self.submeshes) |sm| {
            var lpc = pc.*;
            lpc.material = sm.base_color;
            lpc.nrm0[3] = sm.roughness;
            lpc.nrm1[3] = sm.metallic;
            vkCmdPushConstants(self.cmd, self.pipeline_layout, SHADER_STAGE_VERTEX | SHADER_STAGE_FRAGMENT, 0, @sizeOf(PushConstants), &lpc);
            vkCmdBindDescriptorSets(self.cmd, 0, self.pipeline_layout, 0, 1, &[_]VkDescriptorSet{sm.dset}, 0, null);
            vkCmdDrawIndexed(self.cmd, sm.index_count, 1, sm.first_index, 0, 0);
        }
        vkCmdEndRenderPass(self.cmd);

        if (do_readback) {
            vkCmdCopyImageToBuffer(self.cmd, self.color_image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.readback_buf, 1, &[_]VkBufferImageCopy{.{
                .imageSubresource = .{ .aspectMask = ASPECT_COLOR },
                .imageExtent = .{ .width = width, .height = height, .depth = 1 },
            }});
            const host_barrier = [_]VkBufferMemoryBarrier{.{
                .srcAccessMask = ACCESS_TRANSFER_WRITE,
                .dstAccessMask = ACCESS_HOST_READ,
                .buffer = self.readback_buf,
                .size = @as(u64, width) * height * 4,
            }};
            vkCmdPipelineBarrier(self.cmd, STAGE_TRANSFER, STAGE_HOST, 0, 0, null, 1, &host_barrier, 0, null);
        }

        try check(vkEndCommandBuffer(self.cmd));
        try check(vkQueueSubmit(self.queue, 1, &[_]VkSubmitInfo{.{ .pCommandBuffers = @ptrCast(&self.cmd) }}, self.fence));
        // Prima il check del wait: resettare una fence ancora in-flight è UB.
        try check(vkWaitForFences(self.device, 1, @ptrCast(&self.fence), 1, 2 * std.time.ns_per_s));
        try check(vkResetFences(self.device, 1, @ptrCast(&self.fence)));
    }

    // --- Rendering voxel (ray-march di una texture 3D) --------------------

    /// True se una griglia voxel è stata caricata (`setVoxels`).
    pub fn hasVoxels(self: *const Renderer) bool {
        return self.voxel_dim > 0;
    }

    /// Carica la griglia voxel `dim`³ (RGBA8, `data` = dim³×4) in uno storage
    /// buffer host-visible (un uint RGBA8-packed little-endian per voxel) e lo
    /// aggancia al descriptor set voxel. Nessun command buffer: solo memcpy,
    /// quindi non può andare in device-lost come l'upload di una texture 3D.
    pub fn setVoxels(self: *Renderer, dim: u32, data: []const u8) !void {
        if (dim == 0) return error.BadVoxelGrid;
        const cells: u64 = @as(u64, dim) * dim * dim;
        const size: u64 = cells * 4;
        if (data.len < size) return error.BadVoxelGrid;

        try self.ensureVoxelPipeline();

        _ = vkDeviceWaitIdle(self.device);
        if (self.voxel_buf != VK_NULL) {
            vkDestroyBuffer(self.device, self.voxel_buf, null);
            vkFreeMemory(self.device, self.voxel_mem, null);
            self.voxel_buf = VK_NULL;
            self.voxel_mem = VK_NULL;
            self.voxel_dim = 0;
        }

        var buf: VkBuffer = VK_NULL;
        try check(vkCreateBuffer(self.device, &.{ .size = size, .usage = BUFFER_USAGE_STORAGE }, null, &buf));
        errdefer vkDestroyBuffer(self.device, buf, null);
        var req: VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, buf, &req);
        const mt = self.findMemoryType(req.memoryTypeBits, MEM_HOST_VISIBLE | MEM_HOST_COHERENT) orelse return error.NoMemoryType;
        var mem: VkDeviceMemory = VK_NULL;
        try check(vkAllocateMemory(self.device, &.{ .allocationSize = req.size, .memoryTypeIndex = mt }, null, &mem));
        errdefer vkFreeMemory(self.device, mem, null);
        try check(vkBindBufferMemory(self.device, buf, mem, 0));
        var mapped: *anyopaque = undefined;
        try check(vkMapMemory(self.device, mem, 0, size, 0, &mapped));
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..@intCast(size)], data[0..@intCast(size)]);

        const buf_info = VkDescriptorBufferInfo{ .buffer = buf, .offset = 0, .range = size };
        const write = [_]VkWriteDescriptorSet{.{
            .dstSet = self.voxel_dset,
            .dstBinding = 0,
            .descriptorType = DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buf_info,
        }};
        vkUpdateDescriptorSets(self.device, 1, &write, 0, null);

        self.voxel_buf = buf;
        self.voxel_mem = mem;
        self.voxel_dim = dim;
    }

    /// Riporta il double-buffer di `render()` a uno stato pulito e sincrono.
    /// Necessario quando si alterna `render()` (pipelined, slot ping-pong) e
    /// `renderVoxel()`/`renderSync()` (slot 0 sincrono): senza questo, una fence
    /// signaled in volo dal path pipelined verrebbe ri-submittata (invalido) o
    /// una attesa su slot 0 già resettato andrebbe in timeout.
    pub fn resetFrameSync(self: *Renderer) void {
        _ = vkDeviceWaitIdle(self.device);
        // Dopo il wait idle nessun submit è pendente: si possono resettare
        // entrambe le fence (reset di una fence già unsignaled è valido).
        _ = vkResetFences(self.device, 2, @ptrCast(&self.frame_fences));
        self.frame_index = 0;
    }

    /// Renderizza la griglia voxel e ne fa il readback (RGBA, valido fino alla
    /// prossima chiamata).
    pub fn renderVoxel(self: *Renderer, width: u32, height: u32, pc: *const VoxelPush) ![]const u8 {
        try self.recordVoxel(width, height, pc, true);
        return self.readback_ptr.?[0 .. @as(usize, width) * height * 4];
    }

    /// Come `renderVoxel` ma senza readback (per il blit su swapchain).
    pub fn renderVoxelToImage(self: *Renderer, width: u32, height: u32, pc: *const VoxelPush) !void {
        try self.recordVoxel(width, height, pc, false);
    }

    fn recordVoxel(self: *Renderer, width: u32, height: u32, pc: *const VoxelPush, do_readback: bool) !void {
        if (self.voxel_dim == 0) return error.NoVoxels;
        if (width == 0 or height == 0) return error.EmptyTarget;
        try self.ensureTarget(width, height);

        // Usa lo slot 0 del path frame (come `renderSync`): `renderVoxel` è
        // sincrono e non si interlaccia con `render()` durante il selftest/GUI.
        const cmd = self.frame_cmds[0];
        const fence = self.frame_fences[0];
        const readback_buf = self.readback_bufs[0];

        try check(vkBeginCommandBuffer(cmd, &.{}));
        const clears = [_]VkClearValue{
            .{ .color = .{ 0, 0, 0, 0 } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        vkCmdBeginRenderPass(cmd, &.{
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } },
            .clearValueCount = clears.len,
            .pClearValues = &clears,
        }, 0);
        vkCmdBindPipeline(cmd, 0, self.voxel_pipeline);
        vkCmdSetViewport(cmd, 0, 1, &[_]VkViewport{.{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height) }});
        vkCmdSetScissor(cmd, 0, 1, &[_]VkRect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } }});
        vkCmdPushConstants(cmd, self.voxel_pipeline_layout, SHADER_STAGE_FRAGMENT, 0, @sizeOf(VoxelPush), pc);
        vkCmdBindDescriptorSets(cmd, 0, self.voxel_pipeline_layout, 0, 1, &[_]VkDescriptorSet{self.voxel_dset}, 0, null);
        vkCmdDraw(cmd, 3, 1, 0, 0);
        vkCmdEndRenderPass(cmd);

        if (do_readback) {
            vkCmdCopyImageToBuffer(cmd, self.color_image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback_buf, 1, &[_]VkBufferImageCopy{.{
                .imageSubresource = .{ .aspectMask = ASPECT_COLOR },
                .imageExtent = .{ .width = width, .height = height, .depth = 1 },
            }});
            const host_barrier = [_]VkBufferMemoryBarrier{.{
                .srcAccessMask = ACCESS_TRANSFER_WRITE,
                .dstAccessMask = ACCESS_HOST_READ,
                .buffer = readback_buf,
                .size = @as(u64, width) * height * 4,
            }};
            vkCmdPipelineBarrier(cmd, STAGE_TRANSFER, STAGE_HOST, 0, 0, null, 1, &host_barrier, 0, null);
        }

        try check(vkEndCommandBuffer(cmd));
        try check(vkQueueSubmit(self.queue, 1, &[_]VkSubmitInfo{.{ .pCommandBuffers = @ptrCast(&cmd) }}, fence));
        try check(vkWaitForFences(self.device, 1, @ptrCast(&fence), 1, 2 * std.time.ns_per_s));
        try check(vkResetFences(self.device, 1, @ptrCast(&fence)));
    }

    /// Crea (una sola volta) descriptor set, layout e pipeline del ray-march
    /// voxel. La griglia è uno storage buffer (binding 0). Riusa il render pass
    /// principale (fullscreen, no depth).
    fn ensureVoxelPipeline(self: *Renderer) !void {
        if (self.voxel_ready) return;

        const binding = VkDescriptorSetLayoutBinding{ .binding = 0, .descriptorType = DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = SHADER_STAGE_FRAGMENT };
        try check(vkCreateDescriptorSetLayout(self.device, &.{ .bindingCount = 1, .pBindings = @ptrCast(&binding) }, null, &self.voxel_dsl));

        const pool_size = VkDescriptorPoolSize{ .type = DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 };
        try check(vkCreateDescriptorPool(self.device, &.{ .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = @ptrCast(&pool_size) }, null, &self.voxel_dpool));
        try check(vkAllocateDescriptorSets(self.device, &.{ .descriptorPool = self.voxel_dpool, .pSetLayouts = @ptrCast(&self.voxel_dsl) }, &self.voxel_dset));

        const push = VkPushConstantRange{ .stageFlags = SHADER_STAGE_FRAGMENT, .offset = 0, .size = @sizeOf(VoxelPush) };
        try check(vkCreatePipelineLayout(self.device, &.{
            .setLayoutCount = 1,
            .pSetLayouts = @ptrCast(&self.voxel_dsl),
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = @ptrCast(&push),
        }, null, &self.voxel_pipeline_layout));

        self.voxel_vert_module = try createShaderModule(self.gpa, self.device, voxel_vert_spv);
        self.voxel_frag_module = try createShaderModule(self.gpa, self.device, voxel_frag_spv);
        self.voxel_pipeline = try createVoxelPipeline(self.device, self.render_pass, self.voxel_pipeline_layout, self.voxel_vert_module, self.voxel_frag_module);

        self.voxel_ready = true;
    }

    fn ensureTarget(self: *Renderer, width: u32, height: u32) !void {
        if (self.width == width and self.height == height) return;
        _ = vkDeviceWaitIdle(self.device);
        self.destroyTarget();

        const color = try self.createImage(width, height, FORMAT_R8G8B8A8_UNORM, IMAGE_USAGE_COLOR_ATTACHMENT | IMAGE_USAGE_TRANSFER_SRC, ASPECT_COLOR, true);
        errdefer self.destroyImage(color);
        const depth = try self.createImage(width, height, FORMAT_D32_SFLOAT, IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT, ASPECT_DEPTH, true);
        errdefer self.destroyImage(depth);

        var framebuffer: VkFramebuffer = VK_NULL;
        const attachments = [_]VkImageView{ color.view, depth.view };
        try check(vkCreateFramebuffer(self.device, &.{
            .renderPass = self.render_pass,
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .width = width,
            .height = height,
        }, null, &framebuffer));
        errdefer vkDestroyFramebuffer(self.device, framebuffer, null);

        // Buffer di readback host-visible, mappato in modo persistente (due slot per pipelining).
        const rb_size = @as(u64, width) * height * 4;

        var i: usize = 0;
        while (i < 2) : (i += 1) {
            var rb_buf: VkBuffer = VK_NULL;
            try check(vkCreateBuffer(self.device, &.{ .size = rb_size, .usage = BUFFER_USAGE_TRANSFER_DST }, null, &rb_buf));
            errdefer vkDestroyBuffer(self.device, rb_buf, null);
            var req: VkMemoryRequirements = undefined;
            vkGetBufferMemoryRequirements(self.device, rb_buf, &req);
            const mem_type = self.findMemoryType(req.memoryTypeBits, MEM_HOST_VISIBLE | MEM_HOST_COHERENT) orelse return error.NoMemoryType;
            var rb_mem: VkDeviceMemory = VK_NULL;
            try check(vkAllocateMemory(self.device, &.{ .allocationSize = req.size, .memoryTypeIndex = mem_type }, null, &rb_mem));
            errdefer vkFreeMemory(self.device, rb_mem, null);
            try check(vkBindBufferMemory(self.device, rb_buf, rb_mem, 0));
            var mapped: *anyopaque = undefined;
            try check(vkMapMemory(self.device, rb_mem, 0, rb_size, 0, &mapped));

            self.readback_bufs[i] = rb_buf;
            self.readback_mems[i] = rb_mem;
            self.readback_ptrs[i] = @ptrCast(mapped);
        }

        self.width = width;
        self.height = height;
        self.color_image = color.image;
        self.color_mem = color.mem;
        self.color_view = color.view;
        self.depth_image = depth.image;
        self.depth_mem = depth.mem;
        self.depth_view = depth.view;
        self.framebuffer = framebuffer;

        // Mappatura compatibile a singolo buffer su slot 0
        self.readback_buf = self.readback_bufs[0];
        self.readback_mem = self.readback_mems[0];
        self.readback_ptr = self.readback_ptrs[0];
    }

    const ImageBundle = struct { image: VkImage, mem: VkDeviceMemory, view: VkImageView };

    /// Sotto-mesh sul lato GPU: intervallo dell'index buffer + materiale +
    /// descriptor set con la propria texture baseColor.
    const SubMeshGpu = struct {
        first_index: u32,
        index_count: u32,
        base_color: [4]f32,
        metallic: f32,
        roughness: f32,
        tex: ImageBundle,
        owns_tex: bool, // false se `tex` è la bianca condivisa
        nrm_tex: ImageBundle,
        owns_nrm_tex: bool, // false se `nrm_tex` è la flat condivisa
        dset: VkDescriptorSet,
    };

    fn createImage(self: *Renderer, width: u32, height: u32, format: u32, usage: u32, aspect: u32, with_view: bool) !ImageBundle {
        var image: VkImage = VK_NULL;
        try check(vkCreateImage(self.device, &.{
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .usage = usage,
        }, null, &image));
        errdefer vkDestroyImage(self.device, image, null);

        var req: VkMemoryRequirements = undefined;
        vkGetImageMemoryRequirements(self.device, image, &req);
        const mem_type = self.findMemoryType(req.memoryTypeBits, MEM_DEVICE_LOCAL) orelse
            self.findMemoryType(req.memoryTypeBits, 0) orelse return error.NoMemoryType;
        var mem: VkDeviceMemory = VK_NULL;
        try check(vkAllocateMemory(self.device, &.{ .allocationSize = req.size, .memoryTypeIndex = mem_type }, null, &mem));
        errdefer vkFreeMemory(self.device, mem, null);
        try check(vkBindImageMemory(self.device, image, mem, 0));

        // Le immagini solo-transfer (texture) non ammettono view.
        var view: VkImageView = VK_NULL;
        if (with_view) {
            try check(vkCreateImageView(self.device, &.{
                .image = image,
                .format = format,
                .subresourceRange = .{ .aspectMask = aspect },
            }, null, &view));
        }

        return .{ .image = image, .mem = mem, .view = view };
    }

    fn destroyImage(self: *Renderer, bundle: ImageBundle) void {
        if (bundle.view != VK_NULL) vkDestroyImageView(self.device, bundle.view, null);
        vkDestroyImage(self.device, bundle.image, null);
        vkFreeMemory(self.device, bundle.mem, null);
    }

    fn destroyTarget(self: *Renderer) void {
        if (self.width == 0) return;
        vkDestroyFramebuffer(self.device, self.framebuffer, null);
        self.destroyImage(.{ .image = self.color_image, .mem = self.color_mem, .view = self.color_view });
        self.destroyImage(.{ .image = self.depth_image, .mem = self.depth_mem, .view = self.depth_view });

        var i: usize = 0;
        while (i < 2) : (i += 1) {
            if (self.readback_bufs[i] != VK_NULL) {
                vkDestroyBuffer(self.device, self.readback_bufs[i], null);
                self.readback_bufs[i] = VK_NULL;
            }
            if (self.readback_mems[i] != VK_NULL) {
                vkFreeMemory(self.device, self.readback_mems[i], null);
                self.readback_mems[i] = VK_NULL;
            }
            self.readback_ptrs[i] = null;
        }

        self.readback_buf = VK_NULL;
        self.readback_mem = VK_NULL;
        self.readback_ptr = null;

        self.width = 0;
        self.height = 0;
        self.frame_index = 0;
    }

    fn findMemoryType(self: *const Renderer, type_bits: u32, required: u32) ?u32 {
        for (self.mem_props.memoryTypes[0..self.mem_props.memoryTypeCount], 0..) |mt, i| {
            const bit = @as(u32, 1) << @intCast(i);
            if (type_bits & bit != 0 and mt.propertyFlags & required == required) {
                return @intCast(i);
            }
        }
        return null;
    }

    // --- Pipeline testo (atlante glifi su GPU) ----------------------------

    /// Crea (una sola volta) sampler, descriptor set, layout e pipeline del
    /// testo. Riusa il render pass mesh (color+depth) con depth-test spento.
    fn ensureTextPipe(self: *Renderer) !void {
        if (self.text_ready) return;

        try check(vkCreateSampler(self.device, &.{}, null, &self.text_sampler));

        const binding = VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = SHADER_STAGE_FRAGMENT,
        };
        try check(vkCreateDescriptorSetLayout(self.device, &.{
            .bindingCount = 1,
            .pBindings = @ptrCast(&binding),
        }, null, &self.text_dsl));

        const pool_size = VkDescriptorPoolSize{ .type = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 };
        try check(vkCreateDescriptorPool(self.device, &.{
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = @ptrCast(&pool_size),
        }, null, &self.text_dpool));
        try check(vkAllocateDescriptorSets(self.device, &.{
            .descriptorPool = self.text_dpool,
            .pSetLayouts = @ptrCast(&self.text_dsl),
        }, &self.text_dset));

        const push = VkPushConstantRange{ .stageFlags = SHADER_STAGE_VERTEX, .offset = 0, .size = @sizeOf(TextPush) };
        try check(vkCreatePipelineLayout(self.device, &.{
            .setLayoutCount = 1,
            .pSetLayouts = @ptrCast(&self.text_dsl),
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = @ptrCast(&push),
        }, null, &self.text_pipeline_layout));

        self.text_vert_module = try createShaderModule(self.gpa, self.device, text_vert_spv);
        self.text_frag_module = try createShaderModule(self.gpa, self.device, text_frag_spv);
        self.text_pipeline = try createTextPipeline(self.device, self.render_pass, self.text_pipeline_layout, self.text_vert_module, self.text_frag_module);

        self.text_ready = true;
    }

    /// (Ri)carica l'atlante di copertura come texture campionabile e aggiorna il
    /// descriptor set. Ricrea la texture ad ogni chiamata (una per documento).
    fn uploadAtlas(self: *Renderer, pixels: []const u8, w: u32, h: u32) !void {
        if (w == 0 or h == 0 or pixels.len < @as(usize, w) * h) return error.BadAtlas;

        if (self.text_atlas.image != VK_NULL) {
            self.destroyImage(self.text_atlas);
            self.text_atlas = .{ .image = VK_NULL, .mem = VK_NULL, .view = VK_NULL };
        }

        const atlas = try self.createImage(w, h, FORMAT_R8_UNORM, IMAGE_USAGE_SAMPLED | IMAGE_USAGE_TRANSFER_DST, ASPECT_COLOR, true);
        errdefer self.destroyImage(atlas);

        const size: u64 = @as(u64, w) * h;
        var staging: VkBuffer = VK_NULL;
        try check(vkCreateBuffer(self.device, &.{ .size = size, .usage = BUFFER_USAGE_TRANSFER_SRC }, null, &staging));
        defer vkDestroyBuffer(self.device, staging, null);
        var req: VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, staging, &req);
        const mt = self.findMemoryType(req.memoryTypeBits, MEM_HOST_VISIBLE | MEM_HOST_COHERENT) orelse return error.NoMemoryType;
        var smem: VkDeviceMemory = VK_NULL;
        try check(vkAllocateMemory(self.device, &.{ .allocationSize = req.size, .memoryTypeIndex = mt }, null, &smem));
        defer vkFreeMemory(self.device, smem, null);
        try check(vkBindBufferMemory(self.device, staging, smem, 0));
        var mapped: *anyopaque = undefined;
        try check(vkMapMemory(self.device, smem, 0, size, 0, &mapped));
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..@intCast(size)], pixels[0..@intCast(size)]);

        try check(vkBeginCommandBuffer(self.cmd, &.{}));
        const to_dst = [_]VkImageMemoryBarrier{.{
            .srcAccessMask = 0,
            .dstAccessMask = ACCESS_TRANSFER_WRITE,
            .oldLayout = IMAGE_LAYOUT_UNDEFINED,
            .newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .image = atlas.image,
            .subresourceRange = .{ .aspectMask = ASPECT_COLOR },
        }};
        vkCmdPipelineBarrier(self.cmd, STAGE_TOP, STAGE_TRANSFER, 0, 0, null, 0, null, 1, &to_dst);
        vkCmdCopyBufferToImage(self.cmd, staging, atlas.image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &[_]VkBufferImageCopy{.{
            .imageSubresource = .{ .aspectMask = ASPECT_COLOR },
            .imageExtent = .{ .width = w, .height = h, .depth = 1 },
        }});
        const to_read = [_]VkImageMemoryBarrier{.{
            .srcAccessMask = ACCESS_TRANSFER_WRITE,
            .dstAccessMask = ACCESS_SHADER_READ,
            .oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .image = atlas.image,
            .subresourceRange = .{ .aspectMask = ASPECT_COLOR },
        }};
        vkCmdPipelineBarrier(self.cmd, STAGE_TRANSFER, STAGE_FRAGMENT_SHADER, 0, 0, null, 0, null, 1, &to_read);
        try check(vkEndCommandBuffer(self.cmd));
        try check(vkQueueSubmit(self.queue, 1, &[_]VkSubmitInfo{.{ .pCommandBuffers = @ptrCast(&self.cmd) }}, self.fence));
        try check(vkWaitForFences(self.device, 1, @ptrCast(&self.fence), 1, 2 * std.time.ns_per_s));
        try check(vkResetFences(self.device, 1, @ptrCast(&self.fence)));

        const img_info = VkDescriptorImageInfo{
            .sampler = self.text_sampler,
            .imageView = atlas.view,
            .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write = [_]VkWriteDescriptorSet{.{
            .dstSet = self.text_dset,
            .dstBinding = 0,
            .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &img_info,
        }};
        vkUpdateDescriptorSets(self.device, 1, &write, 0, null);

        self.text_atlas = atlas;
        self.text_atlas_w = w;
        self.text_atlas_h = h;
    }

    /// Assicura un vertex buffer host-visible capace di contenere i vertici e vi
    /// copia i dati (host-coherent, niente flush).
    fn ensureTextVertexBuffer(self: *Renderer, bytes: []const u8) !void {
        const need: u64 = @max(bytes.len, 4);
        if (self.text_vbuf == VK_NULL or self.text_vbuf_cap < need) {
            if (self.text_vbuf != VK_NULL) {
                vkDestroyBuffer(self.device, self.text_vbuf, null);
                vkFreeMemory(self.device, self.text_vmem, null);
                self.text_vbuf = VK_NULL;
            }
            var buf: VkBuffer = VK_NULL;
            try check(vkCreateBuffer(self.device, &.{ .size = need, .usage = BUFFER_USAGE_VERTEX }, null, &buf));
            errdefer vkDestroyBuffer(self.device, buf, null);
            var req: VkMemoryRequirements = undefined;
            vkGetBufferMemoryRequirements(self.device, buf, &req);
            const mt = self.findMemoryType(req.memoryTypeBits, MEM_HOST_VISIBLE | MEM_HOST_COHERENT) orelse return error.NoMemoryType;
            var mem: VkDeviceMemory = VK_NULL;
            try check(vkAllocateMemory(self.device, &.{ .allocationSize = req.size, .memoryTypeIndex = mt }, null, &mem));
            errdefer vkFreeMemory(self.device, mem, null);
            try check(vkBindBufferMemory(self.device, buf, mem, 0));
            var mapped: *anyopaque = undefined;
            try check(vkMapMemory(self.device, mem, 0, need, 0, &mapped));
            self.text_vbuf = buf;
            self.text_vmem = mem;
            self.text_vbuf_cap = need;
            self.text_vptr = @ptrCast(mapped);
        }
        if (bytes.len > 0) @memcpy(self.text_vptr.?[0..bytes.len], bytes);
    }

    /// Renderizza il testo (quad texturati dall'atlante) in un'immagine RGBA.
    /// `vertex_bytes` = vertici (pos+uv+colore, stride 28); `clear` = sfondo.
    /// Ritorna i pixel RGBA letti (validi fino alla chiamata successiva).
    pub fn renderText(self: *Renderer, vertex_bytes: []const u8, vertex_count: u32, atlas_pixels: []const u8, atlas_w: u32, atlas_h: u32, out_w: u32, out_h: u32, clear: [4]f32) ![]const u8 {
        if (out_w == 0 or out_h == 0) return error.EmptyTarget;
        try self.ensureTextPipe();
        try self.uploadAtlas(atlas_pixels, atlas_w, atlas_h);
        try self.ensureTextVertexBuffer(vertex_bytes);
        try self.ensureTarget(out_w, out_h);

        try check(vkBeginCommandBuffer(self.cmd, &.{}));
        const clears = [_]VkClearValue{
            .{ .color = clear },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        vkCmdBeginRenderPass(self.cmd, &.{
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = out_w, .height = out_h } },
            .clearValueCount = clears.len,
            .pClearValues = &clears,
        }, 0);

        vkCmdBindPipeline(self.cmd, 0, self.text_pipeline);
        vkCmdSetViewport(self.cmd, 0, 1, &[_]VkViewport{.{ .x = 0, .y = 0, .width = @floatFromInt(out_w), .height = @floatFromInt(out_h) }});
        vkCmdSetScissor(self.cmd, 0, 1, &[_]VkRect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = out_w, .height = out_h } }});
        const push = TextPush{ .viewport = .{ @floatFromInt(out_w), @floatFromInt(out_h) } };
        vkCmdPushConstants(self.cmd, self.text_pipeline_layout, SHADER_STAGE_VERTEX, 0, @sizeOf(TextPush), &push);
        vkCmdBindDescriptorSets(self.cmd, 0, self.text_pipeline_layout, 0, 1, &[_]VkDescriptorSet{self.text_dset}, 0, null);
        vkCmdBindVertexBuffers(self.cmd, 0, 1, &[_]VkBuffer{self.text_vbuf}, &[_]u64{0});
        if (vertex_count > 0) vkCmdDraw(self.cmd, vertex_count, 1, 0, 0);
        vkCmdEndRenderPass(self.cmd);

        vkCmdCopyImageToBuffer(self.cmd, self.color_image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.readback_buf, 1, &[_]VkBufferImageCopy{.{
            .imageSubresource = .{ .aspectMask = ASPECT_COLOR },
            .imageExtent = .{ .width = out_w, .height = out_h, .depth = 1 },
        }});
        const host_barrier = [_]VkBufferMemoryBarrier{.{
            .srcAccessMask = ACCESS_TRANSFER_WRITE,
            .dstAccessMask = ACCESS_HOST_READ,
            .buffer = self.readback_buf,
            .size = @as(u64, out_w) * out_h * 4,
        }};
        vkCmdPipelineBarrier(self.cmd, STAGE_TRANSFER, STAGE_HOST, 0, 0, null, 1, &host_barrier, 0, null);

        try check(vkEndCommandBuffer(self.cmd));
        try check(vkQueueSubmit(self.queue, 1, &[_]VkSubmitInfo{.{ .pCommandBuffers = @ptrCast(&self.cmd) }}, self.fence));
        try check(vkWaitForFences(self.device, 1, @ptrCast(&self.fence), 1, 2 * std.time.ns_per_s));
        try check(vkResetFences(self.device, 1, @ptrCast(&self.fence)));

        return self.readback_ptr.?[0 .. @as(usize, out_w) * out_h * 4];
    }

    fn destroyTextPipe(self: *Renderer) void {
        if (self.text_vbuf != VK_NULL) {
            vkDestroyBuffer(self.device, self.text_vbuf, null);
            vkFreeMemory(self.device, self.text_vmem, null);
        }
        if (self.text_atlas.image != VK_NULL) self.destroyImage(self.text_atlas);
        if (!self.text_ready) return;
        vkDestroyPipeline(self.device, self.text_pipeline, null);
        vkDestroyPipelineLayout(self.device, self.text_pipeline_layout, null);
        vkDestroyShaderModule(self.device, self.text_vert_module, null);
        vkDestroyShaderModule(self.device, self.text_frag_module, null);
        vkDestroyDescriptorPool(self.device, self.text_dpool, null);
        vkDestroyDescriptorSetLayout(self.device, self.text_dsl, null);
        vkDestroySampler(self.device, self.text_sampler, null);
    }
};

fn deviceHasExtension(gpa: std.mem.Allocator, pd: VkPhysicalDevice, name: []const u8) bool {
    var count: u32 = 0;
    if (vkEnumerateDeviceExtensionProperties(pd, null, &count, null) != VK_SUCCESS) return false;
    const exts = gpa.alloc(VkExtensionProperties, count) catch return false;
    defer gpa.free(exts);
    if (vkEnumerateDeviceExtensionProperties(pd, null, &count, exts.ptr) != VK_SUCCESS) return false;
    for (exts[0..count]) |ext| {
        const ext_name = std.mem.sliceTo(&ext.extensionName, 0);
        if (std.mem.eql(u8, ext_name, name)) return true;
    }
    return false;
}

fn createRenderPass(device: VkDevice) !VkRenderPass {
    const attachments = [_]VkAttachmentDescription{
        .{
            .format = FORMAT_R8G8B8A8_UNORM,
            .loadOp = 1, // CLEAR
            .storeOp = 0, // STORE
            .initialLayout = IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        },
        .{
            .format = FORMAT_D32_SFLOAT,
            .loadOp = 1, // CLEAR
            .storeOp = 1, // DONT_CARE
            .initialLayout = IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        },
    };
    const color_ref = VkAttachmentReference{ .attachment = 0, .layout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    const depth_ref = VkAttachmentReference{ .attachment = 1, .layout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    const subpass = VkSubpassDescription{
        .pColorAttachments = &color_ref,
        .pDepthStencilAttachment = &depth_ref,
    };
    const deps = [_]VkSubpassDependency{
        .{
            .srcSubpass = SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = STAGE_COLOR_ATTACHMENT_OUTPUT | STAGE_EARLY_FRAGMENT_TESTS | STAGE_TRANSFER,
            .dstStageMask = STAGE_COLOR_ATTACHMENT_OUTPUT | STAGE_EARLY_FRAGMENT_TESTS,
            .srcAccessMask = ACCESS_TRANSFER_READ,
            .dstAccessMask = ACCESS_COLOR_WRITE | ACCESS_DEPTH_WRITE,
        },
        .{
            .srcSubpass = 0,
            .dstSubpass = SUBPASS_EXTERNAL,
            .srcStageMask = STAGE_COLOR_ATTACHMENT_OUTPUT,
            .dstStageMask = STAGE_TRANSFER,
            .srcAccessMask = ACCESS_COLOR_WRITE,
            .dstAccessMask = ACCESS_TRANSFER_READ,
        },
    };
    var render_pass: VkRenderPass = VK_NULL;
    try check(vkCreateRenderPass(device, &.{
        .attachmentCount = attachments.len,
        .pAttachments = &attachments,
        .pSubpasses = &subpass,
        .dependencyCount = deps.len,
        .pDependencies = &deps,
    }, null, &render_pass));
    return render_pass;
}

fn createShaderModule(gpa: std.mem.Allocator, device: VkDevice, spv: []const u8) !VkShaderModule {
    if (spv.len == 0 or spv.len % 4 != 0) return error.BadSpirv;
    // @embedFile non garantisce l'allineamento a 4 richiesto da pCode.
    const words = try gpa.alloc(u32, (spv.len + 3) / 4);
    defer gpa.free(words);
    @memcpy(std.mem.sliceAsBytes(words)[0..spv.len], spv);

    var module: VkShaderModule = VK_NULL;
    try check(vkCreateShaderModule(device, &.{
        .codeSize = spv.len,
        .pCode = words.ptr,
    }, null, &module));
    return module;
}

fn createPipeline(device: VkDevice, render_pass: VkRenderPass, layout: VkPipelineLayout, vert: VkShaderModule, frag: VkShaderModule) !VkPipeline {
    const stages = [_]VkPipelineShaderStageCreateInfo{
        .{ .stage = SHADER_STAGE_VERTEX, .module = vert },
        .{ .stage = SHADER_STAGE_FRAGMENT, .module = frag },
    };
    // Vertice interleaved: pos(vec3)+normal(vec3)+uv(vec2)+tangent(vec4), stride 48.
    const binding = VkVertexInputBindingDescription{ .binding = 0, .stride = 48 };
    const attrs = [_]VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = FORMAT_R32G32B32_SFLOAT, .offset = 0 },
        .{ .location = 1, .binding = 0, .format = FORMAT_R32G32B32_SFLOAT, .offset = 12 },
        .{ .location = 2, .binding = 0, .format = FORMAT_R32G32_SFLOAT, .offset = 24 },
        .{ .location = 3, .binding = 0, .format = FORMAT_R32G32B32A32_SFLOAT, .offset = 32 },
    };
    const vertex_input = VkPipelineVertexInputStateCreateInfo{
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = @ptrCast(&binding),
        .vertexAttributeDescriptionCount = attrs.len,
        .pVertexAttributeDescriptions = &attrs,
    };
    const input_assembly = VkPipelineInputAssemblyStateCreateInfo{};
    const viewport_state = VkPipelineViewportStateCreateInfo{};
    const rasterization = VkPipelineRasterizationStateCreateInfo{};
    const multisample = VkPipelineMultisampleStateCreateInfo{};
    const depth_stencil = VkPipelineDepthStencilStateCreateInfo{};
    const blend_attachment = VkPipelineColorBlendAttachmentState{};
    const color_blend = VkPipelineColorBlendStateCreateInfo{ .pAttachments = &blend_attachment };
    const dynamic_states = [_]u32{ 0, 1 }; // VIEWPORT, SCISSOR
    const dynamic = VkPipelineDynamicStateCreateInfo{
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const info = VkGraphicsPipelineCreateInfo{
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic,
        .layout = layout,
        .renderPass = render_pass,
    };
    var pipeline: VkPipeline = VK_NULL;
    try check(vkCreateGraphicsPipelines(device, VK_NULL, 1, @ptrCast(&info), null, @ptrCast(&pipeline)));
    return pipeline;
}

/// Render pass della shadow map: solo depth, con transizione finale a layout
/// campionabile per il lookup nel main pass.
fn createShadowRenderPass(device: VkDevice) !VkRenderPass {
    const attachments = [_]VkAttachmentDescription{.{
        .format = FORMAT_D32_SFLOAT,
        .loadOp = 1, // CLEAR
        .storeOp = 0, // STORE: serve per campionarla dopo
        .initialLayout = IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    }};
    const depth_ref = VkAttachmentReference{ .attachment = 0, .layout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    const dummy_color = VkAttachmentReference{ .attachment = 0, .layout = 0 };
    const subpass = VkSubpassDescription{
        .colorAttachmentCount = 0,
        .pColorAttachments = &dummy_color,
        .pDepthStencilAttachment = &depth_ref,
    };
    const deps = [_]VkSubpassDependency{
        .{
            .srcSubpass = SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = STAGE_FRAGMENT_SHADER,
            .dstStageMask = STAGE_EARLY_FRAGMENT_TESTS,
            .srcAccessMask = ACCESS_SHADER_READ,
            .dstAccessMask = ACCESS_DEPTH_WRITE,
        },
        .{
            .srcSubpass = 0,
            .dstSubpass = SUBPASS_EXTERNAL,
            .srcStageMask = STAGE_LATE_FRAGMENT_TESTS,
            .dstStageMask = STAGE_FRAGMENT_SHADER,
            .srcAccessMask = ACCESS_DEPTH_WRITE,
            .dstAccessMask = ACCESS_SHADER_READ,
        },
    };
    var rp: VkRenderPass = VK_NULL;
    try check(vkCreateRenderPass(device, &.{
        .attachmentCount = attachments.len,
        .pAttachments = &attachments,
        .pSubpasses = &subpass,
        .dependencyCount = deps.len,
        .pDependencies = &deps,
    }, null, &rp));
    return rp;
}

/// Pipeline della shadow pass: legge solo la posizione dal vertex buffer mesh
/// (stride 48), scrive solo depth, con depth-bias contro l'acne di ombra.
fn createShadowPipeline(device: VkDevice, render_pass: VkRenderPass, layout: VkPipelineLayout, vert: VkShaderModule, frag: VkShaderModule) !VkPipeline {
    const stages = [_]VkPipelineShaderStageCreateInfo{
        .{ .stage = SHADER_STAGE_VERTEX, .module = vert },
        .{ .stage = SHADER_STAGE_FRAGMENT, .module = frag },
    };
    const binding = VkVertexInputBindingDescription{ .binding = 0, .stride = 48 };
    const attribute = VkVertexInputAttributeDescription{ .location = 0, .binding = 0, .format = FORMAT_R32G32B32_SFLOAT, .offset = 0 };
    const vertex_input = VkPipelineVertexInputStateCreateInfo{
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = @ptrCast(&binding),
        .vertexAttributeDescriptionCount = 1,
        .pVertexAttributeDescriptions = @ptrCast(&attribute),
    };
    const input_assembly = VkPipelineInputAssemblyStateCreateInfo{};
    const viewport_state = VkPipelineViewportStateCreateInfo{};
    const rasterization = VkPipelineRasterizationStateCreateInfo{
        .depthBiasEnable = 1,
        .depthBiasConstantFactor = 1.25,
        .depthBiasSlopeFactor = 1.75,
    };
    const multisample = VkPipelineMultisampleStateCreateInfo{};
    const depth_stencil = VkPipelineDepthStencilStateCreateInfo{};
    const dummy_blend = VkPipelineColorBlendAttachmentState{};
    const color_blend = VkPipelineColorBlendStateCreateInfo{ .attachmentCount = 0, .pAttachments = &dummy_blend };
    const dynamic_states = [_]u32{ 0, 1 }; // VIEWPORT, SCISSOR
    const dynamic = VkPipelineDynamicStateCreateInfo{
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };
    const info = VkGraphicsPipelineCreateInfo{
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic,
        .layout = layout,
        .renderPass = render_pass,
    };
    var pipeline: VkPipeline = VK_NULL;
    try check(vkCreateGraphicsPipelines(device, VK_NULL, 1, @ptrCast(&info), null, @ptrCast(&pipeline)));
    return pipeline;
}

/// Pipeline del testo: vertici pos(vec2)+uv(vec2)+colore(vec3), alpha blending
/// sopra lo sfondo, depth-test disattivato. Condivide il render pass mesh.
fn createTextPipeline(device: VkDevice, render_pass: VkRenderPass, layout: VkPipelineLayout, vert: VkShaderModule, frag: VkShaderModule) !VkPipeline {
    const stages = [_]VkPipelineShaderStageCreateInfo{
        .{ .stage = SHADER_STAGE_VERTEX, .module = vert },
        .{ .stage = SHADER_STAGE_FRAGMENT, .module = frag },
    };
    const binding = VkVertexInputBindingDescription{ .binding = 0, .stride = 28 };
    const attrs = [_]VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = FORMAT_R32G32_SFLOAT, .offset = 0 },
        .{ .location = 1, .binding = 0, .format = FORMAT_R32G32_SFLOAT, .offset = 8 },
        .{ .location = 2, .binding = 0, .format = FORMAT_R32G32B32_SFLOAT, .offset = 16 },
    };
    const vertex_input = VkPipelineVertexInputStateCreateInfo{
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = @ptrCast(&binding),
        .vertexAttributeDescriptionCount = attrs.len,
        .pVertexAttributeDescriptions = &attrs,
    };
    const input_assembly = VkPipelineInputAssemblyStateCreateInfo{};
    const viewport_state = VkPipelineViewportStateCreateInfo{};
    const rasterization = VkPipelineRasterizationStateCreateInfo{};
    const multisample = VkPipelineMultisampleStateCreateInfo{};
    // Depth-test spento: il testo è 2D, ordinato dalla CPU.
    const depth_stencil = VkPipelineDepthStencilStateCreateInfo{ .depthTestEnable = 0, .depthWriteEnable = 0 };
    // Alpha blending: colore del glifo sopra lo sfondo secondo la copertura.
    // colorWriteMask solo RGB → l'alpha resta quello di clear (opaco).
    const blend_attachment = VkPipelineColorBlendAttachmentState{
        .blendEnable = 1,
        .srcColorBlendFactor = BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = 0, // ADD
        .srcAlphaBlendFactor = 0, // ZERO
        .dstAlphaBlendFactor = 1, // ONE
        .alphaBlendOp = 0,
        .colorWriteMask = COLOR_WRITE_RGB,
    };
    const color_blend = VkPipelineColorBlendStateCreateInfo{ .pAttachments = &blend_attachment };
    const dynamic_states = [_]u32{ 0, 1 }; // VIEWPORT, SCISSOR
    const dynamic = VkPipelineDynamicStateCreateInfo{
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const info = VkGraphicsPipelineCreateInfo{
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic,
        .layout = layout,
        .renderPass = render_pass,
    };
    var pipeline: VkPipeline = VK_NULL;
    try check(vkCreateGraphicsPipelines(device, VK_NULL, 1, @ptrCast(&info), null, @ptrCast(&pipeline)));
    return pipeline;
}

/// Pipeline del ray-march voxel: triangolo a schermo intero senza vertex input,
/// niente depth/blend. Riusa il render pass principale (color+depth).
fn createVoxelPipeline(device: VkDevice, render_pass: VkRenderPass, layout: VkPipelineLayout, vert: VkShaderModule, frag: VkShaderModule) !VkPipeline {
    const stages = [_]VkPipelineShaderStageCreateInfo{
        .{ .stage = SHADER_STAGE_VERTEX, .module = vert },
        .{ .stage = SHADER_STAGE_FRAGMENT, .module = frag },
    };
    // Nessun vertex input: il triangolo fullscreen è generato da gl_VertexIndex.
    const dummy_bind = VkVertexInputBindingDescription{ .binding = 0, .stride = 0 };
    const dummy_attr = VkVertexInputAttributeDescription{ .location = 0, .binding = 0, .format = 0, .offset = 0 };
    const vertex_input = VkPipelineVertexInputStateCreateInfo{
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = @ptrCast(&dummy_bind),
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = @ptrCast(&dummy_attr),
    };
    const input_assembly = VkPipelineInputAssemblyStateCreateInfo{};
    const viewport_state = VkPipelineViewportStateCreateInfo{};
    const rasterization = VkPipelineRasterizationStateCreateInfo{};
    const multisample = VkPipelineMultisampleStateCreateInfo{};
    const depth_stencil = VkPipelineDepthStencilStateCreateInfo{ .depthTestEnable = 0, .depthWriteEnable = 0 };
    const blend_attachment = VkPipelineColorBlendAttachmentState{}; // scrive RGBA (default 0xF)
    const color_blend = VkPipelineColorBlendStateCreateInfo{ .pAttachments = &blend_attachment };
    const dynamic_states = [_]u32{ 0, 1 }; // VIEWPORT, SCISSOR
    const dynamic = VkPipelineDynamicStateCreateInfo{ .dynamicStateCount = dynamic_states.len, .pDynamicStates = &dynamic_states };

    const info = VkGraphicsPipelineCreateInfo{
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic,
        .layout = layout,
        .renderPass = render_pass,
    };
    var pipeline: VkPipeline = VK_NULL;
    try check(vkCreateGraphicsPipelines(device, VK_NULL, 1, @ptrCast(&info), null, @ptrCast(&pipeline)));
    return pipeline;
}

// ---------------------------------------------------------------------------
// Matrice MVP per il fit ortografico (stessa geometria del renderer CPU:
// centratura, yaw attorno a Y, pitch attorno a X, fit al 70% del viewport).
// ---------------------------------------------------------------------------

pub fn buildPushConstants(
    center: [3]f32,
    max_size: f32,
    yaw: f32,
    pitch: f32,
    width: u32,
    height: u32,
    material: Material,
) PushConstants {
    const cos_y = @cos(yaw);
    const sin_y = @sin(yaw);
    const cos_p = @cos(pitch);
    const sin_p = @sin(pitch);

    // Rotazione combinata Rx(pitch)*Ry(yaw), identica al path CPU.
    const r0 = [3]f32{ cos_y, 0, -sin_y };
    const r1 = [3]f32{ -sin_p * sin_y, cos_p, -sin_p * cos_y };
    const r2 = [3]f32{ cos_p * sin_y, sin_p, cos_p * cos_y };

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const fit = 0.7 * @min(w, h);
    const denom = if (max_size > 0) max_size else 1.0;
    const scale = fit / denom;
    const a = scale / (w / 2.0); // x → NDC
    const b = scale / (h / 2.0); // y → NDC (Vulkan: y verso il basso, il CPU path ha y in su)
    const c = 0.5 / denom; // z → depth attorno a 0.5; più vicino = depth minore

    // Righe della MVP (row-major); traslazione = -(riga·centro) + offset.
    var rows: [4][4]f32 = .{
        .{ a * r0[0], a * r0[1], a * r0[2], 0 },
        .{ -b * r1[0], -b * r1[1], -b * r1[2], 0 },
        .{ -c * r2[0], -c * r2[1], -c * r2[2], 0.5 },
        .{ 0, 0, 0, 1 },
    };
    for (0..3) |i| {
        rows[i][3] -= rows[i][0] * center[0] + rows[i][1] * center[1] + rows[i][2] * center[2];
    }

    // GLSL vuole column-major.
    var mvp: [16]f32 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            mvp[col * 4 + row] = rows[row][col];
        }
    }

    // --- Ombre: matrice ortografica oggetto→clip della luce ----------------
    // Key light FISSA nello spazio oggetto (dall'alto-fronte): così l'ombra
    // resta ancorata al modello mentre la camera orbita. La shadow map è
    // renderizzata in spazio oggetto e il lookup usa la posizione oggetto del
    // frammento, quindi la matrice non dipende da yaw/pitch.
    const lo = normalize3(.{ 0.35, 0.9, 0.45 }); // direzione superficie→luce
    // Direzione della key light in spazio camera (per l'illuminazione).
    const light_dir_cam = [4]f32{
        r0[0] * lo[0] + r0[1] * lo[1] + r0[2] * lo[2],
        r1[0] * lo[0] + r1[1] * lo[1] + r1[2] * lo[2],
        r2[0] * lo[0] + r2[1] * lo[1] + r2[2] * lo[2],
        0,
    };

    const ft = [3]f32{ -lo[0], -lo[1], -lo[2] }; // forward: luce→modello
    const up_hint: [3]f32 = if (@abs(ft[1]) > 0.99) .{ 1, 0, 0 } else .{ 0, 1, 0 };
    const s = normalize3(cross3(ft, up_hint)); // destra
    const u = cross3(s, ft); // su effettivo
    const e = if (max_size > 0) max_size * 0.75 else 1.0; // semi-estensione xy
    const rr = if (max_size > 0) max_size else 1.0; // semi-profondità

    const lrows: [4][4]f32 = .{
        .{ s[0] / e, s[1] / e, s[2] / e, -(s[0] * center[0] + s[1] * center[1] + s[2] * center[2]) / e },
        .{ u[0] / e, u[1] / e, u[2] / e, -(u[0] * center[0] + u[1] * center[1] + u[2] * center[2]) / e },
        .{ ft[0] / (2 * rr), ft[1] / (2 * rr), ft[2] / (2 * rr), -(ft[0] * center[0] + ft[1] * center[1] + ft[2] * center[2]) / (2 * rr) + 0.5 },
        .{ 0, 0, 0, 1 },
    };
    var light_vp: [16]f32 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            light_vp[col * 4 + row] = lrows[row][col];
        }
    }

    return .{
        .mvp = mvp,
        // Base di rotazione oggetto→camera (senza scala) per le normali; nei `w`
        // viaggiano roughness e metallic del materiale.
        .nrm0 = .{ r0[0], r0[1], r0[2], material.roughness },
        .nrm1 = .{ r1[0], r1[1], r1[2], material.metallic },
        .nrm2 = .{ r2[0], r2[1], r2[2], 0 },
        .material = material.base_color,
        .light_vp = light_vp,
        .light_dir_cam = light_dir_cam,
    };
}

/// Push constant del ray-march voxel: stessa camera ortografica di
/// `buildPushConstants` (yaw/pitch/fit), ma espressa come raggio (origine +
/// right·ndc.x + up·ndc.y, marcia lungo `dir`) in spazio griglia [0,1]³.
pub fn buildVoxelPush(
    center: [3]f32,
    max_size: f32,
    yaw: f32,
    pitch: f32,
    width: u32,
    height: u32,
    bbox_min: [3]f32,
    bbox_size: [3]f32,
    dim: u32,
) VoxelPush {
    const cos_y = @cos(yaw);
    const sin_y = @sin(yaw);
    const cos_p = @cos(pitch);
    const sin_p = @sin(pitch);
    const r0 = [3]f32{ cos_y, 0, -sin_y };
    const r1 = [3]f32{ -sin_p * sin_y, cos_p, -sin_p * cos_y };
    const r2 = [3]f32{ cos_p * sin_y, sin_p, cos_p * cos_y };

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const denom = if (max_size > 0) max_size else 1.0;
    const fit = 0.7 * @min(w, h);
    const half_w = (w / 2.0) * denom / fit; // estensione ortografica oggetto per ndc.x
    const half_h = (h / 2.0) * denom / fit;

    // Assi camera in spazio oggetto: right=+r0, up=-r1 (la MVP inverte y),
    // direzione di vista (nella scena) = -r2; l'occhio sta sul lato +r2.
    const up = [3]f32{ -r1[0], -r1[1], -r1[2] };
    const fwd = [3]f32{ -r2[0], -r2[1], -r2[2] };
    const big_t = 1.5 * denom;
    const eye = [3]f32{ center[0] + r2[0] * big_t, center[1] + r2[1] * big_t, center[2] + r2[2] * big_t };

    const inv = [3]f32{
        1.0 / (if (bbox_size[0] > 1e-9) bbox_size[0] else 1e-9),
        1.0 / (if (bbox_size[1] > 1e-9) bbox_size[1] else 1e-9),
        1.0 / (if (bbox_size[2] > 1e-9) bbox_size[2] else 1e-9),
    };
    const toGridDir = struct {
        fn f(v: [3]f32, iv: [3]f32) [3]f32 {
            return .{ v[0] * iv[0], v[1] * iv[1], v[2] * iv[2] };
        }
    }.f;

    const origin_g = [3]f32{ (eye[0] - bbox_min[0]) * inv[0], (eye[1] - bbox_min[1]) * inv[1], (eye[2] - bbox_min[2]) * inv[2] };
    const right_g = toGridDir(.{ r0[0] * half_w, r0[1] * half_w, r0[2] * half_w }, inv);
    const up_g = toGridDir(.{ up[0] * half_h, up[1] * half_h, up[2] * half_h }, inv);
    const dir_g = toGridDir(fwd, inv);

    const lo = normalize3(.{ 0.35, 0.9, 0.45 }); // superficie→luce, spazio oggetto
    const light_g = normalize3(toGridDir(lo, inv));

    return .{
        .origin = .{ origin_g[0], origin_g[1], origin_g[2], 0 },
        .right = .{ right_g[0], right_g[1], right_g[2], 0 },
        .up = .{ up_g[0], up_g[1], up_g[2], 0 },
        .dir = .{ dir_g[0], dir_g[1], dir_g[2], 0 },
        .light_g = .{ light_g[0], light_g[1], light_g[2], 0 },
        .light_obj = .{ lo[0], lo[1], lo[2], @floatFromInt(dim) },
    };
}

fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-12) return .{ 0, 1, 0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

/// Fattori del materiale PBR passati al renderer (glTF metallic-roughness).
pub const Material = struct {
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    metallic: f32 = 1.0,
    roughness: f32 = 1.0,
};
