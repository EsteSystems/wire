# Wire — Development Plan

*Created: 2026-02-23*

---

## Overview

This plan covers the full path from wire's current prototype to a production-ready, clustering-capable network fabric controller. Organized into 12 milestones across 4 phases, with ~235 features and concrete tasks for each.

**Current state**: Wire has netlink scaffolding for bonds, bridges, VLANs, veth, routes, addresses, tunnels, namespaces. Daemon structure exists (reconciler, supervisor, watcher, IPC). Declarative config parser exists. Most implementations are partial — correct structure, incomplete bodies.

**Target state**: Production-ready network fabric replacing NetworkManager on enterprise Linux, with clustering and overlay networking.

---

## Phase Overview

| Phase | Milestones | Focus | Weeks |
|-------|-----------|-------|-------|
| **Phase A: Foundation** | M0-M3 | Solid single-node networking | 12-16 |
| **Phase B: Intelligence** | M4-M6 | Daemon, self-healing, declarative config | 10-14 |
| **Phase C: Fabric** | M7-M9 | Overlays, encryption, clustering | 14-20 |
| **Phase D: Enterprise** | M10-M12 | Service chaining, slicing, analytics, multi-site | 16-22 |
| **Total** | | | **52-72** |

---

## Phase A: Foundation — Single-Node Networking

The open-source core. Must be rock-solid before anything else. Every feature here is ported from nmctl's production-proven logic or built fresh on netlink.

---

### Milestone 0 — Netlink Completion & Test Infrastructure

**Goal**: Every netlink operation that wire claims to support actually works, verified by tests on real hardware.

**Duration**: 3-4 weeks

#### Tasks: Bond Netlink

| # | Task | Status | Notes |
|---|------|--------|-------|
| 0.1 | Fix `getBonds()` — parse IFLA_LINKINFO to identify bond interfaces | **DONE** | Filters on link_kind=="bond", parses IFLA_BOND_* from info_data |
| 0.2 | Implement `getBondByName()` with full attribute extraction (mode, members, active_slave, fail_over_mac) | **DONE** | Extracts mode, miimon, updelay, downdelay, xmit_hash, lacp_rate, ad_select, members |
| 0.3 | Complete `createBond()` — all 7 modes, miimon, fail_over_mac=active default | **DONE** | All 7 modes, all options via BondOptions struct |
| 0.4 | Implement `modifyBond()` — change mode, add/remove members on existing bond | **DONE** | RTM_NEWLINK without CREATE/EXCL flags |
| 0.5 | Add bond member carrier status via sysfs `/sys/class/net/<dev>/carrier` | TODO | |
| 0.6 | Validate bond creation pre-checks: interface exists, not already enslaved, mode valid | **DONE** | validateBondCreation() checks existence and master_index |
| 0.7 | Auto-naming: bond0..bond99 (skip existing) | **DONE** | nextBondName() scans interfaces |
| 0.8 | Unit tests: create, modify, delete, list, mode transitions | **DONE** | 14 tests: mode/lacp/xmit/adselect conversion, defaults, struct methods, roundtrip |
| 0.9 | Integration tests on real hardware: bond with 2 NICs, failover, carrier detection | **DONE** | tests/integration.zig: create, list, modify, member add/remove |

#### Tasks: Bridge Netlink

| # | Task | Status | Notes |
|---|------|--------|-------|
| 0.10 | Fix `getBridges()` — parse IFLA_LINKINFO to identify bridge interfaces | **DONE** | interface.zig stores info_data; bridge can filter by link_kind=="bridge" |
| 0.11 | Complete `createBridge()` — STP, priority, forward_delay, hello_time, mac_address | **DONE** | createBridge() + setBridgeStp() via IFLA_BR_STP_STATE |
| 0.12 | Implement bridge slave management: add/remove port via netlink | **DONE** | addBridgeMember/removeBridgeMember via IFLA_MASTER |
| 0.13 | Implement STP enable/disable per bridge via netlink IFLA_BR_STP_STATE | **DONE** | setBridgeStp() + verifyBridgeStp() |
| 0.14 | Implement FDB management: add/remove/list static entries | **DONE** | getBridgeFdb, getAllFdb, addFdbEntry, removeFdbEntry |
| 0.15 | Implement bridge VLAN filtering: per-port VLAN membership | **DONE** | setBridgeVlanFiltering, addBridgeVlanEntry via AF_BRIDGE + IFLA_AF_SPEC |
| 0.16 | Unit tests: create, delete, STP, FDB, VLAN filtering | **DONE** | BridgeFdbMsg size, FdbEntry formatMac, stateString tests |
| 0.17 | Integration tests: bridge with slaves, STP convergence, FDB learning | **DONE** | tests/integration.zig: create with STP, member management |

#### Tasks: VLAN Netlink

| # | Task | Status | Notes |
|---|------|--------|-------|
| 0.18 | Fix VLAN creation in reconciler (currently TODO — needs parent interface resolution) | TODO | Reconciler-level task, not netlink |
| 0.19 | Complete `createVlan()` — parent interface, VLAN ID 1-4094, MTU inheritance | **DONE** | createVlan + createVlanWithName, auto-names parent.vid |
| 0.20 | Implement VLAN listing with parent association | **DONE** | getVlans() filters on link_kind=="vlan", populates parent_index + vlan_id |
| 0.21 | Unit tests: create, delete, list, invalid VLAN IDs | **DONE** | Vlan struct getName, isUp tests + integration VLAN create/list |

#### Tasks: Veth Netlink

| # | Task | Status | Notes |
|---|------|--------|-------|
| 0.22 | Complete `createVethPair()` — verify both ends created, configurable names | **DONE** | Already implemented in veth.zig |
| 0.23 | Implement `setVethNetns()` — move veth end into network namespace | **DONE** | Already implemented (by FD and PID) |
| 0.24 | Implement veth peer detection (find the other end of a veth pair) | **DONE** | getInfo with link_index + link_netns_id parsing |
| 0.25 | Unit tests: create, delete, namespace move, peer detection | TODO | Target: 6+ tests |

#### Tasks: Address & Route Netlink

