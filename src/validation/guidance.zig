const std = @import("std");
const parser = @import("../syntax/parser.zig");
const state_types = @import("../state/types.zig");

/// Guidance level
pub const GuidanceLevel = enum {
    tip, // Helpful suggestion
    warning, // Potential issue
    danger, // Likely to cause problems

    pub fn symbol(self: GuidanceLevel) []const u8 {
        return switch (self) {
            .tip => "[tip]",
            .warning => "[warn]",
            .danger => "[!!!]",
        };
    }
};

/// Guidance category
pub const GuidanceCategory = enum {
    connectivity,
    performance,
    redundancy,
    security,
    best_practice,
    compatibility,
};

/// A single piece of operator guidance
pub const Guidance = struct {
    level: GuidanceLevel,
    category: GuidanceCategory,
    message: [256]u8,
    message_len: usize,
    recommendation: [256]u8,
    recommendation_len: usize,

    pub fn getMessage(self: *const Guidance) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn getRecommendation(self: *const Guidance) ?[]const u8 {
        if (self.recommendation_len == 0) return null;
        return self.recommendation[0..self.recommendation_len];
    }

    pub fn format(self: *const Guidance, writer: anytype) !void {
        try writer.print("{s} {s}", .{ self.level.symbol(), self.getMessage() });
        if (self.getRecommendation()) |rec| {
            try writer.print("\n    -> {s}", .{rec});
        }
        try writer.print("\n", .{});
    }
};

