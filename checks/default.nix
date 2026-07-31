# Pure evaluation checks — no VM, no host, no build of anything that acts on a machine.
#
# Everything nixusb produces is a pure function of nixusb.devices, so the entire contract is
# checkable by evaluating the module and reading the result back. Both directions are proven: the
# rules that SHOULD be generated are, and the inventories that MUST be rejected are.
{ pkgs, nixpkgs, nixusbModule, systemManagerModule, systemManagerLib ? null }:
let
  lib = nixpkgs.lib;

  # Evaluate the NixOS module standalone. `services.udev.extraRules` is stubbed as a plain option so
  # we don't have to drag in all of nixpkgs' NixOS module set just to read our own output back.
  evalNixusb = devices: extra: lib.evalModules {
    modules = [
      nixusbModule
      {
        options.services.udev.extraRules = lib.mkOption {
          type = lib.types.lines;
          default = "";
        };
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
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
  ];

  failures = builtins.filter (e: !e.ok) expectations;
in
{
  purity = pkgs.runCommand "nixusb-purity-checks" { } ''
    ${lib.optionalString (failures != [ ]) ''
      echo "nixusb checks FAILED:" >&2
      ${lib.concatMapStringsSep "\n" (f: ''echo "  - ${f.name}" >&2'') failures}
      exit 1
    ''}
    echo "nixusb: ${toString (builtins.length expectations)} checks passed"
    touch $out
  '';
}
