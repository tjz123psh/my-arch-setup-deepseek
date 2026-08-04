# Physical host deployment plan (ASUS, 2026-08-04)

Status: **DRAFT — read-only inventory complete; no apply authorized.**

This document is the operator-facing plan for running the reviewed nine-stage
orchestrated DAG on the physical ASUS host. It follows the project boundary:
no package, repository, service, `/etc`, boot, disk or real-HOME change is
performed from this document. Every step below executes only after explicit
operator approval per stage.

## 0. Current verified state (read-only inventory, 2026-08-04)

All inventory commands below were read-only; nothing was modified.

| Area | Observed | Note |
| --- | --- | --- |
| OS / kernel | Arch Linux, `7.1.5-zen1-2-zen` | zen kernel, dual-kernel baseline expected |
| Hardware | ASUS notebook: NVIDIA RTX 4050 + AMD Radeon 680M, Realtek RTL8852BE | matches `asus-amd-nvidia` profile |
| Storage | nvme0n1 476.9G: p1 200M vfat, p2 16M, p3/p4/p5 NTFS (Windows), p6 977M vfat `/boot`, p7 149G btrfs `/home`; zram0 14.9G swap | boot and home separated |
| Locale | `/etc/locale.conf`: `LANG=zh_CN.UTF-8 LC_CTYPE=en_US.UTF-8`; locale.gen has en_US.UTF-8 + zh_CN.UTF-8 | already the target of `locale-zh-cn` |
| GPU mode | `supergfxctl -g` → `Hybrid` | `supergfxd-physical-service` is manual; current mode already Hybrid |
| Explicit packages | 185 = 170 sync + 15 AUR | see reconciliation below |
| User groups | `pang : wheel greeter docker libvirt` | docker/libvirt groups already present |
| Enabled system units | bluetooth, clash-verge-service, docker, getty, greetd, grub-btrfsd, libvirt-docker-forward, libvirtd, NetworkManager×4, power-profiles-daemon, supergfxd, systemd-timesyncd | 14 units; most match target apply actions (idempotent) |

### Package reconciliation (host vs repository)

| Bucket | Count | Detail |
| --- | ---: | --- |
| sync packages on host | 170 | exactly equals repository inventory sync set — **0 difference** |
| AUR on host | 15 | equals repository 13 + **claude-code, intellij-idea-ultimate-edition** (removed from repo 2026-08-04 but still installed on host) |
| repo inventory | 183 | 170 sync + 13 AUR |
| repo policy rows | 203 | 183 current + 20 confirmed desired |

Decision needed (below, D1): keep or remove `claude-code` and
`intellij-idea-ultimate-edition` on the physical host. The repository no longer
manages them; a full DAG apply does not touch them either way (they are not in
any managed module), so the decision only affects host cleanliness.

## 1. Deployment scope

Target: full orchestrated nine-stage DAG on profile `asus-amd-nvidia`
(full-orchestrator.py), matching the exact reviewed effect set:

| Stage | Effects | Note |
| --- | ---: | --- |
| privilege-wrapper | 2 | gsudo + fuzzel-askpass deployment |
| official-update | 1 | full `pacman -Syu` boundary |
| official-packages | 162 | official install candidates |
| archlinuxcn-bootstrap | 1 | keyring bootstrap |
| archlinuxcn-packages | 8 | archlinuxcn candidates |
| aur-source-acquisition | 13 | AUR source verification (3 local-fixed cached + 10 remote-fixed) |
| aur-build-install | 13 | clean-chroot builds + install |
| user-config | 169 | physical-v1 config mappings |
| system-actions | 47 | apply/verify/manual/deferred physical actions |
| **Total** | **416** | plan rc=0, no apply blockers |

The plan is currently clean: `non_executable_modules` empty,
`missing_adapter_stages` empty, `non_integrated_stages` empty,
`noncanonical_adapter=False`.

## 2. Execution sequence (each stage gated by approval)

