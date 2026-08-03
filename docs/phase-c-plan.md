# Phase C core desktop and hardware plan

Status date: 2026-07-31  
Scope: read-only inventory and non-executable planning

The broader manual/live-system reconciliation is tracked in
[`reference-baseline.md`](reference-baseline.md). The dual-kernel baseline and
first Portal/session package selection are now confirmed; DMS, conflict,
hardware and clean-session findings still gate any executable integration.

## Safety boundary

No Phase C row is executable. The candidate data in
[`phase-c-package-candidates.tsv`](../manifests/phase-c-package-candidates.tsv)
is not read by `installer/install.sh`, does not change the Phase A module graph,
and does not authorize package, service, `/etc`, boot, driver or repository
changes. No system changes were performed during this inventory.

The planner now computes an exact **review-only package-set preview** from the
applicable rows. That preview is not a repository-resolved pacman transaction,
does not generate an install command and does not authorize apply. Before
implementation, each proposed module still needs refreshed repository metadata,
prior service/config state, a disk estimate, rollback guidance, mocked failure
tests and an explicitly approved clean-VM apply. Hardware and locale changes
additionally require fresh target inventory immediately before apply.

## Review tool

`installer/phase-c-plan.py` renders the 48-row candidate manifest into a
reviewable Phase C plan. It is intentionally a planning tool, not an apply path:

```bash
installer/phase-c-plan.py --profile asus-amd-nvidia
installer/phase-c-plan.py --profile asus-amd-nvidia --json
installer/phase-c-plan.py --profile asus-amd-nvidia --check-installed
installer/phase-c-plan.py --profile desktop-amd
installer/phase-c-plan.py --profile vm
```

Every text/JSON result includes `review_transaction`. Its hard safety fields are
`apply_authorized=false`, `installer_integration=false` and
`install_command=null`. It separates the applicable rows into exact package
name buckets, groups unresolved blockers for the proposed official packages and
never emits `pacman -S` or another apply command.

For the ASUS default (Niri + Hyprland), the preview currently contains:

| Review bucket | Count |
| --- | ---: |
| proposed official | 24 |
| manual base-install preconditions | 2 |
| dependency-only/transitive | 3 |
| pending decision | 1 |
| optional | 4 |
| blocked third-party | 4 |
| excluded | 7 |

The exact proposed official package set is:

```text
amd-ucode blueman bluez bluez-utils fcitx5 fcitx5-gtk fcitx5-qt
fcitx5-rime linux-headers linux-zen-headers mesa nvidia-open-dkms
pipewire pipewire-alsa pipewire-audio pipewire-pulse
power-profiles-daemon sof-firmware vulkan-radeon wireplumber
xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk
xdg-desktop-portal-hyprland
```

By default the tool performs no live package query, leaves
`installed_state_checked=false` and keeps all three proposed status buckets
empty. `--check-installed` only runs read-only `pacman -Qq` checks for applicable
packages and records `installed`, `missing` or `query-failed` with the query exit
status. The transaction preview then classifies only the proposed official set
into `installed_proposed_packages`, `missing_proposed_packages` and
`query_failed_proposed_packages`; optional, pending, precondition, excluded and
third-party packages cannot leak into those three lists. A missing `pacman`
runtime is reported as `query-failed`, not as an empty result.

The top-level JSON safety block remains `planning_only=true`,
`system_changes=false` and `installer_apply_integration=false`. The tool must
remain disconnected from `installer/install.sh` until a separately reviewed,
repository-resolved apply transaction, rollback plan, VM evidence and explicit
user approval exist.

## Repository-resolved transaction preview

`installer/phase-c-transaction-preview.py` is the next standalone review layer:

```bash
python installer/phase-c-transaction-preview.py --profile asus-amd-nvidia --json
python installer/phase-c-transaction-preview.py --profile vm --json
```

It invokes the existing planner for the exact proposed official package set,
then uses only read-only package-manager and systemd queries. It does **not**
refresh sync databases, install/remove packages, change unit enablement, write
configuration or integrate with `installer/install.sh`. Its JSON safety block
is fixed to `read_only=true`, `apply_authorized=false`,
`installer_apply_integration=false` and `system_changes=false`;
`apply.command` is always `null`.

