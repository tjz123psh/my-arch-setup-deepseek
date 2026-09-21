# WiFi 热点修复记录：三个独立故障

> 日期：2026-09-21
> 现象：DankMaterialShell 面板开热点，一直转圈加载；后来能连上但网页打不开。
> 结果：已修复。热点可在 4–5 秒内启动，客户端正常上网。
> 环境：Arch Linux + niri（Wayland）+ quickshell DMS + NetworkManager 1.58.1 + Docker。

## 背景

本机热点由 DMS（DankMaterialShell）面板控制，底层用 NetworkManager 的
**共享连接（`ipv4.method=shared`）** 实现：

```
连接名：DankMaterialShell Hotspot
UUID  ：52503688-1bd1-4d63-8ce9-d78405890a36
网卡  ：wlp3s0（Realtek RTL8852BE，驱动 rtw89_8852be）
模式  ：ap（AP 模式）
```

排查发现**三个互不相关的故障叠加**，各自修完才完全可用：

| # | 故障 | 症状 | 根因 |
|---|---|---|---|
| 1 | 缺 `dnsmasq` | 完全起不来，一直转圈 | 共享连接需要它发 DHCP/DNS |
| 2 | Docker 转发拦截 | 能连上、有 IP，但打不开网页 | Docker 把 `FORWARD` 策略设为 DROP |
| 3 | 缺 `wireless-regdb` | 随机启动失败（5GHz 时好时坏） | 内核停留在"世界域"，5GHz 禁止主动发射 |

---

## 故障 1：缺 `dnsmasq`，热点完全起不来

### 现象

面板一直转圈加载，约 29 秒后失败。热点配置本身完全正常。

### 根因

`ipv4.method=shared` 要求 NetworkManager 用 **dnsmasq** 同时充当 DHCP 服务器和
DNS 转发器。系统没装它，热点走到分配 IP 那步就立刻失败。

`journalctl -u NetworkManager` 关键行：

```
ip:shared4: could not start dnsmasq: 无法找到 "dnsmasq" 二进制文件
state change: ip-config -> failed (reason 'ip-config-unavailable')
```

这个报错看起来像"获取 IP 失败"，容易误判为信道或驱动问题。

### 解决

```bash
sudo pacman -S --needed dnsmasq
```

装完**无需重启 NetworkManager**，直接开热点即成功。

> 注意：`dnsmasq.service` 必须保持 disabled/inactive。dnsmasq 由 NetworkManager
> 按需自行拉起；若手动 `systemctl enable --now dnsmasq`，它会抢占 53/67 端口，
> 热点反而会坏。

### 验证

```bash
nmcli -t -f NAME,DEVICE,STATE connection show --active | grep -i hotspot
ip -4 addr show wlp3s0 | grep 'inet '        # 应为 10.42.0.1/24
pgrep -a dnsmasq                              # 应带 --dhcp-range=10.42.0.10,10.42.0.254
ss -lunp | grep -E ':(53|67)\s'               # 监听 10.42.0.1:53 与 0.0.0.0:67
```

---

## 故障 2：Docker 拦掉转发，能连上但打不开网页

### 现象

手机能连上热点、能拿到 DHCP 地址（`10.42.0.206`），DNS 也能通，
但打开网页一直加载、无响应。本机自己上网完全正常。

### 根因

Docker 需要 `net.ipv4.ip_forward=1` 才能让容器联网。开启它的同时，Docker 出于
安全会把 iptables `filter` 表的 `FORWARD` 链**策略设为 DROP**：

```
Chain FORWARD (policy DROP 15925 packets, 950K bytes)
1  DOCKER-USER
2  DOCKER-FORWARD
```

而 NetworkManager 给热点写的放行规则在**另一张独立的 nft 表**
（`table ip nm-shared-wlp3s0` 的 `filter_forward`）里。nftables 中同一 hook 上的
多个 base chain 逐个求值、**任一 drop 即生效**，热点流量在到达 NM 的 accept 规则前
就被 Docker 的策略丢弃了。

