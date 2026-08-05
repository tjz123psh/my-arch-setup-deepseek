# Project vision & agreed decisions

Status: current. This document records the product decisions agreed with the
operator (2026-08-05), so any future session or reader has a single source of
truth for *why* this repository looks the way it does. It complements
`README.md` (usage) and `AGENTS.md` (working rules).

## 1. Positioning

This is a **personal Arch Linux restore tool** for the operator's own ASUS
AMD + NVIDIA workstation. It is not a general-purpose distribution installer
and it is not an audited/reproducible engineering system.

| Decision | Value |
| --- | --- |
| Audience | the operator only (single machine, ASUS-specific) |
| Trigger | after a manual Arch reinstall reaches the handoff point (partitioning, base install, GRUB, first boot, networking) |
| Goal | `git clone && cd && ./install.sh` restores the full desktop (Niri/Hyprland, packages, AUR, personal config, services) |
| Success criterion | from a fresh archinstall to a working desktop with one command |
| Reference | the host machine's current state is the target snapshot; the old notes document is history only, not the spec |

## 2. Design principles (agreed)

1. **Simple first, personal only.** The installer is `strap.sh` + `install.sh`
   + `scripts/01-09` reading three slim manifests. No review engine, no hash
   pins, no module-readiness tiers (these were removed from the previous
   engineering-era design).
2. **Drivers before desktop.** A dedicated driver step (04-drivers) installs
   AMD/NVIDIA/ASUS-control packages *before* the desktop step, to avoid
   rendering bugs. This was an explicit operator requirement.
3. **AUR is fully automatic.** All 14 AUR recipes build from their real
   upstream sources (makepkg downloads them); no private-source cache dance
   for paru/linuxqq/wechat. The old local-fixed mechanism was removed.
4. **Host state is the snapshot.** The package list, config mappings and
   recipes were captured from the real ASUS machine and the installer
   reproduces that state.
5. **greetd login, not SDDM.** greetd + dms-greeter auto-login into niri
   (switching to hyprland possible); SDDM-related pieces were deleted.
6. **Services mirror the host.** bluetooth, power-profiles, docker, libvirtd,
   NetworkManager, grub-btrfsd, paccache.timer, snapper-cleanup.timer are
   enabled on physical; clash-verge is *installed but not enabled* (config is
   private). libvirt-docker-forward is a host-maintained custom service and is
   intentionally not managed by the installer.
7. **System settings.** locale zh_CN+en_US, timezone Asia/Shanghai, hostname
   default (archlinux), zram with zstd.
8. **Boundaries (never touched).** partitioning, formatting, pacstrap, GRUB
   install and `grub-mkconfig`, kernel selection, initramfs, credentials
   (SSH/GPG/tokens/passwords). GRUB *theme* deployment (files + `GRUB_THEME`
   in `/etc/default/grub`) IS managed, because it is a config asset; applying
   it still requires the operator's manual `grub-mkconfig` afterwards.

## 3. Validation workflow (agreed)

- Each validation round uses a **fresh disposable VM + `git clone` of the
  latest remote code** (never a mutated test VM).
- The operator runs their own VM acceptance; the agent validates first
  (vm mode then physical mode) and fixes issues found.
- Physical mode is exercised in a VM (`-t physical`) so the code path (drivers,
  physical services) is tested without needing the real machine; final
  physical acceptance still happens on the real ASUS host later.

## 4. Known test gaps (honest record)

- Fresh-install database staleness: `ensure_fzf` now syncs (`pacman -Sy`)
  before installing fzf, because a brand-new install's local database points
  at versions the mirrors already pruned (404). Test baselines had newer
  databases and missed this; the operator's fresh VM exposed it (fixed in
  f90e47f).
- libfakeroot `payload not recognized!` during AUR builds is a known-harmless
  upstream warning; builds complete and packages install correctly.
