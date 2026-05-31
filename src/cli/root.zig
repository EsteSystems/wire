const std = @import("std");
const json_output = @import("../output/json.zig");

// Import all handler modules
const cmd_interface = @import("interface.zig");
const cmd_route = @import("route.zig");
const cmd_analyze = @import("analyze.zig");
const cmd_apply = @import("apply.zig");
const cmd_bond = @import("bond.zig");
const cmd_bridge = @import("bridge.zig");
const cmd_vlan = @import("vlan.zig");
const cmd_veth = @import("veth.zig");
const cmd_state = @import("state.zig");
const cmd_diff = @import("diff.zig");
const cmd_events = @import("events.zig");
const cmd_reconcile = @import("reconcile.zig");
const cmd_daemon = @import("daemon.zig");
const cmd_history = @import("history.zig");
const cmd_neighbor = @import("neighbor.zig");
const cmd_rule = @import("rule.zig");
const cmd_namespace = @import("namespace.zig");
const cmd_hardware = @import("hardware.zig");
const cmd_tunnel = @import("tunnel.zig");
const cmd_tc = @import("tc.zig");
const cmd_topology = @import("topology.zig");
const cmd_diagnose = @import("diagnose.zig");
const cmd_validate = @import("validate.zig");
const cmd_watch = @import("watch.zig");
const cmd_help = @import("help.zig");

const version = "1.0.0";

/// Dispatch table entry
const Command = struct {
    name: []const u8,
    handler: Handler,
};

const Handler = union(enum) {
    standard: *const fn (allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) anyerror!void,
    no_alloc: *const fn (io: std.Io, args: []const []const u8) anyerror!void,
    no_args: *const fn (allocator: std.mem.Allocator, io: std.Io) anyerror!void,
};

const commands = [_]Command{
    .{ .name = "interface", .handler = .{ .standard = cmd_interface.handleInterface } },
    .{ .name = "route", .handler = .{ .standard = cmd_route.handleRoute } },
    .{ .name = "analyze", .handler = .{ .no_args = cmd_analyze.handleAnalyze } },
    .{ .name = "apply", .handler = .{ .standard = cmd_apply.handleApply } },
    .{ .name = "validate", .handler = .{ .standard = cmd_validate.handleValidate } },
    .{ .name = "bond", .handler = .{ .standard = cmd_bond.handleBond } },
    .{ .name = "bridge", .handler = .{ .standard = cmd_bridge.handleBridge } },
    .{ .name = "vlan", .handler = .{ .standard = cmd_vlan.handleVlan } },
    .{ .name = "veth", .handler = .{ .standard = cmd_veth.handleVeth } },
    .{ .name = "state", .handler = .{ .standard = cmd_state.handleState } },
    .{ .name = "diff", .handler = .{ .standard = cmd_diff.handleDiff } },
    .{ .name = "events", .handler = .{ .no_alloc = cmd_events.handleEvents } },
    .{ .name = "reconcile", .handler = .{ .standard = cmd_reconcile.handleReconcile } },
    .{ .name = "daemon", .handler = .{ .standard = cmd_daemon.handleDaemon } },
    .{ .name = "history", .handler = .{ .standard = cmd_history.handleHistory } },
    .{ .name = "neighbor", .handler = .{ .standard = cmd_neighbor.handleNeighbor } },
    .{ .name = "rule", .handler = .{ .standard = cmd_rule.handleRule } },
    .{ .name = "netns", .handler = .{ .standard = cmd_namespace.handleNamespace } },
    .{ .name = "namespace", .handler = .{ .standard = cmd_namespace.handleNamespace } },
    .{ .name = "hw", .handler = .{ .standard = cmd_hardware.handleHardware } },
    .{ .name = "hardware", .handler = .{ .standard = cmd_hardware.handleHardware } },
    .{ .name = "tunnel", .handler = .{ .standard = cmd_tunnel.handleTunnel } },
    .{ .name = "tc", .handler = .{ .standard = cmd_tc.handleTc } },
    .{ .name = "qdisc", .handler = .{ .standard = cmd_tc.handleTc } },
    .{ .name = "topology", .handler = .{ .standard = cmd_topology.handleTopology } },
    .{ .name = "diagnose", .handler = .{ .standard = cmd_diagnose.handleDiagnose } },
    .{ .name = "trace", .handler = .{ .standard = cmd_diagnose.handlePathTrace } },
    .{ .name = "probe", .handler = .{ .standard = cmd_diagnose.handleProbe } },
    .{ .name = "watch", .handler = .{ .standard = cmd_watch.handleWatch } },
};

/// Dispatch a command by name. Returns true if command was found and executed.
pub fn dispatch(allocator: std.mem.Allocator, io: std.Io, subject: []const u8, handler_args: []const []const u8) !bool {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, subject)) {
            switch (cmd.handler) {
                .standard => |h| try h(allocator, io, handler_args),
                .no_alloc => |h| try h(io, handler_args),
                .no_args => |h| try h(allocator, io),
            }
            return true;
        }
    }
    return false;
}

pub fn printUsage(io: std.Io) !void {
    try cmd_help.printUsage(io);
}

pub fn printVersion(io: std.Io) !void {
    try cmd_help.printVersion(io);
}
