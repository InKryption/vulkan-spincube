comptime {
    const std = @import("std");
    const root = @import("root");

    const stb_allocator: *const std.mem.Allocator = if (@hasDecl(root, "stb_allocator"))
        &root.stb_allocator
    else
        &std.heap.c_allocator;
    const gen = struct {
        const Metadata = struct { len: usize };
        fn userMalloc(size: usize) callconv(.C) ?*anyopaque {
            if (size == 0) return null;

            const result = stb_allocator.alloc(u8, @sizeOf(Metadata) + size) catch return null;

            std.mem.bytesAsValue(Metadata, result[0..@sizeOf(Metadata)]).* = .{
                .len = result.len,
            };

            return result[@sizeOf(Metadata)..].ptr;
        }

        fn userRealloc(maybe_ptr: ?*anyopaque, size: usize) callconv(.C) ?*anyopaque {
            if (size == 0) {
                userFree(maybe_ptr);
                return null;
            }

            const old_ptr = @ptrCast([*]u8, maybe_ptr orelse return userMalloc(size)) - @sizeOf(Metadata);
            const old_metadata = std.mem.bytesToValue(Metadata, old_ptr[0..@sizeOf(Metadata)]);

            const new_mem = stb_allocator.realloc(old_ptr[0..old_metadata.len], @sizeOf(Metadata) + size) catch return null;

            std.mem.bytesAsValue(Metadata, new_mem[0..@sizeOf(Metadata)]).* = .{
                .len = new_mem.len,
            };

            return @ptrCast(*anyopaque, new_mem[@sizeOf(Metadata)..].ptr);
        }

        fn userFree(maybe_ptr: ?*anyopaque) callconv(.C) void {
            const ptr = @ptrCast([*]u8, maybe_ptr orelse return) - @sizeOf(Metadata);
            const metadata = std.mem.bytesToValue(Metadata, ptr[0..@sizeOf(Metadata)]);
            stb_allocator.free(ptr[0..metadata.len]);
        }
    };

    @export(gen.userMalloc, std.builtin.ExportOptions{ .name = "userMalloc" });
    @export(gen.userRealloc, std.builtin.ExportOptions{ .name = "userRealloc" });
    @export(gen.userFree, std.builtin.ExportOptions{ .name = "userFree" });
}

pub const DesiredChannels = enum(c_int) {
    default = 0,
    grey = 1,
    grey_alpha = 2,
    rgb = 3,
    rgb_alpha = 4,
    _,
};
pub const IoCallbacks = extern struct {
    read: ?fn (user: ?*anyopaque, data: [*]u8, size: c_int) callconv(.C) c_int,
    skip: ?fn (user: ?*anyopaque, n: c_int) callconv(.C) void,
    eof: ?fn (user: ?*anyopaque) callconv(.C) c_int,
};

pub const Image = struct {
    bytes: [*]u8,
    x: c_int,
    y: c_int,
    channels: c_int,
};
pub extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: ?*c_int, y: ?*c_int, channels_in_file: ?*c_int, desired_channels: DesiredChannels) ?[*]u8;
pub fn loadFromMemory(buffer: []const u8, desired_channels: DesiredChannels) ?Image {
    var result: Image = undefined;

    result.bytes = stbi_load_from_memory(
        buffer.ptr,
        @intCast(c_int, buffer.len),
        &result.x,
        &result.y,
        &result.channels,
        desired_channels,
    ) orelse return null;

    return result;
}

pub extern fn stbi_load_from_callbacks(clbk: *const IoCallbacks, user: ?*anyopaque, x: ?*c_int, y: ?*c_int, channels_in_file: ?*c_int, desired_channels: DesiredChannels) ?[*]u8;
pub fn loadFromCallbacks(clbk: IoCallbacks, user: ?*anyopaque, desired_channels: DesiredChannels) ?Image {
    var result: Image = undefined;

    result.bytes = stbi_load_from_callbacks(
        &clbk,
        user,
        &result.x,
        &result.y,
        &result.channels,
        desired_channels,
    ) orelse return null;

    return result;
}

