const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");
const vkutil = @import("vkutil.zig");
const argsparse = @import("MasterQ32/zig-args");
const zlm = @import("ziglibs/zlm");
const shader_bytecode = @import("shaders/index.zig");
const stb_img = @import("stb_image");

const util = @import("util");
const resources = @import("res/index.zig");
const build_options = @import("build_options");

const VulkanInstance = struct {
    handle: vk.Instance,
    dsp: InstanceDispatch,
};
const VulkanDevice = struct {
    handle: vk.Device,
    dsp: DeviceDispatch,

    pub inline fn createBuffer(self: VulkanDevice, allocator: std.mem.Allocator, create_info: vkutil.BufferCreateInfo) DeviceDispatch.CreateBufferError!vk.Buffer {
        return vkutil.createBuffer(allocator, self.dsp, self.handle, create_info);
    }
    pub inline fn destroyBuffer(self: VulkanDevice, allocator: std.mem.Allocator, buffer: vk.Buffer) void {
        return vkutil.destroyBuffer(allocator, self.dsp, self.handle, buffer);
    }

    pub inline fn allocateMemory(self: VulkanDevice, allocator: std.mem.Allocator, allocate_info: vk.MemoryAllocateInfo) DeviceDispatch.AllocateMemoryError!vk.DeviceMemory {
        return vkutil.allocateMemory(allocator, self.dsp, self.handle, allocate_info);
    }
    pub inline fn freeMemory(self: VulkanDevice, allocator: std.mem.Allocator, memory: vk.DeviceMemory) void {
        return vkutil.freeMemory(allocator, self.dsp, self.handle, memory);
    }

    pub inline fn bindBufferMemory(self: VulkanDevice, buffer: vk.Buffer, memory: vk.DeviceMemory, memory_offset: vk.DeviceSize) DeviceDispatch.BindBufferMemoryError!void {
        return self.dsp.bindBufferMemory(self.handle, buffer, memory, memory_offset);
    }
};
const CoreQueueFamilyIndices = struct {
    graphics: u32,
    present: u32,
};
const Swapchain = struct {
    handle: vk.SwapchainKHR,
    details: Swapchain.Details,
    images: std.MultiArrayList(ImageAndView).Slice,

    const Details = struct {
        capabilities: vk.SurfaceCapabilitiesKHR,
        format: vk.SurfaceFormatKHR,
        present_mode: vk.PresentModeKHR,
        extent: vk.Extent2D,
        image_count: u32,
    };
    const ImageAndView = struct {
        img: vk.Image,
        view: vk.ImageView,
    };

    fn create(
        allocator: std.mem.Allocator,
        device: VulkanDevice,
        surface: vk.SurfaceKHR,
        formats: []const vk.SurfaceFormatKHR,
        present_modes: []const vk.PresentModeKHR,
        capabilities: vk.SurfaceCapabilitiesKHR,
        core_qfi: CoreQueueFamilyIndices,
        framebuffer_size: vk.Extent2D,
    ) !Swapchain {
        const details: Swapchain.Details = try figureOutDetails(capabilities, framebuffer_size, formats, present_modes);
        const handle = try createSwapchainHandle(allocator, device, surface, details, core_qfi);
        errdefer vkutil.destroySwapchainKHR(allocator, device.dsp, device.handle, handle);

        var images: std.MultiArrayList(ImageAndView).Slice = images: {
            var images: std.MultiArrayList(ImageAndView) = .{};
            break :images images.toOwnedSlice();
        };
        errdefer images.deinit(allocator);
        try populateImages(allocator, device, handle, details, &images);

        return Swapchain{
            .handle = handle,
            .details = details,
            .images = images,
        };
    }

    fn destroy(self: *Swapchain, allocator: std.mem.Allocator, device: VulkanDevice) void {
        for (self.images.items(.view)) |view| {
            vkutil.destroyImageView(allocator, device.dsp, device.handle, view);
        }
        self.images.deinit(allocator);
        vkutil.destroySwapchainKHR(allocator, device.dsp, device.handle, self.handle);
        self.* = undefined;
    }

    fn recreate(
        self: *Swapchain,
        allocator: std.mem.Allocator,
        device: VulkanDevice,
        surface: vk.SurfaceKHR,
        formats: []const vk.SurfaceFormatKHR,
        present_modes: []const vk.PresentModeKHR,
        capabilities: vk.SurfaceCapabilitiesKHR,
        core_qfi: CoreQueueFamilyIndices,
        framebuffer_size: vk.Extent2D,
    ) !void {
        self.details = try figureOutDetails(capabilities, framebuffer_size, formats, present_modes);
        vkutil.destroySwapchainKHR(allocator, device.dsp, device.handle, self.handle);
        self.handle = try createSwapchainHandle(allocator, device, surface, self.details, core_qfi);
        for (self.images.items(.view)) |view| {
            vkutil.destroyImageView(allocator, device.dsp, device.handle, view);
        }
        try populateImages(allocator, device, self.handle, self.details, &self.images);
    }

    fn populateFramebuffers(
        self: Swapchain,
        allocator: std.mem.Allocator,
        device: VulkanDevice,
        render_pass: vk.RenderPass,
        framebuffers: []vk.Framebuffer,
    ) !void {
        std.debug.assert(framebuffers.len == self.images.len);

        for (self.images.items(.view)) |view, i| {
            errdefer for (framebuffers[0..i]) |prev_fb| {
                device.dsp.destroyFramebuffer(device.handle, prev_fb, &vkutil.allocCallbacksFrom(&allocator));
            };
            const attachments = [_]vk.ImageView{view};
            framebuffers[i] = try device.dsp.createFramebuffer(device.handle, &vk.FramebufferCreateInfo{
                .flags = .{},
                .render_pass = render_pass,

                .attachment_count = @intCast(u32, attachments.len),
                .p_attachments = &attachments,

                .width = self.details.extent.width,
                .height = self.details.extent.height,

                .layers = 1,
            }, &vkutil.allocCallbacksFrom(&allocator));
        }
    }

    fn figureOutDetails(
        capabilities: vk.SurfaceCapabilitiesKHR,
        framebuffer_size: vk.Extent2D,
        formats: []const vk.SurfaceFormatKHR,
        present_modes: []const vk.PresentModeKHR,
    ) error{ NoSurfaceFormatsAvailable, NoSurfacePresentModesAvailable }!Swapchain.Details {
        const selected_format: vk.SurfaceFormatKHR = selected_format: {
            if (formats.len == 0) return error.NoSurfaceFormatsAvailable;
            for (formats) |format| {
                if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                    break :selected_format format;
                }
            }
            break :selected_format formats[0];
        };
        const selected_present_mode: vk.PresentModeKHR = selected_present_mode: {
            if (present_modes.len == 0) return error.NoSurfacePresentModesAvailable;
            if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, .mailbox_khr)) |i| {
                break :selected_present_mode present_modes[i];
            }
            std.debug.assert(std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, .fifo_khr) != null);
            break :selected_present_mode .fifo_khr;
        };
        const selected_extent: vk.Extent2D = selected_extent: {
            if (std.math.maxInt(u32) != capabilities.current_extent.width and
                std.math.maxInt(u32) != capabilities.current_extent.height)
            {
                break :selected_extent capabilities.current_extent;
            }

            break :selected_extent vk.Extent2D{
                .width = std.math.clamp(framebuffer_size.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
                .height = std.math.clamp(framebuffer_size.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
            };
        };
        const image_count: u32 = image_count: {
            const min_image_count: u32 = capabilities.min_image_count;
            const max_image_count: u32 = if (capabilities.max_image_count == 0) std.math.maxInt(u32) else capabilities.max_image_count;
            break :image_count std.math.clamp(min_image_count + 1, min_image_count, max_image_count);
        };
        return Swapchain.Details{
            .capabilities = capabilities,
            .format = selected_format,
            .present_mode = selected_present_mode,
            .extent = selected_extent,
            .image_count = image_count,
        };
    }

    fn createSwapchainHandle(
        allocator: std.mem.Allocator,
        device: VulkanDevice,
        surface: vk.SurfaceKHR,
        details: Swapchain.Details,
        core_qfi: CoreQueueFamilyIndices,
    ) !vk.SwapchainKHR {
        const qfi_array: std.BoundedArray(u32, std.meta.fields(CoreQueueFamilyIndices).len) = qfi_array: {
            var qfi_array = std.BoundedArray(u32, std.meta.fields(CoreQueueFamilyIndices).len).init(0) catch unreachable;
            if (core_qfi.graphics != core_qfi.present) {
                qfi_array.appendSlice(&.{ core_qfi.graphics, core_qfi.present }) catch unreachable;
            }
            break :qfi_array qfi_array;
        };

        return vkutil.createSwapchainKHR(allocator, device.dsp, device.handle, vkutil.SwapchainCreateInfoKHR{
            .surface = surface,

            .min_image_count = details.image_count,
            .image_format = details.format.format,
            .image_color_space = details.format.color_space,
            .image_extent = details.extent,
            .image_array_layers = 1,
            .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true },
            .image_sharing_mode = if (qfi_array.len > 1) .concurrent else .exclusive,

            .queue_family_indices = qfi_array.slice(),

            .pre_transform = details.capabilities.current_transform,
            .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
            .present_mode = details.present_mode,
            .clipped = true,
        });
    }

    fn populateImages(
        allocator: std.mem.Allocator,
        device: VulkanDevice,
        swapchain: vk.SwapchainKHR,
        details: Swapchain.Details,
        slice: *std.MultiArrayList(ImageAndView).Slice,
    ) !void {
        var swapchain_images: std.MultiArrayList(ImageAndView) = slice.toMultiArrayList();

        {
            var count: u32 = undefined;
            if (device.dsp.getSwapchainImagesKHR(device.handle, swapchain, &count, null)) |result| switch (result) {
                .success => {},
                else => unreachable,
            } else |err| return err;

            std.debug.assert(count >= details.image_count);
            const capacity_before_resize = swapchain_images.capacity;
            swapchain_images.resize(allocator, count) catch |err| {
                slice.* = swapchain_images.toOwnedSlice();
                return err;
            };

            if (device.dsp.getSwapchainImagesKHR(device.handle, swapchain, &count, swapchain_images.items(.img).ptr)) |result| switch (result) {
                .success => {},
                else => unreachable,
            } else |err| {
                if (capacity_before_resize == swapchain_images.capacity) {
                    slice.* = swapchain_images.toOwnedSlice();
                }
                return err;
            }
        }

        const images: []const vk.Image = swapchain_images.items(.img);
        const views: []vk.ImageView = swapchain_images.items(.view);
        for (views) |*p_view, i| {
            errdefer for (views[0..i]) |prev_view| {
                vkutil.destroyImageView(allocator, device.dsp, device.handle, prev_view);
            };

            p_view.* = try vkutil.createImageView(allocator, device.dsp, device.handle, vk.ImageViewCreateInfo{
                .flags = vk.ImageViewCreateFlags{},
                .image = images[i],
                .view_type = .@"2d",
                .format = details.format.format,
                .components = vk.ComponentMapping{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = vk.ImageSubresourceRange{
                    .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            });
        }

        slice.* = swapchain_images.toOwnedSlice();
    }
};

const Vertex = extern struct {
    pos: Pos,
    color: Color,

    const Pos = zlm.SpecializeOn(f32).Vec2;
    const Color = extern struct { r: f32, g: f32, b: f32 };

    fn bindingDescription(binding: u32) vk.VertexInputBindingDescription {
        return vk.VertexInputBindingDescription{
            .binding = binding,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        };
    }

    fn attributeDescription(binding: u32, comptime field: std.meta.FieldEnum(Vertex)) vk.VertexInputAttributeDescription {
        return vk.VertexInputAttributeDescription{
            .location = switch (field) {
                .pos => 0,
                .color => 1,
            },
            .binding = binding,
            .format = switch (field) {
                .pos => vk.Format.r32g32_sfloat,
                .color => vk.Format.r32g32b32_sfloat,
            },
            .offset = @offsetOf(Vertex, @tagName(field)),
        };
    }
};
const UniformBufferObject = extern struct {
    model: Model,
    view: View,
    proj: Projection,

    const Model = zlm.SpecializeOn(f32).Mat4;
    const View = zlm.SpecializeOn(f32).Mat4;
    const Projection = zlm.SpecializeOn(f32).Mat4;

    fn descriptorSetLayoutBinding(binding: u32) vk.DescriptorSetLayoutBinding {
        return vk.DescriptorSetLayoutBinding{
            .binding = binding,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = vk.ShaderStageFlags{
                .vertex_bit = true,
            },
            .p_immutable_samplers = null,
        };
    }
};

const BaseDispatch = vk.BaseWrapper(vk.BaseCommandFlags{
    .createInstance = true,
    .getInstanceProcAddr = true,
    .enumerateInstanceVersion = true,
    .enumerateInstanceLayerProperties = true,
    .enumerateInstanceExtensionProperties = true,
});
const InstanceDispatchMin = vk.InstanceWrapper(.{ .destroyInstance = true });
const InstanceDispatch = vk.InstanceWrapper(vk.InstanceCommandFlags{
    .destroyInstance = true,
    .enumeratePhysicalDevices = true,
    .getDeviceProcAddr = true,

    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getPhysicalDeviceFeatures = true,
    .getPhysicalDeviceFormatProperties = true,
    .getPhysicalDeviceImageFormatProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .destroySurfaceKHR = true,

    .createDevice = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,

    .createDebugUtilsMessengerEXT = build_options.vk_debug,
    .destroyDebugUtilsMessengerEXT = build_options.vk_debug,
});
const DeviceDispatchMin = vk.DeviceWrapper(vk.DeviceCommandFlags{ .destroyDevice = true });
const DeviceDispatch = vk.DeviceWrapper(vk.DeviceCommandFlags{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .deviceWaitIdle = true,

    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .getSwapchainImagesKHR = true,

    .getImageMemoryRequirements = true,
    .getBufferMemoryRequirements = true,

    .allocateMemory = true,
    .freeMemory = true,

    .mapMemory = true,
    .unmapMemory = true,

    .bindBufferMemory = true,
    .bindImageMemory = true,

    .createBuffer = true,
    .destroyBuffer = true,

    .createImage = true,
    .destroyImage = true,

    .createImageView = true,
    .destroyImageView = true,

    .createShaderModule = true,
    .destroyShaderModule = true,

    .createPipelineLayout = true,
    .destroyPipelineLayout = true,

    .createDescriptorSetLayout = true,
    .destroyDescriptorSetLayout = true,

    .createGraphicsPipelines = true,
    .destroyPipeline = true,

    .createRenderPass = true,
    .destroyRenderPass = true,

    .createFramebuffer = true,
    .destroyFramebuffer = true,

    .createCommandPool = true,
    .destroyCommandPool = true,

    .createDescriptorPool = true,
    .destroyDescriptorPool = true,

    .allocateDescriptorSets = true,
    .freeDescriptorSets = true,

    .updateDescriptorSets = true,

    .createSemaphore = true,
    .destroySemaphore = true,

    .createFence = true,
    .destroyFence = true,
    .resetFences = true,
    .waitForFences = true,

    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,

    .queueSubmit = true,
    .queueWaitIdle = true,
    .queuePresentKHR = true,

    .beginCommandBuffer = true,
    .endCommandBuffer = true,
    .resetCommandBuffer = true,

    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdCopyBuffer = true,
    .cmdCopyBufferToImage = true,
    .cmdPipelineBarrier = true,
    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,
    .cmdBindPipeline = true,
    .cmdBindVertexBuffers = true,
    .cmdBindIndexBuffer = true,
    // .cmdDraw = true,
    .cmdBindDescriptorSets = true,
    .cmdDrawIndexed = true,

    .acquireNextImageKHR = true,
});

fn getInstanceProcAddress(handle: vk.Instance, name: [*:0]const u8) ?*const anyopaque {
    const inst_ptr = @intToPtr(?*anyopaque, @enumToInt(handle));
    const result: glfw.VKProc = glfw.getInstanceProcAddress(inst_ptr, name) orelse return null;
    return @ptrCast(*const anyopaque, result);
}

/// Returns an instance of `vk.MemoryRequirements` which would
/// require a memory type and allocation size to accomodate both.
fn combinedMemoryRequirements(a: vk.MemoryRequirements, b: vk.MemoryRequirements) vk.MemoryRequirements {
    const alignment = @maximum(a.alignment, b.alignment);
    std.debug.assert(alignment % a.alignment == 0);
    std.debug.assert(alignment % b.alignment == 0);
    return vk.MemoryRequirements{
        .size = std.mem.alignBackwardAnyAlign(a.size + b.size, alignment),
        .alignment = alignment,
        .memory_type_bits = a.memory_type_bits & b.memory_type_bits,
    };
}

fn selectMemoryType(
    mem_properties: vkutil.PhysicalDeviceMemoryProperties,
    /// The memory types from which to choose.
    /// The allocation description for which the selected index must be eligible for.
    mem_requirements: vk.MemoryRequirements,
    /// Property flags which the selected index must have enabled.
    property_flags: vk.MemoryPropertyFlags,
) ?u32 {
    var good_enough: ?u32 = null;
    for (mem_properties.memory_types.constSlice()) |memtype, memtype_index| {
        const memtype_bit_mask = std.math.shl(u32, 1, memtype_index);
        const memtype_allowed = memtype_bit_mask & mem_requirements.memory_type_bits != 0;

        if (!memtype_allowed) continue;
        if (!memtype.property_flags.contains(property_flags)) continue;

        const heap: vk.MemoryHeap = mem_properties.memory_heaps.get(memtype.heap_index);
        if (mem_requirements.size < heap.size) {
            if (good_enough) |*currently_good_enough| {
                const currently_good_enough_type = mem_properties.memory_types.get(currently_good_enough.*);
                const currently_good_enough_heap = mem_properties.memory_heaps.get(currently_good_enough_type.heap_index);
                if (currently_good_enough_heap.size < heap.size) continue;
            }
            good_enough = @intCast(u32, memtype_index);
            continue;
        }

        return @intCast(u32, memtype_index);
    }
    return good_enough;
}

const CreateExtensionSetConfig = struct {
    StrType: type = [:0]const u8,
    store_hash: bool = false,
};

fn allocOneCommandBuffer(
    device_dsp: anytype,
    device: vk.Device,
    command_pool: vk.CommandPool,
    level: vk.CommandBufferLevel,
) @TypeOf(device_dsp).AllocateCommandBuffersError!vk.CommandBuffer {
    comptime std.debug.assert(vkutil.isDeviceWrapper(@TypeOf(device_dsp)));

    var result: vk.CommandBuffer = .null_handle;
    try device_dsp.allocateCommandBuffers(device, &vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = level,
        .command_buffer_count = 1,
    }, @ptrCast(*[1]vk.CommandBuffer, &result));

    return result;
}

