const std = @import("std");

// ---------------------------------------------------------------------------
// Binding Vulkan minimali (esportati per uso modulare)
// ---------------------------------------------------------------------------

pub const VkResult = i32;
pub const VK_SUCCESS: VkResult = 0;
pub const VK_ERROR_INITIALIZATION_FAILED: VkResult = -3;
pub const VK_ERROR_INCOMPATIBLE_DRIVER: VkResult = -9;
/// VK_KHR_portability_enumeration: senza, il loader nasconde i driver "portability"
/// (MoltenVK su macOS) e l'istanza non vede GPU.
pub const INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR: u32 = 0x1;

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
pub const ST_APPLICATION_INFO: VkStructureType = 0;
pub const ST_INSTANCE_CREATE_INFO: VkStructureType = 1;
pub const ST_DEVICE_QUEUE_CREATE_INFO: VkStructureType = 2;
pub const ST_DEVICE_CREATE_INFO: VkStructureType = 3;
pub const ST_SUBMIT_INFO: VkStructureType = 4;
pub const ST_MEMORY_ALLOCATE_INFO: VkStructureType = 5;
pub const ST_FENCE_CREATE_INFO: VkStructureType = 8;
pub const ST_BUFFER_CREATE_INFO: VkStructureType = 12;
pub const ST_IMAGE_CREATE_INFO: VkStructureType = 14;
pub const ST_IMAGE_VIEW_CREATE_INFO: VkStructureType = 15;
pub const ST_SHADER_MODULE_CREATE_INFO: VkStructureType = 16;
pub const ST_PIPELINE_SHADER_STAGE_CREATE_INFO: VkStructureType = 18;
pub const ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: VkStructureType = 19;
pub const ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: VkStructureType = 20;
pub const ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO: VkStructureType = 22;
pub const ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: VkStructureType = 23;
pub const ST_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: VkStructureType = 24;
pub const ST_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO: VkStructureType = 25;
pub const ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: VkStructureType = 26;
pub const ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO: VkStructureType = 27;
pub const ST_GRAPHICS_PIPELINE_CREATE_INFO: VkStructureType = 28;
pub const ST_PIPELINE_LAYOUT_CREATE_INFO: VkStructureType = 30;
pub const ST_FRAMEBUFFER_CREATE_INFO: VkStructureType = 37;
pub const ST_RENDER_PASS_CREATE_INFO: VkStructureType = 38;
pub const ST_COMMAND_POOL_CREATE_INFO: VkStructureType = 39;
pub const ST_COMMAND_BUFFER_ALLOCATE_INFO: VkStructureType = 40;
pub const ST_COMMAND_BUFFER_BEGIN_INFO: VkStructureType = 42;
pub const ST_RENDER_PASS_BEGIN_INFO: VkStructureType = 43;
pub const ST_BUFFER_MEMORY_BARRIER: VkStructureType = 44;
pub const ST_IMAGE_MEMORY_BARRIER: VkStructureType = 45;
// VK_EXT_external_memory_host (extension #179)
pub const ST_IMPORT_MEMORY_HOST_POINTER_INFO_EXT: VkStructureType = 1000178000;
pub const ST_MEMORY_HOST_POINTER_PROPERTIES_EXT: VkStructureType = 1000178001;

pub const FORMAT_R8G8B8A8_UNORM: u32 = 37;
pub const FORMAT_R8G8B8A8_SRGB: u32 = 43;
pub const FORMAT_R32G32B32_SFLOAT: u32 = 106;
pub const FORMAT_R32G32B32A32_SFLOAT: u32 = 109;
pub const FORMAT_D32_SFLOAT: u32 = 126;

pub const IMAGE_LAYOUT_UNDEFINED: u32 = 0;
pub const IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: u32 = 2;
pub const IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL: u32 = 3;
pub const IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL: u32 = 4;
pub const IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: u32 = 6;
pub const IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: u32 = 7;

pub const EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT: u32 = 0x80;

pub const VkExtent2D = extern struct { width: u32, height: u32 };
pub const VkExtent3D = extern struct { width: u32, height: u32, depth: u32 };
pub const VkOffset2D = extern struct { x: i32, y: i32 };
pub const VkOffset3D = extern struct { x: i32, y: i32, z: i32 };
pub const VkRect2D = extern struct { offset: VkOffset2D, extent: VkExtent2D };

pub const VkApplicationInfo = extern struct {
    sType: VkStructureType = ST_APPLICATION_INFO,
    pNext: ?*const anyopaque = null,
    pApplicationName: ?[*:0]const u8 = null,
    applicationVersion: u32 = 0,
    pEngineName: ?[*:0]const u8 = null,
    engineVersion: u32 = 0,
    apiVersion: u32 = 0,
};

pub const VkInstanceCreateInfo = extern struct {
    sType: VkStructureType = ST_INSTANCE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pApplicationInfo: ?*const VkApplicationInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};

pub const VkQueueFamilyProperties = extern struct {
    queueFlags: u32,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

pub const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};

pub const VkDeviceQueueCreateInfo = extern struct {
    sType: VkStructureType = ST_DEVICE_QUEUE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32,
    queueCount: u32 = 1,
    pQueuePriorities: [*]const f32,
};

pub const VkDeviceCreateInfo = extern struct {
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

// Device identity, enough to choose between GPUs (integrated vs discrete) and log the name.
// The driver writes the *whole* VkPhysicalDeviceProperties (apiVersion..sparseProperties),
// so we keep the fields we read at their true offsets and reserve ample tail space for the
// limits/sparse blocks we ignore (real tail ~524B; 1024 is safe headroom).
pub const VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: u32 = 1;
pub const VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: u32 = 2;
pub const VkPhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: u32,
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    tail: [1024]u8, // limits + sparseProperties (unused here)
};

pub const VkMemoryType = extern struct { propertyFlags: u32, heapIndex: u32 };
pub const VkMemoryHeap = extern struct { size: u64, flags: u32 };
pub const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

pub const VkMemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memoryTypeBits: u32,
};

pub const VkBufferCreateInfo = extern struct {
    sType: VkStructureType = ST_BUFFER_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64,
    usage: u32,
    sharingMode: u32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: VkStructureType = ST_MEMORY_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    allocationSize: u64,
    memoryTypeIndex: u32,
};

