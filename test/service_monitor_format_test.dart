// v1.2 (6.7): unit tests for the Service Monitor's pure formatting helpers.
//
// These are the tile-value formatters extracted from service_detail.dart —
// uptime, latency, port, engine label, and the lifecycle-state label matrix.
// Pure Dart; no widget pump, no dylib.

import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/monitor_widgets.dart' show ddbEngineLabel;
import 'package:redimos_manager/src/service_detail.dart';

void main() {
  setUp(() => appLang.value = AppLang.en);
  tearDown(() => appLang.value = AppLang.en);

  group('serviceUptimeValue', () {
    // The canonical spec example: 196 s renders as "3m 16s" (7.3).
    test('formats 196s as "3m 16s"', () {
      final now = DateTime.utc(2026, 8, 20, 12, 0, 0);
      final started = now.subtract(const Duration(seconds: 196));
      expect(serviceUptimeValue(started.toIso8601String(), now: now),
          '3m 16s');
    });

    test('formats sub-minute, hour, and day scales', () {
      final now = DateTime.utc(2026, 8, 20, 12, 0, 0);
      expect(
        serviceUptimeValue(
            now.subtract(const Duration(seconds: 42)).toIso8601String(),
            now: now),
        '42s',
      );
      expect(
        serviceUptimeValue(
            now
                .subtract(const Duration(hours: 2, minutes: 14, seconds: 30))
                .toIso8601String(),
            now: now),
        '2h 14m',
      );
    });

    test('never started / unparseable / future clock reads as "—"', () {
      final now = DateTime.utc(2026, 8, 20, 12, 0, 0);
      expect(serviceUptimeValue('', now: now), '—');
      expect(serviceUptimeValue('not-a-date', now: now), '—');
      expect(
        serviceUptimeValue(
            now.add(const Duration(seconds: 5)).toIso8601String(),
            now: now),
        '—',
      );
    });
  });

  group('serviceLatencyValue', () {
    test('null renders "—" until a probe succeeds', () {
      expect(serviceLatencyValue(null), '—');
    });

    test('sub-10 ms keeps one decimal, otherwise integral ms', () {
      expect(serviceLatencyValue(0.4), '0.4 ms');
      expect(serviceLatencyValue(9.9), '9.9 ms');
      expect(serviceLatencyValue(12.6), '13 ms');
      expect(serviceLatencyValue(125.0), '125 ms');
    });
  });

  group('servicePortValue / serviceDefaultPort', () {
    test('port 0 renders the engine default (7.3)', () {
      expect(
        servicePortValue(ServiceConfig(
            id: 's', name: 'n', engine: ServiceEngine.java, port: 0)),
        '8000',
      );
      expect(
        servicePortValue(ServiceConfig(
            id: 's', name: 'n', engine: ServiceEngine.localStack, port: 0)),
        '4566',
      );
    });

    test('an explicit port wins over the default', () {
      expect(
        servicePortValue(ServiceConfig(
            id: 's', name: 'n', engine: ServiceEngine.java, port: 9457)),
        '9457',
      );
    });

    test('default ports per engine', () {
      expect(serviceDefaultPort(ServiceEngine.java), 8000);
      expect(serviceDefaultPort(ServiceEngine.dockerDynamodb), 8000);
      expect(serviceDefaultPort(ServiceEngine.localStack), 4566);
    });
  });

  group('engine + state labels', () {
    test('each engine renders a distinct label', () {
      final labels = {
        ddbEngineLabel(ServiceEngine.java.wire),
        ddbEngineLabel(ServiceEngine.dockerDynamodb.wire),
        ddbEngineLabel(ServiceEngine.localStack.wire),
      };
      expect(labels, hasLength(3));
    });

    test('every lifecycle state has a distinct label', () {
      final labels = ServiceState.values.map(serviceStateLabel).toSet();
      expect(labels, hasLength(ServiceState.values.length));
    });
  });
}
