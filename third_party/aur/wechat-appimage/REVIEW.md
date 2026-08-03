# Review: wechat-appimage

## Status

- Decision: **reviewed with an explicit local-source precondition**; version matches the inventory and build phases do not acquire data.
- The required AppImage is intentionally not committed and was not downloaded or executed.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/wechat-appimage`
- AUR origin: `https://aur.archlinux.org/wechat-appimage.git`
- AUR commit: `79e238580e278174ebc03fa0091d420aa0a8e59d` (2026-07-10, `Auto update ver 4.1.1-4`)
- Reviewed tree: `38f767d246f46e5c57d41c16b7e40c404be06e3f`
- Upstream version / license: `4.1.1` / custom Tencent license.
- The AUR snapshot associated x86_64 object epoch `1783692407` with SHA-256 `457dba02b91b031cdd4412eee074fbbffb9d9d06b1e50fc1822d34870e114990`.
- Required local filename: `WechatLinux-1783692407-x86_64.AppImage`.
- Local `LICENSE` and `wechat` launcher retain hashes `4348aee67f0c40bd29ec370fff75e24384907514a76104b43354d395c436f0f2` and `c18843571e9626fddadec48f24389da44a3ee29d7d5439db7b51182d73a15019`.
- The AUR clone's full commit/object checks passed.

## Acquisition precondition

Tencent publishes the x86_64 AppImage under a moving vendor filename, so that URL is deliberately not a `source`. Outside `makepkg`, obtain the AUR-attributed bytes from the vendor distribution channel, save them under the required epoch-qualified local filename, and verify the SHA-256 above. The reviewed acquisition stage stores only the verified file at `${XDG_CACHE_HOME:-$HOME/.cache}/my-archlinux-setup/aur-sources/wechat-appimage/WechatLinux-1783692407-x86_64.AppImage` with private permissions. The build stage copies it into a private recipe workspace, where `makepkg` checks the declared hash again. Do not place the large AppImage in the version-controlled recipe directory.

## Version reconciliation

- Inventory observation: `4.1.1-4`.
- AUR snapshot and fixed recipe: `4.1.1-4`.
- `vercmp` result: `0` (**same**).

## Local changes from the AUR recipe

- Restricted architecture to x86_64.
- Replaced the moving remote AppImage source with a fixed local source acquisition precondition.
- Omitted the networked update helper because it is not a build input.
- Preserved the reviewed local license and shell-hardened the launcher argument/default handling; retained offline AppImage extraction and desktop integration.

## Remaining risks

- The AppImage hash is inherited from the reviewed AUR commit and was not independently downloaded or inspected here.
- Acquisition availability depends on Tencent retaining or serving the matching bytes outside the recipe.
- AppImage extraction executes a proprietary binary during `prepare()`; use an isolated build environment.

## Expected output

- Package: `wechat-appimage 4.1.1-4 (x86_64)`
- Provider: `wechat`
- Default artifact: `wechat-appimage-4.1.1-4-x86_64.pkg.tar.zst`
- Expected launcher: `/usr/bin/wechat`.
