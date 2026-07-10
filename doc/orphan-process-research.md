# 孤儿进程处理方案调研(2026-07-10)

> 调研方式:6 路并行调研(macOS 机制 / Windows 机制 / 监督器案例 / 收养式设计 / 现状审计 / 进程标识技术)+ 16 条关键事实断言逐条对抗验证(文档考证 + 本机实验)。共 22 个 agent,全部实验在本机(macOS 15.7.3 / Darwin 24.6, go1.26, Docker 29.6)用一次性夹具完成。
>
> 结论先行:**当前三层方案(优雅退出 rm_shutdown / 按端口 reapStalePort / 启动 PPID==1+路径子串清扫)方向正确但地基弱**——识别靠「路径子串」既会误杀也会漏杀,docker 容器完全在盲区,Windows 两层清扫是 no-op。正解是把「识别」升级为**精确身份注册表**,把「预防」升级为**每平台生命周期绑定**(Windows Job Object / macOS lifeline 管道),并对唯一有状态的子进程(Local DDB)考虑**收养**而非杀。

## 1. 已实证的关键事实(对抗验证结果)

16 条断言:10 confirmed / 6 partially(带实质性 caveat)/ 0 refuted。要点:

| # | 事实 | 裁决与依据 |
|---|---|---|
| F1 | macOS 孤儿一律被 launchd(PID 1)收养;**无 subreaper 等价物**(SDK 全量 grep 无 prctl/procctl/reaper) | confirmed,实验+SDK 检查 |
| F2 | **PPID==1 本身不是"孤儿"证据**:所有 launchd 启动的 GUI app 都是 PPID 1(本机 853 个进程 PPID=1,包括 Finder 和本 app 自己) | confirmed。现有 sweep 之所以安全全靠路径子串过滤 |
| F3 | 路径子串过滤**双向失真**:误杀(用户自己 `nohup` 起的同二进制、argv 里含该路径的任意进程如 `tail -f …/redimos-v1.log`)已实验复现;漏杀(经 `exec`/相对路径启动时 argv 不含绝对路径;用户改了 Settings 路径后旧孤儿永远匹配不上) | confirmed |
| F4 | **docker 是最大盲区**:app 被 SIGKILL 后 `docker run --rm` CLI 死掉但**容器继续跑**(实验:`kill -9` CLI 后容器仍 Up;连 killpg 全组也无效——容器是 containerd/VM 的后代,不是 host 进程);boot sweep 用 host ps 根本看不见;只有下次启动**同一 config** 时 `docker rm -f` 才懒清理 | confirmed(caveat:`--rm` 的自动删除是 daemon 侧、容器**退出时**仍会发生;可捕获信号经 `--sig-proxy` 能转发,只有 SIGKILL/崩溃路径孤儿化) |
| F5 | **管道 EOF 是唯一同时满足「扛 SIGKILL + 零配合 + 无竞态」的预防原语**:写端随进程死亡被内核无条件关闭(fd 收尾是内核退出工作,不走信号/atexit);实测 manager 被 `kill -9` 后 1.6ms 内 janitor 收到 EOF | confirmed |
| F6 | Windows **Job Object + KILL_ON_JOB_CLOSE** 在管理进程被 TerminateProcess/崩溃时仍会杀光 job 内全部进程(内核关句柄触发);孙进程默认留在 job 内 | partially:成立,但三个条件 load-bearing——①manager 必须持有**唯一**句柄(不可继承、不外泄);②启动用 CREATE_SUSPENDED→Assign→Resume 消掉赋值竞态窗;③不要设 SILENT_BREAKAWAY_OK |
| F7 | **收养比预想的能力强**:kqueue `EVFILT_PROC NOTE_EXIT` 可监视**非子进程**(同 uid),实测连完整 wait status(退出码/信号)都送达(文档只对子进程保证 NOTE_EXITSTATUS,代码须容忍缺失);Windows 上 `OpenProcess+WaitForSingleObject+GetExitCodeProcess` 对非子进程完全等价于 Wait。真正丢失的只有:旧 stdout/stderr 管道(native 日志)与「manager 死亡期间发生的退出」 | partially(修正了「拿不到退出码」的预设) |
| F8 | **被收养的 native Go 孤儿是 SIGPIPE 定时炸弹**:向死管道写日志的 Go 子进程几秒内死(EPIPE→SIGPIPE 致命);安静的一直活。Java 免疫(JVM 忽略 SIGPIPE)。redimos 默认 request-log=none → 长引线,但第一条日志就是死期 | confirmed(实验) |
| F9 | `ps -E` 读同 uid 进程 env 可行且 **SIP 无关**(自家二进制非 cs_restricted 即可读);但**拒绝是静默的**(读不到 ≠ 不是我们的,要当 unknown) | partially |
| F10 | `-Dredimos.manager.tag=<uuid>` 放 `-jar` **前**对 DynamoDBLocal 完全无害(实测 v1.25.1 正常服务),且在 `ps -ww` 可见 → java 的 cmdline 哨兵 | confirmed |
| F11 | **flock fd 继承技巧**(macOS):spawn 时把已 flock 的 lockfile fd 经 ExtraFiles 传给子进程,JVM 不会关闭继承的 fd 3;锁随子进程(树)存亡,manager 死后锁仍被孤儿持有,`lsof -t` 可定位持有者;子进程死锁立即释放 → **零配合的活性+身份信号** | confirmed(用真 jar 实测) |
| F12 | (pid, 启动时间µs) 二元组身份:darwin `proc_pidinfo(PROC_PIDTBSDINFO)` 微秒精度(procstats_darwin.go 已链 libproc);Windows `GetProcessTimes` 创建时间(procstats_windows.go **已经在取、只是丢弃**)→ pid 复用误配结构性不可能 | confirmed |
| F13 | Windows **PPID 不会重写**(父死后悬空)→ 无 PPID==1 类比;孤儿判定三段法:父 pid 打不开(87)→孤儿;打开但已退出→孤儿;打开且活着但**创建时间晚于子进程**→pid 被复用、假父→孤儿 | confirmed(文档) |
| F14 | launchd 才是 macOS 的「job object」(job 主进程死后 launchd 会杀同 pgid 余党 + KeepAlive),但采用=架构倒置(子进程归 launchd,Wait/日志/退避全要重做,且「app 死后子进程继续跑」恰是它的 feature) | confirmed,不采用 |
| F15 | 当前代码 spawn 无任何 SysProcAttr(子进程与 Flutter app 同进程组)→ `flutter run` 下 Ctrl-C 的 SIGINT 会**连带打死全部子进程**(监督器背后);terminate 只杀直接 pid,载荷若有包装层会漏 | partially(采样是按 pid 不依赖 cmd 句柄,该子句不成立) |
| F16 | 崩溃时机 DDB 在 preparing(jar 下载中)→ **无孤儿**(spawn 在 ensureDdbJar 之后才执行,只漏一个临时 zip) | confirmed(非问题) |

