#!/usr/bin/env bash
# Conservative txgbe 10G tuning for reproducible Loongson dual-port tests.
# Usage: sudo ./txgbe_loongarch_tune_v2.sh IFACE IP/CIDR
set -euo pipefail

IFACE=${1:-}
IP_CIDR=${2:-}
MTU=${MTU:-9000}
DISABLE_PAUSE=${DISABLE_PAUSE:-1}
DISABLE_LRO=${DISABLE_LRO:-1}

if [ -z "$IFACE" ] || [ -z "$IP_CIDR" ]; then
    echo "Usage: sudo $0 IFACE IP/CIDR" >&2
    exit 2
fi

[ "$EUID" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
[ -d "/sys/class/net/$IFACE" ] || { echo "No such interface: $IFACE" >&2; exit 1; }

sysctl -w net.core.netdev_max_backlog=30000 >/dev/null
sysctl -w net.core.rmem_max=134217728 >/dev/null
sysctl -w net.core.wmem_max=134217728 >/dev/null
sysctl -w net.core.rmem_default=134217728 >/dev/null
sysctl -w net.core.wmem_default=134217728 >/dev/null
sysctl -w net.ipv4.tcp_rmem='4096 87380 134217728' >/dev/null
sysctl -w net.ipv4.tcp_wmem='4096 65536 134217728' >/dev/null
sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null
sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null
sysctl -w net.ipv4.tcp_sack=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w "net.ipv4.conf.$IFACE.rp_filter=0" >/dev/null

ip addr flush dev "$IFACE"
ip link set dev "$IFACE" up
ip link set dev "$IFACE" mtu "$MTU"
ip addr add "$IP_CIDR" dev "$IFACE"

# Keep GRO/TSO/GSO/SG on, but disable software LRO by default for TCP diagnostics.
ethtool -K "$IFACE" tso on gso on sg on gro on rxhash on >/dev/null 2>&1 || true
if [ "$DISABLE_LRO" = 1 ]; then
    ethtool -K "$IFACE" lro off >/dev/null 2>&1 || true
fi

# Pause frames can hide RX starvation as remote TCP retransmits/throttling.
# Disable for diagnostics; set DISABLE_PAUSE=0 to leave current state untouched.
if [ "$DISABLE_PAUSE" = 1 ]; then
    ethtool -A "$IFACE" rx off tx off autoneg off >/dev/null 2>&1 || true
fi

# Show the final state.
echo "# $IFACE"
ethtool "$IFACE" | grep -E 'Speed|Duplex|Link detected' || true
ethtool -c "$IFACE" 2>/dev/null | grep -E 'Adaptive|rx-usecs:|tx-usecs:' || true
ethtool -a "$IFACE" 2>/dev/null || true
ethtool -k "$IFACE" 2>/dev/null | grep -E 'large-receive-offload|generic-receive-offload|tcp-segmentation-offload|generic-segmentation-offload|receive-hashing' || true
