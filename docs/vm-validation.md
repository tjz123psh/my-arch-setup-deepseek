# Snapshot-backed VM validation gate

This document defines the acceptance sequence; it is not authorization to create
or change a VM. Before any real step, inventory the actual libvirt/QEMU/domain/
storage/snapshot state, preserve failed-query exits, present the exact commands
and rollback points, and obtain explicit approval.

The command-level plan, inventory classifications, retained failures and rollback
scope are in [`vm-execution-plan-20260801.md`](vm-execution-plan-20260801.md).
Phase 1 and the disposable candidate/canonical work were explicitly approved.
Final Niri, Hyprland and both-WM candidate children, the promoted no-candidate
canonical matrix and a fresh residue probe are complete. Every child was shut
down and checked offline before deletion; the immutable baseline digest stayed
unchanged. The dedicated session pool is now stopped and undefined without
removing lab files. This evidence authorizes only the exact VM-proven gates and
never substitutes for physical acceptance.

## Baseline boundary

The VM begins at the same handoff as the physical restorer:

- x86_64 Arch base already installed and booted;
- disk/partition/filesystem/bootloader work complete;
- systemd and pacman functional;
- NetworkManager active with working network and DNS;
- one ordinary user with the pre-approved sudo authorization needed by the
  reviewed `gsudo` flow after the first config stage; clean-base NOPASSWD does
  not require Fuzzel, while a password-requiring path must use the helper's
  explicit fixed `systemd-ask-password` fallback until Fuzzel is installed;
- no copied credentials, host keys, machine ID, NetworkManager secrets, private
  logs, host UUID/MAC/IP or account profiles.

The base snapshot is taken **before** candidate manifests or installer apply.
Each WM scenario starts from that same clean snapshot or a proven equivalent
clone. A VM result never substitutes for physical ASUS/GPU/Bluetooth/audio/
suspend/boot/recovery evidence.

## Current code state

The `vm` profile uses `vm-v1`, not `none`. It has 36 mapped rows and four
VM-specific payloads under `config/vm/home/`. Exact config totals are:

| Selection | Total targets | DAG split |
| --- | ---: | --- |
| Niri-only/default | 35 | 2 privilege-wrapper + 33 user-config |
| Hyprland-only | 35 | 2 + 33 |
| both WMs | 36 | 2 + 34 |

All nine canonical handlers and auxiliary inputs are present. Every stage
integration flag is true and exactly `base-preconditions`, `archlinuxcn-trust`,
`build-foundation`, `fonts` and `audio` registry fields were promoted after the
candidate matrix. The later independent production-readiness manifest is also a
plan input: it marks the nine modules present in exact VM selections available,
21 other modules planning and 2 greeter modules unavailable. Thus reviewed
config availability cannot authorize an unselected effect; all 12 non-VM AUR
recipes, including FlClash, remain blocked.

Read-only plans are safe before approval:

```bash
python installer/full-orchestrator.py --profile vm --plan --json
python installer/vm-candidate-gate.py --plan --json
bash tests/static-check.sh
```

The second command now reports `already-promoted`, zero stage/module changes,
`requires_vm=false`, and matching current/candidate hashes. It performs no VM
query and writes no state.

A post-matrix independent review found and locally reproduced two fail-closed
defects. The archlinuxcn helper now conditionally exchanges its two fixed targets
and verifies displaced bytes/hash/mode/UID/GID/device/inode, preserving recovery
entries on rollback uncertainty. The new production-readiness input closes the
unproved `personal-autostart`/FlClash path and audits the other four registry-
available modules absent from VM selections. Because these changed the archive,
plan fingerprint and adapter hash, a fresh final-tree both-WM spot run—not the
older matrix—was required and completed as recorded below.

## Historical candidate gate inside the approved VM

Before promotion, each approved clean candidate used:

```bash
python installer/vm-candidate-gate.py --enable --confirm-vm-candidate
python installer/vm-candidate-gate.py --status --json
```

