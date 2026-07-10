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
  String runMode; // "" | "native" (run the binary) | "docker" (run the image)
  String requirepass;
  List<FlagKV> extraFlags;

  RedimosConfig({
    this.id = '',
    this.name = '',
    this.version = 'v2',
    this.port = 6379,
    this.table = 'redis-data',
    this.endpoint = '',
    this.partitionID = 'aws', // AWS standard partition; the usual value
    this.region = '',
    this.accessKeyId = '',
    this.secretKey = '',
    this.sessionToken = '',
    this.source = '',
    this.multiDb = false,
    this.autoCreateTable = false,
    this.autoRestart = true,
    this.runMode = 'native',
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
        partitionID:
            ((j['partitionID'] ?? '') as String).isEmpty ? 'aws' : j['partitionID'] as String,
        region: (j['region'] ?? '') as String,
        accessKeyId: (j['accessKeyId'] ?? '') as String,
        secretKey: (j['secretKey'] ?? '') as String,
        sessionToken: (j['sessionToken'] ?? '') as String,
        source: (j['source'] ?? '') as String,
        multiDb: (j['multiDb'] ?? false) as bool,
        autoCreateTable: (j['autoCreateTable'] ?? false) as bool,
        autoRestart: (j['autoRestart'] ?? true) as bool,
        runMode: (j['runMode'] ?? 'native') as String,
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
        'runMode': runMode,
        'requirepass': requirepass,
        'extraFlags': extraFlags.map((e) => e.toJson()).toList(),
      };

  RedimosConfig copy() => RedimosConfig.fromJson(toJson());
}

/// Result of inspecting a config's DynamoDB table before start: whether the
/// data already there disagrees with the config's version / MultiDB.
class TableInspect {
  final bool checked; // false = couldn't tell (no data / creds / table)
  final String tableVersion; // "v1" | "v2" inferred from key type
  final bool tableMultiDb;
  final bool tableMultiDbKnown;
  final bool mismatch;
  final String detail; // English, one line

  TableInspect({
    this.checked = false,
    this.tableVersion = '',
    this.tableMultiDb = false,
    this.tableMultiDbKnown = false,
    this.mismatch = false,
    this.detail = '',
  });

  factory TableInspect.fromJson(Map<String, dynamic> j) => TableInspect(
        checked: (j['checked'] ?? false) as bool,
        tableVersion: (j['tableVersion'] ?? '') as String,
        tableMultiDb: (j['tableMultiDb'] ?? false) as bool,
        tableMultiDbKnown: (j['tableMultiDbKnown'] ?? false) as bool,
        mismatch: (j['mismatch'] ?? false) as bool,
        detail: (j['detail'] ?? '') as String,
      );
}

class Settings {
  String redimosV1Path;
  String redimosV2Path;
  String dynamoDbLocalDir; // Java DynamoDBLocal dir override ('' = auto-download)
  String redimosV1Image; // docker run-mode image for v1 ('' => redimos-v1:local)
  String redimosV2Image; // docker run-mode image for v2 ('' => redimos-v2:local)

  Settings({
    this.redimosV1Path = '',
    this.redimosV2Path = '',
    this.dynamoDbLocalDir = '',
    this.redimosV1Image = '',
    this.redimosV2Image = '',
  });

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        redimosV1Path: (j['redimosV1Path'] ?? '') as String,
        redimosV2Path: (j['redimosV2Path'] ?? '') as String,
        dynamoDbLocalDir: (j['dynamoDbLocalDir'] ?? '') as String,
        redimosV1Image: (j['redimosV1Image'] ?? '') as String,
        redimosV2Image: (j['redimosV2Image'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'redimosV1Path': redimosV1Path,
        'redimosV2Path': redimosV2Path,
        'dynamoDbLocalDir': dynamoDbLocalDir,
        'redimosV1Image': redimosV1Image,
        'redimosV2Image': redimosV2Image,
      };
}

// ---------------------------------------------------------------------------
// Local DynamoDB (the manager-owned local backend)
// ---------------------------------------------------------------------------

/// Persisted launch configuration for the Local DynamoDB child.
class LocalDdbConfig {
  String engine; // java | docker | localstack
  String storage; // memory | persist (ignored by localstack)
  int port;
  String dataDir; // java persist dir
  String volume; // docker persist named volume

  LocalDdbConfig({
    this.engine = 'docker',
    this.storage = 'memory',
    this.port = 8000,
    this.dataDir = '',
    this.volume = '',
  });

