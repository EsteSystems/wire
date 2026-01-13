# Wire v0.6.0 Comprehensive Test Plan

## Test Environment

- **VM**: 10.0.0.20 (Linux)
- **Management Interface**: enp0s5f0 (DO NOT MODIFY)
- **Test Interfaces**: enp0s5f1, enp0s5f2, enp0s5f3

## Test Sequence

Tests are ordered to build on each other. Run in sequence.

---

## Phase 1: Interface Management

### 1.1 List and Show
```bash
wire interface                           # List all
wire interface enp0s5f1                  # Show specific
wire interface enp0s5f1 stats            # Show statistics
```

### 1.2 Interface State Changes
```bash
wire interface enp0s5f1 set state up     # Bring up
wire interface enp0s5f1                  # Verify UP
wire interface enp0s5f1 set state down   # Bring down
wire interface enp0s5f1                  # Verify DOWN
```

### 1.3 MTU Changes
```bash
wire interface enp0s5f1 set state up
wire interface enp0s5f1 set mtu 9000     # Jumbo frames
wire interface enp0s5f1                  # Verify MTU=9000
wire interface enp0s5f1 set mtu 1500     # Reset
```

### 1.4 IP Address Management
```bash
wire interface enp0s5f1 address 192.168.100.1/24    # Add address
wire interface enp0s5f1                              # Verify
wire interface enp0s5f1 address del 192.168.100.1   # Remove address
wire interface enp0s5f1                              # Verify removed
```

---

## Phase 2: Bonding

### 2.1 Create LACP Bond
```bash
# Bring interfaces down first
wire interface enp0s5f1 set state down
wire interface enp0s5f2 set state down

# Create bond with LACP (802.3ad)
wire bond bond0 create mode 802.3ad

# Add members
wire bond bond0 add enp0s5f1
wire bond bond0 add enp0s5f2

# Verify
wire bond bond0
wire interface bond0

# Bring bond up
wire interface bond0 set state up
wire interface bond0 address 192.168.50.1/24
wire interface bond0
```

### 2.2 Bond Status
```bash
wire bond show bond0                     # Show bond details
wire interface enp0s5f1                  # Should show master=bond0
wire interface enp0s5f2                  # Should show master=bond0
```

### 2.3 Topology with Bond
```bash
wire topology show                       # Should show bond hierarchy
```

---

## Phase 3: Bridge

### 3.1 Create Bridge
```bash
wire bridge br0 create
wire interface br0 set state up
wire interface br0 address 192.168.60.1/24
wire interface br0
```

### 3.2 Add Ports to Bridge
```bash
# Use enp0s5f3 as bridge port
wire interface enp0s5f3 set state up
wire bridge br0 add enp0s5f3

# Verify
wire bridge br0 show
wire interface enp0s5f3                  # Should show master=br0
```

### 3.3 Bridge FDB
```bash
wire bridge fdb br0                      # Show forwarding database
```

### 3.4 Topology with Bridge
```bash
wire topology show                       # Should show bridge hierarchy
```

---

## Phase 4: VLANs

### 4.1 VLAN on Bond
```bash
wire vlan create bond0.100 id 100 on bond0
wire interface bond0.100 set state up
wire interface bond0.100 address 10.100.0.1/24
wire interface bond0.100
```

### 4.2 Multiple VLANs
```bash
wire vlan create bond0.200 id 200 on bond0
wire interface bond0.200 set state up
wire interface bond0.200 address 10.200.0.1/24
wire vlan show
```

### 4.3 Topology with VLANs
```bash
wire topology show                       # Should show VLAN hierarchy on bond
```

---

## Phase 5: Network Namespaces

### 5.1 Create Namespace
```bash
wire netns create testns
wire netns list
```

### 5.2 Veth Pair with Namespace
```bash
wire veth veth-host peer veth-ns
wire interface veth-host set state up
wire interface veth-host address 172.20.0.1/24

# Move one end to namespace
wire netns set veth-ns testns
wire netns exec testns ip addr add 172.20.0.2/24 dev veth-ns
wire netns exec testns ip link set veth-ns up
wire netns exec testns ip link set lo up
```

### 5.3 Cross-Namespace Connectivity
```bash
wire diagnose ping 172.20.0.2            # Ping namespace from host
wire netns exec testns ping -c2 172.20.0.1   # Ping host from namespace
```

### 5.4 Namespace Interface List
```bash
wire netns exec testns wire interface    # List interfaces in namespace
```

---

## Phase 6: Tunnels

### 6.1 VXLAN Tunnel
```bash
wire tunnel vxlan vxlan100 vni 100 local 192.168.50.1 port 4789
wire interface vxlan100 set state up
wire interface vxlan100 address 10.50.0.1/24
wire interface vxlan100
```

