# VM batch 2026-08-05 — planning software-module validation

This document records the fifth disposable-VM validation batch, executed on
2026-08-05 in this repository (my-arch-setup-deepseek). It validates **module
selection** for the first software-only group of production-planning modules —
`cli-tools`, `desktop-apps`, `ocr` and `recording` — whose package effects were
not previously present in any exact VM selection. The batch runs the full
nine-stage DAG with these modules selected and, on success, promotes them to
`available` in `modules.tsv` and `production-module-readiness.tsv`.

> **Status: COMPLETE.** The full nine-stage DAG passed (run
> `20260804T015201Z-55b9107a7e4b`, plan fingerprint `a2ecfdaf…`), the idempotent
> rerun passed (run `20260804T015833Z-7f1fd494e19b`, same fingerprint, all 37
> packages `up to date -- skipping`), all 37 packages were independently
> confirmed with `pacman -Q`, evidence was extracted to
> `~/.local/state/my-archlinux-setup/vm-lab/20260805/`, and the VM was shut down
> and removed. Host promotion applied the byte-identical candidate values.

## Scope and boundary

- Modules validated and promoted: `cli-tools` (14 packages), `desktop-apps`
  (9 packages), `ocr` (3 packages), `recording` (10 packages, including
  `wl-screenrec-git` from archlinuxcn) — 37 packages total, all
  `package-only`, **zero config mappings and zero system actions**.
- Validated on top of the existing vm default selection
  (`desktop-shared,wm-niri,input-fcitx-rime,base-preconditions,
  build-foundation,fonts,audio`).
- Boundary: these modules carry no physical-scoped system actions, so the VM
  matrix validates the full effect surface; physical hardware acceptance for
  GPU/audio/Bluetooth stays outside this matrix.
- This batch is the first of three per `docs/remaining-work-20260804.md`
  (batch 1 software-only; batches 2-3 graphics and services remain).

## Candidate manifest changes (applied to host after VM success)

1. `manifests/modules.tsv`: `cli-tools`, `desktop-apps`, `ocr`, `recording`
   `planning` → `available`.
2. `manifests/production-module-readiness.tsv`: same four rows `planning` →
   `available`.
3. `manifests/profile-modules.tsv`: add `vm`/`vm-v1` `disabled` rows for
   `cli-tools`, `desktop-apps`, `ocr` (`recording` row already existed).

Sandbox-verified host plan after the candidate edits:

- vm default: unchanged (131 effects, identical pre/post edit).
- vm + four modules: `ready` (no `non_executable_modules` blocker), effect
  vector `2,1,92,1,3,3,3,33,29` (167 effects), confirmations `system,archlinuxcn`.

## Environment

- Host session: `qemu:///session`, SLIRP user networking, port `22222`.
- Base image: `vm-validation-20260801/disks/baseline-handoff.qcow2` (read-only,
  SHA-256 `4210f312fab4344907325ebb8db6a35f42aa5462a5227162075e3109a33f71b3`).
- Overlay: `vm-validation-20260805/disks/batch5-planning-software.qcow2`
  (64 GiB sparse), derived with `qemu-img create -f qcow2 -F qcow2 -b base`.
- Domain: `myarch-batch5-planning` (4 GiB, 4 vCPU, host-passthrough, UEFI,
  virtio disk `cache=none,discard=unmap`, SLIRP `hostfwd 22222:22` via
  `qemu:commandline`; no audio or RNG devices).
- SSH: reused the 2026-08-01 ephemeral key and known_hosts from
  `vm-validation-20260801/ssh/`.
- Tree injected: fresh `bsdtar` pax archive of the host HEAD plus the candidate
  edits (SHA-256 `7cfa66e8f3b8ed91417d0e1c6ec277cad7f348a78b3659a7979e2badcc77cad4`,
  446 members), extracted to `~/my-arch-setup` in the guest.

## Execution evidence

### Guest plan

- Default vm: `2,1,57,1,2,3,3,33,29` (131 effects) — unchanged by the
  candidate edits.
- vm + four modules: no apply blocker; `2,1,92,1,3,3,3,33,29` (167 effects).

### Full DAG apply (run 20260804T015201Z-55b9107a7e4b)

- Exit 0; plan fingerprint `a2ecfdaf2f9b8e99f719a9768638c8618e41374c05987887ed8c61706bf915e2`.
- All nine stages `stage-passed`: privilege-wrapper, official-update,
  official-packages, archlinuxcn-bootstrap, archlinuxcn-packages,
  aur-source-acquisition, aur-build-install, user-config, system-actions.

### Idempotent rerun (run 20260804T015833Z-7f1fd494e19b)

- Exit 0; same fingerprint; `run-completed` on attempt 1; all nine stages
  passed with `up to date -- skipping` for already-installed packages.

### Independent confirmation

- Guest package count 774; all 37 target packages confirmed installed via
  `pacman -Q`, including bat 0.26.1-2, yazi 26.5.6-4, tesseract 5.5.3-1,
  nemo 6.6.4-1, ffmpeg 2:8.1.2-11, wl-screenrec-git r355.0925290-1.

### Evidence files (host `~/.local/state/my-archlinux-setup/vm-lab/20260805/`)

- `run-apply.log` (105 KB, SHA-256 `f28306e1…`)
- `run-rerun.log` (23 KB, SHA-256 `99b16f23…`)

### Cleanup

- ACPI poweroff → `virsh undefine --nvram myarch-batch5-planning` →
  offline `qemu-img check` (No errors, 8.99% allocated) → overlay and NVRAM
  deleted. Baseline `baseline-handoff.qcow2` unchanged.

## Host promotion (applied, pending commit)

- `modules.tsv` / `production-module-readiness.tsv` / `profile-modules.tsv`
  carry the candidate values byte-identical to the guest-validated tree.
- Production readiness now 17 available / 13 planning / 2 unavailable; the
  physical ASUS default blocker count dropped 17 → 13.
- Full test suite and docs-check pass with the updated assertions.