fn recordImageLayoutTransition(
    device_dsp: anytype,
    cmdbuffer: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    subresource_range: vk.ImageSubresourceRange,
) void {
    var src_stage_mask: vk.PipelineStageFlags = undefined;
    var dst_stage_mask: vk.PipelineStageFlags = undefined;

    var src_access_mask: vk.AccessFlags = undefined;
    var dst_access_mask: vk.AccessFlags = undefined;

    const helper = struct {
        fn invalidTransitionPanic() noreturn {
            @panic("Whoops, invalid image layout transition!\n");
        }
    };
    switch (old_layout) {
        .@"undefined" => switch (new_layout) {
            .transfer_dst_optimal => {
                src_access_mask = .{};
                dst_access_mask = .{ .transfer_write_bit = true };

                src_stage_mask = .{ .top_of_pipe_bit = true };
                dst_stage_mask = .{ .transfer_bit = true };
            },
            else => helper.invalidTransitionPanic(),
        },
        .transfer_dst_optimal => switch (new_layout) {
            .shader_read_only_optimal => {
                src_access_mask = .{ .transfer_write_bit = true };
                dst_access_mask = .{ .shader_read_bit = true };

                src_stage_mask = .{ .transfer_bit = true };
                dst_stage_mask = .{ .fragment_shader_bit = true };
            },
            else => helper.invalidTransitionPanic(),
        },
        else => helper.invalidTransitionPanic(),
    }

    vkutil.cmdPipelineBarrier(
        device_dsp,
        cmdbuffer,
        src_stage_mask,
        dst_stage_mask,
        vk.DependencyFlags{},
        &[_]vk.MemoryBarrier{},
        &[_]vk.BufferMemoryBarrier{},
        &[_]vk.ImageMemoryBarrier{.{
            .src_access_mask = src_access_mask,
            .dst_access_mask = dst_access_mask,

            .old_layout = .@"undefined",
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = subresource_range,
        }},
    );
}

const max_frames_in_flight = 2;
const supported_window_sizes: []const vk.Extent2D = &[_]vk.Extent2D{
    .{ .width = 480, .height = 270 },
    .{ .width = 960, .height = 540 },
    .{ .width = 960, .height = 600 },
    .{ .width = 1600, .height = 800 },
    .{ .width = 1920, .height = 1080 },
    .{ .width = 1920, .height = 1200 },
};

pub usingnamespace struct {
    pub const log = util.file_logger.log;
    pub const log_level: std.log.Level = std.enums.nameCast(std.log.Level, build_options.log_level);
};

