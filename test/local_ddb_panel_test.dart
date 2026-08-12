import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/local_ddb_panel.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_status.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'fake_core.dart';
import 'viewport_assertions.dart';

class _LocalDdbCore extends FakeNativeCore {
  final events = <String>[];
  final configs = <LocalDdbConfig>[];
  List<String> logLines = const [];
  Object? startError;
  Object? stopError;

  @override
  void ddbSet(LocalDdbConfig config) {
    events.add('set');
    configs.add(LocalDdbConfig.fromJson(config.toJson()));
  }

  @override
  void ddbStart() {
    events.add('start');
    if (startError case final error?) throw error;
  }

  @override
  void ddbStop() {
    events.add('stop');
    if (stopError case final error?) throw error;
  }

  @override
  List<String> ddbLogs() {
    events.add('logs');
    return List.of(logLines);
  }
}

LocalDdbInfo _info({
  LocalDdbConfig? config,
  String status = 'stopped',
  int port = 0,
  double cpuPercent = 0,
  int memBytes = 0,
  int restarts = 0,
  bool dockerOk = true,
  bool javaOk = true,
}) =>
    LocalDdbInfo(
      config: config ?? LocalDdbConfig(),
      status: status,
      pid: status == 'running' ? 42 : 0,
      port: port,
      uptimeSec: 10,
      exitMsg: '',
      restarts: restarts,
      cpuPercent: cpuPercent,
      memBytes: memBytes,
      diskPerSec: 0,
      dockerOk: dockerOk,
      javaOk: javaOk,
      jarReady: javaOk,
    );

