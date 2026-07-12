> 调研方法:2026-07-12 judge-panel 工作流——4 个安全哲学设计视角(hard-wall 硬墙 /
> graduated-friction 梯度摩擦 / env-marker 环境标记 / workflow-first 开发闭环优先)×
> 3 评委(prod-safety / devloop-ux / fit-cost)交叉打分 → 合成。事实基础 =
> scratchpad/table-danger-facts.md(既有设施实勘)。**只设计,未实施。**

以下为最终设计文档(直接返回,未落盘):

---

# redimos-manager「删表 / 重建表」功能设计(定稿,先设计不实施)

## 1. 问题定性

本地开发循环里「重置表、换 schema、回到干净运行态」一天要做几十次,必须一键顺手;但 manager 无法区分测试 AWS 和生产 AWS 账号,同一个按钮指向真 AWS 就是不可撤销的灾难。现有最强信号只有 Endpoint/AWS 模式开关,schema 权威在 redimos 的 `-auto-create-table` 侧,且多个 config 可能共享同一 endpoint+table、运行中的代理不能被静默抽表——设计必须让安全来自结构而非用户自觉。

## 2. 四方向对比表

| 方向 | 核心做法 | 优点 | 硬伤 | 三评委总分(prod-safety/devloop-ux/fit-cost) |
|---|---|---|---|---|
| **hard-wall** | 破坏性表操作仅存在于 Endpoint 模式,AWS 模式无按钮无解锁,native 层按已保存 config 独立二次拒绝;本地一键 Recreate 封装全流程 | 生产灾难按构造不可能,无可腐化的解锁态,零 store 改动,实现增量最小,防御纵深免费 | 合法「测试 AWS」用户零支持,只能去 console;回环启发式可被 SSH 隧道击穿 | **26**(9/8/9) |
| workflow-first | 复合动词 Reset table…(停→删→AutoCreate 重启)仅在 Endpoint 模式按构造存在;AWS 生删走 per-config 开关+仪式 | 最佳 dev loop 人机工学(侧栏右键入口、落地空表验证、失败整组复原) | AWS 路径仍是「静默持久的上膛枪」(allowAwsTableOps 开关腐化),纯 UI 门禁无 native 兜底 | 23(6/9/8) |
| env-marker | 每 config 加 Auto/Dev/Protected 环境标记,统一谓词门禁;标记随字段修改自动失效 | 唯一能保护共享 Endpoint 的方案(sharer 取最大保护);AWS 摩擦一次性摊销 | 标记是无法证伪的人为声明;三态新概念基本复述模式信号,三处 UI + sharer 聚合税重 | 20(7/8/5) |
| graduated-friction | 不设墙,三档摩擦阶梯(回环轻确认/远程输表名/AWS 解锁+输入+倒计时+爆炸半径加码) | 唯一给 AWS 日常循环一等公民路径;爆炸半径自适应是全场唯一「审问数据本身」的信号 | 每层防线都是用户自觉或仪式,仪式必然习惯化;Wipe 原语重成本弱收益;日常操作藏在菜单跳两层 | 15(4/6/5) |

**裁决:hard-wall 以 26 分明确胜出**(prod-safety 与 fit-cost 双第一,devloop-ux 并列第二),在其骨架上嫁接其余三案的四个近零成本好点子。

## 3. 推荐方案(合成):Endpoint-Only 硬墙 + 工作流化 Recreate

基底 = hard-wall。偷取:workflow-first 的侧栏右键入口/落地空表验证/事务化失败语义/endpoint 归一化文档化;graduated-friction 的 dirty 编辑器锁与 DescribeTable 证据行、爆炸半径自适应加码;env-marker 的「字段变更自动回锁」规则记入未来备注。

### A. UI 位置

- **主入口 = Table 页工具栏右端**(与 index 选择器/刷新控件并排——在你正盯着要销毁的数据的地方做销毁):
  - Endpoint 模式:红色 `OutlinedButton.icon(Icons.restart_alt, 'Recreate')`(高频主原语直达)+ 相邻 caret(`MenuAnchor`)内含次级项 `Delete table…`。
  - AWS 模式:同一位置渲染**禁用**灰色 `Chip(Icons.lock, 'Table ops — Endpoint mode only')`,tooltip:`Destructive table operations are hard-disabled for AWS targets. Use the AWS console or CLI.`。渲染禁用 chip 而非隐藏是刻意的:用户学到能力存在及缺席原因,不会到处找。
- **辅助入口 = 侧栏 config 右键菜单 `Recreate table…`**(仅 Endpoint 模式出现)——dev loop 常从侧栏开始,省一次 tab 跳转(偷自 workflow-first)。
- **明确不放** Configure pinned action bar:那里的红色 Delete 是删 config,「删表」与「删配置」相邻同色异义是经典误触陷阱。
- **编辑器 dirty 时全部入口禁用**,tooltip `Save config first`;所有危险操作只读 **store.json 已保存的 config**,杜绝「编辑器里看着是 Endpoint、存盘的其实是 AWS」的错觉(偷自 graduated-friction)。

