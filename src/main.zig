const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const glfw = @import("glfw");

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
    .createDevice = true,
});

fn getInstanceProcAddress(handle: vk.Instance, name: [*:0]const u8) ?*const anyopaque {
    const inst_ptr = @intToPtr(?*anyopaque, @enumToInt(handle));
    const result: glfw.VKProc = glfw.getInstanceProcAddress(inst_ptr, name) orelse return null;
    return @ptrCast(*const anyopaque, result);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = false }){};
    defer _ = gpa.deinit();

    const allocator: std.mem.Allocator = gpa.allocator();

    try glfw.init(.{});
    defer glfw.terminate();

    const engine: VkEngine = try VkEngine.init(allocator, getInstanceProcAddress, .{
        .desired_layers = &.{},
        .desired_extensions = &.{},
    });
    defer engine.deinit(allocator);
}

const VkEngine = struct {
    inst: VkInstance,

    pub fn init(
        allocator: std.mem.Allocator,
        instanceProcLoader: anytype,
        create_instance_args: CreateVkInstanceArgs,
    ) !VkEngine {
        const inst = try createVkInstance(allocator, instanceProcLoader, create_instance_args);
        errdefer destroyVkInstance(allocator, inst);

        return VkEngine{
            .inst = inst,
        };
    }

    pub fn deinit(self: VkEngine, allocator: std.mem.Allocator) void {
        destroyVkInstance(allocator, self.inst);
    }

    const VkInstance = struct {
        handle: vk.Instance,
        dsp: InstanceDispatch,
    };

    const CreateVkInstanceArgs = struct {
        desired_layers: []const [*:0]const u8 = &.{},
        desired_layers_if_not_found: []const NotFoundStrategy = &.{},

        desired_extensions: []const [*:0]const u8 = &.{},
        desired_extensions_if_not_found: []const NotFoundStrategy = &.{},

        desired_layers_if_not_found_default: NotFoundStrategy = .err,
        desired_extensions_if_not_found_default: NotFoundStrategy = .err,

        const NotFoundStrategy = enum { silent, log, err };
    };
    fn createVkInstance(
        allocator: std.mem.Allocator,
        loader: anytype,
        args: CreateVkInstanceArgs,
    ) !VkInstance {
        std.debug.assert(args.desired_extensions_if_not_found.len <= args.desired_extensions.len);
        std.debug.assert(args.desired_layers_if_not_found.len <= args.desired_layers.len);

        const p_vk_allocator: *const vk.AllocationCallbacks = &allocatorVulkanWrapper(&allocator);
        const bd = try BaseDispatch.load(loader);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const instance_version = try bd.enumerateInstanceVersion();
        std.log.info("Instance Version: {}", .{fmtApiVersion(instance_version)});

        const available_layers: []const vk.LayerProperties = try enumerateInstanceLayerPropertiesAlloc(arena, bd);
        const available_extensions: []const vk.ExtensionProperties = try enumerateInstanceExtensionPropertiesAlloc(arena, bd, null);
        try logLayersAndExtensions(arena, available_layers, available_extensions);

        for (args.desired_layers) |p_layer_name, i| {
            const not_found_strat: CreateVkInstanceArgs.NotFoundStrategy = if (i < args.desired_layers_if_not_found.len)
                args.desired_layers_if_not_found[i]
            else
                args.desired_layers_if_not_found_default;
            const layer_name: []const u8 = std.mem.span(p_layer_name);

            const key: vk.LayerProperties = key: {
                var key: vk.LayerProperties = undefined;
                std.debug.assert(layer_name.len <= key.layer_name.len);
                std.mem.set(u8, &key.layer_name, 0);
                std.mem.copy(u8, &key.layer_name, layer_name);
                break :key key;
            };

            const index = std.sort.binarySearch(vk.LayerProperties, key, available_layers, void{}, struct {
                fn compare(ctx: void, lhs: vk.LayerProperties, rhs: vk.LayerProperties) std.math.Order {
                    _ = ctx;
                    return std.mem.order(u8, &lhs.layer_name, &rhs.layer_name);
                }
            }.compare);
            if (index == null) {
                switch (not_found_strat) {
                    .silent => {},
                    .log, .err => std.log.err("Failed to find instance layer '{s}'.", .{layer_name}),
                }
                switch (not_found_strat) {
                    .silent, .log => {},
                    .err => return error.DesiredInstanceLayerNotFound,
                }
            }
        }

        for (args.desired_extensions) |p_extension_name, i| {
            const not_found_strat: CreateVkInstanceArgs.NotFoundStrategy = if (i < args.desired_extensions_if_not_found.len)
                args.desired_extensions_if_not_found[i]
            else
                args.desired_extensions_if_not_found_default;
            const extension_name = std.mem.span(p_extension_name);

            const key: vk.ExtensionProperties = key: {
                var key: vk.ExtensionProperties = undefined;
                std.mem.set(u8, &key.extension_name, 0);
                std.mem.copy(u8, &key.extension_name, extension_name);
                break :key key;
            };

            const index = std.sort.binarySearch(vk.ExtensionProperties, key, available_extensions, void{}, struct {
                fn compare(ctx: void, lhs: vk.ExtensionProperties, rhs: vk.ExtensionProperties) std.math.Order {
                    _ = ctx;
                    return std.mem.order(u8, &lhs.extension_name, &rhs.extension_name);
                }
            }.compare);
            if (index == null) {
                switch (not_found_strat) {
                    .silent => {},
                    .log, .err => std.log.err("Failed to find instance extension '{s}'.", .{extension_name}),
                }
                switch (not_found_strat) {
                    .silent, .log => {},
                    .err => return error.DesiredInstanceExtensionNotFound,
                }
            }
        }

        const handle = try bd.createInstance(&vk.InstanceCreateInfo{
            .flags = vk.InstanceCreateFlags{},
            .p_application_info = &vk.ApplicationInfo{
                .p_application_name = "vk-spincube",
                .application_version = vk.makeApiVersion(0, 0, 0, 0),

                .p_engine_name = null,
                .engine_version = 0,

                .api_version = switch (vk.apiVersionMinor(instance_version)) {
                    0 => vk.API_VERSION_1_0,
                    1 => vk.API_VERSION_1_1,
                    2 => vk.API_VERSION_1_2,
                    else => vk.API_VERSION_1_3,
                },
            },

            .enabled_layer_count = @intCast(u32, args.desired_layers.len),
            .pp_enabled_layer_names = args.desired_layers.ptr,

            .enabled_extension_count = @intCast(u32, args.desired_extensions.len),
            .pp_enabled_extension_names = args.desired_extensions.ptr,
        }, p_vk_allocator);
        const dsp = InstanceDispatch.load(handle, getInstanceProcAddress) catch |err| {
            if (InstanceDispatchMin.load(handle, getInstanceProcAddress)) |inst_dsp_min| {
                inst_dsp_min.destroyInstance(handle, p_vk_allocator);
            } else |_| {
                std.log.warn("Failed to load function to destroy vulkan instance before encountering error; cleanup not possible.", .{});
            }
            return err;
        };
        return VkInstance{
            .handle = handle,
            .dsp = dsp,
        };
    }
    fn destroyVkInstance(allocator: std.mem.Allocator, inst: VkInstance) void {
        inst.dsp.destroyInstance(inst.handle, &allocatorVulkanWrapper(&allocator));
    }

    fn logLayersAndExtensions(
        allocator: std.mem.Allocator,
        available_layers: []const vk.LayerProperties,
        available_extensions: []const vk.ExtensionProperties,
    ) !void {
        var log_buffer = std.ArrayList(u8).init(allocator);
        defer log_buffer.deinit();

        log_buffer.shrinkRetainingCapacity(0);
        try log_buffer.writer().writeAll("Available Layers:\n");
        for (available_layers) |*layer| {
            try log_buffer.writer().print(
                \\(*) Name: {s}
                \\    Spec: {}
                \\    Impl: {}
                \\    Description: {s}
                \\
                \\
            , .{
                std.mem.sliceTo(&layer.layer_name, 0),
                fmtApiVersion(layer.spec_version),
                fmtApiVersion(layer.implementation_version),
                std.mem.sliceTo(&layer.description, 0),
            });
        }
        log_buffer.shrinkRetainingCapacity(log_buffer.items.len - 2);
        std.log.debug("{s}\n", .{log_buffer.items});

        log_buffer.shrinkRetainingCapacity(0);
        try log_buffer.writer().writeAll("Available Extensions:\n");
        for (available_extensions) |*extension| {
            try log_buffer.writer().print(
                \\(*) {s}: {}
                \\
            , .{ std.mem.sliceTo(&extension.extension_name, 0), fmtApiVersion(extension.spec_version) });
        }
        log_buffer.shrinkRetainingCapacity(log_buffer.items.len - 1);

        std.log.debug("{s}\n", .{log_buffer.items});
    }

    fn enumerateInstanceLayerPropertiesAlloc(
        allocator: std.mem.Allocator,
        bd: BaseDispatch,
    ) ![]vk.LayerProperties {
        var count: u32 = undefined;
        if (bd.enumerateInstanceLayerProperties(&count, null)) |result| switch (result) {
            .success => {},
            else => std.log.warn("`{s}`: {s}\n", .{ @src().fn_name, @tagName(result) }),
        } else |err| return err;

        const layer_properties = try allocator.alloc(vk.LayerProperties, count);
        errdefer allocator.free(layer_properties);

        if (bd.enumerateInstanceLayerProperties(&count, layer_properties.ptr)) |result| switch (result) {
            .success => {},
            else => std.log.warn("`{s}`: {s}\n", .{ @src().fn_name, @tagName(result) }),
        } else |err| return err;

        std.debug.assert(layer_properties.len == count);
        return layer_properties;
    }
    fn enumerateInstanceExtensionPropertiesAlloc(
        allocator: std.mem.Allocator,
        bd: BaseDispatch,
        layer_name: ?[:0]const u8,
    ) ![]vk.ExtensionProperties {
        const p_layer_name: ?[*:0]const u8 = if (layer_name) |ln| ln.ptr else null;

        var count: u32 = undefined;
        if (bd.enumerateInstanceExtensionProperties(p_layer_name, &count, null)) |result| switch (result) {
            .success => {},
            else => std.log.warn("`{s}`: {s}\n", .{ @src().fn_name, @tagName(result) }),
        } else |err| return err;

        const extension_properties = try allocator.alloc(vk.ExtensionProperties, count);
        errdefer allocator.free(extension_properties);

        if (bd.enumerateInstanceExtensionProperties(p_layer_name, &count, extension_properties.ptr)) |result| switch (result) {
            .success => {},
            else => std.log.warn("`{s}`: {s}\n", .{ @src().fn_name, @tagName(result) }),
        } else |err| return err;

        std.debug.assert(extension_properties.len == count);
        return extension_properties;
    }
};

fn allocatorVulkanWrapper(p_allocator: *const std.mem.Allocator) vk.AllocationCallbacks {
    const static = struct {
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

            const bytes = allocator.allocBytes(@intCast(u29, alignment), @sizeOf(Metadata) + size, 0, @returnAddress()) catch return null;
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
    return vk.AllocationCallbacks{
        .p_user_data = @intToPtr(*anyopaque, @ptrToInt(p_allocator)),
        .pfn_allocation = static.allocation,
        .pfn_reallocation = static.reallocation,
        .pfn_free = static.free,
        .pfn_internal_allocation = null,
        .pfn_internal_free = null,
    };
}

fn fmtApiVersion(version_bits: u32) std.fmt.Formatter(formatApiVersion) {
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