The report records:

- active repositories plus each sync database path, mtime and age; metadata older
  than the configured threshold is `stale` and blocks readiness without being
  mislabeled as a failed query;
- planner and dependency-resolution query status/exit evidence, so a failed
  subprocess cannot be represented as an empty package set;
- per-request repository metadata, keeping `target-not-found`, query failure and
  malformed output distinct;
- the `--needed` repository-resolved package rows, classifying direct requests
  and dependencies separately and reporting download/installed byte totals;
- installed, missing and query-failed requested packages;
- installed-package and transaction conflicts without authorizing replacement;
- prior system/user/global-user unit state and selected package-owned paths;
- rollback notes, post-checks, deterministic blockers and unavailable checks.

Exit `0` means the read-only evidence is ready, `1` means a deterministic
blocker such as stale metadata, a missing target or an installed conflict was
found, and `2` means at least one required query was unavailable. Exit `2` takes
precedence while both blocker and unavailable lists remain in JSON. A successful
empty dependency-resolution result is explicitly marked with
`transaction.resolution.successful_empty=true`; it is not confused with a
failed query. The tool never runs a sync-database refresh. Refresh and apply
remain separate future system-changing actions that require inventory, a
reviewable plan, rollback-capable VM evidence and explicit approval.

### Current host read-only evidence (2026-07-31)

The ASUS-profile preview was run without refreshing repositories or changing the
host. The first run correctly returned exit `2` after the current pacman emitted
literal `\t` separators in `--print-format`; the parser had only accepted tab
bytes. That failed check was reproduced, fixed and added to the mocked
regression rather than reported as an empty transaction.

The rerun returned exit `1` / `blocked`, with no unavailable checks. `core`,
`extra`, `multilib` and `archlinuxcn` sync databases were 36.334-53.097 hours old
against the default 24-hour freshness gate. Of 24 requested packages, 22 were
installed; `bluez-utils` and `xdg-desktop-portal-hyprland` were missing. The
read-only resolution contained those two direct packages plus `sdbus-cpp` as a
dependency, totaling 1,731,167 download bytes and 5,672,211 installed bytes from
the existing metadata snapshot. No installed conflict was detected. Required
unit queries and installed package-path ownership checks completed; the missing
Hyprland Portal unit path was represented as `not-installed`, not as a failed
ownership query. No refresh or apply action followed this evidence.

## Read-only session/service acceptance tool

`installer/phase-c-session-check.py` implements the next verification boundary
without implementing Phase C apply. Run it inside the session being checked:

```bash
python installer/phase-c-session-check.py --session niri --json
python installer/phase-c-session-check.py --session hyprland --json
python installer/phase-c-session-check.py --session niri --selection both --json
```

Omit `--json` for a short text summary. `--selection` describes the installed WM
set; it defaults to the active `--session`. Thus `--selection both` preserves the
four-package Portal union while validating only the backend set appropriate to
the current session. The checker defaults to `--profile physical`, retaining
BlueZ/Blueman and power-profile package/service/D-Bus requirements. Disposable
VM scenarios must pass `--profile vm`; that profile keeps Portal, audio, Fcitx
startup and failed-unit checks strict while reporting physical hardware owners
as `not-applicable`, never as passed.

The exit contract is:

| Exit | Result | Meaning |
| ---: | --- | --- |
| `0` | `ready` | every automated, non-interactive acceptance check passed |
| `1` | `blocked` | a deterministic package, configuration or runtime blocker was found |
| `2` | `unavailable` | at least one required command/query/output could not be evaluated |

An `unavailable` result takes precedence in the top-level exit code even when a
deterministic blocker is also present; both lists remain in `overall`. A
successful empty query remains available evidence: for example an empty failed-
unit JSON array passes that check, `pgrep -x` exit `1` with no output means zero
processes, and a successful Bluetooth query with no controller is
`not-applicable`. Missing commands, non-semantic command failures and malformed
JSON/config output are never converted into empty or healthy results.

The JSON report contains `environment`, `portal`, `startup`, `packages`,
`global_user_units`, `audio`, `system_services`, user/system D-Bus evidence,
`power_profiles`, `bluetooth`, `failed_units` and per-check results. Its safety
contract is fixed:

```json
{
  "read_only": true,
  "installer_apply_integration": false,
  "system_changes": false,
  "manual_interactive_checks": false
}
```

The checker reads exact installed package names once with `pacman -Qq`; parses
the package-owned Niri/Hyprland Portal preference; rejects user/system Portal
overrides and unknown active backends; distinguishes an owned D-Bus name from an
activatable-only name; checks the exact single-WM or both-WM Portal package
matrix; verifies package-owned PipeWire/WirePlumber global user-unit state,
current audio units and the Pulse-on-PipeWire server; checks the Niri XDG or
plain-Hyprland guarded Fcitx5/Blueman owner; and inventories relevant services,
buses, power profiles, Bluetooth controller state and failed units. It never
installs a package, enables/starts a service, writes configuration or invokes
`installer/install.sh`.

Automated `ready` is not complete graphical or hardware acceptance. File chooser,
screenshot/screen sharing, playback/recording, Bluetooth pairing/reconnect,
power-profile switching, suspend/resume, GPU/output behavior and reboot remain
manual or isolated-environment checks.

## Evidence method

The host inventory used read-only package, systemd, session, locale, PCI and
runtime queries. Every captured query retained `query_exit`; all files are mode
`600` under a mode-`700` temporary directory outside the repository. The
sanitized durable conclusions below omit usernames, hostnames, cookies and raw
logs.

`expac` was unavailable. Official availability was therefore checked in two
steps:

1. membership in `core`, `extra` or `multilib` from `pacman -Sl`; and
2. individual resolution through `pacman -Sp --print-format`.

The configured `archlinuxcn` database was deliberately excluded from the first
step. This matters because a plain `pacman -Sp asusctl` succeeds on this host
through `archlinuxcn`, not through an official Arch repository.

For this audio/power/startup pass, exact package names were checked with
`pacman -Qq` and repository conflict metadata with `pacman -Si`; unit existence
and state were checked with `systemctl show` while preserving each command's
exit status. The host currently has no installed PulseAudio, JACK2,
`pipewire-media-session`, TuneD, TLP, auto-cpufreq or system76-power package;
those are successful absent results, distinct from a failed query. The package
install hooks and owned XDG/systemd files were inspected read-only. No package
or service change was made.

These are rolling-repository observations, not pinned versions. Official
membership, dependency/conflict metadata and transaction size must be refreshed
against the target's synchronized databases immediately before any future
implementation or apply review.

## Sanitized current-state findings

- The inspected host matches the primary hardware shape: an ASUS TUF A15 with
  AMD Rembrandt integrated graphics and an NVIDIA AD107M RTX 4050 Laptop GPU.
  `amdgpu` and `nvidia` are both the active kernel drivers; `nvidia-smi` and
  `vulkaninfo --summary` succeeded.
- The active session is Niri on Wayland through greetd. The safe process
  environment reports `XDG_CURRENT_DESKTOP=niri`.
- Niri currently runs with `xdg-desktop-portal`, GNOME and GTK backends. Its
  packaged `niri-portals.conf` selects `gnome;gtk`. Hyprland's packaged
  `hyprland-portals.conf` selects `hyprland;gtk`; `pacman -Qo` confirmed those
  files are owned by `niri` and `hyprland` respectively.
- Hyprland ships a plain entry with `Exec=/usr/bin/start-hyprland` and a separate
  UWSM entry with `TryExec=uwsm`. The launchers are package-owned; `uwsm` and
  `xdg-desktop-portal-hyprland` are not installed on the golden host. The plain
  entry declares `DesktopNames=Hyprland`, and the Hyprland binary contains its
  user-systemd/D-Bus environment import path for `XDG_CURRENT_DESKTOP`.
- The user and system Portal override directories are absent, and the repository
  payload contains no `portals.conf` or desktop-specific Portal override. The
  restored Niri configuration explicitly sets `XDG_CURRENT_DESKTOP=niri`.
- PipeWire, its ALSA/Pulse/JACK layers and WirePlumber are active. A sanitized
  Pulse query identifies PipeWire as the server. The installed official package
  hooks globally enable `pipewire.socket`, `pipewire-pulse.socket` and
  `wireplumber.service`; the current user also has matching per-user links. This
  is package metadata and golden-host evidence, not proof that a clean target
  needs a manual user-unit enable command.
