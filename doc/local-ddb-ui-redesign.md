> 调研方法:2026-07-11 先实勘现状(scratchpad/ddb-facts.md:全局单例/URL 子串匹配依赖/
> dock UI/FFI 面),再跑 judge-panel 工作流——4 个独立设计视角(per-config 并进 Configure /
> unified-list 统一列表 / infra-layer 基础设施层 / minimal-change 最小改动)× 3 评委
> (架构诚实度 / UX 清晰度 / 成本风险)交叉打分 → 合成。**只调研,未动代码。**

# Local DynamoDB 面板重构调研报告

## 1. 问题定性

突兀感有确切的结构根源,不是审美偏好:Local DynamoDB 是**被依赖的全局后端**,却披着「第 N 个实例」的外衣挤在 redimos 实例列表的视觉容器底部——实体类型错位;同时 config 与它的依赖关系只靠 endpoint URL 子串匹配(`configUsesLocalDdb` 匹配 `localhost:8079`)隐式成立,Configure 页看不出任何关联,用户要手敲 URL 去「碰巧命中」;停它会连坐重启/断掉所有依赖者,UI 却零提示。dock 的样式怪只是症状,**实体身份不明 + 依赖不可见 + 生命周期语义混淆**才是病灶。

## 2. 四个方向对比表

| 方向 | 核心做法 | 优点 | 硬伤 | 成本 | 评委总分(架构/UX/成本风险) |
|---|---|---|---|---|---|
| **unified-list**(统一列表) | 删 dock,DDB 成为侧栏置顶 pinned tile(独立 LOCAL BACKEND 小节,同 config tile 语法),选中即右栏切换为它自己的 Configure/Monitor/Logs 三 tab;config 加显式 `useManagedDdb` | 最直接治愈突兀感(同一视觉语法+独立小节);引擎控制面获得完整页面;依赖集合单一函数供 3 处 UI 复用 | `'__ddb__'` 哨兵要穿透 `_selected`/`_confirmLeaveEditor`/共享 7-tab TabController,回归面在全 app 最核心的选中脊柱上;stop 图标统一让重操作显轻 | M(偏高) | **22**(8/8/6) |
| **minimal-change**(最小改动) | dock 不搬家,加 BACKEND 分区头+底色脱离实例列表;Configure 加托管开关锁定派生 Url;显式 `useLocalDdb` flag 替换子串匹配;停止确认+连坐 toast | 架构最诚实(单一写面/单一 flag/spawn 派生 endpoint/子串匹配有落日计划);一天内完成;零回归风险;全部工作是其他方向的前置 | dock 物理上还在原地——若突兀感是空间性的只能缓解约 70%,对用户明说的诉求回应最弱 | S+ | **22**(9/5/8) |
| **infra-layer**(基础设施层) | 侧栏底部设 BACKENDS 分区,backend tile+独立详情页;config 存 `backendId`;运行时仍靠子串匹配,v1 零 Go 改动 | Dependents 卡片是四案中对多对一关系最好的表达;v1 不碰级联逻辑,迁移最安全 | 双事实源(backendId=UI 真相 vs 子串=运行时真相)永久漂移风险;端口变更批量重写他 config 的 endpoint 是最吓人的写路径;复数 BACKENDS+禁用「+」是 FFI 撑不起的仪式;tile 还在被嫌弃的位置 | M | **18**(5/7/6) |
| **per-config**(并进 Configure) | 删 dock,Configure 第 4 区加 Source 三选,Managed 时内嵌标注 GLOBAL 的共享引擎卡 | 字面满足用户的「合并进 Configure」;Source 三选建模最完整 | 全局活控制台嵌进 N 个局部延迟保存表单——所有权说谎,在 A 页改端口静默重启 B/C;孤儿态兜底条=dock 借尸还魂;一页两种交互模型 | M | **17**(6/6/5) |

## 3. 推荐方案

**推荐 unified-list 作为终态方向**,并吸收三个败者的最佳部件。理由:它是唯一同时治愈实体错位(独立小节+同语法 tile)和给引擎完整控制面的方向;UX 评委判定它最对症(突兀感来自 dock 的异类视觉语法);架构分仅次于 minimal-change 且差距来自可修的细节。minimal-change 虽同分,但它自己承认对用户明说的诉求只能缓解 70%——不能把「可能不解决问题」的方案当终态。它的全部架构工作(flag、spawn 派生)被收编为本方案的 Phase 1。

### 终态 UI(逐面描述)

**侧栏**:删除 `main.dart:1875` 起的 `LocalDdbPanel` dock。「New config」按钮下方、config 列表上方,新增一个 **pinned 的 LOCAL BACKEND 小节**(11px 大写 overline 标签):一个与 `_configTile` 同高同语法的 DdbTile——leading 为圆角方形 `Icons.storage` avatar(状态点缩为右下角 8px 角标,与 config 的裸状态点区分实体类型),title「Local DynamoDB」,subtitle「java·persist · :8079 · 3.2% · 412MB」,末尾「⛓ 3」依赖徽章(hover 列名单),trailing 与 config 同款 play/stop 按钮。tile 常驻 `surfaceVariant` 淡染底色。config 列表原样 `Expanded` 到底,底部再无任何 dock。

