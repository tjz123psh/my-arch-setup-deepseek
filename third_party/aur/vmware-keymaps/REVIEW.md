# Review: vmware-keymaps

## Status

- Decision: **reviewed AUR recipe; required runtime dependency of
  vmware-workstation (AUR→AUR edge), built and installed FIRST by 06-aur.sh
  so `makepkg -s` on vmware-workstation can resolve it** (review 5.5).
- Small data-only package: installs xkeymap tables into
  `/usr/lib/vmware/xkeymap`. No build step beyond installing files.
- Source is a pinned GitHub release tarball (chowbok/vmware-keymaps v1.0),
  hash-verified by `makepkg` during fetch.

## Provenance

- AUR origin: `https://aur.archlinux.org/vmware-keymaps.git`
- AUR commit: `1a08d90fb1a40d9c67bb80076d5ad41c69db9818`
- Version: `1.0-3`; license: `custom:none` (VMware keymap data).
- Upstream source: `https://github.com/chowbok/vmware-keymaps/archive/refs/tags/v1.0.tar.gz`
- Source SHA-256: `e8ee0df9e35c4a28ab46bc9f9cefc6e2934fe382b93f115bd2e61a2b74490649`

## Integration notes

- Listed in `manifests/aur-recipes.tsv` but NOT in
  `manifests/workstation-packages.tsv` as an install target: it is a
  build-time dependency of vmware-workstation, not an operator-facing target.
  The reconciliation test only requires install targets to have recipes, not
  the reverse (recipe-only deps are allowed).
- 06-aur.sh bootstraps it before the main batch (see REVIEW.md in
  vmware-workstation for the ordering rationale).
