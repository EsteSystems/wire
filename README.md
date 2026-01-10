# wire

A low-level, declarative, continuously-supervised network configuration tool for Linux.

## Overview

**wire** combines the direct kernel access of iproute2 with the desired-state model of infrastructure-as-code tools, wrapped in a natural language CLI. It's designed for enterprise environments: servers, routers, and network appliances.

### Key Features

- **Direct netlink operation** - No command wrapping, no dependencies on iproute2
- **Unified syntax** - CLI commands = configuration file format
- **Continuous supervision** - Daemon mode detects and corrects drift (coming soon)
- **Network analysis** - Built-in `analyze` command for troubleshooting

## Quick Start

### Building

```bash
# Build for local testing
zig build

# Cross-compile for Linux (from FreeBSD/macOS)
zig build -Dtarget=x86_64-linux-gnu
```

### Basic Usage

```bash
# List all interfaces
wire interface

# Show specific interface details
wire interface eth0 show

# Bring interface up/down
wire interface eth0 set state up
wire interface eth0 set state down

# Set MTU
wire interface eth0 set mtu 9000

# Add IP address
wire interface eth0 address 10.0.0.1/24

# Delete IP address
wire interface eth0 address del 10.0.0.1/24

# Show routing table
wire route

# Add route via gateway
wire route add 192.168.0.0/16 via 10.0.0.254

# Add route via interface
wire route add 10.10.0.0/24 dev eth1

# Add default route
wire route add default via 10.0.0.1

# Delete route
wire route del 192.168.0.0/16

# Network analysis
wire analyze
```

### Example Output

```
$ wire interface
1: lo: <UP,CARRIER> mtu 65536
2: eth0: <UP,CARRIER> mtu 1500
    link/ether 00:1a:2b:3c:4d:5e
    inet 10.0.0.5/24 scope global

$ wire analyze

Network Analysis Report
=======================

Interfaces (2 total)
--------------------
[ok] lo: up, loopback
[ok] eth0: up, carrier, 10.0.0.5/24

Routing
-------
[ok] default via 10.0.0.1
```

## Target Environments

- Linux servers
- Routers and network appliances
- Enterprise network infrastructure

## Out of Scope

- Desktop/laptop networking (WiFi, Bluetooth, NetworkManager)
- GUI/TUI interfaces
- Dynamic addressing (DHCP client)
- Firewall rules (use nftables/iptables directly)

## Roadmap

- **v0.1 (MVP)** - Basic interface, address, route management
- **v0.2** - Configuration files, bonds, bridges, VLANs
- **v0.3** - Daemon mode with drift detection
- **v0.4** - Validation, hints, and analysis
- **v0.5** - Diagnostics and third-party tool integration
- **v1.0** - Production ready

## Requirements

- Linux kernel 3.10+ (netlink support)
- CAP_NET_ADMIN capability for network configuration

## License

TBD
