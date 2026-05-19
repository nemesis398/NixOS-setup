{ inputs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
  ];

  networking.hostName = "nix-laptop";
  system.stateVersion = "25.05";
}
