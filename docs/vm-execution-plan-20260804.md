# VM batch 2026-08-04 — module-level promotion validation (complete)

This document records the fourth disposable-VM validation batch, executed on
2026-08-04 in this repository (my-arch-setup-deepseek). It validates **module
selection** for four production-planning modules — `daily-apps`,
`repository-tools`, `development-toolchain` and `personal-autostart` — whose
recipe-level pipeline evidence already exists (batches 2026-08-03 / 2026-08-03b
validated the fixed AUR recipes; `claude-code` and
`intellij-idea-ultimate-edition` were removed from `development-toolchain` by
operator decision before the final run). The batch runs the full nine-stage DAG
with these modules selected, and on success promotes them to `available` in
`modules.tsv` and `production-module-readiness.tsv`.

> **Status: COMPLETE.** After a host-network outage paused the batch, the
> operator restored FlClash egress and the run resumed with the post-removal
> candidate tree. The full nine-stage DAG passed in the guest (plan fingerprint
> `3ad14c99…`, effect vector `2,1,77,1,4,13,13,33,29`, 173 effects), an
> idempotent rerun skipped all 13 AUR artifacts without rebuilding, and
> independent `pacman -Q` confirmed the module-level package effects. The
> evidence lives in
> `~/.local/state/my-archlinux-setup/vm-lab/20260804/`. Host promotion (four
> modules → `available`) is applied and the full local test suite passes. See
> §Verification run (2026-08-04) below.

## Scope and boundary

- Modules to validate and promote: `daily-apps` (7 AUR recipes), `repository-tools`
  (paru + downgrade + pacman-contrib + reflector), `development-toolchain`
  (opencode-bin + 21 official/archlinuxcn packages — `claude-code` and
  `intellij-idea-ultimate-edition` were removed from the module by operator
  decision on 2026-08-04, see the pause record below),
  `personal-autostart` (flclash-bin + FlClash.desktop).
- This batch validates the **module-level** effect surface in the VM matrix:
  official/archlinuxcn package installs, AUR source acquisition and
  build-install, user-config and system-actions stages for the four modules,
  on top of the existing vm default selection
  (`desktop-shared,wm-niri,input-fcitx-rime,base-preconditions,build-foundation,
  fonts,audio`).
- `personal-autostart` has no vm-v1 config mapping (its FlClash.desktop mapping
  is physical-v1 scope); its VM effect is the flclash-bin AUR recipe.
- Boundary: physical ASUS/GPU/BT/audio/suspend/boot-recovery evidence remains
  outside the matrix; the module promotion authorizes only the exact VM-proven
  gate values, never physical acceptance.

## Candidate manifest changes (host repository, applied after VM success)

1. `manifests/modules.tsv`: `repository-tools`, `daily-apps`,
   `development-toolchain` `planning` → `available`
   (`personal-autostart` is already `available`).
2. `manifests/production-module-readiness.tsv`: the four rows `planning` →
   `available` (evidence text updated to record the module selection).
3. `manifests/profile-modules.tsv`: add four `vm`/`vm-v1` rows with
   `disabled` default (so `--modules` can select them without changing the
   default vm selection).

Sandbox-verified host plan after the candidate edits:

- vm default: requested/resolved modules unchanged; 129 effects (identical to
  pre-edit).
- vm + four modules: `ready` (no `non_executable_modules` blocker), effect
  vector `2,1,77,1,4,15,15,33,29`, confirmations `system,archlinuxcn,aur`.

## Environment

- Host session: `qemu:///session`, SLIRP user networking, port `22222`.
- Base image: `vm-validation-20260801/disks/baseline-handoff.qcow2`
  (read-only, SHA-256 `4210f312fab4344907325ebb8db6a35f42aa5462a5227162075e3109a33f71b3`).
- Overlay: `vm-validation-20260804/disks/batch4-module-promotion.qcow2`
  (64 GiB sparse), derived with `qemu-img create -f qcow2 -F qcow2 -b base`.
