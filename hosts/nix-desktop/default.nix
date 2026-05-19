{ inputs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
  ];

  networking.hostName = "nix-desktop";
  system.stateVersion = "25.05";
}