On a closed candidate checkout, `--enable` refused root, required successful VM
detection, privately backed up exact manifest bytes, atomically changed only
those two files, was idempotent for that cycle and refused drift. On the current
promoted canonical checkout a fresh `--enable` is rejected before VM detection
or state creation; the historical transaction must not be restarted.

The exact rollback is:

```bash
python installer/vm-candidate-gate.py --restore --confirm-vm-candidate
```

Restore accepts only the recorded candidate/original hashes and refuses to
overwrite concurrent checkout edits. The VM snapshot remains the higher-level
rollback for all package/repository/service/config effects.

Candidate success did not promote the host checkout automatically. Promotion was
a separate reviewed two-manifest edit whose resulting hashes matched final
candidate evidence; the clean canonical matrix then ran from fresh children
without candidate-only state.

## Exact WM module sets

Use exact non-interactive selections:

```bash
niri_modules='desktop-shared,wm-niri,input-fcitx-rime,base-preconditions,build-foundation,fonts,audio'
hypr_modules='desktop-shared,wm-hyprland,input-fcitx-rime,base-preconditions,build-foundation,fonts,audio'
both_modules='desktop-shared,wm-niri,wm-hyprland,input-fcitx-rime,base-preconditions,build-foundation,fonts,audio'
```

For each variable, first retain the JSON plan and exit status. The real command,
only within an explicitly approved disposable VM, is structurally:

```bash
python installer/full-orchestrator.py --profile vm --modules "$niri_modules" \
  --mode new --apply \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
```

Substitute the other exact module variable for its scenario. The canonical
`stage-executables.tsv` is loaded automatically; do not pass an external
manifest. Before accepting the plan, require:

- `production_apply_integration=true`;
- no `non_integrated_stages`, `missing_adapter_stages`, noncanonical adapter or
  non-executable module blocker from the independent production-readiness
  manifest;
- exact expected effect counts and WM-disjoint config effects;
- the same canonical adapter/input fingerprint throughout the run.

## Per-scenario matrix

Each of Niri-only, Hyprland-only and both-WM must prove:

1. **Initial apply** from the clean snapshot, including wrapper bootstrap, the
   initial official full update, the explicit conditional post-archlinuxcn-trust
   full-system/repository refresh, exact official/archlinuxcn/AUR transactions,
   config and automatic system actions. Record whether sudo was NOPASSWD or prompted; if prompted
   before Fuzzel installation, verify the warning and fixed systemd fallback
   without recording the entered password.
2. **Graceful interruption/recovery** without killing pacman mid-transaction:
   run once with `--stop-after-stage aur-source-acquisition` (expected exit 75),
   inspect schema-3 state, then rerun the exact command with `--resume` and the
   same confirmations. Prior passed stages must verify before skip.
3. **Failure/retry** using an isolated, deliberate boundary failure that does
   not corrupt package state (for example controlled network loss before source
   acquisition), preserving the external exit, then `--retry-stage` or
   `--retry-module` after recovery.
4. **Idempotence** via `--rerun`: update/install actions converge, exact config
   is unchanged, no duplicate repo/include/environment/wants entry appears, and
   the first replacement backup is not overwritten.
5. **Reboot/relogin**, then full adapter verification and read-only session
   checks.
6. **Config restore**: list backups, restore one approved backup with exact typed
   confirmation, verify the pre-restore rollback ID, then restore that rollback.
7. **VM rollback** to the clean snapshot and post-rollback comparison proving
   candidate package/repository/service/config/state effects are absent.

Preserve exact process exits and concise sanitized evidence. A query failure is
not an empty result; an unavailable checker/reviewer is not a pass.

## Graphical/session acceptance

After reboot, log in manually to each installed session (no greeter automation is
introduced by this project) and run:

