#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
adapter="$root/installer/aur-stage-apply.py"

fail() {
  printf 'AUR stage apply test failed: %s\n' "$*" >&2
  exit 1
}

[[ -f $adapter && ! -L $adapter ]] || fail 'production AUR stage adapter is missing or unsafe'

# The production adapter must bind the reviewed privilege payloads and the four
# existing AUR boundary tools, rather than trusting PATH aliases.
/usr/bin/python3 - "$adapter" "$root" <<'PY'
import hashlib
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace

sys.dont_write_bytecode = True
path, root = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("aur_stage_apply_constants", path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
checks = {
    "AUDITED_GSUDO_SHA256": root / "config/home/scripts/desktop/gsudo",
    "AUDITED_ASKPASS_SHA256": root / "config/home/scripts/desktop/fuzzel-askpass",
    "AUR_PLAN_SHA256": root / "installer/aur-plan.py",
    "AUR_SOURCE_ACQUIRE_SHA256": root / "installer/aur-source-acquire.py",
    "AUR_BUILD_SHA256": root / "installer/aur-build.py",
    "AUR_INSTALL_SHA256": root / "installer/aur-install.py",
}
for name, source in checks.items():
    assert getattr(module, name) == hashlib.sha256(source.read_bytes()).hexdigest(), name

# Fuzzel is installed by this very AUR stage and the reviewed askpass helper
# already has a fixed systemd-ask-password fallback. It cannot be a base tool
# required before global preflight; NOPASSWD execution does not invoke either
# prompt provider.
original_which = module.shutil.which
module.shutil.which = lambda name: None if name == "fuzzel" else f"/usr/bin/{name}"
try:
    pending = module.check_commands(
        SimpleNamespace(
            local_sources=(),
            stage="aur-source-acquisition",
            action="preflight",
            selected_modules=(),
        )
    )
finally:
    module.shutil.which = original_which
assert pending == ()
PY

test_root=$(mktemp -d -p /var/tmp myarch-aur-stage-apply-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
runtime="$test_root/runtime"
home="$runtime/home"
mock_bin="$test_root/mock-bin"
call_log="$test_root/calls.tsv"
source_data="$test_root/source-data"
mkdir -p "$fixture/manifests" "$fixture/third_party" "$fixture/config/home/scripts/desktop" \
  "$fixture/config/templates" "$fixture/installer" "$home/scripts/desktop" "$mock_bin" "$source_data"
chmod 700 "$runtime" "$home" "$mock_bin" "$source_data"
: >"$call_log"

cp -- "$root/manifests/workstation-packages.tsv" "$fixture/manifests/"
cp -- "$root/manifests/aur-recipes.tsv" "$fixture/manifests/"
cp -- "$root/manifests/aur-source-acquisition.tsv" "$fixture/manifests/"
cp -- "$root/manifests/aur-build-policy.tsv" "$fixture/manifests/"
cp -- "$root/config/templates/aur-build-pacman.conf" "$fixture/config/templates/"
cp -- "$root/config/home/scripts/desktop/gsudo" "$fixture/config/home/scripts/desktop/gsudo"
cp -- "$root/config/home/scripts/desktop/fuzzel-askpass" "$fixture/config/home/scripts/desktop/fuzzel-askpass"
cp -- "$fixture/config/home/scripts/desktop/gsudo" "$home/scripts/desktop/gsudo"
cp -- "$fixture/config/home/scripts/desktop/fuzzel-askpass" "$home/scripts/desktop/fuzzel-askpass"
cp -a -- "$root/third_party/aur" "$fixture/third_party/aur"
chmod 755 "$fixture/config/home/scripts/desktop/gsudo" \
  "$fixture/config/home/scripts/desktop/fuzzel-askpass" \
  "$home/scripts/desktop/gsudo" "$home/scripts/desktop/fuzzel-askpass"

# Replace the three huge fixed-source hashes only inside the disposable fixture,
# update their recipe declarations, and recompute the canonical recipe tree
# hashes. This lets execute/idempotence paths run without network or large data.
/usr/bin/python3 - "$fixture" "$source_data" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
data_root = Path(sys.argv[2])
acquisition_path = root / "manifests/aur-source-acquisition.tsv"
lines = acquisition_path.read_text().splitlines()
old_to_new: dict[str, str] = {}
outputs: dict[str, bytes] = {}
rewritten: list[str] = []
for line in lines:
    if not line or line.startswith("#"):
        rewritten.append(line)
        continue
    fields = line.split("\t")
    package = fields[0]
    data = f"isolated fixed source for {package}\n".encode()
    digest = hashlib.sha256(data).hexdigest()
    old_to_new[fields[3]] = digest
    fields[3] = digest
    fields[4] = str(len(data))
    if fields[1] != "cargo-vendor":
        fields[6] = digest
    outputs[package] = data
    (data_root / package).write_bytes(data)
    rewritten.append("\t".join(fields))
acquisition_path.write_text("\n".join(rewritten) + "\n")

for package in outputs:
    directory = root / "third_party/aur" / package
    for name in (".SRCINFO", "PKGBUILD"):
        path = directory / name
        text = path.read_text()
        for old, new in old_to_new.items():
            text = text.replace(old, new)
        path.write_text(text)

def tree_hash(directory: Path) -> str:
    digest = hashlib.sha256()
    for entry in sorted(directory.iterdir(), key=lambda item: os.fsencode(item.name)):
        assert entry.is_file() and not entry.is_symlink()
        mode = stat.S_IMODE(entry.stat().st_mode)
        file_digest = hashlib.sha256(entry.read_bytes()).hexdigest()
        digest.update(entry.name.encode())
        digest.update(b"\0")
        digest.update(f"{mode:04o}".encode())
        digest.update(b"\0")
        digest.update(file_digest.encode())
        digest.update(b"\n")
    return digest.hexdigest()

recipe_path = root / "manifests/aur-recipes.tsv"
recipe_lines: list[str] = []
for line in recipe_path.read_text().splitlines():
    if not line or line.startswith("#"):
        recipe_lines.append(line)
        continue
    fields = line.split("\t")
    fields[8] = tree_hash(root / "third_party/aur" / fields[0])
    recipe_lines.append("\t".join(fields))
recipe_path.write_text("\n".join(recipe_lines) + "\n")
PY

cat >"$fixture/installer/aur-plan.py" <<'PY'
#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--verify-sources", action="store_true")
parser.add_argument("--packages", required=True)
parser.add_argument("--source-cache", type=Path, required=True)
parser.add_argument("--project-root", type=Path, required=True)
parser.add_argument("--json", action="store_true")
args = parser.parse_args()
with open(os.environ["MOCK_CALL_LOG"], "a", encoding="utf-8") as handle:
    handle.write("aur-plan\t" + "\t".join(sys.argv[1:]) + "\n")
forced = os.environ.get("MOCK_AUR_PLAN_STATUS")
if forced is not None:
    if os.environ.get("MOCK_AUR_PLAN_EMPTY") != "1":
        print(json.dumps({"mock": "forced planner failure", "overall": {"status": "unavailable"}}))
    raise SystemExit(int(forced))
recipes = {}
for line in (args.project_root / "manifests/aur-recipes.tsv").read_text().splitlines():
    if line and not line.startswith("#"):
        fields = line.split("\t")
        recipes[fields[0]] = fields
sources = {}
for line in (args.project_root / "manifests/aur-source-acquisition.tsv").read_text().splitlines():
    if line and not line.startswith("#"):
        fields = line.split("\t")
        sources[fields[0]] = fields
selected = args.packages.split(",")
reports = []
all_blockers = []
for package in selected:
    row = recipes[package]
    blockers = []
    source_rows = []
    if package in sources:
        policy = sources[package]
        target = args.source_cache / package / policy[2]
        matching = (
            target.is_file()
            and not target.is_symlink()
            and hashlib.sha256(target.read_bytes()).hexdigest() == policy[3]
        )
        if not matching:
            blockers.append(f"{package}: required fixed local source is missing: {policy[2]}")
            source_rows.append({"kind": "local", "filename": policy[2], "state": "missing"})
        else:
            source_rows.append({"kind": "local", "filename": policy[2], "state": "verified"})
    has_remote = row[9] == "remote-fixed" or package == "paru"
    if has_remote:
        source_rows.append({
            "kind": "remote",
            "filename": f"{package}.remote",
            "state": "verified-by-makepkg" if args.verify_sources else "declared-unverified",
        })
    if blockers:
        status = "blocked"
        verification = {"status": "not-requested", "query_exit": None}
    elif args.verify_sources and has_remote:
        status = "ready"
        verification = {"status": "verified", "query_exit": 0}
    elif has_remote:
        status = "static-ready"
        verification = {"status": "not-run", "query_exit": None, "required_for_apply": True}
    else:
        status = "ready"
        verification = {"status": "not-requested", "query_exit": None}
    all_blockers.extend(blockers)
    reports.append({
        "package": package,
        "pkgbase": row[1],
        "role": row[2],
        "module": row[3],
        "pkgver": row[4],
        "pkgrel": row[5],
        "recipe_tree_sha256": row[8],
        "actual_recipe_tree_sha256": row[8],
        "source_policy": row[9],
        "external_source": row[10],
        "sources": source_rows,
        "source_verification": verification,
        "status": status,
        "blockers": blockers,
        "unavailable_checks": [],
    })
if all_blockers:
    overall, code = "blocked", 1
elif any(row["status"] == "static-ready" for row in reports):
    overall, code = "static-ready", 0
else:
    overall, code = "ready", 0
print(json.dumps({
    "schema": 1,
    "selection": {"source": "explicit", "packages": selected},
    "recipes": reports,
    "overall": {
        "status": overall,
        "exit_code": code,
        "blockers": all_blockers,
        "unavailable_checks": [],
        "source_verification_required": [row["package"] for row in reports if row["status"] == "static-ready"],
    },
}))
raise SystemExit(code)
PY

cat >"$fixture/installer/aur-source-acquire.py" <<'PY'
#!/usr/bin/env python3
import argparse
import os
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--apply", action="store_true")
parser.add_argument("--confirm-aur", action="store_true")
parser.add_argument("--packages", required=True)
parser.add_argument("--cache-root", type=Path, required=True)
parser.add_argument("--project-root", type=Path, required=True)
args = parser.parse_args()
with open(os.environ["MOCK_CALL_LOG"], "a", encoding="utf-8") as handle:
    handle.write("aur-source-acquire\t" + "\t".join(sys.argv[1:]) + "\n")
status = int(os.environ.get("MOCK_SOURCE_STATUS", "0"))
if status:
    raise SystemExit(status)
assert args.apply and args.confirm_aur
policies = {}
for line in (args.project_root / "manifests/aur-source-acquisition.tsv").read_text().splitlines():
    if line and not line.startswith("#"):
        fields = line.split("\t")
        policies[fields[0]] = fields
for package in args.packages.split(","):
    row = policies[package]
    directory = args.cache_root / package
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    target = directory / row[2]
    if not target.exists():
        target.write_bytes((Path(os.environ["MOCK_SOURCE_DATA"]) / package).read_bytes())
    os.chmod(target, 0o600)
print("mock fixed sources acquired")
PY

cat >"$fixture/installer/aur-build.py" <<'PY'
#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
action = parser.add_mutually_exclusive_group()
action.add_argument("--plan", action="store_true")
action.add_argument("--build", action="store_true")
parser.add_argument("--post-official", action="store_true")
parser.add_argument("--confirm-aur", action="store_true")
parser.add_argument("--confirm-system-changes", action="store_true")
parser.add_argument("--packages", required=True)
parser.add_argument("--source-cache", type=Path, required=True)
parser.add_argument("--build-root", type=Path, required=True)
parser.add_argument("--state-root", type=Path, required=True)
parser.add_argument("--project-root", type=Path, required=True)
parser.add_argument("--json", action="store_true")
args = parser.parse_args()
with open(os.environ["MOCK_CALL_LOG"], "a", encoding="utf-8") as handle:
    handle.write("aur-build\t" + "\t".join(sys.argv[1:]) + "\n")
recipes = {}
for line in (args.project_root / "manifests/aur-recipes.tsv").read_text().splitlines():
    if line and not line.startswith("#"):
        fields = line.split("\t")
        recipes[fields[0]] = fields
selected = args.packages.split(",")

def create_artifacts():
    for package in selected:
        row = recipes[package]
        directory = args.build_root / "artifacts" / package / row[8]
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(directory, 0o700)
        filename = f"{package}-{row[4]}-{row[5]}-x86_64.pkg.tar.zst"
        artifact = directory / filename
        if not artifact.exists():
            artifact.write_bytes(f"verified mock artifact for {package}\n".encode())
        os.chmod(artifact, 0o600)
        metadata = {
            "package": package,
            "pkgbase": row[1],
            "version": f"{row[4]}-{row[5]}",
            "arch": "x86_64",
            "filename": filename,
            "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
            "bytes": artifact.stat().st_size,
            "file_count": 1,
            "files": [f"usr/share/{package}"],
        }
        state = directory / "artifact.json"
        state.write_text(json.dumps(metadata, sort_keys=True) + "\n")
        os.chmod(state, 0o600)
    chroot = args.state_root / "builds/aur/chroot/root"
    (chroot / "usr/bin").mkdir(parents=True, exist_ok=True)
    (chroot / ".arch-chroot").write_text("mock\n")
    (chroot / "usr/bin/pacman").write_text("mock\n")
    (chroot / "usr/bin/rustc").write_text("mock\n")

if args.build:
    assert args.post_official and args.confirm_aur and args.confirm_system_changes
    status = int(os.environ.get("MOCK_BUILD_STATUS", "0"))
    if status:
        raise SystemExit(status)
    create_artifacts()
    print("mock clean-chroot build passed")
    raise SystemExit(0)
status = int(os.environ.get("MOCK_BUILD_PLAN_STATUS", "0"))
if status:
    raise SystemExit(status)
reports = []
for package in selected:
    row = recipes[package]
    directory = args.build_root / "artifacts" / package / row[8]
    metadata = json.loads((directory / "artifact.json").read_text()) if (directory / "artifact.json").is_file() else None
    artifact = {"state": "absent", "directory": str(directory)}
    if metadata is not None:
        artifact = {
            "state": "verified",
            "directory": str(directory),
            "artifact": str(directory / metadata["filename"]),
            "sha256": metadata["sha256"],
        }
    reports.append({
        "package": package,
        "pkgbase": row[1],
        "role": row[2],
        "module": row[3],
        "pkgver": row[4],
        "pkgrel": row[5],
        "tree_sha256": row[8],
        "source_status": "ready",
        "artifact": artifact,
    })
ready = all(row["artifact"]["state"] == "verified" for row in reports)
print(json.dumps({
    "schema": 1,
    "policy": {"backend": "clean-chroot", "architecture": "x86_64", "root_helper": "gsudo"},
    "selection": {"packages": selected},
    "commands": [
        {"command": name, "state": "available"}
        for name in ("makepkg", "mkarchroot", "makechrootpkg", "arch-nspawn")
    ],
    "root_helper": {"state": "available", "path": str(Path.home() / "scripts/desktop/gsudo")},
    "chroot": {"state": "ready" if ready else "absent", "path": str(args.state_root / "builds/aur/chroot")},
    "packages": reports,
    "overall": {
        "status": "ready" if ready else "blocked",
        "exit_code": 0 if ready else 1,
        "blockers": [] if ready else ["artifacts missing"],
        "unavailable_checks": [],
    },
}))
raise SystemExit(0 if ready else 1)
PY

cat >"$fixture/installer/aur-install.py" <<'PY'
#!/usr/bin/env python3
import argparse
import json
import os
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
action = parser.add_mutually_exclusive_group()
action.add_argument("--plan", action="store_true")
action.add_argument("--install", action="store_true")
parser.add_argument("--confirm-aur", action="store_true")
parser.add_argument("--confirm-system-changes", action="store_true")
parser.add_argument("--packages", required=True)
parser.add_argument("--build-root", type=Path, required=True)
parser.add_argument("--state-root", type=Path, required=True)
parser.add_argument("--project-root", type=Path, required=True)
parser.add_argument("--json", action="store_true")
args = parser.parse_args()
with open(os.environ["MOCK_CALL_LOG"], "a", encoding="utf-8") as handle:
    handle.write("aur-install\t" + "\t".join(sys.argv[1:]) + "\n")
failed = os.environ.get("MOCK_INSTALL_PLAN_FAILED_STATUS")
if not args.install and failed is not None:
    print("mock installed-package query failed", file=sys.stderr)
    raise SystemExit(int(failed))
if not args.install and os.environ.get("MOCK_INSTALL_PLAN_EMPTY") == "1":
    raise SystemExit(0)
recipes = {}
for line in (args.project_root / "manifests/aur-recipes.tsv").read_text().splitlines():
    if line and not line.startswith("#"):
        fields = line.split("\t")
        recipes[fields[0]] = fields
selected = args.packages.split(",")
state_path = args.state_root / "aur-installed.json"

def artifact_for(package):
    row = recipes[package]
    directory = args.build_root / "artifacts" / package / row[8]
    metadata = json.loads((directory / "artifact.json").read_text())
    return {**metadata, "path": str(directory / metadata["filename"]), "recipe_tree_sha256": row[8]}

if args.install:
    assert args.confirm_aur and args.confirm_system_changes
    status = int(os.environ.get("MOCK_INSTALL_STATUS", "0"))
    if status:
        raise SystemExit(status)
    state_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state_path.parent, 0o700)
    state = {"schema": 1, "packages": {}}
    if state_path.is_file() and not state_path.is_symlink():
        state = json.loads(state_path.read_text())
    for package in selected:
        row = recipes[package]
        artifact = artifact_for(package)
        state["packages"][package] = {
            "version": f"{row[4]}-{row[5]}",
            "artifact_sha256": artifact["sha256"],
            "recipe_tree_sha256": row[8],
            "installed_at": "2026-08-01T00:00:00Z",
            "packager": "my-archlinux-setup fixed AUR recipe",
        }
    state_path.write_text(json.dumps(state, sort_keys=True) + "\n")
    os.chmod(state_path, 0o600)
    print("mock artifact install passed")
    raise SystemExit(0)

state = {"schema": 1, "packages": {}}
if state_path.is_file() and not state_path.is_symlink():
    state = json.loads(state_path.read_text())
query_empty = os.environ.get("MOCK_INSTALL_PLAN_QUERY_EMPTY") == "1"
records = []
for package in selected:
    row = recipes[package]
    artifact = artifact_for(package)
    prior = state["packages"].get(package)
    matches = bool(
        prior
        and prior.get("version") == f"{row[4]}-{row[5]}"
        and prior.get("artifact_sha256") == artifact["sha256"]
        and prior.get("recipe_tree_sha256") == row[8]
    )
    if query_empty:
        installed = {"state": "query-failed", "query_exit": 0, "reason": "pacman returned malformed installed metadata"}
        action_name = "unavailable"
    else:
        installed = {"state": "installed", "query_exit": 0, "version": f"{row[4]}-{row[5]}"}
        action_name = "verified-skip" if matches else "reinstall-establish-provenance"
    records.append({
        "package": package,
        "module": row[3],
        "target_version": f"{row[4]}-{row[5]}",
        "artifact": artifact,
        "installed": installed,
        "version_comparison": {"state": "ok", "query_exit": 0, "comparison": 0} if not query_empty else None,
        "action": action_name,
    })
ready = not query_empty and all(row["action"] == "verified-skip" for row in records)
print(json.dumps({
    "schema": 1,
    "selection": {"packages": selected},
    "records": records,
    "effects": [],
    "overall": {
        "status": "ready" if ready else "unavailable",
        "exit_code": 0 if ready else 2,
        "blockers": [],
        "unavailable_checks": [] if ready else [f"{selected[0]}: installed-package query succeeded empty (exit=0)"],
    },
}))
raise SystemExit(0)
PY
chmod 755 "$fixture/installer/"*.py

# PATH contains every immutable/base query dependency, but deliberately omits
# devtools clean-chroot commands until after the all-stage read-only preflight.
for command in makepkg pacman vercmp curl cargo tar zstd bsdtar sudo fuzzel; do
  cat >"$mock_bin/$command" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s' "$(basename -- "$0")" >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
exit 99
MOCK
  chmod 755 "$mock_bin/$command"
done

cat >"$test_root/invoke.py" <<'PY'
#!/usr/bin/python3
import hashlib
import importlib.util
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
adapter = Path(os.environ["ADAPTER_PATH"])
project = Path(os.environ["TEST_PROJECT_ROOT"])
spec = importlib.util.spec_from_file_location("aur_stage_apply_tested", adapter)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.PROJECT_ROOT = project
for constant, relative in {
    "AUR_PLAN_SHA256": "installer/aur-plan.py",
    "AUR_SOURCE_ACQUIRE_SHA256": "installer/aur-source-acquire.py",
    "AUR_BUILD_SHA256": "installer/aur-build.py",
    "AUR_INSTALL_SHA256": "installer/aur-install.py",
}.items():
    setattr(module, constant, hashlib.sha256((project / relative).read_bytes()).hexdigest())
raise SystemExit(module.main())
PY
chmod 755 "$test_root/invoke.py"

selected_modules='daily-apps,repository-tools,build-foundation'
stage_modules='daily-apps,repository-tools'
mapfile -t selection_data < <(/usr/bin/python3 - "$fixture/manifests/workstation-packages.tsv" <<'PY'
import json
import sys
from pathlib import Path

selected_modules = {"daily-apps", "repository-tools", "build-foundation"}
rows = []
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line or line.startswith("#"):
        continue
    fields = line.split("\t")
    if fields[3] in {"aur-build", "paru-bootstrap"} and fields[4] in selected_modules:
        rows.append(fields)
rows.sort(key=lambda row: row[0])
packages = [row[0] for row in rows]
for prefix in ("acquire-source:", "build-install:"):
    effects = [
        {
            "detail": f"package={row[0]} channel={row[1]} repository={row[2]} acquisition={row[3]}",
            "id": prefix + row[0],
            "module": row[4],
        }
        for row in rows
    ]
    print(json.dumps(effects, sort_keys=True, separators=(",", ":")))
print(",".join(packages))
local = []
recipes = {}
for line in (Path(sys.argv[1]).parent / "aur-recipes.tsv").read_text().splitlines():
    if line and not line.startswith("#"):
        fields = line.split("\t")
        recipes[fields[0]] = fields
for package in packages:
    if recipes[package][9] == "local-fixed":
        local.append(package)
print(",".join(local))
PY
)
source_effects=${selection_data[0]}
build_effects=${selection_data[1]}
selected_packages=${selection_data[2]}
local_packages=${selection_data[3]}
[[ -n $selected_packages && -n $local_packages ]] || fail 'fixture selection did not include AUR and local-fixed rows'

RUN_STATUS=0
RUN_OUTPUT=''
run_stage() {
  local output=$1 stage=$2 action=$3 effects=$4
  shift 4
  set +e
  env -i \
    HOME="$home" XDG_CACHE_HOME="$runtime/cache" XDG_STATE_HOME="$runtime/state" \
    PATH="$mock_bin" LC_ALL=C \
    MOCK_CALL_LOG="$call_log" MOCK_SOURCE_DATA="$source_data" \
    ADAPTER_PATH="$adapter" TEST_PROJECT_ROOT="$fixture" \
    FULL_ORCHESTRATOR_ACTION="$action" FULL_ORCHESTRATOR_STAGE="$stage" \
    FULL_ORCHESTRATOR_PROFILE=test FULL_ORCHESTRATOR_MODULES="$selected_modules" \
    FULL_ORCHESTRATOR_STAGE_MODULES="$stage_modules" FULL_ORCHESTRATOR_EFFECTS_JSON="$effects" \
    FULL_ORCHESTRATOR_PLAN_FINGERPRINT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FULL_ORCHESTRATOR_RUN_ID=20260801T000000Z-deadbeef0001 FULL_ORCHESTRATOR_ATTEMPT=1 \
    "$@" /usr/bin/python3 "$test_root/invoke.py" >"$output" 2>&1
  RUN_STATUS=$?
  set -e
  RUN_OUTPUT=$output
}

runtime_digest() {
  /usr/bin/python3 - "$runtime" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path
root=Path(sys.argv[1]); digest=hashlib.sha256()
for path in sorted(root.rglob('*'), key=lambda p: os.fsencode(str(p.relative_to(root)))):
    rel=str(path.relative_to(root)); info=path.lstat()
    digest.update(rel.encode()+b'\0'+f'{stat.S_IFMT(info.st_mode):o}:{stat.S_IMODE(info.st_mode):04o}'.encode()+b'\0')
    if stat.S_ISREG(info.st_mode): digest.update(path.read_bytes())
    elif stat.S_ISLNK(info.st_mode): digest.update(os.readlink(path).encode())
    digest.update(b'\n')
print(digest.hexdigest())
PY
}

# Both all-stage preflights are static/read-only. Missing local sources,
# artifacts, chroot, provenance and selected devtools are expected-pending.
before=$(runtime_digest)
run_stage "$test_root/source-preflight.out" aur-source-acquisition preflight "$source_effects"
((RUN_STATUS == 0)) || { cat "$RUN_OUTPUT" >&2; fail "source preflight exited $RUN_STATUS"; }
run_stage "$test_root/build-preflight.out" aur-build-install preflight "$build_effects"
((RUN_STATUS == 0)) || { cat "$RUN_OUTPUT" >&2; fail "build preflight exited $RUN_STATUS"; }
after=$(runtime_digest)
[[ $after == "$before" ]] || fail 'preflight changed HOME/cache/state files'
[[ ! -e $runtime/cache && ! -e $runtime/state ]] || fail 'preflight created cache/state directories'
[[ $(grep -c $'^aur-plan\t' "$call_log") == 2 ]] || fail 'preflight did not run exactly two static AUR plans'
! grep -Eq $'^(aur-source-acquire|aur-build|aur-install|sudo|fuzzel)\t' "$call_log" || \
  fail 'preflight downloaded, built, installed, or invoked privilege tooling'
! grep -Fq $'\t--verify-sources' "$call_log" || fail 'preflight requested source downloads'

# Global preflights run before the new privilege-wrapper stage executes. A
# genuinely clean HOME may therefore have both installed payloads absent, but
# only while the exact repository payloads retain their production hashes.
clean_home="$runtime/clean-home"
mkdir -m 700 "$clean_home"
clean_before=$(runtime_digest)
run_stage "$test_root/clean-home-source-preflight.out" aur-source-acquisition preflight "$source_effects" \
  HOME="$clean_home"
((RUN_STATUS == 0)) || { cat "$RUN_OUTPUT" >&2; fail "clean-HOME source preflight exited $RUN_STATUS"; }
grep -Fq 'privilege-wrapper=absent' "$RUN_OUTPUT" || fail 'clean-HOME preflight did not classify wrapper as expected-pending'
run_stage "$test_root/clean-home-build-preflight.out" aur-build-install preflight "$build_effects" \
  HOME="$clean_home"
((RUN_STATUS == 0)) || { cat "$RUN_OUTPUT" >&2; fail "clean-HOME build preflight exited $RUN_STATUS"; }
[[ $(runtime_digest) == "$clean_before" ]] || fail 'clean-HOME preflight wrote files/directories'
[[ ! -e $clean_home/scripts ]] || fail 'clean-HOME preflight created privilege-wrapper directories'

before_calls=$(wc -l <"$call_log")
run_stage "$test_root/clean-home-execute.out" aur-source-acquisition execute "$source_effects" \
  HOME="$clean_home"
((RUN_STATUS == 127)) || fail "clean-HOME execute exited $RUN_STATUS instead of 127"
[[ $(wc -l <"$call_log") == "$before_calls" ]] || fail 'clean-HOME execute reached source tooling without wrappers'

cp -- "$fixture/config/home/scripts/desktop/gsudo" "$test_root/project-gsudo.saved"
printf '\n# repository payload drift\n' >>"$fixture/config/home/scripts/desktop/gsudo"
run_stage "$test_root/clean-home-payload-drift.out" aur-source-acquisition preflight "$source_effects" \
  HOME="$clean_home"
((RUN_STATUS == 1)) || fail "clean-HOME repository payload drift exited $RUN_STATUS instead of 1"
cp -- "$test_root/project-gsudo.saved" "$fixture/config/home/scripts/desktop/gsudo"
chmod 755 "$fixture/config/home/scripts/desktop/gsudo"

mkdir -p "$clean_home/scripts/desktop"
chmod 700 "$clean_home/scripts" "$clean_home/scripts/desktop"
cp -- "$fixture/config/home/scripts/desktop/gsudo" "$clean_home/scripts/desktop/gsudo"
chmod 755 "$clean_home/scripts/desktop/gsudo"
run_stage "$test_root/partial-wrapper.out" aur-source-acquisition preflight "$source_effects" HOME="$clean_home"
((RUN_STATUS == 1)) || fail "partially present privilege wrapper exited $RUN_STATUS instead of 1"

mv "$clean_home/scripts/desktop/gsudo" "$test_root/clean-gsudo.saved"
ln -s "$fixture/config/home/scripts/desktop/gsudo" "$clean_home/scripts/desktop/gsudo"
cp -- "$fixture/config/home/scripts/desktop/fuzzel-askpass" "$clean_home/scripts/desktop/fuzzel-askpass"
chmod 755 "$clean_home/scripts/desktop/fuzzel-askpass"
run_stage "$test_root/symlink-wrapper.out" aur-build-install preflight "$build_effects" HOME="$clean_home"
((RUN_STATUS == 1)) || fail "symlinked privilege wrapper exited $RUN_STATUS instead of 1"
unlink "$clean_home/scripts/desktop/gsudo"
mv "$test_root/clean-gsudo.saved" "$clean_home/scripts/desktop/gsudo"
printf '\n# installed helper drift\n' >>"$clean_home/scripts/desktop/fuzzel-askpass"
run_stage "$test_root/helper-drift.out" aur-build-install preflight "$build_effects" HOME="$clean_home"
((RUN_STATUS == 1)) || fail "drifted installed helper exited $RUN_STATUS instead of 1"

# There is no package-selection CLI on the adapter itself.
before_calls=$(wc -l <"$call_log")
set +e
env -i \
  HOME="$home" XDG_CACHE_HOME="$runtime/cache" XDG_STATE_HOME="$runtime/state" \
  PATH="$mock_bin" LC_ALL=C MOCK_CALL_LOG="$call_log" MOCK_SOURCE_DATA="$source_data" \
  ADAPTER_PATH="$adapter" TEST_PROJECT_ROOT="$fixture" \
  FULL_ORCHESTRATOR_ACTION=preflight FULL_ORCHESTRATOR_STAGE=aur-source-acquisition \
  FULL_ORCHESTRATOR_PROFILE=test FULL_ORCHESTRATOR_MODULES="$selected_modules" \
  FULL_ORCHESTRATOR_STAGE_MODULES="$stage_modules" FULL_ORCHESTRATOR_EFFECTS_JSON="$source_effects" \
  FULL_ORCHESTRATOR_PLAN_FINGERPRINT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  FULL_ORCHESTRATOR_RUN_ID=20260801T000000Z-deadbeef0001 FULL_ORCHESTRATOR_ATTEMPT=1 \
  /usr/bin/python3 "$test_root/invoke.py" --packages wooz-git >"$test_root/arbitrary-cli.out" 2>&1
RUN_STATUS=$?
set -e
((RUN_STATUS == 2)) || fail "arbitrary adapter CLI exited $RUN_STATUS instead of 2"
[[ $(wc -l <"$call_log") == "$before_calls" ]] || fail 'rejected arbitrary CLI reached a child tool'

# Effect identity/detail/module/order must be exactly policy-derived.
drift_effects=$(/usr/bin/python3 - "$source_effects" <<'PY'
import json,sys
value=json.loads(sys.argv[1]);value[0]['detail'] += ' drift';print(json.dumps(value,separators=(',',':'),sort_keys=True))
PY
)
run_stage "$test_root/effect-drift.out" aur-source-acquisition preflight "$drift_effects"
((RUN_STATUS == 2)) || fail "effect drift exited $RUN_STATUS instead of 2"

tree_target="$fixture/third_party/aur/${selected_packages%%,*}/PKGBUILD"
cp -- "$tree_target" "$test_root/PKGBUILD.saved"
printf '\n# test drift\n' >>"$tree_target"
run_stage "$test_root/tree-drift.out" aur-source-acquisition preflight "$source_effects"
((RUN_STATUS == 1)) || fail "recipe tree drift exited $RUN_STATUS instead of 1"
cp -- "$test_root/PKGBUILD.saved" "$tree_target"

cp -- "$home/scripts/desktop/gsudo" "$test_root/gsudo.saved"
printf '\n# unaudited drift\n' >>"$home/scripts/desktop/gsudo"
run_stage "$test_root/gsudo-drift.out" aur-build-install preflight "$build_effects"
((RUN_STATUS == 1)) || fail "unaudited gsudo exited $RUN_STATUS instead of 1"
cp -- "$test_root/gsudo.saved" "$home/scripts/desktop/gsudo"
chmod 755 "$home/scripts/desktop/gsudo"
! grep -Eq $'^(sudo|fuzzel)\t' "$call_log" || fail 'wrapper rejection fell back to sudo/fuzzel'

mkdir -m 700 "$test_root/symlink-cache-target"
ln -s "$test_root/symlink-cache-target" "$runtime/symlink-cache"
run_stage "$test_root/symlink-path.out" aur-source-acquisition preflight "$source_effects" \
  XDG_CACHE_HOME="$runtime/symlink-cache"
((RUN_STATUS == 1)) || fail "symlink cache path exited $RUN_STATUS instead of 1"
unlink "$runtime/symlink-cache"

# Source acquisition failures preserve their exact external status and cannot
# leave a successful provenance certificate.
run_stage "$test_root/source-failed.out" aur-source-acquisition execute "$source_effects" MOCK_SOURCE_STATUS=43
((RUN_STATUS == 43)) || fail "source acquisition failure exit was $RUN_STATUS instead of 43"
[[ ! -e $runtime/state/my-archlinux-setup/aur-source-provenance.json ]] || \
  fail 'failed source acquisition wrote provenance'

# Source execute acquires only the selected local-fixed subset, dynamically
# verifies every selected recipe, and writes deterministic private provenance.
run_stage "$test_root/source-execute.out" aur-source-acquisition execute "$source_effects"
((RUN_STATUS == 0)) || { cat "$RUN_OUTPUT" >&2; fail "source execute exited $RUN_STATUS"; }
provenance="$runtime/state/my-archlinux-setup/aur-source-provenance.json"
[[ -f $provenance && ! -L $provenance ]] || fail 'source provenance state is missing or unsafe'
[[ $(stat -c '%a' "$provenance") == 600 && $(stat -c '%h' "$provenance") == 1 ]] || \
  fail 'source provenance is not private mode-600/single-link state'
[[ $(stat -c '%a' "$(dirname -- "$provenance")") == 700 ]] || fail 'source provenance parent is not mode 700'
/usr/bin/python3 - "$provenance" "$fixture" "$selected_packages" <<'PY'
import hashlib,json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text());root=Path(sys.argv[2])
assert state['schema']==1 and state['kind']=='aur-source-verification'
assert [row['package'] for row in state['selection']]==sys.argv[3].split(',')
assert state['recipe_policy_sha256']==hashlib.sha256((root/'manifests/aur-recipes.tsv').read_bytes()).hexdigest()
assert state['source_policy_sha256']==hashlib.sha256((root/'manifests/aur-source-acquisition.tsv').read_bytes()).hexdigest()
assert state['workstation_policy_sha256']==hashlib.sha256((root/'manifests/workstation-packages.tsv').read_bytes()).hexdigest()
raw=Path(sys.argv[1]).read_text().lower()
assert 'https://' not in raw and 'cookie' not in raw and 'signed-url' not in raw
PY

