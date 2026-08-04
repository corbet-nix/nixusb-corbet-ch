# NixOS entry point: the shared inventory + the NixOS projection of it, plus the package layer's
# NixOS backend (install.nix -- imports packages.nix itself, so this list does not need to name it
# separately).
{ ... }:
{
  imports = [
    ./options.nix
    ./nixos.nix
    ./install.nix
  ];
}
