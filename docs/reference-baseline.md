# Manual-install and live-workstation reference baseline

Status date: 2026-07-30  
Scope: sanitized read-only evidence; never an apply input

## Authority and privacy

Private manual is evidence, not executable input. The private installation note
captures the user's installation history, intended workstation features,
recovery knowledge and practical preferences. It also contains machine-specific
paths, embedded media references and plaintext credential examples, so its raw
text must not enter this public repository or installer state.

Live workstation is a mutable reference baseline and the golden functional
source. Because the current ASUS workstation is functioning normally and is the
intended restore target, its packages, sources, services, session ownership,
machine-specific values and personal tools must be compared before the installer
claims to reproduce that experience. The live state is not blindly bulk-copied;
it is converted into explicit module-owned mappings and re-queried when plans
would change system state.

The precedence rule is:

1. latest explicit user instruction and confirmed safety decisions;
2. current read-only target/source evidence with preserved exit status;
3. reviewed conclusions from the private manual; and
4. old commands or screenshots only as historical hints.

No system changes were performed while building this baseline. Raw inventory is
kept outside the repository in private mode-restricted temporary evidence.

## Current sanitized workstation shape

| Area | Successful evidence | Consequence for the installer |
| --- | --- | --- |
| Platform | Arch Linux x86_64, systemd, UEFI firmware | Matches the supported platform; Secure Boot and boot state still need a fresh privileged preflight |
| Kernel | Both `linux` and `linux-zen` plus matching headers are installed; the captured running kernel is Zen | The existing single-`linux` ASUS decision no longer fully describes the source workstation; kernel choice must be reviewed, not silently changed |
| Storage | Separate compressed Btrfs `@` and `@home` subvolumes; a restricted vfat `/boot`; zram swap is active | Disk/boot remain outside post-base apply, while Btrfs/Snapper/zram become explicit conditional modules or manual checks |
| Snapshots | `root` and `home` Snapper configs exist; timeline and cleanup timers are enabled | Existing configs must never be recreated; source policies are evidence, not universal defaults |
| Repositories | `core`, `extra`, `multilib` and `archlinuxcn` are configured | Every candidate must be classified by source; `archlinuxcn` never counts as official |
| Package inventory | The earlier snapshot observed 181 explicit / 18 non-sync packages; the successful 2026-07-31 refresh observed 180 explicit, 165 pacman and 15 non-sync packages, with all 15 independently found in AUR | Every current explicit name is now inventory-only planning evidence and must be accounted for; promotion still requires channel, restore responsibility, module ownership and review rather than a blind bulk command |
| Login/session | greetd is enabled and the active Wayland login is Niri; SDDM is not installed as a unit | Preserve the no-SDDM-fallback decision and audit the working greetd chain |
| Desktop services | DMS, PipeWire sockets/WirePlumber, Bluetooth, power profiles and portals are active | Startup ownership is mapped from read-only evidence; clean-VM validation must confirm package hooks/socket activation rather than guessed duplicate enable commands |
| Hardware controls | `asusd` is static/active and `supergfxd` is enabled/active | Their current success is useful physical evidence, but their `archlinuxcn` source still requires separate authorization |
| Virtualization | QEMU/libvirt/virt-manager are installed, libvirt is active and the account has libvirt-group access | KVM remains an optional physical module with logout and network checks |
| Maintenance tools | migration, restore and root/home snapshot helpers are available | Personal scripts require the existing file-level audit before inclusion |

The Secure Boot line reported `disabled` and the filtered output identified GRUB
as the current boot loader, but the overall `bootctl status` query exited `1`.
The filtered query did not establish the reason for that nonzero status. Those
lines are useful evidence, not a fully successful boot-chain check.

## DMS and greetd correction

dms-shell is now official. At inventory time, `dms-shell`,
`dms-shell-hyprland`, `dms-shell-niri`, `greetd` and `quickshell` resolve from
Arch `extra`. The current workstation runs official `dms-shell` plus
`dms-shell-hyprland`; the latter is a zero-payload dependency selector that
provides `dms-shell-compositor`. This matches the confirmed shape where the
shared shell is installed once and Hyprland adds a compositor-specific package.

This new repository fact invalidates the old assumption that the entire DMS
shell needs a custom fixed-source build. The user has now confirmed official
rolling Arch packages as the DMS shell source. Fixed-source trust requirements
continue to apply independently to the greeter.

greetd-dms-greeter-git remains untrusted. The working greeter binary is owned by
a foreign rolling `-git` package whose local package metadata reports no
validation. The official DMS shell ships greeter assets and examples, but it
does not make the currently installed foreign greeter binary an official or
verified package. Therefore `dms-greetd` and its greeter runtime remain
unavailable in the executable module graph.

The current greetd configuration is mode `600`, launches the DMS greeter on a
dedicated Niri config and has several historical backups. This validates the
intended Niri greeter architecture, not the reproducibility or safety of the
current greeter package.

## Session and configuration ownership

The current normal Niri session uses DMS through `graphical-session.target`.
The current Hyprland configuration uses the plain packaged
`start-hyprland` path and compensates for its different lifecycle by explicitly
starting DMS, Fcitx5, Blueman and other XDG-autostart applications with guarded
commands. UWSM is not installed.

This makes plain Hyprland the evidence-backed current behavior, while also
showing its maintenance cost. A later plain/UWSM decision must compare whether
UWSM correctly activates `graphical-session.target` and XDG autostart before
removing the proven plain-session guards.

