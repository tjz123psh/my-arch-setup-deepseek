# Review: linuxqq-appimage

## Status

- Decision: **reviewed AUR recipe with automatic upstream download**.
- The previous engineering-era design required the AppImage to be supplied
  from a private source cache before building. Under the current
  personal-restore-tool vision, the AppImage is a regular pinned `source`:
  `makepkg` downloads it from the Tencent distribution URL during the build
  and verifies its declared SHA-256. No manual acquisition step.

## Provenance

- AUR origin: `https://aur.archlinux.org/linuxqq-appimage.git`
- AUR commit: `6c9bffa4ef5fb91b14d69e97b19ffee968f58f61` (2026-07-30, `3.2.32-2026-07-30`)
- Reviewed tree: `0d62c227fac03e7bbf8514f0b3db9341a4d3df9c`
- Upstream version / license: `3.2.32_20260730` / custom Tencent license extracted from the AppImage.
- Pinned download URL (in `source_x86_64`): `https://qqdl.gtimg.cn/qqfile/QQNT/9.9.33/release/c97651b2/QQ_3.2.32_260730_x86_64_01.AppImage` (verified reachable, HTTP 206).
- Required SHA-256: `719fa8307f569fcfa99f57f321b5c1e2f7bc8450b24bbfcb55fbc46a70b8f07e`.
- The AUR clone's full commit/object checks passed.

## Acquisition (as integrated)

`makepkg` downloads the pinned URL as `Linuxqq-3.2.32_20260730-x86_64.AppImage`,
verifies the declared SHA-256, and uses it directly. A download or hash
mismatch fails the build (standard makepkg behavior); there is no manual
source-cache step.

## Version reconciliation

- Inventory observation: `3.2.31_20260720-1`.
- AUR snapshot and fixed recipe: `3.2.32_20260730-1`.
- `vercmp` result: `1` (**upgrade**).

## Local changes from the AUR recipe

- Restricted architecture to x86_64.
- Pinned the exact Tencent download URL in `source_x86_64` (the AUR recipe's
  own downloader was removed; the URL is now a plain pinned source).
- Removed network/update helper files and their no-longer-needed build
  dependencies.
- Preserved extraction, desktop/icon edits, executable symlink, and license
  installation.

## Remaining risks

- The proprietary AppImage hash is inherited from the reviewed AUR commit; the
  binary itself is not independently inspectable.
- The Tencent distribution URL or its availability can change; the installer
  fails the build if the download or hash check fails.
- AppImage extraction executes a prebuilt artifact during `prepare()`; use an
  isolated build environment (makepkg runs unprivileged).

## Expected output

- Package: `linuxqq-appimage 3.2.32_20260730-1 (x86_64)`
- Default artifact: `linuxqq-appimage-3.2.32_20260730-1-x86_64.pkg.tar.zst`
- Expected launcher: `/usr/bin/linuxqq`.