Docker 官方文档原话：

> When Docker sets the default forwarding policy to "drop", it will prevent your
> Docker host from acting as a router. This is the recommended setting when IP
> Forwarding is enabled, unless router functionality is required.

判定依据：

- `iptables -vnL FORWARD` → `policy DROP`，丢包计数持续增长、接受数为 0。
- `nft list table ip nm-shared-wlp3s0` → 规则本身正确（含 masquerade + forward accept）。
- 客户端 DHCP 正常、DNS 正常（走 INPUT 路径），只有**转发**的流量不通。

### 解决

在 Docker 官方保留给用户的 `DOCKER-USER` 链里补放行规则。Docker 不会改动该链内容，
重启/升级也不会清掉。

脚本 `/usr/local/bin/hotspot-docker-forward.sh`：

```bash
#!/usr/bin/env bash
# 放行 Wi-Fi 热点的转发流量，避开 Docker 设置的 FORWARD DROP 策略。
#
# 背景：Docker 把 ip filter 表 FORWARD 链的策略设为 DROP；NetworkManager 的热点
# 放行规则写在独立的 nm-shared-<iface> 表里。nftables 中同一 hook 上的多个 base
# chain 逐个求值、任一 drop 即生效，热点客户端的转发流量会在到达 NM 的放行规则前
# 被 Docker 的策略丢弃，表现为客户端能拿到 DHCP 地址、能解析 DNS，但网页打不开。
#
# DOCKER-USER 是 Docker 官方保留给用户自定义规则的链，Docker 不会改动其内容。
# 发往容器网段的流量 RETURN，交回 Docker 自身规则处理（未发布的端口仍被隔离）；
# 其余转发流量放行，实现共享上网。
#
# 幂等：可重复执行。用法：hotspot-docker-forward.sh [网卡名...]
#        不传参数时对默认网卡生效。

set -euo pipefail

if (($# > 0)); then
    IFACES=("$@")
else
    IFACES=(wlp3s0)
fi

ipt() { iptables -w 5 "$@"; }

# 收集容器网桥承载的子网（docker0 与 br-* 设备上的直连路由）。
container_nets() {
    ip -4 route show | awk '$2 == "dev" && ($3 == "docker0" || $3 ~ /^br-/) { print $1 }'
}

mapfile -t NETS < <(container_nets)
if ((${#NETS[@]} == 0)); then
    NETS=(172.16.0.0/12)
    echo "hotspot-docker-forward: 未检测到容器网桥，回退使用 ${NETS[0]}" >&2
fi

ipt -nL DOCKER-USER >/dev/null 2>&1 || ipt -N DOCKER-USER
ipt -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || ipt -I FORWARD 1 -j DOCKER-USER

# 先移除本脚本此前写入的规则，保证重复执行后链内容一致。
for iface in "${IFACES[@]}"; do
    for net in "${NETS[@]}"; do
        ipt -D DOCKER-USER -i "$iface" -d "$net" -j RETURN 2>/dev/null || true
        ipt -D DOCKER-USER -o "$iface" -s "$net" -j RETURN 2>/dev/null || true
    done
    ipt -D DOCKER-USER -i "$iface" -j ACCEPT 2>/dev/null || true
    ipt -D DOCKER-USER -o "$iface" -j ACCEPT 2>/dev/null || true
done

pos=1
for iface in "${IFACES[@]}"; do
    for net in "${NETS[@]}"; do
        ipt -I DOCKER-USER "$pos" -i "$iface" -d "$net" -j RETURN; pos=$((pos + 1))
        ipt -I DOCKER-USER "$pos" -o "$iface" -s "$net" -j RETURN; pos=$((pos + 1))
    done
    ipt -I DOCKER-USER "$pos" -i "$iface" -j ACCEPT; pos=$((pos + 1))
    ipt -I DOCKER-USER "$pos" -o "$iface" -j ACCEPT; pos=$((pos + 1))
done

echo "hotspot-docker-forward: 已为 ${IFACES[*]} 配置规则（容器网段：${NETS[*]}）"
```

