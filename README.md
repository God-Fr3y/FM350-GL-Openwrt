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

[ "$ACTION" = "add" ] || exit 0

case "${PRODUCT}" in
    0e8d/7126/*|e8d/7126/*|0e8d/7127/*|e8d/7127/*)
        ;;
    *)
        exit 0
        ;;
esac

logger -t fm350-fcc "FM350-GL detected (PRODUCT=$PRODUCT), waiting for devices"

MAX_WAIT=30
WAITED=0
while [ ! -c /dev/ttyUSB1 ] && [ $WAITED -lt $MAX_WAIT ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ ! -c /dev/ttyUSB1 ]; then
    logger -t fm350-fcc "ERROR: /dev/ttyUSB1 not found after ${MAX_WAIT}s"
    exit 1
fi

WAITED=0
while ! ip link show eth2 >/dev/null 2>&1 && [ $WAITED -lt $MAX_WAIT ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done

logger -t fm350-fcc "Devices ready, starting FCC unlock"

VENDOR_ID_HASH="3df8c719"
TTY="/dev/ttyUSB1"

# FCC Unlock with retry
OX=$(COMMAND="AT+GTFCCLOCKGEN" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom 2>/dev/null)
CHALLENGE=$(echo "$OX" | grep -o '0x[0-9a-fA-F]\+' | head -1)

if [ -z "$CHALLENGE" ]; then
    sleep 3
    OX=$(COMMAND="AT+GTFCCLOCKGEN" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom 2>/dev/null)
    CHALLENGE=$(echo "$OX" | grep -o '0x[0-9a-fA-F]\+' | head -1)
fi

if [ -z "$CHALLENGE" ]; then
    logger -t fm350-fcc "FCC challenge failed"
    exit 1
fi

HEX_CHALLENGE=$(printf "%08x" "$CHALLENGE")
COMBINED="${HEX_CHALLENGE}${VENDOR_ID_HASH}"
RESPONSE_HASH=$(echo "$COMBINED" | xxd -r -p | sha256sum | cut -d' ' -f1)
TRUNCATED=$(printf "%.8s" "$RESPONSE_HASH")
RESPONSE=$(printf "%d" "0x$TRUNCATED")

OX2=$(COMMAND="AT+GTFCCLOCKVER=$RESPONSE" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom 2>/dev/null)

if ! echo "$OX2" | grep -q "+GTFCCLOCKVER: 1"; then
    logger -t fm350-fcc "FCC unlock FAILED"
    exit 1
fi
logger -t fm350-fcc "FCC unlock SUCCESS"

# === ROOter Connection Sequence ===
logger -t fm350-fcc "Starting ROOter-style connection sequence"

# 1. Enable 5G registration
COMMAND="AT+C5GREG=3" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1

# 2. Set network registration URCs with extended info
COMMAND="AT+CREG=2;+CGREG=2;+CEREG=2" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1

# 3. Set initial attach APN (critical for network registration)
COMMAND='AT+EIAAPN="internet",0,"IP","IP",0,"",""' gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1

# 4. Set operator format (ignore ERROR if already connected)
COMMAND="AT+COPS=2;+COPS=3,0" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1

# 5. Configure PDP context 0 (used for initial attachment)
COMMAND='AT+CGDCONT=0,"IP","internet"' gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1

# 6. Configure PDP context 1 (used for data)
COMMAND='AT+CGDCONT=1,"IP","internet"' gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1

# 7. Attach to packet domain
logger -t fm350-fcc "Attaching to packet domain"
COMMAND="AT+CGATT=1" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1
sleep 3

# Check attachment
ATT_CHECK=$(COMMAND="AT+CGATT?" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom 2>/dev/null)
if ! echo "$ATT_CHECK" | grep -q "+CGATT: 1"; then
    logger -t fm350-fcc "CGATT failed, retrying..."
    sleep 2
    COMMAND="AT+CGATT=1" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1
    sleep 3
fi

# 8. Activate PDP context
logger -t fm350-fcc "Activating PDP context"
COMMAND="AT+CGACT=1,1" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1
sleep 3

# Verify activation
ACT_CHECK=$(COMMAND="AT+CGACT?" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom 2>/dev/null)
if echo "$ACT_CHECK" | grep -q "+CGACT: 1,1"; then
    logger -t fm350-fcc "PDP context activated (confirmed)"
else
    # Try once more
    logger -t fm350-fcc "Retrying PDP activation..."
    sleep 2
    COMMAND="AT+CGACT=1,1" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom >/dev/null 2>&1
    sleep 3
fi

# 9. Get IP
OX4=$(COMMAND="AT+CGPADDR=1" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom 2>/dev/null)
IPADDR=$(echo "$OX4" | grep "+CGPADDR:" | cut -d'"' -f2)

# 10. Get DNS
OX5=$(COMMAND="AT+CGCONTRDP=1" gcom -d "$TTY" -s /etc/gcom/run-at-print.gcom 2>/dev/null)
DNS1=$(echo "$OX5" | grep "+CGCONTRDP:" | cut -d'"' -f6)
DNS2=$(echo "$OX5" | grep "+CGCONTRDP:" | cut -d'"' -f8)

logger -t fm350-fcc "IP=$IPADDR DNS=$DNS1,$DNS2"

if [ -z "$IPADDR" ] || [ "$IPADDR" = "0.0.0.0" ]; then
    logger -t fm350-fcc "No valid IP"
    exit 1
fi

# Calculate gateway (last octet - 1)
GATEWAY=$(echo "$IPADDR" | awk -F. '{if($4>1) $4=$4-1; print $1"."$2"."$3"."$4}')

# Build DNS string
DNS_LIST="$DNS1"
[ -n "$DNS2" ] && DNS_LIST="$DNS_LIST $DNS2"

# Update UCI network config
uci set network.wan_5g=interface
uci set network.wan_5g.proto='static'
uci set network.wan_5g.device='eth2'
uci set network.wan_5g.metric='10'
uci set network.wan_5g.ipaddr="$IPADDR"
uci set network.wan_5g.netmask='255.255.255.252'
uci set network.wan_5g.gateway="$GATEWAY"
uci set network.wan_5g.dns="$DNS_LIST"
uci set network.wan_5g.peerdns='0'
uci commit network

# Ensure wan_5g is in WAN firewall zone for NAT
FIREWALL_ZONE=$(uci show firewall | grep -E "\.network=.*wan_5g" | head -1)
if [ -z "$FIREWALL_ZONE" ]; then
    uci add_list firewall.@zone[1].network='wan_5g'
    uci commit firewall
    /etc/init.d/firewall restart
fi

# Restart the interface so netifd handles routing/masquerade/DNS
ifup wan_5g

logger -t fm350-fcc "Connection complete: $IPADDR via $GATEWAY"
SCRIPT_EOF

chmod +x /etc/hotplug.d/usb/30-fm350-fcc
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