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
const decoder = @import("decoder.zig");

// ---------------------------------------------------------------------------
// Binding Vulkan minimali
// ---------------------------------------------------------------------------

pub const VkResult = i32;
pub const VK_SUCCESS: VkResult = 0;

pub const VkInstance = ?*opaque {};
pub const VkPhysicalDevice = ?*opaque {};
pub const VkDevice = ?*opaque {};
pub const VkQueue = ?*opaque {};
pub const VkCommandBuffer = ?*opaque {};

// Handle non-dispatchable: u64 su tutte le piattaforme.
pub const VkBuffer = u64;
pub const VkImage = u64;
pub const VkImageView = u64;
pub const VkDeviceMemory = u64;
pub const VkShaderModule = u64;
pub const VkPipelineLayout = u64;
pub const VkRenderPass = u64;
pub const VkFramebuffer = u64;
pub const VkPipeline = u64;
pub const VkCommandPool = u64;
pub const VkFence = u64;
pub const VK_NULL: u64 = 0;

pub const VkStructureType = u32;
const ST_APPLICATION_INFO: VkStructureType = 0;
const ST_INSTANCE_CREATE_INFO: VkStructureType = 1;
const ST_DEVICE_QUEUE_CREATE_INFO: VkStructureType = 2;
const ST_DEVICE_CREATE_INFO: VkStructureType = 3;
const ST_SUBMIT_INFO: VkStructureType = 4;
const ST_MEMORY_ALLOCATE_INFO: VkStructureType = 5;
const ST_FENCE_CREATE_INFO: VkStructureType = 8;
const ST_BUFFER_CREATE_INFO: VkStructureType = 12;
const ST_IMAGE_CREATE_INFO: VkStructureType = 14;
const ST_IMAGE_VIEW_CREATE_INFO: VkStructureType = 15;
const ST_SHADER_MODULE_CREATE_INFO: VkStructureType = 16;
const ST_PIPELINE_SHADER_STAGE_CREATE_INFO: VkStructureType = 18;
const ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: VkStructureType = 19;
const ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: VkStructureType = 20;
const ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO: VkStructureType = 22;
const ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: VkStructureType = 23;
const ST_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: VkStructureType = 24;
const ST_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO: VkStructureType = 25;
const ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: VkStructureType = 26;
const ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO: VkStructureType = 27;
const ST_GRAPHICS_PIPELINE_CREATE_INFO: VkStructureType = 28;
const ST_PIPELINE_LAYOUT_CREATE_INFO: VkStructureType = 30;
const ST_FRAMEBUFFER_CREATE_INFO: VkStructureType = 37;
const ST_RENDER_PASS_CREATE_INFO: VkStructureType = 38;
const ST_COMMAND_POOL_CREATE_INFO: VkStructureType = 39;
const ST_COMMAND_BUFFER_ALLOCATE_INFO: VkStructureType = 40;
const ST_COMMAND_BUFFER_BEGIN_INFO: VkStructureType = 42;
const ST_RENDER_PASS_BEGIN_INFO: VkStructureType = 43;
const ST_BUFFER_MEMORY_BARRIER: VkStructureType = 44;
const ST_IMAGE_MEMORY_BARRIER: VkStructureType = 45;
// VK_EXT_external_memory_host (extension #179)
const ST_IMPORT_MEMORY_HOST_POINTER_INFO_EXT: VkStructureType = 1000178000;
const ST_MEMORY_HOST_POINTER_PROPERTIES_EXT: VkStructureType = 1000178001;

pub const FORMAT_R8G8B8A8_UNORM: u32 = 37;
pub const FORMAT_R8G8B8A8_SRGB: u32 = 43;
pub const FORMAT_R32G32B32_SFLOAT: u32 = 106;
pub const FORMAT_R32G32B32A32_SFLOAT: u32 = 109;
pub const FORMAT_D32_SFLOAT: u32 = 126;

const IMAGE_LAYOUT_UNDEFINED: u32 = 0;
const IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: u32 = 2;
const IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL: u32 = 3;
const IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL: u32 = 4;
pub const IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: u32 = 6;
pub const IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: u32 = 7;

const EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT: u32 = 0x80;

pub const VkExtent2D = extern struct { width: u32, height: u32 };
pub const VkExtent3D = extern struct { width: u32, height: u32, depth: u32 };
pub const VkOffset2D = extern struct { x: i32, y: i32 };
pub const VkOffset3D = extern struct { x: i32, y: i32, z: i32 };
pub const VkRect2D = extern struct { offset: VkOffset2D, extent: VkExtent2D };

const VkApplicationInfo = extern struct {
    sType: VkStructureType = ST_APPLICATION_INFO,
    pNext: ?*const anyopaque = null,
    pApplicationName: ?[*:0]const u8 = null,
    applicationVersion: u32 = 0,
    pEngineName: ?[*:0]const u8 = null,
    engineVersion: u32 = 0,
    apiVersion: u32 = 0,
};

const VkInstanceCreateInfo = extern struct {
    sType: VkStructureType = ST_INSTANCE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pApplicationInfo: ?*const VkApplicationInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};

const VkQueueFamilyProperties = extern struct {
    queueFlags: u32,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};

