const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
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

    .createDebugUtilsMessengerEXT = build_options.vk_validation_layers,
    .destroyDebugUtilsMessengerEXT = build_options.vk_validation_layers,
});

fn getInstanceProcAddress(handle: vk.Instance, name: [*:0]const u8) ?*const anyopaque {
    const inst_ptr = @intToPtr(?*anyopaque, @enumToInt(handle));
    const result: glfw.VKProc = glfw.getInstanceProcAddress(inst_ptr, name) orelse return null;
    return @ptrCast(*const anyopaque, result);
}

const file_logger = @import("file_logger.zig");
pub const log = file_logger.log;

pub fn main() !void {
    try file_logger.init("vulkan-spincube.log");
    defer file_logger.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = false }){};
    defer _ = gpa.deinit();

    const allocator: std.mem.Allocator = gpa.allocator();

    try glfw.init(.{});
    defer glfw.terminate();

    const engine = try VkEngine.init(allocator, getInstanceProcAddress);
    defer engine.deinit(allocator);
}

const VkEngine = struct {
    inst: VkInst,
    debug_messenger: if (build_options.vk_validation_layers) vk.DebugUtilsMessengerEXT else void,

    const VkInst = struct { handle: vk.Instance, dsp: InstanceDispatch };

    pub fn init(allocator: std.mem.Allocator, instanceProcLoader: anytype) !VkEngine {
        const inst: VkInst = try initVkInst(allocator, instanceProcLoader);
        errdefer inst.dsp.destroyInstance(inst.handle, &allocatorVulkanWrapper(&allocator));

        const debug_messenger = if (build_options.vk_validation_layers) try createVkDebugMessenger(allocator, inst) else {};
        errdefer if (build_options.vk_validation_layers) destroyVkDebugMessenger(allocator, inst, debug_messenger);

        return VkEngine{
            .inst = inst,
            .debug_messenger = debug_messenger,
        };
    }
    pub fn deinit(self: VkEngine, allocator: std.mem.Allocator) void {
        if (build_options.vk_validation_layers) {
            self.inst.dsp.destroyDebugUtilsMessengerEXT(self.inst.handle, self.debug_messenger, &allocatorVulkanWrapper(&allocator));
        }
        self.inst.dsp.destroyInstance(self.inst.handle, &allocatorVulkanWrapper(&allocator));
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
        }, &allocatorVulkanWrapper(&allocator));
    }
    fn destroyVkDebugMessenger(allocator: std.mem.Allocator, inst: VkInst, debug_messenger: vk.DebugUtilsMessengerEXT) void {
        inst.dsp.destroyDebugUtilsMessengerEXT(inst.handle, debug_messenger, &allocatorVulkanWrapper(&allocator));
    }
    fn vulkanDebugMessengerCallback(
        msg_severity_int: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
        message_types: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
        opt_p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
        p_user_data: ?*anyopaque,
    ) callconv(vk.vulkan_call_conv) vk.Bool32 {
        _ = message_types;
        _ = p_user_data;

        const logger = std.log.scoped(.vulkan_debug_messenger);
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

    fn initVkInst(allocator: std.mem.Allocator, instanceProcLoader: anytype) !VkInst {
        var local_arena_state = std.heap.ArenaAllocator.init(allocator);
        defer local_arena_state.deinit();

        const local_arena = local_arena_state.allocator();

        const bd = try BaseDispatch.load(instanceProcLoader);

        const desired_layers = try desiredInstanceLayerNames(local_arena);
        const available_layers: []const vk.LayerProperties = try enumerateInstanceLayerPropertiesAlloc(local_arena, bd);
        const available_layer_set: std.StringArrayHashMap(void).Unmanaged = available_layer_set: {
            var available_layer_set = std.StringArrayHashMap(void).init(local_arena);

            for (available_layers) |*layer| {
                const str = std.mem.sliceTo(std.mem.span(&layer.layer_name), 0);
                try available_layer_set.putNoClobber(str, {});
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

        const desired_extensions = try desiredInstanceExtensionNames(local_arena);
        const available_extensions = try enumerateInstanceExtensionPropertiesAlloc(local_arena, bd, null);
        const available_extension_set: std.StringArrayHashMap(void).Unmanaged = available_extension_set: {
            var available_extension_set = std.StringArrayHashMap(void).init(local_arena);

            for (available_extensions) |*ext| {
                const str = std.mem.sliceTo(std.mem.span(&ext.extension_name), 0);
                try available_extension_set.putNoClobber(str, {});
            }

            break :available_extension_set available_extension_set.unmanaged;
        };
        const selected_extensions: std.ArrayHashMapUnmanaged([*:0]const u8, void, ArrayCStringContext, true) = selected_extensions: {
            var selected_extensions = std.ArrayHashMap([*:0]const u8, void, ArrayCStringContext, true).init(allocator);
            errdefer selected_extensions.deinit();

            try selected_extensions.ensureUnusedCapacity(desired_extensions.len);
            for (desired_extensions) |p_desired_extension| {
                const desired_extension = std.mem.span(p_desired_extension);
                if (available_extension_set.contains(desired_extension)) {
                    selected_extensions.putAssumeCapacityNoClobber(desired_extension, {});
                } else {
                    std.log.warn("Desired extension '{s}' not available.", .{desired_extension});
                }
            }

            break :selected_extensions selected_extensions.unmanaged;
        };

        {
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
                            std.mem.span(&layer.description),
                            fmtApiVersion(layer.implementation_version),
                            fmtApiVersion(layer.spec_version),
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
                            fmtApiVersion(ext.spec_version),
                        },
                    );
                }
                std.log.debug("{s}", .{log_buff.items});
            }
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

        const handle = try createInstance(allocator, bd, InstanceCreateInfo{
            .p_next = if (build_options.vk_validation_layers) &inst_debug_messenger_creation_info else null,
            .enabled_layer_names = selected_layers.keys(),
            .enabled_extension_names = selected_extensions.keys(),
        });
        const dsp = InstanceDispatch.load(handle, instanceProcLoader) catch |err| {
            const min_dsp = InstanceDispatchMin.load(handle, instanceProcLoader) catch return err;
            min_dsp.destroyInstance(handle, &allocatorVulkanWrapper(&allocator));
            return err;
        };
        errdefer dsp.destroyInstance(handle, &allocatorVulkanWrapper(&allocator));

        return VkInst{
            .handle = handle,
            .dsp = dsp,
        };
    }

    fn desiredInstanceLayerNames(allocator: std.mem.Allocator) ![]const [*:0]const u8 {
        var result = std.ArrayList([*:0]const u8).init(allocator);
        errdefer freeCStringSlice(allocator, result.toOwnedSlice());

        return result.toOwnedSlice();
    }
    fn desiredInstanceExtensionNames(allocator: std.mem.Allocator) ![]const [*:0]const u8 {
        var result = std.ArrayList([*:0]const u8).init(allocator);
        errdefer freeCStringSlice(allocator, result.toOwnedSlice());

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
    fn freeCStringSlice(allocator: std.mem.Allocator, extension_names: []const [*:0]const u8) void {
        for (extension_names) |p_ext_name| {
            const ext_name = std.mem.span(p_ext_name);
            allocator.free(ext_name);
        }
        allocator.free(extension_names);
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
        bd: BaseDispatch,
        instance_create_info: InstanceCreateInfo,
    ) !vk.Instance {
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

        return bd.createInstance(&create_info, &allocatorVulkanWrapper(&allocator));
    }
    pub fn enumerateInstanceLayerPropertiesAlloc(
        allocator: std.mem.Allocator,
        bd: BaseDispatch,
    ) ![]vk.LayerProperties {
        var count: u32 = undefined;
        if (bd.enumerateInstanceLayerProperties(&count, null)) |result| switch (result) {
            .success => {},
            else => unreachable,
        } else |err| return err;

        const layers = try allocator.alloc(vk.LayerProperties, count);
        errdefer allocator.free(layers);

        if (bd.enumerateInstanceLayerProperties(&count, layers.ptr)) |result| switch (result) {
            .success => {},
            else => unreachable,
        } else |err| return err;

        std.debug.assert(layers.len == count);
        return layers;
    }
    pub fn enumerateInstanceExtensionPropertiesAlloc(
        allocator: std.mem.Allocator,
        bd: BaseDispatch,
        layer_name: ?[:0]const u8,
    ) ![]vk.ExtensionProperties {
        const p_layer_name: ?[*:0]const u8 = if (layer_name) |ln| ln.ptr else null;

        var count: u32 = undefined;
        if (bd.enumerateInstanceExtensionProperties(p_layer_name, &count, null)) |result| switch (result) {
            .success => {},
            else => unreachable,
        } else |err| return err;

        const extensions = try allocator.alloc(vk.ExtensionProperties, count);
        errdefer allocator.free(extensions);

        if (bd.enumerateInstanceExtensionProperties(p_layer_name, &count, extensions.ptr)) |result| switch (result) {
            .success => {},
            else => unreachable,
        } else |err| return err;

        std.debug.assert(extensions.len == count);
        return extensions;
    }
    pub fn enumerateInstanceExtensionPropertiesMultipleLayersAlloc(
        allocator: std.mem.Allocator,
        bd: BaseDispatch,
        include_base: bool,
        layer_names: []const [:0]const u8,
    ) ![]vk.ExtensionProperties {
        const counts = try allocator.alloc(u32, @boolToInt(include_base) + layer_names.len);
        defer allocator.free(counts);

        for (layer_names) |layer_name, i| {
            if (bd.enumerateInstanceExtensionProperties(layer_name.ptr, &counts[i], null)) |result| switch (result) {
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

                if (bd.enumerateInstanceExtensionProperties(layer_name.ptr, &counts[i], extensions[start .. start + len].ptr)) |result| switch (result) {
                    .success => {},
                    else => unreachable,
                } else |err| return err;

                std.debug.assert(len == counts[i]);
                start += len;
            }
        }

        return extensions;
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
