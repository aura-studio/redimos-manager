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
- `Select a table or index` 下拉:`Table - <name>` / 各 LSI/GSI
  (redimos 表恒有 LSI `idx`:pk + skN,KEYS_ONLY)。
- `Select attribute projection` 下拉:All attributes / Projected attributes
  (v1 可省:恒 All)。
- **Query 模式追加**:
  - `Partition key` 区:Attribute(只读显示键名 pk)+ Value 输入框;
  - `Sort key - optional` 区:Attribute(只读 sk/skN)+ 条件下拉 + 值输入
    + `Sort descending` 复选框;
  - 条件下拉全集(实测):`Equal to / Less than or equal to / Less than /
    Greater than or equal to / Greater than / Between / Begins with`
    (Between 时出现第二个值输入框)。
- **Filters - optional** 折叠区(Scan/Query 都有):每条过滤器 2×2 网格:
  `Attribute name`(输入)`Condition`(下拉)/ `Type`(String/Number/Binary/
  Boolean/Null 下拉)`Value`(输入),右下 `Remove`;底部 `Add filter`。
  Filter 条件集比 sort key 多 `Not equal to / Exists / Not exists / Contains /
  Not contains` 等(v1 先做 = ≠ begins_with contains exists/not exists)。
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
  斜体标注)| 其余属性自动发现补列;Binary 值显示 base64,pk 列渲染为
  链接(进条目页;v1 改为点行弹 JSON 查看)。空值格显示空白。
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

## 验证清单

- local-ddb 配置(LocalStack :8079,表 redis-data-4,B 键)Scan 首页/翻页;
- Query:pk=`0:ci:6404`(明文输入)命中;sk begins_with;
- Filters:t = "str" 过滤;
- 断后端 → 红条错误横幅;
- 深/浅主题 + 窗口/全屏截图各一轮。