/usr/bin/python3 - "$call_log" "$local_packages" "$selected_packages" "$runtime" "$fixture" <<'PY'
import sys
from pathlib import Path
log=Path(sys.argv[1]).read_text().splitlines(); local=sys.argv[2]; selected=sys.argv[3]
cache=str(Path(sys.argv[4])/'cache/my-archlinux-setup/aur-sources');root=sys.argv[5]
source=[line.split('\t')[1:] for line in log if line.startswith('aur-source-acquire\t')]
verify=[line.split('\t')[1:] for line in log if line.startswith('aur-plan\t') and '--verify-sources' in line]
assert source[-1]==['--apply','--confirm-aur','--packages',local,'--cache-root',cache,'--project-root',root]
assert verify[-1]==['--verify-sources','--packages',selected,'--source-cache',cache,'--project-root',root,'--json']
PY

run_stage "$test_root/source-verify.out" aur-source-acquisition verify "$source_effects"
((RUN_STATUS == 0)) || { cat "$RUN_OUTPUT" >&2; fail "source verify exited $RUN_STATUS"; }
state_identity=$(stat -c '%i:%Y:%s' "$provenance")
state_hash=$(sha256sum "$provenance" | awk '{print $1}')
run_stage "$test_root/source-rerun.out" aur-source-acquisition execute "$source_effects"
((RUN_STATUS == 0)) || { cat "$RUN_OUTPUT" >&2; fail "source rerun exited $RUN_STATUS"; }
[[ $(stat -c '%i:%Y:%s' "$provenance") == "$state_identity" ]] || fail 'idempotent source execute rewrote exact provenance'
[[ $(sha256sum "$provenance" | awk '{print $1}') == "$state_hash" ]] || fail 'idempotent source execute changed provenance'

