// Lightweight app-wide i18n (English / 中文). Mirrors the theme infra in
// main.dart: a global ValueNotifier persisted next to the Go core's store, in
// ~/.redimos/locale, plus a tr() lookup over a static string table. MaterialApp
// rebuilds on change (it listens to appLang), so every widget that reads tr()
// re-localises. No flutter_localizations dependency — only the app's own strings
// are translated; Material's few built-in strings stay English (rarely surfaced
// here since dialogs use custom text).

import 'dart:io';

import 'package:flutter/widgets.dart';

enum AppLang { en, zh }

/// App-wide language selection, chosen from the app bar.
final ValueNotifier<AppLang> appLang = ValueNotifier<AppLang>(AppLang.en);

File? _localeFile() {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return null;
  return File('$home${Platform.pathSeparator}.redimos${Platform.pathSeparator}locale');
}

/// Load the saved language, or fall back to the OS locale on first run.
void loadAppLang() {
  try {
    final f = _localeFile();
    if (f != null && f.existsSync()) {
      appLang.value = f.readAsStringSync().trim() == 'zh' ? AppLang.zh : AppLang.en;
      return;
    }
  } catch (_) {}
  try {
    if (Platform.localeName.toLowerCase().startsWith('zh')) appLang.value = AppLang.zh;
  } catch (_) {}
}

void saveAppLang(AppLang l) {
  try {
    final f = _localeFile();
    if (f == null) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(l == AppLang.zh ? 'zh' : 'en');
  } catch (_) {}
}

/// Look up a UI string for the current language. Falls back to English, then to
/// the key itself (so a missing key shows up in dev rather than crashing).
String tr(String key) {
  final row = _strings[key];
  if (row == null) return key;
  return row[appLang.value] ?? row[AppLang.en] ?? key;
}

