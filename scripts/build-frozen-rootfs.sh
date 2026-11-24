#!/bin/sh
# Phase 1: turn the existing mutable Alpine rootfs into a frozen, read-only
# raster-only IPP Everywhere print server tarball.
#
#   sudo -E KONICA_VENDOR_ZIP=~/Downloads/BH225iGDILinux_201MU.zip \
#        scripts/build-frozen-rootfs.sh
#   sudo -E KONICA_VENDOR_DATA_DIR=/path/to/245igdi scripts/build-frozen-rootfs.sh
#
# Automates steps 2-7 of the frozen-server plan:
#   1. apply patches/raster-only.patch to konica206-native-alpine at the pin
#      and run make check-raster-only as an ordinary (non-root) user;
#   2. rebuild PAPPL/renderer/app inside the existing Alpine rootfs;
#   3. drop Ghostscript, cups-filters, python3 and the build packages, then
#      re-add any runtime libraries that disappeared (checked with ldd);
#   4. copy the three proprietary vendor files into the rootfs;
#   5. delete apk, its config and its caches;
#   6. snapshot to $FROZEN_ARCHIVE and write its SHA256.
# The pinned Alpine minirootfs/rootfs creation itself stays in the source repo;
# this script consumes an already populated rootfs and never modifies it
# until the final snapshot is ready. Keep a backup of the mutable rootfs.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
# pins.env's ROOTFS is the frozen install target. This script instead consumes
# the mutable rootfs from the source project unless ROOTFS was set explicitly.
ROOTFS_FROM_ENV=${ROOTFS:-}
# shellcheck source=/dev/null
. "$HERE/config/pins.env"
[ -n "$ROOTFS_FROM_ENV" ] || ROOTFS=/var/lib/machines/alpine-konica

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo -E ...) so the Alpine rootfs can be rebuilt"
[ -d "$ROOTFS" ] || die "rootfs missing: $ROOTFS (build it with konica206-alpine-nspawn first)"
[ -r "$HERE/$RASTER_ONLY_PATCH" ] || die "patch missing: $HERE/$RASTER_ONLY_PATCH"

# The Alpine minirootfs has no /dev entries. Create the basics before any
# chroot redirection: otherwise `cmd >/dev/null` silently creates a root-owned
# regular file and breaks later unprivileged steps.
if [ ! -c "$ROOTFS/dev/null" ]; then
    rm -f "$ROOTFS/dev/null"
    mknod -m 666 "$ROOTFS/dev/null" c 1 3
    mknod -m 666 "$ROOTFS/dev/zero" c 1 5
    mknod -m 666 "$ROOTFS/dev/random" c 1 8
    mknod -m 666 "$ROOTFS/dev/urandom" c 1 9
fi
for tool in git tar sha256sum install cp rm; do
    command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done
tar --help 2>&1 | grep -q -- '--zstd' || die "GNU tar with --zstd support is required"

CACHE="$CACHE_DIR/sources"
BUILD=/tmp/konica-frozen-build
SERIES=${ALPINE_VERSION%.*}

mkdir -p "$CACHE"

fetch_pinned() {
    fname=$1
    repo=$2
    rev=$3
    target="$CACHE/$fname"
    if [ ! -d "$target/.git" ]; then
        say "fetching $fname from $repo"
        git clone -q "$repo" "$target"
    fi
    say "pinning $fname to $rev"
    git -C "$target" reset --hard -q "$rev"
}

chroot_sh() {
    chroot "$ROOTFS" /bin/sh -c "$1"
}

ldd_both() {
    chroot_sh 'ldd /usr/local/bin/konica206-native; echo ---; ldd /usr/local/lib/konica/konica-native'
}

say "fetching and pinning upstream sources"
fetch_pinned pappl https://github.com/michaelrsweet/pappl.git "$PAPPL_COMMIT"
fetch_pinned konica-native-musl https://github.com/vinod2807/konica-native-musl.git "$KONICA_NATIVE_MUSL_COMMIT"
fetch_pinned konica206-native-alpine https://github.com/vinod2807/konica206-native-alpine.git "$KONICA206_NATIVE_ALPINE_COMMIT"

say "applying $RASTER_ONLY_PATCH"
APP="$CACHE/konica206-native-alpine"
git -C "$APP" apply --check "$HERE/$RASTER_ONLY_PATCH" || die "raster-only.patch does not apply to $KONICA206_NATIVE_ALPINE_COMMIT"
git -C "$APP" apply "$HERE/$RASTER_ONLY_PATCH"

