{
  description = "ceenhad/base: the nixpkgs, Rust, Node and Python every ceenhad repo builds with";

  inputs = {
    # THE pin. Pantheon, lwcp and auctor-home already ran exactly this rev
    # (26.05pre, 2026-01-08) when this repo started, so adopting it costs
    # them nothing and build-mini's store is already warm with it. A repo
    # that follows it shares every store path with the others: one Rust
    # toolchain, one Node, one Python on disk and in the cache, not one each.
    nixpkgs.url = "github:NixOS/nixpkgs/3497aa5c9457a9d88d71fa93a4a8368816fbeeba";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Incremental Cargo builds: dependencies compile once into their own
    # derivation, so a change to a repo's own crates rebuilds only those.
    crane.url = "github:ipetkov/crane";
  };

  outputs = { self, nixpkgs, rust-overlay, crane }:
    let
      lib = nixpkgs.lib;
      versions = builtins.fromTOML (builtins.readFile ./versions.toml);
      # `crane` is also a name inside the overlay's rec set below.
      craneInput = crane;
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
      forSystems = f: lib.genAttrs systems (system: f (self.legacyPackages.${system}));

      # Adds `pkgs.base`: the shared toolchains, and crane built on them.
      overlay = final: _prev: {
        base = rec {
          inherit versions;
          # base.rustWith { targets = [ "thumbv7em-none-eabihf" ]; } for a
          # repo that cross-compiles; the version stays the shared one.
          rustWith = { targets ? [ ], extensions ? [ ] }:
            final.rust-bin.stable.${versions.rust.channel}.default.override {
              extensions = versions.rust.components ++ extensions;
              inherit targets;
            };
          rust = rustWith { };
          crane = (craneInput.mkLib final).overrideToolchain (_: rust);
          node = final."nodejs_${toString versions.node.major}";
          python = final."python3${toString versions.python.minor}";
          checks = import ./lib/checks.nix { pkgs = final; };
        };
      };
    in
    {
      overlays.default = lib.composeExtensions (import rust-overlay) overlay;

      # The package set with the overlay applied. A repo uses
      # `base.legacyPackages.${system}` as its pkgs, so it evaluates nixpkgs
      # once in the same way as every other repo.
      legacyPackages = lib.genAttrs systems (system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        });

      lib = {
        inherit versions systems forSystems;
        # The CI pieces a repo's checks are made of; see lib/checks.nix.
        checks = pkgs: pkgs.base.checks;
      };

      # Shells to extend or use as they are:
      #   devShells.default = pkgs.mkShell {
      #     inputsFrom = [ base.devShells.${system}.rust ];
      #     packages = [ ... ];
      #   };
      devShells = forSystems (pkgs:
        let
          common = with pkgs; [ git jq just pkg-config ];
        in rec {
          rust = pkgs.mkShell {
            packages = common ++ [ pkgs.base.rust ]
              ++ lib.optionals pkgs.stdenv.isDarwin [ pkgs.libiconv ];
          };
          node = pkgs.mkShell { packages = common ++ [ pkgs.base.node ]; };
          python = pkgs.mkShell {
            packages = common ++ [ pkgs.base.python pkgs.uv pkgs.ruff ];
          };
          # Everything, for a repo that mixes them.
          default = pkgs.mkShell { inputsFrom = [ rust node python ]; };
        });

      # This repo's own gate: every shell evaluates and builds on every
      # system build-mini can reach (macOS itself, and Linux through its VM).
      checks = forSystems (pkgs: {
        shells = pkgs.runCommand "base-shells" {
          nativeBuildInputs = [ pkgs.base.rust pkgs.base.node pkgs.base.python ];
        } ''
          rustc --version | grep -F " ${versions.rust.channel} "
          node --version | grep -E '^v${toString versions.node.major}\.'
          python3 --version | grep -F ' 3.${toString versions.python.minor}.'
          touch $out
        '';
      });

      formatter = forSystems (pkgs: pkgs.nixfmt);
    };
}
