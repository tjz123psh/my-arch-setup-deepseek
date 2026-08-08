# 下载模式实验室（隔离区）

本目录是 `my-arch-setup-deepseek` 的独立下载性能/可靠性实验区。

## 规则

- 只做下载链路分析、模拟测试和只读网络探测；不直接修改宿主 `/etc/pacman.conf`、
  `/etc/makepkg.conf`、镜像列表、服务或软件包。
- 不运行主安装器，不安装/删除包，不启动/修改 VM。
- 所有实验输出写在本目录的 `results/`；不得写入密码、token、cookie、私钥或代理凭据。
- 候选实现必须先通过本地 mock server、失败注入、断点/校验和并发测试，再讨论合并到
  `scripts/01-mirror.sh`/`03-packages.sh`/`06-aur.sh`。
- 任何实验结论都要区分：测量成功、检查失败、网络不可用、未测试。

## 当前问题假设

主安装流程可能慢于必要程度的原因包括：

1. `01-mirror.sh` 只探测 Aliyun 的 `core.db`，没有按实际 repo/package 吞吐选择镜像；
2. `timeout 60 run reflector` 不能执行 shell function，fallback 实际可能立即 `rc=127`；
3. 01/02/03/archlinuxcn 阶段多次 `pacman -Sy`/`-Syyu`，存在重复同步与数据库等待；
4. 01 写入 `XferCommand` 后，原生 `ParallelDownloads` 的收益和外部 curl 进程模型需要实测；
5. AUR 的 `makepkg` 目标按 recipe 顺序串行构建，源码/Go/Cargo 缓存脚本也大多串行；
6. 下载超时/重试参数不统一，部分源使用 `/tmp` 错误日志，失败传播和可诊断性不足；
7. 大型 VMware bundle/ISO 与普通小源混在一个串行队列中，容易造成“看起来卡住”。

## 实验阶段

- `01-inventory.md`：代码链路和当前只读基线；
- `02-design.md`：候选方案、取舍和安全边界；
- `bin/`：不修改主安装器的候选工具；
- `tests/`：本地 mock/故障注入、pacman stall 回归和现有 cache helper 静态审计；
- `results/`：只读网络探测和实验结果；
- `CHECKPOINT.md`：当前状态、不可用检查和唯一下一动作；
- `FINAL.md`：实验结论、是否建议合并以及合并前置条件；
- `NEXT-STEP-PROMPT.txt`：给下一模型的受控接手提示词。

## 当前结论

完整结论见 [`FINAL.md`](FINAL.md)。在用户批准主代码变更前，实验候选不会写入
`scripts/01-mirror.sh`、`scripts/03-packages.sh`、`scripts/06-aur.sh`，也不会写宿主
`/etc/pacman.conf`/`/etc/makepkg.conf`。

本地验证：

```bash
./run-lab.sh
```

`batch-download.py` 是实验模型，不是生产安装器；它的 20 项故障注入通过只说明
缓存/断点/校验/失败传播语义在 mock 环境成立。
