> 审计方法:2026-07-11 用完整逻辑图法经 CGEvent 实操遍历本地 ARDM v1.7.1(连活 redimos :6379),
> 建 ardm-inventory 后跑 9 维度并行差距分析工作流(138 agent:每维产候选缺口→逐条对着真实源码
> 对抗式验证「真缺/redimos 可行/是否有意裁」→ 汇总排优先级)。128 候选,65 确认真缺口。
> 权威源码 = lib/src/browser_page.dart + lib/src/resp_client.dart;裁项依据 = doc/browser-page-design.md。

# ARDM 对齐差距报告 — Browser 标签

## 1. 结论摘要

我方 Browser 标签已覆盖 ARDM 数据浏览的**核心骨架**:命名空间树/扁平切换、glob 搜索(SCAN MATCH)、左栏 load-more 分页、五类型(string/hash/list/set/zset)的查看与增删改、TTL 显示/编辑、类型徽章、New Key 全流程——这些经核对均已真实落地且符合 redimos 约束。**真正的核心缺口只有两族**:(1) **键内分页**——hash/set/zset 一次性全量拉取(HGETALL/SMEMBERS/ZRANGE 0 -1)、list 硬截断在 1000 且静默丢数据,大键会卡死 UI 或隐瞒数据;(2) **键内关键字搜索**——四种集合详情表都没有过滤框。二者都是 redimos 完全可行(HSCAN/SSCAN/ZSCAN 均支持,搜索纯客户端),且都能在共享的 `_collectionCard` 上一处修复覆盖四类型,应最优先补。

---

## 2. P0 必补(核心浏览体验缺口)

| 功能 | ARDM 行为 | 我方现状 | redimos 可行性 | 修复要点 | 工作量 |
|---|---|---|---|---|---|
| **键内分页(hash/set/zset)** | 大键先加载 N 行,再 load-more 走 HSCAN/SSCAN/ZSCAN | `_openKey` 一次性 `hgetall`/`smembers`/`zrange 0,-1`(browser_page.dart:195-202),无窗口;大键淹没 RESP 解析器 + DataTable,UI 冻结 | ✅ HSCAN/SSCAN/ZSCAN 均在支持集内 | resp_client 新增 `hscan/sscan/zscan(key,cursor,{match,count})`(仿现有 `scan` 的 ScanPage);`_openKey` 只取首页,per-key 存游标,`_collectionCard` 加 "Load more"(仿左栏 :151-172/:346-355) | M |
| **键内分页(list)** | LRANGE 窗口翻页,任意大列表可逐页浏览 | `lrange(key,0,999)` 硬截断(:198),第 1000+ 元素**静默不可达**,比卡死更糟 | ✅ LRANGE start/stop 支持,绝对索引 LSET/LREM 仍正确 | `_openKey` case 'list' 改为窗口 `lrange(0,N-1)`,加 "Load more" 追加 `lrange(len,len+N-1)` | S |
| **键内关键字搜索(hash/list/set/zset)** | 各集合表头有 Keyword Search 框,原地过滤字段/值/成员 | 四类编辑器 + `_collectionCard` 均无过滤框;`_search`(:301)只过滤左栏键名。大 hash 全量倒进一张表时,搜索是唯一找字段的手段 | ✅ 纯客户端子串过滤,零服务端命令(Redis 本无 LSCAN,ARDM 亦客户端过滤) | 给 `_collectionCard` 加 stateful 过滤 TextField + per-key query;list 过滤须保留 `entry.key` 真实索引供 LSET/LREM。一处改覆盖四类型 | S |
| **Load Number 统一驱动键内页大小** | 同一 Load Number 既管 SCAN COUNT 也管集合每页行数 | 无键内分页可挂(见上);此项是上面分页落地后的收尾 | ✅ 同上 | 键内分页落地后,把页大小接到同一设置项(P2 收尾) | — |

> 注:zset 的 `DESC/ASC 方向切换`是设计文档明确的 v2 裁项,**不属于**此处 P0;P0 只是 zset 的"一次性全量加载"这半边(`zrange 0,-1` 无窗口)。

