const std = @import("std");
const vk = @import("vulkan");

const vkutil = @This();

pub fn isBaseWrapper(comptime T: type) bool {
    if (@typeInfo(T) != .Struct) return false;
    if (!@hasDecl(T, "commands")) return false;
    if (!std.meta.declarationInfo(T, "commands").is_pub) return false;
    return T == vk.BaseWrapper(T.commands);
}
pub fn isInstanceWrapper(comptime T: type) bool {
    if (@typeInfo(T) != .Struct) return false;
    if (!@hasDecl(T, "commands")) return false;
    if (!std.meta.declarationInfo(T, "commands").is_pub) return false;
    return T == vk.InstanceWrapper(T.commands);
}
pub fn isDeviceWrapper(comptime T: type) bool {
    if (@typeInfo(T) != .Struct) return false;
    if (!@hasDecl(T, "commands")) return false;
    if (!std.meta.declarationInfo(T, "commands").is_pub) return false;
    return T == vk.DeviceWrapper(T.commands);
}

pub fn fmtApiVersion(version_bits: u32) std.fmt.Formatter(formatApiVersion) {
    return .{ .data = version_bits };
}
fn formatApiVersion(
    version_bits: u32,
    comptime fmt_str: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) @TypeOf(writer).Error!void {
    _ = fmt_str;
    _ = options;

    const variant = vk.apiVersionVariant(version_bits);
    const major = vk.apiVersionMajor(version_bits);
    const minor = vk.apiVersionMinor(version_bits);
    const patch = vk.apiVersionPatch(version_bits);

    if (comptime fmt_str.len > 0 and fmt_str[0] == 'v') {
        try writer.print("{d}.", .{variant});
    }
    try writer.print("{d}.{d}.{d}", .{ major, minor, patch });
}