pub const VkImportMemoryHostPointerInfoEXT = extern struct {
    sType: VkStructureType = ST_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
    pNext: ?*const anyopaque = null,
    handleType: u32 = EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT,
    pHostPointer: *anyopaque,
};

pub const VkMemoryHostPointerPropertiesEXT = extern struct {
    sType: VkStructureType = ST_MEMORY_HOST_POINTER_PROPERTIES_EXT,
    pNext: ?*anyopaque = null,
    memoryTypeBits: u32 = 0,
};

// VK_KHR_external_memory (promossa in core 1.1, extension #73 → base 1000072000)
pub const VkExternalMemoryBufferCreateInfo = extern struct {
    sType: VkStructureType = 1000072000,
    pNext: ?*const anyopaque = null,
    handleTypes: u32 = EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT,
};

pub const VkImageCreateInfo = extern struct {
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

pub const VkComponentMapping = extern struct { r: u32 = 0, g: u32 = 0, b: u32 = 0, a: u32 = 0 };
pub const VkImageSubresourceRange = extern struct {
    aspectMask: u32,
    baseMipLevel: u32 = 0,
    levelCount: u32 = 1,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 1,
};

pub const VkImageViewCreateInfo = extern struct {
    sType: VkStructureType = ST_IMAGE_VIEW_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    image: VkImage,
    viewType: u32 = 1, // 2D
    format: u32,
    components: VkComponentMapping = .{},
    subresourceRange: VkImageSubresourceRange,
};

pub const VkShaderModuleCreateInfo = extern struct {
    sType: VkStructureType = ST_SHADER_MODULE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    codeSize: usize,
    pCode: [*]const u32,
};

pub const VkPushConstantRange = extern struct { stageFlags: u32, offset: u32, size: u32 };

pub const VkPipelineLayoutCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_LAYOUT_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    setLayoutCount: u32 = 0,
    pSetLayouts: ?*const anyopaque = null,
    pushConstantRangeCount: u32 = 0,
    pPushConstantRanges: ?[*]const VkPushConstantRange = null,
};

pub const VkAttachmentDescription = extern struct {
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

pub const VkAttachmentReference = extern struct { attachment: u32, layout: u32 };

pub const VkSubpassDescription = extern struct {
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

pub const VkSubpassDependency = extern struct {
    srcSubpass: u32,
    dstSubpass: u32,
    srcStageMask: u32,
    dstStageMask: u32,
    srcAccessMask: u32,
    dstAccessMask: u32,
    dependencyFlags: u32 = 0,
};

pub const VkRenderPassCreateInfo = extern struct {
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

pub const VkFramebufferCreateInfo = extern struct {
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

pub const VkPipelineShaderStageCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_SHADER_STAGE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: u32,
    module: VkShaderModule,
    pName: [*:0]const u8 = "main",
    pSpecializationInfo: ?*const anyopaque = null,
};

pub const VkVertexInputBindingDescription = extern struct { binding: u32, stride: u32, inputRate: u32 = 0 };
pub const VkVertexInputAttributeDescription = extern struct { location: u32, binding: u32, format: u32, offset: u32 };

pub const VkPipelineVertexInputStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    vertexBindingDescriptionCount: u32,
    pVertexBindingDescriptions: [*]const VkVertexInputBindingDescription,
    vertexAttributeDescriptionCount: u32,
    pVertexAttributeDescriptions: [*]const VkVertexInputAttributeDescription,
};

pub const VkPipelineInputAssemblyStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    topology: u32 = 3, // TRIANGLE_LIST
    primitiveRestartEnable: u32 = 0,
};

pub const VkPipelineViewportStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    viewportCount: u32 = 1,
    pViewports: ?*const anyopaque = null, // dinamico
    scissorCount: u32 = 1,
    pScissors: ?*const anyopaque = null, // dinamico
};

pub const VkPipelineRasterizationStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    depthClampEnable: u32 = 0,
    rasterizerDiscardEnable: u32 = 0,
    polygonMode: u32 = 0, // FILL
    cullMode: u32 = 0, // NONE
    frontFace: u32 = 0,
    depthBiasEnable: u32 = 0,
    depthBiasConstantFactor: f32 = 0,
    depthBiasClamp: f32 = 0,
    depthBiasSlopeFactor: f32 = 0,
    lineWidth: f32 = 1.0,
};

