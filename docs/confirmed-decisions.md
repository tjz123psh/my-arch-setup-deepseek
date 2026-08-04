# Confirmed project decisions

Status: requirements source of truth  
Last updated: 2026-07-31

## How to use this document

This file preserves the final user-confirmed outcomes of the project's prior
Grilling interview. It is intentionally separate from the handoff:

- this file records **stable requirements and safety boundaries**;
- [`implementation-status.md`](implementation-status.md) records what the
  current tree actually implements;
- [`handoff-20260730.md`](handoff-20260730.md) records the current work
  checkpoint and exact next action.

The raw shared conversation is not copied or linked here because it contains
workstation paths and transient machine context that do not belong in a public
repository. Only the resulting decisions are retained.

When documents disagree, use the latest explicit user instruction first, then
this decision record for project behavior. Current `AGENTS.md` working
agreements still govern how changes are made and validated. Do not silently
change a confirmed decision: update this file with the new decision and record
what it supersedes.

Decision labels used below:

- **MUST** — required behavior or safety boundary;
- **DEFAULT** — preselected behavior that the user may explicitly change;
- **MAY** — supported explicit option;
- **MUST NOT** — prohibited behavior.

## 1. Product scope and supported starting point

### DEC-SCOPE-01 — Post-base-install only

The installer starts after a standard Arch Linux base installation is complete
and network access works. It does not partition disks, format filesystems,
install the base OS, or reproduce the user's manual disk/boot procedure.

### DEC-SCOPE-02 — Supported platform

The first release formally supports:

- x86_64 Arch Linux;
- systemd and pacman;
- a writable, non-immutable root filesystem;
- working network/DNS;
- an ordinary sudo-capable user.

It does not promise support for Arch ARM, containers/chroots, non-systemd
systems, read-only/immutable systems, Manjaro/EndeavourOS or other derivatives,
or arbitrary long-lived mixed desktop installations.

### DEC-SCOPE-03 — Primary and secondary use cases

- **Primary:** a clean post-base-install machine.
- **Secondary and narrow:** explicit `reconcile` of the approved whitelist on
  the known Niri + Hyprland + DMS stack.
- **Not promised:** general convergence of any existing Arch workstation.

Other desktop environments or unsupported display managers are conflicts for
the shared desktop/login modules. The installer must report them and must not
automatically uninstall, disable, or replace them.

### DEC-SCOPE-04 — Profiles

The first profile set is:

- `asus-amd-nvidia` — primary physical workstation profile;
- `desktop-amd` — secondary generic AMD desktop profile;
- `vm` — clean-VM regression profile, not a physical-machine substitute.

Profiles choose defaults; modules remain the actual selectable units.

### DEC-SCOPE-05 — Exact post-network handoff point

The user manually completes the private manual through the base installation,
partitioning, bootloader/dual-boot work and first boot. The user also performs
the initial NetworkManager bootstrap and interactive Wi-Fi connection so that
network, DNS and official mirrors work without transferring network
credentials to the installer.

The installer begins with the workstation configuration that follows the manual
network bootstrap, corresponding to section 9.1 and later in the current manual.
It may verify NetworkManager/service/connectivity state and stop with guidance,
but it does not own Wi-Fi secrets or broaden scope back into sections 1–8.

The later manual is reference input, not a literal command stream. Repository,
AUR, DMS, locale, driver, service, snapshot, boot and optional-tool effects are
still split into reviewed modules with their required conditions and independent
confirmations.

### DEC-SCOPE-06 — Personal same-machine restoration is the product

This project is primarily for the same user to rebuild the same ASUS workstation
after reinstalling Arch. The normally working host is the golden source for the
intended packages, desktop behavior, machine-specific configuration and personal
tools. Faithful restoration takes priority over portability to unknown users or
hardware.

A host-specific value is not excluded merely because it would be unsuitable for
a generic installer. Functional Niri, Hyprland, DMS, Fcitx5/Rime, display,
session, ASUS and personal-script configuration SHOULD be preserved when its
module is selected. Actual credentials, private keys, authentication material
and clearly regenerable or meaningless transient state remain excluded. This
scope correction supersedes earlier decisions that treated a small portable
public subset as the personal installer's desired copy boundary.

