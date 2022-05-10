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
    _ = allocator;

    try glfw.init(.{});
    defer glfw.terminate();

    const inst: VkInstance = try VkInstance.create(allocator, getInstanceProcAddress, .{
        .desired_layers = &.{},
        .desired_extensions = try glfw.getRequiredInstanceExtensions(),
    });
    defer inst.dsp.destroyInstance(inst.handle, &allocatorVulkanWrapper(&allocator));
}

const VkInstance = struct {
    handle: vk.Instance,
    dsp: InstanceDispatch,

    const CreateArgs = struct {
        desired_layers: []const [*:0]const u8,
        desired_extensions: []const [*:0]const u8,
    };
    fn create(
        allocator: std.mem.Allocator,
        loader: anytype,
        args: CreateArgs,
    ) !VkInstance {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();

        const arena = arena_state.allocator();

        const bd = try BaseDispatch.load(loader);

        const instance_version = try bd.enumerateInstanceVersion();
        std.log.info("Instance Version: {}", .{fmtApiVersion(instance_version)});

        const available_layers: []const vk.LayerProperties = available_layers: {
            var count: u32 = undefined;
            if (bd.enumerateInstanceLayerProperties(&count, null)) |result| switch (result) {
                .success => {},
                else => std.log.warn("`enumerateInstanceLayerProperties`: {s}\n", .{@tagName(result)}),
            } else |err| return err;

            const available_layers = try arena.alloc(vk.LayerProperties, count);
            if (bd.enumerateInstanceLayerProperties(&count, available_layers.ptr)) |result| switch (result) {
                .success => {},
                else => std.log.warn("`enumerateInstanceLayerProperties`: {s}\n", .{@tagName(result)}),
            } else |err| return err;

            std.debug.assert(count == available_layers.len);
            break :available_layers available_layers;
        };
        defer arena.free(available_layers);

        const available_extensions: []const vk.ExtensionProperties = available_extensions: {
            var count: u32 = undefined;
            if (bd.enumerateInstanceExtensionProperties(null, &count, null)) |result| switch (result) {
                .success => {},
                else => std.log.warn("`enumerateInstanceExtensionProperties`: {s}\n", .{@tagName(result)}),
            } else |err| return err;

            const available_extensions = try arena.alloc(vk.ExtensionProperties, count);
            if (bd.enumerateInstanceExtensionProperties(null, &count, available_extensions.ptr)) |result| switch (result) {
                .success => {},
                else => std.log.warn("`enumerateInstanceExtensionProperties`: {s}\n", .{@tagName(result)}),
            } else |err| return err;

            std.debug.assert(count == available_extensions.len);
            break :available_extensions available_extensions;
        };
        defer arena.free(available_extensions);

        {
            var log_buffer = std.ArrayList(u8).init(arena);
            defer log_buffer.deinit();

            log_buffer.shrinkRetainingCapacity(0);
            try log_buffer.writer().writeAll("Found Layers:\n");
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
            try log_buffer.writer().writeAll("Found Extensions:\n");
            for (available_extensions) |*extension| {
                try log_buffer.writer().print(
                    \\(*) {s}: {}
                    \\
                , .{ std.mem.sliceTo(&extension.extension_name, 0), fmtApiVersion(extension.spec_version) });
            }
            log_buffer.shrinkRetainingCapacity(log_buffer.items.len - 1);
            std.log.debug("{s}\n", .{log_buffer.items});
        }

        const handle = try bd.createInstance(&vk.InstanceCreateInfo{
            .flags = vk.InstanceCreateFlags{},
            .p_application_info = &vk.ApplicationInfo{
                .p_application_name = "vk-spincube",
                .application_version = vk.makeApiVersion(0, 0, 0, 0),

                .p_engine_name = null,
                .engine_version = 0,

                .api_version = vk.API_VERSION_1_0,
            },

            .enabled_layer_count = @intCast(u32, args.desired_layers.len),
            .pp_enabled_layer_names = args.desired_layers.ptr,

            .enabled_extension_count = @intCast(u32, args.desired_extensions.len),
            .pp_enabled_extension_names = args.desired_extensions.ptr,
        }, &allocatorVulkanWrapper(&allocator));
        const dsp = InstanceDispatch.load(handle, getInstanceProcAddress) catch |err| {
            if (InstanceDispatchMin.load(handle, getInstanceProcAddress)) |inst_dsp_min| {
                inst_dsp_min.destroyInstance(handle, &allocatorVulkanWrapper(&allocator));
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
};

const CStringSet = std.ArrayHashMapUnmanaged([*:0]const u8, void, struct {
    pub fn hash(ctx: @This(), c_str: [*:0]const u8) u32 {
        _ = ctx;
        return std.array_hash_map.StringContext.hash(.{}, std.mem.span(c_str));
    }
    pub fn eql(ctx: @This(), a: [*:0]const u8, b: [*:0]const u8, b_index: usize) bool {
        _ = ctx;
        _ = b_index;
        if (a == b) return true;
        var len: usize = 0;
        while (true) : (len += 1) {
            if (a[len] == 0 and b[len] == 0) break;
            if (a[len] == 0 and b[len] != 0) return false;
            if (a[len] != 0 and b[len] == 0) return false;
        }
        return std.mem.eql(u8, a[0..len], b[0..len]);
    }
}, true);

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
