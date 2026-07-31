# nixusb — the host's USB device inventory as declared data, and stable, enumeration-independent
# identity stamped onto every device node those devices create.
#
# WHY THIS EXISTS
#
# The kernel names USB-backed device nodes by ENUMERATION ORDER, not by hardware identity:
# /dev/snd/card1, /dev/video0, /dev/ttyUSB0, /dev/sdb. That ordering is not stable across a reboot,
# a replug, a dock hotplug, or a kernel update — and it is not even stable across two machines that
# have the same devices plugged in. Anything that hardcodes one of those names is a latent bug.
#
# This is the same failure class nixgpu's `stable-device-paths` module solved for DRM (root-caused
# 2026-07-24 on a production single-GPU cluster, then hit for real 2026-07-29 when a DisplayLink
# dock's `evdi` module took card1 and moved an RX 6800 to card2). nixusb is the USB-side sibling:
# same doctrine, different bus. nixgpu's schema is DRM-specific (`hasRenderNode`, `vramMiB`,
# `bus = pci|platform`) and deliberately not generalized — this module does not extend it, it
# mirrors its shape for devices identified by USB VID/PID/serial instead of PCI vendor id.
#
# ── THE INVENTORY IS THE POINT, NOT THE SYMLINKS ────────────────────────────────────────────────
#
# `nixusb.devices` is readable at eval time whether or not `nixusb.enable` is set, because its
# primary consumer is other MODULES, not udev. A sibling that needs to know "which USB audio devices
# does this fleet have, and what is each one called" reads this table — it is the only place that
# fact is stated. Consumers must read it defensively (`config.nixusb.devices or { }`) so nixusb
# stays an optional input, matching the idiom nixhost already uses for nixnet.interfaces.
#
# At RUNTIME the same table is projected onto udev as `ENV{NIXUSB_NAME}`, stamped on the USB device
# AND on every child node it creates. `ATTRS{}` walks the parent chain, so one rule per device
# covers its `sound`, `video4linux`, `tty`, `hidraw` and `block` children without enumerating them.
# A runtime consumer (a WirePlumber rule, a udev-driven daemon) then matches on a name you chose
# rather than on a number the kernel happened to hand out this boot.
#
# ── IDENTITY, AND WHEN IT IS AMBIGUOUS ──────────────────────────────────────────────────────────
#
# A USB device is identified by `vendorId:productId`, optionally narrowed by `serial`. Many devices
# ship a real serial (a HyperX Cloud III S reports C1V51706C2; a DisplayLink dock reports
# GWCD00161000515) and are then identifiable no matter which host or port they are plugged into —
# which is exactly what lets a device MOVE between machines and still resolve to the same name.
#
# Plenty of devices ship none (a Shure MV5C reports no serial at all). Those are identifiable only
# by vendorId:productId, which is fine while exactly one such device exists — and silently wrong the
# moment a second one appears. That is not left to chance: declaring two serial-less devices with
# the same vendorId:productId is a build-time ERROR, not a warning, because the failure it prevents
# is two devices non-deterministically claiming each other's name.
{ lib, config, ... }:
let
  cfg = config.nixusb;

  hex4 = lib.types.strMatching "[0-9a-f]{4}";

  # `nixusb.devices`' attrset KEY (`name`, bound by the submodule's own `{ name, ... }:` below) is
  # projected verbatim into a udev rule as both an ENV value and a SYMLINK path segment
  # (mkIdentityRule / mkSymlinkRules below) -- unlike vendorId/productId/serial/tags, which are
  # ordinary option VALUES and already carry a strMatching-style type, an attrsOf's key has no type
  # of its own to constrain that way. Proven by eval: a name of `my/cam` silently nests a directory
  # in the SYMLINK path (`usb/by-name/my/cam/%k`), and a name containing `"` breaks out of the
  # udev rule's own quoting entirely.
  #
  # TRIED FIRST, DOESN'T WORK: wrapping `options.nixusb.devices`'s type in `lib.types.addCheck` to
  # reject a bad key at the type level, the same way `hex4` restricts vendorId/productId. Proven
  # empirically NOT to fire: the ordinary declaration shape (`nixusb.devices."my/cam" = { ... };`,
  # an attribute-PATH assignment) is merged by `attrsOf`'s own per-key logic before the container
  # type's `addCheck` ever runs against the whole merged attrset, so a hostile key sailed straight
  # through with no error. Left OUT rather than shipped as a check that silently does nothing.
  #
  # What DOES work, empirically verified the same way: the plain `assertions` mechanism below,
  # exactly the same shape as the existing `duplicateKeys`/`ambiguousModels` checks -- it reads
  # `cfg.devices`'s keys back out (data, not a type) and fails the build with a clear message. One
  # layer here, not two -- the type-level "layer" would have been decorative, and decorative
  # security controls are worse than none (they read as covered when they are not).
  deviceNameType = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]*";

  deviceList = lib.mapAttrsToList (name: device: { inherit name device; }) cfg.devices;

  # A device's identity key. Serial-less devices key on vendor:product alone, which is what makes
  # the ambiguity check below possible: two of them collapse to the same key.
  identityKey = device:
    "${device.vendorId}:${device.productId}"
    + lib.optionalString (device.serial != null) ":${device.serial}";

  keyed = lib.groupBy ({ device, ... }: identityKey device) deviceList;

  duplicateKeys = lib.filterAttrs (_: entries: builtins.length entries > 1) keyed;

  # Serial-less entries sharing a vendor:product are mutually ambiguous EVEN IF only one is declared
  # here, because a second identical unit plugged in later would match the same rule. We can only
  # catch the declared case, so we do.
  seriallessByModel = lib.groupBy
    ({ device, ... }: "${device.vendorId}:${device.productId}")
    (builtins.filter ({ device, ... }: device.serial == null) deviceList);

  ambiguousModels = lib.filterAttrs (_: entries: builtins.length entries > 1) seriallessByModel;

  # Names that don't satisfy `deviceNameType` -- see that binding's comment for the (empirically
  # ruled out) type-level alternative and why this plain data check is what actually works.
  invalidNames = builtins.filter (n: !(deviceNameType.check n)) (lib.attrNames cfg.devices);

  # One match rule per device. `ACTION!="remove"` keeps the stamp off teardown events, where the
  # attributes we match on may already be gone.
  mkIdentityRule = name: device:
    let
      matchers = [
        ''ACTION!="remove"''
        ''ATTRS{idVendor}=="${device.vendorId}"''
        ''ATTRS{idProduct}=="${device.productId}"''
      ] ++ lib.optional (device.serial != null) ''ATTRS{serial}=="${device.serial}"'';

      assignments = [
        ''ENV{NIXUSB_NAME}="${name}"''
      ]
      ++ lib.optional (device.tags != [ ]) ''ENV{NIXUSB_TAGS}="${lib.concatStringsSep ":" device.tags}"''
      ++ [ ''TAG+="nixusb"'' ];
    in
    lib.concatStringsSep ", " (matchers ++ assignments);

  # Symlinks land in a per-device DIRECTORY (`SYMLINK+="usb/by-name/<name>/%k"`), not a flat file.
  # A single USB device routinely creates several nodes in one subsystem — a sound card alone brings
  # controlC*, pcmC*D*p, pcmC*D*c — so a flat symlink would have them overwrite each other
  # non-deterministically. udev supports subdirectories in SYMLINK; %k keeps the kernel name inside.
  mkSymlinkRules = name: device:
    map
      (subsystem: lib.concatStringsSep ", " [
        ''ACTION!="remove"''
        ''ENV{NIXUSB_NAME}=="${name}"''
        ''SUBSYSTEM=="${subsystem}"''
        ''SYMLINK+="usb/by-name/${name}/%k"''
      ])
      device.symlinkSubsystems;

  rulesFor = { name, device }:
    [ (mkIdentityRule name device) ] ++ (mkSymlinkRules name device);

  generatedRules = lib.concatStringsSep "\n" (
    [
      "# Generated by nixusb — do not edit. Source: nixusb.devices"
      "#"
      "# ENV{NIXUSB_NAME} is stamped on the USB device and, because ATTRS{} walks the parent chain,"
      "# on every child node it creates (sound, video4linux, tty, hidraw, block)."
    ]
    ++ lib.concatMap rulesFor (lib.sort (a: b: a.name < b.name) deviceList)
  );
