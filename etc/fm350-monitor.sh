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
