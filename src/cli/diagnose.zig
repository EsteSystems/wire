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

pub fn handleDiagnose(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Diagnose commands (all native, no external tools):\n", .{});
        try stdout.print("  diagnose ping <target>           ICMP ping\n", .{});
        try stdout.print("  diagnose trace <target>          ICMP traceroute\n", .{});
        try stdout.print("  diagnose capture [interface]     Packet capture\n", .{});
        try stdout.print("\nPing options:\n", .{});
        try stdout.print("  -c <count>    Number of pings (default: 4)\n", .{});
        try stdout.print("  -W <secs>     Timeout per packet (default: 1)\n", .{});
        try stdout.print("  -t <ttl>      Time to live (default: 64)\n", .{});
        try stdout.print("  from <iface>  Bind to interface\n", .{});
        try stdout.print("\nTrace options:\n", .{});
        try stdout.print("  -m <hops>     Max hops (default: 30)\n", .{});
        try stdout.print("  -q <probes>   Probes per hop (default: 3)\n", .{});
        try stdout.print("  -W <secs>     Timeout per probe (default: 1)\n", .{});
        try stdout.print("\nCapture options:\n", .{});
        try stdout.print("  -c <count>    Stop after N packets\n", .{});
        try stdout.print("  -t <secs>     Stop after N seconds\n", .{});
        try stdout.print("  -f <filter>   Filter: tcp, udp, icmp, port N, host X.X.X.X\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire diagnose ping 10.0.0.1\n", .{});
        try stdout.print("  wire diagnose trace 8.8.8.8\n", .{});
        try stdout.print("  wire diagnose capture eth0 -c 10\n", .{});
        try stdout.print("  wire diagnose capture eth0 -f \"tcp port 80\"\n", .{});
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "ping")) {
        try handleDiagnosePing(allocator, io, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "trace") or std.mem.eql(u8, subcommand, "traceroute")) {
        try handleDiagnoseTrace(allocator, io, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "capture") or std.mem.eql(u8, subcommand, "cap")) {
        try handleDiagnoseCapture(allocator, io, args[1..]);
    } else {
        try stdout.print("Unknown diagnose subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: ping, trace, capture\n", .{});
    }
}

pub fn handleDiagnosePing(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Usage: wire diagnose ping <target> [options]\n", .{});
        return;
    }

    const target = args[0];
    var options = native_ping.PingOptions{};

    // Parse options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "from") and i + 1 < args.len) {
            options.interface = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
            options.count = std.fmt.parseInt(u32, args[i + 1], 10) catch 4;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-W") and i + 1 < args.len) {
            options.timeout_ms = (std.fmt.parseInt(u32, args[i + 1], 10) catch 1) * 1000;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            options.ttl = std.fmt.parseInt(u8, args[i + 1], 10) catch 64;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            options.packet_size = std.fmt.parseInt(u16, args[i + 1], 10) catch 56;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-i") and i + 1 < args.len) {
            options.interval_ms = (std.fmt.parseInt(u32, args[i + 1], 10) catch 1) * 1000;
            i += 1;
        }
    }

    // Run native ping
    const result = native_ping.ping(allocator, target, options) catch |err| {
        if (err == error.PermissionDenied) {
            try stdout.print("Permission denied: raw socket requires root or CAP_NET_RAW\n", .{});
            return;
        }
        try stdout.print("Failed to run ping: {}\n", .{err});
        return;
    };

    // Display result
    try result.format(stdout);
}

pub fn handleDiagnoseTrace(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Usage: wire diagnose trace <target> [options]\n", .{});
        return;
    }

    const target = args[0];
    var options = native_trace.TraceOptions{};

    // Parse options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "from") and i + 1 < args.len) {
            options.interface = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
            options.max_hops = std.fmt.parseInt(u8, args[i + 1], 10) catch 30;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-q") and i + 1 < args.len) {
            options.probes_per_hop = std.fmt.parseInt(u8, args[i + 1], 10) catch 3;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-W") and i + 1 < args.len) {
            options.timeout_ms = (std.fmt.parseInt(u32, args[i + 1], 10) catch 1) * 1000;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-f") and i + 1 < args.len) {
            options.initial_ttl = std.fmt.parseInt(u8, args[i + 1], 10) catch 1;
            i += 1;
        }
    }

    // Run native traceroute
    var result = native_trace.trace(allocator, target, options) catch |err| {
        if (err == error.PermissionDenied) {
            try stdout.print("Permission denied: raw socket requires root or CAP_NET_RAW\n", .{});
            return;
        }
        try stdout.print("Failed to run traceroute: {}\n", .{err});
        return;
    };
    defer result.deinit();

    // Display result
    try result.format(stdout);
}

