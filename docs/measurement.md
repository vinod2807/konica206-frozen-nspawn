# Phase 5: measure before optimising

Compare three configurations during one identical print job:

1. this nspawn container in raster-only mode;
2. the nspawn container with PDF (the source project, no freeze);
3. the static build (`konica206-static-systemd`, no container).

Use the same document, page size, resolution, copies and duplex settings for
every run. Do not use estimates as evidence.

```sh
# Container-level view
systemd-cgtop
machinectl status konica-frozen
systemctl show systemd-nspawn@konica-frozen.service -p MemoryCurrent -p CPUUsageNSec

# Process-level view (server vs renderer child)
ps -o rss,pcpu -C konica206-native,konica-native

# Disk footprint
du -sh /var/lib/machines/konica-frozen
du -sh /var/lib/konica206-frozen/state /var/lib/konica206-frozen/spool
```

Reference figures from the plan (not acceptance evidence): the server was
measured at about **11 MB idle with 3 threads**; Ghostscript used **28 MB and
0.09 s** for one simple A4 page at 600 dpi.

If the remaining cost is in `konica-native` or the spool files rather than
Ghostscript, that is the next thing to fix: linking the renderer into the
server would remove the child process and the spool files.

## Memory cap

`override.conf` ships with lowered `CPUWeight=50` and `IOWeight=50`, but no
memory cap. Add a `MemoryMax=` value only after measuring peak RSS/PSS here and
verifying that a multi-page 600 dpi job still completes. Record the value and
the measurement that justifies it in this document.