| Installed set | Active login | Automated checker |
| --- | --- | --- |
| Niri only | Niri | `python installer/phase-c-session-check.py --profile vm --session niri --json` |
| Hyprland only | plain Hyprland | `python installer/phase-c-session-check.py --profile vm --session hyprland --json` |
| both | Niri | `python installer/phase-c-session-check.py --profile vm --session niri --selection both --json` |
| both | plain Hyprland | `python installer/phase-c-session-check.py --profile vm --session hyprland --selection both --json` |

`--profile vm` keeps Portal, audio, failed-unit and selected startup ownership
strict, while classifying Bluetooth/Blueman and power-profile package, service,
D-Bus and controller checks as `not-applicable`. Those remain required by the
default `physical` profile and must not be inferred from a VM result.

Exit `0` means only the automated checks are ready. Exit `1` is a deterministic
blocker; exit `2` is unavailable/failed query and must never be called empty or
passing. For both-WM, validate both active logins from the same installed state.

Manual checks after automated readiness:

- compositor starts with the mapped VM config and the other WM's config is absent
  in single-WM scenarios;
- DMS starts exactly once where selected;
- Fuzzel and Fcitx5/Rime work in a clean login;
- file chooser, screenshot and browser/application screen sharing use the
  correct Portal backend set;
- PipeWire playback and recording work;
- failed system/user unit queries are successful and empty, not failed;
- logout/login and reboot preserve session ownership and user wants.

Bluetooth controller, power-profile, suspend/resume and audio device behavior in
virtual hardware are recorded only as VM results. Physical equivalents remain
separate.

## Evidence and rollback record

For each run, retain under a private VM evidence directory:

- sanitized base image/ISO/package database dates;
- domain/storage/snapshot labels without UUID/MAC/IP;
- plan JSON and exit;
- candidate gate status and hashes;
- schema-3 run state and concise stage exits;
- package/source/artifact/config/system-action provenance;
- reboot/session checker JSON and manual checklist;
- backup/restore IDs;
- snapshot rollback command/exit and post-rollback comparison;
- every blocker, failed query and unavailable check.

Commit only a concise sanitized summary under `docs/validation/`; never commit
credentials, raw private logs or machine identifiers.

The official image has been signature/checksum verified and the clean
NetworkManager/GRUB/dual-kernel baseline is frozen read-only. Eight disposable
Niri children preserve successive preflight, transaction, failure/retry and
recipe defects rather than erasing them. The eighth child completed the real
candidate transaction, idempotence, config restore, reboot and broad graphical
acceptance. Candidate-manifest restore and overlay rollback are still pending,
and its checkout predates the final VM-profile session-checker repair.

## Historical execution checkpoint — 2026-08-01

The frozen clean baseline and first Niri child were created. The checkout-only
VM candidate gate was enabled inside that disposable child and the exact nine
stage plan was accepted. Its first global preflight exited `1` before any
confirmation, run-state creation or execute action. Package inventory remained
identical to the frozen baseline. Three clean-base adapter defects were then
reproduced with red tests and repaired locally: pending privilege wrappers for
`archlinuxcn-packages` preflight, removal of the later AUR provider `fuzzel` from
base commands, and a real fixed `core/pacman` repository reachability identity.
A rebuilt archive and fresh child passed clone/candidate/canonical-plan checks,
but its next global preflight exposed a fourth dependency-order defect:
`archlinuxcn-packages` required repository/keyring bootstrap before the earlier
bootstrap stage could run. It also stopped with zero package/apply-state writes;
the local regression now treats only planner-approved absent/refresh bootstrap
as expected-pending and keeps execute/verify strict. This fourth fix is not yet
VM-accepted.

The following fresh run passed every global preflight and executed the wrapper
plus initial official update, but the official package stage exited `1` at
pacman's confirmation prompt because adapter stdin is `/dev/null` and the fixed
argv lacked `--noconfirm`. Pacman and its lock were absent afterward; dependent
stages were recorded as skipped. Red regressions now require explicit
noninteractive argv for official update/packages and archlinuxcn
refresh/packages, all behind the existing orchestrator confirmations. This
fifth fix also requires another fresh-overlay acceptance rather than patching
the changed guest checkout.

