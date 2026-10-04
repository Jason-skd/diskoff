const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const diskoff = b.addModule("diskoff", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    diskoff.linkFramework("CoreFoundation", .{});
    diskoff.linkFramework("DiskArbitration", .{});

    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "diskoff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diskoff", .module = diskoff },
                .{ .name = "clap", .module = clap.module("clap") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the diskoff CLI").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = diskoff });
    const run_tests = b.addRunArtifact(tests);
    const cli_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const test_step = b.step("test", "Run diskoff library and CLI tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_cli_tests.step);
}
