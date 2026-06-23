# Raspberry Pi 5: OS & NVMe Boot

Hardware: Raspberry Pi 5 (8 GB RAM), M.2 HAT+, 256 GB NVMe SSD.

**OS: Raspberry Pi OS Lite (64-bit, Trixie)**
Ships all hardware tools natively: `raspi-config`, `vcgencmd`, `rpi-eeprom-update` — ideal for headless operation and future hardware adjustments.

---

## Overview

```
Flash Raspberry Pi OS to NVMe (from the laptop)
  → First boot: EEPROM update via rpi-eeprom-update
  → Configure OS (SSH, static IP, cgroups, disable swap)
  → Ready for k3s
```

---

## 1. Flash Raspberry Pi OS to NVMe

**On the laptop** (not on the Pi): write Raspberry Pi OS Lite (64-bit) to the NVMe using the **Raspberry Pi Imager**.

The NVMe must either be:
- connected to the laptop via a USB-NVMe adapter, or
- exposed as a USB device via `rpiboot` + USB cable directly from the Pi (requires the M.2 HAT+ in "flash mode")

In the Imager under "OS Customisation" configure **before flashing**:
- Hostname: `raspi` (or your preference)
- SSH: public key authentication, enter your SSH key
- Set username + password
- Wi-Fi: configure if needed, otherwise leave empty (server runs via Ethernet)
- Locale: `Europe/Berlin`, keyboard `de`

---

## 2. First boot: update EEPROM

```bash
ssh <user>@<ip-address>

# Update system and bootloader
sudo apt update && sudo apt full-upgrade -y
sudo rpi-eeprom-update -a
sudo reboot
```

After reboot, verify:
```bash
sudo rpi-eeprom-update
# Output should show: BOOTLOADER: up to date

# Current bootloader version and boot order
sudo rpi-eeprom-config | grep BOOT_ORDER
# Raspberry Pi 5 boots from NVMe by default if present (BOOT_ORDER=0xf461)
# If not: sudo raspi-config → Advanced → Boot Order → NVMe/USB Boot
```

---

## 3. OS base configuration

### Update the system

```bash
sudo apt install -y curl git vim htop iotop
```

### Set hostname (if not done in the Imager)

```bash
sudo hostnamectl set-hostname raspi
```

### Static IP

Raspberry Pi OS Trixie uses NetworkManager. Check the connection name:

```bash
nmcli con show
# Typically "Wired connection 1" or "eth0"
```

```bash
nmcli con mod "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses "<server-ip>/24" \
  ipv4.gateway "<gateway-ip>" \
  ipv4.dns "<gateway-ip> 1.1.1.1"   # Pi-hole or router as primary DNS

nmcli con up "Wired connection 1"
```

### Disable swap

k3s requires swap to be disabled. First check whether swap is even active:

```bash
free -h
swapon --show
```

If the swap line shows `0B` or `swapon` produces no output — nothing to do, proceed to the next step.

If swap is active, disable it according to the swap type:

```bash
# Option A: dphys-swapfile (older RPi OS versions / SD card)
sudo dphys-swapfile swapoff
sudo dphys-swapfile uninstall
sudo systemctl disable dphys-swapfile

# Option B: systemd swap file
sudo swapoff /var/swap      # or the path shown by "swapon --show"
sudo sed -i '/swap/d' /etc/fstab

# Option C: zram (Raspberry Pi OS Trixie)
# zram-generator cannot be disabled via systemctl disable.
# Most reliable solution: remove the package
sudo swapoff /dev/zram0
sudo apt remove systemd-zram-generator
sudo reboot
# After reboot: swapon --show → no output = done
```

### Enable cgroups for k3s

k3s requires cgroup memory. On Raspberry Pi OS Trixie, append the following to the **end of the single line** in `/boot/firmware/cmdline.txt` (no line break!):

> Tip in vim: `Shift+G` jumps to the last line, `A` switches to Append mode at the end of the line.

```
cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
```

Example of what the line should look like afterwards:
```
console=serial0,115200 console=tty1 root=PARTUUID=xxxx [...] cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
```

```bash
sudo reboot
```

After reboot, verify:
```bash
cat /sys/fs/cgroup/cgroup.controllers
# memory must appear in the output: "cpuset cpu io memory pids"
```

**Note:** `/proc/cmdline` also shows `cgroup_disable=memory` — this is automatically injected by the Raspberry Pi firmware bootloader and is not in `cmdline.txt`. This is not a problem: the Linux kernel processes parameters left to right, so `cgroup_enable=memory` at the end overrides the earlier `cgroup_disable=memory`. The only thing that matters is whether `memory` appears in `/sys/fs/cgroup/cgroup.controllers`.

### Firewall (ufw)

```bash
sudo apt install -y ufw
sudo ufw allow ssh
sudo ufw allow 6443/tcp    # k3s API server (kubectl from outside)
sudo ufw allow 8472/udp    # Flannel VXLAN (later for Agent-Nodes)
sudo ufw allow 10250/tcp   # kubelet metrics
sudo ufw enable
```

> Once a second node is added, additional ports may need to be opened (k3s agent communication: 6443, 8472/UDP for Flannel).

---

## 4. Reliability & diagnostics

