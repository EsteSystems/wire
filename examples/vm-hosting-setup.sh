#!/bin/bash
# VM Hosting Network Topology Setup Script
# =========================================
#
# Creates a multi-segment VM hosting topology:
# - Bonded uplink from two physical interfaces
# - Main uplink bridge
# - Two isolated VM segments via veth pairs
# - VLAN-based sub-segment for additional isolation
#
# Usage: ./vm-hosting-setup.sh [IFACE1] [IFACE2]
#   IFACE1: First physical interface (default: enp0s5f1)
#   IFACE2: Second physical interface (default: enp0s5f2)

set -e

IFACE1="${1:-enp0s5f1}"
IFACE2="${2:-enp0s5f2}"

echo "=== VM Hosting Topology Setup ==="
echo "Using interfaces: $IFACE1, $IFACE2"
echo ""

# Layer 1: Bond Setup
echo "Creating bond..."
wire bond bond0 create mode active-backup
wire bond bond0 add "$IFACE1" "$IFACE2"
wire interface bond0 set state up

# Layer 2: Uplink Bridge
echo "Creating uplink bridge..."
wire bridge br-uplink create
wire bridge br-uplink add bond0
wire interface br-uplink set state up
wire interface br-uplink address 10.0.0.100/24

# Layer 2: Segment Bridges
echo "Creating segment bridges..."
wire bridge br-seg1 create
wire interface br-seg1 set state up
wire interface br-seg1 address 10.1.0.1/24

wire bridge br-seg2 create
wire interface br-seg2 set state up
wire interface br-seg2 address 10.2.0.1/24

# Veth Interconnects
echo "Creating veth interconnects..."
wire veth veth-seg1-up peer veth-seg1-br
wire veth veth-seg2-up peer veth-seg2-br

wire bridge br-uplink add veth-seg1-up veth-seg2-up
wire bridge br-seg1 add veth-seg1-br
wire bridge br-seg2 add veth-seg2-br

wire interface veth-seg1-up set state up
wire interface veth-seg1-br set state up
wire interface veth-seg2-up set state up
wire interface veth-seg2-br set state up

# VLAN Segment
echo "Creating VLAN segment..."
wire vlan 100 on br-seg1
wire bridge vlan100br create
wire bridge vlan100br add br-seg1.100
wire interface br-seg1.100 set state up
wire interface vlan100br set state up
wire interface vlan100br address 10.100.0.1/24

# Default route
echo "Adding default route..."
wire route add default via 10.0.0.1 || true

echo ""
echo "=== Topology Created ==="
wire topology show
