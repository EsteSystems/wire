const std = @import("std");

/// Token types for wire's natural language syntax
pub const TokenType = enum {
    // Subjects
    INTERFACE,
    ROUTE,
    BOND,
    BRIDGE,
    VLAN,
    VETH,
    NAMESPACE,
    NEIGHBOR,
    TC,
    TUNNEL,

    // Verbs
    SHOW,
    SET,
    ADD,
    DEL,
    CREATE,
    DELETE,
    ANALYZE,
    TRACE,
    VALIDATE,
    DIAGNOSE,

    // Attributes
    ADDRESS,
    MTU,
    STATE,
    MASTER,
    MODE,
    MEMBERS,
    VIA,
    DEV,
    METRIC,

    // State values
    UP,
    DOWN,

    // Literals
    IDENTIFIER, // Interface names, etc.
    IP_ADDRESS, // 10.0.0.1 or 10.0.0.1/24
    NUMBER, // Numeric values
    STRING, // Quoted strings

    // Structure
    PIPE, // |
    COMMENT, // # comment
    NEWLINE,
    INDENT, // Indentation at start of line (for block format)
    EOF,

    // Keywords
    ON,
    TO,
    FROM,
    WITH,
    AFTER,
    CHECKPOINT,
    DEFAULT,
    PEER,
    ID,
};

/// A token from the lexer
pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

/// Lexer for wire's command syntax
pub const Lexer = struct {
    source: []const u8,
    current: usize,
    start: usize,
    line: usize,
    column: usize,
    line_start: usize,
    at_line_start: bool, // Track if we're at the start of a line (for indent detection)

    const Self = @This();

    /// Keywords mapping
    const keywords = std.StaticStringMap(TokenType).initComptime(.{
        // Subjects
        .{ "interface", .INTERFACE },
        .{ "route", .ROUTE },
        .{ "bond", .BOND },
        .{ "bridge", .BRIDGE },
        .{ "vlan", .VLAN },
        .{ "veth", .VETH },
        .{ "namespace", .NAMESPACE },
        .{ "neighbor", .NEIGHBOR },
        .{ "tc", .TC },
        .{ "tunnel", .TUNNEL },

        // Verbs
        .{ "show", .SHOW },
        .{ "set", .SET },
        .{ "add", .ADD },
        .{ "del", .DEL },
        .{ "create", .CREATE },
        .{ "delete", .DELETE },
        .{ "analyze", .ANALYZE },
        .{ "trace", .TRACE },
        .{ "validate", .VALIDATE },
        .{ "diagnose", .DIAGNOSE },

        // Attributes
        .{ "address", .ADDRESS },
        .{ "mtu", .MTU },
        .{ "state", .STATE },
        .{ "master", .MASTER },
        .{ "mode", .MODE },
        .{ "members", .MEMBERS },
        .{ "via", .VIA },
        .{ "dev", .DEV },
        .{ "metric", .METRIC },

        // State values
        .{ "up", .UP },
        .{ "down", .DOWN },

        // Keywords
        .{ "on", .ON },
        .{ "to", .TO },
        .{ "from", .FROM },
        .{ "with", .WITH },
        .{ "after", .AFTER },
        .{ "checkpoint", .CHECKPOINT },
        .{ "default", .DEFAULT },
        .{ "peer", .PEER },
        .{ "id", .ID },
    });

    pub fn init(source: []const u8) Self {
        return Self{
            .source = source,
            .current = 0,
            .start = 0,
            .line = 1,
            .column = 1,
            .line_start = 0,
            .at_line_start = true,
        };
    }

    /// Get the next token
    pub fn nextToken(self: *Self) Token {
        // Check for indentation at start of line (for block format support)
        if (self.at_line_start and !self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ' or c == '\t') {
                // Consume all leading whitespace
                self.start = self.current;
                while (!self.isAtEnd()) {
                    const ws = self.peek();
                    if (ws == ' ' or ws == '\t') {
                        _ = self.advance();
                    } else {
                        break;
                    }
                }
                self.at_line_start = false;
                return self.makeToken(.INDENT);
            }
            self.at_line_start = false;
        }

        self.skipWhitespace();
        self.start = self.current;

        if (self.isAtEnd()) {
            return self.makeToken(.EOF);
        }

        const c = self.advance();

        // Comments
        if (c == '#') {
            return self.comment();
        }

        // Pipe
        if (c == '|') {
            return self.makeToken(.PIPE);
        }

        // Newline
        if (c == '\n') {
            const token = self.makeToken(.NEWLINE);
            self.line += 1;
            self.line_start = self.current;
            self.column = 1;
            self.at_line_start = true; // Next token check for indent
            return token;
        }

        // Quoted string
        if (c == '"' or c == '\'') {
            return self.string(c);
        }

        // Numbers and IP addresses
        if (isDigit(c)) {
            return self.numberOrIp();
        }

        // Identifiers and keywords
        if (isAlpha(c) or c == '_') {
            return self.identifier();
        }

        // IP addresses can start with digit, handled above
        // Handle CIDR notation attached to identifiers (e.g., eth0.100)
        if (c == '.') {
            return self.identifier(); // Part of interface name like eth0.100
        }

        // Unknown character - treat as identifier
        return self.identifier();
    }

    /// Tokenize entire input
    pub fn tokenize(self: *Self, allocator: std.mem.Allocator) ![]Token {
        var tokens = std.array_list.Managed(Token).init(allocator);
        errdefer tokens.deinit();

        while (true) {
            const token = self.nextToken();
            try tokens.append(token);
            if (token.type == .EOF) break;
        }

        return tokens.toOwnedSlice();
    }

    // Private helper methods

    fn advance(self: *Self) u8 {
        const c = self.source[self.current];
        self.current += 1;
        self.column += 1;
        return c;
    }

    fn peek(self: *Self) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *Self) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn isAtEnd(self: *Self) bool {
        return self.current >= self.source.len;
    }

    fn skipWhitespace(self: *Self) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', '\r' => {
                    _ = self.advance();
                },
                else => return,
            }
        }
    }

    fn makeToken(self: *Self, token_type: TokenType) Token {
        return Token{
            .type = token_type,
            .lexeme = self.source[self.start..self.current],
            .line = self.line,
            .column = self.column - (self.current - self.start),
        };
    }

    fn comment(self: *Self) Token {
        // Consume until end of line
        while (!self.isAtEnd() and self.peek() != '\n') {
            _ = self.advance();
        }
        return self.makeToken(.COMMENT);
    }

    fn string(self: *Self, quote: u8) Token {
        while (!self.isAtEnd() and self.peek() != quote and self.peek() != '\n') {
            _ = self.advance();
        }

        if (self.isAtEnd() or self.peek() == '\n') {
            // Unterminated string - return what we have
            return self.makeToken(.STRING);
        }

        // Closing quote
        _ = self.advance();
        return self.makeToken(.STRING);
    }

    fn numberOrIp(self: *Self) Token {
        var has_dot = false;
        var has_slash = false;
        var has_colon = false;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isDigit(c)) {
                _ = self.advance();
            } else if (c == '.') {
                has_dot = true;
                _ = self.advance();
            } else if (c == '/') {
                has_slash = true;
                _ = self.advance();
            } else if (c == ':') {
                has_colon = true;
                _ = self.advance();
            } else if (isHexDigit(c) and has_colon) {
                // IPv6 address
                _ = self.advance();
            } else {
                break;
            }
        }

        // Determine if it's an IP address or just a number
        if (has_dot or has_slash or has_colon) {
            return self.makeToken(.IP_ADDRESS);
        }
        return self.makeToken(.NUMBER);
    }

    fn identifier(self: *Self) Token {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isAlphaNumeric(c) or c == '_' or c == '-' or c == '.' or c == ':') {
                _ = self.advance();
            } else {
                break;
            }
        }

        const text = self.source[self.start..self.current];

        // Check if it's a keyword
        if (keywords.get(text)) |token_type| {
            return self.makeToken(token_type);
        }

        // Check if it looks like an IP address
        if (looksLikeIp(text)) {
            return self.makeToken(.IP_ADDRESS);
        }

        return self.makeToken(.IDENTIFIER);
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAlphaNumeric(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

fn looksLikeIp(text: []const u8) bool {
    var dot_count: usize = 0;
    var colon_count: usize = 0;
    var slash_found = false;

    for (text) |c| {
        if (c == '.') dot_count += 1;
        if (c == ':') colon_count += 1;
        if (c == '/') slash_found = true;
    }

    // IPv4: has 3 dots, possibly a slash
    if (dot_count == 3) return true;

    // IPv6: has colons
    if (colon_count >= 2) return true;

    // CIDR: has slash with digits after
    if (slash_found and dot_count > 0) return true;

    return false;
}

// Tests
test "lexer basic tokens" {
    var lexer = Lexer.init("interface eth0 show");

    const t1 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.INTERFACE, t1.type);

    const t2 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.IDENTIFIER, t2.type);
    try std.testing.expectEqualStrings("eth0", t2.lexeme);

    const t3 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.SHOW, t3.type);
}