This does not authorize a blind `$HOME` copy. Every deployed path remains
explicitly mapped, backed up before replacement, selected by module, permission
preserving and reviewable before apply.

## 1A. Reference inputs and reconciliation

### DEC-REF-01 — Working workstation is required evidence

The current normally running ASUS workstation is the reference baseline for the
intended full physical experience. Before implementing a workstation module,
the project MUST inventory and compare its current packages/sources, services,
startup ownership, configuration scope and post-check behavior. This does not
authorize a bulk package dump, home copy or automatic convergence.

The live baseline is mutable. Every system-changing plan still re-queries the
target and preserves query failures separately from successful empty results.

### DEC-REF-02 — Private manual is reference, not a script

The user's private manual-install note is a durable requirements/history input.
Its disk, boot, package, service and recovery commands are not executable
installer input and may be stale, machine-specific or unsafe. Current official
package metadata, current host evidence, the latest explicit user instruction
and these confirmed safety boundaries take precedence.

Credentials, account details, private paths and embedded private media from the
note MUST NOT enter the public repository, logs or installer state.

### DEC-REF-03 — Reproduction claims disclose remaining gaps

The repository mapping may be smaller than the live workstation while work is
in progress, but every known functional gap must be audited and documented. The
installer must not call the current mapped subset a full workstation
reproduction while known startup, service, personal-tool or user-facing
behavior remains outside the mappings. A separate portable/public disposition
may be recorded for future reuse, but it does not limit the personal restore
manifest.

## 2. Meaning of “one-click” and module selection

### DEC-UX-01 — One orchestrated run, not a silent script

“One-click” means one reviewed installer entrypoint that:

1. loads a profile;
2. shows every selected module and its package/config/service effects;
3. lets the user change module choices before apply;
4. requests the required independent risk confirmations;
5. executes visible stages with progress and post-checks; and
6. produces a final passed/skipped/not-applicable/failed report.

It does not mean hiding the plan, swallowing failures, or using a global yes
switch.

### DEC-UX-02 — Physical full preset

The first physical run of `asus-amd-nvidia` defaults to the reviewed current
workstation preset. All selected functionality must remain visible by module,
and the user can cancel individual modules before execution.

The full preset may preselect development, Btrfs/Snapper, KVM, recording,
audited scripts, DMS, Niri and Hyprland, but conditional and third-party modules
still obey their own checks and confirmations.

### DEC-UX-03 — Interactive and non-interactive selection

- Interactive mode shows module choices and concrete effects before apply.
- Non-interactive mode MUST explicitly provide the profile, module selection,
  and system-change confirmation.
- AUR, archlinuxcn, DMS greeter source build and automated reboot each require
  separate confirmation flags. Official DMS shell packages use the normal
  official-package confirmation.
- There is no global `--yes` or equivalent bypass.

### DEC-UX-04 — Saved selections

Selections may be saved as a reviewable, credential-free manifest. A later run
must ask whether to reuse, edit, or replace that selection; it must not silently
reuse old choices.

### DEC-UX-05 — Visible stages and retry

The installer must show the current stage, completed work, exact failure and
safe retry path. It must persist non-secret stage state and eventually support:

- `--retry <module>` for a failed module;
- `--rerun` for an intentional rerun;
- skipping only stages whose completion was actually verified.

Retry must not weaken config overwrite, source or confirmation protections.

## 3. Repository and configuration privacy

### DEC-PRIV-01 — One layered personal-restoration repository

The intended repository is `tjz123psh/my-archlinux-setup`, with distinct
installer, manifest, configuration, test and documentation layers. It may be
published, but publication portability is secondary to reproducing the user's
own workstation. Publication never permits actual credentials or private key
material to enter the tree.

### DEC-PRIV-02 — Explicit whitelist only

The project MUST NOT collect or deploy an entire home or `.config` tree. Every
managed source and target must be explicitly reviewed and represented in a
version-controlled mapping or approved minimal tree.