/// tr() with `{name}` placeholder substitution, for strings that interpolate
/// runtime values (endpoint, table name, counts…). Template holds `{name}`.
String trp(String key, Map<String, String> vars) {
  var s = tr(key);
  vars.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

// The translation table. Extraction is incremental — the most visible strings
// (top bar, tabs, common actions) are done first; the rest migrate over time.
// Product names (PartiQL, DynamoDB, Redis, redimos) intentionally stay as-is.
const Map<String, Map<AppLang, String>> _strings = {
  // --- top bar ---
  'app.theme': {AppLang.en: 'Theme', AppLang.zh: '主题'},
  'app.language': {AppLang.en: 'Language', AppLang.zh: '语言'},
  'app.stopAll': {AppLang.en: 'Stop all', AppLang.zh: '全部停止'},
  'app.startAll': {AppLang.en: 'Start all', AppLang.zh: '全部启动'},
  'theme.light': {AppLang.en: 'Light', AppLang.zh: '浅色'},
  'theme.dark': {AppLang.en: 'Dark', AppLang.zh: '深色'},
  'theme.system': {AppLang.en: 'System', AppLang.zh: '跟随系统'},

  // --- right-pane tabs ---
  'tab.configure': {AppLang.en: 'Configure', AppLang.zh: '配置'},
  'tab.monitor': {AppLang.en: 'Monitor', AppLang.zh: '监控'},
  'tab.logs': {AppLang.en: 'Logs', AppLang.zh: '日志'},
  'tab.endpoint': {AppLang.en: 'Endpoint', AppLang.zh: '端点'},
  'tab.table': {AppLang.en: 'Table', AppLang.zh: '表'},
  'tab.partiql': {AppLang.en: 'PartiQL', AppLang.zh: 'PartiQL'},
  'tab.console': {AppLang.en: 'Console', AppLang.zh: '命令行'},
  'tab.browser': {AppLang.en: 'Browser', AppLang.zh: '浏览器'},
  'tab.playground': {AppLang.en: 'Playground', AppLang.zh: '脚本台'},
  'tab.overview': {AppLang.en: 'Overview', AppLang.zh: '概览'},

  // --- v1.2 endpoint Overview tab ---
  'ep.ovBackend': {AppLang.en: 'Backend', AppLang.zh: '后端'},
  'ep.ovEndpoint': {AppLang.en: 'Endpoint', AppLang.zh: '端点地址'},
  'ep.ovRegion': {AppLang.en: 'Region', AppLang.zh: '区域'},
  'ep.ovAwsDefault': {
    AppLang.en: 'AWS default resolver',
    AppLang.zh: 'AWS 默认解析'
  },
  'ep.ovReachability': {AppLang.en: 'Reachability', AppLang.zh: '连通性'},
  'ep.ovChecking': {AppLang.en: 'Checking…', AppLang.zh: '检测中…'},
  'ep.ovReachable': {AppLang.en: 'Reachable', AppLang.zh: '可达'},
  'ep.ovUnreachable': {AppLang.en: 'Unreachable', AppLang.zh: '不可达'},
  'ep.ovTablesCount': {AppLang.en: 'tables', AppLang.zh: '张表'},
  'ep.ovRecheck': {AppLang.en: 'Re-check', AppLang.zh: '重新检测'},
  'ep.ovReadOnlyNote': {
    AppLang.en: 'AWS endpoint — writes are disabled everywhere (read-only).',
    AppLang.zh: 'AWS 端点 —— 所有写操作均被禁用(只读)。'
  },
  'ep.ovNoProcessNote': {
    AppLang.en:
        'An endpoint is a storage backend, not a managed process — CPU/memory monitoring and process logs live on the Instances that proxy it.',
    AppLang.zh:
        '端点是存储后端而非受管进程 —— CPU/内存监控与进程日志在代理它的「实例」上。'
  },

  // --- danger/confirm dialog bodies (interpolated via trp) ---
  'danger.deleteTableBody': {
    AppLang.en:
        'Permanently deletes the table at {endpoint} · {count}. It is NOT recreated — the table and all its data are gone.',
    AppLang.zh: '将永久删除 {endpoint} · {count} 处的表。不会重建 —— 表及其全部数据都会消失。'
  },
  'danger.provisionTableBody': {
    AppLang.en:
        'Creates the table at {endpoint} with redimos’s official schema{version}, empty.',
    AppLang.zh: '将在 {endpoint} 处按 redimos 官方 schema{version} 建一张空表。'
  },
  'danger.recreateTableBody': {
    AppLang.en:
        'Deletes and recreates the table at {endpoint} · {count}. All data in it is permanently lost.',
    AppLang.zh: '将删除并重建 {endpoint} · {count} 处的表。其中的全部数据都会永久丢失。'
  },
  'danger.purgeItemsBody': {
    AppLang.en:
        'Deletes every item ({count}) from the table at {endpoint}. The table and its schema stay. This cannot be undone.',
    AppLang.zh: '将删除 {endpoint} 处表中的全部条目({count})。表与其 schema 保留。此操作不可撤销。'
  },
  'danger.deleteStopsConfigs': {
    AppLang.en:
        'This stops {n} running config(s) that use this table and leaves them stopped.',
    AppLang.zh: '这会停止使用该表的 {n} 个正在运行的配置，并让它们保持停止。'
  },
  'danger.sharedEnvWarning': {
    AppLang.en:
        'This endpoint is not loopback ({endpoint}) — it may be a shared environment.',
    AppLang.zh: '该端点不是回环地址({endpoint})—— 可能是共享环境。'
  },
  'danger.versionKeys': {AppLang.en: ' ({version} keys)', AppLang.zh: '({version} 键)'},
  'danger.provisionStepsBody': {
    AppLang.en:
        'This will: stop {n} running config(s) that use this table → create it → restart them.',
    AppLang.zh: '这会:停止使用该表的 {n} 个运行中的配置 → 建表 → 再重启它们。'
  },
  'danger.recreateStepsBody': {
    AppLang.en:
        'This will: stop {n} running config(s) that use this table → delete and recreate it → restart them.',
    AppLang.zh: '这会:停止使用该表的 {n} 个运行中的配置 → 删除并重建 → 再重启它们。'
  },
  'pq.modifyDataWarning': {
    AppLang.en: 'This statement can modify data in "{table}".\n\n{stmt}',
    AppLang.zh: '该语句可能修改 "{table}" 中的数据。\n\n{stmt}'
  },
  'br.deleteFolderBody': {
    AppLang.en: 'Scan and delete every key under "{prefix}:" ? This cannot be undone.',
    AppLang.zh: '扫描并删除 "{prefix}:" 下的所有键？此操作不可撤销。'
  },

  // --- config sidebar ---
  'config.new': {AppLang.en: 'New config', AppLang.zh: '新建配置'},
  'config.none': {AppLang.en: 'No configs yet', AppLang.zh: '暂无配置'},
  'config.pick': {AppLang.en: 'Select or create a config', AppLang.zh: '选择或新建一个配置'},
  'config.unnamed': {AppLang.en: '(unnamed)', AppLang.zh: '(未命名)'},
  'config.start': {AppLang.en: 'Start', AppLang.zh: '启动'},
  'config.stop': {AppLang.en: 'Stop', AppLang.zh: '停止'},

  // --- v1.2 nav (instances / endpoints sidebar) ---
  'nav.instances': {AppLang.en: 'Instances', AppLang.zh: '实例'},
  'nav.endpoints': {AppLang.en: 'Endpoints', AppLang.zh: '端点'},
  'nav.collapse': {AppLang.en: 'Collapse sidebar', AppLang.zh: '收起侧栏'},
  'nav.expand': {AppLang.en: 'Expand sidebar', AppLang.zh: '展开侧栏'},
  'nav.noneYet': {AppLang.en: 'No instances or endpoints yet', AppLang.zh: '暂无实例或端点'},

  // --- v1.2 Playground (JS via goja / Go via yaegi) ---
  'pg.title': {AppLang.en: 'Playground', AppLang.zh: '脚本台'},
  'pg.run': {AppLang.en: 'Run', AppLang.zh: '运行'},
  'pg.clear': {AppLang.en: 'Clear', AppLang.zh: '清空'},
  'pg.samples': {AppLang.en: 'Samples', AppLang.zh: '示例'},
  'pg.language': {AppLang.en: 'Language', AppLang.zh: '语言'},
  'pg.console': {AppLang.en: 'Console output', AppLang.zh: '控制台输出'},
  'pg.result': {AppLang.en: 'Return value', AppLang.zh: '返回值'},
  'pg.copy': {AppLang.en: 'Copy', AppLang.zh: '复制'},
  'pg.copied': {AppLang.en: 'Copied', AppLang.zh: '已复制'},
  'pg.completed': {AppLang.en: 'Completed', AppLang.zh: '已完成'},
  'pg.failed': {AppLang.en: 'Failed', AppLang.zh: '失败'},
  'pg.startedOn': {AppLang.en: 'Started on', AppLang.zh: '开始于'},
  'pg.elapsed': {AppLang.en: 'Elapsed', AppLang.zh: '耗时'},
  'pg.errorOccurred': {AppLang.en: 'Script error', AppLang.zh: '脚本出错'},
  'pg.readOnly': {AppLang.en: 'read-only', AppLang.zh: '只读'},
  'pg.hostRedis': {AppLang.en: 'Redis', AppLang.zh: 'Redis'},
  'pg.hostDdb': {AppLang.en: 'DynamoDB', AppLang.zh: 'DynamoDB'},
  'pg.typeScript': {
    AppLang.en: 'write a script, or pick a Sample',
    AppLang.zh: '编写脚本，或从「示例」选择'
  },
  'pg.apiHintRedis': {
    AppLang.en:
        'Host objects: redis (get/set/del/type/ttl/hget/hgetall/scan/keys/command), console (log/error/table). JS uses lowercase; Go uses Go names (redis.Get).',
    AppLang.zh:
        '宿主对象：redis(get/set/del/type/ttl/hget/hgetall/scan/keys/command)、console(log/error/table)。JS 用小写，Go 用大写方法名(redis.Get)。'
  },
  'pg.apiHintDdb': {
    AppLang.en:
        'Host objects: ddb (listTables/scan/scanAll/getItem/putItem/deleteItem/partiql/call), console (log/error/table). AWS endpoints are read-only. JS uses lowercase; Go uses Go names (ddb.ScanAll).',
    AppLang.zh:
        '宿主对象：ddb(listTables/scan/scanAll/getItem/putItem/deleteItem/partiql/call)、console(log/error/table)。AWS 端点只读。JS 用小写，Go 用大写方法名(ddb.ScanAll)。'
  },
  'pg.instanceNotRunning': {
    AppLang.en: 'Instance not running',
    AppLang.zh: '实例未运行'
  },
  'pg.instanceNotRunningSub': {
    AppLang.en: 'Start this instance to run scripts against its Redis proxy.',
    AppLang.zh: '启动该实例后，才能对其 Redis 代理运行脚本。'
  },
  // sample titles
  'pg.s.redisPrefix': {
    AppLang.en: 'Key prefix stats',
    AppLang.zh: '按前缀统计键'
  },
  'pg.s.redisHashExport': {AppLang.en: 'Export a hash', AppLang.zh: '导出哈希'},
  'pg.s.redisTtlAudit': {AppLang.en: 'TTL audit', AppLang.zh: 'TTL 审计'},
  'pg.s.redisRename': {AppLang.en: 'Rename a key (write)', AppLang.zh: '重命名键(写)'},
  'pg.s.redisBench': {AppLang.en: 'Benchmark SET+GET (write)', AppLang.zh: '压测 SET+GET(写)'},
  'pg.s.ddbScanAggregate': {
    AppLang.en: 'Scan & aggregate',
    AppLang.zh: '扫描并聚合'
  },
  'pg.s.ddbExportJsonl': {AppLang.en: 'Export as JSONL', AppLang.zh: '导出为 JSONL'},
  'pg.s.ddbSizeHistogram': {AppLang.en: 'Item size histogram', AppLang.zh: '条目大小分布'},
  'pg.s.ddbPartiql': {AppLang.en: 'PartiQL SELECT', AppLang.zh: 'PartiQL 查询'},
  'pg.s.ddbConditionalDelete': {
    AppLang.en: 'Conditional delete (write)',
    AppLang.zh: '条件删除(写)'
  },

  // --- extracted from page files (workflow, phase 1 cont.) ---
  'home.accessKeyId': {AppLang.en: 'AccessKeyID', AppLang.zh: '访问密钥 ID'},
  'home.addFlag': {AppLang.en: 'Add flag', AppLang.zh: '添加参数'},
  'home.auth': {AppLang.en: 'Auth', AppLang.zh: '认证'},
  'home.autoCreate': {AppLang.en: 'AutoCreate', AppLang.zh: '自动建表'},
  'home.autoRestart': {AppLang.en: 'AutoRestart', AppLang.zh: '自动重启'},
  'home.autoRestartLabel': {AppLang.en: 'Auto-restart', AppLang.zh: '自动重启'},
  'home.cancel': {AppLang.en: 'Cancel', AppLang.zh: '取消'},
  'home.cannotBeUndone': {AppLang.en: 'This cannot be undone.', AppLang.zh: '此操作无法撤销。'},
  'home.changeTableName': {AppLang.en: 'Change table name', AppLang.zh: '更改表名'},
  'home.close': {AppLang.en: 'Close', AppLang.zh: '关闭'},
  'home.configUpdatedHint': {AppLang.en: 'Config updated to match the data — Save, then Start again', AppLang.zh: '配置已更新以匹配数据 — 请保存后重新启动'},
  'home.configsSuffix': {AppLang.en: 'config(s)', AppLang.zh: '个配置'},
  'home.copyEndpoint': {AppLang.en: 'Copy endpoint', AppLang.zh: '复制端点'},
  'home.coreBuildHint': {AppLang.en: 'Build it with scripts/build_native.ps1 and place the library next to the app executable, or set REDIMOS_CORE_LIB.', AppLang.zh: '请使用 scripts/build_native.ps1 构建,并将库文件放在应用可执行文件旁,或设置 REDIMOS_CORE_LIB。'},
  'home.coreLoadFailed': {AppLang.en: 'Could not load the native core (redimos_core.dll).', AppLang.zh: '无法加载原生核心 (redimos_core.dll)。'},
  'home.cpu': {AppLang.en: 'CPU', AppLang.zh: 'CPU'},
  'home.dataDir': {AppLang.en: 'Data dir', AppLang.zh: '数据目录'},
  'home.delete': {AppLang.en: 'Delete', AppLang.zh: '删除'},
  'home.deleteConfigTitle': {AppLang.en: 'Delete config?', AppLang.zh: '删除配置?'},
  'home.deleteFailed': {AppLang.en: 'Delete failed', AppLang.zh: '删除失败'},
  'home.deleted': {AppLang.en: 'Deleted', AppLang.zh: '已删除'},
  'home.diskIo': {AppLang.en: 'Disk I/O', AppLang.zh: '磁盘 I/O'},
  'home.dontSave': {AppLang.en: 'Don\'t save', AppLang.zh: '不保存'},
  'home.down': {AppLang.en: 'Down', AppLang.zh: '离线'},
  'home.endpoint': {AppLang.en: 'Endpoint', AppLang.zh: '端点'},
  'home.engine': {AppLang.en: 'Engine', AppLang.zh: '引擎'},
  'home.error': {AppLang.en: 'Error', AppLang.zh: '错误'},
  'home.extraFlags': {AppLang.en: 'Extra flags', AppLang.zh: '额外参数'},
  'home.failed': {AppLang.en: 'Failed', AppLang.zh: '失败'},
  'home.health': {AppLang.en: 'Health', AppLang.zh: '健康'},
  'home.healthy': {AppLang.en: 'Healthy', AppLang.zh: '正常'},
  'home.inMemory': {AppLang.en: 'In-memory', AppLang.zh: '内存模式'},
  'home.key': {AppLang.en: 'Key', AppLang.zh: '键'},
  'home.latency': {AppLang.en: 'Latency', AppLang.zh: '延迟'},
  'home.localDdbLogs': {AppLang.en: 'Local DynamoDB logs', AppLang.zh: '本地 DynamoDB 日志'},
  'home.localDynamoDb': {AppLang.en: 'Local DynamoDB', AppLang.zh: '本地 DynamoDB'},
  'home.logs': {AppLang.en: 'logs', AppLang.zh: '日志'},
  'home.logsTooltip': {AppLang.en: 'Logs', AppLang.zh: '日志'},
  'home.memory': {AppLang.en: 'Memory', AppLang.zh: '内存'},
  'home.monitor': {AppLang.en: 'monitor', AppLang.zh: '监控'},
  'home.multiDb': {AppLang.en: 'MultiDB', AppLang.zh: '多库'},
  'home.name': {AppLang.en: 'Name', AppLang.zh: '名称'},
  'home.native': {AppLang.en: 'Native', AppLang.zh: '原生'},
  'home.noDocker': {AppLang.en: '(no Docker)', AppLang.zh: '(无 Docker)'},
  'home.noJre': {AppLang.en: '(no JRE)', AppLang.zh: '(无 JRE)'},
  'home.noOutput': {AppLang.en: '(no output)', AppLang.zh: '(无输出)'},
  'home.off': {AppLang.en: 'Off', AppLang.zh: '关'},
  'home.on': {AppLang.en: 'On', AppLang.zh: '开'},
  'home.opsPerSec': {AppLang.en: 'Ops/s', AppLang.zh: '操作/秒'},
  'home.permanentlyRemove': {AppLang.en: 'Permanently remove', AppLang.zh: '永久删除'},
  'home.persisted': {AppLang.en: 'Persisted', AppLang.zh: '持久化'},
  'home.port': {AppLang.en: 'Port', AppLang.zh: '端口'},
  'home.preparing': {AppLang.en: 'Preparing…', AppLang.zh: '准备中…'},
  'home.ready': {AppLang.en: 'Ready', AppLang.zh: '就绪'},
  'home.region': {AppLang.en: 'Region', AppLang.zh: '区域'},
  'home.remove': {AppLang.en: 'Remove', AppLang.zh: '移除'},
  'home.restarting': {AppLang.en: 'Restarting…', AppLang.zh: '重启中…'},
  'home.restarts': {AppLang.en: 'Restarts', AppLang.zh: '重启次数'},
  'home.restore': {AppLang.en: 'restore', AppLang.zh: '恢复'},
  'home.restored': {AppLang.en: 'Restored', AppLang.zh: '已恢复'},
  'home.revert': {AppLang.en: 'Restore', AppLang.zh: '还原'},
  'home.revertedChanges': {AppLang.en: 'Reverted unsaved changes', AppLang.zh: '已还原未保存的更改'},
  'home.running': {AppLang.en: 'Running', AppLang.zh: '运行中'},
  'home.save': {AppLang.en: 'Save', AppLang.zh: '保存'},
  'home.saveBeforeStart': {AppLang.en: 'Save the config before starting it', AppLang.zh: '启动前请先保存配置'},
  'home.saveFailed': {AppLang.en: 'Save failed', AppLang.zh: '保存失败'},
  'home.saved': {AppLang.en: 'Saved', AppLang.zh: '已保存'},
  'home.secretAccessKey': {AppLang.en: 'SecretAccessKey', AppLang.zh: '秘密访问密钥'},
  'home.sessionToken': {AppLang.en: 'SessionToken', AppLang.zh: '会话令牌'},
  'home.start': {AppLang.en: 'Start', AppLang.zh: '启动'},
  'home.startFailed': {AppLang.en: 'Start failed', AppLang.zh: '启动失败'},
  'home.startingAnyway': {AppLang.en: 'Starting anyway would fail or corrupt the data. Choose how to fix it:', AppLang.zh: '强行启动会失败或损坏数据。请选择修复方式:'},
  'home.status': {AppLang.en: 'Status', AppLang.zh: '状态'},
  'home.stop': {AppLang.en: 'Stop', AppLang.zh: '停止'},
  'home.stopFailed': {AppLang.en: 'Stop failed', AppLang.zh: '停止失败'},
  'home.stopped': {AppLang.en: 'Stopped', AppLang.zh: '已停止'},
  'home.storage': {AppLang.en: 'Storage', AppLang.zh: '存储'},
  'home.storageManagedByLocalstack': {AppLang.en: 'storage: managed by LocalStack', AppLang.zh: '存储:由 LocalStack 管理'},
  'home.table': {AppLang.en: 'Table', AppLang.zh: '表'},
  'home.tableMismatchTitle': {AppLang.en: 'Table format mismatch', AppLang.zh: '表格式不匹配'},
  'home.tableRenamedHint': {AppLang.en: 'Table renamed — Save, then Start again', AppLang.zh: '表已重命名 — 请保存后重新启动'},
  'home.tapToRestore': {AppLang.en: 'tap ▶ to restore', AppLang.zh: '点击 ▶ 恢复'},
  'home.throttled': {AppLang.en: 'Throttled', AppLang.zh: '限流'},
  'home.unnamedParen': {AppLang.en: '(unnamed)', AppLang.zh: '(未命名)'},
  'home.unsavedChanges': {AppLang.en: 'Unsaved changes', AppLang.zh: '未保存的更改'},
  'home.unsavedChangesBody': {AppLang.en: 'This config has unsaved changes. Do you want to save them before continuing?', AppLang.zh: '此配置有未保存的更改。是否在继续前保存?'},
  'home.uptime': {AppLang.en: 'Uptime', AppLang.zh: '运行时长'},
  'home.url': {AppLang.en: 'Url', AppLang.zh: '地址'},
  'home.useRecommendedConfig': {AppLang.en: 'Use recommended config', AppLang.zh: '使用推荐配置'},
  'home.value': {AppLang.en: 'Value', AppLang.zh: '值'},
  'home.version': {AppLang.en: 'Version', AppLang.zh: '版本'},
  'home.volume': {AppLang.en: 'Volume', AppLang.zh: '数据卷'},
  'ep.tables': {AppLang.en: 'Tables', AppLang.zh: '表'},
  'ep.filterTables': {AppLang.en: 'Filter tables…', AppLang.zh: '筛选表…'},
  'ep.refresh': {AppLang.en: 'Refresh', AppLang.zh: '刷新'},
  'ep.awsReadOnly': {AppLang.en: 'AWS · read-only', AppLang.zh: 'AWS · 只读'},
  'ep.endpoint': {AppLang.en: 'endpoint', AppLang.zh: '端点'},
  'ep.localLoopback': {AppLang.en: 'Local · loopback', AppLang.zh: '本地 · 回环'},
  'ep.awsModeBanner': {AppLang.en: 'AWS mode — table lifecycle is disabled; the manager cannot distinguish test from production.', AppLang.zh: 'AWS 模式 — 表生命周期操作已禁用;管理器无法区分测试环境与生产环境。'},
  'ep.cannotListTables': {AppLang.en: 'Cannot list tables', AppLang.zh: '无法列出表'},
  'ep.retry': {AppLang.en: 'Retry', AppLang.zh: '重试'},
  'ep.noTables': {AppLang.en: 'No tables', AppLang.zh: '没有表'},
  'ep.noTablesHint': {AppLang.en: 'This endpoint has no tables. Start a config with Auto-create, or a config bound to a missing table shows a Provision row here.', AppLang.zh: '此端点没有任何表。启动一个开启了 Auto-create 的配置,或者绑定到缺失表的配置会在此处显示一个预置(Provision)行。'},
  'ep.noTablesMatch': {AppLang.en: 'No tables match', AppLang.zh: '没有匹配的表'},
  'ep.missing': {AppLang.en: '(missing)', AppLang.zh: '(缺失)'},
  'ep.provision': {AppLang.en: 'Provision', AppLang.zh: '预置'},
  'ep.browse': {AppLang.en: 'Browse', AppLang.zh: '浏览'},
  'ep.tableOperations': {AppLang.en: 'Table operations', AppLang.zh: '表操作'},
  'ep.purgeItems': {AppLang.en: 'Purge items', AppLang.zh: '清空项'},
  'ep.recreateTable': {AppLang.en: 'Recreate table', AppLang.zh: '重建表'},
  'ep.deleteTable': {AppLang.en: 'Delete table', AppLang.zh: '删除表'},
  'ep.failedToListTables': {AppLang.en: 'failed to list tables', AppLang.zh: '列出表失败'},
  'ep.inspectFailed': {AppLang.en: 'inspect failed', AppLang.zh: '检查失败'},
  'ep.notAllowed': {AppLang.en: 'not allowed', AppLang.zh: '不允许'},
  'ep.purgingItems': {AppLang.en: 'Purging items…', AppLang.zh: '正在清空项…'},
  'ep.purgeFailed': {AppLang.en: 'purge failed', AppLang.zh: '清空失败'},
  'ep.deletingTable': {AppLang.en: 'Deleting table…', AppLang.zh: '正在删除表…'},
  'ep.deleteFailed': {AppLang.en: 'delete failed', AppLang.zh: '删除失败'},
  'ep.deletedTable': {AppLang.en: 'Deleted table', AppLang.zh: '已删除表'},
  'ep.typeTableName': {AppLang.en: 'Type the table name to confirm:', AppLang.zh: '输入表名以确认:'},
  'ep.cancel': {AppLang.en: 'Cancel', AppLang.zh: '取消'},
  'ep.delete': {AppLang.en: 'Delete', AppLang.zh: '删除'},
  'ep.purge': {AppLang.en: 'Purge', AppLang.zh: '清空'},
  'ep.purgeAllItemsFrom': {AppLang.en: 'Purge all items from', AppLang.zh: '清空表的所有项'},
  'ep.unknownItemCount': {AppLang.en: 'unknown item count', AppLang.zh: '未知项数'},
  'ep.runningConfigsStayUp': {AppLang.en: 'running config(s) use this table; they stay up and will see it empty.', AppLang.zh: '个正在运行的配置使用此表;它们会保持运行并看到空表。'},
  'ep.precheckFailed': {AppLang.en: 'precheck failed', AppLang.zh: '预检失败'},
  'ep.provisioningTable': {AppLang.en: 'Provisioning table…', AppLang.zh: '正在预置表…'},
  'ep.recreatingTable': {AppLang.en: 'Recreating table…', AppLang.zh: '正在重建表…'},
  'ep.tableProvisioned': {AppLang.en: 'Table provisioned', AppLang.zh: '表已预置'},
  'ep.tableRecreated': {AppLang.en: 'Table recreated', AppLang.zh: '表已重建'},
  'ep.operationFailed': {AppLang.en: 'operation failed', AppLang.zh: '操作失败'},
  'ep.provisionTable': {AppLang.en: 'Provision table', AppLang.zh: '预置表'},
  'ep.recreate': {AppLang.en: 'Recreate', AppLang.zh: '重建'},
  'tbl.instanceNotRunning': {AppLang.en: 'Instance not running', AppLang.zh: '实例未运行'},
  'tbl.startToBrowseTable': {AppLang.en: 'Start this config to browse its DynamoDB table.', AppLang.zh: '启动此配置以浏览其 DynamoDB 表。'},
  'tbl.noTableConfigured': {AppLang.en: 'No table configured', AppLang.zh: '未配置表'},
  'tbl.setTableNameToBrowse': {AppLang.en: 'Set a Table name in Configure to browse it.', AppLang.zh: '在配置中设置表名以浏览它。'},
  'tbl.cannotReadTable': {AppLang.en: 'Cannot read table', AppLang.zh: '无法读取表'},
  'tbl.retry': {AppLang.en: 'Retry', AppLang.zh: '重试'},
  'tbl.failedDescribeTable': {AppLang.en: 'failed to describe table', AppLang.zh: '描述表失败'},
  'tbl.queryFailed': {AppLang.en: 'query failed', AppLang.zh: '查询失败'},
  'tbl.browsingReadOnly': {AppLang.en: 'Browsing · read-only', AppLang.zh: '浏览中 · 只读'},
  'tbl.backTo': {AppLang.en: 'Back to', AppLang.zh: '返回'},
  'tbl.refresh': {AppLang.en: 'Refresh', AppLang.zh: '刷新'},
  'tbl.scanOrQueryItems': {AppLang.en: 'Scan or query items', AppLang.zh: '扫描或查询项'},
  'tbl.expandToQueryOrScan': {AppLang.en: 'Expand to query or scan items.', AppLang.zh: '展开以查询或扫描项。'},
  'tbl.scan': {AppLang.en: 'Scan', AppLang.zh: '扫描'},
  'tbl.query': {AppLang.en: 'Query', AppLang.zh: '查询'},
  'tbl.run': {AppLang.en: 'Run', AppLang.zh: '运行'},
  'tbl.reset': {AppLang.en: 'Reset', AppLang.zh: '重置'},
  'tbl.selectTableOrIndex': {AppLang.en: 'Select a table or index', AppLang.zh: '选择表或索引'},
  'tbl.tableLabel': {AppLang.en: 'Table', AppLang.zh: '表'},
  'tbl.indexLabel': {AppLang.en: 'Index', AppLang.zh: '索引'},
  'tbl.selectAttributeProjection': {AppLang.en: 'Select attribute projection', AppLang.zh: '选择属性投影'},
  'tbl.allAttributes': {AppLang.en: 'All attributes', AppLang.zh: '全部属性'},
  'tbl.specificAttributes': {AppLang.en: 'Specific attributes', AppLang.zh: '指定属性'},
  'tbl.enterAttributeName': {AppLang.en: 'Enter attribute name', AppLang.zh: '输入属性名'},
  'tbl.addAttribute': {AppLang.en: 'Add attribute', AppLang.zh: '添加属性'},
  'tbl.partitionKey': {AppLang.en: 'Partition key', AppLang.zh: '分区键'},
  'tbl.enterAttributeValue': {AppLang.en: 'Enter attribute value', AppLang.zh: '输入属性值'},
  'tbl.sortKey': {AppLang.en: 'Sort key ', AppLang.zh: '排序键'},
  'tbl.and': {AppLang.en: 'and', AppLang.zh: '和'},
  'tbl.sortDescending': {AppLang.en: 'Sort descending', AppLang.zh: '降序排序'},
  'tbl.filters': {AppLang.en: 'Filters', AppLang.zh: '筛选器'},
  'tbl.optional': {AppLang.en: '  – optional', AppLang.zh: '  – 可选'},
  'tbl.attributeName': {AppLang.en: 'Attribute name', AppLang.zh: '属性名'},
  'tbl.condition': {AppLang.en: 'Condition', AppLang.zh: '条件'},
  'tbl.type': {AppLang.en: 'Type', AppLang.zh: '类型'},
  'tbl.value': {AppLang.en: 'Value', AppLang.zh: '值'},
  'tbl.addFilter': {AppLang.en: 'Add filter', AppLang.zh: '添加筛选器'},
  'tbl.notRequired': {AppLang.en: 'Not required', AppLang.zh: '无需填写'},
  'tbl.remove': {AppLang.en: 'Remove', AppLang.zh: '移除'},
  'tbl.itemsReturned': {AppLang.en: 'Items returned', AppLang.zh: '返回项数'},
  'tbl.preferences': {AppLang.en: 'Preferences', AppLang.zh: '偏好设置'},
  'tbl.actions': {AppLang.en: 'Actions', AppLang.zh: '操作'},
  'tbl.editItem': {AppLang.en: 'Edit item', AppLang.zh: '编辑项'},
  'tbl.duplicateItem': {AppLang.en: 'Duplicate item', AppLang.zh: '复制项'},
  'tbl.deleteItems': {AppLang.en: 'Delete items', AppLang.zh: '删除项'},
  'tbl.exportToCsv': {AppLang.en: 'Export to CSV', AppLang.zh: '导出为 CSV'},
  'tbl.createItem': {AppLang.en: 'Create item', AppLang.zh: '新建项'},
  'tbl.noItems': {AppLang.en: 'No items', AppLang.zh: '无项'},
  'tbl.noItemsToDisplay': {AppLang.en: 'No items to display. Adjust the scan or query above.', AppLang.zh: '没有可显示的项。请调整上方的扫描或查询。'},
  'tbl.pageSize': {AppLang.en: 'Page size', AppLang.zh: '每页数量'},
  'tbl.itemsWord': {AppLang.en: 'items', AppLang.zh: '项'},
  'tbl.selectAll': {AppLang.en: 'Select all', AppLang.zh: '全选'},
  'tbl.deselectAll': {AppLang.en: 'Deselect all', AppLang.zh: '取消全选'},
  'tbl.cancel': {AppLang.en: 'Cancel', AppLang.zh: '取消'},
  'tbl.saveChanges': {AppLang.en: 'Save changes', AppLang.zh: '保存更改'},
  'tbl.projectionKeyMissing': {AppLang.en: 'This result doesn’t include the item’s full key (projection) — switch to “All attributes” first.', AppLang.zh: '此结果未包含该项的完整键(投影)—— 请先切换到“全部属性”。'},
  'tbl.couldntFetchItem': {AppLang.en: 'Couldn’t fetch the full item', AppLang.zh: '无法获取完整项'},
  'tbl.itemCreated': {AppLang.en: 'Item created', AppLang.zh: '已创建项'},
  'tbl.itemSaved': {AppLang.en: 'Item saved', AppLang.zh: '已保存项'},
  'tbl.saveFailed': {AppLang.en: 'save failed', AppLang.zh: '保存失败'},
  'tbl.itemDdbJson': {AppLang.en: 'Item (DynamoDB JSON)', AppLang.zh: '项 (DynamoDB JSON)'},
  'tbl.copy': {AppLang.en: 'Copy', AppLang.zh: '复制'},
  'tbl.copied': {AppLang.en: 'Copied', AppLang.zh: '已复制'},
  'tbl.close': {AppLang.en: 'Close', AppLang.zh: '关闭'},
  'tbl.missingKeyAttrs': {AppLang.en: 'A selected item is missing its key attributes (projection?)', AppLang.zh: '所选项缺少其键属性(投影?)'},
  'tbl.delete': {AppLang.en: 'Delete', AppLang.zh: '删除'},
  'tbl.itemsParen': {AppLang.en: 'item(s)', AppLang.zh: '个项'},
  'tbl.deleted': {AppLang.en: 'Deleted', AppLang.zh: '已删除'},
  'tbl.failed': {AppLang.en: 'failed', AppLang.zh: '失败'},
  'tbl.exported': {AppLang.en: 'Exported', AppLang.zh: '已导出'},
  'tbl.rowsSuffix': {AppLang.en: 'row(s)', AppLang.zh: '行'},
  'tbl.csvClipboardFallback': {AppLang.en: 'Couldn’t write to Downloads — CSV copied to clipboard instead', AppLang.zh: '无法写入下载文件夹 —— CSV 已改为复制到剪贴板'},
  'tbl.rawWriteBody': {AppLang.en: 'This writes directly to DynamoDB, bypassing redimos’s key/value encoding. An item that doesn’t match redimos’s format can corrupt what the proxy reads — for redimos data, prefer the Browser or Console tab. Continue anyway?', AppLang.zh: '此操作将直接写入 DynamoDB,绕过 redimos 的键/值编码。不符合 redimos 格式的项可能会破坏代理读取的内容 —— 对于 redimos 数据,建议使用浏览器或命令行选项卡。仍要继续吗?'},
  'tbl.condEq': {AppLang.en: 'Equal to', AppLang.zh: '等于'},
  'tbl.condNe': {AppLang.en: 'Not equal to', AppLang.zh: '不等于'},
  'tbl.condLe': {AppLang.en: 'Less than or equal to', AppLang.zh: '小于或等于'},
  'tbl.condLt': {AppLang.en: 'Less than', AppLang.zh: '小于'},
  'tbl.condGe': {AppLang.en: 'Greater than or equal to', AppLang.zh: '大于或等于'},
  'tbl.condGt': {AppLang.en: 'Greater than', AppLang.zh: '大于'},
  'tbl.condBetween': {AppLang.en: 'Between', AppLang.zh: '介于'},
  'tbl.condBeginsWith': {AppLang.en: 'Begins with', AppLang.zh: '开头为'},
  'tbl.condExists': {AppLang.en: 'Exists', AppLang.zh: '存在'},
  'tbl.condNotExists': {AppLang.en: 'Not exists', AppLang.zh: '不存在'},
  'tbl.condContains': {AppLang.en: 'Contains', AppLang.zh: '包含'},
  'tbl.condNotContains': {AppLang.en: 'Not contains', AppLang.zh: '不包含'},
  'pq.runWriteTitle': {AppLang.en: 'Run write statement?', AppLang.zh: '运行写入语句?'},
  'pq.cancel': {AppLang.en: 'Cancel', AppLang.zh: '取消'},
  'pq.run': {AppLang.en: 'Run', AppLang.zh: '运行'},
  'pq.instanceNotRunning': {AppLang.en: 'Instance not running', AppLang.zh: '实例未运行'},
  'pq.instanceNotRunningSub': {AppLang.en: 'Start this config to run PartiQL statements against its table.', AppLang.zh: '启动此配置以对其表运行 PartiQL 语句。'},
  'pq.noTableConfigured': {AppLang.en: 'No table configured', AppLang.zh: '未配置表'},
  'pq.noTableConfiguredSub': {AppLang.en: 'Set a Table name in Configure to run PartiQL statements.', AppLang.zh: '在“配置”中设置表名以运行 PartiQL 语句。'},
  'pq.partiqlEditor': {AppLang.en: 'PartiQL editor', AppLang.zh: 'PartiQL 编辑器'},
  'pq.statementTemplates': {AppLang.en: 'Statement templates', AppLang.zh: '语句模板'},
  'pq.templates': {AppLang.en: 'Templates', AppLang.zh: '模板'},
  'pq.tplScanTable': {AppLang.en: 'Scan table', AppLang.zh: '扫描表'},
  'pq.tplQueryByPk': {AppLang.en: 'Query by partition key', AppLang.zh: '按分区键查询'},
  'pq.tplCountItems': {AppLang.en: 'Count items', AppLang.zh: '统计项数'},
  'pq.tplInsertItem': {AppLang.en: 'Insert item', AppLang.zh: '插入项'},
  'pq.tplUpdateItem': {AppLang.en: 'Update item', AppLang.zh: '更新项'},
  'pq.tplDeleteItem': {AppLang.en: 'Delete item', AppLang.zh: '删除项'},
  'pq.typeStatement': {AppLang.en: 'type a PartiQL statement', AppLang.zh: '输入一条 PartiQL 语句'},
  'pq.clear': {AppLang.en: 'Clear', AppLang.zh: '清除'},
  'pq.tableView': {AppLang.en: 'Table view', AppLang.zh: '表格视图'},
  'pq.jsonView': {AppLang.en: 'JSON view', AppLang.zh: 'JSON 视图'},
  'pq.failed': {AppLang.en: 'Failed', AppLang.zh: '失败'},
  'pq.completed': {AppLang.en: 'Completed', AppLang.zh: '已完成'},
  'pq.startedOn': {AppLang.en: 'Started on', AppLang.zh: '开始于'},
  'pq.elapsedTime': {AppLang.en: 'Elapsed time', AppLang.zh: '耗时'},
  'pq.errorOccurred': {AppLang.en: 'An error occurred during the execution of the command.', AppLang.zh: '执行命令时发生错误。'},
  'pq.itemsReturned': {AppLang.en: 'Items returned', AppLang.zh: '返回项数'},
  'pq.preferences': {AppLang.en: 'Preferences', AppLang.zh: '首选项'},
  'pq.findItems': {AppLang.en: 'Find items', AppLang.zh: '查找项'},
  'pq.nextPage': {AppLang.en: 'Next page', AppLang.zh: '下一页'},
  'pq.noItems': {AppLang.en: 'No items', AppLang.zh: '无项'},
  'pq.noItemsFromStatement': {AppLang.en: 'The statement returned no items.', AppLang.zh: '该语句未返回任何项。'},
  'pq.noItemsMatchFilter': {AppLang.en: 'No items match the filter.', AppLang.zh: '没有项匹配该筛选条件。'},
  'pq.copy': {AppLang.en: 'Copy', AppLang.zh: '复制'},
  'pq.copied': {AppLang.en: 'Copied', AppLang.zh: '已复制'},
  'pq.selectAll': {AppLang.en: 'Select all', AppLang.zh: '全选'},
  'pq.deselectAll': {AppLang.en: 'Deselect all', AppLang.zh: '取消全选'},
  'pq.saveChanges': {AppLang.en: 'Save changes', AppLang.zh: '保存更改'},
  'pq.itemDdbJson': {AppLang.en: 'Item (DynamoDB JSON)', AppLang.zh: '项(DynamoDB JSON)'},
  'pq.close': {AppLang.en: 'Close', AppLang.zh: '关闭'},
  'br.add': {AppLang.en: 'Add', AppLang.zh: '添加'},
  'br.addNewLine': {AppLang.en: 'Add New Line', AppLang.zh: '新增一行'},
  'br.applyTtl': {AppLang.en: 'Apply TTL (≤0 = persist)', AppLang.zh: '应用 TTL(≤0 = 持久化)'},
  'br.asc': {AppLang.en: 'ASC', AppLang.zh: '升序'},
  'br.cancel': {AppLang.en: 'Cancel', AppLang.zh: '取消'},
  'br.cannotReadKey': {AppLang.en: 'Cannot read key', AppLang.zh: '无法读取键'},
  'br.clear': {AppLang.en: 'Clear', AppLang.zh: '清除'},
  'br.close': {AppLang.en: 'Close', AppLang.zh: '关闭'},
  'br.commandCopied': {AppLang.en: 'Command copied', AppLang.zh: '已复制命令'},
  'br.connecting': {AppLang.en: 'Connecting…', AppLang.zh: '连接中…'},
  'br.copied': {AppLang.en: 'Copied', AppLang.zh: '已复制'},
  'br.copy': {AppLang.en: 'Copy', AppLang.zh: '复制'},
  'br.copyAsCommand': {AppLang.en: 'Copy as command', AppLang.zh: '复制为命令'},
  'br.copyKeyName': {AppLang.en: 'Copy key name', AppLang.zh: '复制键名'},
  'br.copyName': {AppLang.en: 'Copy name', AppLang.zh: '复制名称'},
  'br.copyValue': {AppLang.en: 'Copy value', AppLang.zh: '复制值'},
  'br.create': {AppLang.en: 'Create', AppLang.zh: '创建'},
  'br.delete': {AppLang.en: 'Delete', AppLang.zh: '删除'},
  'br.deleteKey': {AppLang.en: 'Delete key', AppLang.zh: '删除键'},
  'br.deleteKeyQ': {AppLang.en: 'Delete key?', AppLang.zh: '删除键?'},
  'br.deleteWholeFolder': {AppLang.en: 'Delete whole folder?', AppLang.zh: '删除整个文件夹?'},
  'br.deleted': {AppLang.en: 'Deleted', AppLang.zh: '已删除'},
  'br.desc': {AppLang.en: 'DESC', AppLang.zh: '降序'},
  'br.edit': {AppLang.en: 'Edit', AppLang.zh: '编辑'},
  'br.editLine': {AppLang.en: 'Edit Line', AppLang.zh: '编辑行'},
  'br.empty': {AppLang.en: 'Empty', AppLang.zh: '空'},
  'br.exitSelect': {AppLang.en: 'Exit select', AppLang.zh: '退出选择'},
  'br.field': {AppLang.en: 'Field', AppLang.zh: '字段'},
  'br.fieldEqValue': {AppLang.en: 'field=value', AppLang.zh: '字段=值'},
  'br.filterLoadedOnly': {AppLang.en: 'Filter applies to loaded rows only — load more to search further.', AppLang.zh: '筛选仅作用于已加载的行 — 加载更多以继续搜索。'},
  'br.firstValue': {AppLang.en: 'first value', AppLang.zh: '首个值'},
  'br.flatView': {AppLang.en: 'Flat view', AppLang.zh: '平铺视图'},
  'br.head': {AppLang.en: 'Head', AppLang.zh: '头部'},
  'br.instanceNotRunning': {AppLang.en: 'Instance not running', AppLang.zh: '实例未运行'},
  'br.key': {AppLang.en: 'Key', AppLang.zh: '键'},
  'br.keyName': {AppLang.en: 'Key name', AppLang.zh: '键名'},
  'br.keyNameCopied': {AppLang.en: 'Key name copied', AppLang.zh: '已复制键名'},
  'br.keyNoLongerExists': {AppLang.en: 'Key no longer exists (it may have been deleted).', AppLang.zh: '键已不存在(可能已被删除)。'},
  'br.keyPlural': {AppLang.en: 'key(s)', AppLang.zh: '个键'},
  'br.keysCouldNotDelete': {AppLang.en: 'key(s) could not be deleted', AppLang.zh: '个键无法删除'},
  'br.keysQ': {AppLang.en: 'keys?', AppLang.zh: '个键?'},
  'br.keysQCannotUndo': {AppLang.en: 'keys? This cannot be undone.', AppLang.zh: '个键?此操作无法撤销。'},
  'br.keysUnit': {AppLang.en: 'keys', AppLang.zh: '个键'},
  'br.keywordSearch': {AppLang.en: 'Keyword Search', AppLang.zh: '关键字搜索'},
  'br.loadAll': {AppLang.en: 'Load all', AppLang.zh: '全部加载'},
  'br.loadAllKeysQ': {AppLang.en: 'Load all keys?', AppLang.zh: '加载全部键?'},
  'br.loadAllWarning': {AppLang.en: 'This walks the entire keyspace with SCAN. On a large database it may take a while.', AppLang.zh: '这将使用 SCAN 遍历整个键空间。在大型数据库上可能需要一些时间。'},
  'br.loadMore': {AppLang.en: 'Load more', AppLang.zh: '加载更多'},
  'br.member': {AppLang.en: 'Member', AppLang.zh: '成员'},
  'br.multiDbOff': {AppLang.en: 'MultiDB is off for this config — SELECT has no effect (every DB maps to db0)', AppLang.zh: '此配置未开启 MultiDB — SELECT 无效(所有 DB 都映射到 db0)'},
  'br.newKey': {AppLang.en: 'New Key', AppLang.zh: '新建键'},
  'br.noKeySelected': {AppLang.en: 'No key selected', AppLang.zh: '未选择键'},
  'br.noKeys': {AppLang.en: 'No keys', AppLang.zh: '无键'},
  'br.noMatchInLoadedRows': {AppLang.en: 'No match in loaded rows', AppLang.zh: '已加载行中无匹配'},
  'br.ok': {AppLang.en: 'OK', AppLang.zh: '确定'},
  'br.open': {AppLang.en: 'Open', AppLang.zh: '打开'},
  'br.overwrite': {AppLang.en: 'Overwrite', AppLang.zh: '覆盖'},
  'br.overwriteKeyQ': {AppLang.en: 'Overwrite key?', AppLang.zh: '覆盖键?'},
  'br.permDelete': {AppLang.en: 'Permanently delete', AppLang.zh: '确定永久删除'},
  'br.pickKey': {AppLang.en: 'Pick a key on the left to view it.', AppLang.zh: '在左侧选择一个键以查看。'},
  'br.pushAt': {AppLang.en: 'Push at: ', AppLang.zh: '插入位置: '},
  'br.reconnectedReloaded': {AppLang.en: 'Reconnected to the server — reloaded this key. Try again.', AppLang.zh: '已重新连接到服务器 — 已重新加载该键。请重试。'},
  'br.refresh': {AppLang.en: 'Refresh', AppLang.zh: '刷新'},
  'br.renameNotSupported': {AppLang.en: 'redimos does not support RENAME — key names are read-only here', AppLang.zh: 'redimos 不支持 RENAME — 此处键名为只读'},
  'br.reset': {AppLang.en: 'Reset', AppLang.zh: '重置'},
  'br.scanDeleteFolder': {AppLang.en: 'Scan & delete whole folder', AppLang.zh: '扫描并删除整个文件夹'},
  'br.scanning': {AppLang.en: 'Scanning…', AppLang.zh: '扫描中…'},
  'br.score': {AppLang.en: 'Score', AppLang.zh: '分数'},
  'br.scoreEqMember': {AppLang.en: 'score=member', AppLang.zh: '分数=成员'},
  'br.search': {AppLang.en: 'Search', AppLang.zh: '搜索'},
  'br.selectDatabase': {AppLang.en: 'Select database (SELECT)', AppLang.zh: '选择数据库(SELECT)'},
  'br.selectMultiple': {AppLang.en: 'Select multiple', AppLang.zh: '多选'},
  'br.selected': {AppLang.en: 'selected', AppLang.zh: '已选'},
  'br.size': {AppLang.en: 'Size', AppLang.zh: '大小'},
  'br.startToBrowse': {AppLang.en: 'Start this config to browse its keyspace.', AppLang.zh: '启动此配置以浏览其键空间。'},
  'br.tail': {AppLang.en: 'Tail', AppLang.zh: '尾部'},
  'br.total': {AppLang.en: 'Total', AppLang.zh: '总数'},
  'br.treeView': {AppLang.en: 'Tree view', AppLang.zh: '树状视图'},
  'br.type': {AppLang.en: 'Type', AppLang.zh: '类型'},
  'br.unsupportedType': {AppLang.en: 'Unsupported type', AppLang.zh: '不支持的类型'},
  'br.value': {AppLang.en: 'Value', AppLang.zh: '值'},
  'br.valueCopied': {AppLang.en: 'Value copied', AppLang.zh: '已复制值'},
  'br.view': {AppLang.en: 'View', AppLang.zh: '查看'},
  'br.viewFormatValue': {AppLang.en: 'View / format value', AppLang.zh: '查看 / 格式化值'},
  'cmd.unbalancedQuotes': {AppLang.en: 'unbalanced quotes', AppLang.zh: '引号不匹配'},
  'cmd.notConnectedStart': {AppLang.en: 'not connected — start the instance', AppLang.zh: '未连接 — 请启动实例'},
  'cmd.instanceFailedToStart': {AppLang.en: 'Instance failed to start', AppLang.zh: '实例启动失败'},
  'cmd.instanceNotRunning': {AppLang.en: 'Instance not running', AppLang.zh: '实例未运行'},
  'cmd.startConfigHint': {AppLang.en: 'Start this config to open an interactive redis-cli console.', AppLang.zh: '启动此配置以打开交互式 redis-cli 控制台。'},
  'cmd.connectingPrompt': {AppLang.en: 'connecting…', AppLang.zh: '连接中…'},
  'cmd.typeCommandHint': {AppLang.en: 'type a command — e.g. PING, SET k v, GET k', AppLang.zh: '输入命令 — 例如 PING, SET k v, GET k'},
  'cmd.notConnected': {AppLang.en: 'not connected', AppLang.zh: '未连接'},
  'cmd.reconnect': {AppLang.en: 'Reconnect', AppLang.zh: '重新连接'},
  'cmd.clear': {AppLang.en: 'Clear', AppLang.zh: '清除'},
  'cmd.connectedTo': {AppLang.en: 'Connected to', AppLang.zh: '已连接到'},
  'cmd.redisCompatible': {AppLang.en: '— Redis-compatible.', AppLang.zh: '— 兼容 Redis。'},
  'cmd.scanTip': {AppLang.en: 'Use SCAN (not KEYS) and HMSET for multi-field hashes.', AppLang.zh: '使用 SCAN(而非 KEYS)和 HMSET 处理多字段哈希。'},
  'cmd.tryCommand': {AppLang.en: 'Try a command — click to insert, then press Enter:', AppLang.zh: '试试命令 — 点击插入,然后按回车:'},
  'cmd.historyHint': {AppLang.en: 'History: ↑ / ↓   ·   Clear: the ⌫ button on the right', AppLang.zh: '历史: ↑ / ↓   ·   清除: 右侧的 ⌫ 按钮'},
  'cmd.reconnecting': {AppLang.en: 'Reconnecting…', AppLang.zh: '重新连接中…'},
  'cmd.connecting': {AppLang.en: 'Connecting…', AppLang.zh: '连接中…'},
  'item.createItem': {AppLang.en: 'Create item', AppLang.zh: '创建项'},
  'item.editItem': {AppLang.en: 'Edit item', AppLang.zh: '编辑项'},
  'item.viewDdbJson': {AppLang.en: 'View DynamoDB JSON', AppLang.zh: '查看 DynamoDB JSON'},
  'item.formTab': {AppLang.en: 'Form', AppLang.zh: '表单'},
  'item.cancel': {AppLang.en: 'Cancel', AppLang.zh: '取消'},
  'item.saveChanges': {AppLang.en: 'Save changes', AppLang.zh: '保存更改'},
  'item.attributes': {AppLang.en: 'Attributes', AppLang.zh: '属性'},
  'item.attributeName': {AppLang.en: 'Attribute name', AppLang.zh: '属性名'},
  'item.type': {AppLang.en: 'Type', AppLang.zh: '类型'},
  'item.value': {AppLang.en: 'Value', AppLang.zh: '值'},
  'item.addNewAttribute': {AppLang.en: 'Add new attribute', AppLang.zh: '添加新属性'},
  'item.partitionKey': {AppLang.en: 'Partition key', AppLang.zh: '分区键'},
  'item.sortKey': {AppLang.en: 'Sort key', AppLang.zh: '排序键'},
  'item.remove': {AppLang.en: 'Remove', AppLang.zh: '移除'},
  'item.attrMissingName': {AppLang.en: 'an attribute is missing its name', AppLang.zh: '某个属性缺少名称'},
  'item.topLevelMustBeObject': {AppLang.en: 'top level must be an object', AppLang.zh: '顶层必须是一个对象'},
  'fmt.copied': {AppLang.en: 'Copied', AppLang.zh: '已复制'},
  'fmt.save': {AppLang.en: 'Save', AppLang.zh: '保存'},
  'fmt.customize': {AppLang.en: 'Customize', AppLang.zh: '自定义'},
  'fmt.size': {AppLang.en: 'Size', AppLang.zh: '大小'},
  'fmt.copy': {AppLang.en: 'Copy', AppLang.zh: '复制'},
  'fmt.saveFailed': {AppLang.en: 'Save failed', AppLang.zh: '保存失败'},
  'fmt.customFormatter': {AppLang.en: 'Custom Formatter', AppLang.zh: '自定义格式器'},
  'fmt.new': {AppLang.en: 'New', AppLang.zh: '新建'},
  'fmt.name': {AppLang.en: 'Name', AppLang.zh: '名称'},
  'fmt.formatter': {AppLang.en: 'Formatter', AppLang.zh: '格式器'},
  'fmt.operation': {AppLang.en: 'Operation', AppLang.zh: '操作'},
  'fmt.noData': {AppLang.en: 'No Data', AppLang.zh: '暂无数据'},
  'fmt.edit': {AppLang.en: 'Edit', AppLang.zh: '编辑'},
  'fmt.delete': {AppLang.en: 'Delete', AppLang.zh: '删除'},
  'fmt.close': {AppLang.en: 'Close', AppLang.zh: '关闭'},
  'fmt.nameCommandRequired': {AppLang.en: 'Name and Command are required.', AppLang.zh: '名称和命令为必填项。'},
  'fmt.nameCollides': {AppLang.en: 'Name collides with a built-in format or another formatter.', AppLang.zh: '名称与内置格式或其他格式器冲突。'},
  'fmt.nameLabel': {AppLang.en: '* Name', AppLang.zh: '* 名称'},
  'fmt.commandLabel': {AppLang.en: '* Command', AppLang.zh: '* 命令'},
  'fmt.params': {AppLang.en: 'Params', AppLang.zh: '参数'},
  'fmt.cancel': {AppLang.en: 'Cancel', AppLang.zh: '取消'},
  'fmt.ok': {AppLang.en: 'OK', AppLang.zh: '确定'},
};
