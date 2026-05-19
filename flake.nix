{
  description = "My personal NixOS configuration for a multi-host fleet.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Inputs added in later phases (commented out until needed):
    #
    # hyprland.url = "github:hyprwm/Hyprland/v0.51.1";
    # quickshell.url  = "git+https://git.outfoxxed.me/quickshell/quickshell?ref=v<TBD>";
    # stylix         = { url = "github:danth/stylix"; inputs.nixpkgs.follows = "nixpkgs"; };
    # sops-nix       = { url = "github:Mic92/sops-nix"; inputs.nixpkgs.follows = "nixpkgs"; };
    # helium         = { url = "github:oxcl/nix-flake-helium-browser"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    disko,
    ...
  } @ inputs: let
    system = "x86_64-linux";

    mkHost = hostname:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {inherit inputs;};
        modules = [
          disko.nixosModules.disko
          ./hosts/${hostname}
          ./modules/system
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {inherit inputs;};
          }
        ];
      };
  in {
    nixosConfigurations = {
      nix-desktop = mkHost "nix-desktop";
      nix-laptop = mkHost "nix-laptop";
    };
  };
}
