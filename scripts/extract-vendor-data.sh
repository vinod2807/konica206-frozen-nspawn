#!/bin/sh
# Extract the three proprietary runtime files the renderer needs.
#
#   scripts/extract-vendor-data.sh DEST_DIR
#
# Source is either:
#   KONICA_VENDOR_DATA_DIR=/path/to/245igdi  (already contains Halftones/ and
#                                             Profiles/)
# or:
#   KONICA_VENDOR_ZIP=/path/to/BH225iGDILinux_201MU.zip
#   (the x86_64 .deb inside the vendor zip; extracted here on the HOST, never
#    downloaded by this project and never shipped in the frozen rootfs).
#
# No dpkg/ar is needed: the .deb's ar member offsets are read with dd and the
# data.tar member is streamed straight into tar.

set -eu

DEST=${1:-}
FILES="Halftones/COPA.DEFAULT.600x600.hft Profiles/sRGB.icm Profiles/sGrayInv.icm"

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$DEST" ] || die "usage: $0 DEST_DIR"
mkdir -p "$DEST/Halftones" "$DEST/Profiles"

VENDOR_DIR=${KONICA_VENDOR_DATA_DIR:-}
if [ -n "$VENDOR_DIR" ]; then
    [ -d "$VENDOR_DIR" ] || die "KONICA_VENDOR_DATA_DIR is not a directory: $VENDOR_DIR"
    for f in $FILES; do
        [ -r "$VENDOR_DIR/$f" ] || die "missing vendor file: $VENDOR_DIR/$f"
    done
    for f in $FILES; do
        install -m 644 "$VENDOR_DIR/$f" "$DEST/$f"
    done
    say "copied vendor files from $VENDOR_DIR"
    exit 0
fi

ZIP=${KONICA_VENDOR_ZIP:-}
[ -n "$ZIP" ] && [ -f "$ZIP" ] || die "set KONICA_VENDOR_DATA_DIR, or KONICA_VENDOR_ZIP to the vendor driver zip"
command -v unzip >/dev/null 2>&1 || die "unzip is required to read the vendor zip"
command -v tar >/dev/null 2>&1 || die "tar is required to read the vendor .deb"

# Locate the data.tar.* member in an ar archive (deb). Sets TAR_NAME,
# TAR_OFFSET and TAR_SIZE.
find_data_tar() {
    deb=$1
    off=8
    n=0
    while [ "$n" -lt 10 ]; do
        # Read the fixed-width ar fields directly from the file: the header's
        # "`\n" magic would split a shell variable into two lines for cut.
        name=$(dd if="$deb" bs=1 skip="$off" count=16 2>/dev/null | tr -d ' \t')
        size=$(dd if="$deb" bs=1 skip=$((off + 48)) count=10 2>/dev/null | tr -d ' \t')
        name=${name%/}
        case "$size" in
            ''|*[!0-9]*) return 1 ;;
        esac
        off=$((off + 60))
        case "$name" in
            data.tar*)
                TAR_NAME=$name
                TAR_OFFSET=$off
                TAR_SIZE=$size
                return 0
                ;;
        esac
        off=$((off + size + (size % 2)))
        n=$((n + 1))
    done
    return 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/konica-vendor.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

say "extracting the x86_64 driver package from $ZIP"
unzip -q -j "$ZIP" '*/For_x86_64/*amd64.deb' -d "$TMP"
DEB=$(find "$TMP" -maxdepth 1 -name '*.deb' | head -1)
[ -n "$DEB" ] || die "no x86_64 .deb found in $ZIP"

find_data_tar "$DEB" || die "no data.tar member found in $DEB"
say "reading $TAR_NAME from the driver package"
dd if="$DEB" bs=1 skip="$TAR_OFFSET" count="$TAR_SIZE" 2>/dev/null > "$TMP/$TAR_NAME"

case "$TAR_NAME" in
    *.xz)  TARFLAGS=xJf ;;
    *.gz)  TARFLAGS=xzf ;;
    *.bz2) TARFLAGS=xjf ;;
    *)     TARFLAGS=xf  ;;
esac

mkdir -p "$TMP/unpacked"
tar -"$TARFLAGS" "$TMP/$TAR_NAME" -C "$TMP/unpacked" \
    ./usr/lib/cups/filter/KonicaMinolta/245igdi/Halftones/COPA.DEFAULT.600x600.hft \
    ./usr/lib/cups/filter/KonicaMinolta/245igdi/Profiles/sRGB.icm \
    ./usr/lib/cups/filter/KonicaMinolta/245igdi/Profiles/sGrayInv.icm

SRC="$TMP/unpacked/usr/lib/cups/filter/KonicaMinolta/245igdi"
for f in $FILES; do
    [ -r "$SRC/$f" ] || die "vendor file not found in driver package: $f"
    install -m 644 "$SRC/$f" "$DEST/$f"
done

say "copied vendor files from $ZIP"
