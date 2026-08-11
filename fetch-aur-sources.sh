#!/usr/bin/env bash
# fetch-aur-sources.sh - build the offline AUR source cache for
# my-arch-setup-deepseek. Run on a machine WITH overseas access; the result
# goes to ~/Downloads/aur-sources (makepkg SRCDEST layout). A physical
# machine with no overseas access copies this (as aur-sources-physical.tar.gz
# or aur-sources-vm.tar.gz) into the repo as .aur-sources/ and 06-aur builds
# every AUR recipe fully offline.
#
# Two cache profiles (machine type), because vmware-workstation's vendor
# payloads (~1G of ISOs) are physical-only:
#   ./fetch-aur-sources.sh physical [dest]   # full: incl. vmware-workstation + keymaps
#   ./fetch-aur-sources.sh vm [dest]         # slim: no vmware-workstation/keymaps
# Package each into its own tar.gz and attach both to the GitHub Release
# (aur-sources-physical.tar.gz / aur-sources-vm.tar.gz); the target machine
# extracts only the one matching its machine type.
#
# Caches three kinds of inputs:
#   1. PKGBUILD `source` files (git bare mirrors + downloaded files)
#   2. Go module cache (greetd-dms-greeter builds via `go build`)
#   3. cargo registry cache (paru builds via `cargo build --frozen`)
set -uo pipefail

PROFILE="${1:-physical}"
case "${PROFILE}" in
  physical|vm) ;;
  *) echo "unknown profile: ${PROFILE} (physical|vm)" >&2; exit 1 ;;
esac
DEST="${2:-$HOME/Downloads/aur-sources}"
mkdir -p "$DEST"
FAILED=0

dl() { # name url [sha256]
  local name="$1" url="$2" want="${3:-}"
  if [[ -s "$DEST/$name" ]]; then echo "SKIP  $name"; return; fi
  if curl -fL -sS --connect-timeout 20 --max-time 1800 -o "$DEST/$name.part" "$url" 2>/tmp/aur-dl.err; then
    if [[ -n "$want" ]]; then
      local got
      got="$(sha256sum "$DEST/$name.part" | cut -d' ' -f1)"
      if [[ "$got" != "$want" ]]; then
        echo "FAIL  $name :: sha256 mismatch (got $got, want $want)"
        rm -f "$DEST/$name.part"
        FAILED=$((FAILED + 1))
        return
      fi
    fi
    mv "$DEST/$name.part" "$DEST/$name"
    echo "OK    $name ($(du -h "$DEST/$name" | cut -f1))"
  else
    echo "FAIL  $name :: $(tail -1 /tmp/aur-dl.err)"
    rm -f "$DEST/$name.part"
    FAILED=$((FAILED + 1))
  fi
}

gitm() { # name url
  local name="$1" url="$2"
  if [[ -d "$DEST/$name" ]]; then echo "SKIP  git:$name"; return; fi
  if git clone --mirror --quiet "$url" "$DEST/$name" 2>/tmp/aur-git.err; then
    echo "OK    git:$name"
  else
    echo "FAIL  git:$name :: $(tail -1 /tmp/aur-git.err)"
    rm -rf "$DEST/$name"
    FAILED=$((FAILED + 1))
  fi
}

echo "== git sources (SRCDEST bare mirrors) =="
gitm fuzzel          https://codeberg.org/dnkl/fuzzel.git
gitm dank-greeter    https://github.com/AvengeMedia/dank-greeter.git
gitm dank-qml-common https://github.com/AvengeMedia/dank-qml-common.git

