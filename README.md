# konica206-frozen-nspawn

Frozen, minimal IPP Everywhere print server for the **Konica Minolta bizhub 206**
on a Fedora bootc host.

This repository is the implementation of the "Frozen minimal IPP Everywhere
print server for the bizhub 206" plan. It keeps the existing nspawn/Alpine
setup from [`konica206-alpine-nspawn`](https://github.com/vinod2807/konica206-alpine-nspawn),
but makes four deliberate changes:

- the app runs **raster-only** (`KONICA_RASTER_ONLY=1`): no Ghostscript, no
  `pdftoraster`, no PDF in `document-format-supported`;
- the rootfs is **frozen read-only** and has **no package manager**;
- IPP listens on **localhost only** (`-o listen=localhost`, no veth);
- all state is in two host directories, so the image itself never changes.

> This repository does **not** modify the source repo. It consumes pinned
> upstream sources, adds one patch, and publishes a tarball plus host config.
> It does not contain Konica proprietary runtime data.

## How it works

```
Fedora host (systemd-nspawn@konica-frozen.service)
└── /var/lib/machines/konica-frozen        ← read-only frozen rootfs (no apk)
    └── konica206-native server            ← PID 1, -o listen=localhost
        ├── konica-native (renderer child)
        └── libusb → /dev/bus/usb (132b:232b)

host IPP endpoint: ipp://127.0.0.1:8001/ipp/print/konica206
   └── CUPS 2.4 driverless queue converts PDF → raster on the HOST
```

PAPPL advertises PWG/URF/JPEG/PNG only. CUPS 2.4 on the Fedora host does the
PDF→raster conversion before submitting the job; nothing in the container ever
sees a PDF. See [docs/architecture.md](docs/architecture.md).

## Phases

| Phase | What | Deliverable in this repo |
|---|---|---|
| 1 | Build the frozen rootfs | [`patches/raster-only.patch`](patches/raster-only.patch), [`scripts/build-frozen-rootfs.sh`](scripts/build-frozen-rootfs.sh), [`scripts/extract-vendor-data.sh`](scripts/extract-vendor-data.sh) |
| 2 | Run it read-only on localhost | [`config/nspawn/konica-frozen.nspawn`](config/nspawn/konica-frozen.nspawn), [`config/systemd/.../override.conf`](config/systemd/systemd-nspawn@konica-frozen.service.d/override.conf), [`scripts/install-host-integration.sh`](scripts/install-host-integration.sh) |
| 3 | Connect the host | [`cups/README.md`](cups/README.md) |
| 4 | Acceptance | [`docs/acceptance.md`](docs/acceptance.md), [`scripts/verify-raster-only.sh`](scripts/verify-raster-only.sh) |
| 5 | Measure | [`docs/measurement.md`](docs/measurement.md) |

## Quick start

On a build machine with git, GNU tar (`--zstd`), zstd and the vendor driver zip:

```sh
# 1. Build the frozen rootfs from an existing Alpine rootfs populated by the
#    source project. The patch is applied and make check-raster-only runs as
#    an unprivileged user inside the build rootfs.
sudo -E KONICA_VENDOR_ZIP=~/Downloads/BH225iGDILinux_201MU.zip \
  ROOTFS=/var/lib/machines/alpine-konica \
  scripts/build-frozen-rootfs.sh

# 2. Install on the Fedora target host (archive + .sha256 copied over).
sudo scripts/install-host-integration.sh ./konica206-frozen-2026-11.tar.zst

# 3. Connect host CUPS (CUPS 2.4, no PPD on the host).
sudo lpadmin -p konica206 -E -v ipp://127.0.0.1:8001/ipp/print/konica206 -m everywhere

# 4. Accept: verify no PDF, print on paper, unplug/replug, reboot.
/var/lib/konica206-frozen/health/verify-raster-only.sh
```

See [docs/build.md](docs/build.md) for every input and the library re-add
logic, and [docs/acceptance.md](docs/acceptance.md) before retiring the old
setup. **Never print CUPS test pages or banner sheets**: they wedge the printer
through PAPPL and need a classic queue plus a power cycle to recover.

## Repository layout

```text
config/pins.env                                      pinned inputs
config/nspawn/konica-frozen.nspawn                   read-only machine + host binds
config/systemd/.../override.conf                     service drop-in (@IPP_PORT@)
config/ipp/get-printer-attributes.test               ipptool probe
patches/raster-only.patch                            app patch at e2855dd
scripts/build-frozen-rootfs.sh                       Phase 1 (steps 2-7)
scripts/extract-vendor-data.sh                       vendor files from dir or zip
scripts/install-host-integration.sh                  Phase 2
scripts/remove-host-integration.sh                   rollback
scripts/health-check.sh                              IPP liveness
scripts/verify-raster-only.sh                        acceptance check #1
systemd/                                             health-check units
udev/70-konica206.rules                              USB permissions (host side)
docs/                                                build/acceptance/measurement/security
cups/README.md                                       host queue recipe
.github/workflows/validate.yml                       static + patch + raster-only CI
```

## Safety properties

- Read-only root at both the `.nspawn` and command-line level; no `apk` binary,
  config or cache in the image.
- Only `/var/lib` (PAPPL state) and `/var/tmp` (job spool) are writable host
  binds; `/tmp` and `/run` are small tmpfs mounts.
- Host network namespace, `listen=localhost`: no LAN exposure of IPP or the
  PAPPL web interface.
- Only `/dev/bus/usb` and `/sys/bus/usb/devices` are passed through, plus a
  device-cgroup `DeviceAllow=char-usb_device rwm` rule.
- Lowered `CPUWeight`/`IOWeight`; memory cap deliberately commented out until
  Phase 5 provides a measured number.
- Proprietary halftone/ICC data is supplied by the user at build time and is
  not redistributed.

## Pinned inputs

See [`docs/upstream-pins.md`](docs/upstream-pins.md) and `config/pins.env`.
The application is pinned to `e2855dd2ad3ec77cb35ec717b68bb26a2f94ec0d`; CI
verifies the patch applies to exactly that revision.
