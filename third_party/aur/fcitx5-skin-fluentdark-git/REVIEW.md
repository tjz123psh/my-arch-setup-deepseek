# Review: fcitx5-skin-fluentdark-git

## Provenance

- AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/fcitx5-skin-fluentdark-git`
- AUR commit: `3c1548f95b2fa5b93b5e9cdd92fefadae4ea6d05` (2024-02-27, “merge with fluentlight”)
- Upstream commit: `399699ac7d366ed6c1952646ed71647e3c8f99b5` (2025-01-07, “Update README.md”)
- Fixed archive: `https://github.com/Reverier-Xu/Fluent-fcitx5/archive/399699ac7d366ed6c1952646ed71647e3c8f99b5.tar.gz`
- SHA-256: `47793bd78207b0752903de093a7fc313ca8cf5ac4d5a28316704cc1160e1cf5f`
- License: upstream `LICENSE` is Mozilla Public License 2.0; the AUR/installed package metadata uses `MPL`.

## Version reconciliation

`manifests/workstation-package-inventory.tsv` observes `v0.4.0.r7.g399699a-1`. The reviewed upstream commit has tag-distance identity `v0.4.0-7-g399699a`, which maps under the AUR version convention to `pkgver=v0.4.0.r7.g399699a`; with `pkgrel=1`, the local recipe exactly reproduces the observed version. The literal version stored in the old floating AUR recipe was stale and was not reused.

## Local changes from the AUR recipe

- Replaced the floating VCS checkout and unchecked source with one commit archive and its reviewed SHA-256.
- Removed the dynamic version function and all build-time VCS requirements.
- Kept the package x86_64-only and retained the original runtime dependency on `fcitx5`.
- Preserved provider/conflict semantics: this package declares neither a provider nor a conflict.
- Preserved the installed payload scope: only `FluentDark` and `FluentDark-solid`, not the light variants present upstream.

## Risks and review notes

- Forge-generated archives are addressed by immutable commit, but a forge-side archive regeneration would intentionally fail the recorded checksum rather than silently change input.
- Blur and shadow behavior remains compositor-dependent; the solid variant is included as the upstream fallback.
- This recipe does not install or activate an Fcitx theme automatically.

## Expected output

- Package identity: `fcitx5-skin-fluentdark-git v0.4.0.r7.g399699a-1 (x86_64)`
- Default artifact name: `fcitx5-skin-fluentdark-git-v0.4.0.r7.g399699a-1-x86_64.pkg.tar.zst`
- With this workstation's enabled debug option, `makepkg --packagelist` also reports `fcitx5-skin-fluentdark-git-debug-v0.4.0.r7.g399699a-1-x86_64.pkg.tar.zst`.
- Payload: six files under each of `/usr/share/fcitx5/themes/FluentDark/` and `/usr/share/fcitx5/themes/FluentDark-solid/`.
