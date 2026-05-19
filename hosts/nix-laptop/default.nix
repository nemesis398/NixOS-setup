{ inputs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
  ];

  networking.hostname = "nix-laptop";
  system.stateVersion = "25.05";
}