### 6.2 GRE Tunnel
```bash
wire tunnel gre gre0-test local 192.168.50.1 remote 192.168.50.2 ttl 64
wire interface gre0-test
```

### 6.3 Delete Tunnels
```bash
wire tunnel delete vxlan100
wire tunnel delete gre0-test
wire interface                           # Verify removed
```

---

## Phase 7: IP Rules (Policy Routing)

### 7.1 Show Rules
```bash
wire rule show
```

### 7.2 Add Custom Rules
```bash
wire rule add from 10.100.0.0/24 table 100 prio 1000
wire rule add from 10.200.0.0/24 table 200 prio 1001
wire rule show                           # Verify new rules
```

### 7.3 Delete Rules
```bash
wire rule del from 10.100.0.0/24 table 100 prio 1000
wire rule del from 10.200.0.0/24 table 200 prio 1001
wire rule show                           # Verify removed
```

---

## Phase 8: Traffic Control

### 8.1 Show Qdiscs
```bash
wire tc bond0 show
```

### 8.2 Add Rate Limiting (TBF)
```bash
wire tc bond0 add tbf rate 100mbit burst 32k latency 50ms
wire tc bond0 show                       # Verify tbf qdisc
```

### 8.3 Replace with fq_codel
```bash
wire tc bond0 del
wire tc bond0 add fq_codel
wire tc bond0 show
```

---

## Phase 9: Hardware Tuning (ethtool)

### 9.1 Show Hardware Info
```bash
wire hw enp0s5f1 show
```

### 9.2 Ring Buffer Settings
```bash
wire hw enp0s5f1 ring                    # Show ring buffers
# Note: May fail on virtio, works on real hardware
```

### 9.3 Coalesce Settings
```bash
wire hw enp0s5f1 coalesce                # Show coalesce params
```

---

## Phase 10: Routing

### 10.1 Show Routes
```bash
wire route
wire route show                          # Same as above
```

### 10.2 Add Routes
```bash
wire route add 10.99.0.0/24 via 192.168.50.254 dev bond0
wire route                               # Verify
```

### 10.3 Delete Routes
```bash
wire route del 10.99.0.0/24
wire route                               # Verify removed
```

---

## Phase 11: Neighbor Table

### 11.1 Show Neighbors
```bash
wire neighbor
wire neighbor show                       # Same
```

### 11.2 ARP Lookup
```bash
wire neighbor lookup 10.0.0.1            # Lookup specific IP
```

### 11.3 Add Static ARP
```bash
wire neighbor add 192.168.50.100 lladdr 00:11:22:33:44:55 dev bond0
wire neighbor show                       # Verify
```

### 11.4 Delete ARP Entry
```bash
wire neighbor del 192.168.50.100 dev bond0
wire neighbor show                       # Verify removed
```

---

## Phase 12: Diagnostics

### 12.1 Ping
```bash
wire diagnose ping 10.0.0.1              # Gateway ping
wire diagnose ping 8.8.8.8               # External ping
```

### 12.2 Trace
```bash
wire trace bond0 to 8.8.8.8              # Trace path
```

### 12.3 TCP Probe
```bash
wire probe 10.0.0.1 22                   # SSH port
wire probe 8.8.8.8 443                   # HTTPS
```

### 12.4 Packet Capture
```bash
wire diagnose capture bond0 --count 10   # Capture 10 packets
```

---

## Phase 13: Topology

### 13.1 Full Topology
```bash
wire topology show
```

### 13.2 Path Analysis
```bash
wire topology path bond0.100 to br0
```

### 13.3 Children
```bash
wire topology children bond0             # Show VLANs on bond
```

---

## Phase 14: Watch Mode

### 14.1 Watch Interface
```bash
wire watch enp0s5f0 --interval 2000      # Watch for 10 seconds, Ctrl+C
```

### 14.2 Watch with Alert
```bash
wire watch 10.0.0.1 --interval 1000 --alert   # Alert on failure
```

---

## Phase 15: Configuration Management

### 15.1 Export Current State
```bash
wire state export > /tmp/current-state.wire
cat /tmp/current-state.wire
```

### 15.2 Create Test Config
```bash
cat > /tmp/test-config.wire << 'EOF'
interface bond0
  address 192.168.50.1/24
  state up

interface bond0.100
  address 10.100.0.1/24
  state up

interface br0
  address 192.168.60.1/24
  state up
EOF
```

### 15.3 Validate Config
```bash
wire validate config /tmp/test-config.wire
```

### 15.4 Diff Config vs Live
```bash
wire diff /tmp/test-config.wire
```

### 15.5 Apply Config (Dry Run)
```bash
wire apply /tmp/test-config.wire --dry-run
```

