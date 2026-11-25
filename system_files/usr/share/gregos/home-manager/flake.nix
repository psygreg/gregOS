{
  description = "Home Manager configuration for @USER@ on gregOS";

  inputs = {
    # nixpkgs-unstable matches the nixpkgs the image exposes through the Nix
    # flake registry, so Home Manager packages and the host GPU drivers use
    # the same glibc generation.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/@REF@";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      homeConfigurations."@USER@" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./home.nix ];
      };
    };
}
