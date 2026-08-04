# Pure evaluation checks — no VM, no host, no build of anything that acts on a machine.
#
# Everything nixusb produces is a pure function of nixusb.devices, so the entire contract is
# checkable by evaluating the module and reading the result back. Both directions are proven: the
# rules that SHOULD be generated are, and the inventories that MUST be rejected are.
#
# `systemManagerLib` (numtide/system-manager's own `lib`, e.g. `makeSystemConfig`) is accepted but
# deliberately NOT used below: it builds a real `nixpkgs.hostPlatform` closure, pulls in `userborn`,
# and `callPackage`s system-manager's own engine just to produce a `linkFarm` derivation -- exactly
# the "VM, host, build" weight this file's header rules out. `systemManagerModule` (the actual
# system-manager plane module, `system-manager/default.nix`) is what gives real coverage cheaply:
# plain `lib.evalModules` over it, same shape as `evalNixusb` below, exercises the REAL module the
# same way -- see `evalNixusbSystemManager`.
{ pkgs, nixpkgs, nixusbModule, systemManagerModule, systemManagerLib ? null }:
let
  lib = nixpkgs.lib;

  # Evaluate the NixOS module standalone. `services.udev.extraRules` is stubbed as a plain option so
  # we don't have to drag in all of nixpkgs' NixOS module set just to read our own output back.
  #
  # `specialArgs.pkgs` and the `environment.systemPackages` stub are here for the PACKAGE layer
  # (../modules/install.nix, pulled in transitively through `nixusbModule` -- see ../modules/
  # default.nix): that module's `{ config, lib, pkgs, ... }:` signature needs a real `pkgs` to
  # resolve nixpkgs attribute names against, and its `environment.systemPackages` assignment needs
  # somewhere to land. Passing the REAL `pkgs` this checks file already receives (not a stub) is
  # what lets the checks below prove an actual nixpkgs attribute resolves, not just that some value
  # was assigned.
  evalNixusb = devices: extra: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      nixusbModule
      {
        options.services.udev.extraRules = lib.mkOption {
          type = lib.types.lines;
          default = "";
        };
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
        options.environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
        };
      }
      ({ ... }: { nixusb.devices = devices; })
      extra
    ];
  };

  # Same idea, for system-manager's plane (`system-manager/default.nix`): it imports the SAME
  # `../modules/options.nix` `nixusbModule` does -- one definition of `nixusb.devices` and its
  # assertions, shared by both planes -- and projects the rules onto `environment.etc` instead of
  # `services.udev.extraRules`. Stubbing `environment.etc` the same way `services.udev.extraRules`
  # is stubbed above evaluates the REAL `systemManagerModule`, at the same near-zero pure-eval cost,
  # without pulling in `systemManagerLib.makeSystemConfig` (see header comment for why not).
  # Same `specialArgs.pkgs` / `environment.systemPackages` stub reasoning as evalNixusb above --
  # ../system-manager/default.nix's own Arch backend for the package layer lives in THIS module,
  # not a separate imported file, and needs both.
  evalNixusbSystemManager = devices: extra: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      systemManagerModule
      {
        options.environment.etc = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options.text = lib.mkOption { type = lib.types.lines; default = ""; };
          });
          default = { };
        };
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
        options.environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
        };
      }
      ({ ... }: { nixusb.devices = devices; })
      extra
    ];
  };

  fixture = {
    hyperx = {
      vendorId = "03f0";
      productId = "06be";
      serial = "C1V51706C2";
      description = "HyperX Cloud III S Wireless headset";
      tags = [ "audio" "headset" ];
      symlinkSubsystems = [ "sound" ];
    };
    shure-mv5c = {
      vendorId = "14ed";
      productId = "1010";
      description = "Shure MV5C USB microphone";
      tags = [ "audio" "microphone" ];
    };
  };

  enabled = evalNixusb fixture { nixusb.enable = true; };
  disabled = evalNixusb fixture { nixusb.enable = false; };

  rules = enabled.config.nixusb.rules;

  smEnabled = evalNixusbSystemManager fixture { nixusb.enable = true; };

  # Collect the messages of assertions that actually FAILED, the way a NixOS build would.
  failedAssertions = cfg: map (a: a.message) (builtins.filter (a: !a.assertion) cfg.assertions);

  ambiguous = evalNixusb
    {
      mic-a = { vendorId = "14ed"; productId = "1010"; };
      mic-b = { vendorId = "14ed"; productId = "1010"; };
    }
    { nixusb.enable = true; };

  duplicate = evalNixusb
    {
      one = { vendorId = "03f0"; productId = "06be"; serial = "C1V51706C2"; };
      two = { vendorId = "03f0"; productId = "06be"; serial = "C1V51706C2"; };
    }
    { nixusb.enable = true; };

  # Regression guard for the udev-injection fix in modules/options.nix (`name` -- the attrset key --
  # used to go bare into ENV{NIXUSB_NAME} and SYMLINK+="usb/by-name/<name>/%k"). Both directions are
  # exercised: a `/`-bearing name (silent SYMLINK path nesting) and a `"`-bearing name (breaks the
  # udev rule's own quoting) must each trip the `invalidNames` assertion below, and an ordinary name
  # must not.
  slashName = evalNixusb
    { "my/cam" = { vendorId = "1234"; productId = "5678"; }; }
    { nixusb.enable = true; };

  quoteName = evalNixusb
    { "weird\"name" = { vendorId = "1234"; productId = "5678"; }; }
    { nixusb.enable = true; };

  # Same hostile name, evaluated through the system-manager plane -- proves the shared assertion
  # actually fires there too, not just on the NixOS side (system-manager is nixusb's documented
  # Arch target, and had zero coverage of its own before this).
  smQuoteName = evalNixusbSystemManager
    { "weird\"name" = { vendorId = "1234"; productId = "5678"; }; }
    { nixusb.enable = true; };

  expectations = [
    {
      name = "serial-bearing device matches on its serial";
      ok = lib.hasInfix ''ATTRS{serial}=="C1V51706C2"'' rules;
    }
    {
      name = "every declared device gets its NIXUSB_NAME stamped";
      ok = lib.hasInfix ''ENV{NIXUSB_NAME}="hyperx"'' rules
        && lib.hasInfix ''ENV{NIXUSB_NAME}="shure-mv5c"'' rules;
    }
    {
      name = "a serial-less device emits no serial matcher at all";
      # Its rule must not carry an empty ATTRS{serial}=="" that would match nothing.
      ok = !(lib.hasInfix ''ATTRS{serial}==""'' rules);
    }
    {
      name = "tags are exported colon-separated";
      ok = lib.hasInfix ''ENV{NIXUSB_TAGS}="audio:headset"'' rules;
    }
    {
      name = "symlinks land in a per-device directory keyed by kernel name";
      ok = lib.hasInfix ''SYMLINK+="usb/by-name/hyperx/%k"'' rules;
    }
    {
      name = "a device that asked for no symlinks gets none";
      ok = !(lib.hasInfix "usb/by-name/shure-mv5c" rules);
    }
    {
      name = "rules reach services.udev when enabled";
      ok = enabled.config.services.udev.extraRules == rules;
    }
    {
      name = "rules are NOT written to udev when disabled";
      ok = disabled.config.services.udev.extraRules == "";
    }
    {
      name = "the inventory stays readable by consumers even when disabled";
      # This is the whole point: sibling modules read nixusb.devices at eval time regardless.
      ok = disabled.config.nixusb.devices ? hyperx;
    }
    {
      name = "two serial-less devices of the same model are REJECTED";
      # Both guards fire here, and correctly so: with `serial = null` the two entries also collapse
      # to the same identity key, so the duplicate check trips alongside the ambiguity check.
      ok = builtins.length (failedAssertions ambiguous.config) >= 1;
    }
    {
      name = "the same physical identity declared twice is REJECTED";
      ok = builtins.length (failedAssertions duplicate.config) >= 1;
    }
    {
      name = "a valid inventory raises no assertion";
      ok = failedAssertions enabled.config == [ ];
    }
    {
      name = "a device name containing '/' is REJECTED (would silently nest a SYMLINK directory)";
      ok = builtins.length (failedAssertions slashName.config) >= 1;
    }
    {
      name = ''a device name containing '"' is REJECTED (would break out of the udev rule's quoting)'';
      ok = builtins.length (failedAssertions quoteName.config) >= 1;
    }
    {
      name = "system-manager plane: rules reach environment.etc when enabled (same shared options.nix)";
      ok = smEnabled.config.environment.etc."udev/rules.d/70-nixusb-by-name.rules".text == rules;
    }
    {
      name = "system-manager plane: a valid inventory raises no assertion";
      ok = failedAssertions smEnabled.config == [ ];
    }
    {
      name = ''system-manager plane: a device name containing '"' is REJECTED too (shared assertion, not NixOS-only)'';
      ok = builtins.length (failedAssertions smQuoteName.config) >= 1;
    }
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # THE PACKAGE LAYER (../lib/catalogue.nix, ../lib/resolve.nix, ../modules/packages.nix,
  # ../modules/install.nix, and ../system-manager/default.nix's Arch half) -- three layers, the
  # same split the sibling nixfs repo uses and for the same reason: a resolution tested only
  # through today's real catalogue (one entry, `usbutils`, arch AND nixpkgs both present, no AUR
  # involved) can only be tested against the entry shapes that catalogue happens to contain.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  catalogue = import ../lib/catalogue.nix { };
  resolve = import ../lib/resolve.nix { inherit lib; };

  outPathOf = n: (lib.getAttrFromPath (lib.splitString "." n) pkgs).outPath;

  allCatalogueEntries =
    lib.concatMap (g: lib.attrValues catalogue.tools.${g}.packages) (lib.attrNames catalogue.tools);

  # ── Layer 1: ../lib/resolve.nix against fixtures, independent of the real catalogue ─────────
  # The real catalogue has no `aur = true` entry and no `arch = null` entry today, so both branches
  # are exercised here rather than left unproven.
  repoEntry = { name = "repoapp"; arch = "repoapp"; nixpkgs = "repoapp"; };
  aurEntry = { name = "aurapp"; arch = "aurapp"; aur = true; nixpkgs = "aurapp"; };
  nixpkgsOnlyEntry = { name = "onlyapp"; arch = null; nixpkgs = "onlyapp"; };
  allFixtures = [ repoEntry aurEntry nixpkgsOnlyEntry ];

  resolveExpectations = [
    {
      name = "package-resolve/arch-excludes-aur-and-nixpkgs-only-entries";
      ok = resolve.archPackages allFixtures == [ "repoapp" ];
    }
    {
      name = "package-resolve/aur-holds-only-aur-entries";
      ok = resolve.aurPackages allFixtures == [ "aurapp" ];
    }
    {
      name = "package-resolve/arch-and-aur-never-emit-a-null";
      # A null pacman name must never reach a package list -- `pacman -S` would be handed a literal
      # "null" and fail the whole transaction, taking every other package in the converge with it.
      ok = !(builtins.elem null (resolve.archPackages allFixtures))
        && !(builtins.elem null (resolve.aurPackages allFixtures));
    }
    {
      name = "package-resolve/unavailable-on-arch-reports-the-nixpkgs-only-entry";
      ok = resolve.unavailableOnArch allFixtures == [ "onlyapp" ];
    }
    {
      name = "package-resolve/unavailable-on-arch-ignores-entries-that-do-have-arch";
      ok = resolve.unavailableOnArch [ repoEntry aurEntry ] == [ ];
    }
    {
      name = "package-resolve/arch-and-nixpkgs-only-partitions-are-disjoint";
      ok =
        let namesWithArch = map (t: t.name) (lib.filter (t: t.arch != null) allFixtures);
        in lib.intersectLists namesWithArch (resolve.unavailableOnArch allFixtures) == [ ];
    }
    {
      name = "package-resolve/empty-selection-resolves-to-empty-everywhere";
      ok = resolve.archPackages [ ] == [ ]
        && resolve.aurPackages [ ] == [ ]
        && resolve.unavailableOnArch [ ] == [ ];
    }
  ];

  # ── Layer 2: ../modules/packages.nix (policy only) against the REAL catalogue, via
  #    lib.evalModules -- cheap enough to run without either backend's installer.
  evalPolicy = extra: (lib.evalModules { modules = [ ../modules/packages.nix extra ]; }).config;

  policyBare = evalPolicy { };
  policyOff = evalPolicy { nixusb.tools.inspection.enable = false; };

  policyExpectations = [
    {
      name = "package-policy/catalogue-every-entry-has-a-nixpkgs-name";
      # nixusb has no third channel (no Flatpak-equivalent), so an entry with neither `arch` nor
      # `nixpkgs` would be undeliverable everywhere.
      ok = lib.all (t: t.nixpkgs != null) allCatalogueEntries;
    }
    {
      name = "package-policy/catalogue-every-nixpkgs-name-exists-in-this-nixpkgs";
      # THE check that catches a renamed or dropped nixpkgs attribute -- a typo or an upstream
      # rename here means a host silently stops getting the tool, discovered only when someone
      # goes looking for a USB device and finds no lsusb.
      ok = lib.all (t: lib.hasAttrByPath (lib.splitString "." t.nixpkgs) pkgs) allCatalogueEntries;
    }
    {
      name = "package-policy/bare-defaults-select-usbutils";
      # tools.inspection.enable defaults true -- the USB domain's own tooling is not a per-host
      # taste pick, so a bare eval already selects it.
      ok = policyBare.nixusb.packageNames == [ "usbutils" ]
        && policyBare.nixusb.archPackages == [ "usbutils" ]
        && policyBare.nixusb.aurPackages == [ ]
        && policyBare.nixusb.unavailableOnArch == [ ];
    }
    {
      name = "package-policy/disabling-the-only-group-selects-nothing";
      ok = policyOff.nixusb.want == [ ]
        && policyOff.nixusb.packageNames == [ ]
        && policyOff.nixusb.archPackages == [ ]
        && policyOff.nixusb.aurPackages == [ ]
        && policyOff.nixusb.unavailableOnArch == [ ];
    }
  ];

  # ── Layer 3: the real backends -- ../modules/install.nix (pulled in transitively through
  #    nixusbModule, see ../modules/default.nix) and ../system-manager/default.nix's Arch half
  #    (pulled in through systemManagerModule) -- evaluated for what they actually RENDER,
  #    against the REAL pkgs this checks file was called with. An empty device inventory ({ }) is
  #    used throughout: the claims under test here are entirely about the package layer, which is
  #    independent of nixusb.devices.
  pkgNixos = evalNixusb { } { };
  pkgNixosOff = evalNixusb { } { nixusb.tools.inspection.enable = false; };
  pkgNixosUdevOff = evalNixusb { } { nixusb.enable = false; };
  pkgArch = evalNixusbSystemManager { } { };

  backendExpectations = [
    {
      name = "package-install/nixos-installs-usbutils-from-nixpkgs";
      ok = lib.elem (outPathOf "usbutils") (map (p: p.outPath) pkgNixos.config.environment.systemPackages);
    }
    {
      name = "package-install/nixos-raises-no-assertion-for-the-real-catalogue";
      ok = failedAssertions pkgNixos.config == [ ];
    }
    {
      name = "package-install/nixos-disabling-the-group-installs-nothing";
      ok = pkgNixosOff.config.environment.systemPackages == [ ];
    }
    {
      name = "package-install/nixos-package-layer-is-independent-of-nixusb.enable";
      # nixusb.enable gates ONLY the udev projection (options.nix/nixos.nix). With it OFF, the
      # package layer must still install -- proving the two halves are genuinely decoupled rather
      # than accidentally sharing one gate.
      ok = lib.elem (outPathOf "usbutils")
        (map (p: p.outPath) pkgNixosUdevOff.config.environment.systemPackages);
    }
    {
      name = "package-arch/publishes-archPackages-for-usbutils";
      ok = lib.elem "usbutils" pkgArch.config.nixusb.archPackages;
    }
    {
      name = "package-arch/publishes-no-aurPackages-for-the-real-catalogue";
      ok = pkgArch.config.nixusb.aurPackages == [ ];
    }
    {
      name = "package-arch/raises-no-assertion-for-the-real-catalogue";
      ok = failedAssertions pkgArch.config == [ ];
    }
    # THE hard invariant: on an Arch host the package comes from pacman and NOTHING from nixpkgs.
    # usbutils has a live Arch source (the archPackages check above proves it), so it must never
    # also appear in this backend's own environment.systemPackages -- that would be a second,
    # PATH-losing copy shadowed by the very pacman package this backend just published.
    {
      name = "package-arch/never-installs-usbutils-from-nixpkgs-shadowing-pacman";
      ok = !(lib.elem (outPathOf "usbutils")
        (map (p: p.outPath) pkgArch.config.environment.systemPackages));
    }
    {
      name = "package-arch/environment-systemPackages-is-empty-today";
      # Sharpened form of the invariant above, for TODAY's catalogue specifically: usbutils is the
      # only entry and it has a live Arch source, so unavailableOnArch is empty and this backend
      # should install literally nothing from nixpkgs.
      ok = pkgArch.config.environment.systemPackages == [ ];
    }
  ];

  allExpectations = expectations ++ resolveExpectations ++ policyExpectations ++ backendExpectations;

  failures = builtins.filter (e: !e.ok) allExpectations;
in
{
  purity = pkgs.runCommand "nixusb-purity-checks" { } ''
    ${lib.optionalString (failures != [ ]) ''
      echo "nixusb checks FAILED:" >&2
      ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg ("  - " + f.name)} >&2") failures}
      exit 1
    ''}
    echo "nixusb: ${toString (builtins.length allExpectations)} checks passed"
    touch $out
  '';
}
