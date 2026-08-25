import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/browser_page.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_states.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_table.dart';

import 'fake_core.dart';
import 'fake_resp_server.dart';
import 'screen_fixtures.dart' as fx;
import 'viewport_assertions.dart';

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

Future<void> _pumpLoaded(
  WidgetTester tester,
  FakeRespServer server, {
  required bool dark,
  GlobalKey? browserKey,
}) async {
  await fx.pumpScreen(
    tester,
    dark: dark,
    child: BrowserPageView(
      key: browserKey,
      config: fx.fixtureConfigAt(server.port),
      running: true,
      core: FakeNativeCore(),
    ),
  );
  await _waitFor(tester, find.text('cache'));
}

Finder _searchField() => find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Glob pattern, e.g. user:*',
    );

Future<void> _submitSearch(WidgetTester tester, String query) async {
  await tester.enterText(_searchField(), query);
  await tester.runAsync(() async {
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pump();
}

Future<void> _openKey(WidgetTester tester, String key) async {
  final keyText = find.byWidgetPredicate(
    (widget) => widget is Text && widget.data == key,
  );
  await _waitFor(tester, keyText);
  await tester.runAsync(() async {
    await tester.tap(keyText.first);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pump();
}

Future<void> _disposeBrowser(
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
      'Browser filters, selects, and scrolls in ${brightness.name}',
      (tester) async {
        final server = FakeRespServer();
        await tester.runAsync(server.start);
        await _pumpLoaded(
          tester,
          server,
          dark: brightness == Brightness.dark,
        );

        expect(find.byType(CodexSearchField), findsOneWidget);
        expect(find.byType(CodexSelectField<int>), findsOneWidget);
        expect(find.byType(CodexStateShell), findsWidgets);

        await _submitSearch(tester, 'user:*');
        expect(
          server.commands,
          contains(equals(['SCAN', '0', 'MATCH', 'user:*', 'COUNT', '300'])),
        );
        expect(find.text('user:1001'), findsOneWidget);
        expect(find.text('cache'), findsNothing);
        // Every scanned key uses the full type-badge row before any key is
        // opened; TYPE replies update badges in place without layout shifts.
        await _waitFor(
          tester,
          find.byKey(const ValueKey('browser-key-type-badge')),
        );
        // Tree and flat views are both kept alive, so each of the two scanned
        // keys has one badge in each view.
        expect(find.byKey(const ValueKey('browser-key-type-badge')),
            findsNWidgets(4));
        expect(
          server.commands.where((c) => c.isNotEmpty && c.first == 'TYPE'),
          containsAll([
            equals(['TYPE', 'user:1001']),
            equals(['TYPE', 'user:1002']),
          ]),
        );

        final userKey = find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == 'user:1001',
        );
        await tester.tap(userKey.first, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        final keyMenuItems = find.byType(PopupMenuItem<String>);
        expect(keyMenuItems, findsNWidgets(3));
        for (var i = 0; i < keyMenuItems.evaluate().length; i++) {
          expectInsideTestViewport(tester, keyMenuItems.at(i));
        }
        final openAction = find.widgetWithText(
          PopupMenuItem<String>,
          tr('br.open'),
        );
        expectHitTestable(tester, openAction);
        await tester.tap(openAction);
        await _waitFor(tester, find.text('Tony Chen'));
        expect(find.byType(CodexSurface), findsWidgets);
        expect(find.byType(CodexTableHeader), findsOneWidget);
        expect(find.byType(CodexTableRow), findsNWidgets(6));
        expect(find.text('Tony Chen'), findsOneWidget);

        await _submitSearch(tester, '*');
        await tester.tap(find.byTooltip('Flat view'));
        await tester.pump();

        final scrollables = find.descendant(
          of: find.byType(BrowserPageView),
          matching: find.byType(Scrollable),
        );
        ScrollPosition? keyListPosition;
        for (var i = 0; i < scrollables.evaluate().length; i++) {
          final position =
              tester.state<ScrollableState>(scrollables.at(i)).position;
          if (axisDirectionToAxis(position.axisDirection) == Axis.vertical &&
              position.maxScrollExtent > 0) {
            keyListPosition = position;
            break;
          }
        }
        expect(keyListPosition, isNotNull);
        keyListPosition!.jumpTo(120);
        await tester.pump();
        expect(keyListPosition.pixels, greaterThan(0));
        expect(tester.takeException(), isNull);

        await _disposeBrowser(tester, server);
      },
    );
  }

  testWidgets('New Key preserves the exact String SET callback parameters',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    final browserKey = GlobalKey();
    await _pumpLoaded(
      tester,
      server,
      dark: true,
      browserKey: browserKey,
    );

    final state = browserKey.currentState;
    expect(state, isNotNull);
    (state as dynamic).startCreateKey();
    await tester.pump();

    expect(find.text('New Key'), findsOneWidget);
    final nameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Key name',
    );
    final valueField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'first value',
    );
    await tester.enterText(nameField, 'created:key');
    await tester.enterText(valueField, 'payload-value');

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();

    expect(
      server.commands,
      contains(equals(['TYPE', 'created:key'])),
      reason: 'String creation must retain the overwrite preflight',
    );
    expect(
      server.commands,
      contains(equals(['SET', 'created:key', 'payload-value'])),
      reason: 'the dialog values must reach Redis unchanged',
    );
    expect(find.text('New Key'), findsNothing);
    expect(tester.takeException(), isNull);

    await _disposeBrowser(tester, server);
  });

  testWidgets('Browser renders bounded empty and key error states with retry',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await _pumpLoaded(tester, server, dark: false);

    await _submitSearch(tester, 'missing:*');
    expect(find.text('No keys'), findsOneWidget);
    expect(find.byType(CodexTablePlaceholder), findsOneWidget);

    await _submitSearch(tester, 'user:*');
    await _waitFor(tester, find.text('user:1001'));
    server.errorsByCommand['TYPE'] = 'ERR type unavailable';
    await _openKey(tester, 'user:1001');
    await _waitFor(tester, find.text('Cannot read key'));

    expect(find.text('ERR type unavailable'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Refresh'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _disposeBrowser(tester, server);
  });
}
