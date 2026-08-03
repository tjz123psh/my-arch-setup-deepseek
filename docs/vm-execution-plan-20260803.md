# VM batch 2026-08-03 — non-VM-selected AUR recipe validation

This document records the second disposable-VM validation batch, executed on
2026-08-03 in this repository (my-arch-setup-deepseek). It validates the nine
remote-fixed AUR recipes that were not selected in the 2026-08-02 VM matrix,
directly via the low-level `aur-build.py` / `aur-install.py` pipeline.

## Scope and boundary

- Recipes validated: `clash-verge-rev-bin`, `google-chrome`,
  `leaf-markdown-viewer-bin`, `obsidian-bin`, `wooz-git`, `claude-code`,
  `intellij-idea-ultimate-edition`, `opencode-bin`, `flclash-bin`.
- Recipes excluded: the three local-fixed recipes (`linuxqq-appimage`,
  `wechat-appimage`, `paru`) were excluded from this batch because their
  `aur-source-acquire.py` plans remained ready but unapplied at the time;
  they were subsequently validated in batch 2026-08-03b (see
  [`vm-execution-plan-20260803b.md`](vm-execution-plan-20260803b.md)).
- Module status: this batch produces **package-specific** evidence only. It does
  not promote `daily-apps`, `development-toolchain` or `personal-autostart` to
  `available`; each planning module still requires its own module selection in
  the VM matrix (see `manifests/production-module-readiness.tsv`).
- Boundary reason: `full-orchestrator.py` fail-closes any module whose
  production readiness is not `available`, so the exact VM matrix cannot select
  these modules yet. The recipe-level pipeline is validated independently.

## Environment

- Host session: `qemu:///session`, SLIRP user networking, port `22222`.
- Base image: `vm-validation-20260801/disks/baseline-handoff.qcow2`
  (read-only, `440`, validated 2026-08-02, backing the official cloud image).
- Overlay: `vm-validation-20260803/disks/batch2-aur.qcow2` (64 GiB sparse),
  derived with `qemu-img create -f qcow2 -F qcow2 -b base`.
- Domain: `myarch-batch2-aur` (4 GiB, 4 vCPU, host-passthrough, UEFI,
  virtio disk with `cache=none,discard=unmap`, SLIRP `hostfwd 22222:22`).
- SSH: reused the 2026-08-01 ephemeral key and known_hosts from
  `vm-validation-20260801/ssh/` (they remain valid for the overlay).
- Tree injected: fresh `bsdtar` pax archive of this repository HEAD
  (`439` members, SHA-256
  `0dcc935ac082d1dcd007c08aee9f60750207244d17578d81198f4a9414f18c8e`),
  excluding `.git` and the root `仓库地址` file.
- Guest tooling: `pacman -Syu --needed devtools base-devel` installed
  (`makepkg`, `mkarchroot`, `makechrootpkg`, `arch-nspawn`), helper scripts
  `gsudo` / `fuzzel-askpass` deployed to `~/scripts/desktop/` per mapping rows
  112/113 and 190/191.

## Execution log

### 1. Clean-chroot initialization and first build pass

`aur-build.py --packages <all nine> --build --post-official
--confirm-aur --confirm-system-changes` initialized the private clean chroot
(`~/.local/state/my-archlinux-setup/builds/aur/chroot`), acquired each recipe
source through the reviewed `remote-fixed` policy, and built nine packages in
the isolated chroot.

First pass results: **six passed** (`wooz-git`, `claude-code`,
`intellij-idea-ultimate-edition`, `opencode-bin`, `flclash-bin`), **four failed**
(`clash-verge-rev-bin`, `google-chrome`, `obsidian-bin`,
`leaf-markdown-viewer-bin`).

### 2. Defect found and fixed — artifact metadata whitelist

All four failures shared one root cause: `aur-build.py` `verify_artifact`
only accepted pacman metadata paths `.BUILDINFO`, `.MTREE`, `.PKGINFO`.
The four PKGBUILDs legitimately declare `install=` (`clash-verge-rev-bin`
`.install`, `google-chrome` `google-chrome.install`, `obsidian-bin`
`obsidian-bin.install`) or `changelog=` (`leaf-markdown-viewer-bin`), so their
built artifacts contain `.INSTALL` / `.CHANGELOG`, which the narrow whitelist
rejected.

Fix (host, commit `2a2fd4d`): accept `.INSTALL` and `.CHANGELOG` in the
metadata whitelist, with a comment citing the PKGBUILD `install=`/`changelog=`
declarations. A regression test (`tests/aur-build-test.sh`,
`MOCK_ARTIFACT_SCENARIO=with-install-changelog`) fails on the old code and
passes on the new one. The fixed `aur-build.py` SHA-256
`a89b92c9…` was re-pinned in `installer/aur-stage-apply.py`
(`AUR_BUILD_SHA256`) and `manifests/stage-inputs.tsv`; the changed
`aur-stage-apply.py` (`df8a4dfd…`) was re-pinned in
`manifests/stage-executables.tsv`. All 39 host tests, `docs-check` and both
profile plans pass.

### 3. Second pass — all nine pass

The four previously failing recipes were rebuilt in the VM against the fixed
tool. All nine now report `status: passed`, `artifact.state: verified`.

### 4. Idempotent rerun

The full nine-recipe command was rerun unchanged. Every artifact returned the
same SHA-256 as the first pass (cached verification), e.g. `clash-verge-rev-bin`
`4a31e513…`, `google-chrome` `6bc3e3da…`, `intellij-idea-ultimate-edition`
`4b914ce8…`. No rebuild occurred.

### 5. Install pass

`aur-install.py --packages <all nine> --install --confirm-aur
--confirm-system-changes` installed all nine artifacts from the verified
`aur-installed.json` state (`schema=1`). Independent guest query confirmed all
nine packages present (`pacman -Q`), e.g. `clash-verge-rev-bin 2.5.2-1`,
`google-chrome 151.0.7922.71-1`, `opencode-bin 1.18.10-1`.

### 6. Shutdown and rollback

The domain was shut down with ACPI, undefined with NVRAM, its overlay passed
offline `qemu-img check`, and the overlay was deleted. No domain remains in the
session.

## Evidence

- `~/.local/state/my-archlinux-setup/vm-lab/20260803/aur-installed.json`
  (per-package artifact and recipe-tree SHA-256, installed-at timestamps).
- `~/.local/state/my-archlinux-setup/vm-lab/20260803/aur-logs/`
  (private build logs, 3 files).
- `~/.local/state/my-archlinux-setup/vm-lab/20260803/aur-install-private.log`.
- Artifact cache lived inside the disposable overlay; the overlay is deleted by
  design after evidence extraction. Package `pkg.tar.zst` hashes are retained
  in `aur-installed.json`.

## Remaining work after this batch

1. The three local-fixed recipes (linuxqq-appimage, wechat-appimage, paru)
   were subsequently validated in batch 2026-08-03b after their private source
   caches were acquired and reviewed (see
   [`vm-execution-plan-20260803b.md`](vm-execution-plan-20260803b.md)).
2. Each of `daily-apps`, `development-toolchain`, `personal-autostart` needs a
   module-level selection in a future VM matrix before production promotion;
   this batch only supplies package-specific recipe evidence.
3. Physical-host acceptance gates remain unchanged and environment-dependent.
