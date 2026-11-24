# Phases 3-4: connect the host and accept

Do these on the target Fedora machine with the real printer attached. A green
CI run is **not** proof that printing works. Do not retire the old
Debian/Podman setup until this page is complete.

## Host installation (Phase 2 recap)

```sh
sudo mkdir -p /var/lib/machines/konica-frozen
sudo tar -C /var/lib/machines/konica-frozen -xpf konica206-frozen-2026-11.tar.zst
sudo install -D -m 644 konica-frozen.nspawn /etc/systemd/nspawn/konica-frozen.nspawn
sudo install -D -m 644 override.conf /etc/systemd/system/systemd-nspawn@konica-frozen.service.d/override.conf
sudo sed -i 's/@IPP_PORT@/8001/' /etc/systemd/system/systemd-nspawn@konica-frozen.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl enable --now systemd-nspawn@konica-frozen.service
```

`scripts/install-host-integration.sh` does all of the above (including checksum
verification, state/spool directories, udev rule and health check) in one step.

## Phase 3: host queue

CUPS 2.4 (current Fedora): create a driverless queue. CUPS converts PDF to
raster on the host before sending it to the raster-only container.

```sh
sudo lpadmin -p konica206 -E -v ipp://127.0.0.1:8001/ipp/print/konica206 -m everywhere
```

CUPS 3.0 needs no queue: the printer appears as an IPP Everywhere endpoint.
**Unverified:** how CUPS 3.0 converts PDF for a printer that does not accept
PDF. Test it before relying on it.

## Phase 4: acceptance matrix

1. **Capabilities.** Run `ipptool` and confirm PDF is not in
   `document-format-supported`:
   ```sh
   /var/lib/konica206-frozen/health/verify-raster-only.sh
   ipptool -tv ipp://127.0.0.1:8001/ipp/print/konica206 \
     /var/lib/konica206-frozen/health/get-printer-attributes.test
   ```
2. **Paper tests.** Print and inspect:
   - A4 simplex page;
   - a multi-page job;
   - a duplex job (long-edge and short-edge);
   - two copies.
3. **Margins.** Check page sizes and margins from LibreOffice against the
   engine's imageable area (12 pt / 4.23 mm inset from e2855dd).
4. **Recovery.** Unplug and replug the printer, then reboot the host. The
   service must return without manual intervention.
5. **Do not** use CUPS test pages or banner sheets. They wedge the printer
   through PAPPL; recovery needs the classic queue and a power cycle.

Record results (date, document, settings, observed output) in the issue/PR that
retires the old setup. Keep the frozen tarball and its SHA256 until every row
has passed repeatedly.

## Rollback

```sh
sudo scripts/remove-host-integration.sh
# restore the previously stopped Debian/Podman service and its queue
```

The old service and CUPS configuration are never modified by this project.
