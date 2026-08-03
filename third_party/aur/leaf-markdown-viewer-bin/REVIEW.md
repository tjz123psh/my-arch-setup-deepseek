# Review: leaf-markdown-viewer-bin

## Status

- Decision: **reviewed and pinned** for x86_64; fixed recipe upgrades the observed package.
- Small documentation files were independently fetched and hashed; the release executable was not downloaded or run.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/leaf-markdown-viewer-bin`
- AUR origin: `https://aur.archlinux.org/leaf-markdown-viewer-bin.git`
- AUR commit: `918f4a87d0869467c533864aa487793bddcb9014` (2026-07-27, release `1.26.2`)
- Reviewed tree: `818daf01f70d6140afe9676ec3b4ecef3a0740a3`
- Upstream tag `1.26.2` is annotated as `ad91d8f735e90fd1d5a4012a37cecbc1f7cf12b2` and peels to commit `0c037dba12e2396f798878654b11b668f3b07929`.
- Upstream version / license: `1.26.2` / MIT.
- Release binary SHA-256: `246fef2b941faa3d47e925700e978f34df0832c32b855a586d32c9441c06eebb`.
- All six documentation/license URLs use the full upstream commit and have independently verified SHA-256 values in `PKGBUILD`.
- The AUR clone's full commit/object checks passed.

## Version reconciliation

- Inventory observation: `1.26.1-1`.
- AUR snapshot and fixed recipe: `1.26.2-1`.
- `vercmp` result: `1` (**upgrade**).

## Local changes from the AUR recipe

- Replaced every default-branch documentation source with the release's full commit.
- Replaced every unchecked documentation entry with an actual independently calculated SHA-256.
- Kept only x86_64 and made the release binary name architecture-explicit.
- Preserved the local changelog, installed documentation, license aliases, and generated shell completions.
- Disabled stripping/debug splitting so the checksum-reviewed prebuilt executable yields one deterministic package artifact.

## Remaining risks

- Completion generation executes the checksum-verified prebuilt Leaf binary during `build()`; it was not sandbox/runtime-tested here.
- The executable was not independently reproduced from source.
- Forge-generated release artifacts remain protected by checksum rather than an upstream detached signature.

## Expected output

- Package: `leaf-markdown-viewer-bin 1.26.2-1 (x86_64)`
- Providers: `leaf`, `leaf-markdown-viewer`
- Default artifact: `leaf-markdown-viewer-bin-1.26.2-1-x86_64.pkg.tar.zst`
- Expected payload: Leaf binary, license/docs, and bash/fish/zsh completions.