---

## 3. P1 建议补

| 功能 | ARDM 行为 | 我方现状 | redimos 可行性 | 修复要点 | 工作量 |
|---|---|---|---|---|---|
| **复制按钮(值/集合行/字段/键名/编辑框)** | String 值、每行、Edit 对话框、键右键都能一键复制 | 全文件从未 import `flutter/services`,无任何 `Clipboard` 调用;值虽可选中但无一键复制 | ✅ 纯客户端,与 redimos 无关 | `_row` 加可选 `onCopy` + copy IconButton;`_stringEditor`/`_formDialog` 各加 Copy;`_leaf` 加右键 Copy key name。一批 import 全解决 | S |
| **左栏 Load All(排空 SCAN)** | 红色 "load all" 循环 SCAN 至 cursor 0,载入整个键空间 | 只有单页 "Load more"(:346-355);设计文档 row 6 却承诺了 load all——是遗漏非裁项 | ✅ 复用 `_scanMore`/`page.done` 循环 | 加红色 "Load all" 按钮,确认后 `while(!_scanDone) await _scanMore()` | S |
| **键右键菜单(Copy / Delete)** | 键右键 → Copy/Delete/… | `_leaf` 只有 onTap;删除须先打开键再点头部红按钮 | ✅ Copy 客户端;Delete=DEL 支持 | `_leaf` 加 `onSecondaryTapDown`/`onLongPress` → showMenu(Copy name + Delete);`_deleteKeyDialog` 改成接受 key 参数。Open-in-new-tab/Export 按有意分歧略过 | S |
| **文件夹级批量删除(Scan & Delete Whole Folder)** | 文件夹右键批量删该命名空间下全部键 | `_Folder` 只有折叠 onTap,无菜单;无按前缀批删;此为我 UI 中该命名空间唯一的清库途径 | ✅ `scan(match:)` + `del()` 皆有,不碰 KEYS/RENAME | `_renderBranch` 透传累积前缀;文件夹加菜单,循环 `scan(match:'prefix*')` 分页 + `del()` 每键(**勿只删内存树叶**),完成后 `_reload` | M |
| **多选批量模式(键 + 文件夹子树)** | 勾选多键/整文件夹批量删/导出 | 选择态只有单个 `String? _selected`;无 checkbox/select-mode | ✅ 批删=循环 DEL;批量导出较软可缓 | 加 `bool _selectMode` + `Set<String> _checked` + 工具栏开关;select 模式 `_leaf` 显 Checkbox;底部批量条 Delete→确认→循环 del。批量导出留 v2 | M |
| **list 截断诚实告知 / 真实 LLEN** | ARDM 分页,任何元素不会无提示地被隐藏 | `lrange 0,999` 硬顶,`Total:N` 用截断后长度**说谎** | ✅ LLEN 是标准 3.2 读命令,不在禁用集 | 若上面 list 键内分页落地则自动解决;最小止血=加 `llen` helper + "Showing first 1000 of N" 横幅 | S |
| **list 头/尾插入(LPUSH/RPUSH)** | Add 时可选 push head/tail | 只有 `rpush`,无 `lpush` helper,头插无法做(设计文档 row 40 承诺了 LPUSH) | ✅ LPUSH/RPUSH 均支持 | 加 `lpush` helper;Add 对话框加 head/tail 切换 | S |
| **set 成员行内编辑(remove-old + add-new)** | set 行有 edit | 唯一缺 edit 的集合编辑器(hash/list/zset 都有) | ✅ srem+sadd 均支持 | `_setEditor` 给 `_row` 加 onEdit:先 `sadd(new)` 再 `srem(old)`(先增后删防丢) | S |
| **Edit/Add Line 多行值文本域** | Edit Line 值区是多行 textarea | `_formDialog` 值 TextField 无 minLines/maxLines,单行(app 已在 `_stringEditor` 证明有此能力) | ✅ 纯 UI,值含换行 redimos 无碍 | `_formDialog` 加可选 `maxLines`,值列 minLines:3/maxLines:12,字段/分数/键保持单行 | S |
| **多标签键工作区(A1)** | 每个打开的键=独立可关闭 tab,可同时开多键 | 单个 `_selected` + 一组扁平详情态,`_openKey` 覆盖式 setState,开第二个键即毁第一个;非裁项 | ✅ 纯客户端 UI/态,复用现有 per-key 命令 | 抽 `_KeyTab` 模型,`String? _selected`→`List<_KeyTab>+active`,`_openKey` 去重 push,右栏上方加可关闭 TabBar。ARDM 招牌工作流但单键浏览已能用,故 P1 非 P0 | L |

