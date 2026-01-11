const std = @import("std");
const state_types = @import("../state/types.zig");
const state_diff = @import("../state/diff.zig");
const parser = @import("../syntax/parser.zig");

/// Confirmation system for applying configuration changes
pub const ConfirmationSystem = struct {
    allocator: std.mem.Allocator,
    skip_confirmation: bool,
    stdin: std.fs.File,
    stdout: std.fs.File.Writer,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, skip_confirmation: bool) Self {
        return Self{
            .allocator = allocator,
            .skip_confirmation = skip_confirmation,
            .stdin = std.io.getStdIn(),
            .stdout = std.io.getStdOut().writer(),
        };
    }

    /// Show a preview of commands that will be executed
    pub fn showCommandPreview(self: *Self, commands: []const parser.Command) !void {
        try self.stdout.print("\nCommands to be applied:\n", .{});
        try self.stdout.print("========================\n", .{});

        for (commands, 0..) |*cmd, i| {
            try self.stdout.print("{d}. ", .{i + 1});
            try self.formatCommand(cmd);
            try self.stdout.print("\n", .{});
        }
        try self.stdout.print("\n", .{});
    }

    /// Show a preview of state changes
    pub fn showChangePreview(self: *Self, diff: *const state_types.StateDiff) !void {
        if (diff.isEmpty()) {
            try self.stdout.print("\nNo changes needed - state is already in sync\n", .{});
            return;
        }

        try self.stdout.print("\nChanges to be applied ({d} total):\n", .{diff.changes.items.len});
        try self.stdout.print("===================================\n\n", .{});

        var dangerous_count: usize = 0;

        for (diff.changes.items) |change| {
            const symbol = getChangeSymbol(change);
            const dangerous = isDangerousChange(change);

            if (dangerous) {
                try self.stdout.print("{s} [CAUTION] ", .{symbol});
                dangerous_count += 1;
            } else {
                try self.stdout.print("{s} ", .{symbol});
            }

            try self.formatChange(change);
            try self.stdout.print("\n", .{});
        }

        if (dangerous_count > 0) {
            try self.stdout.print("\n[!] {d} potentially dangerous change(s) detected\n", .{dangerous_count});
        }
        try self.stdout.print("\n", .{});
    }

    /// Prompt for confirmation
    pub fn promptConfirmation(self: *Self, prompt: []const u8) !bool {
        if (self.skip_confirmation) {
            return true;
        }

        try self.stdout.print("{s} [y/N]: ", .{prompt});

        var buf: [16]u8 = undefined;
        const reader = self.stdin.reader();
        const line = reader.readUntilDelimiter(&buf, '\n') catch {
            return false;
        };

        if (line.len == 0) return false;

        const first = std.ascii.toLower(line[0]);
        return first == 'y';
    }

    /// Prompt for confirmation with extra warning for dangerous changes
    pub fn promptDangerousConfirmation(self: *Self, message: []const u8) !bool {
        if (self.skip_confirmation) {
            return true;
        }

        try self.stdout.print("\n", .{});
        try self.stdout.print("!!! WARNING !!!\n", .{});
        try self.stdout.print("{s}\n", .{message});
        try self.stdout.print("\nType 'yes' to confirm: ", .{});

        var buf: [16]u8 = undefined;
        const reader = self.stdin.reader();
        const line = reader.readUntilDelimiter(&buf, '\n') catch {
            return false;
        };

        return std.mem.eql(u8, line, "yes");
    }

    /// Check if any change in a diff is dangerous
    pub fn hasDangerousChanges(diff: *const state_types.StateDiff) bool {
        for (diff.changes.items) |change| {
            if (isDangerousChange(change)) {
                return true;
            }
        }
        return false;
    }

    /// Format a command for display
    fn formatCommand(self: *Self, cmd: *const parser.Command) !void {
        switch (cmd.subject) {
            .interface => |iface| {
                if (iface.name) |name| {
                    try self.stdout.print("interface {s}", .{name});
                } else {
                    try self.stdout.print("interface", .{});
                }
                try self.formatAction(cmd.action);
            },
            .route => |route| {
                try self.stdout.print("route", .{});
                if (route.destination) |dest| {
                    try self.stdout.print(" {s}", .{dest});
                }
                try self.formatAction(cmd.action);
            },
            .bond => |bond| {
                try self.stdout.print("bond", .{});
                if (bond.name) |name| {
                    try self.stdout.print(" {s}", .{name});
                }
                try self.formatAction(cmd.action);
            },
            .bridge => |bridge| {
                try self.stdout.print("bridge", .{});
                if (bridge.name) |name| {
                    try self.stdout.print(" {s}", .{name});
                }
                try self.formatAction(cmd.action);
            },
            .vlan => |vlan| {
                try self.stdout.print("vlan", .{});
                if (vlan.id) |id| {
                    try self.stdout.print(" {d}", .{id});
                }
                if (vlan.parent) |parent| {
                    try self.stdout.print(" on {s}", .{parent});
                }
            },
            .analyze => {
                try self.stdout.print("analyze", .{});
            },
        }
    }

    fn formatAction(self: *Self, action: parser.Action) !void {
        switch (action) {
            .set => |set| {
                try self.stdout.print(" set {s} {s}", .{ set.attr, set.value });
            },
            .add => |add| {
                if (add.value) |val| {
                    try self.stdout.print(" add {s}", .{val});
                } else {
                    try self.stdout.print(" add", .{});
                }
            },
            .del => |del| {
                if (del.value) |val| {
                    try self.stdout.print(" del {s}", .{val});
                } else {
                    try self.stdout.print(" del", .{});
                }
            },
            .create => {
                try self.stdout.print(" create", .{});
            },
            .delete => {
                try self.stdout.print(" delete", .{});
            },
            .show => {
                try self.stdout.print(" show", .{});
            },
            .none => {},
        }
    }

    /// Format a state change for display
    fn formatChange(self: *Self, change: state_types.StateChange) !void {
        switch (change) {
            .bond_add => |bond| {
                try self.stdout.print("Create bond: {s} (mode: {s})", .{ bond.getName(), @tagName(bond.mode) });
            },
            .bond_remove => |name| {
                try self.stdout.print("Delete bond: {s}", .{name});
            },
            .bridge_add => |bridge| {
                try self.stdout.print("Create bridge: {s}", .{bridge.getName()});
            },
            .bridge_remove => |name| {
                try self.stdout.print("Delete bridge: {s}", .{name});
            },
            .vlan_add => |vlan| {
                try self.stdout.print("Create VLAN: {s} (ID {d})", .{ vlan.getName(), vlan.vlan_id });
            },
            .vlan_remove => |name| {
                try self.stdout.print("Delete VLAN: {s}", .{name});
            },
            .interface_modify => |mod| {
                try self.stdout.print("Modify interface: {s}", .{mod.name});
                if (mod.old.isUp() != mod.new.isUp()) {
                    const old_state = if (mod.old.isUp()) "up" else "down";
                    const new_state = if (mod.new.isUp()) "up" else "down";
                    try self.stdout.print(" (state: {s} -> {s})", .{ old_state, new_state });
                }
                if (mod.old.mtu != mod.new.mtu) {
                    try self.stdout.print(" (mtu: {d} -> {d})", .{ mod.old.mtu, mod.new.mtu });
                }
            },
            .address_add => |addr| {
                var buf: [64]u8 = undefined;
                const addr_str = formatAddress(&addr, &buf) catch "?";
                try self.stdout.print("Add address: {s}", .{addr_str});
            },
            .address_remove => |addr| {
                var buf: [64]u8 = undefined;
                const addr_str = formatAddress(&addr, &buf) catch "?";
                try self.stdout.print("Remove address: {s}", .{addr_str});
            },
            .route_add => |route| {
                var buf: [128]u8 = undefined;
                const route_str = formatRoute(&route, &buf) catch "?";
                try self.stdout.print("Add route: {s}", .{route_str});
            },
            .route_remove => |route| {
                var buf: [128]u8 = undefined;
                const route_str = formatRoute(&route, &buf) catch "?";
                try self.stdout.print("Remove route: {s}", .{route_str});
            },
            else => {
                try self.stdout.print("Other change", .{});
            },
        }
    }
};

