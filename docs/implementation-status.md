# Implementation status and next direction

Status date: 2026-08-03
Requirements source: [`confirmed-decisions.md`](confirmed-decisions.md)

## Objective and unchanged safety boundary

Build a same-user/same-ASUS Arch restorer that starts only after the user has
manually completed disk/base/GRUB work, first boot, NetworkManager startup and a
working network connection. The live workstation is requirements evidence; it
is not an unaudited command stream.

No host package, repository, service, `/etc`, boot, disk or real-HOME apply has
been performed. The approved disposable lab froze the pre-automation package/
GRUB/NetworkManager handoff as a read-only qcow2, completed reversible candidate
and clean canonical matrices, then completed a fresh residue probe. Every root
command inside guests used the installed reviewed `~/scripts/desktop/gsudo`
payload; production adapters contain no `sudo` fallback. The dedicated session
pool is now stopped and undefined without deleting the immutable source or
private evidence.

## Unified production-candidate surface

`installer/full-orchestrator.py` is the current one-click candidate. It derives
this exact DAG from reviewed manifests:

1. `privilege-wrapper`;
2. `official-update`;
3. `official-packages`;
4. `archlinuxcn-bootstrap`;
5. `archlinuxcn-packages`;
6. `aur-source-acquisition`;
7. `aur-build-install`;
8. `user-config`;
9. `system-actions`.

It supports exact or interactive selection, explicit saved selections,
`new`/`reconcile`, independent system/archlinuxcn/AUR confirmations, global
zero-write preflight, private schema-3 run state/logs, dependency skipping,
exact exit preservation, retry-stage/retry-module, resume, verifier-before-skip
and intentional rerun. Optional branch failure does not prevent an independent
branch from recording its own result. An explicit `--stop-after-stage` is the
exception and now acts as a hard execution fence: a passed boundary exits `75`
and remains resumable, while a failed/verify-failed/dependency-skipped boundary
immediately persists the real failed run/exit and leaves every later stage
pending instead of crossing the requested boundary.

The canonical `manifests/stage-executables.tsv` maps all nine stages to five
production adapters and pins every executable hash. Project-relative
`installer/...` paths work after checkout relocation. The manifest is loaded by
default; a byte-identical manifest at another path is classified external and
cannot authorize production apply.

`manifests/stage-inputs.tsv` closes the plan fingerprint over additional trust
inputs: archlinuxcn planner/bootstrap/template, AUR recipe/source/build policies,
AUR child tools, official-only pacman template and all 15 recipe trees. These
inputs are checked at planning and before every adapter boundary. Reviewed runs
also strip adapter test variables and dynamic-loader/Python/shell overrides and
set `PATH=/usr/bin`.

### Promoted VM-proven gates and remaining fail-closed scope

All nine stage rows are `production-apply-integration=true`. Exactly
`base-preconditions`, `archlinuxcn-trust`, `build-foundation`, `fonts` and
`audio` moved from registry `planning` to `available` after byte-identical
candidate proof in fresh Niri, Hyprland and both-WM children. A later independent
review found that registry availability still conflated reviewed configuration
with production execution: selecting `personal-autostart` alone exposed the
unproved `flclash-bin` AUR recipe with no blocker.

`manifests/production-module-readiness.tsv` now supplies the independent,
plan-hashed execution gate. It covers all 32 modules exactly once: 30 available,
0 planning and 2 unavailable. The four config/session surfaces—
`developer-editor`, `personal-scripts`, `asus-hardware` and
`personal-user-services`—were readiness-promoted after the full-DAG VM
selection of batch 2026-08-08 (their package, config and system effects audited
by the regression plans). Exact VM
selections have no blocker; the physical ASUS default has 0 blockers
and no module-level apply gate failures.

A canonical manifest still cannot override a false stage or production module
row, and an external manifest cannot authorize apply. The legacy
`installer/install.sh` changing paths remain disabled outside exact isolated
regression roots; it is not a production fallback.

## Production adapters

### Configuration

