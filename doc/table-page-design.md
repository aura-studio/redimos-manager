# Table 页设计(参照 AWS DynamoDB 控制台「Explore items」)

> 调研方式:2026-07-10 经 claude-in-chrome 实操 AWS 控制台(us-east-1,
> 表 redis-data-mgrtest,深色主题),逐状态截图核实。本文是像素级参照的
> 文字化,Flutter 实现以此为准。

## 目标

给 manager 增加第 5 个标签页 **Table**(Configure / Monitor / Logs / Cmd / **Table**),
浏览当前配置指向的 DynamoDB 表(endpoint + credentials 沿用该配置)。
v1 **只读**(查询/浏览,不做 Create/Edit/Delete——防误伤;编辑留 v2)。

## 控制台原版结构(实测)

### 1. 页头
- 左:表名(粗体大字);右:`Autopreview` 开关 + `View table details` 按钮。
- 我们的对应:左侧表名 = 配置的 Table 字段;右侧放「Refresh」即可(不需要
  Autopreview——首次进入自动跑一次 Scan,与 Autopreview 等效)。

### 2. 「Scan or query items」折叠面板
- **Scan | Query** 两个 segmented radio 大卡片(选中态蓝边+深底)。
- `Select a table or index` 下拉(实测展开):顶部**搜索框** + 分组列表
  `Table → <name>` / `Index → idx`(redimos 表恒有 LSI `idx`:pk + skN,
  KEYS_ONLY)。v1:项目极少,省搜索框,保留分组。
- `Select attribute projection` 下拉(实测展开):**All attributes /
  Specific attributes** 两项;选 Specific 出现「Specific attributes to
  project」= 属性名输入 + `Add attribute` 按钮(可加多个,ProjectionExpression)。
  v1 两项都做。
- **Query 模式追加**:
  - `Partition key` 区:Attribute(只读显示键名 pk)+ Value 输入框;
  - `Sort key - optional` 区:Attribute(只读 sk/skN)+ 条件下拉 + 值输入
    + `Sort descending` 复选框;
  - 条件下拉全集(实测):`Equal to / Less than or equal to / Less than /
    Greater than or equal to / Greater than / Between / Begins with`
    (Between 时出现第二个值输入框)。
- **Filters - optional** 折叠区(Scan/Query 都有):每条过滤器 2×2 网格:
  `Attribute name`(输入)`Condition`(下拉)/ `Type`(下拉,实测 5 项:
  **String / Number / Binary / Boolean / Null**)`Value`(输入),右下
  `Remove`;底部 `Add filter`。
  Condition 下拉**实测 12 项全集**:`Equal to / Not equal to / Less than or
  equal to / Less than / Greater than or equal to / Greater than / Between /
  Exists / Not exists / Contains / Not contains / Begins with`。
  (Exists/Not exists 时无 Value 框;Between 双值框;Boolean 值为 true/false
  下拉;Null 类型无值框。)v1 **12 项全做**(FilterExpression 全支持)。
- 底部:**Run**(橙色主按钮)+ `Reset` 文字按钮。

### 3. 结果横幅(Run 后)
绿色成功条:`✅ Completed · Items returned: 20 · Items scanned: 20 ·
Efficiency: 100% · RCUs consumed: 2`,右侧 ×。失败时红条显示错误。
- 我们的对应:同款横幅;Efficiency = returned/scanned;RCU 本地 DDB 可能拿
  不到 ConsumedCapacity 就省略该段。

### 4. 结果卡片
- 标题:`Table: <name> - Items returned (N)`;
- 工具行:刷新圆钮 + `Actions ▾` + `Create item`(v1 只保留刷新);
- 时间戳:`Scan started on July 10, 2026, 20:46:08`;
- 右侧:分页 `< 1 >` + 齿轮(Preferences);
- **网格**:首列复选框(v1 可省)| 键列在前(`pk (Binary) ▾`,列头带类型
  斜体标注 + **▾ 客户端排序箭头**,对当前页排序,v1 做)| 其余属性自动
  发现补列;Binary 值显示 base64,pk 列渲染为链接(进条目页;v1 改为点行
  弹 JSON 查看)。空值格显示空白。**单元格悬停**出现内联小图标(实测):
  ⧉ 复制值 + ✏️ 快速编辑(v1 只读:保留 ⧉ 复制,裁 ✏️)。
- **分页语义**:DynamoDB 风格——用 LastEvaluatedKey 逐页取,页码只增不可
  跳(`<` 回缓存页,`>` 取下一页)。

### 5. Preferences 弹层(齿轮)
- `Page size` 单选:10 / 25 / 50(默认)/ 100 / 200 / 300;
- 右列:每个已发现属性一个开关(pk/sk/t/val…)+ `Select all / Deselect all`;
- 底部 `Cancel` / `Save changes`(橙)。

