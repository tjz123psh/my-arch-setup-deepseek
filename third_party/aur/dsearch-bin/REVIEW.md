# Review: dsearch-bin

## Status

- Decision: **reviewed and pinned** for x86_64; version is unchanged from the observed workstation package.
- The release binary was not downloaded or executed.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/dsearch-bin`
- AUR origin: `https://aur.archlinux.org/dsearch-bin.git`
- AUR commit: `b9d824a7cccefe7939179028b1cb876556668e70` (2026-06-29, `0.3.2`)
- Reviewed tree: `ffa746c988805d734dad0698a6a7d9798e3d3108`
- Upstream tag `v0.3.2` peels to commit `1269b4688cc94cbd271e1cbbf19a6e7caa2293de`.
- Upstream version / license: `0.3.2` / MIT.
- Release binary SHA-256: `2c9e433f82948c77488543d25955a170835755a39d29ecc2240a8e4d74be63fd`.
- License and README use raw URLs at the full upstream commit; their hashes were independently re-fetched and matched the AUR values.
- The AUR clone's full commit/object checks passed.

## Version reconciliation

- Inventory observation: `0.3.2-1`.
- AUR snapshot and fixed recipe: `0.3.2-1`.
- `vercmp` result: `0` (**same**).

## Local changes from the AUR recipe

- Removed the ARM source and array-index architecture mapping.
- Replaced tag-addressed documentation URLs with full-commit URLs while retaining complete SHA-256 checks.
- Preserved and hashed the local `dsearch.service` unit.
- Disabled stripping/debug splitting so the checksum-reviewed prebuilt executable yields one deterministic package artifact.
- No VCS checkout or package-stage network action remains.

## Remaining risks

- The upstream binary is prebuilt and was not independently reproduced or inspected.
- `dsearch.service` starts a long-lived user service with restart-on-failure; enabling and runtime behavior were not tested.
- The release URL is tag/version addressed; checksum mismatch intentionally blocks any forge-side replacement.

## Expected output

- Package: `dsearch-bin 0.3.2-1 (x86_64)`
- Default artifact: `dsearch-bin-0.3.2-1-x86_64.pkg.tar.zst`
- Expected payload: `/usr/bin/dsearch`, user unit, license, and README.
