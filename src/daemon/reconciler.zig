const std = @import("std");
const state_types = @import("../state/types.zig");
const state_live = @import("../state/live.zig");
const state_diff = @import("../state/diff.zig");
const netlink_interface = @import("../netlink/interface.zig");
const netlink_address = @import("../netlink/address.zig");
const netlink_route = @import("../netlink/route.zig");
const netlink_bond = @import("../netlink/bond.zig");
const netlink_bridge = @import("../netlink/bridge.zig");
const netlink_vlan = @import("../netlink/vlan.zig");
const linux = std.os.linux;

/// Result of a reconciliation action
pub const ReconcileResult = struct {
    success: bool,
    error_message: ?[]const u8 = null,
    change: state_types.StateChange,
};

/// Statistics from a reconciliation run
pub const ReconcileStats = struct {
    total_changes: usize = 0,
    applied: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    start_time: i64 = 0,
    end_time: i64 = 0,

    pub fn duration(self: *const ReconcileStats) i64 {
        return self.end_time - self.start_time;
    }
};

/// Reconciliation policy
pub const ReconcilePolicy = struct {
    /// Stop on first error
    stop_on_error: bool = false,
    /// Dry run mode - don't actually apply changes
    dry_run: bool = false,
    /// Log all actions
    verbose: bool = true,
    /// Maximum number of retries per change
    max_retries: u8 = 5,
    /// Delay between retries (ms)
    retry_delay_ms: u32 = 500,
};

