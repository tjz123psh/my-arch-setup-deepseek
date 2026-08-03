# Configuration audit disposition

This record translates private local audits into repository decisions. It
records categories and reasoning, never private report contents or hashes. The
primary decision is now faithful restoration of the user's same ASUS
workstation. Optional public/portable classifications are retained only as
secondary analysis and no longer define the copy boundary.

## Current mapped starter set

The mapped batch contains terminal profiles, Cava themes, Fcitx5/Rime defaults,
generic Fish startup, Fuzzel, GTK/Nemo styling, Mako, Starship, MPV, a
state-free DMS baseline and environment drop-in, generic Niri/Hyprland
baselines, and a sanitized Neovim setup.

The Neovim source audit covered 44 files, and all 44 current hashes matched the
private 2026-07-29 audit at import time. The repository includes 42 files:

- `lua/core/keymaps.lua` and `lua/plugins/dashboard.lua` use
  `vim.fn.stdpath("config")` instead of a home-relative config path;
- the personal `~/md` Telescope shortcut and matching cheatsheet entry are
  removed;
- the fixed Java 26/Maven `JavaInit` command, matching cheatsheet entry, and
  stale loader comment are removed;
- `JavaRun` now verifies required executables; and
- `colors/dms.lua` and `lua/lualine/themes/dms.lua` are excluded because they
  depend on deferred DMS/base46 integration.

## Scheduled for the faithful workstation pass

The goal is broad coverage of the live functional environment, not a small
publishable sample. Same-machine paths and ASUS-only settings are expected; the
remaining review asks whether a file is functional, what module owns it, what it
depends on, and whether it contains a real secret.

| Root | Required work before mapping |
| --- | --- |
| `niri/` | Map the complete functional compositor/DMS/output/helper set; exclude only ephemeral current window/workspace state by default. |
| `hypr/` | Map the complete functional compositor/DMS/output/autostart/helper set, including the current plain-session compensation. |
| `DankMaterialShell/` | Map settings, monitor geometry, functional generated fragments and the recorder plugin with its command dependency. |
| `fcitx5/` and Rime data | Reconcile both `.config` and `.local/share`; omit historical backups and regenerable caches. |
| `fish/` | Restore working personal startup/functions after checking only for credentials and missing command dependencies. |
| `matugen/`, `danksearch/`, `rog/` | Preserve target-machine paths, indexing roots and ASUS settings under explicit module ownership. |
| `systemd/user/`, `autostart/` | Preserve functional startup ownership while avoiding duplicate launches across Niri and Hyprland. |
| `cava/`, `mpv/`, `nemo/`, `paru/` | Compare current functional files with mapped rows and add missing dependency-owned files. |
| `~/scripts/` | Map required personal tools individually, preserving executable mode and documenting destructive/privileged behavior. |

## Authorized current-only review — 2026-07-30

An exact relative-path comparison found 25 live files absent from the mapped
payload: Niri 5, Hyprland 8, Fcitx5 2, and DankMaterialShell 10. The private
selected list and value-redacted content-risk report are mode `600` under the
project audit state directory. All 25 files were inspected; no source file was
copied or promoted by this review.

The earlier 5 `public-include` / 3 `sanitized-include` / 3 `template` / 14
`exclude` result answered a different question: whether each file suited a
portable public preset. It is retained in the final column as historical reuse
analysis. For this personal restorer, functional current files are copied as-is
unless they are credentials or obvious nonfunctional/transient artifacts.

`personal-include` below means a direct source candidate for the primary ASUS
restore profile, not that it is already mapped. Generated DMS compositor
fragments are included when they participate in the working session, even if
DMS may later regenerate them. Their module should deploy them in the correct
order and accept later DMS ownership. Helper commands remain explicit
configuration because this is the user's workstation; their dependency and
executable modes must still be recorded.