| # | Task | Status | Notes |
|---|------|--------|-------|
| 0.26 | Complete `addAddress()` — IPv4 + IPv6, prefix length, label | **DONE** | addAddress with family, addr_bytes, prefixlen |
| 0.27 | Complete `removeAddress()` — match by address + prefix | **DONE** | deleteAddress with family, addr_bytes, prefixlen |
| 0.28 | Complete `addRoute()` — destination, gateway, metric, table, device scope | **DONE** | addRoute with family, dst, dst_len, gateway, oif |
| 0.29 | Complete `removeRoute()` — match by destination + table | **DONE** | deleteRoute with family, dst, dst_len |
| 0.30 | Implement policy routing rules: source-based routing, multiple tables | **DONE** | rule.zig: getRules, addRule, deleteRule |
| 0.31 | Implement ECMP routes: multiple next-hops | **DONE** | addEcmpRoute with RTA_MULTIPATH and rtnexthop structs |
| 0.32 | Unit tests: address CRUD, route CRUD, policy rules, ECMP | **DONE** | Integration tests for route add/delete |

#### Tasks: Interface Netlink

| # | Task | Status | Notes |
|---|------|--------|-------|
| 0.33 | Complete interface up/down via netlink RTM_SETLINK | **DONE** | setInterfaceState with IFF_UP flag |
| 0.34 | Complete MTU configuration via netlink | **DONE** | setInterfaceMtu via IFLA_MTU |
| 0.35 | Implement hardware offload tuning via ethtool netlink (TSO, GSO, GRO, checksum) | **DONE** | ethtool.zig already implements getCoalesceParams/setCoalesceParams |
| 0.36 | Implement ring buffer tuning via ethtool netlink | **DONE** | ethtool.zig: getRingParams/setRingParams |
| 0.37 | Physical NIC enumeration via sysfs: speed, duplex, carrier, MAC | **DONE** | getPhysicalInterfaces() with sysfs reads for speed/duplex |
| 0.38 | Unit tests: interface state, MTU, offload settings | **DONE** | Integration test for interface list + physical NIC enumeration |

#### Tasks: Test Infrastructure

| # | Task | Status | Notes |
|---|------|--------|-------|
| 0.39 | Create test harness for netlink operations (setup/teardown veth pairs for safe testing) | **DONE** | tests/integration.zig with createTestVeth/cleanupTestVeth helpers |
| 0.40 | Create integration test runner script | **DONE** | `zig build test-integration` step in build.zig |
| 0.41 | CI pipeline: build, unit test, integration test on Linux VM | TODO | |
| 0.42 | Post-operation verification: after every netlink create, read back and confirm | **DONE** | verifyInterfaceExists, verifyBridgeStp |
| 0.43 | Error handling audit: replace all generic errors with specific netlink error codes | **DONE** | errno mapping: EEXIST, ENODEV, EBUSY, EPERM, EINVAL, ENOENT, etc. |
| 0.44 | Buffer overflow audit: validate all fixed-size buffers (512/256 byte) against max interface name lengths | **DONE** | Audited: 256 for simple, 512 for nested, 1024 for ECMP. All safe. ||

**Milestone 0 total**: 44 tasks | **Target test count**: 61+

---

### Milestone 1 — State Persistence & MAC Preservation

**Goal**: Wire tracks what it creates and preserves MAC addresses across reboots. Ported from nmctl's battle-tested state management.

**Duration**: 2-3 weeks

#### Tasks: State Manager

| # | Task | Status | Notes |
|---|------|--------|-------|
| 1.1 | Define state directory: `/var/lib/wire/` | TODO | |
| 1.2 | Implement atomic file writes (.tmp + rename pattern) | TODO | Port from nmctl state.rs |
| 1.3 | Implement `managed_resources.json`: track vswitches, bonds, VLANs, veth pairs with created_at | TODO | |
| 1.4 | Implement track/untrack/is_tracked operations | TODO | |
| 1.5 | Implement `bridge_topology.json`: bridge interconnections for veth restoration | TODO | |
| 1.6 | Implement `master_bridges.json`: list of master bridge devices | TODO | |
| 1.7 | Implement `control-file` sentinel for systemd coordination | TODO | |
| 1.8 | Unit tests: CRUD, atomic writes, concurrent access safety | TODO | Target: 15+ tests |

#### Tasks: MAC Preservation

| # | Task | Status | Notes |
|---|------|--------|-------|
| 1.9 | Implement per-bridge MAC storage: `{bridge}_original_mac` plain text files | TODO | Port from nmctl bridge_mac.rs |
| 1.10 | Implement DHCP-aware MAC priority: lease MAC > original > uplink > current | TODO | |
| 1.11 | Implement `network_identity.json` per bridge: original_mac, lease_mac, current_ip, dhcp_enabled | TODO | |
| 1.12 | Implement MAC restoration via netlink (non-destructive, bridge stays up) | TODO | Critical lesson from nmctl |
| 1.13 | Implement MAC save before VLAN activation (parent bridge MAC shift prevention) | TODO | |
| 1.14 | Unit tests: MAC priority logic, save/restore, DHCP-aware selection | TODO | Target: 10+ tests |

#### Tasks: FDB State

| # | Task | Status | Notes |
|---|------|--------|-------|
| 1.15 | Implement per-bridge FDB state persistence: `{bridge}_fdb.json` | TODO | |
| 1.16 | Implement FDB restore on boot (re-add static entries) | TODO | |
| 1.17 | Unit tests: FDB save/load/restore | TODO | Target: 4+ tests |

**Milestone 1 total**: 17 tasks | **Target test count**: 29+

---

### Milestone 2 — Hub-and-Spoke Topology Engine

**Goal**: Full bridge topology management — the core of Syneto's network architecture. Veth pair lifecycle, connect/disconnect/isolate, reboot persistence.

**Duration**: 3-4 weeks

#### Tasks: Veth Pair Lifecycle

| # | Task | Status | Notes |
|---|------|--------|-------|
| 2.1 | Implement naming convention: abbreviate bridge names ("vswitch0" > "vs0"), generate pair names (vs0-vs1, vs1-vs0) | TODO | Port from nmctl bridge_veth.rs |
| 2.2 | Implement `create_veth_pair()`: create via netlink + enslave each end to its bridge | TODO | |
| 2.3 | Implement `delete_veth_pair()`: delete via netlink + update topology state | TODO | |
| 2.4 | Implement `restore_veth_pairs()`: read topology state, recreate all pairs after reboot | TODO | |
| 2.5 | Implement veth systemd restoration service + timer (boot-time + periodic check) | TODO | Port from nmctl bridge_veth.rs |
| 2.6 | Implement `enable_veth_service()` / `disable_veth_service()` | TODO | |
| 2.7 | Unit tests: naming, create, delete, restore | TODO | Target: 8+ tests |