## 2. 行业案例给出的三族方案

1. **生命周期绑定**(内核或子进程自己保证「管理者死→子进程死」,垂死方无需执行任何代码):Chrome/VS Code(与本项目形态最像的桌面 GUI)全走这条——Windows 用 Job Object;macOS 用协作式 watchdog(VS Code node-native-watchdog 轮询父进程;Chrome 子进程在 IPC 管道断开时自杀)。
2. **监督器与 UI 解耦**(shim/agent 常驻,UI 是可弃客户端):tmux;containerd shim(业界最强收养:daemon 重启后经 socket 重连 shim,连不上则 delete)。代价=多带一个常驻、带版本协议的组件。
3. **注册表 + 对账**(持久化意图与强身份,启动时 reconcile:收养或杀掉重启):pm2 `resurrect`(只承诺恢复期望状态,不重接);systemd(教训:基于 PID/路径的追踪是坏的,KillMode=process 被文档标注 "not recommended",要靠不可逃逸的 cgroup 分组——macOS 没有 cgroup,所以要靠**精确身份**逼近)。

supervisord 的反面教材:纯 parent/child + Wait 架构在自己被 SIGKILL 后**没有任何恢复手段**,重启后会在孤儿旁边再起一份(端口冲突)——正是本项目踩的坑,架构性无解,必须叠加族 1 或族 3。

**适配本项目的判断**:保持 kill-and-restart-fresh 的总模型(foreman/pm2 语义,子进程是廉价 dev server;GUI 即监督器,同生共死是设计而非缺陷),但用族 1 做预防、族 3 做识别与兜底;族 2(常驻 shim)唯一的收益是「GUI 崩溃后 in-memory 表不丢」,暂不值得,若日后要「关 GUI 服务器继续跑」再回头用 launchd/shim。

