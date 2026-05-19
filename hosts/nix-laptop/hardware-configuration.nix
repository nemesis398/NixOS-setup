{ ... }:
{
  # Placeholder — replaced by `nixos-generate-config --show-hardware-config`
  # output during Phase 4.
  boot.initrd.availableKernelModules = [ ];
  boot.kernelModules = [ ];
  hardware.enableRedistributableFirmware = true;
  nixpkgs.hostPlatform = "x86_64-linux";
}