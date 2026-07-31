# experiments

Things tried against real hardware, with what actually happened. An experiment records an
*observation*; when one produces a durable conclusion, that conclusion moves to
[`../studies/`](../studies/README.md) and the experiment stays here as the evidence for it.

| Experiment | Question | Outcome |
|---|---|---|
| _(none yet)_ | | |

## Open questions worth an experiment

- **Do `ATTRS{}` matchers reliably reach every child subsystem?** The design assumes one rule per
  device stamps `NIXUSB_NAME` on `sound`, `video4linux`, `tty`, `hidraw` and `block` children alike,
  because `ATTRS{}` walks the parent chain. Verified by reading udev semantics, not yet by
  instrumenting a device that presents in several subsystems at once (a USB headset with an
  integrated HID volume control is the obvious candidate).

- **Composite devices with per-interface serials.** Some devices report `ATTRS{serial}` on the
  parent USB device but present interfaces whose own attributes differ. Does a single identity rule
  cover all interfaces, or do multi-function devices need per-interface handling?

- **Docked vs. direct enumeration.** A device behind a USB hub or dock enumerates with a different
  `ID_PATH` but the same serial. Confirm identity survives moving a device from a direct port to a
  dock port — this is the property the whole "device moves between machines" claim rests on.

- **Symlink directory behaviour on removal.** `SYMLINK+="usb/by-name/<name>/%k"` creates a directory
  per device. Confirm udev cleans the directory up on unplug rather than leaving an empty one.