/// Determine if a change is potentially dangerous
pub fn isDangerousChange(change: state_types.StateChange) bool {
    switch (change) {
        .interface_modify => |mod| {
            // Bringing down an interface is dangerous
            if (mod.old.isUp() and !mod.new.isUp()) {
                return true;
            }
        },
        .route_remove => |route| {
            // Removing default route is dangerous
            if (route.dst_len == 0) {
                return true;
            }
        },
        .address_remove => {
            // Removing addresses is potentially dangerous
            return true;
        },
        .bond_remove, .bridge_remove => {
            // Deleting virtual interfaces is dangerous
            return true;
        },
        else => {},
    }
    return false;
}

/// Get symbol for change type
fn getChangeSymbol(change: state_types.StateChange) []const u8 {
    return switch (change) {
        .bond_add, .bridge_add, .vlan_add, .address_add, .route_add, .interface_add => "+",
        .bond_remove, .bridge_remove, .vlan_remove, .address_remove, .route_remove, .interface_remove => "-",
        .interface_modify => "~",
    };
}

// Address/route formatting helpers

fn formatAddress(addr: *const state_types.AddressState, buf: []u8) ![]const u8 {
    if (addr.family == 2) {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}/{d}", .{
            addr.address[0],
            addr.address[1],
            addr.address[2],
            addr.address[3],
            addr.prefix_len,
        });
    }
    return "ipv6";
}

