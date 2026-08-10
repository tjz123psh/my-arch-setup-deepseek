---
description: 用可复现历史任务评测模型或 agent 路由，决定是否应调整 OpenCode 模型分工。
agent: sisyphus-prometheus
---

将以下内容作为模型路由评测目标处理：

```text
$ARGUMENTS
```

先加载 `model-routing-eval`，读取其协议和 scorecard 模板。默认只设计或执行一次可恢复的对照评测，不直接改 `opencode.json`、provider、凭据或默认模型。每轮仅比较一个变量，baseline 为当前正式配置；只有达到协议的质量门槛后，才向用户提出有限范围试运行建议。没有至少 5 个可复现任务或相同验收条件时，先产出任务集和评测计划，不伪造结论。
