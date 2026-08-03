# Reviewable VM execution plan — 2026-08-01

This document began as the review boundary for the snapshot-backed candidate
matrix described in [`vm-validation.md`](vm-validation.md). The user subsequently
approved Phase 1 and then explicitly delegated completion of the project. Image
verification, clean baseline, candidate/canonical matrices, rollback probe and
pool closeout are now complete; sections 6–10 retain the commands and their
original review boundary, while section 18 records the result. Recorded approval
does not turn a failed or unavailable check into a pass, and any operation
outside this documented boundary still requires a fresh inventory and
reviewable rollback.

The plan deliberately uses `qemu:///session`, native QEMU SLIRP and files under
the invoking user's home. It does not install a host package, start/change the
host **system** libvirt network or pool, change a host service, use
`/var/lib/libvirt`, or run a host root command. The amended plan defines one
non-autostart, user-session directory pool scoped exactly to `$LAB/disks` while
`virt-install` resolves approved disks, then destroys/undefines that pool without
deleting its files. Root-level base preparation happens only inside the
disposable guest through reviewed cloud-init data; after the project deploys its
wrapper, every deliberate guest root command uses that exact `gsudo` payload.

Independent review is not available as positive evidence. The original
current-tree reviewer returned no final result after long waits. A resumed
focused pass after the clean-base/conditional-commit fixes likewise returned no
checklist or finding after repeated waits and an immediate-result interruption,
then was closed while still running. Three candidates from its earlier partial
report were locally reproduced before repair, but neither attempt constitutes a
complete reviewer pass. Local tests and this reviewable document are available;
a fresh independent pass is not.

## 1. Current read-only inventory

The following checks were run without creating a domain, disk or state path:

- current host `systemd-detect-virt --vm` exited `1`; the host is not a VM;
- `/dev/kvm` exists and is accessible; `virt-host-validate qemu` exited `0`, but
  reported two warnings rather than an all-PASS result: unprivileged device
  cgroup control is unavailable and secure-guest SEV/TDX support is unavailable;
- 16 logical CPUs, 15.96 GB total memory and about 7.12 GB currently available;
- `/home` has about 98.36 GB available;
- `virsh -c qemu:///session list --all --name`, `pool-list --all --name` and
  `net-list --all --name` each exited `0` with an empty result;
- the proposed lab data/state roots are absent;
- TCP loopback port `22222` was queried successfully and was unused;
- `virt-install 5.1.0`, `virsh 12.5.0`, QEMU/qemu-img 11.0.2, `xorriso`, `ssh`,
  `ssh-keygen` and `virt-manager` are available;
- `virt-viewer`, `passt` and `slirp4netns` are absent. The printed domain XML was
  therefore validated with a native QEMU `-netdev user,...hostfwd=...` device,
  not an unavailable backend;
- the installed render nodes are accessible and `virglrenderer` is installed;
  a print-only `virt-install` probe accepted UEFI, virtio 3D, private SPICE,
  sound, RNG and the loopback-only SSH forward;
- all proposed domain names are absent from the successful all-domain listing.
  Separate name-specific `dominfo` probes returned exit `1`/not-found and are
  retained as nonzero lookups, not re-labelled as successful health checks;
- the official versioned cloud image and its checksum/signature URLs returned
  HTTP 200. No image was downloaded.

### Post-approval inventory stop and amended pool boundary

Immediately after the first Phase-1 approval, the required inventory stopped
before creating `$LAB` or downloading anything because `qemu:///session` storage
was no longer empty. Two persistent/autostart directory pools named `tmp` and
`tmp.gGUA57plrL` had appeared. Their private configuration mtimes align with the
earlier print-only `virt-install` probes. The first scans `/tmp`; the second
targets a now-absent temporary directory. Domains and networks remained
successful-empty. A `vol-list --name` probe itself failed because this virsh
version does not support that option; the corrected `vol-list --details` query
succeeded for the active pool and showed that it merely enumerates unrelated
`/tmp` files. The inactive pool's corrected volume query exited nonzero because
an inactive pool cannot be listed. Neither result is called empty or healthy.

At that stop, no volume delete, target-directory delete, pool cleanup, lab
creation or download had occurred. The user then approved/delegated the amended
scope, which was executed as follows:

1. privately back up both exact pool XML definitions and original active/
   autostart states under `$EVIDENCE/preflight-pools/`;
2. disable autostart, stop only the active `tmp` pool, and undefine both pool
   definitions—without touching any target file;
3. verify session domains/pools/networks are successful-empty;
4. define/start one non-autostart pool named
   `myarch-vm-validation-20260801` targeting only `$LAB/disks`;
5. destroy/undefine that dedicated pool at the Phase-1 stop while retaining the
   approved image/baseline/evidence files.

The exact cleanup commands that were then executed are:

```bash
install -d -m 700 -- "$EVIDENCE/preflight-pools"
virsh -c "$URI" pool-dumpxml tmp   >"$EVIDENCE/preflight-pools/tmp.xml"
virsh -c "$URI" pool-dumpxml tmp.gGUA57plrL   >"$EVIDENCE/preflight-pools/tmp.gGUA57plrL.xml"
chmod 600 "$EVIDENCE/preflight-pools/"*.xml

virsh -c "$URI" pool-autostart tmp --disable
virsh -c "$URI" pool-destroy tmp
virsh -c "$URI" pool-undefine tmp
virsh -c "$URI" pool-autostart tmp.gGUA57plrL --disable
virsh -c "$URI" pool-undefine tmp.gGUA57plrL
```

No `vol-delete`, `rm` or target-path operation is part of that cleanup. The
private XML/state record is sufficient to re-define the original pools if the
cleanup itself fails. After successful-empty re-inventory, the dedicated pool was
created only after `$DISKS` existed:

```bash
virsh -c "$URI" pool-define-as myarch-vm-validation-20260801 dir   --target "$DISKS"
virsh -c "$URI" pool-start myarch-vm-validation-20260801
# Deliberately no pool-autostart command.
```

The official image selected for review is immutable by filename:

```text
Arch-Linux-x86_64-cloudimg-20260715.556894.qcow2
SHA-256 f419d4e29aebfc017ad4c9de330a3be0d7eefba710b269108b116aaca1122926
```

