# Firewall Configuration for Network Testing

[ English ](FIREWALL.md) | [ Русский ](FIREWALL_ru.md)

When performing network performance tests (e.g., using `iperf3`), the system firewall may block traffic or introduce latency. This document describes how to configure `iptables` and `nftables` to allow testing traffic.

## 1. iptables

To allow traffic on specific interfaces (e.g., `eth2` and `eth6`):

```bash
# Allow all traffic on specific interfaces
iptables -A INPUT -i eth2 -j ACCEPT
iptables -A INPUT -i eth6 -j ACCEPT

# Or allow specific iperf3 ports (default is 5201)
iptables -A INPUT -p tcp --dport 5201 -j ACCEPT
iptables -A INPUT -p udp --dport 5201 -j ACCEPT
```

To view current rules:
```bash
iptables -L -n -v
```

To clear rules (use with caution):
```bash
iptables -F
```

---

## 2. nftables

`nftables` is the successor to `iptables`.

To allow traffic on specific interfaces:

```bash
# Create a rule to accept traffic on eth2 and eth6
nft add rule inet filter input iifname "eth2" accept
nft add rule inet filter input iifname "eth6" accept

# Or allow specific iperf3 ports
nft add rule inet filter input tcp dport 5201 accept
nft add rule inet filter input udp dport 5201 accept
```

To view current ruleset:
```bash
nft list ruleset
```

---

## 3. Temporary Disabling (for Lab Testing)

In a controlled lab environment, you may choose to disable the firewall service entirely during testing:

**firewalld (RHEL/CentOS/Fedora):**
```bash
systemctl stop firewalld
```

**ufw (Ubuntu/Debian):**
```bash
ufw disable
```

---

## 4. Common Problems

### Symptom: iperf3 "Connection refused" or "No route to host"
- **Cause:** Firewall is blocking the port or the ICMP "destination unreachable" message is sent.
- **Fix:** Ensure the server-side firewall allows the port and the client-side firewall allows return traffic.

### Symptom: Throughput is lower than expected
- **Cause:** Firewall connection tracking (`conntrack`) can consume CPU cycles.
- **Fix:** Bypass connection tracking for testing traffic:
  ```bash
  iptables -t raw -A PREROUTING -i eth2 -j NOTRACK
  iptables -t raw -A OUTPUT -o eth2 -j NOTRACK
  ```
  (Repeat for other interfaces)
