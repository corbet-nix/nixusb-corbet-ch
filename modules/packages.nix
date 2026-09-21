# SPDX-License-Identifier: MIT OR Apache-2.0
#
# nixusb's package layer — the USB tooling catalogue, declared per host.
#
# WHY THIS IS A SEPARATE FILE FROM options.nix, WITH ITS OWN OPTION SURFACE. options.nix is the
# device INVENTORY: pure declared data (`nixusb.devices`) plus the udev projection `nixusb.enable`
# gates. Nothing about that concerns pacman or nixpkgs. This file is the second, independent half
# of nixusb -- the actual USB tooling a host runs (`lsusb` today) -- and it genuinely is a separate
# concern: a host can want stable device names with no interactive tooling installed, or the
# tooling with no udev projection at all. So package selection gets its OWN option surface
# (`nixusb.tools.*`), gated on nothing but its own group enables, rather than riding on
# `nixusb.enable`.
#
# PLATFORM-NEUTRAL BY DESIGN, the same split as nixfs/nixdev/nixoffice: this file declares WHAT is
# wanted and resolves every entry to both a pacman name and a nixpkgs attribute name
# (../lib/resolve.nix). It installs nothing itself -- see ../modules/install.nix (the NixOS
# backend: nixpkgs for everything, because NixOS has no second package manager to lose a PATH race
# against) and ../system-manager/default.nix (the Arch backend: pacman/AUR for everything Arch has,
# nixpkgs ONLY for the entries Arch does not).
{ config, lib, ... }:
let
  cfg = config.nixusb;
  catalogue = import ../lib/catalogue.nix { };
  resolve = import ../lib/resolve.nix { inherit lib; };

  toolGroups = lib.attrNames catalogue.tools;

  # Attaches each package's own attrset key as `name` -- the catalogue's identity for that entry,
  # since both its channel fields are independently nullable (see ../lib/resolve.nix's header).
  withName = table: lib.mapAttrsToList (n: v: v // { name = n; }) table;

  enabledGroups = lib.filter (g: cfg.tools.${g}.enable) toolGroups;

  selectedEntries =
    lib.unique (lib.concatMap (g: withName catalogue.tools.${g}.packages) enabledGroups);

  mkToolOption = group: {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        ${catalogue.tools.${group}.summary}.

        ${catalogue.tools.${group}.detail}
        Packages: ${lib.concatStringsSep ", " (lib.attrNames catalogue.tools.${group}.packages)}.

        On by default. This is the USB domain's own tooling -- wanted on every host that composes
        nixusb, not a per-host taste pick -- so the question a host answers here is not "do I want
        this" but "can I actually use it". Turn it off only where the answer is genuinely no (a
        host with no USB bus of its own to ask), and say why in the host's config.
      '';
    };
  };
in
{
  options.nixusb.tools = lib.genAttrs toolGroups mkToolOption;

  options.nixusb.want = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    readOnly = true;
    internal = true;
    description = "Resolved package entries; the contract a platform backend consumes.";
  };

  options.nixusb.packageNames = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      The resolved selection as nixpkgs attribute names. The contract ../modules/install.nix
      consumes, and what to read if you want to see what a NixOS host will actually get without
      instantiating anything.
    '';
  };

  options.nixusb.archPackages = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      The selected tools as pacman package names, for the host's own reconciler:

        nixarch.packages.pacman = config.nixusb.archPackages;

      This module cannot install them on Arch: see ../system-manager/default.nix, which publishes
      this list rather than installing from it, and installs from nixpkgs only the entries Arch has
      nothing for (`unavailableOnArch` below) -- so a package present in both never gets installed
      twice.
    '';
  };

  options.nixusb.aurPackages = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      Selections that live in the AUR rather than an official repo, kept SEPARATE because
      `pacman -S` cannot resolve them -- it fails the whole transaction with "target not found",
      which takes the rest of the converge down with it. Wire them to the AUR side:

        nixarch.packages.aur = config.nixusb.aurPackages;

      Empty for the current catalogue: `usbutils` is an official-repo package on Arch. The
      mechanism stays for a future entry that is AUR-only.
    '';
  };

  options.nixusb.unavailableOnArch = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      Selected entries with no Arch package at all -- neither an official repo nor the AUR --
      named by nixpkgs attribute name (this catalogue's identity for every entry). Surfaced rather
      than silently handled, so it is visible which entries a non-NixOS host still gets from
      nixpkgs and why: see ../system-manager/default.nix, which installs exactly this list from
      nixpkgs and nothing more.

      Empty for the current catalogue: `usbutils` has a live Arch source. The mechanism stays --
      exercised by a fixture in ../checks/, not by a live entry.
    '';
  };

  config = {
    nixusb.want = selectedEntries;
    nixusb.packageNames = map (t: t.nixpkgs) selectedEntries;
    nixusb.archPackages = resolve.archPackages selectedEntries;
    nixusb.aurPackages = resolve.aurPackages selectedEntries;
    nixusb.unavailableOnArch = resolve.unavailableOnArch selectedEntries;
  };
}