- The Bluetooth kernel path and `bluetooth.service` are active. `bluez-utils`
  and therefore `bluetoothctl` are absent, so no CLI controller post-check was
  possible.
- `power-profiles-daemon` is enabled and active; UPower is D-Bus active. The
  current profile query succeeded. No suspend/resume test was performed.
- The system locale enables `en_US.UTF-8` and `zh_CN.UTF-8`; the active system
  default is `zh_CN.UTF-8` with `LC_CTYPE=en_US.UTF-8`.
- Fcitx5, GTK/Qt integration and Rime are installed. The public Rime config also
  names `rime_ice`, but the matching installed schema package is the
  `archlinuxcn` rolling package `rime-ice-git`.
- `linux`, matching headers, `amd-ucode`, Mesa/RADV and
  `nvidia-open-dkms` are installed. Current Mesa replaces and provides the old
  `libva-mesa-driver` package name.
- `asusctl`, `supergfxctl` and `rog-control-center` are installed from
  `archlinuxcn`. Their daemons are active, but this is current-host evidence,
  not authorization to reproduce them.
- Both system and user failed-unit queries succeeded with empty JSON arrays.
  That is a successful empty result, not a failed health query.
- The standalone session/service checker was then run read-only in the current
  Niri Wayland session. It returned exit `2` with `overall=unavailable`, not
  `ready`: `bluez-utils` is absent, so the required-package check is blocked,
  and `bluetoothctl` is command-missing, so the controller check is unavailable.
  The same report confirmed the installed Niri Portal matrix and active
  GNOME+GTK backend ownership, one Fcitx5 and one Blueman process through the
  generated XDG owner, globally enabled PipeWire/WirePlumber units, active
  audio/system units and PulseAudio compatibility on PipeWire. No system change
  was made to remove this environment-dependent gap.

## Module direction

### Portals and sessions

Portal decision is closed for the first restore baseline:

| Selected compositor modules | Proposed Portal packages |
| --- | --- |
| Niri only | `xdg-desktop-portal`, `xdg-desktop-portal-gtk`, `xdg-desktop-portal-gnome` |
| Hyprland only | `xdg-desktop-portal`, `xdg-desktop-portal-gtk`, `xdg-desktop-portal-hyprland` |
| Niri + Hyprland | the union of all four packages, installed once |

The compositor packages already provide desktop-specific preference files.
`niri-portals.conf` selects `gnome;gtk`, while `hyprland-portals.conf` selects
`hyprland;gtk`; the broker chooses the matching file from the active
`XDG_CURRENT_DESKTOP`. No global Portal override is generated. The golden host
has no user/system override directory, and the project payload contains no such
file. `xdg-desktop-portal-wlr` stays excluded because Niri is not wlroots and its
package selects GNOME instead.

Plain Hyprland session is selected for the first restore baseline. The packaged
plain entry calls `/usr/bin/start-hyprland`; the optional UWSM entry is guarded
by `TryExec=uwsm`. `uwsm` therefore moves to `excluded` with
`plain-session-selected`, avoiding a second session manager and dependency stack
without deleting future support as an explicit, separately tested option.
Greeter/login-manager behavior remains deferred and does not alter this package
choice.

The four selected Portal packages are `proposed`, not executable. Their shared
`portal-session-validation` gate now means clean-session verification rather
than unresolved package selection: selected backend units active, Portal D-Bus
name present, file chooser and screenshot working, then browser/communication
screen sharing in every selected WM after a clean login. The GNOME backend's
larger dependency set must be included in the future repository-resolved size
review; no Phase C row enters apply before that separate plan and approval.

### PipeWire audio

The proposed baseline is PipeWire audio + ALSA + Pulse replacement +
WirePlumber. JACK replacement remains optional because it conflicts with
`jack`/`jack2`. `rtkit` and `alsa-utils` are optional; direct
`realtime-privileges` group policy is excluded from the baseline.

