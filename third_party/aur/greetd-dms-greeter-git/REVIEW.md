# greetd-dms-greeter-git review

- AUR origin: `https://aur.archlinux.org/greetd-dms-greeter-git.git`
- AUR commit pinned: `41ff38b24c9d74067c8841615c503c7dc54ba76f`
- Upstream: `https://github.com/AvengeMedia/dank-greeter` (MIT)
- Installed on the operator's ASUS host as
  `1:0.0.0.r9.gd73d3c0-1` (greetd 0.10.3-2, quickshell 0.3.0-2) and used as
  the login greeter for the niri session.
- Depends: greetd, quickshell, qt6-declarative; git source (rolling).
- The greeter runs as the `greeter` user; the host greetd config starts
  `dms-greeter --command niri --cache-dir /var/cache/dms-greeter -C /etc/greetd/niri/config.kdl`.