cp -- "$fixture/manifests/aur-source-acquisition.tsv" "$test_root/source-policy.saved"
/usr/bin/python3 - "$fixture/manifests/aur-source-acquisition.tsv" <<'PY'
from pathlib import Path
p=Path(__import__('sys').argv[1]);lines=p.read_text().splitlines();
for i,line in enumerate(lines):
    if line and not line.startswith('#'):
        fields=line.split('\t');fields[-1]+=' drift';lines[i]='\t'.join(fields);break
p.write_text('\n'.join(lines)+'\n')
PY
run_stage "$test_root/source-policy-drift.out" aur-source-acquisition verify "$source_effects"
((RUN_STATUS == 1)) || fail "source policy/provenance drift exited $RUN_STATUS instead of 1"
cp -- "$test_root/source-policy.saved" "$fixture/manifests/aur-source-acquisition.tsv"

chmod 644 "$provenance"
run_stage "$test_root/state-mode.out" aur-source-acquisition verify "$source_effects"
((RUN_STATUS == 1)) || fail "non-private provenance exited $RUN_STATUS instead of 1"
chmod 600 "$provenance"
mv "$provenance" "$test_root/provenance.saved"
ln -s "$test_root/provenance.saved" "$provenance"
run_stage "$test_root/state-symlink.out" aur-source-acquisition verify "$source_effects"
((RUN_STATUS == 1)) || fail "symlink provenance exited $RUN_STATUS instead of 1"
unlink "$provenance"
mv "$test_root/provenance.saved" "$provenance"

