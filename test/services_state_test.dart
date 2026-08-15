// Stage 11.4: unit / boundary tests for ServicesState — sorting, selection
// successor, tab retention, history ring capacity, delete cleanup, and the
// generation guards that drop stale async replies (requirements 12.1–12.6).
// Pure Dart with a scripted fake core: no dylib needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/native.dart';
import 'package:redimos_manager/src/services_state.dart';

/// Scripted stand-in for the FFI core: services()/serviceLogs() read whatever
/// the test last scripted; anything else trips noSuchMethod loudly.
class ScriptedCore implements NativeCore {
  List<ServiceInfo> snapshot = const [];
  List<String> errors = const [];
  List<String> warnings = const [];
  int serviceCalls = 0;
  int logCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ScriptedCore: ${invocation.memberName}');

  @override
  ({List<ServiceInfo> services, List<String> errors, List<String> warnings})
      services() {
    serviceCalls++;
    return (services: snapshot, errors: errors, warnings: warnings);
  }

  @override
  List<String> serviceLogs(String id) {
    logCalls++;
    return ['log line from $id'];
  }
}

ServiceInfo svc(String id, String name,
    {String state = 'stopped',
    double cpu = 10,
    int memMb = 128,
    double disk = 1024}) {
  return ServiceInfo.fromJson({
    'config': {'id': id, 'name': name, 'engine': 'java', 'port': 8000},
    'runtime': {
      'state': state,
      'ready': state == 'running',
      'healthy': state == 'running',
      if (state == 'running' || state == 'preparing')
        'metrics': {
          'cpuPercent': cpu,
          'memBytes': memMb * 1024 * 1024,
          'diskBytesPerSec': disk,
        },
    },
  });
}

