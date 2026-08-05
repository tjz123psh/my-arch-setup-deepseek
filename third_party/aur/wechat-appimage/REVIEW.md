# Review: wechat-appimage

## Status

- Decision: **reviewed AUR recipe with automatic upstream download**.
- The previous engineering-era design treated the AppImage as a private
  local-source precondition (moving vendor filename, not a `source`). Under
  the current personal-restore-tool vision the AppImage is a pinned `source`
  with a fixed download URL; `makepkg` downloads and hash-verifies it during
  the build. No manual acquisition step.

## Provenance

- AUR origin: `https://aur.archlinux.org/wechat-appimage.git`
- AUR commit: `79e238580e278174ebc03fa0091d420aa0a8e59d` (2026-07-10, `Auto update ver 4.1.1-4`)
- Reviewed tree: `38f767d246f46e5c57d41c16b7e40c404be06e3f`
- Upstream version / license: `4.1.1` / custom Tencent license.
- The AUR snapshot associated x86_64 object epoch `1783692407` with SHA-256 `457dba02b91b031cdd4412eee074fbbffb9d9d06b1e50fc1822d34870e114990`.
- Pinned download URL (in `source_x86_64`): `https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.AppImage` (verified reachable, HTTP 200).
- Local `LICENSE` and `wechat` launcher retain hashes `4348aee67f0c40bd29ec370fff75e24384907514a76104b43354d395c436f0f2` and `c18843571e9626fddadec48f24389da44a3ee29d7d5439db7b51182d73a15019`.
- The AUR clone's full commit/object checks passed.

## Acquisition (as integrated)

`makepkg` downloads the pinned URL as `WechatLinux-1783692407-x86_64.AppImage`,
verifies the declared SHA-256, and uses it directly. A download or hash
mismatch fails the build; there is no manual source-cache step.

## Version reconciliation

- Inventory observation: `4.1.1-4`.
- AUR snapshot and fixed recipe: `4.1.1-4`.
- `vercmp` result: `0` (**same**).

## Local changes from the AUR recipe

- Restricted architecture to x86_64.
- Pinned the exact Tencent download URL in `source_x86_64` (the moving
  filename is resolved to the pinned URL at review time).
- Omitted the networked update helper because it is not a build input.
- Preserved the reviewed local license and shell-hardened the launcher
  argument/default handling; retained AppImage extraction and desktop
  integration.

## Remaining risks

- The AppImage hash is inherited from the reviewed AUR commit and was not
  independently inspected here.
- The Tencent distribution URL or its availability can change; the installer
  fails the build if the download or hash check fails.
- AppImage extraction executes a proprietary binary during `prepare()`; use an
  isolated build environment (makepkg runs unprivileged).

## Expected output

- Package: `wechat-appimage 4.1.1-4 (x86_64)`
- Provider: `wechat`
- Default artifact: `wechat-appimage-4.1.1-4-x86_64.pkg.tar.zst`
- Expected launcher: `/usr/bin/wechat`.