const VkDeviceQueueCreateInfo = extern struct {
    sType: VkStructureType = ST_DEVICE_QUEUE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32,
    queueCount: u32 = 1,
    pQueuePriorities: [*]const f32,
};

const VkDeviceCreateInfo = extern struct {
    sType: VkStructureType = ST_DEVICE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueCreateInfoCount: u32 = 1,
    pQueueCreateInfos: *const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    pEnabledFeatures: ?*const anyopaque = null,
};

const VkMemoryType = extern struct { propertyFlags: u32, heapIndex: u32 };
const VkMemoryHeap = extern struct { size: u64, flags: u32 };
const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

const VkMemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memoryTypeBits: u32,
};

const VkBufferCreateInfo = extern struct {
    sType: VkStructureType = ST_BUFFER_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64,
    usage: u32,
    sharingMode: u32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
};

const VkMemoryAllocateInfo = extern struct {
    sType: VkStructureType = ST_MEMORY_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    allocationSize: u64,
    memoryTypeIndex: u32,
};

const VkImportMemoryHostPointerInfoEXT = extern struct {
    sType: VkStructureType = ST_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
    pNext: ?*const anyopaque = null,
    handleType: u32 = EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT,
    pHostPointer: *anyopaque,
};

const VkMemoryHostPointerPropertiesEXT = extern struct {
    sType: VkStructureType = ST_MEMORY_HOST_POINTER_PROPERTIES_EXT,
    pNext: ?*anyopaque = null,
    memoryTypeBits: u32 = 0,
};

// VK_KHR_external_memory (promossa in core 1.1, extension #73 → base 1000072000)
const VkExternalMemoryBufferCreateInfo = extern struct {
    sType: VkStructureType = 1000072000,
    pNext: ?*const anyopaque = null,
    handleTypes: u32 = EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT,
};

const VkImageCreateInfo = extern struct {
    sType: VkStructureType = ST_IMAGE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    imageType: u32 = 1, // 2D
    format: u32,
    extent: VkExtent3D,
    mipLevels: u32 = 1,
    arrayLayers: u32 = 1,
    samples: u32 = 1,
    tiling: u32 = 0, // OPTIMAL
    usage: u32,
    sharingMode: u32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
    initialLayout: u32 = IMAGE_LAYOUT_UNDEFINED,
};

const VkComponentMapping = extern struct { r: u32 = 0, g: u32 = 0, b: u32 = 0, a: u32 = 0 };
pub const VkImageSubresourceRange = extern struct {
    aspectMask: u32,
    baseMipLevel: u32 = 0,
    levelCount: u32 = 1,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 1,
};

const VkImageViewCreateInfo = extern struct {
    sType: VkStructureType = ST_IMAGE_VIEW_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    image: VkImage,
    viewType: u32 = 1, // 2D
    format: u32,
    components: VkComponentMapping = .{},
    subresourceRange: VkImageSubresourceRange,
};

const VkShaderModuleCreateInfo = extern struct {
    sType: VkStructureType = ST_SHADER_MODULE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    codeSize: usize,
    pCode: [*]const u32,
};

const VkPushConstantRange = extern struct { stageFlags: u32, offset: u32, size: u32 };

const VkPipelineLayoutCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_LAYOUT_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    setLayoutCount: u32 = 0,
    pSetLayouts: ?*const anyopaque = null,
    pushConstantRangeCount: u32 = 0,
    pPushConstantRanges: ?[*]const VkPushConstantRange = null,
};

const VkAttachmentDescription = extern struct {
    flags: u32 = 0,
    format: u32,
    samples: u32 = 1,
    loadOp: u32, // 0 load, 1 clear, 2 dont care
    storeOp: u32, // 0 store, 1 dont care
    stencilLoadOp: u32 = 2,
    stencilStoreOp: u32 = 1,
    initialLayout: u32,
    finalLayout: u32,
};

const VkAttachmentReference = extern struct { attachment: u32, layout: u32 };

const VkSubpassDescription = extern struct {
    flags: u32 = 0,
    pipelineBindPoint: u32 = 0, // GRAPHICS
    inputAttachmentCount: u32 = 0,
    pInputAttachments: ?*const anyopaque = null,
    colorAttachmentCount: u32 = 1,
    pColorAttachments: *const VkAttachmentReference,
    pResolveAttachments: ?*const anyopaque = null,
    pDepthStencilAttachment: ?*const VkAttachmentReference = null,
    preserveAttachmentCount: u32 = 0,
    pPreserveAttachments: ?*const anyopaque = null,
};

const VkSubpassDependency = extern struct {
    srcSubpass: u32,
    dstSubpass: u32,
    srcStageMask: u32,
    dstStageMask: u32,
    srcAccessMask: u32,
    dstAccessMask: u32,
    dependencyFlags: u32 = 0,
};

const VkRenderPassCreateInfo = extern struct {
    sType: VkStructureType = ST_RENDER_PASS_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    attachmentCount: u32,
    pAttachments: [*]const VkAttachmentDescription,
    subpassCount: u32 = 1,
    pSubpasses: *const VkSubpassDescription,
    dependencyCount: u32,
    pDependencies: [*]const VkSubpassDependency,
};

const VkFramebufferCreateInfo = extern struct {
    sType: VkStructureType = ST_FRAMEBUFFER_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    renderPass: VkRenderPass,
    attachmentCount: u32,
    pAttachments: [*]const VkImageView,
    width: u32,
    height: u32,
    layers: u32 = 1,
};

const VkPipelineShaderStageCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_SHADER_STAGE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: u32,
    module: VkShaderModule,
    pName: [*:0]const u8 = "main",
    pSpecializationInfo: ?*const anyopaque = null,
};

const VkVertexInputBindingDescription = extern struct { binding: u32, stride: u32, inputRate: u32 = 0 };
const VkVertexInputAttributeDescription = extern struct { location: u32, binding: u32, format: u32, offset: u32 };

const VkPipelineVertexInputStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    vertexBindingDescriptionCount: u32,
    pVertexBindingDescriptions: [*]const VkVertexInputBindingDescription,
    vertexAttributeDescriptionCount: u32,
    pVertexAttributeDescriptions: [*]const VkVertexInputAttributeDescription,
};

const VkPipelineInputAssemblyStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    topology: u32 = 3, // TRIANGLE_LIST
    primitiveRestartEnable: u32 = 0,
};

const VkPipelineViewportStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    viewportCount: u32 = 1,
    pViewports: ?*const anyopaque = null, // dinamico
    scissorCount: u32 = 1,
    pScissors: ?*const anyopaque = null, // dinamico
};

const VkPipelineRasterizationStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    depthClampEnable: u32 = 0,
    rasterizerDiscardEnable: u32 = 0,
    polygonMode: u32 = 0, // FILL
    cullMode: u32 = 0, // NONE: winding OBJ non affidabile
    frontFace: u32 = 0,
    depthBiasEnable: u32 = 0,
    depthBiasConstantFactor: f32 = 0,
    depthBiasClamp: f32 = 0,
    depthBiasSlopeFactor: f32 = 0,
    lineWidth: f32 = 1.0,
};

const VkPipelineMultisampleStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    rasterizationSamples: u32 = 1,
    sampleShadingEnable: u32 = 0,
    minSampleShading: f32 = 0,
    pSampleMask: ?*const anyopaque = null,
    alphaToCoverageEnable: u32 = 0,
    alphaToOneEnable: u32 = 0,
};

const VkStencilOpState = extern struct {
    failOp: u32 = 0,
    passOp: u32 = 0,
    depthFailOp: u32 = 0,
    compareOp: u32 = 0,
    compareMask: u32 = 0,
    writeMask: u32 = 0,
    reference: u32 = 0,
};

const VkPipelineDepthStencilStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    depthTestEnable: u32 = 1,
    depthWriteEnable: u32 = 1,
    depthCompareOp: u32 = 1, // LESS
    depthBoundsTestEnable: u32 = 0,
    stencilTestEnable: u32 = 0,
    front: VkStencilOpState = .{},
    back: VkStencilOpState = .{},
    minDepthBounds: f32 = 0,
    maxDepthBounds: f32 = 1,
};

const VkPipelineColorBlendAttachmentState = extern struct {
    blendEnable: u32 = 0,
    srcColorBlendFactor: u32 = 0,
    dstColorBlendFactor: u32 = 0,
    colorBlendOp: u32 = 0,
    srcAlphaBlendFactor: u32 = 0,
    dstAlphaBlendFactor: u32 = 0,
    alphaBlendOp: u32 = 0,
    colorWriteMask: u32 = 0xF,
};

const VkPipelineColorBlendStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    logicOpEnable: u32 = 0,
    logicOp: u32 = 0,
    attachmentCount: u32 = 1,
    pAttachments: *const VkPipelineColorBlendAttachmentState,
    blendConstants: [4]f32 = .{ 0, 0, 0, 0 },
};

const VkPipelineDynamicStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    dynamicStateCount: u32,
    pDynamicStates: [*]const u32,
};

const VkGraphicsPipelineCreateInfo = extern struct {
    sType: VkStructureType = ST_GRAPHICS_PIPELINE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stageCount: u32 = 2,
    pStages: [*]const VkPipelineShaderStageCreateInfo,
    pVertexInputState: *const VkPipelineVertexInputStateCreateInfo,
    pInputAssemblyState: *const VkPipelineInputAssemblyStateCreateInfo,
    pTessellationState: ?*const anyopaque = null,
    pViewportState: *const VkPipelineViewportStateCreateInfo,
    pRasterizationState: *const VkPipelineRasterizationStateCreateInfo,
    pMultisampleState: *const VkPipelineMultisampleStateCreateInfo,
    pDepthStencilState: *const VkPipelineDepthStencilStateCreateInfo,
    pColorBlendState: *const VkPipelineColorBlendStateCreateInfo,
    pDynamicState: *const VkPipelineDynamicStateCreateInfo,
    layout: VkPipelineLayout,
    renderPass: VkRenderPass,
    subpass: u32 = 0,
    basePipelineHandle: VkPipeline = VK_NULL,
    basePipelineIndex: i32 = -1,
};

const VkCommandPoolCreateInfo = extern struct {
    sType: VkStructureType = ST_COMMAND_POOL_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 2, // RESET_COMMAND_BUFFER
    queueFamilyIndex: u32,
};

const VkCommandBufferAllocateInfo = extern struct {
    sType: VkStructureType = ST_COMMAND_BUFFER_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    commandPool: VkCommandPool,
    level: u32 = 0, // PRIMARY
    commandBufferCount: u32 = 1,
};

