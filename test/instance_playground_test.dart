import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/code_editor.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/playground_page.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_status.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';

class _PlaygroundCall {
  const _PlaygroundCall({
    required this.kind,
    required this.lang,
    required this.script,
    required this.port,
    required this.auth,
    required this.config,
    required this.timeoutMs,
  });

  final String kind;
  final String lang;
  final String script;
  final int port;
  final String auth;
  final RedimosConfig? config;
  final int timeoutMs;
}

class _PlaygroundCore extends FakeNativeCore {
  final calls = <_PlaygroundCall>[];
  final responses = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> playgroundRun({
    required String kind,
    required String lang,
    required String script,
    int port = 0,
    String auth = '',
    RedimosConfig? config,
    int timeoutMs = 5000,
  }) async {
    calls.add(_PlaygroundCall(
      kind: kind,
      lang: lang,
      script: script,
      port: port,
      auth: auth,
      config: config,
      timeoutMs: timeoutMs,
    ));
    return responses.removeAt(0);
  }
}

class _PlaygroundTabs extends StatelessWidget {
  const _PlaygroundTabs({required this.core, required this.config});

  final _PlaygroundCore core;
  final RedimosConfig config;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(tabs: [Tab(text: 'Playground'), Tab(text: 'Other')]),
            Expanded(
              child: TabBarView(
                children: [
                  PlaygroundView(
                    core: core,
                    config: config,
                    kind: 'redis',
                    running: true,
                  ),
                  const SizedBox.expand(),
                ],
              ),
            ),
          ],
        ),
      );
}

RedimosConfig _config() => RedimosConfig(
      id: 'playground-config',
      name: 'playground-instance',
      port: 6387,
      table: 'redis-playground',
      region: 'us-west-2',
      requirepass: 'secret-auth',
    );

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: child),
    );

Future<void> _pumpPlayground(
  WidgetTester tester,
  _PlaygroundCore core, {
  RedimosConfig? config,
  Brightness brightness = Brightness.dark,
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _app(
      brightness,
      PlaygroundView(
        core: core,
        config: config ?? _config(),
        kind: 'redis',
        running: true,
      ),
    ),
  );
  await tester.pump();
}

Finder _editor() => find.descendant(
      of: find.byType(CodeField),
      matching: find.byType(TextField),
    );

Future<void> _runScript(WidgetTester tester, String script) async {
  await tester.enterText(_editor(), script);
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, tr('pg.run')));
  await tester.pump();
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'Playground preserves exact run parameters and structured result in ${brightness.name}',
      (tester) async {
        final core = _PlaygroundCore()
          ..responses.add({
            'ok': true,
            'logs': const ['scan started', 'scan complete'],
            'result': [
              {
                'id': 7,
                'nested': {'ready': true},
              },
            ],
            'elapsedMs': 18,
          });
        final config = _config();

        await _pumpPlayground(
          tester,
          core,
          config: config,
          brightness: brightness,
        );
        await _runScript(tester, '  return redis.scan("user:*");  ');

        expect(core.calls, hasLength(1));
        final call = core.calls.single;
        expect(call.kind, 'redis');
        expect(call.lang, 'js');
        expect(call.script, 'return redis.scan("user:*");');
        expect(call.port, config.port);
        expect(call.auth, config.requirepass);
        expect(call.config, same(config));
        expect(call.timeoutMs, 8000);

        expect(find.text('scan started'), findsOneWidget);
        expect(find.text('scan complete'), findsOneWidget);
        expect(find.text('{"id":7,"nested":{"ready":true}}'), findsOneWidget);
        expect(find.byType(CodexStatusBadge), findsOneWidget);
        expect(find.byType(CodexSurface), findsWidgets);
        expect(find.byType(CodexIconButton), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Playground renders error and copies the complete output',
      (tester) async {
    final core = _PlaygroundCore()
      ..responses.add({
        'ok': false,
        'logs': const ['before failure'],
        'error': 'sandbox timeout',
        'elapsedMs': 8000,
      });
    MethodCall? clipboardCall;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboardCall = call;
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pumpPlayground(tester, core);
    await _runScript(tester, 'throw new Error("timeout");');

    expect(find.text('sandbox timeout'), findsOneWidget);
    final badge =
        tester.widget<CodexStatusBadge>(find.byType(CodexStatusBadge));
    expect(badge.status, CodexStatus.error);

    await tester.tap(find.byTooltip(tr('br.copy')));
    await tester.pump();
    expect(clipboardCall?.method, 'Clipboard.setData');
    expect(
      (clipboardCall?.arguments as Map<Object?, Object?>?)?['text'],
      'before failure\nsandbox timeout',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Playground output scrolls without moving the fixed split',
      (tester) async {
    final core = _PlaygroundCore()
      ..responses.add({
        'ok': true,
        'logs': List.generate(120, (index) => 'log-line-$index'),
        'result': const {'done': true},
        'elapsedMs': 25,
      });

    await _pumpPlayground(tester, core, size: const Size(1280, 420));
    final editorRect = tester.getRect(find.byType(CodeField));
    await _runScript(tester, 'return true;');

    final output = find.byKey(
      const ValueKey('playground-output-redis-playground-config'),
    );
    final scrollable = find.descendant(
      of: output,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable.first).position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();

    expect(position.pixels, position.maxScrollExtent);
    expect(tester.getRect(find.byType(CodeField)), editorRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Playground retains unsaved script and output across real tabs',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = _PlaygroundCore()
      ..responses.add({
        'ok': true,
        'logs': const ['retained-output'],
        'result': const {'retained': true},
        'elapsedMs': 4,
      });

    await tester.pumpWidget(
      _app(Brightness.dark, _PlaygroundTabs(core: core, config: _config())),
    );
    await tester.pump();
    await _runScript(tester, 'return "retained-script";');
    expect(find.text('retained-output'), findsOneWidget);

    await tester.tap(find.text('Other'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Playground'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(tester.widget<TextField>(_editor()).controller!.text,
        'return "retained-script";');
    expect(find.text('retained-output'), findsOneWidget);
    expect(core.calls, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
