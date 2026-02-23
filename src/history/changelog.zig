const std = @import("std");
const state_types = @import("../state/types.zig");

/// Change type categories
pub const ChangeType = enum {
    interface,
    address,
    route,
    bond,
    bridge,
    vlan,

    pub fn toString(self: ChangeType) []const u8 {
        return switch (self) {
            .interface => "interface",
            .address => "address",
            .route => "route",
            .bond => "bond",
            .bridge => "bridge",
            .vlan => "vlan",
        };
    }

    pub fn fromString(s: []const u8) ?ChangeType {
        if (std.mem.eql(u8, s, "interface")) return .interface;
        if (std.mem.eql(u8, s, "address")) return .address;
        if (std.mem.eql(u8, s, "route")) return .route;
        if (std.mem.eql(u8, s, "bond")) return .bond;
        if (std.mem.eql(u8, s, "bridge")) return .bridge;
        if (std.mem.eql(u8, s, "vlan")) return .vlan;
        return null;
    }
};

/// A single change log entry
pub const ChangeEntry = struct {
    timestamp: i64,
    change_type: ChangeType,
    target: [64]u8,
    target_len: usize,
    action: [32]u8,
    action_len: usize,
    details: [128]u8,
    details_len: usize,

    const Self = @This();

    pub fn getTarget(self: *const Self) []const u8 {
        return self.target[0..self.target_len];
    }

    pub fn getAction(self: *const Self) []const u8 {
        return self.action[0..self.action_len];
    }

    pub fn getDetails(self: *const Self) []const u8 {
        return self.details[0..self.details_len];
    }

    /// Create a new change entry
    pub fn create(
        change_type: ChangeType,
        target: []const u8,
        action: []const u8,
        details: []const u8,
    ) Self {
        var entry = Self{
            .timestamp = std.time.timestamp(),
            .change_type = change_type,
            .target = undefined,
            .target_len = 0,
            .action = undefined,
            .action_len = 0,
            .details = undefined,
            .details_len = 0,
        };

        const target_copy_len = @min(target.len, entry.target.len);
        @memcpy(entry.target[0..target_copy_len], target[0..target_copy_len]);
        entry.target_len = target_copy_len;

        const action_copy_len = @min(action.len, entry.action.len);
        @memcpy(entry.action[0..action_copy_len], action[0..action_copy_len]);
        entry.action_len = action_copy_len;

        const details_copy_len = @min(details.len, entry.details.len);
        @memcpy(entry.details[0..details_copy_len], details[0..details_copy_len]);
        entry.details_len = details_copy_len;

        return entry;
    }

    /// Format entry for display
    pub fn format(self: *const Self, writer: anytype) !void {
        // Convert timestamp to human-readable
        const ts = self.timestamp;
        const epoch_seconds: u64 = @intCast(ts);

        const seconds_per_minute = 60;
        const seconds_per_hour = 3600;
        const seconds_per_day = 86400;

        const remaining_seconds = epoch_seconds % seconds_per_day;
        const hours = remaining_seconds / seconds_per_hour;
        const minutes = (remaining_seconds % seconds_per_hour) / seconds_per_minute;
        const seconds = remaining_seconds % seconds_per_minute;

        try writer.print("[{d:0>2}:{d:0>2}:{d:0>2}] {s} {s}: {s}", .{
            hours,
            minutes,
            seconds,
            self.change_type.toString(),
            self.getAction(),
            self.getTarget(),
        });

        if (self.details_len > 0) {
            try writer.print(" ({s})", .{self.getDetails()});
        }
        try writer.print("\n", .{});
    }

    /// Serialize to log format: timestamp|type|target|action|details
    pub fn serialize(self: *const Self, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{d}|{s}|{s}|{s}|{s}\n", .{
            self.timestamp,
            self.change_type.toString(),
            self.getTarget(),
            self.getAction(),
            self.getDetails(),
        });
    }

    /// Parse from log format
    pub fn parse(line: []const u8) !Self {
        var entry = Self{
            .timestamp = 0,
            .change_type = .interface,
            .target = undefined,
            .target_len = 0,
            .action = undefined,
            .action_len = 0,
            .details = undefined,
            .details_len = 0,
        };

        var iter = std.mem.splitScalar(u8, line, '|');

        // Timestamp
        const ts_str = iter.next() orelse return error.InvalidFormat;
        entry.timestamp = std.fmt.parseInt(i64, ts_str, 10) catch return error.InvalidTimestamp;

        // Type
        const type_str = iter.next() orelse return error.InvalidFormat;
        entry.change_type = ChangeType.fromString(type_str) orelse return error.InvalidType;

        // Target
        const target = iter.next() orelse return error.InvalidFormat;
        const target_len = @min(target.len, entry.target.len);
        @memcpy(entry.target[0..target_len], target[0..target_len]);
        entry.target_len = target_len;

        // Action
        const action = iter.next() orelse return error.InvalidFormat;
        const action_len = @min(action.len, entry.action.len);
        @memcpy(entry.action[0..action_len], action[0..action_len]);
        entry.action_len = action_len;

        // Details (may contain |, so take rest)
        if (iter.next()) |details| {
            const details_trimmed = std.mem.trimRight(u8, details, "\n\r");
            const details_len = @min(details_trimmed.len, entry.details.len);
            @memcpy(entry.details[0..details_len], details_trimmed[0..details_len]);
            entry.details_len = details_len;
        }

        return entry;
    }
};

