Ниже представлен перевод вашей инструкции на английский язык с сохранением структуры, команд и технической терминологии.

---

# Two-Port Network Card (SFP+) Loopback Physical Test Guide

## Part 1. Concept and Theoretical Background

### Methodology

Typically, assigning two IP addresses from the same subnet to two ports on a single server causes Linux to route traffic via the virtual loopback interface (`lo`) in RAM. This bypasses the physical NIC and cables.

To test the hardware (transceivers, port soldering, chip ASIC), we must isolate the ports into different **Network Namespaces (netns)**. This forces the OS to treat them as two entirely separate logical entities.

### Configuration Rationale

1. **Sysctl Tuning (`net.core...`):** Default Linux settings are optimized for 1Gbps and memory conservation. For 10G/25G/100G tests, default socket buffers (`rmem`/`wmem`) and backlogs become bottlenecks. We increase these to test the NIC's limits rather than kernel defaults.
2. **MTU 9000 (Jumbo Frames):** Increases packet size, reducing CPU overhead (fewer interrupts for the same data volume) and improving payload efficiency.
3. **TSO/GSO/SG (Offloading):** Using `ethtool -K ... on` offloads data segmentation and checksum calculations from the CPU to the NIC. Without this, the CPU will likely hit 100% load before the network link is saturated.
4. **CPU Pinning (Taskset):** Binding `iperf3` processes to specific CPU cores prevents context switching and ensures traffic doesn't cross NUMA node boundaries (critical for multi-socket systems).

---

## Part 2. Preparation and Setup

**Requirements:**

* **Packages:** `iperf3`, `ethtool`, `iproute2`, `pciutils`, `sysstat`.
* **Physical Connection:** Port 0 and Port 1 connected via patch cord (Fiber or DAC).

### Step 0. Tool Installation

Ensure diagnostic utilities are installed. `mpstat` is part of `sysstat`, and `lspci` is part of `pciutils`.

```bash
# Install required tools (Debian/Ubuntu)
sudo apt update
sudo apt install -y iperf3 ethtool pciutils sysstat iproute2 htop

```

### Step 1. Environment Configuration Script

Create a file named `prepare_test.sh`. **Note:** Replace `IFACE_A` and `IFACE_B` with your actual interface names.

```bash
#!/bin/bash

# === CONFIGURATION ===
IFACE_A="enP5p1s0f0"  # Sender Interface
IFACE_B="enP5p1s0f1"  # Receiver Interface
NS_A="ns_sender"
NS_B="ns_receiver"
IP_A="10.0.0.1/24"
IP_B="10.0.0.2/24"

echo "[INFO] Applying system kernel tuning..."
sysctl -w net.core.netdev_max_backlog=30000
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.core.rmem_default=134217728
sysctl -w net.core.wmem_default=134217728
sysctl -w net.core.optmem_max=20480
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"
sysctl -w net.ipv4.tcp_window_scaling=1
sysctl -w net.ipv4.tcp_timestamps=1
sysctl -w net.ipv4.tcp_sack=1

echo "[INFO] Cleaning old namespaces..."
ip netns del $NS_A 2>/dev/null
ip netns del $NS_B 2>/dev/null

echo "[INFO] Creating namespaces..."
ip netns add $NS_A
ip netns add $NS_B

echo "[INFO] Moving physical interfaces to namespaces..."
ip link set $IFACE_A netns $NS_A
ip link set $IFACE_B netns $NS_B

echo "[INFO] Configuring Sender ($IFACE_A)..."
ip netns exec $NS_A ip addr add $IP_A dev $IFACE_A
ip netns exec $NS_A ip link set $IFACE_A up
ip netns exec $NS_A ip link set dev $IFACE_A mtu 9000
ip netns exec $NS_A ethtool -K $IFACE_A tso on gso on sg on gro on

echo "[INFO] Configuring Receiver ($IFACE_B)..."
ip netns exec $NS_B ip addr add $IP_B dev $IFACE_B
ip netns exec $NS_B ip link set $IFACE_B up
ip netns exec $NS_B ip link set dev $IFACE_B mtu 9000
ip netns exec $NS_B ethtool -K $IFACE_B tso on gso on sg on gro on

echo "[INFO] Applying local TCP settings inside namespaces..."
for NS in $NS_A $NS_B; do
    ip netns exec $NS sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864" >/dev/null
    ip netns exec $NS sysctl -w net.ipv4.tcp_wmem="4096 65536 67108864" >/dev/null
done

echo "[SUCCESS] Configuration complete. Interfaces ready for testing."

```

