{ ... }:
{
  # Placeholder — replaced by `nixos-generate-config --show-hardware-config`
  # output during Phase 4.
  boot.initrd.availableKernelModules = [ ];
  boot.kernelModules = [ ];
  hardware.enableRedistributableFirmware = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  # Phase 1 stub: satisfies the `fileSystems."/"` assertion so the flake
  # evaluates. The real entry comes from `nixos-generate-config` in Phase 4
  # and will point at the @root BTRFS subvolume on lv_root.
  fileSystems."/" = {
    device = "/dev/disk/by-label/PLACEHOLDER";
    fsType = "ext4";
  };
}
