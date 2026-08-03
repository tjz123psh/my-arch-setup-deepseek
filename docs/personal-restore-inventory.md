# Personal same-machine restore inventory

Status date: 2026-08-01
Source: the normally running ASUS workstation
Apply authorization: none

## Product boundary

This is the user's own Arch reinstall/restoration project. The live host is the
golden functional source. Machine-specific paths, output names, display modes,
ASUS settings and personal helpers are valid restore data.

The project still excludes actual credentials, private keys, `.ssh`, nested
`.git` internals, NetworkManager secrets and unrelated account/browser data.
It does not reject a reviewed functional file merely because it contains a
personal path or host-specific value.

## Executable mapping now

The executable `physical-v1` mapping contains 162 files:

| Owner | Files |
| --- | ---: |
| Shared desktop, including DMS user config and shared desktop helpers | 37 |
| Fcitx5/Rime input configuration | 7 |
| Neovim/editor | 42 |
| Niri | 15 |
| Hyprland | 16 |
| Personal scripts | 39 |
| User systemd unit files (restored only, not enabled) | 4 |
| Personal autostart entry | 1 |
| Same-ASUS ROG user config | 1 |

A separate `vm-v1` validation scope contains 36 rows: 27 shared, 7 input,
one Niri and one Hyprland. It does not replace or dilute the physical inventory;
it provides a minimal, auditable graphical VM payload. Across both scopes the
mapping manifest therefore has 198 rows.

The 77 reviewed functional live-only files have been promoted:

- DMS/DMS-adjacent shared desktop and Rime: 13;
- shared desktop helpers/library: 4;
- Hyprland config/scripts: 9;
- Niri config/scripts: 6;
- reviewed personal scripts: 39;
- personal autostart: 1;
- same-ASUS ROG user config: 1;
- user systemd unit files restored without enabling/starting: 4.

Executable helper scripts retain mode `755`; two reviewed documentation/prompt files preserve live mode `744`; private Fcitx5 files keep mode
`600`; other reviewed config generally uses `644`. Tests enforce exact paths,
owners and modes. DMS user files are owned by `desktop-shared`; greetd/greeter
is not required for their restoration.

## Default nonfunctional exclusions

These eight files remain excluded because they are empty, historical, cached or
ephemeral—not because ordinary personal configuration is considered private:

```text
.config/DankMaterialShell/.changelog-1.4
.config/DankMaterialShell/.changelog-1.5
.config/DankMaterialShell/.firstlaunch
.config/DankMaterialShell/settings.json.bak-screenrec
.config/fcitx5/conf/cached_layouts
.config/fcitx5/conf/classicui.conf.bak-20260630-dms-theme
.config/hypr/dms/windowrules.lua
.config/niri/layouts/current.json
```

## Broader metadata inventory

`manifests/personal-config-candidates.tsv` contains 77 rows. All 77 are
`personal-include` / `reviewed-functional` rows and have executable mappings.
There are no metadata-only candidate rows left. The final promotion covered:

- `.config/autostart/FlClash.desktop`;
- `.config/rog/rog-control-center.cfg`;
- `.config/systemd/user/{openai-oauth,penpot-mcp,vellum-tray,vellum}.service`.

Those user service files are restored as files only; the installer does not
enable or start them and does not copy the referenced `%h/.codex/auth-k12.json` secret.

Additional observed roots include autostart, user systemd, Matugen, Danksearch,
ROG, DMS helpers and 39 Rime data/config files. Generated Rime builds, learned
user databases and sync identity need separate treatment from authored YAML.

The personal script tree should be restored from reviewed working-tree files or
its source repository, never by copying Git object/index state. Executable modes
must be preserved and each script should be assigned to its functional module.
Hard-coded same-machine paths are acceptable; real secrets and destructive or
missing dependencies remain review blockers.

## Deployment guarantees

For every executable mapping:

- Niri-only excludes Hyprland rows;
- Hyprland-only excludes Niri rows;
- both WMs deploy shared rows once and both WM sets;
- source modes are restricted to reviewed `600`, `644`, `744` or `755`;
- existing content or mode drift is backed up before replacement;
- unrelated files remain untouched;
- symlinked/hard-linked/non-regular targets are rejected.

## Remaining evidence

The physical personal-config review is complete for the current 77-row set and
the dedicated VM mapping is implemented. The candidate and clean canonical VM
matrices exercised all three WM selections, config idempotence/restore, reboot
and real graphical session ownership; the fresh rollback probe found no mapping
residue in the immutable baseline. Same-ASUS GPU/display, Bluetooth/real-audio,
suspend/resume and boot/recovery remain physical acceptance.
