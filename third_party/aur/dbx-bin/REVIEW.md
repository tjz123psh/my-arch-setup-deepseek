# Review: dbx-bin

## Status

- Decision: **reviewed AUR recipe pinned to the machine's installed version**.
  New install target (2026-09-16): the operator asked whether dbx was in the
  payload; it was not, so it is added.

## Provenance

- AUR origin: `https://aur.archlinux.org/dbx-bin.git`
- AUR commit: `05d13d1ce57a590183f3170550a38f911e494b39` ("Update to version 0.6.4", 2026-09-04)
- Reviewed version: `0.6.4-1` — matches the reference machine's installed
  `dbx-bin 0.6.4-1`.
- Note: AUR HEAD is already `0.6.14-1` (2026-09-16). The recipe is deliberately
  pinned to the installed version so offline restores reproduce the reference
  machine; bumping it later means updating `pkgver` + the deb `sha256` together.
- Upstream / license: `https://github.com/t8y2/dbx` / MIT.
- Pinned payload (`source_x86_64`, a GitHub release deb):
  `https://github.com/t8y2/dbx/releases/download/v0.6.4/dbx_0.6.4_amd64.deb`
  with SHA-256 `82eb52a54706a9664f5ee0a754726f81572a9732f97c711cfe086f5d04e4e015`.

## Local changes from the AUR recipe

- None: the PKGBUILD is used as reviewed (it already restricts `arch` to
  x86_64 and extracts the deb in `package()`). No patch files.

## Dependencies

- `webkit2gtk-4.1` and `gtk3` come from the official repositories, so no
  AUR->AUR prerequisite bootstrap is needed for this target.

## Expected output

- Package: `dbx-bin 0.6.4-1 (x86_64)`
