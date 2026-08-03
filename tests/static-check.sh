#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
declare -a unavailable_validators=()
pycache_root=$(mktemp -d)
trap 'rm -rf -- "$pycache_root"' EXIT

for script in "$root"/installer/*.sh "$root"/tests/*.sh; do
  bash -n "$script"
done

shellcheck "$root"/installer/*.sh "$root"/tests/*.sh

PYTHONPYCACHEPREFIX="$pycache_root" python -m py_compile "$root"/installer/*.py "$root"/tests/*.py

python - "$root" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
expected_profiles = {"asus-amd-nvidia", "desktop-amd", "vm"}
module_name_pattern = re.compile(r"[a-z0-9][a-z0-9-]*")


def data_lines(path: pathlib.Path, schema: str):
    if path.is_symlink():
        raise SystemExit(f"manifest must not be a symlink: {path.relative_to(root)}")
    lines = path.read_text().splitlines()
    if not lines or lines[0] != schema:
        raise SystemExit(f"unsupported or missing schema marker: {path.relative_to(root)}")
    for line_number, raw in enumerate(lines, 1):
        if not raw or raw.startswith("#"):
            continue
        yield line_number, raw


def parse_dependencies(raw: str, owner: str, relation: str) -> tuple[str, ...]:
    if raw == "-":
        return ()
    parts = raw.split(",")
    if any(not part or not module_name_pattern.fullmatch(part) for part in parts):
        raise SystemExit(f"invalid {relation} dependency list for {owner}")
    if len(parts) != len(set(parts)):
        raise SystemExit(f"duplicate {relation} dependency for {owner}")
    if owner in parts:
        raise SystemExit(f"self dependency for module {owner}")
    return tuple(parts)


module_path = root / "manifests/modules.tsv"
modules: dict[str, dict[str, object]] = {}
for line_number, raw in data_lines(module_path, "# schema=1"):
    parts = raw.split("\t")
    if len(parts) != 6 or not all(parts):
        raise SystemExit(f"invalid module registry row at line {line_number}")
    module, availability, kind, requires_all_raw, requires_any_raw, purpose = parts
    if not module_name_pattern.fullmatch(module):
        raise SystemExit(f"unsafe module name at line {line_number}: {module}")
    if module in modules:
        raise SystemExit(f"duplicate module at line {line_number}: {module}")
    if availability not in {"available", "planning", "unavailable"}:
        raise SystemExit(f"invalid module availability at line {line_number}: {availability}")
    if kind not in {"selectable", "dependency"}:
        raise SystemExit(f"invalid module kind at line {line_number}: {kind}")
    if any(ord(character) < 32 for character in purpose):
        raise SystemExit(f"control character in module purpose at line {line_number}")
    modules[module] = {
        "availability": availability,
        "kind": kind,
        "requires_all": parse_dependencies(requires_all_raw, module, "requires-all"),
        "requires_any": parse_dependencies(requires_any_raw, module, "requires-any"),
    }
if not modules:
    raise SystemExit("module registry has no entries")
for module, metadata in modules.items():
    for dependency in (*metadata["requires_all"], *metadata["requires_any"]):
        if dependency not in modules:
            raise SystemExit(f"module {module} references unknown dependency: {dependency}")

# Deterministic requires-all closure must be acyclic.
visit_state: dict[str, int] = {}

def visit(module: str) -> None:
    state = visit_state.get(module, 0)
    if state == 1:
        raise SystemExit(f"requires-all dependency cycle includes {module}")
    if state == 2:
        return
    visit_state[module] = 1
    for dependency in modules[module]["requires_all"]:
        visit(dependency)
    visit_state[module] = 2

for module in modules:
    visit(module)

profile_path = root / "manifests/profile-modules.tsv"
profile_modules: dict[str, dict[str, str]] = {}
profile_scopes: dict[str, str] = {}
seen_profile_modules: set[tuple[str, str]] = set()
for line_number, raw in data_lines(profile_path, "# schema=1"):
    parts = raw.split("\t")
    if len(parts) != 4 or not all(parts):
        raise SystemExit(f"invalid profile module row at line {line_number}")
    profile, config_scope, module, default_state = parts
    if profile not in expected_profiles:
        raise SystemExit(f"unknown module profile at line {line_number}: {profile}")
    if config_scope != "none" and not module_name_pattern.fullmatch(config_scope):
        raise SystemExit(f"unsafe config scope at line {line_number}: {config_scope}")
    if module not in modules:
        raise SystemExit(f"unknown profile module at line {line_number}: {module}")
    if modules[module]["kind"] != "selectable":
        raise SystemExit(f"dependency-only module exposed by profile at line {line_number}: {module}")
    if default_state not in {"selected", "disabled"}:
        raise SystemExit(f"invalid module default at line {line_number}: {default_state}")
    key = (profile, module)
    if key in seen_profile_modules:
        raise SystemExit(f"duplicate profile/module at line {line_number}: {profile}/{module}")
    seen_profile_modules.add(key)
    if profile in profile_scopes and profile_scopes[profile] != config_scope:
        raise SystemExit(f"inconsistent config scope for profile {profile}")
    profile_scopes[profile] = config_scope
    profile_modules.setdefault(profile, {})[module] = default_state
missing_profiles = sorted(expected_profiles - profile_modules.keys())
if missing_profiles:
    raise SystemExit(f"profile module manifest lacks profiles: {', '.join(missing_profiles)}")


def close_selection(profile: str, initial: set[str]) -> set[str]:
    selected = set(initial)
    changed = True
    while changed:
        changed = False
        for module in tuple(selected):
            for dependency in modules[module]["requires_all"]:
                if modules[dependency]["kind"] == "selectable" and dependency not in profile_modules[profile]:
                    raise SystemExit(
                        f"profile {profile} cannot satisfy {dependency} required by {module}"
                    )
                if dependency not in selected:
                    selected.add(dependency)
                    changed = True
    for module in selected:
        alternatives = modules[module]["requires_any"]
        if alternatives and not selected.intersection(alternatives):
            raise SystemExit(f"default selection for {profile}: {module} lacks requires-any dependency")
    return selected

for profile, choices in profile_modules.items():
    defaults = {module for module, state in choices.items() if state == "selected"}
    close_selection(profile, defaults)

mapping = root / "manifests/config-mappings.tsv"
sources = set()
source_keys = set()
target_keys = set()
known_scopes = set(profile_scopes.values()) - {"none"}
for line_number, raw in data_lines(mapping, "# schema=2"):
    parts = raw.split("\t")
    if len(parts) != 4 or not all(parts):
        raise SystemExit(f"invalid config mapping at line {line_number}")
    config_scope, module, source, target = parts
    if config_scope not in known_scopes:
        raise SystemExit(f"unknown config scope at line {line_number}: {config_scope}")
    if module not in modules:
        raise SystemExit(f"unknown config module at line {line_number}: {module}")
    if not any(
        profile_scopes[profile] == config_scope and module in choices
        for profile, choices in profile_modules.items()
    ):
        raise SystemExit(f"config module is unavailable in scope at line {line_number}: {module}")
    source_key = (config_scope, source)
    target_key = (config_scope, target)
    if source_key in source_keys:
        raise SystemExit(f"duplicate config mapping source in scope at line {line_number}: {config_scope}/{source}")
    source_keys.add(source_key)
    sources.add(source)
    if target_key in target_keys:
        raise SystemExit(f"duplicate config mapping target in scope at line {line_number}: {config_scope}/{target}")
    target_keys.add(target_key)
    source_path = pathlib.PurePosixPath(source)
    target_path = pathlib.PurePosixPath(target)
    if source.startswith("/") or target.startswith("/") or ".." in source_path.parts or ".." in target_path.parts:
        raise SystemExit(f"unsafe config mapping at line {line_number}")
    if source != source_path.as_posix() or target != target_path.as_posix():
        raise SystemExit(f"non-canonical config mapping at line {line_number}")
    if not re.fullmatch(r"[A-Za-z0-9._/+:-]+", source) or not re.fullmatch(r"[A-Za-z0-9._/+:-]+", target):
        raise SystemExit(f"unsupported/control character in config mapping at line {line_number}")
    if not (root / source).is_file():
        raise SystemExit(f"missing config mapping source at line {line_number}: {source}")
    if not (
        target.startswith(".config/")
        or target.startswith(".local/share/fcitx5/rime/")
        or target.startswith("scripts/")
    ):
        raise SystemExit(f"config mapping target outside approved user roots at line {line_number}: {target}")
    if source not in {f"config/home/{target}", f"config/vm/home/{target}"}:
        raise SystemExit(f"config mapping source must mirror target under an approved scope root at line {line_number}: {source} -> {target}")

public_roots = (root / "config/home", root / "config/vm/home")
actual_sources = set()
sensitive_patterns = {
    "private-key-block": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "GitHub-token-shape": re.compile(rb"(?:github_" rb"pat_|gh[pousr]_[A-Za-z0-9]{20,})"),
    "OpenAI-token-shape": re.compile(rb"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"),
    "AWS-access-key-shape": re.compile(rb"(?<![A-Z0-9])AKIA[A-Z0-9]{16}(?![A-Z0-9])"),
    "shell-secret-assignment-shape": re.compile(
        rb"(?im)^[ \t]*(?:export[ \t]+)?"
        rb"[A-Za-z_][A-Za-z0-9_]*(?:api[_-]?key|access[_-]?token|password|secret)"
        rb"[A-Za-z0-9_]*[ \t]*=[ \t]*[\"'][^\"'\n]{8,}[\"']"
    ),
    "fish-secret-assignment-shape": re.compile(
        rb"(?im)^[ \t]*set(?:[ \t]+-[A-Za-z]+)*[ \t]+"
        rb"[A-Za-z_][A-Za-z0-9_]*(?:api[_-]?key|access[_-]?token|password|secret)"
        rb"[A-Za-z0-9_]*[ \t]+[\"'][^\"'\n]{8,}[\"']"
    ),
    "generic-secret-assignment-shape": re.compile(
        rb"(?i)(?:api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[\"'][^\"'\n]{8,}"
    ),
}

sensitive_pattern_fixtures = {
    "OpenAI-token-shape": b"sk-" + b"x" * 32,
    "AWS-access-key-shape": b"AKIA" + b"X" * 16,
    "shell-secret-assignment-shape": b'export SERVICE_API_KEY="placeholder-value"\n',
    "fish-secret-assignment-shape": b'set -x SERVICE_API_KEY "placeholder-value"\n',
    "generic-secret-assignment-shape": b'api_key: "placeholder-value"\n',
}
for category, fixture in sensitive_pattern_fixtures.items():
    if not sensitive_patterns[category].search(fixture):
        raise SystemExit(f"sensitive-pattern regression fixture was not detected: {category}")
benign_secret_reference = b'v2_write_secret_references "$staging" "$source_root"\n'
for category, pattern in sensitive_patterns.items():
    if pattern.search(benign_secret_reference):
        raise SystemExit(f"sensitive-pattern false positive for secret reference: {category}")
for public_root in public_roots:
    for path in public_root.rglob("*"):
        if path.is_symlink():
            raise SystemExit(f"public configuration payload must not contain symlinks: {path.relative_to(root)}")
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        actual_sources.add(relative)
        if not (
            relative.startswith("config/home/.config/")
            or relative.startswith("config/home/.local/share/fcitx5/rime/")
            or relative.startswith("config/home/scripts/")
            or relative.startswith("config/vm/home/.config/")
            or relative.startswith("config/vm/home/.local/share/fcitx5/rime/")
            or relative.startswith("config/vm/home/scripts/")
        ):
            raise SystemExit(f"payload outside approved user roots: {relative}")
        relative_parts = path.relative_to(public_root).parts
        if ".ssh" in relative_parts or ".git" in relative_parts:
            raise SystemExit(f"credential/VCS directory entered configuration payload: {relative}")
        if path.name in {"id_rsa", "id_ed25519", "identity", "credentials", ".env"}:
            raise SystemExit(f"credential-shaped file entered configuration payload: {relative}")
        source_mode = path.stat().st_mode & 0o777
        if source_mode not in {0o600, 0o644, 0o744, 0o755}:
            raise SystemExit(f"configuration payload mode must be 600, 644, 744 or 755: {relative}")
        if path.stat().st_mode & 0o022:
            raise SystemExit(f"public configuration payload is group/world writable: {relative}")
        data = path.read_bytes()
        for category, pattern in sensitive_patterns.items():
            if pattern.search(data):
                raise SystemExit(f"public configuration payload matched {category}: {relative}")

unmapped = sorted(actual_sources - sources)
if unmapped:
    raise SystemExit(f"repository configuration files lack explicit mappings: {', '.join(unmapped)}")
stale = sorted(sources - actual_sources)
if stale:
    raise SystemExit(f"configuration mappings reference missing payload: {', '.join(stale)}")

for path in (root / "config").rglob("*.json"):
    json.loads(path.read_text())

for checked_relative in (
    "config/home/.config/niri/dms/keybinds.kdl",
    "config/home/.config/hypr/conf/keybinds.lua",
):
    checked = root / checked_relative
    if checked.exists():
        checked_text = checked.read_text()
        for stale_entrypoint in ("$HOME/.local/bin/niri-keys", "$HOME/.local/bin/hypr-keys"):
            if stale_entrypoint in checked_text:
                raise SystemExit(f"WM config references non-restored .local/bin entrypoint: {checked_relative}: {stale_entrypoint}")

packages = root / "manifests/official-packages.tsv"
seen_by_profile = set()
profile_counts = {}
for line_number, raw in data_lines(packages, "# schema=2"):
    parts = raw.split("\t")
    if len(parts) != 4 or not all(parts):
        raise SystemExit(f"invalid official package manifest at line {line_number}")
    profile, module, package, purpose = parts
    if profile not in expected_profiles:
        raise SystemExit(f"unknown package profile at line {line_number}: {profile}")
    if module not in modules:
        raise SystemExit(f"unknown package module at line {line_number}: {module}")
    if modules[module]["kind"] == "selectable" and module not in profile_modules[profile]:
        raise SystemExit(f"package module unsupported by profile at line {line_number}: {profile}/{module}")
    if not re.fullmatch(r"[a-z0-9@._+:-]+", package):
        raise SystemExit(f"unsafe package name at line {line_number}: {package}")
    if any(ord(character) < 32 for character in purpose):
        raise SystemExit(f"control character in package purpose at line {line_number}")
    profile_counts[profile] = profile_counts.get(profile, 0) + 1
    key = (profile, package)
    if key in seen_by_profile:
        raise SystemExit(f"duplicate package for profile at line {line_number}: {package}")
    seen_by_profile.add(key)

missing_profiles = sorted(expected_profiles - profile_counts.keys())
if missing_profiles:
    raise SystemExit(f"official package manifest lacks profiles: {', '.join(missing_profiles)}")
PY

python "$root/tests/docs-check.py" >/dev/null
"$root/tests/audit-tools-test.sh" >/dev/null
"$root/tests/config-deploy-test.sh" >/dev/null
"$root/tests/privilege-wrapper-test.sh" >/dev/null
"$root/tests/config-stage-apply-test.sh" >/dev/null
"$root/tests/module-selection-test.sh" >/dev/null
"$root/tests/production-readiness-test.sh" >/dev/null
"$root/tests/legacy-installer-gate-test.sh" >/dev/null
"$root/tests/orchestration-test.sh" >/dev/null
"$root/tests/full-orchestrator-test.sh" >/dev/null
"$root/tests/stage-executables-test.sh" >/dev/null
"$root/tests/stage-inputs-test.sh" >/dev/null
"$root/tests/vm-candidate-gate-test.sh" >/dev/null
"$root/tests/phase-c-plan-test.sh" >/dev/null
"$root/tests/phase-c-transaction-preview-test.sh" >/dev/null
"$root/tests/phase-c-session-check-test.sh" >/dev/null
"$root/tests/system-action-plan-test.sh" >/dev/null
"$root/tests/system-action-apply-test.sh" >/dev/null
"$root/tests/personal-config-plan-test.sh" >/dev/null
"$root/tests/reference-baseline-test.sh" >/dev/null
"$root/tests/kernel-plan-test.sh" >/dev/null
"$root/tests/kernel-support-check-test.sh" >/dev/null
"$root/tests/dms-source-plan-test.sh" >/dev/null
if ! command -v nvim >/dev/null; then
  unavailable_validators+=("nvim")
fi
"$root/tests/nvim-config-test.sh" >/dev/null
"$root/tests/official-package-test.sh" >/dev/null
"$root/tests/official-package-apply-test.sh" >/dev/null
"$root/tests/workstation-package-inventory-test.sh" >/dev/null
"$root/tests/workstation-package-reconciliation-test.sh" >/dev/null
"$root/tests/package-config-relations-test.sh" >/dev/null
"$root/tests/provider-decisions-test.sh" >/dev/null
"$root/tests/archlinuxcn-source-plan-test.sh" >/dev/null
"$root/tests/archlinuxcn-apply-test.sh" >/dev/null
"$root/tests/aur-source-plan-test.sh" >/dev/null
"$root/tests/aur-source-acquire-test.sh" >/dev/null
"$root/tests/aur-build-test.sh" >/dev/null
"$root/tests/aur-install-test.sh" >/dev/null
"$root/tests/aur-stage-apply-test.sh" >/dev/null
"$root/tests/workstation-package-plan-test.sh" >/dev/null
"$root/tests/preflight-test.sh" >/dev/null

if command -v stylua >/dev/null; then
  stylua --check "$root/config/home/.config/nvim"
else
  printf 'Neovim formatting check unavailable: stylua was not found.\n' >&2
  unavailable_validators+=("stylua")
fi

if command -v niri >/dev/null; then
  niri validate -c "$root/config/home/.config/niri/config.kdl" >/dev/null
  niri validate -c "$root/config/vm/home/.config/niri/config.kdl" >/dev/null
else
  printf 'Niri configuration parser check unavailable: niri was not found.\n' >&2
  unavailable_validators+=("niri")
fi

if command -v Hyprland >/dev/null; then
  Hyprland --verify-config -c "$root/config/home/.config/hypr/hyprland.lua" >/dev/null
  Hyprland --verify-config -c "$root/config/vm/home/.config/hypr/hyprland.lua" >/dev/null
else
  printf 'Hyprland configuration parser check unavailable: Hyprland was not found.\n' >&2
  unavailable_validators+=("Hyprland")
fi

if ((${#unavailable_validators[@]} > 0)); then
  printf 'Static validation incomplete; unavailable validators: %s\n' "${unavailable_validators[*]}" >&2
  exit 2
fi
printf 'Static checks passed; all required validators ran.\n'
