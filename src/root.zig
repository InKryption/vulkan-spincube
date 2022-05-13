const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const glfw = @import("glfw");
const vk = @import("vulkan");
const vkutil = @import("vkutil.zig");

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

    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,

    .getSwapchainImagesKHR = true,
});

fn getInstanceProcAddress(handle: vk.Instance, name: [*:0]const u8) ?*const anyopaque {
    const inst_ptr = @intToPtr(?*anyopaque, @enumToInt(handle));
    const result: glfw.VKProc = glfw.getInstanceProcAddress(inst_ptr, name) orelse return null;
    return @ptrCast(*const anyopaque, result);
}

const file_logger = @import("file_logger.zig");
pub const log = file_logger.log;
pub const log_level: std.log.Level = @field(std.log.Level, @tagName(build_options.log_level));

const debug_utils_messenger_create_info_ext = vk.DebugUtilsMessengerCreateInfoEXT{
    .flags = vk.DebugUtilsMessengerCreateFlagsEXT{},
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
    .pfn_user_callback = vulkanDebugMessengerCallback,
    .p_user_data = null,
};
fn vulkanDebugMessengerCallback(
    msg_severity_int: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
    opt_p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_types;
    _ = p_user_data;

    const logger = std.log.scoped(.vk_messenger);
    const msg_severity = @bitCast(vk.DebugUtilsMessageSeverityFlagsEXT, msg_severity_int);
    const level: std.log.Level = if (msg_severity.error_bit_ext)
        .err
    else if (msg_severity.warning_bit_ext)
        .warn
    else if (msg_severity.info_bit_ext) .info else std.log.Level.debug;

    const p_callback_data = opt_p_callback_data orelse return vk.FALSE;
    switch (level) {
        .err => logger.err("{s}", .{p_callback_data.p_message}),
        .warn => logger.warn("{s}", .{p_callback_data.p_message}),
        .info => logger.info("{s}", .{p_callback_data.p_message}),
        .debug => logger.debug("{s}", .{p_callback_data.p_message}),
    }

    return vk.FALSE;
}

fn desiredInstanceLayerNames(allocator: std.mem.Allocator, comptime StrType: type) ![]const StrType {
    comptime std.debug.assert(
        std.meta.trait.isSlice(StrType) and
            std.meta.trait.isZigString(StrType),
    );
    comptime if (!build_options.vk_validation_layers) return &.{};

    var result = std.ArrayList(StrType).init(allocator);
    errdefer freeSliceOfStrings(allocator, StrType, result.toOwnedSlice());

    try result.append(try allocator.dupeZ(u8, "VK_LAYER_KHRONOS_validation"));

    return result.toOwnedSlice();
}
fn desiredInstanceExtensionNames(allocator: std.mem.Allocator, comptime StrType: type) ![]const StrType {
    comptime std.debug.assert(
        std.meta.trait.isSlice(StrType) and
            std.meta.trait.isZigString(StrType),
    );

    var result = std.ArrayList(StrType).init(allocator);
    errdefer freeSliceOfStrings(allocator, StrType, result.toOwnedSlice());

    const glfw_required_extensions = try glfw.getRequiredInstanceExtensions();
    try result.ensureUnusedCapacity(glfw_required_extensions.len);
    for (glfw_required_extensions) |p_ext_name| {
        const ext_name = std.mem.span(p_ext_name);
        result.appendAssumeCapacity(try allocator.dupeZ(u8, ext_name));
    }

    if (build_options.vk_validation_layers) {
        try result.append(try allocator.dupeZ(u8, vk.extension_info.ext_debug_utils.name));
    }

    return result.toOwnedSlice();
}

fn desiredDeviceExtensionNames(allocator: std.mem.Allocator, comptime StrType: type) ![]const StrType {
    comptime std.debug.assert(
        std.meta.trait.isSlice(StrType) and
            std.meta.trait.isZigString(StrType),
    );

    var result = std.ArrayList(StrType).init(allocator);
    errdefer freeSliceOfStrings(allocator, StrType, result.toOwnedSlice());

    try result.append(try allocator.dupeZ(u8, vk.extension_info.khr_swapchain.name));

    return result.toOwnedSlice();
}

