# Reviewed manifests

All executable manifests are tab-separated, carry a schema marker on their
first line, reject symlinked manifest paths, and are loaded before any installer
state is created. A failed manifest query is an error; it is never treated as an
empty selection.

## Module registry and profile defaults

`modules.tsv` uses schema 1 and has six fields:

1. module ID;
2. reviewed config/session availability (`available`, `planning`, or
   `unavailable`), which is not by itself production execution authority;
3. kind (`selectable` or dependency-only `dependency`);
4. deterministic `requires-all` module list, or `-`;
5. choice-preserving `requires-any` module list, or `-`; and
6. purpose.

`production-module-readiness.tsv` is the independent schema-1 full-DAG gate. It
has module ID, production readiness (`available`, `planning` or `unavailable`)
and reviewable evidence. It must cover every module exactly once; production
readiness cannot exceed `modules.tsv` availability. Its current split is 9
available, 21 planning and 2 unavailable, versus the config/session registry's
14/16/2. The complete file digest is part of every orchestrator plan and is
rechecked before execution.

`profile-modules.tsv` uses schema 1 and has four fields:

1. profile;
2. configuration scope;
3. selectable module; and
4. default state (`selected` or `disabled`).

A user-supplied `--modules` list replaces the profile defaults. `requires-all`
dependencies are then added deterministically. The two unavailable greeter rows
remain registry/planning evidence only: no profile offers them, so explicit
selection rejects them as unsupported before state creation or writes. ASUS defaults select the complete visible policy; modules without complete
production evidence remain `planning` in the independent readiness registry and
make full-preset apply fail closed even when their reviewed config surface is
available.

## Official packages

`official-packages.tsv` uses schema 2 and has four fields:

1. profile;
2. owning module;
3. package name; and
4. purpose.

It is an explicit official-Arch-repository baseline, not a `pacman -Qe` dump.
Repository source is an invariant: third-party packages do not belong here. The
installer validates all rows, takes one in-process snapshot for the selected
profile, and then filters it by the resolved module selection. Display,
availability queries, pacman arguments and state evidence use that same
snapshot.

Before confirmation, each selected package is checked with `pacman -Si`; after
installation, selected packages are recorded from `pacman -Q`. A failed query
retains its exit status, while an empty successful inventory is reported as a
different error.

Raw row counts are 15 for `asus-amd-nvidia`, 15 for `desktop-amd`, and 4 for
`vm`. The default `desktop-amd` narrow starter selects 14 packages because its
Hyprland row is available but disabled. Rejected Fuzzel/Mako/SDDM providers do
not appear here. Dependencies remain pacman's
responsibility. AUR, archlinuxcn and fixed-source DMS recipes require separate
manifests and authorization paths.

## Complete workstation package inventory

`workstation-package-inventory.tsv` is schema-1, dated, inventory-only planning
data with six fields:

1. exact installed package name;
2. observed installed version (evidence, not a version pin);
3. acquisition channel (`pacman` or `aur`);
4. observed repository (`core`, `extra`, `multilib`, `archlinuxcn` or `aur`);
5. restore responsibility (`package-only`, `config-backed`,
   `manual-precondition` or `deferred`); and
6. execution state, currently always `inventory-only`.

Its 180 unique rows are the successful current-host `pacman -Qqe` snapshot: 165
pacman rows and 15 packages independently found through read-only AUR metadata
queries. `linuxqq-appimage`, `wechat-appimage` and `obsidian-bin` are locked as
package-only AUR applications; Niri, Neovim and Fcitx5/Rime are config-backed.
The observation file is not direct installer/apply input. It is cross-checked by
the reconciled planner against the separate target policy. See
[`workstation-packages.md`](../docs/workstation-packages.md).


## Reconciled workstation package policy

`workstation-packages.tsv` is schema-1 target policy with nine fields: package,
target channel, target repository, acquisition method, functional module,
restore responsibility, execution policy, evidence origin and purpose. It has
200 rows: 180 exact current-explicit origins plus 20 confirmed desired
non-explicit requirements. Policies split into 181 install, 18 verify and one
deferred row. Acquisition keeps official pacman, archlinuxcn keyring bootstrap,
already-trusted archlinuxcn, fixed Paru bootstrap and declared AUR builds
separate. The complete policy is consumed by the unified DAG. Its canonical adapters are
implemented and hash-pinned; all nine stage gates and exactly five registry
availability fields were promoted from the candidate checkout. The separate
production-readiness manifest authorizes only the nine modules in the exact VM
selections and keeps the other 21 fail-closed.

`package-source-transitions.tsv` permits exactly one observed-to-target source
change: current archlinuxcn Paru to the confirmed fixed AUR bootstrap.
`package-config-relations.tsv` gives every one of the 26 config-backed packages
an owner/consumer/runtime/optional relation to a same-module mapping.
`provider-decisions.tsv` fixes exclusive Fuzzel, notification and login/greeter
decisions and forbids guessed fallbacks.