Permanently excluded categories include credentials, SSH/GPG private material,
browser/chat/note state, cookies, tokens, caches, databases, machine IDs and
other private session/state data.

### DEC-PRIV-03 — Audit authorization

Audit proceeds in stages:

1. metadata-only inventory of agreed candidates;
2. private risk report where useful;
3. explicit file-level functional and secret review;
4. disposition for faithful personal restore as include or exclude;
5. optional separate portability notes as public include, sanitized include,
   template or exclude; and
6. only reviewed content enters mappings and the repository.

A directory-level approval must not silently authorize unrelated files.
Private reports remain local, mode `600`, and contain no matched values.

### DEC-PRIV-04 — Machine-specific configuration

For the primary `asus-amd-nvidia` restore profile, working output names,
resolutions, refresh rates, device bindings and other machine-specific settings
are expected configuration and may be enabled by default. A secondary generic
profile may use commented examples or manual steps, but that portability layer
must not weaken faithful restoration of the known ASUS target.

### DEC-PRIV-05 — Media

The first public release contains no wallpaper, avatar or third-party media.
Future media requires an explicit candidate path plus confirmed source,
redistribution permission and license. Media is never discovered through a
broad content scan.

### DEC-PRIV-06 — Personal scripts

Functional personal tools under `~/scripts/` may be restored through explicit
physical-profile mappings. Each executable still requires review for secrets,
destructive behavior, dependencies and machine assumptions, but a hard-coded
path or same-machine assumption is not by itself a reason to exclude it from
this personal restorer. VM defaults exclude this module.

### DEC-PRIV-07 — Credentials and manual completion

The installer and repository never migrate account credentials or perform
logins. The final report provides a credential-free manual completion list for
excluded items.

## 4. Config deployment, state and recovery

### DEC-CONFIG-01 — Selected-module config only

Shared config and each selected module's config are distinct. Selecting Niri
must not implicitly deploy Hyprland-only config, and selecting Hyprland must not
implicitly deploy Niri user-session config. Shared desktop config may be
installed once for either or both.

### DEC-CONFIG-02 — Backup before replacement

Approved config is deployed by default when its module is selected. Before an
existing changed target is replaced, the installer creates a timestamped
backup. Unlisted content remains untouched; there is no global force mode.

### DEC-CONFIG-03 — New and reconcile modes

- `new` deploys selected approved content on a clean target.
- `reconcile` first shows differences for the managed whitelist, then requires
  explicit config apply before backing up and replacing approved targets.
- `reconcile` does not claim ownership of unrelated local files.

### DEC-CONFIG-04 — Schema and migration

Installer state and managed config have schema versions. A known reversible
migration must show scope and backup first. Unknown local customization or an
irreversible migration stops that config module rather than guessing.

### DEC-CONFIG-05 — Restore is explicit

Backups are never automatically restored or deleted. The intended interface
includes read-only `--list-backups` and an explicit
`--restore-backup <id>` restricted to approved target scope. Restore first
backs up the current target and requires confirmation. Whole-home restore is
forbidden.

### DEC-STATE-01 — Private local state

State, detailed logs, backups, build artifacts and private audits live under
`~/.local/state/my-archlinux-setup/`, with restrictive permissions and no
uploads.

### DEC-STATE-02 — Retention

Keep the latest 10 detailed run logs, pruning older logs only after a successful
startup. Never automatically prune config backups or retained DMS build
evidence.

## 5. Package, privilege and failure policy

### DEC-PKG-01 — Full update first

Every real package apply starts with a visible `pacman -Syu`. If it fails, the
installer stops before later installation stages. Official and AUR packages
follow Arch rolling versions; fixed third-party downloads use pinned sources
and hashes.

### DEC-PKG-02 — Explicit module ownership

Every package belongs to one module and has a documented purpose and source.
The current machine's package inventory is only an audit candidate, never a
bulk install list. Missing/conflicting packages must not trigger guessed
substitutions, silent AUR fallback, or silent feature removal.

### DEC-PKG-03 — Complete golden-host package coverage