fn formatRoute(route: *const state_types.RouteState, buf: []u8) ![]const u8 {
    var offset: usize = 0;

    // Destination
    if (route.dst_len == 0) {
        const s = "default";
        @memcpy(buf[offset .. offset + s.len], s);
        offset += s.len;
    } else if (route.family == 2) {
        const dst_str = try std.fmt.bufPrint(buf[offset..], "{d}.{d}.{d}.{d}/{d}", .{
            route.dst[0],
            route.dst[1],
            route.dst[2],
            route.dst[3],
            route.dst_len,
        });
        offset += dst_str.len;
    }

    // Gateway
    if (route.has_gateway and route.family == 2) {
        const via = " via ";
        @memcpy(buf[offset .. offset + via.len], via);
        offset += via.len;

        const gw_str = try std.fmt.bufPrint(buf[offset..], "{d}.{d}.{d}.{d}", .{
            route.gateway[0],
            route.gateway[1],
            route.gateway[2],
            route.gateway[3],
        });
        offset += gw_str.len;
    }

    return buf[0..offset];
}

/// Apply configuration options
pub const ApplyOptions = struct {
    skip_confirmation: bool = false,
    dry_run: bool = false,
    force: bool = false,
    verbose: bool = false,
};

// Tests

test "isDangerousChange" {
    // Interface down is dangerous
    const mod_down = state_types.StateChange{
        .interface_modify = .{
            .name = "eth0",
            .old = state_types.InterfaceState{
                .name = [_]u8{ 'e', 't', 'h', '0', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                .name_len = 4,
                .index = 1,
                .flags = 1, // UP
                .mtu = 1500,
                .mac = [_]u8{ 0, 0, 0, 0, 0, 0 },
                .has_mac = false,
                .operstate = 0,
                .link_type = .physical,
                .master_index = null,
            },
            .new = state_types.InterfaceState{
                .name = [_]u8{ 'e', 't', 'h', '0', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                .name_len = 4,
                .index = 1,
                .flags = 0, // DOWN
                .mtu = 1500,
                .mac = [_]u8{ 0, 0, 0, 0, 0, 0 },
                .has_mac = false,
                .operstate = 0,
                .link_type = .physical,
                .master_index = null,
            },
        },
    };

    try std.testing.expect(isDangerousChange(mod_down));
}

test "getChangeSymbol" {
    const add_route = state_types.StateChange{
        .route_add = state_types.RouteState{
            .family = 2,
            .dst = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .dst_len = 0,
            .gateway = [_]u8{ 10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .has_gateway = true,
            .oif = 0,
            .priority = 0,
            .table = 0,
            .protocol = 0,
            .scope = 0,
            .route_type = 1,
        },
    };

    try std.testing.expectEqualStrings("+", getChangeSymbol(add_route));
}