The same local repair batch also closes confirmed independent-review issues in
conditional target replacement, same-run system-action rollback evidence and
explicit display of the conditional post-archlinuxcn-trust full refresh. The
full required static suite passes, but none of those fixes is VM-accepted yet.
The existing child will be gracefully discarded after preserving its failed
preflight evidence; the reviewed archive will be rebuilt and the Niri path will
restart from a new overlay. Hyprland-only, both-WM, rollback probe, canonical
post-promotion matrix and graphical acceptance remain unrun.

A later SSH recovery query against the old running child was not successful:
strict transport exited `255` / connection closed and 15 polls did not become
ready before a 150-second local timeout, although guest-agent ping succeeded and
`sshd.service` queried active. This is a failed/unavailable transport check, not
healthy connectivity; the fresh-overlay restart remains the recovery boundary.

The first noninteractive package run then hit a genuine mirror failure: official
package downloads returned SSL EOF/low-speed timeout errors, pacman reported no
packages upgraded, and its process/lock were absent. Same-run retry verified and
skipped the wrapper/update stages, completed official packages and archlinuxcn
bootstrap, then the archlinuxcn package transaction exited `1`; its read-only
transaction plan still resolved exactly two packages with no conflict, and a
second same-run retry verified all earlier stages and completed both packages.
This proves external failure preservation plus stage retry on the disposable VM.

That retry reached exit `75`, but state inspection found
`aur-source-acquisition=passed`: when the requested archlinuxcn stop stage had
failed on the prior attempt, the scheduler continued an independent AUR branch
and crossed the stop boundary. A red regression now makes stop-after a hard
failure fence, leaving later stages pending. Because the current checkout
fingerprint changed and its source cache is populated, it is retained only as
failed evidence and another fresh child is required. At the pre-Fuzzel boundary,
the real fixed systemd askpass fallback was successfully exercised through a
PTY using a disposable noncredential marker; only status and warning/answer
boolean matches were retained.

On the next full resume, AUR source retry and its graceful stop passed, but the
clean-chroot build failed immediately. Its private log reproduced current
`mkarchroot` behavior: it resolves `<chroot>/root` with `readlink -f`, while the
adapter had created only `<chroot>.parent`; the missing immediate parent produced
“Please specify a working directory” / exit `255`. The old code also collapsed
that child status to `1`. Red tests now require the private chroot base to exist
before invocation and require exact high exit preservation. The simultaneous
`dsearch-user-service` system-action failure was an honest downstream missing
AUR package; it will be retried after a successful build. Because child-tool and
fingerprint hashes changed, this overlay is evidence only and cannot be patched
in place.

The sixth fresh Niri child then reached the real clean-chroot build boundary.
Its controlled source failure and retry reconfirmed the hard stop fence, exact
`/etc/hosts` restoration and three-attempt source provenance. The clean chroot
initialized and updated successfully; `dsearch-bin` and
`fcitx5-skin-fluentdark-git` built, and `fuzzel-ime-git` source verification
passed. Meson then reported the missing Cairo dependency and the stage preserved
exit `255`. `user-config` passed independently. A successful read-only
structured query of durable action state confirmed that the sole
`system-actions` failure was `dsearch-user-service`, downstream of the
all-or-nothing AUR install fence.

A regression first failed on the missing runtime declaration. The fixed
`fuzzel-ime-git` `PKGBUILD` and `.SRCINFO` now include `cairo`; canonical tree
and policy-input digests were refreshed. Targeted AUR/input tests, the complete
static suite, standalone documentation checks and whitespace checks pass, with
generated bytecode removed. This local fix still requires a seventh fresh Niri
overlay. The current guest is retained only long enough for graceful/offline
rollback handling and must not be patched in place. Graphical acceptance,
idempotence, config restore, candidate-manifest restore, Hyprland-only, both-WM,
post-promotion canonical runs and the physical-only checks remain unrun.

