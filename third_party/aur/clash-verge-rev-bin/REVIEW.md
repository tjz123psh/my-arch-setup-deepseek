# Review: clash-verge-rev-bin

## Status

- Decision: **reviewed and pinned** for x86_64 source acquisition; no version regression.
- The review did not download or execute the large Debian artifact, so payload installation remains build-environment dependent.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/clash-verge-rev-bin`
- AUR origin: `https://aur.archlinux.org/clash-verge-rev-bin.git`
- AUR commit: `65d41470c23fa8576308304024b25625c41f3095` (2026-07-20, `2.5.2`)
- Reviewed tree: `c4690cda6278f1216c8c405449043291781d2e96`
- Upstream release tag: `v2.5.2`, resolved during review to `28f2efc504059b1dc75c793618b775c8e1b2a5f1`
- Upstream version / recipe license: `2.5.2` / `GPL3`
- Fixed artifact: versioned GitHub release Debian package; SHA-512 is recorded in `PKGBUILD` and `.SRCINFO`.
- The local clone's commit object and full object graph passed `git cat-file` and `git fsck --full --no-dangling` checks.

## Version reconciliation

- Inventory observation: `2.5.2-1` (snapshot date 2026-07-31).
- AUR snapshot: `2.5.2-1`.
- Fixed recipe: `2.5.2-1`; `vercmp` result against observed version is `0` (**same**).

## Local changes from the AUR recipe

- Restricted `arch` and source/checksum arrays to x86_64.
- Removed unused ARM artifacts while preserving the package name, conflicts, dependencies, install hook, and fixed release checksum.
- Quoted package paths; no source is a VCS checkout or ordinary remote branch.

## Remaining risks

- The proprietary release hosting path is versioned but the artifact was not independently rebuilt from source in this review.
- The inherited `.install` hook invokes the packaged service uninstaller during removal; uninstall behavior was syntax-checked but not exercised.
- The Debian payload filename/compression convention was not tested because the artifact was intentionally not downloaded.

## Expected output

- Package: `clash-verge-rev-bin 2.5.2-1 (x86_64)`
- Default artifact: `clash-verge-rev-bin-2.5.2-1-x86_64.pkg.tar.zst`
- Expected payload: Clash Verge Rev application files from the pinned Debian release.
