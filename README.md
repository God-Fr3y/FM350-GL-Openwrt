# Fibocom FM350-GL on OpenWrt (MediaTek Filogic)

Tested on: ZBT Z8102AX V2, OpenWrt 25.12.4 (kernel 6.12.87), MediaTek MT7981

This guide configures the Fibocom FM350-GL 5G modem for auto-connect on boot using RNDIS mode with FCC unlock.

Prerequisites

· OpenWrt installed (router mode, not dumb AP)
· Internet access on the router for package installation (Ethernet WAN or WiFi client)
· SSH access to the router

Step 1: Install Required Packages

```sh
apk update
apk add kmod-usb-net-rndis kmod-usb-serial-option kmod-usb-net comgt xxd
```

Optional (for debugging):

```sh
apk add usbutils
```

Step 2: Create Gcom AT Command Script

This script is used to send AT commands to the modem and capture responses.

```sh
cat > /etc/gcom/run-at-print.gcom << 'EOF'
opengt
 set com 115200n81
 set comecho off
 set senddelay 0.02
 waitquiet 1 0.2
 flash 0.1

:start
 send $env("COMMAND")
 send "^m"
 get 5 "" $r
 print $r

:continue
 exit 0
EOF
```

Step 3: Create the Hotplug Script

This script automatically runs when the modem is detected. It performs FCC unlock, sets the APN, activates the PDP context, and configures the network interface.

