# Upstream pins and the raster-only patch

| Input | Pin |
|---|---|
| Alpine minirootfs | 3.24.2 x86_64, SHA256 `c5ca053cfe1d85c5b96dff8b9bc57045f7f184a30ffb6b65776409ca90388677` |
| PAPPL | 1.3.1, commit `8eb465be78469c1344e7305bf02d305ee7907e36` |
| Printer application | `konica206-native-alpine` commit `e2855dd2ad3ec77cb35ec717b68bb26a2f94ec0d` ("Render inside the bizhub 206 imageable area") |
| Renderer | `konica-native-musl` commit `e1d522ed8c655541469b6aa49c5ecdec76b7b9d6` |
| Host | Fedora with systemd-nspawn, CUPS 2.4, `cups-ipptool` |

Pins live in [`config/pins.env`](../config/pins.env). The application commit is
**not** tip-of-main: the patch was written against `e2855dd` and CI checks that
it applies to that exact revision.

## What `patches/raster-only.patch` changes

The upstream application always sets `d->format = "application/pdf"`, which
makes PAPPL advertise PDF in `document-format-supported`. Rendering PDF inside
the container is what pulls in Ghostscript (or `cups-filters` + `pdftoraster`).
The patch:

- adds `KONICA_RASTER_ONLY` to the app configuration (`1` enables the mode);
- when enabled, sets the PAPPL driver format to `application/octet-stream`
  (the always-present raw type) and removes the PDF `printfile_cb`, so
  `document-format-supported` contains PWG raster, URF, JPEG and PNG but
  **not** `application/pdf`;
- adds `make check-raster-only`, a regression test that runs as an ordinary
  user with no printer, USB device, CUPS queue, Ghostscript or vendor data.

With raster-only mode on, the PDF→raster step belongs to the host's CUPS 2.4
driverless queue. See [architecture.md](architecture.md).

## Proprietary runtime data

The renderer needs three Konica Minolta files at runtime:

```text
Halftones/COPA.DEFAULT.600x600.hft
Profiles/sRGB.icm
Profiles/sGrayInv.icm
```

They are **not** in this repository, not downloaded by CI and not in the
published tarball. Supply them from a driver you already own, either as an
extracted directory (`KONICA_VENDOR_DATA_DIR`) or as the vendor zip
(`KONICA_VENDOR_ZIP`, the x86_64 `.deb` inside `BH225iGDILinux_201MU.zip`).
The build script copies them into
`/usr/local/lib/konica/KonicaMinolta/245igdi/` immediately before the freeze.

## Update policy

1. Change pins and this document together.
2. Rebase the patch and re-run CI, including `make check-raster-only`.
3. Build in a scratch rootfs; never mutate a known-good frozen rootfs in place.
4. Re-run the physical smoke tests before switching the service over.
5. Keep the previous tarball and SHA256 until the new one passes acceptance.
