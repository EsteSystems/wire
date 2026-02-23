const std = @import("std");
const parser = @import("parser.zig");
const semantic = @import("semantic.zig");
const netlink_interface = @import("../netlink/interface.zig");
const netlink_address = @import("../netlink/address.zig");
const netlink_route = @import("../netlink/route.zig");
const netlink_bond = @import("../netlink/bond.zig");
const netlink_bridge = @import("../netlink/bridge.zig");
const netlink_vlan = @import("../netlink/vlan.zig");
const netlink_veth = @import("../netlink/veth.zig");
const linux = std.os.linux;
const state_live = @import("../state/live.zig");
const connectivity = @import("../analysis/connectivity.zig");
const health = @import("../analysis/health.zig");

const Command = parser.Command;
const Subject = parser.Subject;
const Action = parser.Action;
const Attribute = parser.Attribute;

/// Execution result
pub const ExecutionResult = union(enum) {
    success: SuccessResult,
    err: ErrorResult,
};

pub const SuccessResult = struct {
    message: []const u8,
};

pub const ErrorResult = struct {
    message: []const u8,
    code: ?i32,
};

/// Execution errors
pub const ExecuteError = error{
    InterfaceNotFound,
    InvalidAddress,
    InvalidMtu,
    NetlinkError,
    ValidationFailed,
    NotImplemented,
    OutOfMemory,
};