---

## 4. P2 / 已归 v2(不急)

**格式化 / 视图类(设计文档 row 13-14 明确 v2)**
- **多格式 formatter 下拉**(String S1 / 每行 </> / Edit 对话框):Hex/Msgpack/PHP/Java/Pickle/压缩等编解码;当前只 Text/JSON——已是 v2 裁项,DynamoDB 数据以 Text/JSON 为主,异型编解码边缘价值低。
- **JSON 可折叠语法高亮树**(S2):现为扁平 pretty-print SelectableText,已满足读 JSON 需求;彩色折叠树是同一 v2 formatter 工作的最富端。
- **头部 </> key 级视图按钮**(H6):inline Text/JSON 下拉已存在,头部按钮只会重复;富版属 v2。
- **Edit Line 值 formatter / Size 字节数显示**:纯装饰,单行短值编辑不受影响。

**排序 / 列类(与已裁的 zset DESC/ASC、list 行内移动同族)**
- **可点击排序列头**(hash Key/Value、list Value、zset Score/Member):数据已默认排序展示,重排是便利,与 v2 裁的 DESC/ASC 同桶。
- **索引/ID 列**(set `#`、zset `#`):list 已有 `#` 列,set/zset 是一致性装饰;set 的成员本身即标识,索引仅美观。

**便利/设置类**
- **折叠全部按钮**(L1):文件夹已可逐个折叠,树始终可导航。
- **叶节点按类型着色/图标**(L5):列表仅返回键名,着色一页 300 键=300 次串行 TYPE;打开键时头部已有类型徽章。
- **TTL 内联编辑 + ↺ 重置 + 实时倒计**(H3/H7):功能已全(对话框可改),仅呈现/每秒 tick 是装饰。
- **绿色刷新图标着色**(H5):功能已在,纯配色差异。
- **可配置命名空间分隔符**(L5/ST3,去重同一项):`:` 是压倒性约定,非 `:` 时扁平视图仍可浏览全部键;宿主在被裁的连接管理面。
- **持久化 Key Filter**(ST3):实时搜索框已提供等价能力,仅缺"记在连接上"的持久化。
- **Load Number 可配(SCAN COUNT)**(ST1):COUNT 是非绑定提示,300 vs 500 纯调优。
- **Hot Key 快捷键表**(ST4):鼠标已完全可用;可配置快捷键系统属设置面便利。
- **单键导出到文件**(O2/L7):备份/可移植性便利,一次性 SMEMBERS/LRANGE 本就全量,不使任何键不可用;比它更有用的是 Copy 按钮(已列 P1)。
- **Only Load Current Folder**(L8):等价能力已可用——搜索框输入 `prefix:*` 即可;仅缺一键填充。
- **文件夹内存分析**(L8):属被裁的 INFO/Memory 仪表盘族,且 redimos 上"内存"语义失真。

---

## 5. 有意分歧 / 不适用(非缺口,已明确考虑并排除)

**INFEASIBLE-ON-REDIMOS(命令被拒/语义不成立)**
- **键名内联重命名(H2 RENAME)**:redimos 拒绝 RENAME——只读键名是正确适配,非缺失。
- **Flush DB(FLUSHDB)**:redimos 注册但拒绝,只能 SCAN+DEL 模拟(DynamoDB 上非原子、慢、贵);且属被裁连接管理菜单。
- **Slow Query(SLOWLOG)**:redimos 是无状态 DynamoDB 代理,无 per-command 延迟环缓冲,无可读慢日志;且属被裁 INFO 诊断族。