pub fn main() !void {
    try file_logger.init("vulkan-spincube.log", .{ .stderr_level = .err }, &.{.gpa});
    defer file_logger.deinit();

    var gpa = if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer if (builtin.mode == .Debug) {
        _ = gpa.deinit();
    };

    var arena = std.heap.ArenaAllocator.init(if (builtin.mode == .Debug) gpa.allocator() else std.heap.page_allocator);
    defer arena.deinit();

    const allocator: std.mem.Allocator = arena.allocator();

    try glfw.init(.{});
    defer glfw.terminate();

    const window = try glfw.Window.create(100, 100, "vulkan-spincube", null, null, glfw.Window.Hints{ .client_api = .no_api });
    defer window.destroy();

    const engine = try VkEngine.init(allocator, getInstanceProcAddress, window);
    defer engine.deinit(allocator);

    _ = engine.getCoreDeviceQueue(.present, 0);
    _ = engine.getCoreDeviceQueue(.graphics, 0);

    while (!window.shouldClose()) {
        try glfw.pollEvents();
    }
}

const VkEngine = struct {
    inst: VkInst,
    debug_messenger: if (build_options.vk_validation_layers) vk.DebugUtilsMessengerEXT else void,
    physical_device: vk.PhysicalDevice,
    queue_family_indices: QueueFamilyIndices,
    device: VkDevice,
    surface_khr: vk.SurfaceKHR,
    swapchain_details: SwapchainDetails,
    swapchain_khr: vk.SwapchainKHR,
    swapchain_images: std.MultiArrayList(ImageHandleViewPair).Slice,

    const VkInst = struct { handle: vk.Instance, dsp: InstanceDispatch };
    const VkDevice = struct { handle: vk.Device, dsp: DeviceDispatch };
    const ImageHandleViewPair = struct { img: vk.Image, vew: vk.ImageView };

    const QueueFamilyId = std.meta.FieldEnum(QueueFamilyIndices);
    const QueueFamilyIndices = struct {
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

    pub fn init(
        allocator: std.mem.Allocator,
        instanceProcLoader: anytype,
        window: glfw.Window,
    ) !VkEngine {
        const inst: VkInst = try initVkInst(allocator, instanceProcLoader);
        errdefer inst.dsp.destroyInstance(inst.handle, &vkutil.allocatorVulkanWrapper(&allocator));

        const debug_messenger = if (build_options.vk_validation_layers)
            try createVkDebugMessenger(allocator, inst)
        else {};
        errdefer if (build_options.vk_validation_layers) {
            destroyVkDebugMessenger(allocator, inst, debug_messenger);
        };

        const physical_device: vk.PhysicalDevice = try selectPhysicalDevice(allocator, inst);

        const surface_khr: vk.SurfaceKHR = surface_khr: {
            var surface_khr: vk.SurfaceKHR = undefined;
            if (glfw.createWindowSurface(inst.handle, window, @as(?*const vk.AllocationCallbacks, &vkutil.allocatorVulkanWrapper(&allocator)), &surface_khr)) |result| {
                switch (@intToEnum(vk.Result, result)) {
                    .success => {},
                    else => std.log.warn("glfw.createWindowSurface: '{s}'.\n", .{@tagName(@intToEnum(vk.Result, result))}),
                }
            } else |err| return err;
            break :surface_khr surface_khr;
        };
        errdefer inst.dsp.destroySurfaceKHR(inst.handle, surface_khr, &vkutil.allocatorVulkanWrapper(&allocator));

        const queue_family_indices: QueueFamilyIndices = try selectQueueFamilyIndices(allocator, inst.dsp, physical_device, surface_khr);

        const device = try initVkDevice(allocator, inst.dsp, physical_device, queue_family_indices);
        errdefer device.dsp.destroyDevice(device.handle, &vkutil.allocatorVulkanWrapper(&allocator));

        const swapchain_details = swapchain_details: {
            const capabilities = try inst.dsp.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface_khr);

            const selected_format: vk.SurfaceFormatKHR = selected_format: {
                const formats: []const vk.SurfaceFormatKHR = try vkutil.getPhysicalDeviceSurfaceFormatsKHRAlloc(
                    allocator,
                    inst.dsp,
                    physical_device,
                    surface_khr,
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
                    surface_khr,
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
        const swapchain_khr = try initSwapchain(allocator, device, queue_family_indices, surface_khr, swapchain_details);
        errdefer device.dsp.destroySwapchainKHR(device.handle, swapchain_khr, &vkutil.allocatorVulkanWrapper(&allocator));

        const swapchain_images: std.MultiArrayList(ImageHandleViewPair).Slice = swapchain_images: {
            var swapchain_images: std.MultiArrayList(ImageHandleViewPair) = .{};
            errdefer swapchain_images.deinit(allocator);

            {
                var count: u32 = undefined;
                if (device.dsp.getSwapchainImagesKHR(device.handle, swapchain_khr, &count, null)) |result| switch (result) {
                    .success => {},
                    else => unreachable,
                } else |err| return err;

                std.debug.assert(count >= swapchain_details.image_count);
                try swapchain_images.ensureTotalCapacity(allocator, count);
            }

            break :swapchain_images swapchain_images.toOwnedSlice();
        };
        errdefer {
            var copy = swapchain_images;
            copy.deinit(allocator);
        }

        return VkEngine{
            .inst = inst,
            .debug_messenger = debug_messenger,
            .physical_device = physical_device,
            .queue_family_indices = queue_family_indices,
            .device = device,
            .surface_khr = surface_khr,
            .swapchain_details = swapchain_details,
            .swapchain_khr = swapchain_khr,
            .swapchain_images = swapchain_images,
        };
    }
    pub fn deinit(self: VkEngine, allocator: std.mem.Allocator) void {
        self.device.dsp.destroySwapchainKHR(self.device.handle, self.swapchain_khr, &vkutil.allocatorVulkanWrapper(&allocator));
        self.device.dsp.destroyDevice(self.device.handle, &vkutil.allocatorVulkanWrapper(&allocator));
        self.inst.dsp.destroySurfaceKHR(self.inst.handle, self.surface_khr, &vkutil.allocatorVulkanWrapper(&allocator));
        if (build_options.vk_validation_layers) {
            self.inst.dsp.destroyDebugUtilsMessengerEXT(self.inst.handle, self.debug_messenger, &vkutil.allocatorVulkanWrapper(&allocator));
        }
        self.inst.dsp.destroyInstance(self.inst.handle, &vkutil.allocatorVulkanWrapper(&allocator));
    }

    pub fn getCoreDeviceQueue(self: VkEngine, comptime id: QueueFamilyId, index: u32) vk.Queue {
        return self.device.dsp.getDeviceQueue(self.device.handle, @field(self.queue_family_indices, @tagName(id)), index);
    }

    fn initVkInst(allocator: std.mem.Allocator, instanceProcLoader: anytype) !VkInst {
        var local_arena_state = std.heap.ArenaAllocator.init(allocator);
        defer local_arena_state.deinit();

        const local_arena = local_arena_state.allocator();

        const bd = try BaseDispatch.load(instanceProcLoader);

        const desired_layers = try desiredInstanceLayerNames(local_arena, [:0]const u8);
        const available_layers: []const vk.LayerProperties = try vkutil.enumerateInstanceLayerPropertiesAlloc(local_arena, bd);
        const available_layer_set: std.StringArrayHashMap(void).Unmanaged = available_layer_set: {
            var available_layer_set = std.StringArrayHashMap(void).init(local_arena);

            try available_layer_set.ensureUnusedCapacity(available_layers.len);
            for (available_layers) |*layer| {
                const str = std.mem.sliceTo(std.mem.span(&layer.layer_name), 0);
                available_layer_set.putAssumeCapacityNoClobber(str, {});
            }

            break :available_layer_set available_layer_set.unmanaged;
        };
        const selected_layers: std.ArrayHashMapUnmanaged([*:0]const u8, void, ArrayCStringContext, true) = selected_layers: {
            var selected_layers = std.ArrayHashMap([*:0]const u8, void, ArrayCStringContext, true).init(local_arena);
            errdefer selected_layers.deinit();

            try selected_layers.ensureUnusedCapacity(desired_layers.len);
            for (desired_layers) |p_desired_layer| {
                const desired_layer = std.mem.span(p_desired_layer);
                if (available_layer_set.contains(desired_layer)) {
                    selected_layers.putAssumeCapacityNoClobber(desired_layer, {});
                } else {
                    std.log.warn("Desired layer '{s}' not available.", .{desired_layer});
                }
            }

            break :selected_layers selected_layers.unmanaged;
        };

        const desired_extensions: []const [:0]const u8 = try desiredInstanceExtensionNames(local_arena, [:0]const u8);
        const available_extensions: []const vk.ExtensionProperties = try vkutil.enumerateInstanceExtensionPropertiesAlloc(local_arena, bd, null);
        const selected_extensions = switch (selectExtensionNames(allocator, available_extensions, [:0]const u8, desired_extensions)) {
            .ok => |ok| ok,
            .err => |err| {
                if (err.info.unavailable_extension) |unavailable_extension| {
                    std.log.err("Instance extension '{s}' not found/not available.", .{unavailable_extension});
                }
                return err.code;
            },
        };

        log_layers_and_extensions: {
            var log_buff = std.ArrayList(u8).init(local_arena);
            defer log_buff.deinit();
            const log_buff_writer = log_buff.writer();

            if (selected_layers.count() != 0) {
                log_buff.shrinkRetainingCapacity(0);
                try log_buff_writer.writeAll("Selected layers:\n");
                for (available_layers) |*layer| {
                    if (!selected_layers.contains(std.meta.assumeSentinel(std.mem.sliceTo(&layer.layer_name, 0), 0))) {
                        continue;
                    }
                    try log_buff_writer.print(
                        \\ * {s}: {s}
                        \\     Impl: {}
                        \\     Spec: {}
                        \\
                    ,
                        .{
                            std.mem.sliceTo(&layer.layer_name, 0),
                            std.mem.sliceTo(&layer.description, 0),
                            vkutil.fmtApiVersion(layer.implementation_version),
                            vkutil.fmtApiVersion(layer.spec_version),
                        },
                    );
                }
                std.log.debug("{s}", .{log_buff.items});
            }

            if (selected_extensions.count() != 0) {
                log_buff.shrinkRetainingCapacity(0);
                try log_buff_writer.writeAll("Selected extensions:\n");
                for (available_extensions) |*ext| {
                    if (!selected_extensions.contains(std.meta.assumeSentinel(std.mem.sliceTo(&ext.extension_name, 0), 0))) {
                        continue;
                    }
                    try log_buff_writer.print(
                        " * '{s}': {}\n",
                        .{
                            std.mem.sliceTo(&ext.extension_name, 0),
                            vkutil.fmtApiVersion(ext.spec_version),
                        },
                    );
                }
                std.log.debug("{s}", .{log_buff.items});
            }

            break :log_layers_and_extensions;
        }

        const inst_debug_messenger_creation_info = if (build_options.vk_validation_layers) vk.DebugUtilsMessengerCreateInfoEXT{
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
            .pfn_user_callback = vulkanDebugMessengerCallback,
            .p_user_data = null,
        } else void{};

        const handle = vkutil.createInstance(allocator, bd, vkutil.InstanceCreateInfo{
            .p_next = if (build_options.vk_validation_layers) &inst_debug_messenger_creation_info else null,
            .enabled_layer_names = selected_layers.keys(),
            .enabled_extension_names = selected_extensions.keys(),
        }) catch |err| return switch (err) {
            error.LayerNotPresent => unreachable,
            else => err,
        };
        const dsp = InstanceDispatch.load(handle, instanceProcLoader) catch |err| {
            const min_dsp = InstanceDispatchMin.load(handle, instanceProcLoader) catch {
                std.log.err("Failed to load function to destroy instance, cleanup not possible.", .{});
                return err;
            };
            min_dsp.destroyInstance(handle, &vkutil.allocatorVulkanWrapper(&allocator));
            return err;
        };
        errdefer dsp.destroyInstance(handle, &vkutil.allocatorVulkanWrapper(&allocator));

        return VkInst{
            .handle = handle,
            .dsp = dsp,
        };
    }

    fn createVkDebugMessenger(allocator: std.mem.Allocator, inst: VkInst) !vk.DebugUtilsMessengerEXT {
        return inst.dsp.createDebugUtilsMessengerEXT(inst.handle, &vk.DebugUtilsMessengerCreateInfoEXT{
            .flags = vk.DebugUtilsMessengerCreateFlagsEXT{},
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
            .pfn_user_callback = vulkanDebugMessengerCallback,
            .p_user_data = null,
        }, &vkutil.allocatorVulkanWrapper(&allocator));
    }
    fn destroyVkDebugMessenger(allocator: std.mem.Allocator, inst: VkInst, debug_messenger: vk.DebugUtilsMessengerEXT) void {
        inst.dsp.destroyDebugUtilsMessengerEXT(inst.handle, debug_messenger, &vkutil.allocatorVulkanWrapper(&allocator));
    }

    fn selectPhysicalDevice(allocator: std.mem.Allocator, inst: VkInst) !vk.PhysicalDevice {
        const physical_devices = try vkutil.enumeratePhysicalDevicesAlloc(allocator, inst.dsp, inst.handle);
        defer allocator.free(physical_devices);

        switch (physical_devices.len) {
            0 => return error.NoPhysicalDevicesAvailable,
            1 => return physical_devices[0],
            2 => {
                std.log.warn("TODO: Two physical devices available; no selection process implemented, defaulting to physical_devices[0].", .{});
            },
            else => {
                std.log.warn("TODO: {d} physical devices available; no selection process implemented, defaulting to physical_devices[0].", .{physical_devices.len});
            },
        }
        return physical_devices[0];
    }
    fn selectQueueFamilyIndices(
        allocator: std.mem.Allocator,
        dsp: InstanceDispatch,
        physical_device: vk.PhysicalDevice,
        surface_khr: vk.SurfaceKHR,
    ) !QueueFamilyIndices {
        var indices = std.EnumArray(QueueFamilyId, ?u32).initFill(null);

        const qfam_properties: []const vk.QueueFamilyProperties = try vkutil.getPhysicalDeviceQueueFamilyPropertiesAlloc(allocator, dsp, physical_device);
        defer allocator.free(qfam_properties);

        for (qfam_properties) |qfam, i| {
            const index = @intCast(u32, i);
            const surface_support = (try dsp.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface_khr)) == vk.TRUE;
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

        var result: QueueFamilyIndices = undefined;
        inline for (comptime std.enums.values(QueueFamilyId)) |tag| {
            const tag_name = @tagName(tag);
            const title_case = [_]u8{std.ascii.toUpper(tag_name[0])} ++ tag_name[@boolToInt(tag_name.len >= 1)..];
            @field(result, @tagName(tag)) = indices.get(tag) orelse return @field(anyerror, "MissingFamilyQueueIndexFor" ++ title_case);
        }
        return result;
    }

    fn initVkDevice(
        allocator: std.mem.Allocator,
        instance_dsp: InstanceDispatch,
        physical_device: vk.PhysicalDevice,
        queue_family_indices: QueueFamilyIndices,
    ) !VkDevice {
        const queue_create_infos: []const vk.DeviceQueueCreateInfo = queue_create_infos: {
            var queue_create_infos = std.ArrayList(vk.DeviceQueueCreateInfo).init(allocator);
            errdefer queue_create_infos.deinit();

            try queue_create_infos.append(.{
                .flags = .{},
                .queue_family_index = queue_family_indices.graphics,
                .queue_count = 1,
                .p_queue_priorities = std.mem.span(&[_]f32{1.0}).ptr,
            });
            if (queue_family_indices.graphics != queue_family_indices.present) {
                try queue_create_infos.append(.{
                    .flags = .{},
                    .queue_family_index = queue_family_indices.present,
                    .queue_count = 1,
                    .p_queue_priorities = std.mem.span(&[_]f32{1.0}).ptr,
                });
            }

            break :queue_create_infos queue_create_infos.toOwnedSlice();
        };
        defer allocator.free(queue_create_infos);

        const desired_extensions = try desiredDeviceExtensionNames(allocator, [:0]const u8);
        defer freeSliceOfStrings(allocator, [:0]const u8, desired_extensions);

        const available_extensions = try vkutil.enumerateDeviceExtensionPropertiesAlloc(allocator, instance_dsp, physical_device);
        defer allocator.free(available_extensions);

        const selected_extensions = switch (selectExtensionNames(allocator, available_extensions, [:0]const u8, desired_extensions)) {
            .ok => |ok| ok,
            .err => |err| {
                if (err.info.unavailable_extension) |unavailable_extension| {
                    std.log.err("Device extension '{s}' not found/not available.", .{unavailable_extension});
                }
                return err.code;
            },
        };
        defer {
            var copy = selected_extensions;
            copy.deinit(allocator);
        }

        const handle = try instance_dsp.createDevice(physical_device, &vk.DeviceCreateInfo{
            .flags = .{},

            .queue_create_info_count = @intCast(u32, queue_create_infos.len),
            .p_queue_create_infos = queue_create_infos.ptr,

            .enabled_layer_count = 0,
            .pp_enabled_layer_names = std.mem.span(&[_][*:0]const u8{}).ptr,

            .enabled_extension_count = @intCast(u32, selected_extensions.count()),
            .pp_enabled_extension_names = selected_extensions.keys().ptr,

            .p_enabled_features = null,
        }, &vkutil.allocatorVulkanWrapper(&allocator));
        const dsp = DeviceDispatch.load(handle, instance_dsp.dispatch.vkGetDeviceProcAddr) catch |err| {
            const min_dsp = DeviceDispatchMin.load(handle, instance_dsp.dispatch.vkGetDeviceProcAddr) catch {
                std.log.err("Failed to load function to destroy device, cleanup not possible.", .{});
                return err;
            };
            min_dsp.destroyDevice(handle, &vkutil.allocatorVulkanWrapper(&allocator));
            return err;
        };
        errdefer dsp.destroyDevice(handle, &vkutil.allocatorVulkanWrapper(&allocator));

        return VkDevice{
            .handle = handle,
            .dsp = dsp,
        };
    }

    fn initSwapchain(allocator: std.mem.Allocator, device: VkDevice, qfi: QueueFamilyIndices, surface_khr: vk.SurfaceKHR, details: SwapchainDetails) !vk.SwapchainKHR {
        const queue_family_indices: std.BoundedArray(u32, std.meta.fields(QueueFamilyIndices).len) = queue_family_indices: {
            var queue_family_indices = std.BoundedArray(u32, std.meta.fields(QueueFamilyIndices).len).init(0) catch unreachable;
            if (qfi.graphics != qfi.present) {
                queue_family_indices.appendSlice(&.{ qfi.graphics, qfi.present }) catch unreachable;
            }
            break :queue_family_indices queue_family_indices;
        };
        const create_info = vk.SwapchainCreateInfoKHR{
            .flags = vk.SwapchainCreateFlagsKHR{},
            .surface = surface_khr,

            .min_image_count = details.image_count,
            .image_format = details.format.format,
            .image_color_space = details.format.color_space,
            .image_extent = details.extent,
            .image_array_layers = 1,
            .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true },

            .image_sharing_mode = if (queue_family_indices.len > 1) .concurrent else .exclusive,
            .queue_family_index_count = @intCast(u32, queue_family_indices.len),
            .p_queue_family_indices = queue_family_indices.slice().ptr,

            .pre_transform = details.capabilities.current_transform,
            .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
            .present_mode = details.present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = .null_handle,
        };
        return device.dsp.createSwapchainKHR(device.handle, &create_info, &vkutil.allocatorVulkanWrapper(&allocator));
    }

    const EnsureDesiredExtensionsAreAvailableResult = Result(
        std.ArrayHashMapUnmanaged([*:0]const u8, void, ArrayCStringContext, true),
        std.mem.Allocator.Error || error{ExtensionUnavailable},
        struct {
            unavailable_extension: ?[:0]const u8 = null,
        },
    );
    fn selectExtensionNames(
        allocator: std.mem.Allocator,
        /// Pointers to these will be referenced by the result, therefore
        /// must have a lifetime equal to, or greater than the output.
        available_extensions: []const vk.ExtensionProperties,
        comptime InputStrType: type,
        desired_extensions: []const InputStrType,
    ) EnsureDesiredExtensionsAreAvailableResult {
        const Res = EnsureDesiredExtensionsAreAvailableResult;
        comptime std.debug.assert(
            std.meta.trait.isSlice(InputStrType) and
                std.meta.trait.isZigString(InputStrType),
        );
        const StringZHashMap = std.HashMap([:0]const u8, void, struct {
            pub fn hash(ctx: @This(), str: [:0]const u8) u64 {
                _ = ctx;
                return std.hash_map.StringContext.hash(.{}, str);
            }
            pub fn eql(ctx: @This(), a: [:0]const u8, b: [:0]const u8) bool {
                _ = ctx;
                return std.hash_map.StringContext.eql(.{}, a, b);
            }
        }, std.hash_map.default_max_load_percentage);
        const available_extension_set: StringZHashMap.Unmanaged = available_extension_set: {
            var available_extension_set = StringZHashMap.init(allocator);

            available_extension_set.ensureUnusedCapacity(@intCast(StringZHashMap.Size, available_extensions.len)) catch |err| {
                available_extension_set.deinit();
                return Res.initError(err, .{});
            };
            for (available_extensions) |*ext| {
                const str = std.meta.assumeSentinel(std.mem.sliceTo(std.mem.span(&ext.extension_name), 0), 0);
                available_extension_set.putAssumeCapacityNoClobber(str, {});
            }

            break :available_extension_set available_extension_set.unmanaged;
        };
        defer {
            var copy = available_extension_set;
            copy.deinit(allocator);
        }

        var selected_extensions = std.ArrayHashMap([*:0]const u8, void, ArrayCStringContext, true).init(allocator);

        selected_extensions.ensureUnusedCapacity(desired_extensions.len) catch |err| {
            selected_extensions.deinit();
            return Res.initError(err, .{});
        };
        for (desired_extensions) |p_desired_extension| {
            const desired_extension = std.mem.span(p_desired_extension);
            if (available_extension_set.getKey(desired_extension)) |str| {
                selected_extensions.putAssumeCapacityNoClobber(str.ptr, {});
            } else {
                return Res.initError(error.ExtensionUnavailable, .{ .unavailable_extension = desired_extension });
            }
        }

        return Res.initOk(selected_extensions.unmanaged);
    }
};

pub const ResultTag = enum { ok, err };
pub fn Result(
    comptime T: type,
    comptime ErrSet: type,
    comptime ErrPayload: type,
) type {
    comptime std.debug.assert(@typeInfo(ErrSet) == .ErrorSet);
    return union(ResultTag) {
        const Self = @This();
        ok: Ok,
        err: Err,

        pub fn initOk(value: Ok) Self {
            return Self{ .ok = value };
        }
        pub fn initError(code: Err.Code, info: Err.Info) Self {
            return Self{ .err = Err{
                .code = code,
                .info = info,
            } };
        }

        pub fn unwrap(self: Self) Err.Code!Ok {
            return switch (self) {
                .ok => |ok| ok,
                .err => |err| err.code,
            };
        }

        pub const Ok = T;
        pub const Err = struct {
            code: Err.Code,
            info: Err.Info,

            pub const Code = ErrSet;
            pub const Info = ErrPayload;
        };
    };
}

const ArrayCStringContext = struct {
    pub fn hash(ctx: @This(), p_str: [*:0]const u8) u32 {
        _ = ctx;
        return std.array_hash_map.StringContext.hash(.{}, std.mem.span(p_str));
    }
    pub fn eql(ctx: @This(), a: [*:0]const u8, b: [*:0]const u8, b_index: usize) bool {
        _ = ctx;
        return std.array_hash_map.StringContext.eql(.{}, std.mem.span(a), std.mem.span(b), b_index);
    }
};

fn freeSliceOfStrings(allocator: std.mem.Allocator, comptime StrType: type, extension_names: []const StrType) void {
    for (extension_names) |p_ext_name| {
        const ext_name = std.mem.span(p_ext_name);
        allocator.free(ext_name);
    }
    allocator.free(extension_names);
}
