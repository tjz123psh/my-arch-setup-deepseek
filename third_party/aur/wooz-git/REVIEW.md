# Review: wooz-git

## Provenance

- AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/wooz-git`
- AUR commit: `3c753bf41b0ce51493924f8d8e9e09ef57313dae` (2025-10-04, “don't treat compiler warnings as errors”)
- Upstream commit: `24e2856bf2cc13810f00971ae143973840555321` (2025-12-27, merge of the zoom-in fix)
- Fixed archive: `https://github.com/negrel/wooz/archive/24e2856bf2cc13810f00971ae143973840555321.tar.gz`
- SHA-256: `4286f17ab328d70c15c667850b15c8c08892dac9cc9e440c58e252c06c74dff8`
- License: MIT; the upstream `LICENSE` is installed under `/usr/share/licenses/wooz-git/`.

## Version reconciliation

`manifests/workstation-package-inventory.tsv` observes `r189.24e2856-1`. The AUR version convention for this package is total reachable commit count plus abbreviated commit: the reviewed upstream commit has count `189` and abbreviation `24e2856`, yielding `pkgver=r189.24e2856`. With `pkgrel=1`, the local recipe exactly reproduces the observed version. The literal version stored in the floating AUR recipe represented an earlier source state and was not reused.

## Local changes from the AUR recipe

- Replaced the floating VCS checkout and unchecked source with one commit archive and its reviewed SHA-256.
- Removed the dynamic version function and the VCS build dependency.
- Kept the existing x86_64-only architecture and AUR build/runtime dependency sets.
- Preserved `provides=('wooz')` and `conflicts=('wooz')` exactly.
- Preserved `-Dwerror=false` from the reviewed AUR commit so compiler warnings do not fail the package build.

## Risks and review notes

- Runtime support depends on the compositor's Wayland protocol support, especially screen capture/output protocols.
- The upstream project is small and still declares version `0.1.0` in Meson; the package version intentionally follows the AUR commit-count convention reconciled above.
- Forge-generated archives are addressed by immutable commit, but a forge-side archive regeneration would intentionally fail the recorded checksum.

## Expected output

- Package identity: `wooz-git r189.24e2856-1 (x86_64)`
- Provider/conflict: `wooz`
- Default artifact name: `wooz-git-r189.24e2856-1-x86_64.pkg.tar.zst`
- With this workstation's enabled debug option, `makepkg --packagelist` also reports `wooz-git-debug-r189.24e2856-1-x86_64.pkg.tar.zst`.
- Payload: `/usr/bin/wooz` and `/usr/share/licenses/wooz-git/LICENSE`.
