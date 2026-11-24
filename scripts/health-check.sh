#!/bin/sh
# Phase 4 helper: confirm the PAPPL IPP endpoint answers on localhost.
# Retries briefly because the app can take a few seconds to bind its listener.
#
#   /var/lib/konica206-frozen/health/health-check.sh
#   IPP_PORT=8002 sh scripts/health-check.sh      # from a source checkout
set -u

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
UNIT="systemd-nspawn@${MACHINE_NAME:-konica-frozen}.service"

if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        echo "NOTE: $UNIT is not active" >&2
    fi
fi

probe() {
    if command -v ipptool >/dev/null 2>&1 && [ -r "$TEST_FILE" ]; then
        # -q suppresses even the PASS line on success, so do not use it here.
        OUT=$(ipptool -t "$URL" "$TEST_FILE" 2>&1) || return 1
        case "$OUT" in
            *'[PASS]'*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    # Shallow fallback: any HTTP response means the listener is up.
    if command -v curl >/dev/null 2>&1; then
        CODE=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/ipp/print/konica206" 2>/dev/null || true)
        case "$CODE" in
            000|'') return 1 ;;
            *) return 0 ;;
        esac
    fi
    return 2
}

n=0
while [ "$n" -lt 10 ]; do
    if probe; then
        if command -v ipptool >/dev/null 2>&1 && [ -r "$TEST_FILE" ]; then
            echo "HEALTHY: $URL answered GetPrinterAttributes"
        else
            echo "HEALTHY (shallow HTTP probe only; install cups-ipptool for a real check)"
        fi
        exit 0
    fi
    n=$((n + 1))
    [ "$n" -lt 10 ] && sleep 1
done

echo "UNHEALTHY: $URL did not respond after 10 attempts" >&2
[ -n "${OUT:-}" ] && echo "$OUT" >&2
exit 1