pub const VkPipelineMultisampleStateCreateInfo = extern struct {
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

pub const VkStencilOpState = extern struct {
    failOp: u32 = 0,
    passOp: u32 = 0,
    depthFailOp: u32 = 0,
    compareOp: u32 = 0,
    compareMask: u32 = 0,
    writeMask: u32 = 0,
    reference: u32 = 0,
};

pub const VkPipelineDepthStencilStateCreateInfo = extern struct {
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

pub const VkPipelineColorBlendAttachmentState = extern struct {
    blendEnable: u32 = 0,
    srcColorBlendFactor: u32 = 0,
    dstColorBlendFactor: u32 = 0,
    colorBlendOp: u32 = 0,
    srcAlphaBlendFactor: u32 = 0,
    dstAlphaBlendFactor: u32 = 0,
    alphaBlendOp: u32 = 0,
    colorWriteMask: u32 = 0xF,
};

pub const VkPipelineColorBlendStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    logicOpEnable: u32 = 0,
    logicOp: u32 = 0,
    attachmentCount: u32 = 1,
    pAttachments: *const VkPipelineColorBlendAttachmentState,
    blendConstants: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const VkPipelineDynamicStateCreateInfo = extern struct {
    sType: VkStructureType = ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    dynamicStateCount: u32,
    pDynamicStates: [*]const u32,
};

pub const VkGraphicsPipelineCreateInfo = extern struct {
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

pub const VkCommandPoolCreateInfo = extern struct {
    sType: VkStructureType = ST_COMMAND_POOL_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 2, // RESET_COMMAND_BUFFER
    queueFamilyIndex: u32,
};

pub const VkCommandBufferAllocateInfo = extern struct {
    sType: VkStructureType = ST_COMMAND_BUFFER_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    commandPool: VkCommandPool,
    level: u32 = 0, // PRIMARY
    commandBufferCount: u32 = 1,
};

pub const VkCommandBufferBeginInfo = extern struct {
    sType: VkStructureType = ST_COMMAND_BUFFER_BEGIN_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 1, // ONE_TIME_SUBMIT
    pInheritanceInfo: ?*const anyopaque = null,
};

pub const VkClearValue = extern union {
    color: [4]f32,
    depth_stencil: extern struct { depth: f32, stencil: u32 },
};

pub const VkRenderPassBeginInfo = extern struct {
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

pub const VkBufferImageCopy = extern struct {
    bufferOffset: u64 = 0,
    bufferRowLength: u32 = 0,
    bufferImageHeight: u32 = 0,
    imageSubresource: VkImageSubresourceLayers,
    imageOffset: VkOffset3D = .{ .x = 0, .y = 0, .z = 0 },
    imageExtent: VkExtent3D,
};

pub const VkBufferMemoryBarrier = extern struct {
    sType: VkStructureType = ST_BUFFER_MEMORY_BARRIER,
    pNext: ?*const anyopaque = null,
    srcAccessMask: u32,
    dstAccessMask: u32,
    srcQueueFamilyIndex: u32 = 0xFFFFFFFF,
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

pub const VkFenceCreateInfo = extern struct {
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
pub const BUFFER_USAGE_TRANSFER_SRC: u32 = 0x1;
pub const BUFFER_USAGE_TRANSFER_DST: u32 = 0x2;
pub const BUFFER_USAGE_STORAGE: u32 = 0x20;
pub const BUFFER_USAGE_INDEX: u32 = 0x40;
pub const BUFFER_USAGE_VERTEX: u32 = 0x80;
pub const MEM_DEVICE_LOCAL: u32 = 1;
pub const MEM_HOST_VISIBLE: u32 = 2;
pub const MEM_HOST_COHERENT: u32 = 4;
pub const IMAGE_USAGE_TRANSFER_SRC: u32 = 0x1;
pub const IMAGE_USAGE_TRANSFER_DST: u32 = 0x2;
pub const IMAGE_USAGE_COLOR_ATTACHMENT: u32 = 0x10;
pub const IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT: u32 = 0x20;
pub const ASPECT_COLOR: u32 = 1;
pub const ASPECT_DEPTH: u32 = 2;
pub const QUEUE_GRAPHICS: u32 = 1;
pub const SHADER_STAGE_VERTEX: u32 = 1;
pub const SHADER_STAGE_FRAGMENT: u32 = 0x10;
pub const STAGE_TOP: u32 = 0x1;
pub const STAGE_COLOR_ATTACHMENT_OUTPUT: u32 = 0x400;
pub const STAGE_EARLY_FRAGMENT_TESTS: u32 = 0x100;
pub const STAGE_LATE_FRAGMENT_TESTS: u32 = 0x200;
pub const STAGE_TRANSFER: u32 = 0x1000;
pub const STAGE_HOST: u32 = 0x4000;
pub const ACCESS_COLOR_WRITE: u32 = 0x100;
pub const ACCESS_DEPTH_WRITE: u32 = 0x400;
pub const ACCESS_TRANSFER_READ: u32 = 0x800;
pub const ACCESS_TRANSFER_WRITE: u32 = 0x1000;
pub const ACCESS_HOST_READ: u32 = 0x2000;
pub const SUBPASS_EXTERNAL: u32 = 0xFFFFFFFF;

pub inline fn vkCreateInstance(a0: *const VkInstanceCreateInfo, a1: ?*const anyopaque, a2: *VkInstance) VkResult {
    return dispatch.vkCreateInstance(a0, a1, a2);
}
pub inline fn vkEnumerateInstanceExtensionProperties(a0: ?[*:0]const u8, a1: *u32, a2: ?[*]VkExtensionProperties) VkResult {
    return dispatch.vkEnumerateInstanceExtensionProperties(a0, a1, a2);
}
pub inline fn vkDestroyInstance(a0: VkInstance, a1: ?*const anyopaque) void {
    return dispatch.vkDestroyInstance(a0, a1);
}
pub inline fn vkEnumeratePhysicalDevices(a0: VkInstance, a1: *u32, a2: ?[*]VkPhysicalDevice) VkResult {
    return dispatch.vkEnumeratePhysicalDevices(a0, a1, a2);
}
pub inline fn vkGetPhysicalDeviceQueueFamilyProperties(a0: VkPhysicalDevice, a1: *u32, a2: ?[*]VkQueueFamilyProperties) void {
    return dispatch.vkGetPhysicalDeviceQueueFamilyProperties(a0, a1, a2);
}
pub inline fn vkGetPhysicalDeviceMemoryProperties(a0: VkPhysicalDevice, a1: *VkPhysicalDeviceMemoryProperties) void {
    return dispatch.vkGetPhysicalDeviceMemoryProperties(a0, a1);
}
pub inline fn vkGetPhysicalDeviceProperties(a0: VkPhysicalDevice, a1: *VkPhysicalDeviceProperties) void {
    return dispatch.vkGetPhysicalDeviceProperties(a0, a1);
}
pub inline fn vkEnumerateDeviceExtensionProperties(a0: VkPhysicalDevice, a1: ?[*:0]const u8, a2: *u32, a3: ?[*]VkExtensionProperties) VkResult {
    return dispatch.vkEnumerateDeviceExtensionProperties(a0, a1, a2, a3);
}
pub inline fn vkCreateDevice(a0: VkPhysicalDevice, a1: *const VkDeviceCreateInfo, a2: ?*const anyopaque, a3: *VkDevice) VkResult {
    return dispatch.vkCreateDevice(a0, a1, a2, a3);
}
pub inline fn vkDestroyDevice(a0: VkDevice, a1: ?*const anyopaque) void {
    return dispatch.vkDestroyDevice(a0, a1);
}
pub inline fn vkGetDeviceQueue(a0: VkDevice, a1: u32, a2: u32, a3: *VkQueue) void {
    return dispatch.vkGetDeviceQueue(a0, a1, a2, a3);
}
pub inline fn vkGetDeviceProcAddr(a0: VkDevice, a1: [*:0]const u8) ?PfnVoidFunction {
    return dispatch.vkGetDeviceProcAddr(a0, a1);
}
pub inline fn vkCreateBuffer(a0: VkDevice, a1: *const VkBufferCreateInfo, a2: ?*const anyopaque, a3: *VkBuffer) VkResult {
    return dispatch.vkCreateBuffer(a0, a1, a2, a3);
}
pub inline fn vkDestroyBuffer(a0: VkDevice, a1: VkBuffer, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyBuffer(a0, a1, a2);
}
pub inline fn vkGetBufferMemoryRequirements(a0: VkDevice, a1: VkBuffer, a2: *VkMemoryRequirements) void {
    return dispatch.vkGetBufferMemoryRequirements(a0, a1, a2);
}
pub inline fn vkAllocateMemory(a0: VkDevice, a1: *const VkMemoryAllocateInfo, a2: ?*const anyopaque, a3: *VkDeviceMemory) VkResult {
    return dispatch.vkAllocateMemory(a0, a1, a2, a3);
}
pub inline fn vkFreeMemory(a0: VkDevice, a1: VkDeviceMemory, a2: ?*const anyopaque) void {
    return dispatch.vkFreeMemory(a0, a1, a2);
}
pub inline fn vkBindBufferMemory(a0: VkDevice, a1: VkBuffer, a2: VkDeviceMemory, a3: u64) VkResult {
    return dispatch.vkBindBufferMemory(a0, a1, a2, a3);
}
pub inline fn vkMapMemory(a0: VkDevice, a1: VkDeviceMemory, a2: u64, a3: u64, a4: u32, a5: **anyopaque) VkResult {
    return dispatch.vkMapMemory(a0, a1, a2, a3, a4, a5);
}
pub inline fn vkCreateImage(a0: VkDevice, a1: *const VkImageCreateInfo, a2: ?*const anyopaque, a3: *VkImage) VkResult {
    return dispatch.vkCreateImage(a0, a1, a2, a3);
}
pub inline fn vkDestroyImage(a0: VkDevice, a1: VkImage, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyImage(a0, a1, a2);
}
pub inline fn vkGetImageMemoryRequirements(a0: VkDevice, a1: VkImage, a2: *VkMemoryRequirements) void {
    return dispatch.vkGetImageMemoryRequirements(a0, a1, a2);
}
pub inline fn vkBindImageMemory(a0: VkDevice, a1: VkImage, a2: VkDeviceMemory, a3: u64) VkResult {
    return dispatch.vkBindImageMemory(a0, a1, a2, a3);
}
pub inline fn vkCreateImageView(a0: VkDevice, a1: *const VkImageViewCreateInfo, a2: ?*const anyopaque, a3: *VkImageView) VkResult {
    return dispatch.vkCreateImageView(a0, a1, a2, a3);
}
pub inline fn vkDestroyImageView(a0: VkDevice, a1: VkImageView, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyImageView(a0, a1, a2);
}
pub inline fn vkCreateShaderModule(a0: VkDevice, a1: *const VkShaderModuleCreateInfo, a2: ?*const anyopaque, a3: *VkShaderModule) VkResult {
    return dispatch.vkCreateShaderModule(a0, a1, a2, a3);
}
pub inline fn vkDestroyShaderModule(a0: VkDevice, a1: VkShaderModule, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyShaderModule(a0, a1, a2);
}
pub inline fn vkCreatePipelineLayout(a0: VkDevice, a1: *const VkPipelineLayoutCreateInfo, a2: ?*const anyopaque, a3: *VkPipelineLayout) VkResult {
    return dispatch.vkCreatePipelineLayout(a0, a1, a2, a3);
}
pub inline fn vkDestroyPipelineLayout(a0: VkDevice, a1: VkPipelineLayout, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyPipelineLayout(a0, a1, a2);
}
pub inline fn vkCreateRenderPass(a0: VkDevice, a1: *const VkRenderPassCreateInfo, a2: ?*const anyopaque, a3: *VkRenderPass) VkResult {
    return dispatch.vkCreateRenderPass(a0, a1, a2, a3);
}
pub inline fn vkDestroyRenderPass(a0: VkDevice, a1: VkRenderPass, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyRenderPass(a0, a1, a2);
}
pub inline fn vkCreateFramebuffer(a0: VkDevice, a1: *const VkFramebufferCreateInfo, a2: ?*const anyopaque, a3: *VkFramebuffer) VkResult {
    return dispatch.vkCreateFramebuffer(a0, a1, a2, a3);
}
pub inline fn vkDestroyFramebuffer(a0: VkDevice, a1: VkFramebuffer, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyFramebuffer(a0, a1, a2);
}
pub inline fn vkCreateGraphicsPipelines(a0: VkDevice, a1: u64, a2: u32, a3: [*]const VkGraphicsPipelineCreateInfo, a4: ?*const anyopaque, a5: [*]VkPipeline) VkResult {
    return dispatch.vkCreateGraphicsPipelines(a0, a1, a2, a3, a4, a5);
}
pub inline fn vkDestroyPipeline(a0: VkDevice, a1: VkPipeline, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyPipeline(a0, a1, a2);
}
pub inline fn vkCreateCommandPool(a0: VkDevice, a1: *const VkCommandPoolCreateInfo, a2: ?*const anyopaque, a3: *VkCommandPool) VkResult {
    return dispatch.vkCreateCommandPool(a0, a1, a2, a3);
}
pub inline fn vkDestroyCommandPool(a0: VkDevice, a1: VkCommandPool, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyCommandPool(a0, a1, a2);
}
pub inline fn vkAllocateCommandBuffers(a0: VkDevice, a1: *const VkCommandBufferAllocateInfo, a2: [*]VkCommandBuffer) VkResult {
    return dispatch.vkAllocateCommandBuffers(a0, a1, a2);
}
pub inline fn vkBeginCommandBuffer(a0: VkCommandBuffer, a1: *const VkCommandBufferBeginInfo) VkResult {
    return dispatch.vkBeginCommandBuffer(a0, a1);
}
pub inline fn vkEndCommandBuffer(a0: VkCommandBuffer) VkResult {
    return dispatch.vkEndCommandBuffer(a0);
}
pub inline fn vkCmdBeginRenderPass(a0: VkCommandBuffer, a1: *const VkRenderPassBeginInfo, a2: u32) void {
    return dispatch.vkCmdBeginRenderPass(a0, a1, a2);
}
pub inline fn vkCmdEndRenderPass(a0: VkCommandBuffer) void {
    return dispatch.vkCmdEndRenderPass(a0);
}
pub inline fn vkCmdBindPipeline(a0: VkCommandBuffer, a1: u32, a2: VkPipeline) void {
    return dispatch.vkCmdBindPipeline(a0, a1, a2);
}
pub inline fn vkCmdSetViewport(a0: VkCommandBuffer, a1: u32, a2: u32, a3: [*]const VkViewport) void {
    return dispatch.vkCmdSetViewport(a0, a1, a2, a3);
}
pub inline fn vkCmdSetScissor(a0: VkCommandBuffer, a1: u32, a2: u32, a3: [*]const VkRect2D) void {
    return dispatch.vkCmdSetScissor(a0, a1, a2, a3);
}
pub inline fn vkCmdBindVertexBuffers(a0: VkCommandBuffer, a1: u32, a2: u32, a3: [*]const VkBuffer, a4: [*]const u64) void {
    return dispatch.vkCmdBindVertexBuffers(a0, a1, a2, a3, a4);
}
pub inline fn vkCmdBindIndexBuffer(a0: VkCommandBuffer, a1: VkBuffer, a2: u64, a3: u32) void {
    return dispatch.vkCmdBindIndexBuffer(a0, a1, a2, a3);
}
pub inline fn vkCmdPushConstants(a0: VkCommandBuffer, a1: VkPipelineLayout, a2: u32, a3: u32, a4: u32, a5: *const anyopaque) void {
    return dispatch.vkCmdPushConstants(a0, a1, a2, a3, a4, a5);
}
pub inline fn vkCmdDrawIndexed(a0: VkCommandBuffer, a1: u32, a2: u32, a3: u32, a4: i32, a5: u32) void {
    return dispatch.vkCmdDrawIndexed(a0, a1, a2, a3, a4, a5);
}
pub inline fn vkCmdCopyImageToBuffer(a0: VkCommandBuffer, a1: VkImage, a2: u32, a3: VkBuffer, a4: u32, a5: [*]const VkBufferImageCopy) void {
    return dispatch.vkCmdCopyImageToBuffer(a0, a1, a2, a3, a4, a5);
}
pub inline fn vkCmdCopyBufferToImage(a0: VkCommandBuffer, a1: VkBuffer, a2: VkImage, a3: u32, a4: u32, a5: [*]const VkBufferImageCopy) void {
    return dispatch.vkCmdCopyBufferToImage(a0, a1, a2, a3, a4, a5);
}
pub inline fn vkCmdPipelineBarrier(a0: VkCommandBuffer, a1: u32, a2: u32, a3: u32, a4: u32, a5: ?*const anyopaque, a6: u32, a7: ?[*]const VkBufferMemoryBarrier, a8: u32, a9: ?[*]const VkImageMemoryBarrier) void {
    return dispatch.vkCmdPipelineBarrier(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9);
}
pub inline fn vkCreateFence(a0: VkDevice, a1: *const VkFenceCreateInfo, a2: ?*const anyopaque, a3: *VkFence) VkResult {
    return dispatch.vkCreateFence(a0, a1, a2, a3);
}
pub inline fn vkDestroyFence(a0: VkDevice, a1: VkFence, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyFence(a0, a1, a2);
}
pub inline fn vkResetFences(a0: VkDevice, a1: u32, a2: [*]const VkFence) VkResult {
    return dispatch.vkResetFences(a0, a1, a2);
}
pub inline fn vkWaitForFences(a0: VkDevice, a1: u32, a2: [*]const VkFence, a3: u32, a4: u64) VkResult {
    return dispatch.vkWaitForFences(a0, a1, a2, a3, a4);
}
pub inline fn vkQueueSubmit(a0: VkQueue, a1: u32, a2: [*]const VkSubmitInfo, a3: VkFence) VkResult {
    return dispatch.vkQueueSubmit(a0, a1, a2, a3);
}
pub inline fn vkDeviceWaitIdle(a0: VkDevice) VkResult {
    return dispatch.vkDeviceWaitIdle(a0);
}

pub const PfnGetMemoryHostPointerProperties = *const fn (VkDevice, u32, *const anyopaque, *VkMemoryHostPointerPropertiesEXT) callconv(.c) VkResult;

// Export dmabuf della color image mesh (VK_KHR_external_memory_fd +
// VK_EXT_external_memory_dma_buf + VK_EXT_image_drm_format_modifier), per
// presentDmabuf zero-copy su Wayland — vedi issue #11. Valori numerici presi
// da /usr/include/vulkan/vulkan_core.h (mai a memoria: un sType sbagliato nella
// pNext chain è corruzione silenziosa, non un errore che il driver segnala).
pub const EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT: u32 = 0x200;
pub const ST_EXTERNAL_MEMORY_IMAGE_CREATE_INFO: VkStructureType = 1000072001;
pub const ST_EXPORT_MEMORY_ALLOCATE_INFO: VkStructureType = 1000072002;
pub const ST_MEMORY_GET_FD_INFO_KHR: VkStructureType = 1000074002;
pub const ST_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT: VkStructureType = 1000158003;
pub const ST_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT: VkStructureType = 1000158005;
pub const IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT: u32 = 1000158000;
// vkGetImageSubresourceLayout su un'immagine DRM_FORMAT_MODIFIER_EXT vuole
// l'aspect del PIANO DI MEMORIA (piano fisico del modifier), non l'aspect
// logico ASPECT_COLOR usato per la image view — sono namespace diversi.
// Single-plane (il nostro caso, LINEAR): solo il piano 0.
pub const ASPECT_MEMORY_PLANE_0_BIT_EXT: u32 = 0x80;
// Da /usr/include/libdrm/drm_fourcc.h: fourcc_mod_code(NONE, 0) e
// fourcc_code('A','B','2','4') — richiesto esplicitamente in fase di export
// così l'unico modifier possibile è quello universalmente importabile da
// (quasi) ogni compositor, senza negoziazione (Zrame non implementa ancora
// zwp_linux_dmabuf_feedback_v1, vedi window_wayland.zig).
pub const DRM_FORMAT_MOD_LINEAR: u64 = 0;
pub const DRM_FORMAT_ABGR8888: u32 = 0x34324241; // layout memoria R,G,B,A — combacia con FORMAT_R8G8B8A8_UNORM

pub const VkExternalMemoryImageCreateInfo = extern struct {
    sType: VkStructureType = ST_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    handleTypes: u32,
};

pub const VkExportMemoryAllocateInfo = extern struct {
    sType: VkStructureType = ST_EXPORT_MEMORY_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    handleTypes: u32,
};

pub const VkImageDrmFormatModifierListCreateInfoEXT = extern struct {
    sType: VkStructureType = ST_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
    pNext: ?*const anyopaque = null,
    drmFormatModifierCount: u32,
    pDrmFormatModifiers: [*]const u64,
};

pub const VkImageDrmFormatModifierPropertiesEXT = extern struct {
    sType: VkStructureType = ST_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT,
    pNext: ?*anyopaque = null,
    drmFormatModifier: u64 = 0,
};

pub const VkMemoryGetFdInfoKHR = extern struct {
    sType: VkStructureType = ST_MEMORY_GET_FD_INFO_KHR,
    pNext: ?*const anyopaque = null,
    memory: VkDeviceMemory,
    handleType: u32,
};

pub const VkImageSubresource = extern struct {
    aspectMask: u32,
    mipLevel: u32 = 0,
    arrayLayer: u32 = 0,
};

pub const VkSubresourceLayout = extern struct {
    offset: u64 = 0,
    size: u64 = 0,
    rowPitch: u64 = 0,
    arrayPitch: u64 = 0,
    depthPitch: u64 = 0,
};

// Core dal loader (nessun GetDeviceProcAddr): stesso trattamento di
// vkGetImageMemoryRequirements più sopra.
pub inline fn vkGetImageSubresourceLayout(a0: VkDevice, a1: VkImage, a2: *const VkImageSubresource, a3: *VkSubresourceLayout) void {
    return dispatch.vkGetImageSubresourceLayout(a0, a1, a2, a3);
}

// Estensioni: caricate via vkGetDeviceProcAddr solo se il device le supporta
// (stesso pattern di PfnGetMemoryHostPointerProperties).
pub const PfnGetMemoryFd = *const fn (VkDevice, *const VkMemoryGetFdInfoKHR, *i32) callconv(.c) VkResult;
pub const PfnGetImageDrmFormatModifierProperties = *const fn (VkDevice, VkImage, *VkImageDrmFormatModifierPropertiesEXT) callconv(.c) VkResult;

pub const VK_ERROR_DEVICE_LOST: VkResult = -4;

/// `VK_ERROR_DEVICE_LOST` ha un errore suo: il chiamante deve distruggere il
/// renderer (non ritentare il frame su un device che non tornerà).
pub fn check(r: VkResult) !void {
    if (r == VK_SUCCESS) return;
    if (r == VK_ERROR_DEVICE_LOST) return error.VulkanDeviceLost;
    return error.VulkanError;
}

pub const ST_SAMPLER_CREATE_INFO: VkStructureType = 31;
pub const ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: VkStructureType = 32;
pub const ST_DESCRIPTOR_POOL_CREATE_INFO: VkStructureType = 33;
pub const ST_DESCRIPTOR_SET_ALLOCATE_INFO: VkStructureType = 34;
pub const ST_WRITE_DESCRIPTOR_SET: VkStructureType = 35;

pub const FORMAT_R8_UNORM: u32 = 9;
pub const FORMAT_R32G32_SFLOAT: u32 = 103;
pub const IMAGE_USAGE_SAMPLED: u32 = 0x4;
pub const IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: u32 = 5;
pub const DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: u32 = 1;
pub const DESCRIPTOR_TYPE_STORAGE_BUFFER: u32 = 7;
pub const BLEND_FACTOR_SRC_ALPHA: u32 = 6;
pub const BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: u32 = 7;
pub const ACCESS_SHADER_READ: u32 = 0x20;
pub const STAGE_FRAGMENT_SHADER: u32 = 0x80;
pub const COLOR_WRITE_RGB: u32 = 0x7;

pub const VkSampler = u64;
pub const VkDescriptorSetLayout = u64;
pub const VkDescriptorPool = u64;
pub const VkDescriptorSet = u64;

pub const VkSamplerCreateInfo = extern struct {
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

pub const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32,
    stageFlags: u32,
    pImmutableSamplers: ?*const anyopaque = null,
};

pub const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: VkStructureType = ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    bindingCount: u32,
    pBindings: [*]const VkDescriptorSetLayoutBinding,
};

pub const VkDescriptorPoolSize = extern struct { type: u32, descriptorCount: u32 };

pub const VkDescriptorPoolCreateInfo = extern struct {
    sType: VkStructureType = ST_DESCRIPTOR_POOL_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: [*]const VkDescriptorPoolSize,
};

pub const VkDescriptorSetAllocateInfo = extern struct {
    sType: VkStructureType = ST_DESCRIPTOR_SET_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32 = 1,
    pSetLayouts: [*]const VkDescriptorSetLayout,
};

pub const VkDescriptorImageInfo = extern struct {
    sampler: VkSampler,
    imageView: VkImageView,
    imageLayout: u32,
};

pub const VkDescriptorBufferInfo = extern struct {
    buffer: VkBuffer,
    offset: u64 = 0,
    range: u64,
};

pub const VkWriteDescriptorSet = extern struct {
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

pub inline fn vkCreateSampler(a0: VkDevice, a1: *const VkSamplerCreateInfo, a2: ?*const anyopaque, a3: *VkSampler) VkResult {
    return dispatch.vkCreateSampler(a0, a1, a2, a3);
}
pub inline fn vkDestroySampler(a0: VkDevice, a1: VkSampler, a2: ?*const anyopaque) void {
    return dispatch.vkDestroySampler(a0, a1, a2);
}
pub inline fn vkCreateDescriptorSetLayout(a0: VkDevice, a1: *const VkDescriptorSetLayoutCreateInfo, a2: ?*const anyopaque, a3: *VkDescriptorSetLayout) VkResult {
    return dispatch.vkCreateDescriptorSetLayout(a0, a1, a2, a3);
}
pub inline fn vkDestroyDescriptorSetLayout(a0: VkDevice, a1: VkDescriptorSetLayout, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyDescriptorSetLayout(a0, a1, a2);
}
pub inline fn vkCreateDescriptorPool(a0: VkDevice, a1: *const VkDescriptorPoolCreateInfo, a2: ?*const anyopaque, a3: *VkDescriptorPool) VkResult {
    return dispatch.vkCreateDescriptorPool(a0, a1, a2, a3);
}
pub inline fn vkDestroyDescriptorPool(a0: VkDevice, a1: VkDescriptorPool, a2: ?*const anyopaque) void {
    return dispatch.vkDestroyDescriptorPool(a0, a1, a2);
}
pub inline fn vkAllocateDescriptorSets(a0: VkDevice, a1: *const VkDescriptorSetAllocateInfo, a2: *VkDescriptorSet) VkResult {
    return dispatch.vkAllocateDescriptorSets(a0, a1, a2);
}
pub inline fn vkUpdateDescriptorSets(a0: VkDevice, a1: u32, a2: [*]const VkWriteDescriptorSet, a3: u32, a4: ?*const anyopaque) void {
    return dispatch.vkUpdateDescriptorSets(a0, a1, a2, a3, a4);
}
pub inline fn vkCmdBindDescriptorSets(a0: VkCommandBuffer, a1: u32, a2: VkPipelineLayout, a3: u32, a4: u32, a5: [*]const VkDescriptorSet, a6: u32, a7: ?*const u32) void {
    return dispatch.vkCmdBindDescriptorSets(a0, a1, a2, a3, a4, a5, a6, a7);
}
pub inline fn vkCmdDraw(a0: VkCommandBuffer, a1: u32, a2: u32, a3: u32, a4: u32) void {
    return dispatch.vkCmdDraw(a0, a1, a2, a3, a4);
}

// ---------------------------------------------------------------------------
// Tabella di dispatch: riempita a runtime da `loader.zig` (nessun import statico
// del loader Vulkan). Generata dalle firme sopra; livello di ogni comando in
// `Level` (global → vkGetInstanceProcAddr(NULL), il resto → (instance)).
// ---------------------------------------------------------------------------
pub const Dispatch = struct {
    vkCreateInstance: *const fn (*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) callconv(.c) VkResult,
    vkEnumerateInstanceExtensionProperties: *const fn (?[*:0]const u8, *u32, ?[*]VkExtensionProperties) callconv(.c) VkResult,
    vkDestroyInstance: *const fn (VkInstance, ?*const anyopaque) callconv(.c) void,
    vkEnumeratePhysicalDevices: *const fn (VkInstance, *u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, *u32, ?[*]VkQueueFamilyProperties) callconv(.c) void,
    vkGetPhysicalDeviceMemoryProperties: *const fn (VkPhysicalDevice, *VkPhysicalDeviceMemoryProperties) callconv(.c) void,
    vkGetPhysicalDeviceProperties: *const fn (VkPhysicalDevice, *VkPhysicalDeviceProperties) callconv(.c) void,
    vkEnumerateDeviceExtensionProperties: *const fn (VkPhysicalDevice, ?[*:0]const u8, *u32, ?[*]VkExtensionProperties) callconv(.c) VkResult,
    vkCreateDevice: *const fn (VkPhysicalDevice, *const VkDeviceCreateInfo, ?*const anyopaque, *VkDevice) callconv(.c) VkResult,
    vkDestroyDevice: *const fn (VkDevice, ?*const anyopaque) callconv(.c) void,
    vkGetDeviceQueue: *const fn (VkDevice, u32, u32, *VkQueue) callconv(.c) void,
    vkGetDeviceProcAddr: *const fn (VkDevice, [*:0]const u8) callconv(.c) ?PfnVoidFunction,
    vkCreateBuffer: *const fn (VkDevice, *const VkBufferCreateInfo, ?*const anyopaque, *VkBuffer) callconv(.c) VkResult,
    vkDestroyBuffer: *const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.c) void,
    vkGetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, *VkMemoryRequirements) callconv(.c) void,
    vkAllocateMemory: *const fn (VkDevice, *const VkMemoryAllocateInfo, ?*const anyopaque, *VkDeviceMemory) callconv(.c) VkResult,
    vkFreeMemory: *const fn (VkDevice, VkDeviceMemory, ?*const anyopaque) callconv(.c) void,
    vkBindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkMapMemory: *const fn (VkDevice, VkDeviceMemory, u64, u64, u32, **anyopaque) callconv(.c) VkResult,
    vkCreateImage: *const fn (VkDevice, *const VkImageCreateInfo, ?*const anyopaque, *VkImage) callconv(.c) VkResult,
    vkDestroyImage: *const fn (VkDevice, VkImage, ?*const anyopaque) callconv(.c) void,
    vkGetImageMemoryRequirements: *const fn (VkDevice, VkImage, *VkMemoryRequirements) callconv(.c) void,
    vkBindImageMemory: *const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkCreateImageView: *const fn (VkDevice, *const VkImageViewCreateInfo, ?*const anyopaque, *VkImageView) callconv(.c) VkResult,
    vkDestroyImageView: *const fn (VkDevice, VkImageView, ?*const anyopaque) callconv(.c) void,
    vkCreateShaderModule: *const fn (VkDevice, *const VkShaderModuleCreateInfo, ?*const anyopaque, *VkShaderModule) callconv(.c) VkResult,
    vkDestroyShaderModule: *const fn (VkDevice, VkShaderModule, ?*const anyopaque) callconv(.c) void,
    vkCreatePipelineLayout: *const fn (VkDevice, *const VkPipelineLayoutCreateInfo, ?*const anyopaque, *VkPipelineLayout) callconv(.c) VkResult,
    vkDestroyPipelineLayout: *const fn (VkDevice, VkPipelineLayout, ?*const anyopaque) callconv(.c) void,
    vkCreateRenderPass: *const fn (VkDevice, *const VkRenderPassCreateInfo, ?*const anyopaque, *VkRenderPass) callconv(.c) VkResult,
    vkDestroyRenderPass: *const fn (VkDevice, VkRenderPass, ?*const anyopaque) callconv(.c) void,
    vkCreateFramebuffer: *const fn (VkDevice, *const VkFramebufferCreateInfo, ?*const anyopaque, *VkFramebuffer) callconv(.c) VkResult,
    vkDestroyFramebuffer: *const fn (VkDevice, VkFramebuffer, ?*const anyopaque) callconv(.c) void,
    vkCreateGraphicsPipelines: *const fn (VkDevice, u64, u32, [*]const VkGraphicsPipelineCreateInfo, ?*const anyopaque, [*]VkPipeline) callconv(.c) VkResult,
    vkDestroyPipeline: *const fn (VkDevice, VkPipeline, ?*const anyopaque) callconv(.c) void,
    vkCreateCommandPool: *const fn (VkDevice, *const VkCommandPoolCreateInfo, ?*const anyopaque, *VkCommandPool) callconv(.c) VkResult,
    vkDestroyCommandPool: *const fn (VkDevice, VkCommandPool, ?*const anyopaque) callconv(.c) void,
    vkAllocateCommandBuffers: *const fn (VkDevice, *const VkCommandBufferAllocateInfo, [*]VkCommandBuffer) callconv(.c) VkResult,
    vkBeginCommandBuffer: *const fn (VkCommandBuffer, *const VkCommandBufferBeginInfo) callconv(.c) VkResult,
    vkEndCommandBuffer: *const fn (VkCommandBuffer) callconv(.c) VkResult,
    vkCmdBeginRenderPass: *const fn (VkCommandBuffer, *const VkRenderPassBeginInfo, u32) callconv(.c) void,
    vkCmdEndRenderPass: *const fn (VkCommandBuffer) callconv(.c) void,
    vkCmdBindPipeline: *const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void,
    vkCmdSetViewport: *const fn (VkCommandBuffer, u32, u32, [*]const VkViewport) callconv(.c) void,
    vkCmdSetScissor: *const fn (VkCommandBuffer, u32, u32, [*]const VkRect2D) callconv(.c) void,
    vkCmdBindVertexBuffers: *const fn (VkCommandBuffer, u32, u32, [*]const VkBuffer, [*]const u64) callconv(.c) void,
    vkCmdBindIndexBuffer: *const fn (VkCommandBuffer, VkBuffer, u64, u32) callconv(.c) void,
    vkCmdPushConstants: *const fn (VkCommandBuffer, VkPipelineLayout, u32, u32, u32, *const anyopaque) callconv(.c) void,
    vkCmdDrawIndexed: *const fn (VkCommandBuffer, u32, u32, u32, i32, u32) callconv(.c) void,
    vkCmdCopyImageToBuffer: *const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, [*]const VkBufferImageCopy) callconv(.c) void,
    vkCmdCopyBufferToImage: *const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, [*]const VkBufferImageCopy) callconv(.c) void,
    vkCmdPipelineBarrier: *const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?[*]const VkBufferMemoryBarrier, u32, ?[*]const VkImageMemoryBarrier) callconv(.c) void,
    vkCreateFence: *const fn (VkDevice, *const VkFenceCreateInfo, ?*const anyopaque, *VkFence) callconv(.c) VkResult,
    vkDestroyFence: *const fn (VkDevice, VkFence, ?*const anyopaque) callconv(.c) void,
    vkResetFences: *const fn (VkDevice, u32, [*]const VkFence) callconv(.c) VkResult,
    vkWaitForFences: *const fn (VkDevice, u32, [*]const VkFence, u32, u64) callconv(.c) VkResult,
    vkQueueSubmit: *const fn (VkQueue, u32, [*]const VkSubmitInfo, VkFence) callconv(.c) VkResult,
    vkDeviceWaitIdle: *const fn (VkDevice) callconv(.c) VkResult,
    vkGetImageSubresourceLayout: *const fn (VkDevice, VkImage, *const VkImageSubresource, *VkSubresourceLayout) callconv(.c) void,
    vkCreateSampler: *const fn (VkDevice, *const VkSamplerCreateInfo, ?*const anyopaque, *VkSampler) callconv(.c) VkResult,
    vkDestroySampler: *const fn (VkDevice, VkSampler, ?*const anyopaque) callconv(.c) void,
    vkCreateDescriptorSetLayout: *const fn (VkDevice, *const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, *VkDescriptorSetLayout) callconv(.c) VkResult,
    vkDestroyDescriptorSetLayout: *const fn (VkDevice, VkDescriptorSetLayout, ?*const anyopaque) callconv(.c) void,
    vkCreateDescriptorPool: *const fn (VkDevice, *const VkDescriptorPoolCreateInfo, ?*const anyopaque, *VkDescriptorPool) callconv(.c) VkResult,
    vkDestroyDescriptorPool: *const fn (VkDevice, VkDescriptorPool, ?*const anyopaque) callconv(.c) void,
    vkAllocateDescriptorSets: *const fn (VkDevice, *const VkDescriptorSetAllocateInfo, *VkDescriptorSet) callconv(.c) VkResult,
    vkUpdateDescriptorSets: *const fn (VkDevice, u32, [*]const VkWriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void,
    vkCmdBindDescriptorSets: *const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, [*]const VkDescriptorSet, u32, ?*const u32) callconv(.c) void,
    vkCmdDraw: *const fn (VkCommandBuffer, u32, u32, u32, u32) callconv(.c) void,
};

pub const PfnVoidFunction = *const fn () callconv(.c) void;
pub const PfnGetInstanceProcAddr = *const fn (VkInstance, [*:0]const u8) callconv(.c) ?PfnVoidFunction;

pub const Level = enum { global, instance, device };
pub fn level(comptime name: []const u8) Level {
    @setEvalBranchQuota(20_000);
    const global = [_][]const u8{ "vkCreateInstance", "vkEnumerateInstanceExtensionProperties" };
    const instance = [_][]const u8{ "vkCreateDevice", "vkDestroyInstance", "vkEnumerateDeviceExtensionProperties", "vkEnumeratePhysicalDevices", "vkGetDeviceProcAddr", "vkGetPhysicalDeviceMemoryProperties", "vkGetPhysicalDeviceProperties", "vkGetPhysicalDeviceQueueFamilyProperties" };
    inline for (global) |g| if (comptime std.mem.eql(u8, g, name)) return .global;
    inline for (instance) |g| if (comptime std.mem.eql(u8, g, name)) return .instance;
    return .device;
}

/// Puntatori risolti. Validi solo dopo `loader.ensureLoaded()` + `loader.ensureInstance()`
/// riusciti: Renderer.init è l'unico ingresso e li chiama prima di ogni comando.
pub var dispatch: Dispatch = undefined;
