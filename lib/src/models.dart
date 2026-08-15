// Data models mirrored from the Go core's JSON. Kept intentionally simple —
// every value crosses the FFI boundary as JSON.

/// One extra redimos flag: a key (flag name, picked from a dropdown) + value.
class FlagKV {
  String key;
  String value;
  FlagKV({this.key = '', this.value = ''});
  factory FlagKV.fromJson(Map<String, dynamic> j) => FlagKV(
      key: (j['key'] ?? '') as String, value: (j['value'] ?? '') as String);
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
  bool
      autoCreateTable; // pass -auto-create-table (create table if missing + verify schema)
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
        partitionID: ((j['partitionID'] ?? '') as String).isEmpty
            ? 'aws'
            : j['partitionID'] as String,
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

/// A DynamoDB backend (the connection + credentials half of a former config),
/// shared by instances that target it. kind ∈ {local, aws, url}. Mirrors the Go
/// Endpoint struct; derived from configs by the core.
class DdbEndpoint {
  final String id;
  final String name;
  final String kind; // "local" | "aws" | "url"
  final String endpoint;
  final String partitionID;
  final String region;
  final String accessKeyId;
  final String secretKey;
  final String sessionToken;
  final String source;
  const DdbEndpoint({
    this.id = '',
    this.name = '',
    this.kind = 'aws',
    this.endpoint = '',
    this.partitionID = '',
    this.region = '',
    this.accessKeyId = '',
    this.secretKey = '',
    this.sessionToken = '',
    this.source = '',
  });
  factory DdbEndpoint.fromJson(Map<String, dynamic> j) => DdbEndpoint(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        kind: (j['kind'] ?? 'aws') as String,
        endpoint: (j['endpoint'] ?? '') as String,
        partitionID: (j['partitionID'] ?? '') as String,
        region: (j['region'] ?? '') as String,
        accessKeyId: (j['accessKeyId'] ?? '') as String,
        secretKey: (j['secretKey'] ?? '') as String,
        sessionToken: (j['sessionToken'] ?? '') as String,
        source: (j['source'] ?? '') as String,
      );

  /// Synthesize a config that points a storage view at this endpoint (no proxy /
  /// table). Table pages take a RedimosConfig, so this bridges an endpoint to them.
  RedimosConfig toStorageConfig() => RedimosConfig(
        id: 'endpoint:$id',
        name: name,
        table: '',
        endpoint: endpoint,
        partitionID: partitionID.isEmpty ? 'aws' : partitionID,
        region: region,
        accessKeyId: accessKeyId,
        secretKey: secretKey,
        sessionToken: sessionToken,
        source: source,
      );
}

/// A redimos proxy (the process/redis half of a former config): the table it
/// serves + a reference to the endpoint it targets. Mirrors the Go Instance.
class ProxyInstance {
  final String id;
  final String name;
  final String version;
  final int port;
  final String table;
  final String endpointId;
  final bool multiDb;
  final bool autoCreateTable;
  final bool autoRestart;
  final String runMode;
  final String requirepass;
  final List<FlagKV> extraFlags;
  const ProxyInstance({
    this.id = '',
    this.name = '',
    this.version = 'v2',
    this.port = 6379,
    this.table = '',
    this.endpointId = '',
    this.multiDb = false,
    this.autoCreateTable = false,
    this.autoRestart = true,
    this.runMode = 'native',
    this.requirepass = '',
    this.extraFlags = const [],
  });
  factory ProxyInstance.fromJson(Map<String, dynamic> j) => ProxyInstance(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        version: (j['version'] ?? 'v2') as String,
        port: (j['port'] ?? 6379) as int,
        table: (j['table'] ?? '') as String,
        endpointId: (j['endpointId'] ?? '') as String,
        multiDb: (j['multiDb'] ?? false) as bool,
        autoCreateTable: (j['autoCreateTable'] ?? false) as bool,
        autoRestart: (j['autoRestart'] ?? true) as bool,
        runMode: (j['runMode'] ?? 'native') as String,
        requirepass: (j['requirepass'] ?? '') as String,
        extraFlags: (((j['extraFlags'] as List?) ?? const [])
            .map((e) => FlagKV.fromJson(e as Map<String, dynamic>))
            .toList()),
      );
}

class Settings {
  String redimosV1Path;
  String redimosV2Path;
  String
      dynamoDbLocalDir; // Java DynamoDBLocal dir override ('' = auto-download)
  String
      redimosV1Image; // docker run-mode image for v1 ('' => redimos-v1:local)
  String
      redimosV2Image; // docker run-mode image for v2 ('' => redimos-v2:local)

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

/// A user-defined value formatter for the Browser's format dropdown. [command]
/// is an external program; [params] is an argv template whose {VALUE}/{HEX}/
/// {KEY}/{FIELD}/{SCORE}/{MEMBER} placeholders are substituted at run time.
/// [name] is the dropdown label and the unique id.
class CustomFormatter {
  final String name;
  final String command;
  final String params;
  const CustomFormatter(
      {required this.name, required this.command, required this.params});

