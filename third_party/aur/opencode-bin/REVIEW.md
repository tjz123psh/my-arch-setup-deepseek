# Review: opencode-bin

> **2026-09-19 复核**：本文顶部的 AUR commit / 版本号为首次审查时的快照，可能落后于当前 pin；
> 权威值以同目录 `AUR_COMMIT`、`PKGBUILD` 与文末 Update 段为准。

## Status

- Decision: **reviewed and pinned** for x86_64; fixed version matches the observed workstation package.
- The release archive was not downloaded or executed.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/opencode-bin`
- AUR origin: `https://aur.archlinux.org/opencode-bin.git`
- AUR commit: `69b15cc11ee8eecc8e4379075f18af9ead1bd6af` (2026-07-30, `Update to v1.18.10`)
- Reviewed tree: `205835e72539d1ccbdcd6849893612de61786a63`
- Upstream tag `v1.18.10` resolves to commit `7902e04c3a67f7c69726bc955efb46e29214c797`.
- Upstream version / license: `1.18.10` / MIT.
- Fixed x86_64 archive SHA-256: `6b1113da704253fb4da12b41e4236acecb9f2b62949c945f6eeacaa15111b976`.
- The AUR clone's full commit/object checks passed.

## Version reconciliation

- Inventory observation: `1.18.10-1`.
- AUR snapshot and fixed recipe: `1.18.10-1`.
- `vercmp` result: `0` (**same**).

## Local changes from the AUR recipe

- Removed the ARM source/checksum and restricted `arch` to x86_64.
- Kept only the version-qualified GitHub release archive and complete SHA-256.
- Removed an empty subversion variable without changing the resolved URL.
- The package phase only installs the already acquired binary.

## Remaining risks

- The upstream executable was not independently rebuilt or runtime-tested.
- The release tag URL is checksum-gated but no detached upstream signature is declared.
- Runtime interactions with external AI providers are outside package-build review scope.

## Expected output

- Package: `opencode-bin 1.18.31-1 (x86_64)`
- Provider: `opencode`
- Default artifact: `opencode-bin-1.18.31-1-x86_64.pkg.tar.zst`
- Expected executable: `/usr/bin/opencode`.

## Update 2026-09-17: 1.18.10 -> 1.18.31 (AUR commit 0e7831a8531d9a796b6b5ef85edb1b83f32950db)

- Local form kept: x86_64 only, version-qualified release URL, the AUR empty _subver not carried over,
  ARM source/checksum removed.
- Release archive re-downloaded (60,590,585 B) and hashed: sha256
  e9312be75ed803b7415fc2aeabda1f4fe938912a39673762dc0c38c0e11ebde4 (matches the AUR recipe value).
