# NixOS plane: hand the generated rules to services.udev.
{ lib, config, ... }:
let
  cfg = config.nixusb;
in
{
  config = lib.mkIf cfg.enable {
    services.udev.extraRules = cfg.rules;
  };
}