The normally working host's successful explicit package inventory MUST be
accounted for package by package before the personal restore is called complete.
The inventory is not itself a blind bulk-install command: every row still needs
a declared channel, restore responsibility and module/apply policy. A failed
inventory or source query is unavailable, never an empty package list.

Daily applications such as QQ (`linuxqq-appimage`), WeChat
(`wechat-appimage`), Obsidian (`obsidian-bin`) and Chrome are package-only:
install the declared package without migrating account/cache/profile data.
Packages that own the user's reviewed environment—such as Niri, Neovim,
Fcitx5/Rime, Fish and Kitty—are config-backed and pair package installation with
explicit `config-mappings.tsv` rows. This decision supersedes any implication
that the current 17-package executable starter or the 24-package Phase C subset
is the complete workstation software list.

### DEC-PKG-04 — Pacman and declared AUR channels

The first personal workstation restore plans packages obtained through pacman
repositories and declared AUR entries. Other application acquisition mechanisms
are ignored unless the user later adds one explicitly. archlinuxcn is a pacman
repository for planning classification but retains the separate authorization
and signature requirements in DEC-ARCHLINUXCN-01. AUR remains declared-package
only under DEC-AUR-01. This membership decision does not itself authorize a real
host, VM, repository or AUR apply.

### DEC-PRIVILEGE-01 — Ordinary-user main process

The main process MUST run as the invoking ordinary user. Only disclosed
system-level commands elevate. Config always targets that user's home, never
root's home. Source/build operations remain unprivileged unless a narrowly
specified system/chroot step requires elevation.

### DEC-FAIL-01 — Core versus optional failure

- Core module failure stops dependent work immediately.
- An independent optional module may fail while unrelated modules continue,
  but the final installer status remains non-zero.
- Failed or unavailable checks are never reported as passing or empty.
- No automatic package/service/system rollback is attempted.

The log records prior state, actual operations, exit statuses and manual
recovery guidance. Snapper rollback is available only when its selected module
is applicable and verified.

### DEC-REBOOT-01 — No automatic reboot by default

The installer reports whether a reboot/re-login is needed and lets the user
choose when. VM automation may reboot only through an explicit confirmation.

### DEC-PREFLIGHT-01 — Hard blockers

Before apply, hard blockers include unsupported OS/architecture, root execution
or unavailable sudo, network/DNS/mirror failure, pacman lock, insufficient disk
space and profile/hardware contradiction. Module-specific non-applicability,
such as Snapper on non-Btrfs, is reported as skipped/not-applicable rather than
falsely passed.

### DEC-PREFLIGHT-02 — Space estimates

The plan estimates space from selected modules and adds a 5 GiB general safety
margin. DMS chroot/source build uses its own estimate plus a 10 GiB safety
margin on relevant filesystems.

## 6. Hardware, locale and mirrors

### DEC-HW-01 — ASUS AMD + NVIDIA baseline

The primary hardware plan uses `linux`, `linux-headers` and
`nvidia-open-dkms`, gated by detected compatible NVIDIA hardware. A mismatch
must not force the driver; it directs the user to a compatible profile. VM
never receives the NVIDIA module.

### DEC-HW-02 — Kernels precede workstation automation

Kernel packages are selected during the user's manual base installation before
the section 9.1 handoff. The workstation installer detects those kernels and may
propose matching headers/DKMS support; it does not silently add/remove kernels,
change the GRUB default or rewrite the user's saved boot choice.

The manual ASUS baseline requires both `linux` and `linux-zen`; the standard
kernel remains the fallback. Matching `linux-headers` and `linux-zen-headers`
are future workstation-installer support effects. The installer does not choose
which GRUB entry is saved/default and does not automatically reboot.

### DEC-LOCALE-01 — Chinese defaults

`asus-amd-nvidia` defaults to `zh_CN.UTF-8` plus Fcitx5 and Rime.
`desktop-amd` and `vm` do not change locale by default; Chinese input remains an
explicit module. Locale uses `locale.gen` and `/etc/locale.conf`, and the final
report explains required re-login/reboot.

### DEC-MIRROR-01 — Mirror and repository separation

