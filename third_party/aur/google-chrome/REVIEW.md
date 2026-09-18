# Review: google-chrome

> **2026-09-19 复核**：本文顶部的 AUR commit / 版本号为首次审查时的快照，可能落后于当前 pin；
> 权威值以同目录 `AUR_COMMIT`、`PKGBUILD` 与文末 Update 段为准。

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

- Package: `google-chrome 153.0.8010.47-1 (x86_64)`
- Default artifact: `google-chrome-153.0.8010.47-1-x86_64.pkg.tar.zst`
- Expected executable launcher: `/usr/bin/google-chrome-stable`.

## Update 2026-09-17: 151.0.7922.71 -> 153.0.8010.47 (AUR commit 18cc0c7e2711d5eb10e708ccaac8d91dd1772246)

- x86_64-only local form kept; ARM artifact/checksum still removed; the AUR update-discovery comment
  block stays dropped.
- Local google-chrome-stable.sh (quoted XDG_CONFIG_HOME path + shellcheck directive) and the
  newline-normalized eula_text.html are unchanged, so their local sha512 values stay: aa346ffe... (EULA)
  and f60e9424... (launcher). google-chrome.install is byte-identical to AUR.
- Vendor artifact re-downloaded (141,932,640 B) and hashed: sha512
  cd70639f4737c043a9eb2c349dd2d447b1929b78eba972fa997c4120e7730018f62aa3ddcda1e5f0fe06b76c786076f281b4a5b50e96a62dfe4cf4aa35b70238
  (matches the AUR recipe value).