/// Change logger - records and retrieves change history
pub const ChangeLogger = struct {
    allocator: std.mem.Allocator,
    log_path: []const u8,

    const Self = @This();
    const default_path = "/var/lib/wire/changelog.log";

    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8) Self {
        return Self{
            .allocator = allocator,
            .log_path = path orelse default_path,
        };
    }

    /// Ensure parent directory exists (creates full path)
    fn ensureDir(self: *Self) !void {
        // Get parent directory
        const parent = std.fs.path.dirname(self.log_path) orelse return;

        // Open root as base for makePath
        var root = std.fs.openDirAbsolute("/", .{}) catch {
            // Fallback: try makeDirAbsolute
            std.fs.makeDirAbsolute(parent) catch |err| {
                if (err != error.PathAlreadyExists) {
                    return err;
                }
            };
            return;
        };
        defer root.close();

        // Remove leading / for relative path
        const rel_path = if (parent.len > 0 and parent[0] == '/')
            parent[1..]
        else
            parent;

        root.makePath(rel_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
        };
    }

    /// Log a change entry
    pub fn logChange(self: *Self, entry: ChangeEntry) !void {
        try self.ensureDir();

        const file = std.fs.createFileAbsolute(self.log_path, .{
            .truncate = false,
        }) catch |err| {
            if (err == error.PathAlreadyExists) {
                // File exists, open for append
                const f = try std.fs.openFileAbsolute(self.log_path, .{ .mode = .write_only });
                try f.seekFromEnd(0);
                var buf: [512]u8 = undefined;
                const line = try entry.serialize(&buf);
                try f.writeAll(line);
                f.close();
                return;
            }
            return err;
        };
        defer file.close();

        // Seek to end
        try file.seekFromEnd(0);

        var buf: [512]u8 = undefined;
        const line = try entry.serialize(&buf);
        try file.writeAll(line);
    }

    /// Log a state change from StateDiff
    pub fn logStateChange(self: *Self, change: state_types.StateChange) !void {
        const entry = stateChangeToEntry(change);
        try self.logChange(entry);
    }

    /// Read recent entries (last N)
    pub fn readRecent(self: *Self, count: usize) ![]ChangeEntry {
        const all = try self.readAll();
        defer self.allocator.free(all);

        if (all.len <= count) {
            // Return a copy
            const result = try self.allocator.alloc(ChangeEntry, all.len);
            @memcpy(result, all);
            return result;
        }

        // Return last N
        const result = try self.allocator.alloc(ChangeEntry, count);
        @memcpy(result, all[all.len - count ..]);
        return result;
    }

    /// Read all entries
    pub fn readAll(self: *Self) ![]ChangeEntry {
        var entries = std.array_list.Managed(ChangeEntry).init(self.allocator);
        errdefer entries.deinit();

        const file = std.fs.openFileAbsolute(self.log_path, .{}) catch {
            return entries.toOwnedSlice();
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        var remaining: []u8 = &[_]u8{};

        while (true) {
            const bytes_read = file.read(buf[remaining.len..]) catch break;
            if (bytes_read == 0) break;

            const total = remaining.len + bytes_read;
            var data = buf[0..total];

            while (std.mem.indexOf(u8, data, "\n")) |newline_pos| {
                const line = data[0..newline_pos];
                if (line.len > 0) {
                    const entry = ChangeEntry.parse(line) catch continue;
                    try entries.append(entry);
                }
                data = data[newline_pos + 1 ..];
            }

            // Keep remaining partial line
            remaining = data;
            if (remaining.len > 0 and remaining.ptr != buf[0..].ptr) {
                std.mem.copyForwards(u8, &buf, remaining);
            }
        }

        return entries.toOwnedSlice();
    }

    /// Format and display recent entries
    pub fn displayRecent(self: *Self, count: usize, writer: anytype) !void {
        const entries = try self.readRecent(count);
        defer self.allocator.free(entries);

        if (entries.len == 0) {
            try writer.print("No changes recorded.\n", .{});
            return;
        }

        try writer.print("Recent Changes ({d} entries)\n", .{entries.len});
        try writer.print("-----------------------------\n", .{});

        for (entries) |*entry| {
            try entry.format(writer);
        }
    }

    /// Get total entry count
    pub fn getEntryCount(self: *Self) !usize {
        const entries = try self.readAll();
        defer self.allocator.free(entries);
        return entries.len;
    }
};

