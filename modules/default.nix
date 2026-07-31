# NixOS entry point: the shared inventory + the NixOS projection of it.
{ ... }:
{
  imports = [
    ./options.nix
    ./nixos.nix
  ];
}
