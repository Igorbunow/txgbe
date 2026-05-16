# Load Testing for Aggregated Bandwidth (Multi-Interface)

[ English ](sfp_performance_test.md) | [ Русский ](sfp_performance_test_ru.md)

**Goal:** Verify the total throughput of two or more physical links simultaneously to identify PCIe bus limitations, adapter overheating, or CPU interrupt distribution issues.

## 1. Test Architecture

Instead of bonding interfaces into one logical one, we use **subnet separation**. This ensures that traffic goes strictly through the assigned physical lines and allows for even loading of all CPU cores.

**Addressing Scheme (Example):**

| Link | Host 1 (Sender) Interface | Host 1 IP | <---> | Host 2 (Receiver) Interface | Host 2 IP | Subnet |
| --- | --- | --- | --- | --- | --- | --- |
| **Link A** | `enP5p1s0f0` | `10.0.1.1` | <---> | `eth2` | `10.0.1.2` | 10.0.1.0/24 |
| **Link B** | `enP5p1s0f1` | `10.0.2.1` | <---> | `eth6` | `10.0.2.2` | 10.0.2.0/24 |

---

## 2. System Preparation

### 2.1. Kernel Tuning (Sysctl)

The same settings as in the original instructions apply. They are global for the entire OS.

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

### 2.2. Interface Configuration (using `net_tune.sh`)

Use the script from Appendix A of the original instructions, but run it for each interface with **different** subnets.

**On Host 1 (Sender):**

```bash
# Configure first port (Subnet 10.0.1.x)
./net_tune.sh enP5p1s0f0 10.0.1.1/24

# Configure second port (Subnet 10.0.2.x)
./net_tune.sh enP5p1s0f1 10.0.2.1/24
```

**On Host 2 (Receiver):**

```bash
# Configure first port (opposite part)
./net_tune.sh eth2 10.0.1.2/24

# Configure second port (opposite part)
./net_tune.sh eth6 10.0.2.2/24
```

---

## 3. Running the Test (Parallel Streams)

To load two channels, we need to run **two instances** of iperf3 simultaneously. To avoid conflict, we use different TCP ports (e.g., 5201 and 5202).

### 3.1. Starting Servers (On Host 2 - Receiver)

Run two servers, each "listening" on its port. You can bind (`-B`) them to specific IPs for reliability.

```bash
# Server for Link A (port 5201)
iperf3 -s -B 10.0.1.2 -p 5201 &

# Server for Link B (port 5202)
iperf3 -s -B 10.0.2.2 -p 5202 &
```

### 3.2. Starting Clients (On Host 1 - Sender)

Run the tests simultaneously in the background.

**Important about CPU Affinity:**
If you are testing 40G/100G, it is critical to distribute iperf3 processes across different CPU cores, otherwise one core will become a bottleneck for two powerful streams.

```bash
# Option 1: Simple run (if speeds are up to 20G total)
iperf3 -c 10.0.1.2 -p 5201 -t 60 -P 4 &  # Link A test
iperf3 -c 10.0.2.2 -p 5202 -t 60 -P 4 &  # Link B test

# Option 2: With core affinity (MANDATORY for 40G/100G)
# Suppose the card is on NUMA node 0. Bind the first test to cores 0-7, the second to 8-15.
taskset -c 1-4 iperf3 -c 10.0.1.2 -p 5201 -t 60 -P 4 &
taskset -c 5-8 iperf3 -c 10.0.2.2 -p 5202 -t 60 -P 4 &
```

### 3.3. Monitoring Total Speed

In a separate terminal (on any host), it's convenient to use `dstat` or `sar` to view the total network load, as iperf3 will output logs in a mixed fashion.

```bash
# Install dstat (if not present)
# apt install dstat / yum install dstat

# View total traffic for all interfaces
dstat -net
```

*You should see the sum of the speeds (for example, with two 10G links you will see "recv" or "send" around 20G).*

---

## 4. Bottleneck Diagnostics During Aggregation

When loaded simultaneously, problems often arise that are not visible on a single port.

### 4.1. Checking PCIe Bus Width

If the ports individually output 10G, but together only 14G (instead of 20G), the problem is most likely in the PCIe slot.

```bash
# Check status (LnkSta) for both devices or for the root bridge
lspci -vv | grep -E "LnkCap|LnkSta"
```

*For two 10G ports, PCIe Gen2 x8 or Gen3 x4 is sufficient. For two 25G/40G, Gen3 x16 or Gen4 is required.*

### 4.2. Interrupt Overlap (IRQ Balance)

Ensure that the queues of different network cards are processed by different CPU cores.

```bash
# View interrupts for a specific interface
cat /proc/interrupts | grep enP5p1s0f0
cat /proc/interrupts | grep enP5p1s0f1
```

If you see that both interfaces are "bombing" the same CPU core (CPU0) with interrupts, you need to start `irqbalance` or distribute them manually:

```bash
systemctl start irqbalance
```

---

## Appendix B: Bulk Launch Script (`run_dual_test.sh`)

Create this script on Host 1 (Sender) to automate the launch.

```bash
#!/bin/bash

# Target settings
TARGET_IP_1="10.0.1.2" # Host 2 IP on link A
TARGET_IP_2="10.0.2.2" # Host 2 IP on link B
TIME=60
THREADS=4

echo "====================================================="
echo "Running Dual-Link test (Total Bandwidth)"
echo "Link A: -> $TARGET_IP_1 (Port 5201)"
echo "Link B: -> $TARGET_IP_2 (Port 5202)"
echo "====================================================="

# Run the first stream in the background (cores 1-4)
taskset -c 1-4 iperf3 -c $TARGET_IP_1 -p 5201 -t $TIME -P $THREADS > result_link_A.txt 2>&1 &
PID1=$!

# Run the second stream in the background (cores 5-8)
taskset -c 5-8 iperf3 -c $TARGET_IP_2 -p 5202 -t $TIME -P $THREADS > result_link_B.txt 2>&1 &
PID2=$!

echo "Tests started. PIDs: $PID1, $PID2"
echo "Waiting for completion ($TIME sec)..."

wait $PID1
wait $PID2

echo "====================================================="
echo "RESULTS:"
echo "--- Link A ---"
grep "sender" result_link_A.txt | tail -n 1
echo "--- Link B ---"
grep "sender" result_link_B.txt | tail -n 1
echo "====================================================="
```
