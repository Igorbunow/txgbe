#!/usr/bin/env bash
# Collect txgbe dual-port performance diagnostics on LoongArch/Loongson.
# Run this while iperf3 traffic is active.
# Usage: sudo ./txgbe_loongarch_collect_diag_v2.sh IFACE1 IFACE2 [seconds]
set -u

IF1=${1:-}
IF2=${2:-}
SECS=${3:-20}
OUT=${OUT:-"txgbe_diag_$(date +%Y%m%d_%H%M%S)"}

if [ -z "$IF1" ] || [ -z "$IF2" ]; then
    echo "Usage: sudo $0 IFACE1 IFACE2 [seconds]" >&2
    exit 2
fi

mkdir -p "$OUT"
exec > >(tee "$OUT/collect.log") 2>&1

irq_filter() {
    awk -v if1="$IF1" -v if2="$IF2" '
        NR == 1 || index($0, if1) || index($0, if2) || index($0, "txgbe") { print }
    ' /proc/interrupts
}

irq_list() {
    awk -v if1="$IF1" -v if2="$IF2" '
        index($0, if1) || index($0, if2) || index($0, "txgbe") {
            gsub(/ /, "", $1);
            sub(/:/, "", $1);
            if ($1 ~ /^[0-9]+$/) print $1;
        }
    ' /proc/interrupts | sort -n | uniq
}

stats_filter='queue_[0-9]+_(packets|bytes)|rx_queue_[0-9]+|tx_queue_[0-9]+|flow_control|pxon|pxoff|fdir|no_buffer|no_dma|alloc_rx|tx_busy|restart|timeout|miss|drop|crc|error|errors|rx_packets|tx_packets|rx_bytes|tx_bytes|rx_csum|tx_csum|rx_no_dma|tx_no_dma|rx_missed|rx_no_buffer'

save_iface_snapshot() {
    local ifc=$1
    local tag=$2
    {
        echo "# ip -s link $ifc"
        ip -s link show dev "$ifc" 2>&1 || true
        echo "# ethtool $ifc"
        ethtool "$ifc" 2>&1 || true
        echo "# ethtool -l $ifc"
        ethtool -l "$ifc" 2>&1 || true
        echo "# ethtool -g $ifc"
        ethtool -g "$ifc" 2>&1 || true
        echo "# ethtool -c $ifc"
        ethtool -c "$ifc" 2>&1 || true
        echo "# ethtool -a $ifc"
        ethtool -a "$ifc" 2>&1 || true
        echo "# ethtool -k $ifc"
        ethtool -k "$ifc" 2>&1 || true
        echo "# ethtool -x $ifc"
        ethtool -x "$ifc" 2>&1 | head -160 || true
        echo "# queue CPU masks"
        find "/sys/class/net/$ifc/queues" -maxdepth 2 -type f \
            \( -name xps_cpus -o -name rps_cpus -o -name rps_flow_cnt \) \
            -print -exec sh -c 'printf "  "; cat "$1"' _ {} \; 2>/dev/null || true
        echo "# ethtool -S $ifc filtered"
        ethtool -S "$ifc" 2>&1 | grep -Ei "$stats_filter" || true
    } > "$OUT/${ifc}_${tag}.txt"
}

copy_counter_file() {
    local src=$1
    local dst=$2
    [ -r "$src" ] && cp "$src" "$dst" || true
}

echo "# date"
date -Is

echo "# uname"
uname -a

echo "# cpu"
grep -Ei 'CPU Family|Model Name|PRID|CPU MHz|ISA|Features|processor' /proc/cpuinfo || true

echo "# module params"
for p in /sys/module/txgbe/parameters/*; do
    [ -e "$p" ] && echo "$(basename "$p")=$(cat "$p" 2>/dev/null)"
done | sort

echo "# PCI links"
for IF in "$IF1" "$IF2"; do
    DEV=$(readlink -f "/sys/class/net/$IF/device" 2>/dev/null || true)
    echo "## $IF device=$DEV"
    [ -n "$DEV" ] && lspci -s "$(basename "$DEV")" -vv 2>/dev/null | grep -Ei 'LnkCap|LnkSta|DevCap|DevCtl|MSI-X|NUMA|ASPM|MaxPayload|MaxReadReq' || true
done

echo "# IRQ mapping before"
irq_filter
for IRQ in $(irq_list); do
    echo "irq=$IRQ smp_affinity_list=$(cat /proc/irq/$IRQ/smp_affinity_list 2>/dev/null || true) smp_affinity=$(cat /proc/irq/$IRQ/smp_affinity 2>/dev/null || true)"
done

save_iface_snapshot "$IF1" before
save_iface_snapshot "$IF2" before
copy_counter_file /proc/net/softnet_stat "$OUT/softnet_before.txt"
irq_filter > "$OUT/interrupts_before.txt"

if command -v nstat >/dev/null 2>&1; then
    nstat -az > "$OUT/nstat_before.txt" 2>&1 || true
fi

echo "# sampling interrupts and softnet for ${SECS}s"
: > "$OUT/interrupts_samples.txt"
: > "$OUT/softnet_samples.txt"
for i in $(seq 1 "$SECS"); do
    {
        echo "--- sample $i $(date -Is)"
        irq_filter
    } >> "$OUT/interrupts_samples.txt"
    {
        echo "--- sample $i $(date -Is)"
        cat /proc/net/softnet_stat || true
    } >> "$OUT/softnet_samples.txt"
    sleep 1
done

echo "# IRQ mapping after"
irq_filter
for IRQ in $(irq_list); do
    echo "irq=$IRQ smp_affinity_list=$(cat /proc/irq/$IRQ/smp_affinity_list 2>/dev/null || true) smp_affinity=$(cat /proc/irq/$IRQ/smp_affinity 2>/dev/null || true)"
done

save_iface_snapshot "$IF1" after
save_iface_snapshot "$IF2" after
copy_counter_file /proc/net/softnet_stat "$OUT/softnet_after.txt"
irq_filter > "$OUT/interrupts_after.txt"

if command -v nstat >/dev/null 2>&1; then
    nstat -az > "$OUT/nstat_after.txt" 2>&1 || true
fi

echo "# filtered stats after"
for IF in "$IF1" "$IF2"; do
    echo "## $IF"
    sed -n '/# ethtool -S .* filtered/,$p' "$OUT/${IF}_after.txt" | head -220 || true
done

echo "# dmesg txgbe tail"
dmesg -T | grep -Ei 'txgbe|irq|msi|msix|aer|pcie|dma|timeout|hang|reset|link' | tail -300 > "$OUT/dmesg_txgbe_tail.txt" || true
cat "$OUT/dmesg_txgbe_tail.txt" || true

echo "# done: $OUT"
