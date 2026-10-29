# The pieces a repo's CI checks are built from, taken from pro-fi-pantheon's
# shared/substrate/ci/checks.nix, where they moved its gates onto build-mini.
#
# WHY CHECKS ARE NIX DERIVATIONS. A check's source is only the files it reads
# (`src` below). When none of them changed, its result is already in the
# store and the gate costs an evaluation: a re-run, a rebase, a push that
# touched another project, or a second PR with the same tree. When something
# did change, crane's dependency-only build is still cached, so only the
# repo's own crates compile. And because every repo builds with the same
# toolchain from the same nixpkgs, those dependency builds and toolchains are
# shared between repos too.
#
# Use them from a repo's flake:
#
#   checks = base.lib.forSystems (pkgs: let c = pkgs.base.checks; in {
#     api = c.rust {
#       name = "api";
#       src = c.src ./. [ "api" "shared/proto" ];
#       dir = "api";
#     };
#     web = c.npm { name = "web"; src = c.src ./. [ "web" ]; dir = "web"; };
#   });
#
# and build one with `nix build .#checks.<system>.api`.
{ pkgs }:
let
  lib = pkgs.lib;

  # A check's output is a stamp: the gate is that the build succeeded.
  stamp = ''
    runHook preInstall
    touch $out
    runHook postInstall
  '';
in
rec {
  # The source for a check: `paths` under `root` (files or folders), never
  # Markdown, minus `exclude`. A docs edit then busts no cache, and a test
  # that reads a file outside its paths fails in the sandbox instead of
  # passing on a runner that happens to have the whole checkout.
  src = root: paths: srcExcept root paths [ ];
  srcExcept = root: paths: exclude:
    lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.difference
        (lib.fileset.unions (map (p: root + "/${p}") paths))
        (lib.fileset.unions (
          [ (lib.fileset.fileFilter (f: f.hasExt "md") root) ]
          ++ map (p: root + "/${p}") exclude));
    };

  # ── Rust ─────────────────────────────────────────────────────────────────
  # `dir` is the workspace inside `src`; `commands` run in it, offline against
  # its Cargo.lock. `depsCommand` builds the dependency graph once, in the
  # profiles and features `commands` use, so it is reused until Cargo.lock or
  # the toolchain changes.
  rust =
    { name
    , src
    , dir ? "."
    , commands ? ''
        cargo fmt --check
        cargo clippy --workspace --all-targets --locked -- -D warnings
        cargo test --workspace --locked
      ''
    , depsCommand ? "cargo clippy --workspace --all-targets --locked && cargo test --workspace --locked --no-run"
    , toolchain ? pkgs.base.rust
    , nativeBuildInputs ? [ ]
    , buildInputs ? [ ]
    # Attributes for the check alone, not its dependency build.
    , extra ? { }
    }:
    let
      craneLib = pkgs.base.crane.overrideToolchain (_: toolchain);
      cargoLock = "${src}/${dir}/Cargo.lock";
      common = {
        pname = "ci-${name}";
        version = "0";
        inherit src;
        sourceRoot = "source/${dir}";
        inherit cargoLock;
        cargoVendorDir = craneLib.vendorCargoDeps { inherit cargoLock; };
        strictDeps = true;
        nativeBuildInputs = [ pkgs.pkg-config ] ++ nativeBuildInputs;
        buildInputs = buildInputs
          ++ lib.optionals pkgs.stdenv.isDarwin [ pkgs.libiconv ];
        CARGO_PROFILE = "";
        CARGO_TERM_COLOR = "never";
      };
      cargoArtifacts = craneLib.buildDepsOnly (common // {
        buildPhaseCargoCommand = depsCommand;
        doCheck = false;
      });
    in
    craneLib.mkCargoDerivation (common // {
      inherit cargoArtifacts;
      buildPhaseCargoCommand = commands;
      doInstallCargoArtifacts = false;
      installPhase = stamp;
    } // extra);

  # ── Python ───────────────────────────────────────────────────────────────
  # The shared interpreter with `packages` from nixpkgs (no pip resolution in
  # the sandbox). The project is installed editable, without its own
  # dependencies, into a venv over it, then ruff and pytest run from `dir`.
  python =
    { name
    , src
    , dir ? "."
    , packages ? (_: [ ])
    , lint ? true
    , tests ? "tests"
    , pre ? ""
    , nativeBuildInputs ? [ ]
    }:
    let
      py = pkgs.base.python.withPackages (ps:
        [ ps.pip ps.setuptools ps.wheel ps.pytest ] ++ packages ps);
    in
    pkgs.runCommand "ci-${name}"
      {
        inherit src;
        nativeBuildInputs = [ py pkgs.ruff ] ++ nativeBuildInputs;
      } ''
      cp -r --no-preserve=mode $src source
      cd source/${dir}
      export HOME=$TMPDIR MPLBACKEND=Agg
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      python -m venv --system-site-packages $TMPDIR/venv
      . $TMPDIR/venv/bin/activate
      if [ -f pyproject.toml ] || [ -f setup.py ]; then
        pip install --quiet --no-index --no-deps --no-build-isolation -e .
      fi
      ${pre}
      ${lib.optionalString lint "ruff check --no-cache ."}
      python -m pytest -p no:cacheprovider -q ${tests}
      touch $out
    '';

  # ── Node ─────────────────────────────────────────────────────────────────
  # `gate` (by default `npm run gate`: typecheck, lint, build, test, as the
  # package defines it) with node_modules from package-lock.json, each
  # package fetched by its own integrity hash, so there is no npmDepsHash to
  # keep current.
  npm =
    { name
    , src
    , dir ? "."
    , gate ? "npm run gate"
    , nativeBuildInputs ? [ ]
    , extra ? { }
    }:
    pkgs.buildNpmPackage ({
      pname = "ci-${name}";
      version = "0";
      inherit src nativeBuildInputs;
      nodejs = pkgs.base.node;
      sourceRoot = "source/${dir}";
      npmDeps = pkgs.importNpmLock { npmRoot = "${src}/${dir}"; };
      npmConfigHook = pkgs.importNpmLock.npmConfigHook;
      PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
      buildPhase = ''
        runHook preBuild
        ${gate}
        runHook postBuild
      '';
      dontNpmInstall = true;
      installPhase = stamp;
    } // extra);
}
