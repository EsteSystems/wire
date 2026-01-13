# wire

A low-level, declarative, continuously-supervised network configuration tool for Linux.

## Overview

**wire** combines the direct kernel access of iproute2 with the desired-state model of infrastructure-as-code tools, wrapped in a natural language CLI. It's designed for enterprise environments: servers, routers, and network appliances.

### Key Features

- **Direct netlink operation** - No command wrapping, no dependencies on iproute2
- **Unified syntax** - CLI commands = configuration file format
- **Continuous supervision** - Daemon mode detects and corrects drift
- **Network analysis** - Built-in `analyze` command for troubleshooting
- **Native diagnostics** - Packet capture, ping, traceroute, service probing without external tools

## Quick Start

### Building

```bash
# Build for local testing
zig build

# Cross-compile for Linux (from FreeBSD/macOS)
zig build -Dtarget=x86_64-linux-gnu
```

### Basic Usage

#### Interface Management

```bash
wire interface                          # List all interfaces
wire interface eth0 show                # Show interface details
wire interface eth0 set state up        # Bring interface up
wire interface eth0 set state down      # Bring interface down
wire interface eth0 set mtu 9000        # Set MTU
wire interface eth0 address 10.0.0.1/24 # Add IP address
wire interface eth0 address del 10.0.0.1/24
wire interface eth0 stats               # Show RX/TX statistics
```

#### Routing

```bash
wire route                              # Show routing table
wire route add 192.168.0.0/16 via 10.0.0.254
wire route add 10.10.0.0/24 dev eth1
wire route add default via 10.0.0.1
wire route del 192.168.0.0/16
```

#### Bonds, Bridges, VLANs

```bash
wire bond bond0 create mode 802.3ad
wire bond bond0 add eth0 eth1
wire bridge br0 create
wire bridge br0 add eth2
wire bridge br0 fdb                     # Show forwarding database
wire vlan 100 on eth0                   # Create eth0.100
```

#### Veth Pairs (Container Networking)

```bash
wire veth veth0 peer veth1              # Create veth pair
wire veth veth0 show                    # Show peer info
wire veth veth0 delete                  # Delete pair
```

#### Network Namespaces

```bash
wire netns                              # List namespaces
wire netns add isolated                 # Create namespace
wire netns set veth1 isolated           # Move interface to namespace
wire netns exec isolated ip addr        # Execute command in namespace
wire netns exec isolated wire interface # Run wire in namespace
wire netns del isolated                 # Delete namespace
```

#### IP Policy Routing (Rules)

```bash
wire rule                               # Show all rules
wire rule add from 10.0.0.0/24 table 100 prio 1000
wire rule add to 192.168.0.0/16 table 200
wire rule add fwmark 1 table 100
wire rule del 1000                      # Delete by priority
```

#### Traffic Control (QoS)

```bash
wire tc eth0                            # Show qdiscs
wire tc eth0 add fq_codel               # Fair queuing with CoDel
wire tc eth0 add tbf rate 100mbit burst 32k
wire tc eth0 add pfifo limit 1000
wire tc eth0 del                        # Remove qdisc
```

#### Hardware Tuning (ethtool)

```bash
wire hw eth0 show                       # Driver info, ring, coalesce
wire hw eth0 ring                       # Ring buffer parameters
wire hw eth0 ring set rx 4096 tx 4096   # Set ring sizes
wire hw eth0 coalesce                   # Interrupt coalescing
wire hw eth0 coalesce set rx 100 tx 100 # Set coalesce (usecs)
```

#### Tunnels (VXLAN, GRE)

```bash
wire tunnel vxlan vx0 vni 100 local 10.0.0.1
wire tunnel vxlan vx0 vni 100 local 10.0.0.1 group 239.1.1.1
wire tunnel gre gre1 local 10.0.0.1 remote 10.0.0.2
wire tunnel gre gre1 local 10.0.0.1 remote 10.0.0.2 key 12345
wire tunnel gretap gretap1 local 10.0.0.1 remote 10.0.0.2
wire tunnel delete vx0                  # Delete tunnel
```

#### Diagnostics & Troubleshooting