Keep the base install's official mirrors by default. An explicit
`china-mirrors` module may use reflector with official HTTPS mirrors.
archlinuxcn remains a separate third-party authorization, never an implicit
mirror fallback.

## 7. Niri, Hyprland, DMS and greetd

This section is a critical product contract.

### DEC-WM-01 — Both WMs are first-class and selectable

Niri and Hyprland may be installed individually or together. Their coexistence
is supported and must not be treated as a conflict.

The `asus-amd-nvidia` full preset DEFAULTS to both Niri and Hyprland, while the
execution plan allows either one to be cancelled. VM validates Niri only;
Hyprland remains a separate physical/manual acceptance path until an isolated
Hyprland test is designed.

### DEC-WM-02 — One shared desktop, two WMs

Niri and Hyprland are not independent desktop stacks. They share one desktop
foundation:

- greetd/DMS login path;
- DMS shell, status/notification/launcher/control center;
- theme, wallpaper and input method;
- shared applications and approved common autostart.

Niri/Hyprland-specific config owns only each compositor's rules, workspaces,
outputs, keybindings and required hooks. Each service has one startup owner;
duplicate startup is fixed or blocks inclusion.

### DEC-WM-03 — Selected configuration boundaries

- Niri selected: deploy shared + Niri config.
- Hyprland selected: deploy shared + Hyprland config.
- Both selected: deploy shared once plus both WM config sets.
- Neither WM is not a normal physical desktop selection.

### DEC-DMS-01 — DMS user configuration is shared desktop state

Working DMS user settings, monitor data, browser integration and reviewed plugin
files belong to `desktop-shared`. They restore independently of greetd or any
greeter package and are deployed once for Niri, Hyprland or both.

### DEC-DMS-02 — Greeter removed from executable profiles

Greeter installation is deferred and MUST NOT block the personal package/config
restore. No executable profile selects `dms-greetd` or
`dms-niri-greeter`. The unavailable registry rows and source-plan documents may
remain as historical planning evidence, but the user can complete greeter setup
later through DMS settings or a future separately approved system module.

### DEC-DMS-03 — No login-manager changes in the current path

The current installer does not install, configure, enable, disable or replace a
login manager. It does not manage `/etc/greetd`, guess a session, or require a
Niri greeter runtime. Any future login-manager work needs fresh inventory, a
reviewable system-change plan, rollback behavior and explicit approval.

### DEC-DMS-04 — No automatic SDDM fallback

Greeter deferral or failure must never trigger an automatic SDDM installation or
service change. SDDM can only be introduced as a future independently selected
and approved module.

### DEC-WM-04 — Packaged plain Hyprland is the first session baseline

Plain Hyprland session is selected for the first restore baseline. The packaged
`hyprland.desktop` entry launches `/usr/bin/start-hyprland`; the separate
`hyprland-uwsm.desktop` entry remains optional and is hidden when `uwsm` is
absent through `TryExec=uwsm`. Phase C therefore excludes `uwsm` rather than
installing a second session manager and its dependency stack. A future explicit
UWSM option may be reconsidered only after isolated lifecycle evidence; it is not
part of the current greeter or login-manager work.

### DEC-WM-05 — Portals follow the selected desktop session

Portal decision is closed for the first restore baseline:

- Niri only: `xdg-desktop-portal`, `xdg-desktop-portal-gtk` and
  `xdg-desktop-portal-gnome`;
- Hyprland only: `xdg-desktop-portal`, `xdg-desktop-portal-gtk` and
  `xdg-desktop-portal-hyprland`;
- both WMs: install the union of those four packages once.

The compositor packages already provide `niri-portals.conf` and
`hyprland-portals.conf`, selected by the active desktop session. No user or
system-wide global Portal override is generated. `xdg-desktop-portal-wlr`
remains excluded. These package choices remain planning-only until each selected
session passes clean-login, file chooser, screenshot and screen-sharing
validation and a separate apply transaction receives explicit approval.

### DEC-WM-06 — Shared startup ownership follows the session lifecycle

