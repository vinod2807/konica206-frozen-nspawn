# Fedora host CUPS integration

The frozen container is raster-only: it deliberately does not advertise
`application/pdf`. CUPS 2.4 on the Fedora host converts PDF jobs to raster
before forwarding them, so a driverless queue is enough.

```sh
sudo lpadmin -p konica206 -E -v ipp://127.0.0.1:8001/ipp/print/konica206 -m everywhere
sudo cupsenable konica206
sudo cupsaccept konica206
```

Do **not** install the legacy Konica PPD or filter chain on the host for this
queue, and do not point it at the USB device: only the container may own USB
interface 1. If a queue already uses port 8001, install this project with
`IPP_PORT=8002` and use that port in the URI instead.

### Important: force 600 dpi on the host queue

CUPS 2.4's generated IPP Everywhere PPD defaults to **300 dpi** even though the
app advertises `printer-resolution-default = 600dpi`. The renderer is fixed at
600 dpi, so a 300 dpi raster prints in **one quarter of the page**. After
`lpadmin -m everywhere`, set the queue defaults to 600 dpi:

`scripts/fix-cups-dpi.sh` does this for you (pass the queue name if it is not
the default `konica206-frozen`):

```sh
sudo scripts/fix-cups-dpi.sh konica206
```

It patches the generated PPD (`DefaultResolution: 600dpi` and the Normal
quality mapping), sets `print-quality-default=high`, removes any duplicate
resolution default from earlier attempts, restarts CUPS and verifies the
attributes with `ipptool`. Re-run it if the queue is ever recreated with
`lpadmin -m everywhere`.

Alternatively, do it by hand and verify with
`ipptool -tv ipp://localhost/printers/konica206 <ppd-test>`: both
`print-quality-default = high` and `printer-resolution-default = 600dpi` should
appear exactly once. A print job's container log must say
`Page 1 raster data is 4961x7016x8`; `2480x3508x8` means 300 dpi.

CUPS 3.0 needs no queue: the printer appears as an IPP Everywhere endpoint.
It is **unverified** whether CUPS 3.0 converts PDF for a printer that does not
accept PDF; test that before relying on it.

Never print a CUPS test page or enable banner sheets on this queue.
