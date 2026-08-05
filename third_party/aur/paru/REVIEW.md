# Review: paru

## Status

- Decision: **reviewed AUR recipe with fully automatic upstream build**.
- The previous engineering-era design required a deterministic offline Cargo
  vendor archive (`paru-vendor-2.1.0.tar.zst`) injected from a private source
  cache. Under the current personal-restore-tool vision, AUR packages build
  fully automatically: `makepkg` downloads the pinned upstream source and
  `prepare()` upgrades the alpm crates so the build works against the host's
  libalpm 16. No private source cache, no vendor archive, no hash-gated
  offline acquisition.
- A build cannot start until the pinned upstream source archive is downloaded
  and hash-verified by `makepkg` (standard AUR flow).

## Provenance

- AUR origin: `https://aur.archlinux.org/paru.git`
- Upstream release: `v2.1.0`; upstream source archive SHA-256:
  `eea4dbb524db765d5316f540f9ee670c0bf81aae4827b5417eebb4c9b5651727`.
- Upstream version / license: `2.1.0` / GPL-3.0-or-later.
- Build requires cargo; the installer ensures a Rust toolchain is active
  (`ensure_rust`) before building any AUR package.

## Build flow (as integrated)

1. `makepkg` downloads `paru-2.1.0.tar.gz` from the pinned GitHub release URL
   and verifies its SHA-256.
2. `prepare()` runs `cargo update alpm alpm-utils` to lift the alpm bindings to
   a version supporting libalpm 16, then `cargo fetch --locked --target`.
3. `build()` runs `cargo build --frozen` against the fetched lock.
4. The resulting package installs the same payload as upstream: `/usr/bin/paru`,
   `/etc/paru.conf`, manual pages, completions, locale catalogs.

Verified on a clean VM: `paru 2.1.0-5` builds and runs against the current
Arch libalpm (`paru v2.1.0 - libalpm v16.0.1`).

## Version reconciliation

- Inventory observation: `2.1.0-5` from archlinuxcn.
- Reviewed upstream/AUR package version: `2.1.0`.
- Local package: `2.1.0-5`; `vercmp` against the observation is `0` (**same**).
- The local `pkgrel=5` preserves the observed version boundary while
  identifying the reviewed local packaging revision.

## Local changes from the AUR recipe

- Restricted architecture to x86_64.
- `prepare()` explicitly upgrades `alpm`/`alpm-utils` (the current Arch
  libalpm is v16; the upstream default lock resolves an alpm version that only
  supports libalpm 15) and fetches the lock.
- Builds with `cargo build --frozen`.

## Remaining risks

- Build-time network is required (crates.io fetch during `prepare()`); this is
  the standard AUR trade-off and acceptable for a personal restore tool.
- `libfakeroot internal error: payload not recognized!` may appear during
  man-page compression; it is a known-harmless upstream fakeroot warning and
  does not affect the resulting package.

## Expected output

- Package: `paru 2.1.0-5 (x86_64)`
- Default artifact: `paru-2.1.0-5-x86_64.pkg.tar.zst`
- Expected payload: `/usr/bin/paru`, `/etc/paru.conf`, manual pages,
  completions and locale catalogs.