`installer/config-stage-apply.py` owns `privilege-wrapper` and `user-config`.
The first stage deploys exactly `gsudo` and `fuzzel-askpass`; those targets are
excluded from the later user-config effects, so stage ownership is disjoint.
Preflight is read-only, execute backs up before atomic replacement, and verify
distinguishes deterministic drift from unavailable inspection. Final target
commits use Linux `renameat2`: absent targets are `NOREPLACE`, while existing
targets are exchanged, the displaced inode/hash/mode is checked against the
preflight snapshot, and a mismatch is exchanged back. Restore-to-absent uses the
same conditional quarantine/verification boundary rather than a blind unlink.

The clean-base privilege bootstrap no longer makes the later AUR Fuzzel provider
a precondition: `gsudo` requires only `sudo` before dispatch. NOPASSWD therefore
reaches the reviewed sudo argv without invoking askpass. If sudo requests a
password, the adjacent helper still prefers Fuzzel, but emits an explicit warning
before using fixed `/usr/bin/systemd-ask-password` when Fuzzel is absent; with
neither prompt provider it exits `127`. This changes only the password-prompt
interface, never the privilege path—there is still no direct-`sudo` adapter
fallback. The disposable Niri evidence exercised the fixed pre-Fuzzel
`systemd-ask-password` branch with a noncredential marker and the later graphical
Fuzzel branch. A real physical password prompt remains environment-dependent;
no credential value was retained.

The explicit restore interface now implements the confirmed decision:

- `--list-backups` emits a read-only JSON inventory and creates no missing state;
- `--restore-backup <id>` prints the exact scope-constrained plan;
- only the exact typed `restore <id>` confirmation permits a write;
- every changing current target is captured into a complete pre-restore backup
  before the first restore operation;
- concurrent target drift aborts before stale rollback evidence is created;
- the reported rollback backup is itself restorable;
- traversal, symlink/hard-link, corrupt/incomplete metadata, payload drift,
  unrecorded files and removed mapping ownership fail closed.

### Official packages

`installer/official-package-apply.py` handles the initial full `pacman -Syu`
boundary and the exact selected 162-package full ASUS official policy. It
reconstructs effects from the 203-row ledger, inventories active repositories,
blocks unknown/unreviewed trust, pins the archlinuxcn planner and wrapper
payloads, uses exact argv arrays and distinguishes `pacman -Qu` current,
pending, ambiguous-empty and failed-query outcomes. After the orchestrator's
explicit system confirmation, changing pacman argv include fixed
`--noconfirm`; adapter stdin remains `/dev/null`, so no hidden prompt can turn a
reviewed one-click transaction into an EOF failure.

### Archlinuxcn

`installer/archlinuxcn-apply.py` handles the fixed keyring/repository bootstrap
and exact selected packages. It pins package/signature hashes and signer,
validates the repository template, pins the planner hash internally, performs a
conditional second full update after adding trust and never runs partial `-Sy`.
The restricted root helper can write only the managed fragment and
`/etc/pacman.conf`. Each final commit is conditional: absent paths use
`RENAME_NOREPLACE`; existing paths use `RENAME_EXCHANGE`; displaced bytes, hash,
mode, UID/GID, device and inode must equal the ordinary-user backup snapshot.
Mismatch triggers a safe exchange-back, and a second race or rollback failure
retains both directory entries with an explicit recovery path. Existing host
trust remains blocked rather than silently adopted. Keyring, refresh and package
transactions use exact noninteractive argv only after independent archlinuxcn
confirmation.

### AUR

`installer/aur-stage-apply.py` handles source acquisition and build/install for
only the selected fixed recipes. It reconstructs exact effects, verifies all
recipe tree identities, pins four child tools, treats both missing installed
privilege payloads as expected-pending only during global preflight, acquires
only declared local-fixed sources, requires source provenance, builds before
install, preserves external failures and verifies exact installed artifact
provenance. No arbitrary AUR name/fallback interface exists.

The pinned `aur-build.py` now creates the ordinary-user-owned private chroot base
before invoking current devtools: `mkarchroot` resolves `<base>/root` with
`readlink -f` and otherwise returns “Please specify a working directory”. It
still exclusively owns creation of the root subtree. External child exits
1–255 are retained exactly (negative signal returns are normalized to 128+signal)
instead of collapsing high statuses to generic `1`.

