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
npm run capture:flutter   # flutter test 截 8 屏 → out/flutter/*.png（2560×1600）
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
capture-flutter.sh flutter test 侧 capture
diff.js            对比 + report.md
out/{mockup,flutter,diff}/  截图与热力图
out/report.md      汇总报告（含 hostname/字体 hash/Chrome 版本）
```
