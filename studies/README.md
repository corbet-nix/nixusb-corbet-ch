# studies

Durable conclusions — the world as it is, once an experiment has settled a question. Each study
should cite the [`../experiments/`](../experiments/README.md) entry that produced it.

| Study | Conclusion |
|---|---|
| _(none yet)_ | |

## Why this module exists at all

The one conclusion already settled, inherited rather than derived here: **device indexes are not
portable.** `nixgpu` root-caused this for DRM on 2026-07-24 on a production single-GPU cluster, then
hit it for real on 2026-07-29 when a DisplayLink dock's `evdi` module took `card1` and moved an
RX 6800 to `card2` while a device plugin was still binding a hardcoded `/dev/dri/card1`.

USB has the identical property and a worse blast radius, because far more devices are hotpluggable
and far more of them are moved between machines. The conclusion transfers directly; only the key
changes, from PCI vendor ID to USB vendor/product/serial.

The corollary that shaped the schema: **a device with a serial has host-independent identity, and a
device without one does not.** That asymmetry is why serial-less devices are supported but capped at
one unit per model, enforced at build time rather than documented as a caveat.
