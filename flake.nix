{
  description = "The host's USB device inventory as declared data, plus stable, enumeration-independent identity stamped onto every device node those devices create.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.system-manager.url = "github:numtide/system-manager";
  inputs.system-manager.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, system-manager }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };

      # "Detect once, paste once", the same shape as nixram's detect-level: this reads the machine
      # in front of you and prints a nixusb.devices block to commit. It is deliberately NOT a live
      # auto-detector -- the inventory is a hardware FACT that belongs in the config, reviewed like
      # any other, not something re-derived on every boot.
      mkDetectDevices = pkgs: pkgs.writeShellApplication {
        name = "detect-devices";
        runtimeInputs = [ pkgs.systemd pkgs.gawk pkgs.gnused ];
        text = ''
          # product/manufacturer/serial below are raw USB string descriptors reported by the DEVICE
          # itself -- the kernel does not sanitize them, so a device can report one containing a
          # double quote or a backslash. vendorId/productId are the one exception (always exactly 4
          # lowercase hex digits, formatted by the kernel, not the device) and name is already
          # sanitized down to lowercase letters, digits and hyphens a few lines below -- everything
          # else that reaches a double-quoted Nix string literal below goes through nixEscape first:
          # unescaped, a quote closes the literal early (broken Nix once pasted) and a dollar sign
          # can open Nix's own string interpolation (attacker-shaped Nix once pasted) -- same
          # injection shape as the sharenfs/udev-name fixes elsewhere in this family, just one step
          # removed (this only ever lands in a file a human reviews before committing, never
          # executed automatically), so it gets the same defence rather than none.
          nixEscape() {
            # Backslash FIRST (or the quote/dollar escapes below would themselves get re-escaped),
            # then double quote, then every dollar sign -- escaping EVERY dollar sign (not only one
            # followed by an opening brace) neutralizes Nix's own string-interpolation syntax too,
            # without this generator script ever having to spell out that two-character opener
            # itself inside its own Nix source.
            printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g'
          }

          echo "# nixusb.devices — generated from the USB devices currently attached to $(hostname)."
          echo "# Review before committing: names are guesses, and a device with no serial can only"
          echo "# ever name ONE unit of that model."
          echo
          echo "nixusb.devices = {"

          for dev in /sys/bus/usb/devices/*; do
            [ -r "$dev/idVendor" ] || continue

            vid=$(cat "$dev/idVendor")
            pid=$(cat "$dev/idProduct")
            serial=$(cat "$dev/serial" 2>/dev/null || true)
            product=$(cat "$dev/product" 2>/dev/null || true)
            manufacturer=$(cat "$dev/manufacturer" 2>/dev/null || true)

            # Root hubs are not interesting inventory -- they are the bus, not a device on it.
            case "$product" in *"root hub"*) continue ;; esac
            [ -n "$product" ] || continue

            name=$(printf '%s' "$product" \
              | tr '[:upper:]' '[:lower:]' \
              | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//')
            [ -n "$name" ] || name="usb-$vid-$pid"

            serialEsc=$(nixEscape "$serial")
            descriptionEsc=$(nixEscape "$manufacturer $product")

            echo "  \"$name\" = {"
            echo "    vendorId = \"$vid\";"
            echo "    productId = \"$pid\";"
            if [ -n "$serial" ]; then
              echo "    serial = \"$serialEsc\";"
            else
              echo "    # This device reports no USB serial, so it is identified by model alone."
            fi
            echo "    description = \"$descriptionEsc\";"
            echo "  };"
          done

          echo "};"
        '';
      };
    in
    {
      nixosModules.nixusb = import ./modules/default.nix;
      nixosModules.default = self.nixosModules.nixusb;

      # For non-NixOS hosts (Arch/CachyOS et al.) applying config via numtide/system-manager rather
      # than a real NixOS rebuild. Both planes import the SAME options.nix, so the inventory and its
      # assertions are defined exactly once; only the projection onto udev differs.
      systemManagerModules.nixusb = import ./system-manager/default.nix;
      systemManagerModules.default = self.systemManagerModules.nixusb;

      apps = forAllSystems (system: {
        detect-devices = {
          type = "app";
          program = "${mkDetectDevices (pkgsFor system)}/bin/detect-devices";
        };
      });

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit nixpkgs;
          nixusbModule = self.nixosModules.nixusb;
          systemManagerModule = self.systemManagerModules.nixusb;
          systemManagerLib = system-manager.lib;
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
