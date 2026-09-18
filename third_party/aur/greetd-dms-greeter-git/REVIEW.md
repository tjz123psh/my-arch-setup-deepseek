# greetd-dms-greeter-git review

> **2026-09-19 复核**：本文顶部的 AUR commit / 版本号为首次审查时的快照，可能落后于当前 pin；
> 权威值以同目录 `AUR_COMMIT`、`PKGBUILD` 与文末 Update 段为准。

- AUR origin: `https://aur.archlinux.org/greetd-dms-greeter-git.git`
- AUR commit pinned: `41ff38b24c9d74067c8841615c503c7dc54ba76f`
- Upstream: `https://github.com/AvengeMedia/dank-greeter` (MIT)
- Installed on the operator's ASUS host as
  `1:0.0.0.r9.gd73d3c0-1` (greetd 0.10.3-2, quickshell 0.3.0-2) and used as
  the login greeter for the niri session.
- Depends: greetd, quickshell, qt6-declarative; git source (rolling).
- The greeter runs as the `greeter` user; the host greetd config starts
  `dms-greeter --command niri --cache-dir /var/cache/dms-greeter -C /etc/greetd/niri/config.kdl`.

## Update 2026-09-17: re-pin to upstream master (AUR commit 63109962d1b2d17a3b10da4aaca1cbc689f50a6c)

- dank-greeter pin f353eafd... -> 0175be5c2084e2c5027324403a329e04040cd0bc
  (git describe --long --tags = v1.6.2-0-g0175be5, hence pkgver=1.6.2.r0.g0175be5).
- dank-qml-common submodule pin 28fde731... -> 26396ce432d6c71c3f5367438f96f4a8d667e160
  (submodule SHA recorded by the dank-greeter tree at that commit).
- Local conventions kept: reproducible commit pins instead of the floating git+ source, local sysusers +
  tmpfiles units, real go test (failure fails the build), GOMODCACHE left to the installer's offline cache.
- The AUR recipe still floats on master; the pins above are the reviewed snapshot for this update.
