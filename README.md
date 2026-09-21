# nixusb

**The host's USB device inventory as declared data, and stable, enumeration-independent identity
stamped onto every device node those devices create.**

Status: **early.** The inventory, the udev projection, both planes (NixOS and system-manager) and the
evaluation checks are complete and proven. No consumer module ships against it yet.

## The problem

The kernel names USB-backed device nodes by **enumeration order**, not by hardware identity:

```
/dev/snd/card1     /dev/video0     /dev/ttyUSB0     /dev/sdb
```

That ordering is not stable across a reboot, a replug, a dock hotplug, or a kernel update — and it
is not stable across two machines with the same devices attached. Anything that hardcodes one of
those names is a latent bug waiting for a reboot.

This is the same failure class [`nixgpu`](https://github.com/corbet-nix/nixgpu-corbet-ch)'s
`stable-device-paths` solved for DRM, where a DisplayLink dock's `evdi` module claimed `card1` and
moved a real GPU to `card2` while a device plugin was still binding a hardcoded `/dev/dri/card1`.
`nixusb` is the USB-side sibling: same doctrine, different bus. It does not extend nixgpu's schema
(that one is DRM-specific — `hasRenderNode`, `vramMiB`, `bus = pci|platform`); it mirrors its shape
for devices identified by USB vendor/product/serial.

## The inventory is the point

```nix
nixusb.enable = true;

nixusb.devices = {
  hyperx = {
    vendorId = "03f0";
    productId = "06be";
    serial = "C1V51706C2";
    description = "HyperX Cloud III S Wireless headset";
    tags = [ "audio" "headset" ];
  };

  shure-mv5c = {
    vendorId = "14ed";
    productId = "1010";
    # This model reports no USB serial, so it is identified by model alone.
    description = "Shure MV5C USB microphone";
    tags = [ "audio" "microphone" ];
  };
};
```

`nixusb.devices` is readable at evaluation time **whether or not `nixusb.enable` is set**, because
its primary consumer is other *modules*, not udev. A sibling that needs to know "which USB audio
devices does this host have, and what is each called" reads this table — it is the only place that
fact is stated. Consumers read it defensively so nixusb stays an optional input:

```nix
let devices = config.nixusb.devices or { };
    audio = lib.filterAttrs (_: d: builtins.elem "audio" d.tags) devices;
in ...
```

At runtime the same table is projected onto udev:

```
ACTION!="remove", ATTRS{idVendor}=="03f0", ATTRS{idProduct}=="06be", ATTRS{serial}=="C1V51706C2", \
  ENV{NIXUSB_NAME}="hyperx", ENV{NIXUSB_TAGS}="audio:headset", TAG+="nixusb"
```

`ATTRS{}` walks the parent chain, so **one rule per device** stamps `NIXUSB_NAME` on the USB device
*and* on every child node it creates — `sound`, `video4linux`, `tty`, `hidraw`, `block` — without
enumerating them. A runtime consumer then matches on a name you chose rather than on a number the
kernel happened to hand out this boot.

## Identity, and when it is ambiguous

A device is identified by `vendorId:productId`, optionally narrowed by `serial`.

Many devices ship a real serial, and are then identifiable **no matter which host or port they are
plugged into** — which is what lets a device move between machines and still resolve to the same
name. Plenty ship none. Those are identifiable by model alone, which is fine while exactly one such
device exists and silently wrong the moment a second appears.

That is not left to chance. Declaring two serial-less devices with the same `vendorId:productId` is
a **build-time error**, not a warning:

```
nixusb.devices declares more than one device with no `serial` sharing a vendorId:productId:
  14ed:1010 — mic-a, mic-b

Without a serial these are indistinguishable to udev, so they would non-deterministically claim
each other's NIXUSB_NAME depending on enumeration order — the exact class of bug this module
exists to prevent.
```

Declaring the same physical identity twice is likewise an error. Both checks are **ungated on
`enable`**: a malformed inventory is wrong whether or not it is currently projected onto udev.

## Optional stable paths

Most consumers want `ENV{NIXUSB_NAME}` and never touch a filesystem path. For one that genuinely
needs to `open()` something:

```nix
nixusb.devices.hyperx.symlinkSubsystems = [ "sound" ];
```

yields a per-device **directory**, keeping the kernel name as the leaf:

```
/dev/usb/by-name/hyperx/controlC1
/dev/usb/by-name/hyperx/pcmC1D0p
/dev/usb/by-name/hyperx/pcmC1D0c
```

A directory rather than a flat symlink because a single USB device routinely creates several nodes
in one subsystem — a flat link would have them overwrite each other non-deterministically, which is
the bug, not the fix.

## Non-NixOS hosts

Both planes import the **same** `modules/options.nix`, so the inventory and its assertions are
defined exactly once and only the projection differs:

| Host | Import | Projection |
|---|---|---|
| NixOS | `nixosModules.nixusb` | `services.udev.extraRules` |
| Arch / CachyOS (system-manager) | `systemManagerModules.nixusb` | `environment.etc."udev/rules.d/70-nixusb-by-name.rules"` |

Rules are not retroactive on first apply — existing device nodes keep whatever identity they were
(or were not) stamped with. Replug the device, or:

```
udevadm control --reload-rules && udevadm trigger --subsystem-match=usb
```

## Building the inventory

`nix run .#detect-devices` reads the machine in front of you and prints a `nixusb.devices` block to
paste. It is deliberately **not** a live auto-detector — the inventory is a hardware fact that
belongs in the config, reviewed like any other, not re-derived on every boot. Review the output:
the generated names are guesses from the USB product string.

## Checks

`nix flake check` runs pure evaluation checks — no VM, no host, nothing that acts on a machine.
Everything nixusb produces is a pure function of `nixusb.devices`, so the whole contract is
verifiable by evaluating the module and reading the result back. Both directions are proven: that
the right rules are generated, **and** that malformed inventories are rejected.

## Licence

Outbound licence is `MIT OR Apache-2.0`. See `LICENSE-MIT` and `LICENSE-APACHE`; every source file carries `SPDX-License-Identifier: MIT OR Apache-2.0`.