The seventh fresh Niri child did not qualify as the required Cairo-fix rerun.
It passed baseline, archive, candidate-plan and initial package boundaries, but
the command-level execution document omitted the command-scoped
`--stop-after-stage aur-source-acquisition` flag from the controlled-failure
resume. Source acquisition preserved exit `2`, while its dependent AUR build was
skipped and independent config/system-action branches executed. This is failed
procedural evidence, not a hard-fence pass. A red documentation regression now
requires the parameter on both that resume and the bounded source retry. Hosts restoration, mode,
external resolver recovery and backup removal all passed. The child will be
discarded without an in-place checkout update, and an eighth fresh overlay is
required before the Cairo dependency fix can be called VM-accepted.

## Eighth Niri candidate evidence — complete apply and graphical session

The eighth fresh child repeated the 210-package frozen-baseline comparison,
successful-empty system/user failed-unit queries, project/state absence checks,
435-member allowlisted archive verification, reversible candidate enable and
exact nine-stage plan. The initial package boundary exited `75`. The real
pre-Fuzzel `systemd-ask-password` fallback passed without retaining its
noncredential marker. A controlled source failure preserved exit `2` and the
command-scoped stop fence kept the AUR build, user config and system actions
pending. `/etc/hosts` was restored byte-for-byte and by mode, bounded resolver
recovery passed, the `/run` backup was removed, and the source retry stopped at
exit `75` before a full resume completed all nine stages with exit `0`.

The private clean chroot built and installed all three fixed AUR recipes,
including `fuzzel-ime-git` with its Cairo runtime dependency. Exact installed
version/source/reason checks passed; stable `fuzzel` remained absent and
`/usr/bin/fuzzel` belonged to `fuzzel-ime-git`. `dsearch.service` was enabled and
active, and both failed-unit queries succeeded with empty arrays. An unchanged
rerun kept the package manifest, 35 config target hashes/modes, repository
fragment and backup inventory unchanged. A mapped Fuzzel config drift then
proved deployment backup, cancelled zero-write restore, exact restore,
pre-restore rollback creation and rollback restore. All three private backup
records remain complete/restorable. A post-restore official-mirror timeout made
`aur-build-install` exit `1`; a later exact HTTPS check passed and a stage-only
retry returned `0`. One user-manager query also briefly exited `1`; the later
diagnostic and three bounded rechecks succeeded. Neither transient failure is
reported as healthy.

The guest reboot request returned `0`, libvirt still reported the domain
running, and strict SSH observed a changed boot identity without retaining the
identity itself. The post-reboot canonical rerun returned `0`; packages,
configs, backup inventory, candidate state, NetworkManager, dsearch, failed-unit
queries, Niri parser and Fuzzel provider all reverified.

A real tty1/logind Niri session then proved tty autologin, `/usr/bin/niri-session`,
DMS exactly once, Kitty, Niri-only config exclusion, Fuzzel, the installed
Fuzzel askpass branch with masked input, Fcitx5/Rime Chinese candidates, Niri's
screenshot UI and a valid saved PNG, and the standard Portal file chooser.
ScreenCast `CreateSession`, `SelectSources` and `Start` all returned `0` with one
stream; no request/session handle, PipeWire node ID, bus name or raw stream was
retained. Two earlier user-interaction delays produced `TimeoutError` and remain
private failed evidence. PipeWire exposed one sink and one source, `pw-play`
returned `0`, and a finite `pipewiresrc` recording to `fakesink` returned `0`
without retaining audio. A separate manually interrupted `pw-record` produced a
valid positive-frame WAV but exit `1`; that exact nonzero result is retained and
was not used as the passing recording probe.

The guest's older `phase-c-session-check.py` returned exit `2`: strict Portal,
audio, Fcitx, bus and failed-unit checks passed, but it incorrectly applied
physical Bluetooth/Blueman/power requirements to the VM. The host tree now has
an explicit default-physical/opt-in-VM applicability model, VM-specific Niri and
Hyprland startup paths, and separate audio versus physical-power conflict
checks. Red-then-green regressions cover both VM sessions, missing Fcitx, failed
applicable audio queries, audio conflicts and nonapplicable power conflicts;
the default physical contract remains strict. Because the eighth checkout was
never patched in place, a fresh final archive and later child must run the new
checker with `--profile vm` before Niri is fully accepted.

