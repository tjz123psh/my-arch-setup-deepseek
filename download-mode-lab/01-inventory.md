# 下载链路盘点（初始记录）

日期：2026-08-08
范围：只读代码/配置阅读；本目录实验尚未改变宿主系统。

## 当前链路

### 官方 pacman

1. `scripts/01-mirror.sh`
   - 先用 Aliyun `core.db` 做单点可达性判断；
   - 成功就写入 8 个中国镜像；
   - 失败则安装 reflector，并尝试 `timeout 60 run reflector ...`；
   - 后续通过 `sed` 向 `/etc/pacman.conf` 的 `[options]` 插入 `XferCommand`。
2. `scripts/02-system.sh`
   - `pacman -S --needed ...`；
   - 全系统升级 `pacman -Syu`。
3. `scripts/03-packages.sh`
   - archlinuxcn 配置/同步；
   - 可能再次 `pacman -Sy`；
   - 批量安装官方包，失败重试后逐包安装。

### AUR / makepkg

- `scripts/06-aur.sh` 为每个 recipe 建独立目录并顺序执行 `makepkg -s`；
- makepkg 的 HTTP/HTTPS DLAGENT 由脚本尝试改写超时和重试；
- `.aur-sources` 存在时通过 `SRCDEST/GOMODCACHE/CARGO_HOME` 走离线缓存；
- `vmware-keymaps` 先 bootstrap，其他 recipe 仍是单队列；
- 大型 VMware bundle/ISO 在 `fetch-aur-sources.sh` 中串行下载。

### 目前只读观察

- 当前 `/etc/pacman.conf` 的 `ParallelDownloads = 5` 存在；没有启用的 `XferCommand`（只有注释行）。
- 当前 `/etc/makepkg.conf` 的默认 DLAGENT 没有超时；主脚本只有在实际安装到 06 时才尝试改写它。
- 当前宿主没有 `aria2c`、`axel`、`parallel`、`wget2`；不能把“增加并发工具”当成零依赖改动。
- 当前主机查询到的 `dms-shell` 等包/服务不属于本实验的下载结论，不在此目录修改。

## 已确认的高风险慢点（尚未量化）

| 位置 | 风险 | 需要怎样验证 |
|---|---|---|
| 01:36-60 | 单点探测 + reflector function 调用错误 | mock function/命令和镜像探测对照 |
| 01:79-83 | 外部 curl 是否削弱 pacman 原生并发 | 临时 pacman.conf + mock URL 进程计数 |
| 02/03 | 重复同步数据库 | 记录 pacman invocation 和下载字节 |
| 06:69-195 | recipe 串行 makepkg | 不构建真实包，用 fake makepkg 计时/并发模型 |
| fetch:18-40 | URL/git 下载串行、错误日志共用 `/tmp` | mock server + 并发下载器故障注入 |
| fetch:113-133 | 大文件串行且无统一 manifest | 小型 fixture 模拟大小/校验/断点 |

## 后续验证更新（2026-08-08）

本文件的“尚未量化”是初始盘点时的状态；当前证据以 `FINAL.md` 和 `results/`
为准：

- `install.sh` 的 pre-flight `-Sy/-Syyu` 在 `01-mirror.sh` 之前，已确认首次大同步
  不受 01 的镜像优化影响；
- pacman native/Xfer 对照已重复验证：native 按 `ParallelDownloads` 并发，外部
  `XferCommand` 在本机 pacman 7.1 mock 中退化为单流；
- native stall mock 在服务器 12 秒不发字节时约 10 秒非零退出，证明原生默认低速
  超时存在；`tests/pacman-native-stall-test.sh` 可重复该结果；这不是硬总时限；
- 官方和 archlinuxcn 的实际包 Range 探测已完成，结果分别记录为 `OK` 或
  `UNAVAILABLE`，未把探测失败当成空结果；
- AUR 独立源 jobs=1/jobs=3 队列模型已两轮通过；这不授权并发 makepkg；
- `source-cache-audit.py` 已确认通用 `dl()` 的非空跳过、删除 `.part`、共享错误
  日志和 Git 失败清理缺陷；该结果故意标为 `defects_confirmed`，不是健康 PASS；
- `download-integrity-test.py` 已两轮 20/20 通过，覆盖 checksum、Range、原子发布
  和非零失败传播。
