const std = @import("std");

pub fn build(b: *std.Build) void {
    // Optimization level
    const optimize = b.standardOptimizeOption(.{});

    // Linux target for production build
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });

    // Native target for tests (so they can run on dev machine)
    const native_target = b.standardTargetOptions(.{});

    // Main executable - always build for Linux
    const exe = b.addExecutable(.{
        .name = "wire",
        .root_source_file = b.path("src/main.zig"),
        .target = linux_target,
        .optimize = optimize,
        .link_libc = false, // No libc - direct syscalls
    });

    // Install the executable
    b.installArtifact(exe);

    // Run command won't work on non-Linux, but keep for when testing on Linux
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run wire (Linux only)");
    run_step.dependOn(&run_cmd.step);

    // Unit tests - use native target so they can run on dev machine
    // These tests only test pure Zig logic, not Linux-specific syscalls
    const syntax_tests = b.addTest(.{
        .root_source_file = b.path("src/syntax/lexer.zig"),
        .target = native_target,
        .optimize = optimize,
    });

    const run_syntax_tests = b.addRunArtifact(syntax_tests);
    const test_step = b.step("test", "Run unit tests (native)");
    test_step.dependOn(&run_syntax_tests.step);

    // Linux-specific tests (netlink, etc.) - run on target VM
    const linux_test_step = b.step("test-linux", "Run Linux-specific tests (requires Linux)");

    const netlink_tests = b.addTest(.{
        .root_source_file = b.path("src/netlink/socket.zig"),
        .target = linux_target,
        .optimize = optimize,
    });

    const run_netlink_tests = b.addRunArtifact(netlink_tests);
    linux_test_step.dependOn(&run_netlink_tests.step);

    // Check step - verify code compiles for Linux without running
    const check_step = b.step("check", "Check that code compiles for Linux");
    check_step.dependOn(&exe.step);
}
