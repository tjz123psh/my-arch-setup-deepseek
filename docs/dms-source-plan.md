# DMS shell and greeter source plan

Status date: 2026-07-30  
Scope: read-only, non-executable planning

## Boundary

Official shell choice is confirmed. Current Arch sync databases contain
`dms-shell`, `dms-shell-niri` and `dms-shell-hyprland` in `extra`, and the live
workstation runs the official shared shell plus the Hyprland selector. This is
strong evidence for replacing the old custom shell-build assumption, and the
user has explicitly accepted these official rolling shell packages.

Greeter remains independently blocked. The live `dms-greeter` binary is owned
by a foreign rolling `greetd-dms-greeter-git` package whose local metadata
reports no validation. A working login does not make that package reproducible
or acceptable for the installer.

No executable module is unlocked by this plan. `dms-greetd` and
`dms-niri-greeter` remain unavailable, and neither this document nor its
candidate manifest is read by `installer/install.sh`.

No system changes were performed.

## Confirmed source decision

Use the signed Arch official packages for the DMS user shell and compositor
selectors:

- `dms-shell` as the shared shell;
- `dms-shell-niri` only when DMS is selected with Niri but no Hyprland; and
- `dms-shell-hyprland` whenever Hyprland is selected.

This follows the existing official rolling-package policy used for Niri,
Hyprland and the rest of Arch. Shell packages use the normal
official-package confirmation and no DMS source-build authorization or custom
clean chroot. Package source and membership are still refreshed before apply.

The fixed-source/clean-chroot requirement remains for the DMS greeter until a
non-rolling source, hash, recipe, expected files and package validation are
reviewed. The installer never falls back to the current `-git` package, a remote
installer or SDDM.

## Selector rules

### Niri-only selector

For DMS + Niri without Hyprland, plan `dms-shell` with `dms-shell-niri`. The
selector has no payload but satisfies the official shell's
`dms-shell-compositor` dependency and ensures Niri is present.

### Hyprland selector

For DMS + Hyprland, plan `dms-shell` with `dms-shell-hyprland`. The selector has
no payload, satisfies the same virtual dependency and ensures Hyprland is
present.

### Both-WM selector requires VM proof

The live both-WM workstation has only the Hyprland selector installed and DMS
works in the active Niri session. This supports using the Hyprland selector for
the both-WM case, matching the confirmed “Hyprland adds its package” model.
However, a clean VM must prove Niri and Hyprland login/session behavior before
that rule becomes executable. Installing both zero-payload selectors is not
chosen without evidence that it is needed.

## Future module split

The current `dms-greetd` placeholder combines user shell intent with login
system changes. With the shell source confirmed, implementation should separate:

1. an official `dms-shell` user-session module with selected-WM package logic,
   user config ownership and `dms.service` post-checks; and
2. the still-blocked `dms-greetd` login module with fixed greeter package,
   `/etc/greetd` files, greeter user/runtime setup and service enablement.

Current DMS user configuration cannot move automatically. Ten current-only DMS
files remain subject to file-level privacy/generated-file disposition review.

## Verification and recovery

Official shell post-checks eventually include package source, selected provider,
`dms.service` ownership, `graphical-session.target`, D-Bus notification
ownership, DMS IPC and one startup owner in each selected WM.

Greeter checks eventually include artifact hash/file list, dedicated user and
cache permissions, reviewed Niri greeter config, greetd config backup, login to
each selected session, first-session Niri behavior and last-session memory.

Shell failure must not disable an existing login path. Greeter/greetd apply
captures prior unit/config state and stops before service enablement if package,
config or user-runtime verification fails. There is no automatic SDDM install
and no automatic package rollback.

## Confirmed decision

Arch official rolling `dms-shell` and selector packages supersede the
fixed-source build requirement for the user shell. This decision does not
authorize or unblock any DMS greeter source.
