# VM batch 2026-08-03b — local-fixed AUR recipe validation (in progress)

This document records the third disposable-VM validation batch, executed on
2026-08-03 in this repository (my-arch-setup-deepseek). It validates the three
local-fixed AUR recipes (`linuxqq-appimage`, `wechat-appimage`, `paru`) whose
private source caches are now acquired, using the same low-level
`aur-build.py` / `aur-install.py` pipeline as batch 2026-08-03a.

> **Status: IN PROGRESS.** The VM exists and the tree + private sources are
> injected. The first build attempt failed before building with
> `aur-build: build plan is not ready`; the cause is a source-cache path
> mismatch in the guest (see section 5). The fix and the remaining steps are
> listed below.

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
- Tree injected: fresh `bsdtar` pax archive of this repository HEAD
  (`440` members, SHA-256
  `dbaa823fe9c9dabd59ebcb7aed4fd146e63d1d3de6fd39dcfdf3f4ded0393dde`),
  excluding `.git` and the root `仓库地址` file, extracted to
  `~/my-arch-setup` in the guest.
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

### 4. Fix (next step, not yet executed)

In the guest:

```
mkdir -p ~/.cache/my-archlinux-setup/aur-sources
mv ~/aur-sources/* ~/.cache/my-archlinux-setup/aur-sources/
# verify: sha256sum over all three files must match the manifest hashes
```

then rerun the build command from section 2 unchanged.

### 5. Remaining steps after the fix (planned)

1. First build pass of the three recipes (clean-chroot init + build).
2. Idempotent rerun of the same command — artifacts must return identical
   SHA-256 without rebuilding.
3. Install pass: `aur-install.py --packages linuxqq-appimage,paru,wechat-appimage
   --install --confirm-aur --confirm-system-changes` + independent
   `pacman -Q` confirmation. `paru` is built from role `paru-bootstrap`, so
   verify the guest now has a working `paru` binary.
4. Evidence extraction to
   `~/.local/state/my-archlinux-setup/vm-lab/20260803/` (installed-state
   JSON, private build logs), then ACPI shutdown, `virsh undefine --nvram`,
   offline `qemu-img check`, overlay deletion.
5. Update `manifests/production-module-readiness.tsv` evidence rows
   (`daily-apps`, `repository-tools`), `docs/implementation-status.md`
   remaining-gates item 2, and this document's status header.

## Evidence (as of this writing)

- Host private source cache: `~/.cache/my-archlinux-setup/aur-sources/`
  (three files, all hashes match the manifest).
- VM: `myarch-batch3-local` running; overlay
  `batch3-local-fixed.qcow2`; injected tree SHA-256 as above.
