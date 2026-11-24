#!/bin/sh
# Undo Phase 2. Does not touch any existing printer service, CUPS queue,
# package layer or bootc deployment. The frozen rootfs is left in place by
# default; KONICA_REMOVE_ROOTFS=1 moves it aside to a timestamped directory.
#
#   sudo scripts/remove-host-integration.sh
#   KONICA_REMOVE_ROOTFS=1 sudo -E scripts/remove-host-integration.sh
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/config/pins.env"

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ...)"

UNIT="systemd-nspawn@$MACHINE_NAME.service"
HEALTH_DIR="$STATE_DIR/health"
HC_UNIT=konica206-frozen-healthcheck.service
HC_TIMER=konica206-frozen-healthcheck.timer

say "stopping and disabling units"
systemctl disable --now "$UNIT" "$HC_TIMER" "$HC_UNIT" 2>/dev/null || true
systemctl stop "$HC_UNIT" 2>/dev/null || true

say "removing host files"
rm -f "/etc/systemd/nspawn/$MACHINE_NAME.nspawn"
rm -f "/etc/systemd/system/$UNIT.d/override.conf"
rmdir "/etc/systemd/system/$UNIT.d" 2>/dev/null || true
rm -f /etc/udev/rules.d/75-konica206-frozen.rules
rm -f "/etc/systemd/system/$HC_UNIT" "/etc/systemd/system/$HC_TIMER"
rm -rf "$HEALTH_DIR"

if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled &&
   command -v semanage >/dev/null 2>&1; then
    say "removing SELinux fcontext rules"
    semanage fcontext -d "$HEALTH_DIR/health-check.sh" 2>/dev/null || true
    semanage fcontext -d "$HEALTH_DIR/verify-raster-only.sh" 2>/dev/null || true
fi

if [ "${KONICA_REMOVE_ROOTFS:-0}" = 1 ] && [ -e "$ROOTFS" ]; then
    DISABLED="$ROOTFS.disabled.$(date -u +%Y%m%dT%H%M%SZ)"
    say "moving rootfs aside to $DISABLED"
    mv "$ROOTFS" "$DISABLED"
fi

say "reloading systemd and udev"
systemctl daemon-reload
udevadm control --reload || true

say "done"
echo "Existing printer services, CUPS queues and package layers were untouched."