const VkCommandBufferBeginInfo = extern struct {
    sType: VkStructureType = ST_COMMAND_BUFFER_BEGIN_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 1, // ONE_TIME_SUBMIT
    pInheritanceInfo: ?*const anyopaque = null,
};

pub const VkClearValue = extern union {
    color: [4]f32,
    depth_stencil: extern struct { depth: f32, stencil: u32 },
};

const VkRenderPassBeginInfo = extern struct {
    sType: VkStructureType = ST_RENDER_PASS_BEGIN_INFO,
    pNext: ?*const anyopaque = null,
    renderPass: VkRenderPass,
    framebuffer: VkFramebuffer,
    renderArea: VkRect2D,
    clearValueCount: u32,
    pClearValues: [*]const VkClearValue,
};

pub const VkViewport = extern struct { x: f32, y: f32, width: f32, height: f32, minDepth: f32 = 0, maxDepth: f32 = 1 };

pub const VkImageSubresourceLayers = extern struct {
    aspectMask: u32,
    mipLevel: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 1,
};

const VkBufferImageCopy = extern struct {
    bufferOffset: u64 = 0,
    bufferRowLength: u32 = 0,
    bufferImageHeight: u32 = 0,
    imageSubresource: VkImageSubresourceLayers,
    imageOffset: VkOffset3D = .{ .x = 0, .y = 0, .z = 0 },
    imageExtent: VkExtent3D,
};

const VkBufferMemoryBarrier = extern struct {
    sType: VkStructureType = ST_BUFFER_MEMORY_BARRIER,
    pNext: ?*const anyopaque = null,
    srcAccessMask: u32,
    dstAccessMask: u32,
    srcQueueFamilyIndex: u32 = 0xFFFFFFFF, // IGNORED
    dstQueueFamilyIndex: u32 = 0xFFFFFFFF,
    buffer: VkBuffer,
    offset: u64 = 0,
    size: u64,
};

pub const VkImageMemoryBarrier = extern struct {
    sType: VkStructureType = ST_IMAGE_MEMORY_BARRIER,
    pNext: ?*const anyopaque = null,
    srcAccessMask: u32,
    dstAccessMask: u32,
    oldLayout: u32,
    newLayout: u32,
    srcQueueFamilyIndex: u32 = 0xFFFFFFFF,
    dstQueueFamilyIndex: u32 = 0xFFFFFFFF,
    image: VkImage,
    subresourceRange: VkImageSubresourceRange,
};

const VkFenceCreateInfo = extern struct {
    sType: VkStructureType = ST_FENCE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
};

pub const VkSubmitInfo = extern struct {
    sType: VkStructureType = ST_SUBMIT_INFO,
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 0,
    pWaitSemaphores: ?[*]const u64 = null,
    pWaitDstStageMask: ?[*]const u32 = null,
    commandBufferCount: u32 = 1,
    pCommandBuffers: [*]const VkCommandBuffer,
    signalSemaphoreCount: u32 = 0,
    pSignalSemaphores: ?[*]const u64 = null,
};

// Flag usati
const BUFFER_USAGE_TRANSFER_SRC: u32 = 0x1;
const BUFFER_USAGE_TRANSFER_DST: u32 = 0x2;
const BUFFER_USAGE_INDEX: u32 = 0x40;
const BUFFER_USAGE_VERTEX: u32 = 0x80;
const MEM_DEVICE_LOCAL: u32 = 1;
const MEM_HOST_VISIBLE: u32 = 2;
const MEM_HOST_COHERENT: u32 = 4;
const IMAGE_USAGE_TRANSFER_SRC: u32 = 0x1;
const IMAGE_USAGE_TRANSFER_DST: u32 = 0x2;
const IMAGE_USAGE_COLOR_ATTACHMENT: u32 = 0x10;
const IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT: u32 = 0x20;
pub const ASPECT_COLOR: u32 = 1;
const ASPECT_DEPTH: u32 = 2;
const QUEUE_GRAPHICS: u32 = 1;
const SHADER_STAGE_VERTEX: u32 = 1;
const SHADER_STAGE_FRAGMENT: u32 = 0x10;
pub const STAGE_TOP: u32 = 0x1;
const STAGE_COLOR_ATTACHMENT_OUTPUT: u32 = 0x400;
const STAGE_EARLY_FRAGMENT_TESTS: u32 = 0x100;
const STAGE_LATE_FRAGMENT_TESTS: u32 = 0x200;
pub const STAGE_TRANSFER: u32 = 0x1000;
const STAGE_HOST: u32 = 0x4000;
const ACCESS_COLOR_WRITE: u32 = 0x100;
const ACCESS_DEPTH_WRITE: u32 = 0x400;
pub const ACCESS_TRANSFER_READ: u32 = 0x800;
pub const ACCESS_TRANSFER_WRITE: u32 = 0x1000;
const ACCESS_HOST_READ: u32 = 0x2000;
const SUBPASS_EXTERNAL: u32 = 0xFFFFFFFF;

