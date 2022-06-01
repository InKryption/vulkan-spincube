const std = @import("std");

const shader_bytecode_paths = @import("shader-bytecode-paths");
comptime {
    // update whenever new shaders are added
    std.debug.assert(@typeInfo(shader_bytecode_paths).Struct.decls.len == 2);
}

pub const vert = @embedFile(shader_bytecode_paths.vert);
pub const frag = @embedFile(shader_bytecode_paths.frag);
