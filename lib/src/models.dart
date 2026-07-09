// Data models mirrored from the Go core's JSON. Kept intentionally simple —
// every value crosses the FFI boundary as JSON.

/// One extra redimos flag: a key (flag name, picked from a dropdown) + value.
class FlagKV {
  String key;
  String value;
  FlagKV({this.key = '', this.value = ''});
  factory FlagKV.fromJson(Map<String, dynamic> j) =>
      FlagKV(key: (j['key'] ?? '') as String, value: (j['value'] ?? '') as String);
  Map<String, dynamic> toJson() => {'key': key, 'value': value};
}

class RedimosConfig {
  String id;
  String name;
  String version; // "v1" | "v2"
  int port;
  String table;
  // endpoint (aws.Endpoint): url / partitionID / signingRegion
  String endpoint; // the endpoint URL; empty => online AWS default resolver
  String partitionID;
  String region; // signingRegion
  // credentials (aws.Credentials): accessKeyID / secretAccessKey / sessionToken / source
  String accessKeyId;
  String secretKey;
  String sessionToken;
  String source;
  bool multiDb;
  bool autoCreateTable; // pass -auto-create-table (create table if missing + verify schema)
  bool autoRestart; // supervisor: auto-restart the child on unexpected exit
  String requirepass;
  List<FlagKV> extraFlags;

  RedimosConfig({
    this.id = '',
    this.name = '',
    this.version = 'v2',
    this.port = 6379,
    this.table = 'redis-data',
    this.endpoint = '',
    this.partitionID = '',
    this.region = '',
    this.accessKeyId = '',
    this.secretKey = '',
    this.sessionToken = '',
    this.source = '',
    this.multiDb = false,
    this.autoCreateTable = false,
    this.autoRestart = true,
    this.requirepass = '',
    this.extraFlags = const [],
  });

  factory RedimosConfig.fromJson(Map<String, dynamic> j) => RedimosConfig(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        version: (j['version'] ?? 'v2') as String,
        port: (j['port'] ?? 6379) as int,
        table: (j['table'] ?? 'redis-data') as String,
        endpoint: (j['endpoint'] ?? '') as String,
        partitionID: (j['partitionID'] ?? '') as String,
        region: (j['region'] ?? '') as String,
        accessKeyId: (j['accessKeyId'] ?? '') as String,
        secretKey: (j['secretKey'] ?? '') as String,
        sessionToken: (j['sessionToken'] ?? '') as String,
        source: (j['source'] ?? '') as String,
        multiDb: (j['multiDb'] ?? false) as bool,
        autoCreateTable: (j['autoCreateTable'] ?? false) as bool,
        autoRestart: (j['autoRestart'] ?? true) as bool,
        requirepass: (j['requirepass'] ?? '') as String,
        extraFlags: (((j['extraFlags'] as List?) ?? const [])
            .map((e) => FlagKV.fromJson(e as Map<String, dynamic>))
            .toList()),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'port': port,
        'table': table,
        'endpoint': endpoint,
        'partitionID': partitionID,
        'region': region,
        'accessKeyId': accessKeyId,
        'secretKey': secretKey,
        'sessionToken': sessionToken,
        'source': source,
        'multiDb': multiDb,
        'autoCreateTable': autoCreateTable,
        'autoRestart': autoRestart,
        'requirepass': requirepass,
        'extraFlags': extraFlags.map((e) => e.toJson()).toList(),
      };

  RedimosConfig copy() => RedimosConfig.fromJson(toJson());
}

class Settings {
  String redimosV1Path;
  String redimosV2Path;

  Settings({this.redimosV1Path = '', this.redimosV2Path = ''});

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        redimosV1Path: (j['redimosV1Path'] ?? '') as String,
        redimosV2Path: (j['redimosV2Path'] ?? '') as String,
      );

  Map<String, dynamic> toJson() =>
      {'redimosV1Path': redimosV1Path, 'redimosV2Path': redimosV2Path};
}

class InstanceStatus {
  final String id;
  final String status; // running | restarting | stopped | error | failed
  final int pid;
  final int port;
  final int uptimeSec;
  final String exitMsg;
  final int restarts; // supervised auto-restarts so far
  final bool autoRestart;

  InstanceStatus({
    required this.id,
    required this.status,
    required this.pid,
    required this.port,
    required this.uptimeSec,
    required this.exitMsg,
    this.restarts = 0,
    this.autoRestart = false,
  });

  factory InstanceStatus.fromJson(Map<String, dynamic> j) => InstanceStatus(
        id: (j['id'] ?? '') as String,
        status: (j['status'] ?? 'stopped') as String,
        pid: (j['pid'] ?? 0) as int,
        port: (j['port'] ?? 0) as int,
        uptimeSec: (j['uptimeSec'] ?? 0) as int,
        exitMsg: (j['exitMsg'] ?? '') as String,
        restarts: (j['restarts'] ?? 0) as int,
        autoRestart: (j['autoRestart'] ?? false) as bool,
      );

  bool get isRunning => status == 'running';
}
