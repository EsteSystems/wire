# Wire — Development Guide

## Project Overview

Wire is a Zig-based network fabric controller targeting enterprise Linux. It manages network interfaces (bonds, bridges, VLANs, veth pairs, tunnels), routes, addresses, and namespaces via direct netlink syscalls — no NetworkManager, no libc dependency.

**Target**: Replace NetworkManager on Syneto appliances with a deterministic, self-healing network controller.

## Build / Test / Deploy

```bash
# Build for Linux (cross-compiles from macOS)
zig build                     # or: make
zig build -Doptimize=ReleaseSafe

# Check compilation without running
zig build check

# Run unit tests (pure logic, runs on macOS)
zig build test                # or: make test

# Run Linux-specific tests (requires Linux VM)
zig build test-linux

# Format code
zig fmt src/

# Deploy to test VM
make deploy                   # scp to root@10.0.0.20
TESTVM=root@<ip> make deploy  # custom target
```

## Repository Layout

```
wire/
├── src/
│   ├── main.zig                 # CLI entry point, command dispatch
│   ├── netlink/                 # Direct netlink operations (core)
│   │   ├── socket.zig           # Netlink socket, message builder, attribute parser, constants
│   │   ├── interface.zig        # Interface CRUD, IFLA_LINKINFO parsing
│   │   ├── bond.zig             # Bond lifecycle (create, modify, delete, list)
│   │   ├── bridge.zig           # Bridge lifecycle, FDB, VLAN filtering
│   │   ├── vlan.zig             # 802.1Q VLAN interfaces
│   │   ├── veth.zig             # Veth pair lifecycle, namespace moves
│   │   ├── address.zig          # IP address management
│   │   ├── route.zig            # Routing table management, ECMP
│   │   ├── neighbor.zig         # ARP/NDP neighbor table
│   │   ├── rule.zig             # Policy routing rules
│   │   ├── namespace.zig        # Network namespace lifecycle
│   │   ├── tunnel.zig           # GRE/IPIP/VXLAN tunnels
│   │   ├── ethtool.zig          # Ethtool via generic netlink
│   │   ├── events.zig           # Netlink event monitoring
│   │   ├── qdisc.zig            # Traffic control (tc) qdiscs
│   │   └── stats.zig            # Interface statistics
│   ├── syntax/                  # Config file lexer/parser/executor
│   ├── config/                  # Config loading and resolution
│   ├── state/                   # Desired vs live state management
│   ├── daemon/                  # Daemon (reconciler, supervisor, watcher, IPC)
│   ├── analysis/                # Topology analysis, health checks
│   ├── diagnostics/             # Ping, traceroute, validation
│   ├── plugins/                 # Native and adapter plugins
│   ├── output/                  # JSON output formatting
│   ├── ui/                      # Confirmation prompts
│   ├── history/                 # Changelog, snapshots
│   └── validation/              # Pre-apply checks, guidance
├── tests/
│   └── integration.zig          # Integration test harness (Linux only)
├── docs/
│   └── DEVELOPMENT_PLAN.md      # Full milestone plan (M0-M12)
├── build.zig                    # Build configuration
├── Makefile                     # Convenience targets
├── packaging/                   # Debian/RPM packaging
├── systemd/                     # Service files
├── completions/                 # Shell completions (bash/zsh/fish)
├── man/                         # Man pages
└── examples/                    # Example configurations
```

## Code Conventions

### Netlink Message Building Pattern

All netlink operations follow the same pattern:

```zig
var nl = try socket.NetlinkSocket.open();
defer nl.close();

var buf: [512]u8 = undefined;
var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

const hdr = try builder.addHeader(socket.RTM.NEWLINK, flags);
try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{ ... });
try builder.addAttrString(socket.IFLA.IFNAME, name);

// Nested attributes
const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);
try builder.addAttrString(socket.IFLA_INFO.KIND, "bond");
builder.endNestedAttr(linkinfo_start);

const msg = builder.finalize(hdr);
const response = try nl.request(msg, allocator);
allocator.free(response);
```

### Allocator Patterns

- Functions that return owned slices take `allocator: std.mem.Allocator` as first param
- Internal-only allocations use a local `GeneralPurposeAllocator`
- Caller frees returned slices: `defer allocator.free(result)`
- Use `errdefer` for cleanup on error paths

### Error Handling

- Use specific error types: `error.InterfaceNotFound`, `error.InterfaceAlreadyEnslaved`
- Parse netlink errno responses (EEXIST, ENODEV, EBUSY) into meaningful errors
- Never silently swallow errors

### Naming

- Zig standard: `camelCase` for functions and variables, `PascalCase` for types
- Netlink constants mirror kernel naming: `IFLA_BOND.MODE`, `RTM.NEWLINK`
- Interface name buffers: `[16]u8` (IFNAMSIZ) with separate `name_len`

### Buffer Sizes

- Simple messages (delete, set state): `[256]u8`
- Messages with nested attrs (create with options): `[512]u8`
- Messages with many nested attrs (ECMP, VLAN filtering): `[1024]u8`
- Receive buffer: 32768 bytes (in NetlinkSocket)

## Development Rules

1. **No task is "done" unless fully implemented.** Stub functions, TODO comments, or empty bodies do not count as complete. If a function claims to do something, it must actually do it.

2. **Complete implementations only.** Every function must handle success paths, error paths, and edge cases. No "happy path only" code.

3. **Test what you build.** Every new function needs at least one unit test for pure logic, and integration test coverage for netlink operations.

4. **Post-operation verification.** After creating or modifying a network object, read it back and confirm it matches expectations.

5. **Solid design patterns.** Follow existing codebase patterns. Use the MessageBuilder for all netlink messages. Use AttrParser for all response parsing.

6. **Professional quality.** Code must compile cleanly (`zig build check`), pass all tests (`zig build test`), and handle real-world conditions (interfaces that don't exist, operations that fail, concurrent modifications).

7. **No libc.** Wire uses direct Linux syscalls via `std.os.linux`. Do not introduce libc dependencies.

8. **Cross-compile awareness.** Build targets Linux x86_64. Unit tests run on native (macOS dev machine). Netlink tests run on Linux only.
