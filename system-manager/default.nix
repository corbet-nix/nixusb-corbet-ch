# SPDX-License-Identifier: MIT OR Apache-2.0
# Arch/CachyOS plane: two independent halves.
#
# 1. system-manager has no `services.udev`, so the device-inventory projection writes the rules
#    file directly. udev reads /etc/udev/rules.d, so an `environment.etc` entry is the whole
#    mechanism. The inventory and its assertions come from the SAME ../modules/options.nix the
#    NixOS plane imports -- there is exactly one definition of nixusb.devices in this repo, and
#    only the projection differs. Gated on `nixusb.enable`, same as the NixOS plane.
#
#    After a first apply the rules are not retroactive: device nodes that already exist keep
#    whatever identity they were (or were not) stamped with. Either replug the device or run:
#      udevadm control --reload-rules && udevadm trigger --subsystem-match=usb
#
# 2. The package layer's Arch backend: publish the pacman/AUR names for the host's own reconciler,
#    and install from nixpkgs ONLY the entries Arch has nothing for at all. UNCONDITIONAL -- not
#    gated on `nixusb.enable`, which is entirely the inventory-projection option above and says
#    nothing about whether a host wants USB tooling installed.
#
#    THE ANTI-SHADOWING RULE THIS HALF EXISTS TO ENFORCE. On a live Arch host, `/usr/sbin` precedes
#    the system-manager Nix profile on `PATH` -- confirmed live by the sibling nixfs repo across
#    many tools (mkfs.xfs, smartctl, pv, lsscsi, mkfs.f2fs, mcopy, mdadm, hdparm all resolving to
#    the distro copy while the pinned nixpkgs copies sat unused in the system-manager profile). So
#    installing an entry from nixpkgs here when pacman ALSO has it does not add redundancy, it adds
#    a copy that is never the one that runs. This backend draws a hard line: an entry with a pacman
#    name is published for the reconciler and installed from NOWHERE here; an entry with none
#    (`unavailableOnArch`) is installed from nixpkgs and published NOWHERE else. No entry is ever
#    both.
#
#    THE PUBLISHED LISTS ARE NOT WIRED TO A RECONCILER HERE, on purpose -- the same reasoning as the
#    sibling nixfs/nixdev/nixoffice Arch backends: wiring a reconciler in here would couple this
#    general flake to one deployment's package module. A host's own config connects it:
#
#      nixarch.packages.pacman = config.nixusb.archPackages;
#      nixarch.packages.aur = config.nixusb.aurPackages;
{ lib, config, pkgs, ... }:
let
  cfg = config.nixusb;

  # The only entries this backend may touch with nixpkgs: exactly `unavailableOnArch`, never more.
  # Filtered from `cfg.want` directly (not re-derived from the published name list) so a bug that
  # changed what gets INSTALLED here could not also quietly change what the option reports.
  nixpkgsOnly = lib.filter (t: t.arch == null) cfg.want;

  path = name: lib.splitString "." name;
  resolves = t: lib.hasAttrByPath (path t.nixpkgs) pkgs;
  missing = lib.filter (t: !(resolves t)) nixpkgsOnly;
in
{
  imports = [ ../modules/options.nix ../modules/packages.nix ];

  config = {
    environment.etc = lib.mkIf cfg.enable {
      "udev/rules.d/70-nixusb-by-name.rules".text = cfg.rules;
    };

    assertions = [
      {
        assertion = missing == [ ];
        message = ''
          nixusb: ${toString (builtins.length missing)} nixpkgs-only package(s) do not exist in
          this nixpkgs: ${lib.concatStringsSep ", " (map (t: t.nixpkgs) missing)}.

          This is a catalogue problem, not a host problem -- a package was renamed or dropped
          upstream. Fix ../lib/catalogue.nix so every host gets the correction, rather than pinning
          an older nixpkgs or omitting the entry on one machine.
        '';
      }
    ];

    environment.systemPackages =
      map (t: lib.getAttrFromPath (path t.nixpkgs) pkgs) (lib.filter resolves nixpkgsOnly);
  };
}