### Step 2. Verification (Namespaces and IP)

Verify that interfaces moved correctly and IPs are assigned:

```bash
# List namespaces
ip netns list

# Brief check of addresses and links in all namespaces
ip -c -all netns exec ip -br addr show
ip -c -all netns exec ip -br link show

# Connectivity Sanity Check
ip netns exec ns_sender ping -c 3 10.0.0.2

```

### Step 3. Verify Offload Parameters

Check if hardware offloading is active:

```bash
ip netns exec ns_sender ethtool -k enP5p1s0f0

```

Key categories to watch:

* **Transmit Offloads:** `tx-checksumming`, `tcp-segmentation-offload (TSO)`.
* **Receive Offloads:** `rx-checksumming`, `generic-receive-offload (GRO)`.

---

## Part 3. Running the Test

### 1. Link State Check

```bash
ip netns exec ns_sender ethtool enP5p1s0f0 | grep -E "Speed|Duplex|Link detected"

```

*Expected: Link detected: yes.*

### 2. Real-time Error Monitoring (In a separate terminal)

```bash
watch -n 1 "echo '--- SENDER ---'; ip netns exec ns_sender ethtool -S enP5p1s0f0 | grep -E 'err|drop|loss|missed|crc'; echo ''; echo '--- RECEIVER ---'; ip netns exec ns_receiver ethtool -S enP5p1s0f1 | grep -E 'err|drop|loss|missed|crc'"

```

### 3. Stress Testing (iperf3)

**Terminal 1 (Receiver/Server):**

```bash
ip netns exec ns_receiver taskset -c 0-3 iperf3 -s

```

**Terminal 2 (Sender/Client):**

```bash
# -P 8: 8 parallel streams
# -R: Reverse mode (recommended to test both ways)
ip netns exec ns_sender taskset -c 4-7 iperf3 -c 10.0.0.2 -t 30 -P 8 -R

```

---

## Part 4. Advanced Diagnostics

### 1. Ring Buffers

If you see `rx_missed_errors`, the hardware buffer might be full.

```bash
ip netns exec ns_sender ethtool -g enP5p1s0f0
# To increase: ethtool -G enP5p1s0f0 rx 4096

```

### 2. Flow Control (Pause Frames)

```bash
ip netns exec ns_sender ethtool -a enP5p1s0f0

```

### 3. PCIe Lane Width

Ensure the card hasn't downgraded its link (e.g., x4 instead of x8).

```bash
lspci -s 05:01:00.0 -vvv | grep LnkSta

```

### 4. Transceiver Temperature (SFP)

```bash
ip netns exec ns_sender ethtool -m enP5p1s0f0

```

### 5. CPU Utilization (Softirq)

Use `htop` or `mpstat` to ensure one core isn't bottlenecked by `Software IRQ` (si).

```bash
watch --color -n 1 "mpstat -P ALL 1 1"

```

### 6. NUMA Locality

Check which NUMA node handles the NIC to avoid cross-socket latency:

```bash
cat /sys/class/net/enP5p1s0f0/device/numa_node

```

---

## Part 5. Cleanup (Restore Defaults)

Create `restore_default.sh` to return the system to its original state:

```bash
#!/bin/bash
IFACE_A="enP5p1s0f0"
IFACE_B="enP5p1s0f1"

echo "[INFO] Deleting namespaces..."
ip netns del ns_sender 2>/dev/null
ip netns del ns_receiver 2>/dev/null

echo "[INFO] Flushing IP addresses and resetting MTU..."
ip addr flush dev $IFACE_A
ip addr flush dev $IFACE_B
ip link set dev $IFACE_A mtu 1500
ip link set dev $IFACE_B mtu 1500

echo "[INFO] Restoring system sysctl defaults..."
sysctl --system > /dev/null

```

### Summary of Error Indicators

* **rx_missed_errors / rx_fifo_errors:** Buffer overflow (PCIe bottleneck or Ring Buffer too small).
* **Symbol / CRC / FCS errors:** Physical layer issue (bad cable, dirty optics, SFP overheating).
* **Retransmits in iperf:** Packet loss in transit.

Would you like me to create a summary table of the most common error counters and their specific hardware causes?
