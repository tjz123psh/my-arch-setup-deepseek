# Kernel and DKMS planning boundary

Status date: 2026-07-31  
Scope: read-only, non-executable planning

## Start boundary

Kernels are a manual base-install input. The private manual selects kernels in
archinstall before the section 9.1 handoff, and GRUB is generated before the
workstation installer starts. The one-click path must therefore inspect the
installed/running kernels rather than silently installing, removing or changing
the default kernel.

Dual-kernel ASUS baseline is confirmed. New ASUS base installs select both
`linux` and `linux-zen` during the manual archinstall stage, with matching
support added later. The standard kernel remains the recovery fallback. The
current workstation also runs Zen, but the installer does not infer or change
which GRUB entry is the saved default.

No system changes were performed for this plan.

## Current evidence

- `linux`, `linux-headers`, `linux-zen`, `linux-zen-headers` and
  `nvidia-open-dkms` are installed at matching rolling versions.
- The running kernel query succeeded and identified the Zen kernel.
- `dkms status` succeeded and reports the NVIDIA module installed for both the
  standard and Zen kernel release.
- `/etc/default/grub` is readable and uses a saved/default-memory policy. This
  explains the current Zen boot but is not authorization to alter it.
- Ordinary-user access to `/boot` and the GRUB environment block failed, so the
  generated menu and saved entry were not verified.

## Proposed installer behavior

### Detect first

The preflight should collect, with separate exit status:

1. running release from `uname -r`;
2. exact installed supported kernel packages;
3. matching installed header packages;
4. `/usr/lib/modules/<release>/build` availability;
5. selected DKMS package and `dkms status`; and
6. bootloader/mount type only as a review gate, without writing it.

Unknown custom kernels are not treated as absent. They make automatic DKMS
support unavailable until a reviewed package-to-header mapping exists.

The running release is informational only: after a full update it may be older
than the newly installed kernel until reboot. Package/header selection and DKMS
coverage use the installed package database plus `/usr/lib/modules`, not
`uname -r` alone.

### Read-only checker

`installer/kernel-support-check.py` implements the detection and validation
portion without implementing any package, DKMS, initramfs or boot change:

```bash
installer/kernel-support-check.py --profile asus-amd-nvidia
installer/kernel-support-check.py --profile asus-amd-nvidia --json
installer/kernel-support-check.py --profile desktop-amd
installer/kernel-support-check.py --profile vm
```

It reads local package state with `pacman -Q`, maps installed supported kernel
packages to releases with `pacman -Qql`, inventories `/usr/lib/modules`, reads
the running release with `uname -r`, and parses `dkms status` only when the
profile requires NVIDIA DKMS. It never invokes `pacman -S`, `dkms install`,
`mkinitcpio`, `grub-mkconfig`, `systemctl` or a privilege wrapper, and it is not
called by `installer/install.sh`.

The report preserves three distinct outcomes:

- exit `0`, `ready`: every required query completed and every required check
  passed;
- exit `1`, `blocked`: queries completed but found a missing package, mismatched
  kernel/header version, missing build directory or incomplete DKMS coverage;
- exit `2`, `unavailable`: a required command/query failed, was unavailable, or
  returned output that could not be parsed safely.

A successful empty `dkms status` is recorded as an available empty result. It
therefore blocks NVIDIA coverage with exit `1`; it is not mislabeled as a query
failure or a healthy result. For `pacman -Q`, exit `1` is called `missing` only
when the standard `package ... was not found` diagnostic matches; other exit-1
failures remain `query-failed`.

The 2026-07-31 read-only run on the golden ASUS host returned `ready`: `linux`
and `linux-zen` were installed with exact-version matching headers, both mapped
module releases had build directories, and installed NVIDIA DKMS state covered
both releases. This is current-host evidence only. It does not replace a clean
VM transaction, DKMS rebuild, initramfs verification, reboot into both kernels
or fallback recovery test.

### Install support, not kernels

Headers follow detected kernels. For each supported kernel already installed by
the user, the official package stage may propose its exact matching header
package when missing:

| Detected kernel | Proposed support package |
| --- | --- |
| `linux` | `linux-headers` |
| `linux-zen` | `linux-zen-headers` |

The ASUS NVIDIA module may then install `nvidia-open-dkms`, which must build for
every detected supported kernel. A successful package transaction is not enough
if one kernel lacks its DKMS module.

The normal package flow performs the required full `pacman -Syu` before adding
missing support packages. It must then verify exact package-version equality for
`linux`/`linux-headers` and `linux-zen`/`linux-zen-headers`. `IgnorePkg`, stale
mirrors or any other condition that prevents the kernel/header pair from
converging blocks DKMS work instead of accepting a mismatched header tree.

Current sync metadata gives installed-size lower bounds of about 282 MiB for
`linux-headers`, 286 MiB for `linux-zen-headers`, and 568 MiB for both. The DKMS
source package adds about 132 MiB before dependencies, generated modules,
initramfs output and the general 5 GiB safety margin. A future plan must refresh
the exact transaction against synchronized target databases.

### Keep boot ownership manual

No automatic GRUB default change is allowed. The normal support path does not
run `grub-set-default`, edit `GRUB_DEFAULT`, change saved-entry behavior or
remove fallback kernels. Because kernels are selected before the handoff, it
also does not need to add a new kernel to the boot menu.

If a future explicit module is allowed to add a missing kernel after handoff,
that is a separate boot-affecting plan requiring privileged `/boot` inventory,
an exact `grub-mkconfig` diff/recovery plan and independent confirmation. It is
not part of this kernel-support proposal.

## Post-checks

- matching header package for every detected supported kernel;
- build directory present for every kernel release;
- NVIDIA DKMS state installed for every supported release;
- current kernel's `nvidia`, `nvidia_modeset` and `nvidia_drm` modules loaded
  when hardware is applicable;
- `nvidia-smi` succeeds on the physical profile;
- initramfs generation reports no selected-kernel failure; and
- final report requests, but never automatically performs, reboot testing of
  each installed kernel and fallback entry.

Failure for one selected kernel fails the driver module; it is not hidden by a
successful build for the other kernel. Package or boot rollback remains manual
from recorded prior state and the existing fallback kernel.

## Failed and unavailable checks

- Ordinary-user `/boot` traversal failed with permission denied.
- `grub-editenv list` failed because the restricted boot path could not be
  resolved. The saved default entry is therefore unknown.
- No reboot into either kernel, initramfs rebuild, package apply or GRUB
  regeneration was performed.
- The independent review has not yet covered this new kernel plan.

The executable installer and official package manifest remain unchanged.