echo "== URL sources =="
# dsearch-bin
dl LICENSE-0.3.2        "https://raw.githubusercontent.com/AvengeMedia/danksearch/1269b4688cc94cbd271e1cbbf19a6e7caa2293de/LICENSE"
dl README-0.3.2.md      "https://raw.githubusercontent.com/AvengeMedia/danksearch/1269b4688cc94cbd271e1cbbf19a6e7caa2293de/README.md"
dl dsearch-x86_64-0.3.2.gz "https://github.com/AvengeMedia/danksearch/releases/download/v0.3.2/dsearch-linux-amd64.gz"
# fcitx5-skin-fluentdark-git
dl Fluent-fcitx5-399699ac7d366ed6c1952646ed71647e3c8f99b5.tar.gz "https://github.com/Reverier-Xu/Fluent-fcitx5/archive/399699ac7d366ed6c1952646ed71647e3c8f99b5.tar.gz"
# google-chrome
dl google-chrome-stable_151.0.7922.71-1_amd64.deb "https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_151.0.7922.71-1_amd64.deb"
# linuxqq-appimage (CN CDN)
dl Linuxqq-3.2.32_20260730-x86_64.AppImage "https://qqdl.gtimg.cn/qqfile/QQNT/9.9.33/release/c97651b2/QQ_3.2.32_260730_x86_64_01.AppImage"
# obsidian-bin
dl obsidian_1.12.7_amd64.deb "https://github.com/obsidianmd/obsidian-releases/releases/download/v1.12.7/obsidian_1.12.7_amd64.deb"
# opencode-bin
dl opencode-bin_1.18.10_x86_64.tar.gz "https://github.com/anomalyco/opencode/releases/download/v1.18.10/opencode-linux-x64.tar.gz"
# paru
dl paru-2.1.0.tar.gz "https://github.com/Morganamilo/paru/archive/v2.1.0.tar.gz"
# wechat-appimage (CN CDN)
dl WechatLinux-1783692407-x86_64.AppImage "https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.AppImage"
# wooz-git
dl wooz-24e2856bf2cc13810f00971ae143973840555321.tar.gz "https://github.com/negrel/wooz/archive/24e2856bf2cc13810f00971ae143973840555321.tar.gz"

if [[ "${PROFILE}" == "physical" ]]; then
  echo "== VMware sources (vmware-workstation bundle + tools ISOs) =="
  # vmware-workstation 26H1-3 (AUR): the large vendor payloads (Workstation
  # bundle + guest-tools ISOs) are fetched at build time from archive.org and
  # packages-prod.broadcom.com. They are cached here WITH sha256 verification
  # (the checksums below come from the pinned PKGBUILD); the recipe-local files
  # (services, patches, bootstrap scripts, dkms.conf.in, ...) ship in the repo
  # and are NOT cached. Licensing: Workstation is a Broadcom/VMware product with
  # a personal-use EULA; the cache stays out of git (distributed via Releases,
  # never committed).
  dl_vmware() { # name url sha256
    local name="$1" url="$2" expect="$3" got
    if [[ -s "$DEST/$name" ]]; then
      got="$(sha256sum "$DEST/$name" | cut -d' ' -f1)"
      if [[ "$got" == "$expect" ]]; then echo "SKIP  $name (verified)"; return; fi
      echo "WARN  $name checksum mismatch; re-downloading"
      rm -f "$DEST/$name"
    fi
    if curl -fL -sS --connect-timeout 20 --max-time 7200 -o "$DEST/$name.part" "$url" 2>/tmp/aur-dl.err; then
      got="$(sha256sum "$DEST/$name.part" | cut -d' ' -f1)"
      if [[ "$got" == "$expect" ]]; then
        mv "$DEST/$name.part" "$DEST/$name"
        echo "OK    $name (verified, $(du -h "$DEST/$name" | cut -f1))"
      else
        echo "FAIL  $name checksum mismatch (got $got)"
        rm -f "$DEST/$name.part"; FAILED=$((FAILED + 1))
      fi
    else
      echo "FAIL  $name :: $(tail -1 /tmp/aur-dl.err)"
      rm -f "$DEST/$name.part"; FAILED=$((FAILED + 1))
    fi
  }
  # 1 bundle + 8 guest-tools ISOs (sha256 from third_party/aur/vmware-workstation/PKGBUILD)
  dl_vmware "VMware-Workstation-Full-26H1-25388281.x86_64.bundle" \
    "https://archive.org/download/VMware-Workstation-Full-26H1-25388281.x86_64/VMware-Workstation-Full-26H1-25388281.x86_64.bundle" \
    "3f6d2501e654dbc7701a8290ff6ffcfba6c5444cd5f35f4933cd08c9499f6d84"
  dl_vmware "linux.iso" "https://packages-prod.broadcom.com/tools/frozen/linux/linux.iso" \
    "4e66b286b743d9cf788c487295b1dec3c6071d657674f650aadc23e8900758ff"
  dl_vmware "linuxPreGlibc25.iso" "https://packages-prod.broadcom.com/tools/frozen/linux/linuxPreGlibc25.iso" \
    "aef8f747bd9a6e84d139c57b8c1f8e87c83a9b9df69cd09602030190fec21973"
  dl_vmware "netware.iso" "https://packages-prod.broadcom.com/tools/frozen/netware/netware.iso" \
    "2c89993d811f5d90f7b0e2a286e9339907055e51ecb16f25509e5c4517326487"
  dl_vmware "solaris.iso" "https://packages-prod.broadcom.com/tools/frozen/solaris/solaris.iso" \
    "4666b0adfec6636ecda60bfab889cbf28f06f77526442628a70789fd76823e70"
  dl_vmware "winPre2k.iso" "https://packages-prod.broadcom.com/tools/frozen/windows/winPre2k.iso" \
    "a17a11d65f841d213ffc2d6681acdf849c380e77055334c7a8127c1373991ebb"
  dl_vmware "winPreVista.iso" "https://packages-prod.broadcom.com/tools/frozen/windows/winPreVista.iso" \
    "aab73d3ef4668beec725541c08c41042bb22fc86cd5563310fc170b952631d8a"
  dl_vmware "winVistaSP1.iso" "https://packages-prod.broadcom.com/tools/frozen/windows/WindowsToolsVista/SP1/windows.iso" \
    "3b8f9d6e43f5d1dff0576cb93d008c14e0434d7233872f6c63988513d2bda5d1"
  dl_vmware "winVistaSP2.iso" "https://packages-prod.broadcom.com/tools/frozen/windows/WindowsToolsVista/SP2/windows.iso" \
    "8f1cc3181055891b98672f715e0ca7bbe4018960eae945d7a4b9f640c44c3d79"
  # vmware-keymaps (AUR dependency of vmware-workstation; small GitHub tarball).
  # The download NAME must equal the PKGBUILD source alias
  # (vmware-keymaps-1.0-3.tar.gz, pkgver=1.0 pkgrel=3) or makepkg cannot find
  # it in SRCDEST offline (review P1-7). The sha256 is pinned from the
  # PKGBUILD sha256sums so a supply-chain change fails the fetch.
  dl vmware-keymaps-1.0-3.tar.gz "https://github.com/chowbok/vmware-keymaps/archive/refs/tags/v1.0.tar.gz" \
     "e8ee0df9e35c4a28ab46bc9f9cefc6e2934fe382b93f115bd2e61a2b74490649"
