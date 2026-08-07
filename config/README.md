# Reviewed personal deployable configuration

This tree contains the explicitly reviewed payload for the same-user/same-ASUS
restorer. Faithful machine-specific output names, display values, personal paths
and helper behavior are allowed when required by the working workstation. It is
not a generic public dotfile template and is never permission to copy all of
`$HOME` or `.config`.

Every deployed regular file must have one per-scope row in
`manifests/config-mappings.tsv`, one selected module owner and a reviewed mode
declared in that row (`600`, `644`, `744` or `755`); the declared mode, not the
working-tree permission, is what gets deployed.
`config/home/` owns the physical-v1 payload (231 rows at last reconciliation);
VMware guests deploy the same full scope except the machine-role rows, which
follow `MACHINE_TYPE` (vmware-host rows deploy on physical only,
vmware-guest rows on vm only — same module selection as packages). There is no
separate VM tree.
Static reconciliation validates manifest schema, source-file existence and
mode syntax. Deploy-time safety (07-config) refuses to follow symlinks anywhere
in the target path — a symlinked target or path component is skipped instead of
writing through to a file outside HOME — and backs up changed targets first.
The host-asset sync workflow runs a secret scan before copying and again on the
staged diff; Fish payload with credential assignments is never copied.

Credentials, private keys, NetworkManager secrets, browser/chat/note profiles,
cookies, tokens, caches, databases and private session state remain excluded.
The Fish payload may optionally source the user-maintained, unmapped
`~/.config/fish/private-env.fish`; no secret value belongs here.

Portable/system templates live separately under `config/templates/` and are
never silently substituted for user payload. The archlinuxcn and AUR pacman
templates are hash-bound inputs to their dedicated production adapters, but
module gates still prevent use before approved VM validation.

The mapped `scripts/desktop/gsudo` payload never changes the privilege route:
production adapters call only that wrapper, which dispatches `sudo -A`. It does
not pre-require the later AUR Fuzzel provider, so the scoped-sudo clean-base
bootstrap can proceed. Its adjacent askpass helper prefers Fuzzel and otherwise
warns before using fixed `/usr/bin/systemd-ask-password`; if neither prompt
provider is available it exits `127`. No password or prompt output belongs in
repository or validation logs.
