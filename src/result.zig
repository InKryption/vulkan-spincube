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
            comptime tag: ResultTag,
            expr: std.meta.fields(Self)[std.meta.fieldIndex(Self, @tagName(tag)).?].field_type,
        ) Self {
            return @unionInit(Self, @tagName(tag), expr);
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
