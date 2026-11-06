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
    root.addImport("sleep_app_builder", b.createModule(.{
        .root_source_file = b.path("band-apps/sleep-today/pack.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const exe = b.addExecutable(.{ .name = "smart-band", .root_module = root });
    b.installArtifact(exe);
    const panel_root = b.createModule(.{
        .root_source_file = b.path("src/panel_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const panel = b.addExecutable(.{ .name = "smart-band-panel", .root_module = panel_root });
    b.installArtifact(panel);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step("run", "Run the Bluetooth band tool").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = root });
    const test_step = b.step("test", "Run offline protocol, input, and package-builder tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const panel_tests = b.addTest(.{ .root_module = panel_root });
    test_step.dependOn(&b.addRunArtifact(panel_tests).step);

    const app_builder = b.addExecutable(.{
        .name = "build-sleep-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("band-apps/sleep-today/pack.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const package = b.addRunArtifact(app_builder);
    package.setCwd(b.path("."));
    package.addPassthruArgs();
    package.has_side_effects = true;
    b.step("sleep-app", "Build the Sleep today device package").dependOn(&package.step);
    const builder_tests = b.addTest(.{ .root_module = app_builder.root_module });
    test_step.dependOn(&b.addRunArtifact(builder_tests).step);

    const check = b.step("check", "Compile the tool and check formatting");
    check.dependOn(&exe.step);
    check.dependOn(&panel.step);
    check.dependOn(&app_builder.step);
    check.dependOn(&b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check", "build.zig", "config.example.zon", "src", "band-apps/sleep-today/pack.zig" }).step);
}