- Domain: `myarch-batch4-promotion` (4 GiB, 4 vCPU, host-passthrough, UEFI,
  virtio disk `cache=none,discard=unmap`, SLIRP `hostfwd 22222:22`; no audio or
  RNG devices).
- SSH: reused the 2026-08-01 ephemeral key and known_hosts from
  `vm-validation-20260801/ssh/`.
- Tree injected: fresh `bsdtar` pax archive of the host HEAD, excluding `.git`
  and the root `仓库地址` file, extracted to `~/my-arch-setup` in the guest.
  The guest tree's three candidate manifests carry the candidate edits above.
- Private sources injected: host `~/.cache/my-archlinux-setup/aur-sources/`
  (linuxqq-appimage, paru, wechat-appimage) into
  `~/.cache/my-archlinux-setup/aur-sources/` at the contract path.
- Guest tooling: `pacman -Syu --needed devtools base-devel` (makepkg,
  mkarchroot, makechrootpkg, arch-nspawn); `gsudo`/`fuzzel-askpass` deployed.

## Execution steps

1. Plan readiness in guest: `full-orchestrator.py --profile vm --modules
   <default+4> --plan --json` must report ready, no apply blocker, exact
   effect vector `2,1,77,1,4,15,15,33,29`.
2. Full DAG apply: `full-orchestrator.py --profile vm --modules <default+4>
   --mode new --apply --confirm-system-changes --confirm-archlinuxcn
   --confirm-aur` — nine stages, official full refresh, archlinuxcn bootstrap,
   AUR acquire/build-install for all twelve recipes, user-config, actions.
3. Idempotent rerun: same command without confirmations re-verified by state
   (exit 0, unchanged targets).
4. Independent `pacman -Q` checks: daily-apps recipes, paru, downgrade,
   pacman-contrib, reflector, claude-code, intellij-idea-ultimate-edition,
   opencode-bin, development-toolchain official packages, flclash-bin.
5. Evidence extraction to
   `~/.local/state/my-archlinux-setup/vm-lab/20260804/`.
6. ACPI shutdown → `virsh undefine --nvram` → offline `qemu-img check` →
   delete overlay.
7. Host promotion: apply the byte-identical candidate manifest edits
   (modules.tsv, production-module-readiness.tsv, profile-modules.tsv), update
   `tests/production-readiness-test.sh` (proven recipes set 3→15, readiness
   counts 9/21/2 → 13/17/2, audit_modules drops `personal-autostart`,
   non-executable blocker assertions), run the full local test suite and
   docs-check, then commit.

## Rollback scope

- Any unexpected preflight/query/build/service/config result stops the matrix;
  no ad-hoc host/guest fix without a revised plan.
- Overlay is disposable: undefine the shut-down domain with `--nvram`, offline
  `qemu-img check`, delete only the child overlay. The read-only baseline and
  its digest are unchanged.
- Host manifests are edited only after VM success and are one reviewed commit
  reverting to the pre-batch state if the final suite fails.

## Pause record (2026-08-04)

Operator paused the batch ("现在我还要睡，等我起来再说") before it completed;
resume requires an operator decision. Everything below was verified before the
pause.

### Progress achieved in the guest (domain `myarch-batch4-promotion`)

- Plan: ready, no apply blocker, exact effect vector `2,1,77,1,4,15,15,33,29`
  (177 effects) — matches the host sandbox prediction.
- `official-update`: 496 packages installed (official full refresh).
- `official-packages`, `archlinuxcn-bootstrap`, `archlinuxcn-packages`: passed.
- AUR artifacts already built (5 of 15), verified under their recipe pins:
  - clash-verge-rev-bin-2.5.2-1-x86_64.pkg.tar.zst
  - claude-code-2.1.220-1-x86_64.pkg.tar.zst (sha256
    `fe900aaa3be99cb33ea7f4232d1c7239cfbb0dd694f3e4ecd618eaa9ffed354c`,
    recipe pin `8f4d40bc…` matches)
  - dsearch-bin-0.3.2-1-x86_64.pkg.tar.zst
  - fcitx5-skin-fluentdark-git-v0.4.0.r7.g399699a-1-x86_64.pkg.tar.zst
  - fuzzel-ime-git-1.14.1.r26.g302f228-1-x86_64.pkg.tar.zst
