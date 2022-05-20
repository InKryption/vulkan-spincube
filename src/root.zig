const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");
const vkutil = @import("vkutil.zig");

const build_options = @import("build_options");
const shader_bytecode = @import("shader-bytecodes");
const Result = @import("result.zig").Result;

const VulkanInstace = struct {
    handle: vk.Instance,
    dsp: InstanceDispatch,
};
const VulkanDevice = struct {
    handle: vk.Device,
    dsp: DeviceDispatch,
};
const CoreQueueFamilyIndices = struct {
    graphics: u32,
    present: u32,
};
const SwapchainDetails = struct {
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

    .createDebugUtilsMessengerEXT = build_options.vk_validation_layers,
    .destroyDebugUtilsMessengerEXT = build_options.vk_validation_layers,
});
const DeviceDispatchMin = vk.DeviceWrapper(vk.DeviceCommandFlags{ .destroyDevice = true });
const DeviceDispatch = vk.DeviceWrapper(vk.DeviceCommandFlags{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .deviceWaitIdle = true,

    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .getSwapchainImagesKHR = true,

    .createImageView = true,
    .destroyImageView = true,

    .createShaderModule = true,
    .destroyShaderModule = true,

    .createGraphicsPipelines = true,
    .destroyPipeline = true,

    .createPipelineLayout = true,
    .destroyPipelineLayout = true,

    .createRenderPass = true,
    .destroyRenderPass = true,

    .createFramebuffer = true,
    .destroyFramebuffer = true,

    .createCommandPool = true,
    .destroyCommandPool = true,

    .createSemaphore = true,
    .destroySemaphore = true,

    .createFence = true,
    .destroyFence = true,
    .resetFences = true,
    .waitForFences = true,

    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,

    .beginCommandBuffer = true,
    .endCommandBuffer = true,
    .resetCommandBuffer = true,

    .queueSubmit = true,
    .queuePresentKHR = true,

    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,
    .cmdBindPipeline = true,
    .cmdDraw = true,

    .acquireNextImageKHR = true,
});

fn getInstanceProcAddress(handle: vk.Instance, name: [*:0]const u8) ?*const anyopaque {
    const inst_ptr = @intToPtr(?*anyopaque, @enumToInt(handle));
    const result: glfw.VKProc = glfw.getInstanceProcAddress(inst_ptr, name) orelse return null;
    return @ptrCast(*const anyopaque, result);
}

const file_logger = @import("file_logger.zig");
pub const log = file_logger.log;
pub const log_level: std.log.Level = std.enums.nameCast(std.log.Level, build_options.log_level);

