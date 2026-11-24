# Architecture

## Components

| Layer | Owner | Notes |
|---|---|---|
| Fedora bootc host systemd | Fedora | Owns `systemd-nspawn@konica-frozen.service`. |
| systemd-nspawn | systemd | Read-only root, host network namespace, USB bind, two writable host binds. |
| Frozen Alpine rootfs | this project | musl, libcups, libusb, PAPPL, app, renderer, vendor data. No apk, no Ghostscript, no cups-filters, no Python, no cupsd, no init. |
| `konica206-native` | upstream + patch | PAPPL app; the container's only process (PID 1). `-o listen=localhost`, `-o server-port=8001`. |
| `konica-native` | upstream | Renderer child: CUPS raster on stdin → halftoned/compressed printer stream on stdout → libusb. |
| Fedora CUPS 2.4 | Fedora | Optional driverless queue; converts PDF to raster on the host. Never opens USB. |

## Data flow (raster-only)

```text
IPP client / CUPS 2.4
   → PDF→raster conversion on the HOST (CUPS filter chain)
   → ipp://127.0.0.1:8001/ipp/print/konica206   (image/pwg-raster)
   → PAPPL in the container
   → 8-bit gray raster callbacks → compressed CUPS raster spool (/var/tmp)
   → konica-native (halftone + ICC profiles → JBIG1/PJL)
   → libusb, 8192-byte writes → bizhub 206 USB interface 1
```

The printer never receives a PDF from the container and the container never
runs a PDF interpreter. A direct client that submits `application/pdf` gets a
rejection rather than a render.

## Service model

Only the distribution's `systemd-nspawn@.service` template plus one drop-in is
used. The drop-in clears the template's `ExecStart` (which would boot
`/sbin/init` with private users and a veth) and runs
`/usr/local/bin/konica206-native server ...` directly. `.nspawn` contains no
`ExecStart=`, so there is a single place deciding how the app starts.

Host settings that must reach PID 1 are passed with nspawn's `--setenv=`:
`KONICA_RASTER_ONLY=1`, `KONICA_VENDOR_FILTER`, `KONICA_PPD` and
`TMPDIR=/var/tmp`. A systemd `Environment=` line applies to nspawn on the
host and is not inherited inside the container.

`Type=simple`, bounded `Restart=on-failure` (10 s, 5 starts / 300 s), and a
device-cgroup `DeviceAllow=char-usb_device rwm` rule complete the service.

## Filesystem

| Container path | Source | Purpose |
|---|---|---|
| `/` | frozen tarball, `ReadOnly=yes` + `--read-only` | all code and vendor data |
| `/var/lib` | host `/var/lib/konica206-frozen/state` | PAPPL state file |
| `/var/tmp` | host `/var/lib/konica206-frozen/spool` | CUPS raster and printer-stream spool (disk, not RAM) |
| `/tmp`, `/run` | tmpfs (64M / 16M) | volatile scratch |

The rootfs contains neither `/etc/apk`, `/lib/apk` nor `/var/cache/apk`; there
is no way to install anything into a running container.

## Network

`Private=no` and `VirtualEthernet=no` share the host network namespace, so
`127.0.0.1:8001` inside the container is the host's own loopback address.
`-o listen=localhost` binds both IPP and the PAPPL web interface to loopback.
Nothing is reachable from the LAN.

## USB

The host udev rule `udev/70-konica206.rules` matches `132b:232b`, sets
`MODE=0660`, `GROUP=lp` and `TAG+="uaccess"` so the node survives
unplug/replug. The nspawn config binds `/dev/bus/usb` and reads
`/sys/bus/usb/devices` for libusb enumeration. The device-cgroup rule is
required in addition to the bind, otherwise `libusb_open()` fails with EPERM.
Only one process may own interface 1 at a time: stop the legacy stack before
printing from this server.

## Health check

`konica206-frozen-healthcheck.timer` probes `GetPrinterAttributes` two minutes
after boot and every five minutes. `scripts/verify-raster-only.sh` is the
one-shot acceptance check that additionally fails if `application/pdf` appears
in `document-format-supported`.
