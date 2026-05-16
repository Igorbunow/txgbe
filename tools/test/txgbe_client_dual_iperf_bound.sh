#!/usr/bin/env bash
# Deterministic dual-port txgbe iperf3 client test.
# Uses explicit source binding and per-subnet destinations so each SFP+ port is tested separately.
set -euo pipefail

IF0=${IF0:-enp8s0f0}
IF1=${IF1:-enp8s0f1}
IP0=${IP0:-10.0.20.20/24}
IP1=${IP1:-10.0.21.20/24}
SRC0=${SRC0:-10.0.20.20}
SRC1=${SRC1:-10.0.21.20}
DST0=${DST0:-10.0.20.30}
DST1=${DST1:-10.0.21.31}
PORT0=${PORT0:-5201}
PORT1=${PORT1:-5202}
TIME=${TIME:-300}
PARALLEL=${PARALLEL:-4}
MTU=${MTU:-9000}

[ "$EUID" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

for IF in "$IF0" "$IF1"; do
    [ -d "/sys/class/net/$IF" ] || { echo "No such interface: $IF" >&2; exit 1; }
    sysctl -w "net.ipv4.conf.$IF.rp_filter=0" >/dev/null || true
    ip link set dev "$IF" up
    ip link set dev "$IF" mtu "$MTU"
    ethtool -K "$IF" tso on gso on sg on gro on rxhash on >/dev/null 2>&1 || true
    ethtool -K "$IF" lro off >/dev/null 2>&1 || true
    ethtool -A "$IF" rx off tx off autoneg off >/dev/null 2>&1 || true
done

sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
sysctl -w net.core.netdev_max_backlog=30000 >/dev/null || true
sysctl -w net.core.rmem_max=134217728 >/dev/null || true
sysctl -w net.core.wmem_max=134217728 >/dev/null || true
sysctl -w net.ipv4.tcp_rmem='4096 87380 134217728' >/dev/null || true
sysctl -w net.ipv4.tcp_wmem='4096 65536 134217728' >/dev/null || true

ip addr flush dev "$IF0"
ip addr flush dev "$IF1"
ip addr add "$IP0" dev "$IF0"
ip addr add "$IP1" dev "$IF1"
ip route replace 10.0.20.0/24 dev "$IF0" src "$SRC0"
ip route replace 10.0.21.0/24 dev "$IF1" src "$SRC1"

echo "# route verification"
ip route get "$DST0" from "$SRC0"
ip route get "$DST1" from "$SRC1"

echo "# interface state"
ip -br addr show "$IF0" "$IF1"
ethtool "$IF0" | grep -E 'Speed|Duplex|Link detected' || true
ethtool "$IF1" | grep -E 'Speed|Duplex|Link detected' || true

echo "# starting iperf3 clients"
iperf3 -B "$SRC0" -c "$DST0" -t "$TIME" -P "$PARALLEL" -p "$PORT0" -i 10 > "iperf_${IF0}_${PORT0}.log" &
PID0=$!
iperf3 -B "$SRC1" -c "$DST1" -t "$TIME" -P "$PARALLEL" -p "$PORT1" -i 10 > "iperf_${IF1}_${PORT1}.log" &
PID1=$!
wait "$PID0" "$PID1"

echo "# done"
tail -80 "iperf_${IF0}_${PORT0}.log"
echo "---"
tail -80 "iperf_${IF1}_${PORT1}.log"