Current mapped config is intentionally incomplete relative to the live source:

| Config area | Current files | Mapped files | Current-only files |
| --- | ---: | ---: | ---: |
| Niri | 14 | 9 | 5 |
| Hyprland | 15 | 7 | 8 |
| Fcitx5 under `.config` | 7 | 5 | 2 |
| DankMaterialShell | 12 | 2 | 10 |

An exact selected-list content review covered all 25 current-only files without
directory traversal. The older 5/3/3/14 result is now retained only as optional
portability history. Under the confirmed personal-restore policy, 17 functional
files—including machine-specific outputs, generated compositor fragments,
plain-Hyprland startup and user helpers—are direct mapping candidates. Eight
empty markers, historical backups, regenerable caches or ephemeral session
files are default exclusions. No source file has yet been promoted or mapped.

The input-method state also spans both `.config` and `.local/share`, while the
current mapping only covers `.config`. Both locations reference Rime Ice,
whose installed schema package is third-party. Startup, data location and
third-party schema ownership must be resolved together.

## Manual-note disposition

| Manual area | Use as evidence | Required correction/boundary |
| --- | --- | --- |
| archinstall, partitioning and Windows dual boot | Records how the source machine was created | Outside the post-base installer; device names, formatting and boot writes stay manual |
| Initial NetworkManager + `nmtui` connection | Defines the exact handoff into automation | User completes it interactively; installer starts after connectivity and never stores Wi-Fi credentials |
| UEFI, GRUB and random-seed recovery | Valuable recovery context | Current `/boot` was unreadable to the ordinary-user audit; no boot command is authorized from the note |
| Kernels | Records and validates the user's dual-kernel preference | ASUS manual base install now requires `linux` + `linux-zen`; automation only adds matching support and does not change GRUB default |
| Mirrors and archlinuxcn | Explains current package availability | Official mirrors, archlinuxcn and AUR remain separate trust/confirmation domains |
| GPU and ASUS stack | Strong candidate list validated by the live host | Correct package source and unit names; gate on PCI/kernel/boot state and physical checks |
| PipeWire/Bluetooth/power | Closely matches the working service stack | Preserve package-owned PipeWire/WirePlumber global enablement, keep one Fcitx5/Blueman startup owner per session, use exact conflict queries, and confirm package hooks/socket activation in a clean VM |
| DMS installer command | Historical installation route | The remote installer flow is prohibited and obsolete for the now-official shell packages |
| Locale/Fcitx/Rime | Captures desired Chinese input behavior | Expand package groups explicitly, reconcile both data roots, and keep Rime Ice separately authorized |
| Broad package lists | Useful workstation feature inventory | Classify package ownership/source; never pass the list directly to pacman |
| Btrfs/Snapper/zram | Important resilience and recovery requirements | Detect applicability, preserve existing configs and validate rollback in a VM before apply |
| KVM/hugepages | Captures optional virtualization goals | Hugepages and VM device choices are hardware/workload-specific, never physical defaults |
| Personal migration/snapshot/recording tools | Records workflows users expect after reinstall | Audit each script/source and keep installation/uninstall behavior explicit and symmetric |
| SDDM section | Historical fallback documentation | Current host has no SDDM unit; confirmed no-automatic-fallback policy wins |

The private note currently has overly broad `0666` permissions and contains
plaintext credential examples. Those are private-note hygiene issues. They were
not changed by this repository task and their values are deliberately omitted.

## Reconciliation gate

Before the portal/UWSM package combination or further Phase C/D implementation:

1. preserve the confirmed ASUS `linux` + `linux-zen` manual baseline; kernel
   installation itself remains before the automation handoff, as detailed in
   [`kernel-plan.md`](kernel-plan.md);
2. preserve the confirmed official Arch `dms-shell` source while keeping the
   unvalidated greeter blocked behind a fixed-source build;
3. use the completed 25-file review as the first faithful-restore batch, not as
   a portable-subset limit;
4. inventory the remaining functional desktop, user-systemd, autostart, Rime,
   ASUS and personal-script roots;
5. refresh package/source/service evidence on the target; and
6. only then settle portal and Hyprland session ownership and implement new
   executable stages.

## Failed and unavailable checks

- Ordinary-user `/boot` traversal failed with permission denied; GRUB menu,
  environment block and generated entries were not verified.
- `btrfs subvolume list /` failed with operation not permitted. Successful
  `findmnt --json` and Snapper JSON prove the mounted/configured subvolumes, not
  a complete subvolume inventory.
- `swapon --json` and `zramctl --json` are unsupported by the installed tools
  and exited `1`. Structured block data plus raw column fallbacks succeeded and
  confirmed active zram.
- The first JSON filter for enabled units used the wrong field and exited `5`;
  the corrected `unit_file` query succeeded. The failed filter is not treated
  as empty service evidence.
- `dms --version` produced no version and exited `1`; package ownership and
  official sync-database metadata succeeded independently.
- `bluetoothctl`, `expac` and `man` remain unavailable as recorded in the Phase
  C plan.
- Independent reviewer capacity most recently failed with provider `429`; no
  reviewer finding or approval exists for this baseline.

Environment-dependent checks still required include privileged boot/Btrfs
inventory, clean-VM confirmation of package-owned service presets and socket
activation, Hyprland login, DMS greeter package rebuild/verification,
root/home rollback, reboot into both kernels, physical GPU/suspend/output tests,
audio/Bluetooth/power post-checks and a clean-VM apply.
