# Phase 1: build the frozen rootfs

`scripts/build-frozen-rootfs.sh` automates steps 2-7 below. The output is one
tarball, `konica206-frozen-2026-11.tar.zst`, plus a `.sha256` file.

## Prerequisites

- An existing Alpine rootfs from
  [`konica206-alpine-nspawn`](https://github.com/vinod2807/konica206-alpine-nspawn)
  (`create-alpine-rootfs.sh` + `install-alpine-dependencies.sh` have already
  run). Point `ROOTFS` at it; keep a backup, because the script rebuilds the
  app in place before snapshotting.
- Host tools: `git`, `tar` with `--zstd` (GNU tar 1.31+), `zstd`, `sha256sum`,
  `unzip` (only if extracting from the vendor zip), root privileges.
- The three vendor files, either extracted (`KONICA_VENDOR_DATA_DIR`) or in the
  vendor zip (`KONICA_VENDOR_ZIP`, default from Downloads is not assumed).

Network access to GitHub and the Alpine CDN is needed on first build; sources
are cached under `$CACHE_DIR/sources` and pinned with `git reset --hard`.

## What the script does

1. **Patch and test as a normal user.** Fetches `konica206-native-alpine` at
   `e2855dd`, applies `patches/raster-only.patch`, copies it into the build
   rootfs, creates an unprivileged `konbuild` user there and runs
   `make check-raster-only` via `su`. No printer, USB, CUPS, Ghostscript or
   vendor data is involved.
2. **Rebuild.** Builds PAPPL 1.3.1 (if absent), `konica-native` (with its
   vendor-free `make check`) and the patched app (`make`, `make check`,
   `make install`), installs the upstream PPD under `/usr/local/share/konica`.
3. **Strip.** Removes `ghostscript`, `cups-filters` and `python3` plus the
   temporary `apk --virtual .konica-build` set. Runs `ldd` on both binaries
   before and after; any `not found` soname is mapped back to a package:

   | SONAME | Package |
   |---|---|
   | `libcups.so*`, `libcupsimage.so*` | `cups-libs` |
   | `libusb-1.0.so*` | `libusb` |
   | `libpng*` | `libpng` |
   | `libjpeg*` | `libjpeg-turbo` |
   | `libssl.so*`, `libcrypto.so*` | `openssl` |
   | `libz.so*` | `zlib` |
   | `libavahi*` | `avahi` |
   | `libintl.so*` | `gettext-libs` |
   | `libzstd.so*` | `zstd-libs` |
   | `libbrotli*` | `brotli-libs` |
   | `libgnutls.so*`, `libdbus-1.so*`, `libp11-kit.so*`, `libidn2.so*`, `libunistring.so*` | their Alpine runtime packages |

   An unknown missing library is a hard error: add it to the mapping rather
   than shipping a rootfs that cannot start.
4. **Vendor data.** Copies exactly three files into
   `/usr/local/lib/konica/KonicaMinolta/245igdi/`. For the zip input, the
   script reads the x86_64 `.deb` member offsets with `dd` (no `dpkg`/`ar`
   needed) and extracts the files from its `data.tar.*`.
5. **Remove apk.** Deletes `/etc/apk`, `/lib/apk`, `/var/cache/apk` and the
   `apk` binary itself, then asserts they are gone.
6. **Snapshot.** Writes an install manifest (pins, both `ldd` reports, package
   list), cleans `/tmp`, `/var/tmp` and the build tree, then creates the tarball
   with `tar --zstd` and writes a SHA256 next to it.

## Commands

```sh
# From an extracted vendor directory:
sudo -E KONICA_VENDOR_DATA_DIR=/path/to/245igdi \
  ROOTFS=/var/lib/machines/alpine-konica \
  scripts/build-frozen-rootfs.sh

# Or from the driver zip:
sudo -E KONICA_VENDOR_ZIP=/home/vinod/Downloads/BH225iGDILinux_201MU.zip \
  ROOTFS=/var/lib/machines/alpine-konica \
  scripts/build-frozen-rootfs.sh
```

Outputs (in the current directory by default):

```text
konica206-frozen-2026-11.tar.zst
konica206-frozen-2026-11.tar.zst.sha256
```

## Verify before deploying

```sh
sha256sum -c konica206-frozen-2026-11.tar.zst.sha256
tar --zstd -tf konica206-frozen-2026-11.tar.zst | grep usr/local/bin/konica206-native
tar --zstd -xOf konica206-frozen-2026-11.tar.zst \
  ./usr/local/share/konica206-frozen/INSTALL_MANIFEST.txt
tar --zstd -tf konica206-frozen-2026-11.tar.zst | grep -E '^\./(etc|lib)/apk' && echo 'BAD: apk present' || true
```

The last command must print nothing. If it finds apk files, do not deploy.