服务 `/etc/systemd/system/hotspot-docker-forward.service`：

```ini
[Unit]
Description=放行 Wi-Fi 热点转发流量（Docker FORWARD DROP 策略）
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hotspot-docker-forward.sh

[Install]
WantedBy=multi-user.target
```

安装：

```bash
sudo install -m 0755 -o root -g root hotspot-docker-forward.sh  /usr/local/bin/hotspot-docker-forward.sh
sudo install -m 0644 -o root -g root hotspot-docker-forward.service /etc/systemd/system/hotspot-docker-forward.service
sudo systemctl daemon-reload
sudo systemctl enable --now hotspot-docker-forward.service
```

`PartOf=docker.service` 让 Docker 重启时本服务一并重启，规则自动重建。
手工重跑：`sudo /usr/local/bin/hotspot-docker-forward.sh`

### 为什么不去改 Docker 配置

官方也提供 `"ip-forward-no-drop": true`（写进 `/etc/docker/daemon.json`）来取消
默认丢弃策略，但那是**全局**生效的：整台机器的转发都失去保护。用 `DOCKER-USER`
只影响热点网卡，Docker 的安全默认对容器依然有效。

### 验证

| 对照项 | 结果 |
|---|---|
| 不加放行规则，ping 公网 | 100% 丢包（复现故障） |
| 加放行规则，ping 公网 | 0% 丢包，计数器同步增长 |
| 移除规则，ping 公网 | 100% 丢包（反证因果） |
| 同一源访问容器网段 | 仍 100% 丢包（容器隔离未破坏） |

测试用网络命名空间（netns + veth）模拟热点客户端，真实走内核转发路径：

```bash
# 1. 建命名空间与 veth 对，命名空间内默认路由指向主机
sudo ip netns add hotspot-fwd-test
sudo ip link add veth-fwd-test type veth peer name veth-fwd-test-c
sudo ip link set veth-fwd-test-c netns hotspot-fwd-test
sudo ip addr add 10.99.0.1/24 dev veth-fwd-test && sudo ip link set veth-fwd-test up
sudo ip netns exec hotspot-fwd-test ip addr add 10.99.0.2/24 dev veth-fwd-test-c
sudo ip netns exec hotspot-fwd-test ip link set veth-fwd-test-c up
sudo ip netns exec hotspot-fwd-test ip route add default via 10.99.0.1

# 2. 模拟 NetworkManager 的共享地址伪装
sudo iptables -t nat -I POSTROUTING 1 -s 10.99.0.0/24 ! -o veth-fwd-test -j MASQUERADE

# 3. 关掉反向路径过滤，避免干扰
sudo sysctl -qw net.ipv4.conf.veth-fwd-test.rp_filter=0

# 4. 测公网与容器网段
sudo ip netns exec hotspot-fwd-test ping -c3 223.5.5.5      # 应通
sudo ip netns exec hotspot-fwd-test ping -c2 172.19.0.2     # 应不通（隔离）

# 5. 清理
sudo ip netns del hotspot-fwd-test; sudo ip link del veth-fwd-test
```

幂等性自检：

```bash
before=$(sudo iptables -S DOCKER-USER | md5sum)
sudo systemctl restart hotspot-docker-forward.service
after=$(sudo iptables -S DOCKER-USER | md5sum)
[ "$before" = "$after" ] && echo 幂等 OK
```

---

## 故障 3：缺 `wireless-regdb`，热点随机启动失败

### 现象

前两个问题修好后，热点**时好时坏**：面板"正在启动热点..."一直转，
约 29 秒后失败；重试一次有时又成功。2.4 GHz 稳定，5 GHz 随机失败。

