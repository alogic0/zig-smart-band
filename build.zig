const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const exe = b.addExecutable(.{ .name = "smart-band", .root_module = root });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step("run", "Run the Bluetooth band tool").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run offline protocol and input tests").dependOn(&b.addRunArtifact(tests).step);
    const check = b.step("check", "Compile the tool and check formatting");
    check.dependOn(&exe.step);
    check.dependOn(&b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check", "build.zig", "config.example.zon", "src" }).step);
}
