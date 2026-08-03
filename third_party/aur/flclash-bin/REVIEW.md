# Review: flclash-bin

## Status

- Decision: **reviewed and pinned** for x86_64; no version regression.
- Large release payloads were not downloaded or executed.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/flclash-bin`
- AUR origin: `https://aur.archlinux.org/flclash-bin.git`
- AUR commit: `97f93d636ed82ec26affdf4635f33d63ea5b61be` (2026-07-13, `update to 0.8.94`)
- Reviewed tree: `23d853123c71fb010ed16301762fa73b07c7bcf6`
- Upstream release tag `v0.8.94` resolves to `7e7f1f89f363c31bbb7aa5af3f34a8b5c32a7a19`.
- Upstream version / license: `0.8.94` / `GPL-3.0-only`.
- Debian release SHA-256: `e3d7ad04d6918cbe40d69a146c214ab3674cfb8ce4494d6ab5ae5d8105fea643`.
- Compatibility plug-in text is pinned to Gist revision `c18484d78449d0e3b376a6e2a49852486305ff1e`, SHA-256 `367033ae3a8bd11f37e398f38c5de0acd8985b62b93b966eb43648fba6bd9094`.
- The full AUR commit/object checks passed.

## Version reconciliation

- Inventory observation: `0.8.94-1`.
- AUR snapshot and fixed recipe: `0.8.94-1`.
- `vercmp` result: `0` (**same**).

## Local changes from the AUR recipe

- Kept only x86_64 source/checksum data and removed dead ARM comments.
- Preserved the fixed Gist revision instead of introducing a moving raw URL.
- Preserved the local launcher logic, normalized its missing final newline, pinned the resulting SHA-256 `efe4503308a1e4e44b892065b6fb8f582bd2f7d01e3f0232e4d86539101ebbb5`, and made path handling explicit.
- Disabled stripping/debug splitting for deterministic handling of the two prebuilt binary artifacts.
- No source-control checkout or network-capable lifecycle action is present.

## Remaining risks

- The decoded QuickJS bridge is a separately maintained binary blob delivered as Base64 rather than an artifact built with FlClash.
- Neither binary artifact was independently reproduced or runtime-tested.
- Debian payload layout and desktop-entry edits were only reviewed statically.

## Expected output

- Package: `flclash-bin 0.8.94-1 (x86_64)`
- Provider: `flclash=0.8.94`
- Default artifact: `flclash-bin-0.8.94-1-x86_64.pkg.tar.zst`