The image signature identifies signing subkey fingerprint
`656E4C5AC1CC3B86E539D97E343635A6859A9174`. The official `arch-boxes` README
served by Arch Linux GitLab currently publishes that subkey under primary
fingerprint `1B9A16984A4E8CB448712D2AE0B78BF4326C6F8F`. The key was parsed in an
isolated temporary GnuPG home. It is not currently present in the host pacman
key database: those two key lookup commands exited nonzero and remain failed
lookups. The apply plan therefore imports only the HTTPS-fetched official key
into a private **lab-only** GnuPG home and rejects any fingerprint mismatch; it
does not mutate or trust that key in the host pacman keyring.

## 2. Exact host-side paths and fixed parameters

The following variables are the complete host write boundary for phase 1:

```bash
URI='qemu:///session'
PORT='22222'
LAB="$HOME/.local/share/my-archlinux-setup/vm-validation-20260801"
EVIDENCE="$HOME/.local/state/my-archlinux-setup/vm-lab/20260801"
DOWNLOADS="$LAB/downloads"
DISKS="$LAB/disks"
SEED="$LAB/cloud-init"
SSH_DIR="$LAB/ssh"
GNUPG_HOME="$LAB/gnupg"
ARCHIVE="$LAB/current-reviewed-tree.tar"
IMAGE='Arch-Linux-x86_64-cloudimg-20260715.556894.qcow2'
IMAGE_SHA256='f419d4e29aebfc017ad4c9de330a3be0d7eefba710b269108b116aaca1122926'
PRIMARY_FPR='1B9A16984A4E8CB448712D2AE0B78BF4326C6F8F'
SIGNING_FPR='656E4C5AC1CC3B86E539D97E343635A6859A9174'
IMAGE_BASE_URL='https://geo.mirror.pkgbuild.com/images/latest'
KEY_README_URL='https://gitlab.archlinux.org/archlinux/arch-boxes/-/raw/master/README.md'
```

Directories are created mode `700`; downloaded metadata, seed data, SSH material,
archives, disks and evidence are never group/world accessible. The ephemeral SSH
private key remains mode `600`, is never printed or committed and is deleted only
in the separately confirmed final lab cleanup.

## 3. Approved change set if permission is granted

Phase 1 would perform only these changes:

1. Back up/remove only the two print-probe session pool definitions as above,
   create the two private user-owned lab roots, and create one temporary
   non-autostart session pool scoped to `$DISKS`.
2. Download the versioned image, its `.SHA256`, `.SHA256.sig`, `.sig`, and the
   official `arch-boxes` README using HTTPS to `.partial` files followed by
   atomic rename.
3. Extract the published public key, require the exact primary/signing
   fingerprints, cryptographically verify both detached signatures, require the
   pinned image SHA-256, and run read-only `qemu-img info/check`.
4. Generate one ephemeral VM-only SSH key and a private NoCloud seed.
5. Create a 64 GiB sparse qcow2 base overlay, boot one base-preparation domain,
   let cloud-init create the isolated `pang` user, perform one full
   `pacman -Syu --needed` containing all 18 policy `verify-only` handoff packages
   plus OpenSSH, regenerate the already-installed official-image GRUB menu,
   switch the guest to NetworkManager, enable sshd and configure VM-only tty1
   autologin.
6. Verify the post-network handoff, shut the base domain down with ACPI, undefine
   it (including NVRAM), and make the validated base overlay read-only.
7. Build a private archive from an explicit top-level allowlist, excluding
   `.git` and the root file `仓库地址` without reading that file.
8. Sequentially create, run, reboot, inspect and roll back three disposable
   candidate overlays: Niri-only, Hyprland-only and both-WM.
9. Keep the verified source image, read-only base and private evidence until the
   candidate report is reviewed. Do **not** promote host production gates in
   phase 1.

Any unexpected preflight, query, signature, package, service, graphical or
rollback result stops the matrix. It is not permission for an ad-hoc host/guest
fix; a changed plan is presented before continuing.

## 4. Image/key verification commands (completed)

Downloads use no pipe-to-execution flow:

```bash
install -d -m 700 -- "$LAB" "$EVIDENCE" "$DOWNLOADS" "$DISKS" \
  "$SEED" "$SSH_DIR" "$GNUPG_HOME"

for suffix in '' '.SHA256' '.SHA256.sig' '.sig'; do
  target="$DOWNLOADS/$IMAGE$suffix"
  curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location \
    --output "$target.partial" "$IMAGE_BASE_URL/$IMAGE$suffix"
  chmod 600 "$target.partial"
  mv -- "$target.partial" "$target"
done

curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location \
  --output "$DOWNLOADS/arch-boxes-README.md.partial" "$KEY_README_URL"
chmod 600 "$DOWNLOADS/arch-boxes-README.md.partial"
mv -- "$DOWNLOADS/arch-boxes-README.md.partial" \
  "$DOWNLOADS/arch-boxes-README.md"

sed -n '/^-----BEGIN PGP PUBLIC KEY BLOCK-----$/,/^-----END PGP PUBLIC KEY BLOCK-----$/p' \
  "$DOWNLOADS/arch-boxes-README.md" >"$DOWNLOADS/arch-boxes.asc"
chmod 600 "$DOWNLOADS/arch-boxes.asc"
```

A small Python parser reads `gpg --show-keys --with-colons` output and requires
exactly the two fingerprints above before import. Verification then runs in the
private lab home:

```bash
GNUPGHOME="$GNUPG_HOME" gpg --batch --no-options --import \
  "$DOWNLOADS/arch-boxes.asc"
GNUPGHOME="$GNUPG_HOME" gpg --batch --no-options --status-fd 1 \
  --verify "$DOWNLOADS/$IMAGE.sig" "$DOWNLOADS/$IMAGE" \
  >"$EVIDENCE/image-signature.status" 2>"$EVIDENCE/image-signature.err"
GNUPGHOME="$GNUPG_HOME" gpg --batch --no-options --status-fd 1 \
  --verify "$DOWNLOADS/$IMAGE.SHA256.sig" "$DOWNLOADS/$IMAGE.SHA256" \
  >"$EVIDENCE/checksum-signature.status" 2>"$EVIDENCE/checksum-signature.err"
```

Both status files must contain `VALIDSIG $SIGNING_FPR`; exit `0` alone is not the
only assertion. Then:

```bash
(
  cd -- "$DOWNLOADS"
  sha256sum --check --strict -- "$IMAGE.SHA256"
)
printf '%s  %s\n' "$IMAGE_SHA256" "$DOWNLOADS/$IMAGE" | sha256sum --check --strict -
qemu-img info --output=json "$DOWNLOADS/$IMAGE" >"$EVIDENCE/source-image-info.json"
qemu-img check --output=json "$DOWNLOADS/$IMAGE" >"$EVIDENCE/source-image-check.json"
chmod 440 "$DOWNLOADS/$IMAGE"
```

