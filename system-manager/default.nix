# Arch/CachyOS plane: system-manager has no `services.udev`, so write the rules file directly.
# udev reads /etc/udev/rules.d, so an `environment.etc` entry is the whole mechanism.
#
# The inventory and its assertions come from the SAME ../modules/options.nix the NixOS plane imports
# -- there is exactly one definition of nixusb.devices in this repo, and only the projection differs.
#
# After a first apply the rules are not retroactive: device nodes that already exist keep whatever
# identity they were (or were not) stamped with. Either replug the device or run:
#   udevadm control --reload-rules && udevadm trigger --subsystem-match=usb
{ lib, config, ... }:
let
  cfg = config.nixusb;
in
{
  imports = [ ../modules/options.nix ];

  config = lib.mkIf cfg.enable {
    environment.etc."udev/rules.d/70-nixusb-by-name.rules".text = cfg.rules;
  };
}
