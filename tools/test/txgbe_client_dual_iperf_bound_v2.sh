#!/usr/bin/env bash
# Deterministic dual-port txgbe iperf3 client test.
#
# The script configures two local interfaces, verifies that each destination is
# routed through the expected source address/interface, and then starts two
# iperf3 clients in parallel. All parameters may be overridden through the
# environment, for example:
#   TIME=600 PARALLEL=8 ./txgbe_client_dual_iperf_bound_v2.sh

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
INTERVAL=${INTERVAL:-10}
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
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
    sysctl -w net.core.netdev_max_backlog=30000 >/dev/null || true
    sysctl -w net.core.rmem_max=134217728 >/dev/null || true
    sysctl -w net.core.wmem_max=134217728 >/dev/null || true
    sysctl -w net.ipv4.tcp_rmem='4096 87380 134217728' >/dev/null || true
    sysctl -w net.ipv4.tcp_wmem='4096 65536 134217728' >/dev/null || true
}

configure_iface() {
    local ifname=$1
    local ip_cidr=$2
    local src=$3
    local subnet=$4

    sysctl -w "net.ipv4.conf.${ifname}.rp_filter=0" >/dev/null || true

    ip link set dev "${ifname}" up
    ip link set dev "${ifname}" mtu "${MTU}"

    ip addr flush dev "${ifname}"
    ip addr add "${ip_cidr}" dev "${ifname}"
    ip route replace "${subnet}" dev "${ifname}" src "${src}"

    ethtool -K "${ifname}" tso on gso on sg on gro on rxhash on >/dev/null 2>&1 || true
    ethtool -K "${ifname}" lro off >/dev/null 2>&1 || true
}

show_iface_state() {
    local ifname=$1

    echo "## ${ifname} address"
    ip -br addr show dev "${ifname}"

    echo "## ${ifname} link"
    ethtool "${ifname}" | grep -E 'Speed|Duplex|Link detected' || true
}

verify_route() {
    local dst=$1
    local src=$2
    local expected_if=$3
    local route

    route=$(ip route get "${dst}" from "${src}")
    echo "${route}"

    if ! printf '%s\n' "${route}" | grep -q "dev ${expected_if}"; then
        echo "ERROR: route to ${dst} from ${src} is not using ${expected_if}" >&2
        exit 1
    fi
}

start_iperf_client() {
    local ifname=$1
    local src=$2
    local dst=$3
    local port=$4
    local logfile="${LOGDIR}/iperf_client_${ifname}_${port}.log"

    echo "# starting ${ifname}: ${src} -> ${dst}:${port}, log=${logfile}" >&2
    iperf3 -B "${src}" -c "${dst}" -t "${TIME}" -P "${PARALLEL}" -p "${port}" -i "${INTERVAL}" >"${logfile}" 2>&1 &
    echo "$!"
}

require_root
mkdir -p "${LOGDIR}"
check_iface "${IF0}"
check_iface "${IF1}"
configure_common_sysctl
configure_iface "${IF0}" "${IP0}" "${SRC0}" "10.0.20.0/24"
configure_iface "${IF1}" "${IP1}" "${SRC1}" "10.0.21.0/24"

echo "# route verification"
verify_route "${DST0}" "${SRC0}" "${IF0}"
verify_route "${DST1}" "${SRC1}" "${IF1}"

echo "# interface state"
show_iface_state "${IF0}"
show_iface_state "${IF1}"

echo "# starting iperf3 clients"
PID0=$(start_iperf_client "${IF0}" "${SRC0}" "${DST0}" "${PORT0}")
PID1=$(start_iperf_client "${IF1}" "${SRC1}" "${DST1}" "${PORT1}")

trap 'kill ${PID0} ${PID1} 2>/dev/null || true' INT TERM EXIT
wait "${PID0}"
wait "${PID1}"
trap - INT TERM EXIT

echo "# done"
echo "# ${IF0}/${PORT0} summary"
tail -80 "${LOGDIR}/iperf_client_${IF0}_${PORT0}.log"
echo "---"
echo "# ${IF1}/${PORT1} summary"
tail -80 "${LOGDIR}/iperf_client_${IF1}_${PORT1}.log"