The shared Fcitx5 and Blueman applets have exactly one startup owner per active
session. Niri uses each package's XDG autostart entry through
`xdg-desktop-autostart.target`; the plain Hyprland baseline uses the existing
idempotent guarded commands in the mapped Hyprland autostart config. No second
Niri compositor command is added, and no duplicate owner is introduced when
both WMs are installed.

### DEC-SVC-01 — PipeWire and power policy owners are explicit

The first audio baseline uses PipeWire, `pipewire-pulse` and WirePlumber. Their
official package hooks own global user-unit/socket enablement; the installer
must not guess or add per-user enable commands. `pulseaudio`,
`pipewire-media-session`, JACK/JACK2 and competing power daemons are conflict
preflight blockers, not packages to remove or silently replace. The selected
`power-profiles-daemon` future action is an explicit system-service enable,
subject to prior-state inventory and approval.

## 8. DMS shell and fixed-source greeter supply chain

### DEC-DMS-BUILD-01 — Official shell exception; fixed greeter

The DMS user shell and compositor selectors use the signed rolling packages from
official Arch repositories, following the same official-package policy as Niri
and Hyprland. They MUST NOT fall back to AUR, archlinuxcn or a remote installer.

The DMS greeter MUST NOT use `-git` packages, rolling commits, an unreviewed AUR
recipe or a remote installer. Missing verifiable fixed greeter source blocks the
login module but must not force the independent official shell or unrelated
modules to fail.

### DEC-DMS-BUILD-02 — Accepted source and integrity

For the greeter, use an official release or publicly attributable upstream
tag/commit pinned in the repository. SHA-256 verification is mandatory. If
upstream signatures exist, verify and record the exact key fingerprint;
otherwise state honestly that source + hash were checked, not cryptographic
publisher identity.

### DEC-DMS-BUILD-03 — Clean chroot

Build the fixed DMS greeter package with Arch devtools in a dedicated clean
`makechrootpkg` chroot using official Arch repositories and keyrings only. Do
not inherit host AUR/archlinuxcn configuration and do not fall back when an
official dependency is unavailable.

The dedicated chroot lives under
`~/.local/state/my-archlinux-setup/builds/dms/chroot/`, is retained by default,
and is cleaned only through a scoped, confirmed command.

### DEC-DMS-BUILD-04 — Privilege and artifact verification

Source acquisition and build orchestration use the ordinary user; narrowly
disclosed chroot setup/update and final package installation may elevate.
Before installing the greeter with `pacman -U`, verify exact package name,
version, architecture, artifact
SHA-256 and package file list against version-controlled expectations. A
mismatch preserves evidence and installs nothing.

### DEC-DMS-BUILD-05 — Immutable release recipes

Each project Release pins an immutable DMS greeter recipe directory containing
source hashes, PKGBUILD, patches and expected artifact metadata. The greeter
does not self-update. Updating it requires a new project Release after
source/license/dependency review, clean-chroot build, static checks and clean-VM
regression. Official shell packages continue to follow the normal Arch rolling
update policy.

## 9. AUR and archlinuxcn

### DEC-THIRDPARTY-01 — Independent authorization

Official repositories are the default trust domain. AUR, archlinuxcn and DMS
source build each have separate authorization and cannot imply one another.

### DEC-AUR-01 — Fixed paru bootstrap and declared packages only

Paru bootstrap uses a reviewed fixed source/version/hash/license and an
unprivileged build directory. Only version-controlled AUR package entries may
be installed. The installer is not a general arbitrary-AUR-package interface.

A changed package version/source/PKGBUILD blocks that package pending renewed
review; the installer does not auto-edit or silently accept the recipe.

### DEC-ARCHLINUXCN-01 — Explicit signed repository setup

archlinuxcn requires explicit authorization, an explicit mirror/repository
section, expected keys and signature verification. Key, mirror, database,
source or signature anomalies stop that module without switching to another
third-party source. The two fixed pacman configuration targets are committed
conditionally with no-replace/exchange identity checks; a concurrent
administrator entry is restored or retained at a reported recovery path rather
than overwritten.