`archlinuxcn-bootstrap.tsv` pins the keyring package and detached signature
hashes, trusted signer primary fingerprint, HTTPS mirror and explicit SigLevel.
`config/templates/archlinuxcn.conf` is the exact fragment. The standalone
`archlinuxcn-plan.py` consumes them read-only; neither file is an apply command.
The production helper writes only that fragment and `/etc/pacman.conf` through
Linux `renameat2`: absent paths use `RENAME_NOREPLACE`, existing paths use
`RENAME_EXCHANGE`, and displaced bytes/hash/mode/UID/GID/device/inode must match
the backed-up snapshot. A mismatch is exchanged back; rollback uncertainty
retains a reported recovery path instead of deleting a concurrent administrator
write.

## Fixed AUR recipes, source acquisition and clean-chroot build

`aur-recipes.tsv` is schema 2 with fourteen fields: package name, AUR pkgbase,
role (`aur-build` or `paru-bootstrap`), module, fixed pkgver/pkgrel/architecture,
reviewed AUR commit, complete recipe-tree SHA-256, source policy, optional
external-source filename, downloaded-source execution marker, review state and
review note. Its exact set is 14 regular AUR packages plus Paru; arbitrary names,
extra recipe directories, symlinks, `SKIP`, moving/VCS sources, build-time
network commands, version regressions and tree drift fail closed. The separate
pkgbase field preserves the current `obsidian` split base for package
`obsidian-bin`.

`aur-source-acquisition.tsv` describes the only three private local-source
preconditions: signed-URL LinuxQQ, deterministic Paru Cargo vendor generation
from the reviewed libalpm-16 lock, and checksum-gated WeChat. The acquisition
adapter never persists cookies/signed URLs, refuses conflicting cache files,
writes mode-600 outputs under a mode-700 cache and preserves command exits.
Large external sources never enter the recipe tree.

`aur-build-policy.tsv` and `config/templates/aur-build-pacman.conf` pin an
x86_64 official-only clean chroot, `base-devel,rust` chroot bootstrap, official
`devtools` host prerequisite, audited `gsudo` root helper and the only permitted
artifact roots (`usr,opt,etc`). `aur-build.py` verifies sources before invoking
`makechrootpkg`, builds as the chroot's unprivileged build user, checks exact
pkgname/pkgbase/version/arch/packager/hash/file roots and never installs an
artifact. `aur-install.py` accepts only those private verified artifacts,
refuses automatic downgrade, re-installs same-version packages only when needed
to establish fixed-recipe provenance, and requires both AUR and system-change
confirmations. All adapters have mocked failure-path tests; the exact three
VM-selected recipes also have real clean-chroot/install/rerun evidence, while the
other 12 remain production-blocked.

## Unified stages, executables and auxiliary inputs

`stages.tsv` is the schema-2 nine-row DAG. Its fields are stage ID, trust domain,
criticality, dependency list, confirmation domain, effect source,
`production-apply-integration` boolean and purpose. The exact ordered stage set
is `privilege-wrapper`, official update/packages, archlinuxcn
bootstrap/packages, AUR source/build-install, user config and system actions.
Every production integration boolean is now `true` after the candidate and
clean canonical VM matrices. The orchestrator still enforces the values as real
apply gates rather than informational labels. The separately hashed production
module readiness—not config/session availability—is the independent module
blocker.

`stage-executables.tsv` is schema 1 with the exact second-line marker
`# reviewed=true`. Each row names execute and verify paths plus their SHA-256.
Safe `installer/...` paths resolve relative to the checkout, making a relocated
checkout reproducible without embedding a personal absolute path. The canonical
file covers all nine stages; an identical manifest supplied from another path
is classified external and cannot authorize production apply.

`stage-inputs.tsv` binds adapter inputs not already present in the ordinary plan:
the archlinuxcn planner/bootstrap/template, AUR policy/tool/template files and
all 15 fixed recipe trees. Each row has input ID, owning stages, kind (`file` or
`tree`), safe project-relative path and reviewed SHA-256. Applicable inputs are
included in the plan fingerprint and rechecked before every preflight/execute/
verify boundary. A failed or changed input is a trust failure, never an empty
stage.

## System actions and conflicts

`system-actions.tsv` is schema 1 with 30 reviewed actions. It records module,
profile applicability, `apply`/`verify`/`manual`/`deferred` disposition,
privilege, fixed handler/target, applicability condition, conflict set,
dependencies, rollback, post-check, purpose and evidence. The companion
`system-action-conflicts.tsv` defines five exact conflict sets. The production
adapter accepts only its reviewed executable columns and has no arbitrary unit,
command or target CLI.