# Official-stage devtools are now considered present for execute/verify.
for command in mkarchroot makechrootpkg arch-nspawn; do
  cp -- "$mock_bin/makepkg" "$mock_bin/$command"
  chmod 755 "$mock_bin/$command"
done

# Build failure is exact and is a hard barrier before install.
before_install=$(grep -c $'^aur-install\t.*\t--install\($\|\t\)' "$call_log" || true)
run_stage "$test_root/build-failed.out" aur-build-install execute "$build_effects" MOCK_BUILD_STATUS=47
((RUN_STATUS == 47)) || fail "build failure exit was $RUN_STATUS instead of 47"
after_install=$(grep -c $'^aur-install\t.*\t--install\($\|\t\)' "$call_log" || true)
((after_install == before_install)) || fail 'artifact install ran after build failure'

# A successful build followed by a failed install preserves the install status.
run_stage "$test_root/install-failed.out" aur-build-install execute "$build_effects" MOCK_INSTALL_STATUS=53
((RUN_STATUS == 53)) || fail "install failure exit was $RUN_STATUS instead of 53"
run_stage "$test_root/build-install.out" aur-build-install execute "$build_effects"
((RUN_STATUS == 0)) || { cat "$RUN_OUTPUT" >&2; fail "build/install execute exited $RUN_STATUS"; }
install_state="$runtime/state/my-archlinux-setup/aur-installed.json"
[[ -f $install_state && ! -L $install_state && $(stat -c '%a' "$install_state") == 600 ]] || \
  fail 'install provenance is missing, symlinked, or not mode 600'

