# Review: paru

## Status

- Decision: **reviewed fixed-source bootstrap with an explicit offline-vendor acquisition precondition**.
- The previous local draft repackaged an archlinuxcn binary. That crossed the declared Paru bootstrap trust boundary and was rejected before installer integration.
- A build cannot start until the exact deterministic Cargo vendor archive is present and hash-verified.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/paru`
- AUR origin: `https://aur.archlinux.org/paru.git`
- AUR commit: `329be2113c590046cb29858c23d9b96a8d7bd586` (2025-12-12, `Add support for libalpm16`)
- Reviewed AUR tree: `ca7dce10af710aeaf3850b708c8d44f16fd9e89a`
- Upstream release: `v2.1.0`; tag object `300f76a4f87239ebc5b36b9e0a5325e380f755a1` resolves to commit `730cd1674f2ac75f0ff8b8c17a81634c3a689c87`.
- Upstream source archive SHA-256: `eea4dbb524db765d5316f540f9ee670c0bf81aae4827b5417eebb4c9b5651727`.
- Upstream version / license: `2.1.0` / GPL-3.0-or-later.
- Upstream `Cargo.lock` SHA-256: `455f7103a3a6fb757fe970922e4d3d06ab0cb26b4f7ca5846f7daf2e63528532`; it resolves `alpm 4.0.3` and is rejected for libalpm 16.
- Reviewed libalpm-16 lock override: `Cargo.lock.libalpm16`, SHA-256 `4231e3bfa8172ad2c0c79322921fd974be97f1dec00bf970e9892ada9a98b323`. It changes only `alpm 4.0.3 -> 4.0.4`, `alpm-sys 4.0.3 -> 4.0.5`, their checksums and Cargo's resulting Windows-target edge. `alpm 4.0.4` explicitly configures both libalpm 15 and 16.
- Required local vendor filename: `paru-vendor-2.1.0.tar.zst`.
- Required deterministic libalpm-16 vendor archive SHA-256: `08de76ee34cca3c04b5dc4fae14f5f9b0269c5f2b4e3a19b435c984b99cdb587` (51,178,317 bytes in the review run).
- The AUR clone's full commit/object checks passed.

## Offline vendor acquisition

The AUR source recipe used `cargo update`/`cargo fetch` during `prepare()`. The fixed recipe forbids that build-time network path. After the independent AUR confirmation, the source-acquisition stage must instead:

1. download and verify the fixed upstream source archive;
2. verify the source archive, then replace its incompatible upstream lock with the version-controlled libalpm-16 lock override and verify that exact hash;
3. run `cargo vendor --locked --versioned-dirs` against that fixed lock as the ordinary user in a private temporary directory;
4. archive the resulting `vendor/` tree with sorted paths, epoch-zero timestamps, numeric owner/group zero, POSIX format with atime/ctime PAX keys removed, then compress with single-threaded Zstandard level 10; and
5. accept the result only when it matches the fixed vendor archive SHA-256 above.

The review generated the updated archive twice independently from the same vendor tree; both 51,178,317-byte outputs matched byte-for-byte and produced the recorded hash. A different Cargo/vendor result fails closed and requires renewed review; it is not silently accepted. The generated archive is a private source-cache input, not committed to Git.

## Version reconciliation

- Inventory observation: `2.1.0-5` from archlinuxcn.
- Reviewed upstream/AUR package version: `2.1.0`.
- Fixed local bootstrap package: `2.1.0-5`; `vercmp` against the observation is `0` (**same**).
- The local `pkgrel=5` preserves the observed version boundary while identifying the reviewed local packaging revision; it does not claim to reproduce archlinuxcn's binary payload.

## Local changes from the AUR recipe

- Restricted architecture to x86_64.
- Retained the fixed upstream source archive, dependency metadata, configuration backup, manual pages, completions and locale payload.
- Removed `cargo update` and `cargo fetch` from `prepare()`.
- Replaces the upstream libalpm-15 lock with the reviewed libalpm-16 lock, requires its checksum-gated offline Cargo vendor archive, and writes a local `.cargo/config.toml` that replaces crates.io with that extracted directory.
- Builds with `cargo --frozen --offline` in the unprivileged isolated AUR build path.
- The earlier signed archlinuxcn binary-repack draft is not an executable target.

## Remaining risks

- The 51 MiB vendor archive is generated after approval rather than stored in the repository. Lock/vendor/toolchain drift intentionally blocks on fixed hashes.
- A current-host unprivileged Bubblewrap build with networking unshared, a private empty HOME, selective read-only system/toolchain mounts and the fixed offline sources completed successfully. The artifact linked `libalpm.so.16`, its `.PKGINFO`/file list matched the recipe, and the extracted binary returned `paru v2.1.0 - libalpm v16.0.1` inside the same isolation boundary.
- That current-host build emitted a non-fatal fakeroot `payload not recognized` warning plus makepkg's generic `$srcdir` reference warning. Exit status, package metadata and runtime checks passed, but the warnings remain evidence to reproduce in the clean VM rather than being called absent.
- Clean-VM installation, ordinary AUR use and removal remain for the snapshot-backed acceptance gate.
- The upstream release has no detached publisher signature in this recipe; integrity is pinned by the reviewed source, lock and vendor hashes, not claimed publisher-signature identity.

## Expected output

- Package: `paru 2.1.0-5 (x86_64)`
- Default artifact: `paru-2.1.0-5-x86_64.pkg.tar.zst`
- Expected payload: `/usr/bin/paru`, `/etc/paru.conf`, manual pages, completions and locale catalogs.
