# Service 配置面 roadmap（分析结论）

> 2026-08-19 由「v1.2 服务页配置分析」定稿。本轮（tab 重排 + 端点 Configure tab +
> Sky 默认主题）未落实任何配置项新增；本文是后续迭代的工作清单。

## 现状（v1.2 表单 8 项）

`lib/src/service_configure.dart`：

| 字段 | 控件 | 适用 | 备注 |
| --- | --- | --- | --- |
| name | 文本 | 全部 | 必填，peers 间 case-fold 唯一 |
| engine | 下拉 java/docker/localstack | 全部 | live 时锁定 |
| port | 数字 | 全部 | 0 = 引擎默认（java/docker 8000，localstack 4566） |
| storage.mode | 下拉 memory/managed/custom | 全部 | live 时锁定 |
| storage.path | 文本 | java + custom | 必填 |
| storage.volume | 文本 | 非 java + custom | 必填 |
| engineOptions.heap | 文本 | java | → `-Xmx` |
| engineOptions.SERVICES | 文本 | localstack | **陷阱**：core build 时无条件拒绝（`service_engine.go:597-599`），填了必启动失败 |

Core 权威校验在 `native/service.go:165-221`（validateServiceConfig）：名称
case-fold 唯一、端口唯一、engineOptions 仅扁平标量。运行中（live）时
engine/port/storage 身份字段锁死（`service_ops.go:57-67`），UI 同步禁用。

## P1 —— UI 层可补（core 已具备能力）

1. **移除 SERVICES 陷阱控件**。该键 core 硬拒，UI 采集即必败，应删除或改为
   只读说明。
2. **通用 engineOptions KV 高级编辑器**。core 的 EngineOptions 是开放
   `map[string]any`，localstack 任意标量键都会透传为 `-e k=v`
   （`service_engine.go:610-617`）。补一个「高级选项」键值编辑区，
   `DEBUG` / `LS_LOG` 等日志级别环境变量立即可用；java/docker 侧其余键
   目前被静默忽略，编辑器需提示这一点。

## P2 —— core 层新增（需双平台重建 core + 回归）

按价值排序：

1. **autoRestart 字段化**。现在 `armLaunch` 硬编码 `autoRestart: true`
   （`service_engine.go:117`）；v1 曾有该控件。加 `ServiceConfig.AutoRestart`
   并在表单暴露「随管理器自启」开关。
2. **DynamoDB Local 官方 flag**：`-cors`、`-delayTransientStatuses`、
   `-disableTelemetry` 目前未接线。
   **注意：`-optimizeDbBeforeStartup` 有已知 UpdateItem 复制新行的缺陷，
   永不放开。**
3. **java 引擎 JVM 参数**：仅支持 `-Xmx`；`-Xms` 等可经 EngineOptions 透传。
4. **容器引擎选项**：镜像 tag 选择（现写死 `amazon/dynamodb-local` /
   `localstack/localstack:4.0`）、资源限制 `--memory/--cpus`、`-u root`、
   PERSISTENCE 开关、容器内端口。
5. **每服务 readiness/stop 超时**：现包级 var（readiness 30s / stop 10s，
   `service_lifecycle.go:54,57`），不可按 Service 配置。

## v1 传承参照（语义已迁移，形态可借鉴）

v1 的 requirepass / version(v1/v2) / multiDb / autoCreateTable / table /
extraFlags 属代理侧配置，v1.2 归 Instance/Endpoint 实体，不进 Service 表单。
其中 **extraFlags 的 12 键白名单行式编辑器**与 **autoRestart 控件**的形态值得
Service 高级编辑器借鉴。

## 附：端点 Name 字段现状

端点（Endpoint）的 Name 是 core 从 region / "local" / URL host **推导的显示名**
（`native/model_split.go` endpointDisplayName），不持久化；Configure tab 的
Name 输入框因此仅影响当次会话显示，保存真正落盘的只有 endpoint/region 两个
字段（经绑定 instance config 同步写回）。若要 Name 可编辑，需 core 侧为
Endpoint 增加可持久化别名，属后续 core 工作。
