{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/release-21.05";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system};
      in rec {
        # `nix build`
        packages.elo-anything = pkgs.stdenv.mkDerivation {
          name = "elo-anything";
          src = ./.;

          buildInputs = [ pkgs.elmPackages.elm pkgs.elmPackages.elm-test ];
          buildPhase = pkgs.elmPackages.fetchElmDeps {
            elmPackages = import ./nix/elm-srcs.nix;
            elmVersion = "0.19.1";
            registryDat = ./nix/registry.dat;
          };

          doCheck = true;
          checkPhase = ''
            env ELM_HOME=.elm elm-test
          '';

          installPhase = ''
            make dist
            mkdir -p $out/share/
            mv dist $out/share/elo-anything
          '';
        };
        defaultPackage = packages.elo-anything;
        overlay = final: prev: { elo-anything = packages.elo-anything; };

        # `nix shell`
        devShell = pkgs.mkShell {
          buildInputs = with pkgs; [
            git

            # Elm
            elmPackages.elm
            elmPackages.elm-format
            elmPackages.elm-json
            elmPackages.elm-test
            elm2nix

            # Build Stuff
            gnumake
            modd
            devd
          ];
        };
      });
}
