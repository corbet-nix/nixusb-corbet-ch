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

            echo "  \"$name\" = {"
            echo "    vendorId = \"$vid\";"
            echo "    productId = \"$pid\";"
            if [ -n "$serial" ]; then
              echo "    serial = \"$serial\";"
            else
              echo "    # This device reports no USB serial, so it is identified by model alone."
            fi
            echo "    description = \"$manufacturer $product\";"
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