### B. 原语集

两个,刻意不是三个:

1. **Recreate table**(95% 场景)= 停依赖 → DeleteTable → 等表消失 → 带一次性 `-auto-create-table` 重启,覆盖「重置数据」与「v1(S)↔v2(B) 换版本换 schema」两大需求。换版本迁移手势即:Configure 改版本 → Save → Recreate。
2. **Delete table**(菜单内次级)= 仅删表不重建,依赖全部留在停止态;弹窗注明 AutoCreate 下次启动会重建空表。用于收摊/改名/交给别的工具。

**不做 WipeData**(Scan+BatchWrite 批删):本地被 Recreate 严格支配(O(1) vs O(n)、无部分失败态、回到权威 schema);唯一价值场景(AWS 上保表清数据)已被墙掉。**不做 manager 侧 CreateTable**(见 D)。

### C. 安全模型分层(每层确切行为与文案)

- **L1 · 能力墙(设计脊柱)**:按钮仅在 `_ddbMode == 'endpoint'`(saved config.endpoint 非空)时存在;AWS 模式只有禁用锁 chip。**无解锁开关、无 env var、无隐藏快捷键、无「我知道我在做什么」勾选。** 安全是结构性的,不会因习惯化衰减——每天点确认的人在指向生产那天也会点,但不存在的按钮点不穿。
- **L2 · native 层独立拒绝(防御纵深,三评委一致要偷的 5 行)**:Go 侧 `tableDelete` 按 **store.json 已保存 config** 判定,endpoint 为空即拒绝,返回:`{ok:false, error:"destructive table ops require an explicit endpoint (AWS mode is read-only for table lifecycle)"}`。Flutter 状态 bug、stale `_ddbMode`、编辑未存的模式翻转,都永远够不到真 AWS 的 DeleteTable。
- **L3 · 端点分级摩擦(唯一启发式层,只调摩擦不当安全边界)**:
  - **回环端点**(localhost / 127.0.0.0/8 / ::1 / host.docker.internal,归一化规则成文,localhost≡127.0.0.1≡::1)= 单弹窗,Enter 确认。
  - **非回环端点** = 同一个弹窗,追加琥珀横幅 `This endpoint is not loopback (ddb.shared.internal:8000) — it may be a shared environment` + 输表名 TextField(逐字符精确匹配前红按钮禁用)。
  - **爆炸半径自适应加码**(偷自 graduated-friction,仅非回环生效):DescribeTable 显示 ItemCount>100k 或表龄>30 天时,额外必勾 checkbox:`I understand this table has ~1.2M items and was created 214 days ago.`——测试表通常又小又新,摩擦随「这张表多像生产」而升。
- **L4 · saved-config 单一事实源 + dirty 锁**(见 A)。

**各级成本一览**:回环 = 1 击 + Enter;非回环 = 1 弹窗 + 输表名(大/老表再 +1 勾);AWS = 不可能。

**弹窗文案(逐字)**:

Recreate(回环):
> 标题:`Recreate table "redimos"?`
> 正文:`Deletes and recreates the DynamoDB table at http://127.0.0.1:8000 · ~3,204 items. All data in it is permanently lost.`
> `This will: stop 2 running configs that use this table (dev-a ●, dev-b ●) → delete the table → restart them. redimos recreates the table on startup with its official schema (v2 · Binary keys).`
> (若无依赖在跑:`…will start dev-a once so the table is created now.`)
> 按钮:`Cancel`(默认) / 红色 FilledButton `Recreate`(Enter 触发)

Delete(回环):
> 标题:`Delete table "redimos"?`
> 正文:`Deletes the table at http://127.0.0.1:8000 · ~3,204 items. It will not be recreated now. If a config with Auto-create table starts later, redimos will recreate it empty.`
> `Running configs using this table will be stopped and left stopped: dev-a ●.`
> 按钮:`Cancel` / 红色 `Delete table`

非回环 = 上述弹窗 + 琥珀横幅 + `Type the table name to confirm:` 输入框(+条件 checkbox)。

### D. 重建执行者(schema 权威)

**manager 只做 DeleteTable,永不 CreateTable。** 建表唯一权威 = redimos `-auto-create-table`(含对既有表的兼容性检查):schema 只有一份,活在将要使用这张表的那个二进制里,v1(String 键)/v2(Binary 键)自动跟随 config 所选版本,**漂移按构造不可能**。Recreate 时 manager 在重启命令行**一次性注入** `-auto-create-table`(不改持久配置、无需勾选框,偷自 hard-wall 原案——全场最佳 AutoCreate 人机工学);若无依赖在跑,启动本 config 一次让建表现在发生(弹窗已写明);用户不接受启动即用 Delete。

### E. 运行态处理

**绝不静默抽运行中代理脚下的表。**

