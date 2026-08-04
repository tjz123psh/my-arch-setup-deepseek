# Complete workstation package inventory and reconciled restore policy

Status date: 2026-08-02
Scope: golden-host observation, reconciled target policy, and review-gated trust-stage adapters

## User-confirmed rule

The personal one-click restore must cover the user's complete retained software
set, not only compositor, Portal, audio and hardware packages. Package behavior
is explicit:

- **package-only** installs the declared application/tool without copying its
  account, cache or profile; QQ, WeChat, Obsidian and Chrome are locked examples;
- **config-backed** installs the declared package and waits for its reviewed
  package/config relation before deploying mappings;
- **manual-precondition** verifies the package supplied by the manual base/boot/
  network handoff without taking ownership;
- **deferred** remains visible but is never installed by the current release.

Pacman official repositories, explicitly bootstrapped archlinuxcn and fixed
reviewed AUR recipes are separate trust domains. Their adapters are routed by
the canonical nine-stage DAG and auxiliary-input fingerprint. All nine stage flags
and only five module-registry availability fields were promoted by the VM
candidate cycle. Full-DAG authority is separate:
`production-module-readiness.tsv` marks exactly 9 modules available, 21 planning
and 2 unavailable, and its digest is part of every plan. Wiring, config-surface
availability or a true stage flag alone never authorizes a production-planning
selection.

## Immutable observation snapshot

`manifests/workstation-package-inventory.tsv` remains the exact dated observation
and is never direct apply input. Its successful capture contains 183 explicit
packages:

```text
pacman -Qqe   -> exit 0, 183 explicit packages
pacman -Qqen  -> exit 0, 170 sync-database packages
pacman -Qqem  -> exit 0, 13 packages absent from sync databases
pacman -Si    -> all 170 repository metadata queries succeeded
paru -Sia     -> all 13 non-sync packages were found in AUR
```

| Observed repository/channel | Count |
| --- | ---: |
| core | 13 |
| extra | 146 |
| multilib | 1 |
| archlinuxcn through pacman | 10 |
| AUR | 13 |
| **Total** | **183** |

A fresh read-only 2026-08-01 comparison reran `pacman -Qqe`, `-Qqen`, `-Qqem`
and `-Q`, all with exit `0`. It found zero missing names, extra names, version
mismatches or observed pacman/AUR channel mismatches. `pacman -Sl` for all four
configured repositories and individual `paru -Sia` for all 13 foreign packages
also exited `0`, with zero source mismatches. These are rolling-version facts,
not version pins.

## Reconciled target policy

`manifests/workstation-packages.tsv` is the separate target ledger. It has 203
unique package rows:

| Origin | Count |
| --- | ---: |
| exact current explicit observation | 183 |
| confirmed desired non-explicit requirement | 20 |
| **Total** | **203** |

The 20 non-explicit rows are requirements supported by the manual, reviewed
configuration, Phase C decisions and current installed/dependency state:

```text
alsa-ucm-conf bash bluez-utils coreutils devtools ffmpeg gawk hyprland libnotify
mesa pipewire-audio python-gobject ripgrep sed ttf-jetbrains-mono-nerd
udisks2 wf-recorder xdg-desktop-portal xdg-desktop-portal-gtk
xdg-desktop-portal-hyprland
```

Responsibility and execution policy now reconcile to:

| Responsibility | Count | Policy |
| --- | ---: | --- |
| package-only | 158 | install |
| config-backed | 26 | install after package/config relation checks |
| manual-precondition | 18 | verify only |
| deferred | 1 | never install in this release |
| **Total** | **203** | 184 install / 18 verify / 1 deferred |

Every row has an exact target channel/repository, acquisition method, functional
module, responsibility, policy, evidence origin and purpose. The default ASUS
policy's 184 install rows split into non-overlapping trust stages:

```text
official pacman install:          157
archlinuxcn keyring bootstrap:      1
already-trusted archlinuxcn:        8
fixed Paru bootstrap:               1
declared fixed AUR recipes:        12
```

The current host's Paru was observed in archlinuxcn, but the confirmed target
uses a fixed AUR bootstrap. The only allowed source transition is recorded in
`manifests/package-source-transitions.tsv`; no other observed source may change
without a new reviewed transition.

## Closed provider and stale-starter decisions

`manifests/provider-decisions.tsv` prevents guessed fallbacks:

- AUR `fuzzel-ime-git` is the exclusive selected Fuzzel provider; official
  `fuzzel` is rejected rather than silently substituted.
- DMS is the selected notification owner; absent-host `mako` is rejected. Mako
  was removed from the executable official starter and its orphan config mapping
  and payload were removed.