### 6. 条目查看(控制台是 Edit item 页,v1 做只读弹窗)
- 控制台:面包屑进独立页,右上 `Form | JSON view` 双态;
  - Form:表格 Attribute name | Value | Type | Remove + `Add new attribute ▾`
    + Cancel/Save/Save and close;
  - JSON view:`View DynamoDB JSON` 开关(on = 带类型 `{"B": "..."}` 形态)
    + `Copy` 按钮 + 行号语法高亮编辑器 + 底部状态条(Ln/Col/Errors)。
- 我们的 v1:点行弹 Dialog,标题 pk/sk,内容 = DynamoDB JSON(等宽字体,
  可选中),`Copy` 按钮;Form 态可省。

## 数据面(Go 侧,扩展 native/ddbinspect.go)

现有:SigV4 签名 + DescribeTable + Scan(Limit 20)。新增:

```
rm_table_meta(configJSON)   -> {keySchema:[{name,type}], lsi/gsi:[{name,keys}], err}
rm_table_page(reqJSON)      -> {items:[{attr:{type,repr}}], cols:[...], lastKey, // 透传下页
                                returned, scanned, timeMs, err}
```

- `rm_table_page` 请求:`{config, op:"scan"|"query", index:"", pkValue, skCond:{op,v1,v2},
  filters:[{attr,type,op,v1,v2}], limit, exclusiveStartKey, scanForward}`。
- 值编码:Binary 键接收 UTF-8 明文(内部转 bytes)——redimos 表的 pk 实际是
  可读串(如 `0:ci:6404`);展示层同时给 `repr`(可打印 UTF-8)与 `b64`。
  这一点**优于控制台**(控制台只给 base64,肉眼不可读)。
- 分页:请求/响应透传 ExclusiveStartKey/LastEvaluatedKey(JSON 原样)。
- Query 的 KeyConditionExpression 组装:`pk = :pk [AND sk <op> :v]`;
  begins_with/between 特殊形态;LSI idx 时 sort key = skN(N 型)。

## Flutter 侧(lib/src/table_page.dart,新文件)

- Tab 数组加 `Table`(icon: Icons.table_chart,`_tab('Table')`),TabController
  length 4→5;`AutomaticKeepAliveClientMixin` 保状态。
- 布局(全部适配现有深/浅主题,复用 _tileColor 等):
  1. 折叠卡「Scan or query items」:SegmentedButton(Scan/Query)+ 索引下拉
     + Query 条件区 + Filters 列表 + Run(FilledButton)/Reset;
  2. 结果横幅(绿/红,可关);
  3. 结果卡:标题行(Items returned (N) + 刷新 + 分页 + 齿轮)+
     水平滚动 DataTable(列自动发现,键列前置,Binary 列显示 repr,
     tooltip 给 base64)+ 点行弹 JSON Dialog;
  4. Preferences Dialog:page size 单选 + 列开关。
- 状态:每配置独立(keyed by config id);切配置重置。

## 弹窗/浮层全集(逐个实操核实)

| 弹窗 | 实测细节 | v1 处置 |
|---|---|---|
| Preferences(齿轮) | Page size 6 档单选 + 每列开关 + Select all/Deselect all + Cancel/Save changes(橙) | ✅ 同样 |
| Actions ▾ 菜单 | 5 项:`Edit item / Duplicate item / Delete items / Download selected items to CSV`(需选中,未选中禁用灰)+ `Download results to CSV`(常可用);选中 N 条时结果标题变 `(N/20)`,表头复选框半选态 | 裁(写操作);Download results to CSV 只读,v1.1 候选 |
| Delete item(s) 确认弹窗 | 标题 `Delete item` + ×;正文 `Delete 1 item from the <table> table? This action cannot be reversed.` + 警示插画;`Cancel` / `Delete`(橙) | 裁(写操作) |
| 单元格 ✏️ 快速编辑 | **键属性**(pk/sk)点 ✏️ 弹提示浮层:`Edit Sort key — You can't edit Sort key inline. To edit it in the item editor, choose Edit.` + Cancel/Edit(橙);部分列(如 t)悬停只有 ⧉ 无 ✏️ | 裁(写操作);⧉ 复制保留 |
| Create item 页 | Form 态:pk/sk 预填行(`Empty value` 占位,类型列 Binary);JSON 态:预填键骨架 `{"pk":{"B":""},"sk":{"B":""}}`;底部 Cancel / Create item(橙) | 裁(写操作) |
| Add new attribute ▾ | 类型 10 项:`String / Number / Boolean / Binary / Null / String set / Number set / Binary set / List / Map` | 裁(写操作,v2 编辑用) |
| 条目页 Form\|JSON 双态 + View DynamoDB JSON + Copy | (前文已述) | JSON 态进 v1(只读 Dialog) |

