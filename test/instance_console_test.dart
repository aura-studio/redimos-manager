import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/cmd_console.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_states.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';

import 'fake_resp_server.dart';
import 'screen_fixtures.dart' as fx;

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
  fail('Timed out waiting for expected widget');
}

Finder _consoleInput() => find.descendant(
      of: find.byType(CmdConsole),
      matching: find.byType(TextField),
    );

Future<void> _pumpConnected(
  WidgetTester tester,
  FakeRespServer server, {
  required bool dark,
}) async {
  await fx.pumpScreen(
    tester,
    dark: dark,
    child: CmdConsole(
      host: '127.0.0.1',
      port: server.port,
      running: true,
      instanceName: 'Test Redis',
    ),
  );
  await _waitFor(tester, find.text('redimos-cli'));
}

Future<void> _submit(
  WidgetTester tester,
  String command, {
  Finder? expected,
}) async {
  final input = _consoleInput();
  await tester.runAsync(() async {
    await tester.enterText(input, command);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await Future<void>.delayed(const Duration(milliseconds: 80));
  });
  await tester.pump();
  if (expected != null) await _waitFor(tester, expected);
}

Future<void> _disposeConsole(
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
      'Console preserves command parameters and renders replies in ${brightness.name}',
      (tester) async {
        final server = FakeRespServer();
        await tester.runAsync(server.start);
        await _pumpConnected(
          tester,
          server,
          dark: brightness == Brightness.dark,
        );

        expect(find.byType(CodexTextField), findsOneWidget);
        expect(find.byType(CodexStateShell), findsOneWidget);
        expect(find.byType(CodexSurface), findsWidgets);

        await _submit(
          tester,
          'SET console:key "hello world"',
          expected: find.text('OK'),
        );
        expect(
          server.commands,
          contains(equals(['SET', 'console:key', 'hello world'])),
          reason: 'quoted values must reach RESP unchanged after tokenization',
        );
        expect(find.text('OK'), findsOneWidget);

        server.errorsByCommand['GET'] = 'ERR value unavailable';
        await _submit(
          tester,
          'GET console:key',
          expected: find.text('(error) ERR value unavailable'),
        );
        expect(
          server.commands,
          contains(equals(['GET', 'console:key'])),
        );
        expect(find.text('(error) ERR value unavailable'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await _disposeConsole(tester, server);
      },
    );
  }

  testWidgets(
      'Console helper tray excludes hidden and disconnected controls from focus',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await _pumpConnected(tester, server, dark: true);

    final helper = find.byKey(const ValueKey('cmd-console-helper-focus'));
    expect(tester.widget<ExcludeFocus>(helper).excluding, isFalse);

    await _submit(tester, 'PING', expected: find.text('PONG'));
    expect(tester.widget<ExcludeFocus>(helper).excluding, isTrue);

    await _disposeConsole(tester, server);
    await fx.pumpScreen(
      tester,
      dark: false,
      child: const CmdConsole(
        host: '127.0.0.1',
        port: 6379,
        running: false,
        instanceName: 'Stopped Redis',
      ),
    );

    expect(
        find.byKey(const ValueKey('cmd-console-helper-focus')), findsOneWidget);
    expect(tester.widget<ExcludeFocus>(helper).excluding, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Console restores focus and navigates command history',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await _pumpConnected(tester, server, dark: true);

    final input = _consoleInput();
    await _submit(tester, 'PING', expected: find.text('PONG'));
    await _submit(tester, 'DBSIZE', expected: find.text('(integer) 375'));

    final field = tester.widget<TextField>(input);
    expect(field.focusNode?.hasFocus, isTrue);
    expect(field.controller?.text, isEmpty);

    await tester.tap(input);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'DBSIZE');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'PING');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'DBSIZE');
    expect(tester.takeException(), isNull);

    await _disposeConsole(tester, server);
  });

  testWidgets('Console output remains scrollable without overflow',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await _pumpConnected(tester, server, dark: false);

    for (var i = 0; i < 14; i++) {
      await _submit(tester, 'INFO server');
    }
    expect(
      server.commands.where((args) => args.first == 'INFO').length,
      14,
    );

    final scrollables = find.descendant(
      of: find.byType(CmdConsole),
      matching: find.byType(Scrollable),
    );
    ScrollPosition? outputPosition;
    for (var i = 0; i < scrollables.evaluate().length; i++) {
      final position =
          tester.state<ScrollableState>(scrollables.at(i)).position;
      if (axisDirectionToAxis(position.axisDirection) == Axis.vertical &&
          position.maxScrollExtent > 0) {
        outputPosition = position;
        break;
      }
    }

    expect(outputPosition, isNotNull);
    outputPosition!.jumpTo(outputPosition.maxScrollExtent / 2);
    await tester.pump();
    expect(outputPosition.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);

    await _disposeConsole(tester, server);
  });
}
