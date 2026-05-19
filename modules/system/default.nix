{ ... }:
{
  imports = [
    ./locale.nix
    ./users.nix
  ];

  # Architecture Layer 9 settings
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  # ADR-05: systemd-boot only. Enabling it here also satisfies the bootloader
  # assertion in the Phase 1 skeleton (otherwise NixOS falls back to GRUB,
  # which demands `boot.loader.grub.devices`).
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;
}
