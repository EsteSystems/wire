//! Wire Grammar Definition
//!
//! This module formally defines the wire command grammar. The grammar follows
//! a natural language pattern with Subject-Verb-Object structure.
//!
//! Grammar (EBNF-like notation):
//!
//! ```
//! command     = subject [ action ] { attribute } [ comment ] ;
//!
//! subject     = interface_subject
//!             | route_subject
//!             | bond_subject
//!             | bridge_subject
//!             | vlan_subject
//!             | "analyze" ;
//!
//! interface_subject = "interface" [ IDENTIFIER ] ;
//! route_subject     = "route" [ destination ] ;
//! bond_subject      = "bond" [ IDENTIFIER ] ;
//! bridge_subject    = "bridge" [ IDENTIFIER ] ;
//! vlan_subject      = "vlan" [ NUMBER ] [ "on" IDENTIFIER ] ;
//!
//! destination = IP_ADDRESS | "default" ;
//!
//! action      = "show"
//!             | "set" IDENTIFIER value
//!             | "add" [ value ]
//!             | "del" [ value ]
//!             | "create"
//!             | "delete"
//!             | "address" [ "del" ] [ IP_ADDRESS ] ;
//!
//! attribute   = "via" IP_ADDRESS
//!             | "dev" IDENTIFIER
//!             | "metric" NUMBER
//!             | "mode" IDENTIFIER
//!             | "members" { IDENTIFIER }
//!             | "on" IDENTIFIER
//!             | "state" ( "up" | "down" )
//!             | "mtu" NUMBER ;
//!
//! value       = IDENTIFIER | IP_ADDRESS | NUMBER | STRING ;
//!
//! comment     = "#" { any character except newline } ;
//!
//! IDENTIFIER  = letter { letter | digit | "_" | "-" | "." | ":" } ;
//! IP_ADDRESS  = ipv4_address [ "/" prefix ] | ipv6_address [ "/" prefix ] ;
//! NUMBER      = digit { digit } ;
//! STRING      = '"' { any character except '"' } '"'
//!             | "'" { any character except "'" } "'" ;
//!
//! ipv4_address = octet "." octet "." octet "." octet ;
//! octet        = digit [ digit [ digit ] ] ;
//! prefix       = digit [ digit [ digit ] ] ;
//! ```
//!
//! Example commands:
//!
//! ```
//! # Interface commands
//! interface                           # List all interfaces
//! interface eth0 show                 # Show specific interface
//! interface eth0 set state up         # Bring interface up
//! interface eth0 set state down       # Bring interface down
//! interface eth0 set mtu 9000         # Set MTU
//! interface eth0 address 10.0.0.1/24  # Add address
//! interface eth0 address del 10.0.0.1/24  # Delete address
//!
//! # Route commands
//! route                               # List routes
//! route show                          # List routes (explicit)
//! route add default via 10.0.0.254    # Add default route
//! route add 192.168.0.0/16 via 10.0.0.1  # Add network route
//! route del default                   # Delete default route
//! route del 192.168.0.0/16            # Delete network route
//!
//! # Bond commands (future)
//! bond bond0 create mode 802.3ad members eth0 eth1
//! bond bond0 add eth2
//! bond bond0 del eth1
//! bond bond0 show
//!
//! # Bridge commands (future)
//! bridge br0 create
//! bridge br0 add eth1 eth2
//! bridge br0 del eth1
//! bridge br0 show
//!
//! # VLAN commands (future)
//! vlan 100 on eth0
//! vlan 100 on eth0 delete
//!
//! # Analysis
//! analyze
//! ```
//!
//! Configuration file format:
//!
//! Configuration files use the exact same syntax as CLI commands.
//! One command per line, with # for comments.
//!
//! ```
//! # /etc/wire/network.conf
//!
//! # Primary interface
//! interface eth0 address 10.0.0.1/24
//! interface eth0 set state up
//!
//! # Default gateway
//! route add default via 10.0.0.254
//!
//! # Internal network
//! route add 192.168.0.0/16 via 10.0.1.1
//! ```

const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

