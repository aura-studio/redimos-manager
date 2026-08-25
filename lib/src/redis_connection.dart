// The Connect module's entity: a persisted Redis client connection. Lives in
// the app's own prefs dir (~/.redimosmanager/connections.json) — the Go core
// store holds instance/endpoint configs only, and a connection is a purely
// client-side object (like the theme prefs pattern in theme_prefs.dart).

import 'dart:convert';
import 'dart:io';

import 'theme_prefs.dart';

class RedisConnection {
  final String id;
  final String name;
  final String host;
  final int port;
  final String password;
  final int database;
  // Persisted + displayed; connection behaviour is a later stage.
  final bool tls;
  final bool readOnlyReplica;

  const RedisConnection({
    this.id = '',
    this.name = '',
    this.host = '127.0.0.1',
    this.port = 6379,
    this.password = '',
    this.database = 0,
    this.tls = false,
    this.readOnlyReplica = false,
  });

  RedisConnection copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? password,
    int? database,
    bool? tls,
    bool? readOnlyReplica,
  }) =>
      RedisConnection(
        id: id ?? this.id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        password: password ?? this.password,
        database: database ?? this.database,
        tls: tls ?? this.tls,
        readOnlyReplica: readOnlyReplica ?? this.readOnlyReplica,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'password': password,
        'database': database,
        'tls': tls,
        'readOnlyReplica': readOnlyReplica,
      };

  static RedisConnection fromJson(Map j) => RedisConnection(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        host: '${j['host'] ?? '127.0.0.1'}',
        port: (j['port'] is num) ? (j['port'] as num).toInt() : 6379,
        password: '${j['password'] ?? ''}',
        database: (j['database'] is num) ? (j['database'] as num).toInt() : 0,
        tls: j['tls'] == true,
        readOnlyReplica: j['readOnlyReplica'] == true,
      );
}

File? _connectionsFile({Directory? dir}) {
  final effective = dir ?? debugPrefsDir;
  if (effective != null) return File('${effective.path}/connections.json');
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return null;
  return File('$home/.redimosmanager/connections.json');
}

/// Synchronously restores the persisted connections before the first frame.
/// Any failure (missing file, corrupt JSON) yields an empty list — the
/// Connect module starts blank rather than blocking startup.
List<RedisConnection> loadConnections({Directory? dir}) {
  final file = _connectionsFile(dir: dir);
  if (file == null) return const [];
  try {
    if (!file.existsSync()) return const [];
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) RedisConnection.fromJson(e),
    ];
  } catch (_) {
    return const [];
  }
}

/// Persists the connection list atomically (tmp + rename), creating the
/// config directory on first write. IO failures are swallowed: the in-memory
/// list still applies for this session.
void saveConnections(List<RedisConnection> connections, {Directory? dir}) {
  final file = _connectionsFile(dir: dir);
  if (file == null) return;
  try {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
        jsonEncode([for (final c in connections) c.toJson()]));
    tmp.renameSync(file.path);
  } catch (_) {
    // Best-effort persistence.
  }
}
