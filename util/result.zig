const std = @import("std");

pub const ResultTag = enum { ok, err };

pub fn Result(
    comptime ErrPayload: type,
    comptime ErrorUnion: type,
) type {
    comptime std.debug.assert(@typeInfo(ErrorUnion) == .ErrorUnion);
    return union(ResultTag) {
        const Self = @This();
        ok: Ok,
        err: Err,

        pub fn init(
            maybe_error_info: (if (@sizeOf(ErrPayload) == 0) @TypeOf(null) else ?ErrPayload),
            error_union: ErrorUnion,
        ) Self {
            if (error_union) |ok| {
                std.debug.assert(maybe_error_info == null);
                return Self{ .ok = ok };
            } else |err_value| {
                const info = if (@sizeOf(ErrPayload) == 0) undefined else maybe_error_info.?;
                return Self{ .err = .{
                    .value = err_value,
                    .info = info,
                } };
            }
        }

        pub fn unwrap(self: Self) Err.Value!Ok {
            return switch (self) {
                .ok => |ok| ok,
                .err => |err| err.value,
            };
        }

        pub const Ok = @typeInfo(ErrorUnion).ErrorUnion.payload;
        pub const Err = struct {
            value: Err.Value,
            info: Err.Info,

            pub const Value = @typeInfo(ErrorUnion).ErrorUnion.error_set;
            pub const Info = ErrPayload;
        };
    };
}