/// Grammar rules enumeration (for documentation/validation)
pub const GrammarRule = enum {
    Command,
    Subject,
    InterfaceSubject,
    RouteSubject,
    BondSubject,
    BridgeSubject,
    VlanSubject,
    Action,
    ShowAction,
    SetAction,
    AddAction,
    DelAction,
    CreateAction,
    DeleteAction,
    AddressAction,
    Attribute,
    ViaAttribute,
    DevAttribute,
    MetricAttribute,
    ModeAttribute,
    MembersAttribute,
    StateAttribute,
    MtuAttribute,
    Comment,
};

/// Check if a token type can start a subject
pub fn canStartSubject(token_type: lexer.TokenType) bool {
    return switch (token_type) {
        .INTERFACE, .ROUTE, .BOND, .BRIDGE, .VLAN, .ANALYZE => true,
        else => false,
    };
}

/// Check if a token type can start an action
pub fn canStartAction(token_type: lexer.TokenType) bool {
    return switch (token_type) {
        .SHOW, .SET, .ADD, .DEL, .CREATE, .DELETE, .ADDRESS => true,
        else => false,
    };
}

/// Check if a token type is an attribute keyword
pub fn isAttributeKeyword(token_type: lexer.TokenType) bool {
    return switch (token_type) {
        .VIA, .DEV, .METRIC, .MODE, .MEMBERS, .ON, .STATE, .MTU => true,
        else => false,
    };
}

/// Check if a token type is a value type
pub fn isValueType(token_type: lexer.TokenType) bool {
    return switch (token_type) {
        .IDENTIFIER, .IP_ADDRESS, .NUMBER, .STRING, .DEFAULT, .UP, .DOWN => true,
        else => false,
    };
}

/// Grammar documentation for help output
pub const HelpText = struct {
    pub const interface_help =
        \\Interface Commands:
        \\  interface                           List all interfaces
        \\  interface <name> show               Show interface details
        \\  interface <name> set state up       Bring interface up
        \\  interface <name> set state down     Bring interface down
        \\  interface <name> set mtu <value>    Set MTU
        \\  interface <name> address <ip/pfx>   Add IP address
        \\  interface <name> address del <ip>   Delete IP address
        \\
    ;

    pub const route_help =
        \\Route Commands:
        \\  route                               Show routing table
        \\  route show                          Show routing table
        \\  route add <dst> via <gw>            Add route via gateway
        \\  route add default via <gw>          Add default route
        \\  route del <dst>                     Delete route
        \\  route del default                   Delete default route
        \\
    ;

    pub const bond_help =
        \\Bond Commands (future):
        \\  bond                                List all bonds
        \\  bond <name> create mode <mode>      Create bond
        \\  bond <name> add <member>            Add member to bond
        \\  bond <name> del <member>            Remove member from bond
        \\  bond <name> show                    Show bond details
        \\
    ;

    pub const bridge_help =
        \\Bridge Commands (future):
        \\  bridge                              List all bridges
        \\  bridge <name> create                Create bridge
        \\  bridge <name> add <port>            Add port to bridge
        \\  bridge <name> del <port>            Remove port from bridge
        \\  bridge <name> show                  Show bridge details
        \\
    ;

    pub const vlan_help =
        \\VLAN Commands (future):
        \\  vlan <id> on <parent>               Create VLAN interface
        \\  vlan <id> on <parent> delete        Delete VLAN interface
        \\
    ;

    pub const analyze_help =
        \\Analysis Commands:
        \\  analyze                             Full network analysis
        \\
    ;

    pub const full_help =
        \\wire - Network configuration tool for Linux
        \\
        \\Usage: wire <command> [options]
        \\
    ++ interface_help ++ route_help ++ analyze_help ++
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version information
        \\
    ;
};

// Tests

test "canStartSubject" {
    try std.testing.expect(canStartSubject(.INTERFACE));
    try std.testing.expect(canStartSubject(.ROUTE));
    try std.testing.expect(!canStartSubject(.SHOW));
    try std.testing.expect(!canStartSubject(.IDENTIFIER));
}

test "canStartAction" {
    try std.testing.expect(canStartAction(.SHOW));
    try std.testing.expect(canStartAction(.SET));
    try std.testing.expect(canStartAction(.ADD));
    try std.testing.expect(!canStartAction(.INTERFACE));
}

test "isAttributeKeyword" {
    try std.testing.expect(isAttributeKeyword(.VIA));
    try std.testing.expect(isAttributeKeyword(.MTU));
    try std.testing.expect(!isAttributeKeyword(.SHOW));
}