- Guest root now has 788 installed packages; `/` has 53 GiB free.
- Guest pacman mirrorlist (system, chroot root, chroot pang) switched to
  `https://mirrors.aliyun.com/archlinux/$repo/os/$arch` to avoid the broken
  geo mirror during the FlClash outage window.
- Guest makepkg.conf DLAGENTS patched to
  `/usr/bin/curl -qgb "" -fLC - --retry 500 --retry-delay 1 --retry-all-errors -o %o %u`
  (system, chroot root, chroot pang) so large sources resume across the
  ~10 MiB-per-connection FlClash truncation.
- `~/.local/state/my-archlinux-setup/logs/` holds the per-run AUR source
  acquisition logs; runs live under
  `~/.local/state/my-archlinux-setup/full-orchestrator/runs/20260803T175601Z-fa270b9cf8cd/`
  (plan fingerprint `86ad4393…`).

### Blocking issue (environment, not repository)

Host FlClash lost all foreign egress; every foreign site returns TLS EOF /
connection reset (github.com, raw.githubusercontent, objects.githubusercontent,
codeload, api.github.com, dl.google.com, download.jetbrains.com,
download-cdn.jetbrains.com, flclash CDN). Only Chinese mirrors (aliyun, tuna,
ustc) respond. The host 7890 proxy is also dead (same TLS EOF), so the guest
cannot reach foreign sources through `10.0.2.2:7890` either. This is a host
network-stack fault outside the workspace; it cannot be fixed while the
operator is away.

Consequences for the batch:

- `aur-source-acquisition` cannot verify the 9 remote-fixed recipes that
  require foreign downloads (the fixed local sources linuxqq/paru/wechat are
  cached and verify fine). The stage is fail-closed: it aborts on the first
  unverifiable remote source.
- **Operator decision (2026-08-04): remove `claude-code` and
  `intellij-idea-ultimate-edition` from the `development-toolchain` module** —
  claude-code is not needed, and the intellij source (~1.6 GiB) is too heavy to
  download in a batch-restore flow. Both recipes were dropped from
  `aur-recipes.tsv` (15 → 13), `workstation-packages.tsv`, the observed
  inventory (180 → 178) and the private recipe tree; pins and tests were
  re-derived and the full local suite passes. The intellij tarball was deleted
  during the earlier rollback of the pre-download attempt.

### Decision needed from the operator

1. Fix/restore host FlClash egress (or accept its transient outages), then
   resume the batch. The AUR scope is now 13 recipes: 3 local-fixed cached
   (linuxqq/paru/wechat) + 7 daily-apps/other remote-fixed + opencode-bin +
   dsearch-bin/fcitx5-skin-fluentdark-git/fuzzel-ime-git matrix recipes.
   `claude-code` and `intellij-idea-ultimate-edition` are no longer part of the
   module and do not gate this batch.
2. Alternatively re-run this part of the batch from scratch after the network
   recovers (the overlay keeps all guest state, so a resume is cheap).
3. Whether the operator prefers to watch the run live.

Resume command (after network recovery, from guest):

```
export TMPDIR=~/tmp; cd ~/my-arch-setup && \
python3 installer/full-orchestrator.py --profile vm \
  --modules desktop-shared,wm-niri,input-fcitx-rime,base-preconditions,build-foundation,fonts,audio,\
daily-apps,repository-tools,development-toolchain,personal-autostart \
  --retry-stage aur-source-acquisition --apply \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
```

All guest processes were stopped before the pause (verified no residual
orchestrator/makepkg/curl). The domain is still running with its overlay
intact.