/// Operator guidance engine
pub const OperatorGuidance = struct {
    allocator: std.mem.Allocator,
    guidance: std.array_list.Managed(Guidance),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .guidance = std.array_list.Managed(Guidance).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.guidance.deinit();
    }

    /// Analyze configuration and live state to generate guidance
    pub fn analyzeConfig(
        self: *Self,
        commands: []const parser.Command,
        live: *const state_types.NetworkState,
    ) ![]const Guidance {
        self.guidance.clearRetainingCapacity();

        // Check for missing default route
        try self.checkDefaultRoute(commands, live);

        // Check for interface up without address
        try self.checkInterfaceWithoutAddress(commands, live);

        // Check for bond with no members
        try self.checkEmptyBond(commands);

        // Check for MTU mismatches
        try self.checkMtuMismatches(commands);

        // Check for best practices
        try self.checkBestPractices(commands);

        return self.guidance.items;
    }

    /// Check if there's a default route configured
    fn checkDefaultRoute(
        self: *Self,
        commands: []const parser.Command,
        live: *const state_types.NetworkState,
    ) !void {
        // Check live state for default route
        var has_live_default = false;
        for (live.routes.items) |*route| {
            if (route.dst_len == 0 and route.route_type == 1) {
                has_live_default = true;
                break;
            }
        }

        // Check commands for default route
        var adding_default = false;
        var removing_default = false;

        for (commands) |*cmd| {
            switch (cmd.subject) {
                .route => |route| {
                    const is_default = if (route.destination) |dest|
                        std.mem.eql(u8, dest, "default")
                    else switch (cmd.action) {
                        .add => |add| if (add.value) |val| std.mem.eql(u8, val, "default") else false,
                        .del => |del| if (del.value) |val| std.mem.eql(u8, val, "default") else false,
                        else => false,
                    };

                    if (is_default) {
                        switch (cmd.action) {
                            .add => adding_default = true,
                            .del => removing_default = true,
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        if (!has_live_default and !adding_default) {
            try self.addGuidance(
                .warning,
                .connectivity,
                "No default route configured",
                "Add a default route: route default via <gateway>",
            );
        }

        if (has_live_default and removing_default and !adding_default) {
            try self.addGuidance(
                .danger,
                .connectivity,
                "Removing default route without adding a replacement",
                "Ensure you have alternative connectivity before removing the default route",
            );
        }
    }

    /// Check for interfaces brought up without addresses
    fn checkInterfaceWithoutAddress(
        self: *Self,
        commands: []const parser.Command,
        live: *const state_types.NetworkState,
    ) !void {
        // Track which interfaces are being brought up and which get addresses
        var bringing_up = std.StringHashMap(void).init(self.allocator);
        defer bringing_up.deinit();

        var getting_address = std.StringHashMap(void).init(self.allocator);
        defer getting_address.deinit();

        for (commands) |*cmd| {
            switch (cmd.subject) {
                .interface => |iface| {
                    if (iface.name) |name| {
                        switch (cmd.action) {
                            .set => |set| {
                                if (std.mem.eql(u8, set.attr, "state") and std.mem.eql(u8, set.value, "up")) {
                                    // Check if interface already has an address
                                    const has_addr = live.findInterface(name) != null and blk: {
                                        if (live.findInterface(name)) |iface_state| {
                                            const addrs = live.getAddressesForInterface(iface_state.index);
                                            break :blk addrs.len > 0;
                                        }
                                        break :blk false;
                                    };

                                    if (!has_addr) {
                                        try bringing_up.put(name, {});
                                    }
                                }
                            },
                            .add => {
                                try getting_address.put(name, {});
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // Check for interfaces being brought up without getting an address
        var iter = bringing_up.iterator();
        while (iter.next()) |entry| {
            if (!getting_address.contains(entry.key_ptr.*)) {
                // Check if it's a bridge/bond member or VLAN parent (those don't need addresses)
                var is_member = false;
                for (commands) |*cmd| {
                    switch (cmd.subject) {
                        .bond => |bond| {
                            switch (cmd.action) {
                                .add => |add| {
                                    if (add.value) |member| {
                                        if (std.mem.eql(u8, member, entry.key_ptr.*)) {
                                            is_member = true;
                                        }
                                    }
                                },
                                else => {},
                            }
                            _ = bond;
                        },
                        .bridge => |bridge| {
                            switch (cmd.action) {
                                .add => |add| {
                                    if (add.value) |port| {
                                        if (std.mem.eql(u8, port, entry.key_ptr.*)) {
                                            is_member = true;
                                        }
                                    }
                                },
                                else => {},
                            }
                            _ = bridge;
                        },
                        else => {},
                    }
                }

                if (!is_member) {
                    try self.addGuidanceFmt(
                        .tip,
                        .connectivity,
                        "Interface '{s}' is being brought up without an IP address",
                        .{entry.key_ptr.*},
                        "Consider adding an address if this interface needs IP connectivity",
                    );
                }
            }
        }
    }

    /// Check for bonds with no members
    fn checkEmptyBond(self: *Self, commands: []const parser.Command) !void {
        // Track bonds being created and members being added
        var bonds_created = std.StringHashMap(void).init(self.allocator);
        defer bonds_created.deinit();

        var bonds_with_members = std.StringHashMap(void).init(self.allocator);
        defer bonds_with_members.deinit();

        for (commands) |*cmd| {
            switch (cmd.subject) {
                .bond => |bond| {
                    if (bond.name) |name| {
                        switch (cmd.action) {
                            .create => {
                                try bonds_created.put(name, {});
                            },
                            .add => {
                                try bonds_with_members.put(name, {});
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        var iter = bonds_created.iterator();
        while (iter.next()) |entry| {
            if (!bonds_with_members.contains(entry.key_ptr.*)) {
                try self.addGuidanceFmt(
                    .warning,
                    .redundancy,
                    "Bond '{s}' is created but has no members",
                    .{entry.key_ptr.*},
                    "Add members with: bond <name> add <interface>",
                );
            }
        }
    }

    /// Check for MTU mismatches
    fn checkMtuMismatches(self: *Self, commands: []const parser.Command) !void {
        // Track MTU settings
        var mtu_settings = std.StringHashMap(u32).init(self.allocator);
        defer mtu_settings.deinit();

        for (commands) |*cmd| {
            switch (cmd.subject) {
                .interface => |iface| {
                    if (iface.name) |name| {
                        switch (cmd.action) {
                            .set => |set| {
                                if (std.mem.eql(u8, set.attr, "mtu")) {
                                    const mtu = std.fmt.parseInt(u32, set.value, 10) catch continue;
                                    try mtu_settings.put(name, mtu);
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // Check VLAN parent MTU
        for (commands) |*cmd| {
            switch (cmd.subject) {
                .vlan => |vlan| {
                    if (vlan.parent) |parent| {
                        if (vlan.id) |id| {
                            var vlan_name_buf: [32]u8 = undefined;
                            const vlan_name = std.fmt.bufPrint(&vlan_name_buf, "{s}.{d}", .{ parent, id }) catch continue;

                            const parent_mtu = mtu_settings.get(parent);
                            const vlan_mtu = mtu_settings.get(vlan_name);

                            if (vlan_mtu) |v_mtu| {
                                if (parent_mtu) |p_mtu| {
                                    if (v_mtu > p_mtu) {
                                        try self.addGuidanceFmt(
                                            .warning,
                                            .compatibility,
                                            "VLAN '{s}' MTU ({d}) exceeds parent '{s}' MTU ({d})",
                                            .{ vlan_name, v_mtu, parent, p_mtu },
                                            "VLAN MTU should not exceed parent interface MTU",
                                        );
                                    }
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// Check for best practices
    fn checkBestPractices(self: *Self, commands: []const parser.Command) !void {
        // Check bond mode recommendations
        for (commands) |*cmd| {
            switch (cmd.subject) {
                .bond => {
                    switch (cmd.action) {
                        .create => {
                            var has_mode = false;
                            for (cmd.attributes) |attr| {
                                if (std.mem.eql(u8, attr.name, "mode")) {
                                    has_mode = true;
                                    if (attr.value) |mode| {
                                        // Check for mode 0 (balance-rr) which often has issues
                                        if (std.mem.eql(u8, mode, "0") or std.mem.eql(u8, mode, "balance-rr")) {
                                            try self.addGuidance(
                                                .tip,
                                                .performance,
                                                "Bond mode 'balance-rr' may cause out-of-order packets",
                                                "Consider 'active-backup' (1) or '802.3ad' (4) for most use cases",
                                            );
                                        }
                                    }
                                }
                            }
                            if (!has_mode) {
                                try self.addGuidance(
                                    .tip,
                                    .best_practice,
                                    "Bond created without explicit mode",
                                    "Default mode is balance-rr. Consider specifying mode explicitly",
                                );
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    /// Add a guidance entry
    fn addGuidance(
        self: *Self,
        level: GuidanceLevel,
        category: GuidanceCategory,
        message: []const u8,
        recommendation: ?[]const u8,
    ) !void {
        var g = Guidance{
            .level = level,
            .category = category,
            .message = undefined,
            .message_len = 0,
            .recommendation = undefined,
            .recommendation_len = 0,
        };

        const msg_len = @min(message.len, g.message.len);
        @memcpy(g.message[0..msg_len], message[0..msg_len]);
        g.message_len = msg_len;

        if (recommendation) |rec| {
            const rec_len = @min(rec.len, g.recommendation.len);
            @memcpy(g.recommendation[0..rec_len], rec[0..rec_len]);
            g.recommendation_len = rec_len;
        }

        try self.guidance.append(g);
    }

    /// Add a guidance entry with formatted message
    fn addGuidanceFmt(
        self: *Self,
        level: GuidanceLevel,
        category: GuidanceCategory,
        comptime msg_fmt: []const u8,
        msg_args: anytype,
        recommendation: []const u8,
    ) !void {
        var g = Guidance{
            .level = level,
            .category = category,
            .message = undefined,
            .message_len = 0,
            .recommendation = undefined,
            .recommendation_len = 0,
        };

        const msg_result = std.fmt.bufPrint(&g.message, msg_fmt, msg_args) catch {
            g.message_len = g.message.len;
            return try self.guidance.append(g);
        };
        g.message_len = msg_result.len;

        const rec_len = @min(recommendation.len, g.recommendation.len);
        @memcpy(g.recommendation[0..rec_len], recommendation[0..rec_len]);
        g.recommendation_len = rec_len;

        try self.guidance.append(g);
    }

    /// Format all guidance for display
    pub fn format(self: *const Self, writer: anytype) !void {
        if (self.guidance.items.len == 0) {
            try writer.print("No guidance to offer.\n", .{});
            return;
        }

        try writer.print("\nOperator Guidance\n", .{});
        try writer.print("=================\n\n", .{});

        // Group by level
        var danger_count: usize = 0;
        var warning_count: usize = 0;
        var tip_count: usize = 0;

        for (self.guidance.items) |*g| {
            switch (g.level) {
                .danger => danger_count += 1,
                .warning => warning_count += 1,
                .tip => tip_count += 1,
            }
        }

        if (danger_count > 0) {
            try writer.print("Critical Issues ({d}):\n", .{danger_count});
            for (self.guidance.items) |*g| {
                if (g.level == .danger) {
                    try g.format(writer);
                }
            }
            try writer.print("\n", .{});
        }

        if (warning_count > 0) {
            try writer.print("Warnings ({d}):\n", .{warning_count});
            for (self.guidance.items) |*g| {
                if (g.level == .warning) {
                    try g.format(writer);
                }
            }
            try writer.print("\n", .{});
        }

        if (tip_count > 0) {
            try writer.print("Tips ({d}):\n", .{tip_count});
            for (self.guidance.items) |*g| {
                if (g.level == .tip) {
                    try g.format(writer);
                }
            }
        }
    }
};

/// Convenience function to analyze and return guidance
pub fn analyzeConfiguration(
    commands: []const parser.Command,
    live: *const state_types.NetworkState,
    allocator: std.mem.Allocator,
) ![]const Guidance {
    var engine = OperatorGuidance.init(allocator);
    defer engine.deinit();

    const results = try engine.analyzeConfig(commands, live);

    // Copy results to return (since engine will be deinitialized)
    var output = try allocator.alloc(Guidance, results.len);
    for (results, 0..) |g, i| {
        output[i] = g;
    }

    return output;
}

// Tests

test "OperatorGuidance init" {
    const allocator = std.testing.allocator;
    var og = OperatorGuidance.init(allocator);
    defer og.deinit();

    try std.testing.expect(og.guidance.items.len == 0);
}

test "addGuidance" {
    const allocator = std.testing.allocator;
    var og = OperatorGuidance.init(allocator);
    defer og.deinit();

    try og.addGuidance(
        .warning,
        .connectivity,
        "Test message",
        "Test recommendation",
    );

    try std.testing.expect(og.guidance.items.len == 1);
    try std.testing.expectEqualStrings("Test message", og.guidance.items[0].getMessage());
}
