# redimos-manager — 路线图 / 设计

本文汇总 2026-07 一轮讨论定下的几件事:Local DynamoDB 一站式启动、redimos 的 Docker 运行模式、子进程 Supervisor(保活)、图形监控。设计草案配套两个可视化预览(仅样式):Local DynamoDB 5 种启动方式、监控面板。

---

## 0. 已锁定的默认(可后续调)

| 决策 | 取值 |
|---|---|
| Auto-restart 默认 | **On**("监控它不挂掉"是本意;人为 Stop 不触发,崩溃循环有上限保护) |
| 监控面板位置 | detail 区里和 `logs` 并列的**可折叠 `monitor` 条** |
| redimos Docker 镜像 | Settings 里填镜像名/tag(每版一个),默认 `redimos-v1:local` / `redimos-v2:local`;manager 不自动 build |
| 监控深度 | 先做**进程级**(CPU/内存/存活/重启,gopsutil);redimos `/metrics`(ops/延迟/throttle)第二步 |
| gopsutil 依赖 | 采用(跨平台取 CPU/内存最干净) |
| Java 组件获取 | **自动下载**官方 DynamoDBLocal 包并缓存本地 + Settings 可手填路径覆盖 |
| Local DynamoDB 默认引擎 | 有 Docker → `dynamodb-local · In-memory`;否则 → `Java · In-memory` |
| Docker 网络 | 一律 `-p` 把端口发布到 host;容器间/容器→宿主服务全走 `host.docker.internal:<发布口>`(不碰 `--network host`) |

---

## A. Local DynamoDB(一站式本地后端)

侧栏底部一条**全局单例**小控件(不属于任何配置),起/停一个本地 DynamoDB。和每条配置的 `Auto Create` 组合成一条龙:起本地 DynamoDB → 建 endpoint 指向它的配置 + Auto Create On → ▶ → 零手工建库建表。

**表现形式** = 两级下拉,而非 5 个扁平项:
- `Engine`(3):`Java · local` / `Docker · dynamodb-local` / `Docker · LocalStack`
- `Storage`(2):`In-memory` / `Persisted` —— 选 LocalStack 时**自动隐藏**(自管存储)

于是组合成 5 种:

| # | Engine | Storage | 依赖 | 端口 | 底层 |
|---|---|---|---|---|---|
| 1 | Java · local | In-memory | Java | 8000 | `java -jar DynamoDBLocal.jar -inMemory` |
| 2 | Java · local | Persisted | Java | 8000 | `… -dbPath <dir> -sharedDb` |
| 3 | Docker · dynamodb-local | In-memory | Docker | 8000 | `amazon/dynamodb-local -inMemory` |
| 4 | Docker · dynamodb-local | Persisted | Docker | 8000 | `-v vol:/data … -dbPath /data -sharedDb` |
| 5 | Docker · LocalStack | 自管 | Docker | 4566 | `localstack`,`SERVICES=dynamodb` |

- Engine 下拉按 Docker/Java 探测结果**逐项灰掉**不可用项;全不可用则整体降级为提示,不影响其余功能。
- Persisted 才出现落盘字段:Java = 本地文件夹(`-dbPath`);Docker = 命名卷(`-v`)。
- Java 组件缺失时自动从 AWS 官方地址下载 `dynamodb_local_latest`(含 jar + sqlite4java 原生库)缓存到 `~/.redimos/dynamodb-local/`。

---

## B. redimos 运行模式(Native / Docker)

REDIMOS 段加 `Run mode` 下拉(和 Version 并列):`Native`(现状,`bin/redimos-vN.exe`)/ `Docker`。

**Docker 模式的端口/网络规则(已定)**:
- RESP 口:`docker run -p <port>:<port> … -addr :<port>` → 宿主 `localhost:<port>` 照旧连。
- 连本地 DynamoDB:容器里的 `localhost` 是容器自己 → manager 自动把 endpoint 主机名 `localhost`/`127.0.0.1` → **`host.docker.internal`**(去连宿主已发布的 8000/4566)。线上 AWS(endpoint 空)不改写。
- metrics 口:容器内钉固定口(`:9121`)+ `-p 127.0.0.1::9121` 让 Docker 在宿主侧自动挑空闲口,`docker port` 读回实际端口再拉 `/metrics`/`/healthz`。

---

## C. Supervisor(保活)

住在 Go core(它本来就管每个子进程的 start/stop/`cmd.Wait`)。

- `cmd.Wait` 返回且**非**用户主动 Stop → 若该配置 Auto-restart 开 → **退避重启**:`1s → 2s → 5s → 10s → 30s`(封顶),记 `restartCount`。
- **崩溃循环保护**:窗口内连续快速失败 ≥ N 次(如 30s 内 5 次)→ 判 `Failed`、**停手**、置红并通知,不再无限拉。
- 人为 Stop 打 `intendedStop` 标记,退出不重启(区分"人为停"与"崩了")。
- 每条配置一个 `Auto-restart` 开关(On/Off,同 Multi DB 样式);`restartCount`/`lastExit`/state 经 `rm_status` 给 UI。
- 进阶(后置):redimos `/readyz` 连续 unhealthy 也触发重启,不只看进程存活。

---

## D. 图形监控

detail 区里和 `logs` 并列的可折叠 `monitor` 条。

| 层 | 指标 | 来源 |
|---|---|---|
| 进程级(所有子进程) | CPU% / 内存 / 存活 / 重启数 | gopsutil 采 PID;Docker 子进程走 `docker stats` |
| redimos 专属 | 健康、连接数、ops/s、DDB throttle、p99 | redimos `/healthz`+`/readyz`+`/metrics`(端口从启动日志 `metrics=[::]:PORT` 抓) |

侧栏每行加健康色 + mini CPU/内存 + 重启计数;`Failed` 置红。

---

## X. 子进程抽象(贯穿 B/C/D)

Native 和 Docker 两套统一到一个 `childProcess` 抽象,只是底层实现不同:

| 事项 | Native | Docker |
|---|---|---|
| 启动 | `exec.Command` | `docker run -d --name …` |
| 存活/保活 | PID + `cmd.Wait` | `docker inspect` + 重跑 |
| 资源指标 | gopsutil(PID) | `docker stats` |
| 停止 | kill PID | `docker stop/rm` |
| 端口互通 | 直接 localhost | 全走宿主 `host.docker.internal:<发布口>` |

---

## 实施阶段

1. **Supervisor**(auto-restart + 退避 + 崩溃循环保护 + 状态暴露 + UI 开关)← 先做
2. **进程级监控**(gopsutil:CPU/内存/uptime/重启 → `monitor` 折叠面板 + 侧栏 mini)
3. **Local DynamoDB 控件**(5 种启动方式;Engine/Storage/端口/落盘;Java 自动下载;Docker 容器)
4. **redimos Run mode = Docker**(容器化 redimos + 端口/网络改写 + metrics 端口回读)
5. **redimos /metrics 抓取**(ops/延迟/throttle/连接数 → 监控面板 sparkline)

每阶段:改 Go core(`native/`)→ 重建 DLL(docker+mingw)→ 改 UI(`lib/`)→ 重建 app → 实测验证。

## 开放项
- 崩溃循环阈值(默认 30s 内 5 次)是否可配。
- Docker 子进程退出监听:轮询 `docker inspect` vs `docker events`。
- LocalStack 起来后是否需要预热等待其 DynamoDB service ready。
