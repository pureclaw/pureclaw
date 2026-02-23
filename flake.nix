{
  description = "A very basic flake";
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils, haskellNix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (system:
    let
      lib = nixpkgs.lib;
      overlays = [ haskellNix.overlay
        (final: prev: {
          # This overlay adds our project to pkgs
          pureclaw-project =
            final.haskell-nix.cabalProject' {
              src = ./.;
              compiler-nix-name = "ghc9121";
              modules = [
                  {
                      enableProfiling = true;
                      enableLibraryProfiling = true;
                  }
              ];

              # This is used by `nix develop .` to open a shell for use with
              # `cabal`, `hlint` and `haskell-language-server`
              shell.tools = {
                cabal = {};
                ghcid = {};
                hlint = {};
                # haskell-language-server = {};
              };
            };
        })
      ];
      pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
      flake = pkgs.pureclaw-project.flake {
        # This adds support for `nix build .#js-unknown-ghcjs:hello:exe:hello`
        # crossPlatforms = p: [p.ghcjs];
      };
    in flake // {
      # Built by `nix build .`
      packages.default = flake.packages."pureclaw:exe:pureclaw";
      inherit pkgs;
    });
}
