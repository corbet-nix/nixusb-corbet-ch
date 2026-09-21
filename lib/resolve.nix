# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The channel resolution: pure functions from a list of selected catalogue entries to the
# per-channel outputs a platform backend consumes. Split out of modules/packages.nix for the same
# reason the sibling nixfs/nixoffice repos split theirs: inline, the only input these could ever be
# tested against is the REAL catalogue in ../lib/catalogue.nix, which is a table of what happens to
# be selected today (one entry, arch AND nixpkgs both present, no AUR involved), not a set of
# fixtures chosen to exercise every branch. ../checks/default.nix drives the `aur = true` and
# `arch = null` branches with fixtures instead, because today's catalogue has neither.
#
# EVERY ARCH FIELD IS INDEPENDENTLY NULLABLE: an entry may have a pacman name, or none at all
# (`arch = null`) where Arch offers nothing. So an entry's own catalogue key -- `name`, attached by
# ../modules/packages.nix before calling these -- is what anything REPORTING about an entry reports
# it BY, never one of the channel names themselves (both are nullable, neither is a safe identity).
{ lib }:
rec {
  # Official-repo pacman names. `aur = true` entries are held back for aurPackages: `pacman -S`
  # cannot resolve an AUR name and fails the WHOLE transaction on "target not found", taking every
  # other package in the same converge with it.
  archPackages = selected:
    lib.unique (map (t: t.arch)
      (lib.filter (t: (t.arch or null) != null && !(t.aur or false)) selected));

  aurPackages = selected:
    lib.unique (map (t: t.arch)
      (lib.filter (t: (t.arch or null) != null && (t.aur or false)) selected));

  # Entries with no Arch package at all -- the ones a non-NixOS host can only ever get from nixpkgs,
  # because there is nothing else to reach for. Gated on the missing `arch` field and NOTHING else:
  # which other channels an entry happens to carry says nothing about whether Arch can install it.
  unavailableOnArch = selected:
    lib.unique (map (t: t.name) (lib.filter (t: (t.arch or null) == null) selected));
}