### 根因链

1. 本机**未装 `wireless-regdb`**（无线管制域数据库），`/lib/firmware/regulatory.db`
   不存在。
2. 因此 `cfg80211` 停留在 **country 00（世界域）**。
3. 世界域下 5 GHz 信道全部带 `no_ir=1`（禁止主动发射）；AP 模式必须主动发信标，
   于是 `wpa_supplicant` 报 `Failed to start AP functionality`。
4. 唯一例外：内核扫描到邻居 AP 的 beacon hint 时会临时放开该频点。
   → 启动前是否恰好扫到邻居，决定了成败，表现为 **50% 随机失败**。

失败回合的 wpa_supplicant 日志：

```
wlp3s0: CTRL-EVENT-REGDOM-CHANGE init=CORE type=WORLD
wlp3s0: CTRL-EVENT-REGDOM-BEACON-HINT before freq=5180 max_tx_power=2000 no_ir=1
wlp3s0: Failed to start AP functionality
```

NetworkManager 侧：

```
Activation: (wifi) Hotspot network creation took too long, failing activation
state change: config -> failed (reason 'supplicant-timeout')
```

成功回合则是直接 `interface state UNINITIALIZED->ENABLED` → `AP-ENABLED`。

### 解决

```bash
sudo pacman -S --needed wireless-regdb
```

写入持久化配置 `/etc/modprobe.d/cfg80211-regdom.conf`：

```ini
# 开机即把无线管制域设为 CN（中国）。
# 若不设，内核停留在"世界域"：5GHz 信道默认禁止主动发射(no_ir)，
# 导致 5GHz 热点(AP 模式)启动随机失败。
options cfg80211 ieee80211_regdom=CN
```

**关键：装包后必须重载无线模块栈**，否则已加载的 `cfg80211` 读不到新数据库。

```bash
sudo nmcli radio wifi off
# 逐层卸载（有依赖顺序）
for m in rtw89_8852be rtw89_8852b rtw89_8852b_common rtw89_pci rtw89_core mac80211 cfg80211; do
    lsmod | grep -q "^$m " && sudo modprobe -r "$m"
done
sudo modprobe rtw89_8852be
sudo nmcli radio wifi on
sudo iw reg set CN
```

> 重载后若 `wlp3s0` 变成 `unavailable` 且 NM 报
> `Couldn't initialize supplicant interface: wpa_supplicant couldn't grab this interface`，
> 重启 wpa_supplicant 即可恢复：
>
> ```bash
> sudo systemctl restart wpa_supplicant
> nmcli device connect wlp3s0
> ```

### 实测结果

| 阶段 | 管制域 | 5GHz 成功率 | 失败时耗时 |
|---|---|---|---|
| 修复前 | `00` | 3/6（50%） | 29 秒超时 |
| 修复后 | `CN` | 6/6，压力测试 8/8（100%） | 4–5 秒 |

2.4 GHz 回归测试 4/4 通过；多轮开关后管制域稳定保持 `CN`，不再退回世界域。

### 验证

```bash
cat /sys/module/cfg80211/parameters/ieee80211_regdom   # 应为 CN，不是 00
iw reg get                                             # country CN: DFS-FCC
ls /lib/firmware/regulatory.db                         # 数据库存在
# 5GHz 非 DFS 信道应无 "no IR" 标记
iw phy phy0 info | awk '/Band 2:/,/Band 4:/' | grep -E '^\s+\* (5180|5200|5220|5240|5745|5785)'
```

---

## 排查速查表

热点出问题时，按这个顺序看：

