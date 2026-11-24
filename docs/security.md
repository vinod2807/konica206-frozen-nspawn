# Security decisions

- **No network exposure.** The container shares the host network namespace
  without a veth, and the app is started with `-o listen=localhost`. Both the
  IPP endpoint and PAPPL's unauthenticated web interface are reachable only
  from the host. Nothing ever listens on the LAN.
- **Immutable image.** `ReadOnly=yes` in the `.nspawn` file and `--read-only`
  on the command line. The image has no `apk` binary, `/etc/apk`, `/lib/apk` or
  `/var/cache/apk`, so nothing in it can install or update packages.
- **Minimal writable surface.** Only `/var/lib` (PAPPL state) and `/var/tmp`
  (job/raster spool) are host binds. `/tmp` and `/run` are small tmpfs mounts.
- **Minimal device access.** `/dev/bus/usb` is bound, not all of `/dev`. The
  device cgroup allows the USB character-device group only; no `--privileged`.
  The host udev rule matches the printer's `132b:232b` IDs.
- **No second print stack inside the container.** No cupsd, no cups-filters,
  no Ghostscript, no Python, no OpenRC. The host CUPS does the PDF→raster step.
- **Bounded supervision.** `Restart=on-failure`, `RestartSec=10s`, 5 starts per
  300 s. An unplugged printer does not stop the app, so there is no hot restart
  loop.
- **Resource limits.** Lowered CPU and IO weights. No memory cap until Phase 5
  produces a measured value. The renderer child inherits CPU/address-space/file
  limits from the app's existing filter sandbox.
- **Proprietary data.** The halftone screen and ICC profiles are supplied by
  the user at build time. No binary, tarball or repository published here
  contains them. See [upstream-pins.md](upstream-pins.md).
- **No secrets.** No credentials, keys or tokens are stored in this repository.
