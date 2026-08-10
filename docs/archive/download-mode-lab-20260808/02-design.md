# 候选下载模式与初步设计

## 结论先行（待 mock/网络对照验证）

优先候选不是盲目安装 `aria2c` 或把所有源改成多线程，而是：

1. **镜像选择和下载执行分离**：并发探测实际 repo 的 HEAD + 小范围吞吐，形成有过期时间的排序；
2. **官方包优先使用 pacman 原生 downloader**：保留 `ParallelDownloads`，先不强制外部 `XferCommand`；pacman 7.1 已有下载超时选项和 sandbox，外部 curl 只作为显式 fallback；
3. **预取与安装分离**：用 `pacman -Sw`/`--downloadonly` 把网络失败集中在可重试阶段，确认缓存和签名后再做安装事务；不把下载失败隐藏在安装阶段；
4. **AUR 源码采用 manifest 驱动的有限并发预取**：每个目标独立 `.part`、checksum/大小验证、失败隔离；大型 VMware 文件单独队列，不阻塞小源；
5. **缓存优先**：已有完整且校验通过的文件不重复下载；缓存 manifest 绑定 recipe/source hash；
6. **所有超时/重试有统一预算**：connect、低速、总时限、重试次数分开记录，超时返回码保留；
7. **不改变主安装器，先在本目录验证**：候选工具只生成临时 pacman.conf/缓存和报告，用户批准后才考虑合并。

## 不推荐直接采用的方案

- 直接把 `ParallelDownloads` 调到很大：可能把单个镜像打爆，也不能修复错误镜像选择；
- `curl | sh`、无 checksum 的第三方下载器、无签名的本地 repo；
- 用 `--disable-download-timeout` 解决所有慢：这会把真正卡死变成长时间无反馈；
- 多进程并发 `makepkg`：recipe 依赖、pacman 数据库、磁盘空间和 AUR->AUR 拓扑需要先隔离；
- 在主脚本里临时修改宿主 `/etc/pacman.conf` 而没有备份/恢复和用户批准。

## 对照组

- A：现有 pacman 原生（ParallelDownloads=5，无 XferCommand）；
- B：现有脚本写入的外部 curl XferCommand + ParallelDownloads=5；
- C：原生 pacman + 动态镜像排序 + `--downloadonly` 预取；
- D：C + manifest 驱动 AUR 源码有限并发预取。

必须用 mock server 验证 A/B 的真实并发数和失败传播，再用小范围只读网络探测验证镜像排序；没有真实安装 benchmark 时，不得宣称 C/D 已经快多少倍。

## 验证后的设计收敛（2026-08-08）

`FINAL.md` 是本实验当前结论。对照已不再只是候选假设：

1. 默认官方包路径保留 pacman native downloader；不要默认写入外部
   `XferCommand`。native stall 仍会按默认低速规则失败并返回非零，不能用
   `DisableDownloadTimeout` 掩盖问题。
2. 镜像排序必须以实际 repo/package 的短探测为输入，并区分 `UNAVAILABLE`、Range
   不支持和真正空结果。
3. AUR 只对独立 source prefetch 做有限并发；makepkg 仍按依赖拓扑串行/分层。
4. `.part`、checksum/size、原子 rename、断点恢复和失败报告是合并门槛，不是可选优化。
5. `fetch-aur-sources.sh` 的手工 source 列表、非空 cache 跳过和无 resume 缺陷必须
   在主代码合并前单独解决；不能把实验候选直接复制进去。

证据：`results/pacman-*.json`、`results/package-range-1m.json`、
`results/download-integrity.json`、`results/aur-queue-model.json`、
`results/source-cache-audit.json`。