The package-owned startup contract is now closed for planning: the official
package install hooks use `systemctl --global enable` for the PipeWire and
WirePlumber user units, while socket activation supplies the runtime start.
The future transaction must preserve that package-owned mechanism, must not add
an ad-hoc per-user enable command, and must record the prior global/user unit
state before any package operation. Conflict inventory uses an exact-name
`pacman -Qq` exact-name set and must separately classify installed, absent and
query-failed conflict packages. PulseAudio, `pipewire-media-session`, and
JACK/JACK2 are not automatically removed or replaced; a detected conflict
stops the transaction for review. No automatic conflict removal is allowed.

Post-checks: no failed user units, PipeWire and WirePlumber active after socket
activation, `wpctl status -n`, a sanitized Pulse server query, output/input
playback and recording, and Bluetooth audio when Bluetooth is selected.

### Bluetooth

The proposed physical baseline is `bluez`, `bluez-utils` and `blueman`, with an
explicit, prior-state-aware enable of `bluetooth.service`. Blueman startup is
now mapped to one owner per active session: Niri relies on the package-provided
`/etc/xdg/autostart/blueman.desktop` through
`xdg-desktop-autostart.target`, while plain Hyprland uses the existing guarded
command in `config/home/.config/hypr/conf/autostart.lua`. Niri must not add a
second compositor command, and Hyprland must retain its `pgrep` guard. This is
one startup owner per active session.

Post-checks: kernel adapter present, service enabled/active, `org.bluez` on the
system bus, `bluetoothctl show`, then manual pair/reconnect and audio profile
validation. Absence of an adapter is not-applicable, while a failed adapter
query is failed.

### Power

The proposed physical baseline is `power-profiles-daemon`; UPower is its
official dependency and remains D-Bus activated. Its future system action is
explicitly `enable-power-profiles-daemon.service`, but only after inventory and
approval. Preflight must stop this module when TLP, TuneD, auto-cpufreq,
system76-power or another conflicting power daemon/package is active or
installed. TuneD/TuneD-PPD is excluded as a competing owner, not silently
removed; the Intel-oriented `thermald` candidate is excluded for this AMD
laptop.

Post-checks: service enabled/active, D-Bus name present, profiles listed and a
reviewed profile selected, battery state visible, then physical suspend/resume
and AC/battery transitions. The installer must not preserve the source host's
temporary `performance` selection as a universal default.

### Locale and Fcitx/Rime

The ASUS default locale module should back up and manage only the reviewed
`/etc/locale.gen` and `/etc/locale.conf` changes, run `locale-gen`, and report a
required re-login. Other profiles keep locale unchanged unless Chinese input is
explicitly selected.

The official input baseline is Fcitx5, Rime and GTK/Qt integrations. Startup
ownership is now mapped per session: Niri relies on the package-provided
`/etc/xdg/autostart/org.fcitx.Fcitx5.desktop` through
`xdg-desktop-autostart.target`, while plain Hyprland uses the existing guarded
`fcitx5 -d` command in `config/home/.config/hypr/conf/autostart.lua`. No second
Fcitx command is added to Niri, and the Rime engine row does not claim a startup
owner.

Rime Ice configuration mismatch: the public config names `rime_ice`, but the
corresponding package is third-party `rime-ice-git`. Before official-only apply,
either make that schema conditional/remove it from the official config or add a
separately authorized fixed third-party recipe. It must not be silently fetched
from `archlinuxcn`.

Post-checks: both locales listed by `locale -a`, effective locale values after
re-login, exactly one Fcitx process/startup owner, `fcitx5-remote` response, GTK
and Qt input, and Chinese composition through every configured Rime schema.

### AMD and NVIDIA graphics

The ASUS kernel baseline follows the confirmed decision: `linux`, matching
`linux-headers` and hardware-gated `nvidia-open-dkms`. The AMD side proposes
`amd-ucode`, Mesa and RADV. NVIDIA user-space libraries are an exact-version
dependency of the DKMS package; 32-bit libraries stay in a separate optional
multilib choice.

Preflight must verify PCI IDs, selected kernel/header agreement, conflicting
driver packages, available bootloader/initramfs integration and sufficient DKMS
build space. `amd-ucode` requires a separate reviewed boot integration step; a
package install alone is not reported as effective. VM never selects NVIDIA.

Post-checks after required reboot: `lspci -nnk` exact driver ownership, expected
modules loaded, DKMS status for every selected kernel, `nvidia-smi`, Vulkan on
the intended GPU, VA-API, external outputs and physical suspend/resume. Package
success alone does not pass graphics acceptance.

