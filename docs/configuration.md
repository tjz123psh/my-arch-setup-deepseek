# Approved personal-workstation configuration mapping

The restorer deploys only explicitly reviewed files for the same-user physical
workstation or its dedicated validation VM. Machine-specific values are allowed
in `physical-v1` when they are part of the working ASUS setup; credentials,
private keys, cookies, account profiles and network secrets remain excluded.

The schema-2 source of truth is `manifests/config-mappings.tsv`. Each row binds
one configuration scope, module, repository-relative regular-file source and
HOME-relative target. The current set contains 198 files: 162 in `physical-v1`
and 36 in `vm-v1`. Source/target uniqueness is enforced per scope, so a reduced
VM payload may deliberately target the same HOME-relative path as its physical
counterpart without sharing the same source file.

## Scope ownership

| Module | `physical-v1` | `vm-v1` | Total |
| --- | ---: | ---: | ---: |
| `desktop-shared` | 37 | 27 | 64 |
| `input-fcitx-rime` | 7 | 7 | 14 |
| `developer-editor` | 42 | 0 | 42 |
| `wm-niri` | 15 | 1 | 16 |
| `wm-hyprland` | 16 | 1 | 17 |
| `personal-scripts` | 39 | 0 | 39 |
| `personal-user-services` | 4 | 0 | 4 |
| `personal-autostart` | 1 | 0 | 1 |
| `asus-hardware` | 1 | 0 | 1 |
| **Total** | **162** | **36** | **198** |

The physical scope includes a 42-file Neovim configuration, complete reviewed
DMS user state, Fcitx5/Rime, independent Niri and Hyprland boundaries, personal
scripts, one autostart entry, ASUS user configuration and user unit files. DMS
user configuration belongs to `desktop-shared`; greeter/login-manager setup is
not part of either scope.

The VM scope is a deliberately reduced graphical regression payload. It reuses
reviewed shared and Rime sources where appropriate and owns four VM-specific
files under `config/vm/home/`:

```text
.config/DankMaterialShell/settings.json
.config/fuzzel/fuzzel.ini
.config/hypr/hyprland.lua
.config/niri/config.kdl
```

## Selection results

For `physical-v1`:

- shared + input + editor + Niri: 101 targets;
- shared + input + editor + Hyprland: 102 targets;
- shared + input + editor + both WMs: 117 targets;
- previous row + `personal-scripts`: 156 targets;
- ASUS defaults with all reviewed physical personal modules: 162 targets;
- generic AMD defaults with input disabled: 94 targets.

For `vm-v1`:

- default/Niri-only: 35 targets;
- explicit Hyprland-only: 35 targets;
- both WMs: 36 targets.

Niri-only never deploys a Hyprland-owned row and Hyprland-only never deploys a
Niri-owned row. Selecting both writes shared/input rows once and adds both WM
files. The VM DMS settings are a minimal regression configuration, not evidence
that graphical login or DMS runtime acceptance has passed.

## Runtime deployment contract

`installer/config-stage-apply.py` handles the `privilege-wrapper` and
`user-config` DAG stages. It accepts only the fingerprint-bound environment from
`installer/full-orchestrator.py`; it is not an arbitrary copy interface.

- `preflight` validates manifests, exact effects, source hashes/modes, HOME,
  target parents and current target type without creating target or state paths.
- `execute` backs up every changed existing target before an atomic replacement,
  records private mode-`600` provenance, and leaves exact matches unchanged.
- `verify` returns `1` for deterministic missing/content/mode drift and preserves
  inspection/query failures separately instead of calling them healthy.
- Symlinks, hard-linked files, non-regular files, unsafe owners/parents, source
  drift and targets outside the approved HOME roots fail closed.
- Repository source modes are restricted to reviewed `600`, `644`, `744` or
  `755`; deployment restores the reviewed source mode.

The explicit `privilege-wrapper` stage deploys only
`scripts/desktop/{gsudo,fuzzel-askpass}` before any root-requiring stage. There is
no `sudo` fallback. `gsudo` checks only for `sudo` before dispatch, allowing a
clean-base NOPASSWD policy to proceed before the selected AUR Fuzzel provider is
installed. When sudo needs a password, the adjacent helper prefers Fuzzel; if it
is absent, the helper prints an explicit warning and invokes fixed
`/usr/bin/systemd-ask-password`, which may use a terminal or systemd agent. If
neither provider exists, it fails closed with exit `127`. The non-Fuzzel prompt
path is a bootstrap fallback, not a substitute Fuzzel package/provider, and its
actual interaction remains part of VM/physical acceptance.

## Backup inventory and restore

Replacement backups live under
`~/.local/state/my-archlinux-setup/backups/<backup-id>/`. Each root is mode `700`
and contains a mode-`600`, hash-bearing `.backup.json`. Backups are never
pruned, deleted or restored automatically.

Read the machine-readable inventory without creating state:

```bash
python installer/config-stage-apply.py --list-backups
```

Restore one reviewed backup explicitly:

```bash
python installer/config-stage-apply.py --restore-backup <backup-id>
```

The command first prints the exact approved target plan and makes no write until
the user types `restore <backup-id>` exactly. After confirmation it captures
**all current changing targets** into a new `pre-restore` backup before the first
restore write, applies only manifest-backed targets still present in the current
profile scope, and reports the rollback backup ID. That pre-restore backup is
itself restorable. Path traversal, corrupt/incomplete metadata, payload hash or
mode drift, unrecorded files and removed scope ownership are blockers. Whole-HOME
restore is impossible through this interface.

## Privacy and validation

Approved payload roots are `config/home/.config/`, the reviewed Rime subset
under `config/home/.local/share/fcitx5/rime/`, `config/home/scripts/`, and the
corresponding `config/vm/home/` tree. The Fish configuration may optionally
source the unmapped `~/.config/fish/private-env.fish`; no secret value belongs in
this repository.

Static validation enforces mapping completeness per scope, regular-file/mode
rules, no credential-like payload, and JSON parsing. Deployment, backup,
restore, cancellation, traversal, corruption, idempotence and selected-WM
boundaries are exercised by:

```text
tests/config-deploy-test.sh
tests/config-stage-apply-test.sh
tests/module-selection-test.sh
tests/personal-config-plan-test.sh
```

Actual Niri/Hyprland/DMS graphical behavior remains environment-dependent until
the approved snapshot-backed VM matrix in `docs/vm-validation.md` is complete.
