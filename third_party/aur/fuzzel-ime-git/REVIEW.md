# Review: fuzzel-ime-git

## Provenance

- AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/fuzzel-ime-git`
- AUR commit: `c49a01c7c754df0663cfa0dacfdf7c71ea4711dd` (2026-06-18, “Remove obsolete IME patch”)
- Upstream commit: `302f228bb87d3c861a8debd39b9d8e4a0ea81037` (2026-07-25, documentation typo fix)
- Fixed archive: `https://codeberg.org/dnkl/fuzzel/archive/302f228bb87d3c861a8debd39b9d8e4a0ea81037.tar.gz`
- SHA-256: `8208887cc93899c560e7543b118c0763167b2096bc9407135f2bee952cef0447`
- License: MIT; the upstream `LICENSE` is installed under `/usr/share/licenses/fuzzel-ime-git/`.

## Version reconciliation

`manifests/workstation-packages.tsv` observes `1.14.1.r26.g302f228-1`. The reviewed upstream commit has tag-distance identity `1.14.1-26-g302f228`, which maps under the AUR version convention to `pkgver=1.14.1.r26.g302f228`; with `pkgrel=1`, the local recipe exactly reproduces the observed version. The literal version stored in the floating AUR recipe represented an earlier source state and was not reused.

## Local changes from the AUR recipe

- Replaced the floating VCS checkout and unchecked source with one commit archive and its reviewed SHA-256.
- Removed the dynamic version function and the VCS build dependency.
- Restricted `arch` from the AUR recipe's x86_64/aarch64 set to the requested x86_64-only scope.
- Preserved `provides=("fuzzel=${pkgver}")` and conflicts with both `fuzzel` and `fuzzel-git`.
- Retained the AUR commit's removal of the old IME patch because the support is upstream at the pinned commit.
- **Local modification (2026-08-06): switched the source from the Codeberg archive
  endpoint to a pinned git clone.** The archive endpoint
  (`https://codeberg.org/dnkl/fuzzel/archive/<commit>.tar.gz`) is unreachable
  from CN networks (connection hangs; verified from both the validation VM and
  the operator host) while the git smart-HTTP endpoint
  (`https://codeberg.org/dnkl/fuzzel.git`) responds. The recipe now clones the
  same pinned commit (`302f228…`) into the same `fuzzel/` srcdir layout, so
  `build()` is unchanged; `sha256sums` becomes `SKIP`, as is conventional for
  git sources. The original archive SHA-256 is recorded in Provenance above.

## Risks and review notes

- The Codeberg archive extracts to a stable `fuzzel/` directory rather than a commit-suffixed directory; clean source trees remain important when rebuilding.
- The archive has no repository metadata, so the upstream binary version generator falls back to the Meson project version `1.14.1`; the Arch package version still carries and reconciles the exact commit identity.
- Upstream ships optional Meson fallback descriptors. Declared system dependencies satisfy them, and Arch's Meson wrapper disables fallback downloads.
- Forge-generated archives are addressed by immutable commit, but a forge-side archive regeneration would intentionally fail the recorded checksum.

## Expected output

- Package identity: `fuzzel-ime-git 1.14.1.r26.g302f228-1 (x86_64)`
- Provider: `fuzzel=1.14.1.r26.g302f228`
- Default artifact name: `fuzzel-ime-git-1.14.1.r26.g302f228-1-x86_64.pkg.tar.zst`
- With this workstation's enabled debug option, `makepkg --packagelist` also reports `fuzzel-ime-git-debug-1.14.1.r26.g302f228-1-x86_64.pkg.tar.zst`.
- Payload includes `/usr/bin/fuzzel`, the system example configuration, manual pages, fish/zsh completions, documentation, and the package license copy.

## Update 2026-09-17: pin upstream master 616485c08cd0924af23f0ee9cbf7f104baba2dcc

- The AUR recipe itself is unchanged (AUR commit c49a01c7c754df0663cfa0dacfdf7c71ea4711dd still current);
  the -git package tracks upstream master, which moved from 302f228 to 616485c0.
- git describe --long --tags 616485c = 1.15.0-7-g616485c -> pkgver=1.15.0.r7.g616485c (same AUR mapping rule).
- Local modification retained: pinned git+https://codeberg.org/dnkl/fuzzel.git#commit=... clone instead of
  the unreachable Codeberg archive endpoint; x86_64-only arch kept.
- Verified against a --bare --filter=blob:none clone of the upstream repository (commit exists, describe matches).
