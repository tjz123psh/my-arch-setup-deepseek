# VM batch 2026-08-03b — local-fixed AUR recipe validation (complete)

This document records the third disposable-VM validation batch, executed on
2026-08-03 in this repository (my-arch-setup-deepseek). It validates the three
local-fixed AUR recipes (`linuxqq-appimage`, `wechat-appimage`, `paru`) whose
private source caches are now acquired, using the same low-level
`aur-build.py` / `aur-install.py` pipeline as batch 2026-08-03a.

> **Status: COMPLETE.** All three local-fixed recipes passed the real
> clean-chroot build, idempotent rerun and install paths in the disposable VM.
> The batch also surfaced and fixed a recipe-manifest hash inconsistency in the
> host repository (commit `915030e`). See the execution log below.

## Scope and boundary

- Recipes validated: `linuxqq-appimage`, `wechat-appimage` (both
  `executes_source=true`) and `paru` (role `paru-bootstrap`,
  `executes_source=false`, cargo-vendor source).
- Source acquisition: all three sources were acquired on the host with
  `aur-source-acquire.py` and verified against the reviewed
  `manifests/aur-source-acquisition.tsv` hashes (commit `fb3b60b`):
  - `linuxqq-appimage/Linuxqq-3.2.32_20260730-x86_64.AppImage` =
    `719fa8307f…` (266,814,428 bytes)
  - `paru/paru-vendor-2.1.0.tar.zst` = `18e89a23…` (51,178,321 bytes,
    renewed deterministic cargo 1.97.0 output, see
    `third_party/aur/paru/REVIEW.md` Renewed 2026-08-03)
  - `wechat-appimage/WechatLinux-1783692407-x86_64.AppImage` =
    `457dba02…` (288,864,760 bytes)
- Module status: same as batch a — **package-specific** evidence only; no
  module promotion (`daily-apps` / `repository-tools` remain planning).
- Boundary reason: identical to batch a (`full-orchestrator.py` fail-closes
  non-available modules; the recipe-level pipeline is validated directly).

## Environment

- Host session: `qemu:///session`, SLIRP user networking, port `22222`.
- Base image: `vm-validation-20260801/disks/baseline-handoff.qcow2`
  (read-only, `440`, validated 2026-08-02).
- Overlay: `vm-validation-20260803/disks/batch3-local-fixed.qcow2`
  (64 GiB sparse), derived with
  `qemu-img create -f qcow2 -F qcow2 -b base`.
- Domain: `myarch-batch3-local` (4 GiB, 4 vCPU, host-passthrough, UEFI,
  virtio disk `cache=none,discard=unmap`, SLIRP `hostfwd 22222:22`; no audio
  or RNG devices — neither needed for this batch).
- SSH: reused the 2026-08-01 ephemeral key and known_hosts from
  `vm-validation-20260801/ssh/`.
- Tree injected: the first injection was a fresh `bsdtar` pax archive of the
  repository HEAD (`440` members, SHA-256
  `dbaa823fe9c9dabd59ebcb7aed4fd146e63d1d3de6fd39dcfdf3f4ded0393dde`),
  excluding `.git` and the root `仓库地址` file, extracted to
  `~/my-arch-setup` in the guest. After the host fix (commit `915030e`), the
  tree was re-injected as a fresh `bsdtar` pax archive of the fixed HEAD
  (`442` members, SHA-256 `b3ddd145…`).
- Private sources injected: `scp -r` from the host
  `~/.cache/my-archlinux-setup/aur-sources/` → guest home. **Initial copy
  landed in `~/aur-sources/` — this is the bug below.**
- Guest tooling: `pacman -Syu --needed devtools base-devel` installed
  (`makepkg`, `mkarchroot`, `makechrootpkg`, `arch-nspawn` all present);
  `gsudo` / `fuzzel-askpass` deployed to `~/scripts/desktop/` per mapping
  rows 112/113 and 190/191.

## Execution log

### 1. Plan readiness check

`aur-build.py --packages linuxqq-appimage,paru,wechat-appimage --plan --json`
reports: chroot `absent`, all four tool binaries `available`, three package
checks `verified` for the recipe tree, but the private source cache check for
`wechat-appimage` reports `WechatLinux-…AppImage` **`missing`**, so the plan
is `blocked`.

### 2. First build attempt (failed before building)

`aur-build.py --packages linuxqq-appimage,paru,wechat-appimage --build
--post-official --confirm-aur --confirm-system-changes --json` exited `1`
with the single line `aur-build: build plan is not ready` — the fail-closed
plan gate fired, i.e. no build started at all.

### 3. Root cause — source cache path mismatch in the guest

- The `aur-source-acquire.py` cache contract is
  `~/.cache/my-archlinux-setup/aur-sources/<package>/…` (host and guest).
- The `scp -r` of the host cache into the guest home created
  `/home/pang/aur-sources/…` instead of
  `/home/pang/.cache/my-archlinux-setup/aur-sources/…`.
