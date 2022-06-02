const std = @import("std");

fn ConstifyPtr(comptime Ptr: type) type {
    var info: std.builtin.Type.Pointer = @typeInfo(Ptr).Pointer;
    info.is_const = true;
    return @Type(.{ .Pointer = info });
}

pub fn ManyPtrContextArrayHashMap(comptime Ptr: type) type {
    if (!std.meta.trait.isConstPtr(Ptr)) {
        return ManyPtrContextArrayHashMap(ConstifyPtr(Ptr));
    }
    const HashMapImpl = ManyPtrContextHashMap(Ptr);
    return struct {
        const Self = @This();

        pub fn hash(ctx: Self, key: Ptr) u32 {
            _ = ctx;
            return @truncate(u32, HashMapImpl.hash(.{}, key));
        }

        pub fn eql(ctx: Self, a: Ptr, b: Ptr, b_index: usize) bool {
            _ = ctx;
            _ = b_index;
            return HashMapImpl.eql(.{}, a, b);
        }
    };
}

pub fn ManyPtrContextHashMap(comptime Ptr: type) type {
    if (!std.meta.trait.isConstPtr(Ptr)) {
        return ManyPtrContextHashMap(ConstifyPtr(Ptr));
    }
    return struct {
        const Self = @This();

        pub fn hash(ctx: Self, key: Ptr) u64 {
            _ = ctx;
            const bytes = std.mem.sliceAsBytes(std.mem.span(key));
            return std.hash.Wyhash.hash(0, bytes);
        }

        pub fn eql(ctx: Self, a: Ptr, b: Ptr) bool {
            _ = ctx;
            return std.mem.eql(std.meta.Elem(Ptr), std.mem.span(a), std.mem.span(b));
        }
    };
}