Future<void> _pumpPanel(
  WidgetTester tester, {
  required Brightness brightness,
  required _LocalDdbCore core,
  required LocalDdbInfo info,
  required VoidCallback onMutated,
}) async {
  tester.view.physicalSize = const Size(600, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(
            width: 280,
            child: LocalDdbPanel(
              core: core,
              info: info,
              onMutated: onMutated,
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _textFieldInside(Key key) => find.descendant(
      of: find.byKey(key),
      matching: find.byType(TextField),
    );

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('local-ddb-toggle')));
  await tester.pump();
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'uses shared fixed controls and semantic status in ${brightness.name}',
      (tester) async {
        final core = _LocalDdbCore();
        await _pumpPanel(
          tester,
          brightness: brightness,
          core: core,
          info: _info(),
          onMutated: () {},
        );

        expect(find.byType(CodexStatusDot), findsOneWidget);
        expect(
          tester.widget<CodexStatusDot>(find.byType(CodexStatusDot)).status,
          CodexStatus.stopped,
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('local-ddb-toggle'))).height,
          Dim.ctlH,
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('local-ddb-body'))).height,
          0,
        );

        await _expand(tester);

        expect(find.byType(CodexSelectField<String>), findsNWidgets(2));
        expect(find.byType(CodexTextField), findsOneWidget);
        expect(find.byType(CodexButton), findsOneWidget);
        expect(find.byType(CodexIconButton), findsOneWidget);
        expect(
          tester
              .widget<CodexButton>(
                find.byKey(const ValueKey('local-ddb-primary-action')),
              )
              .variant,
          CodexButtonVariant.primary,
        );
        final port = tester.widget<CodexTextField>(
          find.byKey(const ValueKey('local-ddb-port')),
        );
        expect(port.style?.fontFamily, Ts.monoFamily);
        expect(port.style?.fontFeatures, Ts.tabular);
        expect(find.byType(AnimatedSize), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('start persists exact pending fields before launching',
      (tester) async {
    final core = _LocalDdbCore();
    var mutations = 0;
    await _pumpPanel(
      tester,
      brightness: Brightness.dark,
      core: core,
      info: _info(
        config: LocalDdbConfig(
          engine: 'docker',
          storage: 'persist',
          port: 8000,
          dataDir: '/unused/java',
          volume: 'old-volume',
        ),
      ),
      onMutated: () => mutations++,
    );
    await _expand(tester);

    await tester.enterText(
      _textFieldInside(const ValueKey('local-ddb-port')),
      '8123',
    );
    await tester.enterText(
      _textFieldInside(const ValueKey('local-ddb-store')),
      'orders-volume',
    );
    await tester.tap(find.byKey(const ValueKey('local-ddb-primary-action')));
    await tester.pump();

    expect(core.events, ['set', 'start']);
    expect(core.configs, hasLength(1));
    expect(core.configs.single.toJson(), {
      'engine': 'docker',
      'storage': 'persist',
      'port': 8123,
      'dataDir': '/unused/java',
      'volume': 'orders-volume',
    });
    expect(mutations, 2,
        reason: 'the persisted config and lifecycle change each refresh state');
    expect(tester.takeException(), isNull);
  });

  testWidgets('engine switch applies defaults and forwards exact config',
      (tester) async {
    final core = _LocalDdbCore();
    var mutations = 0;
    await _pumpPanel(
      tester,
      brightness: Brightness.light,
      core: core,
      info: _info(
        config: LocalDdbConfig(
          engine: 'docker',
          storage: 'memory',
          port: 8000,
          dataDir: '/java-data',
          volume: 'ddb-volume',
        ),
      ),
      onMutated: () => mutations++,
    );
    await _expand(tester);

    await tester.tap(find.byKey(const ValueKey('local-ddb-engine')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Docker · LocalStack').last);
    await tester.pumpAndSettle();

    expect(core.events, ['set']);
    expect(core.configs.single.toJson(), {
      'engine': 'localstack',
      'storage': 'memory',
      'port': 4566,
      'dataDir': '/java-data',
      'volume': 'ddb-volume',
    });
    expect(mutations, 1);
    expect(
      tester
          .widget<TextField>(
            _textFieldInside(const ValueKey('local-ddb-port')),
          )
          .controller!
          .text,
      '4566',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('running state stops without rewriting config', (tester) async {
    final core = _LocalDdbCore();
    var mutations = 0;
    await _pumpPanel(
      tester,
      brightness: Brightness.dark,
      core: core,
      info: _info(
        config: LocalDdbConfig(port: 9000),
        status: 'running',
        port: 9000,
        cpuPercent: 2.5,
        memBytes: 64 * 1024 * 1024,
        restarts: 2,
      ),
      onMutated: () => mutations++,
    );

    final status = tester.widget<CodexStatusDot>(find.byType(CodexStatusDot));
    expect(status.status, CodexStatus.running);
    final stats = tester.widget<Text>(
      find.byKey(const ValueKey('local-ddb-stats')),
    );
    expect(stats.data, ':9000 · 2.5% · 64MB · ↻2');
    expect(stats.style?.fontFamily, Ts.monoFamily);

    await _expand(tester);
    expect(find.byType(CodexTextField), findsNothing);
    expect(find.byType(CodexSelectField<String>), findsNothing);
    expect(
      tester
          .widget<CodexButton>(
            find.byKey(const ValueKey('local-ddb-primary-action')),
          )
          .variant,
      CodexButtonVariant.danger,
    );

    await tester.tap(find.byKey(const ValueKey('local-ddb-primary-action')));
    await tester.pump();

    expect(core.events, ['stop']);
    expect(core.configs, isEmpty);
    expect(mutations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logs use a sunken mono surface and preserve exact output',
      (tester) async {
    final core = _LocalDdbCore()
      ..logLines = const ['starting on :8000', 'ready'];
    await _pumpPanel(
      tester,
      brightness: Brightness.light,
      core: core,
      info: _info(),
      onMutated: () {},
    );
    await _expand(tester);

    await tester.tap(find.byKey(const ValueKey('local-ddb-logs-action')));
    await tester.pumpAndSettle();

    expect(core.events, ['logs']);
    final dialog = find.byKey(const ValueKey('local-ddb-logs-dialog'));
    expect(dialog, findsOneWidget);
    expectInsideTestViewport(
      tester,
      dialog,
      reason: 'the logs dialog must fit the narrower 600x800 stress viewport',
    );
    expectHitTestable(tester, find.text(tr('home.close')));
    final surface = tester.widget<CodexSurface>(
      find.descendant(
        of: find.byKey(const ValueKey('local-ddb-logs-dialog')),
        matching: find.byType(CodexSurface),
      ),
    );
    expect(surface.variant, CodexSurfaceVariant.sunken);
    final output = tester.widget<SelectableText>(
      find.byKey(const ValueKey('local-ddb-logs-content')),
    );
    expect(output.data, 'starting on :8000\nready');
    expect(output.style?.fontFamily, Ts.monoFamily);

    await tester.tap(find.text(tr('home.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('local-ddb-logs-dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lifecycle errors use semantic danger and do not fake success',
      (tester) async {
    final core = _LocalDdbCore()
      ..startError = StateError('local engine unavailable');
    var mutations = 0;
    await _pumpPanel(
      tester,
      brightness: Brightness.dark,
      core: core,
      info: _info(),
      onMutated: () => mutations++,
    );
    await _expand(tester);

    await tester.tap(find.byKey(const ValueKey('local-ddb-primary-action')));
    await tester.pump();

    expect(core.events, ['set', 'start']);
    expect(mutations, 1,
        reason: 'only the successful config persistence refreshes state');
    expect(find.textContaining('local engine unavailable'), findsOneWidget);
    final snackbar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackbar.backgroundColor, AppTokens.dark.danger);
    expect(tester.takeException(), isNull);
  });
}