A failed download, key parse, signature, checksum or image check is a blocker,
not an absent/empty result.

## 5. Base handoff creation (completed after recorded failed attempts)

The ephemeral key is generated without displaying its private material:

```bash
ssh-keygen -q -t ed25519 -N '' \
  -C 'my-arch-setup-vm-validation-20260801' \
  -f "$SSH_DIR/id_ed25519"
chmod 600 "$SSH_DIR/id_ed25519"
```

The final NoCloud v3 user-data contains no password/hash and disables password
SSH/root login. It writes the fixed NetworkManager profile, VM-only tty1
autologin and a single root handoff script. `runcmd` invokes only that script, so
an earlier pacman or service failure can no longer be hidden by a successful last
command. The script uses `set -Eeuo pipefail`, a private `/run` pacman config with
`ParallelDownloads = 1`, `--disable-download-timeout`, up to three complete
transaction attempts, exact dual-kernel GRUB generation, all networkd trigger
sockets, NetworkManager/DNS/HTTPS checks and final service-owner assertions:

```yaml
#cloud-config
users:
  - name: pang
    shell: /bin/bash
    lock_passwd: true
    groups: [wheel]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - __EPHEMERAL_PUBLIC_KEY_INJECTED_WITHOUT_LOGGING__
ssh_pwauth: false
disable_root: true
ssh_deletekeys: true
ssh_genkeytypes: [ed25519]
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
write_files:
  - path: /etc/NetworkManager/system-connections/vm-handoff.nmconnection
    owner: root:root
    permissions: '0600'
    content: |
      [connection]
      id=vm-handoff
      type=ethernet
      autoconnect=true
      [ipv4]
      method=auto
      [ipv6]
      method=auto
  - path: /etc/systemd/system/getty@tty1.service.d/autologin.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Service]
      ExecStart=
      ExecStart=-/usr/bin/agetty --autologin pang --noclear %I $TERM
  - path: /usr/local/sbin/myarch-vm-handoff
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      packages=(base bash btrfs-progs coreutils dosfstools efibootmgr
        exfat-utils gawk grub linux linux-zen mkinitcpio networkmanager
        os-prober sed sudo wpa_supplicant zram-generator openssh)
      pacman_config=/run/myarch-vm-pacman.conf
      cp -- /etc/pacman.conf "$pacman_config"
      if grep -Eq '^[[:space:]]*ParallelDownloads[[:space:]]*=' "$pacman_config"; then
        sed -Ei 's/^[[:space:]]*ParallelDownloads[[:space:]]*=.*/ParallelDownloads = 1/' "$pacman_config"
      else
        printf '\nParallelDownloads = 1\n' >>"$pacman_config"
      fi
      cleanup() { rm -f -- "$pacman_config"; }
      trap cleanup EXIT
      last_status=1
      for attempt in 1 2 3; do
        if pacman --config "$pacman_config" -Syu --noconfirm --needed \
          --disable-download-timeout -- "${packages[@]}"; then
          last_status=0
          break
        else
          last_status=$?
        fi
        printf 'VM handoff pacman attempt %s failed with exit %s\n' \
          "$attempt" "$last_status" >&2
        (( attempt < 3 )) || exit "$last_status"
        sleep 15
      done
      (( last_status == 0 ))
      grub-mkconfig -o /boot/grub/grub.cfg
      systemctl enable sshd.service NetworkManager.service
      systemctl start NetworkManager.service
      # Bounded connected-state wait occurs here.
      systemctl disable systemd-networkd.service systemd-networkd.socket \
        systemd-networkd-resolve-hook.socket systemd-networkd-varlink.socket \
        systemd-networkd-varlink-metrics.socket
      systemctl stop systemd-networkd.socket \
        systemd-networkd-resolve-hook.socket systemd-networkd-varlink.socket \
        systemd-networkd-varlink-metrics.socket systemd-networkd.service
      systemctl restart NetworkManager.service
      # A second bounded connected-state wait occurs here.
      getent ahosts geo.mirror.pkgbuild.com >/dev/null
      curl --proto '=https' --tlsv1.2 --fail --silent --show-error --head \
        --max-time 30 https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db \
        >/dev/null
      systemctl start sshd.service
      systemctl is-active --quiet NetworkManager.service sshd.service
      # Every networkd service/socket must now be inactive or the script exits 1.
runcmd:
  - [/usr/local/sbin/myarch-vm-handoff]
```

The seed also includes an exact NoCloud `network-config` for DHCP on the
image's fixed `eth0` name. The full generated script—including both bounded
connected-state loops and final per-unit assertions—is hash-preserved privately;
the abbreviated comments above do not weaken the executed v3 evidence.

This autologin belongs only to the disposable external VM baseline so manual
seat-based compositor starts are possible without creating/migrating a password.
It is not a project greeter/login-manager feature and disappears with the qcow2
rollback.

Meta-data fixes a nonprivate lab instance name. The seed is built locally:

```bash
xorriso -as mkisofs -quiet -output "$DISKS/seed.iso" -volid cidata \
  -joliet -rock "$SEED/user-data" "$SEED/meta-data" "$SEED/network-config"
chmod 600 "$DISKS/seed.iso"
virsh -c "$URI" pool-refresh myarch-vm-validation-20260801
qemu-img create -f qcow2 -F qcow2 -b "$DOWNLOADS/$IMAGE" \
  -o size=64G "$DISKS/baseline-handoff.qcow2"
chmod 600 "$DISKS/baseline-handoff.qcow2"
```

The reviewed `virt-install` shape is:

```bash
virt-install --connect "$URI" --name myarch-validate-base \
  --memory 4096 --vcpus 4 --cpu host-passthrough \
  --boot uefi --osinfo archlinux --import \
  --disk "path=$DISKS/baseline-handoff.qcow2,format=qcow2,bus=virtio,cache=none,discard=unmap" \
  --disk "path=$DISKS/seed.iso,device=cdrom,readonly=on" \
  --network none \
  --qemu-commandline="-netdev user,id=vmnet0,hostfwd=tcp:127.0.0.1:$PORT-:22" \
  --qemu-commandline='-device virtio-net-pci,netdev=vmnet0,id=vmnic,bus=pcie.0,addr=0x8' \
  --graphics spice,listen=none,gl.enable=yes --video virtio,accel3d=yes \
  --sound ich9 --rng /dev/urandom --noautoconsole
```

