{
  description = "PureClaw — Haskell-native AI agent runtime with security-by-construction";
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      haskellNix,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (
      system:
      let
        lib = nixpkgs.lib;
        overlays = [
          haskellNix.overlay
          (final: prev: {
            # This overlay adds our project to pkgs
            pureclaw-project = final.haskell-nix.cabalProject' {
              src = ./.;
              compiler-nix-name = "ghc9123";
              modules = [
                {
                  enableProfiling = true;
                  enableLibraryProfiling = true;
                }
              ];

              # This is used by `nix develop .` to open a shell for use with
              # `cabal`, `hlint` and `haskell-language-server`
              shell.tools = {
                cabal = { };
                ghcid = { };
                hlint = { };
                # haskell-language-server = {};
              };
              shell.buildInputs = with final; [
                age
                age-plugin-yubikey
                git
                ripgrep
                tmux
              ];
              # signal-cli is intentionally NOT provided by the flake. Signal's
              # servers reject pre-0.14 clients (499 DeprecatedVersionException,
              # May 2026), and the nixpkgs 0.14.3 build ships a broken native
              # libsignal pairing that throws "getServerGuid(...) must not be
              # null" (NPE) on every sealed-sender inbound message — so the
              # gateway can't receive. Install signal-cli >= 0.14.5 system-wide
              # (macOS: `brew install signal-cli`; Linux: distro/upstream
              # release) and ensure it is on PATH for `pureclaw gateway`. The
              # dev shell inherits the caller's PATH, so a system signal-cli is
              # picked up. Revisit in-flake pinning once nixpkgs ships a working
              # signal-cli >= 0.14.5.
            };
          })
        ];
        pkgs = import nixpkgs {
          inherit system overlays;
          inherit (haskellNix) config;
        };
        flake = pkgs.pureclaw-project.flake {
          # This adds support for `nix build .#js-unknown-ghcjs:hello:exe:hello`
          # crossPlatforms = p: [p.ghcjs];
        };
      in
      flake
      // {
        # Built by `nix build .`
        packages.default = flake.packages."pureclaw:exe:pureclaw";
        inherit pkgs;
      }
    );
  nixConfig = {
    extra-substituters = [
      # IOG binary cache — covers haskell.nix + most Haskell packages
      "https://cache.iog.io"
      # Project binary cache — CI pushes here after successful builds
      "https://pureclaw-nix-cache.s3.amazonaws.com"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "pureclaw-ci:tiDJ1F73/W/XyhU5o280QMWljJRc57++M+6TDKSCjQI="
    ];
  };
}
