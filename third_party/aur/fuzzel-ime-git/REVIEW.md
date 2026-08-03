# Review: fuzzel-ime-git

## Provenance

- AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/fuzzel-ime-git`
- AUR commit: `c49a01c7c754df0663cfa0dacfdf7c71ea4711dd` (2026-06-18, “Remove obsolete IME patch”)
- Upstream commit: `302f228bb87d3c861a8debd39b9d8e4a0ea81037` (2026-07-25, documentation typo fix)
- Fixed archive: `https://codeberg.org/dnkl/fuzzel/archive/302f228bb87d3c861a8debd39b9d8e4a0ea81037.tar.gz`
- SHA-256: `8208887cc93899c560e7543b118c0763167b2096bc9407135f2bee952cef0447`
- License: MIT; the upstream `LICENSE` is installed under `/usr/share/licenses/fuzzel-ime-git/`.

## Version reconciliation

`manifests/workstation-package-inventory.tsv` observes `1.14.1.r26.g302f228-1`. The reviewed upstream commit has tag-distance identity `1.14.1-26-g302f228`, which maps under the AUR version convention to `pkgver=1.14.1.r26.g302f228`; with `pkgrel=1`, the local recipe exactly reproduces the observed version. The literal version stored in the floating AUR recipe represented an earlier source state and was not reused.

## Local changes from the AUR recipe

- Replaced the floating VCS checkout and unchecked source with one commit archive and its reviewed SHA-256.
- Removed the dynamic version function and the VCS build dependency.
- Restricted `arch` from the AUR recipe's x86_64/aarch64 set to the requested x86_64-only scope.
- Preserved `provides=("fuzzel=${pkgver}")` and conflicts with both `fuzzel` and `fuzzel-git`.
- Retained the AUR commit's removal of the old IME patch because the support is upstream at the pinned commit.

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