**DIVERGENT-BY-DESIGN(架构选择,已在设计文档记录)**
- **连接工具条**:home 按钮、console(>_)、四宫格连接菜单(Close/Edit/Delete/Duplicate/Mark Color)、Import Key、Import CMD——本 tab 绑定单一 `widget.config` 直连,连接生命周期在 app 外层配置列表;CLI 在独立 Cmd 标签(共享 RESP 传输)。设计文档 row 1-2 明确裁。
- **DB 选择器(DB0-15)**:仅 `config.multiDb` 时显示——始终显 16 槽会在单逻辑键空间上呈现幻影库,门控才符合 redimos 语义。
- **New Key 需首个值 / 不建空键**:redimos/DynamoDB 无空集合键,必须 ≥1 元素才物化;我方在创建时内联写首值,ARDM 延后到详情编辑——UX 时序差异,我方更正确(且做得更多)。
- **hash 编辑锁定 Field**:字段重命名须非原子 HDEL+HSET,锁定值内联编辑是稳妥选择;可 v2 解锁。
- **Open In New Tab**:主从单选架构,每键仍完全可达,仅失同屏看两键。
- **INFO 仪表盘(A2)+ Auto Refresh(O1)+ 外观设置(暗色/语言/缩放/字体,ST2)**:属被 Monitor 页覆盖的仪表盘/app 级 chrome;DBSIZE=0 令 Key Statistics 失真。设计文档 row 3 明确裁。
- **regex/exact 搜索勾选框**:设计文档 row 5 明确 v2(SCAN MATCH 仅 glob,regex 需客户端后过滤)。

**ALREADY-PRESENT(核对确认已实现,非缺口)**
- 左栏:刷新按钮、New Key(键名+类型+首值)、glob 搜索框、命名空间树、文件夹 (count) 徽章、可折叠文件夹、树↔扁平切换、Load more。
- 键头部:类型徽章(TYPE)、TTL 显示(-1=No expiry)、删除键(红,且比 ARDM 多确认框)、刷新键。
- String:Size 字节数、多行 textarea + Save。
- Hash:Add 对话框、Total 计数、行内 edit、行内 delete。
- List:`#` 索引列、Add(RPUSH)、行内 edit(LSET)、行内 delete(LREM)。
- Set:Add(SADD)、行内 delete(SREM)、Total 计数。
- Zset:Add(ZADD)、行内 edit(改分数保成员)、行内 delete(ZREM)、score-edit 对话框。
- New Key 对话框:键名输入、类型下拉(String 默认)、Cancel/Create、创建后打开编辑器;Set 单值 Add、Zset score+member Add、Edit Line Cancel/OK。

---

## 6. 落地顺序建议(按 ROI)

1. **键内关键字搜索**(P0,S)——一处改 `_collectionCard` 覆盖 hash/list/set/zset 四类型,纯客户端零命令,收益立现。
2. **list 键内分页 + LLEN 诚实告知**(P0,S)——止住静默丢数据(最严重的正确性问题),LRANGE 窗口最简单。
3. **hash/set/zset 键内分页**(P0,M)——加 HSCAN/SSCAN/ZSCAN helper,复用左栏 load-more 模式,消除大键卡死。
4. **复制按钮全家桶**(P1,S)——一批 `flutter/services` import + `_row.onCopy`/`_formDialog`/`_stringEditor`/`_leaf`,广覆盖高频便利。
5. **键右键菜单(Copy + Delete)+ 左栏 Load All**(P1,S)——小改动补齐常用交互。
6. **set 行内编辑 + list 头/尾插入 + Edit Line 多行值**(P1,S)——补齐编辑一致性缺口。
7. **文件夹批量删除 + 多选批量模式**(P1,M)——清库能力,依赖前面分页/游标基建。
8. **多标签工作区(A1)**(P1,L)——招牌工作流,最大重构,放最后;可作为独立里程碑。

> 关键判断:第 1-3 步(两族核心缺口)决定"能否可靠浏览大键",是相对 ARDM 唯一实质性的 parity 差距;其余均为便利/装饰,不阻塞浏览。
