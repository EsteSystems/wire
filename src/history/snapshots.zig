const std = @import("std");
const state_types = @import("../state/types.zig");
const state_exporter = @import("../state/exporter.zig");
const state_desired = @import("../state/desired.zig");
const parser = @import("../syntax/parser.zig");

/// Snapshot information
pub const SnapshotInfo = struct {
    timestamp: i64,
    filename: [64]u8,
    filename_len: usize,
    size: u64,

    pub fn getFilename(self: *const SnapshotInfo) []const u8 {
        return self.filename[0..self.filename_len];
    }
};

/// Snapshot result
pub const Snapshot = struct {
    timestamp: i64,
    path: [256]u8,
    path_len: usize,
    size: u64,

    pub fn getPath(self: *const Snapshot) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// Snapshot manager - handles creating and retrieving state snapshots
pub const SnapshotManager = struct {
    allocator: std.mem.Allocator,
    snapshot_dir: []const u8,
    max_snapshots: usize,

    const Self = @This();
    const default_dir = "/var/lib/wire/snapshots";
    const default_max = 100;

    pub fn init(allocator: std.mem.Allocator, dir: ?[]const u8) Self {
        return Self{
            .allocator = allocator,
            .snapshot_dir = dir orelse default_dir,
            .max_snapshots = default_max,
        };
    }

    pub fn initWithMax(allocator: std.mem.Allocator, dir: ?[]const u8, max: usize) Self {
        return Self{
            .allocator = allocator,
            .snapshot_dir = dir orelse default_dir,
            .max_snapshots = max,
        };
    }

    /// Ensure snapshot directory exists (creates parent dirs too)
    pub fn ensureDir(self: *Self) !void {
        // Open root as base for makePath
        var root = std.fs.openDirAbsolute("/", .{}) catch {
            // Fallback: try makeDirAbsolute
            std.fs.makeDirAbsolute(self.snapshot_dir) catch |err| {
                if (err != error.PathAlreadyExists) {
                    return err;
                }
            };
            return;
        };
        defer root.close();

        // Remove leading / for relative path
        const rel_path = if (self.snapshot_dir.len > 0 and self.snapshot_dir[0] == '/')
            self.snapshot_dir[1..]
        else
            self.snapshot_dir;

        root.makePath(rel_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
        };
    }

    /// Create a snapshot of the current state
    pub fn createSnapshot(self: *Self, state: *const state_types.NetworkState) !Snapshot {
        try self.ensureDir();

        const timestamp = std.time.timestamp();

        // Generate filename: snapshot_<timestamp>.conf
        var filename_buf: [64]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "snapshot_{d}.conf", .{timestamp}) catch unreachable;

        // Build full path
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.snapshot_dir, filename }) catch unreachable;

        // Export state to file
        var exporter = state_exporter.StateExporter.init(self.allocator, state_exporter.ExportOptions{
            .comments = true,
            .skip_loopback = true,
            .skip_auto_addresses = true,
            .skip_kernel_routes = true,
        });

        try exporter.exportToFile(state, path);

        // Get file size
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const stat = try file.stat();

        var snapshot = Snapshot{
            .timestamp = timestamp,
            .path = undefined,
            .path_len = path.len,
            .size = stat.size,
        };
        @memcpy(snapshot.path[0..path.len], path);

        // Prune old snapshots if needed
        _ = self.pruneOld() catch {};

        return snapshot;
    }

    /// Load a snapshot by timestamp
    pub fn loadSnapshot(self: *Self, timestamp: i64) !state_types.NetworkState {
        // Build filename
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/snapshot_{d}.conf", .{ self.snapshot_dir, timestamp }) catch unreachable;

        // Read file
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            return error.SnapshotNotFound;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch {
            return error.ReadError;
        };
        defer self.allocator.free(content);

        // Parse content
        const commands = parser.parseConfig(content, self.allocator) catch {
            return error.ParseError;
        };
        defer {
            for (commands) |*cmd| {
                var c = cmd.*;
                c.deinit(self.allocator);
            }
            self.allocator.free(commands);
        }

        // Build network state from commands
        return state_desired.buildDesiredState(commands, self.allocator) catch {
            return error.BuildStateError;
        };
    }

    /// List all available snapshots
    pub fn listSnapshots(self: *Self) ![]SnapshotInfo {
        var snapshots = std.ArrayList(SnapshotInfo).init(self.allocator);
        errdefer snapshots.deinit();

        var dir = std.fs.openDirAbsolute(self.snapshot_dir, .{ .iterate = true }) catch {
            return snapshots.toOwnedSlice();
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            // Parse filename: snapshot_<timestamp>.conf
            if (!std.mem.startsWith(u8, entry.name, "snapshot_")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".conf")) continue;

            const ts_str = entry.name[9 .. entry.name.len - 5];
            const timestamp = std.fmt.parseInt(i64, ts_str, 10) catch continue;

            // Get file size
            const stat = dir.statFile(entry.name) catch continue;

            var info = SnapshotInfo{
                .timestamp = timestamp,
                .filename = undefined,
                .filename_len = entry.name.len,
                .size = stat.size,
            };
            const copy_len = @min(entry.name.len, info.filename.len);
            @memcpy(info.filename[0..copy_len], entry.name[0..copy_len]);

            try snapshots.append(info);
        }

        // Sort by timestamp (newest first)
        const items = snapshots.items;
        std.mem.sort(SnapshotInfo, items, {}, struct {
            fn lessThan(_: void, a: SnapshotInfo, b: SnapshotInfo) bool {
                return a.timestamp > b.timestamp;
            }
        }.lessThan);

        return snapshots.toOwnedSlice();
    }

    /// Find snapshot closest to given timestamp
    pub fn findClosestSnapshot(self: *Self, target_ts: i64) !?SnapshotInfo {
        const snapshots = try self.listSnapshots();
        defer self.allocator.free(snapshots);

        if (snapshots.len == 0) return null;

        var closest: ?SnapshotInfo = null;
        var min_diff: i64 = std.math.maxInt(i64);

        for (snapshots) |snap| {
            const diff = @abs(snap.timestamp - target_ts);
            if (diff < min_diff) {
                min_diff = @intCast(diff);
                closest = snap;
            }
        }

        return closest;
    }

    /// Remove old snapshots beyond the limit
    pub fn pruneOld(self: *Self) !usize {
        var snapshots = try self.listSnapshots();
        defer self.allocator.free(snapshots);

        if (snapshots.len <= self.max_snapshots) return 0;

        var removed: usize = 0;
        const to_remove = snapshots.len - self.max_snapshots;

        // Snapshots are sorted newest first, so remove from end
        for (snapshots[self.max_snapshots..]) |snap| {
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.snapshot_dir, snap.getFilename() }) catch continue;

            std.fs.deleteFileAbsolute(path) catch continue;
            removed += 1;
        }

        _ = to_remove;
        return removed;
    }

    /// Get the most recent snapshot
    pub fn getLatestSnapshot(self: *Self) !?SnapshotInfo {
        const snapshots = try self.listSnapshots();
        defer self.allocator.free(snapshots);

        if (snapshots.len == 0) return null;
        return snapshots[0]; // Already sorted newest first
    }

    /// Format snapshot info for display
    pub fn formatSnapshotInfo(info: *const SnapshotInfo, writer: anytype) !void {
        // Convert timestamp to human-readable
        const ts = info.timestamp;
        const epoch_seconds: u64 = @intCast(ts);

        // Calculate date/time components (simplified)
        const seconds_per_minute = 60;
        const seconds_per_hour = 3600;
        const seconds_per_day = 86400;

        const days_since_epoch = epoch_seconds / seconds_per_day;
        const remaining_seconds = epoch_seconds % seconds_per_day;
        const hours = remaining_seconds / seconds_per_hour;
        const minutes = (remaining_seconds % seconds_per_hour) / seconds_per_minute;
        const seconds = remaining_seconds % seconds_per_minute;

        // Approximate year/month/day (simplified, not accurate for all dates)
        var year: u64 = 1970;
        var remaining_days = days_since_epoch;

        while (remaining_days >= 365) {
            const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
            const year_days: u64 = if (is_leap) 366 else 365;
            if (remaining_days >= year_days) {
                remaining_days -= year_days;
                year += 1;
            } else {
                break;
            }
        }

        try writer.print("{d} ({d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}) - {d} bytes\n", .{
            ts,
            year,
            remaining_days / 30 + 1, // Approximate month
            remaining_days % 30 + 1, // Approximate day
            hours,
            minutes,
            seconds,
            info.size,
        });
    }
};

// Tests

test "SnapshotManager init" {
    const allocator = std.testing.allocator;
    const mgr = SnapshotManager.init(allocator, null);

    try std.testing.expectEqualStrings("/var/lib/wire/snapshots", mgr.snapshot_dir);
    try std.testing.expectEqual(@as(usize, 100), mgr.max_snapshots);
}

test "SnapshotManager custom dir" {
    const allocator = std.testing.allocator;
    const mgr = SnapshotManager.init(allocator, "/tmp/wire-test");

    try std.testing.expectEqualStrings("/tmp/wire-test", mgr.snapshot_dir);
}
