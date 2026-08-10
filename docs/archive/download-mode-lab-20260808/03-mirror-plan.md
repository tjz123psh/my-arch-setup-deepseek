# 第三步：动态镜像计划（隔离实验）

日期：2026-08-08（Asia/Shanghai）

## 1. 范围与硬边界

第三步只在 `download-mode-lab/` 实现“观测结果 → 可审查 mirror plan”的聚合器，
不直接修改：

- `scripts/01-mirror.sh` 或其他主安装器流程；
- 宿主 `/etc/pacman.conf`、`/etc/pacman.d/mirrorlist` 或 archlinuxcn 配置；
- 宿主服务、软件包、网络、内核、GRUB；
- KVM/VMware 配置、磁盘、快照或任何 VM 资产。

工具：

```text
bin/mirror-plan.py
bin/probe-mirrors.py
bin/probe-ranges.py
bin/probe-package-ranges.py
tests/mirror-plan-test.py
```

planner 只写调用方指定的输出文件，使用同目录临时文件原子替换；不调用 shell、
pacman 或 root 命令。

## 2. 输入 lane 与排序规则

官方仓库和 `archlinuxcn` 始终独立排序。观测按 measurement lane 分开，**不会把
数据库 Range 与实际包 Range 的速度混进同一个中位数**：

1. `package`：`probe-package-ranges.py` 的实际包 Range；
2. `database-range`：`probe-ranges.py` 的数据库 Range；
3. `throughput`：带字节/吞吐字段但无法归类的手工观测；
4. `latency`：`probe-mirrors.py` 的 HEAD 观测。

同一仓库优先选有可用样本的最高 lane：

```text
package > database-range > throughput > latency
```

如果 package lane 全部不可用，才退回 database-range；不会用低优先级 lane 偷换成同
一类 fallback。相同 lane 的重复样本按镜像聚合并取中位数。

吞吐 lane 的评分为：

```text
median_throughput_mib_s
× measured_availability_ratio
× range_support_ratio       # 仅 package/database-range lane
```

latency lane 没有吞吐数据时才使用：

```text
availability_ratio / median_latency_seconds
```

`RANGE_UNSUPPORTED`、`UNAVAILABLE`、超时和不完整样本不会进入可应用的 server 列表，
但会保留在候选观测中。`unavailable_candidates` 只表示**当前选中 lane** 的失败
候选；被 package lane 取代的 database/HEAD 候选放在
`other_measurement_candidates`，不再误标为“不可用镜像”。

## 3. 状态、退出码和安全契约

输出顶层状态：

```text
ok             有足够的 primary + fallback，可审查应用

degraded       有可用镜像但少于 min_fallbacks + 1；默认非零退出，不可自动应用
unavailable    目标仓库没有可用候选，非零退出
stale          输入超过 TTL，非零退出
future         输入时间超出允许的未来时钟偏差，非零退出
invalid        JSON、URL、仓库名、状态/HTTP/exit_code 组合不一致，非零退出
```

每份成功计划包含 `applyable`；只有 `status=ok` 时为 `true`。即使显式使用
`--allow-degraded` 让命令以零退出，`applyable` 仍为 `false`，调用方必须检查该字段，
不能只看 shell exit code。

新鲜度：

- 默认 `--max-age-seconds=86400`；安装会话建议使用更短 TTL；
- 默认允许最多 300 秒未来时钟偏差，超出即 `future`；
- `max-age-seconds` 上限为 7 天，未来偏差上限为 1 天，NaN/Inf 和越界参数拒绝；
- stale/future/invalid 都 fail closed，不生成可应用的空 mirrorlist。

URL 只允许无 userinfo、无 query/fragment、无空白/控制字符及 pacman 配置特殊字符的
`http://`/`https://` 地址；malformed URL 统一生成 `invalid` 报告，不抛出未处理异常。
仓库名目前限定为 `official` 和 `archlinuxcn`，server 模板分别为：

```text
https://host/archlinux/$repo/os/$arch
https://host/archlinuxcn/$arch
```

探测的原始 stderr 不写入计划。计划只保留有限的结构化 `error_class`（例如
`timeout`、`range_unsupported`、`http_500`、`probe_exit_28`），并保留 HTTP 状态和
退出码；这样不会把 bearer token、代理认证或任意诊断文本带进 JSON。

## 4. 已完成的回归与真实探测

### 4.1 本地 mock 回归

`tests/mirror-plan-test.py` 当前 **41/41 PASS**，覆盖：

