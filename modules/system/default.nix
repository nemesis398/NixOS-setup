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
  boot.loader.systemd-boot.configurationLimit = 20;
}