- SDDM remains rejected as an automatic fallback.
- the observed rolling `greetd-dms-greeter-git` source is rejected; the one
  deferred package row never enters an AUR install bucket while a fixed greeter
  source remains unresolved.

The 26 config-backed packages all have a machine-checked relation in
`manifests/package-config-relations.tsv`. Relations distinguish owner, consumer,
runtime dependency and optional enhancement and must match at least one reviewed
same-module mapping. Fcitx/Rime is now its own `input-fcitx-rime` module rather
than being inseparable from generic shared desktop configuration.

### Package-only daily applications

The target policy retains at least:

```text
linuxqq-appimage wechat-appimage obsidian-bin google-chrome
```

No QQ/WeChat login state, browser profile, Obsidian application state or vault is
mapped. The vault is user data handled by independent backup/restore policy.

### Config-backed package set

The 26 rows are:

```text
alacritty cava dgop dms-shell dsearch-bin
fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-rime
fcitx5-skin-fluentdark-git fish flclash-bin fuzzel-ime-git hyprland
kitty matugen mpv neovide neovim niri quickshell
rime-ice-git rime-wanxiang-gram-zh-hans rog-control-center starship
```

This does not authorize a blind `.config` copy. Each package is tied to an
explicit relation and selected-module mapping.

## Review tools and current safety boundary

Render the complete target policy with:

```bash
python installer/workstation-package-plan.py
python installer/workstation-package-plan.py --json
```

The authoritative integrated plan is:

```bash
python installer/full-orchestrator.py --profile asus-amd-nvidia --plan --json
```

It derives all 162 official, one bootstrap, eight archlinuxcn and 13 AUR effects
from the same 203-row snapshot and shows the canonical executable/input
fingerprints. Current safety remains explicit: the nine stage integrations are
true, but the default full ASUS policy still resolves unproved `planning`
modules and is blocked before preflight. The exact VM Niri/Hyprland/both
selections have no apply blockers. The legacy `install.sh --plan` is only a
compatibility view and its changing actions are disabled outside tests.

`installer/archlinuxcn-plan.py` separately validates the pinned keyring asset,
detached signature fingerprint, exact HTTPS mirror/template and current target
state. On the current golden host it exits `1` / `blocked`, because the existing
manual archlinuxcn section inherits `SigLevel` instead of being an absent or
exactly managed section. That is review evidence, not permission to overwrite it.

The declared AUR path is now machine-reviewable in four separate adapters:

```bash
python installer/aur-plan.py --json
python installer/aur-source-acquire.py --json
python installer/aur-build.py --json
python installer/aur-install.py --json
```

`aur-recipes.tsv` pins 14 regular recipes plus the Paru bootstrap by pkgbase,
AUR commit and full recipe-tree SHA-256. Remote-only recipes are `static-ready`,
not apply-ready, until `makepkg --verifysource` succeeds. Paru uses a reviewed
libalpm-16 lock and deterministic offline vendor archive; LinuxQQ and WeChat
have private cache acquisition preconditions. Build policy requires the newly
confirmed official `devtools` package, an official-only clean chroot containing
`base-devel` + `rust`, an unprivileged build user, exact artifact identity/hash/
file-root checks, and the audited `gsudo` wrapper. Installation re-verifies
artifact hashes, refuses automatic downgrades, records private provenance and
requires independent AUR plus system-change confirmation. Mock failure-path regressions pass. Real clean-chroot evidence repeatedly built
and installed the three exact VM-selected recipes; the other 10 recipes were not
selected and are individually asserted behind production-planning module gates
and any private-cache prerequisite. This includes `flclash-bin`: its
`personal-autostart` config surface is reviewed, but its complete AUR/config
effects are not production-ready.

The historical `official-packages.tsv` component manifest remains a narrow alpha
fixture and is not the complete package policy. Production effect derivation uses
`workstation-packages.tsv`; canonical official, archlinuxcn and AUR adapters are
connected to `full-orchestrator.py`. Snapshot-backed candidate/canonical evidence
and the post-review final-tree both-WM spot run are complete only for the exact VM
selection; a full ASUS plan remains blocked and requires separate physical/full-
policy evidence plus approval.

## Remaining package gates

1. Keep the 12 non-VM-selected AUR recipes and their owning modules
   production-planning until exact source/cache, clean-chroot, artifact and
   runtime evidence exists. The regression enumerates every recipe/module pair;
   LinuxQQ and WeChat private acquisition prerequisites remain explicit.
2. Preserve active repository identity, full-update implications, sizes,
   conflicts and prior state in every exact physical plan; no arbitrary package
   or fallback path is permitted.
3. Treat the completed three-scenario VM matrix as proof only for its exact
   selected effects. It does not authorize the full ASUS preset, physical
   services, hardware modules or a host apply.
