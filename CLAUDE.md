# ceenhad/base

## Where to build and test

How to build from whichever machine you are on is ceenhad/strongbox's
`machines/building.md`, the one copy for every repo. Strongbox's session hook
hands each session its machine's part of it. This repo's only check is
`shells` (`flake.nix` `checks`): `aarch64-darwin` is what CI's macOS lane
builds; `aarch64-linux` is what the other repos' CI builds with on build-mini.
Never build `x86_64-linux` on build-mini. This repo's CI is the only place
base's x86_64 build runs. When you change how anything builds, edit
`building.md`, never a repo's `CLAUDE.md`.

**CI** This repo is public, so its own `.github/workflows/ci.yml` runs on
GitHub's hosted runners, which cost nothing for a public repo, and never on
build-mini, where a pull request from a fork would run on the build machine.
It calls this repo's `nix-checks.yml` twice, for a pull request once it is
ready for review, for a push to `main`, and by hand: `linux` on
`ubuntu-latest` (`x86_64-linux`) and `macos` on `macos-latest`
(`aarch64-darwin`). Each builds every check and evaluates the flake for every
system without building; there is no paths filter. A CI result you didn't see
is not a pass: say what ran.

The other repos call `nix-checks.yml@main`, on build-mini by default, so a
change to it reaches all of them on their next run. A change to a version
(`versions.toml`, `flake.lock`) reaches a repo only when that repo moves:
change it here, let CI pass, then run `nix flake update base` in each repo and
let its CI pass. The weekly version-drift check (ceenhad/strongbox
`machines/mac-mini-1/version-drift.py`) reports, in a "Version drift" issue on
this repo, every repo whose `base` is behind `main`.