> 结论:控制台的弹窗全部服务于**写操作**(除 Preferences),v1 只读版需要
> 的弹窗仅两个:Preferences + 条目 JSON Dialog,均已在方案内。

## 覆盖矩阵(控制台 UI 细节 → v1 处置,逐项)

| # | 控制台细节(全部实测核实) | v1 处置 |
|---|---|---|
| 1 | 左侧表选择侧栏(tag 过滤/搜索/收藏星/分页/齿轮) | **N/A**:Table 页绑定当前配置的表,无需选表 |
| 2 | 页头表名 | ✅ 同样(取配置 Table 字段) |
| 3 | Autopreview 开关 | ✅ 等价:进页自动跑一次 Scan(无需开关) |
| 4 | View table details 按钮 | **裁**:表详情已由 Configure/Monitor 覆盖 |
| 5 | 面包屑 / Info 帮助链接 | **N/A**(标签页上下文) |
| 6 | Scan \| Query segmented 卡片 | ✅ 同样(SegmentedButton) |
| 7 | 表/索引下拉(搜索框+Table/Index 分组) | ✅ 同样(分组保留;搜索框省——只有 2 项) |
| 8 | 投影下拉 All / Specific attributes(+Add attribute) | ✅ 同样(两项都做,ProjectionExpression) |
| 9 | Query:Partition key(键名只读+Value) | ✅ 同样 |
| 10 | Query:Sort key 条件 7 操作符 + Between 双值 + Sort descending | ✅ 同样(7 项全做) |
| 11 | Filters:Attribute/Condition/Type/Value + Remove + Add filter | ✅ 同样 |
| 12 | Filter Condition 12 项全集 | ✅ 同样(12 项全做) |
| 13 | Filter Type 5 项(S/N/B/BOOL/NULL) | ✅ 同样 |
| 14 | Run(橙主按钮)+ Reset | ✅ 同样 |
| 15 | 结果横幅(returned/scanned/Efficiency/RCU + ×) | ✅ 同样(RCU 本地拿不到时省略该段) |
| 16 | 结果标题 `Table: <name> - Items returned (N)` + 时间戳 | ✅ 同样 |
| 17 | 刷新圆钮 | ✅ 同样 |
| 18 | Actions ▾(Export CSV / Delete items / Duplicate) | **裁**(写操作);Export CSV 只读,列入 v1.1 候选 |
| 19 | Create item 按钮 | **裁**(v1 只读) |
| 20 | 分页 `< 1 >`(LastEvaluatedKey 逐页) | ✅ 同样 |
| 21 | 齿轮 Preferences:Page size 6 档 + 列开关 + Select/Deselect all | ✅ 同样 |
| 22 | 网格:键列前置、列头类型标注、属性自动发现、空格空白 | ✅ 同样 |
| 23 | 列头 ▾ 客户端排序 | ✅ 同样(当前页排序) |
| 24 | 单元格悬停 ⧉ 复制 / ✏️ 编辑 | ✅ ⧉ 复制保留;✏️ 裁(只读) |
| 25 | 首列复选框(批量选择,服务于删除/复制) | **裁**(服务于写操作) |
| 26 | 列宽拖拽调整 | **裁**(Flutter DataTable 无原生支持;自动列宽) |
| 27 | pk 值为链接进条目页 | ✅ 等价:点行弹条目 Dialog |
| 28 | 条目页 Form \| JSON view 双态 | ⚠️ v1 只做 JSON 态(只读;Form 态属编辑,v2) |
| 29 | JSON 态:View DynamoDB JSON 开关(带类型/普通 JSON) | ✅ 同样(Dialog 内开关) |
| 30 | JSON 态:Copy 按钮 + 行号/高亮/状态条 | ✅ Copy + 等宽可选中;行号/高亮简化(只读无需纠错) |
| 31 | Binary 值显示 base64 | ✅ **增强**:明文优先(可打印 UTF-8),tooltip/切换给 base64——redimos 表刚需 |

裁剪项全部集中在**写操作**(18/19/24✏️/25/28-Form)与**平台限制**(26)两类;
其余 UI 细节 v1 全部对齐或等价。

## 验证清单

- local-ddb 配置(LocalStack :8079,表 redis-data-4,B 键)Scan 首页/翻页;
- Query:pk=`0:ci:6404`(明文输入)命中;sk begins_with;
- Filters:t = "str" 过滤;
- 断后端 → 红条错误横幅;
- 深/浅主题 + 窗口/全屏截图各一轮。