| 检查 | 命令 | 正常表现 |
|---|---|---|
| 卡在哪一步 | `journalctl -u NetworkManager --since "-10 min" \| grep -E 'failed\|unavailable\|could not'` | 无相关行 |
| DHCP 服务 | `pgrep -a dnsmasq` | 进程存在，带 `--dhcp-range` |
| 转发放行 | `sudo iptables -vnL FORWARD --line-numbers \| head -4` | 若 policy DROP 且计数增长 → 故障 2 |
| 转发放行规则 | `sudo iptables -vnL DOCKER-USER --line-numbers` | 应有 6 条 `wlp3s0` 规则 |
| 管制域 | `cat /sys/module/cfg80211/parameters/ieee80211_regdom` | `CN`；`00` 即故障 3 |
| 无线驱动错误 | `sudo dmesg \| grep -i rtw89 \| tail` | 无 `Failed to start AP` |
| 客户端是否连上 | `cat /var/lib/NetworkManager/dnsmasq-wlp3s0.leases` | 有租约行 |

排查热点"卡加载"时，**先看 `journalctl -u NetworkManager` 里
`state change: ... -> failed (reason '...')` 那一行**，比看界面快得多。

---

## 常见误区

### 在面板"可用网络"列表里点自己的热点名

不要这样做。DMS 会创建一条同名客户端配置去"连接"这个网络，而那块网卡正在自己
发这个信号——物理上不可能成功，还会把热点踢掉、抢走网卡，表现为热点莫名闪断。

用热点就按面板"热点"区块的开关。若已误建，删除：

```bash
nmcli connection show | grep <你的热点SSID>   # 确认是否多出一条 infrastructure 模式的配置
nmcli connection delete <那条配置名>
```

### 认为开热点需要 Docker

不需要。Docker 与本机热点毫无关系，它只是恰好也在这台机器上运行（用于
`~/Projects/Feed stream/feed-java` 的 MySQL/Redis），并且修改了系统的转发默认策略。
故障 2 的修复写在 Docker 的规则链里，是因为**问题出在 Docker 设的默认策略上**，
而不是因为热点依赖 Docker。

### 热点起来过一次就以为好了

这些故障是**间歇性**的。判断修没修好要跑多轮开关测试，不是开一次成功就算：

```bash
for i in $(seq 1 6); do
  nmcli connection down "DankMaterialShell Hotspot" >/dev/null 2>&1
  sleep 1
  nmcli connection up "DankMaterialShell Hotspot" >/dev/null 2>&1 && echo "第 $i 轮: 成功" || echo "第 $i 轮: 失败"
  sleep 2
done
```

修复前 5 GHz 约 50% 成功率，修复后应稳定 100%。

---

## 当前最终状态

| 项目 | 状态 |
|---|---|
| 热点连接名 / SSID | `DankMaterialShell Hotspot` / `tjzpsh111`（5 GHz，AP 模式） |
| 无线管制域 | `CN`（由 `/etc/modprobe.d/cfg80211-regdom.conf` 开机生效） |
| DHCP/DNS | `dnsmasq 2.93`，由 NetworkManager 按需拉起（服务保持 disabled） |
| 转发放行 | `hotspot-docker-forward.service` 已启用，6 条 `wlp3s0` 规则 |
| 热点地址 | `wlp3s0` = `10.42.0.1/24`，地址池 `10.42.0.10–254` |

### 无害噪音

dnsmasq 每次启动都会打印一条：

```
chown of PID file /run/nm-dnsmasq-wlp3s0.pid failed: please add capability CAP_CHOWN
```

不影响 DHCP/DNS 功能。

内核偶发 `rtw89_8852be ... timed out to flush queues` 属驱动噪音，与热点启动失败
无因果关系（已用对照实验排除）。

### 系统升级后可能要重做

- `linux-firmware` 升级一般不影响（`regulatory.db` 由 `wireless-regdb` 提供）。
- 重装系统或重置桌面环境后，DMS 可能又建出同名冲突配置（见上文误区）。
- Docker 若被重装，确认 `hotspot-docker-forward.service` 仍在：
  `systemctl is-enabled hotspot-docker-forward.service`
