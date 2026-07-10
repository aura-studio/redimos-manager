import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

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

/// Thin Dart wrapper over the Go core dynamic library. All state (configs,
/// child processes) lives in Go; this just marshals JSON across the boundary.
class NativeCore {
  late final DynamicLibrary _lib;
  late final _StrDartFn _version, _load, _status, _stopAll, _shutdown;
  late final _StrDartFn _ddbGet, _ddbStart, _ddbStop, _ddbLogs;
  late final _StrArgDartFn _saveConfig, _deleteConfig, _setSettings, _start, _stop, _logs;
  late final _StrArgDartFn _ddbSet, _inspectTable;
  late final _FreeDartFn _free;

  NativeCore() {
    _lib = DynamicLibrary.open(_resolveLibraryPath());
    _version = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_version');
    _load = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_load');
    _status = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_status');
    _stopAll = _lib.lookupFunction<_StrNativeFn, _StrDartFn>('rm_stop_all');
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

  ({List<RedimosConfig> configs, Settings settings}) load() {
    final j = jsonDecode(_call0(_load)) as Map<String, dynamic>;
    // The core refuses to manage children when another app instance already
    // holds the single-instance lock; surface that instead of a broken UI.
    final lockError = j['lockError'];
    if (lockError != null) throw StateError(lockError.toString());
    final configs = ((j['configs'] as List?) ?? [])
        .map((e) => RedimosConfig.fromJson(e as Map<String, dynamic>))
        .toList();
    final settings =
        Settings.fromJson((j['settings'] as Map<String, dynamic>?) ?? {});
    return (configs: configs, settings: settings);
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
  void stopAll() => _call0(_stopAll);

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

  void _expectOk(String raw) {
    final r = jsonDecode(raw) as Map<String, dynamic>;
    if (r['ok'] != true) throw StateError(r['error']?.toString() ?? 'call failed');
  }
}
