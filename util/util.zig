pub const ExternSlice = @import("extern_slice.zig").ExternSlice;
pub const externSlice = @import("extern_slice.zig").externSlice;
pub const Result = @import("result.zig").Result;
pub const file_logger = @import("file_logger.zig");

pub const ManyPtrContextArrayHashMap = @import("many_ptr_ctx.zig").ManyPtrContextArrayHashMap;
pub const ManyPtrContextHashMap = @import("many_ptr_ctx.zig").ManyPtrContextHashMap;

/// Returns an empty slice of `T`.
pub fn emptySlice(comptime T: type) []T {
    return &[_]T{};
}

/// Returns an empty, sentinel-terminated slice of `T`.
pub fn emptySliceSentinel(comptime T: type, comptime sentinel: T) [:sentinel]T {
    return &[_:sentinel]T{};
}