Current rollback boundary: the eighth domain remains running only while its
private evidence is finalized. Next, rebuild the allowlisted archive, privately
retain the eighth archive/status/log/screenshots, gracefully shut down, require
bounded shutoff, undefine with NVRAM, run an offline qcow2 JSON check and delete
only its child overlay. Then create the next child from the immutable mode-440
baseline, run the final checker, restore candidate manifests and complete the
overlay rollback. Hyprland-only, both-WM, post-promotion canonical runs and
physical-only checks remain pending.

## Ninth Niri attempt — external download failure and completed reviewer repair

The ninth child used the first archive containing the explicit VM-profile
checker. Baseline package/failed-unit/project-absence checks, the 435-member
archive, reversible candidate enable and the exact `2,1,55,1,2,3,3,33,29`
canonical plan all passed. The first official package transaction and two exact
stage retries failed with exit `1` because the official mirror repeatedly
returned low-speed timeouts and SSL EOF. An exact HTTPS HEAD between attempts
returned `0`; that did not erase the later transfer failures.

The fourth retry's SSH transport returned `255`, but this was not called a stage
result. A later strict SSH query and guest-agent ping both succeeded. Durable
state then showed official packages, both archlinuxcn stages, AUR source and user
config passed; clean-chroot initialization failed with exact `255` after the
same timeout/SSL/download class, and system actions failed `1` because dsearch
was not installed past the all-or-nothing AUR fence. Pacman was absent, its lock
was absent, the package query succeeded with 676 packages, and the private run/
AUR logs are retained. Since an independent review simultaneously required new
checkout fixes, no further retry or guest patch was valid. The child shut down
gracefully, was undefined with NVRAM, passed its offline qcow2 check and had only
its child overlay deleted.

The completed independent reviewer produced five findings, all reproduced on
the current tree before editing:

1. config restore could delete a second concurrent writer after a rollback
   exchange;
2. VM candidate enable/restore had a hash-check-to-`os.replace` race that could
   overwrite a concurrent manifest edit and still return success;
3. canonical config-only and `none` plans were falsely rejected when no
   auxiliary input row applied;
4. VM power conflicts were omitted correctly but the merged check falsely
   reported both audio and power as passing;
5. a commented or unreachable Hyprland command could be treated as an executable
   startup owner.

Red-then-green regressions now require conditional `renameat2` exchange and
post-exchange identity checks for config restore and all four candidate manifest
writes, preserve conflicting recovery files, prevent stale terminal candidate
states, allow config-only plans while requiring per-stage auxiliary coverage,
split audio conflict checks from VM-not-applicable power checks, and require the
startup guard as a direct statement inside an executable
`hl.on("hyprland.start", ...)` callback. Targeted config/candidate/orchestrator/
stage-input/Phase-C suites pass. The reviewer's direct Hyprland runtime parser
ended by signal 6 in its restricted review environment and is unavailable there,
not passing; the normal project suite must rerun its installed validators before
a new archive.

That next action was completed by the tenth fresh Niri child; the later sections
retain its exact failure/retry and rollback evidence. It is no longer a pending
instruction.

## Final-tree Niri acceptance and first Hyprland retry defect — 2026-08-02

A tenth fresh Niri child used the post-review archive. Its immutable baseline,
435-member archive, conditional candidate enable and exact canonical plan passed.
The first apply completed every independent branch but preserved
`archlinuxcn-bootstrap` download exit `7`; both fixed asset HEAD queries then
returned `0`, and an exact stage retry completed all nine stages. An unchanged
rerun returned `0`. Reboot was proved by changed boot identity without retaining
the identity.

