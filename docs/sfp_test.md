# Instruction for Load Testing and Diagnostics of SFP Interfaces

This manual describes the process of preparing a Linux operating system and conducting throughput tests for network interface cards (10GbE and higher).

## 1. Testing Principle

**Goal:** To verify the physical link integrity, the quality of SFP modules/cables, and the maximum throughput of the Network Interface Card (NIC).

**Principle:**
To correctly test high-speed interfaces (10G/25G/40G), it is necessary to eliminate software bottlenecks (OS kernel and TCP/IP stack). By default, Linux settings are optimized for reliability and handling multiple connections rather than maximizing the speed of a single stream.

We perform the following actions:

1. **Buffer Expansion (Sysctl):** Increase the memory allocated for network packets so the kernel can process the incoming stream without dropping packets due to queue overflows.
2. **Jumbo Frames (MTU 9000):** Increase the payload size in a single frame. This reduces the number of CPU interrupts (fewer packets for the same data volume) and decreases header overhead.
3. **Offloading:** Offload packet segmentation and assembly tasks (TSO/GSO) from the CPU to the NIC chip.
4. **Traffic Generation (Iperf3):** Run a synthetic test to saturate the channel with data.

---

## 2. System Preparation (Tuning)

These settings must be applied to **both** hosts (Sender and Receiver).

### 2.1. Kernel Tuning (Sysctl)

The commands below increase TCP queue and buffer sizes.

*What these parameters do:*

* `net.core.netdev_max_backlog`: The queue of packets received by the card but not yet processed by the kernel. Critical for 10G+; otherwise, packets will be dropped during traffic spikes.
* `rmem_max` / `wmem_max`: Maximum read/write socket buffer sizes.
* `tcp_window_scaling`: Allows the TCP window to grow beyond 64KB (necessary for high-speed networks).

```bash
# Apply settings on the fly
sysctl -w net.core.netdev_max_backlog=30000
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.core.rmem_default=134217728
sysctl -w net.core.wmem_default=134217728
sysctl -w net.core.optmem_max=20480

# TCP stack tuning (IPv4)
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"
sysctl -w net.ipv4.tcp_window_scaling=1
sysctl -w net.ipv4.tcp_timestamps=1
sysctl -w net.ipv4.tcp_sack=1

```

### 2.2. Network Interface Configuration

Setting IP addresses, enabling Jumbo Frames, and hardware offloading.

*What these parameters do:*

* `mtu 9000`: Enables Jumbo Frames. Important: MTU must be identical on both ends of the link and on all intermediate switches.
* `tso on` (TCP Segmentation Offload): The card itself handles splitting large data into TCP segments.
* `gso on` (Generic Segmentation Offload): Similar to TSO, but more generic.
* `sg on` (Scatter-Gather): Allows the card to work with fragmented memory, which is required for TSO/GSO.

**On Host 1 (Example):**

```bash
# Interface 1
ip addr add 10.0.20.20/24 dev enP5p1s0f0
ip link set enP5p1s0f0 up
ip link set dev enP5p1s0f0 mtu 9000
ethtool -K enP5p1s0f0 tso on gso on sg on

# Interface 2
ip addr add 10.0.21.21/24 dev enP5p1s0f1
ip link set enP5p1s0f1 up
ip link set dev enP5p1s0f1 mtu 9000
ethtool -K enP5p1s0f1 tso on gso on sg on

```

**On Host 2 (Example):**

```bash
# Interface 1 (peer)
ip addr add 10.0.20.30/24 dev eth2
ip link set eth2 up
ip link set dev eth2 mtu 9000
ethtool -K eth2 tso on gso on sg on

# Interface 2 (peer)
ip addr add 10.0.21.31/24 dev eth6
ip link set eth6 up
ip link set dev eth6 mtu 9000
ethtool -K eth6 tso on gso on sg on

```

### 2.3. Firewall Configuration

Incoming traffic must be allowed for the test.

