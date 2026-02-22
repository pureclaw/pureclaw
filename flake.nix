{
  description = "PureClaw — Haskell-native AI agent runtime with security-by-construction";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    haskell-nix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, haskell-nix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          inherit (haskell-nix) config;
          overlays = [ haskell-nix.overlay ];
        };

        # Pin GHC version here — bump deliberately, then re-freeze deps
        ghcVersion = "ghc9101";

        project = pkgs.haskell-nix.cabalProject' {
          src = ./.;
          compiler-nix-name = ghcVersion;

          # Dev shell tools — only present in `nix develop`, not in the build
          shell.tools = {
            cabal                = "latest";
            haskell-language-server = "latest";
            hlint                = "latest";
            ormolu               = "latest";  # formatter
          };

          shell.buildInputs = with pkgs; [
            pkg-config
            zlib        # common Haskell dep
            openssl     # for http-client-tls
          ];

          shell.shellHook = ''
            echo "PureClaw dev shell (GHC ${ghcVersion})"
            echo "  cabal build        — build all"
            echo "  cabal test         — run tests"
            echo "  cabal repl         — REPL"
            echo "  ormolu --mode inplace src/**/*.hs  — format"
          '';
        };

        flake = project.flake {};

      in flake // {
        # nix build  →  builds the pureclaw executable
        packages.default = flake.packages."pureclaw:exe:pureclaw";

        # nix run  →  runs pureclaw directly
        apps.default = {
          type = "app";
          program = "${flake.packages."pureclaw:exe:pureclaw"}/bin/pureclaw";
        };

        # nix develop  →  enters dev shell with GHC + HLS + cabal + ormolu
        # devShell is already set by project.flake {}
      }
    );

  nixConfig = {
    extra-substituters = [
      # IOG binary cache — covers haskell.nix + most Haskell packages
      "https://cache.iog.io"
      # Project binary cache — CI pushes here after successful builds
      "s3://mb-nix-cache?region=us-east-1"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "equitek-ci:vXVUXig6ISy/jPmxB9VPRwpju17OfraujXiUwAXW6co="
    ];
  };
}
