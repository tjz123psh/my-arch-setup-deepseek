#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
payload="$root/config/home/.config/nvim"

python - "$root" <<'PY'
from pathlib import Path
import json
import sys

root = Path(sys.argv[1])
payload = root / "config/home/.config/nvim"
if not payload.is_dir():
    raise SystemExit("Neovim mapped payload is missing")

files = {
    path.relative_to(payload).as_posix()
    for path in payload.rglob("*")
    if path.is_file()
}
if len(files) != 42:
    raise SystemExit(f"expected 42 reviewed Neovim files, found {len(files)}")

required = {".gitignore", "init.lua", "lazy-lock.json", "stylua.toml"}
missing_required = sorted(required - files)
if missing_required:
    raise SystemExit(f"missing required Neovim metadata: {', '.join(missing_required)}")

excluded = {"colors/dms.lua", "lua/lualine/themes/dms.lua"}
present_excluded = sorted(excluded & files)
if present_excluded:
    raise SystemExit(f"excluded DMS Neovim integration is present: {', '.join(present_excluded)}")

mapping_sources = {
    raw.split("\t")[2]
    for raw in (root / "manifests/config-mappings.tsv").read_text().splitlines()
    if raw and not raw.startswith("#")
}
expected_sources = {
    f"config/home/.config/nvim/{relative}"
    for relative in files
}
missing_mappings = sorted(expected_sources - mapping_sources)
if missing_mappings:
    raise SystemExit(f"unmapped Neovim payload: {', '.join(missing_mappings)}")

all_text = "\n".join(
    path.read_text()
    for path in sorted(payload.rglob("*"))
    if path.is_file()
)
for forbidden in ("~/.config/nvim", "cwd=~/md", "/home/"):
    if forbidden in all_text:
        raise SystemExit(f"personal path remains in Neovim payload: {forbidden}")

keymaps = (payload / "lua/core/keymaps.lua").read_text()
dashboard = (payload / "lua/plugins/dashboard.lua").read_text()
for relative, text in (("lua/core/keymaps.lua", keymaps), ("lua/plugins/dashboard.lua", dashboard)):
    if 'vim.fn.stdpath("config")' not in text:
        raise SystemExit(f"portable Neovim config path is missing from {relative}")

telescope = (payload / "lua/plugins/telescope.lua").read_text()
cheatsheet = (payload / "lua/core/cheatsheet.lua").read_text()
commands = (payload / "lua/core/commands.lua").read_text()
if "<leader>fd" in telescope or "<leader>fd" in cheatsheet:
    raise SystemExit("personal documentation keymap remains in Neovim payload")
if "JavaInit" in all_text:
    raise SystemExit("machine-specific JavaInit command/reference remains in Neovim payload")
for executable in ("java", "javac", "bash"):
    marker = f'vim.fn.executable("{executable}")'
    if marker not in commands:
        raise SystemExit(f"JavaRun lacks an executable guard for {executable}")

json.loads((payload / "lazy-lock.json").read_text())
PY

if command -v nvim >/dev/null 2>&1; then
  PAYLOAD="$payload" nvim --clean --headless -u NONE \
    -c 'lua for _, path in ipairs(vim.fn.glob(vim.env.PAYLOAD .. "/**/*.lua", true, true)) do assert(loadfile(path)) end' \
    -c 'quitall' >/dev/null
else
  printf 'Neovim Lua syntax check unavailable: nvim was not found.\n' >&2
  exit 2
fi

printf 'Neovim configuration checks passed.\n'
