const std = @import("std");

pub fn externSlice(slice: anytype) ExternSlice(std.mem.Span(@TypeOf(slice))) {
    const Coerced = std.mem.Span(@TypeOf(slice));
    return ExternSlice(Coerced).init(slice);
}
pub fn ExternSlice(comptime ZigSlice: type) type {
    const info: std.builtin.Type.Pointer = @typeInfo(ZigSlice).Pointer;
    if (info.size != .Slice) {
        @compileError("Expected slice type, got " ++ @typeName(ZigSlice));
    }

    return extern struct {
        const Self = @This();
        ptr: Ptr,
        len: usize,

        pub fn init(zig_slice: Slice) Self {
            return Self{
                .ptr = zig_slice.ptr,
                .len = zig_slice.len,
            };
        }

        pub fn slice(self: Self) Slice {
            return self.ptr[0..self.len];
        }

        pub const Slice = ZigSlice;
        pub const Ptr = Blk: {
            var new_info = info;
            new_info.size = .Many;
            break :Blk @Type(.{ .Pointer = new_info });
        };
    };
}