pub fn handleDiagnoseCapture(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    var options = native_capture.CaptureOptions{};
    var filter_str: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c") and i + 1 < args.len) {
            options.count = std.fmt.parseInt(u32, args[i + 1], 10) catch null;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            options.duration_secs = std.fmt.parseInt(u32, args[i + 1], 10) catch null;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-f") and i + 1 < args.len) {
            filter_str = args[i + 1];
            i += 1;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            options.interface = arg;
        }
    }

    // Apply filter
    if (filter_str) |f| {
        const filter_opts = native_capture.parseFilter(f);
        options.filter_proto = filter_opts.filter_proto;
        options.filter_port = filter_opts.filter_port;
        options.filter_host = filter_opts.filter_host;
    }

    // Default to 10 packets if no limit specified
    if (options.count == null and options.duration_secs == null) {
        options.count = 10;
    }

    // Print header
    if (options.interface) |iface| {
        try stdout.print("Capturing on {s}", .{iface});
    } else {
        try stdout.print("Capturing on all interfaces", .{});
    }
    if (options.count) |c| {
        try stdout.print(", max {d} packets", .{c});
    }
    if (options.duration_secs) |d| {
        try stdout.print(", max {d} seconds", .{d});
    }
    try stdout.print("\n\n", .{});

    // Run capture
    const capture_stats = native_capture.capture(allocator, options, stdout) catch |err| {
        if (err == error.PermissionDenied) {
            try stdout.print("Permission denied: packet capture requires root or CAP_NET_RAW\n", .{});
            return;
        }
        if (err == error.InterfaceNotFound) {
            try stdout.print("Interface not found\n", .{});
            return;
        }
        try stdout.print("Failed to capture: {}\n", .{err});
        return;
    };

    // Print stats
    try capture_stats.format(stdout);
}

pub fn handlePathTrace(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len < 3) {
        try stdout.print("Usage: wire trace <interface> to <destination>\n", .{});
        try stdout.print("\nTrace network path from interface to destination IP.\n", .{});
        try stdout.print("Validates interface states, bonds, bridges, VLANs, and ARP entries.\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire trace eth0 to 10.0.0.1\n", .{});
        try stdout.print("  wire trace br0 to 192.168.1.1\n", .{});
        try stdout.print("  wire trace bond0.100 to 10.0.0.50\n", .{});
        return;
    }

    const source = args[0];

    // Expect "to" keyword
    if (args.len < 3 or !std.mem.eql(u8, args[1], "to")) {
        try stdout.print("Usage: wire trace <interface> to <destination>\n", .{});
        return;
    }

    const destination = args[2];

    // Run path trace
    var trace = path_trace.tracePath(allocator, source, destination) catch |err| {
        if (err == error.PermissionDenied) {
            try stdout.print("Permission denied: path tracing requires root\n", .{});
            return;
        }
        try stdout.print("Failed to trace path: {}\n", .{err});
        return;
    };
    defer trace.deinit();

    // Display result
    try trace.format(stdout);
}

pub fn handleProbe(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Probe commands:\n", .{});
        try stdout.print("  probe <host> <port|service>     Test TCP connectivity\n", .{});
        try stdout.print("  probe <host> <port> --timeout <ms>  With custom timeout\n", .{});
        try stdout.print("  probe <host> scan               Scan common ports\n", .{});
        try stdout.print("  probe service <name>            Lookup service port\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire probe 10.0.0.1 22          Test SSH port\n", .{});
        try stdout.print("  wire probe 10.0.0.1 ssh         Test SSH by name\n", .{});
        try stdout.print("  wire probe 10.0.0.1 http        Test HTTP port\n", .{});
        try stdout.print("  wire probe 10.0.0.1 scan        Scan common ports\n", .{});
        try stdout.print("  wire probe service ssh          Show SSH port number\n", .{});
        return;
    }

    const first_arg = args[0];

    // wire probe service <name> - lookup service
    if (std.mem.eql(u8, first_arg, "service")) {
        if (args.len < 2) {
            try stdout.print("Usage: wire probe service <name>\n", .{});
            return;
        }
        const service_name = args[1];
        if (probe.lookupService(allocator, service_name, null) catch null) |service| {
            try stdout.print("{s}: {d}/{s}\n", .{ service.name, service.port, service.protocol.toString() });
        } else {
            try stdout.print("Service '{s}' not found in /etc/services\n", .{service_name});
        }
        return;
    }

    // wire probe <host> <port|service|scan>
    if (args.len < 2) {
        try stdout.print("Usage: wire probe <host> <port|service>\n", .{});
        return;
    }

    const target = first_arg;
    const port_or_cmd = args[1];

    // Parse timeout if provided
    var timeout_ms: u32 = 3000; // Default 3 seconds
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--timeout") or std.mem.eql(u8, args[i], "-t")) {
            timeout_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                try stdout.print("Invalid timeout: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        }
    }

    // wire probe <host> scan - scan common ports
    if (std.mem.eql(u8, port_or_cmd, "scan")) {
        try stdout.print("Scanning {s} (common ports, timeout {d}ms)...\n\n", .{ target, timeout_ms });

        for (probe.CommonPorts.quick_scan) |port| {
            const result = probe.probeTcp(target, port, timeout_ms);
            try result.format(stdout);
        }
        return;
    }

    // Resolve port from service name or number
    const port = probe.resolvePort(allocator, port_or_cmd, .tcp) catch |err| {
        if (err == error.unknownService) {
            try stdout.print("Unknown service: {s}\n", .{port_or_cmd});
            try stdout.print("Use a port number or a service name from /etc/services\n", .{});
        } else {
            try stdout.print("Failed to resolve port: {}\n", .{err});
        }
        return;
    };

    // Probe the port
    const result = probe.probeTcp(target, port, timeout_ms);
    try result.format(stdout);
}

