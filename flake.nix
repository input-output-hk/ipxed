{
  description = "Flake for iPXE Server";

  nixConfig.build-users-group = "";
  nixConfig.extra-experimental-features = "nix-command flakes ca-references";
  nixConfig.extra-substituters =
    "https://hydra.iohk.io https://hydra.mantis.ist";
  nixConfig.extra-trusted-public-keys =
    "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ= hydra.mantis.ist-1:4LTe7Q+5pm8+HawKxvmn2Hx0E3NbkYjtf1oWv+eAmTo=";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-21.05";
    inclusive.url = "github:input-output-hk/nix-inclusive";
    devshell.url = "github:numtide/devshell";
    crystal.url = "github:manveru/crystal-flake";
    utils.url = "github:kreisys/flake-utils";
  };

  outputs = { self, utils, nixpkgs, ... }@inputs:
    let
    in utils.lib.simpleFlake {
      inherit nixpkgs;
      preOverlays = [ inputs.crystal.overlay inputs.devshell.overlay ];

      overlay = final: prev: {
        ipxed = prev.crystal.buildCrystalPackage {
          pname = "ipxed";
          version = "0.1.0";
          format = "shards";
          src = inputs.inclusive.lib.inclusive ./. [ ./src ./shard.yml ];
        };
      };

      packages = { ipxed }@pkgs: { defaultPackage = ipxed; };

      hydraJobs = { ipxed }@pkgs: pkgs;

      devShell = { devshell, lib, crystal, shards, crystal2nix }:
        devshell.mkShell {
          name = "ipxe-server";
          packages = [ crystal shards crystal2nix ];
          env = [ ];
        };
    };
}
