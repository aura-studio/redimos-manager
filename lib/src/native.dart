import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'models.dart';

// C signatures: every function returns a heap char* (freed via rm_free);
// the mutating ones take a single UTF-8 char* argument.
typedef _StrNativeFn = Pointer<Utf8> Function();
typedef _StrDartFn = Pointer<Utf8> Function();
typedef _StrArgNativeFn = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _StrArgDartFn = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNativeFn = Void Function(Pointer<Utf8>);
typedef _FreeDartFn = void Function(Pointer<Utf8>);

/// Invoke a `char* fn(char*)` core symbol from ANY isolate by re-opening the
/// (process-global, already-loaded) dynamic library and looking the symbol up
/// there. Used to run the blocking table-recreate off the UI isolate via
/// [Isolate.run] — the closure captures only the sendable String arguments.
String _callCoreSymbol(String libPath, String symbol, String arg) {
  final lib = DynamicLibrary.open(libPath);
  final fn = lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>(symbol);
  final free = lib.lookupFunction<_FreeNativeFn, _FreeDartFn>('rm_free');
  final a = arg.toNativeUtf8();
  try {
    final p = fn(a);
    final s = p.toDartString();
    free(p);
    return s;
  } finally {
    malloc.free(a);
  }
}

/// Thin Dart wrapper over the Go core dynamic library. All state (configs,
/// child processes) lives in Go; this just marshals JSON across the boundary.
class NativeCore {
  late final DynamicLibrary _lib;
  late final _StrDartFn _version, _load, _status, _stopAll, _restoreAll, _shutdown;
  late final _StrDartFn _ddbGet, _ddbStart, _ddbStop, _ddbLogs;
  late final _StrArgDartFn _saveConfig, _deleteConfig, _setSettings, _start, _stop, _logs;
  late final _StrArgDartFn _ddbSet, _inspectTable, _tableMeta, _tablePage, _partiql;
  late final _StrArgDartFn _tablePrecheck, _tableGetItem, _tablePutItem, _tableDeleteItem;
  late final _StrDartFn _getFormatters;
  late final _StrArgDartFn _setFormatters;
  late final _FreeDartFn _free;

  NativeCore() {
    _lib = DynamicLibrary.open(_resolveLibraryPath());
    _version = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_version');
    _load = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_load');
    _status = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_status');
    _stopAll = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_stop_all');
    _restoreAll = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_restore_all');
    _shutdown = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_shutdown');
    _saveConfig = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_save_config');
    _deleteConfig = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_delete_config');
    _setSettings = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_set_settings');
    _start = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_start');
    _stop = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_stop');
    _logs = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_logs');
    _ddbGet = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_ddb_get');
    _ddbStart = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_ddb_start');
    _ddbStop = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_ddb_stop');
    _ddbLogs = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_ddb_logs');
    _ddbSet = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_ddb_set');
    _inspectTable = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_inspect_table');
    _tableMeta = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_table_meta');
    _tablePage = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_table_page');
    _partiql = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_partiql');
    _tablePrecheck = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_table_precheck');
    _tableGetItem = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_table_get_item');
    _tablePutItem = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_table_put_item');
    _tableDeleteItem = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_table_delete_item');
    _getFormatters = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_get_formatters');
    _setFormatters = _lib.lookupFunction<_StrArgNativeFn, _StrArgDartFn>('rm_set_formatters');
    _free = _lib.lookupFunction<_FreeNativeFn, _FreeDartFn>('rm_free');
  }

