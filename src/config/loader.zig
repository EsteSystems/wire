const std = @import("std");
const parser = @import("../syntax/parser.zig");
const semantic = @import("../syntax/semantic.zig");
const executor = @import("../syntax/executor.zig");
const resolver = @import("resolver.zig");
const pre_apply = @import("../validation/pre_apply.zig");
const confirmation = @import("../ui/confirmation.zig");
const guidance = @import("../validation/guidance.zig");
const state_live = @import("../state/live.zig");

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
pub fn applyConfig(path: []const u8, allocator: std.mem.Allocator, options: ApplyOptions) !ApplyResult {
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

    if (options.dry_run) {
        // Semantic validation
        try stdout.print("\nValidating syntax...\n", .{});
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

        try stdout.print("Syntax validation: {d} valid, {d} errors\n", .{ valid_count, error_count });

        // Pre-apply validation (check against live state)
        try stdout.print("\nValidating against live state...\n", .{});
        var pre_report = pre_apply.validateBeforeApply(loaded.commands, allocator) catch |err| {
            try stdout.print("Pre-apply validation failed: {s}\n", .{@errorName(err)});
            return ApplyResult{
                .success = false,
                .applied = 0,
                .failed = error_count + 1,
                .skipped = valid_count,
                .message = "Pre-apply validation failed",
            };
        };
        defer pre_report.deinit();

        try pre_report.format(stdout);

        try stdout.print("\nValidation Summary\n", .{});
        try stdout.print("------------------\n", .{});
        try stdout.print("Commands: {d}, Syntax errors: {d}\n", .{ loaded.commands.len, error_count });
        try stdout.print("Pre-apply: {d} error(s), {d} warning(s)\n", .{ pre_report.errors, pre_report.warnings });

        const total_errors = error_count + pre_report.errors;
        return ApplyResult{
            .success = total_errors == 0,
            .applied = 0,
            .failed = total_errors,
            .skipped = valid_count,
            .message = if (total_errors == 0) "Validation passed" else "Validation failed",
        };
    }

    // Pre-apply validation (check against live state)
    try stdout.print("Validating against live state... ", .{});
    var pre_report = pre_apply.validateBeforeApply(loaded.commands, allocator) catch |err| {
        try stdout.print("FAILED ({s})\n", .{@errorName(err)});
        return ApplyResult{
            .success = false,
            .applied = 0,
            .failed = 1,
            .skipped = 0,
            .message = "Pre-apply validation failed",
        };
    };
    defer pre_report.deinit();

    if (pre_report.hasErrors()) {
        try stdout.print("FAILED\n\n", .{});
        try pre_report.format(stdout);
        return ApplyResult{
            .success = false,
            .applied = 0,
            .failed = pre_report.errors,
            .skipped = 0,
            .message = "Pre-apply validation found errors",
        };
    }

    if (pre_report.hasWarnings()) {
        try stdout.print("OK ({d} warnings)\n", .{pre_report.warnings});
        try pre_report.format(stdout);
    } else {
        try stdout.print("OK\n", .{});
    }

    // Generate operator guidance
    try stdout.print("Analyzing configuration... ", .{});
    var live_state = state_live.queryLiveState(allocator) catch {
        try stdout.print("SKIPPED (could not query live state)\n", .{});
        // Continue without guidance
        var guidance_engine = guidance.OperatorGuidance.init(allocator);
        defer guidance_engine.deinit();

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

        // Show command preview
        var confirm_sys = confirmation.ConfirmationSystem.init(allocator, options.skip_confirmation);
        try confirm_sys.showCommandPreview(loaded.commands);

        // Prompt for confirmation
        if (!options.skip_confirmation) {
            const prompt = if (pre_report.hasWarnings())
                "Apply configuration with warnings?"
            else
                "Apply this configuration?";

            const confirmed = confirm_sys.promptConfirmation(prompt) catch false;
            if (!confirmed) {
                try stdout.print("\nAborted by user.\n", .{});
                return ApplyResult{
                    .success = false,
                    .applied = 0,
                    .failed = 0,
                    .skipped = loaded.commands.len,
                    .message = "Aborted by user",
                };
            }
        }

        // Apply commands
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
    };
    defer live_state.deinit();

    var guidance_engine = guidance.OperatorGuidance.init(allocator);
    defer guidance_engine.deinit();

    const guidance_items = guidance_engine.analyzeConfig(loaded.commands, &live_state) catch &[_]guidance.Guidance{};
    if (guidance_items.len > 0) {
        try stdout.print("OK ({d} items)\n", .{guidance_items.len});
        try guidance_engine.format(stdout);
    } else {
        try stdout.print("OK\n", .{});
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

    // Show command preview
    var confirm_sys = confirmation.ConfirmationSystem.init(allocator, options.skip_confirmation);
    try confirm_sys.showCommandPreview(loaded.commands);

    // Prompt for confirmation
    if (!options.skip_confirmation) {
        const prompt = if (pre_report.hasWarnings())
            "Apply configuration with warnings?"
        else
            "Apply this configuration?";

        const confirmed = confirm_sys.promptConfirmation(prompt) catch false;
        if (!confirmed) {
            try stdout.print("\nAborted by user.\n", .{});
            return ApplyResult{
                .success = false,
                .applied = 0,
                .failed = 0,
                .skipped = loaded.commands.len,
                .message = "Aborted by user",
            };
        }
    }

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

/// Options for applying configuration
pub const ApplyOptions = struct {
    dry_run: bool = false,
    skip_confirmation: bool = false,
    force: bool = false,
    verbose: bool = false,
};

// Tests

test "config loader init" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();

    try std.testing.expectEqualStrings("/etc/wire", loader.base_path);
}