pub fn main() !void {
    try util.file_logger.init("vulkan-spincube.log", .{ .stderr_level = .warn });
    defer util.file_logger.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .verbose_log = false,
        .stack_trace_frames = 8,
        .retain_metadata = true,
    }){};
    defer _ = gpa.deinit();

    const allocator: std.mem.Allocator = gpa.allocator();
    stb_img.setAllocator(allocator);

    try glfw.init(.{});
    defer glfw.terminate();

    const UserConfiguredData = struct {
        window_start_size_index: usize,
        desired_vulkan_layers: []const [:0]const u8,
        list_instance_layers_and_exit: bool,
    };
    const cmdline_data: UserConfiguredData = cmdline_data: {
        const CmdLineSpec = struct {
            /// whether to display the help text.
            help: bool = false,
            /// specify window size.
            size: ?usize = null,
            /// specify vulkan layers.
            @"vk-layers": []const u8 = &.{},
            /// list vulkan layers.
            @"vk-list-layers": bool = false,
        };
        const CmdLineDescription = std.EnumArray(std.meta.FieldEnum(CmdLineSpec), []const u8);
        const cmdline_description: CmdLineDescription = CmdLineDescription.init(.{
            .help = "    --help: Displays this message.\n",
            .size = comptime blk: {
                var str: []const u8 = std.fmt.comptimePrint(
                    \\    --size: Sets the window size, accepting an index from 0 to {d}, with a mapping:
                    \\
                ,
                    .{supported_window_sizes.len - 1},
                );
                for (supported_window_sizes) |supported_size, i| {
                    str = str ++ std.fmt.comptimePrint(
                        "        {d}: {d}x{d}\n",
                        .{ i, supported_size.width, supported_size.height },
                    );
                }
                break :blk str;
            },
            .@"vk-list-layers" = "List the available instance layers.",
            .@"vk-layers" = "    --vk-layers: Specify a list of vulkan layer names to use.\n",
        });

        var local_arena_state = std.heap.ArenaAllocator.init(allocator);
        defer local_arena_state.deinit();
        const local_arena = local_arena_state.allocator();

        const cmdline_parse_result = try argsparse.parseForCurrentProcess(CmdLineSpec, local_arena, .silent);
        const cmdline_options: CmdLineSpec = cmdline_parse_result.options;

        if (cmdline_options.help) return {
            const stdout_writer = std.io.getStdOut().writer();

            try stdout_writer.writeAll("Command line options:\n");
            inline for (comptime std.enums.values(CmdLineDescription.Key)) |field| {
                const desc: []const u8 = cmdline_description.get(field);
                try stdout_writer.writeAll(desc);
            }
        };

        const window_start_size_index: usize = window_start_size_index: {
            if (cmdline_options.size) |size| {
                break :window_start_size_index size;
            }
            const primary_monitor = glfw.Monitor.getPrimary() orelse return {
                std.log.err("Failed to query primary monitor size; please specify a size using `--size=[index]`.", .{});
            };
            const work_area = primary_monitor.getWorkarea() catch |err| return {
                std.log.err("Encountered '{}' while attempting to query primary monitor size; plese specify a size using `--size=[index]`.", .{err});
            };
            var i = supported_window_sizes.len;
            while (true) {
                if (i == 0) break;
                i -= 1;
                const supported_size = supported_window_sizes[i];
                if (supported_size.width <= work_area.width and
                    supported_size.height <= work_area.height)
                {
                    break :window_start_size_index i;
                }
            }
            std.log.err("", .{});
            return;
        };
        if (window_start_size_index >= supported_window_sizes.len) {
            std.log.err("Unsupported window size index. Must be in the range [0,{d}).", .{supported_window_sizes.len});
            return;
        }

        const desired_vulkan_layers: []const [:0]const u8 = desired_vulkan_layers: {
            var vk_layers_iter = std.mem.tokenize(u8, cmdline_options.@"vk-layers", ", ");

            const desired_vulkan_layers = try allocator.alloc([:0]const u8, count: {
                var count: usize = 0;
                while (vk_layers_iter.next() != null) count += 1;
                break :count count;
            });
            errdefer allocator.free(desired_vulkan_layers);

            vk_layers_iter.reset();
            for (desired_vulkan_layers) |*name, i| {
                errdefer for (desired_vulkan_layers[0..i]) |prev| allocator.free(prev);
                name.* = try allocator.dupeZ(u8, vk_layers_iter.next().?);
            }
            break :desired_vulkan_layers desired_vulkan_layers;
        };
        errdefer for (desired_vulkan_layers) |name| {
            allocator.free(name);
        } else allocator.free(desired_vulkan_layers);

        break :cmdline_data UserConfiguredData{
            .window_start_size_index = window_start_size_index,
            .desired_vulkan_layers = desired_vulkan_layers,
            .list_instance_layers_and_exit = cmdline_options.@"vk-list-layers",
        };
    };
    defer {
        for (cmdline_data.desired_vulkan_layers) |name| allocator.free(name);
        allocator.free(cmdline_data.desired_vulkan_layers);
    }

    const indices_data: []const u16 = &[_]u16{
        0, 1, 2,
        2, 3, 0,
    };
    const vertices_data: []const Vertex = &[_]Vertex{
        .{ .pos = .{ .x = -0.5, .y = -0.5 }, .color = .{ .r = 1.0, .g = 0.0, .b = 0.0 } },
        .{ .pos = .{ .x = 00.5, .y = -0.5 }, .color = .{ .r = 0.0, .g = 1.0, .b = 0.0 } },
        .{ .pos = .{ .x = 00.5, .y = 00.5 }, .color = .{ .r = 0.0, .g = 0.0, .b = 1.0 } },
        .{ .pos = .{ .x = -0.5, .y = 00.5 }, .color = .{ .r = 1.0, .g = 1.0, .b = 1.0 } },
    };

    const window: glfw.Window = window: {
        const size = supported_window_sizes[cmdline_data.window_start_size_index];
        break :window try glfw.Window.create(size.width, size.height, "vulkan-spincube", null, null, glfw.Window.Hints{
            .client_api = .no_api,
            .resizable = false,
            .visible = false,
        });
    };
    defer window.destroy();

    const WindowData = struct {
        we_are_in_focus: bool = true,
    };
    var window_data: WindowData = .{};
    window.setUserPointer(&window_data);
    defer window.setUserPointer(null);
    window.setFocusCallback(struct {
        fn focusCallback(wnd: glfw.Window, focused: bool) void {
            const p_user_data = wnd.getUserPointer(WindowData).?;
            p_user_data.we_are_in_focus = focused;
        }
    }.focusCallback);

    const debug_messenger_create_info = if (build_options.vk_debug) vk.DebugUtilsMessengerCreateInfoEXT{
        .flags = .{},
        .message_severity = vk.DebugUtilsMessageSeverityFlagsEXT{
            .verbose_bit_ext = true,
            .info_bit_ext = true,
            .warning_bit_ext = true,
            .error_bit_ext = true,
        },
        .message_type = vk.DebugUtilsMessageTypeFlagsEXT{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
        },
        .pfn_user_callback = @as(vk.PfnDebugUtilsMessengerCallbackEXT, vkutil.loggingDebugMessengerCallback),
        .p_user_data = null,
    } else void{};

    const base_dsp = try BaseDispatch.load(getInstanceProcAddress);

    if (cmdline_data.list_instance_layers_and_exit) return {
        var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());

        const available_layers: []const vk.LayerProperties = try vkutil.enumerateInstanceLayerPropertiesAlloc(allocator, base_dsp);
        defer allocator.free(available_layers);

        try stdout.writer().writeAll("Available Instance Layers:\n");
        for (available_layers) |available| {
            try stdout.writer().print("    * {s}\n", .{std.mem.sliceTo(&available.layer_name, 0)});
        }

        try stdout.flush();
    };

    const inst: VulkanInstance = inst: {
        const dsp_min = try InstanceDispatchMin.load(.null_handle, getInstanceProcAddress);

        var local_arena_state = std.heap.ArenaAllocator.init(allocator);
        defer local_arena_state.deinit();
        const local_arena = local_arena_state.allocator();

        const StringZContext = util.ManyPtrContextArrayHashMap([:0]const u8);

        const available_layers: []const vk.LayerProperties = try vkutil.enumerateInstanceLayerPropertiesAlloc(local_arena, base_dsp);
        const desired_layers: []const [:0]const u8 = desired_layers: {
            const DesiredLayersSet = std.ArrayHashMap([:0]const u8, usize, StringZContext, false);
            const Closure = struct {
                p_desired_layers: *DesiredLayersSet,

                fn addDesiredLayerName(closure: @This(), str: [:0]const u8) !void {
                    const gop = try closure.p_desired_layers.getOrPut(str);
                    if (gop.found_existing) {
                        gop.value_ptr.* += 1;
                        std.log.warn("Duplicate desired layer name '{s}' ({d} occurrences).", .{ gop.key_ptr.*, gop.value_ptr.* });
                    } else {
                        gop.value_ptr.* = 1;
                    }
                }
            };

            var desired_layers_set = DesiredLayersSet.init(local_arena);
            const closure: Closure = .{
                .p_desired_layers = &desired_layers_set,
            };

            try desired_layers_set.ensureUnusedCapacity(cmdline_data.desired_vulkan_layers.len);
            for (cmdline_data.desired_vulkan_layers) |layer_name| {
                try closure.addDesiredLayerName(layer_name);
            }

            if (build_options.vk_debug) {
                try closure.addDesiredLayerName("VK_LAYER_KHRONOS_validation");
            }

            break :desired_layers desired_layers_set.keys();
        };
        if (desired_layers.len > available_layers.len) {
            std.log.warn("Requesting {d} instance layers, but only {d} instance layers available.", .{ desired_layers.len, available_layers.len });
        }
        const selected_layers: []const [*:0]const u8 = selected_layers: {
            var selected_layers_set = std.ArrayHashMap([:0]const u8, void, StringZContext, true).init(local_arena);

            try selected_layers_set.ensureUnusedCapacity(desired_layers.len);
            for (desired_layers) |desired_name| {
                for (available_layers) |available_layer| {
                    const available_name: []const u8 = std.mem.sliceTo(&available_layer.layer_name, 0);

                    if (std.mem.eql(u8, available_name, desired_name)) {
                        try selected_layers_set.put(desired_name, {});
                        break;
                    }
                } else {
                    std.log.err("Was unable to find layer with name '{s}'.", .{desired_name});
                }
            }

            const selected_layers = try local_arena.alloc([*:0]const u8, selected_layers_set.count());
            for (selected_layers) |*name, i| name.* = selected_layers_set.keys()[i];
            break :selected_layers selected_layers;
        };

        const available_extensions: []const vk.ExtensionProperties = try vkutil.enumerateInstanceExtensionPropertiesAlloc(local_arena, base_dsp, null);
        const desired_extensions: []const [*:0]const u8 = desired_extensions: {
            var desired_extensions = std.ArrayList([*:0]const u8).init(local_arena);
            errdefer desired_extensions.deinit();

            if (build_options.vk_debug) {
                try desired_extensions.append(vk.extension_info.ext_debug_utils.name);
            }

            if (glfw.getRequiredInstanceExtensions()) |required_glfw_extensions| {
                try desired_extensions.ensureUnusedCapacity(required_glfw_extensions.len);
                for (required_glfw_extensions) |req_glfw_ext| {
                    desired_extensions.appendAssumeCapacity(req_glfw_ext);
                }
            } else |err| {
                std.log.err("Failed to query required GLFW extensions: '{}'.", .{err});
                return;
            }

            break :desired_extensions desired_extensions.toOwnedSlice();
        };
        if (desired_extensions.len > available_extensions.len) {
            std.log.warn("Requesting {d} instance extensions, but only {d} instance extensions available.", .{ desired_extensions.len, available_extensions.len });
        }
        for (desired_extensions) |desired_ext| {
            const desired_ext_name = std.mem.span(desired_ext);
            for (available_extensions) |available_ext| {
                const available_ext_name = std.mem.sliceTo(&available_ext.extension_name, 0);
                if (std.mem.eql(u8, desired_ext_name, available_ext_name)) {
                    break;
                }
            } else {
                std.log.err("Desired extension '{s}' doesn't appear available.", .{std.mem.span(desired_ext)});
                return;
            }
        }

        const handle = try vkutil.createInstance(allocator, base_dsp, vkutil.InstanceCreateInfo{
            .p_next = if (build_options.vk_debug) &debug_messenger_create_info else null,
            .enabled_layer_names = selected_layers,
            .enabled_extension_names = desired_extensions,
        });
        errdefer vkutil.destroyInstance(allocator, dsp_min, handle);

        const dsp = try InstanceDispatch.load(handle, getInstanceProcAddress);
        break :inst VulkanInstance{
            .handle = handle,
            .dsp = dsp,
        };
    };
    defer vkutil.destroyInstance(allocator, inst.dsp, inst.handle);

    const debug_messenger = if (build_options.vk_debug) try vkutil.createDebugUtilsMessengerEXT(
        allocator,
        inst.dsp,
        inst.handle,
        debug_messenger_create_info,
    ) else void{};
    defer if (build_options.vk_debug) vkutil.destroyDebugUtilsMessengerEXT(allocator, inst.dsp, inst.handle, debug_messenger);

    const physical_device: vk.PhysicalDevice = physical_device: {
        const all_physical_devices: []const vk.PhysicalDevice = try vkutil.enumeratePhysicalDevicesAlloc(allocator, inst.dsp, inst.handle);
        defer allocator.free(all_physical_devices);

        const selected_index: usize = switch (all_physical_devices.len) {
            0 => {
                std.log.err("No vulkan physical devices available.", .{});
                return;
            },
            1 => 0,
            else => blk: {
                std.log.warn("TODO: Implement algorithm for selecting between than >={d} physical devices; defaulting to physical device 0.", .{all_physical_devices.len});
                break :blk 0;
            },
        };
        const physical_device: vk.PhysicalDevice = all_physical_devices[selected_index];

        const properties = inst.dsp.getPhysicalDeviceProperties(physical_device);
        std.log.info(
            \\Selected physical device at index {d}:
            \\ * device_name: "{s}"
            \\ * api_version: {}
            \\ * driver_version: {}
            \\ * device_id: {d}
            \\ * vendor_id: {d}
            \\ * device_type: {s}
            \\ * pipeline_cache_uuid: {s}
            \\ * sparse_properties:
            \\   + residency_aligned_mip_size: {}
            \\   + residency_non_resident_strict: {}
            \\   + residency_standard_2d_block_shape: {}
            \\   + residency_standard_2d_multisample_block_shape: {}
            \\   + residency_standard_3d_block_shape: {}
        , .{
            selected_index,
            std.mem.sliceTo(&properties.device_name, 0),
            vkutil.fmtApiVersion(properties.api_version),
            vkutil.fmtApiVersion(properties.driver_version),
            properties.device_id,
            properties.vendor_id,
            @tagName(properties.device_type),
            std.fmt.fmtSliceEscapeUpper(&properties.pipeline_cache_uuid),

            properties.sparse_properties.residency_aligned_mip_size,
            properties.sparse_properties.residency_non_resident_strict,
            properties.sparse_properties.residency_standard_2d_block_shape,
            properties.sparse_properties.residency_standard_2d_multisample_block_shape,
            properties.sparse_properties.residency_standard_3d_block_shape,
        });

        break :physical_device physical_device;
    };
    const physdev_mem_properties = vkutil.getPhysicalDeviceMemoryProperties(inst.dsp, physical_device);

    const window_surface: vk.SurfaceKHR = window_surface: {
        var window_surface: vk.SurfaceKHR = .null_handle;
        const result = try glfw.createWindowSurface(inst.handle, window, @as(?*const vk.AllocationCallbacks, &vkutil.allocCallbacksFrom(&allocator)), &window_surface);
        switch (@intToEnum(vk.Result, result)) {
            .success => {},
            .error_extension_not_present => unreachable,
            .error_native_window_in_use_khr => unreachable,
            .error_initialization_failed => return error.GlfwVulkanInitialisationFailed,
            else => unreachable,
        }
        break :window_surface window_surface;
    };
    defer inst.dsp.destroySurfaceKHR(inst.handle, window_surface, &vkutil.allocCallbacksFrom(&allocator));

    const core_qfi: CoreQueueFamilyIndices = core_qfi: {
        var indices = std.EnumArray(std.meta.FieldEnum(CoreQueueFamilyIndices), ?u32).initFill(null);

        const qfam_properties: []const vk.QueueFamilyProperties = try vkutil.getPhysicalDeviceQueueFamilyPropertiesAlloc(allocator, inst.dsp, physical_device);
        defer allocator.free(qfam_properties);

        for (qfam_properties) |qfam, i| {
            const index = @intCast(u32, i);
            const surface_support = (try inst.dsp.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, window_surface)) == vk.TRUE;
            if (qfam.queue_flags.graphics_bit and surface_support) {
                indices.set(.graphics, index);
                indices.set(.present, index);
                break;
            }
            if (qfam.queue_flags.graphics_bit) {
                if (indices.get(.graphics)) |prev_index| {
                    if (qfam_properties[prev_index].queue_count < qfam.queue_count) {
                        indices.set(.graphics, index);
                    }
                }
            }
            if (surface_support) {
                if (indices.get(.present)) |prev_index| {
                    if (qfam_properties[prev_index].queue_count < qfam.queue_count) {
                        indices.set(.present, index);
                    }
                }
            }
        }

        log_qfamily_indices: {
            std.log.debug("Selected following queue family indices:", .{});
            var iterator = indices.iterator();
            while (iterator.next()) |entry| {
                std.log.debug("  {s}: {}", .{ @tagName(entry.key), entry.value.* });
            }
            break :log_qfamily_indices;
        }

        var result: CoreQueueFamilyIndices = undefined;
        inline for (comptime std.enums.values(std.meta.FieldEnum(CoreQueueFamilyIndices))) |tag| {
            const tag_name = @tagName(tag);
            const title_case = [_]u8{std.ascii.toUpper(tag_name[0])} ++ tag_name[@boolToInt(tag_name.len >= 1)..];
            @field(result, @tagName(tag)) = indices.get(tag) orelse return @field(anyerror, "MissingFamilyQueueIndexFor" ++ title_case);
        }
        break :core_qfi result;
    };

    const device: VulkanDevice = device: {
        var local_arena = std.heap.ArenaAllocator.init(allocator);
        defer local_arena.deinit();

        const queue_create_infos: []const vk.DeviceQueueCreateInfo = queue_create_infos: {
            var queue_create_infos = std.ArrayList(vk.DeviceQueueCreateInfo).init(local_arena.allocator());
            errdefer queue_create_infos.deinit();

            try queue_create_infos.append(.{
                .flags = .{},
                .queue_family_index = core_qfi.graphics,
                .queue_count = 1,
                .p_queue_priorities = &[_]f32{1.0},
            });
            if (core_qfi.graphics != core_qfi.present) {
                try queue_create_infos.append(.{
                    .flags = .{},
                    .queue_family_index = core_qfi.present,
                    .queue_count = 1,
                    .p_queue_priorities = &[_]f32{1.0},
                });
            }

            break :queue_create_infos queue_create_infos.toOwnedSlice();
        };
        defer local_arena.allocator().free(queue_create_infos);

        const desired_extensions: []const [*:0]const u8 = desired_extensions: {
            var desired_extensions = std.ArrayList([*:0]const u8).init(local_arena.allocator());
            errdefer desired_extensions.deinit();

            try desired_extensions.append(vk.extension_info.khr_swapchain.name);

            break :desired_extensions desired_extensions.toOwnedSlice();
        };
        defer local_arena.allocator().free(desired_extensions);

        const dev_dsp_min = try DeviceDispatchMin.load(.null_handle, inst.dsp.dispatch.vkGetDeviceProcAddr);
        const handle = try vkutil.createDevice(allocator, inst.dsp, physical_device, vkutil.DeviceCreateInfo{
            .queue_create_infos = queue_create_infos,
            .enabled_extension_names = desired_extensions,
        });
        errdefer vkutil.destroyDevice(allocator, dev_dsp_min, handle);
        const dsp = try DeviceDispatch.load(handle, inst.dsp.dispatch.vkGetDeviceProcAddr);

        break :device VulkanDevice{
            .handle = handle,
            .dsp = dsp,
        };
    };
    defer vkutil.destroyDevice(allocator, device.dsp, device.handle);

    var surface_formats = std.ArrayList(vk.SurfaceFormatKHR).init(allocator);
    defer surface_formats.deinit();

    var surface_present_modes = std.ArrayList(vk.PresentModeKHR).init(allocator);
    defer surface_present_modes.deinit();

    var swapchain: Swapchain = try Swapchain.create(
        allocator,
        device,
        window_surface,
        try vkutil.getPhysicalDeviceSurfaceFormatsKHRArrayList(&surface_formats, inst.dsp, physical_device, window_surface),
        try vkutil.getPhysicalDeviceSurfacePresentModesKHRArrayList(&surface_present_modes, inst.dsp, physical_device, window_surface),
        try inst.dsp.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, window_surface),
        core_qfi,
        framebuffer_size: {
            const fb_size = try window.getFramebufferSize();
            break :framebuffer_size vk.Extent2D{
                .width = fb_size.width,
                .height = fb_size.height,
            };
        },
    );
    defer swapchain.destroy(allocator, device);

    // NOTE: This currently causes a leak on my laptop, and it seems to be because the implementation is ignoring the
    // provided AllocationCallbacks.
    // TODO: Look into filing a bug report on this or something
    const graphics_descriptor_set_layout: vk.DescriptorSetLayout = try vkutil.createDescriptorSetLayout(
        allocator,
        device.dsp,
        device.handle,
        vkutil.DescriptorSetLayoutCreateInfo{
            .bindings = &[_]vk.DescriptorSetLayoutBinding{
                UniformBufferObject.descriptorSetLayoutBinding(0),
            },
        },
    );
    defer vkutil.destroyDescriptorSetLayout(
        allocator,
        device.dsp,
        device.handle,
        graphics_descriptor_set_layout,
    );

    const graphics_pipeline_layout: vk.PipelineLayout = try vkutil.createPipelineLayout(
        allocator,
        device.dsp,
        device.handle,
        vkutil.PipelineLayoutCreateInfo{
            .set_layouts = &[_]vk.DescriptorSetLayout{graphics_descriptor_set_layout},
            .push_constant_ranges = &[_]vk.PushConstantRange{},
        },
    );
    defer vkutil.destroyPipelineLayout(allocator, device.dsp, device.handle, graphics_pipeline_layout);

    const graphics_render_pass: vk.RenderPass = graphics_render_pass: {
        const attachments = [_]vk.AttachmentDescription{
            .{
                .flags = .{},
                .format = swapchain.details.format.format,
                .samples = vk.SampleCountFlags{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .@"undefined",
                .final_layout = .present_src_khr,
            },
        };

        const input_attachment_refs: []const vk.AttachmentReference = &.{};
        const color_attachment_refs: []const vk.AttachmentReference = &[_]vk.AttachmentReference{.{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        }};
        const preserve_attachment_refs: []const u32 = &.{};

        const subpasses = [_]vk.SubpassDescription{
            .{
                .flags = .{},
                .pipeline_bind_point = .graphics,
                //
                .input_attachment_count = @intCast(u32, input_attachment_refs.len),
                .p_input_attachments = input_attachment_refs.ptr,
                //
                .color_attachment_count = @intCast(u32, color_attachment_refs.len),
                .p_color_attachments = color_attachment_refs.ptr,
                //
                .p_resolve_attachments = null,
                .p_depth_stencil_attachment = null,
                //
                .preserve_attachment_count = @intCast(u32, preserve_attachment_refs.len),
                .p_preserve_attachments = preserve_attachment_refs.ptr,
            },
        };
        const subpass_dependencies: []const vk.SubpassDependency = &[_]vk.SubpassDependency{
            .{ // image acquisition subpass dependency
                .src_subpass = vk.SUBPASS_EXTERNAL,
                .dst_subpass = 0,
                //
                .src_stage_mask = vk.PipelineStageFlags{ .color_attachment_output_bit = true },
                .dst_stage_mask = vk.PipelineStageFlags{ .color_attachment_output_bit = true },
                //
                .src_access_mask = vk.AccessFlags{},
                .dst_access_mask = vk.AccessFlags{ .color_attachment_write_bit = true },
                //
                .dependency_flags = vk.DependencyFlags{},
            },
        };

        break :graphics_render_pass try device.dsp.createRenderPass(
            device.handle,
            &vk.RenderPassCreateInfo{
                .flags = .{},

                .attachment_count = @intCast(u32, attachments.len),
                .p_attachments = &attachments,

                .subpass_count = @intCast(u32, subpasses.len),
                .p_subpasses = &subpasses,

                .dependency_count = @intCast(u32, subpass_dependencies.len),
                .p_dependencies = subpass_dependencies.ptr,
            },
            &vkutil.allocCallbacksFrom(&allocator),
        );
    };
    defer device.dsp.destroyRenderPass(device.handle, graphics_render_pass, &vkutil.allocCallbacksFrom(&allocator));

    const graphics_pipeline: vk.Pipeline = graphics_pipeline: {
        const vk_allocator: ?*const vk.AllocationCallbacks = &vkutil.allocCallbacksFrom(&allocator);

        const vert_shader_module: vk.ShaderModule = try device.dsp.createShaderModule(device.handle, &vk.ShaderModuleCreateInfo{
            .flags = .{},
            .code_size = shader_bytecode.vert.len,
            .p_code = @ptrCast([*]const u32, shader_bytecode.vert),
        }, vk_allocator);
        defer device.dsp.destroyShaderModule(device.handle, vert_shader_module, vk_allocator);

        const frag_shader_module: vk.ShaderModule = try device.dsp.createShaderModule(device.handle, &vk.ShaderModuleCreateInfo{
            .flags = .{},
            .code_size = shader_bytecode.frag.len,
            .p_code = @ptrCast([*]const u32, shader_bytecode.frag),
        }, vk_allocator);
        defer device.dsp.destroyShaderModule(device.handle, frag_shader_module, vk_allocator);

        const shader_stage_create_infos = [_]vk.PipelineShaderStageCreateInfo{
            .{ // vert stage
                .flags = .{},
                .stage = vk.ShaderStageFlags{ .vertex_bit = true },
                .module = vert_shader_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .{ // frag stage
                .flags = .{},
                .stage = vk.ShaderStageFlags{ .fragment_bit = true },
                .module = frag_shader_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
        };

        const viewports = [_]vk.Viewport{
            .{
                .x = 0.0,
                .y = 0.0,
                .width = @intToFloat(f32, swapchain.details.extent.width),
                .height = @intToFloat(f32, swapchain.details.extent.height),
                .min_depth = 0.0,
                .max_depth = 0.0,
            },
        };

        const scissors = [_]vk.Rect2D{
            .{
                .offset = vk.Offset2D{ .x = 0, .y = 0 },
                .extent = swapchain.details.extent,
            },
        };

        const rasterization_state_create_info: vk.PipelineRasterizationStateCreateInfo = .{
            .flags = .{},
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .cull_mode = vk.CullModeFlags{ .back_bit = true },
            .front_face = .clockwise,
            .depth_bias_enable = vk.FALSE,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
            .line_width = 1.0,
        };

        const multisample_state_create_info: vk.PipelineMultisampleStateCreateInfo = .{
            .flags = .{},
            .rasterization_samples = vk.SampleCountFlags{ .@"1_bit" = true },
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 1.0,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        };

        const color_blend_attachment_states = [_]vk.PipelineColorBlendAttachmentState{
            .{
                .blend_enable = vk.FALSE,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .zero,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = vk.ColorComponentFlags{
                    .r_bit = true,
                    .g_bit = true,
                    .b_bit = true,
                    .a_bit = true,
                },
            },
        };

        const color_blend_state_create_info: vk.PipelineColorBlendStateCreateInfo = .{
            .flags = .{},
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .attachment_count = @intCast(u32, color_blend_attachment_states.len),
            .p_attachments = &color_blend_attachment_states,
            .blend_constants = [1]f32{0.0} ** 4,
        };

        const dynamic_states: []const vk.DynamicState = &[_]vk.DynamicState{
            .viewport,
            .scissor,
        };

        const vertex_binding_descriptions = [_]vk.VertexInputBindingDescription{
            Vertex.bindingDescription(0),
        };
        const vertex_attribute_descriptions = [_]vk.VertexInputAttributeDescription{
            Vertex.attributeDescription(0, .pos),
            Vertex.attributeDescription(0, .color),
        };
        const graphics_pipeline_create_info = vk.GraphicsPipelineCreateInfo{
            .flags = vk.PipelineCreateFlags{},

            .stage_count = @intCast(u32, shader_stage_create_infos.len),
            .p_stages = &shader_stage_create_infos,

            .p_vertex_input_state = &vk.PipelineVertexInputStateCreateInfo{
                .flags = .{},

                .vertex_binding_description_count = @intCast(u32, vertex_binding_descriptions.len),
                .p_vertex_binding_descriptions = &vertex_binding_descriptions,

                .vertex_attribute_description_count = @intCast(u32, vertex_attribute_descriptions.len),
                .p_vertex_attribute_descriptions = &vertex_attribute_descriptions,
            },
            .p_input_assembly_state = &vk.PipelineInputAssemblyStateCreateInfo{
                .flags = .{},
                .topology = vk.PrimitiveTopology.triangle_list,
                .primitive_restart_enable = vk.FALSE,
            },
            .p_tessellation_state = null,
            .p_viewport_state = &vk.PipelineViewportStateCreateInfo{
                .flags = .{},

                .viewport_count = @intCast(u32, viewports.len),
                .p_viewports = &viewports,

                .scissor_count = @intCast(u32, scissors.len),
                .p_scissors = &scissors,
            },
            .p_rasterization_state = &rasterization_state_create_info,
            .p_multisample_state = &multisample_state_create_info,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blend_state_create_info,
            .p_dynamic_state = &vk.PipelineDynamicStateCreateInfo{
                .flags = .{},
                .dynamic_state_count = @intCast(u32, dynamic_states.len),
                .p_dynamic_states = dynamic_states.ptr,
            },

            .layout = graphics_pipeline_layout,
            .render_pass = graphics_render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        var pipeline: vk.Pipeline = undefined;
        if (device.dsp.createGraphicsPipelines(
            device.handle,
            .null_handle,
            @intCast(u32, 1),
            &[_]vk.GraphicsPipelineCreateInfo{graphics_pipeline_create_info},
            vk_allocator,
            @ptrCast(*[1]vk.Pipeline, &pipeline),
        )) |result| switch (result) {
            .success => {},
            .pipeline_compile_required => unreachable, // ?
            else => unreachable,
        } else |err| return err;

        break :graphics_pipeline pipeline;
    };
    defer device.dsp.destroyPipeline(device.handle, graphics_pipeline, &vkutil.allocCallbacksFrom(&allocator));

    var swapchain_framebuffers: std.ArrayList(vk.Framebuffer) = swapchain_framebuffers: {
        var swapchain_framebuffers = std.ArrayList(vk.Framebuffer).init(allocator);

        try swapchain_framebuffers.resize(swapchain.images.len);
        try swapchain.populateFramebuffers(allocator, device, graphics_render_pass, swapchain_framebuffers.items);

        break :swapchain_framebuffers swapchain_framebuffers;
    };
    defer {
        for (swapchain_framebuffers.items) |fb| {
            device.dsp.destroyFramebuffer(device.handle, fb, &vkutil.allocCallbacksFrom(&allocator));
        }
        swapchain_framebuffers.deinit();
    }

    const drawing_cmdpool: vk.CommandPool = try device.dsp.createCommandPool(device.handle, &vk.CommandPoolCreateInfo{
        .flags = vk.CommandPoolCreateFlags{ .reset_command_buffer_bit = true },
        .queue_family_index = core_qfi.graphics,
    }, &vkutil.allocCallbacksFrom(&allocator));
    defer device.dsp.destroyCommandPool(device.handle, drawing_cmdpool, &vkutil.allocCallbacksFrom(&allocator));

    const copying_cmdpool: vk.CommandPool = try device.dsp.createCommandPool(device.handle, &vk.CommandPoolCreateInfo{
        .flags = vk.CommandPoolCreateFlags{ .transient_bit = true },
        .queue_family_index = core_qfi.graphics,
    }, &vkutil.allocCallbacksFrom(&allocator));
    defer device.dsp.destroyCommandPool(device.handle, copying_cmdpool, &vkutil.allocCallbacksFrom(&allocator));

    const graphics_descriptor_pool: vk.DescriptorPool = try vkutil.createDescriptorPool(allocator, device.dsp, device.handle, vkutil.DescriptorPoolCreateInfo{
        .flags = vk.DescriptorPoolCreateFlags{
            // so we don't have to manually call `freeDescriptorSets`.
            .free_descriptor_set_bit = false,
        },
        .max_sets = max_frames_in_flight,
        .pool_sizes = &[_]vk.DescriptorPoolSize{.{
            .type = .uniform_buffer,
            .descriptor_count = max_frames_in_flight,
        }},
    });
    defer vkutil.destroyDescriptorPool(allocator, device.dsp, device.handle, graphics_descriptor_pool);

    const SyncronizedFrame = struct {
        cmdbuffer: vk.CommandBuffer,
        in_flight: vk.Fence,
        image_available: vk.Semaphore,
        render_finished: vk.Semaphore,
        descriptor_set: vk.DescriptorSet,
    };
    const syncronized_frames: std.MultiArrayList(SyncronizedFrame).Slice = syncronized_frames: {
        const syncronized_frames: std.MultiArrayList(SyncronizedFrame).Slice = blk: {
            var syncronized_frames = std.MultiArrayList(SyncronizedFrame){};
            try syncronized_frames.resize(allocator, max_frames_in_flight);
            break :blk syncronized_frames.toOwnedSlice();
        };
        errdefer {
            var copy = syncronized_frames;
            copy.deinit(allocator);
        }

        try device.dsp.allocateCommandBuffers(device.handle, &vk.CommandBufferAllocateInfo{
            .command_pool = drawing_cmdpool,
            .level = .primary,
            .command_buffer_count = @intCast(u32, syncronized_frames.len),
        }, syncronized_frames.items(.cmdbuffer).ptr);
        errdefer device.dsp.freeCommandBuffers(
            device.handle,
            drawing_cmdpool,
            @intCast(u32, syncronized_frames.len),
            syncronized_frames.items(.cmdbuffer).ptr,
        );

        const in_flight_fences = syncronized_frames.items(.in_flight);
        for (in_flight_fences) |*fence, i| {
            errdefer for (in_flight_fences[0..i]) |prev| {
                device.dsp.destroyFence(device.handle, prev, &vkutil.allocCallbacksFrom(&allocator));
            };

            fence.* = try device.dsp.createFence(
                device.handle,
                &vk.FenceCreateInfo{ .flags = vk.FenceCreateFlags{ .signaled_bit = true } },
                &vkutil.allocCallbacksFrom(&allocator),
            );
        }
        errdefer for (in_flight_fences) |fence| {
            device.dsp.destroyFence(device.handle, fence, &vkutil.allocCallbacksFrom(&allocator));
        };

        const closure: struct {
            a: *const std.mem.Allocator,
            dev: *const VulkanDevice,

            fn initSemaphores(closure: @This(), semaphores: []vk.Semaphore) !void {
                for (semaphores) |*sem, i| {
                    errdefer closure.deinitSemaphores(semaphores[0..i]);

                    sem.* = try closure.dev.dsp.createSemaphore(
                        closure.dev.handle,
                        &vk.SemaphoreCreateInfo{ .flags = .{} },
                        &vkutil.allocCallbacksFrom(closure.a),
                    );
                }
            }

            fn deinitSemaphores(closure: @This(), semaphores: []const vk.Semaphore) void {
                for (semaphores) |sem| {
                    closure.dev.dsp.destroySemaphore(closure.dev.handle, sem, &vkutil.allocCallbacksFrom(closure.a));
                }
            }
        } = .{ .a = &allocator, .dev = &device };

        const image_available_sems = syncronized_frames.items(.image_available);
        try closure.initSemaphores(image_available_sems);
        errdefer closure.deinitSemaphores(image_available_sems);

        const render_finished_sems = syncronized_frames.items(.render_finished);
        try closure.initSemaphores(render_finished_sems);
        errdefer closure.deinitSemaphores(render_finished_sems);

        try vkutil.allocateDescriptorSets(device.dsp, device.handle, vkutil.DescriptorSetAllocateInfo{
            .descriptor_pool = graphics_descriptor_pool,
            .set_layouts = &set_layouts: {
                var set_layouts = [_]vk.DescriptorSetLayout{.null_handle} ** max_frames_in_flight;
                std.mem.set(vk.DescriptorSetLayout, &set_layouts, graphics_descriptor_set_layout);
                break :set_layouts set_layouts;
            },
        }, syncronized_frames.items(.descriptor_set));
        // NOTE: here would be the errdefer'd call to `freeDescriptorSets`, but it's not allowed
        // when not setting the `free_descriptor_set_bit` flag in the creation of the
        // associated descriptor pool.
        // vkutil.freeDescriptorSets(device.dsp, device.handle, graphics_descriptor_pool, syncronized_frames.items(.descriptor_set)) catch |err| {
        //     std.log.err("freeDescriptorSets: {s}", .{@errorName(err)});
        // };

        break :syncronized_frames syncronized_frames;
    };
    defer {
        // NOTE: here would be the call to `freeDescriptorSets`, but it's not allowed
        // when not setting the `free_descriptor_set_bit` flag in the creation of the
        // associated descriptor pool.
        // vkutil.freeDescriptorSets(device.dsp, device.handle, graphics_descriptor_pool, syncronized_frames.items(.descriptor_set)) catch |err| {
        //     std.log.err("freeDescriptorSets: {s}", .{@errorName(err)});
        // };

        inline for (.{ .render_finished, .image_available }) |field| {
            for (syncronized_frames.items(field)) |sem| {
                device.dsp.destroySemaphore(device.handle, sem, &vkutil.allocCallbacksFrom(&allocator));
            }
        }

        for (syncronized_frames.items(.in_flight)) |fence| {
            device.dsp.destroyFence(device.handle, fence, &vkutil.allocCallbacksFrom(&allocator));
        }

        device.dsp.freeCommandBuffers(device.handle, drawing_cmdpool, @intCast(u32, syncronized_frames.len), syncronized_frames.items(.cmdbuffer).ptr);

        var copy = syncronized_frames;
        copy.deinit(allocator);
    }

    const uniform_buffer_segment_len: usize = @sizeOf(UniformBufferObject);
    const uniform_buffer_total_len: usize = uniform_buffer_segment_len * max_frames_in_flight;
    const uniform_buffer: vk.Buffer = try device.createBuffer(allocator, vkutil.BufferCreateInfo{
        .size = uniform_buffer_total_len,
        .usage = vk.BufferUsageFlags{
            .uniform_buffer_bit = true,
        },
        .sharing_mode = .exclusive,
        .queue_family_indices = &.{},
    });
    defer device.destroyBuffer(allocator, uniform_buffer);

    const uniform_buffers_mem: vk.DeviceMemory = uniform_buffers_mem: {
        const requirements: vk.MemoryRequirements = device.dsp.getBufferMemoryRequirements(device.handle, uniform_buffer);
        break :uniform_buffers_mem try device.allocateMemory(allocator, vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = selectMemoryType(
                physdev_mem_properties,
                requirements,
                vk.MemoryPropertyFlags{
                    .host_visible_bit = true,
                    .host_coherent_bit = true,
                },
            ) orelse return error.NoSuitableMemoryTypesOnSelectedPhysicalDevice,
        });
    };
    defer device.freeMemory(allocator, uniform_buffers_mem);

    try device.bindBufferMemory(uniform_buffer, uniform_buffers_mem, 0);

    init_ubo_buff_and_descriptor_sets: {
        const descriptor_sets: []const vk.DescriptorSet = syncronized_frames.items(.descriptor_set);

        {
            var i: usize = 0;
            while (i < max_frames_in_flight) : (i += 1) {
                const descriptor_write = [_]vk.WriteDescriptorSet{.{
                    .dst_set = descriptor_sets[i],
                    .dst_binding = 0,
                    .dst_array_element = 0,
                    .descriptor_type = .uniform_buffer,
                    .descriptor_count = 1,
                    .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{
                        .buffer = uniform_buffer,
                        .offset = uniform_buffer_segment_len * i,
                        .range = uniform_buffer_segment_len,
                    }},
                    .p_image_info = util.emptySlice(vk.DescriptorImageInfo).ptr,
                    .p_texel_buffer_view = util.emptySlice(vk.BufferView).ptr,
                }};
                vkutil.updateDescriptorSets(device.dsp, device.handle, &descriptor_write, util.emptySlice(vk.CopyDescriptorSet));
            }
        }

        break :init_ubo_buff_and_descriptor_sets;
    }

    const texture_embed = resources.texture;
    const texture_info = try stb_img.infoFromMemory(texture_embed);

    const texture_extent = vk.Extent3D{
        .width = @intCast(u32, texture_info.x),
        .height = @intCast(u32, texture_info.y),
        .depth = 1,
    };
    const texture_image: vk.Image = try device.dsp.createImage(device.handle, &vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = .r8g8b8a8_srgb,
        .extent = texture_extent,
        .mip_levels = 1,
        .array_layers = 1,
        .samples = vk.SampleCountFlags{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = vk.ImageUsageFlags{
            .transfer_dst_bit = true,
            .sampled_bit = true,
        },

        .sharing_mode = .exclusive,

        .queue_family_index_count = 0,
        .p_queue_family_indices = util.emptySlice(u32).ptr,

        .initial_layout = .@"undefined",
    }, &vkutil.allocCallbacksFrom(&allocator));
    defer device.dsp.destroyImage(device.handle, texture_image, &vkutil.allocCallbacksFrom(&allocator));

    const texture_memory: vk.DeviceMemory = texture_memory: {
        const requirements = device.dsp.getImageMemoryRequirements(device.handle, texture_image);
        break :texture_memory try device.allocateMemory(allocator, vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = selectMemoryType(physdev_mem_properties, requirements, vk.MemoryPropertyFlags{
                .device_local_bit = true,
            }) orelse return error.NoSuitableMemoryTypes,
        });
    };
    defer device.freeMemory(allocator, texture_memory);

    const texture_image_view: vk.ImageView = try vkutil.createImageView(allocator, device.dsp, device.handle, vk.ImageViewCreateInfo{
        .flags = vk.ImageViewCreateFlags{},
        .image = texture_image,
        .view_type = .@"2d",
        .format = .r8g8b8a8_srgb,
        .components = vk.ComponentMapping{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    });
    defer vkutil.destroyImageView(allocator, device.dsp, device.handle, texture_image_view);

    try device.dsp.bindImageMemory(device.handle, texture_image, texture_memory, 0);

    init_texture_memory: {
        const texture_data: stb_img.Image = stb_img.loadFromMemory(texture_embed, .rgb_alpha) orelse return error.FailedToLoadImageFromMemory;
        defer stb_img.imageFree(texture_data.bytes);

        const image_size = @intCast(vk.DeviceSize, texture_data.x) *
            @intCast(vk.DeviceSize, texture_data.y) *
            @intCast(vk.DeviceSize, texture_data.channels);
        const staging_buffer: vk.Buffer = try device.createBuffer(allocator, vkutil.BufferCreateInfo{
            .size = device.dsp.getImageMemoryRequirements(device.handle, texture_image).size,
            .usage = vk.BufferUsageFlags{
                .transfer_src_bit = true,
            },
            .sharing_mode = .exclusive,
            .queue_family_indices = &.{},
        });
        defer device.destroyBuffer(allocator, staging_buffer);

        const staging_buf_req = device.dsp.getBufferMemoryRequirements(device.handle, staging_buffer);
        const staging_buffer_mem: vk.DeviceMemory = try device.allocateMemory(allocator, vk.MemoryAllocateInfo{
            .allocation_size = staging_buf_req.size,
            .memory_type_index = selectMemoryType(physdev_mem_properties, staging_buf_req, vk.MemoryPropertyFlags{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            }) orelse return error.NoSuitableMemoryTypes,
        });
        defer device.freeMemory(allocator, staging_buffer_mem);

        try device.bindBufferMemory(staging_buffer, staging_buffer_mem, 0);

        init_staging_buff_data: {
            const mapped_memory = @ptrCast([*]u8, (try device.dsp.mapMemory(
                device.handle,
                staging_buffer_mem,
                0,
                image_size,
                .{},
            )).?);
            defer device.dsp.unmapMemory(device.handle, staging_buffer_mem);

            @memcpy(mapped_memory, texture_data.bytes, image_size);
            break :init_staging_buff_data;
        }

        const copy_cmdbuffer = try allocOneCommandBuffer(device.dsp, device.handle, copying_cmdpool, .primary);
        defer device.dsp.freeCommandBuffers(device.handle, copying_cmdpool, 1, @ptrCast(*const [1]vk.CommandBuffer, &copy_cmdbuffer));

        record_copy_cmdbuffer: {
            try device.dsp.beginCommandBuffer(copy_cmdbuffer, &vk.CommandBufferBeginInfo{
                .flags = vk.CommandBufferUsageFlags{ .one_time_submit_bit = true },
                .p_inheritance_info = null,
            });

            recordImageLayoutTransition(
                device.dsp,
                copy_cmdbuffer,
                texture_image,
                .@"undefined",
                .transfer_dst_optimal,
                vk.ImageSubresourceRange{
                    .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            );

            device.dsp.cmdCopyBufferToImage(copy_cmdbuffer, staging_buffer, texture_image, .transfer_dst_optimal, 1, &[_]vk.BufferImageCopy{.{
                .buffer_offset = 0,
                .buffer_row_length = 0,
                .buffer_image_height = 0,

                .image_subresource = vk.ImageSubresourceLayers{
                    .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },

                .image_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
                .image_extent = texture_extent,
            }});

            recordImageLayoutTransition(
                device.dsp,
                copy_cmdbuffer,
                texture_image,
                .transfer_dst_optimal,
                .shader_read_only_optimal,
                vk.ImageSubresourceRange{
                    .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            );

            try device.dsp.endCommandBuffer(copy_cmdbuffer);
            break :record_copy_cmdbuffer;
        }

        try device.dsp.queueSubmit(device.dsp.getDeviceQueue(device.handle, core_qfi.graphics, 0), 1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = @intCast(u32, 0),
            .p_wait_semaphores = util.emptySlice(vk.Semaphore).ptr,
            .p_wait_dst_stage_mask = util.emptySlice(vk.PipelineStageFlags).ptr,

            .command_buffer_count = 1,
            .p_command_buffers = &[_]vk.CommandBuffer{copy_cmdbuffer},

            .signal_semaphore_count = @intCast(u32, 0),
            .p_signal_semaphores = util.emptySlice(vk.Semaphore).ptr,
        }}, .null_handle);
        try device.dsp.queueWaitIdle(device.dsp.getDeviceQueue(device.handle, core_qfi.graphics, 0));

        break :init_texture_memory;
    }

    const vertices_buffer_len: usize = vertices_data.len * @sizeOf(Vertex);
    const vertices_buffer: vk.Buffer = try device.createBuffer(allocator, vkutil.BufferCreateInfo{
        .size = vertices_buffer_len,
        .usage = vk.BufferUsageFlags{
            .vertex_buffer_bit = true,
            .transfer_dst_bit = true,
        },
        .sharing_mode = .exclusive,
        .queue_family_indices = &.{},
    });
    defer device.destroyBuffer(allocator, vertices_buffer);

    const index_buffer_len: usize = indices_data.len * @sizeOf(u16);
    const index_buffer: vk.Buffer = try device.createBuffer(allocator, vkutil.BufferCreateInfo{
        .size = index_buffer_len,
        .usage = vk.BufferUsageFlags{
            .index_buffer_bit = true,
            .transfer_dst_bit = true,
        },
        .sharing_mode = .exclusive,
        .queue_family_indices = &.{},
    });
    defer device.destroyBuffer(allocator, index_buffer);

    const vert_buff_mem_req = device.dsp.getBufferMemoryRequirements(device.handle, vertices_buffer);
    const indices_buff_mem_req = device.dsp.getBufferMemoryRequirements(device.handle, index_buffer);

    const vertices_and_indices_mem: vk.DeviceMemory = vertices_and_indices_mem: {
        const combined_requirements = combinedMemoryRequirements(
            vert_buff_mem_req,
            indices_buff_mem_req,
        );

        const memtype_index: u32 = selectMemoryType(
            physdev_mem_properties,
            combined_requirements,
            vk.MemoryPropertyFlags{
                .device_local_bit = true,
            },
        ) orelse return error.NoSuitableMemoryTypesOnSelectedPhysicalDevice;

        break :vertices_and_indices_mem try device.allocateMemory(allocator, vk.MemoryAllocateInfo{
            .allocation_size = combined_requirements.size,
            .memory_type_index = memtype_index,
        });
    };
    defer device.freeMemory(allocator, vertices_and_indices_mem);

    try device.bindBufferMemory(vertices_buffer, vertices_and_indices_mem, 0);
    try device.bindBufferMemory(index_buffer, vertices_and_indices_mem, vert_buff_mem_req.size);

    init_vertices_and_indices_buffers: {
        const staging_buffer: vk.Buffer = try device.createBuffer(allocator, vkutil.BufferCreateInfo{
            .size = vertices_buffer_len + index_buffer_len,
            .usage = vk.BufferUsageFlags{
                .vertex_buffer_bit = true,
                .index_buffer_bit = true,
                .transfer_src_bit = true,
            },
            .sharing_mode = .exclusive,
            .queue_family_indices = &.{},
        });
        defer device.destroyBuffer(allocator, staging_buffer);

        const staging_buff_mem_req = device.dsp.getBufferMemoryRequirements(device.handle, staging_buffer);

        const staging_buff_mem: vk.DeviceMemory = try device.allocateMemory(allocator, vk.MemoryAllocateInfo{
            .allocation_size = staging_buff_mem_req.size,
            .memory_type_index = selectMemoryType(
                physdev_mem_properties,
                staging_buff_mem_req,
                vk.MemoryPropertyFlags{
                    .host_visible_bit = true,
                    .host_coherent_bit = true,
                },
            ) orelse return error.NoSuitableMemoryTypesOnSelectedPhysicalDevice,
        });
        defer device.freeMemory(allocator, staging_buff_mem);

        try device.bindBufferMemory(staging_buffer, staging_buff_mem, 0);

        init_staging_buffer: {
            const mapped_memory = @ptrCast([*]u8, (try device.dsp.mapMemory(device.handle, staging_buff_mem, 0, staging_buff_mem_req.size, .{})).?);
            defer device.dsp.unmapMemory(device.handle, staging_buff_mem);

            @memcpy(
                mapped_memory,
                @ptrCast([*]const u8, vertices_data),
                vertices_buffer_len,
            );
            @memcpy(
                mapped_memory + vertices_buffer_len,
                @ptrCast([*]const u8, indices_data),
                index_buffer_len,
            );

            break :init_staging_buffer;
        }

        const copy_cmdbuffer = try allocOneCommandBuffer(device.dsp, device.handle, copying_cmdpool, .primary);
        defer device.dsp.freeCommandBuffers(device.handle, copying_cmdpool, 1, @ptrCast(*const [1]vk.CommandBuffer, &copy_cmdbuffer));

        record_copy_cmdbuffer: {
            try device.dsp.beginCommandBuffer(copy_cmdbuffer, &vk.CommandBufferBeginInfo{
                .flags = vk.CommandBufferUsageFlags{ .one_time_submit_bit = true },
                .p_inheritance_info = null,
            });

            device.dsp.cmdCopyBuffer(copy_cmdbuffer, staging_buffer, vertices_buffer, 1, &[_]vk.BufferCopy{.{
                .src_offset = 0,
                .dst_offset = 0,
                .size = vertices_buffer_len,
            }});
            device.dsp.cmdCopyBuffer(copy_cmdbuffer, staging_buffer, index_buffer, 1, &[_]vk.BufferCopy{.{
                .src_offset = vertices_buffer_len,
                .dst_offset = 0,
                .size = index_buffer_len,
            }});

            try device.dsp.endCommandBuffer(copy_cmdbuffer);
            break :record_copy_cmdbuffer;
        }

        try device.dsp.queueSubmit(device.dsp.getDeviceQueue(device.handle, core_qfi.graphics, 0), 1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = @intCast(u32, 0),
            .p_wait_semaphores = util.emptySlice(vk.Semaphore).ptr,
            .p_wait_dst_stage_mask = util.emptySlice(vk.PipelineStageFlags).ptr,

            .command_buffer_count = 1,
            .p_command_buffers = &[_]vk.CommandBuffer{copy_cmdbuffer},

            .signal_semaphore_count = @intCast(u32, 0),
            .p_signal_semaphores = util.emptySlice(vk.Semaphore).ptr,
        }}, .null_handle);
        try device.dsp.queueWaitIdle(device.dsp.getDeviceQueue(device.handle, core_qfi.graphics, 0));

        break :init_vertices_and_indices_buffers;
    }

    const in_flight_slice: []const vk.Fence = syncronized_frames.items(.in_flight);
    const image_available_slice: []const vk.Semaphore = syncronized_frames.items(.image_available);
    const render_finished_slice: []const vk.Semaphore = syncronized_frames.items(.render_finished);
    const cmdbuffer_slice: []const vk.CommandBuffer = syncronized_frames.items(.cmdbuffer);
    const descriptor_set_slice: []const vk.DescriptorSet = syncronized_frames.items(.descriptor_set);

    var current_frame: u32 = 0;
    defer device.dsp.deviceWaitIdle(device.handle) catch |err| std.log.err("deviceWaitIdle: {s}", .{@errorName(err)});

    var frame_timer = try std.time.Timer.start();
    var ubo_timer = std.time.Timer.start() catch unreachable;
    const ubo_start_time: u64 = ubo_timer.read();

    const uniform_buffer_mapped_memory = @ptrCast([*]u8, (try device.dsp.mapMemory(
        device.handle,
        uniform_buffers_mem,
        0,
        uniform_buffer_total_len,
        .{},
    )).?)[0..uniform_buffer_total_len];
    defer device.dsp.unmapMemory(device.handle, uniform_buffers_mem);

    var frames_per_second: u8 = 60;

    try window.show();
    mainloop: while (!window.shouldClose()) {
        try glfw.pollEvents();
        if (!window_data.we_are_in_focus) continue;

        if (frame_timer.read() < (1000 * std.time.ns_per_ms) / @as(u64, frames_per_second)) {
            continue :mainloop;
        } else frame_timer.reset();

        handle_framebuffer_resizes: {
            const fbsize: vk.Extent2D = fbsize: {
                const fbsize = try window.getFramebufferSize();
                break :fbsize vk.Extent2D{
                    .width = fbsize.width,
                    .height = fbsize.height,
                };
            };
            if (fbsize.width == 0 or fbsize.height == 0) continue;
            if (fbsize.width != swapchain.details.extent.width or
                fbsize.height != swapchain.details.extent.height)
            {
                const capabilities = try inst.dsp.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, window_surface);
                const formats = try vkutil.getPhysicalDeviceSurfaceFormatsKHRArrayList(&surface_formats, inst.dsp, physical_device, window_surface);
                const present_modes = try vkutil.getPhysicalDeviceSurfacePresentModesKHRArrayList(&surface_present_modes, inst.dsp, physical_device, window_surface);

                try swapchain.recreate(allocator, device, window_surface, formats, present_modes, capabilities, core_qfi, fbsize);
                for (swapchain_framebuffers.items) |fb| {
                    device.dsp.destroyFramebuffer(device.handle, fb, &vkutil.allocCallbacksFrom(&allocator));
                }
                try swapchain_framebuffers.resize(swapchain.images.len);
                try swapchain.populateFramebuffers(allocator, device, graphics_render_pass, swapchain_framebuffers.items);
            }

            break :handle_framebuffer_resizes;
        }

        draw_frame: {
            const in_flight: vk.Fence = in_flight_slice[current_frame];
            const image_available: vk.Semaphore = image_available_slice[current_frame];
            const render_finished: vk.Semaphore = render_finished_slice[current_frame];
            const cmdbuffer: vk.CommandBuffer = cmdbuffer_slice[current_frame];
            const descriptor_set: vk.DescriptorSet = descriptor_set_slice[current_frame];
            current_frame = (current_frame + 1) % max_frames_in_flight;

            if (device.dsp.waitForFences(device.handle, 1, @ptrCast(*const [1]vk.Fence, &in_flight), vk.TRUE, std.math.maxInt(u64))) |result| {
                switch (result) {
                    .success => {},
                    .timeout => @panic(std.fmt.comptimePrint("wow ok, that somehow took {d} seconds.", .{std.math.maxInt(u64) / std.time.ns_per_s})),
                    else => unreachable,
                }
            } else |err| return err;

            const image_index: u32 = if (device.dsp.acquireNextImageKHR(
                device.handle,
                swapchain.handle,
                std.math.maxInt(u64),
                image_available,
                .null_handle,
            )) |ret| switch (ret.result) {
                .success => ret.image_index,
                .suboptimal_khr => blk: {
                    std.log.warn("acquireNextImageKHR: {s}.", .{@tagName(ret.result)});
                    break :blk ret.image_index;
                },
                .timeout,
                .not_ready,
                => continue :mainloop,

                else => unreachable,
            } else |err| switch (err) {
                error.OutOfDateKHR => continue :mainloop,
                else => return err,
            };

            try device.dsp.resetFences(device.handle, 1, @ptrCast(*const [1]vk.Fence, &in_flight));
            try device.dsp.resetCommandBuffer(cmdbuffer, vk.CommandBufferResetFlags{});
            record_command_buffer: {
                try device.dsp.beginCommandBuffer(cmdbuffer, &vk.CommandBufferBeginInfo{
                    .flags = .{},
                    .p_inheritance_info = null,
                });

                device.dsp.cmdSetViewport(cmdbuffer, 0, 1, &[_]vk.Viewport{.{
                    .x = 0.0,
                    .y = 0.0,
                    .width = @intToFloat(f32, swapchain.details.extent.width),
                    .height = @intToFloat(f32, swapchain.details.extent.height),
                    .min_depth = 0.0,
                    .max_depth = 0.0,
                }});
                device.dsp.cmdSetScissor(cmdbuffer, 0, 1, &[_]vk.Rect2D{.{
                    .offset = vk.Offset2D{ .x = 0, .y = 0 },
                    .extent = swapchain.details.extent,
                }});

                vkutil.cmdBeginRenderPass(device.dsp, cmdbuffer, vkutil.RenderPassBeginInfo{
                    .render_pass = graphics_render_pass,
                    .framebuffer = swapchain_framebuffers.items[image_index],
                    .render_area = vk.Rect2D{
                        .offset = vk.Offset2D{ .x = 0, .y = 0 },
                        .extent = swapchain.details.extent,
                    },
                    .clear_values = &[_]vk.ClearValue{.{
                        .color = vk.ClearColorValue{ .float_32 = [4]f32{
                            0.0,
                            0.0,
                            0.0,
                            1.0,
                        } },
                    }},
                }, .@"inline");

                device.dsp.cmdBindPipeline(cmdbuffer, .graphics, graphics_pipeline);
                device.dsp.cmdBindVertexBuffers(cmdbuffer, 0, 1, &[_]vk.Buffer{vertices_buffer}, &[_]vk.DeviceSize{0});
                vkutil.cmdBindVertexBuffers(device.dsp, cmdbuffer, 0, &.{vertices_buffer}, &.{0});
                device.dsp.cmdBindIndexBuffer(cmdbuffer, index_buffer, 0, vk.IndexType.uint16);
                device.dsp.cmdBindDescriptorSets(cmdbuffer, .graphics, graphics_pipeline_layout, 0, 1, @ptrCast([*]const vk.DescriptorSet, &descriptor_set), 0, util.emptySlice(u32).ptr);
                device.dsp.cmdDrawIndexed(cmdbuffer, @intCast(u32, indices_data.len), 1, 0, 0, 0);

                device.dsp.cmdEndRenderPass(cmdbuffer);

                try device.dsp.endCommandBuffer(cmdbuffer);
                break :record_command_buffer;
            }

            update_uniform_buffer: {
                const time_since_start = @intToFloat(f32, ubo_timer.read() - ubo_start_time) / @intToFloat(f32, std.time.ns_per_s);

                const ubo = ubo: {
                    var ubo = UniformBufferObject{
                        .model = UniformBufferObject.Model.identity.mul(UniformBufferObject.Model.createAngleAxis(
                            zlm.SpecializeOn(f32).Vec3.new(0, 0, 1),
                            time_since_start * zlm.toRadians(90.0),
                        )),
                        .view = UniformBufferObject.View.createLookAt(
                            .{ .x = 2.0, .y = 2.0, .z = 2.0 },
                            .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                            .{ .x = 0.0, .y = 0.0, .z = 1.0 },
                        ),
                        .proj = UniformBufferObject.Projection.createPerspective(
                            zlm.toRadians(45.0),
                            @intToFloat(f32, swapchain.details.extent.width / swapchain.details.extent.height),
                            0.1,
                            10.0,
                        ),
                    };
                    // TODO: from tutorial; is it necessary?
                    ubo.proj.fields[0][0] = -1;

                    break :ubo ubo;
                };

                @memcpy(uniform_buffer_mapped_memory[uniform_buffer_segment_len * current_frame ..].ptr, @ptrCast([*]const u8, &ubo), uniform_buffer_segment_len);
                break :update_uniform_buffer;
            }

            const wait_semaphores: []const vk.Semaphore = &.{image_available};
            const signal_semaphores: []const vk.Semaphore = &.{render_finished};

            try device.dsp.queueSubmit(device.dsp.getDeviceQueue(device.handle, core_qfi.graphics, 0), 1, &[_]vk.SubmitInfo{.{
                .wait_semaphore_count = @intCast(u32, wait_semaphores.len),
                .p_wait_semaphores = wait_semaphores.ptr,
                .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }},

                .command_buffer_count = 1,
                .p_command_buffers = &[_]vk.CommandBuffer{cmdbuffer},

                .signal_semaphore_count = @intCast(u32, signal_semaphores.len),
                .p_signal_semaphores = signal_semaphores.ptr,
            }}, in_flight);

            if (device.dsp.queuePresentKHR(device.dsp.getDeviceQueue(device.handle, core_qfi.present, 0), &vk.PresentInfoKHR{
                .wait_semaphore_count = @intCast(u32, signal_semaphores.len),
                .p_wait_semaphores = signal_semaphores.ptr,

                .swapchain_count = 1,
                .p_swapchains = &[_]vk.SwapchainKHR{swapchain.handle},

                .p_image_indices = &[_]u32{image_index},
                .p_results = @as(?[*]vk.Result, null),
            })) |result| switch (result) {
                .success => {},
                else => std.log.info("queuePresentKHR: {s}.", .{@tagName(result)}),
            } else |err| {
                std.log.warn("queuePresentKHR error: {s}.", .{@errorName(err)});
                switch (err) {
                    error.OutOfDateKHR => continue :mainloop,
                    else => return err,
                }
            }

            break :draw_frame;
        }
    }
}