# Conflicting/incomplete chroot and non-private artifact metadata fail closed.
first_package=${selected_packages%%,*}
first_tree=$(awk -F '\t' -v package="$first_package" '$1==package {print $9; exit}' \
  "$fixture/manifests/aur-recipes.tsv")
artifact_metadata="$runtime/state/my-archlinux-setup/builds/aur/artifacts/$first_package/$first_tree/artifact.json"
chmod 644 "$artifact_metadata"
run_stage "$test_root/artifact-mode.out" aur-build-install verify "$build_effects"
((RUN_STATUS == 1)) || fail "non-private artifact metadata exited $RUN_STATUS instead of 1"
chmod 600 "$artifact_metadata"
chroot_marker="$runtime/state/my-archlinux-setup/builds/aur/chroot/root/usr/bin/rustc"
mv "$chroot_marker" "$test_root/rustc.saved"
run_stage "$test_root/chroot-incomplete.out" aur-build-install preflight "$build_effects"
((RUN_STATUS == 1)) || fail "incomplete chroot exited $RUN_STATUS instead of 1"
mv "$test_root/rustc.saved" "$chroot_marker"

# Verify accepts only fully verified artifact plans and all verified-skip records.
run_stage "$test_root/build-verify.out" aur-build-install verify "$build_effects"
((RUN_STATUS == 0)) || { cat "$RUN_OUTPUT" >&2; fail "build/install verify exited $RUN_STATUS"; }