```bash
# If using iptables
iptables -A INPUT -i eth2 -j ACCEPT
iptables -A INPUT -i eth6 -j ACCEPT
# Or disable the firewall entirely during testing (systemctl stop firewalld / ufw disable)

```

---

## 3. Conducting the Test

### 3.1. Link Status Check

Before starting the load, ensure the physical link is up and parameters are negotiated.

```bash
# Check speed, duplex, and auto-negotiation
ethtool enP5p1s0f0 | egrep "Speed|Duplex|Auto-neg|Link detected"

# Check SFP module physical parameters (TX/RX power, temperature)
# IMPORTANT: Monitor RX power. Low levels indicate a poor cable or dirty optics.
ethtool -m enP5p1s0f0

```

### 3.2. Monitoring (In a separate terminal)

Watch for errors in real-time during the test. An increase in `drop` or `errors` counters indicates issues.

```bash
# Clear statistics before testing (some drivers may not support this)
ethtool -S enP5p1s0f0 > /dev/null 

# Monitoring
watch -n 1 "ethtool -S enP5p1s0f0 | grep -E 'err|drop|loss|crc|fail'"

```

**Monitoring both interfaces simultaneously:**

```bash
watch -n 1 "echo '--- SENDER ---'; ethtool -S enP5p1s0f0 | grep -E 'err|drop|loss|missed|crc'; echo ''; echo '--- RECEIVER ---'; ethtool -S enP5p1s0f1 | grep -E 'err|drop|loss|missed|crc'"

```

### 3.3. Running Iperf3 (Load)

**On the Server (Receiving side - Host 1):**

```bash
iperf3 -s

```

**On the Client (Generating side - Host 2):**

```bash
# -c: Server IP
# -t: Test duration (30 sec)
# -P: Number of parallel streams (critical for saturating the channel)
# -R: Reverse mode (Server sends, Client receives - reverse direction test)
iperf3 -c 10.0.20.20 -t 30 -P 4

```

*Recommendation:* Run tests in both directions (with and without the `-R` flag), as TX and RX performance can differ.

---

## 4. Advanced Diagnostics (Missing Commands)

The initial notes lacked important commands for deep analysis, especially if the speed is lower than expected.

### 4.1. NUMA Node Binding (CPU Affinity)

For 40G/100G speeds, it is critical that the testing process runs on the same physical CPU to which the NIC's PCIe bus is connected.

1. Find the NUMA node of the card:

```bash
cat /sys/class/net/enP5p1s0f0/device/numa_node

```

*(If output is -1, the system does not see NUMA or you have a single CPU).*

2. Run iperf with core binding (e.g., if the card is on node 1):

```bash
# Server binding
numactl --cpunodebind=1 iperf3 -s

# Client binding
numactl --cpunodebind=1 iperf3 -c 10.0.20.20 -t 30 -P 4

```

### 4.2. Flow Control Check (Pause Frames)

If the card receives "Pause Frames," it means the receiver or the switch is asking to "slow down." This kills performance.

```bash
ethtool -a enP5p1s0f0
ethtool -S enP5p1s0f0 | grep -i pause

```

### 4.3. PCIe Link Width Check

Ensure the card is seated in a slot at the required speed (e.g., x8 Gen3 or Gen4). If the card runs in x4 or Gen1 mode, it will not reach full speed.

```bash
# LnkCap - capabilities, LnkSta - current status.
# Speed and Width should match or be close to maximum.
lspci -s 05:01:00.0 -vv | grep -E "LnkCap|LnkSta"

```

### 4.4. Protocol Statistics (Softnet)

Check if the kernel is dropping packets due to CPU overload (net_rx_action).

```bash
# Look at the 2nd and 3rd columns. If values increase during the test, there is a CPU shortage.
cat /proc/net/softnet_stat

```

### 4.5. CRC Errors and Physics (Extended dmesg)

AER (Advanced Error Reporting) errors in kernel logs point to issues with the PCIe bus or the card itself.