| Live relative path | Personal restore | Optional portability history | Reason |
| --- | --- | --- | --- |
| `.config/DankMaterialShell/.changelog-1.4` | `default-exclude` | `exclude` | Empty generated migration marker. |
| `.config/DankMaterialShell/.changelog-1.5` | `default-exclude` | `exclude` | Empty generated migration marker. |
| `.config/DankMaterialShell/firefox.css` | `personal-include` | `exclude` | Functional DMS browser-theme bridge for this environment; actual browser profiles remain excluded. |
| `.config/DankMaterialShell/.firstlaunch` | `default-exclude` | `exclude` | Empty local first-run marker, not functional configuration. |
| `.config/DankMaterialShell/monitors.json` | `personal-include` | `template` | Working host/output geometry is desired on the same ASUS workstation. |
| `.config/DankMaterialShell/plugins/ShorinScreenrec/plugin.json` | `personal-include` | `public-include` | Recorder plugin metadata; deploy with its command dependency. |
| `.config/DankMaterialShell/plugins/ShorinScreenrec/ShorinScreenrecSettings.qml` | `personal-include` | `public-include` | Functional plugin settings UI. |
| `.config/DankMaterialShell/plugins/ShorinScreenrec/ShorinScreenrecWidget.qml` | `personal-include` | `public-include` | Functional widget logic; deploy with its command dependency. |
| `.config/DankMaterialShell/plugins/ShorinScreenrec/StartupCheck.qml` | `personal-include` | `public-include` | Functional dependency-presence check. |
| `.config/DankMaterialShell/settings.json.bak-screenrec` | `default-exclude` | `exclude` | Historical generated backup, superseded by the active settings source. |
| `.config/fcitx5/conf/cached_layouts` | `default-exclude` | `exclude` | Regenerable keyboard-layout cache. |
| `.config/fcitx5/conf/classicui.conf.bak-20260630-dms-theme` | `default-exclude` | `exclude` | Historical backup superseded by active Fcitx5 configuration. |
| `.config/hypr/conf/autostart.lua` | `personal-include` | `sanitized-include` | Proven plain-Hyprland startup compensation and personal application startup. |
| `.config/hypr/dms/layout.lua` | `personal-include` | `exclude` | Generated but functional DMS/Hyprland layout for the current session. |
| `.config/hypr/dms/outputs.lua` | `personal-include` | `template` | Working host display/output binding is wanted on the same machine. |
| `.config/hypr/dms/windowrules.lua` | `default-exclude` | `exclude` | Empty generated fragment; include later if it gains functional content. |
| `.config/hypr/keybinds.list` | `personal-include` | `sanitized-include` | Current shortcut data belongs with the commands it documents. |
| `.config/hypr/scripts/fake-overview.sh` | `personal-include` | `sanitized-include` | Existing helper is part of the working environment; optional hardening is not a copy blocker. |
| `.config/hypr/scripts/hypr-force-kill-window` | `personal-include` | `exclude` | Intentional user helper; preserve executable mode and document `SIGKILL` behavior. |
| `.config/hypr/scripts/hypr-keys` | `personal-include` | `public-include` | Read-only shortcut viewer used by the current environment. |
| `.config/niri/dms/binds.kdl` | `personal-include` | `exclude` | Generated but functional DMS keybindings for the current Niri session. |
| `.config/niri/dms/outputs.kdl` | `personal-include` | `template` | Working Niri output names, modes, positions and refresh values are desired. |
| `.config/niri/dms/wpblur.kdl` | `personal-include` | `exclude` | Generated but functional DMS wallpaper-blur fragment. |
| `.config/niri/layouts/current.json` | `default-exclude` | `exclude` | Ephemeral workspace/window-title session state. |
| `.config/niri/scripts/niri-force-kill-window` | `personal-include` | `exclude` | Intentional user helper; preserve executable mode and document `SIGKILL` behavior. |

Personal restore totals are 17 `personal-include` and 8 `default-exclude`.
These totals are a decision for this exact 25-file difference only, not the full
workstation manifest. The next pass must inventory the other functional roots
and then add explicit module-owned mappings rather than copying all of `$HOME`.

## Default exclusions

Actual credentials, private keys, tokens, cookies, NetworkManager secrets,
browser/chat account profiles, machine identity, unrelated databases and
regenerable caches remain outside automatic restoration. Historical backups,
empty markers and ephemeral layout/session state are excluded by default, not
because they are “too private” but because they are not needed to recreate the
functional environment. No whole-home or whole-`.config` deployment exists;
each future file still needs an intentional module owner and copy mapping.
