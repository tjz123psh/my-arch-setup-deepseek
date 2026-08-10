---
description: 为宽泛前端需求启动统一设计、实现与视觉验收链路。
agent: sisyphus-prometheus
---

将以下需求作为前端交付任务处理：

```text
$ARGUMENTS
```

先加载 `design-reasoning`。判定产品类型与目标平台，建立七行 UI Contract；随后按阶段选择一个主导 skill（结构、平台基线、视觉、实现、视觉复核、行为验收），不要同时让多个大而全 skill 争夺决定权。新建或重设计且视觉有变化时，路线中必须显式列出 `design-critique`，并真实运行完成截图 → 视觉评审 → 修正 → 再截图，之后才做行为验收。Web/Desktop 的验收等级只使用 `Smoke`、`Standard` 或 `Release`，并把选择写入 Contract；明确的小样式修复或纯非视觉逻辑不需要强制展开完整流程。
