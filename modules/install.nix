# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The NixOS backend for nixusb's package layer: resolve the selection into
# environment.systemPackages, entirely from nixpkgs.
#
# NixOS has no second package manager to lose a PATH race against -- see ../system-manager/
# default.nix's header for the live evidence that on a real Arch host, `/usr/sbin` precedes the
# system-manager Nix profile on PATH, so a distro copy on that host shadows anything installed from
# here. This file has no such hazard to avoid, which is why it stays the simpler "everything from
# nixpkgs" backend.
#
# A MISSING ATTRIBUTE IS A BUILD FAILURE, NOT A WARNING. Every selected entry was asked for, and
# nixpkgs does drop packages. A tool that silently stopped being installed some months ago,
# discovered while trying to identify a failing USB device, is the worst outcome this file can
# produce -- so it fails at eval, loudly, with the name in the message, rather than warning and
# continuing.
#
# UNCONDITIONAL: not gated on `nixusb.enable` -- that option is ../modules/options.nix's, and it
# gates only the udev projection of the device inventory. The package layer has its own gate
# (`nixusb.tools.*.enable`, on by default), independent of whether a host also wants stable device
# names.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixusb;
  path = name: lib.splitString "." name;
  resolves = name: lib.hasAttrByPath (path name) pkgs;
  missing = lib.filter (n: !(resolves n)) cfg.packageNames;
in
{
  imports = [ ./packages.nix ];

  config = {
    assertions = [
      {
        assertion = missing == [ ];
        message = ''
          nixusb: ${toString (builtins.length missing)} selected package(s) do not exist in this
          nixpkgs: ${lib.concatStringsSep ", " missing}.

          This is a catalogue problem, not a host problem -- a package was renamed or dropped
          upstream. Fix ../lib/catalogue.nix so every host gets the correction, rather than pinning
          an older nixpkgs or omitting the entry on one machine.
        '';
      }
    ];

    environment.systemPackages =
      map (n: lib.getAttrFromPath (path n) pkgs) (lib.filter resolves cfg.packageNames);
  };
}
