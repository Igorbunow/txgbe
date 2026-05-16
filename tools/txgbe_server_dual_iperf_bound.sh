#!/usr/bin/env bash
# Deterministic dual-port iperf3 server setup.
#
# The script configures two server-side interfaces and starts two iperf3 server
# instances bound to different addresses. Parameters may be overridden through
# the environment, for example:
#   IF0=eth2 IF1=eth6 ./txgbe_server_iperf_config_fixed_v2.sh

set -euo pipefail

IF0=${IF0:-eth2}
IF1=${IF1:-eth6}
IP0=${IP0:-10.0.20.30/24}
IP1=${IP1:-10.0.21.31/24}
BIND0=${BIND0:-10.0.20.30}
BIND1=${BIND1:-10.0.21.31}
PORT0=${PORT0:-5201}
PORT1=${PORT1:-5202}
MTU=${MTU:-9000}
LOGDIR=${LOGDIR:-.}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        echo "ERROR: run as root" >&2
        exit 1
    fi
}

check_iface() {
    local ifname=$1
    if [ ! -d "/sys/class/net/${ifname}" ]; then
        echo "ERROR: no such interface: ${ifname}" >&2
        exit 1
    fi
}

configure_common_sysctl() {
    sysctl -w net.core.netdev_max_backlog=30000 >/dev/null || true
    sysctl -w net.core.rmem_max=134217728 >/dev/null || true
    sysctl -w net.core.wmem_max=134217728 >/dev/null || true
    sysctl -w net.ipv4.tcp_rmem='4096 87380 134217728' >/dev/null || true
    sysctl -w net.ipv4.tcp_wmem='4096 65536 134217728' >/dev/null || true
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
}

configure_iface() {
    local ifname=$1
    local ip_cidr=$2

    sysctl -w "net.ipv4.conf.${ifname}.rp_filter=0" >/dev/null || true
    ip link set dev "${ifname}" up
    ip link set dev "${ifname}" mtu "${MTU}"
    ip addr flush dev "${ifname}"
    ip addr add "${ip_cidr}" dev "${ifname}"

    ethtool -K "${ifname}" tso on gso on sg on gro on >/dev/null 2>&1 || true
    ethtool -K "${ifname}" lro off >/dev/null 2>&1 || true
}

show_iface_state() {
    local ifname=$1

    echo "## ${ifname} address"
    ip -br addr show dev "${ifname}"

    echo "## ${ifname} link"
    ethtool "${ifname}" | grep -E 'Speed|Duplex|Link detected' || true
}

stop_old_iperf() {
    local port=$1

    pkill -f "iperf3 -s .* -p ${port}" 2>/dev/null || true
    pkill -f "iperf3 -s.*-p ${port}" 2>/dev/null || true
}

start_iperf_server() {
    local ifname=$1
    local bind_addr=$2
    local port=$3
    local logfile="${LOGDIR}/iperf_server_${ifname}_${port}.log"

    echo "# starting ${ifname}: listen ${bind_addr}:${port}, log=${logfile}"
    iperf3 -s -B "${bind_addr}" -p "${port}" >"${logfile}" 2>&1 &
}

require_root
mkdir -p "${LOGDIR}"
check_iface "${IF0}"
check_iface "${IF1}"
configure_common_sysctl
configure_iface "${IF0}" "${IP0}"
configure_iface "${IF1}" "${IP1}"
stop_old_iperf "${PORT0}"
stop_old_iperf "${PORT1}"
start_iperf_server "${IF0}" "${BIND0}" "${PORT0}"
start_iperf_server "${IF1}" "${BIND1}" "${PORT1}"

echo "# interface state"
show_iface_state "${IF0}"
show_iface_state "${IF1}"

echo "# listeners"
ss -ltnp | grep -E ":(${PORT0}|${PORT1})" || true