## 3. 现状审计:按严重度排序的缺口

1. **HIGH|docker 孤儿对 boot sweep 不可见**(F4):删配置/改端口/换引擎后永久泄漏;换引擎场景还会让继任者绑不上 :8000 而 crash-loop。→ 修法见 §4-P0。
2. **HIGH|Windows 零事后恢复**:两层 reap 都是 no-op;崩溃后下次启动 bind-fail×5 → "failed",无自愈。→ §4-P2。
3. **MED-HIGH|boot sweep 误杀**(F3,已实验复现):PPID-1 + argv 含路径即杀,波及用户自己 nohup 的同二进制、`tail -f` 该路径日志的进程。→ §4-P1 注册表根治。
4. **MED|无单实例锁**:双实例时 B 的 Start 会经 reapStalePort 杀掉 A 的健康受监督子进程 → 监督器互相拉起 → ping-pong;两实例还并发写 store.json。→ `~/.redimos/lock` flock,~20 行。
5. **MED|退出与退避竞态**:`terminate()` 可插在 `doRestart` 的 intendedStop 检查与 `spawn()` 的 cmd.Start 之间 → 新 spawn 的子进程躲过必杀、活过 app 退出。→ spawn 内 Start 后在锁内复查 intendedStop,+ terminate 取消退避 timer。
6. **LOW-MED|stale-path 盲区**(F3 漏杀半边):sweep 匹配的是**当前** Settings 路径。→ 注册表记录 spawn 时实际路径,与 Settings 解耦。
7. **LOW|TOCTOU pid 复用**(ps 扫描→Kill 间 ≤50ms):理论性;杀前复查 (argv + lstart 早于本会话启动) 即闭合。
8. **LOW|SIGKILL-only**:对 persist 模式的 java 不温柔。→ TERM→2s→KILL 阶梯。

非问题(已验证):preparing 期崩溃无孤儿(F16);`--rm` 对**已退出**容器的清理不受 CLI 死亡影响;活兄弟实例的子进程 boot sweep 不会碰(PPID≠1);优雅退出的 docker rm -f 是 awaited 的。

## 4. 推荐路线图(分层,每层独立可交付)

### P0 — 立即做的小改(合计 ≲100 行)
- **`Setpgid: true`**(spawn 全部非 docker 子进程)+ `terminate()` 改 **killpg**(TERM→宽限→KILL):覆盖载荷可能 fork 的子树,顺带修掉 `flutter run` Ctrl-C 连带击杀子进程的问题(F15)。killpg 对「已孤儿化的组」依然有效(实验:组是成员属性,不随父死失效)。
- **docker 容器打标签 + boot 容器清扫**:`--label redimos.manager.session=<uuid>`;启动时 `docker ps -q --filter label=redimos.manager.session` →(owner 已死才)`rm -f`。同时给 sweep 补 name-prefix 过滤兜底。修 §3-1。
- **单实例 flock 锁**:修 §3-4,顺带保护 store.json。
- **竞态修补**:§3-5 的两处小改。

### P1 — 识别地基:children registry(~300 行,核心投资)
`~/.redimos/run/children.json`(tmp+rename 原子写 + 自身 flock):每次 spawn 后记 `{role, pid, startUnixMicro, comm, port, container, metricsAddr, 实际 bin 路径}`;监督重启原位更新;终态删除。孤儿判定从「路径子串」换成「注册在案 且 (pid,start-µs,comm) 三元组精确匹配」→ 误杀/漏杀/TOCTOU/stale-path(§3-3/6/7)一次根治,且是 Windows 可移植的(不依赖 PPID 语义)。加辅助信号:env 哨兵 `REDIMOS_MANAGER_SESSION=<uuid>`(macOS `ps -E` 可读,F9)、java `-D` 哨兵(F10)。路径子串 sweep 降级为「注册表缺失/损坏时的兜底」保留一个版本后删除。