### System actions

`installer/system-action-apply.py` accepts only the reviewed executable columns
of `system-actions.tsv`. The manifest contains 30 actions (11 apply, 10 verify,
6 manual, 3 deferred) and five conflict sets. Automatic actions cover time sync,
hardware-gated Bluetooth/power, Niri DMS wants, dsearch, user-unit reload,
Docker/libvirt/default network, locale and Fcitx environment. Group membership,
Snapper, boot recovery, hugepages, physical acceptance and greeter remain
manual/deferred.

Fixed locale/environment root-helper commits use the same conditional
`renameat2` exchange/no-replace rule as user configuration. Same-run retries
advance the durable attempt while retaining each action's first nonempty
`prior` and original backup references, so idempotent re-query cannot rewrite
rollback origin state.

The plan and schema-3 run state now retain structured pending, manual, deferred,
conditional and relogin/reboot acceptance. A successful automatic run reports
`automatic-stages-completed-with-pending-acceptance` when applicable; it cannot
claim the whole workstation is complete.

The completed defect-finding review reported two additional findings, both
reproduced before editing: the archlinuxcn helper's final unconditional replace
could discard another administrator's write, and `personal-autostart` could
execute the unproved FlClash AUR path. Red tests first demonstrated all existing/
absent fixed-target windows and the exact no-blocker plan. The conditional root
commit and independent production-readiness registry above make those same tests
green. Its separate AUR environment probe failed in its own harness and remains
unavailable rather than passing.

A final independent read-only reviewer then found no reproducible finding in the
fixed tree. It statically traced both fixes and pin/readiness coverage but, by its
own report, did not rerun the active race/readiness probes or full parser suite;
those omissions are not reviewer passes. One combined symbol-inventory command
exited `1` because its final `rg` had no match and remains a failed check rather
than an empty healthy result. The main execution separately ran the actual
red-then-green regressions and complete `tests/static-check.sh` successfully.

## Package policy

The immutable observation remains 183 explicit packages: 170 sync-database and
13 non-sync/AUR. The separate target policy has 203 unique rows:

| Responsibility | Rows |
| --- | ---: |
| install (`package-only` or `config-backed`) | 184 |
| verify-only manual precondition | 18 |
| deferred greeter | 1 |

The install rows split into 162 official, one archlinuxcn keyring bootstrap,
eight archlinuxcn packages, one fixed Paru bootstrap and 12 other fixed AUR
recipes. QQ, WeChat, Obsidian and Chrome remain package-only. All 26
config-backed packages have explicit package/config relations. The only allowed
observed-to-target source transition is Paru from current archlinuxcn to the
fixed AUR bootstrap. Fuzzel/Mako/SDDM/rolling-greeter fallbacks remain rejected.

## Configuration and WM behavior

`manifests/config-mappings.tsv` has 198 rows:

| Scope | Rows | WM results |
| --- | ---: | --- |
| `physical-v1` | 162 | Niri 101, Hyprland 102, both 117 before personal modules; full ASUS 162 |
| `vm-v1` | 36 | Niri-only/default 35, Hyprland-only 35, both 36 |

The physical scope includes 42 Neovim/editor rows and the complete reviewed 77
personal functional files. The VM scope has a minimal dedicated DMS/Fuzzel/Niri/
Hyprland payload rather than an undocumented copy. Niri-only and Hyprland-only
are disjoint; both deploy shared/input once. The official `dms-shell` user
package/config remains selected independently from the unavailable, unoffered
`dms-greetd`/`dms-niri-greeter` placeholders; greeter/login manager remains
outside both scopes.

Both VM compositor files pass their installed parsers locally:

```text
niri validate -c config/vm/home/.config/niri/config.kdl
Hyprland --verify-config -c config/vm/home/.config/hypr/hyprland.lua
```

That parser evidence is not graphical login or runtime acceptance.

## Current read-only host evidence

A canonical VM-default plan has all nine applicable stages, no missing handler,
33 user-config effects plus two exclusive privilege-wrapper effects, 55 official
package effects, two archlinuxcn packages and three fixed AUR effects. It now has
no apply blocker. The default ASUS plan has all stages integrated and no
production-planning module blockers after the batch 2026-08-08 promotion of the
last four config/session surfaces.