The native SLIRP NIC provides DHCP/DNS/outbound access and binds SSH only on host
loopback. No libvirt network is defined or started. Cloud-init completion is polled through the already packaged QEMU guest agent,
with `LC_ALL=C` fixed for host-side libvirt state parsing; it does not depend on
SSH surviving the network-owner transition. Only after `status=done`,
`extended_status=done` and `errors=[]` does SSH accept the new host key into the
private lab `known_hosts`. Strict host-key checking is never disabled.

Required successful base queries are NetworkManager active, sshd active,
cloud-init complete, `systemd-detect-virt --vm`, DNS plus official mirror
reachability, successful `sudo -n -l` authorization inspection, a successful
empty system/user failed-unit baseline, expanded root storage and absence of the
project wrapper/config/state. A single successful `pacman -Qq -- ...` query must
contain all exact policy handoff packages:

```text
base bash btrfs-progs coreutils dosfstools efibootmgr exfat-utils gawk grub
linux linux-zen mkinitcpio networkmanager os-prober sed sudo wpa_supplicant
zram-generator
```

Both kernel/initramfs payload sets and regenerated GRUB menu entries are queried
without changing the boot default. The official image build itself already uses
GRUB for both BIOS and removable UEFI boot; the baseline transaction adds the
confirmed second kernel and regenerates that existing guest-only menu. No
address, MAC, UUID, host key or raw cloud-init log is copied into public
documentation.

The base is frozen only after a clean shutdown:

```bash
virsh -c "$URI" shutdown myarch-validate-base
# Poll domstate with a bounded timeout; destroy is not a successful substitute.
virsh -c "$URI" undefine myarch-validate-base --nvram
qemu-img check --output=json "$DISKS/baseline-handoff.qcow2" \
  >"$EVIDENCE/baseline-image-check.json"
chmod 440 "$DISKS/baseline-handoff.qcow2"
```

If graceful shutdown times out, execution stops for review instead of silently
using `destroy`.

### Baseline execution evidence

The approved execution produced these explicitly retained failures before the
final baseline passed:

1. Local seed validation expected eight `runcmd` rows although the v1 document
   contained seven; validation exited `1`, and ISO/disk creation had not begun.
2. First runtime start exited `1` because an unaddressed custom NIC collided with
   virtio GL video at PCI slot 1. The failed domain was absent, its one generated
   NVRAM file was safely removed, and the clean overlay check passed. The NIC is
   now fixed at otherwise unused slot 8.
3. The v1 baseline booted and cloud-init completed, but additional systemd 257
   networkd sockets kept networkd active beside NetworkManager. It was gracefully
   shut down and its clean overlay discarded.
4. The v2 baseline stopped every networkd socket, but the package download had
   failed with mirror timeout/SSL errors. Multiple independent `runcmd` rows let
   cloud-init report `done` because the final sshd command succeeded; package and
   NetworkManager checks correctly failed. A host SSH poll also timed out with
   exit `124`, and one localized `domstate` comparison briefly misclassified an
   actually running domain. Guest-agent evidence exposed both issues. The v2
   domain was gracefully shut down and its clean overlay discarded.
5. The v3 fail-fast script completed on its first pacman attempt. Final checks
   proved cloud-init done/no-errors, exact 18 precondition packages, both kernels
   and root-read GRUB entries, UEFI/Btrfs, NetworkManager as sole network owner,
   DNS/HTTPS, NOPASSWD authorization, successful-empty system/user failed-unit
   arrays and absence of all project payload/state. One ordinary-user GRUB grep
   and one cloud-output retry-count grep failed with permission denied; equivalent
   root-read guest-agent queries passed without changing permissions.

The v3 guest shut down gracefully, was undefined with NVRAM, passed qcow2 check,
was hash-recorded and is now a mode-`440` immutable handoff baseline backed by the
mode-`440` verified source image.

## 6. Exact checkout archive boundary (completed and repeated)

The archive is created only after the synchronized local static suite and review.
Its explicit allowlist prevents the untracked root file `仓库地址` from being
read or copied:

```bash
archive_tmp="$ARCHIVE.partial"
bsdtar --format=pax -C /home/pang/Projects/my-arch-setup -cf "$archive_tmp" \
  .gitignore README.md config docs installer manifests tests third_party
chmod 600 "$archive_tmp"
bsdtar -tf "$archive_tmp" >"$EVIDENCE/archive-members.txt"
mv -- "$archive_tmp" "$ARCHIVE"
archive_digest=$(sha256sum "$ARCHIVE" | awk '{print $1}')
printf '%s  current-reviewed-tree.tar\n' "$archive_digest" \
  >"$EVIDENCE/archive.SHA256"
chmod 600 "$EVIDENCE/archive.SHA256"
```

The fixed filename makes the `sha256sum` field unambiguous; a Python verifier
also requires exactly one lowercase 64-hex digest before the value is supplied
to the guest. The member list is checked for absolute/traversal paths and top-level names
outside that allowlist. Each guest receives the same archive and verifies the
same SHA-256 before extracting it into `~/my-arch-setup`. `.git`, host state,
credentials, NetworkManager secrets and the forbidden root file are absent.

## 7. Candidate scenario matrix (completed 2026-08-02)

Each scenario gets a new overlay from the read-only handoff; only one domain runs
at a time on port `22222`:

| Scenario | Domain/overlay suffix | Exact modules | Expected effects by stage |
| --- | --- | --- | --- |
| Niri | `candidate-niri` | `desktop-shared,wm-niri,input-fcitx-rime,base-preconditions,build-foundation,fonts,audio` | `2,1,55,1,2,3,3,33,29` |
| Hyprland | `candidate-hyprland` | `desktop-shared,wm-hyprland,input-fcitx-rime,base-preconditions,build-foundation,fonts,audio` | `2,1,55,1,2,3,3,33,28` |
| both | `candidate-both` | `desktop-shared,wm-niri,wm-hyprland,input-fcitx-rime,base-preconditions,build-foundation,fonts,audio` | `2,1,58,1,2,3,3,34,29` |

The effect order is `privilege-wrapper`, `official-update`,
`official-packages`, `archlinuxcn-bootstrap`, `archlinuxcn-packages`,
`aur-source-acquisition`, `aur-build-install`, `user-config`, `system-actions`.
The single bootstrap effect explicitly displays all three reviewed operations:
the pinned keyring package, fixed pacman include/fragment configuration, and a
conditional second full-system/repository refresh after that trust is added.
This is not counted or described as only one full update, and no partial `-Sy`
path is permitted.

