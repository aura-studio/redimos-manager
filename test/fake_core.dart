// Golden-test fake for the Go FFI core (test-only).
//
// NativeCore's constructor opens the native dylib immediately (native.dart),
// which doesn't exist under `flutter test` — so the golden harness pumps an
// `implements` fake instead (implements, not extends: the real constructor
// never runs). Only the methods the golden screens actually touch are
// overridden; anything else trips noSuchMethod loudly so a surprise call is a
// test failure, not a silent default.

import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/native.dart';

class FakeNativeCore implements NativeCore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeNativeCore: ${invocation.memberName}');

  // ---- Browser (instance) ----

  @override
  List<CustomFormatter> getFormatters() => const [];

  // ---- Logs ----

  @override
  List<String> logs(String id) => const [
        // v2.3 mockup (inst-logs): the 13 log lines verbatim, HH:MM:SS.mmm
        // timestamps — the mockup's <b> emphasis is dropped (fixture is plain
        // text; the capture channel can't do partial-bold runs anyway).
        '08:12:02.114 INFO  backend ready on 127.0.0.1:6379 · db3 selected',
        '08:12:02.318 INFO  SCAN cursor 0 → 4096 · 128 keys matched "user:*"',
        '08:12:03.007 DEBUG cache hit ratio 0.982 (window 60s)',
        "08:12:03.244 INFO  partiql: SELECT * FROM users WHERE plan = 'pro' → 42 rows · 12 ms",
        '08:12:04.892 WARN  slow command KEYS * 312 ms — prefer SCAN on production',
        '08:12:05.120 INFO  write-through: SET session:token:9f3a synced to table redimos-prod',
        '08:12:06.431 INFO  playground run hash-crud.js finished · 128 ms · 6 statements',
        '08:12:07.903 ERROR dynamodb: ProvisionedThroughputExceededException · retry 1/3 in 200 ms',
        '08:12:08.105 INFO  dynamodb: retry 1/3 succeeded',
        '08:12:09.217 WARN  key cache:product:* eviction pressure rising · hit rate 0.91',
        '08:12:10.552 INFO  client connected · addr 10.0.4.21:52144 · proto RESP3',
        '08:12:11.008 DEBUG latency-trace: p50 0.2 ms · p99 0.4 ms',
        '08:12:12.690 INFO  HGETALL user:1001 · 6 fields · 412 B · 0.4 ms',
      ];

  // ---- Endpoint surfaces ----

  @override
  Future<Map<String, dynamic>> epListTables(RedimosConfig c) async => {
        'ok': true,
        'awsMode': false,
        // v2.3 mockup (ep tables): users 12.4k / sessions 3.1k /
        // events 892; users is keyed user# + profile.
        'tables': [
          {
            'name': 'users',
            'missing': false,
            'status': 'ACTIVE',
            'kind': 'v2',
            'itemCount': 12400,
            'sizeBytes': 3489664,
            'pkName': 'user#',
            'skName': 'profile',
            'usedBy': [
              {'id': 'c1', 'version': 'v2'}
            ],
          },
          {
            'name': 'sessions',
            'missing': false,
            'status': 'ACTIVE',
            'kind': 'raw',
            'itemCount': 3100,
            'sizeBytes': 612040,
            'pkName': 'id',
            'skName': '',
            'usedBy': const [],
          },
          {
            'name': 'events',
            'missing': false,
            'status': 'ACTIVE',
            'kind': 'raw',
            'itemCount': 892,
            'sizeBytes': 204800,
            'pkName': 'ts',
            'skName': '',
            'usedBy': const [],
          },
        ],
      };

  // ---- Table explorer (endpoint Browser's right pane) ----

  @override
  TableMeta tableMeta(RedimosConfig c) => TableMeta(
        ok: true,
        table: 'users',
        targets: [
          // v2.3 mockup: PK user# · SK profile.
          TableTarget(
              name: 'users',
              kind: 'table',
              pk: TableKeyRef(name: 'user#', type: 'S'),
              sk: TableKeyRef(name: 'profile', type: 'S')),
          TableTarget(
              name: 'byEmail',
              kind: 'GSI',
              pk: TableKeyRef(name: 'email', type: 'S')),
        ],
      );

  @override
  TablePage tablePage(Map<String, dynamic> req) {
    TableItem item(String pk, String sk, String name, String plan, String updated) =>
        TableItem(
          cells: {
            'pk': AttrCell(type: 'S', repr: pk),
            'sk': AttrCell(type: 'S', repr: sk),
            'name': AttrCell(type: 'S', repr: name),
            'plan': AttrCell(type: 'S', repr: plan),
            'updated_at': AttrCell(type: 'S', repr: updated),
          },
          ddbJson: '{"pk":{"S":"$pk"},"sk":{"S":"$sk"}}',
        );

    // v2.3 mockup (ep-browser): the six users rows verbatim.
    final rows = [
      item('user#1001', 'profile', 'Tony Chen', 'pro', '2026-08-05T06:12:44Z'),
      item('user#1002', 'profile', 'Alice Wu', 'pro', '2026-08-04T22:03:12Z'),
      item('user#1003', 'profile', 'Bob Lee', 'free', '2026-08-04T19:41:05Z'),
      item('user#1004', 'profile', 'Carol Ng', 'team', '2026-08-03T14:27:56Z'),
      item('user#1005', 'profile', 'Dave Park', 'free', '2026-08-02T09:15:33Z'),
      item('user#1006', 'profile', 'Erin Zhao', 'pro', '2026-08-01T18:52:20Z'),
    ];
    return TablePage(
      ok: true,
      cols: const ['pk', 'sk', 'name', 'plan', 'updated_at'],
      rows: rows,
      returned: rows.length,
      scanned: rows.length,
      timeMs: 7,
    );
  }

  @override
  Map<String, dynamic> tableGetItem(RedimosConfig c, Map<String, dynamic> key) =>
      {'ok': true, 'item': const <String, dynamic>{}};

  // ---- PartiQL / Playground (never invoked on the first frame — Run only) ----

  @override
  PartiqlResult partiql(Map<String, dynamic> req) => PartiqlResult(ok: true);

  @override
  Future<Map<String, dynamic>> playgroundRun({
    required String kind,
    required String lang,
    required String script,
    int port = 0,
    String auth = '',
    RedimosConfig? config,
    int timeoutMs = 5000,
  }) async =>
      {'ok': true, 'logs': const <String>[], 'elapsedMs': 12};
}