Inside the real Niri Wayland/logind session, the new checker ran through the
systemd user-session environment and returned exit `0` / `overall=ready` with no
blockers or unavailable checks. Portal, audio conflicts/runtime, Fcitx owner,
user bus and successful-empty failed-unit checks remained strict; physical
power/Bluetooth ownership and power conflicts were explicitly
`not-applicable`. The conditional candidate restore returned the exact original
hashes, a second restore was idempotent, and the closed checkout again exposed
all nine integration plus planning-module blockers. Graceful shutdown, offline
zero-error qcow2 check, immutable baseline digest check and child-only deletion
completed the Niri rollback.

The first fresh Hyprland-only child then passed baseline/archive/candidate/plan
and all stages through AUR source. Clean-chroot initialization preserved exit
`255` for timeout/SSL/download failure; user config passed and system actions
honestly failed only because dsearch was behind the all-or-nothing AUR fence.
A later official HEAD returned `0`, but `--retry-stage aur-build-install` could
not start: the failed `mkarchroot` had left a root-owned partial chroot and old
preflight returned exit `1` / incomplete. This is retained failure evidence, not
a network retry pass.

A red regression now makes failed initialization create a partial root and
requires the same state to retry successfully. The fixed tool removes only the
known private `root` and `root.lock` via the audited wrapper and exact
`/usr/bin/rm -rf --one-file-system --preserve-root=all --` argv, then removes the
ordinary-user empty base. Unknown content or cleanup failure is retained for
review; the original external status remains the reported build failure.
`aur-build`, AUR-stage, executable/input pin and syntax tests pass. The failed
Hyprland child was never patched; it shut down, passed offline checking and had
only its overlay deleted. That new archive/fresh Hyprland child was required and is completed below.

## Final Hyprland and both-WM candidate results — 2026-08-02

The fresh post-fix Hyprland candidate completed the exact
`2,1,55,1,2,3,3,33,28` plan after a bounded official mirror retry. Its unchanged
rerun, reboot identity change, single-WM config/process boundary and direct DMS
graphical-environment checker all passed with no blocker/unavailable result.
The user-manager-only checker retained the known plain `start-hyprland` session
environment limitation. A noninteractive `org.freedesktop.portal.Screenshot`
request returned response code `2`; it is unavailable visual evidence, not a
pass. Candidate restore and second restore matched originals, the closed plan
returned all nine blockers, and offline rollback passed.

The fresh both-WM candidate used exact effects `2,1,58,1,2,3,3,34,29`. Apply,
rerun and reboot passed. A clean Niri login and a separately renewed tty/login
Hyprland session each returned `overall=ready` with `--selection both`. Niri
produced a guest-owned valid 1280×800 PNG whose frame and DMS UI were readable.
Hyprland Portal screenshot again returned code `2`. Compositor shutdown under
the intentionally persistent SSH user manager left prior-session DMS/Portal
units failed; their exact set and broken-pipe/lost-compositor logs were retained,
then an exact reset made the final failed-unit query empty. Candidate restore,
idempotent restore and child-only rollback passed.

## Gate promotion and clean canonical matrix — 2026-08-02

The host pre-promotion candidate hashes matched the final Niri and both evidence.
Only nine `false→true` stage fields and five `planning→available` module fields
changed. The candidate planner now reports `already-promoted`; promotion tests
failed before the edit and pass afterward. Host plans show the three exact effect
vectors, canonical adapter ownership and empty apply blockers.

Three new baseline children then ran without candidate enable/restore state:

| Scenario | First/final automatic run | Unchanged rerun | Session result | Rollback |
| --- | --- | --- | --- | --- |
| Niri | official mirror exit `1`, bounded HEAD + exact retry, all 9 passed | exit `0`, 35 unchanged targets | Niri/selection=niri ready | offline zero errors |
| Hyprland | all 9 passed | transient AUR source exit `2`, three HEAD queries + exact retry, final clean rerun `0` | Hyprland/selection=hyprland ready | offline zero errors |
| both | all 9 passed | exit `0`, 36 unchanged targets | clean Niri and clean Hyprland/selection=both ready | offline zero errors |