```sh
mkdir -p /etc/hotplug.d/usb

cat > /etc/hotplug.d/usb/30-fm350-fcc << 'SCRIPT_EOF'
#!/bin/sh
# /etc/hotplug.d/usb/30-fm350-fcc
#
# Runs FCC unlock + PDP activation + network config when the FM350-GL
# enumerates. Only handles the ONE-TIME device-add event; ongoing
# connectivity is watched separately by /etc/fm350-monitor.sh (cron).

[ "$ACTION" = "add" ] || exit 0

case "${PRODUCT}" in
    0e8d/7126/*|e8d/7126/*|0e8d/7127/*|e8d/7127/*)
        ;;
    *)
        exit 0
        ;;
esac

# Composite device fires a uevent per interface (RNDIS + N serial ports).
# Only act on the whole-device event, not each interface's.
if [ "$DEVTYPE" != "usb_device" ]; then
    exit 0
fi

. /etc/fm350-lib.sh

LOCKFILE="/var/run/fm350-fcc.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { logger -t fm350-fcc "Another instance running, exiting"; exit 0; }

TTY="/dev/ttyUSB1"
GCOM_SCRIPT="/etc/gcom/run-at-print.gcom"

logger -t fm350-fcc "FM350-GL detected, waiting for AT port"

fm350_full_bringup || exit 1
SCRIPT_EOF

chmod +x /etc/hotplug.d/usb/30-fm350-fcc

```
Create a shared library script
```
cat > /etc/fm350-lib.sh << 'SCRIPT_EOF'
#!/bin/sh
# /etc/fm350-lib.sh
#
# Shared functions for talking to the Fibocom FM350-GL over AT commands.
# Sourced by both /etc/hotplug.d/usb/30-fm350-fcc (runs once at device add)
# and /etc/fm350-monitor.sh (runs periodically via cron to catch mid-session drops).
#
# Callers must set TTY and GCOM_SCRIPT before sourcing/using these functions.

MAX_WAIT="${MAX_WAIT:-30}"

# --- Wait for the AT port to exist and actually answer commands ---
# device node existing != modem firmware ready to answer AT
fm350_wait_at() {
    local waited=0

    while [ ! -c "$TTY" ] && [ $waited -lt $MAX_WAIT ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ ! -c "$TTY" ]; then
        logger -t fm350-fcc "ERROR: $TTY not found"
        return 1
    fi

    waited=0
    until COMMAND="AT" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null | grep -q "OK"; do
        sleep 1
        waited=$((waited + 1))
        if [ $waited -ge $MAX_WAIT ]; then
            logger -t fm350-fcc "ERROR: AT port not responding"
            return 1
        fi
    done

    # Verbose CME errors so any failure downstream is logged with a real
    # reason instead of a bare "ERROR" - cheap to enable, invaluable when
    # something breaks in a way we haven't already diagnosed.
    COMMAND="AT+CMEE=2" gcom -d "$TTY" -s "$GCOM_SCRIPT" >/dev/null 2>&1

    return 0
}

# --- FCC unlock, gated on real unlock state (not interface IP) ---
fm350_ensure_unlock() {
    local eff unlock_state ox challenge hex_challenge combined response_hash truncated response ox2

    eff=$(COMMAND="AT+GTFCCEFFSTATUS?" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null)
    unlock_state=$(echo "$eff" | grep -o '+GTFCCEFFSTATUS: [0-9]*,[0-9]*' | cut -d',' -f2)

    if [ "$unlock_state" = "1" ]; then
        logger -t fm350-fcc "FCC already unlocked this power cycle, skipping unlock step"
        return 0
    fi

    logger -t fm350-fcc "Performing FCC unlock"
    local vendor_id_hash="3df8c719"

    ox=$(COMMAND="AT+GTFCCLOCKGEN" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null)
    challenge=$(echo "$ox" | grep -o '0x[0-9a-fA-F]\+' | head -1)
    if [ -z "$challenge" ]; then
        sleep 3
        ox=$(COMMAND="AT+GTFCCLOCKGEN" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null)
        challenge=$(echo "$ox" | grep -o '0x[0-9a-fA-F]\+' | head -1)
    fi
    if [ -z "$challenge" ]; then
        logger -t fm350-fcc "FCC challenge failed"
        return 1
    fi

    hex_challenge=$(printf "%08x" "$challenge")
    combined="${hex_challenge}${vendor_id_hash}"
    response_hash=$(echo "$combined" | xxd -r -p | sha256sum | cut -d' ' -f1)
    truncated=$(printf "%.8s" "$response_hash")
    response=$(printf "%d" "0x$truncated")

    ox2=$(COMMAND="AT+GTFCCLOCKVER=$response" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null)
    if ! echo "$ox2" | grep -q "+GTFCCLOCKVER: 1"; then
        logger -t fm350-fcc "FCC unlock FAILED: $ox2"
        return 1
    fi
    logger -t fm350-fcc "FCC unlock SUCCESS"
    return 0
}

# --- Wait for eth2 link to exist (separate from having an IP assigned) ---
fm350_wait_link() {
    local waited=0
    while ! ip link show eth2 >/dev/null 2>&1 && [ $waited -lt $MAX_WAIT ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if ! ip link show eth2 >/dev/null 2>&1; then
        logger -t fm350-fcc "ERROR: eth2 never appeared"
        return 1
    fi
    return 0
}

# --- Ensure PDP context is active, based on real modem state ---
fm350_ensure_pdp() {
    local cgact act_result act_check

    cgact=$(COMMAND="AT+CGACT?" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null)
    if echo "$cgact" | grep -q "+CGACT: 1,1"; then
        logger -t fm350-fcc "PDP context already active"
        return 0
    fi

    COMMAND="AT+C5GREG=3" gcom -d "$TTY" -s "$GCOM_SCRIPT" >/dev/null 2>&1
    sleep 1
    COMMAND='AT+CGDCONT=1,"IP","internet"' gcom -d "$TTY" -s "$GCOM_SCRIPT" >/dev/null 2>&1
    sleep 1

    act_result=$(COMMAND="AT+CGACT=1,1" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>&1)
    logger -t fm350-fcc "CGACT attempt result: $act_result"
    sleep 3

    act_check=$(COMMAND="AT+CGACT?" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null)
    if ! echo "$act_check" | grep -q "+CGACT: 1,1"; then
        sleep 3
        act_result=$(COMMAND="AT+CGACT=1,1" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>&1)
        logger -t fm350-fcc "CGACT retry result: $act_result"
        sleep 3
        act_check=$(COMMAND="AT+CGACT?" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null)
        if ! echo "$act_check" | grep -q "+CGACT: 1,1"; then
            logger -t fm350-fcc "PDP activation FAILED. Last response: $act_result"
            return 1
        fi
    fi

    logger -t fm350-fcc "PDP context activated"
    return 0
}

# --- Fetch IP/DNS from the modem, compute gateway/netmask, apply via UCI ---
fm350_configure_network() {
    local ox4 ipaddr ox5 dns_all dns1 dns2
    local d abc x y netaddr res subnet gw_last gateway netmask firewall_check

    ox4=$(COMMAND="AT+CGPADDR=1" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null)
    ipaddr=$(echo "$ox4" | grep "+CGPADDR:" | cut -d'"' -f2)

    ox5=$(COMMAND="AT+CGCONTRDP=1" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null)
    dns_all=$(echo "$ox5" | grep -o '"[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+"' | tr -d '"')
    dns1=$(echo "$dns_all" | sed -n '1p')
    dns2=$(echo "$dns_all" | sed -n '2p')

    logger -t fm350-fcc "IP=$ipaddr DNS1=$dns1 DNS2=$dns2"
    if [ -z "$ipaddr" ] || [ "$ipaddr" = "0.0.0.0" ]; then
        logger -t fm350-fcc "No valid IP obtained"
        return 1
    fi

    d=$(echo "$ipaddr" | awk -F'.' '{print $4}')
    abc=$(echo "$ipaddr" | awk -F'.' '{print $1"."$2"."$3}')
    x=1; y=4
    netaddr=$((y-1)); res=$((d%y))
    while [ $res -eq 0 ] || [ $res -eq $netaddr ]; do
        x=$((x+1)); y=$((y*2)); netaddr=$((y-1)); res=$((d%y))
    done
    subnet=$((31-x))
    gw_last=$((d/y))
    if [ $res -eq 1 ]; then gw_last=$((gw_last*y+2)); else gw_last=$((gw_last*y+1)); fi
    gateway="$abc.$gw_last"
    netmask="255.255.255.$((256 - (1 << (32 - $subnet))))"

    uci set network.wan_5g=interface
    uci set network.wan_5g.proto='static'
    uci set network.wan_5g.device='eth2'
    uci set network.wan_5g.metric='10'
    uci set network.wan_5g.ipaddr="$ipaddr"
    uci set network.wan_5g.netmask="$netmask"
    uci set network.wan_5g.gateway="$gateway"
    uci set network.wan_5g.dns="$dns1 $dns2"
    uci set network.wan_5g.peerdns='0'
    uci commit network

    firewall_check=$(uci show firewall | grep -E "\.network=.*wan_5g")
    if [ -z "$firewall_check" ]; then
        uci add_list firewall.@zone[1].network='wan_5g'
        uci commit firewall
        /etc/init.d/firewall restart
    fi

    ifup wan_5g
    sleep 2
    ip route show | grep -q "^default" || ip route add default via "$gateway" dev eth2

    logger -t fm350-fcc "Connection complete: $ipaddr/$subnet via $gateway DNS=$dns1 $dns2"
    return 0
}

# --- Full bring-up sequence: unlock -> link -> PDP -> network config ---
fm350_full_bringup() {
    fm350_wait_at || return 1
    fm350_ensure_unlock || return 1
    fm350_wait_link || return 1
    fm350_ensure_pdp || return 1
    fm350_configure_network || return 1
    return 0
}

chmod +x /etc/fm350-lib.sh
SCRIPT_EOF
```
Create monitor script
```
cat > /etc/fm350-monitor.sh << 'SCRIPT_EOF'
#!/bin/sh
# /etc/fm350-monitor.sh
#
# Runs periodically via cron. The hotplug script only fires when the USB
# device enumerates (boot/replug) - it has no way to notice a mid-session
# drop where the modem stays enumerated but the PDP context or network
# registration is lost. This script catches that case: ping test first
# (cheap, no modem I/O), and only if it fails does it touch the modem at
# all and attempt recovery via the same bring-up logic hotplug uses.

. /etc/fm350-lib.sh

TTY="/dev/ttyUSB1"
GCOM_SCRIPT="/etc/gcom/run-at-print.gcom"
PING_TARGET="8.8.8.8"

LOCKFILE="/var/run/fm350-fcc.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { logger -t fm350-fcc "monitor: bring-up already in progress, skipping this cycle"; exit 0; }

# If eth2 doesn't even exist, the modem isn't enumerated - nothing for the
# monitor to do, hotplug will handle it when/if the device reappears.
if ! ip link show eth2 >/dev/null 2>&1; then
    exit 0
fi

# Cheap check first: does traffic actually flow over eth2 right now?
if ping -I eth2 -c 2 -W 3 "$PING_TARGET" >/dev/null 2>&1; then
    exit 0
fi

logger -t fm350-fcc "monitor: connectivity check failed, investigating"

if [ ! -c "$TTY" ]; then
    logger -t fm350-fcc "monitor: $TTY missing, modem may have dropped off USB - nothing to do here, waiting for hotplug re-add"
    exit 1
fi

# Confirm the AT port is actually responsive before doing anything else.
# If it's not, the modem itself is in a bad state that a PDP re-activation
# won't fix - log it and bail rather than looping pointlessly.
if ! COMMAND="AT" gcom -d "$TTY" -s "$GCOM_SCRIPT" 2>/dev/null | grep -q "OK"; then
    logger -t fm350-fcc "monitor: AT port unresponsive, modem needs manual attention"
    exit 1
fi
COMMAND="AT+CMEE=2" gcom -d "$TTY" -s "$GCOM_SCRIPT" >/dev/null 2>&1

# Modem is alive and talking - most likely cause is the PDP context (or
# registration) dropped. Re-run the same bring-up sequence hotplug uses;
# fm350_ensure_unlock/fm350_ensure_pdp are already idempotent so this is
# safe to call even if only part of the state actually needs fixing.
logger -t fm350-fcc "monitor: AT port alive, attempting recovery"

fm350_ensure_unlock || { logger -t fm350-fcc "monitor: unlock check failed during recovery"; exit 1; }
fm350_wait_link      || { logger -t fm350-fcc "monitor: eth2 not present during recovery"; exit 1; }
fm350_ensure_pdp     || { logger -t fm350-fcc "monitor: PDP re-activation failed during recovery"; exit 1; }
fm350_configure_network || { logger -t fm350-fcc "monitor: network reconfiguration failed during recovery"; exit 1; }

# Verify the fix actually worked before declaring success
if ping -I eth2 -c 2 -W 3 "$PING_TARGET" >/dev/null 2>&1; then
    logger -t fm350-fcc "monitor: recovery successful"
else
    logger -t fm350-fcc "monitor: recovery ran but connectivity still failing - may need investigation"
fi

chmod +x /etc/fm350-monitor.sh

/etc/init.d/cron enable
/etc/init.d/cron start

echo "*/2 * * * * /etc/fm350-monitor.sh" >> /etc/crontabs/root
/etc/init.d/cron restart
SCRIPT_EOF
```

