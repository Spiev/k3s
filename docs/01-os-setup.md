# 01 — Raspberry Pi 5: OS & NVMe-Boot

Hardware: Raspberry Pi 5 (8 GB RAM), M.2 HAT+, 256 GB NVMe SSD.

**OS: Raspberry Pi OS Lite (64-bit, Bookworm)**
Bringt alle Hardware-Tools nativ mit: `raspi-config`, `vcgencmd`, `rpi-eeprom-update` — ideal für Headless-Betrieb und spätere Hardware-Anpassungen.

---

## Überblick

```
Raspberry Pi OS auf NVMe flashen (vom Laptop)
  → Erster Boot: EEPROM-Update via rpi-eeprom-update
  → OS konfigurieren (SSH, statische IP, cgroups, Swap deaktivieren)
  → Bereit für k3s
```

---

## 1. Raspberry Pi OS auf NVMe flashen

**Auf dem Laptop** (nicht auf dem Pi): Raspberry Pi OS Lite (64-bit) mit dem **Raspberry Pi Imager** direkt auf die NVMe schreiben.

Die NVMe muss dazu entweder:
- per USB-NVMe-Adapter am Laptop angeschlossen sein, oder
- über `rpiboot` + USB-Kabel direkt vom Pi als USB-Gerät am Laptop erscheinen (erfordert das M.2 HAT+ im "flash mode")

Im Imager unter "OS Customisation" **vor dem Flashen** konfigurieren:
- Hostname: `raspi` (oder was du bevorzugst)
- SSH: Public-Key-Authentifizierung, deinen SSH-Key eintragen
- Benutzername + Passwort setzen
- WLAN: konfigurieren, wenn notwendig, sonst leer lassen (Server läuft per Ethernet)
- Locale: `Europe/Berlin`, Keyboard `de`

---

## 2. Erster Boot: EEPROM aktualisieren

```bash
ssh <user>@<ip-adresse>

# System + Bootloader auf aktuellen Stand bringen
sudo apt update && sudo apt full-upgrade -y
sudo rpi-eeprom-update -a
sudo reboot
```

Nach dem Neustart prüfen:
```bash
sudo rpi-eeprom-update
# Ausgabe sollte zeigen: BOOTLOADER: up to date

# Aktuelle Bootloader-Version und Boot-Reihenfolge
sudo rpi-eeprom-config | grep BOOT_ORDER
# Raspberry Pi 5 booted standardmäßig von NVMe wenn vorhanden (BOOT_ORDER=0xf461)
# Falls nicht: sudo raspi-config → Advanced → Boot Order → NVMe/USB Boot
```

---

## 3. OS-Grundkonfiguration

### System aktualisieren

```bash
sudo apt install -y curl git vim htop iotop
```

### Hostname setzen (falls nicht im Imager gemacht)

```bash
sudo hostnamectl set-hostname raspi
```

### Statische IP

Raspberry Pi OS Bookworm nutzt NetworkManager. Verbindungsname prüfen:

```bash
nmcli con show
# Typischerweise "Wired connection 1" oder "eth0"
```

```bash
nmcli con mod "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses "<server-ip>/24" \
  ipv4.gateway "<gateway-ip>" \
  ipv4.dns "<gateway-ip> 1.1.1.1"   # Pi-hole oder Router als primärer DNS

nmcli con up "Wired connection 1"
```

### Swap deaktivieren

k3s erfordert deaktivierten Swap. Erst prüfen ob überhaupt Swap aktiv ist:

```bash
free -h
swapon --show
```

Wenn die Swap-Zeile `0B` zeigt bzw. `swapon` keine Ausgabe liefert — nichts zu tun, weiter zum nächsten Schritt.

Falls Swap aktiv ist, je nach Swap-Variante deaktivieren:

```bash
# Variante A: dphys-swapfile (ältere RPi OS Versionen / SD-Karte)
sudo dphys-swapfile swapoff
sudo dphys-swapfile uninstall
sudo systemctl disable dphys-swapfile

# Variante B: systemd swap file
sudo swapoff /var/swap      # oder den Pfad aus "swapon --show"
sudo sed -i '/swap/d' /etc/fstab

# Variante C: zram (Raspberry Pi OS Bookworm)
# zram-generator kann nicht per systemctl disable deaktiviert werden.
# Zuverlässigste Lösung: Paket entfernen
sudo swapoff /dev/zram0
sudo apt remove systemd-zram-generator
sudo reboot
# Nach Neustart: swapon --show → keine Ausgabe = erledigt
```

### cgroups für k3s aktivieren

k3s benötigt cgroup memory. Auf Raspberry Pi OS Bookworm in `/boot/firmware/cmdline.txt` am **Ende der einzigen Zeile** (kein Zeilenumbruch!) ergänzen:

> Tipp in vim: `Shift+G` springt zur letzten Zeile, `A` wechselt in Append-Modus ans Zeilenende.

```
cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
```

Beispiel wie die Zeile danach aussehen sollte:
```
console=serial0,115200 console=tty1 root=PARTUUID=xxxx [...] cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
```

```bash
sudo reboot
```

Nach dem Neustart prüfen:
```bash
cat /sys/fs/cgroup/cgroup.controllers
# memory muss in der Ausgabe stehen: "cpuset cpu io memory pids"
```

**Hinweis:** In `/proc/cmdline` erscheint zusätzlich `cgroup_disable=memory` — das wird vom Raspberry Pi Firmware-Bootloader automatisch injiziert und steht nicht in `cmdline.txt`. Kein Problem: der Linux-Kernel verarbeitet Parameter von links nach rechts, `cgroup_enable=memory` am Ende überschreibt das frühere `cgroup_disable=memory`. Maßgeblich ist allein ob `memory` in `/sys/fs/cgroup/cgroup.controllers` auftaucht.

### Firewall (ufw)

```bash
sudo apt install -y ufw
sudo ufw allow ssh
sudo ufw allow 6443/tcp    # k3s API-Server (kubectl von außen)
sudo ufw allow 8472/udp    # Flannel VXLAN (später für Agent-Nodes)
sudo ufw allow 10250/tcp   # kubelet metrics
sudo ufw enable
```

> Longhorn benötigt zusätzliche Ports sobald ein zweiter Node hinzukommt — das kommt in einem späteren Schritt.

---

## 4. Abschluss-Check

```bash
# OS-Version
cat /etc/os-release | grep PRETTY_NAME
# Sollte Debian GNU/Linux 12 (bookworm) zeigen

# Kernel (64-bit?)
uname -m
# aarch64 = 64-bit ✓

# Disk
df -h /
# /dev/nvme0n1p2 als root, ausreichend freier Platz

# RAM
free -h
# ~7.x GB total, Swap: 0B

# cgroups aktiv (memory muss in der Ausgabe stehen)
cat /sys/fs/cgroup/cgroup.controllers

# Netzwerk
ip addr show eth0

# EEPROM aktuell
sudo rpi-eeprom-update

# SSH-Key-Login funktioniert
# Passwort-Login deaktivieren:
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh
```

---

## Weiter: [02 — k3s installieren](./02-k3s-install.md)