```bash
dmesg -T | grep -E -i "aer|pcie|warn|error|fault|eth"

```

### 4.6. Per-Core CPU Load Check

During the test, it is important to see if any single core is hitting 100% (especially `si` - softirq).

```bash
htop
# or
mpstat -P ALL 1

```

---

## 5. Results Checklist

1. **Speed:** Is it close to the theoretical maximum (for 10G ≈ 9.4-9.9 Gbit/s considering overhead)?
2. **Retransmits (Retr):** In the iperf output, the `Retr` field should be 0 or minimal. A high number indicates packet loss.
3. **Drops/Errors:** `ethtool -S` output should not show an increase in `rx_crc_errors` (damaged cable/SFP) or `rx_missed_errors` (buffer/performance shortage).
4. **Temperature:** SFP module temperature (`ethtool -m`) does not exceed the threshold (typically 70°C).

---

# Addendum: Aggregated Bandwidth Load Testing (Dual-Link / Multi-Interface)

This section describes the standard practice for verifying the PCIe bus limit, CPU interrupt handling capabilities, and the maximum throughput of the network adapter (NIC) when using multiple ports simultaneously.

## 1. Testing Principle

**Goal:** To check the total throughput of two or more physical links simultaneously to reveal:

1. **PCIe Bus Limitations:** Whether the slot bandwidth is sufficient for dual streams.
2. **CPU Bottlenecks:** Problems with interrupt distribution (NUMA balancing) or single-core saturation.
3. **Thermal Issues:** Mutual heating of SFP modules when adjacent ports are fully loaded.

**Why not use Bonding/LACP?**
For pure hardware load testing, it is **not recommended** to combine interfaces into a logical Bond (LACP/Bonding) via the OS.
*Reason:* With Bonding, a single TCP stream from one `iperf3` process will still be hashed to only one physical cable.
*Best Strategy:* **Parallel Subnets.** We configure each port in its own unique subnet and run parallel `iperf3` processes pinned to specific CPU cores.

## 2. Test Architecture

Instead of bonding, we isolate the traffic. This guarantees that traffic flows strictly over the assigned physical lines and allows for even CPU loading.

**Addressing Scheme (Example):**

| Link | Sender Interface | Sender IP | Receiver Interface | Receiver IP | Subnet |
| --- | --- | --- | --- | --- | --- |
| **Link A** | `enP5p1s0f0` | `10.0.20.20` | `eth2` | `10.0.20.30` | `10.0.20.0/24` |
| **Link B** | `enP5p1s0f1` | `10.0.21.21` | `eth6` | `10.0.21.31` | `10.0.21.0/24` |

---

## 3. System Preparation

### 3.1. Kernel Tuning (Sysctl)

Apply the global system settings on both hosts as described in the main instruction.

```bash
# Execute on both hosts
sysctl -w net.core.netdev_max_backlog=30000
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.core.optmem_max=20480
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"
sysctl -w net.ipv4.tcp_window_scaling=1

```

### 3.2. Interface Configuration

Use the `net_tune.sh` script from **Appendix A** (main instruction) for each interface individually using the distinct subnets.

**On Host 1 (Sender):**

```bash
# Configure Port 1 (Subnet 10.0.20.x)
./net_tune.sh enP5p1s0f0 10.0.20.20/24

# Configure Port 2 (Subnet 10.0.21.x)
./net_tune.sh enP5p1s0f1 10.0.21.21/24

```

**On Host 2 (Receiver):**

```bash
# Configure Port 1 (Peer)
./net_tune.sh eth2 10.0.20.30/24

# Configure Port 2 (Peer)
./net_tune.sh eth6 10.0.21.31/24

```

---

## 4. Running the Test (Parallel Streams)

To saturate two channels, we must run two instances of `iperf3` simultaneously. To avoid conflicts, we bind them to specific IPs and use different ports (e.g., 5201 and 5202).

### 4.1. Starting Servers (Receiver - Host 2)

