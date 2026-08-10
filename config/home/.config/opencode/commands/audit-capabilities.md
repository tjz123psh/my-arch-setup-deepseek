---
description: 审计 OpenCode 如何增强和约束模型能力，覆盖 Agents、Skills、Commands、MCP、插件与上下文管理，不以 provider 或凭据检查为中心。
agent: sisyphus-prometheus
---

只读审计本机 OpenCode 能力层，不修改文件。主要范围：

- `instructions.md`、`build-prompt.md` 与 `agents/*.md` 的职责分层、冲突和失效路由
- Skills 的触发 metadata、知识增量、重叠、发现成本、渐进加载与能力缺口
- Commands 是否提供稳定入口，是否错误扩大任务或把 review 变成修改
- MCP 与内置工具的职责边界、重复实现、回退路径和真实可用性
- DCP/compaction 是否保护用户目标、硬约束、Skill/Agent 结果并避免上下文噪声

除非用户明确要求，不审计 provider Key、代理地址、模型价格或 `opencode.json` 的普通字段；只把配置文件用于确认能力入口是否启用。

执行要求：

1. 先读全局提示词、Agents、Commands、`dcp.jsonc` 和 `skills/meta/workflow/SKILL.md`。
2. 统计 Skill 数量、分类和 metadata 体积；抽查重叠或外部迁移痕迹，不把结构检查通过等同于内容优质。
3. 对照所有提示词中的工具名与实际启用能力，找出已禁用、改名或互相竞争的路线。
4. 区分能力缺失、能力重复、路由失败和上下文损失，不用“多装 MCP”作为默认答案。
5. findings 优先并按严重度排序，每项给出文件位置、触发条件和实际影响；最后列出现有强项与前三项改进顺序。

用户补充范围：

```text
$ARGUMENTS
```