Every reboot changed boot identity without retaining the raw identity. Failed
external queries remained distinct from successful empty results and were never
renamed as passes.

## Fresh residue probe and lab closeout

A fresh child from the unchanged baseline matched the original 210-package list.
Structured checks found no checkout/private installer state, selected package,
mapped Niri/Hyprland/DMS/Fcitx config, privilege wrapper, DMS wants link,
dsearch unit, managed archlinuxcn fragment/include/section or Fcitx entries in
`/etc/environment`; system and user failed-unit queries succeeded empty. The
probe passed offline qcow2 checking and only its overlay was deleted. After all
domains/children were absent, the dedicated pool was stopped and undefined
without deleting its target, immutable baseline, seed or private evidence.

## Evidence boundary after VM completion

Automated selected-package/config/service/session behavior is complete for the
exact VM scope. Physical ASUS/GPU/outputs, Bluetooth, real audio devices,
suspend, boot/recovery, privileged group membership, the deferred greeter and
12 recipes behind production-planning module gates are not satisfied by this
matrix.
Hyprland runtime checks pass, but reliable guest-owned visual capture remains
environment-dependent.

## Post-review final-tree both-WM spot run — 2026-08-02

A fresh overlay from the unchanged mode-440 baseline verified and extracted the
437-member reviewed archive (349 files, 88 directories), then produced
`already-promoted`, the exact `2,1,58,1,2,3,3,34,29` effect vector, all nine
selected production-readiness rows `available`, and no apply blocker. Baseline
queries succeeded with 210 packages, empty system/user failed-unit results and
no checkout or installer state.

The first automatic run retained archlinuxcn asset-download exit `7`; both exact
asset HEAD queries then returned `0`, and an exact `archlinuxcn-bootstrap` stage
retry completed all nine stages. The clean `--rerun` exited `0`; its 684-package
manifest was byte-identical before/after. The managed fragment matched the
reviewed template, `pacman.conf` contained exactly one include, both files were
root-owned mode 644, and no conditional-recovery entry remained. This exercises
the final code's absent-fragment `RENAME_NOREPLACE` path; injected existing/
double-race and rollback-failure paths remain covered by the red-then-green
isolated regression rather than a destructive guest race.

The reboot request's SSH transport returned `255`, not success. Independent
libvirt and SSH polling observed the disconnect, reconnection and changed boot
identity with zero libvirt query failures; no raw identity was retained. Clean
Niri and clean Hyprland logins each had exactly one compositor, DMS and Fcitx5
owner, and both strict `--profile vm --selection both` checkers returned
`0`/ready with no blocker or unavailable check. Between sessions, the expected
stale DMS/GNOME/GTK Portal failures were recorded, then exact stop/reset/unset
cleanup returned `0` and the new tty session was distinct. Final system/user
failed-unit queries both succeeded empty.

Harness failures remain failures rather than being erased by their corrected
checks: the first process-count poll emitted multiline shell output and timed
out; a libvirt screendump returned “no surface”; the first Hyprland summary
parser raised `TypeError`; and several legacy/misquoted Hyprland quit forms
returned `7`/`2` or returned `0` without exiting. Correct structured process
queries, summary parsing and the Lua dispatcher object `hl.dsp.exit()` then
succeeded. None of those corrections is called a first-attempt pass, and the
spot run makes no new visual claim.

The guest shut down gracefully, the domain was undefined with NVRAM, the child
image reported zero offline check errors and only that overlay was deleted. The
baseline digest was unchanged. The dedicated pool was destroyed and undefined
without `pool-delete`; final domain inventory was successfully empty and the
pool was absent. This closes final-code VM validation for the exact both-WM
selection only. Physical ASUS/GPU/output, Bluetooth, real audio, suspend,
boot/recovery, privileged groups and the 12 production-planning AUR recipes
remain outside this evidence.
