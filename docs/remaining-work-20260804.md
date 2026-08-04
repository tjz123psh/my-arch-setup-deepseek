# Remaining work before physical-host apply (2026-08-04 audit)

Status date: 2026-08-04. This document is the consolidated, audited inventory of
everything that remains **before the physical-host deployment phase** can start.
Physical apply itself is **deferred by operator decision**; this list covers the
software-side work that must complete first.

## Current baseline (verified facts)

- Nine-stage DAG (`full-orchestrator.py`) validated end-to-end in disposable VMs;
  13 fixed AUR recipes passed real source/build/artifact/install/rerun paths.
- Module registry (`modules.tsv`): **21 `available` / 9 `planning` / 2 `unavailable`**
  (32 total).
- Execution gate (`production-module-readiness.tsv`): **21 `available` /
  9 `planning` / 2 `unavailable`** — the four config-only available
  modules (`developer-editor`, `personal-scripts`, `asus-hardware`,
  `personal-user-services`) are readiness-`planning` for full-DAG execution.
- Workstation policy: 203 rows (183 current-explicit + 20 confirmed-desired);
  184 install / 18 verify / 1 deferred. AUR recipes: 13 (10 remote-fixed +
  3 local-fixed with private caches).
- Physical-host audit (2026-08-04): host explicit sync set fully covered by the
  policy (0 missing); five host-explicit packages adopted (polkit-gnome,
  ydotool, qemu-guest-agent, spice-vdagent, sysbench) in commit `72852fe`.
- Full ASUS physical profile remains fail-closed with **9 apply blockers**
  (5 planning modules + `developer-editor`, `personal-scripts`,
  `asus-hardware`, `personal-user-services`).

## Remaining work items

### A. Module-level VM validation for the remaining 5 planning modules

The remaining 5 planning modules are **package-only** (zero config mappings).
Their system actions are mostly physical-profile-scoped (see B), so the VM
matrix validates the package effects; physical-scoped actions stay
not-applicable in `vm` profile exactly as in batch 2026-08-04.

Package inventory per module (all `pacman`/`extra` unless noted):

| Module | Packages | System actions (profile) |
| --- | --- | --- |
| `cli-tools` ✓ | bat, btop, eza, fastfetch, fzf, git-delta, jq, lsof, sysbench, unzip, wget, yazi, yt-dlp, zoxide (14) | none |
| `desktop-apps` ✓ | cinnamon-translations, ffmpegthumbnailer, file-roller, flatpak, mission-center, nemo, nemo-fileroller, tumbler, webkitgtk-6.0 (9) | none |
| `graphics-amd` ✓ | amd-ucode (core), mesa, mesa-utils, vulkan-mesa-layers, vulkan-radeon, vulkan-tools (6) | none |
| `graphics-nvidia` ✓ | lib32-nvidia-utils (multilib), libva-nvidia-driver, libva-utils, nvidia-open-dkms, nvidia-prime, nvidia-settings, nvidia-utils (7) | none |
| `hardware-tools` ✓ | evtest, fprintd, fwupd, linux-firmware (core), powertop (5) | none |
| `ocr` ✓ | tesseract, tesseract-data-chi_sim, tesseract-data-eng (3) | none |
| `recording` ✓ | ffmpeg, grim, gtk-layer-shell, gtk4-layer-shell, python-gobject, python-opencv, python-pillow, slurp, wf-recorder, wl-screenrec-git (archlinuxcn) (10) | none |
| `bluetooth` | blueman, bluez, bluez-utils (3) | blueman-session-owner (verify, physical), bluetooth-service (apply, physical) |
| `power` | power-profiles-daemon (1) | power-profiles-service (apply, physical) |
| `container-tools` | docker, docker-compose (2) | docker-service (apply, physical), docker-group-membership (manual, physical) |
| `kernel-support` | linux-headers (core), linux-zen-headers (2) | kernel-dkms-verification (verify, physical) |
| `storage-maintenance` | btrfs-assistant, grub-btrfs, inotify-tools, rsync, smartmontools, snapper (6) | snapper-configs (manual), snapper-timers (manual), grub-btrfs-recovery (deferred) |
| `virtualization` | dnsmasq, edk2-ovmf, libvirt, qemu-desktop, qemu-guest-agent, spice-vdagent, virt-manager (7) | libvirtd-service (apply), libvirt-default-network (apply), libvirt-group-membership (manual), virtualization-hugepages (deferred) |

Validation approach (one batch per group, mirroring `docs/vm-execution-plan-20260804.md`):

1. Batch software-only: `cli-tools`, `desktop-apps`, `ocr`, `recording`
   (37 packages, no physical-scoped actions). **COMPLETE (batch 2026-08-05):
   full nine-stage DAG passed in the VM, idempotent rerun, all 37 packages
   independently confirmed, evidence in
   `~/.local/state/my-archlinux-setup/vm-lab/20260805/`.**
