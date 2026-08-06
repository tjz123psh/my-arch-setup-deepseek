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

# The default REPO_URL points at a private GitHub repo; an unauthenticated
# https clone is refused. Give the operator actionable ways out (and stay
# useful for a plain network failure too).
hint_clone_failed() {
  cat >&2 <<'EOF'

The clone/update failed. If this is the private my-arch-setup repo, GitHub
refuses an unauthenticated https clone. Fix one of these and re-run:

  1) Authenticate git as the user who will run install.sh afterwards:
       gh auth login
     (or configure a credential helper / PAT for https://github.com)

  2) Point REPO_URL at a reachable clone URL, e.g. the SSH form:
       sudo REPO_URL=git@github.com:tjz123psh/my-arch-setup-deepseek.git \
            bash strap.sh

  3) Skip strap.sh entirely: copy the repo onto the machine another way
     (host HTTP share / tar) and run its install.sh directly.
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