#### Tasks: Topology State Machine

| # | Task | Status | Notes |
|---|------|--------|-------|
| 2.8 | Implement `connect(spoke, hub)`: create veth pair, enslave ends, update topology state | TODO | Port from nmctl bridge_topology.rs |
| 2.9 | Implement `disconnect(spoke, hub)`: delete veth pair, update topology state | TODO | |
| 2.10 | Implement `isolate(bridge)`: remove all veth connections from a bridge | TODO | |
| 2.11 | Implement `quarantine(bridge)`: isolate + disable all ports | TODO | |
| 2.12 | Implement topology visualization: ASCII tree display | TODO | |
| 2.13 | Implement master bridge designation and state tracking | TODO | |
| 2.14 | Unit tests: connect, disconnect, isolate, quarantine, topology display | TODO | Target: 10+ tests |

#### Tasks: VLAN Dual-Bridge Pattern

| # | Task | Status | Notes |
|---|------|--------|-------|
| 2.15 | Implement VLAN creation with companion bridge: VLAN interface + vlanNbr bridge | TODO | Port from nmctl vlan.rs |
| 2.16 | Implement STP disable on VLAN bridges (leaf bridges, no loops) | TODO | Critical: prevents FDB flush disruption |
| 2.17 | Implement VLAN listing grouped by parent bridge | TODO | |
| 2.18 | Implement parent bridge MAC preservation during VLAN activation | TODO | |
| 2.19 | Unit tests: dual-bridge creation, STP disable, MAC preservation | TODO | Target: 8+ tests |

#### Tasks: Bridge Uplink Management

| # | Task | Status | Notes |
|---|------|--------|-------|
| 2.20 | Implement single NIC uplink: enslave interface to bridge | TODO | Port from nmctl bridge.rs |
| 2.21 | Implement bond uplink: create bond, enslave to bridge | TODO | |
| 2.22 | Implement uplink transitions: single-to-bond, bond-to-single, remove uplink | TODO | |
| 2.23 | Implement bridge deletion with full cleanup: veth pairs, uplink, MAC files, topology state | TODO | |
| 2.24 | Unit tests: uplink create, transitions, cleanup | TODO | Target: 10+ tests |

**Milestone 2 total**: 24 tasks | **Target test count**: 36+

---

### Milestone 3 — Transaction Safety & Boot Baseline

**Goal**: Multi-step operations are atomic (rollback on failure). Appliance boots deterministically.

**Duration**: 3-4 weeks

#### Tasks: Transaction Engine

| # | Task | Status | Notes |
|---|------|--------|-------|
| 3.1 | Implement `UndoAction` enum: DeleteInterface, RemoveAddress, UntrackResource, RemoveMasterBridge | TODO | Port from nmctl transaction.rs |
| 3.2 | Implement `Transaction` struct: accumulate undo actions, rollback on error | TODO | |
| 3.3 | Implement `Transaction.run(fn)`: closure-based auto-rollback | TODO | |
| 3.4 | Implement manual mode: `Transaction.new()` + explicit `rollback()` for complex flows | TODO | |
| 3.5 | Wrap bond creation in transaction (bond + slaves + activate) | TODO | |
| 3.6 | Wrap bridge creation in transaction (bridge + uplink) | TODO | |
| 3.7 | Wrap VLAN creation in transaction (VLAN interface + companion bridge) | TODO | |
| 3.8 | Implement failure injection for testing (Nth operation fails) | TODO | Port pattern from nmctl MockNmClient |
| 3.9 | Unit tests: rollback on bond/bridge/VLAN creation failure | TODO | Target: 12+ tests |

#### Tasks: Boot-Time Baseline

| # | Task | Status | Notes |
|---|------|--------|-------|
| 3.10 | Implement appliance type detection: Physical vs Virtual via `systemd-detect-virt` | TODO | Port from nmctl baseline.rs |
| 3.11 | Implement `baseline auto`: create management bridge (vswitch0) with first physical NIC | TODO | |
| 3.12 | Implement MAC restore + uplink re-activation if management bridge exists | TODO | |
| 3.13 | Implement ICN setup (Physical): create veth0-veth1 pair, ICN on veth0 (172.16.254.2/24) | TODO | |
| 3.14 | Implement Hypervisor Network setup (Physical): veth1 (172.16.254.1/24) | TODO | |
| 3.15 | Implement Virtual ICN fallback: second physical NIC for ICN | TODO | |
| 3.16 | Implement `baseline force`: delete all managed resources, reset state, recreate | TODO | |
| 3.17 | Implement baseline systemd service: write unit file, daemon-reload, enable | TODO | |
| 3.18 | Implement `baseline enable-service` / `disable-service` with control file management | TODO | |
| 3.19 | Implement boot-time determinism: guaranteed order bonds > bridges > VLANs > veth > addresses | TODO | |
| 3.20 | Unit tests: auto fresh, auto existing, force, appliance detection, MAC restore | TODO | Target: 15+ tests |
| 3.21 | Integration tests on real hardware: full boot cycle | TODO | Target: 8+ tests |

#### Tasks: IP & DNS Configuration

| # | Task | Status | Notes |
|---|------|--------|-------|
| 3.22 | Implement DHCP client integration: spawn/manage dhcpcd per interface | TODO | |
| 3.23 | Implement lease file monitoring: detect IP assignment, update network identity | TODO | |
| 3.24 | Implement static IP assignment via netlink | TODO | |
| 3.25 | Implement DNS configuration: write /etc/resolv.conf or integrate with systemd-resolved | TODO | |
| 3.26 | Implement default gateway management via netlink | TODO | |
| 3.27 | Implement static route management via netlink with metric support | TODO | |
| 3.28 | Unit tests: DHCP integration, static IP, DNS, routes | TODO | Target: 10+ tests |

#### Tasks: VM Integration