test "lexer ip address" {
    var lexer = Lexer.init("10.0.0.1/24");

    const t1 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.IP_ADDRESS, t1.type);
    try std.testing.expectEqualStrings("10.0.0.1/24", t1.lexeme);
}

test "lexer route command" {
    var lexer = Lexer.init("route add default via 10.0.0.254");

    try std.testing.expectEqual(TokenType.ROUTE, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.ADD, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.DEFAULT, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.VIA, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.IP_ADDRESS, lexer.nextToken().type);
}

test "lexer comment" {
    var lexer = Lexer.init("interface eth0 # this is a comment\nroute show");

    try std.testing.expectEqual(TokenType.INTERFACE, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.IDENTIFIER, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.COMMENT, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.NEWLINE, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.ROUTE, lexer.nextToken().type);
}

test "lexer pipe" {
    var lexer = Lexer.init("interface eth0 show | grep up");

    try std.testing.expectEqual(TokenType.INTERFACE, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.IDENTIFIER, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.SHOW, lexer.nextToken().type);
    try std.testing.expectEqual(TokenType.PIPE, lexer.nextToken().type);
}

test "lexer interface with dot" {
    var lexer = Lexer.init("interface bond0.100 show");

    try std.testing.expectEqual(TokenType.INTERFACE, lexer.nextToken().type);
    const t2 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.IDENTIFIER, t2.type);
    try std.testing.expectEqualStrings("bond0.100", t2.lexeme);
}