### DEC-THIRDPARTY-02 — No automatic removal

The installer does not automatically uninstall AUR/archlinuxcn/DMS packages or
remove third-party repositories/keys. State and final reports list changes and
manual recovery steps.

## 10. Bootstrap and release trust

### DEC-RELEASE-01 — Reviewed path first

README recommends download, verify, inspect and execute. A convenience one-line
entry may exist only as a small version-fixed bootstrap and must not nest
unreviewed remote scripts.

### DEC-RELEASE-02 — Immutable release target

The bootstrap targets an explicit GitHub Release tag, never moving `main`, and
displays source and version.

### DEC-RELEASE-03 — Hash and signature

Every Release publishes `SHA256SUMS` and `SHA256SUMS.asc`. The bootstrap always
verifies archive SHA-256. Signature verification is default and accepts only a
pre-imported key matching the documented full primary fingerprint. A deliberate
`--skip-signature-check` may skip signature validation, never hash validation.

### DEC-RELEASE-04 — Key management

Use a project-specific offline primary OpenPGP key and expiring signing
subkeys. Publish the full primary fingerprint and rotation history; do not trust
by UID/email or auto-import from an unknown keyserver.

## 11. Validation and release gates

### DEC-VALIDATE-01 — Static and CI boundary

Static validation covers Bash syntax, ShellCheck, argument/module parsing,
manifest/mapping integrity and release hash/signature structure. GitHub Actions
must remain unprivileged and must not pretend to perform local KVM graphical
coverage.

### DEC-VALIDATE-02 — Clean local VM

KVM/libvirt + virt-manager provides the clean-Arch acceptance environment. VM
creation is documented, not performed by the installer. Start regression from
a verified clean baseline snapshot.

The VM profile validates official-source install, default skip boundaries,
state/logging, safe rerun, Niri graphical session and key commands/services.
It does not replace physical GPU/login/hardware acceptance.

### DEC-VALIDATE-03 — Physical acceptance

Manual physical checks include graphical login, Niri, Hyprland when selected,
network, audio, Bluetooth, sleep/wake, outputs, AMD/NVIDIA driver state, Chinese
input and post-login environment. Module-specific features are checked only
when selected and are never auto-marked passed.

### DEC-VALIDATE-04 — Evidence

Each release stores a sanitized `docs/validation/` summary. Raw logs remain
local and must not publish usernames, hostnames, IPs, UUIDs or full private
logs.

## 12. Superseded interview decisions

These earlier answers MUST NOT be reintroduced:

| Earlier decision | Final replacement |
| --- | --- |
| DMS always skipped by default | Generic/VM defaults skip it, but the primary physical full preset preselects it with separate disclosure and authorization. |
| Automatically fall back to SDDM when DMS fails | No automatic SDDM installation or enablement; stop/preserve/retry the login module. |
| Do not migrate any personal scripts | Audited public-safe scripts may be an explicit physical-only module. |
| Support only Niri as the install target | Niri and Hyprland are first-class, individually selectable and supported together. |
| Do not choose a first DMS session | First session defaults to Niri; preserve last successful choice when safely supported. |
| Build the DMS greeter directly with host `makepkg` | Use an official-source-only clean `makechrootpkg` chroot. |
| No existing-system alignment in the first release | A narrow whitelist-only `reconcile` mode is required for the known Niri + Hyprland + DMS stack, without general convergence promises. |
| Main-model-only review because an old reviewer interrupted | Current `AGENTS.md` requires an independent read-only reviewer for complex/high-risk work when available; an unavailable reviewer must be reported, not treated as passing. |

## 13. Current production-candidate implementation choices

These implementation choices realize the confirmed semantics but are not
misrepresented as verbatim interview answers. Any later change must update the
manifests, tests and this section together.

### IMPL-C-01 — Versioned TSV module/effect contract

Schema-marked TSV files own module/profile selection, independent full-DAG
production readiness, the 200-row package policy, 198 config mappings, 30 system
actions, nine DAG stages, canonical executables and auxiliary trust inputs.
`--modules` is an exact requested set;
`requires-all` closure is disclosed and an unsatisfied `requires-any` remains an
error rather than an inferred choice.

