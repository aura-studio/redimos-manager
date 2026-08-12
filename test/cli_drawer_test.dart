import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/cli_drawer.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_status.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'fake_resp_server.dart';
import 'viewport_assertions.dart';

Future<void> _pumpDrawer(
  WidgetTester tester, {
  required Brightness brightness,
  required int port,
  String? auth,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 900,
            child: CliDrawer(
              host: '127.0.0.1',
              port: port,
              auth: auth,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  int attempts = 60,
}) async {
  for (var i = 0; i < attempts; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for expected CLI drawer widget');
}

Finder _drawerInput() => find.descendant(
      of: find.byKey(const ValueKey('cli-drawer-input')),
      matching: find.byType(TextField),
    );

Future<void> _submit(
  WidgetTester tester,
  String command, {
  Finder? expected,
}) async {
  await tester.enterText(_drawerInput(), command);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  if (expected != null) await _waitFor(tester, expected);
}

Future<void> _disposeDrawer(
  WidgetTester tester,
  FakeRespServer server,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(server.close);
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'uses fixed Codex shell without animated reflow in ${brightness.name}',
      (tester) async {
        await _pumpDrawer(
          tester,
          brightness: brightness,
          port: 1,
        );

        expect(
          tester
              .getSize(find.byKey(const ValueKey('cli-drawer-header')))
              .height,
          Dim.cliHeadH,
        );
        expect(find.byKey(const ValueKey('cli-drawer-body')), findsNothing);
        expect(
          tester
              .widget<CodexStatusDot>(
                find.byKey(const ValueKey('cli-drawer-connection')),
              )
              .status,
          CodexStatus.neutral,
        );

        await tester.tap(
          find.byKey(const ValueKey('cli-drawer-tab-helper')),
        );
        await tester.pump();

        expect(
          tester.getSize(find.byKey(const ValueKey('cli-drawer-body'))).height,
          220,
        );
        expectInsideTestViewport(
          tester,
          find.byKey(const ValueKey('cli-drawer')),
        );
        expectHitTestable(
          tester,
          find.byKey(const ValueKey('cli-drawer-toggle')),
        );
        final surface = tester.widget<CodexSurface>(
          find.descendant(
            of: find.byKey(const ValueKey('cli-drawer-body')),
            matching: find.byType(CodexSurface),
          ),
        );
        expect(surface.variant, CodexSurfaceVariant.sunken);
        expect(find.byType(AnimatedSize), findsNothing);
        expect(
            find.byType(CodexButton), findsNWidgets(kCliHelperCommands.length));

        final expanded = tester.getRect(
          find.byKey(const ValueKey('cli-drawer')),
        );
        await tester.pump(const Duration(milliseconds: 90));
        expect(
          tester.getRect(find.byKey(const ValueKey('cli-drawer'))),
          expanded,
        );

        await tester.tap(find.byKey(const ValueKey('cli-drawer-toggle')));
        await tester.pump();
        expect(find.byKey(const ValueKey('cli-drawer-body')), findsNothing);
        final collapsed = tester.getRect(
          find.byKey(const ValueKey('cli-drawer')),
        );
        expect(collapsed.height, Dim.cliHeadH);
        await tester.pump(const Duration(milliseconds: 210));
        expect(
          tester.getRect(find.byKey(const ValueKey('cli-drawer'))),
          collapsed,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
      'closing drawer releases hidden input focus and resumes traversal',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await _pumpDrawer(
      tester,
      brightness: Brightness.dark,
      port: server.port,
    );

    await tester.tap(find.byKey(const ValueKey('cli-drawer-tab-cli')));
    await tester.runAsync(() => server.waitForConnections(1));
    await tester.pump();
    final input = _drawerInput();
    final inputFocus = tester.widget<TextField>(input).focusNode!;
    expect(inputFocus.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('cli-drawer-toggle')));
    await tester.pump();

    expect(find.byKey(const ValueKey('cli-drawer-body')), findsNothing);
    expect(inputFocus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(inputFocus.hasFocus, isFalse);
    expect(find.byKey(const ValueKey('cli-drawer-body')), findsNothing);
    expect(tester.takeException(), isNull);

    await _disposeDrawer(tester, server);
  });

  testWidgets('helper inserts the exact command and returns focus to CLI',
      (tester) async {
    await _pumpDrawer(
      tester,
      brightness: Brightness.dark,
      port: 1,
    );

    await tester.tap(find.byKey(const ValueKey('cli-drawer-tab-helper')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cli-drawer-helper-HGETALL')));
    await tester.pump();

    expect(find.byKey(const ValueKey('cli-drawer-cli-body')), findsOneWidget);
    final field = tester.widget<TextField>(_drawerInput());
    expect(field.controller!.text, 'HGETALL ');
    expect(field.focusNode!.hasFocus, isTrue);
    final codexField = tester.widget<CodexTextField>(
      find.byKey(const ValueKey('cli-drawer-input')),
    );
    expect(codexField.style?.fontFamily, Ts.monoFamily);
    expect(tester.takeException(), isNull);
  });

  testWidgets('executes exact RESP parameters and preserves command history',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await _pumpDrawer(
      tester,
      brightness: Brightness.light,
      port: server.port,
      auth: 'drawer-secret',
    );

    await tester.tap(find.byKey(const ValueKey('cli-drawer-tab-cli')));
    await tester.pump();
    await tester.runAsync(() => server.waitForConnections(1));
    await _waitFor(
      tester,
      find.byKey(const ValueKey('cli-drawer-connection')),
    );

    await _submit(
      tester,
      'SET drawer:key "hello world"',
      expected: find.text('OK'),
    );
    await _submit(
      tester,
      'PING',
      expected: find.text('PONG'),
    );

    expect(server.commands, contains(equals(['AUTH', 'drawer-secret'])));
    expect(
      server.commands,
      contains(equals(['SET', 'drawer:key', 'hello world'])),
    );
    expect(server.commands, contains(equals(['PING'])));

    await tester.tap(_drawerInput());
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.widget<TextField>(_drawerInput()).controller!.text, 'PING');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      tester.widget<TextField>(_drawerInput()).controller!.text,
      'SET drawer:key "hello world"',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<TextField>(_drawerInput()).controller!.text, 'PING');
    expect(tester.takeException(), isNull);

    await _disposeDrawer(tester, server);
  });

  testWidgets('profiler reflects executions and clears without closing drawer',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await _pumpDrawer(
      tester,
      brightness: Brightness.dark,
      port: server.port,
    );

    await tester.tap(find.byKey(const ValueKey('cli-drawer-tab-cli')));
    await tester.pump();
    await tester.runAsync(() => server.waitForConnections(1));
    await _submit(tester, 'PING', expected: find.text('PONG'));
    await _submit(tester, 'DBSIZE', expected: find.text('(integer) 375'));

    await tester.tap(find.byKey(const ValueKey('cli-drawer-tab-profiler')));
    await tester.pump();

    expect(find.text('2 profiled'), findsOneWidget);
    expect(find.text('PING'), findsOneWidget);
    expect(find.text('DBSIZE'), findsOneWidget);
    expect(find.byKey(const ValueKey('cli-drawer-body')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('cli-drawer-profiler-clear')),
    );
    await tester.pump();
    expect(
      find.text('No commands profiled yet — run some in the CLI tab'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cli-drawer-body')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _disposeDrawer(tester, server);
  });

  testWidgets('unbalanced input reports locally without opening a socket',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await _pumpDrawer(
      tester,
      brightness: Brightness.light,
      port: server.port,
    );

    await tester.tap(find.byKey(const ValueKey('cli-drawer-tab-helper')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cli-drawer-helper-GET')));
    await tester.pump();
    await _submit(
      tester,
      'GET "unfinished',
      expected: find.text('(error) unbalanced quotes'),
    );

    expect(server.connectionCount, 0);
    expect(server.commands, isEmpty);
    expect(tester.takeException(), isNull);

    await _disposeDrawer(tester, server);
  });
}
