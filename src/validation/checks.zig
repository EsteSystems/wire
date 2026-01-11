const std = @import("std");
const pre_apply = @import("pre_apply.zig");

const ValidationIssue = pre_apply.ValidationIssue;
const Severity = pre_apply.Severity;
const ValidationCode = pre_apply.ValidationCode;

/// Create a validation issue with formatted message
pub fn createIssue(
    severity: Severity,
    code: ValidationCode,
    comptime msg_fmt: []const u8,
    msg_args: anytype,
    suggestion: []const u8,
    command_index: usize,
) ValidationIssue {
    var issue = ValidationIssue{
        .severity = severity,
        .code = code,
        .message = undefined,
        .message_len = 0,
        .suggestion = undefined,
        .suggestion_len = 0,
        .command_index = command_index,
    };

    // Format message
    const msg_result = std.fmt.bufPrint(&issue.message, msg_fmt, msg_args) catch |err| {
        switch (err) {
            error.NoSpaceLeft => {
                // Message too long, truncate
                issue.message_len = issue.message.len;
                return issue;
            },
        }
    };
    issue.message_len = msg_result.len;

    // Copy suggestion
    if (suggestion.len > 0) {
        const sug_len = @min(suggestion.len, issue.suggestion.len);
        @memcpy(issue.suggestion[0..sug_len], suggestion[0..sug_len]);
        issue.suggestion_len = sug_len;
    }

    return issue;
}

/// Create a simple issue without formatting
pub fn createSimpleIssue(
    severity: Severity,
    code: ValidationCode,
    message: []const u8,
    suggestion: ?[]const u8,
    command_index: ?usize,
) ValidationIssue {
    var issue = ValidationIssue{
        .severity = severity,
        .code = code,
        .message = undefined,
        .message_len = 0,
        .suggestion = undefined,
        .suggestion_len = 0,
        .command_index = command_index,
    };

    // Copy message
    const msg_len = @min(message.len, issue.message.len);
    @memcpy(issue.message[0..msg_len], message[0..msg_len]);
    issue.message_len = msg_len;

    // Copy suggestion
    if (suggestion) |sug| {
        const sug_len = @min(sug.len, issue.suggestion.len);
        @memcpy(issue.suggestion[0..sug_len], sug[0..sug_len]);
        issue.suggestion_len = sug_len;
    }

    return issue;
}

/// Validation check: Interface exists
pub fn checkInterfaceExists(
    name: []const u8,
    exists: bool,
    command_index: usize,
) ?ValidationIssue {
    if (!exists) {
        return createIssue(
            .err,
            .interface_not_found,
            "Interface '{s}' does not exist",
            .{name},
            "Ensure the interface exists or will be created",
            command_index,
        );
    }
    return null;
}

/// Validation check: Gateway is reachable
pub fn checkGatewayReachable(
    gateway: []const u8,
    reachable: bool,
    command_index: usize,
) ?ValidationIssue {
    if (!reachable) {
        return createIssue(
            .warning,
            .gateway_unreachable,
            "Gateway '{s}' may not be reachable",
            .{gateway},
            "Ensure an interface has an address in the same subnet",
            command_index,
        );
    }
    return null;
}

/// Validation check: Address conflict
pub fn checkAddressConflict(
    address: []const u8,
    existing_interface: ?[]const u8,
    command_index: usize,
) ?ValidationIssue {
    if (existing_interface) |iface| {
        return createIssue(
            .err,
            .address_conflict,
            "Address '{s}' already exists on interface '{s}'",
            .{ address, iface },
            "Choose a different address or remove the existing one first",
            command_index,
        );
    }
    return null;
}

/// Validation check: Route conflict
pub fn checkRouteConflict(
    destination: []const u8,
    has_conflict: bool,
    command_index: usize,
) ?ValidationIssue {
    if (has_conflict) {
        return createIssue(
            .warning,
            .route_conflict,
            "A route for '{s}' already exists",
            .{destination},
            "The existing route may be replaced",
            command_index,
        );
    }
    return null;
}

