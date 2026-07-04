// ---------------------------------------------------------------------------
// Binding Vulkan minimali (esportati per uso modulare)
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

pub extern "vulkan" fn vkCreateInstance(*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) VkResult;
pub extern "vulkan" fn vkDestroyInstance(VkInstance, ?*const anyopaque) void;
pub extern "vulkan" fn vkEnumeratePhysicalDevices(VkInstance, *u32, ?[*]VkPhysicalDevice) VkResult;
pub extern "vulkan" fn vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice, *u32, ?[*]VkQueueFamilyProperties) void;
pub extern "vulkan" fn vkGetPhysicalDeviceMemoryProperties(VkPhysicalDevice, *VkPhysicalDeviceMemoryProperties) void;
pub extern "vulkan" fn vkEnumerateDeviceExtensionProperties(VkPhysicalDevice, ?[*:0]const u8, *u32, ?[*]VkExtensionProperties) VkResult;
pub extern "vulkan" fn vkCreateDevice(VkPhysicalDevice, *const VkDeviceCreateInfo, ?*const anyopaque, *VkDevice) VkResult;
pub extern "vulkan" fn vkDestroyDevice(VkDevice, ?*const anyopaque) void;
pub extern "vulkan" fn vkGetDeviceQueue(VkDevice, u32, u32, *VkQueue) void;
pub extern "vulkan" fn vkGetDeviceProcAddr(VkDevice, [*:0]const u8) ?*const fn () callconv(.c) void;
pub extern "vulkan" fn vkCreateBuffer(VkDevice, *const VkBufferCreateInfo, ?*const anyopaque, *VkBuffer) VkResult;
pub extern "vulkan" fn vkDestroyBuffer(VkDevice, VkBuffer, ?*const anyopaque) void;
pub extern "vulkan" fn vkGetBufferMemoryRequirements(VkDevice, VkBuffer, *VkMemoryRequirements) void;
pub extern "vulkan" fn vkAllocateMemory(VkDevice, *const VkMemoryAllocateInfo, ?*const anyopaque, *VkDeviceMemory) VkResult;
pub extern "vulkan" fn vkFreeMemory(VkDevice, VkDeviceMemory, ?*const anyopaque) void;
pub extern "vulkan" fn vkBindBufferMemory(VkDevice, VkBuffer, VkDeviceMemory, u64) VkResult;
pub extern "vulkan" fn vkMapMemory(VkDevice, VkDeviceMemory, u64, u64, u32, **anyopaque) VkResult;
pub extern "vulkan" fn vkCreateImage(VkDevice, *const VkImageCreateInfo, ?*const anyopaque, *VkImage) VkResult;
pub extern "vulkan" fn vkDestroyImage(VkDevice, VkImage, ?*const anyopaque) void;
pub extern "vulkan" fn vkGetImageMemoryRequirements(VkDevice, VkImage, *VkMemoryRequirements) void;
pub extern "vulkan" fn vkBindImageMemory(VkDevice, VkImage, VkDeviceMemory, u64) VkResult;
pub extern "vulkan" fn vkCreateImageView(VkDevice, *const VkImageViewCreateInfo, ?*const anyopaque, *VkImageView) VkResult;
pub extern "vulkan" fn vkDestroyImageView(VkDevice, VkImageView, ?*const anyopaque) void;
pub extern "vulkan" fn vkCreateShaderModule(VkDevice, *const VkShaderModuleCreateInfo, ?*const anyopaque, *VkShaderModule) VkResult;
pub extern "vulkan" fn vkDestroyShaderModule(VkDevice, VkShaderModule, ?*const anyopaque) void;
pub extern "vulkan" fn vkCreatePipelineLayout(VkDevice, *const VkPipelineLayoutCreateInfo, ?*const anyopaque, *VkPipelineLayout) VkResult;
pub extern "vulkan" fn vkDestroyPipelineLayout(VkDevice, VkPipelineLayout, ?*const anyopaque) void;
pub extern "vulkan" fn vkCreateRenderPass(VkDevice, *const VkRenderPassCreateInfo, ?*const anyopaque, *VkRenderPass) VkResult;
pub extern "vulkan" fn vkDestroyRenderPass(VkDevice, VkRenderPass, ?*const anyopaque) void;
pub extern "vulkan" fn vkCreateFramebuffer(VkDevice, *const VkFramebufferCreateInfo, ?*const anyopaque, *VkFramebuffer) VkResult;
pub extern "vulkan" fn vkDestroyFramebuffer(VkDevice, VkFramebuffer, ?*const anyopaque) void;
pub extern "vulkan" fn vkCreateGraphicsPipelines(VkDevice, u64, u32, [*]const VkGraphicsPipelineCreateInfo, ?*const anyopaque, [*]VkPipeline) VkResult;
pub extern "vulkan" fn vkDestroyPipeline(VkDevice, VkPipeline, ?*const anyopaque) void;
pub extern "vulkan" fn vkCreateCommandPool(VkDevice, *const VkCommandPoolCreateInfo, ?*const anyopaque, *VkCommandPool) VkResult;
pub extern "vulkan" fn vkDestroyCommandPool(VkDevice, VkCommandPool, ?*const anyopaque) void;
pub extern "vulkan" fn vkAllocateCommandBuffers(VkDevice, *const VkCommandBufferAllocateInfo, [*]VkCommandBuffer) VkResult;
pub extern "vulkan" fn vkBeginCommandBuffer(VkCommandBuffer, *const VkCommandBufferBeginInfo) VkResult;
pub extern "vulkan" fn vkEndCommandBuffer(VkCommandBuffer) VkResult;
pub extern "vulkan" fn vkCmdBeginRenderPass(VkCommandBuffer, *const VkRenderPassBeginInfo, u32) void;
pub extern "vulkan" fn vkCmdEndRenderPass(VkCommandBuffer) void;
pub extern "vulkan" fn vkCmdBindPipeline(VkCommandBuffer, u32, VkPipeline) void;
pub extern "vulkan" fn vkCmdSetViewport(VkCommandBuffer, u32, u32, [*]const VkViewport) void;
pub extern "vulkan" fn vkCmdSetScissor(VkCommandBuffer, u32, u32, [*]const VkRect2D) void;
pub extern "vulkan" fn vkCmdBindVertexBuffers(VkCommandBuffer, u32, u32, [*]const VkBuffer, [*]const u64) void;
pub extern "vulkan" fn vkCmdBindIndexBuffer(VkCommandBuffer, VkBuffer, u64, u32) void;
pub extern "vulkan" fn vkCmdPushConstants(VkCommandBuffer, VkPipelineLayout, u32, u32, u32, *const anyopaque) void;
pub extern "vulkan" fn vkCmdDrawIndexed(VkCommandBuffer, u32, u32, u32, i32, u32) void;
pub extern "vulkan" fn vkCmdCopyImageToBuffer(VkCommandBuffer, VkImage, u32, VkBuffer, u32, [*]const VkBufferImageCopy) void;
pub extern "vulkan" fn vkCmdCopyBufferToImage(VkCommandBuffer, VkBuffer, VkImage, u32, u32, [*]const VkBufferImageCopy) void;
pub extern "vulkan" fn vkCmdPipelineBarrier(VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?[*]const VkBufferMemoryBarrier, u32, ?[*]const VkImageMemoryBarrier) void;
pub extern "vulkan" fn vkCreateFence(VkDevice, *const VkFenceCreateInfo, ?*const anyopaque, *VkFence) VkResult;
pub extern "vulkan" fn vkDestroyFence(VkDevice, VkFence, ?*const anyopaque) void;
pub extern "vulkan" fn vkResetFences(VkDevice, u32, [*]const VkFence) VkResult;
pub extern "vulkan" fn vkWaitForFences(VkDevice, u32, [*]const VkFence, u32, u64) VkResult;
pub extern "vulkan" fn vkQueueSubmit(VkQueue, u32, [*]const VkSubmitInfo, VkFence) VkResult;
pub extern "vulkan" fn vkDeviceWaitIdle(VkDevice) VkResult;

