# PartiQL 页设计(参照 AWS DynamoDB 控制台「PartiQL editor」)

> 调研方式:2026-07-11 经 claude-in-chrome 实操控制台(us-east-1,深色主题),
> 完全逻辑图逐状态遍历。唯一未实证的边:写语句成功反馈(分类器拒绝向 AWS
> 真表写入,合理)——该形态在本实现中对本地表实测补齐。

## 控制台结构(实测)

### 1. 页头
`PartiQL editor` + 计费警示副文案(Operations … might incur charges. Learn more)。

### 2. 左侧「Tables (N)」树面板
- 工具:刷新 ↻ / 收起 < / `Find tables` 搜索 / 分页 / 齿轮。
- 表节点 ▶ 展开 = **仅键属性**(`pk — Partition key` / `sk — Sort key`)。
- **表级 ⋮ 菜单**(两组):`Run query → Scan table`(生成 SELECT 并立即可跑);
  `Add to editor → Query table / Table name / Set item / Drop item`(插入模板)。
- **属性级 ⋮ 菜单**:`Add to editor → Query table / Field name`。

### 3. 编辑器(多标签)
- 标签条:`Query 1` + **⋮ 标签管理**(TAB ACTIONS: New tab / Close all tabs
  [单标签时禁用];OPEN QUERY TABS: 列出打开标签)+ 全屏图标 + `+` 新建。
- 编辑器:行号、**语法高亮**(关键字紫/字符串橙)、右下 `行:列 PartiQL`
  指示、右上键盘快捷键图标。
- `Run`(**空语句禁用灰**,有语句橙色)+ `Clear`。
- 「Scan table」实测生成 `SELECT * FROM "redis-data-mgrtest"` 填入编辑器。

### 4. 结果区:Table view | JSON view 双态
- **状态行**:`✅ Completed` / `⊗ Failed`(红)+ `Started on <ts>` +
  `Elapsed time <N>ms`。
- **Table view**:`Items returned (N)` + `Download results to CSV` 按钮 +
  **`Find items` 客户端过滤框**(Explore items 没有的!)+ 分页 `< 1 >` +
  齿轮;网格列头带 ▽ 排序;**Binary 显示 base64**(控制台不明文化)。
  无复选框/无 Actions/无 Create item(纯结果展示)。
- **JSON view**:整个结果集一个 JSON 数组(行号 + 高亮,DynamoDB JSON 形态)。
- **错误横幅**(红):粗体 `An error occurred during the execution of the
  command.` + 换行 `<ExceptionType>: <message>`(实测 ResourceNotFoundException)。
- 写语句**直接执行无确认**(控制台行为;本实现改进:非 SELECT 弹确认)。

## 本实现(第 6 个 tab「PartiQL」,全英文 UI)

数据面:`rm_partiql`(ExecuteStatement:Statement + Limit + NextToken;
响应 Items[cellFromAV 复用,Binary 明文化增强] + NextToken + 耗时)。
错误原样透传 AWS 异常串,前端红横幅同款文案结构。

UI(lib/src/partiql_page.dart):
- 顶部工具卡:语句模板下拉(Scan table / Query table / Count / Insert item /
  Update item / Delete item —— 对应控制台表树菜单,按当前配置表与键 schema
  生成)+ Run(空禁用)/ Clear;
- 编辑器:多行等宽 TextField(语法高亮从简,保留行列指示);
- 结果:状态行(Completed/Failed + started + elapsed)、Items returned (N)、
  Find items 过滤、NextToken 分页(页码栈,支持后退)、网格(键列前置、
  Binary 明文 + base64 tooltip)、点行 DynamoDB JSON 弹窗、列偏好齿轮;
- **非 SELECT 确认对话框**(This statement can modify data…)——比控制台安全;
- 多标签/保存查询/CSV 下载 = v2(单标签先行)。

## 覆盖矩阵(控制台细节 → v1 处置)

| # | 控制台细节 | v1 处置 |
|---|---|---|
| 1 | 计费警示副文案 | N/A(本地/自担费用,省) |
| 2 | 表树面板(多表浏览/搜索/分页) | 等价:单配置单表 → 顶部表参考(表名+键)+ 模板下拉替代表级/属性级 ⋮ 菜单 |
| 3 | 表级 ⋮ Scan/Query/Set/Drop 模板 | ✅ 模板下拉(含 Count 增强) |
| 4 | 属性级 ⋮ Field name 插入 | 裁(编辑器直接敲更快) |
| 5 | 多标签 + 标签管理 ⋮ + 全屏 | 裁 → v2(单编辑器) |
| 6 | 行号/语法高亮/行列指示 | 部分:等宽+行列指示;高亮 v2 |
| 7 | Run 空禁用 / Clear | ✅ 同样 |
| 8 | Table/JSON view 双态 | ✅ 同样 |
| 9 | Completed/Failed + Started on + Elapsed | ✅ 同样 |
| 10 | Items returned (N) | ✅ 同样 |
| 11 | Download results to CSV | 裁 → v2 |
| 12 | Find items 客户端过滤 | ✅ 同样 |
| 13 | 分页 < 1 > (NextToken) | ✅ 同样(页码栈可后退) |
| 14 | 齿轮列偏好 | ✅ 同样(复用 Table 页 Preferences 模式) |
| 15 | 列头排序 | ✅ 同样(客户端) |
| 16 | Binary=base64 | ✅ **增强**:明文优先 + base64 tooltip |
| 17 | 错误红横幅(粗体标题+异常串) | ✅ 同样 |
| 18 | 写语句直接执行 | ✅ **增强**:非 SELECT 先确认 |
