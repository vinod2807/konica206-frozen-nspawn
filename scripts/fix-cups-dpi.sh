#!/bin/sh
# Fix the CUPS 2.4 driverless-queue DPI mismatch on the Fedora host.
#
# CUPS's generated IPP Everywhere PPD defaults to 300 dpi even though the
# container advertises printer-resolution-default = 600dpi. The renderer is
# fixed at 600 dpi, so a 300 dpi raster prints in one quarter of the page.
# This patches the queue's generated PPD and its IPP quality default. Re-run it
# if the queue is ever recreated with `lpadmin -m everywhere`.
#
#   sudo scripts/fix-cups-dpi.sh [queue-name]     # default: konica206-frozen
set -eu

QUEUE=${1:-konica206-frozen}
PPD=/etc/cups/ppd/$QUEUE.ppd
say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ...)"
[ -f "$PPD" ] || die "PPD not found: $PPD (is the queue installed?)"

say "patching $PPD to use 600 dpi"
sed -i 's/^\*DefaultResolution: 300dpi/\*DefaultResolution: 600dpi/' "$PPD"
sed -i 's|^\*cupsPrintQuality Normal: "<</HWResolution\[300 300\]>>setpagedevice"|*cupsPrintQuality Normal: "<</HWResolution[600 600]>>setpagedevice"|' "$PPD"
grep -E '^\*(DefaultResolution|cupsPrintQuality (Normal|High):)' "$PPD" | head -3

say "setting print-quality-default=high on $QUEUE"
lpadmin -p "$QUEUE" -o print-quality-default=high
# Remove a resolution default set by an earlier attempt: together with the
# PPD default it would be advertised twice.
lpadmin -p "$QUEUE" -R printer-resolution-default 2>/dev/null || true

say "restarting CUPS so the new defaults are advertised"
systemctl restart cups

if command -v ipptool >/dev/null 2>&1; then
    TEST=$(mktemp "${TMPDIR:-/tmp}/konica-attrs.XXXXXX")
    trap 'rm -f "$TEST"' EXIT HUP INT TERM
    cat > "$TEST" <<'EOF'
{
  NAME "Check CUPS DPI defaults"
  OPERATION Get-Printer-Attributes
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR naturalLanguage attributes-natural-language en
  ATTR uri printer-uri $uri
  STATUS successful-ok
}
EOF
    OUT=$(ipptool -tv "ipp://localhost/printers/$QUEUE" "$TEST" 2>&1)
    printf '%s\n' "$OUT" | grep -i -E 'print-quality-default|printer-resolution-default' || true
    if printf '%s\n' "$OUT" | grep -qi 'Duplicate "printer-resolution-default"'; then
        die "duplicate printer-resolution-default attribute on $QUEUE"
    fi
else
    say "WARNING: ipptool not installed; could not verify the defaults"
fi

say "done"
echo "Confirm with a print job: the container log must say 'raster data is 4961x7016x8', not '2480x3508x8'."