const max_frames_in_flight = 2;
pub fn main() !void {
    try file_logger.init("vulkan-spincube.log", .{ .stderr_level = .err }, null);
    defer file_logger.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true, .verbose_log = true, .stack_trace_frames = 8 }){};
    defer _ = gpa.deinit();

    const allocator: std.mem.Allocator = gpa.allocator();

    try glfw.init(.{});
    defer glfw.terminate();

    const window = try glfw.Window.create(400, 400, "vulkan-spincube", null, null, glfw.Window.Hints{ .client_api = .no_api });
    defer window.destroy();

    const debug_messenger_create_info = if (build_options.vk_validation_layers) vk.DebugUtilsMessengerCreateInfoEXT{
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

    const inst: VulkanInstace = inst: {
        const bdsp = try BaseDispatch.load(getInstanceProcAddress);
        const dsp_min = try InstanceDispatchMin.load(.null_handle, getInstanceProcAddress);

        var local_arena = std.heap.ArenaAllocator.init(allocator);
        defer local_arena.deinit();

        const desired_extensions: []const [*:0]const u8 = desired_extensions: {
            var desired_extensions = std.ArrayList([*:0]const u8).init(local_arena.allocator());
            errdefer desired_extensions.deinit();

            try desired_extensions.append(vk.extension_info.ext_debug_utils.name);

            {
                const required_glfw_extensions = try glfw.getRequiredInstanceExtensions();
                try desired_extensions.ensureUnusedCapacity(required_glfw_extensions.len);
                for (required_glfw_extensions) |req_glfw_ext| {
                    desired_extensions.appendAssumeCapacity(req_glfw_ext);
                }
            }

            break :desired_extensions desired_extensions.toOwnedSlice();
        };

        const handle = try vkutil.createInstance(allocator, bdsp, vkutil.InstanceCreateInfo{
            .p_next = if (build_options.vk_validation_layers) &debug_messenger_create_info else null,
            .enabled_extension_names = desired_extensions,
        });
        errdefer vkutil.destroyInstance(allocator, dsp_min, handle);

        const dsp = try InstanceDispatch.load(handle, getInstanceProcAddress);
        break :inst VulkanInstace{
            .handle = handle,
            .dsp = dsp,
        };
    };
    defer vkutil.destroyInstance(allocator, inst.dsp, inst.handle);

    const debug_messenger = if (build_options.vk_validation_layers) try vkutil.createDebugUtilsMessengerEXT(
        allocator,
        inst.dsp,
        inst.handle,
        debug_messenger_create_info,
    ) else void{};
    defer vkutil.destroyDebugUtilsMessengerEXT(allocator, inst.dsp, inst.handle, debug_messenger);

    const physical_device: vk.PhysicalDevice = physical_device: {
        const all_physical_devices: []const vk.PhysicalDevice = try vkutil.enumeratePhysicalDevicesAlloc(allocator, inst.dsp, inst.handle);
        defer allocator.free(all_physical_devices);

        const selected_index: usize = switch (all_physical_devices.len) {
            0 => return error.NoAvailableVulkanPhysicalDevices,
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
    _ = physical_device;

    const window_surface: vk.SurfaceKHR = window_surface: {
        var window_surface: vk.SurfaceKHR = .null_handle;
        const result = try glfw.createWindowSurface(inst.handle, window, @as(?*const vk.AllocationCallbacks, &vkutil.allocCallbacksFrom(&allocator)), &window_surface);
        switch (@intToEnum(vk.Result, result)) {
            .success => {},
            else => std.debug.todo(""),
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
                .p_queue_priorities = std.mem.span(&[_]f32{1.0}).ptr,
            });
            if (core_qfi.graphics != core_qfi.present) {
                try queue_create_infos.append(.{
                    .flags = .{},
                    .queue_family_index = core_qfi.present,
                    .queue_count = 1,
                    .p_queue_priorities = std.mem.span(&[_]f32{1.0}).ptr,
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

    const swapchain_details: SwapchainDetails = swapchain_details: {
        const capabilities = try inst.dsp.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, window_surface);
        const selected_format: vk.SurfaceFormatKHR = selected_format: {
            const formats: []const vk.SurfaceFormatKHR = try vkutil.getPhysicalDeviceSurfaceFormatsKHRAlloc(
                allocator,
                inst.dsp,
                physical_device,
                window_surface,
            );
            defer allocator.free(formats);

            if (formats.len == 0) return error.NoSurfaceFormatsAvailable;
            for (formats) |format| {
                if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                    std.log.debug("Selected surface format: {}", .{format});
                    break :selected_format format;
                }
            }

            break :selected_format formats[0];
        };
        const selected_present_mode: vk.PresentModeKHR = selected_present_mode: {
            const present_modes: []const vk.PresentModeKHR = try vkutil.getPhysicalDeviceSurfacePresentModesKHRAlloc(
                allocator,
                inst.dsp,
                physical_device,
                window_surface,
            );
            defer allocator.free(present_modes);

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

            const framebuffer_size: vk.Extent2D = framebuffer_size: {
                const fb_size = try window.getFramebufferSize();
                break :framebuffer_size vk.Extent2D{
                    .width = fb_size.width,
                    .height = fb_size.height,
                };
            };

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
        break :swapchain_details SwapchainDetails{
            .capabilities = capabilities,
            .format = selected_format,
            .present_mode = selected_present_mode,
            .extent = selected_extent,
            .image_count = image_count,
        };
    };
    const swapchain = swapchain: {
        const qfi_array: std.BoundedArray(u32, std.meta.fields(CoreQueueFamilyIndices).len) = qfi_array: {
            var qfi_array = std.BoundedArray(u32, std.meta.fields(CoreQueueFamilyIndices).len).init(0) catch unreachable;
            if (core_qfi.graphics != core_qfi.present) {
                qfi_array.appendSlice(&.{ core_qfi.graphics, core_qfi.present }) catch unreachable;
            }
            break :qfi_array qfi_array;
        };

        break :swapchain try vkutil.createSwapchainKHR(allocator, device.dsp, device.handle, vkutil.SwapchainCreateInfoKHR{
            .surface = window_surface,

            .min_image_count = swapchain_details.image_count,
            .image_format = swapchain_details.format.format,
            .image_color_space = swapchain_details.format.color_space,
            .image_extent = swapchain_details.extent,
            .image_array_layers = 1,
            .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true },
            .image_sharing_mode = if (qfi_array.len > 1) .concurrent else .exclusive,

            .queue_family_indices = qfi_array.slice(),

            .pre_transform = swapchain_details.capabilities.current_transform,
            .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
            .present_mode = swapchain_details.present_mode,
            .clipped = true,
        });
    };
    defer vkutil.destroySwapchainKHR(allocator, device.dsp, device.handle, swapchain);

    const swapchain_images: std.MultiArrayList(ImageAndView).Slice = swapchain_images: {
        var swapchain_images: std.MultiArrayList(ImageAndView) = .{};
        errdefer swapchain_images.deinit(allocator);

        {
            var count: u32 = undefined;
            if (device.dsp.getSwapchainImagesKHR(device.handle, swapchain, &count, null)) |result| switch (result) {
                .success => {},
                else => unreachable,
            } else |err| return err;

            std.debug.assert(count >= swapchain_details.image_count);
            try swapchain_images.resize(allocator, count);

            if (device.dsp.getSwapchainImagesKHR(device.handle, swapchain, &count, swapchain_images.items(.img).ptr)) |result| switch (result) {
                .success => {},
                else => unreachable,
            } else |err| return err;
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
                .format = swapchain_details.format.format,
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

        break :swapchain_images swapchain_images.toOwnedSlice();
    };
    defer {
        for (swapchain_images.items(.view)) |view| {
            vkutil.destroyImageView(allocator, device.dsp, device.handle, view);
        }
        var copy = swapchain_images;
        copy.deinit(allocator);
    }

    const graphics_pipeline_layout: vk.PipelineLayout = graphics_pipeline_layout: {
        const set_layouts = [_]vk.DescriptorSetLayout{};
        const push_constant_ranges = [_]vk.PushConstantRange{};

        break :graphics_pipeline_layout try device.dsp.createPipelineLayout(
            device.handle,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},

                .set_layout_count = @intCast(u32, set_layouts.len),
                .p_set_layouts = std.mem.span(&set_layouts).ptr,

                .push_constant_range_count = @intCast(u32, push_constant_ranges.len),
                .p_push_constant_ranges = std.mem.span(&push_constant_ranges).ptr,
            },
            &vkutil.allocCallbacksFrom(&allocator),
        );
    };
    defer device.dsp.destroyPipelineLayout(device.handle, graphics_pipeline_layout, &vkutil.allocCallbacksFrom(&allocator));

    const graphics_render_pass: vk.RenderPass = graphics_render_pass: {
        const attachments = [_]vk.AttachmentDescription{
            .{
                .flags = .{},
                .format = swapchain_details.format.format,
                .samples = vk.SampleCountFlags{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .@"undefined",
                .final_layout = .present_src_khr,
            },
        };

        const input_attachment_refs = [_]vk.AttachmentReference{};
        const color_attachment_refs = [_]vk.AttachmentReference{.{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        }};
        const preserve_attachment_refs = [_]u32{};

        const subpasses = [_]vk.SubpassDescription{
            .{
                .flags = .{},
                .pipeline_bind_point = .graphics,
                //
                .input_attachment_count = @intCast(u32, input_attachment_refs.len),
                .p_input_attachments = std.mem.span(&input_attachment_refs).ptr,
                //
                .color_attachment_count = @intCast(u32, color_attachment_refs.len),
                .p_color_attachments = &color_attachment_refs,
                //
                .p_resolve_attachments = null,
                .p_depth_stencil_attachment = null,
                //
                .preserve_attachment_count = @intCast(u32, preserve_attachment_refs.len),
                .p_preserve_attachments = std.mem.span(&preserve_attachment_refs).ptr,
            },
        };
        const subpass_dependencies = [_]vk.SubpassDependency{
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
                .p_dependencies = std.mem.span(&subpass_dependencies).ptr,
            },
            &vkutil.allocCallbacksFrom(&allocator),
        );
    };
    defer device.dsp.destroyRenderPass(device.handle, graphics_render_pass, &vkutil.allocCallbacksFrom(&allocator));

    const graphics_pipeline: vk.Pipeline = graphics_pipeline: {
        {
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
                    .width = @intToFloat(f32, swapchain_details.extent.width),
                    .height = @intToFloat(f32, swapchain_details.extent.height),
                    .min_depth = 0.0,
                    .max_depth = 0.0,
                },
            };

            const scissors = [_]vk.Rect2D{
                .{
                    .offset = vk.Offset2D{ .x = 0, .y = 0 },
                    .extent = swapchain_details.extent,
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

            const dynamic_states = [_]vk.DynamicState{
                // .viewport,
                // .line_width,
            };

            const graphics_pipeline_create_info = vk.GraphicsPipelineCreateInfo{
                .flags = vk.PipelineCreateFlags{},

                .stage_count = @intCast(u32, shader_stage_create_infos.len),
                .p_stages = &shader_stage_create_infos,

                .p_vertex_input_state = &vk.PipelineVertexInputStateCreateInfo{
                    .flags = .{},

                    .vertex_binding_description_count = 0,
                    .p_vertex_binding_descriptions = std.mem.span(&[_]vk.VertexInputBindingDescription{}).ptr,

                    .vertex_attribute_description_count = 0,
                    .p_vertex_attribute_descriptions = std.mem.span(&[_]vk.VertexInputAttributeDescription{}).ptr,
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
                    .p_dynamic_states = std.mem.span(&dynamic_states).ptr,
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
        }
    };
    defer device.dsp.destroyPipeline(device.handle, graphics_pipeline, &vkutil.allocCallbacksFrom(&allocator));

    const swapchain_framebuffers: []const vk.Framebuffer = swapchain_framebuffers: {
        const image_views: []const vk.ImageView = swapchain_images.items(.view);

        const swapchain_framebuffers: []vk.Framebuffer = try allocator.alloc(vk.Framebuffer, image_views.len);
        errdefer allocator.free(swapchain_framebuffers);

        for (image_views) |view, i| {
            errdefer for (swapchain_framebuffers[0..i]) |prev_fb| {
                device.dsp.destroyFramebuffer(device.handle, prev_fb, &vkutil.allocCallbacksFrom(&allocator));
            };

            const attachments = [_]vk.ImageView{view};
            swapchain_framebuffers[i] = try device.dsp.createFramebuffer(device.handle, &vk.FramebufferCreateInfo{
                .flags = .{},
                .render_pass = graphics_render_pass,

                .attachment_count = @intCast(u32, attachments.len),
                .p_attachments = &attachments,

                .width = swapchain_details.extent.width,
                .height = swapchain_details.extent.height,

                .layers = 1,
            }, &vkutil.allocCallbacksFrom(&allocator));
        }
        break :swapchain_framebuffers swapchain_framebuffers;
    };
    defer {
        for (swapchain_framebuffers) |fb| {
            device.dsp.destroyFramebuffer(device.handle, fb, &vkutil.allocCallbacksFrom(&allocator));
        }
        allocator.free(swapchain_framebuffers);
    }

    const cmdpool: vk.CommandPool = try device.dsp.createCommandPool(device.handle, &vk.CommandPoolCreateInfo{
        .flags = vk.CommandPoolCreateFlags{ .reset_command_buffer_bit = true },
        .queue_family_index = core_qfi.graphics,
    }, &vkutil.allocCallbacksFrom(&allocator));
    defer device.dsp.destroyCommandPool(device.handle, cmdpool, &vkutil.allocCallbacksFrom(&allocator));

    const SyncronizedFrame = struct {
        cmdbuffer: vk.CommandBuffer,
        image_available: vk.Semaphore,
        render_finished: vk.Semaphore,
        in_flight: vk.Fence,
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
            .command_pool = cmdpool,
            .level = .primary,
            .command_buffer_count = @intCast(u32, syncronized_frames.len),
        }, syncronized_frames.items(.cmdbuffer).ptr);
        errdefer device.dsp.freeCommandBuffers(
            device.handle,
            cmdpool,
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

        break :syncronized_frames syncronized_frames;
    };
    defer {
        inline for (.{ .render_finished, .image_available }) |field| {
            for (syncronized_frames.items(field)) |sem| {
                device.dsp.destroySemaphore(device.handle, sem, &vkutil.allocCallbacksFrom(&allocator));
            }
        }

        for (syncronized_frames.items(.in_flight)) |fence| {
            device.dsp.destroyFence(device.handle, fence, &vkutil.allocCallbacksFrom(&allocator));
        }

        device.dsp.freeCommandBuffers(device.handle, cmdpool, @intCast(u32, syncronized_frames.len), syncronized_frames.items(.cmdbuffer).ptr);

        var copy = syncronized_frames;
        copy.deinit(allocator);
    }

    var current_frame: u32 = 0;
    defer device.dsp.deviceWaitIdle(device.handle) catch |err| std.log.err("deviceWaitIdle: {}", .{err});
    mainloop: while (!window.shouldClose()) {
        try glfw.pollEvents();
        {
            const fbsize = try window.getFramebufferSize();
            if (fbsize.width == 0) continue;
            if (fbsize.height == 0) continue;
        }

        draw_frame: {
            const in_flight: vk.Fence = syncronized_frames.items(.in_flight)[current_frame];
            const image_available: vk.Semaphore = syncronized_frames.items(.image_available)[current_frame];
            const render_finished: vk.Semaphore = syncronized_frames.items(.render_finished)[current_frame];
            const cmdbuffer: vk.CommandBuffer = syncronized_frames.items(.cmdbuffer)[current_frame];
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
                swapchain,
                std.math.maxInt(u64),
                image_available,
                .null_handle,
            )) |ret| switch (ret.result) {
                .success,
                .suboptimal_khr,
                => ret.image_index,
                .not_ready => continue :mainloop,
                .timeout => blk: {
                    std.log.warn("acquireNextImageKHR: {s}.", .{@tagName(ret.result)});
                    break :blk ret.image_index;
                },

                else => unreachable,
            } else |err| switch (err) {
                error.OutOfDateKHR => std.debug.todo(""),
                else => return err,
            };

            try device.dsp.resetFences(device.handle, 1, @ptrCast(*const [1]vk.Fence, &in_flight));

            try device.dsp.resetCommandBuffer(cmdbuffer, vk.CommandBufferResetFlags{});
            record_command_buffer: {
                try device.dsp.beginCommandBuffer(cmdbuffer, &vk.CommandBufferBeginInfo{
                    .flags = .{},
                    .p_inheritance_info = null,
                });

                device.dsp.cmdBeginRenderPass(cmdbuffer, &vk.RenderPassBeginInfo{
                    .render_pass = graphics_render_pass,
                    .framebuffer = swapchain_framebuffers[image_index],
                    .render_area = vk.Rect2D{
                        .offset = vk.Offset2D{ .x = 0, .y = 0 },
                        .extent = swapchain_details.extent,
                    },

                    .clear_value_count = 1,
                    .p_clear_values = &[_]vk.ClearValue{.{
                        .color = vk.ClearColorValue{ .float_32 = [4]f32{
                            0.0,
                            0.0,
                            0.0,
                            1.0,
                        } },
                    }},
                }, .@"inline");

                device.dsp.cmdBindPipeline(cmdbuffer, .graphics, graphics_pipeline);
                device.dsp.cmdDraw(cmdbuffer, 3, 1, 0, 0);

                device.dsp.cmdEndRenderPass(cmdbuffer);

                try device.dsp.endCommandBuffer(cmdbuffer);
                break :record_command_buffer;
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
                .p_swapchains = &[_]vk.SwapchainKHR{swapchain},

                .p_image_indices = &[_]u32{image_index},
                .p_results = @as(?[*]vk.Result, null),
            })) |result| switch (result) {
                .success => {},
                else => std.log.warn("queuePresentKHR: {s}.", .{@tagName(result)}),
            } else |err| return err;

            break :draw_frame;
        }
    }
}
