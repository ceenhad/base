# ceenhad/base

The nixpkgs, Rust, Node and Python that every ceenhad repo builds with, plus
the CI pieces that make those builds cheap. One pin here instead of one per
repo, so versions can't drift apart between repos, and build-mini keeps one
copy of each toolchain and of every dependency built with it, not one per repo.

| | Version | Where it's chosen |
|---|---|---|
| nixpkgs | `3497aa5c` (26.05pre, 2026-01-08) | `flake.nix` |
| Rust | 1.96.0, with rust-src, clippy, rustfmt, rust-analyzer | `versions.toml` |
| Node | 22 | `versions.toml` |
| Python | 3.13 | `versions.toml` |

Public on purpose: it holds no product code and no secrets, and any flake,
cloud session or CI runner can fetch it with no token.

## Using it

```nix
{
  inputs = {
    base.url = "github:ceenhad/base";
    # Follow its nixpkgs, never a pin of your own: that is what shares the
    # store between repos.
    nixpkgs.follows = "base/nixpkgs";
  };

  outputs = { self, base, ... }: {
    devShells = base.lib.forSystems (pkgs: {
      default = pkgs.mkShell {
        inputsFrom = [ base.devShells.${pkgs.stdenv.hostPlatform.system}.rust ];
        packages = [ pkgs.sqlx-cli ];
      };
    });

    checks = base.lib.forSystems (pkgs: let c = pkgs.base.checks; in {
      api = c.rust { name = "api"; root = ./.; src = c.src ./. [ "api" ]; dir = "api"; };
      web = c.npm  { name = "web"; root = ./.; src = c.src ./. [ "web" ]; dir = "web"; };
      tools = c.python { name = "tools"; src = c.src ./. [ "tools" ]; dir = "tools";
                         packages = ps: [ ps.httpx ]; };
    });
  };
}
```

`base.legacyPackages.<system>` is nixpkgs with `pkgs.base` added:

- `pkgs.base.rust`, or `pkgs.base.rustWith { targets = [ ... ]; }` to cross-compile at the same version
- `pkgs.base.crane`: crane on that toolchain
- `pkgs.base.node`, `pkgs.base.python`
- `pkgs.base.checks`: `rust`, `python`, `npm`, `src`, `srcExcept`; see [lib/checks.nix](lib/checks.nix)

A repo that needs something newer than the pin for one package (pantheon's
CI runner, say) adds a second nixpkgs input for that package alone, and says
why next to it.

Moving every repo to a new version: change it here, let CI pass, then
`nix flake update base` in each repo.

## CI

[`.github/workflows/nix-checks.yml`](.github/workflows/nix-checks.yml) runs a
repo's `checks.<system>.*` as a gate, the way pro-fi-pantheon does: each
check its own job, only the ones whose files changed, drafts nothing until
ready for review. A check nothing touched is already in the store and costs
seconds.

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  workflow_dispatch:
jobs:
  nix:
    uses: ceenhad/base/.github/workflows/nix-checks.yml@main
    with:
      filters: .github/ci-filters.yml   # optional
```

By default it runs on build-mini (`[self-hosted, build-mini, nix]`, a runner
registered for the repo in ceenhad/strongbox `machines/build-mini/`), whose
Nix sends Linux builds to its VM. For GitHub's hosted runners, pass
`runs-on: '["ubuntu-latest"]'` and `system: x86_64-linux`. A public repo uses
hosted runners only: on build-mini a pull request from a fork would run on
the build machine. This repo's own CI does exactly that.