A direct temporary-HOME compatibility preflight used that exact plan/effect set
without state writes. Results were preserved individually:

| Stage(s) | Exit | Classification |
| --- | ---: | --- |
| `privilege-wrapper`, `user-config` | 0 | exact read-only config effects accepted |
| both AUR stages | 0 | accepted with explicit expected-pending sources/chroot/provenance/wrapper |
| official stages | 1 | active repository trust did not pass |
| archlinuxcn stages | 1 | existing repository is unmanaged; keyring matched |
| `system-actions` | 1 | one deterministic current-environment blocker |

The nonzero results are blockers, not failed-to-find-nothing and not VM
acceptance. The existing `archlinuxcn-plan.py` host result remains exit `1` /
`unmanaged-existing` because the manually configured section inherits SigLevel.
No host file was changed to make it green.

## Validation completed in this batch

The adapter/orchestrator/config/system-action regression inventory remains
covered by the umbrella suite. The latest host tree additionally has an explicit
Phase C applicability contract:

- `--profile physical` is the default and keeps Bluetooth/Blueman/power package,
  service, D-Bus and controller requirements strict;
- `--profile vm` marks only those physical contracts `not-applicable`, while
  Portal, PipeWire/audio, Fcitx startup, user/system bus and failed-unit checks
  remain strict;
- VM Hyprland checks its mapped `hyprland.lua` and the Fcitx guard rather than a
  physical startup file;
- audio conflicts remain applicable to VMs, while unselected physical power
  conflicts do not create false blockers.

`tests/phase-c-session-check-test.sh` first failed on the old applicability
behavior and now covers VM Niri, VM Hyprland, missing Fcitx, applicable audio
query failure, independent audio versus VM-not-applicable power conflicts, and
comment-only/unreachable startup guards without weakening the physical default.
The four VM documentation commands are pinned to `--profile vm` by
`tests/docs-check.py`. Targeted Phase C, config-stage, candidate-gate,
orchestrator, stage-input and stage-executable tests exit `0`. The synchronized
`tests/static-check.sh`, standalone docs check and whitespace check also exit
`0`; all required Niri/Hyprland validators actually ran. `ruff` and `pyflakes`
remain unavailable from earlier executable queries and are not reported as
passing. Generated bytecode was removed after validation.

The approved snapshot-backed lab has now completed a strong eighth Niri evidence
run. All nine candidate stages passed after deliberate stop/failure/retry
boundaries. The Cairo-fixed AUR recipes built and installed in a clean chroot;
package/provider/service/failed-unit checks passed. Unchanged rerun idempotence,
config drift backup, cancelled restore, exact restore, pre-restore rollback,
rollback restore, a real external mirror failure/stage retry, reboot and broad
graphical Niri acceptance were exercised. Portal file chooser, screenshot and
ScreenCast plus PipeWire playback/finite recording passed. Two ScreenCast
interaction timeouts, an interrupted `pw-record` exit `1`, the mirror exit `1`
and one transient user-manager exit `1` remain explicit failed evidence.

The eighth guest used the older checker and returned exit `2` on false physical
Bluetooth/Blueman/power requirements. A ninth fresh child carried the first
VM-profile repair, but repeated official mirror timeout/SSL EOF failures and a
clean-chroot download exit `255` prevented AUR completion. Its host SSH retry
returned `255`; later strict SSH and guest-agent queries succeeded, and durable
state kept the transport and stage results separate. The failed child was
shut down, undefined, checked offline and deleted without an in-place patch.

The independent reviewer then completed with five findings, all reproduced
before editing. Config restore and candidate manifests now use conditional
exchange/identity verification and retain both files on double races; candidate
terminal state revalidates manifest truth. Canonical config-only/none plans are
allowed while per-stage auxiliary coverage remains mandatory. Phase C reports
audio and physical-power conflicts independently and accepts guards only as
direct executable startup-callback statements. Red-then-green regressions cover
all findings. The reviewer's direct Hyprland parser ended by signal 6 in its
restricted environment, so that subcheck is unavailable—not passing. A fresh
post-fix reviewer then received two 600-second waits, an interrupt and one final
180-second wait but returned no result before being closed while still running;
that re-review is unavailable, not passing. No host package, repository,
service, `/etc`, boot, disk, network or real-HOME state was changed.