  static String _resolveLibraryPath() {
    final base = _libBaseName();
    // 1) next to the executable (the bundled location — see build_native script)
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final beside = '$exeDir${Platform.pathSeparator}$base';
    if (File(beside).existsSync()) return beside;
    // 2) an override for `flutter run` dev loops
    final env = Platform.environment['REDIMOS_CORE_LIB'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    // 3) let the loader search (PATH / cwd)
    return base;
  }

  static String _libBaseName() {
    if (Platform.isWindows) return 'redimos_core.dll';
    if (Platform.isMacOS) return 'redimos_core.dylib';
    return 'redimos_core.so';
  }

  // ---- raw call helpers ----
  String _call0(_StrDartFn fn) {
    final p = fn();
    final s = p.toDartString();
    _free(p);
    return s;
  }

  String _call1(_StrArgDartFn fn, String arg) {
    final a = arg.toNativeUtf8();
    try {
      final p = fn(a);
      final s = p.toDartString();
      _free(p);
      return s;
    } finally {
      malloc.free(a);
    }
  }

  // ---- typed API ----
  String version() => _call0(_version);

  ({
    List<RedimosConfig> configs,
    List<DdbEndpoint> endpoints,
    List<ProxyInstance> instances,
    Settings settings,
    List<String> stopAllSnapshot,
  }) load() {
    final j = jsonDecode(_call0(_load)) as Map<String, dynamic>;
    // The core refuses to manage children when another app instance already
    // holds the single-instance lock; surface that instead of a broken UI.
    final lockError = j['lockError'];
    if (lockError != null) throw StateError(lockError.toString());
    final configs = ((j['configs'] as List?) ?? [])
        .map((e) => RedimosConfig.fromJson(e as Map<String, dynamic>))
        .toList();
    // v1.2 split view of the same configs, grouped by backend.
    final endpoints = ((j['endpoints'] as List?) ?? [])
        .map((e) => DdbEndpoint.fromJson(e as Map<String, dynamic>))
        .toList();
    final instances = ((j['instances'] as List?) ?? [])
        .map((e) => ProxyInstance.fromJson(e as Map<String, dynamic>))
        .toList();
    final settings =
        Settings.fromJson((j['settings'] as Map<String, dynamic>?) ?? {});
    final snap = ((j['stopAllSnapshot'] as List?) ?? [])
        .map((e) => e.toString())
        .toList();
    return (
      configs: configs,
      endpoints: endpoints,
      instances: instances,
      settings: settings,
      stopAllSnapshot: snap,
    );
  }

  Map<String, InstanceStatus> status() {
    final list = jsonDecode(_call0(_status)) as List;
    final out = <String, InstanceStatus>{};
    for (final e in list) {
      final s = InstanceStatus.fromJson(e as Map<String, dynamic>);
      out[s.id] = s;
    }
    return out;
  }

  /// Returns the saved config id, or throws with the core's error message.
  String saveConfig(RedimosConfig c) {
    final r = jsonDecode(_call1(_saveConfig, jsonEncode(c.toJson())))
        as Map<String, dynamic>;
    if (r['ok'] != true) throw StateError(r['error']?.toString() ?? 'save failed');
    return (r['id'] ?? c.id) as String;
  }

  void deleteConfig(String id) => _expectOk(_call1(_deleteConfig, id));
  void setSettings(Settings s) =>
      _expectOk(_call1(_setSettings, jsonEncode(s.toJson())));
  void start(String id) => _expectOk(_call1(_start, id));
  void stop(String id) => _expectOk(_call1(_stop, id));

  /// Inspect the DynamoDB table a config points at for a version/MultiDB
  /// mismatch with existing data. Never throws — returns an unchecked result
  /// on any failure.
  TableInspect inspectTable(RedimosConfig c) {
    try {
      return TableInspect.fromJson(
          jsonDecode(_call1(_inspectTable, jsonEncode(c.toJson()))) as Map<String, dynamic>);
    } catch (_) {
      return TableInspect();
    }
  }
  /// Table browser: the selectable Scan/Query targets (base table + indexes).
  TableMeta tableMeta(RedimosConfig c) {
    try {
      return TableMeta.fromJson(
          jsonDecode(_call1(_tableMeta, jsonEncode(c.toJson()))) as Map<String, dynamic>);
    } catch (e) {
      return TableMeta(ok: false, error: e.toString());
    }
  }

  /// Table browser: run one Scan/Query page. [req] is the tablePageReq map
  /// (config + op + filters + pagination). Never throws — returns ok:false.
  TablePage tablePage(Map<String, dynamic> req) {
    try {
      return TablePage.fromJson(
          jsonDecode(_call1(_tablePage, jsonEncode(req))) as Map<String, dynamic>);
    } catch (e) {
      return TablePage(ok: false, error: e.toString());
    }
  }

  /// PartiQL tab: execute one statement. Never throws — returns ok:false.
  PartiqlResult partiql(Map<String, dynamic> req) {
    try {
      return PartiqlResult.fromJson(
          jsonDecode(_call1(_partiql, jsonEncode(req))) as Map<String, dynamic>);
    } catch (e) {
      return PartiqlResult(ok: false, error: e.toString());
    }
  }

  /// AppBar "Stop all": stop every running config and return the ids that were
  /// running (recorded natively so the "restore" button survives an app restart).
  List<String> stopAll() {
    final j = jsonDecode(_call0(_stopAll)) as Map<String, dynamic>;
    return ((j['snapshot'] as List?) ?? []).map((e) => e.toString()).toList();
  }

  /// AppBar green "restore": start every config recorded by the last Stop all;
  /// returns the ids actually (re)started.
  List<String> restoreAll() {
    final j = jsonDecode(_call0(_restoreAll)) as Map<String, dynamic>;
    return ((j['started'] as List?) ?? []).map((e) => e.toString()).toList();
  }

  /// Terminate every managed child (redimos instances + Local DynamoDB). Call on
  /// app exit so nothing is left orphaned holding a port.
  void shutdown() => _call0(_shutdown);

  List<String> logs(String id) {
    final j = jsonDecode(_call1(_logs, id)) as Map<String, dynamic>;
    return ((j['lines'] as List?) ?? []).map((e) => e.toString()).toList();
  }

  // ---- Local DynamoDB ----
  LocalDdbInfo ddbGet() =>
      LocalDdbInfo.fromJson(jsonDecode(_call0(_ddbGet)) as Map<String, dynamic>);
  void ddbSet(LocalDdbConfig c) =>
      _expectOk(_call1(_ddbSet, jsonEncode(c.toJson())));
  void ddbStart() => _expectOk(_call0(_ddbStart));
  void ddbStop() => _expectOk(_call0(_ddbStop));

  List<String> ddbLogs() {
    final j = jsonDecode(_call0(_ddbLogs)) as Map<String, dynamic>;
    return ((j['lines'] as List?) ?? []).map((e) => e.toString()).toList();
  }

  // ---- destructive table lifecycle (Endpoint mode only; native re-guards) ----

  /// Info for the recreate confirmation dialog.
  Map<String, dynamic> tablePrecheck(String configId) =>
      jsonDecode(_call1(_tablePrecheck, configId)) as Map<String, dynamic>;

  /// Table tab: fetch one FULL item by [key] (DynamoDB-JSON key map), so the
  /// editor never edits a projection-truncated item. Returns {ok, item} / {ok:false}.
  Map<String, dynamic> tableGetItem(RedimosConfig c, Map<String, dynamic> key) {
    try {
      return jsonDecode(_call1(_tableGetItem, jsonEncode({'config': c.toJson(), 'key': key})))
          as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Table tab: write (create/replace) one item. [item] is DynamoDB-JSON.
  /// Endpoint-gated natively. Never throws — returns {ok:false, error}.
  Map<String, dynamic> tablePutItem(RedimosConfig c, Map<String, dynamic> item) {
    try {
      return jsonDecode(_call1(_tablePutItem, jsonEncode({'config': c.toJson(), 'item': item})))
          as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Table tab: delete one item by its [key] (DynamoDB-JSON key map). Endpoint-gated.
  Map<String, dynamic> tableDeleteItem(RedimosConfig c, Map<String, dynamic> key) {
    try {
      return jsonDecode(_call1(_tableDeleteItem, jsonEncode({'config': c.toJson(), 'key': key})))
          as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Endpoint tab: list every table on a config's endpoint (read-only). Runs on
  /// a background isolate — a ListTables + per-table DescribeTable fan-out (each
  /// with a 6s timeout) would otherwise freeze the UI on a large AWS account.
  /// Never throws — returns {ok:false, error} on any failure.
  Future<Map<String, dynamic>> epListTables(RedimosConfig c) async {
    final libPath = _resolveLibraryPath();
    final arg = jsonEncode(c.toJson());
    try {
      final raw = await Isolate.run(
          () => _callCoreSymbol(libPath, 'rm_ep_list_tables', arg));
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Stop dependents → delete table → restart with one-shot auto-create. Runs on
  /// a background isolate (the native call sleeps/polls for up to ~13s), so the
  /// UI stays responsive and the progress dialog animates. The isolate re-opens
  /// the process-global core library and invokes the same symbol.
  Future<Map<String, dynamic>> tableRecreate(String configId) async {
    final libPath = _resolveLibraryPath();
    final raw = await Isolate.run(
        () => _callCoreSymbol(libPath, 'rm_table_recreate', configId));
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Blast-radius info for a Purge/Delete confirmation on an arbitrary table
  /// (allowed?, endpoint, loopback, item count/age, bound running dependents).
  /// Read-only. Never throws — returns {ok:false, error} on failure.
  Future<Map<String, dynamic>> tableInspect(RedimosConfig c, String table) async {
    final libPath = _resolveLibraryPath();
    final arg = jsonEncode({'config': c.toJson(), 'table': table});
    try {
      final raw = await Isolate.run(
          () => _callCoreSymbol(libPath, 'rm_table_inspect', arg));
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Delete every item from a table (schema kept). Runs on a background isolate
  /// (a Scan + BatchWriteItem loop can take a while on a large table).
  Future<Map<String, dynamic>> tablePurge(RedimosConfig c, String table) async {
    final libPath = _resolveLibraryPath();
    final arg = jsonEncode({'config': c.toJson(), 'table': table});
    final raw =
        await Isolate.run(() => _callCoreSymbol(libPath, 'rm_table_purge', arg));
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Drop a table entirely (no recreate); stops bound running configs. Runs on a
  /// background isolate (the native call sleeps/polls for the delete to settle).
  Future<Map<String, dynamic>> tableDelete(RedimosConfig c, String table) async {
    final libPath = _resolveLibraryPath();
    final arg = jsonEncode({'config': c.toJson(), 'table': table});
    final raw =
        await Isolate.run(() => _callCoreSymbol(libPath, 'rm_table_delete', arg));
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // ---- value formatter (Browser format dropdown) ----

  /// The persisted custom formatters (empty on any failure).
  List<CustomFormatter> getFormatters() {
    try {
      final j = jsonDecode(_call0(_getFormatters)) as Map<String, dynamic>;
      return ((j['formatters'] as List?) ?? [])
          .map((e) => CustomFormatter.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Replace the whole custom-formatter list (atomic native persist).
  void setFormatters(List<CustomFormatter> fs) => _expectOk(
      _call1(_setFormatters, jsonEncode({'formatters': [for (final f in fs) f.toJson()]})));

  /// Decode [valueB64] (base64 of the value's EXACT bytes) as [format]; pass
  /// 'Auto' to auto-detect. Runs on a background isolate so decoding a large or
  /// compressed value never blocks the UI. Never throws — returns {ok:false}.
  Future<Map<String, dynamic>> formatValue(
      {required String format, required String valueB64}) async {
    final libPath = _resolveLibraryPath();
    final arg = jsonEncode({'format': format, 'valueB64': valueB64});
    try {
      final raw = await Isolate.run(() => _callCoreSymbol(libPath, 'rm_format', arg));
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Run a custom formatter program on a value. Runs on a background isolate
  /// (spawns an external process). Never throws — returns {ok:false, error}.
  Future<Map<String, dynamic>> formatCustom({
    required String command,
    required String params,
    required String valueB64,
    String key = '',
    String field = '',
    String score = '',
    String member = '',
    int timeoutMs = 5000,
  }) async {
    final libPath = _resolveLibraryPath();
    final arg = jsonEncode({
      'command': command,
      'params': params,
      'valueB64': valueB64,
      'key': key,
      'field': field,
      'score': score,
      'member': member,
      'timeoutMs': timeoutMs,
    });
    try {
      final raw = await Isolate.run(() => _callCoreSymbol(libPath, 'rm_format_custom', arg));
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ---- Playground (JS via goja / Go via yaegi, sandboxed + timeout) ----

  /// Run a Playground [script] against either a running proxy's Redis
  /// (`kind:'redis'` → connects to `127.0.0.1:port`, optional [auth]) or an
  /// endpoint's DynamoDB (`kind:'ddb'` → uses [config]'s backend, writes gated
  /// by the AWS read-only guard natively). [lang] is 'js' or 'go'. Runs on a
  /// background isolate (it blocks on the network + interpreter for up to
  /// [timeoutMs]). Never throws — returns {ok, logs[], result, error, elapsedMs}.
  Future<Map<String, dynamic>> playgroundRun({
    required String kind,
    required String lang,
    required String script,
    int port = 0,
    String auth = '',
    RedimosConfig? config,
    int timeoutMs = 5000,
  }) async {
    final libPath = _resolveLibraryPath();
    final arg = jsonEncode({
      'kind': kind,
      'lang': lang,
      'script': script,
      'port': port,
      'auth': auth,
      'config': config?.toJson() ?? <String, dynamic>{},
      'timeoutMs': timeoutMs,
    });
    try {
      final raw = await Isolate.run(
          () => _callCoreSymbol(libPath, 'rm_playground_run', arg));
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  void _expectOk(String raw) {
    final r = jsonDecode(raw) as Map<String, dynamic>;
    if (r['ok'] != true) throw StateError(r['error']?.toString() ?? 'call failed');
  }
}
