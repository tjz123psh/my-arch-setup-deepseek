# Review: linuxqq-nt-bwrap

## Status

- Decision: **reviewed AUR recipe with pinned upstream deb**.
- Replaces the former `linuxqq-appimage` recipe: the operator's machine now runs
  the bwrap package (the AppImage + fuse2 stack was dropped 2026-09-16).

## Provenance

- AUR origin: `https://aur.archlinux.org/linuxqq-nt-bwrap.git`
- AUR commit: `e46ddeb2001f83d3add4b0a8be49129791cb8406`
- Upstream version / license: `3.2.33_52892-1` / custom Tencent license
  (installed by the package from the deb).
- Matches the installed package on the reference machine:
  `linuxqq-nt-bwrap 3.2.33_52892-1`.
- Pinned payload (`source_x86_64`):
  `https://qqdl.gtimg.cn/qqfile/QQNT/9.9.35/beta/1763096b/linuxqq_3.2.33-52892_amd64.deb`
  with SHA-256 `502a978f2d03af9f21acefc461f9d1d1fe09b65bad620bbfcdb589a79ac53b7e`
  (declared in the PKGBUILD; makepkg downloads and verifies it, offline from
  `.aur-sources/` when the cache is present).

## Local changes from the AUR recipe

- `arch` restricted to `x86_64` (this project's target machine).
- No other change: extraction, install script, desktop/icon edits and the
  bubblewrap launcher are the reviewed AUR content.

## AUR->AUR dependency (offline bootstrap)

- `depends=(... 'snapd-xdg-open-git' ...)` is an AUR package. `makepkg -s`
  cannot resolve an AUR dependency offline, so 06-aur bootstraps
  `third_party/aur/snapd-xdg-open-git` before the main batch (the same
  mechanism already used for `vmware-keymaps` -> `vmware-workstation`).
  Online mode resolves it automatically through paru.

## Expected output

- Package: `linuxqq-nt-bwrap 3.2.33_52892-1 (x86_64)`
- Launcher: `/usr/bin/linuxqq`
