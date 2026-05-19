{ inputs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
  ];

  networking.hostname = "nix-desktop";
  system.stateVersion = "25.05";
}
