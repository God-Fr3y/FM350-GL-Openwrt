#!/bin/sh
# /etc/fm350-restart.sh
#
# Resets the FM350-GL modem's own firmware (AT+CFUN=15) without touching
# the router's OS, WiFi, or any other interface. Useful for forcing the
# carrier to hand out a new public-facing IP when behind CGNAT.
#
# The modem re-enumerates on USB after the reset, which causes
# /etc/hotplug.d/usb/30-fm350-fcc to fire automatically and run the full
# bring-up sequence (FCC unlock check, PDP activation, network config) -
# no manual follow-up steps needed.
#
# Usage: /etc/fm350-restart.sh

TTY="/dev/ttyUSB1"
GCOM_SCRIPT="/etc/gcom/run-at-print.gcom"

logger -t fm350-fcc "Manual modem restart requested"

# NOTE: AT+CFUN=15 may not return "OK" due to a race condition (the modem
# is already resetting by the time it would reply) - this is expected,
# not a failure. Don't treat a timeout/empty response here as an error.
COMMAND="AT+CFUN=15" gcom -d "$TTY" -s "$GCOM_SCRIPT" >/dev/null 2>&1

logger -t fm350-fcc "Reset command sent, modem will re-enumerate and hotplug will handle bring-up (~20-40s)"
