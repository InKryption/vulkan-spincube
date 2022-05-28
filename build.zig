const std = @import("std");
const vk = @import("dep/Snektron/vulkan-zig/generator/index.zig");
const mach = @import("dep/hexops/mach/build.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("vulkan-spincube", "src/root.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const build_options = b.addOptions();
    exe.addOptions("build_options", build_options);
    build_options.addOption(bool, "vk_validation_layers", b.option(bool, "vk-validation-layers", "Enable Vulkan Validation Layers.") orelse (mode == .Debug));
    build_options.addOption(std.log.Level, "log_level", b.option(std.log.Level, "log-level", "Sets the log level.") orelse switch (mode) {
        .Debug => std.log.Level.debug,
        .ReleaseSafe => std.log.Level.info,
        .ReleaseFast, .ReleaseSmall => std.log.Level.err,
    });

    const vk_gen_step = vk.VkGenerateStep.init(b, "dep/KhronosGroup/Vulkan-Docs/xml/vk.xml", "generated/vk.zig");
    exe.step.dependOn(&vk_gen_step.step);
    exe.addPackage(vk_gen_step.package);

    mach.glfw.link(b, exe, mach.glfw.Options{ .vulkan = true });
    exe.addPackage(mach.glfw.pkg);

    const @"zig-args" = std.build.Pkg{
        .name = "MasterQ32/zig-args",
        .source = .{ .path = "dep/MasterQ32/zig-args/args.zig" },
    };
    const zlm = std.build.Pkg{
        .name = "ziglibs/zlm",
        .source = .{ .path = "dep/ziglibs/zlm/zlm.zig" },
    };

    exe.addPackage(@"zig-args");
    exe.addPackage(zlm);

    const vk_shader_compile_step = vk.ShaderCompileStep.init(b, &.{"glslc"}, "shader-bytecode");
    exe.step.dependOn(&vk_shader_compile_step.step);
    {
        const shader_byte_code_paths = b.addOptions();
        exe.addOptions("shader-bytecode-paths", shader_byte_code_paths);
        shader_byte_code_paths.addOptionFileSource("vert", .{ .path = vk_shader_compile_step.add("src/shader.vert") });
        shader_byte_code_paths.addOptionFileSource("frag", .{ .path = vk_shader_compile_step.add("src/shader.frag") });
    }

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
