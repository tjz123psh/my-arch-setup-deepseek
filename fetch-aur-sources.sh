#!/usr/bin/env bash
# fetch-aur-sources.sh - build the offline AUR source cache for
# my-arch-setup-deepseek. Run on a machine WITH overseas access; the result
# goes to ~/Downloads/aur-sources (makepkg SRCDEST layout). A physical
# machine with no overseas access copies this (as aur-sources.tar.gz) into
# the repo as .aur-sources/ and 06-aur builds every AUR recipe fully offline.
#
# Caches three kinds of inputs:
#   1. PKGBUILD `source` files (git bare mirrors + downloaded files)
#   2. Go module cache (greetd-dms-greeter builds via `go build`)
#   3. cargo registry cache (paru builds via `cargo build --frozen`)
set -uo pipefail

DEST="${1:-$HOME/Downloads/aur-sources}"
mkdir -p "$DEST"
FAILED=0

dl() { # name url
  local name="$1" url="$2"
  if [[ -s "$DEST/$name" ]]; then echo "SKIP  $name"; return; fi
  if curl -fL -sS --connect-timeout 20 --max-time 1800 -o "$DEST/$name.part" "$url" 2>/tmp/aur-dl.err; then
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
# flclash-bin
dl flclash-0.8.94-x86_64.deb "https://github.com/chen08209/FlClash/releases/download/v0.8.94/FlClash-0.8.94-linux-amd64.deb"
dl libquickjs_c_bridge_plugin.so.base64 "https://gist.githubusercontent.com/dongfengweixiao/bbddee34d6456326200fac3463761296/raw/c18484d78449d0e3b376a6e2a49852486305ff1e/libquickjs_c_bridge_plugin.so.base64"
# google-chrome
dl google-chrome-stable_151.0.7922.71-1_amd64.deb "https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_151.0.7922.71-1_amd64.deb"
# leaf-markdown-viewer-bin
dl leaf-1.26.2-x86_64.bin "https://github.com/RivoLink/leaf/releases/download/1.26.2/leaf-linux-x86_64"
dl LICENSE-MIT.txt       "https://raw.githubusercontent.com/RivoLink/leaf/0c037dba12e2396f798878654b11b668f3b07929/LICENSE"
dl CHANGELOG-1.26.2.md    "https://raw.githubusercontent.com/RivoLink/leaf/0c037dba12e2396f798878654b11b668f3b07929/CHANGELOG.md"
dl CONTRIBUTING-1.26.2.md "https://raw.githubusercontent.com/RivoLink/leaf/0c037dba12e2396f798878654b11b668f3b07929/CONTRIBUTING.md"
dl README-1.26.2.md       "https://raw.githubusercontent.com/RivoLink/leaf/0c037dba12e2396f798878654b11b668f3b07929/README.md"
dl SECURITY-1.26.2.md     "https://raw.githubusercontent.com/RivoLink/leaf/0c037dba12e2396f798878654b11b668f3b07929/SECURITY.md"
dl TESTING-1.26.2.md      "https://raw.githubusercontent.com/RivoLink/leaf/0c037dba12e2396f798878654b11b668f3b07929/TESTING.md"
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
# clash-verge-rev-bin
dl clash-verge-rev-2.5.2-x86_64.deb "https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v2.5.2/Clash.Verge_2.5.2_amd64.deb"

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