2. Batch graphics (VM-safe package install only): `graphics-amd`,
   `graphics-nvidia`, `hardware-tools`, `kernel-support` — validate official
   package install; DKMS/GPU mode checks stay physical. **COMPLETE
   (batch 2026-08-06): full nine-stage DAG passed in the VM (after enabling
   the guest `[multilib]` repo and fixing the baseline's dangling pacman.conf
   `Include` warnings), idempotent rerun, all 20 packages independently
   confirmed, evidence in `~/.local/state/my-archlinux-setup/vm-lab/20260806/`.**
3. Batch services: `bluetooth`, `power`, `container-tools`, `storage-maintenance`,
   `virtualization` — package install plus the apply-class services
   (bluetooth.service, power-profiles-daemon, docker.service, libvirtd.service,
   default network) in a VM where the service controller exists, or record
   not-applicable where the hardware is absent.
4. Per batch: guest plan → full DAG apply → idempotent rerun → independent
   `pacman -Q` → evidence extraction → ACPI shutdown → `qemu-img check` →
   delete overlay → host promotion (readiness + modules.tsv) → test-suite update
   → commit.

Expected promotion effect after batch 3: registry 21 → 26 available;
execution readiness 21 → 26 available. Remaining after this: only the 2
`unavailable` modules (`dms-niri-greeter`, `dms-greetd`).

### B. System-action truth table for physical-scoped actions

The 5 remaining planning modules carry actions that are **physical-profile-scoped** and
therefore never ran in any VM. Before physical apply, each needs an explicit
disposition recorded (they already exist in `system-actions.tsv`; this section
tracks their validation status):

| Action | Module | Class | VM status | Physical requirement |
| --- | --- | --- | --- | --- |
| blueman-session-owner | bluetooth | verify | never ran | verify one Blueman owner at clean login |
| bluetooth-service | bluetooth | apply | not-applicable (no controller) | enable BlueZ daemon on physical profile |
| power-profiles-service | power | apply | not-applicable | single power policy owner on physical |
| docker-service | container-tools | apply | not-applicable | daemon enabled; group manual |
| docker-group-membership | container-tools | manual | never ran | explicit user consent, reversible |
| kernel-dkms-verification | kernel-support | verify | never ran | headers match detected kernels |
| snapper-configs | storage-maintenance | manual | never ran | separate create-config review |
| snapper-timers | storage-maintenance | manual | never ran | retention policy approval |
| grub-btrfs-recovery | storage-maintenance | deferred | never ran | manual boot-chain acceptance |
| libvirtd-service | virtualization | apply | not-applicable | enable libvirtd, qemu:///system |
| libvirt-default-network | virtualization | apply | not-applicable | default NAT network |
| libvirt-group-membership | virtualization | manual | never ran | explicit group consent |
| virtualization-hugepages | virtualization | deferred | never ran | workload-specific testing |

These are **documented dispositions, not VM claims**. They stay open until
physical apply.

### C. The four config-only available modules

`developer-editor`, `personal-scripts`, `asus-hardware`, `personal-user-services`
are registry-`available` but readiness-`planning` (usable via reviewed
config-only path). Full-DAG selection of each (package + config + actions) needs
a VM matrix pass before they can become readiness-`available`:

- `developer-editor`: Neovim config etc. (config-backed)
- `personal-scripts`: `~/scripts` payloads
- `asus-hardware`: asusd/supergfxd physical services (physical-acceptance manual)
- `personal-user-services`: user unit files

### D. Documentation drift fixes (found during this audit)

1. `README.md` module counts said "13 available / 17 planning" — fixed to
   "17 available / 13 planning" (commit pending with this doc).
2. Re-audit `docs/implementation-status.md` and `docs/workstation-packages.md`
   numbers after each promotion batch.

### E. Open decisions

1. Greeter/login-manager (`dms-niri-greeter`, `dms-greetd`) stays
   unavailable/deferred; SDDM rejected. No action planned.
2. Physical-host residual packages claude-code and
   intellij-idea-ultimate-edition remain installed on the host but are no longer
   in policy. Removal is a physical-host write action — deferred with the
   physical phase.
3. Hyprland noninteractive screenshot remains unavailable in the lab; retained
   as a limitation, never claimed as a visual pass.

## Definition of done for this phase

- The remaining 5 planning modules promoted to `available` (registry 26 available;
  execution readiness 26 available) with per-batch VM evidence in `vm-lab/` and
  plan documents.
- All four config-only available modules readiness-promoted after full-DAG VM
  selection.
- Physical-scoped action disposition table above verified against current
  `system-actions.tsv` and complete.
- All docs re-audited; no stale counts.
- Only then: physical-host deployment plan (separate, operator-approved).
