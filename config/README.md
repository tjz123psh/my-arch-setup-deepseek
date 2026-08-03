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
`config/home/` owns the 162-row physical payload; `config/vm/home/` owns only the
four VM-specific files, while the remaining VM rows deliberately reuse reviewed
physical sources.
Static validation rejects symlinks, group/world-writable payload, private-key
blocks, common token shapes and shell-style secret assignments and validates
JSON. Runtime repeats source/target safety checks and backs up changed targets.

Credentials, private keys, NetworkManager secrets, browser/chat/note profiles,
cookies, tokens, caches, databases and private session state remain excluded.
The Fish payload may optionally source the user-maintained, unmapped
`~/.config/fish/private-env.fish`; no secret value belongs here.

Portable/system templates live separately under `config/templates/` and are
never silently substituted for user payload. The archlinuxcn and AUR pacman
templates are now hash-bound inputs to their dedicated production adapters, but
false stage/module gates still prevent use before approved VM validation.

The mapped `scripts/desktop/gsudo` payload never changes the privilege route:
production adapters call only that wrapper, which dispatches `sudo -A`. It does
not pre-require the later AUR Fuzzel provider, so NOPASSWD clean-base bootstrap
can proceed. Its adjacent askpass helper prefers Fuzzel and otherwise warns
before using fixed `/usr/bin/systemd-ask-password`; if neither prompt provider is
available it exits `127`. No password or prompt output belongs in repository or
validation logs.