Launch two servers, each "listening" on its specific IP.

```bash
# Server 1: Listens on Link A IP, port 5201
iperf3 -s -B 10.0.20.30 -p 5201 --daemon --logfile server1.log

# Server 2: Listens on Link B IP, port 5202
iperf3 -s -B 10.0.21.31 -p 5202 --daemon --logfile server2.log

```

*The `--daemon` flag runs the process in the background. Logs are written to files.*

### 4.2. Starting Clients (Sender - Host 1) - **Crucial: CPU Affinity**

When testing 40G/100G, it is critical to separate `iperf3` processes onto different CPU cores. Otherwise, one core will become a bottleneck for two powerful streams (softirq saturation).

1. **Check NUMA nodes:**
```bash
cat /sys/class/net/enP5p1s0f0/device/numa_node

```


2. **Launch with `taskset`:**
If both cards are on the same NUMA node (e.g., 0), bind the first test to cores 1-4 and the second to cores 5-8.

```bash
# Test 1: Traffic to 10.0.20.30 (via Link A)
# Bind to cores 1-4
taskset -c 1-4 iperf3 -c 10.0.20.30 -p 5201 -B 10.0.20.20 -t 60 -P 4 --logfile client1.log &

# Test 2: Traffic to 10.0.21.31 (via Link B)
# Bind to cores 5-8 (to avoid interference)
taskset -c 5-8 iperf3 -c 10.0.21.31 -p 5202 -B 10.0.21.21 -t 60 -P 4 --logfile client2.log &

```

### 4.3. Monitoring Total Throughput

Since `iperf3` logs are separate, use system tools to see the aggregate speed.

**Option A: Using `dstat` (Recommended for total view)**

```bash
# Install dstat if missing: apt install dstat / yum install dstat
# View total traffic across all interfaces
dstat -net

```

*You should see the sum of speeds (e.g., with two 10G links, "recv" or "send" should be ~20G).*

**Option B: Using `ethtool` for errors**

```bash
watch -n 1 "echo '=== LINK 1 ==='; ethtool -S enP5p1s0f0 | grep -E 'err|drop|loss|crc'; echo ''; echo '=== LINK 2 ==='; ethtool -S enP5p1s0f1 | grep -E 'err|drop|loss|crc'"

```

---

## 5. Aggregation Diagnostics and Troubleshooting

Issues often arise under simultaneous load that are invisible on a single port.

### 5.1. PCIe Bus Width Check

If ports yield 10G individually, but only ~14G combined (instead of 20G), the issue is likely the PCIe slot.

* **10G Dual:** Requires PCIe Gen2 x8 or Gen3 x4.
* **25G/40G Dual:** Requires PCIe Gen3 x16 or Gen4.

```bash
# Check status (LnkSta) vs Capability (LnkCap)
lspci -vv | grep -E "LnkCap|LnkSta"
# Or check the device tree
lspci -tv

```

### 5.2. Interrupt Overlap (IRQ Balance)

Ensure queues from different NICs are handled by different CPU cores. If `htop` shows one Core at 100% `si` (softirq), the adapters are "sitting" on the same core.

```bash
# Check interrupts for interfaces
cat /proc/interrupts | grep enP5p1s0f0
cat /proc/interrupts | grep enP5p1s0f1

```

*Solution:* Run `systemctl start irqbalance` or manually distribute IRQs.

### 5.3. Thermal Check (Mutual Heating)

SFP modules heat each other up. Monitor this during the test:

```bash
# Display temperature for both ports side-by-side
paste <(ethtool -m enP5p1s0f0 | grep Temper) <(ethtool -m enP5p1s0f1 | grep Temper)

```

---

### Appendix B: Bulk Launch Script (`run_dual_test.sh`)

Create this script on Host 1 (Sender) to automate the parallel launch.

