# Browser 页设计(参照 Another Redis Desktop Manager 的数据浏览)

> 调研:2026-07-11 经 CGEvent 实操本地 ARDM 连**正在跑的 redimos :6379**
> (真数据、真兼容性)。裁掉连接管理/CLI/日志/INFO 仪表盘(已有功能或
> Monitor 覆盖)。新 tab **直连当前配置的 redimos RESP 端口**,无需 Go 改动。

## ARDM 结构(实测)

### 左面板
- 连接工具条:home / console / refresh / grid-view(树↔平铺切换)/ 折叠。
- `DB0` 下拉(选库)+ `+ New Key`。
- 搜索框:glob 输入 + 放大镜 + 正则复选框。
- **命名空间树**:按 `:` 分组成文件夹(queue / rank / session>token / tags /
  user>profile),每级带 `(count)` 徽标;叶子 = 完整键名。平铺模式=不分组。
- 底部:`load more`(增量 SCAN)/ `load all`(红,危险)。

### 右面板:键详情(五类型共享头)
`<Type>` 徽标 + 键名(+ rename ✓)+ `TTL <n>`(-1=无;活值倒计;+ reset +
set ✓)+ delete(红)/ refresh(绿)/ JSON(蓝 </>)。类型专有体:
- **String**:格式下拉(Text/JSON/…)+ `Size: NB` + `Copy` + 值文本域。
- **Hash**:`Add New Line` + 表 `ID(Total:N) | Key ↕ | Value ↕ | Keyword Search`
  + 每行 view/edit/delete/formatter。
- **List**:`Add New Line` + 表 `ID | Value ↕`(+ 每行动作)。
- **Set**:同 List(表 `ID | Value`)。
- **Zset**:`Add New Line` + `DESC/ASC` 切换 + 表 `ID | Score ↕ | Member ↕`。
- New Key 弹窗:键名 + 类型选择(+ 首个字段/值)。

## redimos 能力映射(实现时逐条实测,基于既往 Redis 3.2 对齐审计)

| 功能 | redimos | Browser 处置 |
|---|---|---|
| 列键 | **KEYS 禁用**;SCAN(MATCH/COUNT/cursor)可用 | SCAN 分页(glob→MATCH) |
| 类型判定 | TYPE 可用 | TYPE |
| TTL | TTL/EXPIRE/PERSIST 可用 | TTL 显示+设置+persist |
| 删键 | DEL 可用 | delete 带确认 |
| 改名 | **RENAME 注册但拒绝** | 键名只读 + tooltip 说明「redimos 不支持 RENAME」 |
| 选库 | SELECT(MultiDB 时 0-15) | 仅 MultiDB 配置显示 db 下拉 |
| String | GET/SET 可用 | 值查看/编辑(Text·JSON),SET 保存 |
| Hash | HGETALL 读;**HSET 单字段**(多字段被拒);HDEL | 表增改删(HSET 单对) |
| List | LRANGE / RPUSH·LPUSH / LSET / LREM | 表,追加/改/删 |
| Set | SMEMBERS / SADD / SREM | 表,增/删 |
| ZSet | ZRANGE WITHSCORES / ZADD / ZREM | 表,增改删(带 score) |

## 本实现(第 7 个 tab「Browser」,全 Flutter 零 Go 改动)

- **共享 RESP 客户端**:把 cmd_console.dart 的 `RedisConsoleClient` + parser
  抽到 `lib/src/resp_client.dart`,加类型化助手(scanKeys/typeOf/ttl/
  各类型读写);Cmd 与 Browser 同一通路(127.0.0.1:configPort)。
- **browser_page.dart**:
  - 左:搜索(glob,默认 `*`)、树/平铺切换、SCAN `load more` + 已载计数、
    New Key、refresh、MultiDB 时 db0-15 下拉;
  - 右:类型头(徽标 / 键名**只读**+改名禁用提示 / TTL 显示+编辑+persist /
    delete 带确认 / refresh)+ 五类型编辑器;二进制值可打印判定(复用 Table
    页思路,不可打印显十六进制预览)。
- main.dart 接线 tab 6→7。

## 覆盖矩阵

| # | ARDM 细节 | v1 处置 |
|---|---|---|
| 1 | 连接管理/新建连接 | **裁**(用户指定;直连当前配置) |
| 2 | console(CLI) | **裁**(Cmd 页已有) |
| 3 | INFO 仪表盘(Server/Memory/Stats) | **裁**(Monitor 页已有) |
| 4 | 命名空间树 / 平铺切换 | ✅ 同样 |
| 5 | glob 搜索 + 正则 | ✅ glob(正则=v2) |
| 6 | SCAN load more / load all | ✅ load more(load all 加确认) |
| 7 | DB 选择器 | ✅ 仅 MultiDB |
| 8 | New Key(名+类型) | ✅ 同样 |
| 9 | 五类型编辑器 | ✅ 同样(读+常用写) |
| 10 | TTL 显示/设置/persist | ✅ 同样 |
| 11 | 键删除 | ✅ 带确认 |
| 12 | 改名 | ✅ 只读+禁用提示(redimos 不支持) |
| 13 | 每行 formatter / view 弹窗 | 部分:值弹窗查看;多格式 formatter=v2 |
| 14 | List 行内移动 / Zset DESC/ASC | 裁 → v2 |
| 15 | 二进制值 | ✅ 可打印判定 |