pub extern "vulkan" fn vkCreateInstance(*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) VkResult;
pub extern "vulkan" fn vkDestroyInstance(VkInstance, ?*const anyopaque) void;
pub extern "vulkan" fn vkEnumeratePhysicalDevices(VkInstance, *u32, ?[*]VkPhysicalDevice) VkResult;
extern "vulkan" fn vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice, *u32, ?[*]VkQueueFamilyProperties) void;
extern "vulkan" fn vkGetPhysicalDeviceMemoryProperties(VkPhysicalDevice, *VkPhysicalDeviceMemoryProperties) void;
extern "vulkan" fn vkEnumerateDeviceExtensionProperties(VkPhysicalDevice, ?[*:0]const u8, *u32, ?[*]VkExtensionProperties) VkResult;
extern "vulkan" fn vkCreateDevice(VkPhysicalDevice, *const VkDeviceCreateInfo, ?*const anyopaque, *VkDevice) VkResult;
pub extern "vulkan" fn vkDestroyDevice(VkDevice, ?*const anyopaque) void;
extern "vulkan" fn vkGetDeviceQueue(VkDevice, u32, u32, *VkQueue) void;
extern "vulkan" fn vkGetDeviceProcAddr(VkDevice, [*:0]const u8) ?*const fn () callconv(.c) void;
extern "vulkan" fn vkCreateBuffer(VkDevice, *const VkBufferCreateInfo, ?*const anyopaque, *VkBuffer) VkResult;
extern "vulkan" fn vkDestroyBuffer(VkDevice, VkBuffer, ?*const anyopaque) void;
extern "vulkan" fn vkGetBufferMemoryRequirements(VkDevice, VkBuffer, *VkMemoryRequirements) void;
extern "vulkan" fn vkAllocateMemory(VkDevice, *const VkMemoryAllocateInfo, ?*const anyopaque, *VkDeviceMemory) VkResult;
extern "vulkan" fn vkFreeMemory(VkDevice, VkDeviceMemory, ?*const anyopaque) void;
extern "vulkan" fn vkBindBufferMemory(VkDevice, VkBuffer, VkDeviceMemory, u64) VkResult;
extern "vulkan" fn vkMapMemory(VkDevice, VkDeviceMemory, u64, u64, u32, **anyopaque) VkResult;
extern "vulkan" fn vkCreateImage(VkDevice, *const VkImageCreateInfo, ?*const anyopaque, *VkImage) VkResult;
extern "vulkan" fn vkDestroyImage(VkDevice, VkImage, ?*const anyopaque) void;
extern "vulkan" fn vkGetImageMemoryRequirements(VkDevice, VkImage, *VkMemoryRequirements) void;
extern "vulkan" fn vkBindImageMemory(VkDevice, VkImage, VkDeviceMemory, u64) VkResult;
extern "vulkan" fn vkCreateImageView(VkDevice, *const VkImageViewCreateInfo, ?*const anyopaque, *VkImageView) VkResult;
extern "vulkan" fn vkDestroyImageView(VkDevice, VkImageView, ?*const anyopaque) void;
extern "vulkan" fn vkCreateShaderModule(VkDevice, *const VkShaderModuleCreateInfo, ?*const anyopaque, *VkShaderModule) VkResult;
extern "vulkan" fn vkDestroyShaderModule(VkDevice, VkShaderModule, ?*const anyopaque) void;
extern "vulkan" fn vkCreatePipelineLayout(VkDevice, *const VkPipelineLayoutCreateInfo, ?*const anyopaque, *VkPipelineLayout) VkResult;
extern "vulkan" fn vkDestroyPipelineLayout(VkDevice, VkPipelineLayout, ?*const anyopaque) void;
extern "vulkan" fn vkCreateRenderPass(VkDevice, *const VkRenderPassCreateInfo, ?*const anyopaque, *VkRenderPass) VkResult;
extern "vulkan" fn vkDestroyRenderPass(VkDevice, VkRenderPass, ?*const anyopaque) void;
extern "vulkan" fn vkCreateFramebuffer(VkDevice, *const VkFramebufferCreateInfo, ?*const anyopaque, *VkFramebuffer) VkResult;
extern "vulkan" fn vkDestroyFramebuffer(VkDevice, VkFramebuffer, ?*const anyopaque) void;
extern "vulkan" fn vkCreateGraphicsPipelines(VkDevice, u64, u32, [*]const VkGraphicsPipelineCreateInfo, ?*const anyopaque, [*]VkPipeline) VkResult;
extern "vulkan" fn vkDestroyPipeline(VkDevice, VkPipeline, ?*const anyopaque) void;
extern "vulkan" fn vkCreateCommandPool(VkDevice, *const VkCommandPoolCreateInfo, ?*const anyopaque, *VkCommandPool) VkResult;
extern "vulkan" fn vkDestroyCommandPool(VkDevice, VkCommandPool, ?*const anyopaque) void;
extern "vulkan" fn vkAllocateCommandBuffers(VkDevice, *const VkCommandBufferAllocateInfo, [*]VkCommandBuffer) VkResult;
extern "vulkan" fn vkBeginCommandBuffer(VkCommandBuffer, *const VkCommandBufferBeginInfo) VkResult;
extern "vulkan" fn vkEndCommandBuffer(VkCommandBuffer) VkResult;
extern "vulkan" fn vkCmdBeginRenderPass(VkCommandBuffer, *const VkRenderPassBeginInfo, u32) void;
extern "vulkan" fn vkCmdEndRenderPass(VkCommandBuffer) void;
extern "vulkan" fn vkCmdBindPipeline(VkCommandBuffer, u32, VkPipeline) void;
extern "vulkan" fn vkCmdSetViewport(VkCommandBuffer, u32, u32, [*]const VkViewport) void;
extern "vulkan" fn vkCmdSetScissor(VkCommandBuffer, u32, u32, [*]const VkRect2D) void;
extern "vulkan" fn vkCmdBindVertexBuffers(VkCommandBuffer, u32, u32, [*]const VkBuffer, [*]const u64) void;
extern "vulkan" fn vkCmdBindIndexBuffer(VkCommandBuffer, VkBuffer, u64, u32) void;
extern "vulkan" fn vkCmdPushConstants(VkCommandBuffer, VkPipelineLayout, u32, u32, u32, *const anyopaque) void;
extern "vulkan" fn vkCmdDrawIndexed(VkCommandBuffer, u32, u32, u32, i32, u32) void;
extern "vulkan" fn vkCmdCopyImageToBuffer(VkCommandBuffer, VkImage, u32, VkBuffer, u32, [*]const VkBufferImageCopy) void;
extern "vulkan" fn vkCmdCopyBufferToImage(VkCommandBuffer, VkBuffer, VkImage, u32, u32, [*]const VkBufferImageCopy) void;
pub extern "vulkan" fn vkCmdPipelineBarrier(VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?[*]const VkBufferMemoryBarrier, u32, ?[*]const VkImageMemoryBarrier) void;
extern "vulkan" fn vkCreateFence(VkDevice, *const VkFenceCreateInfo, ?*const anyopaque, *VkFence) VkResult;
extern "vulkan" fn vkDestroyFence(VkDevice, VkFence, ?*const anyopaque) void;
extern "vulkan" fn vkResetFences(VkDevice, u32, [*]const VkFence) VkResult;
extern "vulkan" fn vkWaitForFences(VkDevice, u32, [*]const VkFence, u32, u64) VkResult;
pub extern "vulkan" fn vkQueueSubmit(VkQueue, u32, [*]const VkSubmitInfo, VkFence) VkResult;
pub extern "vulkan" fn vkDeviceWaitIdle(VkDevice) VkResult;