```bash
# Neighbor table (ARP/NDP)
wire neighbor                           # Show all entries
wire neighbor show eth0                 # Filter by interface
wire neighbor lookup 10.0.0.1           # Lookup specific IP
wire neighbor arp                       # IPv4 only

# Network topology
wire topology                           # Show interface hierarchy
wire trace eth0 to 10.0.0.1             # Trace path to destination

# Service probing (TCP connectivity)
wire probe 10.0.0.1 22                  # Test port 22
wire probe 10.0.0.1 ssh                 # Test by service name
wire probe 10.0.0.1 scan                # Scan common ports
wire probe service mysql                # Lookup port number

# Native packet capture
wire diagnose capture eth0              # Capture on interface
wire diagnose capture eth0 --count 10   # Capture 10 packets

# Native ping/traceroute
wire diagnose ping 10.0.0.1
wire diagnose trace 10.0.0.1

# Analysis
wire analyze                            # Full network analysis
```

#### Validation

```bash
wire validate config network.wire       # Validate configuration file
wire validate vlan 100 on eth0          # Validate VLAN setup
wire validate path eth0 to 10.0.0.1     # Validate network path
wire validate service 10.0.0.1 ssh      # Validate service connectivity
```

#### Continuous Monitoring

```bash
wire watch 10.0.0.1 22                  # Watch service (default 1s interval)
wire watch 10.0.0.1 ssh --interval 500  # Custom interval (ms)
wire watch 10.0.0.1 80 --alert 100      # Alert if latency > 100ms
wire watch interface eth0               # Watch interface status
```

#### Configuration Management

```bash
wire apply config.wire                  # Apply configuration
wire apply config.wire --dry-run        # Validate only
wire diff config.wire                   # Compare to live state
wire state                              # Export current state
```

### Example Output

```
$ wire interface
1: lo: <UP,CARRIER> mtu 65536
2: eth0: <UP,CARRIER> mtu 1500
    link/ether 00:1a:2b:3c:4d:5e
    inet 10.0.0.5/24 scope global

$ wire neighbor
Neighbor Table
IP Address         MAC Address          State        Interface
10.0.0.1           02:2b:c4:d0:ee:af    REACHABLE    eth0

$ wire interface eth0 stats
eth0 statistics:
  RX: 3467702 packets, 379.77 MB
  TX: 6671410 packets, 2.78 GB

$ wire probe 10.0.0.1 scan
Scanning 10.0.0.1 (common ports, timeout 3000ms)...

10.0.0.1:22/tcp OPEN (205us)
10.0.0.1:80/tcp CLOSED (connection refused)
10.0.0.1:443/tcp CLOSED (connection refused)
10.0.0.1:3306/tcp CLOSED (connection refused)
10.0.0.1:5432/tcp CLOSED (connection refused)
10.0.0.1:6379/tcp CLOSED (connection refused)

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

$ wire validate path eth0 to 10.0.0.1
Validating path from eth0 to 10.0.0.1...

[PASS] Source interface exists: eth0
[PASS] Source is UP: Interface is up
[PASS] Source has carrier: Link detected
[PASS] Build topology: Topology graph built
[PASS] Path source ready: Source interface operational
[PASS] Destination reachable: TCP connection successful

Validation PASSED

$ wire watch 10.0.0.1 22 --alert 50
Watching 10.0.0.1:22 (interval=1000ms, timeout=3000ms)
Alert threshold: 50ms
Press Ctrl+C to stop

[0.001] . 432us
[1.003] . 587us
[2.008] . 1.2ms ALERT: High latency
[3.012] . 445us
^C
```

## Target Environments

- Linux servers
- Routers and network appliances
- Enterprise network infrastructure
- Container hosts and orchestration nodes

## Out of Scope

- Desktop/laptop networking (WiFi, Bluetooth, NetworkManager)
- GUI/TUI interfaces
- Dynamic addressing (DHCP client)
- Firewall rules (use nftables/iptables directly)

## Roadmap

- **v0.1** - Basic interface, address, route management ✓
- **v0.2** - Configuration files, bonds, bridges, VLANs ✓
- **v0.3** - Daemon mode with drift detection ✓
- **v0.4** - Validation, hints, and analysis ✓
- **v0.5** - Diagnostics and topology-aware troubleshooting ✓
- **v0.6** - Advanced networking (namespaces, rules, tc, tunnels, ethtool) ✓
- **v1.0** - Production ready

## Requirements

- Linux kernel 3.10+ (netlink support)
- CAP_NET_ADMIN capability for network configuration
- No external dependencies (pure Zig, statically linked)

## License

BSD