/// Validation check: Dangerous operation - removing default route
pub fn checkRemovingDefaultRoute(command_index: usize) ValidationIssue {
    return createSimpleIssue(
        .warning,
        .removing_default_route,
        "Removing default route may cause loss of external connectivity",
        "Ensure you have alternative access",
        command_index,
    );
}

/// Validation check: Dangerous operation - removing only address
pub fn checkRemovingOnlyAddress(interface: []const u8, command_index: usize) ValidationIssue {
    return createIssue(
        .warning,
        .removing_only_address,
        "Removing the only address from '{s}' may cause connectivity loss",
        .{interface},
        "Ensure you have alternative access",
        command_index,
    );
}

/// Validation check: Dangerous operation - bringing down management interface
pub fn checkBringingDownManagement(interface: []const u8, command_index: usize) ValidationIssue {
    return createIssue(
        .warning,
        .bringing_down_management_interface,
        "Bringing down '{s}' may cause loss of connectivity",
        .{interface},
        "Ensure you have console or out-of-band access",
        command_index,
    );
}

/// Validation check: Dependency missing
pub fn checkDependencyMissing(
    resource_type: []const u8,
    name: []const u8,
    command_index: usize,
) ValidationIssue {
    return createIssue(
        .err,
        .dependency_missing,
        "{s} '{s}' does not exist",
        .{ resource_type, name },
        "Create it before this command",
        command_index,
    );
}

/// Get a human-readable description for a validation code
pub fn getCodeDescription(code: ValidationCode) []const u8 {
    return switch (code) {
        .interface_not_found => "The specified interface was not found in the system",
        .interface_already_exists => "An interface with this name already exists",
        .interface_is_loopback => "Cannot perform this operation on loopback interface",
        .gateway_unreachable => "The gateway IP is not reachable from any configured interface",
        .gateway_not_in_subnet => "The gateway is not in the same subnet as any interface",
        .no_route_to_gateway => "No route exists to reach the gateway",
        .address_conflict => "This IP address is already assigned to another interface",
        .address_already_assigned => "This address is already assigned to this interface",
        .address_on_down_interface => "Adding address to an interface that is down",
        .route_conflict => "A route with this destination already exists",
        .route_duplicate => "This exact route already exists",
        .route_unreachable_gateway => "The route's gateway is not reachable",
        .dependency_missing => "A required resource does not exist",
        .parent_interface_missing => "The parent interface for this VLAN does not exist",
        .bond_member_missing => "The interface to add to the bond does not exist",
        .bridge_port_missing => "The interface to add to the bridge does not exist",
        .removing_default_route => "Removing the default route may cause connectivity loss",
        .removing_only_address => "Removing the only IP address may cause connectivity loss",
        .bringing_down_management_interface => "Bringing down this interface may cause connectivity loss",
        .unknown_error => "An unknown validation error occurred",
    };
}

// Tests

test "createIssue" {
    const issue = createIssue(
        .err,
        .interface_not_found,
        "Interface '{s}' not found",
        .{"eth0"},
        "Check interface name",
        0,
    );

    try std.testing.expectEqual(Severity.err, issue.severity);
    try std.testing.expectEqual(ValidationCode.interface_not_found, issue.code);
    try std.testing.expectEqualStrings("Interface 'eth0' not found", issue.getMessage());
    try std.testing.expectEqualStrings("Check interface name", issue.getSuggestion().?);
}

test "createSimpleIssue" {
    const issue = createSimpleIssue(
        .warning,
        .gateway_unreachable,
        "Gateway unreachable",
        "Add an address in the gateway's subnet",
        5,
    );

    try std.testing.expectEqual(Severity.warning, issue.severity);
    try std.testing.expectEqualStrings("Gateway unreachable", issue.getMessage());
}