### Persistent journal logging

Raspberry Pi OS ships a vendor drop-in that forces the systemd journal to be
**volatile** (RAM-only) to protect SD cards from wear:

```
/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf
[Journal]
Storage=volatile
```

Consequence: after a crash or hard reboot **all kernel/network logs are gone** —
post-mortem analysis is impossible. Since this node boots from NVMe (not an SD
card), wear is a non-issue and we want persistent logs.

Override it with a higher-numbered drop-in (drop-ins are applied in lexical
order, later wins — so `99-` beats `40-`):

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-persistent.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
Compress=yes
# Rotation/retention — caps NVMe usage
SystemMaxUse=500M
SystemKeepFree=1G
SystemMaxFileSize=50M
MaxRetentionSec=1month
EOF

sudo systemctl restart systemd-journald
sudo journalctl --flush
```

Verify (the last `Storage=` line wins, and a journal file must appear on disk):

```bash
sudo systemd-analyze cat-config systemd/journald.conf | grep -i 'Storage='
sudo find /var/log/journal -name 'system.journal'   # must list a file
journalctl --disk-usage
```

After this, `journalctl -b -1` shows the **previous** boot — i.e. the logs from
just before a crash.

### Network watchdog

The Pi 5 onboard NIC (`eth0`, `macb` driver, attached via RP1/PCIe) can in rare
cases drop external connectivity while the OS keeps running normally (containers,
local healthchecks all fine) — the symptom is "no ping, no SSH" requiring a hard
reset. This watchdog pings the default gateway every minute and escalates:
**3 failures → NIC reconnect, 6 failures → reboot**. All actions are logged to
the (now persistent) journal under tag `net-watchdog`.

```bash
sudo tee /usr/local/sbin/net-watchdog.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# net-watchdog: detect loss of external connectivity (eth0/macb).
# Escalation: 3 failures -> NIC reconnect, 6 -> reboot. Logs to journal.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

IFACE="eth0"
STATE=/run/net-watchdog.fails
SOFT_THRESHOLD=3
HARD_THRESHOLD=6
TAG=net-watchdog

log() { logger -t "$TAG" -- "$*"; }

GATEWAY="$(ip route | awk '/^default/{print $3; exit}')"
[ -z "${GATEWAY:-}" ] && GATEWAY=192.168.178.1

if ping -I "$IFACE" -c 3 -W 2 "$GATEWAY" >/dev/null 2>&1; then
    if [ -f "$STATE" ]; then
        log "Gateway $GATEWAY reachable again (after $(cat "$STATE") failures)."
        rm -f "$STATE"
    fi
    exit 0
fi

fails=0
[ -f "$STATE" ] && fails=$(cat "$STATE")
fails=$((fails + 1))
echo "$fails" > "$STATE"
log "Gateway $GATEWAY via $IFACE unreachable (failure $fails)."

if [ "$fails" -ge "$HARD_THRESHOLD" ]; then
    log "CRITICAL: $fails failures -> reboot."
    sync
    systemctl reboot
elif [ "$fails" -eq "$SOFT_THRESHOLD" ]; then
    log "WARNING: $fails failures -> NIC reconnect ($IFACE)."
    nmcli device reconnect "$IFACE" >/dev/null 2>&1 || { ip link set "$IFACE" down; sleep 2; ip link set "$IFACE" up; }
fi
exit 0
EOF
sudo chmod +x /usr/local/sbin/net-watchdog.sh

sudo tee /etc/systemd/system/net-watchdog.service >/dev/null <<'EOF'
[Unit]
Description=Network connectivity watchdog (eth0/macb)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/net-watchdog.sh
EOF

sudo tee /etc/systemd/system/net-watchdog.timer >/dev/null <<'EOF'
[Unit]
Description=Run network watchdog every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now net-watchdog.timer
```

Inspect:

```bash
systemctl list-timers net-watchdog.timer
journalctl -t net-watchdog          # only logs on failures/recovery
```

> The watchdog reboots on sustained gateway loss. If the gateway itself is down
> (router reboot, switch off) the node will reboot every ~6 min until the network
> returns — acceptable since the node is unreachable anyway in that state.

### Static DHCP lease

The node uses DHCP. To keep its IP stable, configure a **fixed lease /
reservation on the router** (FRITZ!Box: *Heimnetz → Netzwerk →* edit the node →
*"Always assign the same IPv4 address to this network device"*). This is
preferable to a hard-coded static IP on the node and rules out lease loss as a
cause of connectivity drops.

---

## 5. Final check

```bash
# OS version
cat /etc/os-release | grep PRETTY_NAME
# Should show: Debian GNU/Linux 13 (trixie)

# Kernel (64-bit?)
uname -m
# aarch64 = 64-bit ✓

# Disk
df -h /
# /dev/nvme0n1p2 as root, sufficient free space

# RAM
free -h
# ~7.x GB total, Swap: 0B

# cgroups active (memory must appear in the output)
cat /sys/fs/cgroup/cgroup.controllers

# Network
ip addr show eth0

# EEPROM up to date
sudo rpi-eeprom-update

# SSH key login works
# Disable password login:
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh
```

---

## Next: [Install k3s](./k3s-install.md)