**DDB 详情页(选中 tile 时)**:右栏沿用同一条 50px TabBar 骨架,换成 3 个 tab——
- *Configure*:engine 三选 × storage 二选 + Port + DataDir/Volume + 「Auto-start with app」开关(收编顶层 `ddbAutoStart`);页首放 **Dependents 卡片**(偷自 infra-layer):每个依赖 config 一行,状态点+名字,整行可点跳选该 config;
- *Monitor*:现 MonitorView 中 LOCAL DYNAMODB 分区(CPU/Mem/Disk sparkline + Engine/Health tiles)升格整页,数据源 `_ddbCpuHist` 等已存在;
- *Logs*:`rm_ddb_logs` 从 720×420 模态对话框升格为与 config LogsView 同款的全页终端面板。

**Configure 页 DYNAMODB 区(per-config)**:区头右侧放**三段 SegmentedButton:Managed local | Custom URL | AWS**(偷自 per-config,比布尔开关建模完整)。Managed 时 Url 字段变为只读派生 chip「http://localhost:8079(由共享引擎派生)」+ 尾部 link 图标「查看 Local DynamoDB →」(点击即选中 DdbTile),凭据字段预填 dummy 折进 Advanced 折叠;Custom/AWS 时维持现状自由编辑。老 config 的 endpoint 子串命中但未声明托管时,显示一键收编 chip「检测到指向本地 :8079 — 切换为托管?」(偷自 infra-layer,迁移靠用户确认而非静默改写)。

**Monitor 页(per-config)**:原 LOCAL DYNAMODB 大分区缩成单行健康条「Local DynamoDB · Running · :8079 · 查看 →」,消除双份 sparkline。

**生命周期(偷自 minimal-change)**:停 DDB 且有运行中依赖者时,确认对话框**按名字列出**(非计数):[连带停止全部] / [仍然停止] / [取消];DDB 重启触发 `restartLocalDdbDependents` 时弹 toast「Local DynamoDB restarted — N 个依赖配置正在重启」,把今天完全静默的连坐说出声。

### 依赖联动修法(替代 URL 子串匹配)

`RedimosConfig` 新增显式字段 `ddbSource: managed|custom|aws`(store.json `configs[]` 每项 additive 新增,顶层 `localDdb`/`ddbAutoStart` 结构不动)。**managed 时 endpoint 不再是存储值,而是 spawn 时由 native 从当前 `LocalDdbConfig.port` 实时派生**(偷自 minimal-change 的关键决策)——改端口自动对全部 managed config 生效,根治「dock 改 8079→8080 所有手敲 Url 瞬间静默断链」;明令禁止「批量重写各 config 存储的 Url 字符串」这个懒变体,那等于把派生值又变回会漂移的副本。native 侧 `configUsesLocalDdb`/`restartLocalDdbDependents`/`afterDdbReady` 只换判定谓词为 `ddbSource==managed`,子串匹配降级为迁移期 fallback 并**保留一个版本后删除**(落日计划)。依赖徽章、Dependents 卡片、停止确认名单三处 UI 读同一个依赖集合函数(偷自 unified-list 自身的单一事实源纪律)。FFI 面(`rm_ddb_get/set/start/stop/logs` 全局无参)零改动。

## 4. 分期落地

**Phase 1 — 治突兀 + 修架构债(成本 S+,约 1~2 天,零核心回归面)**
1. `ddbSource` 字段打通:Dart model + Go struct + store.json + spawn 时派生 endpoint;native 判定谓词替换,子串匹配作 fallback(S)。
2. 侧栏改造:删除 dock,DdbTile + LOCAL BACKEND 小节移到列表顶部 pinned 位(tile 本身是现 dock 折叠行的重排,不做详情页;展开控制暂保留现有展开态或 Logs 对话框)(S)。
3. 停止确认对话框(按名列出运行中依赖者)+ 连坐重启 toast(S)。
4. Configure 页一键收编 chip(迁移入口)(S)。
Phase 1 结束时:dock 消失、实体类型在视觉上归位、依赖显式化、级联行为发声——突兀感的三个根源全部消解,且没碰选中模型和 TabController。

**Phase 2 — 完整详情页与编辑器整合(成本 M)**
1. `'__ddb__'` 哨兵选中贯通 `_selected`/`_confirmLeaveEditor`,第二个 TabController(或索引钳制),DDB 三 tab 详情页(Configure 含 Dependents 卡片 / Monitor 整页 / Logs 全页)——Monitor 与 Logs 大量复用现组件(M)。
2. Configure 页 DYNAMODB 区三段 Source 选择器 + 只读派生 chip + Advanced 凭据折叠(S~M)。
3. per-config Monitor 的 DDB 分区缩为单行健康条(S)。
4. 删除子串匹配 fallback(下一个版本)(S)。

## 5. 不推荐的路及原因

- **per-config(并进 Configure)**:字面服从了用户、实质背叛了单例——全局活控制台复制进 N 个延迟保存表单,在 A 页改端口静默重启 B/C,孤儿态兜底条是 dock 以最费解的形态还魂;其 Source 三选已被本方案偷走。
- **infra-layer(BACKENDS 基础设施层)**:双事实源(backendId vs 子串)需要永久调解规则,端口变更批量重写他人 endpoint 是全部提案里最危险的写路径,复数 BACKENDS+禁用「+」是硬全局 FFI 撑不起的谎言;其 Dependents 卡片与收编 chip 已被偷走。
- **minimal-change 作为终态**:架构分最高但对用户明说的诉求回应最弱(dock 原地不动,自认只缓解 70%);它不是被否决而是被降格——其全部内容就是本方案的 Phase 1。