| # | Task | Status | Notes |
|---|------|--------|-------|
| 3.29 | Implement libvirt network create/delete (virsh net-define/net-start with XML template) | TODO | Port from nmctl libvirt.rs |
| 3.30 | Implement libvirt network modify (virsh net-update) | TODO | |
| 3.31 | Implement VM attach/detach (virsh attach-interface/detach-interface) | TODO | |
| 3.32 | Implement VM listing with network info (virsh domiflist parsing) | TODO | |
| 3.33 | Implement live VM network move (ip link set master for running VMs) | TODO | |
| 3.34 | Implement VM sync-interfaces: validate persistent config vs running state | TODO | |
| 3.35 | Unit tests: libvirt operations | TODO | Target: 6+ tests |

**Milestone 3 total**: 35 tasks | **Target test count**: 51+

---

### Phase A Summary

| Milestone | Tasks | Tests | Weeks | Result |
|-----------|-------|-------|-------|--------|
| M0: Netlink completion | 44 | 61+ | 3-4 | Every netlink operation works and is tested |
| M1: State & MAC | 17 | 29+ | 2-3 | Persistent state, MAC preservation |
| M2: Topology engine | 24 | 36+ | 3-4 | Hub-and-spoke, veth lifecycle, VLAN dual-bridge |
| M3: Transactions & boot | 35 | 51+ | 3-4 | Atomic operations, baseline boot, DHCP, libvirt |
| **Phase A total** | **120** | **177+** | **12-16** | **Production-ready single-node networking** |

**Deliverable**: wire replaces NetworkManager on a Syneto appliance. All nmctl domain logic ported.

---

## Phase B: Intelligence — Daemon, Self-Healing, Declarative Config

The daemon layer. Wire becomes a continuously-running service that monitors and repairs.

---

### Milestone 4 — Daemon Core & Netlink Event Loop

**Goal**: wire-d runs as a systemd service, subscribes to kernel netlink events, and maintains live network state in memory.

**Duration**: 3-4 weeks

#### Tasks: Daemon Lifecycle

| # | Task | Status | Notes |
|---|------|--------|-------|
| 4.1 | Implement daemon entry point with sd_notify integration | TODO | |
| 4.2 | Implement signal handling: SIGHUP (reload config), SIGTERM (graceful shutdown) | TODO | |
| 4.3 | Implement PID file and single-instance enforcement | TODO | |
| 4.4 | Implement systemd service file: `wire-d.service` with watchdog | TODO | |
| 4.5 | Implement graceful degradation: if daemon crashes, kernel network state persists | TODO | |
| 4.6 | Implement emergency CLI mode: direct netlink operations when daemon unavailable | TODO | |

#### Tasks: Netlink Event Subscription

| # | Task | Status | Notes |
|---|------|--------|-------|
| 4.7 | Implement RTNL multicast group subscription: RTNLGRP_LINK, RTNLGRP_IPV4_IFADDR, RTNLGRP_IPV4_ROUTE | TODO | |
| 4.8 | Implement event dispatcher: link up/down, address add/remove, route change | TODO | |
| 4.9 | Implement carrier detection via netlink (RTM_NEWLINK with IFLA_CARRIER) | TODO | |
| 4.10 | Implement bond member state change detection | TODO | |
| 4.11 | Implement event debouncing: collapse rapid state changes into single action | TODO | |
| 4.12 | Unit tests: event parsing, debouncing, dispatch | TODO | Target: 10+ tests |

#### Tasks: Live State Cache

| # | Task | Status | Notes |
|---|------|--------|-------|
| 4.13 | Implement in-memory live state: all interfaces, addresses, routes, bridges, bonds, VLANs | TODO | |
| 4.14 | Implement full state snapshot on daemon start (query all via netlink) | TODO | |
| 4.15 | Implement incremental state update from netlink events | TODO | |
| 4.16 | Implement state export: dump current state to JSON (for diagnostics/API) | TODO | |
| 4.17 | Unit tests: state snapshot, incremental update, export | TODO | Target: 8+ tests |

#### Tasks: CLI-Daemon IPC

| # | Task | Status | Notes |
|---|------|--------|-------|
| 4.18 | Implement Unix domain socket IPC: `/var/run/wire.sock` | TODO | |
| 4.19 | Implement request/response protocol (JSON or binary) | TODO | |
| 4.20 | Implement CLI client mode: `wire` talks to daemon when running, falls back to direct netlink | TODO | |
| 4.21 | Implement daemon status query: `wire status` returns daemon health + live state summary | TODO | |
| 4.22 | Unit tests: IPC protocol, request routing, fallback mode | TODO | Target: 6+ tests |

**Milestone 4 total**: 22 tasks | **Target test count**: 24+

---

### Milestone 5 — Self-Healing & Closed-Loop Automation

**Goal**: Wire detects problems and fixes them automatically — the telecom-inspired reconciliation loop.

**Duration**: 3-4 weeks

#### Tasks: Drift Detection & Correction

| # | Task | Status | Notes |
|---|------|--------|-------|
| 5.1 | Complete reconciler: compare desired state (config) vs live state (netlink) | TODO | Reconciler structure exists, needs full implementation |
| 5.2 | Implement drift types: missing interface, wrong IP, wrong MTU, missing route, broken veth | TODO | |
| 5.3 | Implement drift correction actions for each drift type | TODO | |
| 5.4 | Implement dry-run mode: show what would change without applying | TODO | |
| 5.5 | Implement config diff output: human-readable before/after comparison | TODO | |
| 5.6 | Unit tests: drift detection for each type, correction verification | TODO | Target: 12+ tests |

#### Tasks: Self-Healing Loops

| # | Task | Status | Notes |
|---|------|--------|-------|
| 5.7 | Implement carrier loss auto-response: detect within milliseconds via netlink events | TODO | |
| 5.8 | Implement veth pair auto-repair: detect missing veth, recreate immediately | TODO | Replaces 3-min timer with event-driven |
| 5.9 | Implement uplink flap dampening: hold down for configurable period before restoring | TODO | |
| 5.10 | Implement escalation policies: Tier 1 auto-fix, Tier 2 alert, Tier 3 quarantine | TODO | |
| 5.11 | Implement healing verification: after auto-repair, probe to confirm fix worked | TODO | |
| 5.12 | Implement self-healing audit log: every autonomous action logged with before/after state | TODO | |
| 5.13 | Unit tests: healing scenarios, escalation, verification | TODO | Target: 10+ tests |

#### Tasks: Structured Logging & Observability Foundation