```bash
#!/bin/bash
# Description: Automated Dual-Link Iperf3 Test

# Target Settings (Receiver IPs)
TARGET_IP_1="10.0.20.30" # Host 2 IP on Link A
TARGET_IP_2="10.0.21.31" # Host 2 IP on Link B

# Source Bindings (Sender IPs) - Optional but recommended
SOURCE_IP_1="10.0.20.20"
SOURCE_IP_2="10.0.21.21"

TIME=60
THREADS=4

echo "====================================================="
echo "Starting Dual-Link Test (Total Bandwidth)"
echo "Link A: $SOURCE_IP_1 -> $TARGET_IP_1 (Port 5201)"
echo "Link B: $SOURCE_IP_2 -> $TARGET_IP_2 (Port 5202)"
echo "====================================================="

# Start first stream in background (Cores 1-4)
taskset -c 1-4 iperf3 -c $TARGET_IP_1 -B $SOURCE_IP_1 -p 5201 -t $TIME -P $THREADS > result_link_A.txt 2>&1 &
PID1=$!

# Start second stream in background (Cores 5-8)
taskset -c 5-8 iperf3 -c $TARGET_IP_2 -B $SOURCE_IP_2 -p 5202 -t $TIME -P $THREADS > result_link_B.txt 2>&1 &
PID2=$!

echo "Tests running. PIDs: $PID1, $PID2"
echo "Waiting for completion ($TIME sec)..."
wait $PID1
wait $PID2

echo "====================================================="
echo "RESULTS:"
echo "--- Link A (Sender) ---"
grep "sender" result_link_A.txt | tail -n 1
echo "--- Link B (Sender) ---"
grep "sender" result_link_B.txt | tail -n 1
echo "====================================================="

```


### Appendix A: Network Interface Initialization Script (`net_tune.sh`)

Below is a universal Bash script that automates the configuration process. It combines kernel tuning, IP addressing, MTU setup, and hardware offloading.

The script is designed to be run on any host (Sender or Receiver) by simply changing the arguments.

Save this code to a file, e.g., `net_tune.sh`, and make it executable: `chmod +x net_tune.sh`.