## Verification run (2026-08-04, resumed after network restore)

The operator restored host FlClash egress, the batch resumed, and this section
records the final successful run. The old PAUSED state (fingerprint
`86ad4393…`) was superseded by a new tree (commit e3c2325 plus the candidate
promotion manifests) whose plan fingerprint is `3ad14c99…`.

### Guest run (domain `myarch-batch4-promotion`)

- Fresh tree injected from the host archive (SHA-256 `167982e2…`, 431 members)
  plus the private AUR source cache for linuxqq/paru/wechat.
- Plan: ready, no apply blocker, effect vector `2,1,77,1,4,13,13,33,29`
  (173 effects).
- Full DAG apply (`--mode new`): all nine stages passed — privilege-wrapper,
  official-update (496 packages), official-packages, archlinuxcn-bootstrap,
  archlinuxcn-packages, aur-source-acquisition (13 recipes source-verified),
  aur-build-install (13 clean-chroot builds + installs), user-config
  (33 targets), system-actions (failed-units empty).
- Idempotent rerun (`--rerun`): run-completed with the same fingerprint; the
  AUR build log shows `skip: <pkg>: verified artifact already exists` for all
  13 packages and "nothing to do" for the chroot update; no artifact mtime
  changed (all artifacts remain in the 21:54–21:58 window).
- Independent `pacman -Q`: all 13 AUR packages installed with the pinned
  versions (e.g. paru 2.1.0-5, opencode-bin 1.18.10-1, linuxqq-appimage
  3.2.32_20260730-1); module-level official packages present (pacman-contrib
  1.13.1-1, reflector 2023-5, downgrade 12.0.2-1); `paru --version` runs
  (v2.1.0, libalpm v16.0.1); guest total 812 installed packages.

### Evidence (host `~/.local/state/my-archlinux-setup/vm-lab/20260804/`)

- `aur-installed.json` — module-level installation snapshot (13 AUR + 3 module
  official packages + total count), sha256 `dd48cacc…`.
- `run-apply.log` / `run-rerun.log` — full-orchestrator run logs for the apply
  (fingerprint `3ad14c99…`) and the idempotent rerun, sha256 `b7da5264…` /
  `09d0ef0b…`.
- `aur-build-20260803T215415Z-155887.log` — the successful 13-recipe clean-chroot
  build log (sha256 `cc1d4dd0…`); `aur-build-20260803T220140Z-213228.log` — the
  idempotent rerun skip log (sha256 `b1c5399f…`).
- `aur-install-20260803T215842Z-199594.log` / `aur-install-20260803T220144Z-213291.log`,
  `aur-source-acquire-*.log` — per-stage AUR install/source logs.
- Earlier paused-attempt logs (17:20–17:57, fingerprint `86ad4393…`) are also
  preserved in the directory for provenance.

### Cleanup

ACPI shutdown → `virsh undefine --nvram myarch-batch4-promotion` → offline
`qemu-img check` (No errors, 19.17% allocated) → overlay and NVRAM deleted.
The read-only baseline `baseline-handoff.qcow2` and its digest
(`4210f312…`) are unchanged. The domain list is empty.

### Host promotion (commit after this document)

- `manifests/modules.tsv`: `daily-apps`, `repository-tools`,
  `development-toolchain` → `available` (`personal-autostart` was already
  available).
- `manifests/production-module-readiness.tsv`: the same four rows →
  `available`, evidence text updated to record the module-level verification.
- `manifests/profile-modules.tsv`: four `vm`/`vm-v1` rows with `disabled`
  default added (so `--modules` can select them without changing the default vm
  selection).
- `tests/production-readiness-test.sh`: proven set covers all 13 recipes,
  readiness counts `{available: 13, planning: 17, unavailable: 2}`,
  audit_modules now `developer-editor`, `personal-scripts`, `asus-hardware`,
  `personal-user-services`.
- Full local suite: 39/39 tests pass (including docs-check and static-check).