void main() {
  late ScriptedCore core;
  late ServicesState state;

  setUp(() {
    core = ScriptedCore();
    state = ServicesState(core, historyCapacity: 5);
  });

  group('sorting and identity', () {
    test('display order is case-insensitive name with ID tie-break', () async {
      core.snapshot = [
        svc('i3', 'zeta'),
        svc('i1', 'alpha'),
        svc('i2', 'Beta'), // capital B must not sort after lowercase
      ];
      await state.refresh();
      expect(state.services.map((s) => s.id).toList(), ['i1', 'i2', 'i3']);
    });

    test('selection follows the immutable ID across renames and reordering',
        () async {
      core.snapshot = [svc('a', 'one'), svc('b', 'two')];
      await state.refresh();
      state.select('b');
      // Rename + reorder: identity is the ID, never the name or position.
      core.snapshot = [svc('b', 'renamed-two'), svc('a', 'one')];
      await state.refresh();
      expect(state.selectedId, 'b');
      expect(state.selected?.config.name, 'renamed-two');
    });

    test('refresh keeps selection when the ID survives', () async {
      core.snapshot = [svc('a', 'one'), svc('b', 'two'), svc('c', 'three')];
      await state.refresh();
      state.select('b');
      core.snapshot = [svc('c', 'three'), svc('b', 'two')];
      await state.refresh();
      expect(state.selectedId, 'b');
    });
  });

  group('selection successor', () {
    test('vanished selection moves to the same slot, then first, then null',
        () async {
      core.snapshot = [svc('a', 'one'), svc('b', 'two'), svc('c', 'three')];
      await state.refresh();

      state.select('b'); // last slot in name order (one, three, two)
      core.snapshot = [svc('a', 'one'), svc('c', 'three')];
      await state.refresh();
      expect(state.selectedId, 'c'); // past-the-end clamps to the new last

      core.snapshot = [svc('a', 'one')];
      await state.refresh();
      expect(state.selectedId, 'a'); // slot clamps to the first

      core.snapshot = [];
      await state.refresh();
      expect(state.selectedId, isNull);
    });

    test('onServiceDeleted moves the selection to the natural successor',
        () async {
      // Names sort one/three/two → display order a, c, b.
      core.snapshot = [svc('a', 'one'), svc('b', 'two'), svc('c', 'three')];
      await state.refresh();
      state.select('b'); // the last card
      state.onServiceDeleted('b');
      expect(state.selectedId, 'c'); // last card → new last
      core.snapshot = [svc('a', 'one'), svc('c', 'three')];
      await state.refresh(); // sync the list after the delete
      expect(state.selectedId, 'c');
      state.onServiceDeleted('c');
      expect(state.selectedId, 'a');
      core.snapshot = [svc('a', 'one')];
      await state.refresh();
      state.onServiceDeleted('a');
      expect(state.selectedId, isNull);
    });
  });

  group('tab retention', () {
    test('detail tab survives switching Services and clearing the selection',
        () async {
      core.snapshot = [svc('a', 'one'), svc('b', 'two')];
      await state.refresh();
      state.select('a');
      state.selectedTab = 2;
      state.select('b'); // switch entity
      expect(state.selectedTab, 2);
      state.select(null); // leave the Services area entirely
      expect(state.selectedTab, 2);
      state.select('a'); // come back
      expect(state.selectedTab, 2);
    });
  });

  group('history ring buffer', () {
    test('samples only live Services and evicts past the capacity', () async {
      core.snapshot = [svc('a', 'one', state: 'running')];
      for (var i = 0; i < 8; i++) {
        core.snapshot = [
          svc('a', 'one', state: 'running', cpu: i.toDouble())
        ];
        await state.refresh();
      }
      final h = state.historyOf('a');
      expect(h.cpuPercent, [3.0, 4.0, 5.0, 6.0, 7.0]); // cap 5, oldest evicted
      expect(h.memMb, hasLength(5));
      expect(h.diskBytesPerSec, hasLength(5));
    });

    test('a stopped Service freezes its history; another keeps sampling',
        () async {
      core.snapshot = [
        svc('a', 'one', state: 'running', cpu: 1),
        svc('b', 'two', state: 'running', cpu: 2),
      ];
      await state.refresh();
      core.snapshot = [
        svc('a', 'one', state: 'stopped'),
        svc('b', 'two', state: 'running', cpu: 3),
      ];
      await state.refresh();
      expect(state.historyOf('a').cpuPercent, [1.0]); // frozen, kept on screen
      expect(state.historyOf('b').cpuPercent, [2.0, 3.0]);
    });

    test('unknown IDs get an empty history, never an exception', () {
      expect(state.historyOf('ghost').isEmpty, true);
      expect(state.historyOf('ghost').cpuPercent, isEmpty);
    });
  });

  group('delete cleanup', () {
    test('deleted IDs lose their history without touching siblings', () async {
      core.snapshot = [
        svc('a', 'one', state: 'running'),
        svc('b', 'two', state: 'running'),
      ];
      await state.refresh();
      state.onServiceDeleted('a');
      expect(state.historyOf('a').isEmpty, true);
      expect(state.historyOf('b').isEmpty, false);
    });

    test('a refresh without the ID drops its history too', () async {
      core.snapshot = [
        svc('a', 'one', state: 'running'),
        svc('b', 'two', state: 'running'),
      ];
      await state.refresh();
      core.snapshot = [svc('b', 'two', state: 'running')];
      await state.refresh();
      expect(state.historyOf('a').isEmpty, true);
      expect(state.historyOf('b').isEmpty, false);
    });
  });

  group('generation guards (12.4)', () {
    test('a superseded refresh never notifies; the latest snapshot wins',
        () async {
      var notifies = 0;
      state.addListener(() => notifies++);
      core.snapshot = [svc('old', 'stale')];
      final first = state.refresh(); // issued, then overtaken before landing
      core.snapshot = [svc('new', 'fresh')];
      final second = state.refresh();
      expect(await first, false); // dropped by the generation guard
      expect(await second, true);
      expect(notifies, 1); // the stale reply never reached the listeners
      expect(state.services.single.id, 'new');
    });

    test('dispose poisons an in-flight refresh', () async {
      final pending = state.refresh();
      state.dispose();
      expect(await pending, false);
      expect(state.services, isEmpty); // nothing applied after dispose
    });

    test('log replies are dropped when the selection moved', () async {
      core.snapshot = [svc('a', 'one'), svc('b', 'two')];
      await state.refresh();
      state.select('a');
      final pending = state.requestLogs('a');
      state.select('b'); // the reply for 'a' is now stale
      expect(await pending, isNull);
      // Same-ID request still lands.
      expect(await state.requestLogs('b'), isNotEmpty);
    });

    test('a newer log request supersedes the older one', () async {
      core.snapshot = [svc('a', 'one')];
      await state.refresh();
      state.select('a');
      final older = state.requestLogs('a');
      final newer = state.requestLogs('a');
      expect(await older, isNull);
      expect(await newer, ['log line from a']);
    });

    test('select() bumps the log generation even toward null', () async {
      core.snapshot = [svc('a', 'one')];
      await state.refresh();
      state.select('a');
      final pending = state.requestLogs('a');
      state.select(null);
      expect(await pending, isNull);
    });
  });

  group('list envelope extras', () {
    test('boot recovery errors and warnings surface on the state', () async {
      core.snapshot = [svc('a', 'one')];
      core.errors = ['service b: engine not found'];
      core.warnings = ['legacy ddb migrated'];
      await state.refresh();
      expect(state.loadErrors, ['service b: engine not found']);
      expect(state.warnings, ['legacy ddb migrated']);
    });
  });
}
