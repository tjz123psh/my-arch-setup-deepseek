# Review: obsidian-bin

> **2026-09-19 复核**：本文顶部的 AUR commit / 版本号为首次审查时的快照，可能落后于当前 pin；
> 权威值以同目录 `AUR_COMMIT`、`PKGBUILD` 与文末 Update 段为准。

## Status

- Decision: **reviewed from the current `obsidian` AUR pkgbase at the observed 1.12.7 version**.
- An earlier local draft incorrectly reconstructed 1.12.7 from the stale standalone `obsidian-bin` pkgbase commit at 1.8.10. Independent review identified the wrong pkgbase, missing launcher behavior and stale install hook; that draft was rejected before installer integration.
- The 85,762,386-byte Debian payload has not yet been downloaded or executed; extraction, AppArmor lifecycle and runtime validation remain in the isolated VM gate.

## Provenance

- Current AUR pkgbase: `obsidian`, origin `https://aur.archlinux.org/obsidian.git`.
- Reviewed AUR commit: `f5fc32c5df9b3caae1c719f78992277ab8dab1f0` (2026-03-25, `Update`).
- AUR package: `obsidian-bin 1.12.7-1`; the other split output, `obsidian-appimage`, is deliberately excluded.
- Fixed upstream tag: `v1.12.7`, commit `8173c5931a6f55bede9e542c6bf1b117f47e1fdc`.
- GitHub release ID `298621467`, published `2026-03-23T15:56:19Z`.
- Fixed Debian asset SHA-256: `3644e3ef19bcd23db4d17f7c73311b5245429391a2a48b361da93375f59712b0`.
- Reviewed launcher SHA-256: `a94e20705d4b67501f225d74f4460b746a258e52aa6bc522aed1e26ac42dbef9`.
- Upstream version / license: `1.12.7` / custom proprietary terms plus bundled Electron/Chromium notices.
- The current AUR clone was clean and its commit/object checks passed.

## Version and installed-host reconciliation

- Inventory observation: `obsidian-bin 1.12.7-1`.
- Installed local pacman metadata records `%BASE%=obsidian`, not `obsidian-bin`.
- The installed `/usr/bin/obsidian` is the same 319-byte launcher pattern restored here: it reads non-comment lines from `${XDG_CONFIG_HOME:-$HOME/.config}/obsidian-flags.conf` and passes them to `/opt/Obsidian/obsidian`.
- The fixed recipe is `obsidian-bin 1.12.7-1` under `pkgbase=obsidian`; `vercmp` against the observed package is `0` (**same**).

## Local changes from the reviewed current AUR recipe

- Restricted the split pkgbase to the selected `obsidian-bin` x86_64 package; removed AppImage and aarch64 sources/output.
- Kept the fixed 1.12.7 Debian artifact and current launcher with complete SHA-256 checks.
- Preserved the desktop-command rewrite, Electron/Chromium license installation, package dependencies, provider and conflict.
- Preserved the current `obsidian-bin.install` behavior: sandbox mode adjustment, MIME/desktop cache refresh, and conditional validation/installation/removal of the bundled AppArmor profile. Those root-time hook effects are disclosed package effects and require AUR package authorization; they are not attributed to a user-config stage.
- Generalized Debian payload extraction to require exactly one `data.tar.*` member rather than assuming one compression extension.

## Remaining risks

- The proprietary Debian artifact is checksum-gated but not independently rebuilt and declares no detached publisher signature here.
- The install hook may write `/etc/apparmor.d/obsidian` only when AppArmor is installed and the bundled profile passes `apparmor_parser`; the VM must verify both applicable and not-applicable paths plus removal symmetry.
- Wrapper flags, launch behavior and desktop integration still require installed-package runtime checks in the isolated VM.

## Expected output

- Package base: `obsidian`.
- Package: `obsidian-bin 1.13.7-1 (x86_64)`.
- Default artifact: `obsidian-bin-1.13.7-1-x86_64.pkg.tar.zst`.
- Expected launcher: `/usr/bin/obsidian` as a regular wrapper file, not a direct symlink.
- Conditional package-hook artifact: `/etc/apparmor.d/obsidian` only on compatible AppArmor systems.

## Update 2026-09-17: 1.12.7 -> 1.13.7 (official release v1.13.7)

- Official Debian artifact downloaded (107,021,628 B) and hashed: sha256
  17dc33b49cb3e785ecc27edd2ea0c79e40207798b554fd2886e36ebee7af9ae0 from
  https://github.com/obsidianmd/obsidian-releases/releases/download/v1.13.7/obsidian_1.13.7_amd64.deb
- Local x86_64-only derivation kept (split pkgbase restricted to obsidian-bin, AppImage/aarch64 removed,
  local obsidian-bin launcher + obsidian-bin.install hook kept, single data.tar.* requirement kept).
  The launcher hash a94e2070... is unchanged.
- AUR provenance note: the AUR obsidian-bin git repository is stale at pkgver=1.8.10
  (HEAD e89ed1447d267e208b01482bb78c9f6c3e5d45e7, last commit 2025-06-03) while the AUR RPC advertises
  1.13.7-2 (modified 2026-09-06); no 1.13.7 recipe content is retrievable via cgit, git or snapshot.
  This recipe therefore tracks the official upstream release directly and AUR_COMMIT records the AUR HEAD
  that was actually inspected.

## Fix 2026-09-18: desktop-entry filename is not stable (offline VM round failure)

- Symptom (offline round, VM 2026-09-18): `sed: cannot read .../pkg/obsidian-bin/usr/share/applications/obsidian.desktop:
  No such file or directory` -> `error: an error occurred in package()` -> recipe skipped, 06-aur ended with
  "1 AUR package(s) failed to build" (10/11 built from the cache).
- Cause: `package()` patched one hardcoded filename, but upstream renamed the entry:
  1.12.7 shipped `usr/share/applications/obsidian.desktop`, 1.13.7 ships
  `md.obsidian.Obsidian.desktop` (Exec `/opt/Obsidian/obsidian %U` -> rewritten to `obsidian`).
- Fix: patch EVERY `usr/share/applications/*.desktop` the Debian payload provides and fail closed when
  the payload ships none. Verified: `bash -n PKGBUILD` + `makepkg --printsrcinfo` OK.

