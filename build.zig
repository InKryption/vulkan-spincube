const std = @import("std");
const vk = @import("dep/Snektron/vulkan-zig/generator/index.zig");
const mach_glfw = @import("dep/hexops/mach/glfw/build.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("vulkan-spincube", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const vk_gen_step = vk.VkGenerateStep.init(b, "dep/KhronosGroup/Vulkan-Docs/xml/vk.xml", "generated/vk.zig");
    exe.step.dependOn(&vk_gen_step.step);
    exe.addPackage(vk_gen_step.package);

    mach_glfw.link(b, exe, mach_glfw.Options{ .vulkan = true });
    exe.addPackage(mach_glfw.pkg);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