| # | Task | Status | Notes |
|---|------|--------|-------|
| 5.14 | Implement structured JSON logging for all operations | TODO | |
| 5.15 | Implement log levels: debug, info, warn, error with per-module control | TODO | |
| 5.16 | Implement operation context: each action tagged with trigger (user, reconciler, event) | TODO | |
| 5.17 | Implement log rotation and size limits | TODO | |

**Milestone 5 total**: 17 tasks | **Target test count**: 22+

---

### Milestone 6 — Declarative Configuration & Backup

**Goal**: Single config file describes entire network. Apply, validate, diff, backup, restore.

**Duration**: 3-4 weeks

#### Tasks: Config Language

| # | Task | Status | Notes |
|---|------|--------|-------|
| 6.1 | Finalize config DSL syntax: sequential and hierarchical formats | TODO | Parser exists, needs completion |
| 6.2 | Complete config parser: full validation of all network object types | TODO | |
| 6.3 | Implement semantic validation: reference integrity (VLAN parent exists, bond members exist) | TODO | |
| 6.4 | Implement config resolution: named references to interfaces, bridges, bonds | TODO | |
| 6.5 | Implement config validation (dry-run): parse + validate without applying | TODO | |
| 6.6 | Implement config apply: translate config to desired state, run reconciler | TODO | |
| 6.7 | Implement config diff: show what would change before applying | TODO | |
| 6.8 | Unit tests: parser, validation, resolution, diff | TODO | Target: 15+ tests |

#### Tasks: Config Backup & Restore

| # | Task | Status | Notes |
|---|------|--------|-------|
| 6.9 | Implement config export: dump current live state as wire config format | TODO | |
| 6.10 | Implement config backup: snapshot config + state files to `/var/lib/wire/backups/` | TODO | |
| 6.11 | Implement backup metadata: timestamp, node name, interface count | TODO | |
| 6.12 | Implement config restore: apply backup config via reconciler | TODO | |
| 6.13 | Implement backup list/show/set-default | TODO | |
| 6.14 | Unit tests: export, backup, restore round-trip | TODO | Target: 8+ tests |

#### Tasks: Idempotency & Safety

| # | Task | Status | Notes |
|---|------|--------|-------|
| 6.15 | Verify all operations are idempotent: same command safe to run multiple times | TODO | |
| 6.16 | Implement atomic state transitions: no partial configurations on failure | TODO | |
| 6.17 | Implement zero-downtime upgrade: upgrade binary, daemon restarts, state persists | TODO | |

**Milestone 6 total**: 17 tasks | **Target test count**: 23+

---

### Phase B Summary

| Milestone | Tasks | Tests | Weeks | Result |
|-----------|-------|-------|-------|--------|
| M4: Daemon core | 22 | 24+ | 3-4 | wire-d runs, event loop, IPC |
| M5: Self-healing | 17 | 22+ | 3-4 | Closed-loop automation, structured logging |
| M6: Declarative config | 17 | 23+ | 3-4 | Config language, backup/restore |
| **Phase B total** | **56** | **69+** | **10-14** | **Intelligent, self-healing daemon** |

**Deliverable**: wire-d runs as a service, monitors network health, auto-repairs drift, declarative config files.

---

## Phase C: Fabric — Overlays, Encryption, Clustering

This is where wire becomes a multi-node network fabric. Pro tier features.

---

### Milestone 7 — Overlay Networking

**Goal**: VXLAN tunnels between nodes, FDB management, GRE/IPIP fallback.

**Duration**: 4-6 weeks

#### Tasks: VXLAN

| # | Task | Status | Notes |
|---|------|--------|-------|
| 7.1 | Implement VXLAN tunnel creation via netlink: VNI, remote IP, local IP, destination port | TODO | tunnel.zig has scaffolding |
| 7.2 | Implement VXLAN with multicast group for BUM traffic | TODO | |
| 7.3 | Implement VXLAN-to-bridge binding: attach VXLAN interface as bridge port | TODO | |
| 7.4 | Implement head-end replication: unicast-based BUM handling (no multicast required) | TODO | |
| 7.5 | Implement FDB entry management for VXLAN: static remote MAC entries | TODO | |
| 7.6 | Implement FDB synchronization: share MAC tables between tunnel endpoints | TODO | |
| 7.7 | Implement MTU handling: account for VXLAN overhead (50 bytes) on underlay | TODO | |
| 7.8 | Implement VXLAN tunnel health probing: periodic probe through tunnel to detect black holes | TODO | |
| 7.9 | Unit tests: VXLAN create, FDB, MTU, probe | TODO | Target: 10+ tests |
| 7.10 | Integration tests: VXLAN between two nodes, VM-to-VM across tunnel | TODO | Target: 6+ tests |

#### Tasks: GRE & IPIP

| # | Task | Status | Notes |
|---|------|--------|-------|
| 7.11 | Implement GRE tunnel creation via netlink | TODO | |
| 7.12 | Implement IPIP tunnel creation via netlink | TODO | |
| 7.13 | Implement tunnel type auto-selection based on capabilities | TODO | |
| 7.14 | Unit tests: GRE, IPIP create/delete | TODO | Target: 4+ tests |

#### Tasks: GENEVE & Advanced Overlays

| # | Task | Status | Notes |
|---|------|--------|-------|
| 7.15 | Implement GENEVE tunnel creation via netlink (extensible TLV metadata) | TODO | |
| 7.16 | Implement VXLAN-GPE for non-Ethernet payloads | TODO | |
| 7.17 | Unit tests: GENEVE, VXLAN-GPE | TODO | Target: 4+ tests |

**Milestone 7 total**: 17 tasks | **Target test count**: 24+

---

### Milestone 8 — Encrypted Fabric

**Goal**: WireGuard mesh between nodes. Optional IPsec. VXLAN rides inside encrypted tunnels.

**Duration**: 3-4 weeks

#### Tasks: WireGuard

