# Review: intellij-idea-ultimate-edition

## Status

- Decision: **reviewed and pinned** for x86_64; fixed version is newer than the inventory observation.
- The large commercial IDE archive was not downloaded or executed.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/intellij-idea-ultimate-edition`
- AUR origin: `https://aur.archlinux.org/intellij-idea-ultimate-edition.git`
- AUR commit: `6e314a27a1d6296f4365eb7d5b00cf66a25582d7` (2026-07-23, update to `2026.2.0.1`)
- Reviewed tree: `7556da54189361879c2808d6076101c1419cdbd2`
- Upstream version / license: `2026.2.0.1` / `custom:commercial`.
- Fixed JetBrains archive SHA-256: `914e31e31b4e1285d538cf3fae5b300af08bcff36bc298ac6200504bbe12f180`.
- Local desktop file SHA-256: `83af2ba8f9f14275a6684e79d6d4bd9b48cd852c047dacfc81324588fa2ff92b`.
- The AUR clone's full commit/object checks passed.

## Version reconciliation

- Inventory observation: `2026.2-1`.
- AUR snapshot and fixed recipe: `2026.2.0.1-1`.
- `vercmp` result: `1` (**upgrade**).

## Local changes from the AUR recipe

- Removed all ARM-only JBR/fsnotifier sources and conditional preparation logic, including the ordinary-branch raw file.
- Restricted `arch` to x86_64 and retained only the versioned IDEA archive.
- Preserved bundled JBR installation, desktop integration, backups, dependencies, provider, and conflicts.
- Build phases perform only local archive/file operations.

## Remaining risks

- This is a proprietary commercial distribution; entitlement and upstream terms remain the user's responsibility.
- The archive and bundled JBR were not downloaded, independently reproduced, or runtime-tested.
- The recipe preserves the AUR package's self-referential optional JRE metadata while also bundling/providing that JRE; behavior was not changed without a package-level test.

## Expected output

- Package: `intellij-idea-ultimate-edition 2026.2.0.1-1 (x86_64)`
- Default artifact: `intellij-idea-ultimate-edition-2026.2.0.1-1-x86_64.pkg.tar.zst`
- Expected launchers: `/usr/bin/intellij-idea-ultimate-edition` and `/usr/bin/idea`.
