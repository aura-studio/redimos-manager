# pixel-diff — v2.3 像素级逼近验收管线

spec: `.kiro/specs/pixel-fidelity-v23/`（requirements / design / tasks）

对 8 屏（实例 6 + 端点 2）做分区像素 diff：Puppeteer 截 mockup HTML、
`flutter test` 截 Flutter 渲染，pixelmatch 出全屏 + 4 ROI 差异率、色彩断言、热力图与 `report.md`。

## 环境前置（结果仅对生成机有效）

- macOS（字体回退 PingFang SC、Skia 渲染管线均按本机）
- node v26.5.0 / npm 11.17.0（`/usr/local/bin/node`）
- flutter 不在 PATH，脚本内自行 `export PATH="$HOME/flutter/bin:$PATH"`
- 依赖锁精确版本：`pixelmatch@5.3.0`、`pngjs@7.0.0`、`puppeteer@25.5.0`
- Chrome for Testing **151.0.7922.71**（puppeteer bundled，位于 `~/.cache/puppeteer/chrome/`；
  若 postinstall 被 allow-scripts 拦截，用 `npx puppeteer browsers install chrome` 补装）

## 一键命令

```bash
npm run validate          # 校验 mockup 源（8 屏 allowlist，缺失即报错退出）
npm run capture:mockup    # Puppeteer 截 8 屏 → out/mockup/*.png（2560×1600）
npm run capture:flutter -- 1  # 运行号 1：截 8 屏×双主题 → active captures/run-1/（2560×1600）
npm run diff              # 四类判据 → out/report.md + 热力图 out/diff/*.png
```

## 判据（requirements 3.x）

| 类型 | 标准 |
| --- | --- |
| 几何 | 关键盒模型位置/尺寸偏差 ≤ 1px |
| 色彩 | 纯色采样点 RGB 逐通道相等（容差 0） |
| 文本区 | 全屏 diffRatio ≤ `THRESHOLDS.text`（CP 8.4 校准：max(噪声地板×2, 3%)） |
| ROI | rail / midBar / cardHead / tableHead 各自 ≤ 局部阈值 |

pixelmatch 固定参数：`threshold: 0.15`、`includeAA: false`。
两侧尺寸必须都是 2560×1600，不等则直接判失败（不 pad 不裁切）。

## 目录

```
config.js          唯一配置：路径/allowlist/视口/ROI/阈值
capture-mockup.js  Puppeteer 截图（注入字体与禁动画样式，不改 mockup 原件）
capture-flutter.sh 双主题 Flutter capture + 不可覆盖 run 目录
diff.js            对比 + report.md
out/{mockup,flutter,diff}/  截图与热力图
out/report.md      汇总报告（含 hostname/字体 hash/Chrome 版本）
reference-manifest.schema.json  Codex active reference 的可审阅 JSON Schema
reference-manifest.js           manifest 解析、路径隔离与严格验收校验器
reference-manifest.test.js      仅使用系统临时目录的 manifest 单元测试
active-diff.js                  manifest 驱动的 Codex active 多维比较器
active-diff.test.js             指标、隔离、阈值与失败证据单元测试
noise-floor.js                  三轮同源 capture 的最大 pairwise 噪声测量器
noise-floor.test.js             噪声计划、provenance、聚合与阈值约束单元测试
archive-v23.test.js             临时仓库中验证完整归档、校验和、只读与拒绝覆盖
```

## Codex reference manifest

Codex reference 与本页上方的 v2.3 历史管线相互隔离。`v2.3-archive/` 只保存历史证据，不能作为 active reference，也不能被 manifest 路径间接引用。

校验器提供两种模式：

- `draft`：允许 9.3 阶段逐步建立候选槽位，不要求文件存在或已批准；仍校验字段、screen/theme 与文件唯一性、ROI 边界、命名和 archive/path traversal 隔离。16.2 起额外接受六个 capture-only Service 屏（`svc-empty`、`svc-overview-running`、`svc-overview-failed`、`svc-monitor`、`svc-logs`、`svc-configure`）作为候选条目；它们没有 approved reference，永远不能进入验收基线。
- `acceptance`（默认）：要求八屏 × light/dark 共 16 个唯一条目全部为 `approved`，viewport 为 1280×800、DPR 2，PNG 为 2560×1600，文件位于 active manifest root 内，并有包含 reviewer 与 rendering environment 的批准历史。Service capture-only 条目会因覆盖检查被拒绝。

```bash
npm run test:manifest
```

对候选 manifest 做结构校验：

```bash
npm run validate:manifest -- --draft path/to/manifest.json
```

对已批准 manifest 做严格验收校验：

```bash
npm run validate:manifest -- path/to/manifest.json
```

校验器只读文件并报告全部已发现的问题；不会创建、批准、bless 或覆盖 reference/capture。

初始化 8×2 候选槽位（仅首次运行；若 manifest 已存在会拒绝覆盖）：

