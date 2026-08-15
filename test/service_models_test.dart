// Stage 10 tests: Service Dart models and the NativeCore envelope contract —
// JSON defaults, unknown enums, error envelopes, ID pass-through, and the
// typed Stop All / Restore All snapshot (10.4). Pure Dart: no dylib needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/native.dart';

void main() {
  group('ServiceConfig JSON', () {
    test('defaults survive an empty payload', () {
      final c = ServiceConfig.fromJson(const {});
      expect(c.id, '');
      expect(c.name, '');
      expect(c.engine, ServiceEngine.dockerDynamodb);
      expect(c.port, 0);
      expect(c.storage.mode, ServiceStorageMode.memory);
      expect(c.desiredRunning, false);
    });

    test('round-trip keeps identity and options', () {
      final c = ServiceConfig(
        id: 'abc123',
        name: 'Dev DDB',
        engine: ServiceEngine.java,
        port: 8123,
        storage: ServiceStorage(mode: ServiceStorageMode.custom, path: '/tmp/x'),
        engineOptions: {'heap': '512m'},
        desiredRunning: true,
      );
      final back = ServiceConfig.fromJson(c.toJson());
      expect(back.id, 'abc123'); // the ID is the wire identity — never lost
      expect(back.name, 'Dev DDB');
      expect(back.engine, ServiceEngine.java);
      expect(back.port, 8123);
      expect(back.storage.mode, ServiceStorageMode.custom);
      expect(back.storage.path, '/tmp/x');
      expect(back.engineOptions['heap'], '512m');
      expect(back.desiredRunning, true);
    });

    test('create payload omits the empty id', () {
      final j = ServiceConfig(name: 'x').toJson();
      expect(j['id'], ''); // present but empty: the core reads "" as create
      expect(j['engine'], 'docker');
    });

    test('engine wire values', () {
      expect(ServiceEngine.fromWire('java'), ServiceEngine.java);
      expect(ServiceEngine.fromWire('docker'), ServiceEngine.dockerDynamodb);
      expect(ServiceEngine.fromWire('localstack'), ServiceEngine.localStack);
      expect(ServiceEngine.dockerDynamodb.wire, 'docker');
      expect(() => ServiceEngine.fromWire('qemu'), throwsFormatException);
    });

    test('storage mode wire values', () {
      expect(ServiceStorageMode.fromWire('managed'), ServiceStorageMode.managed);
      expect(ServiceStorageMode.fromWire('custom'), ServiceStorageMode.custom);
      expect(ServiceStorageMode.fromWire('memory'), ServiceStorageMode.memory);
      expect(ServiceStorageMode.fromWire(''), ServiceStorageMode.memory);
      expect(() => ServiceStorageMode.fromWire('nfs'), throwsFormatException);
    });

    test('unknown runtime state degrades to error, never stopped/running', () {
      expect(ServiceState.fromWire('running'), ServiceState.running);
      expect(ServiceState.fromWire('preparing'), ServiceState.preparing);
      expect(ServiceState.fromWire('mystery-state'), ServiceState.error);
      expect(ServiceState.fromWire(''), ServiceState.error);
    });
  });

  group('ServiceInfo / runtime', () {
    test('missing runtime half means stopped', () {
      final info = ServiceInfo.fromJson(const {
        'config': {'id': 's1', 'name': 'one', 'engine': 'java'}
      });
      expect(info.id, 's1');
      expect(info.runtime.state, ServiceState.stopped);
      expect(info.runtime.ready, false);
      expect(info.runtime.metrics, isNull);
    });

    test('running runtime carries metrics and readiness', () {
      final info = ServiceInfo.fromJson(const {
        'config': {'id': 's1', 'name': 'one', 'engine': 'docker'},
        'runtime': {
          'state': 'running',
          'pid': 4242,
          'containerId': 'redimos-service-s1',
          'startedAt': '2026-08-15T03:00:00Z',
          'ready': true,
          'healthy': true,
          'metrics': {'cpuPercent': 12.5, 'memBytes': 1048576, 'diskBytesPerSec': 2048.0},
        }
      });
      expect(info.runtime.state, ServiceState.running);
      expect(info.runtime.isLive, true);
      expect(info.runtime.pid, 4242);
      expect(info.runtime.metrics?.cpuPercent, 12.5);
      expect(info.runtime.metrics?.memBytes, 1048576);
    });

    test('failed runtime carries the taxonomy code', () {
      final rt = ServiceRuntime.fromJson(const {
        'state': 'failed',
        'error': 'port conflict: port 8000 is already in use',
        'errorCode': 'port_conflict',
      });
      expect(rt.state, ServiceState.failed);
      expect(rt.errorCode, 'port_conflict');
      expect(rt.isLive, false);
    });
  });

  group('delete result', () {
    test('parses cleanup outcome', () {
      final r = ServiceDeleteResult.fromJson(const {
        'id': 's1',
        'dataCleaned': true,
        'manualCleanup': ['remove the custom volume v1'],
        'partial': false,
      });
      expect(r.id, 's1');
      expect(r.dataCleaned, true);
      expect(r.manualCleanup, hasLength(1));
      expect(r.partial, false);
    });

    test('defaults to preserved data', () {
      final r = ServiceDeleteResult.fromJson(const {});
      expect(r.dataCleaned, false);
      expect(r.manualCleanup, isEmpty);
      expect(r.partial, false);
    });
  });

  group('envelope contract', () {
    test('success envelope passes through', () {
      final j = NativeCore.parseEnvelope('{"ok":true,"id":"s1"}', 'serviceStart');
      expect(j['id'], 's1');
    });

    test('error envelope throws with code, message and id', () {
      try {
        NativeCore.parseEnvelope(
            '{"ok":false,"id":"s1","code":"port_conflict","error":"Port 8000 is busy"}',
            'serviceStart');
        fail('must throw');
      } on ServiceApiException catch (e) {
        expect(e.code, 'port_conflict');
        expect(e.id, 's1');
        expect(e.op, 'serviceStart');
        expect(e.message, contains('Port 8000'));
      }
    });

    test('missing code degrades to invalid_response, never success', () {
      expect(
        () => NativeCore.parseEnvelope('{"ok":false}', 'serviceDelete'),
        throwsA(isA<ServiceApiException>()
            .having((e) => e.code, 'code', 'invalid_response')),
      );
    });

    test('undecodable reply is an error, not a default', () {
      expect(
        () => NativeCore.parseEnvelope('{not json', 'services'),
        throwsA(isA<ServiceApiException>()
            .having((e) => e.code, 'code', 'invalid_response')),
      );
    });

    test('ok:false without code survives a partial delete payload', () {
      try {
        NativeCore.parseEnvelope(
            '{"ok":false,"code":"partial_delete","error":"persist failed",'
            '"dataCleaned":true,"partial":true}',
            'serviceDelete');
        fail('must throw');
      } on ServiceApiException catch (e) {
        expect(e.code, 'partial_delete');
      }
    });
  });

  group('typed global snapshot', () {
    test('stop result keeps the two ID namespaces apart', () {
      final r = GlobalStopResult.fromJson(const {
        'snapshot': {
          'instances': ['i1', 'i2'],
          'services': ['s1'],
        },
        'stopped': [
          {'kind': 'instance', 'id': 'i1'},
          {'kind': 'service', 'id': 's1'},
        ],
        'failed': [
          {'kind': 'instance', 'id': 'i2', 'reason': 'did not settle'},
        ],
      });
      expect(r.snapshot.instances, ['i1', 'i2']);
      expect(r.snapshot.services, ['s1']);
      expect(r.stopped.map((e) => '${e.kind}:${e.id}'),
          ['instance:i1', 'service:s1']);
      expect(r.failed.single.reason, 'did not settle');
    });

    test('restore result reports restored / failed / missing', () {
      final r = GlobalRestoreResult.fromJson(const {
        'restored': [
          {'kind': 'service', 'id': 's1'}
        ],
        'failed': [
          {'kind': 'instance', 'id': 'i9', 'reason': 'engine unavailable'}
        ],
        'missing': [
          {'kind': 'service', 'id': 's-gone'}
        ],
      });
      expect(r.restored.single.id, 's1');
      expect(r.failed.single.kind, 'instance');
      expect(r.missing.single.id, 's-gone');
    });

    test('empty payloads yield empty snapshots, not nulls', () {
      final snap = GlobalStopSnapshot.fromJson(const {});
      expect(snap.isEmpty, true);
      final res = GlobalStopResult.fromJson(const {});
      expect(res.stopped, isEmpty);
      expect(res.failed, isEmpty);
    });
  });
}
