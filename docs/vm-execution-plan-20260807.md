# VM batch 2026-08-07 — service-planning module promotion (COMPLETE)

Disposable-VM validation of the five service-class planning modules:
`bluetooth`, `power`, `container-tools`, `storage-maintenance` and
`virtualization` (19 packages total). This is the third and final planning
batch; after it the module registry and execution readiness reach
26 available / 4 planning / 2 unavailable.

> **Status: COMPLETE.** Nine-stage DAG passed in the guest; idempotent rerun
> clean; all 19 target packages independently confirmed installed;
> physical-profile-scoped service actions recorded not-applicable in the VM
> (they are `asus-amd-nvidia`/`desktop-amd` scope and never run in the `vm`
> profile); evidence extracted; overlay destroyed; host promotion committed.

## Scope

- `bluetooth` (3): blueman, bluez, bluez-utils — action `bluetooth-service`
  (apply, physical) recorded not-applicable in VM.
- `power` (1): power-profiles-daemon — `power-profiles-service` (apply,
  physical) not-applicable in VM.
- `container-tools` (2): docker, docker-compose — `docker-service` (apply,
  physical) and `docker-group-membership` (manual, physical) not-applicable.
- `storage-maintenance` (6): btrfs-assistant, grub-btrfs, inotify-tools,
  rsync, smartmontools, snapper — `snapper-configs`/`snapper-timers` (manual),
  `grub-btrfs-recovery` (deferred) not-applicable.
- `virtualization` (7): dnsmasq, edk2-ovmf, libvirt, qemu-desktop,
  qemu-guest-agent, spice-vdagent, virt-manager — `libvirtd-service`,
  `libvirt-default-network` (apply), `libvirt-group-membership` (manual),
  `virtualization-hugepages` (deferred) not-applicable.

The VM validates package install; all five modules' system actions are
physical-profile-scoped and stay not-applicable in the `vm` profile exactly as
documented in `docs/remaining-work-20260804.md` section B.

## Environment

- Host session `qemu:///session`, SLIRP port 22222.
- Base image `vm-validation-20260801/disks/baseline-handoff.qcow2`
  (read-only, SHA-256 `4210f312…`); overlay
  `vm-validation-20260807/disks/batch7-services.qcow2` (64 GiB sparse).
- Domain `myarch-batch7-services` (4 GiB / 4 vCPU, host-passthrough, UEFI,
  `OVMF_CODE.4m.fd`, SLIRP `hostfwd 22222:22` via qemu:commandline, virtio-net
  at pcie addr 0x8). SSH via the 2026-08-01 ephemeral key.
- Candidate tree: host HEAD + five-module promotion (`modules.tsv`,
  `production-module-readiness.tsv`, `profile-modules.tsv` +5 vm rows),
  packed as `/tmp/opencode/batch7-tree.tar`
  (SHA-256 `fedf0fd55bf845fa33ebf5102b23e4e73a3e4defa9beb185d29ad4d0d7aee4db`,
  448 members), injected to `~/my-arch-setup` with the safe /tmp/tree-x mv.

## Guest plan (matches host sandbox)

`--modules desktop-shared,wm-niri,input-fcitx-rime,base-preconditions,
build-foundation,fonts,audio,bluetooth,power,container-tools,
storage-maintenance,virtualization --plan --json`: EXIT 0, no blockers,
effect vector `2,1,76,1,2,3,3,33,29` (150 effects), confirmations
`system,archlinuxcn,aur`.

## Verification runs

1. Full DAG apply (`--mode new --apply --confirm-*`): EXIT 0.
   run-id `20260804T070241Z-3108d10b26e5`, plan fingerprint
   `cb2a4ef611bbe16f568b69d6f9cc5d1420795c6ce88d32718cb855570992240d`;
   **9 stage-passed, 0 failed** (privilege-wrapper → official-update →
   official-packages → archlinuxcn-bootstrap → archlinuxcn-packages →
   aur-source-acquisition → aur-build-install → user-config →
   system-actions). system-actions failed-units checks empty (system/user).
2. Idempotent rerun (`--rerun --apply --confirm-*`): EXIT 0.
   run-id `20260804T071000Z-15ad237bffc0`, same fingerprint; 9 stage-passed,
   0 failed, `76 up to date -- skipping`, `2 nothing to do` (no rebuilds).
3. Independent `pacman -Q`: 19/19 target packages present (blueman 2.4.6-2,
   bluez 5.87-2, bluez-utils 5.87-2, power-profiles-daemon 0.30-1,
   docker 1:29.7.1-1, docker-compose 5.4.0-1, btrfs-assistant 2.2-5,
   grub-btrfs 4.14-1, inotify-tools 4.25.9.0-1, rsync 3.4.4-1,
   smartmontools 7.5-1, snapper 0.13.1-2, dnsmasq 2.93-1, edk2-ovmf 202605-1,
   libvirt 1:12.6.0-1, qemu-desktop 11.0.3-1, qemu-guest-agent 11.0.3-1,
   spice-vdagent 0.23.0-1, virt-manager 5.1.0-4). Guest total 798 packages.
4. Service actions: run.log contains no `bluetooth-service`/`power-profiles-
   service`/`docker-service`/`libvirtd-service`/`default-network` execution
   rows — physical-profile-scoped, correctly not-applicable in the vm profile.

## Evidence

Extracted to host `~/.local/state/my-archlinux-setup/vm-lab/20260807/`:
- `run-apply.log` (104 555 B, SHA-256
  `7b80fc4bcb7ec8b4b773904e20007ae1c81212fa27745b1d0dc4fd9fedd65428`)
- `run-rerun.log` (22 878 B, SHA-256
  `7d2fd09e76f1963cf7114395e126bf728446e26112cebbe2080c672d68b174c3`)

## Cleanup

ACPI shutdown (`sudo -n systemctl poweroff`) → `virsh undefine --nvram
myarch-batch7-services` → offline `qemu-img check`
(No errors, 8.37% allocated) → child overlay and NVRAM deleted.
Read-only baseline and digest `4210f312…` unchanged; domain list empty.

## Host promotion (commit `17d4ce4` successor)

- `modules.tsv` + `production-module-readiness.tsv`: the five modules
  planning → available (registry and readiness now 26/4/2).
- `profile-modules.tsv`: +5 vm/vm-v1 disabled rows (25 total).
- `tests/production-readiness-test.sh`: `{available:21,planning:9}` →
  `{available:26,planning:4}`.
- `tests/module-selection-test.sh`: asus-default and desktop-default
  `apply readiness` now `ready for implemented component actions` (their full
  default selections are all available after this batch).
- Docs: README (26/4/2), docs/modules.md, docs/implementation-status.md
  (blocker list 9 → 4), docs/confirmed-decisions.md,
  docs/remaining-work-20260804.md (batch 3 COMPLETE, baseline 26/4/2,
  blockers 4, A-section and DoD DONE).
- Full 39-test suite PASS, docs-check PASS.
