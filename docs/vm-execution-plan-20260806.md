# VM batch 2026-08-06 — graphics / hardware / kernel module promotion (COMPLETE)

This document records the sixth disposable-VM validation batch, executed on
2026-08-06 in this repository (my-arch-setup-deepseek). It validates **module
selection** for four production-planning modules — `graphics-amd`,
`graphics-nvidia`, `hardware-tools` and `kernel-support` — whose 20 official
packages (including the multilib `lib32-nvidia-utils` and the DKMS
`nvidia-open-dkms`) had not yet been selected in any VM matrix run. On success
the four modules were promoted to `available` in `modules.tsv` and
`production-module-readiness.tsv`.

> **Status: COMPLETE.** Full nine-stage DAG passed in the VM after two guest
> environment fixes (enabling the `[multilib]` repository and repairing the
> baseline's dangling `Include` lines in `/etc/pacman.conf`), the idempotent
> rerun passed with all packages skipped, all 20 target packages were
> independently confirmed installed, evidence was extracted, and the four
> modules were promoted on the host (commit `54006f7`-style, see below).

## Scope and boundary

- Modules validated and promoted: `graphics-amd` (6), `graphics-nvidia` (7),
  `hardware-tools` (5), `kernel-support` (2) — 20 official packages.
- VM-safe scope: **package install only**. DKMS/GPU mode switching checks stay
  physical (`docs/remaining-work-20260804.md` line 62-64).
- The guest baseline had `[multilib]` disabled in `/etc/pacman.conf`; this is
  the first batch to select a multilib package (`lib32-nvidia-utils`), so the
  guest repository configuration was fixed as a disposable-VM adaptation (not a
  repository change).
- Boundary unchanged: physical ASUS GPU/audio/BT/suspend acceptance remains
  outside the matrix.

## Environment

- Domain `myarch-batch6-graphics` (qemu:///session, 4 GiB / 4 vCPU,
  host-passthrough, pc-q35-8.2, UEFI OVMF_CODE.4m.fd, virtio-blk vda + SLIRP
  `hostfwd 22222:22` via `qemu:commandline`).
- Base image `vm-validation-20260801/disks/baseline-handoff.qcow2` (read-only,
  SHA-256 `4210f312…`); overlay
  `vm-validation-20260806/disks/batch6-graphics.qcow2` (64 GiB sparse).
- Tree injected: `bsdtar` pax archive of the host HEAD plus the four-module
  candidate edits (`modules.tsv`, `production-module-readiness.tsv`,
  `profile-modules.tsv`), SHA-256 `f1677c55815a612331daa7dbbf49a0844b2684fe0da3c980ac65463516e19ca8`,
  447 members, extracted to `~/my-arch-setup`.
- Guest fixes (disposable, not repository): enabled `[multilib]`, replaced the
  mirrorlist with `https://mirrors.aliyun.com/archlinux/$repo/os/$arch`, and
  commented the dangling `Include = /etc/pacman.d/mirrorlist` lines that
  belonged to the commented `[*-testing]` sections (they were emitting
  `warning: directive Server ... not recognized` on every pacman stderr, which
  broke the archlinuxcn keyring absent-check's exact `error:` regex).

## Execution

1. Guest plan: `full-orchestrator.py --profile vm --modules
   desktop-shared,wm-niri,input-fcitx-rime,base-preconditions,build-foundation,
   fonts,audio,graphics-amd,graphics-nvidia,hardware-tools,kernel-support
   --plan --json` → exit 0, no apply blocker, effect vector
   `[2,1,77,1,2,3,3,33,29]` (151 effects), confirmations
   `system,archlinuxcn,aur`.
2. Full DAG apply (attempt 1) failed: `official-package-apply: repository
   query failed for lib32-nvidia-utils` — `[multilib]` disabled in the guest
   baseline. Attempt 2 failed: archlinuxcn keyring absent-check broke on the
   pacman.conf stderr warning. Attempt 3 failed: `no servers configured for
   repository` — the earlier fix had commented the `[extra]`/`[multilib]`
   `Include` lines too. Attempt 4 rejected by the failed-prior run-state guard;
   the final attempt used `--rerun` and passed.
3. Final successful run: run-id `20260804T025915Z-4b2558e3edfe`, plan
   fingerprint `c65ea4f4e…`, **9 stages passed + run-completed**:
   privilege-wrapper, official-update, official-packages,
   archlinuxcn-bootstrap, archlinuxcn-packages, aur-source-acquisition,
   aur-build-install, user-config, system-actions.
4. Idempotent rerun: run-id `20260804T031037Z-fdf975d1000c`, same fingerprint,
   9 stages passed, all packages `up to date -- skipping`, 0 failures.
5. Independent `pacman -Q` of all 20 target packages: 20/20 installed
   (amd-ucode, mesa, mesa-utils, vulkan-mesa-layers, vulkan-radeon,
   vulkan-tools, lib32-nvidia-utils, libva-nvidia-driver, libva-utils,
   nvidia-open-dkms, nvidia-prime, nvidia-settings, nvidia-utils, evtest,
   fprintd, fwupd, linux-firmware, powertop, linux-headers, linux-zen-headers).

## Evidence

Extracted to `~/.local/state/my-archlinux-setup/vm-lab/20260806/`:

- `run-apply.log` — 95497 B, SHA-256 `284737d2a4e93e092af65d46f17b3fd21802229629ae3e6d6330ff6c118d1d12`
- `run-rerun.log` — 23023 B, SHA-256 `9162b4d25ab809ef3902027eca259647cf792a15fa391bae83611d027b52759c`

## Cleanup

- ACPI poweroff (`sudo -n systemctl poweroff`) → `virsh undefine --nvram
  myarch-batch6-graphics` → offline `qemu-img check` (No errors, 12.32%
  allocated) → deleted overlay + NVRAM. Baseline and its digest unchanged;
  domain list empty.

## Host promotion

Applied the byte-identical candidate values: `modules.tsv` and
`production-module-readiness.tsv` promote the four modules to `available`
(readiness now 21 available / 9 planning / 2 unavailable; physical ASUS
default blockers reduced 13 → 9). `profile-modules.tsv` gained four
`vm`/`vm-v1` disabled rows. `tests/production-readiness-test.sh` readiness
count assertion 17/13 → 21/9. Docs updated: README, docs/modules.md,
docs/implementation-status.md (blocker list 13 → 9), docs/confirmed-decisions.md,
docs/vm-validation.md, docs/remaining-work-20260804.md (batch 2 COMPLETE,
remaining 5 planning modules). Full 39-test suite PASS.