- 依赖判定 = **归一化 endpoint(scheme+host+port,回环别名等价)+ table 相等**(归一化规则写入代码注释与文档,针对现有子串匹配隐患);只有 Endpoint 模式 config 可能命中(操作只存在于此)。
- 弹窗按名列出运行中依赖 + 绿色 live-dot,爆炸半径先于同意可见。
- 管线(复用 `restartLocalDdbDependents` 机架):记录在跑集合 → 全停 → `tableDelete`(内轮询 DescribeTable 至 ResourceNotFoundException,超时 15s)→(Recreate)重启恰好先前在跑的集合,首个带注入参数 →(Recreate)等 tableMeta ACTIVE。期间涉事 config 的 Start/Stop 禁用,模态 stepper 显示 `Stop → Delete → Start → Verify`。
- **事务化失败语义(偷自 workflow-first)**:删表失败 → 把停掉的依赖**全部重启,状态完全复原**并报错;删成功但重启失败 → config 卡红色 banner `table "redimos" was deleted; proxy failed to restart — start it manually to recreate` 并深链该 config 的 Logs 页,其余依赖仍尝试重启(诚实的部分失败面,无静默半态)。
- 完成后**落在已验证为空的 Table 页**(走既有 DescribeTable/tableMeta 通路)——循环以视觉证据收尾。Delete-only 后 Table 页显示 `table not found` 空态 + 提示 `Start the proxy with Auto-create table to recreate it`。
- 已知局限如实声明:manager 外(CLI/他机)启动的 redimos 不可见,删表后会自行报错。

### F. AWS 模式最终裁决

**彻底禁止,无任何解锁路径。** 依据:①manager 反正分不清测试/生产账号,任何门禁都是让用户自证,而声明无法证伪;②高频本地循环必然把任何确认仪式训练成肌肉记忆,唯独不存在的按钮点不穿;③真正的权限边界是 IAM,manager 的 AWS 侧职责到只读为止;④双层实施(UI 不存在 + native 按已保存 config 拒绝)使 UI bug 也非旁路。代价(测试 AWS 用户去 console/CLI)明知接受——那是砍功能,不是加错功能。**未来若确要放开**,前置条件(记录在案,不进 v1):per-config 解锁 bool 必须带 env-marker 的「mode/endpoint/region/credentials/table 任一字段修改即自动回锁」+ 「不随 config 复制传播」两条规则。

### store.json / 模型改动

**零。** 无新字段、无解锁标志、无 allowlist;`-auto-create-table` 注入是瞬态启动参数不落盘。无状态即无可misconfigure、无可迁移、无可被社工。

### native FFI 新增(仅名字)

- `tableDelete`(DeleteTable + DescribeTable 轮询至 not-found,内置 saved-config endpoint 非空守卫)——走 ddbtable.go 既有手搓 SigV4 `ddbCall` 通路,约 40 行,零新依赖。无其它新增(DescribeTable 证据行复用既有 `tableMeta`)。

## 4. 实施分期

| 期 | 内容 | 成本 |
|---|---|---|
| **P1 核心墙+主流程** | native `tableDelete` + L2 守卫;Table 页工具栏(红 Recreate + caret Delete / AWS 锁 chip);两个回环弹窗;停→删→重启管线(复用 restartLocalDdbDependents)+ 一次性参数注入 + 失败 banner | **M** |
| **P2 摩擦阶梯** | endpoint 归一化与回环分类成文实现;非回环琥珀横幅+输表名;dirty 编辑器锁;弹窗内 item count/表龄证据行 | **S** |
| **P3 打磨** | 侧栏右键入口;模态 stepper;删失败整组复原重启;完成后落地空 Table 页验证;爆炸半径自适应 checkbox | **S** |

## 5. 否决的路及原因

- **graduated-friction 的 AWS 解锁+仪式阶梯**:每层防线都是用户自觉,开关一开永不关,换上生产凭据那天仪式已被日常训练成惯性。
- **env-marker 三态环境标记**:新全局概念基本复述模式信号,付三处 UI+sharer 聚合+编辑器钩子的税,而错误的 Dev 声明无人能证伪。
- **workflow-first 的 allowAwsTableOps 开关**:自己都承认是「静默持久的上膛枪」,且纯 Flutter 门禁无 native 兜底。
- **WipeData(Scan+批删)**:本地被 Recreate 严格支配,唯一价值场景在墙外;为它搭进度回调管线是重成本弱收益。
- **manager 手搓 CreateTable**:schema 双份必漂移,v1/S 与 v2/B 的正确性只能由将运行的二进制决定。
- **放 Configure pinned action bar**:与红色 Delete config 相邻同色异义,误触陷阱。
- **确认倒计时**:纯剧场,只拦惯性连点,训练用户机械等 5 秒再点掉。
- **DynamoDB 资源 Tag 随表走的保护**:扩 API 面且依赖目标端支持,控制面收益不抵复杂度(env-marker 案内已自行砍掉)。

---

**一句话结论**:按 hard-wall 实施——墙就是刚落地的 Endpoint/AWS 开关本身,本地 1 击 + Enter 完成停→删→AutoCreate 重建一条龙,AWS 侧按钮不存在且 native 按已保存配置二次拒绝;schema 权威原封不动留在 redimos,store.json 零改动,native 只加一个 `tableDelete`。
