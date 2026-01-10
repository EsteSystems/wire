const std = @import("std");
const parser = @import("parser.zig");
const semantic = @import("semantic.zig");
const netlink_interface = @import("../netlink/interface.zig");
const netlink_address = @import("../netlink/address.zig");
const netlink_route = @import("../netlink/route.zig");
const linux = std.os.linux;

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
    stdout: std.fs.File.Writer,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .stdout = std.io.getStdOut().writer(),
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
            .bond => return ExecuteError.NotImplemented,
            .bridge => return ExecuteError.NotImplemented,
            .vlan => return ExecuteError.NotImplemented,
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

        // Get interfaces
        const interfaces = netlink_interface.getInterfaces(self.allocator) catch return ExecuteError.NetlinkError;
        defer self.allocator.free(interfaces);

        self.stdout.print("Interfaces ({d} total)\n", .{interfaces.len}) catch {};
        self.stdout.print("--------------------\n", .{}) catch {};

        for (interfaces) |iface| {
            const status: []const u8 = if (iface.isUp() and iface.hasCarrier())
                "ok"
            else if (iface.isUp())
                "warn"
            else
                "down";

            const addrs = netlink_address.getAddressesForInterface(self.allocator, @intCast(iface.index)) catch continue;
            defer self.allocator.free(addrs);

            var addr_info: [64]u8 = undefined;
            var addr_len: usize = 0;

            if (addrs.len > 0) {
                var tmp_buf: [64]u8 = undefined;
                const addr_str = addrs[0].formatAddress(&tmp_buf) catch continue;
                @memcpy(addr_info[0..addr_str.len], addr_str);
                addr_len = addr_str.len;
            }

            const state = if (iface.isUp()) "up" else "down";
            const carrier = if (iface.hasCarrier()) "carrier" else "no-carrier";

            if (addr_len > 0) {
                self.stdout.print("[{s}] {s}: {s}, {s}, {s}\n", .{ status, iface.getName(), state, carrier, addr_info[0..addr_len] }) catch {};
            } else if (!iface.isLoopback()) {
                self.stdout.print("[{s}] {s}: {s}, {s}, no address\n", .{ status, iface.getName(), state, carrier }) catch {};
            } else {
                self.stdout.print("[{s}] {s}: {s}, loopback\n", .{ status, iface.getName(), state }) catch {};
            }
        }

        // Get routes
        const routes = netlink_route.getRoutes(self.allocator) catch return ExecuteError.NetlinkError;
        defer self.allocator.free(routes);

        self.stdout.print("\nRouting\n", .{}) catch {};
        self.stdout.print("-------\n", .{}) catch {};

        var has_default = false;
        for (routes) |route| {
            if (route.route_type != 1) continue;

            if (route.isDefault()) {
                has_default = true;
                var gw_buf: [64]u8 = undefined;
                const gw = route.formatGateway(&gw_buf) catch continue;
                self.stdout.print("[ok] default via {s}\n", .{gw}) catch {};
            }
        }

        if (!has_default) {
            self.stdout.print("[warn] No default route configured\n", .{}) catch {};
        }

        self.stdout.print("\n", .{}) catch {};
    }
};

/// Execute a command string
pub fn executeString(source: []const u8, allocator: std.mem.Allocator) ExecuteError!void {
    var cmd = parser.parse(source, allocator) catch return ExecuteError.ValidationFailed;
    defer cmd.deinit(allocator);

    var executor = Executor.init(allocator);
    try executor.execute(&cmd);
}