Automatic actions include time sync, hardware-gated Bluetooth/power, Niri DMS
wants, dsearch, Docker/libvirt/default-network, locale and Fcitx environment.
Group membership, Snapper, boot/recovery, hugepages, physical ASUS acceptance
and greeter remain manual/deferred as declared. The full plan/state exposes
pending/manual/deferred/conditional/relogin-or-reboot acceptance explicitly.

## Phase C package candidates

`phase-c-package-candidates.tsv` is schema-1 planning data with eight fields:

1. proposed future module;
2. package name;
3. source finding (`official`, `unavailable-official` or `archlinuxcn`);
4. disposition, including non-installing `precondition` rows;
5. applicability gate;
6. possible future service action;
7. blocker; and
8. purpose.

Its 48 rows are not executable and are not loaded by `installer/install.sh`.
`installer/phase-c-plan.py` may read this manifest to produce a text or JSON
review plan. Its `review_transaction` groups exact applicable package names into
proposed official, precondition, dependency-only, pending, optional, blocked
third-party and excluded buckets; the ASUS default split is 24/2/3/1/4/4/7.
The transaction always has `apply_authorized=false`,
`installer_integration=false` and `install_command=null`. Optional read-only
`pacman -Qq` checks classify only proposed official packages as installed,
missing or query-failed. The tool does not install packages, enable services or
write system files. The rows preserve the read-only portal, audio, Bluetooth,
power, locale/input, graphics and ASUS review without weakening the current
official manifest.
Third-party rows must remain `blocked-third-party`. The Portal rows are now
`proposed` behind `portal-session-validation`, while `uwsm` is excluded by the
plain-session decision; all remain non-executable until the separate transaction,
clean-session tests and explicit approval exist. See
[`phase-c-plan.md`](../docs/phase-c-plan.md).

For service-owned rows, `package-global-enable` means the future transaction
must preserve the official package hook (`systemctl --global enable`) rather
than inventing per-user commands. `session-startup-map` means exactly one
Fcitx5/Blueman owner per active session: package XDG autostart for Niri and the
existing guarded Hyprland configuration for plain Hyprland. Conflict checks use
exact package names and retain `query-failed` as distinct from a successful
absent result. No candidate row authorizes automatic conflict removal or
replacement; clean-VM hooks/socket-activation and post-check evidence remain
required before integration.

## DMS source candidates

`dms-package-candidates.tsv` is a separate schema-1, seven-field planning
manifest for the DMS shell/compositor/greetd/greeter trust split. Its eight rows
are not loaded by the installer. Official shell/provider rows are proposed
under the confirmed official-source decision, while the observed foreign
rolling greeter and unresolved fixed greeter stay blocked. See
[`dms-source-plan.md`](../docs/dms-source-plan.md).

## Personal configuration candidates

`personal-config-candidates.tsv` is a schema-1, seven-field planning manifest
for the faithful same-user/same-ASUS restore pass:

1. candidate area;
2. proposed future module;
3. live path relative to the user's home;
4. current file mode;
5. restore disposition (`personal-include` or `candidate`);
6. review state (`reviewed-functional` or `metadata-only`); and
7. purpose or remaining blocker.

The manifest itself is not loaded by `installer/install.sh`. All 77 rows are
reviewed functional files now promoted into `config-mappings.tsv`: the original
exact Niri/Hyprland/Fcitx5/DMS comparison, shared desktop/DMS-adjacent
configuration files, two authored Rime data-root customizations, the reviewed
personal script working-tree subset, one personal autostart entry, one same-ASUS
ROG user config, and four user systemd unit files. The user service files are
restored as files only; no service is enabled or started, and referenced secrets
are not copied.

## Configuration mappings

`config-mappings.tsv` uses schema 2 and has four fields: configuration scope,
owning module, repository-relative source and invoking-user-HOME-relative
target. Source/target uniqueness is enforced per scope.

The manifest has 198 rows:

| Scope | Rows | Payload roots |
| --- | ---: | --- |
| `physical-v1` | 162 | reviewed `.config`, Rime data-root subset and `scripts` under `config/home/` |
| `vm-v1` | 36 | shared reviewed sources plus four files under `config/vm/home/` |

Physical ownership is 37 shared, 7 input, 42 editor, 15 Niri, 16 Hyprland,
39 scripts, 4 user-service, 1 autostart and 1 ASUS row. VM ownership is 27
shared, 7 input, one Niri and one Hyprland row. VM Niri-only and Hyprland-only
each select 35 total targets; both select 36. The privilege wrapper's two
selected mappings belong exclusively to `privilege-wrapper` and are excluded
from `user-config` effects.

Approved sources are single-link regular files with reviewed modes. Paths with
traversal/control characters, unsafe targets, symlinked sources, duplicate
per-scope ownership and unmapped payload files are invalid. `config-stage-apply`
binds every selected source hash into effects, performs zero-write preflight,
uses backup-before-atomic-replace and provides manifest-backed explicit backup
listing/restore without any whole-HOME operation.
