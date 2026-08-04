# Module and profile model

Requirements source: [`confirmed-decisions.md`](confirmed-decisions.md)  
Implementation state: [`implementation-status.md`](implementation-status.md)

`installer/full-orchestrator.py` resolves profile defaults and exact
`--modules` selections from `manifests/modules.tsv` and
`manifests/profile-modules.tsv`. Every reconciled package, configuration mapping
and system action has one registered functional owner. The legacy
`installer/install.sh` remains plan-compatible but is not a production changing
entrypoint.

## Availability and production gates

Two deliberately separate schema-1 manifests prevent configuration review from
becoming package/service authorization:

- `manifests/modules.tsv` records the module's reviewed config/session surface.
  Its `available`, `planning` and `unavailable` values remain selection and
  config-only deployment metadata.
- `manifests/production-module-readiness.tsv` records whether the complete
  full-DAG effects of that module may execute. Its exact coverage is hashed into
  every plan and rechecked before adapter execution.

The registry currently contains 21 `available`, 9 `planning` and 2
`unavailable` module surfaces. The stricter execution registry contains 21
`available`, 9 `planning` and 2 `unavailable` rows. Production apply also
requires every applicable row in `manifests/stages.tsv` to have
`production-apply-integration=true`, complete canonical adapter coverage and no
external-manifest substitution. All nine stage flags are true after the
candidate and clean canonical VM matrices. Exact VM selections resolve only the
thirteen production-ready modules; physical/full-policy selections fail closed
on any independently `planning` production row.

## Configuration/session modules

| Module | Current responsibility |
| --- | --- |
| `desktop-shared` | Shared desktop/DMS config plus package/action ownership |
| `input-fcitx-rime` | Fcitx5/Rime config and packages; requires `archlinuxcn-trust` |
| `developer-editor` | A 42-file Neovim/editor configuration |
| `wm-niri` | Niri package/config/session boundary |
| `wm-hyprland` | Plain Hyprland package/config/session boundary |
| `personal-scripts` | Reviewed same-user helper scripts |
| `personal-autostart` | Reviewed graphical autostart entry |
| `asus-hardware` | Same-ASUS user config; requires `archlinuxcn-trust` |
| `personal-user-services` | User unit files restored without enabling them |

These modules remain marked `available` for their audited config surface. Only
`desktop-shared`, `input-fcitx-rime`, `wm-niri` and `wm-hyprland` are also
production-ready. `developer-editor`, `personal-scripts`,
`personal-autostart`, `asus-hardware` and `personal-user-services` are
independently `planning` for full-DAG execution because no exact VM selection
covered their complete effects. In particular, this closes the former
`personal-autostart`/`flclash-bin` AUR bypass without disabling reviewed
config-only deployment. The official `dms-shell` user-session package remains
owned by `desktop-shared`; `dms-greetd` and `dms-niri-greeter` remain
unavailable and unoffered. There is no SDDM fallback.

## Full-policy planning modules

The module-registry planning set is:

```text
repository-tools daily-apps desktop-apps cli-tools development-toolchain
container-tools storage-maintenance virtualization kernel-support bluetooth
power graphics-amd graphics-nvidia hardware-tools recording ocr
```

The production planning set additionally contains the five reviewed but
non-VM-selected config/session modules listed above, for 21 blockers in the
default ASUS plan. The VM-proven `base-preconditions`, `archlinuxcn-trust`,
`build-foundation`, `fonts` and `audio` rows moved to registry `available`; the
separate production registry marks those five plus the four exact VM
config/session owners ready and promotes nothing else.

They own the plan-visible 200-row package policy and automatic/manual/deferred
system actions. `archlinuxcn-trust` is dependency-only and is resolved whenever
a selected module owns an archlinuxcn package; this ensures the bootstrap stages
cannot disappear from an apparently valid VM/Rime plan.

## Configuration scope counts

`manifests/config-mappings.tsv` has 198 rows:

| Scope/scenario | Config targets |
| --- | ---: |
| `physical-v1` total | 162 |
| physical shared + input + editor + Niri | 101 |
| physical shared + input + editor + Hyprland | 102 |
| physical shared + input + editor + both WMs | 117 |
| physical ASUS default with reviewed personal modules | 162 |
| generic AMD defaults (input disabled) | 94 |
| `vm-v1` Niri-only/default | 35 |
| `vm-v1` Hyprland-only | 35 |
| `vm-v1` both WMs | 36 |

The two privilege-wrapper targets are owned exclusively by the first DAG stage;
they are excluded from `user-config` effect accounting. Niri-only and
Hyprland-only remain disjoint, while shared/DMS/input config is deployed once.

## Unified stage ownership

The exact stage order is:

1. `privilege-wrapper`;
2. `official-update`;
3. `official-packages`;
4. `archlinuxcn-bootstrap`;
5. `archlinuxcn-packages`;
6. `aur-source-acquisition`;
7. `aur-build-install`;
8. `user-config`;
9. `system-actions`.

Optional trust branches continue independently after an unrelated optional
failure, while dependency descendants are skipped. A prior pass is never
silently trusted: retry/resume verifies it before skip. Automatic stage
completion retains structured pending/manual/deferred/conditional and
relogin/reboot acceptance rather than claiming the workstation is fully
reproduced.

## Selection rules

- `--modules` replaces defaults exactly; deterministic `requires-all` closure is
  added and shown.
- Unknown, duplicate, dependency-only, profile-ineligible and unsatisfied
  choices fail before state.
- Plan mode creates no state and loads the canonical executable/input manifests
  automatically.
- Non-interactive apply requires exact modules or explicit saved selection plus
  every applicable trust confirmation.
- `planning`/`unavailable`, false stage integration, missing handlers and an
  external executable manifest are independent apply blockers.
- Greeter, manual disk/base/GRUB ownership and physical acceptance never become
  silent no-ops.
