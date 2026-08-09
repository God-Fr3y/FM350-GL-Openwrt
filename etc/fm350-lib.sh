#!/bin/sh
# /etc/fm350-lib.sh
#
# Shared functions for talking to the Fibocom FM350-GL over AT commands.
# Sourced by /etc/hotplug.d/usb/30-fm350-fcc (runs once at device add),
# /etc/fm350-monitor.sh (runs periodically via cron to catch mid-session
# drops), and /etc/fm350-restart.sh (manual on-demand modem reset).
#
# Callers must set TTY and GCOM_SCRIPT before sourcing/using these functions.

MAX_WAIT="${MAX_WAIT:-30}"

# --- Wait for the AT port to exist and actually answer commands ---
# device node existing != modem firmware ready to answer AT
fm350_wait_at() {
    local waited=0

    if [ ! -f "$GCOM_SCRIPT" ]; then
        logger -t fm350-fcc "FATAL: $GCOM_SCRIPT missing"
        return 1
    fi

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
# NOTE: the APN lives here ("internet" below) - change it here, not in the
# hotplug script, if your carrier needs a different APN.
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