say "installing temporary build packages inside the rootfs"
mkdir -p "$ROOTFS/etc/apk" "$ROOTFS/etc/apk/keys"
cat > "$ROOTFS/etc/apk/repositories" <<EOF
$ALPINE_BASEURL/v$SERIES/main
$ALPINE_BASEURL/v$SERIES/community
EOF
rm -f "$ROOTFS/etc/resolv.conf"
[ ! -r /etc/resolv.conf ] || cp -fL /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
chroot_sh 'apk update'
chroot_sh 'apk add --no-cache --virtual .konica-build build-base pkgconf musl-utils python3 cups-dev libusb-dev libpng-dev libjpeg-turbo-dev zlib-dev openssl-dev avahi-dev'

say "copying pinned sources into the rootfs"
chroot_sh "rm -rf $BUILD && mkdir -p $BUILD"
for name in pappl konica-native-musl konica206-native-alpine; do
    cp -a "$CACHE/$name" "$ROOTFS$BUILD/$name"
done

if [ ! -e "$ROOTFS/usr/local/lib/libpappl.so.1" ]; then
    say "building PAPPL $PAPPL_VERSION"
    chroot_sh "cd $BUILD/pappl && ./configure --prefix=/usr/local >/dev/null && make -j\$(nproc) >/dev/null && make install >/dev/null"
fi
chroot_sh 'grep -qxF /usr/local/lib /etc/ld.so.conf || echo /usr/local/lib >> /etc/ld.so.conf; ldconfig'

say "building and testing konica-native (renderer)"
chroot_sh "cd $BUILD/konica-native-musl && make CC=cc >/dev/null && make check >/dev/null && install -D -m755 konica-native /usr/local/lib/konica/konica-native"

say "running make check-raster-only as a normal user"
# Step 1's test must not run as root. Create a temporary unprivileged user in
# the build rootfs, hand it the patched source tree, and drop privileges with
# su for this one target only.
chroot_sh 'id konbuild >/dev/null 2>&1 || adduser -D -h /home/konbuild konbuild'
chroot_sh "chown -R konbuild:konbuild $BUILD/konica206-native-alpine"
chroot_sh "su -s /bin/sh konbuild -c 'cd $BUILD/konica206-native-alpine && make check-raster-only'"

say "building, testing and installing the patched app"
chroot_sh "PKG_CONFIG_PATH=/usr/local/lib/pkgconfig make -C $BUILD/konica206-native-alpine >/dev/null"
chroot_sh "PKG_CONFIG_PATH=/usr/local/lib/pkgconfig make -C $BUILD/konica206-native-alpine check"
chroot_sh "PKG_CONFIG_PATH=/usr/local/lib/pkgconfig make -C $BUILD/konica206-native-alpine install >/dev/null"
chroot_sh "install -D -m644 $BUILD/konica206-native-alpine/vendor/KonicaMinolta/KonicaMinolta-206-native.ppd /usr/local/share/konica/KonicaMinolta-206-native.ppd"
chroot_sh 'ldconfig'

LDD_BEFORE=$(mktemp "${TMPDIR:-/tmp}/konica-ldd-before.XXXXXX")
LDD_FINAL=$(mktemp "${TMPDIR:-/tmp}/konica-ldd-final.XXXXXX")
trap 'rm -f "$LDD_BEFORE" "$LDD_FINAL"' EXIT HUP INT TERM
ldd_both > "$LDD_BEFORE" 2>&1 || die "ldd failed on the freshly built binaries"
say "ldd of the freshly built binaries (saved in the manifest):"
cat "$LDD_BEFORE"

say "removing Ghostscript, cups-filters, python3 and the build packages"
chroot_sh 'apk del ghostscript cups-filters python3' || true
chroot_sh 'apk del .konica-build'