Step 4: Configure the WAN Interface (Initial Setup)

```sh
uci set network.wan_5g=interface
uci set network.wan_5g.proto='dhcp'
uci set network.wan_5g.device='eth2'
uci set network.wan_5g.metric='10'
uci commit network
```

Note: The interface is initially set to DHCP but will be changed to static by the hotplug script when the modem connects.

Step 5: Reboot and Verify

```sh
reboot
```

After reboot, wait about 60-90 seconds for the modem to initialize, then check:

```sh
# Check hotplug logs
logread | grep fm350-fcc

# Check IP address
ip addr show eth2

# Test connectivity
ping -c3 8.8.8.8
ping -c3 google.com
```

Customization

Changing APN

Edit the APN in the hotplug script (/etc/hotplug.d/usb/30-fm350-fcc):

```sh
COMMAND='AT+CGDCONT=1,"IP","your_apn_here"'
```

Using IPv6 or Dual Stack

Change the PDP type:

```sh
# IPv4 only
COMMAND='AT+CGDCONT=1,"IP","internet"'

# IPv6 only
COMMAND='AT+CGDCONT=1,"IPV6","internet"'

# Dual stack (IPv4v6)
COMMAND='AT+CGDCONT=1,"IPV4V6","internet"'
```

Troubleshooting

