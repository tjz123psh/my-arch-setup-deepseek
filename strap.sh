#!/usr/bin/env bash
# strap.sh - one-command Arch workstation restore (shorin-style entry).
#
# Usage (from a tty on a freshly-installed Arch system):
#   sudo bash strap.sh
#
# The script must run as root (like shorin's installer): it drives the whole
# restore without interactive password prompts. It self-clones the repository
# into /opt/my-arch-setup if missing, then delegates to install.sh.
# The clone is the audited path (no curl|bash of remote content).

set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/tjz123psh/my-arch-setup-deepseek.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/my-arch-setup}"
BRANCH="${BRANCH:-main}"

die() { echo "strap.sh: $*" >&2; exit 1; }

# The default REPO_URL points at a public GitHub repo, so an unauthenticated
# https clone works wherever GitHub is reachable. If the clone still fails,
# it is a network problem (typically no overseas access on the target
# machine); the hint below offers the offline USB path.
hint_clone_failed() {
  cat >&2 <<'EOF'

The clone/update failed. The repo is public, so this is almost always a
network issue (no route to GitHub, e.g. a CN-only network). Options:

  1) Check connectivity first:
       curl -m 10 -sI https://github.com
     (on a CN-only network, use a proxy or the offline path below)

  2) Offline path (no overseas access): copy the repo onto the machine via
     USB and run its install.sh directly. Pre-download the AUR cache too -
     see docs/physical-offline-install.md for the full procedure.

  3) Point REPO_URL at a reachable clone URL if you have a mirror:
       sudo REPO_URL=<reachable clone URL> bash strap.sh
EOF
}

clone_or_update() {
  if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    echo "==> Cloning setup repository into ${INSTALL_DIR} ..."
    if ! git clone --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}" 2>/tmp/strap-git.err; then
      echo "==> ERROR: could not clone ${REPO_URL}" >&2
      sed 's/^/    /' /tmp/strap-git.err >&2 2>/dev/null || true
      hint_clone_failed
      exit 1
    fi
  else
    echo "==> Repository present; pulling latest ${BRANCH} ..."
    if ! git -C "${INSTALL_DIR}" pull --ff-only 2>/tmp/strap-git.err; then
      echo "==> ERROR: could not update ${INSTALL_DIR}" >&2
      sed 's/^/    /' /tmp/strap-git.err >&2 2>/dev/null || true
      hint_clone_failed
      exit 1
    fi
  fi
}

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "must run as root (e.g. 'sudo bash strap.sh')"
  fi
  command -v git >/dev/null 2>&1 || die "git not found; install it first (pacman -S git)."
  clone_or_update
  exec bash "${INSTALL_DIR}/install.sh" "$@"
}

main "$@"