The post-review tenth Niri child now fully passes canonical apply/retry, unchanged
rerun, reboot, real-session VM checker, conditional candidate restore and
offline overlay rollback. Its initial archlinuxcn asset exit `7` remains explicit.
A first Hyprland-only child exposed a clean-chroot initialization retry blocker:
external exit `255` left a partial root that preflight rejected. The fixed AUR
build tool now performs narrowly scoped audited cleanup of only known private
partial paths, preserves the external exit and permits same-state retry; a
red-then-green test and canonical child/adapter pins cover it. That stale child
was safely discarded without patching.

## Final VM validation and gate promotion — 2026-08-02

The final fresh Hyprland candidate completed all nine stages after bounded real
network retry, converged on an unchanged rerun, rebooted into a real plain
Hyprland session and returned `overall=ready`; its only visual limitation was a
noninteractive Portal Screenshot response code `2`. The fresh both-WM candidate
then ran clean Niri and clean Hyprland logins separately with both exact checker
commands ready. Niri produced a readable guest-owned 1280×800 screenshot. All
candidate manifests restored exact originals twice, every child shut down
cleanly, every offline qcow2 check reported zero errors, and only disposable
children were deleted.

Host promotion changed only nine stage booleans and the five proven module
availability values. Their resulting hashes exactly matched the candidate hashes
from the final Niri and both evidence. Promotion regressions first failed on the
closed tree, then passed; canonical Niri/Hyprland/both plans had effects
`2,1,55,1,2,3,3,33,29`, `2,1,55,1,2,3,3,33,28`, and
`2,1,58,1,2,3,3,34,29` with zero blocker.

Three more fresh children then ran without candidate enable/restore state. Each
completed all nine canonical stages, a final unchanged rerun, verified reboot,
its exact real-session checker and child-only rollback. Retained external
failures were an official mirror low-speed exit `1` in Niri and an AUR source
download-query exit `2` in Hyprland; bounded HEAD checks succeeded and exact
stage retries preserved then cleared those failures. During automated Niri to
Hyprland switching, compositor shutdown left DMS/GNOME/GTK Portal user units
failed in the deliberately persistent SSH user manager; the exact sets and
broken-pipe/lost-compositor journals were retained, reset explicitly, and final
failed-unit queries were empty. These are not silently reported as clean first
attempts.

A final fresh rollback probe matched the original 210-package manifest and
successfully found no project checkout/state, Niri/Hyprland/DMS/Fcitx config,
privilege-wrapper payload, Niri→DMS wants link, dsearch unit, managed
archlinuxcn fragment/include/section or Fcitx system-environment residue. System
and user failed-unit queries both succeeded empty. The pool was destroyed and
undefined only after all domains and disposable overlays were absent; lab files
and private evidence remain.

Because the two later safety repairs changed the adapter hash and plan input, a
fresh final-tree both-WM child was also run. It verified the 437-member archive
and exact blocker-free effect vector. Initial archlinuxcn download exit `7` was
retained; two asset HEAD checks and exact retry returned `0`; all stages and a
clean rerun passed with an unchanged 684-package manifest. The new managed
fragment/include were exact and left no recovery entry. Reboot transport exit
`255` was followed by independently observed disconnect/reconnect and changed
boot identity. Separate clean Niri and Hyprland checkers returned ready, final
failed-unit queries succeeded empty, the child passed offline checking and only
its overlay was deleted. Baseline digest stayed unchanged and the re-opened pool
was again destroyed/undefined. Corrected harness checks do not erase retained
process-poll, screendump, summary-parser or obsolete Hyprland-quit failures.

## Requirement-by-requirement completion audit