/// Convert a StateChange to a ChangeEntry
pub fn stateChangeToEntry(change: state_types.StateChange) ChangeEntry {
    return switch (change) {
        .interface_add => |iface| ChangeEntry.create(.interface, iface.getName(), "add", "new interface"),
        .interface_remove => |name| ChangeEntry.create(.interface, name, "remove", "deleted"),
        .interface_modify => |mod| blk: {
            var detail_buf: [64]u8 = undefined;
            const old_up = mod.old.isUp();
            const new_up = mod.new.isUp();
            const detail = if (old_up != new_up)
                std.fmt.bufPrint(&detail_buf, "state: {s} -> {s}", .{
                    if (old_up) "up" else "down",
                    if (new_up) "up" else "down",
                }) catch "modified"
            else if (mod.old.mtu != mod.new.mtu)
                std.fmt.bufPrint(&detail_buf, "mtu: {d} -> {d}", .{ mod.old.mtu, mod.new.mtu }) catch "modified"
            else
                "modified";
            break :blk ChangeEntry.create(.interface, mod.name, "modify", detail);
        },
        .address_add => |addr| blk: {
            var buf: [64]u8 = undefined;
            const addr_str = formatAddress(&addr, &buf) catch "?";
            break :blk ChangeEntry.create(.address, addr_str, "add", "assigned");
        },
        .address_remove => |addr| blk: {
            var buf: [64]u8 = undefined;
            const addr_str = formatAddress(&addr, &buf) catch "?";
            break :blk ChangeEntry.create(.address, addr_str, "remove", "removed");
        },
        .route_add => |route| blk: {
            var buf: [64]u8 = undefined;
            const route_str = formatRoute(&route, &buf) catch "?";
            break :blk ChangeEntry.create(.route, route_str, "add", "added");
        },
        .route_remove => |route| blk: {
            var buf: [64]u8 = undefined;
            const route_str = formatRoute(&route, &buf) catch "?";
            break :blk ChangeEntry.create(.route, route_str, "remove", "removed");
        },
        .bond_add => |bond| ChangeEntry.create(.bond, bond.getName(), "create", "new bond"),
        .bond_remove => |name| ChangeEntry.create(.bond, name, "destroy", "deleted"),
        .bridge_add => |bridge| ChangeEntry.create(.bridge, bridge.getName(), "create", "new bridge"),
        .bridge_remove => |name| ChangeEntry.create(.bridge, name, "destroy", "deleted"),
        .vlan_add => |vlan| blk: {
            var buf: [32]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "id {d}", .{vlan.vlan_id}) catch "added";
            break :blk ChangeEntry.create(.vlan, vlan.getName(), "create", detail);
        },
        .vlan_remove => |name| ChangeEntry.create(.vlan, name, "destroy", "deleted"),
    };
}

fn formatAddress(addr: *const state_types.AddressState, buf: []u8) ![]const u8 {
    if (addr.family == 2) { // IPv4
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}/{d}", .{
            addr.address[0],
            addr.address[1],
            addr.address[2],
            addr.address[3],
            addr.prefix_len,
        });
    }
    return "?";
}

fn formatRoute(route: *const state_types.RouteState, buf: []u8) ![]const u8 {
    if (route.isDefault()) {
        if (route.has_gateway) {
            return std.fmt.bufPrint(buf, "default via {d}.{d}.{d}.{d}", .{
                route.gateway[0],
                route.gateway[1],
                route.gateway[2],
                route.gateway[3],
            });
        }
        return "default";
    }

    if (route.family == 2) { // IPv4
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}/{d}", .{
            route.dst[0],
            route.dst[1],
            route.dst[2],
            route.dst[3],
            route.dst_len,
        });
    }
    return "?";
}

// Tests

test "ChangeEntry create" {
    const entry = ChangeEntry.create(.interface, "eth0", "up", "brought up");

    try std.testing.expectEqual(ChangeType.interface, entry.change_type);
    try std.testing.expectEqualStrings("eth0", entry.getTarget());
    try std.testing.expectEqualStrings("up", entry.getAction());
    try std.testing.expectEqualStrings("brought up", entry.getDetails());
}

test "ChangeEntry serialize and parse" {
    const entry = ChangeEntry.create(.route, "default", "add", "gateway 10.0.0.1");

    var buf: [512]u8 = undefined;
    const line = try entry.serialize(&buf);

    const parsed = try ChangeEntry.parse(std.mem.trimRight(u8, line, "\n"));

    try std.testing.expectEqual(entry.change_type, parsed.change_type);
    try std.testing.expectEqualStrings(entry.getTarget(), parsed.getTarget());
    try std.testing.expectEqualStrings(entry.getAction(), parsed.getAction());
}

test "ChangeLogger init" {
    const allocator = std.testing.allocator;
    const logger = ChangeLogger.init(allocator, null);

    try std.testing.expectEqualStrings("/var/lib/wire/changelog.log", logger.log_path);
}