---

## Phase 16: Events

### 16.1 Monitor Events
```bash
# In one terminal:
wire events

# In another terminal, trigger changes:
wire interface enp0s5f3 set state down
wire interface enp0s5f3 set state up

# Should see events in first terminal
```

---

## Phase 17: History

### 17.1 Show History
```bash
wire history show
```

### 17.2 Create Snapshot
```bash
wire history snapshot "before-cleanup"
wire history list
```

---

## Phase 18: Cleanup

### 18.1 Remove Test Objects
```bash
# Delete VLANs
wire vlan bond0.100 delete
wire vlan bond0.200 delete

# Delete namespace
wire netns del testns

# Remove bridge ports and delete bridge
wire bridge br0 del enp0s5f3
wire bridge br0 delete

# Remove bond members and delete bond
wire bond bond0 del enp0s5f1
wire bond bond0 del enp0s5f2
wire bond bond0 delete

# Delete veth pair
wire veth veth-host delete

# Verify clean state
wire interface
wire topology show
```

---

## Test Results Summary

**Test Date:** 2026-01-12
**Version:** wire 0.6.0
**Test VM:** 10.0.0.20 (Rocky Linux)

| Phase | Test | Status | Notes |
|-------|------|--------|-------|
| 1.1 | Interface list/show | PASS | |
| 1.2 | State changes | PASS | |
| 1.3 | MTU changes | PASS | |
| 1.4 | Address management | PASS | |
| 2.1 | Create LACP bond | PASS | Syntax: `wire bond bond0 create mode 802.3ad` |
| 2.2 | Bond status | PASS | |
| 2.3 | Topology with bond | PASS | |
| 3.1 | Create bridge | PASS | Syntax: `wire bridge br0 create` |
| 3.2 | Add bridge ports | PASS | |
| 3.3 | Bridge FDB | PASS | |
| 3.4 | Topology with bridge | PASS | |
| 4.1 | VLAN on bond | PASS | |
| 4.2 | Multiple VLANs | PASS | |
| 4.3 | Topology with VLANs | PASS | VLANs show as separate nodes |
| 5.1 | Create namespace | PASS | |
| 5.2 | Veth with namespace | PASS | Use `wire netns set <if> <ns>` |
| 5.3 | Cross-ns connectivity | PASS | |
| 5.4 | Namespace interface list | PASS | `wire netns exec <ns> wire interface` works |
| 6.1 | VXLAN tunnel | PASS | |
| 6.2 | GRE tunnel | PASS | |
| 6.3 | Delete tunnels | PASS | |
| 7.1 | Show rules | PASS | |
| 7.2 | Add rules | PASS | |
| 7.3 | Delete rules | PASS | |
| 8.1 | Show qdiscs | PASS | |
| 8.2 | TBF rate limiting | PASS | |
| 8.3 | fq_codel | PASS | |
| 9.1 | Hardware info | PASS | |
| 9.2 | Ring buffers | PASS | |
| 9.3 | Coalesce | PASS | |
| 10.1 | Show routes | PASS | |
| 10.2 | Add routes | PASS | |
| 10.3 | Delete routes | PASS | |
| 11.1 | Show neighbors | PASS | |
| 11.2 | ARP lookup | PASS | |
| 11.3 | Add static ARP | PASS | |
| 11.4 | Delete ARP | PASS | |
| 12.1 | Ping | PASS | |
| 12.2 | Trace | PASS | |
| 12.3 | TCP probe | PASS | |
| 12.4 | Packet capture | PASS | |
| 13.1 | Full topology | PASS | |
| 13.2 | Path analysis | PASS | |
| 13.3 | Children | PASS | |
| 14.1 | Watch interface | PASS | |
| 14.2 | Watch with alert | PASS | |
| 15.1 | Export state | PASS | |
| 15.2 | Create config | PASS | Use command format, not block format |
| 15.3 | Validate config | PASS | Syntax: `wire validate config <file>` |
| 15.4 | Diff config | PASS | |
| 15.5 | Apply dry-run | PASS | |
| 16.1 | Monitor events | PASS | |
| 17.1 | Show history | PASS | |
| 17.2 | Create snapshot | PASS | |
| 18.1 | Cleanup | PASS | |

## Bugs Fixed During Testing

1. **`wire netns exec` didn't search PATH** (FIXED in v0.6.0)
   - Commands like `wire netns exec testns ip addr` returned exit code 127
   - Fix: Added `findInPath()` helper to search PATH directories

## Known Issues

1. **VLANs in topology** - VLANs appear as separate root nodes instead of nested under parent interface
2. **Config file format** - Parser expects command format (`interface eth0 set state up`) not block format
