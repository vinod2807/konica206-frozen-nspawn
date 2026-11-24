#!/bin/sh
# Phase 4 acceptance check #1: PDF must not be in document-format-supported.
# Run on the Fedora host with cups-ipptool installed:
#
#   /var/lib/konica206-frozen/health/verify-raster-only.sh
#   IPP_PORT=8002 sh scripts/verify-raster-only.sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PORT=${IPP_PORT:-}
if [ -z "$PORT" ] && [ -r "$HERE/port" ]; then
    PORT=$(cat "$HERE/port")
fi
PORT=${PORT:-8001}
URL="ipp://127.0.0.1:$PORT/ipp/print/konica206"
if [ -r "$HERE/get-printer-attributes.test" ]; then
    TEST_FILE=$HERE/get-printer-attributes.test
else
    TEST_FILE=$HERE/../config/ipp/get-printer-attributes.test
fi

command -v ipptool >/dev/null 2>&1 || {
    echo "ERROR: ipptool not found (install cups-ipptool on the Fedora host)" >&2
    exit 2
}
[ -r "$TEST_FILE" ] || { echo "ERROR: test file missing: $TEST_FILE" >&2; exit 2; }

OUT=$(ipptool -tv "$URL" "$TEST_FILE" 2>&1) || {
    printf '%s\n' "$OUT" >&2
    echo "ERROR: GetPrinterAttributes failed" >&2
    exit 1
}

if printf '%s\n' "$OUT" | grep -qi 'application/pdf'; then
    echo "FAIL: application/pdf is still advertised by $URL" >&2
    printf '%s\n' "$OUT" | grep -i 'document-format' >&2 || true
    exit 1
fi
if ! printf '%s\n' "$OUT" | grep -qi 'image/pwg-raster'; then
    echo "FAIL: no raster format advertised by $URL" >&2
    exit 1
fi

echo "PASS: $URL is raster-only (no application/pdf, PWG raster advertised)"