else
  echo "== profile=${PROFILE}: skipping VMware sources (vmware-workstation/keymaps are physical-only) =="
fi

echo
echo "== Go module cache (greetd-dms-greeter) =="
if command -v go >/dev/null 2>&1; then
  if [[ ! -d "$DEST/go-mod" ]] || [[ -z "$(ls -A "$DEST/go-mod" 2>/dev/null)" ]]; then
    rm -rf /tmp/aur-dg-wc
    git clone -q --no-checkout "$DEST/dank-greeter" /tmp/aur-dg-wc 2>/dev/null
    git -C /tmp/aur-dg-wc checkout -q "$(git --git-dir="$DEST/dank-greeter" rev-parse HEAD)" 2>/dev/null
    ( cd /tmp/aur-dg-wc/core && GOMODCACHE="$DEST/go-mod" GOPROXY=https://proxy.golang.org go mod download ) \
      && echo "OK    go-mod ($(du -sh "$DEST/go-mod" | cut -f1))" || { echo "FAIL  go-mod"; FAILED=$((FAILED + 1)); }
    rm -rf /tmp/aur-dg-wc
  else
    echo "SKIP  go-mod"
  fi
else
  echo "NOTE  go not installed; skip Go module cache (greetd-dms-greeter will need network)"
fi

echo
echo "== cargo registry cache (paru) =="
# NOTE: paru's recipe carries a committed Cargo.lock (alpm pinned to 4.0.4 /
# alpm-sys 4.0.5) so the offline build never runs `cargo update`. Keep this
# lock in sync with the cache: after the update below, copy the generated
# Cargo.lock from the paru source dir into third_party/aur/paru/Cargo.lock.
if command -v cargo >/dev/null 2>&1; then
  if [[ ! -d "$DEST/cargo" ]] || [[ -z "$(ls -A "$DEST/cargo" 2>/dev/null)" ]]; then
    rm -rf /tmp/aur-paru-src
    mkdir -p /tmp/aur-paru-src
    tar -xf "$DEST/paru-2.1.0.tar.gz" -C /tmp/aur-paru-src
    ( cd /tmp/aur-paru-src/paru-2.1.0 \
        && CARGO_HOME="$DEST/cargo" cargo update alpm alpm-utils \
        && CARGO_HOME="$DEST/cargo" cargo fetch --locked --target "$(rustc -vV | sed -n 's|host: ||p')" ) \
      && echo "OK    cargo ($(du -sh "$DEST/cargo" | cut -f1))" || { echo "FAIL  cargo"; FAILED=$((FAILED + 1)); }
    rm -rf /tmp/aur-paru-src
  else
    echo "SKIP  cargo"
  fi
else
  echo "NOTE  cargo not installed; skip cargo cache (paru will need network)"
fi

echo
if (( FAILED > 0 )); then echo "== DONE: $FAILED FAILED (see above) =="; exit 1; fi
echo "== ALL OK =="
du -sh "$DEST"