  factory LocalDdbConfig.fromJson(Map<String, dynamic> j) => LocalDdbConfig(
        engine: (j['engine'] ?? 'docker') as String,
        storage: (j['storage'] ?? 'memory') as String,
        port: (j['port'] ?? 8000) as int,
        dataDir: (j['dataDir'] ?? '') as String,
        volume: (j['volume'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'engine': engine,
        'storage': storage,
        'port': port,
        'dataDir': dataDir,
        'volume': volume,
      };
}

/// One rm_ddb_get snapshot: config + runtime status + dependency detection.
class LocalDdbInfo {
  final LocalDdbConfig config;
  final String status; // stopped | preparing | running | restarting | error | failed
  final int pid;
  final int uptimeSec;
  final String exitMsg;
  final int restarts;
  final double cpuPercent;
  final int memBytes;
  final double diskPerSec; // disk I/O bytes/sec (read+written)
  final bool adopted; // inherited from a previous session (crash recovery)
  final bool dockerOk;
  final bool javaOk;
  final bool jarReady;

  LocalDdbInfo({
    required this.config,
    required this.status,
    required this.pid,
    required this.uptimeSec,
    required this.exitMsg,
    required this.restarts,
    required this.cpuPercent,
    required this.memBytes,
    required this.diskPerSec,
    this.adopted = false,
    required this.dockerOk,
    required this.javaOk,
    required this.jarReady,
  });

  factory LocalDdbInfo.fromJson(Map<String, dynamic> j) {
    final st = (j['status'] as Map<String, dynamic>?) ?? {};
    final det = (j['detect'] as Map<String, dynamic>?) ?? {};
    return LocalDdbInfo(
      config: LocalDdbConfig.fromJson((j['config'] as Map<String, dynamic>?) ?? {}),
      status: (st['status'] ?? 'stopped') as String,
      pid: (st['pid'] ?? 0) as int,
      uptimeSec: (st['uptimeSec'] ?? 0) as int,
      exitMsg: (st['exitMsg'] ?? '') as String,
      restarts: (st['restarts'] ?? 0) as int,
      cpuPercent: ((st['cpuPercent'] ?? 0) as num).toDouble(),
      memBytes: (st['memBytes'] ?? 0) as int,
      diskPerSec: ((st['diskPerSec'] ?? 0) as num).toDouble(),
      adopted: (st['adopted'] ?? false) as bool,
      dockerOk: (det['docker'] ?? false) as bool,
      javaOk: (det['java'] ?? false) as bool,
      jarReady: (det['jarReady'] ?? false) as bool,
    );
  }

  bool get isActive =>
      status == 'running' || status == 'preparing' || status == 'restarting';
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
  final double cpuPercent; // % of all cores (Task-Manager style)
  final int memBytes; // working set
  final String runMode; // "native" | "docker"
  // redimos /metrics-derived fields (from the manager's scraper).
  final bool metricsOk; // scrape reached the endpoint
  final bool healthy; // /healthz == 200
  final bool ready; // /readyz == 200
  final double opsPerSec; // command rate
  final double avgLatencyMs; // average command latency
  final int throttled; // cumulative DynamoDB throttles
  final bool adopted; // inherited from a previous session (crash recovery)

  InstanceStatus({
    required this.id,
    required this.status,
    required this.pid,
    required this.port,
    required this.uptimeSec,
    required this.exitMsg,
    this.restarts = 0,
    this.autoRestart = false,
    this.cpuPercent = 0,
    this.memBytes = 0,
    this.runMode = 'native',
    this.metricsOk = false,
    this.healthy = false,
    this.ready = false,
    this.opsPerSec = 0,
    this.avgLatencyMs = 0,
    this.throttled = 0,
    this.adopted = false,
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
        cpuPercent: ((j['cpuPercent'] ?? 0) as num).toDouble(),
        memBytes: (j['memBytes'] ?? 0) as int,
        runMode: (j['runMode'] ?? 'native') as String,
        metricsOk: (j['metricsOk'] ?? false) as bool,
        healthy: (j['healthy'] ?? false) as bool,
        ready: (j['ready'] ?? false) as bool,
        opsPerSec: ((j['opsPerSec'] ?? 0) as num).toDouble(),
        avgLatencyMs: ((j['avgLatencyMs'] ?? 0) as num).toDouble(),
        throttled: (j['throttled'] ?? 0) as int,
        adopted: (j['adopted'] ?? false) as bool,
      );

  bool get isRunning => status == 'running';
}