# Ghostscript/cups-filters used to pull in libraries the app still needs.
# ldd decides what comes back; nothing is re-added speculatively.
say "restoring runtime libraries reported missing by ldd"
n=0
while [ "$n" -lt 3 ]; do
    ldd_both > "$LDD_FINAL" 2>&1 || die "ldd failed after removing packages"
    # shellcheck disable=SC2013
    missing=$(awk '/not found/ {print $1}' "$LDD_FINAL" | sort -u)
    [ -n "$missing" ] || break
    pkgs=""
    for soname in $missing; do
        case "$soname" in
            libcups.so*|libcupsimage.so*) pkgs="$pkgs cups-libs" ;;
            libusb-1.0.so*)                pkgs="$pkgs libusb" ;;
            libpng*)                       pkgs="$pkgs libpng" ;;
            libjpeg*)                      pkgs="$pkgs libjpeg-turbo" ;;
            libssl.so*|libcrypto.so*)      pkgs="$pkgs openssl" ;;
            libz.so*)                      pkgs="$pkgs zlib" ;;
            libavahi*)                     pkgs="$pkgs avahi" ;;
            *) die "no known package provides $soname (add it to the mapping in this script)" ;;
        esac
    done
    # shellcheck disable=SC2086
    pkgs=$(printf '%s\n' $pkgs | sort -u | tr '\n' ' ')
    say "re-adding:$pkgs"
    # shellcheck disable=SC2086
    chroot_sh "apk add --no-cache $pkgs"
    n=$((n + 1))
done
[ -z "$(awk '/not found/ {print $1}' "$LDD_FINAL")" ] || die "unresolved library dependencies: $(cat "$LDD_FINAL")"
chroot_sh 'ldconfig'

say "installing the three proprietary vendor files"
VENDOR_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/konica-vendor-out.XXXXXX")
trap 'rm -f "$LDD_BEFORE" "$LDD_FINAL"; rm -rf "$VENDOR_STAGE"' EXIT HUP INT TERM
# shellcheck source=/dev/null
KONICA_VENDOR_DATA_DIR=${KONICA_VENDOR_DATA_DIR:-} \
KONICA_VENDOR_ZIP=${KONICA_VENDOR_ZIP:-} \
    "$HERE/scripts/extract-vendor-data.sh" "$VENDOR_STAGE"
VENDOR_DEST="$ROOTFS/usr/local/lib/konica/KonicaMinolta/245igdi"
mkdir -p "$VENDOR_DEST"
cp -a "$VENDOR_STAGE/." "$VENDOR_DEST/"

say "writing the frozen-rootfs manifest"
MANIFEST_DIR="$ROOTFS/usr/local/share/konica206-frozen"
mkdir -p "$MANIFEST_DIR"
{
    echo "Generated (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Alpine:          $ALPINE_VERSION ($ALPINE_ARCH)"
    echo "PAPPL:           $PAPPL_VERSION ($PAPPL_COMMIT)"
    echo "Application:     konica206-native-alpine ($KONICA206_NATIVE_ALPINE_COMMIT) + $(basename "$RASTER_ONLY_PATCH")"
    echo "Renderer:        konica-native-musl ($KONICA_NATIVE_MUSL_COMMIT)"
    echo "Runtime mode:    KONICA_RASTER_ONLY=1 (no Ghostscript, no cups-filters, no pdf renderer)"
    echo "Vendor data:     supplied from the host at build time; not redistributed"
    echo
    echo "ldd before package removal:"
    cat "$LDD_BEFORE"
    echo
    echo "ldd in the frozen rootfs:"
    cat "$LDD_FINAL"
    echo
    echo "Installed packages:"
    chroot_sh 'apk info 2>/dev/null | sort'
} > "$MANIFEST_DIR/INSTALL_MANIFEST.txt"

say "cleaning build residue, apk and its configuration/caches"
chroot_sh "rm -rf $BUILD /tmp/* /var/tmp/* /var/cache/apk"
chroot_sh 'rm -rf /etc/apk /lib/apk /var/cache/apk; rm -f /sbin/apk /usr/sbin/apk /bin/apk'
[ ! -e "$ROOTFS/sbin/apk" ] || die "apk binary still present in the frozen rootfs"
[ ! -d "$ROOTFS/etc/apk" ] || die "/etc/apk still present in the frozen rootfs"

ARCHIVE=$FROZEN_ARCHIVE
case "$ARCHIVE" in
    /*) ;;
    *) ARCHIVE="$PWD/$ARCHIVE" ;;
esac
say "snapshotting the frozen rootfs to $ARCHIVE"
tar --zstd -cf "$ARCHIVE.tmp" -C "$ROOTFS" .
mv "$ARCHIVE.tmp" "$ARCHIVE"
(cd "$(dirname "$ARCHIVE")" && sha256sum "$(basename "$ARCHIVE")") > "$ARCHIVE.sha256"
tar --zstd -tf "$ARCHIVE" >/dev/null

say "done"
echo "Archive:  $ARCHIVE"
echo "SHA256:   $(cat "$ARCHIVE.sha256")"
echo "Next:     sudo scripts/install-host-integration.sh $ARCHIVE"