For each suffix:

```bash
qemu-img create -f qcow2 -F qcow2 -b "$DISKS/baseline-handoff.qcow2" \
  "$DISKS/<suffix>.qcow2"
chmod 600 "$DISKS/<suffix>.qcow2"

virt-install --connect "$URI" --name "myarch-<suffix>" \
  --memory 4096 --vcpus 4 --cpu host-passthrough \
  --boot uefi --osinfo archlinux --import \
  --disk "path=$DISKS/<suffix>.qcow2,format=qcow2,bus=virtio,cache=none,discard=unmap" \
  --network none \
  --qemu-commandline="-netdev user,id=vmnet0,hostfwd=tcp:127.0.0.1:$PORT-:22" \
  --qemu-commandline='-device virtio-net-pci,netdev=vmnet0,id=vmnic,bus=pcie.0,addr=0x8' \
  --graphics spice,listen=none,gl.enable=yes --video virtio,accel3d=yes \
  --sound ich9 --rng /dev/urandom --noautoconsole
```

After archive verification/extraction, the guest must first show the closed plan,
then enable only the reversible in-VM candidate:

```bash
cd "$HOME/my-arch-setup"
python installer/vm-candidate-gate.py --plan --json
python installer/vm-candidate-gate.py --enable --confirm-vm-candidate
python installer/vm-candidate-gate.py --status --json
python installer/full-orchestrator.py --profile vm --modules '<exact-modules>' \
  --mode new --plan --json
```

The plan must have all nine canonical handlers, the expected effects above,
`production_apply_integration=true`, no apply blocker, and the canonical
adapter/input fingerprints. A mismatch stops before apply.

The first changing run deliberately stops after the archlinuxcn package
transaction but before any AUR source is acquired:

```bash
python installer/full-orchestrator.py --profile vm --modules '<exact-modules>' \
  --mode new --apply --stop-after-stage archlinuxcn-packages \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
# Required exit: 75; state: running; archlinuxcn-packages: passed;
# aur-source-acquisition: pending.
```

`--stop-after-stage` is a hard execution fence. If the named stage fails,
verification fails, or it is dependency-skipped, the command returns the
preserved failure instead of running any later independent branch; later rows
remain pending for an explicit retry. Only a passed named stage produces the
resumable exit `75` above.

At this exit-75 boundary Fuzzel is not installed yet. On the VM tty, the helper's
real fixed `systemd-ask-password` fallback is exercised with a disposable
noncredential marker; only a boolean match and the explicit warning are retained,
never the entered/output text. The run then remains paused for the controlled
first-source failure below. After eventual graphical login, the Fuzzel branch is
tested the same way from a terminal.

## 8. Controlled failure, retry and idempotence (completed with retained failures)

Because this is the first run and the AUR source stage is still pending, no
verified source cache can turn the planned network failure into a false
idempotent success. With no pacman transaction active, `/etc/hosts` is backed up under
`/run` and three selected source hosts are mapped to loopback using the installed,
hash-verified guest `gsudo`. SSH remains connected to host loopback. The exact
in-guest mutation is:

```bash
GSUDO="$HOME/scripts/desktop/gsudo"
test -x "$GSUDO"
test -f /etc/hosts && test ! -L /etc/hosts
before_hosts_hash=$(sha256sum /etc/hosts | awk '{print $1}')
before_hosts_mode=$(stat -c '%a' /etc/hosts)
"$GSUDO" -- cp --archive -- /etc/hosts /run/myarch-vm-hosts.before
printf '%s\n' \
  '127.0.0.1 github.com raw.githubusercontent.com codeberg.org # myarch-vm-controlled-failure' \
  '::1 github.com raw.githubusercontent.com codeberg.org # myarch-vm-controlled-failure' \
  | "$GSUDO" -- tee --append /etc/hosts >/dev/null
python - <<'PY_HOSTS_BLOCKED'
import socket
for host in ('github.com', 'raw.githubusercontent.com', 'codeberg.org'):
    addresses = {row[4][0] for row in socket.getaddrinfo(host, 443)}
    assert addresses and addresses <= {'127.0.0.1', '::1'}, (host, addresses)
PY_HOSTS_BLOCKED
```

Resuming must fail specifically in `aur-source-acquisition` and preserve the
external nonzero exit:

```bash
python installer/full-orchestrator.py --profile vm --modules '<exact-modules>' \
  --mode new --apply --resume --stop-after-stage aur-source-acquisition \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
# Required: nonzero; state identifies aur-source-acquisition as failed and every
# later stage remains pending.
```

The failure mapping is rolled back before retry; byte hash and mode must match
and external DNS must again return at least one non-loopback result:

```bash
"$GSUDO" -- cp --archive -- /run/myarch-vm-hosts.before /etc/hosts
[[ $(sha256sum /etc/hosts | awk '{print $1}') == "$before_hosts_hash" ]]
[[ $(stat -c '%a' /etc/hosts) == "$before_hosts_mode" ]]
"$GSUDO" -- rm -f -- /run/myarch-vm-hosts.before
python - <<'PY_HOSTS_RESTORED'
import socket
for host in ('github.com', 'raw.githubusercontent.com', 'codeberg.org'):
    addresses = {row[4][0] for row in socket.getaddrinfo(host, 443)}
    assert addresses and not addresses <= {'127.0.0.1', '::1'}, (host, addresses)
PY_HOSTS_RESTORED

python installer/full-orchestrator.py --profile vm --modules '<exact-modules>' \
  --mode new --apply --retry-stage aur-source-acquisition \
  --stop-after-stage aur-source-acquisition \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
# Required on success: exit 75; aur-source-acquisition: passed; every later
# stage remains pending. A real external retry failure keeps its exact nonzero
# exit and uses this same bounded retry command again after reachability returns.
```

`--stop-after-stage` is command-scoped and is not retained from the earlier
archlinuxcn boundary. It must therefore be supplied on both the controlled
failure resume and every source retry. If the planned failure occurs in
preflight or any other stage, or any later stage leaves `pending`, it is not
accepted and no retry claim is made. A successful source retry exits `75` and
proves the public graceful boundary without killing any package transaction.
The first full apply then resumes from that boundary:

```bash
python installer/full-orchestrator.py --profile vm --modules '<exact-modules>' \
  --mode new --apply --resume \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
```