pub fn loggingDebugMessengerCallback(
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

pub const allocCallbacksFrom = allocation_wrapper.allocCallbacksFrom;
const allocation_wrapper = struct {
    fn allocCallbacksFrom(p_allocator: *const std.mem.Allocator) vk.AllocationCallbacks {
        return vk.AllocationCallbacks{
            .p_user_data = @intToPtr(*anyopaque, @ptrToInt(p_allocator)),
            .pfn_allocation = @as(vk.PfnAllocationFunction, allocation),
            .pfn_reallocation = @as(vk.PfnReallocationFunction, reallocation),
            .pfn_free = @as(vk.PfnFreeFunction, free),
            .pfn_internal_allocation = null,
            .pfn_internal_free = null,
        };
    }

    const Metadata = struct {
        len: usize,
        alignment: u29,
    };
    fn allocation(
        p_user_data: ?*anyopaque,
        size: usize,
        alignment: usize,
        allocation_scope: vk.SystemAllocationScope,
    ) callconv(vk.vulkan_call_conv) ?*anyopaque {
        _ = allocation_scope;
        const allocator = @ptrCast(*const std.mem.Allocator, @alignCast(@alignOf(std.mem.Allocator), p_user_data)).*;

        if (size == 0) return null;

        const bytes = allocator.rawAlloc(@sizeOf(Metadata) + size, @intCast(u29, alignment), 0, @returnAddress()) catch return null;
        std.mem.bytesAsValue(Metadata, bytes[0..@sizeOf(Metadata)]).* = .{
            .len = bytes.len,
            .alignment = @intCast(u29, alignment),
        };

        return @ptrCast(*anyopaque, bytes[@sizeOf(Metadata)..].ptr);
    }

    fn reallocation(
        p_user_data: ?*anyopaque,
        p_original: ?*anyopaque,
        size: usize,
        alignment: usize,
        allocation_scope: vk.SystemAllocationScope,
    ) callconv(vk.vulkan_call_conv) ?*anyopaque {
        if (size == 0) {
            free(p_user_data, p_original);
            return null;
        }

        const allocator = @ptrCast(*const std.mem.Allocator, @alignCast(@alignOf(std.mem.Allocator), p_user_data)).*;

        const old_ptr = (@ptrCast([*]u8, p_original orelse return allocation(p_user_data, size, alignment, allocation_scope)) - @sizeOf(Metadata));
        const old_metadata = std.mem.bytesToValue(Metadata, old_ptr[0..@sizeOf(Metadata)]);

        const old_bytes = old_ptr[0..old_metadata.len];
        const new_bytes = allocator.reallocBytes(old_bytes, old_metadata.alignment, size, @intCast(u29, alignment), 0, @returnAddress()) catch return null;

        std.mem.bytesAsValue(Metadata, new_bytes[0..@sizeOf(Metadata)]).* = .{
            .len = new_bytes.len,
            .alignment = @intCast(u29, alignment),
        };
        return @ptrCast(*anyopaque, new_bytes[@sizeOf(Metadata)..].ptr);
    }

    fn free(
        p_user_data: ?*anyopaque,
        p_memory: ?*anyopaque,
    ) callconv(vk.vulkan_call_conv) void {
        const allocator = @ptrCast(*const std.mem.Allocator, @alignCast(@alignOf(std.mem.Allocator), p_user_data)).*;

        const ptr = (@ptrCast([*]u8, p_memory orelse return) - @sizeOf(Metadata));
        const metadata = std.mem.bytesToValue(Metadata, ptr[0..@sizeOf(Metadata)]);

        const bytes = ptr[0..metadata.len];
        return allocator.rawFree(bytes, metadata.alignment, @returnAddress());
    }
};

pub const InstanceCreateInfo = struct {
    p_next: ?*const anyopaque = null,

    flags: vk.InstanceCreateFlags = .{},
    application_info: ?ApplicationInfo = null,

    enabled_layer_names: []const [*:0]const u8 = &.{},
    enabled_extension_names: []const [*:0]const u8 = &.{},

    pub const ApplicationInfo = struct {
        application_name: ?[:0]const u8,
        application_version: u32,

        engine_name: ?[:0]const u8,
        engine_version: u32,

        api_version: ApiVersion,

        pub const ApiVersion = enum(u32) {
            @"1_0" = vk.API_VERSION_1_0,
            @"1_1" = vk.API_VERSION_1_1,
            @"1_2" = vk.API_VERSION_1_2,
            @"1_3" = vk.API_VERSION_1_3,
            _,
        };
    };
};
pub fn createInstance(
    allocator: std.mem.Allocator,
    base_dsp: anytype,
    instance_create_info: InstanceCreateInfo,
) (std.mem.Allocator.Error || @TypeOf(base_dsp).CreateInstanceError)!vk.Instance {
    comptime std.debug.assert(isBaseWrapper(@TypeOf(base_dsp)));

    const maybe_app_info: ?vk.ApplicationInfo = if (instance_create_info.application_info) |app_info| vk.ApplicationInfo{
        .p_application_name = if (app_info.application_name) |app_name| app_name.ptr else null,
        .application_version = app_info.application_version,

        .p_engine_name = if (app_info.engine_name) |engine_name| engine_name.ptr else null,
        .engine_version = app_info.engine_version,

        .api_version = @enumToInt(app_info.api_version),
    } else null;
    const p_app_info: ?*const vk.ApplicationInfo = if (maybe_app_info) |*app_info| app_info else null;

    const create_info = vk.InstanceCreateInfo{
        .p_next = instance_create_info.p_next,

        .flags = instance_create_info.flags,
        .p_application_info = p_app_info,

        .enabled_layer_count = @intCast(u32, instance_create_info.enabled_layer_names.len),
        .pp_enabled_layer_names = instance_create_info.enabled_layer_names.ptr,

        .enabled_extension_count = @intCast(u32, instance_create_info.enabled_extension_names.len),
        .pp_enabled_extension_names = instance_create_info.enabled_extension_names.ptr,
    };

    return base_dsp.createInstance(&create_info, &vkutil.allocCallbacksFrom(&allocator));
}
pub fn enumerateInstanceLayerPropertiesAlloc(
    allocator: std.mem.Allocator,
    base_dsp: anytype,
) (std.mem.Allocator.Error || @TypeOf(base_dsp).EnumerateInstanceLayerPropertiesError)![]vk.LayerProperties {
    comptime std.debug.assert(isBaseWrapper(@TypeOf(base_dsp)));

    var count: u32 = undefined;
    if (base_dsp.enumerateInstanceLayerProperties(&count, null)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    const layers = try allocator.alloc(vk.LayerProperties, count);
    errdefer allocator.free(layers);

    if (base_dsp.enumerateInstanceLayerProperties(&count, layers.ptr)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    std.debug.assert(layers.len == count);
    return layers;
}
pub fn enumerateInstanceExtensionPropertiesAlloc(
    allocator: std.mem.Allocator,
    base_dsp: anytype,
    layer_name: ?[:0]const u8,
) (std.mem.Allocator.Error || @TypeOf(base_dsp).EnumerateInstanceExtensionPropertiesError)![]vk.ExtensionProperties {
    comptime std.debug.assert(isBaseWrapper(@TypeOf(base_dsp)));

    const p_layer_name: ?[*:0]const u8 = if (layer_name) |ln| ln.ptr else null;

    var count: u32 = undefined;
    if (base_dsp.enumerateInstanceExtensionProperties(p_layer_name, &count, null)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    const extensions = try allocator.alloc(vk.ExtensionProperties, count);
    errdefer allocator.free(extensions);

    if (base_dsp.enumerateInstanceExtensionProperties(p_layer_name, &count, extensions.ptr)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    std.debug.assert(extensions.len == count);
    return extensions;
}
pub fn enumerateInstanceExtensionPropertiesMultipleLayersAlloc(
    allocator: std.mem.Allocator,
    base_dsp: anytype,
    include_base: bool,
    layer_names: []const [:0]const u8,
) (std.mem.Allocator.Error || @TypeOf(base_dsp).EnumerateInstanceExtensionPropertiesError)![]vk.ExtensionProperties {
    comptime std.debug.assert(isBaseWrapper(@TypeOf(base_dsp)));

    const counts = try allocator.alloc(u32, @boolToInt(include_base) + layer_names.len);
    defer allocator.free(counts);

    for (layer_names) |layer_name, i| {
        if (base_dsp.enumerateInstanceExtensionProperties(layer_name.ptr, &counts[i], null)) |result| switch (result) {
            .success => {},
            else => unreachable,
        } else |err| return err;
    }

    const extensions = try allocator.alloc(vk.ExtensionProperties, full_count: {
        var full_count: usize = 0;
        for (counts) |count| {
            full_count += count;
        }
        break :full_count full_count;
    });
    errdefer allocator.free(extensions);

    {
        var start: usize = 0;
        for (layer_names) |layer_name, i| {
            const len = counts[i];

            if (base_dsp.enumerateInstanceExtensionProperties(layer_name.ptr, &counts[i], extensions[start .. start + len].ptr)) |result| switch (result) {
                .success => {},
                else => unreachable,
            } else |err| return err;

            std.debug.assert(len == counts[i]);
            start += len;
        }
    }

    return extensions;
}

pub fn destroyInstance(
    allocator: std.mem.Allocator,
    instance_dsp: anytype,
    instance: vk.Instance,
) void {
    comptime std.debug.assert(isInstanceWrapper(@TypeOf(instance_dsp)));
    instance_dsp.destroyInstance(instance, &vkutil.allocCallbacksFrom(&allocator));
}
pub fn getPhysicalDeviceSurfaceFormatsKHRAlloc(
    allocator: std.mem.Allocator,
    instance_dsp: anytype,
    physical_device: vk.PhysicalDevice,
    surface_khr: vk.SurfaceKHR,
) (std.mem.Allocator.Error || @TypeOf(instance_dsp).GetPhysicalDeviceSurfaceFormatsKHRError)![]vk.SurfaceFormatKHR {
    comptime std.debug.assert(isInstanceWrapper(@TypeOf(instance_dsp)));

    var count: u32 = undefined;
    if (instance_dsp.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface_khr, &count, null)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    const formats = try allocator.alloc(vk.SurfaceFormatKHR, count);
    errdefer allocator.free(formats);

    if (instance_dsp.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface_khr, &count, formats.ptr)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    std.debug.assert(formats.len == count);
    return formats;
}
pub fn getPhysicalDeviceSurfacePresentModesKHRAlloc(
    allocator: std.mem.Allocator,
    instance_dsp: anytype,
    physical_device: vk.PhysicalDevice,
    surface_khr: vk.SurfaceKHR,
) (std.mem.Allocator.Error || @TypeOf(instance_dsp).GetPhysicalDeviceSurfacePresentModesKHRError)![]vk.PresentModeKHR {
    comptime std.debug.assert(isInstanceWrapper(@TypeOf(instance_dsp)));

    var count: u32 = undefined;
    if (instance_dsp.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface_khr, &count, null)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    const present_modes = try allocator.alloc(vk.PresentModeKHR, count);
    errdefer allocator.free(present_modes);

    if (instance_dsp.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface_khr, &count, present_modes.ptr)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    std.debug.assert(present_modes.len == count);
    return present_modes;
}
pub fn enumerateDeviceExtensionPropertiesAlloc(
    allocator: std.mem.Allocator,
    instance_dsp: anytype,
    physical_device: vk.PhysicalDevice,
) (std.mem.Allocator.Error || @TypeOf(instance_dsp).EnumerateDeviceExtensionPropertiesError)![]vk.ExtensionProperties {
    comptime std.debug.assert(isInstanceWrapper(@TypeOf(instance_dsp)));

    var count: u32 = undefined;
    if (instance_dsp.enumerateDeviceExtensionProperties(physical_device, null, &count, null)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    const extensions = try allocator.alloc(vk.ExtensionProperties, count);
    errdefer allocator.free(extensions);

    if (instance_dsp.enumerateDeviceExtensionProperties(physical_device, null, &count, extensions.ptr)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    std.debug.assert(extensions.len == count);
    return extensions;
}
pub fn getPhysicalDeviceQueueFamilyPropertiesAlloc(
    allocator: std.mem.Allocator,
    instance_dsp: anytype,
    physical_device: vk.PhysicalDevice,
) std.mem.Allocator.Error![]vk.QueueFamilyProperties {
    comptime std.debug.assert(isInstanceWrapper(@TypeOf(instance_dsp)));

    var count: u32 = undefined;

    instance_dsp.getPhysicalDeviceQueueFamilyProperties(physical_device, &count, null);
    const properties = try allocator.alloc(vk.QueueFamilyProperties, count);
    errdefer allocator.free(properties);

    instance_dsp.getPhysicalDeviceQueueFamilyProperties(physical_device, &count, properties.ptr);
    std.debug.assert(properties.len == count);

    return properties;
}
pub fn enumeratePhysicalDevicesAlloc(
    allocator: std.mem.Allocator,
    instance_dsp: anytype,
    instance: vk.Instance,
) (std.mem.Allocator.Error || @TypeOf(instance_dsp).EnumeratePhysicalDevicesError)![]vk.PhysicalDevice {
    comptime std.debug.assert(isInstanceWrapper(@TypeOf(instance_dsp)));

    var count: u32 = undefined;
    if (instance_dsp.enumeratePhysicalDevices(instance, &count, null)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    const physical_devices = try allocator.alloc(vk.PhysicalDevice, count);
    errdefer allocator.free(physical_devices);

    if (instance_dsp.enumeratePhysicalDevices(instance, &count, physical_devices.ptr)) |result| switch (result) {
        .success => {},
        else => unreachable,
    } else |err| return err;

    std.debug.assert(physical_devices.len == count);
    return physical_devices;
}
pub fn createDebugUtilsMessengerEXT(
    allocator: std.mem.Allocator,
    instance_dsp: anytype,
    instance: vk.Instance,
    create_info: vk.DebugUtilsMessengerCreateInfoEXT,
) @TypeOf(instance_dsp).CreateDebugUtilsMessengerEXTError!vk.DebugUtilsMessengerEXT {
    comptime std.debug.assert(isInstanceWrapper(@TypeOf(instance_dsp)));
    return instance_dsp.createDebugUtilsMessengerEXT(instance, &create_info, &vkutil.allocCallbacksFrom(&allocator));
}
pub fn destroyDebugUtilsMessengerEXT(
    allocator: std.mem.Allocator,
    instance_dsp: anytype,
    instance: vk.Instance,
    messenger: vk.DebugUtilsMessengerEXT,
) void {
    comptime std.debug.assert(isInstanceWrapper(@TypeOf(instance_dsp)));
    return instance_dsp.destroyDebugUtilsMessengerEXT(instance, messenger, &vkutil.allocCallbacksFrom(&allocator));
}

pub const DeviceCreateInfo = struct {
    p_next: ?*const anyopaque = null,
    flags: vk.DeviceCreateFlags = .{},

    queue_create_infos: []const vk.DeviceQueueCreateInfo,
    enabled_extension_names: []const [*:0]const u8 = &.{},
    enabled_features: ?vk.PhysicalDeviceFeatures = null,
};
pub fn createDevice(
    allocator: std.mem.Allocator,
    instance_dsp: anytype,
    physical_device: vk.PhysicalDevice,
    create_info: DeviceCreateInfo,
) @TypeOf(instance_dsp).CreateDeviceError!vk.Device {
    comptime std.debug.assert(isInstanceWrapper(@TypeOf(instance_dsp)));
    return instance_dsp.createDevice(
        physical_device,
        &vk.DeviceCreateInfo{
            .p_next = create_info.p_next,
            .flags = create_info.flags,

            .queue_create_info_count = @intCast(u32, create_info.queue_create_infos.len),
            .p_queue_create_infos = create_info.queue_create_infos.ptr,

            .enabled_layer_count = 0,
            .pp_enabled_layer_names = std.mem.span(&[_][*:0]const u8{}).ptr,

            .enabled_extension_count = @intCast(u32, create_info.enabled_extension_names.len),
            .pp_enabled_extension_names = create_info.enabled_extension_names.ptr,

            .p_enabled_features = if (create_info.enabled_features) |*features| features else null,
        },
        &vkutil.allocCallbacksFrom(&allocator),
    );
}
pub fn destroyDevice(
    allocator: std.mem.Allocator,
    device_dsp: anytype,
    device: vk.Device,
) void {
    comptime std.debug.assert(isDeviceWrapper(@TypeOf(device_dsp)));
    return device_dsp.destroyDevice(device, &vkutil.allocCallbacksFrom(&allocator));
}

pub const SwapchainCreateInfoKHR = struct {
    p_next: ?*const anyopaque = null,
    flags: vk.SwapchainCreateFlagsKHR = .{},

    surface: vk.SurfaceKHR,

    min_image_count: u32,
    image_format: vk.Format,
    image_color_space: vk.ColorSpaceKHR,
    image_extent: vk.Extent2D,
    image_array_layers: u32,
    image_usage: vk.ImageUsageFlags,
    image_sharing_mode: vk.SharingMode,

    queue_family_indices: []const u32,

    pre_transform: vk.SurfaceTransformFlagsKHR,
    composite_alpha: vk.CompositeAlphaFlagsKHR,
    present_mode: vk.PresentModeKHR,
    clipped: bool,

    old_swapchain: vk.SwapchainKHR = .null_handle,
};
pub fn createSwapchainKHR(
    allocator: std.mem.Allocator,
    device_dsp: anytype,
    device: vk.Device,
    create_info: SwapchainCreateInfoKHR,
) @TypeOf(device_dsp).CreateSwapchainKHRError!vk.SwapchainKHR {
    comptime std.debug.assert(isDeviceWrapper(@TypeOf(device_dsp)));
    return device_dsp.createSwapchainKHR(device, &vk.SwapchainCreateInfoKHR{
        .p_next = create_info.p_next,
        .flags = create_info.flags,

        .surface = create_info.surface,

        .min_image_count = create_info.min_image_count,
        .image_format = create_info.image_format,
        .image_color_space = create_info.image_color_space,
        .image_extent = create_info.image_extent,
        .image_array_layers = create_info.image_array_layers,
        .image_usage = create_info.image_usage,
        .image_sharing_mode = create_info.image_sharing_mode,

        .queue_family_index_count = @intCast(u32, create_info.queue_family_indices.len),
        .p_queue_family_indices = create_info.queue_family_indices.ptr,

        .pre_transform = create_info.pre_transform,
        .composite_alpha = create_info.composite_alpha,
        .present_mode = create_info.present_mode,
        .clipped = if (create_info.clipped) vk.TRUE else vk.FALSE,

        .old_swapchain = create_info.old_swapchain,
    }, &vkutil.allocCallbacksFrom(&allocator));
}
pub fn destroySwapchainKHR(
    allocator: std.mem.Allocator,
    device_dsp: anytype,
    device: vk.Device,
    swapchain: vk.SwapchainKHR,
) void {
    comptime std.debug.assert(isDeviceWrapper(@TypeOf(device_dsp)));
    return device_dsp.destroySwapchainKHR(device, swapchain, &vkutil.allocCallbacksFrom(&allocator));
}
pub fn createImageView(
    allocator: std.mem.Allocator,
    device_dsp: anytype,
    device: vk.Device,
    create_info: vk.ImageViewCreateInfo,
) @TypeOf(device_dsp).CreateImageViewError!vk.ImageView {
    comptime std.debug.assert(isDeviceWrapper(@TypeOf(device_dsp)));
    return device_dsp.createImageView(device, &create_info, &vkutil.allocCallbacksFrom(&allocator));
}
pub fn destroyImageView(
    allocator: std.mem.Allocator,
    device_dsp: anytype,
    device: vk.Device,
    image_view: vk.ImageView,
) void {
    comptime std.debug.assert(isDeviceWrapper(@TypeOf(device_dsp)));
    return device_dsp.destroyImageView(device, image_view, &vkutil.allocCallbacksFrom(&allocator));
}

pub const BufferCreateInfo = struct {
    p_next: ?*const anyopaque = null,
    flags: vk.BufferCreateFlags = .{},

    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,

    sharing_mode: vk.SharingMode,
    queue_family_indices: []const u32,
};
pub fn createBuffer(
    allocator: std.mem.Allocator,
    device_dsp: anytype,
    device: vk.Device,
    create_info: BufferCreateInfo,
) @TypeOf(device_dsp).CreateBufferError!vk.Buffer {
    return device_dsp.createBuffer(device, &vk.BufferCreateInfo{
        .p_next = create_info.p_next,
        .flags = create_info.flags,

        .size = create_info.size,
        .usage = create_info.usage,

        .sharing_mode = create_info.sharing_mode,

        .queue_family_index_count = @intCast(u32, create_info.queue_family_indices.len),
        .p_queue_family_indices = create_info.queue_family_indices.ptr,
    }, &vkutil.allocCallbacksFrom(&allocator));
}
pub fn destroyBuffer(
    allocator: std.mem.Allocator,
    device_dsp: anytype,
    device: vk.Device,
    buffer: vk.Buffer,
) void {
    return device_dsp.destroyBuffer(device, buffer, &vkutil.allocCallbacksFrom(&allocator));
}