| # | Task | Status | Notes |
|---|------|--------|-------|
| 8.1 | Implement WireGuard interface creation via netlink | TODO | |
| 8.2 | Implement key pair generation (use kernel crypto or wg genkey) | TODO | |
| 8.3 | Implement peer configuration: public key, endpoint, allowed IPs | TODO | |
| 8.4 | Implement point-to-point WireGuard tunnel (OSS tier) | TODO | |
| 8.5 | Implement auto-mesh: full mesh WireGuard between all cluster nodes (Pro tier) | TODO | |
| 8.6 | Implement key rotation: periodic re-key without traffic interruption | TODO | |
| 8.7 | Implement VXLAN-inside-WireGuard: overlay tunnels ride encrypted underlay | TODO | |
| 8.8 | Unit tests: WireGuard create, peer config, key rotation | TODO | Target: 8+ tests |
| 8.9 | Integration tests: encrypted tunnel between two nodes, VXLAN inside | TODO | Target: 4+ tests |

#### Tasks: IPsec (Enterprise)

| # | Task | Status | Notes |
|---|------|--------|-------|
| 8.10 | Implement IPsec transport mode via xfrm netlink | TODO | |
| 8.11 | Implement IPsec policy and SA management | TODO | |
| 8.12 | Unit tests: IPsec setup, policy | TODO | Target: 4+ tests |

#### Tasks: MACsec (Enterprise)

| # | Task | Status | Notes |
|---|------|--------|-------|
| 8.13 | Implement MACsec interface creation via netlink | TODO | |
| 8.14 | Implement MACsec key management | TODO | |
| 8.15 | Unit tests: MACsec create, key setup | TODO | Target: 3+ tests |

**Milestone 8 total**: 15 tasks | **Target test count**: 19+

---

### Milestone 9 — Clustering

**Goal**: Multiple wire-d instances form a cluster, share state, coordinate segment placement.

**Duration**: 6-8 weeks

#### Tasks: Peer Discovery & Health

| # | Task | Status | Notes |
|---|------|--------|-------|
| 9.1 | Implement static peer configuration: cluster members in config file | TODO | |
| 9.2 | Implement mDNS peer discovery for zero-config on flat networks | TODO | |
| 9.3 | Implement heartbeat protocol: periodic health probes between all peers | TODO | |
| 9.4 | Implement health metrics: carrier status, latency, packet loss between peers | TODO | |
| 9.5 | Implement peer state machine: joining, healthy, degraded, unreachable, removed | TODO | |
| 9.6 | Unit tests: discovery, heartbeat, state transitions | TODO | Target: 10+ tests |

#### Tasks: Leader Election & Distributed State

| # | Task | Status | Notes |
|---|------|--------|-------|
| 9.7 | Implement priority-based leader election (not Raft — simpler for 3-16 nodes) | TODO | |
| 9.8 | Implement cluster network map: which segments exist on which nodes | TODO | |
| 9.9 | Implement state replication: leader broadcasts map to all members | TODO | |
| 9.10 | Implement split-brain protection: quorum-based decisions | TODO | |
| 9.11 | Implement node fencing: isolate partitioned nodes from segment management | TODO | |
| 9.12 | Unit tests: election, replication, split-brain scenarios | TODO | Target: 12+ tests |

#### Tasks: Segment Orchestration

| # | Task | Status | Notes |
|---|------|--------|-------|
| 9.13 | Implement segment stretch: "VLAN 100 available on nodes A, B, C" | TODO | |
| 9.14 | Implement automatic VXLAN tunnel creation between nodes for stretched segments | TODO | |
| 9.15 | Implement FDB synchronization across cluster for stretched segments | TODO | |
| 9.16 | Implement dynamic tunnel teardown: remove tunnels when no VMs need the segment | TODO | |
| 9.17 | Implement segment migration: move segment ownership from one node to another | TODO | |
| 9.18 | Unit tests: stretch, tunnel lifecycle, FDB sync, migration | TODO | Target: 10+ tests |

#### Tasks: Node Lifecycle

| # | Task | Status | Notes |
|---|------|--------|-------|
| 9.19 | Implement node join: new node announces itself, receives cluster state | TODO | |
| 9.20 | Implement node leave (graceful): drain segments, remove tunnels, leave cluster | TODO | |
| 9.21 | Implement node failure handling: detect unreachable, re-route segments | TODO | |
| 9.22 | Implement rolling upgrade: upgrade one node at a time without fabric disruption | TODO | |
| 9.23 | Unit tests: join, leave, failure, upgrade scenarios | TODO | Target: 8+ tests |

#### Tasks: VM Migration Awareness

| # | Task | Status | Notes |
|---|------|--------|-------|
| 9.24 | Implement libvirt migration event subscription (virsh event or D-Bus) | TODO | |
| 9.25 | Implement pre-migration hook: stretch segment to destination node before VM arrives | TODO | |
| 9.26 | Implement post-migration hook: tear down segment on source if no VMs remain | TODO | |
| 9.27 | Implement network-follows-VM: automatic segment lifecycle tracking VM placement | TODO | |
| 9.28 | Integration tests: VM migration with network follow across 2 nodes | TODO | Target: 4+ tests |

**Milestone 9 total**: 28 tasks | **Target test count**: 44+

---

### Phase C Summary

| Milestone | Tasks | Tests | Weeks | Result |
|-----------|-------|-------|-------|--------|
| M7: Overlays | 17 | 24+ | 4-6 | VXLAN, GRE, GENEVE tunnels |
| M8: Encryption | 15 | 19+ | 3-4 | WireGuard mesh, IPsec, MACsec |
| M9: Clustering | 28 | 44+ | 6-8 | Multi-node fabric with segment orchestration |
| **Phase C total** | **60** | **87+** | **14-20** | **Clustering network fabric** |

**Deliverable**: Multi-node wire cluster with overlay networking, encrypted mesh, automatic segment stretching, VM migration awareness.

---

## Phase D: Enterprise — Advanced Features

Analytics, multi-tenancy, service chaining, multi-site. Enterprise tier.

---

### Milestone 10 — Service Chaining, Network Slicing & QoS

**Goal**: Telecom-inspired traffic management. Route traffic through VM appliances. Isolate workloads with guaranteed resources.

**Duration**: 5-7 weeks

#### Tasks: Service Chaining

| # | Task | Status | Notes |
|---|------|--------|-------|
| 10.1 | Implement service function registration: declare a VM/bridge as a network function | TODO | |
| 10.2 | Implement service chain declaration: ordered list of functions traffic must traverse | TODO | |
| 10.3 | Implement chain building: create veth-connected bridge sequence for traffic steering | TODO | |
| 10.4 | Implement chain health monitoring: detect if a function VM is down | TODO | |
| 10.5 | Implement chain bypass on failure: temporarily skip dead function (with alert) | TODO | |
| 10.6 | Implement chain insertion/removal without downtime | TODO | |
| 10.7 | Implement per-chain traffic counters | TODO | |
| 10.8 | Unit tests: chain build, health, bypass, hot-swap | TODO | Target: 10+ tests |

