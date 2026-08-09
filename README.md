# Fibocom FM350-GL on OpenWrt (MediaTek Filogic)

Auto-connect setup for the Fibocom FM350-GL 5G modem on OpenWrt, using **USB/RNDIS mode** with automated **FCC unlock**, boot-time bring-up, and a self-healing connectivity monitor.

**Tested on:** ZBT Z8102AX V2 · OpenWrt 25.12.4 (kernel 6.12.94) · MediaTek MT7981 · apk package manager

> This modem also supports native PCIe (`kmod-mtk-t7xx`) mode on hardware that wires the M.2 slot's PCIe lanes. This repo is specifically for **USB/RNDIS mode**, which is what most M.2-to-USB adapter boards and dual-mode routers actually expose. Check `lspci` on your router — if the FM350-GL doesn't show up there, you're USB-only and this repo applies to you.

---

## What this does

- Detects the modem on USB enumeration and performs the required **FCC unlock** automatically (challenge/response, no manual intervention)
- Activates the PDP context and configures a static IP/gateway/DNS on the `eth2` RNDIS interface, derived from what the modem itself reports
- Runs a **cron-based monitor** every 2 minutes that catches mid-session drops (PDP context lost, registration lost) that a hotplug-only approach can't see, since the USB device never actually disappears in that failure mode
- Includes an on-demand **modem-only restart** script for forcing a new carrier-assigned public IP (useful behind CGNAT) without rebooting the router

---

## Repo structure

```
FM350-GL-Openwrt/
├── README.md
├── install.sh                          # copies everything below into place
└── etc/
    ├── gcom/
    │   └── run-at-print.gcom           # AT command transport script
    ├── fm350-lib.sh                    # shared functions (unlock, PDP, network config)
    ├── fm350-monitor.sh                # cron: detects and heals mid-session drops
    ├── fm350-restart.sh                # on-demand modem-only reset (new public IP)
    └── hotplug.d/usb/
        └── 30-fm350-fcc                # fires on modem USB enumeration
```

The `etc/` layout mirrors the real router filesystem on purpose — `install.sh` just copies each file to the matching path under `/etc`.

---

## Prerequisites

- OpenWrt installed in **router mode** (not dumb AP)
- Internet access on the router for package installation (Ethernet WAN or WiFi client, temporarily)
- SSH access to the router
- `git-http` if cloning directly on the router: `apk add git git-http` (stock `git` lacks HTTPS support — fails with `remote-https is not a git command` otherwise)
- `git` available somewhere to clone this repo (on the router itself, or clone elsewhere and `scp`/copy the folder over)

---

## Quick install (recommended)

Clone the repo **on the router** and run the installer:

```sh
cd /root
git clone https://github.com/God-Fr3y/FM350-GL-Openwrt.git
cd FM350-GL-Openwrt
sh install.sh
```

`install.sh`:
1. Installs required packages (`kmod-usb-net-rndis`, `kmod-usb-serial-option`, `kmod-usb-net`, `comgt`, `xxd`)
2. Copies all scripts into their `/etc` locations and sets executable permissions
3. Enables cron and adds the monitor job (`*/2 * * * *`)
4. Creates the initial `wan_5g` interface (DHCP — the hotplug script switches it to static once the modem connects)
5. **Adds every custom file to `/etc/sysupgrade.conf`**, so a future firmware upgrade doesn't silently delete all of this (see [Persisting across firmware upgrades](#persisting-across-firmware-upgrades) — this bit us during development, hence it's now automatic)

If your router doesn't have `git`, clone the repo on a computer instead and copy the folder onto the router with `scp -r`:
```sh
scp -r FM350-GL-Openwrt root@192.168.1.1:/root/
```
then SSH in and run `sh install.sh` as above.