### IMPL-C-02 — WM/profile defaults

`asus-amd-nvidia` defaults to both WMs. `desktop-amd` and `vm` default to Niri
and expose Hyprland disabled but explicitly selectable. `vm-v1` has a dedicated
36-row payload and supports Niri-only, Hyprland-only and both-WM validation.
Selecting one never deploys the other's owned config.

### IMPL-C-03 — Greeter remains separate

`dms-greetd` and `dms-niri-greeter` remain unavailable, unoffered placeholders;
no profile silently selects them and no SDDM fallback exists. DMS user config is
independently owned by `desktop-shared`. Automatic-stage completion may still
contain pending/manual/deferred acceptance and is never called full workstation
completion.

### IMPL-C-04 — Canonical nine-stage orchestrator

`installer/full-orchestrator.py` owns the production candidate. It loads the
canonical executable manifest by default and derives privilege wrapper,
official update/packages, archlinuxcn bootstrap/packages, AUR source/build,
user-config and system-actions stages. The two wrapper mappings are owned only by
the first stage.

Every applicable stage implements a zero-write preflight before confirmations or
run state. System, archlinuxcn and AUR confirmations are independent. Private
schema-3 state is bound to profile/mode/selection, stage effects, executable
hashes, selected config payloads and auxiliary Arch/AUR inputs. Retry/resume
verifies prior passes; optional branches continue independently; `--rerun`
creates a new run; `--stop-after-stage` creates a safe exit-75 resume boundary.

The canonical manifest cannot override a false stage integration flag, an
external manifest cannot authorize apply, and the separately hashed
`production-module-readiness.tsv` remains an independent blocker. The completed
candidate and clean canonical VM matrices promoted all nine stage flags plus
exactly five registry availability fields. The module-level DAG batch
(2026-08-04) then verified `daily-apps`, `repository-tools`,
`development-toolchain` and `personal-autostart` in a full nine-stage run;
batches 2026-08-05 and 2026-08-06 extended this to `cli-tools`,
`desktop-apps`, `ocr`, `recording`, `graphics-amd`, `graphics-nvidia`,
`hardware-tools`, `kernel-support`, `bluetooth`, `power`, `container-tools`,
`storage-maintenance` and `virtualization`, so
the production registry authorizes twenty-six modules (26 available, 4 planning,
2 unavailable); reviewed config availability therefore cannot expose an
unproved package, AUR or system effect. The legacy `install.sh` changing paths
are disabled outside exact temp regression roots.

### IMPL-C-05 — Reversible VM candidate gate

`vm-candidate-gate.py` may change only `modules.tsv` and `stages.tsv` inside an
approved VM checkout. It requires exact confirmation and successful VM
detection, privately backs up closed manifests, promotes only the five VM
planning modules and nine stage flags, is idempotent and refuses concurrent
drift. Restore is hash-bound. It performs no package/service/system action and
does not promote the main checkout automatically. The candidate cycle is now
complete: on the promoted canonical tree `--plan` reports `already-promoted`
with zero changes and a fresh `--enable` is rejected before VM detection/state.

## 14. Open decisions/evidence gates

Do not guess these during implementation:

1. Exact fixed DMS greeter upstream release/tag/hashes, if the deferred greeter
   is ever resumed.
2. Physical ASUS/hybrid-GPU/display, Bluetooth/real-audio, suspend/resume,
   boot/recovery and any root-equivalent group decision that VM evidence cannot
   settle.
3. Exact source/cache and runtime evidence for the 12 fixed AUR recipes outside
   the promoted VM selection and every production-planning module. The current
   readiness manifest keeps all of them blocked, including FlClash.
4. Log pruning timing/details beyond the confirmed “keep latest 10 after a
   successful startup” rule.

The dedicated libvirt lab definition, candidate Niri/Hyprland/both matrix,
canonical no-candidate matrix, fresh rollback probe and post-review final-tree
both-WM spot run are recorded completed VM evidence, not open decisions. Their
scope does not satisfy the physical or production-planning items above.