pub extern fn stbi_load_gif_from_memory(buffer: [*]const u8, len: c_int, delays: ?*[*]c_int, x: ?*c_int, y: ?*c_int, z: ?*c_int, comp: ?*c_int, req_comp: DesiredChannels) ?[*]u8;
pub extern fn stbi_load_16_from_memory(buffer: [*]const u8, len: c_int, x: ?*c_int, y: ?*c_int, channels_in_file: ?*c_int, desired_channels: DesiredChannels) ?[*]u16;
pub extern fn stbi_load_16_from_callbacks(clbk: *const IoCallbacks, user: ?*anyopaque, x: ?*c_int, y: ?*c_int, channels_in_file: ?*c_int, desired_channels: DesiredChannels) ?[*]u16;
pub extern fn stbi_loadf_from_memory(buffer: [*]const u8, len: c_int, x: ?*c_int, y: ?*c_int, channels_in_file: ?*c_int, desired_channels: DesiredChannels) ?[*]f32;
pub extern fn stbi_loadf_from_callbacks(clbk: *const IoCallbacks, user: ?*anyopaque, x: ?*c_int, y: ?*c_int, channels_in_file: ?*c_int, desired_channels: DesiredChannels) ?[*]f32;
pub extern fn stbi_hdr_to_ldr_gamma(gamma: f32) void;
pub extern fn stbi_hdr_to_ldr_scale(scale: f32) void;
pub extern fn stbi_ldr_to_hdr_gamma(gamma: f32) void;
pub extern fn stbi_ldr_to_hdr_scale(scale: f32) void;
pub extern fn stbi_is_hdr_from_callbacks(clbk: *const IoCallbacks, user: ?*anyopaque) c_int;
pub extern fn stbi_is_hdr_from_memory(buffer: [*]const u8, len: c_int) c_int;
pub extern fn stbi_failure_reason() [*:0]const u8;

pub extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
pub fn imageFree(retval_from_stbi_load: *anyopaque) void {
    return stbi_image_free(retval_from_stbi_load);
}

pub extern fn stbi_info_from_memory(buffer: [*]const u8, len: c_int, x: ?*c_int, y: ?*c_int, comp: ?*c_int) c_int;
pub extern fn stbi_info_from_callbacks(clbk: *const IoCallbacks, user: ?*anyopaque, x: ?*c_int, y: ?*c_int, comp: ?*c_int) c_int;
pub extern fn stbi_is_16_bit_from_memory(buffer: [*]const u8, len: c_int) c_int;
pub extern fn stbi_is_16_bit_from_callbacks(clbk: *const IoCallbacks, user: ?*anyopaque) c_int;
pub extern fn stbi_set_unpremultiply_on_load(flag_true_if_should_unpremultiply: c_int) void;
pub extern fn stbi_convert_iphone_png_to_rgb(flag_true_if_should_convert: c_int) void;
pub extern fn stbi_set_flip_vertically_on_load(flag_true_if_should_flip: c_int) void;
pub extern fn stbi_set_unpremultiply_on_load_thread(flag_true_if_should_unpremultiply: c_int) void;
pub extern fn stbi_convert_iphone_png_to_rgb_thread(flag_true_if_should_convert: c_int) void;
pub extern fn stbi_set_flip_vertically_on_load_thread(flag_true_if_should_flip: c_int) void;
pub extern fn stbi_zlib_decode_malloc_guesssize(buffer: [*]const u8, len: c_int, initial_size: c_int, outlen: ?*c_int) ?[*]u8;
pub extern fn stbi_zlib_decode_malloc_guesssize_headerflag(buffer: [*]const u8, len: c_int, initial_size: c_int, outlen: ?*c_int, parse_header: c_int) ?[*]u8;
pub extern fn stbi_zlib_decode_malloc(buffer: [*]const u8, len: c_int, outlen: ?*c_int) ?[*]u8;
pub extern fn stbi_zlib_decode_buffer(obuffer: [*]u8, olen: c_int, ibuffer: [*]const u8, ilen: c_int) c_int;
pub extern fn stbi_zlib_decode_noheader_malloc(buffer: [*]const u8, len: c_int, outlen: ?*c_int) ?[*]u8;
pub extern fn stbi_zlib_decode_noheader_buffer(obuffer: [*]u8, olen: c_int, ibuffer: [*]const u8, ilen: c_int) c_int;