#### Tasks: Network Slicing

| # | Task | Status | Notes |
|---|------|--------|-------|
| 10.9 | Implement slice definition: named set of VLANs, bridges, tunnels, QoS policies | TODO | |
| 10.10 | Implement resource reservation per slice: guaranteed bandwidth, max latency | TODO | |
| 10.11 | Implement slice isolation enforcement at bridge + VLAN level | TODO | |
| 10.12 | Implement slice spanning across cluster nodes via segment orchestration | TODO | |
| 10.13 | Implement slice lifecycle: create, modify, delete as atomic operations | TODO | |
| 10.14 | Implement slice SLA monitoring: verify QoS commitments continuously | TODO | |
| 10.15 | Implement slice admission control: reject VMs if slice at capacity | TODO | |
| 10.16 | Unit tests: slice lifecycle, isolation, SLA | TODO | Target: 10+ tests |

#### Tasks: Traffic Control & QoS

| # | Task | Status | Notes |
|---|------|--------|-------|
| 10.17 | Implement tc-based rate limiting per interface via netlink (qdisc.zig exists) | TODO | |
| 10.18 | Implement priority queuing: traffic classification into priority bands | TODO | |
| 10.19 | Implement DSCP marking: set/match DiffServ code points | TODO | |
| 10.20 | Implement HTB (Hierarchical Token Bucket): bandwidth guarantees with borrowing | TODO | |
| 10.21 | Implement per-VM bandwidth limits via tc on VM's vnet interface | TODO | |
| 10.22 | Implement per-VLAN QoS policies | TODO | |
| 10.23 | Implement ingress policing: drop/remark traffic exceeding rate | TODO | |
| 10.24 | Unit tests: rate limiting, HTB, per-VM/per-VLAN QoS | TODO | Target: 8+ tests |

**Milestone 10 total**: 24 tasks | **Target test count**: 28+

---

### Milestone 11 — Observability, Diagnostics & Security

**Goal**: Full production visibility. Prometheus metrics, diagnostics toolkit, security enforcement.

**Duration**: 5-7 weeks

#### Tasks: Prometheus Metrics

| # | Task | Status | Notes |
|---|------|--------|-------|
| 11.1 | Implement Prometheus metrics endpoint (HTTP /metrics) | TODO | |
| 11.2 | Export interface metrics: TX/RX packets, bytes, errors, drops | TODO | |
| 11.3 | Export bond metrics: member status, active slave, failover count | TODO | |
| 11.4 | Export tunnel metrics: per-tunnel throughput, latency, packet loss | TODO | |
| 11.5 | Export cluster metrics: peer health, leader status, segment count | TODO | |
| 11.6 | Export daemon metrics: operation latency, reconciliation count, healing actions | TODO | |
| 11.7 | Implement historical snapshots: periodic full state capture for diff analysis | TODO | |
| 11.8 | Implement configuration changelog: every change with timestamp and trigger | TODO | |
| 11.9 | Implement alerting rules: configurable thresholds with webhook notifications | TODO | |

#### Tasks: Advanced Diagnostics

| # | Task | Status | Notes |
|---|------|--------|-------|
| 11.10 | Complete built-in ping (ICMP) — no external binary dependency | TODO | Scaffolding exists in diagnostics/ |
| 11.11 | Complete built-in traceroute | TODO | |
| 11.12 | Implement targeted packet capture with BPF filters | TODO | |
| 11.13 | Implement cross-node path analysis: trace through overlay tunnels | TODO | |
| 11.14 | Implement connectivity matrix: test reachability between all segments from all nodes | TODO | |
| 11.15 | Implement MTU path discovery: detect VXLAN overhead issues across tunnel paths | TODO | |
| 11.16 | Implement network validation: verify topology matches declared intent | TODO | |
| 11.17 | Implement fault injection: simulate link failures, latency, packet loss for testing | TODO | |

#### Tasks: Security

| # | Task | Status | Notes |
|---|------|--------|-------|
| 11.18 | Implement MAC address allowlist per bridge port (prevent MAC spoofing) | TODO | |
| 11.19 | Implement ARP inspection: validate ARP replies against known IP-MAC bindings | TODO | |
| 11.20 | Implement DHCP snooping: prevent rogue DHCP servers | TODO | |
| 11.21 | Implement port security: limit MACs learned per bridge port | TODO | |
| 11.22 | Implement storm control: rate-limit broadcast/multicast/unknown-unicast | TODO | |
| 11.23 | Implement network segmentation policies: "segment A cannot reach segment B" | TODO | |
| 11.24 | Implement traffic flow logging: record VM communication patterns | TODO | |

#### Tasks: OAM (Operations, Administration, Maintenance)

| # | Task | Status | Notes |
|---|------|--------|-------|
| 11.25 | Implement link quality monitoring: error rates, CRC counters | TODO | |
| 11.26 | Implement end-to-end connectivity checks across overlay paths | TODO | |
| 11.27 | Implement loopback testing: inject test frames at specific points | TODO | |
| 11.28 | Implement maintenance windows: schedule changes with auto-rollback on failure | TODO | |
| 11.29 | Implement change impact prediction: "this affects N VMs across M nodes" | TODO | |
| 11.30 | Implement network inventory: real-time inventory of all objects across cluster | TODO | |

**Milestone 11 total**: 30 tasks | **Target test count**: 20+ (many features are operational, tested via integration)

---

### Milestone 12 — Multi-Site, Multi-Tenancy, API & Integrations

**Goal**: Enterprise-grade multi-site, multi-tenant, and integration capabilities.

**Duration**: 6-8 weeks

#### Tasks: Multi-Site