```bash
#!/bin/bash

# ==============================================================================
# SFP/10G+ Network Interface Tuning Script
# Description: Script to prepare an interface for load testing.
#              Applies sysctl settings, MTU, IP, and Offloading.
#
# Usage:       ./net_tune.sh <INTERFACE_NAME> <IP_ADDRESS_CIDR>
# Example:     ./net_tune.sh enP5p1s0f0 10.0.20.20/24
# ==============================================================================

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

# Check arguments
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <interface> <IP-address/mask>"
    echo "Example: $0 eth2 192.168.100.2/24"
    exit 1
fi

IFACE=$1
IP_CIDR=$2

# Check if interface exists
if [ ! -d "/sys/class/net/$IFACE" ]; then
    echo "Error: Interface $IFACE not found in the system."
    exit 1
fi

echo "============================================================"
echo " STARTING CONFIGURATION FOR INTERFACE: $IFACE"
echo "============================================================"

# ------------------------------------------------------------------------------
# 1. Kernel Tuning (Sysctl)
# ------------------------------------------------------------------------------
echo "[1/4] Applying Sysctl parameters (Kernel Tuning)..."

# Increase the incoming packet queue at the driver level
sysctl -w net.core.netdev_max_backlog=30000 > /dev/null

# Increase maximum socket buffer sizes (OS)
sysctl -w net.core.rmem_max=134217728 > /dev/null
sysctl -w net.core.wmem_max=134217728 > /dev/null
sysctl -w net.core.rmem_default=134217728 > /dev/null
sysctl -w net.core.wmem_default=134217728 > /dev/null
sysctl -w net.core.optmem_max=20480 > /dev/null

# TCP stack tuning (IPv4)
# Low / Pressure / High thresholds
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" > /dev/null
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" > /dev/null

# Enable window scaling and SACK
sysctl -w net.ipv4.tcp_window_scaling=1 > /dev/null
sysctl -w net.ipv4.tcp_timestamps=1 > /dev/null
sysctl -w net.ipv4.tcp_sack=1 > /dev/null

# Disable reverse path filtering (useful for tests to avoid routing issues)
sysctl -w net.ipv4.conf.all.rp_filter=0 > /dev/null
sysctl -w net.ipv4.conf.$IFACE.rp_filter=0 > /dev/null

echo "      -> Kernel parameters applied."

# ------------------------------------------------------------------------------
# 2. IP and MTU Configuration
# ------------------------------------------------------------------------------
echo "[2/4] Configuring IP address and MTU..."

# Flush old IP addresses on the interface (to avoid conflicts)
ip addr flush dev $IFACE

# Set new IP
ip addr add $IP_CIDR dev $IFACE
if [ $? -eq 0 ]; then
    echo "      -> IP address $IP_CIDR set."
else
    echo "      -> ERROR setting IP address."
    exit 1
fi

# Bring interface up
ip link set $IFACE up

# Set Jumbo Frames (MTU 9000)
# IMPORTANT: Ensure the switch between hosts also supports MTU 9000
ip link set dev $IFACE mtu 9000
if [ $? -eq 0 ]; then
    echo "      -> MTU set to 9000 (Jumbo Frames)."
else
    echo "      -> ERROR: Could not set MTU 9000. Check driver support."
fi

# ------------------------------------------------------------------------------
# 3. Offloading Configuration (CPU Offload)
# ------------------------------------------------------------------------------
echo "[3/4] Enabling hardware offloading..."

# TSO: TCP Segmentation Offload
# GSO: Generic Segmentation Offload
# SG:  Scatter-Gather
# GRO: Generic Receive Offload
ethtool -K $IFACE tso on gso on sg on gro on > /dev/null 2>&1

echo "      -> TSO, GSO, SG, GRO activated."

# ------------------------------------------------------------------------------
# 4. Diagnostics and Verification
# ------------------------------------------------------------------------------
echo "[4/4] Status Verification..."
echo "------------------------------------------------------------"

# Output NUMA node info (important for process binding)
if [ -f "/sys/class/net/$IFACE/device/numa_node" ]; then
    NUMA_NODE=$(cat /sys/class/net/$IFACE/device/numa_node)
    echo "INFO: Interface bound to NUMA Node: $NUMA_NODE"
    echo "      (Use 'numactl --cpunodebind=$NUMA_NODE' to run iperf3)"
else
    echo "INFO: NUMA Node not defined."
fi

# Check link
LINK_STATUS=$(ethtool $IFACE | grep "Link detected" | awk '{print $3}')
SPEED=$(ethtool $IFACE | grep "Speed" | awk '{print $2}')
DUPLEX=$(ethtool $IFACE | grep "Duplex" | awk '{print $2}')

echo "INFO: Link status:   $LINK_STATUS"
echo "INFO: Speed:         $SPEED"
echo "INFO: Duplex:        $DUPLEX"
echo "INFO: Current MTU:   $(cat /sys/class/net/$IFACE/mtu)"

echo "------------------------------------------------------------"
echo "Done. Ready to run tests."
echo ""
echo "Command for error monitoring:"
echo "watch -n 1 \"ethtool -S $IFACE | grep -E 'err|drop|loss'\""
echo "============================================================"

```

---

### How to use this script

1. **On Host 1 (e.g., Server):**

```bash
# Configure interface enP5p1s0f0 with address 10.0.20.20
./net_tune.sh enP5p1s0f0 10.0.20.20/24

# After successful execution, run iperf server
# (Assuming the script identified NUMA Node: 0)
numactl --cpunodebind=0 iperf3 -s

```

2. **On Host 2 (e.g., Client):**

```bash
# Configure interface eth2 with address 10.0.20.30
./net_tune.sh eth2 10.0.20.30/24

# Run the test
# (Assuming the script identified NUMA Node: 1)
numactl --cpunodebind=1 iperf3 -c 10.0.20.20 -t 30 -P 4

```

---