An additional unchanged `--rerun` must converge without duplicate repo/include/
environment/wants entries or a new config backup. Package manifests, config
hashes, backup inventory and failed-unit queries are compared before/after.

For symmetric config restore evidence, one mapped user target is deliberately
changed after the unchanged rerun, then another `--rerun` must back it up and
restore the repository payload. `--list-backups` selects the completed deployment
backup whose target list contains that exact path. The plan is printed, cancelled
once to prove zero writes, then confirmed with exact `restore <id>`. The reported
pre-restore rollback backup is selected by `source_backup_id` and restored in the
same exact-confirmation flow. Final adapter verification must match repository
content and mode.

## 9. Reboot and graphical acceptance (automated VM scope completed)

After automatic stages and structured pending/reboot guidance are recorded, the
installed audited wrapper performs the guest reboot:

```bash
"$HOME/scripts/desktop/gsudo" -- systemctl reboot
```

The SSH disconnect is expected, but it is not itself proof of reboot. The host
requires a successful libvirt state query followed by a new successful SSH boot
identity/uptime query and complete adapter verification. A timeout or failed
query is retained as failure/unavailable evidence.

The VM-only tty1 autologin then creates a real seat/logind user session without
a project greeter. `virt-manager -c qemu:///session --show-domain-console
<domain>` is opened only after approval; it is a GUI action and will require the
normal execution approval path.

From tty1 the user manually starts:

- Niri-only: `/usr/bin/niri-session`;
- Hyprland-only: `/usr/bin/start-hyprland`;
- both: each command in a separate clean login, logging out between them.

The matching `phase-c-session-check.py --profile vm` command runs from a terminal
inside the active session. The explicit VM profile makes only physical Bluetooth/
Blueman and power-profile ownership `not-applicable`; Portal, audio, Fcitx
startup and failed-unit checks remain strict. Exit `0` covers only its automated
checks. Manual acceptance
still covers compositor startup, mapped single/both-WM boundaries, DMS exactly
once, Fuzzel, Fcitx5/Rime, file chooser, screenshots, screen sharing, PipeWire
playback/recording, reboot/relogin and successful-empty failed-unit queries.
Unavailable virtual hardware remains unavailable rather than passing; VM results
do not replace physical GPU/ASUS/Bluetooth/audio/suspend/boot evidence.

## 10. Per-scenario rollback and final phase-1 stop (completed)

Before rollback, private evidence is copied to `$EVIDENCE/<suffix>/` without raw
credentials, addresses, MACs, UUIDs or private logs. The in-guest candidate
manifest backup is restored and its exact original hashes verified:

```bash
python installer/vm-candidate-gate.py --restore --confirm-vm-candidate
```

Then:

```bash
virsh -c "$URI" shutdown "myarch-<suffix>"
# Require shut off within the bounded timeout.
virsh -c "$URI" undefine "myarch-<suffix>" --nvram
qemu-img check --output=json "$DISKS/<suffix>.qcow2" \
  >"$EVIDENCE/<suffix>/overlay-final-check.json"
rm -f -- "$DISKS/<suffix>.qcow2"
```

Deleting the disposable overlay returns to the immutable handoff. A fresh
`myarch-rollback-probe` overlay is booted after the matrix to compare the base
package manifest and prove the project checkout/state/config/repository/service
effects are absent. It is then shut down, undefined with NVRAM and deleted.

After all domains are absent, the dedicated session pool is stopped and
undefined without deleting files:

```bash
virsh -c "$URI" pool-destroy myarch-vm-validation-20260801
virsh -c "$URI" pool-undefine myarch-vm-validation-20260801
```

Phase 1 stops here. The source image, read-only baseline, seed, SSH key and
private evidence are retained for review; all candidate domains/overlays and the
dedicated session pool are absent. No host gate is promoted automatically.

Only after reviewing all three candidate results would a separate plan propose:

1. changing only proven `modules.tsv`/`stages.tsv` gates in the host checkout;
2. rerunning static tests and an independent read-only review;
3. requesting a second explicit approval;
4. repeating all three scenarios from fresh baseline overlays without
   `vm-candidate-gate.py` to prove the canonical production path.

## 11. Rollback scope

- **Before base freeze:** shut down the domain; if graceful shutdown fails, stop
  for review. Undefine with `--nvram`; retain the failed disk/evidence until
  diagnosed rather than calling it rolled back.
- **Guest failure injection:** restore byte-for-byte `/etc/hosts` from the
  pre-change `/run` backup through audited guest `gsudo` before retry.
- **Config restore:** every restore creates and reports a restorable pre-restore
  backup before the first target write.
- **Candidate manifests:** use `vm-candidate-gate.py --restore` only when its
  recorded hashes accept the current tree; otherwise stop.
- **Scenario package/repository/service/config changes:** undefine the shut-down
  domain and delete only its child overlay; the read-only baseline is unchanged.
- **Whole lab cleanup (later, separately confirmed):** after concise evidence is
  committed and the user approves deletion, remove only `$LAB` and the raw
  private `$EVIDENCE` tree. The temporary user-session pool is first destroyed/
  undefined without volume deletion. No host package/service/network rollback is
  needed because phase 1 makes none.

## 12. Execution incident and retained rollback state — 2026-08-01

The dedicated user-session pool was accidentally marked autostart while
`virsh pool-autostart` was mistakenly used as a read-only query. The command was
immediately reversed with `--disable`; a successful `pool-info` post-check
reported the pool active, persistent and `Autostart: no`. No volume, domain,
network or disk file was changed by the correction. Future inventory must read
the `Autostart` field from `pool-info`; bare `pool-autostart` is never a query.

The first Niri child remains disposable failed-preflight evidence. It must be
shut down gracefully, undefined with only its NVRAM, checked while offline and
then have only `candidate-niri.qcow2` deleted. The mode-440 source image and
mode-440 `baseline-handoff.qcow2` remain immutable rollback anchors. The repaired
checkout is never copied over the candidate-enabled old checkout; a newly hashed
allowlisted archive and fresh child are required.

## 13. Current Niri AUR-build checkpoint — 2026-08-01

A sixth fresh Niri child repeated the frozen-baseline checks, fixed archive
verification, reversible candidate gate, exact canonical plan and global
preflight. The controlled AUR-source failure proved the repaired hard stop fence;
`/etc/hosts` was restored byte-for-byte and by mode, external resolution passed
a bounded recheck, and the temporary backup was removed. A source retry then
passed with three durable attempts. The real pre-Fuzzel systemd askpass fallback
also passed through a PTY with a disposable noncredential marker; only status and
boolean warning/answer matches were retained.

