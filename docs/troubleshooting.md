# Troubleshooting

## Service will not start

```sh
systemctl status systemd-nspawn@konica-frozen.service
journalctl -u systemd-nspawn@konica-frozen.service -b
machinectl status konica-frozen
```

The drop-in has `ConditionPathExists=/var/lib/machines/konica-frozen/usr/local/bin/konica206-native`;
if the tarball was extracted to the wrong directory the unit is skipped rather
than failing. Check `ROOTFS` and re-install the archive.

## `application/pdf` still in document-format-supported

- Confirm the image was built from this repo: read
  `/usr/local/share/konica206-frozen/INSTALL_MANIFEST.txt` inside the container
  (or from the tarball). It must mention `KONICA_RASTER_ONLY=1`.
- Confirm the drop-in actually passes `--setenv=KONICA_RASTER_ONLY=1`; a service
  `Environment=` line would not reach the process in the container.
- Check that port `@IPP_PORT@` was substituted and that you are probing the
  right port (`8001`, or the side-by-side port you chose).

## USB device not found / `libusb_open()` EPERM

- Check the printer IDs: `lsusb | grep 132b:232b`.
- Confirm the host udev rule is installed as
  `/etc/udev/rules.d/75-konica206-frozen.rules` and reloaded.
- Confirm both `Bind=/dev/bus/usb`, `BindReadOnly=/sys/bus/usb/devices` and
  `DeviceAllow=char-usb_device rwm` are present. The bind alone is not enough:
  nspawn's device cgroup blocks the open.
- Only one process may own USB interface 1. Stop the legacy stack before
  testing this server.

## Frozen rootfs fails with a missing library

The build script maps `ldd`'s `not found` sonames to Alpine packages and
re-adds them before deleting apk. If a binary still fails, the manifest in the
tarball records both `ldd` reports. Rebuild with the missing soname added to
the mapping in `scripts/build-frozen-rootfs.sh`; do not try to `apk add`
anything at runtime.

## Spool files pile up

`/var/tmp` is a host directory (`/var/lib/konica206-frozen/spool`), not tmpfs.
A wedged job can leave `konica-out-*` / `konica-ras-*` files there. Stop the
service, inspect the files, remove only orphaned ones, then restart. Do not
delete the PAPPL state in `/var/lib/konica206-frozen/state` while the server is
running.

## Health check reports UNHEALTHY

Install `cups-ipptool` on the host for a real `GetPrinterAttributes` probe;
without it the script falls back to a shallow HTTP check. The script retries
for 10 seconds, so a slow boot is usually not a failure. Check the port file at
`/var/lib/konica206-frozen/health/port`.

## Print lands in one quarter of the page

The host CUPS queue is sending 300 dpi raster while the renderer is fixed at
600 dpi. Check the container log for `raster data is 2480x3508x8`; a correct
600 dpi A4 page is `4961x7016x8`. Fix the queue with
`sudo scripts/fix-cups-dpi.sh <queue-name>` (see [cups/README.md](../cups/README.md))
and print again. If `ipptool` shows `printer-resolution-default` twice, the
script removes the duplicate.

## Printer wedge after a test page

CUPS test pages and banner sheets can wedge the printer through PAPPL. Recovery
needs the classic queue plus a power cycle. Do not use them; see
[acceptance.md](acceptance.md).