```bash
npm run init:references
```

默认目录为 `visual-evidence/active/codex-v1/`。初始化器只创建 `candidate` manifest 和 `references/`、`captures/`、`reports/` 空目录占位，不生成 PNG，也不包含自动批准入口。三个输出目录默认忽略其生成内容，避免候选 capture、reference 或失败报告被误纳入提交。

## Codex active comparison

active comparator 与 legacy `diff.js` 完全隔离，只接受显式路径，不递归搜索 reference、capture 或 archive：

```bash
npm run diff:active -- \
  --manifest visual-evidence/active/codex-v1/manifest.json \
  --run visual-evidence/active/codex-v1/captures/run-1
```

CLI 始终以 `acceptance` 模式加载 manifest；任一 reference 仍为 `candidate`、缺少批准 history/reviewer、缺少 16 项覆盖、文件/尺寸/路径不合法时都会 fail closed。无阈值时只输出 metrics，`passed` 为 `null`，不会创建报告、批准 reference 或复制 capture。

每个 screen/theme 输出：

- `fullFrameDiffRatio = differingPixels / comparedPixels`；
- manifest 每个 ROI 的独立 diff ratio；重叠 ROI 不影响全局计算；
- 每个 ROI 的 `r/g/b/a` normalized MAE；
- ROI 矩形四边锚点推导的逻辑像素 `x/y/width/height` 偏差与最大偏差。画布边界由已验证尺寸确定；内部边缘不可辨识时会明确记录，并在启用 geometry 阈值时失败。

9.6 完成噪声测量与最终 manifest 阈值结构前，若需要测试阈值判定，只接受显式批准且绑定 `referenceVersion` 的阈值信封；不能传裸数字，也不能沿用 v2.3 的 3%：

```json
{
  "schemaVersion": 1,
  "referenceVersion": "codex-v1",
  "approval": "approved",
  "reviewer": "reviewer-id",
  "reason": "derived from documented three-run noise measurement",
  "approvedAt": "2026-08-12T00:00:00.000Z",
  "metrics": {
    "fullFrameDiffRatio": 0.001,
    "roiDiffRatios": {"railSidebar": 0.001, "topBars": 0.001, "detail": 0.001, "statusbar": 0.001},
    "maxGeometryDeviationPx": 1,
    "channelMAE": {"r": 0.001, "g": 0.001, "b": 0.001, "a": 0}
  }
}
```

```bash
npm run diff:active -- \
  --manifest visual-evidence/active/codex-v1/manifest.json \
  --run visual-evidence/active/codex-v1/captures/run-1 \
  --thresholds path/to/approved-thresholds.json
```

任一 full-frame、ROI、geometry 或 channel 指标超限即退出失败，并在 `reports/run-N/` 以 `<screen>-<theme>-{expected,actual,diff,metrics}` 唯一命名保留四件套。同一 run 已存在失败报告时拒绝覆盖；工具从不写入 `references/`。

## Codex noise-floor measurement

9.6 使用 manifest 明确列出的 `captures/run-2`、`run-3`、`run-4`，不扫描目录，也不改写保留的 schema v1 `run-1`。每个新 run 必须包含 28 张 2560×1600 PNG（8 个 golden 屏 + 6 个 capture-only Service 屏，各 light/dark，16.2 起）和 schema v2 metadata；metadata 记录 build、全部 Dart fixture、实际字体、Flutter/platform、viewport 与 physical size provenance。三轮这些字段必须完全一致，否则测量拒绝执行。

依次创建不可覆盖的同源 capture：

```bash
npm run capture:flutter -- 2
npm run capture:flutter -- 3
npm run capture:flutter -- 4
```

随后计算每个 screen/theme 的全部 run pair，并分别保留 full-frame diff ratio、各 ROI diff ratio、geometry deviation 与各 RGBA channel normalized MAE 的最大实测值及来源 run pair：

```bash
npm run measure:noise -- --manifest visual-evidence/active/codex-v1/manifest.json
```

报告排他写入 manifest 声明的 `reports/noise-floor-runs-2-4.json`，已存在时拒绝覆盖。测量完成后，manifest 的 `measured` 状态必须以 `reportSha256` 绑定该普通文件，并校验其 referenceVersion、runNumbers、threshold policy、pending approval 与 legacy exclusion 语义；缺失、替换、symlink 或内容篡改均 fail closed。报告只建立 `strictly-greater-than-measured-noise` 下界：未来 threshold proposal 必须绑定同一报告 SHA-256、逐项严格大于实测地板并记录正 margin 和理由。它不会导入 legacy v2.3 的 3%，不会批准 threshold/reference，也不会把 candidate reference 复制或 bless 为 acceptance；独立审核前 `thresholdApproval` 始终保持 `pending`。

运行全部 archive/manifest/capture/active/noise 工具测试（均使用临时目录，不修改 active reference 或已归档证据）：

```bash
npm run test:tools
```
