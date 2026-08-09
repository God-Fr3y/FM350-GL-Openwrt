#!/bin/sh
# install.sh
#
# Installs the FM350-GL OpenWrt scripts from this repo onto the router.
# Run this ON THE ROUTER, from the root of a cloned copy of this repo.
#
#   git clone https://github.com/God-Fr3y/FM350-GL-Openwrt.git
#   cd FM350-GL-Openwrt
#   sh install.sh
#
# Safe to re-run: existing files are overwritten with the repo's version,
# cron/sysupgrade entries are only added if not already present.

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing required packages"
apk update
apk add kmod-usb-net-rndis kmod-usb-serial-option kmod-usb-net comgt xxd

echo "==> Copying scripts into /etc"
mkdir -p /etc/gcom /etc/hotplug.d/usb

cp "$REPO_DIR/etc/gcom/run-at-print.gcom"     /etc/gcom/run-at-print.gcom
cp "$REPO_DIR/etc/fm350-lib.sh"               /etc/fm350-lib.sh
cp "$REPO_DIR/etc/fm350-monitor.sh"           /etc/fm350-monitor.sh
cp "$REPO_DIR/etc/fm350-restart.sh"           /etc/fm350-restart.sh
cp "$REPO_DIR/etc/hotplug.d/usb/30-fm350-fcc" /etc/hotplug.d/usb/30-fm350-fcc

chmod +x /etc/fm350-lib.sh /etc/fm350-monitor.sh /etc/fm350-restart.sh
chmod +x /etc/hotplug.d/usb/30-fm350-fcc

echo "==> Setting up cron monitor (every 2 minutes)"
/etc/init.d/cron enable
/etc/init.d/cron start
grep -q "fm350-monitor.sh" /etc/crontabs/root 2>/dev/null || \
    echo "*/2 * * * * /etc/fm350-monitor.sh" >> /etc/crontabs/root
/etc/init.d/cron restart

echo "==> Configuring initial WAN interface (wan_5g)"
uci set network.wan_5g=interface
uci set network.wan_5g.proto='dhcp'
uci set network.wan_5g.device='eth2'
uci set network.wan_5g.metric='10'
uci commit network

echo "==> Adding files to sysupgrade preserve list (survive firmware upgrades)"
for f in \
    /etc/gcom/run-at-print.gcom \
    /etc/fm350-lib.sh \
    /etc/fm350-monitor.sh \
    /etc/fm350-restart.sh \
    /etc/hotplug.d/usb/30-fm350-fcc \
    /etc/crontabs/root
do
    grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
done

echo ""
echo "==> Done."
echo "If your carrier needs a non-default APN, edit it in /etc/fm350-lib.sh"
echo "(the AT+CGDCONT line inside fm350_ensure_pdp), then run: reboot"
