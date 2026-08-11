# 噪声地板（CP 8.1–8.3，2026-08-08 校准）

同一构建（第 7 章末，HEAD 未提交工作区）连跑 3 个「重截 capture + diff」周期。
**噪声地板语义**：run 间波动（max−min），不是绝对 diffRatio——绝对值含两通道结构性差异
（capture 无 app chrome、loaded 数据态装饰等），那是第 9 章的收敛对象，进阈值会使判据空转
（design.md L92 意图：阈值要能抓住 0.1–0.5% 的单边框/图标位移）。

## 全屏 diffRatio ×3（像素精度）

| screen | run1 px | run2 px | run3 px | spread px | spread % |
| --- | --- | --- | --- | --- | --- |
| inst-browse | 380351 | 380351 | 380351 | 0 | 0.0000 |
| inst-console | 358226 | 358291 | 358345 | 119 | 0.0029 |
| inst-monitor | 349085 | 349085 | 349085 | 0 | 0.0000 |
| inst-logs | 336334 | 336334 | 336334 | 0 | 0.0000 |
| inst-playground | 314357 | 314357 | 314357 | 0 | 0.0000 |
| inst-config | 458336 | 458336 | 458336 | 0 | 0.0000 |
| ep-overview | 353997 | 353975 | 353957 | 40 | 0.0010 |
| ep-browser | 322506 | 322506 | 322506 | 0 | 0.0000 |

## ROI diffRatio ×3（报告 2 位精度）

8 屏 × 4 ROI 全部 run 间 spread = 0.00（rail 92.42–96.01%、midBar 17.40–24.64%、
cardHead 2.29–7.79%、tableHead 0.33–7.18% 均为结构性常数，逐 run 不变）。

## 8.3 裁定

最大波动 0.0029% ≪ 1% 干预线 → 无需定位非确定性源。微抖来源已知且接受：
inst-console / ep-overview 为 loaded/探针态 capture 的 fake-server 计时残差（elapsed ms
读数与 AA 边缘），量级 ≤119px / 4.096M。其余 6 屏字节级稳定（Skia 确定性后端，
第 6.10 已证）。

## 阈值导出（8.4/8.5）

- text = max(地板 × 2, 3%) = max(0.0058%, 3%) = **3%**（下限主导）
- roi（同法）= max(0 × 2, 3%) = **各 3%**：rail / midBar / cardHead / tableHead
  注意：rail≈95%、midBar≈18–25% 的当前比值是**结构性**差异（capture 通道无 app
  chrome——rail/顶栏/midBar 不在渲染内；色彩采样 railBg 同理全败），第 9 章首轮
  收敛即处理 capture 通道 chrome 包裹；校准阈值在此是目标线不是现状线。