const PfnGetMemoryHostPointerProperties = *const fn (VkDevice, u32, *const anyopaque, *VkMemoryHostPointerPropertiesEXT) callconv(.c) VkResult;

fn check(r: VkResult) !void {
    if (r != VK_SUCCESS) return error.VulkanError;
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

const vert_spv = @embedFile("mesh_vert_spv");
const frag_spv = @embedFile("mesh_frag_spv");
const shadow_vert_spv = @embedFile("shadow_vert_spv");
const shadow_frag_spv = @embedFile("shadow_frag_spv");
const voxel_vert_spv = @embedFile("voxel_vert_spv");
const voxel_frag_spv = @embedFile("voxel_frag_spv");

/// Risoluzione della shadow map (depth della key light).
const SHADOW_SIZE: u32 = 1024;

pub const PushConstants = extern struct {
    mvp: [16]f32,
    // Righe della sola rotazione oggetto→camera: trasformano le normali senza
    // la scala non-uniforme della MVP. I `w` trasportano i fattori materiale.
    nrm0: [4]f32, // xyz = riga 0; w = roughness
    nrm1: [4]f32, // xyz = riga 1; w = metallic
    nrm2: [4]f32, // xyz = riga 2; w inutilizzato
    material: [4]f32, // rgb = baseColor factor; a = alpha
    // Ombre: proiezione oggetto→clip della luce (per il lookup nella shadow map)
    // e direzione della key light in spazio camera (illuminazione coerente con
    // le ombre). 208 byte totali (device qui: maxPushConstantsSize = 256).
    light_vp: [16]f32,
    light_dir_cam: [4]f32,
};

/// Push constant della shadow pass: solo la proiezione oggetto→clip della luce.
pub const ShadowPush = extern struct {
    light_vp: [16]f32,
};

/// Push constant del ray-march voxel (96 byte). Raggio ortografico ricostruito
/// da origine + right·ndc.x + up·ndc.y, marciato lungo `dir` in spazio griglia.
pub const VoxelPush = extern struct {
    origin: [4]f32, // origine raggio (spazio griglia [0,1])
    right: [4]f32, // × ndc.x
    up: [4]f32, // × ndc.y
    dir: [4]f32, // direzione di marcia (spazio griglia)
    light_g: [4]f32, // dir verso la luce (spazio griglia, raggio d'ombra)
    light_obj: [4]f32, // xyz = dir luce oggetto (N·L); w = dim
};

pub const InitOptions = struct {
    /// Extension di instance aggiuntive (es. surface per zuer-gui).
    instance_extensions: []const [*:0]const u8 = &.{},
    /// Extension di device aggiuntive (es. VK_KHR_swapchain).
    device_extensions: []const [*:0]const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Binding aggiuntivi per la pipeline testo (atlante glifi campionabile).
// ---------------------------------------------------------------------------

const ST_SAMPLER_CREATE_INFO: VkStructureType = 31;
const ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: VkStructureType = 32;
const ST_DESCRIPTOR_POOL_CREATE_INFO: VkStructureType = 33;
const ST_DESCRIPTOR_SET_ALLOCATE_INFO: VkStructureType = 34;
const ST_WRITE_DESCRIPTOR_SET: VkStructureType = 35;

const FORMAT_R8_UNORM: u32 = 9;
const FORMAT_R32G32_SFLOAT: u32 = 103;
const IMAGE_USAGE_SAMPLED: u32 = 0x4;
const IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: u32 = 5;
const DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: u32 = 1;
const BLEND_FACTOR_SRC_ALPHA: u32 = 6;
const BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: u32 = 7;
const ACCESS_SHADER_READ: u32 = 0x20;
const STAGE_FRAGMENT_SHADER: u32 = 0x80;
const COLOR_WRITE_RGB: u32 = 0x7;

const VkSampler = u64;
const VkDescriptorSetLayout = u64;
const VkDescriptorPool = u64;
const VkDescriptorSet = u64;

const VkSamplerCreateInfo = extern struct {
    sType: VkStructureType = ST_SAMPLER_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    magFilter: u32 = 1, // LINEAR
    minFilter: u32 = 1,
    mipmapMode: u32 = 0, // NEAREST
    addressModeU: u32 = 2, // CLAMP_TO_EDGE
    addressModeV: u32 = 2,
    addressModeW: u32 = 2,
    mipLodBias: f32 = 0,
    anisotropyEnable: u32 = 0,
    maxAnisotropy: f32 = 1,
    compareEnable: u32 = 0,
    compareOp: u32 = 0,
    minLod: f32 = 0,
    maxLod: f32 = 0,
    borderColor: u32 = 0,
    unnormalizedCoordinates: u32 = 0,
};

const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32,
    stageFlags: u32,
    pImmutableSamplers: ?*const anyopaque = null,
};

const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: VkStructureType = ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    bindingCount: u32,
    pBindings: [*]const VkDescriptorSetLayoutBinding,
};

