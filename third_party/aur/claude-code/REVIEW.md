# Review: claude-code

## Status

- Decision: **reviewed and pinned** for x86_64 source acquisition; this is an upgrade, not a regression.
- The executable was not downloaded or run; source checksum enforcement and metadata generation were verified.

## Provenance

- Local AUR snapshot: `/tmp/my-arch-setup-aur-review-20260801/claude-code`
- AUR origin: `https://aur.archlinux.org/claude-code.git`
- AUR commit: `17784e502f8e85b945a662c63a39abd9f1fbebbe` (2026-07-26, `Update claude-code to 2.1.220`)
- Reviewed tree: `5bd330c063faf6daa18d08276776d9b6b8cad764`
- Upstream version / license declaration: `2.1.220` / `LicenseRef-claude-code`
- Fixed executable URL: Anthropic's version-specific `2.1.220/linux-x64/claude` path; SHA-256 `674f61f20ff306f3100cf9200e4c36c4b70278b5bef2884549819b942a89c863`.
- Legal snapshot: fetched from `https://code.claude.com/docs/en/legal-and-compliance.md` on 2026-08-01, stored as local `cc-legal`, SHA-256 `d8814ea0d3a0ae8294d2e274ace1c5f7ab09353bae9da78a5050308828b4100f`.
- The local clone's full commit and object graph passed object and filesystem-integrity checks.

## Version reconciliation

- Inventory observation: `2.1.215-1`.
- AUR snapshot and fixed recipe: `2.1.220-1`.
- `vercmp(2.1.220-1, 2.1.215-1) = 1`: **upgrade**.

## Local changes from the AUR recipe

- Restricted architecture and binary source to x86_64.
- Replaced the mutable legal-document download with a committed text snapshot and an enforced SHA-256.
- Preserved the wrapper that disables upstream self-update and installation-layout checks.
- Removed all unchecked sources; build and package functions perform no network acquisition.

## Remaining risks

- Claude Code is an opaque upstream executable and was not reproduced from source.
- The local legal snapshot is auditable but can become stale relative to Anthropic's live terms; reviewers must compare it before a future version bump.
- The legal page links to separate live terms and policies whose content is not vendored here.

## Expected output

- Package: `claude-code 2.1.220-1 (x86_64)`
- Default artifact: `claude-code-2.1.220-1-x86_64.pkg.tar.zst`
- Expected payload: `/opt/claude-code/bin/claude`, `/usr/bin/claude`, and the pinned legal snapshot.