### ASUS and hybrid controls

ASUS controls are third-party on this host. `asusctl`, `supergfxctl` and
`rog-control-center` resolve from `archlinuxcn`, so Phase C cannot add them to
the official manifest. They remain blocked pending the separate third-party
authorization required by the product contract. The official
`switcheroo-control` candidate may be evaluated, but it is not a guessed
replacement for ASUS GPU mode control.

Any later ASUS module must capture prior daemon states, distinguish static
D-Bus activation from enabled services, define safe GPU mode transitions and
reboot expectations, and validate charge limit, fan/profile behavior and hybrid
GPU state on physical hardware.

## Conflicts and recovery

| Area | Required preflight stop | Recovery boundary |
| --- | --- | --- |
| Portals | Unknown user/system global override, missing packaged desktop preference, or failed backend/session query | Baseline owns no override; do not auto-remove shared backend packages |
| Audio | Exact-name package/unit conflict: PulseAudio, JACK/JACK2 or another PipeWire session manager | Restore recorded global/user unit state; do not auto-remove or replace packages; package rollback remains manual |
| Bluetooth | Failed adapter query or pre-existing custom daemon config | Restore prior service state and backed-up managed config only |
| Power | TLP, TuneD, auto-cpufreq, system76-power or unknown policy owner/package | Restore recorded unit states; do not guess, remove or replace a competing daemon |
| Locale/input | Unknown locale file edits, duplicate startup owner or missing configured Rime schema | Restore backed-up locale/config files, rerun locale-gen, re-login |
| Graphics | Hardware mismatch, kernel/header mismatch, conflicting driver or unreviewed boot path | Stop before install; package/boot recovery is manual from recorded prior state |
| ASUS controls | Missing independent third-party authorization or incompatible hardware | No apply in Phase C |

## Failed and unavailable checks

- `expac` and `man` are unavailable. Neither check is reported as passing.
- The current Niri checker run returned exit `2` / `overall=unavailable`.
  `bluez-utils` is absent and `bluetoothctl` is therefore command-missing;
  required-package status is a deterministic blocker while the controller query
  remains unavailable. BlueZ service/bus evidence does not replace that check,
  and this run is not reported as ready or healthy.
- An attempted `systemctl --user show-environment <name>` form failed with exit
  `1` and `Too many arguments`; it is not environment evidence. Safe values
  were read from the current process instead.
- An initial Hyprland config read used the wrong path and exited `2`; the actual
  Lua entrypoint and mapped files were then inspected.
- An initial startup-reference scan included a nonexistent Quickshell path and
  exited `2`; the corrected scan over existing Niri/Hyprland trees completed
  with ripgrep's no-match exit `1`.
- An exploratory `pacman -Fl uwsm` form exited `1`; official membership and
  resolver queries independently succeeded, so that failed command is not used
  as package-availability evidence.
- An initial Hyprland environment search passed a nonexistent `/etc/hypr` root to
  `find`, producing `find=1` and `xargs=123`; it is not no-match evidence. The
  corrected direct search over existing package/user config roots completed with
  grep exit `1`, meaning a successful query with no assignment match.
- No packaged `start-hyprland` man page was found. Static session evidence is
  therefore limited to package ownership, desktop entries, the launcher's
  read-only `--help`, and strings in the installed Hyprland binary; an actual
  Hyprland login remains environment-dependent.
- `expac` was unavailable, so package metadata was read with `pacman -Qq` and
  `pacman -Si`. The exact-name conflict queries above succeeded; an absent
  package is not reported as a failed query. `systemctl show` returned loaded
  or `not-found` unit states successfully for the checked conflict owners.
- The current Niri session has exactly one generated XDG autostart unit and one
  process each for Fcitx5 and Blueman. This validates the current host's owner
  mapping only; a clean Hyprland login and fresh-target package activation are
  still environment-dependent.

Environment-dependent work still not performed: clean-VM package/preset apply,
graphical Hyprland login, per-WM screen sharing, Bluetooth pairing, audio
record/playback, suspend/resume, locale migration, DKMS rebuild, reboot, output
testing or ASUS control changes.
