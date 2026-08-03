# Review: google-chrome

## Status

- Decision: **reviewed and pinned** for x86_64; fixed recipe upgrades the observed workstation version.
- The large proprietary Debian package was not downloaded or run.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/google-chrome`
- AUR origin: `https://aur.archlinux.org/google-chrome.git`
- AUR commit: `cf617f18280a369fd9dff2849c3161163badf264` (2026-07-30, `upgpkg: google-chrome 151.0.7922.71-1`)
- Reviewed tree: `2c1841815f5528898dd04834532a83d4db6df030`
- Upstream version / license: `151.0.7922.71` / `custom:chrome`.
- Fixed vendor pool artifact SHA-512: `b657e18aef41d0316a7edf4367673282dfe4f142fc1e106eff304ee0dfdbac9319dbbe4468ecbfd461ef074e00c2a35168694b5eafe6971c8b606b39dada6e52`.
- The local EULA content is copied from the reviewed AUR commit with its missing final newline normalized, SHA-512 `aa346ffe6adf3b0402abdf8f0abe6ec72c93238099af3a7c0dde86c6400792f4893a93325178746854564ba39ea5a3a6824ecf87277bf1a47c3c4e0a5853c474`; the launcher was shell-hardened and is pinned by SHA-512 `f60e9424ba1a3cb6d84c994606a1ee8518c10312f2d8ccdfc58940ab9698a887993aeaf07a249222dff9dc9a10cff8e1b479f7967091b37736783569eacf9446`.
- The full AUR commit/object checks passed.

## Version reconciliation

- Inventory observation: `150.0.7871.181-1`.
- AUR snapshot and fixed recipe: `151.0.7922.71-1`.
- `vercmp` result: `1` (**upgrade**).

## Local changes from the AUR recipe

- Removed the ARM artifact and checksum; `arch` is x86_64 only.
- Kept the version-qualified vendor pool URL and all complete checksums.
- Removed an update-discovery command from comments so the recipe itself contains no ambiguous acquisition instructions.
- Preserved launcher flag splitting while quoting its configuration path, and preserved the EULA, install note, icon placement, and desktop-entry edits.

## Remaining risks

- Chrome is proprietary; the binary and embedded Widevine component were not rebuilt or inspected.
- Google does not provide a reproducible source-to-binary path for this artifact in the recipe.
- Debian archive layout and packaging hooks were syntax/static checked only.

## Expected output

- Package: `google-chrome 151.0.7922.71-1 (x86_64)`
- Default artifact: `google-chrome-151.0.7922.71-1-x86_64.pkg.tar.zst`
- Expected executable launcher: `/usr/bin/google-chrome-stable`.
