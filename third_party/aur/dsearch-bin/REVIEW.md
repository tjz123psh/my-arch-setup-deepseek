# Review: dsearch-bin

> **2026-09-19 复核**：本文顶部的 AUR commit / 版本号为首次审查时的快照，可能落后于当前 pin；
> 权威值以同目录 `AUR_COMMIT`、`PKGBUILD` 与文末 Update 段为准。

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

- Package: `dsearch-bin 1.6.0-1 (x86_64)`
- Default artifact: `dsearch-bin-1.6.0-1-x86_64.pkg.tar.zst`
- Expected payload: `/usr/bin/dsearch`, user unit, license, and README.

## Update 2026-09-17: 0.3.2 -> 1.6.0 (AUR commit 97ab391c1cd004482c4cd5d53f5453386e9d8416)

- Upstream tag v1.6.0 peels to 984f86e644a93d2a366d960e3c56233260a501de.
- Local conventions preserved: x86_64 only, documentation URLs pinned to the full commit,
  local dsearch.service kept, !strip !debug kept.
- Hashes re-derived from real bytes:
  LICENSE @984f86e = 4cee96286c5b7da9763a4694868bb1853b33bb1558821e0c609ad2eabd426bfa;
  README.md @984f86e = b99cd31bc10e7b07e90907c70c92a42427f240ee7ad3d9c5b57acd4938077cb2;
  dsearch-linux-amd64.gz (7,708,935 B) = e7ebc1d3032ef89006ab8a43746bf503f387decd018ff3977bb1550cb2c5b36a;
  dsearch.service unchanged (6908e1e9...).
- The AUR 1.6.0 recipe dropped its own doc-URL commit pin; the local pin is retained on purpose.
