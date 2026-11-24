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

CUPS 3.0 needs no queue: the printer appears as an IPP Everywhere endpoint.
It is **unverified** whether CUPS 3.0 converts PDF for a printer that does not
accept PDF; test that before relying on it.

Never print a CUPS test page or enable banner sheets on this queue.
