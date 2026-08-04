#!/usr/bin/env bash
# strap.sh - one-command Arch workstation restore (shorin-style entry).
#
# Usage (from a tty on a freshly-installed Arch system):
#   bash strap.sh
# or one-shot:
#   curl -L https://example.invalid/strap.sh | bash    # after publishing
#
# The script must run as root (like shorin's installer): it drives the whole
# restore without interactive password prompts. It self-clones the repository
# into /opt/my-arch-setup if missing, then delegates to install.sh.

set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/tjz123psh/my-arch-setup-deepseek.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/my-arch-setup}"
BRANCH="${BRANCH:-main}"

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "strap.sh must run as root (e.g. 'sudo bash strap.sh')." >&2
    exit 1
  fi

  command -v git >/dev/null 2>&1 || { echo "git not found; install it first (pacman -S git)." >&2; exit 1; }

  if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    echo "==> Cloning setup repository into ${INSTALL_DIR} ..."
    git clone --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
  else
    echo "==> Repository present; pulling latest ${BRANCH} ..."
    git -C "${INSTALL_DIR}" pull --ff-only
  fi

  exec bash "${INSTALL_DIR}/install.sh" "$@"
}

main "$@"
