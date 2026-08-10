# FlClash 自定义规则配置（闲鱼/阿里系直连）

> 用途：重装系统后恢复「goofish（闲鱼）等阿里系域名直连」规则的操作说明。
> 最后核对：2026-08-10，FlClash 0.8.94（AUR 包 `flclash-bin`），规则存储经数据库实测 + FlClash 源码（chen08209/FlClash）确认。

## 一、这条规则是什么

当时加的是 7 条「阿里系域名直连」规则，全部为 `DOMAIN-SUFFIX` 类型、目标 `DIRECT`（直连，不走代理）：

| 规则 | 效果 |
|---|---|
| `DOMAIN-SUFFIX,goofish.com,DIRECT` | 闲鱼直连 |
| `DOMAIN-SUFFIX,taobao.com,DIRECT` | 淘宝直连 |
| `DOMAIN-SUFFIX,tmall.com,DIRECT` | 天猫直连 |
| `DOMAIN-SUFFIX,alicdn.com,DIRECT` | 阿里 CDN 直连 |
| `DOMAIN-SUFFIX,mmstat.com,DIRECT` | 阿里统计直连 |
| `DOMAIN-SUFFIX,alibaba.com,DIRECT` | 阿里国际直连 |
| `DOMAIN-SUFFIX,aliyun.com,DIRECT` | 阿里云直连 |

**为什么**：闲鱼/淘宝是国内服务，走代理会慢、出验证码、甚至因异地 IP 触发风控，所以直连最优。

## 二、订阅级还是全局？（实测结论）

**这些规则是绑定在订阅上的「附加规则」，不是全局规则。**

证据（本机 `~/.local/share/com.follow.clash/database.sqlite` 实测）：

- `rules` 表存规则本体（`rule_action=DOMAIN_SUFFIX`、`content=goofish.com`、`rule_target=DIRECT`）
- `profile_rule_mapping` 表把每条规则绑定到订阅 id `341449391317454848`，`scene=added`（附加规则），`order=a0..a6`

含义：

- **切换订阅（换供应商）后，这 7 条规则不会自动跟随**。新订阅若也要直连闲鱼，需重新添加，或改用全局附加规则。
- FlClash 源码 `queryAddedRules(profileId)` 语义：`profileId IS NULL`（全局）∪ 当前订阅的 `added` 规则。全局规则对所有订阅生效，订阅级只对指定订阅生效。

**建议**：重装后直接加为**全局附加规则**，一劳永逸。

## 三、重装系统后的配置步骤

### 0. 安装 FlClash

```bash
paru -S flclash-bin        # 或从 AUR 手动安装
```

### 1. 导入订阅

打开 FlClash → 「订阅」页 → 添加订阅（填订阅 URL）→ 更新。

### 2a. 方式一（推荐）：全局附加规则（对所有订阅生效）

打开 FlClash → **设置 → 配置 → 编辑全局规则**（源码 `AddedRulesView`，界面文案「编辑全局规则」）→ 添加规则，逐条填入：

- 规则名称（类型）：`DOMAIN-SUFFIX`
- 规则内容：`goofish.com`（再逐条加 taobao.com / tmall.com / alicdn.com / mmstat.com / alibaba.com / aliyun.com）
- 规则目标：`DIRECT`

保存后所有订阅都会带上这 7 条，规则列表中排在最前，优先级最高。

### 2b. 方式二：订阅级附加规则（只对单个订阅生效）

「订阅」页 → 点订阅卡片右上角 `⋮` → **覆写** → 覆写模式选**自定义** → **规则** → 添加规则（同上，名称/内容/目标三项）。

### 2c. 方式三：直接写数据库（无界面，需 FlClash 完全退出）

数据库位置：`~/.local/share/com.follow.clash/database.sqlite`

```bash
# 1. 找到新订阅的 id（重装后订阅 id 会变）
sqlite3 ~/.local/share/com.follow.clash/database.sqlite "SELECT id, name FROM profiles;"

# 2. 插入 7 条规则（id 用当前毫秒时间戳拼后缀，避免冲突）
sqlite3 ~/.local/share/com.follow.clash/database.sqlite <<'SQL'
INSERT INTO rules (id, rule_action, content, rule_target, rule_provider, sub_rule, no_resolve, src) VALUES
  (strftime('%s','now')||'0001','DOMAIN_SUFFIX','goofish.com','DIRECT',NULL,NULL,0,0),
  (strftime('%s','now')||'0002','DOMAIN_SUFFIX','taobao.com','DIRECT',NULL,NULL,0,0),
  (strftime('%s','now')||'0003','DOMAIN_SUFFIX','tmall.com','DIRECT',NULL,NULL,0,0),
  (strftime('%s','now')||'0004','DOMAIN_SUFFIX','alicdn.com','DIRECT',NULL,NULL,0,0),
  (strftime('%s','now')||'0005','DOMAIN_SUFFIX','mmstat.com','DIRECT',NULL,NULL,0,0),
  (strftime('%s','now')||'0006','DOMAIN_SUFFIX','alibaba.com','DIRECT',NULL,NULL,0,0),
  (strftime('%s','now')||'0007','DOMAIN_SUFFIX','aliyun.com','DIRECT',NULL,NULL,0,0);
SQL

# 3. 订阅级：关联到订阅（<订阅id> 换成第 1 步查到的值）
sqlite3 ~/.local/share/com.follow.clash/database.sqlite <<'SQL'
INSERT INTO profile_rule_mapping (id, profile_id, rule_id, scene, "order") VALUES
  ('<订阅id>_a0','<订阅id>',(SELECT id FROM rules WHERE content='goofish.com'),'added','a0'),
  ('<订阅id>_a1','<订阅id>',(SELECT id FROM rules WHERE content='taobao.com'),'added','a1'),
  ('<订阅id>_a2','<订阅id>',(SELECT id FROM rules WHERE content='tmall.com'),'added','a2'),
  ('<订阅id>_a3','<订阅id>',(SELECT id FROM rules WHERE content='alicdn.com'),'added','a3'),
  ('<订阅id>_a4','<订阅id>',(SELECT id FROM rules WHERE content='mmstat.com'),'added','a4'),
  ('<订阅id>_a5','<订阅id>',(SELECT id FROM rules WHERE content='alibaba.com'),'added','a5'),
  ('<订阅id>_a6','<订阅id>',(SELECT id FROM rules WHERE content='aliyun.com'),'added','a6');
SQL
```

> 全局规则不写 `profile_rule_mapping`（`profileId IS NULL` 即全局），只有订阅级才需要第 3 步。
> 方式三只在界面操作不可行时用；直接改库有风险（版本变更可能改表结构），改前先备份 `database.sqlite`。