Reboot once install finishes:
```sh
reboot
```
Wait 60-90 seconds after reboot for the modem to initialize, then verify (see [Step 5: Verify](#verify) below).

---

## Manual install (no git on the router)

If you'd rather not clone the repo at all, copy each file's contents directly. This is exactly what `install.sh` automates — use this if you want to inspect or customize before installing.

**1. Install packages**
```sh
apk update
apk add kmod-usb-net-rndis kmod-usb-serial-option kmod-usb-net comgt xxd
```

**2. Create the gcom AT command script** — copy contents of [`etc/gcom/run-at-print.gcom`](etc/gcom/run-at-print.gcom) to `/etc/gcom/run-at-print.gcom`

**3. Create the shared library** — copy contents of [`etc/fm350-lib.sh`](etc/fm350-lib.sh) to `/etc/fm350-lib.sh`, then `chmod +x /etc/fm350-lib.sh`

**4. Create the hotplug script** — copy contents of [`etc/hotplug.d/usb/30-fm350-fcc`](etc/hotplug.d/usb/30-fm350-fcc) to `/etc/hotplug.d/usb/30-fm350-fcc`, then `chmod +x /etc/hotplug.d/usb/30-fm350-fcc`

**5. Create the monitor script** — copy contents of [`etc/fm350-monitor.sh`](etc/fm350-monitor.sh) to `/etc/fm350-monitor.sh`, then `chmod +x /etc/fm350-monitor.sh`, and register it with cron:
```sh
/etc/init.d/cron enable
/etc/init.d/cron start
echo "*/2 * * * * /etc/fm350-monitor.sh" >> /etc/crontabs/root
/etc/init.d/cron restart
```

**6. Create the restart script** — copy contents of [`etc/fm350-restart.sh`](etc/fm350-restart.sh) to `/etc/fm350-restart.sh`, then `chmod +x /etc/fm350-restart.sh`

**7. Configure the initial WAN interface**
```sh
uci set network.wan_5g=interface
uci set network.wan_5g.proto='dhcp'
uci set network.wan_5g.device='eth2'
uci set network.wan_5g.metric='10'
uci commit network
```
The interface starts as DHCP but gets switched to static by the hotplug script once the modem connects and reports its real IP/gateway/DNS.

**8. Persist across firmware upgrades** — see the section below, don't skip this.

---

## Persisting across firmware upgrades

**This matters — skipping it means losing everything on your next `sysupgrade`.**

OpenWrt's `sysupgrade` only preserves `/etc/config/*` and whatever's explicitly listed in `/etc/sysupgrade.conf` by default. Every file this repo creates lives outside that default scope, so a firmware upgrade wipes all of it unless you add it yourself:

```sh
cat >> /etc/sysupgrade.conf << 'EOF'
/etc/gcom/run-at-print.gcom
/etc/fm350-lib.sh
/etc/fm350-monitor.sh
/etc/fm350-restart.sh
/etc/hotplug.d/usb/30-fm350-fcc
/etc/crontabs/root
EOF
```

`install.sh` does this automatically. If you did the manual install, run the block above yourself.

**Symptom if this gets missed:** after a `sysupgrade`, `/etc/config/network` (built-in preserved) still holds the last-known static IP/gateway from before the upgrade, and if the modem never actually lost power during the OS-level reboot, it may still be sitting there registered and passing traffic on that stale config — giving a false impression that everything's fine. The moment the modem *does* reset (power loss, physical reboot, PDP drop), there's no script left to bring it back up. Check with:
```sh
ls -la /etc/fm350-lib.sh /etc/fm350-monitor.sh /etc/fm350-restart.sh /etc/hotplug.d/usb/30-fm350-fcc /etc/gcom/run-at-print.gcom
```
If any are missing, re-run `install.sh` (or the manual steps) immediately.

---

## Verify

```sh
# Check hotplug/monitor logs
logread | grep fm350-fcc

# Check IP address
ip addr show eth2

# Test connectivity
ping -c3 8.8.8.8
ping -c3 google.com
```

---

## Customization

### Changing the APN

The APN lives in `/etc/fm350-lib.sh`, inside the `fm350_ensure_pdp()` function — **not** in the hotplug script:
```sh
COMMAND='AT+CGDCONT=1,"IP","your_apn_here"'
```

### IPv6 / dual stack

Change the PDP type in the same line:
```sh
# IPv4 only (default)
COMMAND='AT+CGDCONT=1,"IP","internet"'

# IPv6 only
COMMAND='AT+CGDCONT=1,"IPV6","internet"'

# Dual stack
COMMAND='AT+CGDCONT=1,"IPV4V6","internet"'
```

### Locking to LTE-only (5G NSA can hurt latency-sensitive use)

5G NSA (EN-DC) maintains a simultaneous LTE anchor + NR secondary link and continuously adds/drops/reselects the NR carrier as signal conditions change — each of those events is a brief radio-layer stall. If you're seeing latency spikes or drops during gaming/calls that a 4G-only device on the same SIM doesn't show, this is a common cause. Force LTE-only:
```sh
COMMAND="AT+GTACT=2" gcom -d /dev/ttyUSB1 -s /etc/gcom/run-at-print.gcom
```
(`2` = LTE only. `17` = NR+LTE. `10` = Automatic. See the FM350 AT command manual, `+GTACT`.) To make this permanent, add the same line near the top of `fm350_ensure_pdp()` in `/etc/fm350-lib.sh`.

### Getting a new public IP (behind CGNAT)

```sh
/etc/fm350-restart.sh
```
Resets the modem's own firmware (`AT+CFUN=15`) without touching the router. The modem re-enumerates on USB, which triggers the hotplug script automatically — no manual follow-up needed. Give it 20-40 seconds.

### Bufferbloat / latency under load

If uploads/downloads show fine throughput and 0% loss but latency balloons under sustained load, that's typically bufferbloat from the modem/carrier's own unmanaged buffer, not this setup. Install `luci-app-sqm` + `sqm-scripts`, point it at `eth2`, use the `cake` qdisc with `piece_of_cake.qos`, and set download/upload limits to ~85% of your actual measured speeds. This is a separate layer from everything above and doesn't require changing anything in this repo.

---

## Troubleshooting

**Check if the modem is detected**
```sh
lsusb | grep 0e8d
ls -la /dev/ttyUSB*
```

**Manual FCC unlock test**
```sh
COMMAND="AT+GTFCCLOCKGEN" gcom -d /dev/ttyUSB1 -s /etc/gcom/run-at-print.gcom
```

**Manual connection test**
```sh
COMMAND='AT+CGDCONT=1,"IP","internet"' gcom -d /dev/ttyUSB1 -s /etc/gcom/run-at-print.gcom
COMMAND="AT+CGACT=1,1" gcom -d /dev/ttyUSB1 -s /etc/gcom/run-at-print.gcom
COMMAND="AT+CGPADDR=1" gcom -d /dev/ttyUSB1 -s /etc/gcom/run-at-print.gcom
```

**Simulate hotplug for testing**
```sh
ACTION=add PRODUCT=0e8d/7126/1 DEVTYPE=usb_device /etc/hotplug.d/usb/30-fm350-fcc
```

**Scripts missing / nothing connects after a firmware upgrade** — see [Persisting across firmware upgrades](#persisting-across-firmware-upgrades) above. This is the most common cause of "it worked before and now it just doesn't" after flashing a new build.

**`gcom: Could not open scriptfile`** — the gcom script itself is missing (usually the same root cause as above). Recheck with `ls -la /etc/gcom/run-at-print.gcom` and recreate from this repo if needed.

**`AT+CFUN=15` (restart) returns no `OK`** — expected. The modem is already resetting by the time it would reply; this is a documented race condition in the FM350's own AT command reference, not a failure.

---

## How it works

1. **Hotplug detection** — when the FM350-GL enumerates (plug-in, boot, or after `fm350-restart.sh`), `30-fm350-fcc` fires
2. **Device wait** — waits for `/dev/ttyUSB1` (AT port) to exist and actually answer `AT`, and for `eth2` (RNDIS interface) to appear
3. **FCC unlock** — checks real unlock state via `AT+GTFCCEFFSTATUS?` first (skips redundant unlock if already unlocked this power cycle); otherwise gets a challenge via `AT+GTFCCLOCKGEN`, computes a SHA-256 response using vendor hash `3df8c719`, verifies via `AT+GTFCCLOCKVER`
4. **APN + PDP activation** — sets `AT+CGDCONT`, activates with `AT+CGACT=1,1`, checked against real state (not assumed) with a retry on failure
5. **IP/DNS retrieval** — pulls the assigned IP from `AT+CGPADDR=1` and DNS servers from `AT+CGCONTRDP=1`
6. **Network config** — computes gateway/netmask from the assigned IP, applies a static UCI config on `eth2`, adds it to the WAN firewall zone, calls `ifup wan_5g`
7. **Ongoing monitoring** — `fm350-monitor.sh` runs every 2 minutes via cron: cheap ping check first, and only touches the modem (AT port check → recovery bring-up) if that ping fails, so it doesn't do unnecessary AT I/O on a healthy connection

---

## Credits

FCC unlock implementation based on the approach used in ROOter/GoldenOrb firmware. Vendor ID hash `3df8c719` is specific to Fibocom FM350-GL modems.
