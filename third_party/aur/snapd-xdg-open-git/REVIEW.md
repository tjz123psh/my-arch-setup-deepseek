# Review: snapd-xdg-open-git

## Status

- Decision: **reviewed AUR recipe, VCS source pinned to a commit**. Not an
  install target: it is the AUR->AUR runtime dependency of
  `linuxqq-nt-bwrap`, bootstrapped by 06-aur before the main batch (the
  `vmware-keymaps` precedent).

## Provenance

- AUR origin: `https://aur.archlinux.org/snapd-xdg-open-git.git`
- AUR commit: `6d9020d89459d250359660664b7170c3355eda03`
- Upstream: `https://github.com/snapcore/snapd-xdg-open`, commit
  `6fed3570066ea93598e8091bf749352a02d482ad` (2017-03-31, the HEAD the
  reference machine's build used: installed `snapd-xdg-open-git r44.6fed357-2`).
- License: GPL-3.0-or-later.

## Local changes from the AUR recipe

- `source=("git+...#commit=6fed3570066ea93598e8091bf749352a02d482ad")`: the
  upstream commit is pinned so the build never follows repository HEAD
  (supply-chain rule for VCS recipes; `md5sums=('SKIP')` is inherent to a
  VCS source and is compensated by the commit pin).
- No other change.

## Offline cache

- `fetch-aur-sources.sh` mirrors upstream into `.aur-sources/snapd-xdg-open`
  (bare git mirror); with `SRCDEST` pointing at the cache, makepkg clones from
  the mirror and never touches the network.

## Expected output

- Package: `snapd-xdg-open-git r44.6fed357-2 (x86_64)`
