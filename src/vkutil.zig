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

pub const allocatorVulkanWrapper = allocation_wrapper.allocatorVulkanWrapper;
const allocation_wrapper = struct {
    fn allocatorVulkanWrapper(p_allocator: *const std.mem.Allocator) vk.AllocationCallbacks {
        return vk.AllocationCallbacks{
            .p_user_data = @intToPtr(*anyopaque, @ptrToInt(p_allocator)),
            .pfn_allocation = allocation,
            .pfn_reallocation = reallocation,
            .pfn_free = free,
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
            .len = size,
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

        const old_bytes = old_ptr[0 .. @sizeOf(Metadata) + old_metadata.len];
        const new_bytes = allocator.reallocBytes(old_bytes, old_metadata.alignment, size, @intCast(u29, alignment), 0, @returnAddress()) catch return null;

        std.mem.bytesAsValue(Metadata, new_bytes[0..@sizeOf(Metadata)]).* = .{
            .len = size,
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

        const bytes = ptr[0 .. @sizeOf(Metadata) + metadata.len];
        return allocator.rawFree(bytes, metadata.alignment, @returnAddress());
    }
};

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

    return base_dsp.createInstance(&create_info, &vkutil.allocatorVulkanWrapper(&allocator));
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