- The guest `~/.cache/my-archlinux-setup/aur-sources/` is therefore empty,
  so the plan gate saw `wechat-appimage`'s AppImage as `missing` and refused
  to build (exactly the intended fail-closed behavior — the check worked;
  the deployment path was wrong).

### 4. Fix — source cache path mismatch in the guest (executed)

In the guest, the private sources were moved from `~/aur-sources/` to the
contract path `~/.cache/my-archlinux-setup/aur-sources/`, and all three files
were re-verified with `sha256sum` against the manifest hashes (all matched:
linuxqq `719fa8307f…`, paru-vendor `18e89a23…`, wechat `457dba02…`).

### 5. Host repository fix surfaced by the plan gate (commit `915030e`)

After the guest cache fix, the plan gate still failed for `paru` with two
inconsistencies that traced back to the host repository (commit `fb3b60b`
had updated the vendored-source hash and the tree hash but missed two pins):

- `paru: recipe tree SHA-256 differs from the reviewed manifest` — the
  `manifests/aur-recipes.tsv` pin was stale.
- `paru: local source checksum mismatch: paru-vendor-2.1.0.tar.zst` — the
  `PKGBUILD`/`.SRCINFO` sha256sums entry was the pre-renewal hash.

Fix applied and verified on the host (`aur-build.py --plan` reports all three
`ready`; all 39 `tests/*.sh`, `docs-check.py` and static checks pass):
`third_party/aur/paru/PKGBUILD` + `.SRCINFO` sha256sums → `18e89a23…`,
`REVIEW.md` renewed-hash description, `manifests/aur-recipes.tsv` paru
recipe-tree-sha256 → `44df2230…`, `manifests/stage-inputs.tsv`
`aur-recipe-policy` → `05a5e926…` and `aur-tree:paru` → `44df2230…`.

### 6. Re-injection and validation run (executed)

A fresh `bsdtar` pax archive of the fixed host HEAD (SHA-256
`b3ddd145…`, 442 members) was injected into the guest, and the plan was
`ready` again. The full validation run then completed:

1. **First build pass** (`aur-build.py --packages linuxqq-appimage,paru,wechat-appimage
   --build --post-official --confirm-aur --confirm-system-changes --json`,
   clean-chroot init with base-devel + rust, then three clean-chroot builds) —
   all three `passed`, exit `0`:
   - `linuxqq-appimage` `3.2.32_20260730-1` artifact SHA-256 `f430a7929874…`
   - `paru` `2.1.0-5` artifact SHA-256 `5be4d55533d4…`
   - `wechat-appimage` `4.1.1-4` artifact SHA-256 `247050448457…`
2. **Idempotent rerun** — same command; the rerun log records
   `skip: <pkg>: verified artifact already exists` for all three, artifact
   SHA-256s identical to the first pass and artifact mtimes unchanged.
3. **Install pass** (`aur-install.py --packages linuxqq-appimage,paru,wechat-appimage
   --install --confirm-aur --confirm-system-changes --json`) — exit `0`; the
   independent `pacman -Q` check confirms `linuxqq-appimage 3.2.32_20260730-1`,
   `paru 2.1.0-5` and `wechat-appimage 4.1.1-4` installed, with a working
   `/usr/bin/paru` binary (`paru v2.1.0 - libalpm v16.0.1`).
4. **Evidence extraction, ACPI shutdown, `virsh undefine --nvram`, offline
   `qemu-img check` (no errors), overlay deletion.**

### 7. Follow-up documentation (executed)

- `manifests/production-module-readiness.tsv` evidence rows updated:
  `daily-apps` now records all seven recipes passing across batches
  2026-08-03 / 2026-08-03b; `repository-tools` records the `paru-bootstrap`
  recipe passing. Both modules remain `planning` — package-specific evidence
  only, no module promotion.
- `docs/implementation-status.md` Fixed AUR pipeline row and
  remaining-gates item 2 updated to reflect all twelve recipes validated.

## Evidence (as of this writing)

- Host private source cache: `~/.cache/my-archlinux-setup/aur-sources/`
  (three files, all hashes match the manifest).
- VM evidence extracted to
  `~/.local/state/my-archlinux-setup/vm-lab/20260803/`:
  - `aur-installed-local.json` (this batch's three packages with artifact and
    recipe-tree SHA-256, distinct from batch a's `aur-installed.json`),
  - `aur-logs/aur-build-20260803T160750Z-1283.log` (first build pass,
    including clean-chroot init) and
    `aur-logs/aur-build-20260803T161445Z-18322.log` (idempotent rerun,
    recording `skip: verified artifact already exists` for all three),
  - `aur-install-private-local.log` (install pass).
- Artifact cache lived inside the disposable overlay; the overlay was deleted
  by design after evidence extraction. Package `pkg.tar.zst` SHA-256s are
  retained in `aur-installed-local.json`.
- VM `myarch-batch3-local` was shut down via ACPI, undefined with `--nvram`,
  passed offline `qemu-img check` (no errors), and the overlay
  `batch3-local-fixed.qcow2` was deleted.