The full resume initialized and updated the private clean chroot, built
`dsearch-bin` and `fcitx5-skin-fluentdark-git`, and verified the fixed
`fuzzel-ime-git` source. Its build then returned exact exit `255`: Meson could
not resolve the runtime Cairo dependency. The orchestrator preserved that exit,
while the independent `user-config` branch passed and `system-actions` returned
`1`. A later read-only structured state query succeeded and proved the sole
failed action was `dsearch-user-service`, which could not succeed because the
AUR stage correctly installs nothing after any build failure. The private build
log is retained at `$EVIDENCE/niri/sixth-aur-private.log`; raw private log bytes
are not copied into this document.

A local regression first failed because the fixed recipe metadata omitted
`cairo`. Both `PKGBUILD` and generated `.SRCINFO` now declare it as a runtime
dependency, and the recipe-tree plus recipe-policy input digests were recomputed
through the canonical planner/input algorithms. The AUR source/build/stage tests,
stage executable/input tests, complete static suite, standalone documentation
check and `git diff --check` all pass; generated bytecode was removed. This fix
is not yet VM-accepted. The running child is evidence only and must be shut down,
undefined and checked offline before deleting only its overlay and creating a
new child from the mode-440 baseline. It must never receive an in-place checkout
patch.

## 14. Seventh Niri procedural stop-fence failure — 2026-08-01

A seventh fresh child passed the 210-package baseline comparison, successful-
empty system/user failed-unit queries, project-absence checks, fixed archive
verification, reversible candidate gate, exact canonical plan and the initial
exit-`75` stop after `archlinuxcn-packages`. The real pre-Fuzzel systemd askpass
fallback also passed after replacing one ambiguously quoted SSH shell query with
a structured remote-Python check. That discarded query and an unavailable
optional `pactree` query remain recorded as failures, not evidence.

The first hosts-injection aggregate query exited `1`; its automatic rollback was
then independently shown to restore hash/mode and external DNS. A second bounded
injection check passed. The documented controlled-failure resume was then run
literally. `aur-source-acquisition` preserved exit `2`, but
`aur-build-install` became dependency-skipped, `user-config` passed and
`system-actions` failed instead of all three remaining pending. The cause was
procedural, not a scheduler regression: the documented command omitted
`--stop-after-stage aur-source-acquisition`, while stop options are command-
scoped. Earlier sixth-run stderr proves its successful hard-fence probe had
carried that parameter.

`/etc/hosts` was restored to the original hash/mode, a bounded external resolver
check passed, the `/run` backup was removed and the controlled marker is absent.
The seventh archive, sanitized final state and private run log are retained under
`$EVIDENCE/niri/`. A docs regression failed before the correction and now
requires the controlled resume command to carry its own stop boundary. This
changed checkout must be archived and tested only in another fresh child; the
seventh guest is failed evidence and is never patched in place.

## 15. Eighth Niri complete transaction and graphical evidence — 2026-08-01

The eighth fresh child accepted the Cairo recipe repair and the corrected
command-scoped source stop fence. Its 210-package baseline and 435-member
allowlisted archive matched their frozen inputs. Candidate enable exposed the
expected nine stages and `2,1,55,1,2,3,3,33,29` effects with no apply blocker.
Initial package stop, pre-Fuzzel askpass fallback, controlled source failure,
exact hosts rollback, bounded source retry and full resume produced exits
`75,0,2,75,0` in their documented boundaries. All three fixed AUR packages then
built and installed in the clean chroot, including the new Cairo runtime.

The unchanged rerun was package/config/repository/backup idempotent. A deliberate
mapped-config drift proved deployment backup, cancelled restore, exact restore,
pre-restore rollback and rollback restore. The official mirror later timed out
during post-restore verification, producing an honest `aur-build-install` exit
`1`; an exact HTTPS recheck and stage-only retry returned `0`. A transient
post-apply user-manager query also exited `1`; a diagnostic query and three
bounded rechecks later passed. The guest reboot was observed by a changed boot
identity without retaining the identity, and the post-reboot canonical rerun and
all package/config/service/failed-unit checks passed.

The real tty1/logind Niri session accepted DMS once, Kitty, Niri-only config
ownership, Fuzzel, masked Fuzzel askpass, Fcitx5/Rime candidates, screenshot
creation, Portal file chooser and Portal ScreenCast. The ScreenCast flow returned
`0` for CreateSession/SelectSources/Start with one stream and retained no handle,
node ID or raw stream. Two prior interaction timeouts remain failed evidence.
PipeWire exposed one sink/source, playback returned `0`, and finite PipeWire
recording to a discard sink returned `0`; an interrupted `pw-record` exit `1` is
retained separately.

The checkout still carried the old session checker. Its exit `2` preserved the
false physical Bluetooth/Blueman/power blockers while its strict Portal/audio/
Fcitx/bus/failed-unit checks passed. The host repair introduces explicit
`--profile {physical,vm}`, leaves physical as the strict default, makes only
physical hardware ownership nonapplicable in a VM, uses the exact VM Hyprland
config path and keeps audio conflicts applicable. Targeted checker/docs tests,
the complete static suite and whitespace check pass locally, but this repair was
not copied into the eighth child. The eighth run is therefore strong evidence,
not the final Niri acceptance.

The next rollback is narrowly fixed: retain private eighth evidence, graceful
shutdown, bounded shutoff, undefine only `myarch-candidate-niri` with NVRAM,
offline JSON image check and delete only `candidate-niri.qcow2`. Rebuild the
allowlisted archive first, then create the next child from the immutable mode-440
baseline and require the new `--profile vm` checker to exit `0`, candidate
manifest restore to match original hashes, and the disposable overlay rollback
to complete. No host root/package/service/boot/network/system-config change is
part of this boundary.

## 16. Ninth Niri external failure and reviewer-triggered restart — 2026-08-01

The ninth child verified the immutable baseline, final-profile-checker archive,
candidate gate and exact Niri plan. Its first official package run and two
stage-only retries preserved exit `1` for low-speed/SSL EOF mirror failures.
An intervening exact HTTPS HEAD returned `0` but did not turn those later failed
transfers into success. The fourth retry's host SSH process returned `255`; a
later strict SSH query and guest-agent ping both succeeded, so the transport
failure remains separate from the durable stage state.

