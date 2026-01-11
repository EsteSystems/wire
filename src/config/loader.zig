const std = @import("std");
const parser = @import("../syntax/parser.zig");
const semantic = @import("../syntax/semantic.zig");
const executor = @import("../syntax/executor.zig");
const resolver = @import("resolver.zig");

/// Configuration loading errors
pub const ConfigError = error{
    FileNotFound,
    ReadError,
    ParseError,
    ValidationError,
    OutOfMemory,
    CircularDependency,
};

/// Result of loading a configuration
pub const ConfigResult = struct {
    commands: []parser.Command,
    source_file: []const u8,
    source_content: []const u8, // Keep source alive for string references
    errors: []const ConfigLoadError,

    pub fn deinit(self: *ConfigResult, allocator: std.mem.Allocator) void {
        for (self.commands) |*cmd| {
            var c = cmd.*;
            c.deinit(allocator);
        }
        allocator.free(self.commands);
        allocator.free(self.source_content);
        allocator.free(self.errors);
    }
};

pub const ConfigLoadError = struct {
    line: usize,
    message: []const u8,
    file: []const u8,
};

/// Configuration loader
pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    errors: std.ArrayList(ConfigLoadError),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .base_path = "/etc/wire",
            .errors = std.ArrayList(ConfigLoadError).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.errors.deinit();
    }

    /// Loaded config with source content kept alive
    pub const LoadedConfig = struct {
        commands: []parser.Command,
        source: []const u8,

        pub fn deinit(self: *LoadedConfig, allocator: std.mem.Allocator) void {
            for (self.commands) |*cmd| {
                var c = cmd.*;
                c.deinit(allocator);
            }
            allocator.free(self.commands);
            allocator.free(self.source);
        }
    };

    /// Load configuration from a file
    pub fn loadFile(self: *Self, path: []const u8) ConfigError!LoadedConfig {
        const file = std.fs.cwd().openFile(path, .{}) catch {
            return ConfigError.FileNotFound;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch {
            return ConfigError.ReadError;
        };
        errdefer self.allocator.free(content);

        const commands = self.parseContent(content, path) catch {
            return ConfigError.ParseError;
        };

        return LoadedConfig{
            .commands = commands,
            .source = content,
        };
    }

    /// Load configuration from the default location
    /// Note: For multi-file loading, caller should use loadFile directly
    pub fn loadDefault(self: *Self) ConfigError!LoadedConfig {
        const main_config = std.fmt.allocPrint(self.allocator, "{s}/network.conf", .{self.base_path}) catch {
            return ConfigError.OutOfMemory;
        };
        defer self.allocator.free(main_config);

        return self.loadFile(main_config);
    }

    /// Parse configuration content
    fn parseContent(self: *Self, content: []const u8, source: []const u8) ConfigError![]parser.Command {
        _ = source;
        const commands = parser.parseConfig(content, self.allocator) catch {
            return ConfigError.ParseError;
        };
        return commands;
    }
};

/// Validate configuration without applying
pub fn validateConfig(path: []const u8, allocator: std.mem.Allocator) !ValidationReport {
    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();

    var loaded = loader.loadFile(path) catch |err| {
        return ValidationReport{
            .valid = false,
            .total_commands = 0,
            .valid_commands = 0,
            .warnings = 0,
            .errors = 1,
            .error_messages = &[_][]const u8{@errorName(err)},
        };
    };
    defer loaded.deinit(allocator);

    var valid_count: usize = 0;
    const warning_count: usize = 0;
    var error_count: usize = 0;
    var error_messages = std.ArrayList([]const u8).init(allocator);
    defer error_messages.deinit();

    for (loaded.commands) |*cmd| {
        var result = semantic.validateCommand(cmd, allocator) catch {
            error_count += 1;
            continue;
        };
        defer result.deinit(allocator);

        if (result.valid) {
            valid_count += 1;
        } else {
            error_count += 1;
            for (result.errors) |err| {
                try error_messages.append(err.message);
            }
        }
    }

    return ValidationReport{
        .valid = error_count == 0,
        .total_commands = loaded.commands.len,
        .valid_commands = valid_count,
        .warnings = warning_count,
        .errors = error_count,
        .error_messages = try error_messages.toOwnedSlice(),
    };
}