/// Reconciler - applies state changes to make live state match desired state
pub const Reconciler = struct {
    allocator: std.mem.Allocator,
    policy: ReconcilePolicy,
    results: std.ArrayList(ReconcileResult),
    stats: ReconcileStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, policy: ReconcilePolicy) Self {
        return Self{
            .allocator = allocator,
            .policy = policy,
            .results = std.ArrayList(ReconcileResult).init(allocator),
            .stats = ReconcileStats{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.results.deinit();
    }

    /// Reconcile: apply changes from diff to make live state match desired
    pub fn reconcile(self: *Self, diff: *const state_types.StateDiff) !ReconcileStats {
        self.stats = ReconcileStats{
            .start_time = std.time.timestamp(),
            .total_changes = diff.changes.items.len,
        };
        self.results.clearRetainingCapacity();

        for (diff.changes.items) |change| {
            const result = self.applyChange(change);
            try self.results.append(result);

            if (result.success) {
                self.stats.applied += 1;
            } else {
                self.stats.failed += 1;
                if (self.policy.stop_on_error) {
                    break;
                }
            }
        }

        self.stats.end_time = std.time.timestamp();
        return self.stats;
    }

    /// Apply a single change
    fn applyChange(self: *Self, change: state_types.StateChange) ReconcileResult {
        if (self.policy.dry_run) {
            return ReconcileResult{
                .success = true,
                .change = change,
            };
        }

        var retries: u8 = 0;
        while (retries <= self.policy.max_retries) : (retries += 1) {
            const result = self.applyChangeOnce(change);
            if (result.success) {
                return result;
            }

            if (retries < self.policy.max_retries) {
                std.time.sleep(self.policy.retry_delay_ms * std.time.ns_per_ms);
            }
        }

        return ReconcileResult{
            .success = false,
            .error_message = "Max retries exceeded",
            .change = change,
        };
    }

    fn applyChangeOnce(self: *Self, change: state_types.StateChange) ReconcileResult {
        _ = self;

        switch (change) {
            .bond_add => |bond| {
                // Convert state BondMode to netlink BondMode
                const mode: netlink_bond.BondMode = @enumFromInt(@intFromEnum(bond.mode));
                netlink_bond.createBond(bond.getName(), mode) catch {
                    return ReconcileResult{
                        .success = false,
                        .error_message = "Failed to create bond",
                        .change = change,
                    };
                };
                return ReconcileResult{ .success = true, .change = change };
            },

            .bond_remove => |name| {
                netlink_bond.deleteBond(name) catch {
                    return ReconcileResult{
                        .success = false,
                        .error_message = "Failed to delete bond",
                        .change = change,
                    };
                };
                return ReconcileResult{ .success = true, .change = change };
            },

            .bridge_add => |bridge| {
                netlink_bridge.createBridge(bridge.getName()) catch {
                    return ReconcileResult{
                        .success = false,
                        .error_message = "Failed to create bridge",
                        .change = change,
                    };
                };
                return ReconcileResult{ .success = true, .change = change };
            },

            .bridge_remove => |name| {
                netlink_bridge.deleteBridge(name) catch {
                    return ReconcileResult{
                        .success = false,
                        .error_message = "Failed to delete bridge",
                        .change = change,
                    };
                };
                return ReconcileResult{ .success = true, .change = change };
            },

            .vlan_add => |vlan| {
                // Get parent name from parent_index
                // For now, we need to look up the parent interface name
                // This requires a live state query or we store parent name in VlanState
                // For simplicity, assume parent name is stored or we use a default
                const parent_idx = vlan.parent_index;
                _ = parent_idx;

                // TODO: Look up parent interface name
                // For now, skip VLAN creation - needs more state info
                return ReconcileResult{
                    .success = false,
                    .error_message = "VLAN creation requires parent interface lookup",
                    .change = change,
                };
            },

            .vlan_remove => |name| {
                netlink_vlan.deleteVlan(name) catch {
                    return ReconcileResult{
                        .success = false,
                        .error_message = "Failed to delete VLAN",
                        .change = change,
                    };
                };
                return ReconcileResult{ .success = true, .change = change };
            },

            .interface_modify => |mod| {
                // Apply interface state and MTU changes
                // Use mod.new.getName() instead of mod.name to avoid dangling slice
                const iface_name = mod.new.getName();
                const d_up = mod.new.isUp();
                const l_up = mod.old.isUp();

                if (d_up != l_up) {
                    netlink_interface.setInterfaceState(iface_name, d_up) catch {
                        return ReconcileResult{
                            .success = false,
                            .error_message = "Failed to set interface state",
                            .change = change,
                        };
                    };
                    // Wait for interface to be ready after bringing it up
                    if (d_up) {
                        std.time.sleep(200 * std.time.ns_per_ms);
                    }
                }

                if (mod.new.mtu != mod.old.mtu) {
                    netlink_interface.setInterfaceMtu(iface_name, mod.new.mtu) catch {
                        return ReconcileResult{
                            .success = false,
                            .error_message = "Failed to set interface MTU",
                            .change = change,
                        };
                    };
                }

                return ReconcileResult{ .success = true, .change = change };
            },

            .address_add => |addr| {
                // Look up interface by name to get actual index
                const iface_name = addr.getInterfaceName();
                var if_index: u32 = @intCast(addr.interface_index);

                if (iface_name.len > 0) {
                    // Query interface by name
                    const allocator = std.heap.page_allocator;
                    const maybe_iface = netlink_interface.getInterfaceByName(allocator, iface_name) catch {
                        return ReconcileResult{
                            .success = false,
                            .error_message = "Failed to query interface",
                            .change = change,
                        };
                    };
                    if (maybe_iface) |iface| {
                        if_index = @intCast(iface.index);
                    } else {
                        return ReconcileResult{
                            .success = false,
                            .error_message = "Interface not found",
                            .change = change,
                        };
                    }
                }

                const addr_bytes: []const u8 = if (addr.family == 2) &addr.address[0..4].* else &addr.address[0..16].*;
                netlink_address.addAddress(if_index, addr.family, addr_bytes, addr.prefix_len) catch {
                    return ReconcileResult{
                        .success = false,
                        .error_message = "Failed to add address",
                        .change = change,
                    };
                };
                return ReconcileResult{ .success = true, .change = change };
            },

            .address_remove => |addr| {
                const addr_bytes: []const u8 = if (addr.family == 2) &addr.address[0..4].* else &addr.address[0..16].*;
                netlink_address.deleteAddress(@intCast(addr.interface_index), addr.family, addr_bytes, addr.prefix_len) catch {
                    return ReconcileResult{
                        .success = false,
                        .error_message = "Failed to remove address",
                        .change = change,
                    };
                };
                return ReconcileResult{ .success = true, .change = change };
            },

            .route_add => |route| {
                const dst_bytes: ?[]const u8 = if (route.dst_len > 0)
                    (if (route.family == 2) &route.dst[0..4].* else &route.dst[0..16].*)
                else
                    null;

                const gw_bytes: ?[]const u8 = if (route.has_gateway)
                    (if (route.family == 2) &route.gateway[0..4].* else &route.gateway[0..16].*)
                else
                    null;

                netlink_route.addRoute(route.family, dst_bytes, route.dst_len, gw_bytes, if (route.oif > 0) route.oif else null) catch {
                    return ReconcileResult{
                        .success = false,
                        .error_message = "Failed to add route",
                        .change = change,
                    };
                };
                return ReconcileResult{ .success = true, .change = change };
            },

            .route_remove => |route| {
                const dst_bytes: ?[]const u8 = if (route.dst_len > 0)
                    (if (route.family == 2) &route.dst[0..4].* else &route.dst[0..16].*)
                else
                    null;

                netlink_route.deleteRoute(route.family, dst_bytes, route.dst_len) catch {
                    return ReconcileResult{
                        .success = false,
                        .error_message = "Failed to delete route",
                        .change = change,
                    };
                };
                return ReconcileResult{ .success = true, .change = change };
            },

            else => {
                return ReconcileResult{
                    .success = false,
                    .error_message = "Unknown change type",
                    .change = change,
                };
            },
        }
    }

    /// Get results from last reconciliation
    pub fn getResults(self: *const Self) []const ReconcileResult {
        return self.results.items;
    }

    /// Get stats from last reconciliation
    pub fn getStats(self: *const Self) ReconcileStats {
        return self.stats;
    }
};

/// One-shot reconciliation: compare desired vs live and apply corrections
pub fn reconcileOnce(
    desired: *const state_types.NetworkState,
    allocator: std.mem.Allocator,
    policy: ReconcilePolicy,
) !ReconcileStats {
    // Query live state
    var live = try state_live.queryLiveState(allocator);
    defer live.deinit();

    // Compute diff
    var diff = try state_diff.compare(desired, &live, allocator);
    defer diff.deinit();

    // Apply changes
    var reconciler = Reconciler.init(allocator, policy);
    defer reconciler.deinit();

    return reconciler.reconcile(&diff);
}

/// Format reconciliation results for display
pub fn formatResults(results: []const ReconcileResult, stats: ReconcileStats, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    try writer.print("Reconciliation Results\n", .{});
    try writer.print("======================\n", .{});
    try writer.print("Total changes: {d}\n", .{stats.total_changes});
    try writer.print("Applied: {d}\n", .{stats.applied});
    try writer.print("Failed: {d}\n", .{stats.failed});
    try writer.print("Skipped: {d}\n", .{stats.skipped});
    try writer.print("Duration: {d}s\n\n", .{stats.duration()});

    if (results.len > 0) {
        try writer.print("Details:\n", .{});
        for (results) |result| {
            const status = if (result.success) "OK" else "FAIL";
            const change_name = @tagName(result.change);
            try writer.print("  [{s}] {s}", .{ status, change_name });
            if (result.error_message) |msg| {
                try writer.print(" - {s}", .{msg});
            }
            try writer.print("\n", .{});
        }
    }

    return stream.getWritten();
}

// Tests

test "Reconciler init" {
    const allocator = std.testing.allocator;
    var reconciler = Reconciler.init(allocator, .{});
    defer reconciler.deinit();

    try std.testing.expect(reconciler.stats.total_changes == 0);
}

test "ReconcileStats duration" {
    const stats = ReconcileStats{
        .start_time = 1000,
        .end_time = 1005,
    };
    try std.testing.expectEqual(@as(i64, 5), stats.duration());
}