That state proved official packages, archlinuxcn bootstrap/packages, AUR source
and user config passed. Clean-chroot initialization then preserved exit `255`
for another timeout/SSL/download failure, and dsearch's system action returned
`1` behind the all-or-nothing AUR fence. A successful package query counted 676
packages; no pacman process or lock remained. Private run/build logs are
retained. The child was not retried after independent review changed the host
tree: it shut down gracefully, was undefined with NVRAM, passed offline qcow2
checking and had only its overlay deleted.

The independent review itself completed and identified five locally reproduced
issues: two final-exchange races capable of losing concurrent config/manifest
writes, a config-only auxiliary-input false blocker, merged VM power-conflict
status that was not explicitly `not-applicable`, and comment/unreachable-code
Hyprland startup ownership. Each now has a red-then-green regression. Conditional
manifest/config exchange verifies displaced and installed identities, retains
both files on a second race, and candidate terminal status rechecks manifest
truth. Auxiliary inputs are required per applicable trust stage rather than by a
global nonempty count. Audio and power conflict checks are independent, and the
Hyprland guard must be a direct executable startup-callback statement.

Because these fixes change the reviewed archive and the config adapter hash, the
ninth child can never be patched into evidence. After the full synchronized
suite and archive rebuild, the exact next VM is a tenth fresh child from the
mode-440 baseline. It must pass final VM-profile session acceptance, conditional
candidate restore and offline overlay rollback.

## 17. Final Niri pass and retryable chroot initialization — 2026-08-02

The post-review tenth Niri child completed the final candidate proof. A fixed
archlinuxcn asset download first returned exit `7`; later bounded HEAD checks
and an exact stage retry completed all nine stages, followed by an unchanged
rerun and observed reboot. The real Niri session's `--profile vm` checker
returned `0`/ready with strict Portal/audio/Fcitx/bus/failed-unit evidence and
explicit physical `not-applicable` results. Conditional candidate restore,
idempotent restore, closed-gate recheck, graceful shutdown, offline image check,
baseline digest verification and child overlay deletion all passed.

The next Hyprland-only child exposed a retry defect after a real external
clean-chroot initialization exit `255`. `mkarchroot` left a partial root, so old
preflight rejected the exact AUR stage retry as incomplete. The repaired fixed
build tool preserves the external failure, removes only known `root` and
`root.lock` under its validated private chroot using audited fixed argv, refuses
to erase unknown entries, and leaves a clean absent boundary for retry. A
red-then-green partial-root/same-state retry test plus AUR adapter and canonical
pin tests pass. The stale child was safely discarded; the required fresh Hyprland child and
later matrices are recorded below.

## 18. Final candidate, canonical and rollback-probe execution — 2026-08-02

A fresh fixed Hyprland candidate, then a fresh both-WM candidate, completed all
nine exact stages, convergent reruns, verified reboot and strict VM-profile
session checks. Both-WM acceptance used separate clean Niri and Hyprland tty/
login sessions. The Niri guest screenshot was a valid readable 1280×800 PNG;
Hyprland noninteractive Portal Screenshot returned response code `2` and remains
unavailable. Candidate restore and its idempotent second call matched the closed
manifest hashes before each child was checked offline and deleted.

The main tree then promoted only the byte-identical candidate values: nine stage
booleans and five module availability fields. Fresh canonical Niri, Hyprland and
both children ran without candidate state. Exact effects were
`2,1,55,1,2,3,3,33,29`, `2,1,55,1,2,3,3,33,28`, and
`2,1,58,1,2,3,3,34,29`; plans had canonical adapter/input fingerprints and no
apply blocker. Each scenario reached a final exit-0 unchanged rerun, changed
boot identity, ready matching session check and zero-error offline rollback.
Official mirror exit `1`, AUR source-query exit `2`, Niri quit transport exit
`1` and stale prior-compositor user units remain explicit evidence with bounded
rechecks/retries; none is relabeled as a first-attempt pass.

The final `myarch-rollback-probe` child matched the baseline's 210 packages and
found no checkout/state/config/repository/environment/wants/service residue.
After its own offline check and child-only deletion, libvirt domain inventory was
successfully empty. The dedicated pool was stopped and undefined without
`pool-delete`; the target, immutable baseline, seed and private evidence remain.
The plan's disposable VM phase is therefore closed. Physical and still-planning
module acceptance remains outside this completed VM execution.


## 19. Post-matrix fail-closed review and final-tree rerun requirement — 2026-08-02

A later completed independent review found two defects outside the previously
reported five. Both were reproduced before editing. First, the archlinuxcn root
helper could overwrite a different administrator entry arriving after its hash
check but before `os.replace`. It now uses `RENAME_NOREPLACE` for an absent
fragment and `RENAME_EXCHANGE` for existing fragment/`pacman.conf` targets,
verifies displaced bytes/hash/mode/UID/GID/device/inode, exchanges back on drift
and retains a recovery path on a second race or rollback failure. Second,
registry-level `personal-autostart=available` let `flclash-bin` escape the claim
that all 12 non-VM recipes were blocked. A new plan-hashed
`production-module-readiness.tsv` gate covers all 32 modules (9 available, 21
planning, 2 unavailable), blocks FlClash and the other 11 recipes, and separately
audits the five registry-available modules absent from exact VM selections.

These repairs did not authorize a new package/config/service effect or alter the
immutable baseline, but they changed the reviewed archive, canonical plan
fingerprint and archlinuxcn adapter hash. The old matrix therefore remained
historical evidence for its exact tree. After the synchronized local suite and
archive rebuild, a fresh approved `myarch-final-tree-both` child verified the
437-member archive and exact both-WM plan. Initial archlinuxcn download exit `7`
was retained; two exact HEAD queries and stage retry returned `0`; a clean rerun
returned `0` with an unchanged 684-package manifest. Reboot identity changed,
then separate clean Niri and Hyprland checkers both returned ready. Harness-only
process polling, screendump, summary parsing and obsolete/misquoted Hyprland quit
attempts remain explicit failed evidence; corrected structured checks and
`hl.dsp.exit()` succeeded.

The domain shut down gracefully, was undefined with NVRAM and its child reported
zero offline check errors before child-only deletion. Baseline SHA-256 was
unchanged. The dedicated pool was destroyed and undefined without `pool-delete`;
final domain inventory succeeded empty and the pool was absent. The final-tree
spot phase is closed for the exact both-WM selection, while physical and
production-planning scope remains outside it.