| Requirement area | Current result | Remaining boundary |
| --- | --- | --- |
| Manual disk/base/GRUB/network handoff | Contract and frozen VM baseline verified | Real reinstall remains user/manual by design |
| Exact module/WM selection | Implemented; Niri, Hyprland and both config/process boundaries passed | Greeter remains a separate unavailable module |
| Official + archlinuxcn trust stages | Canonical VM-selected effects applied, verified, retried and rerun | Existing physical host repository state requires a fresh reviewed reconcile plan |
| Fixed AUR pipeline | All thirteen fixed recipes passed real source/build/artifact/install/rerun paths: three in the 2026-08-02 matrix, the remaining ten in the module-level DAG of batch 2026-08-04 (after claude-code and intellij-idea-ultimate-edition were removed by operator decision), including partial-chroot recovery and .INSTALL/.CHANGELOG metadata acceptance | Module promotion for the four validated modules is complete; physical-host application is outstanding |
| User config and privilege wrapper | Hash-bound effects, race-safe backup/restore and idempotence passed | No real HOME apply was performed |
| Automatic system actions | VM-applicable actions and rollback/state checks passed | Hardware services and privileged groups remain physical/manual |
| Portal/audio/Fcitx session ownership | Strict Niri/Hyprland checkers passed in all exact selections | Hyprland noninteractive screenshot remained unavailable; real audio devices are physical-only |
| Retry/resume/rerun/reboot | Exact external exits retained; bounded retries, convergence and boot-identity changes passed | Network availability remains environmental, never converted to success |
| Rollback/isolation | Candidate restore, zero-error offline children and residue probe passed | Physical rollback still requires its separately reviewed host plan |
| Credentials/private state | Archive excludes secrets, `.git`, generated bytecode and root private file; evidence retains no raw bus/socket/boot IDs | Credentials remain intentionally out of scope |
| Full ASUS policy | Plan-visible and fail-closed with 21 production module blockers | Physical hardware acceptance and three private-cache recipe paths remain unproved |

## Remaining environment-dependent gates

1. Physical ASUS/hybrid-GPU/output, Bluetooth, real playback/recording,
   suspend/resume, boot/recovery and any Docker/libvirt root-equivalent group
   decision require an explicitly approved real-host plan and human acceptance.
 2. All ten non-VM-selected AUR recipes passed real clean-chroot build,
    install and idempotent rerun in disposable VM batches. The seven
    remote-fixed recipes (clash-verge-rev-bin, google-chrome,
    leaf-markdown-viewer-bin, obsidian-bin, wooz-git, opencode-bin and
    flclash-bin) passed in batch 2026-08-03. The three local-fixed recipes
    (linuxqq and wechat AppImages, paru cargo-vendor) then passed in batch
    2026-08-03b after their private source caches were acquired and verified
    against the reviewed manifest (commit `fb3b60b`; paru vendor hash renewed
    deterministically under cargo 1.97.0, see
    `third_party/aur/paru/REVIEW.md`); batch 2026-08-03b also surfaced and
    fixed a recipe-manifest hash inconsistency (commit `915030e`). See
    `docs/vm-execution-plan-20260803b.md` for the full record. On 2026-08-04
    the operator removed `claude-code` and `intellij-idea-ultimate-edition`
    from the `development-toolchain` module (not used / oversized 1.6 GiB
    source); those two recipes and their reviewed trees were dropped from
    `aur-recipes.tsv`, `workstation-packages.tsv` and the private recipe tree
    (see the batch 2026-08-04 plan document). Every module's full-DAG effects
    were subsequently validated by its own module selection in the VM matrix
    (batches 2026-08-04 through 2026-08-08); the readiness manifest now blocks
    no production module. No recipe-level subset result was generalized to a
    module.
3. Greeter/login-manager remains deferred and unavailable; SDDM remains rejected
   as a fallback.
4. Hyprland automated runtime/session checks pass, but a reliable guest-owned
   screenshot is unavailable in this lab. That limitation is retained rather
   than called a visual pass.
5. Local Git closeout uses explicit safe pathspecs; `master` is explicitly
   published to `origin/master`, with no tag or GitHub Release. Reviewer
   omissions and failed/unavailable harness checks remain
   recorded rather than converted to passes. The root untracked file `仓库地址`
   remains unread and untouched.