const VkDescriptorPoolSize = extern struct { type: u32, descriptorCount: u32 };

const VkDescriptorPoolCreateInfo = extern struct {
    sType: VkStructureType = ST_DESCRIPTOR_POOL_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: [*]const VkDescriptorPoolSize,
};

const VkDescriptorSetAllocateInfo = extern struct {
    sType: VkStructureType = ST_DESCRIPTOR_SET_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32 = 1,
    pSetLayouts: [*]const VkDescriptorSetLayout,
};

const VkDescriptorImageInfo = extern struct {
    sampler: VkSampler,
    imageView: VkImageView,
    imageLayout: u32,
};

const VkWriteDescriptorSet = extern struct {
    sType: VkStructureType = ST_WRITE_DESCRIPTOR_SET,
    pNext: ?*const anyopaque = null,
    dstSet: VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32 = 0,
    descriptorCount: u32 = 1,
    descriptorType: u32,
    pImageInfo: ?*const VkDescriptorImageInfo = null,
    pBufferInfo: ?*const anyopaque = null,
    pTexelBufferView: ?*const anyopaque = null,
};

extern "vulkan" fn vkCreateSampler(VkDevice, *const VkSamplerCreateInfo, ?*const anyopaque, *VkSampler) VkResult;
extern "vulkan" fn vkDestroySampler(VkDevice, VkSampler, ?*const anyopaque) void;
extern "vulkan" fn vkCreateDescriptorSetLayout(VkDevice, *const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, *VkDescriptorSetLayout) VkResult;
extern "vulkan" fn vkDestroyDescriptorSetLayout(VkDevice, VkDescriptorSetLayout, ?*const anyopaque) void;
extern "vulkan" fn vkCreateDescriptorPool(VkDevice, *const VkDescriptorPoolCreateInfo, ?*const anyopaque, *VkDescriptorPool) VkResult;
extern "vulkan" fn vkDestroyDescriptorPool(VkDevice, VkDescriptorPool, ?*const anyopaque) void;
extern "vulkan" fn vkAllocateDescriptorSets(VkDevice, *const VkDescriptorSetAllocateInfo, *VkDescriptorSet) VkResult;
extern "vulkan" fn vkUpdateDescriptorSets(VkDevice, u32, [*]const VkWriteDescriptorSet, u32, ?*const anyopaque) void;
extern "vulkan" fn vkCmdBindDescriptorSets(VkCommandBuffer, u32, VkPipelineLayout, u32, u32, [*]const VkDescriptorSet, u32, ?*const u32) void;
extern "vulkan" fn vkCmdDraw(VkCommandBuffer, u32, u32, u32, u32) void;

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

    // Rendering voxel (ray-march di una texture 3D), inizializzato pigramente.
    voxel_ready: bool = false, // pipeline/risorse statiche create
    voxel_sampler: VkSampler = VK_NULL,
    voxel_dsl: VkDescriptorSetLayout = VK_NULL,
    voxel_dpool: VkDescriptorPool = VK_NULL,
    voxel_dset: VkDescriptorSet = VK_NULL,
    voxel_pipeline_layout: VkPipelineLayout = VK_NULL,
    voxel_pipeline: VkPipeline = VK_NULL,
    voxel_vert_module: VkShaderModule = VK_NULL,
    voxel_frag_module: VkShaderModule = VK_NULL,
    voxel_tex: ImageBundle = .{ .image = VK_NULL, .mem = VK_NULL, .view = VK_NULL },
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

        var physical: VkPhysicalDevice = null;
        var queue_family: u32 = 0;
        var has_host_import = false;
        for (devices[0..dev_count]) |pd| {
            var qf_count: u32 = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, null);
            var qfs: [16]VkQueueFamilyProperties = undefined;
            qf_count = @min(qf_count, 16);
            vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, &qfs);
            const family = for (qfs[0..qf_count], 0..) |qf, i| {
                if (qf.queueFlags & QUEUE_GRAPHICS != 0) break @as(u32, @intCast(i));
            } else continue;

            physical = pd;
            queue_family = family;
            has_host_import = deviceHasExtension(gpa, pd, "VK_EXT_external_memory_host");
            break;
        }
        if (physical == null) return error.NoGpu;

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
            vkDestroySampler(self.device, self.voxel_sampler, null);
        }
        if (self.voxel_tex.image != VK_NULL) self.destroyImage(self.voxel_tex);
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

    /// Carica la griglia voxel `dim`³ (RGBA8, `data` = dim³×4) come texture 3D
    /// sRGB campionabile e la aggancia al descriptor set voxel.
    pub fn setVoxels(self: *Renderer, dim: u32, data: []const u8) !void {
        if (dim == 0) return error.BadVoxelGrid;
        const cells: u64 = @as(u64, dim) * dim * dim;
        const size: u64 = cells * 4;
        if (data.len < size) return error.BadVoxelGrid;

        try self.ensureVoxelPipeline();

        _ = vkDeviceWaitIdle(self.device);
        if (self.voxel_tex.image != VK_NULL) {
            self.destroyImage(self.voxel_tex);
            self.voxel_tex = .{ .image = VK_NULL, .mem = VK_NULL, .view = VK_NULL };
            self.voxel_dim = 0;
        }

        // UNORM (non SRGB): le texture 3D sRGB non sono garantite dall'hardware;
        // lo shader linearizza l'albedo campionato (pow 2.2).
        const tex = try self.createImage3D(dim, FORMAT_R8G8B8A8_UNORM, IMAGE_USAGE_SAMPLED | IMAGE_USAGE_TRANSFER_DST);
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
        @memcpy(dst[0..@intCast(size)], data[0..@intCast(size)]);

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
            .imageExtent = .{ .width = dim, .height = dim, .depth = dim },
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

        const img_info = VkDescriptorImageInfo{
            .sampler = self.voxel_sampler,
            .imageView = tex.view,
            .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write = [_]VkWriteDescriptorSet{.{
            .dstSet = self.voxel_dset,
            .dstBinding = 0,
            .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &img_info,
        }};
        vkUpdateDescriptorSets(self.device, 1, &write, 0, null);

        self.voxel_tex = tex;
        self.voxel_dim = dim;
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

        try check(vkBeginCommandBuffer(self.cmd, &.{}));
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
        vkCmdBindPipeline(self.cmd, 0, self.voxel_pipeline);
        vkCmdSetViewport(self.cmd, 0, 1, &[_]VkViewport{.{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height) }});
        vkCmdSetScissor(self.cmd, 0, 1, &[_]VkRect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } }});
        vkCmdPushConstants(self.cmd, self.voxel_pipeline_layout, SHADER_STAGE_FRAGMENT, 0, @sizeOf(VoxelPush), pc);
        vkCmdBindDescriptorSets(self.cmd, 0, self.voxel_pipeline_layout, 0, 1, &[_]VkDescriptorSet{self.voxel_dset}, 0, null);
        vkCmdDraw(self.cmd, 3, 1, 0, 0);
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
        try check(vkWaitForFences(self.device, 1, @ptrCast(&self.fence), 1, 2 * std.time.ns_per_s));
        try check(vkResetFences(self.device, 1, @ptrCast(&self.fence)));
    }

    /// Crea (una sola volta) sampler 3D, descriptor set, layout e pipeline del
    /// ray-march voxel. Riusa il render pass principale (fullscreen, no depth).
    fn ensureVoxelPipeline(self: *Renderer) !void {
        if (self.voxel_ready) return;

        try check(vkCreateSampler(self.device, &.{}, null, &self.voxel_sampler)); // NEAREST → voxel netti

        const binding = VkDescriptorSetLayoutBinding{ .binding = 0, .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = SHADER_STAGE_FRAGMENT };
        try check(vkCreateDescriptorSetLayout(self.device, &.{ .bindingCount = 1, .pBindings = @ptrCast(&binding) }, null, &self.voxel_dsl));

        const pool_size = VkDescriptorPoolSize{ .type = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 };
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

    fn createImage3D(self: *Renderer, dim: u32, format: u32, usage: u32) !ImageBundle {
        var image: VkImage = VK_NULL;
        try check(vkCreateImage(self.device, &.{
            .imageType = 2, // 3D
            .format = format,
            .extent = .{ .width = dim, .height = dim, .depth = dim },
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

        var view: VkImageView = VK_NULL;
        try check(vkCreateImageView(self.device, &.{
            .image = image,
            .viewType = 2, // 3D
            .format = format,
            .subresourceRange = .{ .aspectMask = ASPECT_COLOR },
        }, null, &view));

        return .{ .image = image, .mem = mem, .view = view };
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