| # | Task | Status | Notes |
|---|------|--------|-------|
| 12.1 | Implement site definition: group nodes by physical location | TODO | |
| 12.2 | Implement intra-site vs inter-site tunnel policy (VXLAN within, WireGuard between) | TODO | |
| 12.3 | Implement WAN-aware segment stretching: only stretch across WAN when requested | TODO | |
| 12.4 | Implement site affinity: keep segments local unless VM migrates | TODO | |
| 12.5 | Implement WAN bandwidth reservation for stretched segments | TODO | |
| 12.6 | Implement active-passive site failover: entire site fails, standby activates | TODO | |
| 12.7 | Implement active-active multi-site: both sites serve traffic | TODO | |
| 12.8 | Implement site-aware migration advisor: latency impact prediction | TODO | |

#### Tasks: Multi-Tenancy

| # | Task | Status | Notes |
|---|------|--------|-------|
| 12.9 | Implement network namespace isolation per tenant | TODO | |
| 12.10 | Implement VLAN range assignment per tenant | TODO | |
| 12.11 | Implement resource quotas: segments, tunnels, bandwidth per tenant | TODO | |
| 12.12 | Implement tenant RBAC: admin, operator, viewer roles per tenant | TODO | |
| 12.13 | Implement tenant isolation verification: continuous validation | TODO | |
| 12.14 | Implement per-tenant billing metrics: bandwidth and resource usage | TODO | |

#### Tasks: Intent-Based Networking

| # | Task | Status | Notes |
|---|------|--------|-------|
| 12.15 | Implement workload connectivity intent: "group A can reach group B on port X" | TODO | |
| 12.16 | Implement segment availability intent: "VLAN N on all compute nodes" | TODO | |
| 12.17 | Implement redundancy intent: "survive any single link failure" | TODO | |
| 12.18 | Implement performance intent: "< 1ms inter-node latency" | TODO | |
| 12.19 | Implement compliance intent: "no unencrypted cross-site traffic" | TODO | |
| 12.20 | Implement intent conflict detection | TODO | |
| 12.21 | Implement intent simulation: predict resource impact without applying | TODO | |

#### Tasks: API & Integrations

| # | Task | Status | Notes |
|---|------|--------|-------|
| 12.22 | Implement REST API: JSON endpoints for all operations | TODO | |
| 12.23 | Implement webhook notifications: HTTP callbacks on events | TODO | |
| 12.24 | Implement Prometheus service discovery: auto-register nodes | TODO | |
| 12.25 | Create Grafana dashboard templates for common scenarios | TODO | |
| 12.26 | Create Ansible module for declarative management via playbooks | TODO | |
| 12.27 | Create Terraform provider for infrastructure-as-code | TODO | |
| 12.28 | Implement SNMP agent for legacy monitoring compatibility | TODO | |
| 12.29 | Implement gRPC streaming API for real-time event consumption | TODO | |

#### Tasks: Programmable Data Plane

| # | Task | Status | Notes |
|---|------|--------|-------|
| 12.30 | Implement eBPF-based fast path for overlay traffic | TODO | |
| 12.31 | Implement XDP packet filtering for DDoS mitigation | TODO | |
| 12.32 | Implement per-flow load balancing across VXLAN tunnels via eBPF | TODO | |
| 12.33 | Implement hardware offload hints: generate tc-flower rules for NIC offload | TODO | |

**Milestone 12 total**: 33 tasks | **Target test count**: 15+ (many are integration-level)

---

### Phase D Summary

| Milestone | Tasks | Tests | Weeks | Result |
|-----------|-------|-------|-------|--------|
| M10: Chaining, slicing, QoS | 24 | 28+ | 5-7 | Telecom-grade traffic management |
| M11: Observability & security | 30 | 20+ | 5-7 | Prometheus, diagnostics, OAM, security |
| M12: Multi-site, tenancy, API | 33 | 15+ | 6-8 | Full enterprise platform |
| **Phase D total** | **87** | **63+** | **16-22** | **Enterprise network fabric** |

**Deliverable**: Complete enterprise platform with service chaining, network slicing, multi-site, multi-tenancy, REST API, Terraform, and eBPF acceleration.

---

## Grand Total

| Phase | Milestones | Tasks | Tests | Weeks | Deliverable |
|-------|-----------|-------|-------|-------|-------------|
| **A: Foundation** | M0-M3 | 120 | 177+ | 12-16 | Production single-node networking |
| **B: Intelligence** | M4-M6 | 56 | 69+ | 10-14 | Self-healing daemon + declarative config |
| **C: Fabric** | M7-M9 | 60 | 87+ | 14-20 | Clustering + overlays + encryption |
| **D: Enterprise** | M10-M12 | 87 | 63+ | 16-22 | Service chaining, slicing, multi-site, API |
| **Total** | **13 milestones** | **323 tasks** | **396+ tests** | **52-72 weeks** | **The network fabric king** |

---

## Release Mapping

| Release | Milestones | Tier | Market Event |
|---------|-----------|------|-------------|
| **v0.5** | M0 | Internal | Validated netlink layer |
| **v1.0** | M0-M3 | OSS | "Better than NetworkManager for servers" — community launch |
| **v1.5** | M4-M5 | OSS | Self-healing daemon — HackerNews moment |
| **v2.0** | M6-M7 | OSS + Pro preview | Declarative config + VXLAN — Proxmox SDN alternative |
| **v3.0** | M8-M9 | Pro | Encrypted clustering — first paying customers |
| **v4.0** | M10-M11 | Enterprise preview | Service chaining + observability |
| **v5.0** | M12 | Enterprise | Multi-site + API + Terraform — enterprise ready |

---

## Success Criteria Per Phase

**Phase A complete when:**
- [ ] wire replaces NM on a Syneto appliance
- [ ] Boot-to-operational in < 5 seconds
- [ ] All 7 nmctl production lessons encoded
- [ ] 177+ tests passing
- [ ] Deployed to Syneto test server

**Phase B complete when:**
- [ ] wire-d runs for 30 days without restart
- [ ] Drift correction happens within 1 second of detection
- [ ] Config file describes full Syneto topology
- [ ] Zero manual intervention needed after boot

**Phase C complete when:**
- [ ] 3-node cluster forms and operates autonomously
- [ ] VM migration triggers automatic network stretch
- [ ] WireGuard mesh encrypts all inter-node traffic
- [ ] Failover of one node doesn't disrupt running VMs on others

**Phase D complete when:**
- [ ] 5+ paying customers on Pro tier
- [ ] REST API serves web UI or external orchestrator
- [ ] Grafana dashboard shows full cluster health
- [ ] Multi-site deployment (2 sites) operational
