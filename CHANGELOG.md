# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-01-15

### Added
- Man pages: wire(8) and wire.conf(5)
- Systemd service file for daemon mode
- JSON output support (`--json` / `-j` flag) for interface, route, neighbor, bond, tc, and rule commands
- Shell completions for bash, zsh, and fish
- RPM spec file for RHEL/Rocky/Fedora packaging
- Debian packaging files
- Makefile for easy installation
- LICENSE file (BSD 3-Clause)

### Changed
- Binary installation path changed to /usr/local/sbin (was /usr/local/bin)

## [0.6.0] - 2026-01-14

### Added
- Network namespace management (`wire netns`)
  - Create, delete, list namespaces
  - Execute commands in namespaces
  - Move interfaces between namespaces
- IP policy routing rules (`wire rule`)
  - Source/destination based routing
  - Firewall mark (fwmark) rules
  - Multiple routing tables
- Traffic control / QoS (`wire tc`)
  - Qdisc management (fq_codel, tbf, htb, pfifo)
  - Class and filter support
- Hardware tuning (`wire hw`)
  - Ring buffer configuration
  - Interrupt coalescing settings
  - Driver information via ethtool/genetlink
- Advanced tunnel types
  - GENEVE tunnels
  - IP-in-IP tunnels
  - SIT tunnels (IPv6 over IPv4)
  - WireGuard interface creation

## [0.5.0] - 2026-01-13

### Added
- Network topology visualization (`wire topology`)
- Path tracing (`wire trace <interface> to <destination>`)
- Native neighbor table (ARP/NDP) queries (`wire neighbor`)
- Interface statistics (`wire interface <name> stats`)
- Veth pair management (`wire veth`)
  - Create veth pairs
  - Move endpoints to namespaces
  - Show peer information
- TCP service probing (`wire probe`)
  - Test connectivity to host:port
  - Service name resolution via /etc/services
  - Port scanning (common ports)
- Validation commands (`wire validate`)
  - Configuration file validation
  - VLAN validation
  - Path validation
  - Service connectivity validation
- Continuous monitoring (`wire watch`)
  - Watch service connectivity
  - Watch interface status
  - Latency alert thresholds
- Native packet capture (`wire diagnose capture`)

## [0.4.0] - 2026-01-12

### Added
- Pre-apply validation system
  - Gateway reachability checks
  - Interface existence validation
  - Address conflict detection
  - Route conflict detection
- Confirmation system with flags
  - `--yes` for auto-confirm
  - `--force` to skip errors
  - `--strict` to fail on warnings
  - `--dry-run` for validation only
  - `--staging` for relaxed validation
- Operator guidance system
  - Context-aware hints
  - Missing configuration warnings
  - Performance recommendations
- Network analysis (`wire analyze`)
  - Interface health analysis
  - Routing analysis
  - Connectivity checks
- Snapshot management (`wire history snapshot`)
- State export (`wire state export`)
  - Export live state as configuration
  - Selective export options

## [0.3.0] - 2026-01-11

### Added
- Daemon mode with continuous supervision
  - `wire daemon start/stop/status/reload`
  - PID file management
  - Signal handling (SIGHUP, SIGTERM)
- Netlink event monitoring
  - Real-time network change detection
  - Event-driven reconciliation
- State management
  - Live state queries via netlink
  - Desired state from configuration
  - State diffing and drift detection
- Reconciliation engine
  - Automatic drift correction
  - Configurable reconciliation interval
- CLI-daemon IPC via Unix socket
- Configuration file watching

## [0.2.0] - 2026-01-10

### Added
- Configuration file support
  - Same syntax as CLI commands
  - Comment support (#)
  - `/etc/wire/conf.d/*.conf` includes
- Bond interface management (`wire bond`)
  - All 7 bond modes supported
  - LACP parameters (lacp_rate, xmit_hash_policy)
  - Member add/remove
- Bridge interface management (`wire bridge`)
  - Bridge creation with STP option
  - Port management
  - Forwarding database display (`wire bridge <name> fdb`)
- VLAN interface management (`wire vlan`)
  - 802.1Q VLAN creation
  - Custom interface naming
- Dependency resolution
  - Automatic ordering based on object types
  - Circular dependency detection
  - Topological sort for apply order

## [0.1.0] - 2026-01-09

### Added
- Initial release
- Direct netlink interface (no iproute2 dependency)
- Interface management
  - List, show, state control
  - MTU and MAC address configuration
  - IP address add/remove
- Routing table management
  - Route listing
  - Add routes via gateway or device
  - Default route support
  - Route deletion
- Natural language CLI syntax
- Cross-compilation support (x86_64-linux-gnu)
- Basic error handling with actionable messages
- `--help` and `--version` flags