pub const ValidationReport = struct {
    valid: bool,
    total_commands: usize,
    valid_commands: usize,
    warnings: usize,
    errors: usize,
    error_messages: []const []const u8,

    pub fn deinit(self: *ValidationReport, allocator: std.mem.Allocator) void {
        allocator.free(self.error_messages);
    }
};

/// Apply configuration from a file
pub fn applyConfig(path: []const u8, allocator: std.mem.Allocator, dry_run: bool) !ApplyResult {
    const stdout = std.io.getStdOut().writer();

    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();

    // Parse configuration
    try stdout.print("Parsing configuration... ", .{});
    var loaded = loader.loadFile(path) catch |err| {
        try stdout.print("FAILED\n", .{});
        return ApplyResult{
            .success = false,
            .applied = 0,
            .failed = 0,
            .skipped = 0,
            .message = @errorName(err),
        };
    };
    defer loaded.deinit(allocator);
    try stdout.print("OK ({d} commands)\n", .{loaded.commands.len});

    if (dry_run) {
        // Validation only
        try stdout.print("\nValidating configuration...\n", .{});
        var valid_count: usize = 0;
        var error_count: usize = 0;

        for (loaded.commands, 0..) |*cmd, i| {
            var result = semantic.validateCommand(cmd, allocator) catch {
                try stdout.print("  Command {d}: FAILED (validation error)\n", .{i + 1});
                error_count += 1;
                continue;
            };
            defer result.deinit(allocator);

            if (result.valid) {
                valid_count += 1;
            } else {
                error_count += 1;
                for (result.errors) |err| {
                    try stdout.print("  Command {d}: {s}\n", .{ i + 1, err.message });
                }
            }
        }

        try stdout.print("\nValidation Results\n", .{});
        try stdout.print("------------------\n", .{});
        try stdout.print("Total: {d}, Valid: {d}, Errors: {d}\n", .{ loaded.commands.len, valid_count, error_count });

        return ApplyResult{
            .success = error_count == 0,
            .applied = 0,
            .failed = error_count,
            .skipped = valid_count,
            .message = if (error_count == 0) "Validation passed" else "Validation failed",
        };
    }

    // Resolve dependencies to get correct execution order
    try stdout.print("Resolving dependencies... ", .{});
    const ordered_commands = resolver.resolveCommands(loaded.commands, allocator) catch |err| {
        try stdout.print("FAILED ({s})\n", .{@errorName(err)});
        return ApplyResult{
            .success = false,
            .applied = 0,
            .failed = 0,
            .skipped = 0,
            .message = "Dependency resolution failed",
        };
    };
    defer allocator.free(ordered_commands);
    try stdout.print("OK\n", .{});

    // Apply commands in resolved order
    try stdout.print("\nApplying configuration...\n", .{});
    var exec = executor.Executor.init(allocator);
    var applied: usize = 0;
    var failed: usize = 0;

    for (ordered_commands) |cmd| {
        exec.execute(cmd) catch {
            failed += 1;
            continue;
        };
        applied += 1;
    }

    try stdout.print("\nApply Results\n", .{});
    try stdout.print("-------------\n", .{});
    try stdout.print("Applied: {d}, Failed: {d}\n", .{ applied, failed });

    return ApplyResult{
        .success = failed == 0,
        .applied = applied,
        .failed = failed,
        .skipped = 0,
        .message = if (failed == 0) "Configuration applied successfully" else "Some commands failed",
    };
}

pub const ApplyResult = struct {
    success: bool,
    applied: usize,
    failed: usize,
    skipped: usize,
    message: []const u8,
};

// Tests

test "config loader init" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();

    try std.testing.expectEqualStrings("/etc/wire", loader.base_path);
}