- 官方/archlinuxcn 独立排序、重复样本、中位数和 pacman server template；
- unavailable 观测保留、fallback 门槛、degraded 默认非零及显式 allow 语义；
- package/database lane 隔离和优先级；
- `RANGE_UNSUPPORTED` 不满足 fallback；
- stale/future fail closed；
- HTTP 状态与 exit code 矛盾组合拒绝；
- unknown repo、userinfo、控制字符、query、fragment、malformed URL 拒绝；
- 原始诊断/合成 token 不进入计划；
- 固定输入下的确定性排序及错误报告原子写入；
- 非有限派生吞吐、UTC/过期时间溢出、非 UTF-8/超长整数/深嵌套 JSON fail closed；
- 两个真实 probe 函数的 `206 → OK/true/0`、`200 → RANGE_UNSUPPORTED/false/0`、
  失败 → `UNAVAILABLE/false/nonzero` 契约。

`bash download-mode-lab/run-lab.sh` 已连续两轮通过；每轮还包含 Python syntax、原子
下载故障注入 20/20、AUR 有界队列模型、native stall 回归和 source-cache 缺陷审计。
source-cache 审计的状态仍是 `defects_confirmed`，它是主代码缺陷证据，不是健康 PASS。

### 4.2 真实只读网络探测

保留了之前的第一轮快照（`results/mirror-head.json`、`mirror-range-256k.json`、
`package-range-1m.json`），并在 2026-08-08 16:06–16:07（本地时间）完成第二轮；
随后用修正后的 probe 契约在 17:37（Asia/Shanghai；09:37 UTC）完成第三轮。所有重复输出仅写入被 git 忽略的
`fixtures/tmp/final-verification/`，不覆盖审查快照。第三轮统计如下：

| 探测（第三轮） | OK | UNAVAILABLE | RANGE_UNSUPPORTED | 结果 |
|---|---:|---:|---:|---|
| HEAD（15 个官方/archlinuxcn 候选） | 15 | 0 | 0 | 命令退出 0 |
| 数据库 256 KiB Range | 12 | 1 | 2 | 命令退出 0 |
| 实际包 1 MiB Range | 12 | 3 | 0 | 命令退出 0 |

失败项保留了退出码/HTTP 状态；失败不被解释为空列表或健康。第三轮 package lane
生成的**当前样本**排序为：

- 官方：Aliyun → Tencent → Huawei → 清华 → 163 → USTC（LZU、ZJU 不可用）；
- archlinuxcn：Aliyun → Huawei → Tencent → 清华 → USTC → ZJU（LZU 不可用）。

第二轮和第三轮的排名不同，正是必须使用短 TTL、实际包探测和 fallback 的原因；这些
数字不是长期带宽承诺。

排序受时间、出口、代理、镜像同步和代表包选择影响，不能提交为永久 mirrorlist，也
不能代替目标机 `pacman -Sw` 前后对照。

## 5. 当前仍未做、不能宣称完成的事项

- 没有把 planner 接入 `scripts/01-mirror.sh`，没有生成或应用宿主 mirrorlist；
- 没有真实 `pacman -Sw`/完整安装前后耗时对照；
- 没有真实 AUR 下载/构建、Go/Cargo cache、VMware bundle/ISO 断点恢复验收；
- 没有 VM、仿物理或物理机实战测试；
- Hyprland/DMS 登录、重登、VMware 3D/Wayland 运行时仍未测；
- ShellCheck 仍有 warning/info，完整仓库不宣称全绿；
- reviewer 两轮独立复核先后发现并验证关闭了输入 lane、时间、URL、状态机、脱敏、
  数值溢出和 JSON 解码边界问题，最终 blocker-only 结论为“无阻断发现”；reviewer
  未独立运行会写临时文件的完整套件，因此完整回归证据仍以本地两轮 41/41 为准。

## 6. 接入前必须单独批准的最小方案

下一步只能先展示 `scripts/01-mirror.sh` 的最小 integration dry-run，不直接 apply：

1. 将动态探测放在镜像写入前，使用临时工作区输出 plan；
2. 只在 `status=ok` 且 `applyable=true` 时生成新的官方/archlinuxcn server 内容；
3. `degraded`、`unavailable`、`stale`、`future`、`invalid` 一律保留现有 mirrorlist，不覆盖；
4. 在写入前生成带权限/路径记录的备份，使用临时文件 + 原子 rename；
5. 失败时不执行 pacman sync，不安装额外 downloader，不碰 VM/宿主资产；
6. 先在隔离 fake root/pacman mock 回归，再请求用户明确批准主代码补丁。

在没有该批准前，第三步结论是：**隔离实验完成，可进入 integration review；不能进入主
安装器 apply**。
