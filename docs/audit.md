# Local configuration audit

The configuration phase inventories the current workstation broadly so a
reinstalled copy of the same machine can reproduce its **complete functional
personal environment**. The running host is the golden source. It is not limited
to a few demonstration directories, and machine-specific values are not removed
merely for portability. The safety boundary is explicit mapping and secret
exclusion, not an arbitrary small count.

Run:

```bash
bash installer/audit-candidates.sh
```

The report is written under
`~/.local/state/my-archlinux-setup/audits/` with mode `600`. It contains only
relative paths, type, mode, and size. It does not read file contents, traverse
outside the predefined desktop candidates, copy data, upload anything, or
write to the repository.

After reviewing its scope, run `bash installer/audit-content.sh` for the
predefined reusable desktop/developer roots. This second report reads eligible
text/config files but stores only a relative path, size, SHA-256, and
risk-category flags. It never prints or stores matching lines or values; it
deliberately excludes browser/chat/note/credential/state roots and common
media, audio, video, and font extensions before hashing or pattern scanning.

For a narrower approval, create a private newline-delimited list of paths
relative to `$HOME`, then run:

```bash
bash installer/audit-content.sh --files-from /private/path/selected-files.txt
```

Selected-list mode performs no directory traversal. It currently accepts only
normalized regular files under `.config/niri/`, `.config/hypr/`,
`.config/fcitx5/`, and `.config/DankMaterialShell/`; it rejects empty lists,
duplicates, paths outside those roots, missing files, and any symlink component.
An explicit selection may include a backup-named file when that exact file was
approved for review, unlike the broad mode's conservative basename exclusions.

Reports are generated as mode-`600` temporary files in the private audit
directory and renamed only after a complete successful scan. Traversal, stat,
hash, or pattern-query failure preserves the external exit status and removes
the incomplete report; a failed scan is never presented as an empty result.
Symlinked content-review roots, selected paths, selected-list files, and project
audit-state directories are rejected rather than followed silently.

## Broad candidate scope

The metadata phase broadly inventories every immediate `~/.config` entry and
recursively lists metadata for roots that are not excluded for clear security
reasons. This includes Wayland compositors, DMS, bars/launchers,
notifications, terminals, fish/starship, Fcitx5, GTK theming, desktop theme
tools, user-session units, development tools, and related desktop tools.
`~/scripts/` was inventoried by metadata first, then the reviewed working-tree subset was promoted into explicit mappings.

The scripts walk prunes nested `.git` and `.ssh` entries and omits the same
credential-shaped basenames used by the desktop-config metadata walk (for
example `.env` and `credentials.json`). It records neither their contents nor
their path metadata.

It deliberately excludes browser profiles, chat apps, note applications,
caches, databases, session files, credential stores, audio cookies, and
separately managed private tool configuration. It also does not scan media;
assets need an explicit future path and confirmed redistribution license.

## Content review and classification

Before a candidate is committed, inspect it and record two separate decisions:

1. **Personal restore: include** — copy the functional current file for the
   same-user/same-ASUS profile, including machine-specific values when needed.
2. **Personal restore: exclude** — omit actual credentials/private keys or
   clearly regenerable backup, cache, empty-marker or ephemeral session state.
3. **Optional portability note** — independently label a future generic/public
   preset as unchanged, sanitized, template or excluded. This label does not
   restrict the personal restore manifest.

Every deployed target remains a specified file or reviewed minimal tree.
Existing targets are backed up before replacement, executable modes are
preserved, selected modules deploy only their own rows, and unlisted files stay
untouched. This is faithful restore without a blind whole-home overwrite.

The first reviewed file set and its intentionally deferred candidates are in
[`configuration.md`](configuration.md).
