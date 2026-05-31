const std = @import("std");
const compat = @import("../compat.zig");
const netlink_interface = @import("../netlink/interface.zig");
const netlink_address = @import("../netlink/address.zig");
const netlink_route = @import("../netlink/route.zig");
const netlink_bond = @import("../netlink/bond.zig");
const netlink_bridge = @import("../netlink/bridge.zig");
const netlink_vlan = @import("../netlink/vlan.zig");
const netlink_veth = @import("../netlink/veth.zig");
const config_loader = @import("../config/loader.zig");
const state_types = @import("../state/types.zig");
const state_live = @import("../state/live.zig");
const state_desired = @import("../state/desired.zig");
const state_diff = @import("../state/diff.zig");
const state_exporter = @import("../state/exporter.zig");
const netlink_events = @import("../netlink/events.zig");
const reconciler = @import("../daemon/reconciler.zig");
const supervisor = @import("../daemon/supervisor.zig");
const ipc = @import("../daemon/ipc.zig");
const connectivity = @import("../analysis/connectivity.zig");
const health = @import("../analysis/health.zig");
const snapshots = @import("../history/snapshots.zig");
const changelog = @import("../history/changelog.zig");
const neighbor = @import("../netlink/neighbor.zig");
const ip_rule = @import("../netlink/rule.zig");
const namespace = @import("../netlink/namespace.zig");
const ethtool = @import("../netlink/ethtool.zig");
const tunnel = @import("../netlink/tunnel.zig");
const qdisc = @import("../netlink/qdisc.zig");
const stats = @import("../netlink/stats.zig");
const topology = @import("../analysis/topology.zig");
const native_ping = @import("../plugins/native/ping.zig");
const native_trace = @import("../plugins/native/traceroute.zig");
const native_capture = @import("../plugins/native/capture.zig");
const path_trace = @import("../diagnostics/trace.zig");
const probe = @import("../diagnostics/probe.zig");
const validate = @import("../diagnostics/validate.zig");
const watch = @import("../diagnostics/watch.zig");
const json_output = @import("../output/json.zig");
const linux = std.os.linux;

const version = "1.0.0";

pub fn printVersion(io: std.Io) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    try stdout.print("wire {s}\n", .{version});
    try stdout.print("Low-level, declarative, continuously-supervised network configuration for Linux\n", .{});
}

pub fn printUsage(io: std.Io) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    try stdout.print(
        \\wire - Network configuration tool for Linux
        \\
        \\Usage: wire <command> [options]
        \\
        \\Interface & Address Management:
        \\  interface                      List all interfaces
        \\  interface <name>               Show interface details
        \\  route                          Show routing table
        \\  neighbor                       Show ARP/NDP table
        \\
        \\Virtual Interfaces:
        \\  bond                           Bond interface management
        \\  bridge                         Bridge interface management
        \\  vlan                           VLAN interface management
        \\  veth                           Veth pair management
        \\  tunnel                         VXLAN/GRE tunnel management
        \\
        \\Advanced Networking:
        \\  rule                           IP policy routing rules
        \\  netns                          Network namespace management
        \\  tc                             Traffic control (qdiscs)
        \\  hw                             Hardware tuning (ethtool)
        \\
        \\Configuration:
        \\  apply <config>                 Apply configuration file
        \\  validate <config>              Validate configuration
        \\  diff <config>                  Compare config vs live state
        \\  state                          Show current network state
        \\
        \\Diagnostics:
        \\  topology                       Show network topology
        \\  diagnose                       Network diagnostics (ping, trace, capture)
        \\  trace <if> to <ip>             Trace path to destination
        \\  probe <host> <port>            Test TCP connectivity
        \\  watch <target>                 Continuous monitoring
        \\  analyze                        Analyze network configuration
        \\
        \\Daemon & History:
        \\  daemon                         Supervision daemon control
        \\  events                         Monitor network events
        \\  history                        Change history and snapshots
        \\
        \\Options:
        \\  -h, --help                     Show this help
        \\  -v, --version                  Show version
        \\
        \\Run 'wire <command>' without arguments for detailed help on each command.
        \\
    , .{});
}


test "version string" {
    try std.testing.expect(version.len > 0);
}