in
{
  options.nixusb = {
    enable = lib.mkEnableOption ''
      projection of the nixusb.devices inventory onto udev.

      The inventory itself is readable by other modules whether or not this is enabled — turning
      this on is what additionally writes the udev rules that stamp ENV{NIXUSB_NAME} at runtime
    '';

    devices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          vendorId = lib.mkOption {
            type = hex4;
            example = "03f0";
            description = ''
              USB vendor ID, four lowercase hex digits, no `0x` prefix — exactly as the kernel
              reports it in `ATTRS{idVendor}` and as `lsusb` prints it before the colon.

              Read it with `lsusb`, or for a device you can already see:
              `udevadm info -q property /sys/class/sound/cardN | grep ID_VENDOR_ID`.
            '';
          };

          productId = lib.mkOption {
            type = hex4;
            example = "06be";
            description = ''
              USB product ID, four lowercase hex digits, no `0x` prefix — `ATTRS{idProduct}`, and
              the half of `lsusb`'s ID field after the colon.
            '';
          };

          serial = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9._:-]+");
            default = null;
            example = "C1V51706C2";
            description = ''
              The device's USB serial (`ATTRS{serial}` / `ID_SERIAL_SHORT`), or `null` for a device
              that reports none.

              A serial is what makes identity HOST-INDEPENDENT: the device resolves to the same
              nixusb name whichever machine and whichever port it is plugged into. Set it whenever
              the device has one.

              Leaving it `null` is supported but narrows identity to vendorId:productId, so it can
              only ever name ONE such device. Declaring two serial-less devices with the same
              vendorId:productId is a build-time error.
            '';
          };

          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            example = "HyperX Cloud III S Wireless headset";
            description = ''
              Human-readable description of the physical device. Documentation only — nothing
              matches on it. Worth filling in: this table is the fleet's inventory of what is
              actually plugged in where, and a bare VID:PID ages badly.
            '';
          };

          tags = lib.mkOption {
            type = lib.types.listOf (lib.types.strMatching "[a-z0-9][a-z0-9-]*");
            default = [ ];
            example = [ "audio" "headset" ];
            description = ''
              Free-form consumer tags, exported at runtime as a colon-separated `ENV{NIXUSB_TAGS}`
              and readable at eval time by any module that wants a subset of the inventory
              (e.g. every device tagged `audio`).

              nixusb assigns no meaning to any tag — consumers define their own vocabulary.
            '';
          };

          symlinkSubsystems = lib.mkOption {
            type = lib.types.listOf (lib.types.strMatching "[a-z0-9_-]+");
            default = [ ];
            example = [ "sound" "tty" ];
            description = ''
              Kernel subsystems for which to additionally create stable symlinks under
              `/dev/usb/by-name/<name>/`, one per device node, keeping the kernel name as the leaf
              (so a sound card yields `/dev/usb/by-name/<name>/controlC1`, `.../pcmC1D0p`, ...).

              Empty by default: most consumers want `ENV{NIXUSB_NAME}` and never touch a path. Set
              this only for a consumer that genuinely needs a filesystem path it can open.
            '';
          };

          host = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "laptop";
            description = ''
              The host this device is normally attached to, if it has a usual home. Documentation
              only — nixusb never enforces it, and a device with a serial resolves correctly
              wherever it actually is. Records intent so a fleet-wide inventory reads sensibly.
            '';
          };
        };

        config.description = lib.mkDefault name;
      }));
      default = { };
      description = ''
        The host's USB device inventory, keyed by the stable name you want each device known by.

        This is pure declared data. It is readable by other modules regardless of `nixusb.enable`,
        and it is the single place this family states which USB devices exist and what they are
        called — consumers read it rather than restating VID/PID themselves.

        Each key MUST match `[A-Za-z0-9][A-Za-z0-9_-]*` (enforced by an assertion in `config`, see
        `deviceNameType`) -- it is projected verbatim into a udev rule as an `ENV` value and a
        `SYMLINK` path segment, and udev's own quoting/path syntax gives a wider name no safe
        meaning.
      '';
      example = lib.literalExpression ''
        {
          hyperx = {
            vendorId = "03f0";
            productId = "06be";
            serial = "C1V51706C2";
            description = "HyperX Cloud III S Wireless headset";
            tags = [ "audio" ];
          };

          shure-mv5c = {
            vendorId = "14ed";
            productId = "1010";
            # This model reports no USB serial at all, so it is identified by model alone.
            description = "Shure MV5C USB microphone";
            tags = [ "audio" "microphone" ];
          };
        }
      '';
    };

    rules = lib.mkOption {
      type = lib.types.lines;
      internal = true;
      readOnly = true;
      description = ''
        The generated udev rules, consumed by whichever plane is in use — `services.udev.extraRules`
        on NixOS, an `environment.etc` entry under system-manager. Not user-settable.
      '';
    };
  };

  config = {
    nixusb.rules = generatedRules;

    # Eager assertions, UNGATED on `enable`: a malformed inventory is wrong whether or not it is
    # currently projected onto udev, and the whole point is to fail at build time rather than let
    # two devices race for one name on some future boot.
    assertions = [
      {
        assertion = duplicateKeys == { };
        message = ''
          nixusb.devices declares the same USB identity more than once:
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList
            (key: entries: "  ${key} — declared as: ${lib.concatMapStringsSep ", " (e: e.name) entries}")
            duplicateKeys)}

          Each physical device must appear exactly once. If these really are separate units of the
          same model, give each one its `serial` so they can be told apart.
        '';
      }
      {
        assertion = ambiguousModels == { };
        message = ''
          nixusb.devices declares more than one device with no `serial` sharing a vendorId:productId:
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList
            (model: entries: "  ${model} — ${lib.concatMapStringsSep ", " (e: e.name) entries}")
            ambiguousModels)}

          Without a serial these are indistinguishable to udev, so they would non-deterministically
          claim each other's NIXUSB_NAME depending on enumeration order — the exact class of bug
          this module exists to prevent.

          Find each unit's serial with:
            udevadm info -q property /sys/bus/usb/devices/<dev> | grep ID_SERIAL_SHORT
          and set `serial` on each. If the hardware genuinely reports none, only one such device can
          be declared.
        '';
      }
      {
        assertion = invalidNames == [ ];
        message = ''
          nixusb.devices declares a name that is not a safe udev identifier/path segment:
          ${lib.concatMapStringsSep "\n" (n: "  \"${n}\"") invalidNames}

          Each name must match [A-Za-z0-9][A-Za-z0-9_-]*. The name is projected verbatim into a
          udev rule as ENV{NIXUSB_NAME} and into a SYMLINK path segment
          (usb/by-name/<name>/%k) -- a `/` silently nests an extra directory, and a `"` breaks
          out of the rule's own quoting entirely. Rename the device to a plain identifier.
        '';
      }
    ];
  };
}