### P2 — Windows 补课(强于 macOS 的终态)
- **Job Object + KILL_ON_JOB_CLOSE**(每 instance 一个 job;CREATE_SUSPENDED→Assign→NtResumeProcess,fallback Toolhelp 遍历线程 Resume;F6 三条件全落实):manager 任何死法,内核收光子进程树 → Windows 上孤儿类**消失**。调研已产出**可编译**(amd64+arm64 vet/build 绿)的 Go 草图(scratchpad orphanx-win/,零依赖 NewLazyDLL 风格与 procstats_windows.go 一致)。`TerminateJobObject` 顺带升级 terminate 为全树杀。
- **Windows 端口 reap**:`GetExtendedTcpTable`(v4+v6 双表;v6 行 dwState 字段位置陷阱;dwLocalPort 网络字节序)→ pid → `QueryFullProcessImageName`(redimos)/PEB 命令行(java)匹配。孤儿判定用 F13 三段法。
- 真机冒烟清单已备(6 项,见调研原文)。

### P3 — macOS 预防:lifeline janitor(~150 行 helper)
单个 janitor 辅助进程(bundle 内 Contents/Helpers/),启动时持 lifeline 管道读端;manager 经控制管道注册 `PGID <pgid> MATCH <path>` / `CTR <container>`,terminate 时 UNREG。manager 任何死法(含 SIGKILL,实测 1.6ms)→ EOF → janitor 对每个 PGID 先验身份再 killpg(TERM→2s→KILL)、对每个 CTR `docker rm -f`,然后自尽。优雅退出时注册表已空,EOF pass 是幂等 no-op。不选 per-child wrapper(破坏 Wait/日志/采样的直接父子关系,纯亏);不选 launchd(架构倒置,F14);不选 kqueue 父监视做主干(注册竞态,管道无此问题)。janitor 与 manager 同死时,P1 注册表仍兜底——各层正交。

### P4 — 可选:定向收养(~350-400 行含 P1 共享部分)
- **收养 Local DDB(推荐)**:唯一有状态的子进程;默认 in-memory,崩溃后孤儿里装着用户全部 dev 表,现行 kill-on-sight 恰在用户恢复工作时抹数据(F4/F8:java 免疫 SIGPIPE、docker 是一等收养对象,都是健壮孤儿)。收养 = registry 命中 → 不杀,标 `adopted`,kqueue NOTE_EXIT(F7)接监督(死了照常退避重启),UI 加 "adopted · 上一会话日志不可用" 徽标;metricsAddr 从注册表恢复。
- **收养 docker redimos(近乎免费,+~40 行)**:`docker logs --tail 200 -f` 当日志泵(**能找回历史日志**,比 native 还好)+ `docker wait` 拿真退出码。
- **不收养 native redimos**:无状态、毫秒级重生,而被收养的是 SIGPIPE 定时炸弹(F8)且日志不可恢复——杀掉重启严格更优。(若未来想要,先决条件是 spawn 从管道改为日志文件+tail,~100 行,今天不值得。)

## 5. 一页结论

- 「重启后如何兼容孤儿」的完整答案是**四件套**:①正常退出不留孤儿(已有 rm_shutdown);②活着时不让孤儿产生成为可能(P2 Job Object / P3 janitor,内核级、扛 SIGKILL);③重启后用**精确身份**对账(P1 注册表:pid+start-µs+comm,而非路径子串)决定杀或收养;④对唯一有状态的 DDB 用收养保数据(P4)。
- 现有三层保留为兜底,但其中「PPID==1 + 路径子串」应视为**过渡性启发式**:PPID==1 在 macOS 不是孤儿证据(F2),路径子串双向失真(F3),docker 全盲(F4)——P1 落地后降级、再一个版本后删除。
- Windows 现状是零保护,但终态反而最强(Job Object 是内核原语,比 macOS 一切用户态方案都硬)。
- 实施优先级:P0 → P1 → P2 → P3 → P4;P0+P1 后,实际用户可感的孤儿问题(误杀/漏杀/docker 泄漏/双实例互殴)即已根治,P2/P3 把「事后清扫」升级为「事前不可能」,P4 是 UX 增值。

## 附:实验产物索引(session scratchpad,重启后即失效)
- `orphanx/`:lifeline janitor PoC(1.6ms EOF)、kqueue 非子进程 watch、pgid/setsid 逃逸、flock fd 继承(真 jar)、SIGPIPE 引线、docker CLI 击杀系列(t1-t5)
- `orphanx-win/`:Windows Job Object + 端口/孤儿清扫的可编译 Go 草图(amd64+arm64 vet 绿)
- 调研原文 6 份 + 16 条裁决:`orphan-reports/*.md`、`orphan-research.json`
