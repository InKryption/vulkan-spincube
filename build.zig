const std = @import("std");
const vk = @import("dep/Snektron/vulkan-zig/generator/index.zig");
const mach = @import("dep/hexops/mach/build.zig");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable("vulkan-spincube", "src/root.zig");
    exe.setBuildMode(mode);
    exe.setTarget(target);
    exe.install();

    const build_options = b.addOptions();
    exe.addOptions("build_options", build_options);
    build_options.addOption(bool, "vk_debug", b.option(bool, "vk-debug", "Enable Vulkan Validation Layers.") orelse (mode == .Debug));
    build_options.addOption(std.log.Level, "log_level", b.option(std.log.Level, "log-level", "Sets the log level.") orelse switch (mode) {
        .Debug => std.log.Level.debug,
        .ReleaseSafe => std.log.Level.info,
        .ReleaseFast, .ReleaseSmall => std.log.Level.err,
    });

    stb_image_lib: {
        exe.addPackagePath("stb_image", "stb_image/stb_image.zig");

        const stbi_lib = b.addStaticLibrary("stbi", "stb_image/impl.c");
        stbi_lib.setBuildMode(mode);
        stbi_lib.setTarget(target);
        stbi_lib.addIncludePath("stb_image");
        stbi_lib.linkLibC();
        exe.linkLibrary(stbi_lib);

        const stbi_no_failure_strings = b.option(bool, "stbi-no-failure-strings", "stb_image macro option.") orelse false;
        if (stbi_no_failure_strings) stbi_lib.defineCMacro("STBI_NO_FAILURE_STRINGS", null);

        const stbi_failure_usermsg = b.option(bool, "stbi-failure-usermsg", "stb_image macro option.") orelse false;
        if (stbi_failure_usermsg) stbi_lib.defineCMacro("STBI_FAILURE_USERMSG", "stbi_image macro option.");

        break :stb_image_lib;
    }

    mach.glfw.link(b, exe, mach.glfw.Options{ .vulkan = true });
    exe.addPackage(mach.glfw.pkg);

    exe.addPackagePath("util", "util/util.zig");
    exe.addPackagePath("MasterQ32/zig-args", "dep/MasterQ32/zig-args/args.zig");
    exe.addPackagePath("ziglibs/zlm", "dep/ziglibs/zlm/zlm.zig");

    const vk_gen_step = vk.VkGenerateStep.init(b, "dep/KhronosGroup/Vulkan-Docs/xml/vk.xml", "generated/vk.zig");
    exe.step.dependOn(&vk_gen_step.step);
    exe.addPackage(vk_gen_step.package);

    const vk_shader_compile_step = vk.ShaderCompileStep.init(b, &.{"glslc"}, "shader-bytecode");
    exe.step.dependOn(&vk_shader_compile_step.step);
    {
        const shader_byte_code_paths = b.addOptions();
        exe.addOptions("shader-bytecode-paths", shader_byte_code_paths);
        shader_byte_code_paths.addOptionFileSource("vert", .{ .path = vk_shader_compile_step.add("src/shaders/shader.vert") });
        shader_byte_code_paths.addOptionFileSource("frag", .{ .path = vk_shader_compile_step.add("src/shaders/shader.frag") });
    }

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