pub const PfnGetMemoryHostPointerProperties = *const fn (VkDevice, u32, *const anyopaque, *VkMemoryHostPointerPropertiesEXT) callconv(.c) VkResult;

pub fn check(r: VkResult) !void {
    if (r != VK_SUCCESS) return error.VulkanError;
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

pub extern "vulkan" fn vkCreateSampler(VkDevice, *const VkSamplerCreateInfo, ?*const anyopaque, *VkSampler) VkResult;
pub extern "vulkan" fn vkDestroySampler(VkDevice, VkSampler, ?*const anyopaque) void;
pub extern "vulkan" fn vkCreateDescriptorSetLayout(VkDevice, *const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, *VkDescriptorSetLayout) VkResult;
pub extern "vulkan" fn vkDestroyDescriptorSetLayout(VkDevice, VkDescriptorSetLayout, ?*const anyopaque) void;
pub extern "vulkan" fn vkCreateDescriptorPool(VkDevice, *const VkDescriptorPoolCreateInfo, ?*const anyopaque, *VkDescriptorPool) VkResult;
pub extern "vulkan" fn vkDestroyDescriptorPool(VkDevice, VkDescriptorPool, ?*const anyopaque) void;
pub extern "vulkan" fn vkAllocateDescriptorSets(VkDevice, *const VkDescriptorSetAllocateInfo, *VkDescriptorSet) VkResult;
pub extern "vulkan" fn vkUpdateDescriptorSets(VkDevice, u32, [*]const VkWriteDescriptorSet, u32, ?*const anyopaque) void;
pub extern "vulkan" fn vkCmdBindDescriptorSets(VkCommandBuffer, u32, VkPipelineLayout, u32, u32, [*]const VkDescriptorSet, u32, ?*const u32) void;
pub extern "vulkan" fn vkCmdDraw(VkCommandBuffer, u32, u32, u32, u32) void;
