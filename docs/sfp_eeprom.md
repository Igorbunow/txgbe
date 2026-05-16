Here is the English version of the guide for reading SFP EEPROM data, decoded diagnostics (signal levels, temperature, etc.), and raw hex dumps using `ethtool`.

### How to Read SFP EEPROM Data (Decoded and Raw) and Signal Levels

The standard Linux utility `ethtool` with the `-m` (--dump-module-eeprom) option is used to access SFP/SFP+ module data. It can provide both a raw hex dump and a human-readable decoded output (including DOM diagnostics like TX/RX power, temperature, voltage, and bias current).

---

### 1. Decoded Output (Signal Levels, Temperature, etc.)

This is the easiest way to get a human-readable report, including all digital diagnostic monitoring (DOM) data if the module supports it.

```bash
sudo ethtool -m <interface_name>
```

**Example Output (SFP with DOM support):**

```text
        Vendor SN                                 : F2220644072
        Date code                                 : 220824
        Optical diagnostics support               : Yes
        Laser bias current                        : 6.000 mA
        Laser output power                        : 0.5000 mW / -3.01 dBm
        Receiver signal average optical power     : 0.4000 mW / -3.98 dBm
        Module temperature                        : 50.41 degrees C / 122.75 degrees F
        Module voltage                            : 3.2811 V
        Alarm/warning flags implemented           : Yes
        Laser bias current high alarm threshold   : 15.000 mA
...
```

**Note:** If you don't see diagnostics (temperature, power, etc.), the module either does not support DOM or is a passive DAC cable.

---

### 2. Raw EEPROM Dump (Hexadecimal View)

To get the raw byte-by-byte data (useful for debugging or working with SFF-8472/SFF-8636 specifications), use the `raw on` and `hex on` options.

```bash
sudo ethtool -m <interface_name> raw on hex on
```

**Example Output:**

```text
Offset          Values

0x0000:         03 04 00 00 00 00 01 00 00 00 00 01 0d 00 00 00
0x0010:         00 00 00 00 46 53 20 20 20 20 20 20 20 20 00 00
0x0020:         00 00 00 00 47 53 46 50 2d 31 47 2d 54 58 20 20
...
```

*   `Offset` — byte offset from the start of EEPROM.
*   `Values` — hexadecimal byte values. Decoding requires the SFF-8472 (for SFP) or SFF-8636 (for QSFP) specification.

---

### 3. Partial Dump / Reading a Specific Range

If you only need a portion of the EEPROM (e.g., vendor name starting at offset `0x14`), use `offset` and `length`.

```bash
sudo ethtool -m eth0 offset 0x14 length 32
```

This will print 32 bytes starting from offset 0x14. In many SFP modules, this range contains the vendor name string.

---

### 4. Modern Modules (CMIS – 400G and above)

Modern high-speed modules (400G/800G) use the CMIS (Common Management Interface Specification) standard. Recent versions of `ethtool` and the Linux kernel can read telemetry from these modules using the same command:

```bash
sudo ethtool -m eth0
```

No special flags are needed — the tool automatically detects the memory map type.

---

### Common Problems and Solutions

| Problem | Likely Cause | Solution |
| :--- | :--- | :--- |
| **No temperature/power information** | Module does not support DOM (Digital Optical Monitoring) | Check module specs. Passive DACs also lack diagnostics. |
| **Output looks like raw hex/gibberish instead of nice text** | `ethtool` was compiled without decoding support (common in embedded systems like OpenWrt) | Install full version: `apt install ethtool` (Debian) or `opkg install ethtool-full` (OpenWrt) |
| **Permission denied** | Access to hardware diagnostics requires root privileges | Always use `sudo` |
| **Command not found** | ethtool is not installed | Install it: `sudo apt install ethtool` (Debian/Ubuntu), `sudo yum install ethtool` (RHEL/CentOS) |

---

### Quick Reference: ethtool -m Options

| Option | Purpose | Example |
| :--- | :--- | :--- |
| **`-m`** | Main command for SFP/QSFP module EEPROM access | `ethtool -m eth0` |
| **`raw on`** | Output raw binary data (use with `hex on`) | `ethtool -m eth0 raw on hex on` |
| **`hex on`** | Display values in hexadecimal format | `ethtool -m eth0 hex on` |
| **`offset N`** | Start reading at byte offset `N` (decimal) | `ethtool -m eth0 offset 64` |
| **`length N`** | Read `N` bytes | `ethtool -m eth0 length 128` |
| **`page N`** | Read a specific EEPROM page (advanced, for SFF-8472) | `ethtool -m eth0 page 0x03` |

---

### Alternative Tools (if ethtool is not available)

On very minimal systems, you can sometimes read the EEPROM directly via sysfs (if enabled in the kernel/driver):

```bash
# For some drivers (e.g., ixgbe, mlx5), the EEPROM may appear as a file
hexdump -C /sys/class/net/eth0/device/eeprom
```

However, `ethtool -m` is the standard, cross-driver method and is strongly recommended over direct sysfs access.
