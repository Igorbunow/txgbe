# Loopback Quick Test Guide

[ English ](loopback_quick_guide.md) | [ Русский ](loopback_quick_guide_ru.md)

This guide describes how to perform a quick loopback test using network namespaces.

## 1. Setup

Create a script `sfp_conf_loopback.sh`:

```bash
#!/bin/bash

# Increase incoming packet queue (CRITICAL for 10G)
sysctl -w net.core.netdev_max_backlog=30000
# Increase buffers
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.core.rmem_default=134217728
sysctl -w net.core.wmem_default=134217728
sysctl -w net.core.optmem_max=20480
# TCP Tuning
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"
sysctl -w net.ipv4.tcp_window_scaling=1
sysctl -w net.ipv4.tcp_timestamps=1
sysctl -w net.ipv4.tcp_sack=1

# Clean up previous namespaces
ip netns del ns_sender 2>/dev/null
ip netns del ns_receiver 2>/dev/null

# Create namespaces
ip netns add ns_sender
ip netns add ns_receiver

# Move interfaces to namespaces
# Adjust interface names (enP5p1s0f0, enP5p1s0f1) to match your system
ip link set enP5p1s0f0 netns ns_sender
ip link set enP5p1s0f1 netns ns_receiver

# Configure Sender
ip netns exec ns_sender ip addr add 10.0.0.1/24 dev enP5p1s0f0
ip netns exec ns_sender ip link set enP5p1s0f0 up
ip netns exec ns_sender ip link set dev enP5p1s0f0 mtu 9000
# Enable TSO/GSO (important!)
ip netns exec ns_sender ethtool -K enP5p1s0f0 tso on gso on sg on

# Configure Receiver
ip netns exec ns_receiver ip addr add 10.0.0.2/24 dev enP5p1s0f1
ip netns exec ns_receiver ip link set enP5p1s0f1 up
ip netns exec ns_receiver ip link set dev enP5p1s0f1 mtu 9000
ip netns exec ns_receiver ethtool -K enP5p1s0f1 tso on gso on sg on
```

## 2. Verification

Check interface configuration:

```bash
ip -all netns exec ip a
```

Monitor errors in another terminal:

```bash
watch -n 1 "ip netns exec ns_sender ethtool -S enP5p1s0f0 | grep -E 'err|drop|loss'"
watch -n 1 "ip netns exec ns_receiver ethtool -S enP5p1s0f1 | grep -E 'err|drop|loss'"
```

## 3. Running Traffic

Start iperf3 server in receiver namespace:

```bash
ip netns exec ns_receiver iperf3 -s
```

Start iperf3 client in sender namespace:

```bash
ip netns exec ns_sender iperf3 -c 10.0.0.2 -t 30 -P 4 -R
```

With explicit core binding:

```bash
ip netns exec ns_receiver taskset -c 7-10 iperf3 -s
ip netns exec ns_sender taskset -c 1-4 iperf3 -c 10.0.0.2 -t 15 -P 4 -R 
```

## 4. Diagnostics

Check link status:

```bash
ip netns exec ns_sender ethtool enP5p1s0f0
ip netns exec ns_receiver ethtool enP5p1s0f1
```

Check features:

```bash
ip netns exec ns_sender ethtool -k enP5p1s0f0
```

Check PCI parameters:

```bash
lspci -vv | grep -E "LnkCap|LnkSta"
dmesg -T | grep -iE "aer|pcie|corrected|uncorrected|txgbe"
```

Read SFP EEPROM:

```bash
ip netns exec ns_sender ethtool -m enP5p1s0f0
```
