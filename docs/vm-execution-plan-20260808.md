# VM batch 2026-08-08 — config-only module readiness promotion

This document records the sixth disposable-VM validation batch, executed on
2026-08-08 in this repository (my-arch-setup-deepseek). It validated the
full-DAG module selection of the four config-only surfaces —
`developer-editor`, `personal-scripts`, `asus-hardware` and
`personal-user-services` — that were registry-`available` but readiness-`planning`,
and on success promoted their production readiness to `available`. This closes
the last `planning` module: readiness is now 30 `available` / 0 `planning` /
2 `unavailable`.

> **Status: COMPLETE.**

## Scope and boundary

- Modules validated and readiness-promoted: `developer-editor` (6 extra
  packages: fd, lua-language-server, neovide, neovim, ripgrep, stylua),
  `personal-scripts` (no packages), `asus-hardware` (3 archlinuxcn packages:
  asusctl, rog-control-center, supergfxctl), `personal-user-services` (no
  packages).
- All 86 config mappings owned by these four modules are `physical-v1` scope:
  under the `vm` profile the user-config stage deploys none of them, exactly
  like `personal-autostart` in batch 2026-08-04. The system actions
  (`personal-user-unit-reload`, `asusd-package-activation`,
  `supergfxd-physical-service`, `physical-hardware-acceptance`) are
  physical-profile-scoped and recorded not-applicable in the VM.
- Boundary: physical asusd/supergfxd/GPU-mode and hardware acceptance remain
  outside the matrix; the promotion authorizes only the exact VM-proven gate
  values.

## Candidate manifest changes (host repository, applied after VM success)

1. `manifests/production-module-readiness.tsv`: the four rows `planning` →
   `available` (evidence text updated).
2. `manifests/profile-modules.tsv`: four `vm`/`vm-v1` rows with `disabled`
   default appended (so `--modules` can select them without changing the
   default vm selection). `modules.tsv` already listed them `available`.

Host-verified plan after the edits: default vm selection unchanged
(`2,1,57,1,2,3,3,33,29`, 131 effects); vm + four modules ready with no
blocker and effect vector `2,1,63,1,5,3,3,33,29` (140 effects), no
confirmations required.

## Environment

- Host session: `qemu:///session`, SLIRP user networking, port `22222`.
- Base image: `vm-validation-20260801/disks/baseline-handoff.qcow2`
  (read-only, SHA-256
  `4210f312fab4344907325ebb8db6a35f42aa5462a5227162075e3109a33f71b3`).
- Overlay: `vm-validation-20260808/disks/batch8-config.qcow2` (64 GiB sparse).
- Domain: `myarch-batch8-config` (4 GiB, 4 vCPU, host-passthrough, UEFI,
  virtio-blk + SLIRP hostfwd 22222:22).
- Tree injected: fresh `bsdtar` pax archive of the host HEAD plus the candidate
  edits (SHA-256 `2b23765d4cb8592d6db732fa96175afba1ba7cfd950abda7776b0705796fb8fa`,
  449 members), extracted to `~/my-arch-setup`.
- Guest tooling: devtools/base-devel from earlier batches; aliyun pacman
  mirrorlist and patched DLAGENTS retained in the baseline overlay.

## Execution steps

1. Plan readiness in guest: `full-orchestrator.py --profile vm --modules
   <default+4> --plan --json` reports ready, no apply blocker, effect vector
   `2,1,63,1,5,3,3,33,29` (140 effects).
2. Full DAG apply: `full-orchestrator.py --profile vm --modules <default+4>
   --mode new --apply --confirm-system-changes --confirm-archlinuxcn
   --confirm-aur` — nine stages; official-packages installs the six
   developer-editor extra packages, archlinuxcn-packages installs the three
   asus-hardware packages; user-config deploys no mappings (all physical
   scope); system-actions has no vm-scope actions.
3. Idempotent rerun: same command re-verified by state (exit 0, unchanged
   targets, no rebuild).
4. Independent `pacman -Q` checks for all 9 target packages.
5. Evidence extraction to `~/.local/state/my-archlinux-setup/vm-lab/20260808/`.
6. ACPI shutdown → `virsh undefine --nvram` → offline `qemu-img check` →
   delete overlay.
7. Host promotion: apply the candidate readiness and profile-modules edits,
   update `tests/production-readiness-test.sh` (readiness counts
   26/4/2 → 30/0/2; audit_modules now assert `available` and absence from
   blockers), update README/docs counts, run the full local test suite and
   docs-check, then commit.

## Rollback scope

- Any unexpected preflight/query/build/service/config result stops the matrix.
- Overlay is disposable: undefine with `--nvram`, offline `qemu-img check`,
  delete only the child overlay. The read-only baseline and its digest are
  unchanged.
- Host manifests are edited only after VM success and are one reviewed commit.

## Verification record

### Guest runs (domain `myarch-batch8-config`)

- Full apply (`--mode new`): run-id `20260804T075949Z-bedb45f76987`; run.log
  verified 9 stage-passed + run-completed with failure-exit 0.
- Idempotent rerun: run-id `20260804T080849Z-1042396f277f`; run.log verified
  9 stage-passed, 0 failed, all targets `up to date -- skipping`.
- Independent `pacman -Q`: 9/9 target packages confirmed (fd,
  lua-language-server, neovide, neovim, ripgrep, stylua, asusctl,
  rog-control-center, supergfxctl); guest total 711 packages.
- No config mapping deployed and no system action executed under the vm
  profile (all physical scope), matching the plan.

### Evidence (host `~/.local/state/my-archlinux-setup/vm-lab/20260808/`)

- `run-apply.log` — SHA-256
  `b49c36c0bec86b3ac7fa22234b931177c04b71ce0730027b9a592c7332de110d`
- `run-rerun.log` — SHA-256
  `53eb592afc7e8898974e77d2caf64cf85d001dfd6a09682720cf4cf6b33b530c`

### Cleanup

- ACPI shutdown (`sudo -n systemctl poweroff`), `virsh undefine --nvram`,
  offline `qemu-img check` (No errors, 8.04% allocated), overlay + NVRAM
  deleted; domain list empty. Baseline digest unchanged.

### Host promotion (commit pending at the time of this writing)

- `production-module-readiness.tsv`: four rows → `available` (30/0/2).
- `profile-modules.tsv`: four vm rows appended (29 vm rows total).
- `tests/production-readiness-test.sh`: readiness counts 26/4/2 → 30/0/2;
  audit_modules loop now asserts `module not in blockers` and
  `selected_readiness[module] == "available"`.
- Docs: README, modules.md, implementation-status.md, confirmed-decisions.md,
  remaining-work-20260804.md counts and blocker language updated.
- Full test suite: PASS=39 FAIL=0; docs-check PASS.