/// Command executor - bridges parser to netlink operations
pub const Executor = struct {
    allocator: std.mem.Allocator,
    stdout: std.fs.File.DeprecatedWriter,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .stdout = std.fs.File.stdout().deprecatedWriter(),
        };
    }

    /// Execute a parsed command
    pub fn execute(self: *Self, cmd: *const Command) ExecuteError!void {
        // First validate
        var result = semantic.validateCommand(cmd, self.allocator) catch return ExecuteError.ValidationFailed;
        defer result.deinit(self.allocator);

        if (!result.valid) {
            for (result.errors) |err| {
                self.stdout.print("Validation error: {s}\n", .{err.message}) catch {};
            }
            return ExecuteError.ValidationFailed;
        }

        // Execute based on subject
        switch (cmd.subject) {
            .interface => |iface| try self.executeInterface(iface, cmd.action, cmd.attributes),
            .route => |route| try self.executeRoute(route, cmd.action, cmd.attributes),
            .analyze => try self.executeAnalyze(),
            .bond => |bond| try self.executeBond(bond, cmd.action, cmd.attributes),
            .bridge => |bridge| try self.executeBridge(bridge, cmd.action, cmd.attributes),
            .vlan => |vlan| try self.executeVlan(vlan, cmd.action, cmd.attributes),
            .veth => |veth| try self.executeVeth(veth, cmd.action),
            .tc => try self.executeTc(cmd),
            .tunnel => try self.executeTunnel(cmd),
        }
    }

    // Bond commands

    fn executeBond(
        self: *Self,
        bond: parser.BondSubject,
        action: Action,
        attributes: []const Attribute,
    ) ExecuteError!void {
        const name = bond.name orelse return ExecuteError.ValidationFailed;

        switch (action) {
            .create => {
                // Get mode from attributes or use default
                var mode: netlink_bond.BondMode = .balance_rr;
                for (attributes) |attr| {
                    if (std.mem.eql(u8, attr.name, "mode")) {
                        if (attr.value) |mode_str| {
                            mode = netlink_bond.BondMode.fromString(mode_str) orelse .balance_rr;
                        }
                    }
                }
                netlink_bond.createBond(name, mode) catch return ExecuteError.NetlinkError;
                self.stdout.print("Bond {s} created with mode {s}\n", .{ name, mode.toString() }) catch {};
            },
            .delete => {
                netlink_bond.deleteBond(name) catch return ExecuteError.NetlinkError;
                self.stdout.print("Bond {s} deleted\n", .{name}) catch {};
            },
            .add => |add| {
                if (add.value) |member| {
                    netlink_bond.addBondMember(name, member) catch return ExecuteError.NetlinkError;
                    self.stdout.print("Added {s} to bond {s}\n", .{ member, name }) catch {};
                }
            },
            .del => |del| {
                if (del.value) |member| {
                    netlink_bond.removeBondMember(member) catch return ExecuteError.NetlinkError;
                    self.stdout.print("Removed {s} from bond\n", .{member}) catch {};
                }
            },
            else => return ExecuteError.NotImplemented,
        }
    }

    // Bridge commands

    fn executeBridge(
        self: *Self,
        bridge: parser.BridgeSubject,
        action: Action,
        attributes: []const Attribute,
    ) ExecuteError!void {
        _ = attributes;
        const name = bridge.name orelse return ExecuteError.ValidationFailed;

        switch (action) {
            .create => {
                netlink_bridge.createBridge(name) catch return ExecuteError.NetlinkError;
                self.stdout.print("Bridge {s} created\n", .{name}) catch {};
            },
            .delete => {
                netlink_bridge.deleteBridge(name) catch return ExecuteError.NetlinkError;
                self.stdout.print("Bridge {s} deleted\n", .{name}) catch {};
            },
            .add => |add| {
                if (add.value) |port| {
                    netlink_bridge.addBridgeMember(name, port) catch return ExecuteError.NetlinkError;
                    self.stdout.print("Added {s} to bridge {s}\n", .{ port, name }) catch {};
                }
            },
            .del => |del| {
                if (del.value) |port| {
                    netlink_bridge.removeBridgeMember(port) catch return ExecuteError.NetlinkError;
                    self.stdout.print("Removed {s} from bridge\n", .{port}) catch {};
                }
            },
            else => return ExecuteError.NotImplemented,
        }
    }

    // VLAN commands

    fn executeVlan(
        self: *Self,
        vlan: parser.VlanSubject,
        action: Action,
        attributes: []const Attribute,
    ) ExecuteError!void {
        switch (action) {
            .create, .none => {
                // "vlan 100 on eth0" defaults to create
                const id = vlan.id orelse return ExecuteError.ValidationFailed;
                const parent = vlan.parent orelse return ExecuteError.ValidationFailed;

                // Check for custom name in attributes
                var custom_name: ?[]const u8 = null;
                for (attributes) |attr| {
                    if (std.mem.eql(u8, attr.name, "name")) {
                        custom_name = attr.value;
                    }
                }

                if (custom_name) |name| {
                    netlink_vlan.createVlanWithName(parent, id, name) catch return ExecuteError.NetlinkError;
                    self.stdout.print("VLAN {s} created (ID {d} on {s})\n", .{ name, id, parent }) catch {};
                } else {
                    netlink_vlan.createVlan(parent, id) catch return ExecuteError.NetlinkError;
                    self.stdout.print("VLAN {s}.{d} created\n", .{ parent, id }) catch {};
                }
            },
            .delete => {
                if (vlan.parent) |parent| {
                    if (vlan.id) |id| {
                        var name_buf: [32]u8 = undefined;
                        const vlan_name = std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ parent, id }) catch return ExecuteError.ValidationFailed;
                        netlink_vlan.deleteVlan(vlan_name) catch return ExecuteError.NetlinkError;
                        self.stdout.print("VLAN {s} deleted\n", .{vlan_name}) catch {};
                    }
                }
            },
            else => return ExecuteError.NotImplemented,
        }
    }

    // Veth commands

    fn executeVeth(
        self: *Self,
        veth: parser.VethSubject,
        action: Action,
    ) ExecuteError!void {
        switch (action) {
            .create, .none => {
                const name = veth.name orelse return ExecuteError.ValidationFailed;
                const peer = veth.peer orelse return ExecuteError.ValidationFailed;

                netlink_veth.createVethPair(name, peer) catch return ExecuteError.NetlinkError;
                self.stdout.print("Created veth pair: {s} <-> {s}\n", .{ name, peer }) catch {};
            },
            .delete => {
                const name = veth.name orelse return ExecuteError.ValidationFailed;
                netlink_veth.deleteVeth(name) catch return ExecuteError.NetlinkError;
                self.stdout.print("Deleted veth pair: {s}\n", .{name}) catch {};
            },
            .show => {
                const name = veth.name orelse return ExecuteError.ValidationFailed;
                if (netlink_veth.getVethInfo(self.allocator, name)) |maybe_info| {
                    if (maybe_info) |info| {
                        self.stdout.print("Veth: {s}\n", .{name}) catch {};
                        self.stdout.print("  Peer: {s} (index {d})\n", .{ info.getPeerName(), info.peer_index }) catch {};
                    } else {
                        self.stdout.print("{s}: not a veth interface\n", .{name}) catch {};
                    }
                } else |_| {
                    return ExecuteError.NetlinkError;
                }
            },
            else => return ExecuteError.NotImplemented,
        }
    }

    // Interface commands

    fn executeInterface(
        self: *Self,
        iface: parser.InterfaceSubject,
        action: Action,
        attributes: []const Attribute,
    ) ExecuteError!void {
        switch (action) {
            .none => {
                // List all interfaces
                try self.listInterfaces();
            },
            .show => {
                // Show specific interface
                if (iface.name) |name| {
                    try self.showInterface(name);
                }
            },
            .set => |set| {
                if (iface.name) |name| {
                    if (std.mem.eql(u8, set.attr, "state")) {
                        const up = std.mem.eql(u8, set.value, "up");
                        netlink_interface.setInterfaceState(name, up) catch return ExecuteError.NetlinkError;
                        self.stdout.print("Interface {s} set to {s}\n", .{ name, set.value }) catch {};
                    } else if (std.mem.eql(u8, set.attr, "mtu")) {
                        const mtu = std.fmt.parseInt(u32, set.value, 10) catch return ExecuteError.InvalidMtu;
                        netlink_interface.setInterfaceMtu(name, mtu) catch return ExecuteError.NetlinkError;
                        self.stdout.print("Interface {s} MTU set to {d}\n", .{ name, mtu }) catch {};
                    }
                }
            },
            .add => |add| {
                // Add address to interface
                if (iface.name) |name| {
                    if (add.value) |addr_str| {
                        try self.addAddressToInterface(name, addr_str);
                    }
                }
            },
            .del => |del| {
                // Delete address from interface
                if (iface.name) |name| {
                    if (del.value) |addr_str| {
                        try self.delAddressFromInterface(name, addr_str);
                    }
                }
            },
            else => return ExecuteError.NotImplemented,
        }

        _ = attributes;
    }

    fn listInterfaces(self: *Self) ExecuteError!void {
        const interfaces = netlink_interface.getInterfaces(self.allocator) catch return ExecuteError.NetlinkError;
        defer self.allocator.free(interfaces);

        for (interfaces) |iface| {
            const state = if (iface.isUp()) "UP" else "DOWN";
            const carrier = if (iface.hasCarrier()) "CARRIER" else "NO-CARRIER";

            self.stdout.print("{d}: {s}: <{s},{s}> mtu {d}\n", .{
                iface.index,
                iface.getName(),
                state,
                carrier,
                iface.mtu,
            }) catch {};

            if (iface.has_mac) {
                const mac = iface.formatMac();
                self.stdout.print("    link/ether {s}\n", .{mac}) catch {};
            }

            // Get addresses
            const addrs = netlink_address.getAddressesForInterface(self.allocator, @intCast(iface.index)) catch continue;
            defer self.allocator.free(addrs);

            for (addrs) |addr| {
                var addr_buf: [64]u8 = undefined;
                const addr_str = addr.formatAddress(&addr_buf) catch continue;
                const family = if (addr.isIPv4()) "inet" else "inet6";
                self.stdout.print("    {s} {s} scope {s}\n", .{ family, addr_str, addr.scopeString() }) catch {};
            }
        }
    }

    fn showInterface(self: *Self, name: []const u8) ExecuteError!void {
        const maybe_iface = netlink_interface.getInterfaceByName(self.allocator, name) catch return ExecuteError.NetlinkError;

        if (maybe_iface) |iface| {
            const state = if (iface.isUp()) "UP" else "DOWN";
            const carrier = if (iface.hasCarrier()) "CARRIER" else "NO-CARRIER";

            self.stdout.print("{d}: {s}: <{s},{s}> mtu {d}\n", .{
                iface.index,
                iface.getName(),
                state,
                carrier,
                iface.mtu,
            }) catch {};

            if (iface.has_mac) {
                const mac = iface.formatMac();
                self.stdout.print("    link/ether {s}\n", .{mac}) catch {};
            }

            self.stdout.print("    operstate: {s}\n", .{iface.operstateString()}) catch {};

            // Get addresses
            const addrs = netlink_address.getAddressesForInterface(self.allocator, @intCast(iface.index)) catch return;
            defer self.allocator.free(addrs);

            for (addrs) |addr| {
                var addr_buf: [64]u8 = undefined;
                const addr_str = addr.formatAddress(&addr_buf) catch continue;
                const family = if (addr.isIPv4()) "inet" else "inet6";
                self.stdout.print("    {s} {s} scope {s}\n", .{ family, addr_str, addr.scopeString() }) catch {};
            }
        } else {
            self.stdout.print("Interface {s} not found\n", .{name}) catch {};
            return ExecuteError.InterfaceNotFound;
        }
    }

    fn addAddressToInterface(self: *Self, name: []const u8, addr_str: []const u8) ExecuteError!void {
        // Get interface index
        const maybe_iface = netlink_interface.getInterfaceByName(self.allocator, name) catch return ExecuteError.NetlinkError;
        if (maybe_iface == null) {
            self.stdout.print("Interface {s} not found\n", .{name}) catch {};
            return ExecuteError.InterfaceNotFound;
        }
        const iface = maybe_iface.?;

        // Parse address
        const parsed = netlink_address.parseIPv4(addr_str) catch {
            self.stdout.print("Invalid address: {s}\n", .{addr_str}) catch {};
            return ExecuteError.InvalidAddress;
        };

        // Add address
        netlink_address.addAddress(@intCast(iface.index), linux.AF.INET, &parsed.addr, parsed.prefix) catch return ExecuteError.NetlinkError;

        self.stdout.print("Added {s} to {s}\n", .{ addr_str, name }) catch {};
    }

    fn delAddressFromInterface(self: *Self, name: []const u8, addr_str: []const u8) ExecuteError!void {
        // Get interface index
        const maybe_iface = netlink_interface.getInterfaceByName(self.allocator, name) catch return ExecuteError.NetlinkError;
        if (maybe_iface == null) {
            self.stdout.print("Interface {s} not found\n", .{name}) catch {};
            return ExecuteError.InterfaceNotFound;
        }
        const iface = maybe_iface.?;

        // Parse address
        const parsed = netlink_address.parseIPv4(addr_str) catch {
            self.stdout.print("Invalid address: {s}\n", .{addr_str}) catch {};
            return ExecuteError.InvalidAddress;
        };

        // Delete address
        netlink_address.deleteAddress(@intCast(iface.index), linux.AF.INET, &parsed.addr, parsed.prefix) catch return ExecuteError.NetlinkError;

        self.stdout.print("Deleted {s} from {s}\n", .{ addr_str, name }) catch {};
    }

    // Route commands

    fn executeRoute(
        self: *Self,
        route: parser.RouteSubject,
        action: Action,
        attributes: []const Attribute,
    ) ExecuteError!void {
        switch (action) {
            .none, .show => {
                try self.listRoutes();
            },
            .add => |add| {
                try self.addRoute(route.destination orelse add.value, attributes);
            },
            .del => |del| {
                try self.delRoute(route.destination orelse del.value);
            },
            else => return ExecuteError.NotImplemented,
        }
    }

    fn listRoutes(self: *Self) ExecuteError!void {
        const routes = netlink_route.getRoutes(self.allocator) catch return ExecuteError.NetlinkError;
        defer self.allocator.free(routes);

        const interfaces = netlink_interface.getInterfaces(self.allocator) catch return ExecuteError.NetlinkError;
        defer self.allocator.free(interfaces);

        for (routes) |route| {
            // Skip local/broadcast routes
            if (route.route_type != 1) continue; // Only unicast

            var dst_buf: [64]u8 = undefined;
            const dst = route.formatDst(&dst_buf) catch continue;

            self.stdout.print("{s}", .{dst}) catch {};

            if (route.has_gateway) {
                var gw_buf: [64]u8 = undefined;
                const gw = route.formatGateway(&gw_buf) catch continue;
                self.stdout.print(" via {s}", .{gw}) catch {};
            }

            // Find interface name
            if (route.oif != 0) {
                for (interfaces) |iface| {
                    if (@as(u32, @intCast(iface.index)) == route.oif) {
                        self.stdout.print(" dev {s}", .{iface.getName()}) catch {};
                        break;
                    }
                }
            }

            self.stdout.print(" proto {s}", .{route.protocolString()}) catch {};

            if (route.priority != 0) {
                self.stdout.print(" metric {d}", .{route.priority}) catch {};
            }

            self.stdout.print("\n", .{}) catch {};
        }
    }

    fn addRoute(self: *Self, dest: ?[]const u8, attributes: []const Attribute) ExecuteError!void {
        var gateway: ?[4]u8 = null;
        var dst: ?[4]u8 = null;
        var dst_len: u8 = 0;

        // Parse destination
        if (dest) |d| {
            if (std.mem.eql(u8, d, "default")) {
                dst_len = 0; // default route
            } else {
                const parsed = netlink_address.parseIPv4(d) catch {
                    self.stdout.print("Invalid destination: {s}\n", .{d}) catch {};
                    return ExecuteError.InvalidAddress;
                };
                dst = parsed.addr;
                dst_len = parsed.prefix;
            }
        }

        // Parse attributes
        for (attributes) |attr| {
            if (std.mem.eql(u8, attr.name, "via")) {
                if (attr.value) |gw_str| {
                    const gw_parsed = netlink_address.parseIPv4(gw_str) catch {
                        self.stdout.print("Invalid gateway: {s}\n", .{gw_str}) catch {};
                        return ExecuteError.InvalidAddress;
                    };
                    gateway = gw_parsed.addr;
                }
            }
        }

        const dst_slice: ?[]const u8 = if (dst) |*d| d[0..4] else null;
        const gw_slice: ?[]const u8 = if (gateway) |*g| g[0..4] else null;

        netlink_route.addRoute(linux.AF.INET, dst_slice, dst_len, gw_slice, null) catch return ExecuteError.NetlinkError;

        self.stdout.print("Route added\n", .{}) catch {};
    }

    fn delRoute(self: *Self, dest: ?[]const u8) ExecuteError!void {
        var dst: ?[4]u8 = null;
        var dst_len: u8 = 0;

        if (dest) |d| {
            if (std.mem.eql(u8, d, "default")) {
                dst_len = 0;
            } else {
                const parsed = netlink_address.parseIPv4(d) catch {
                    self.stdout.print("Invalid destination: {s}\n", .{d}) catch {};
                    return ExecuteError.InvalidAddress;
                };
                dst = parsed.addr;
                dst_len = parsed.prefix;
            }
        } else {
            self.stdout.print("Destination required for route deletion\n", .{}) catch {};
            return ExecuteError.InvalidAddress;
        }

        const dst_slice: ?[]const u8 = if (dst) |*d| d[0..4] else null;

        netlink_route.deleteRoute(linux.AF.INET, dst_slice, dst_len) catch return ExecuteError.NetlinkError;

        self.stdout.print("Route deleted\n", .{}) catch {};
    }

    // Analyze command

    fn executeAnalyze(self: *Self) ExecuteError!void {
        self.stdout.print("\nNetwork Analysis Report\n", .{}) catch {};
        self.stdout.print("=======================\n\n", .{}) catch {};

        // Query live state
        var live_state = state_live.queryLiveState(self.allocator) catch {
            self.stdout.print("Error: Could not query network state\n", .{}) catch {};
            return ExecuteError.NetlinkError;
        };
        defer live_state.deinit();

        // Connectivity Analysis
        var conn_analyzer = connectivity.ConnectivityAnalyzer.init(self.allocator);
        defer conn_analyzer.deinit();

        _ = conn_analyzer.analyze(&live_state) catch {};
        conn_analyzer.format(self.stdout) catch {};
        self.stdout.print("\n", .{}) catch {};

        // Configuration Health
        var health_analyzer = health.HealthAnalyzer.init(self.allocator);
        defer health_analyzer.deinit();

        _ = health_analyzer.analyze(&live_state) catch {};
        health_analyzer.format(self.stdout) catch {};
        self.stdout.print("\n", .{}) catch {};

        // Interface Details
        self.stdout.print("Interface Details\n", .{}) catch {};
        self.stdout.print("-----------------\n", .{}) catch {};

        for (live_state.interfaces.items) |*iface| {
            const status: []const u8 = if (iface.isUp() and iface.hasCarrier())
                "ok"
            else if (iface.isUp())
                "warn"
            else
                "down";

            const addrs = live_state.getAddressesForInterface(iface.index);

            var addr_info: [64]u8 = undefined;
            var addr_len: usize = 0;

            if (addrs.len > 0) {
                if (addrs[0].family == 2) {
                    const addr_str = std.fmt.bufPrint(&addr_info, "{d}.{d}.{d}.{d}/{d}", .{
                        addrs[0].address[0],
                        addrs[0].address[1],
                        addrs[0].address[2],
                        addrs[0].address[3],
                        addrs[0].prefix_len,
                    }) catch continue;
                    addr_len = addr_str.len;
                }
            }

            const state = if (iface.isUp()) "up" else "down";
            const carrier = if (iface.hasCarrier()) "carrier" else "no-carrier";

            if (addr_len > 0) {
                self.stdout.print("[{s}] {s}: {s}, {s}, {s}\n", .{ status, iface.getName(), state, carrier, addr_info[0..addr_len] }) catch {};
            } else if (iface.link_type != .loopback) {
                self.stdout.print("[{s}] {s}: {s}, {s}, no address\n", .{ status, iface.getName(), state, carrier }) catch {};
            } else {
                self.stdout.print("[{s}] {s}: {s}, loopback\n", .{ status, iface.getName(), state }) catch {};
            }
        }

        // Summary
        self.stdout.print("\nSummary\n", .{}) catch {};
        self.stdout.print("-------\n", .{}) catch {};

        const conn_counts = conn_analyzer.countByStatus();
        const health_counts = health_analyzer.countByStatus();
        const overall = health_analyzer.overallStatus();

        self.stdout.print("Connectivity: {d} ok, {d} warnings, {d} errors\n", .{ conn_counts.ok, conn_counts.warning, conn_counts.err }) catch {};
        self.stdout.print("Health: {d} healthy, {d} degraded, {d} unhealthy\n", .{ health_counts.healthy, health_counts.degraded, health_counts.unhealthy }) catch {};
        self.stdout.print("Overall status: {s}\n", .{switch (overall) {
            .healthy => "HEALTHY",
            .degraded => "DEGRADED",
            .unhealthy => "UNHEALTHY",
        }}) catch {};

        self.stdout.print("\n", .{}) catch {};
    }

    // TC commands - delegate to main CLI handler for now
    fn executeTc(self: *Self, cmd: *const Command) ExecuteError!void {
        const tc = cmd.subject.tc;
        self.stdout.print("TC command: interface={s} type={s} kind={s}\n", .{
            tc.interface orelse "(none)",
            tc.tc_type orelse "(none)",
            tc.tc_kind orelse "(none)",
        }) catch {};
        self.stdout.print("Note: TC commands in config files run via 'wire tc' CLI\n", .{}) catch {};
        // TC commands are complex and require main.zig handleTc for full execution
        // Config file tc commands are parsed for validation but executed via CLI
    }

    // Tunnel commands - delegate to main CLI handler for now
    fn executeTunnel(self: *Self, cmd: *const Command) ExecuteError!void {
        const tunnel = cmd.subject.tunnel;
        self.stdout.print("Tunnel command: type={s} name={s}\n", .{
            tunnel.tunnel_type orelse "(none)",
            tunnel.name orelse "(none)",
        }) catch {};
        self.stdout.print("Note: Tunnel commands in config files run via 'wire tunnel' CLI\n", .{}) catch {};
        // Tunnel commands are complex and require main.zig handleTunnel for full execution
        // Config file tunnel commands are parsed for validation but executed via CLI
    }
};

/// Execute a command string
pub fn executeString(source: []const u8, allocator: std.mem.Allocator) ExecuteError!void {
    var cmd = parser.parse(source, allocator) catch return ExecuteError.ValidationFailed;
    defer cmd.deinit(allocator);

    var executor = Executor.init(allocator);
    try executor.execute(&cmd);
}
