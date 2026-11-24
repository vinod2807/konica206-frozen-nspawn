#!/bin/sh
# Phase 2: install the frozen rootfs and its host integration on Fedora.
#
#   sudo scripts/install-host-integration.sh [archive.tar.zst]
#   IPP_PORT=8002 sudo -E scripts/install-host-integration.sh   # side-by-side
#   KONICA_FORCE=1 sudo -E scripts/install-host-integration.sh  # replace rootfs
#
# Installs only under /etc and /var: no rpm-ostree overlay, no package
# layering, no new bootc deployment and no writes under /usr. Existing CUPS
# queues and printer services are never touched.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/config/pins.env"

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# PAPPL starts with zero printers; Create-Printer must be sent to the running
# system. Reach the container's own /run and network namespace from the host.
ensure_printer() {
    n=0
    while [ "$n" -lt 15 ]; do
        systemctl is-active --quiet "$UNIT" && break
        n=$((n + 1))
        sleep 1
    done
    leader=$(machinectl show "$MACHINE_NAME" -p Leader --value 2>/dev/null || true)
    if [ -z "$leader" ]; then
        say "WARNING: container leader not found; create the printer manually (see docs)"
        return 0
    fi
    if nsenter -t "$leader" -m -n -p -u -i -- /usr/local/bin/konica206-native add \
        -d konica206 -m konica-bizhub-206 \
        -v "konica://KONICA%20MINOLTA/206?serial=$PRINTER_SERIAL"; then
        say "created PAPPL printer konica206"
    else
        say "WARNING: printer add failed (it may already exist)"
    fi
}

[ "$(id -u)" -eq 0 ] || die "run as root (sudo -E ...)"
case "$IPP_PORT" in
    ''|*[!0-9]*) die "IPP_PORT must be numeric (got '$IPP_PORT')" ;;
esac

ARCHIVE=${1:-$PWD/$FROZEN_ARCHIVE}
case "$ARCHIVE" in
    /*) ;;
    *) ARCHIVE="$PWD/$ARCHIVE" ;;
esac
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE (build it with scripts/build-frozen-rootfs.sh)"

if [ -f "$ARCHIVE.sha256" ]; then
    say "verifying $ARCHIVE.sha256"
    (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE.sha256")") || die "archive checksum mismatch"
else
    say "WARNING: no .sha256 file next to the archive; skipping checksum verification"
fi

UNIT="systemd-nspawn@$MACHINE_NAME.service"
HEALTH_DIR="$STATE_DIR/health"

if [ -e "$ROOTFS" ]; then
    [ "${KONICA_FORCE:-0}" = 1 ] || die "$ROOTFS exists; set KONICA_FORCE=1 to replace it (a .bak snapshot is kept)"
    BACKUP="$ROOTFS.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    say "moving existing rootfs to $BACKUP"
    mv "$ROOTFS" "$BACKUP"
fi

say "extracting the frozen rootfs into $ROOTFS"
mkdir -p "$ROOTFS"
tar -xpf "$ARCHIVE" -C "$ROOTFS"

say "creating writable host state and spool directories"
mkdir -p "$STATE_DIR/state" "$STATE_DIR/spool" "$HEALTH_DIR"
chmod 755 "$STATE_DIR" "$STATE_DIR/state" "$STATE_DIR/spool" "$HEALTH_DIR"

say "installing the nspawn machine configuration"
install -D -m 644 "$HERE/config/nspawn/$MACHINE_NAME.nspawn" "/etc/systemd/nspawn/$MACHINE_NAME.nspawn"

say "installing the systemd drop-in (port $IPP_PORT)"
mkdir -p "/etc/systemd/system/$UNIT.d"
sed "s|@IPP_PORT@|$IPP_PORT|g" \
    "$HERE/config/systemd/$UNIT.d/override.conf" > "/etc/systemd/system/$UNIT.d/override.conf"
chmod 644 "/etc/systemd/system/$UNIT.d/override.conf"

say "installing the USB udev rule"
# Distinct filename: the bootc host already ships 70-konica206.rules.
install -D -m 644 "$HERE/udev/70-konica206.rules" /etc/udev/rules.d/75-konica206-frozen.rules
udevadm control --reload || true

say "installing the IPP health check under /var (bootc-safe)"
install -D -m 755 "$HERE/scripts/health-check.sh" "$HEALTH_DIR/health-check.sh"
install -D -m 755 "$HERE/scripts/verify-raster-only.sh" "$HEALTH_DIR/verify-raster-only.sh"
install -D -m 644 "$HERE/config/ipp/get-printer-attributes.test" "$HEALTH_DIR/get-printer-attributes.test"
printf '%s\n' "$IPP_PORT" > "$HEALTH_DIR/port"
chmod 644 "$HEALTH_DIR/port"
# systemd runs as init_t; a script inherited from /var/lib may be var_lib_t and
# fail with 203/EXEC. Label it bin_t and persist the rule across relabels.
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t bin_t "$HEALTH_DIR/health-check.sh" 2>/dev/null || \
            semanage fcontext -m -t bin_t "$HEALTH_DIR/health-check.sh" || true
        semanage fcontext -a -t bin_t "$HEALTH_DIR/verify-raster-only.sh" 2>/dev/null || \
            semanage fcontext -m -t bin_t "$HEALTH_DIR/verify-raster-only.sh" || true
    fi
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v "$HEALTH_DIR/health-check.sh" "$HEALTH_DIR/verify-raster-only.sh" || true
    fi
fi

HC_UNIT=konica206-frozen-healthcheck.service
HC_TIMER=konica206-frozen-healthcheck.timer
say "installing $HC_UNIT and $HC_TIMER"
sed "s|@IPP_PORT@|$IPP_PORT|g" "$HERE/systemd/$HC_UNIT" > "/etc/systemd/system/$HC_UNIT"
install -D -m 644 "$HERE/systemd/$HC_TIMER" "/etc/systemd/system/$HC_TIMER"
chmod 644 "/etc/systemd/system/$HC_UNIT" "/etc/systemd/system/$HC_TIMER"

say "enabling and starting $UNIT"
systemctl daemon-reload
systemctl enable --now "$UNIT" "$HC_TIMER"
ensure_printer

say "done"
echo "Status:   systemctl status $UNIT"
echo "IPP:      ipp://127.0.0.1:$IPP_PORT/ipp/print/konica206"
echo "Health:   $HEALTH_DIR/health-check.sh"
echo "Raster:   $HEALTH_DIR/verify-raster-only.sh"
echo "Rollback: sudo scripts/remove-host-integration.sh"