Check if modem is detected

```sh
lsusb | grep 0e8d
ls -la /dev/ttyUSB*
```

Manual FCC unlock test

```sh
COMMAND="AT+GTFCCLOCKGEN" gcom -d /dev/ttyUSB1 -s /etc/gcom/run-at-print.gcom
```

Manual connection test

```sh
COMMAND='AT+CGDCONT=1,"IP","internet"' gcom -d /dev/ttyUSB1 -s /etc/gcom/run-at-print.gcom
COMMAND="AT+CGACT=1,1" gcom -d /dev/ttyUSB1 -s /etc/gcom/run-at-print.gcom
COMMAND="AT+CGPADDR=1" gcom -d /dev/ttyUSB1 -s /etc/gcom/run-at-print.gcom
```

Simulate hotplug for testing

```sh
ACTION=add PRODUCT=0e8d/7126/1 /etc/hotplug.d/usb/30-fm350-fcc
```

How It Works

1. Hotplug Detection: When the FM350-GL modem is plugged in or detected at boot, the hotplug script triggers
2. Device Wait: Script waits for /dev/ttyUSB1 (AT command port) and eth2 (RNDIS network interface)
3. FCC Unlock: Sends AT+GTFCCLOCKGEN to get a challenge, computes SHA256 response using vendor hash 3df8c719, sends AT+GTFCCLOCKVER to verify
4. APN Setup: Configures PDP context with APN "internet" (change if needed)
5. PDP Activation: Activates the data connection with AT+CGACT=1,1
6. IP Retrieval: Gets assigned IP from AT+CGPADDR=1 and DNS from AT+CGCONTRDP=1
7. Network Config: Sets up static IP on eth2 with /30 subnet, adds to WAN firewall zone for NAT
8. Interface Restart: Calls ifup wan_5g so netifd properly configures routing and DNS forwarding

Files Created

File Purpose
/etc/gcom/run-at-print.gcom Gcom script for AT commands
/etc/hotplug.d/usb/30-fm350-fcc Auto-connect hotplug script

Credits

Based on the FCC unlock implementation from ROOter/GoldenOrb firmware. Vendor ID hash 3df8c719 is specific to Fibocom FM350-GL modems.
