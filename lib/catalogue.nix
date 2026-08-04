#
# nixusb's package catalogue — the USB tooling a host runs, as opposed to modules/options.nix's
# device INVENTORY (which devices exist and what they are called). Two separate concerns: a host
# can want stable device names with no interactive tooling installed, or the tooling with no udev
# projection at all. See modules/packages.nix for why this file introduces its own option surface
# rather than gating anything on `nixusb.enable`.
#
# ONE GROUP TODAY (`inspection`), SHAPED FOR A SECOND. The group is a boolean, on by default — the
# same convention nixfs's generic toolkit uses (`tools.<group>.enable`), and for the same reason:
# USB inspection tooling is not a per-host taste pick the way nixdev's editors are. Every host that
# composes nixusb wants to be able to ask "what is actually plugged in", so the question a host
# answers is not "do I want this" but "can I actually use it" — turn a group off only where the
# answer is genuinely no (a container with no USB bus of its own to ask).
#
# TWO COLUMNS PER ENTRY, the same shape as nixfs/nixdev/nixoffice: `arch` (pacman package name, or
# `null` where Arch has nothing at all — official repo AND AUR) and `nixpkgs` (the nixpkgs attribute
# name). `aur = true` marks an AUR-only entry, held back from the plain pacman list the same way
# nixfs's `hfsprogs` is — `pacman -S` cannot resolve an AUR name and fails the WHOLE transaction on
# "target not found".
#
# THE DE-DUPLICATION THIS ENTRY CLOSES. `usbutils` used to live in nixfs's `tools.inspection` group
# (nixfs's own storage-bus-adjacent inspection toolkit — smartctl, hdparm, nvme-cli, lsscsi,
# sg3_utils, plus usbutils and pciutils for "what is attached"). nixusb is the USB domain's own
# repo and is composed everywhere nixfs is not (the Arch container owns no block devices, so it
# does not compose nixfs at all — see nixfs's own `filesystems` option doc), so USB tooling moved
# here and nixfs kept only what is genuinely storage-bus-adjacent (pciutils stays in nixfs; PCI
# enumeration is not this repo's domain). Confirmed BOTH names live, not copied from a spec sheet:
# `pacman -Si usbutils` reports it in the CachyOS `cachyos-core-v3` repo (019-1.1, no AUR involved),
# and `usbutils` resolves as a top-level nixpkgs attribute (pname "usbutils") against infra's pinned
# nixpkgs revision.
{ ... }:
{
  tools = {
    inspection = {
      packages.usbutils = { arch = "usbutils"; nixpkgs = "usbutils"; };
      summary = "ask a USB device what it is";
      detail = ''
        lsusb enumerates what is attached to the bus and, with -v, walks each device's full
        descriptor tree -- vendor/product strings, configurations, interfaces, endpoints. The
        interactive counterpart to modules/options.nix's device inventory: that file states
        identity declaratively (VID:PID:serial -> a stable name); this is the tool you reach for
        to go find those numbers in the first place, or to check what a device claims to be before
        it gets an entry there at all.
      '';
    };
  };
}