1. **Pre-flight** (read-only): re-run the inventory above; confirm host matches
   the baseline (no new packages/services since this plan was written).
2. **DAG apply** (`--mode new --apply` with the three confirmations):
   ```
   cd /home/pang/Projects/my-arch-setup-deepseek
   python3 installer/full-orchestrator.py --profile asus-amd-nvidia \
     --mode new --apply \
     --confirm-system-changes --confirm-archlinuxcn --confirm-aur
   ```
   The orchestrator persists run-state under
   `~/.local/state/my-archlinux-setup/full-orchestrator/runs/` and enforces
   fail-closed preflight checks at every stage.
3. **Per-stage verification**: after each of the nine stages completes, record
   its exit status and the run.log stage-passed events; any failure stops the
   run (no ad-hoc host fix without a revised plan).
4. **Idempotent rerun**: `--rerun --apply` with confirmations; all targets must
   report `up to date -- skipping` (artifact hashes unchanged).
5. **Independent verification**: `pacman -Q` for the 183 managed explicit
   packages; `systemctl status` for the apply-class services; config file
   checks for deployed mappings; manual-action checklist (below).

## 3. Manual / deferred actions (not executed by apply)

These are recorded by the orchestrator as `manual` or `deferred`; they require
separate operator action and acceptance:

| Action | Kind | Physical acceptance required |
| --- | --- | --- |
| `supergfxd-physical-service` | manual | hybrid GPU reboot output, suspend/resume |
| `docker-group-membership` | manual | group membership + `docker info` after relogin |
| `libvirt-group-membership` | manual | group membership + virt-manager connection after relogin |
| `physical-hardware-acceptance` | manual | GPU, display, audio, bluetooth, AC/battery, suspend, ASUS controls (each separately recorded) |
| `grub-btrfs-recovery` | deferred | bootable snapshot menu + recovery; never run grub-mkconfig in this workflow |
| `virtualization-hugepages` | deferred | workload-specific hugepage tuning stays out of generic restore |
| `greeter-login-manager` | deferred | greetd/SDDM changes stay outside this release |

## 4. Rollback

- Orchestrator run-state and per-stage logs are written under
  `~/.local/state/my-archlinux-setup/`; the previous host state (package list,
  enabled units, config files) is captured in this inventory and in the run
  preflight, enabling per-module restore.
- Service actions restore "recorded enabled and active booleans" — they never
  remove BlueZ paired devices, Docker data, libvirt volumes/networks or locale
  files (per manifest semantics).
- Boot chain (`grub-mkconfig`, GRUB install, kernel selection) is never touched
  by the one-click workflow; snapshot boot menu and recovery are deferred to
  manual acceptance.
- The physical host's existing Windows partitions and `/home` are never
  modified by the DAG (no disk/partition operations exist in any stage).

## 5. Open decisions for the operator

- **D1**: keep or remove the two host AUR packages no longer in the repository
  (`claude-code`, `intellij-idea-ultimate-edition`). Remove requires a separate
  approved `pacman -R` (write operation, outside this plan).
- **D2**: approve the exact stage gating — run all nine stages in one approved
  session, or stop after `official-packages` / `user-config` for review
  before AUR build-install and system-actions.
- **D3**: confirm the 5 host-only sync packages adopted into the policy
  (polkit-gnome, qemu-guest-agent, spice-vdagent, sysbench, ydotool) are wanted
  as managed targets (they are already installed; apply is idempotent for them).
- **D4**: approve manual-action acceptance order and who records the
  physical-hardware-acceptance items.

## 6. Definition of done

- Nine-stage DAG rc=0 with stage-passed events for every stage; idempotent
  rerun with zero rebuilds.
- `pacman -Q` shows all 183 managed explicit packages; apply-class services
  enabled and active; deployed config mappings byte-match repository content.
- Manual/deferred items either accepted with recorded evidence or explicitly
  deferred with reason.
- Nothing outside the plan was modified; no force-push, no host `/etc`/boot
  edits beyond the reviewed DAG stages.
