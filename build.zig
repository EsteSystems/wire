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
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = linux_target,
            .optimize = optimize,
        }),
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
    const test_step = b.step("test", "Run unit tests (native)");

    // Syntax tests
    const syntax_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/syntax/lexer.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(syntax_tests).step);

    // Netlink module tests (pure logic only - enum conversions, parsing, struct tests)
    const netlink_test_files = [_][]const u8{
        "src/netlink/socket.zig",
        "src/netlink/bond.zig",
        "src/netlink/bridge.zig",
        "src/netlink/vlan.zig",
        "src/netlink/neighbor.zig",
        "src/netlink/veth.zig",
    };

    for (netlink_test_files) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = native_target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Linux-specific tests (netlink, etc.) - run on target VM
    const linux_test_step = b.step("test-linux", "Run Linux-specific tests (requires Linux)");

    const linux_netlink_test_files = [_][]const u8{
        "src/netlink/socket.zig",
        "src/netlink/bond.zig",
        "src/netlink/bridge.zig",
        "src/netlink/vlan.zig",
        "src/netlink/interface.zig",
        "src/netlink/address.zig",
        "src/netlink/route.zig",
        "src/netlink/neighbor.zig",
        "src/netlink/veth.zig",
        "src/netlink/namespace.zig",
        "src/netlink/rule.zig",
        "src/netlink/ethtool.zig",
        "src/netlink/events.zig",
        "src/netlink/qdisc.zig",
        "src/netlink/stats.zig",
    };

    for (linux_netlink_test_files) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = linux_target,
                .optimize = optimize,
            }),
        });
        linux_test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Integration tests - Linux only, requires root
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = linux_target,
            .optimize = optimize,
        }),
    });
    const integration_step = b.step("test-integration", "Run integration tests (requires Linux + root)");
    integration_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // Check step - verify code compiles for Linux without running
    const check_step = b.step("check", "Check that code compiles for Linux");
    check_step.dependOn(&exe.step);
}