  factory CustomFormatter.fromJson(Map<String, dynamic> j) => CustomFormatter(
        name: (j['name'] ?? '') as String,
        command: (j['command'] ?? '') as String,
        params: (j['params'] ?? '') as String,
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'command': command, 'params': params};
}

// ---------------------------------------------------------------------------
// Instance status
// ---------------------------------------------------------------------------

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
  // redimos's own reported cause for a failing backend check (the /readyz body's
  // backend_error). Empty when it reports none: a ready proxy, an endpoint that
  // never answered, or a redimos too old to publish the field. Empty therefore
  // means "no cause known", NOT "no problem" — healthy/ready remain the signals
  // that say whether something is wrong, and this only ever explains it.
  final String backendError;

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
    this.backendError = '',
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
        backendError: (j['backendError'] ?? '') as String,
      );

  bool get isRunning => status == 'running';
}

// ---------------------------------------------------------------------------
// Table browser (the "Table" tab — read-only DynamoDB explore, redimos-flavour)
// ---------------------------------------------------------------------------

/// A key attribute reference: its name and DynamoDB scalar type (S | N | B).
class TableKeyRef {
  final String name;
  final String type;
  TableKeyRef({required this.name, required this.type});
  factory TableKeyRef.fromJson(Map<String, dynamic> j) => TableKeyRef(
      name: (j['name'] ?? '') as String, type: (j['type'] ?? '') as String);
}

/// A selectable Scan/Query target: the base table or one of its indexes.
class TableTarget {
  final String name;
  final String kind; // "table" | "LSI" | "GSI"
  final TableKeyRef pk;
  final TableKeyRef? sk;
  TableTarget(
      {required this.name, required this.kind, required this.pk, this.sk});
  factory TableTarget.fromJson(Map<String, dynamic> j) => TableTarget(
        name: (j['name'] ?? '') as String,
        kind: (j['kind'] ?? 'table') as String,
        pk: TableKeyRef.fromJson((j['pk'] as Map<String, dynamic>?) ?? {}),
        sk: j['sk'] == null
            ? null
            : TableKeyRef.fromJson(j['sk'] as Map<String, dynamic>),
      );
  bool get isTable => kind == 'table';
}

