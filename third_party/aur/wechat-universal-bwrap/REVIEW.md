# Review: wechat-universal-bwrap

## Status

- Decision: **reviewed AUR recipe with pinned upstream deb**.
- Replaces the former `wechat-appimage` recipe: the operator's machine now runs
  the bwrap package (AppImage + fuse2 dropped 2026-09-16).

## Provenance

- AUR origin: `https://aur.archlinux.org/wechat-universal-bwrap.git`
- AUR commit: `cca34f3887618542a3e9f4cd519099eb428204e7`
- Upstream version / license: `4.1.13.9-1` / `LicenseRef-wechat-license`
  (bundled `wechat-license` file).
- Matches the installed package on the reference machine:
  `wechat-universal-bwrap 4.1.13.9-1`.
- Pinned payload (`source_x86_64`, makepkg renames it to the recipe's deb name):
  `https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.deb` with
  SHA-256 `096865e050ba0d3c1a23887227e2400bf343037b1d7d658c84c88ff26bfdc17f`
  (declared in the PKGBUILD).

## Local changes from the AUR recipe

- `arch` restricted to `x86_64` (this project's target machine).
- Removed the two AUR-side release-scraping helpers
  (`fetch_tencent_wechat_release.sh`, `fetch_uos_wechat_release.py`): they are
  not `source` entries and are only used to update the recipe by hand; the
  pinned deb URL + SHA-256 replace them for this project.
- Kept: `wechat-universal.sh` launcher, desktop entry, install script,
  `libuosdevicea` compatibility shim and the license file.

## Expected output

- Package: `wechat-universal-bwrap 4.1.13.9-1 (x86_64)`
- Launcher: `/usr/bin/wechat-universal`
