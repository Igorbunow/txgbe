# Настройка Firewall для сетевого тестирования

[ English ](FIREWALL.md) | [ Русский ](FIREWALL_ru.md)

При выполнении тестов производительности сети (например, с использованием `iperf3`) системный брандмауэр (firewall) может блокировать трафик или вносить задержки. В этом документе описано, как настроить `iptables` и `nftables` для разрешения тестового трафика.

## 1. iptables

Чтобы разрешить трафик на определенных интерфейсах (например, `eth2` и `eth6`):

```bash
# Разрешить весь трафик на конкретных интерфейсах
iptables -A INPUT -i eth2 -j ACCEPT
iptables -A INPUT -i eth6 -j ACCEPT

# Или разрешить конкретные порты iperf3 (по умолчанию 5201)
iptables -A INPUT -p tcp --dport 5201 -j ACCEPT
iptables -A INPUT -p udp --dport 5201 -j ACCEPT
```

Просмотр текущих правил:
```bash
iptables -L -n -v
```

Очистка правил (используйте с осторожностью):
```bash
iptables -F
```

---

## 2. nftables

`nftables` является преемником `iptables`.

Чтобы разрешить трафик на определенных интерфейсах:

```bash
# Создать правило для приема трафика на eth2 и eth6
nft add rule inet filter input iifname "eth2" accept
nft add rule inet filter input iifname "eth6" accept

# Или разрешить конкретные порты iperf3
nft add rule inet filter input tcp dport 5201 accept
nft add rule inet filter input udp dport 5201 accept
```

Просмотр текущего набора правил:
```bash
nft list ruleset
```

---

## 3. Временное отключение (для лабораторных тестов)

В контролируемой лабораторной среде вы можете полностью отключить службу брандмауэра на время тестирования:

**firewalld (RHEL/CentOS/Fedora):**
```bash
systemctl stop firewalld
```

**ufw (Ubuntu/Debian):**
```bash
ufw disable
```

---

## 4. Распространенные проблемы

### Симптом: iperf3 "Connection refused" или "No route to host"
- **Причина:** Брандмауэр блокирует порт или отправляется сообщение ICMP "destination unreachable".
- **Решение:** Убедитесь, что брандмауэр на стороне сервера разрешает порт, а брандмауэр на стороне клиента разрешает обратный трафик.

### Симптом: Пропускная способность ниже ожидаемой
- **Причина:** Отслеживание соединений брандмауэра (`conntrack`) может потреблять ресурсы процессора.
- **Решение:** Обход отслеживания соединений для тестового трафика:
  ```bash
  iptables -t raw -A PREROUTING -i eth2 -j NOTRACK
  iptables -t raw -A OUTPUT -o eth2 -j NOTRACK
  ```
  (Повторите для других интерфейсов)