# A failed child query and a successful-but-empty/malformed query are both
# unavailable, but remain observably distinct and never become a healthy skip.
run_stage "$test_root/query-failed.out" aur-build-install verify "$build_effects" \
  MOCK_INSTALL_PLAN_FAILED_STATUS=37
((RUN_STATUS == 37)) || fail "failed install query exit was $RUN_STATUS instead of 37"
grep -Fq 'failed with exit 37' "$RUN_OUTPUT" || fail 'failed query was not reported as failed'
run_stage "$test_root/query-empty.out" aur-build-install verify "$build_effects" \
  MOCK_INSTALL_PLAN_QUERY_EMPTY=1
((RUN_STATUS == 2)) || fail "empty install query exit was $RUN_STATUS instead of 2"
grep -Eiq 'succeeded empty|malformed.*exit.?0|query.*exit.?0' "$RUN_OUTPUT" || \
  fail 'successful-but-empty query was not reported distinctly'

# Exact build/install argv include the whole fixed selection and both gates.
/usr/bin/python3 - "$call_log" "$selected_packages" "$runtime" "$fixture" <<'PY'
import sys
from pathlib import Path
lines=Path(sys.argv[1]).read_text().splitlines();selected=sys.argv[2];runtime=Path(sys.argv[3]);root=sys.argv[4]
source_cache=str(runtime/'cache/my-archlinux-setup/aur-sources')
build_root=str(runtime/'state/my-archlinux-setup/builds/aur')
state_root=str(runtime/'state/my-archlinux-setup')
build=[line.split('\t')[1:] for line in lines if line.startswith('aur-build\t') and '\t--build\t' in line]
install=[line.split('\t')[1:] for line in lines if line.startswith('aur-install\t') and '\t--install\t' in line]
assert build and build[-1]==[
    '--build','--post-official','--confirm-aur','--confirm-system-changes','--packages',selected,
    '--source-cache',source_cache,'--build-root',build_root,'--state-root',state_root,'--project-root',root,
]
assert install and install[-1]==[
    '--install','--confirm-aur','--confirm-system-changes','--packages',selected,
    '--build-root',build_root,'--state-root',state_root,'--project-root',root,
]
PY

! grep -Eq $'^(sudo|fuzzel)\t' "$call_log" || fail 'adapter fell back to sudo/fuzzel'
/usr/bin/python3 - "$adapter" <<'PY'
import ast
import sys
from pathlib import Path

tree = ast.parse(Path(sys.argv[1]).read_text())
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    if isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name):
        assert not (node.func.value.id == 'os' and node.func.attr == 'system')
        if node.func.value.id == 'subprocess':
            assert node.func.attr == 'run'
            assert node.args and isinstance(node.args[0], ast.Call)
            assert isinstance(node.args[0].func, ast.Name) and node.args[0].func.id == 'list'
            assert all(keyword.arg != 'shell' for keyword in node.keywords)
PY

printf '%s\n' \
  'AUR stage adapter checks passed (exact effects/argv, clean-HOME zero-write preflight, provenance, failures, private paths, no sudo fallback).'