class TableMeta {
  final bool ok;
  final String? error;
  final String table;
  final List<TableTarget> targets;
  TableMeta(
      {required this.ok, this.error, this.table = '', this.targets = const []});
  factory TableMeta.fromJson(Map<String, dynamic> j) => TableMeta(
        ok: (j['ok'] ?? false) as bool,
        error: j['error'] as String?,
        table: (j['table'] ?? '') as String,
        targets: ((j['targets'] as List?) ?? [])
            .map((e) => TableTarget.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One displayed cell value. For Binary, [repr] is the decoded UTF-8 when
/// [printable]; [b64] always holds the base64 form.
class AttrCell {
  final String type; // S|N|B|BOOL|NULL|SS|NS|BS|L|M|?
  final String repr;
  final String? b64;
  final bool printable;
  AttrCell(
      {required this.type,
      required this.repr,
      this.b64,
      this.printable = true});
  factory AttrCell.fromJson(Map<String, dynamic> j) => AttrCell(
        type: (j['t'] ?? '?') as String,
        repr: (j['repr'] ?? '') as String,
        b64: j['b64'] as String?,
        printable: (j['printable'] ?? true) as bool,
      );
  bool get isBinary => type == 'B';
}

class TableItem {
  final Map<String, AttrCell> cells;
  final String ddbJson;
  TableItem({required this.cells, required this.ddbJson});
  factory TableItem.fromJson(Map<String, dynamic> j) => TableItem(
        cells: ((j['cells'] as Map<String, dynamic>?) ?? {}).map((k, v) =>
            MapEntry(k, AttrCell.fromJson(v as Map<String, dynamic>))),
        ddbJson: (j['ddbJson'] ?? '') as String,
      );
}

class TablePage {
  final bool ok;
  final String? error;
  final List<String> cols;
  final List<TableItem> rows;
  final int returned;
  final int scanned;
  final int timeMs;
  final Map<String, dynamic>?
      lastKey; // opaque LastEvaluatedKey; null = last page
  TablePage({
    required this.ok,
    this.error,
    this.cols = const [],
    this.rows = const [],
    this.returned = 0,
    this.scanned = 0,
    this.timeMs = 0,
    this.lastKey,
  });
  factory TablePage.fromJson(Map<String, dynamic> j) => TablePage(
        ok: (j['ok'] ?? false) as bool,
        error: j['error'] as String?,
        cols: ((j['cols'] as List?) ?? []).map((e) => e.toString()).toList(),
        rows: ((j['rows'] as List?) ?? [])
            .map((e) => TableItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        returned: (j['returned'] ?? 0) as int,
        scanned: (j['scanned'] ?? 0) as int,
        timeMs: (j['timeMs'] ?? 0) as int,
        lastKey: j['lastKey'] as Map<String, dynamic>?,
      );
  bool get hasNext => lastKey != null;
  double get efficiency => scanned == 0 ? 1.0 : returned / scanned;
}

/// Result of one PartiQL ExecuteStatement call (the "PartiQL" tab).
class PartiqlResult {
  final bool ok;
  final String? error;
  final List<String> cols;
  final List<TableItem> rows;
  final int returned;
  final int timeMs;
  final String? nextToken; // null = no more pages
  PartiqlResult({
    required this.ok,
    this.error,
    this.cols = const [],
    this.rows = const [],
    this.returned = 0,
    this.timeMs = 0,
    this.nextToken,
  });
  factory PartiqlResult.fromJson(Map<String, dynamic> j) => PartiqlResult(
        ok: (j['ok'] ?? false) as bool,
        error: j['error'] as String?,
        cols: ((j['cols'] as List?) ?? []).map((e) => e.toString()).toList(),
        rows: ((j['rows'] as List?) ?? [])
            .map((e) => TableItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        returned: (j['returned'] ?? 0) as int,
        timeMs: (j['timeMs'] ?? 0) as int,
        nextToken: j['nextToken'] as String?,
      );
  bool get hasNext => nextToken != null && nextToken!.isNotEmpty;
}

// ---------------------------------------------------------------------------
// Service entity models (v1.2). Mirrored from the Go core's JSON wire shapes;
// every value crosses the FFI boundary as JSON. The persisted half
// (ServiceConfig) never carries transient runtime state — that half is
// ServiceRuntime, rebuilt by the core on every poll.
// ---------------------------------------------------------------------------

/// How a Service runs locally. Wire values: "java" | "docker" | "localstack".
enum ServiceEngine {
  java,
  dockerDynamodb,
  localStack;

  String get wire {
    switch (this) {
      case ServiceEngine.java:
        return 'java';
      case ServiceEngine.dockerDynamodb:
        return 'docker';
      case ServiceEngine.localStack:
        return 'localstack';
    }
  }

  /// Unknown wire values fail closed: a Service with an engine the core does
  /// not know about must never be quietly treated as a known one.
  static ServiceEngine fromWire(String s) {
    switch (s) {
      case 'java':
        return ServiceEngine.java;
      case 'docker':
      case 'docker-dynamodb': // a design-era spelling; the core says "docker"
        return ServiceEngine.dockerDynamodb;
      case 'localstack':
        return ServiceEngine.localStack;
    }
    throw FormatException('unknown service engine "$s"');
  }
}

/// Where a Service keeps its data. Wire values: memory | managed | custom.
enum ServiceStorageMode {
  memory,
  managed,
  custom;

  String get wire {
    switch (this) {
      case ServiceStorageMode.memory:
        return 'memory';
      case ServiceStorageMode.managed:
        return 'managed';
      case ServiceStorageMode.custom:
        return 'custom';
    }
  }

  static ServiceStorageMode fromWire(String s) {
    switch (s) {
      case 'memory':
      case '':
        return ServiceStorageMode.memory;
      case 'managed':
        return ServiceStorageMode.managed;
      case 'custom':
        return ServiceStorageMode.custom;
    }
    throw FormatException('unknown service storage mode "$s"');
  }
}

/// One Service lifecycle state. The core reports its own statuses
/// (stopped/preparing/running/restarting/failed/error); stopping and
/// recovering are presentational states the UI layers on top. An unknown wire
/// value degrades to [error] — never silently to stopped/running.
enum ServiceState {
  stopped,
  preparing,
  running,
  restarting,
  stopping,
  failed,
  error,
  recovering;

  static ServiceState fromWire(String s) {
    switch (s) {
      case 'stopped':
        return ServiceState.stopped;
      case 'preparing':
        return ServiceState.preparing;
      case 'running':
        return ServiceState.running;
      case 'restarting':
        return ServiceState.restarting;
      case 'stopping':
        return ServiceState.stopping;
      case 'failed':
        return ServiceState.failed;
      case 'recovering':
        return ServiceState.recovering;
      case 'error':
      default:
        return ServiceState.error;
    }
  }
}

class ServiceStorage {
  ServiceStorageMode mode;
  String path; // java: data directory (custom mode)
  String volume; // docker/localstack: volume name (custom mode)
  ServiceStorage(
      {this.mode = ServiceStorageMode.memory,
      this.path = '',
      this.volume = ''});

  factory ServiceStorage.fromJson(Map<String, dynamic> j) => ServiceStorage(
        mode: ServiceStorageMode.fromWire((j['mode'] ?? '') as String),
        path: (j['path'] ?? '') as String,
        volume: (j['volume'] ?? '') as String,
      );
  Map<String, dynamic> toJson() => {
        'mode': mode.wire,
        if (path.isNotEmpty) 'path': path,
        if (volume.isNotEmpty) 'volume': volume,
      };
}

class ServiceConfig {
  String id; // core-generated, immutable, globally unique ('' = create)
  String name;
  ServiceEngine engine;
  int port; // 0 = engine default (8000 ddb / 4566 localstack)
  ServiceStorage storage;
  Map<String, dynamic> engineOptions;
  bool desiredRunning;

  ServiceConfig({
    this.id = '',
    this.name = '',
    this.engine = ServiceEngine.dockerDynamodb,
    this.port = 0,
    ServiceStorage? storage,
    this.engineOptions = const {},
    this.desiredRunning = false,
  }) : storage = storage ?? ServiceStorage();

  factory ServiceConfig.fromJson(Map<String, dynamic> j) => ServiceConfig(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        engine: ServiceEngine.fromWire((j['engine'] ?? 'docker') as String),
        port: (j['port'] ?? 0) as int,
        storage: ServiceStorage.fromJson(
            (j['storage'] as Map<String, dynamic>?) ?? const {}),
        engineOptions: ((j['engineOptions'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), v)),
        desiredRunning: (j['desiredRunning'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'engine': engine.wire,
        'port': port,
        'storage': storage.toJson(),
        if (engineOptions.isNotEmpty) 'engineOptions': engineOptions,
        'desiredRunning': desiredRunning,
      };

  ServiceConfig copy() => ServiceConfig.fromJson(toJson());
}

/// Live resource sample of a running Service (the core's sampler output).
class ServiceMetrics {
  final double cpuPercent;
  final int memBytes;
  final double diskBytesPerSec;
  ServiceMetrics(
      {this.cpuPercent = 0, this.memBytes = 0, this.diskBytesPerSec = 0});
  factory ServiceMetrics.fromJson(Map<String, dynamic> j) => ServiceMetrics(
        cpuPercent: ((j['cpuPercent'] ?? 0) as num).toDouble(),
        memBytes: (j['memBytes'] ?? 0) as int,
        diskBytesPerSec: ((j['diskBytesPerSec'] ?? 0) as num).toDouble(),
      );
}

/// The transient half of a Service: never persisted, rebuilt on every poll.
class ServiceRuntime {
  final ServiceState state;
  final int pid;
  final String containerId;
  final String startedAt; // RFC3339, '' when never started
  final bool ready;
  final bool healthy;
  final String errorCode; // taxonomy code when error is set, '' otherwise
  final String error;
  final ServiceMetrics? metrics; // present while running

  ServiceRuntime({
    this.state = ServiceState.stopped,
    this.pid = 0,
    this.containerId = '',
    this.startedAt = '',
    this.ready = false,
    this.healthy = false,
    this.errorCode = '',
    this.error = '',
    this.metrics,
  });

  factory ServiceRuntime.fromJson(Map<String, dynamic> j) => ServiceRuntime(
        state: ServiceState.fromWire((j['state'] ?? 'stopped') as String),
        pid: (j['pid'] ?? 0) as int,
        containerId: (j['containerId'] ?? '') as String,
        startedAt: (j['startedAt'] ?? '') as String,
        ready: (j['ready'] ?? false) as bool,
        healthy: (j['healthy'] ?? false) as bool,
        errorCode: (j['errorCode'] ?? '') as String,
        error: (j['error'] ?? '') as String,
        metrics: j['metrics'] == null
            ? null
            : ServiceMetrics.fromJson(j['metrics'] as Map<String, dynamic>),
      );

  bool get isLive =>
      state == ServiceState.running ||
      state == ServiceState.preparing ||
      state == ServiceState.restarting;
}

/// One Service as the core reports it: persisted config + live runtime.
class ServiceInfo {
  final ServiceConfig config;
  final ServiceRuntime runtime;
  ServiceInfo({required this.config, required this.runtime});

  factory ServiceInfo.fromJson(Map<String, dynamic> j) => ServiceInfo(
        config: ServiceConfig.fromJson(
            (j['config'] as Map<String, dynamic>?) ?? const {}),
        runtime: ServiceRuntime.fromJson(
            (j['runtime'] as Map<String, dynamic>?) ?? const {}),
      );

  String get id => config.id;
}

/// The outcome of one Service deletion (stage 8 safety rules).
class ServiceDeleteResult {
  final String id;
  final bool dataCleaned;
  final List<String> manualCleanup;
  final bool partial;
  ServiceDeleteResult({
    this.id = '',
    this.dataCleaned = false,
    this.manualCleanup = const [],
    this.partial = false,
  });
  factory ServiceDeleteResult.fromJson(Map<String, dynamic> j) =>
      ServiceDeleteResult(
        id: (j['id'] ?? '') as String,
        dataCleaned: (j['dataCleaned'] ?? false) as bool,
        manualCleanup: ((j['manualCleanup'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        partial: (j['partial'] ?? false) as bool,
      );
}

// ---------------------------------------------------------------------------
// Typed Stop All / Restore All (the v2 snapshot: Instance and Service IDs in
// separate namespaces so restore never confuses the two).
// ---------------------------------------------------------------------------

class GlobalStopSnapshot {
  final List<String> instances;
  final List<String> services;
  GlobalStopSnapshot({this.instances = const [], this.services = const []});
  factory GlobalStopSnapshot.fromJson(Map<String, dynamic> j) =>
      GlobalStopSnapshot(
        instances: ((j['instances'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        services: ((j['services'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
  bool get isEmpty => instances.isEmpty && services.isEmpty;
}

/// One entity named in a stop/restore result. kind: "instance" | "service".
class EntityRef {
  final String kind;
  final String id;
  EntityRef({required this.kind, required this.id});
  factory EntityRef.fromJson(Map<String, dynamic> j) => EntityRef(
        kind: (j['kind'] ?? '') as String,
        id: (j['id'] ?? '') as String,
      );
}

/// One entity whose stop/restore failed, with the reason.
class EntityFailure {
  final String kind;
  final String id;
  final String reason;
  EntityFailure({required this.kind, required this.id, this.reason = ''});
  factory EntityFailure.fromJson(Map<String, dynamic> j) => EntityFailure(
        kind: (j['kind'] ?? '') as String,
        id: (j['id'] ?? '') as String,
        reason: (j['reason'] ?? '') as String,
      );
}

class GlobalStopResult {
  final GlobalStopSnapshot snapshot;
  final List<EntityRef> stopped;
  final List<EntityFailure> failed;
  GlobalStopResult({
    GlobalStopSnapshot? snapshot,
    this.stopped = const [],
    this.failed = const [],
  }) : snapshot = snapshot ?? GlobalStopSnapshot();
  factory GlobalStopResult.fromJson(Map<String, dynamic> j) => GlobalStopResult(
        snapshot: GlobalStopSnapshot.fromJson(
            (j['snapshot'] as Map<String, dynamic>?) ?? const {}),
        stopped: ((j['stopped'] as List?) ?? const [])
            .map((e) => EntityRef.fromJson(e as Map<String, dynamic>))
            .toList(),
        failed: ((j['failed'] as List?) ?? const [])
            .map((e) => EntityFailure.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class GlobalRestoreResult {
  final List<EntityRef> restored;
  final List<EntityFailure> failed; // stay in the snapshot for retry
  final List<EntityRef> missing; // entity no longer exists
  GlobalRestoreResult({
    this.restored = const [],
    this.failed = const [],
    this.missing = const [],
  });
  factory GlobalRestoreResult.fromJson(Map<String, dynamic> j) =>
      GlobalRestoreResult(
        restored: ((j['restored'] as List?) ?? const [])
            .map((e) => EntityRef.fromJson(e as Map<String, dynamic>))
            .toList(),
        failed: ((j['failed'] as List?) ?? const [])
            .map((e) => EntityFailure.fromJson(e as Map<String, dynamic>))
            .toList(),
        missing: ((j['missing'] as List?) ?? const [])
            .map((e) => EntityRef.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ---------------------------------------------------------------------------
// Service ABI error contract. The core answers every Service call with an
// envelope; failures carry a stable machine [code] (the error taxonomy) plus
// a human message. The Dart side throws this instead of returning fake
// success defaults.
// ---------------------------------------------------------------------------

class ServiceApiException implements Exception {
  /// Stable machine code: invalid_request, service_not_found, duplicate_name,
  /// port_conflict, service_busy, invalid_transition, resource_unowned,
  /// unsafe_data_path, unowned_volume, engine_unavailable, readiness_timeout,
  /// persist_failed, partial_delete, recovery_failed, legacy_api_unsupported.
  final String code;
  final String message;
  final String? id; // the affected Service ID when the envelope carries one
  final String op; // the operation that failed (save/start/stop/... context)
  ServiceApiException(this.code, this.message, {this.id, this.op = ''});

  @override
  String toString() =>
      'ServiceApiException(${op.isEmpty ? code : '$op: $code'})'
      '${id == null ? '' : ' id=$id'}: $message';
}
