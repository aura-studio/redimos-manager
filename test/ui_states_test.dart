import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_states.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('keeps persistent anchors and body bounds in $brightness',
        (tester) async {
      final geometry = <CodexContentState, List<Rect>>{};

      for (final state in CodexContentState.values) {
        await tester.pumpWidget(
          _app(
            brightness,
            SizedBox(
              width: 520,
              height: 360,
              child: CodexStateShell(
                state: state,
                toolbar: const SizedBox(
                  key: ValueKey('toolbar'),
                  height: 30,
                  child: Text('Toolbar'),
                ),
                filters: const SizedBox(
                  key: ValueKey('filters'),
                  height: 30,
                  child: Text('Filters'),
                ),
                content: const SizedBox.expand(
                  key: ValueKey('content'),
                  child: Text('Loaded content'),
                ),
                message: 'State message',
                detail: 'Domain detail',
                retryLabel: 'Retry',
                onRetry: () {},
              ),
            ),
          ),
        );

        geometry[state] = [
          tester.getRect(find.byKey(const ValueKey('toolbar'))),
          tester.getRect(find.byKey(const ValueKey('filters'))),
          tester.getRect(
            find
                .descendant(
                  of: find.byType(CodexStateShell),
                  matching: find.byType(ClipRect),
                )
                .first,
          ),
        ];
        expect(tester.takeException(), isNull);
      }

      final expectedGeometry = geometry[CodexContentState.content]!;
      for (final state in CodexContentState.values) {
        expect(geometry[state], expectedGeometry);
      }
      expect(expectedGeometry[2].size, const Size(520, 284));
    });

    testWidgets('renders accessible loading and empty states in $brightness',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          brightness,
          const Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 220,
                  child: CodexStateShell(
                    state: CodexContentState.loading,
                    content: SizedBox(),
                    message: 'Loading records',
                  ),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 220,
                  child: CodexStateShell(
                    state: CodexContentState.empty,
                    content: SizedBox(),
                    message: 'No records',
                    detail: 'Change the active filter.',
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
      expect(find.text('Change the active filter.'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading records'), findsOneWidget);
      expect(find.bySemanticsLabel('No records'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('preserves domain error text and invokes retry unchanged',
      (tester) async {
    var retries = 0;
    const domainError = 'ProvisionedThroughputExceededException: request 17';
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(
        Brightness.dark,
        SizedBox(
          width: 480,
          height: 260,
          child: CodexStateShell(
            state: CodexContentState.error,
            content: const SizedBox(),
            message: 'Cannot read table',
            detail: domainError,
            retryLabel: 'Retry table request',
            onRetry: () => retries++,
          ),
        ),
      ),
    );

    expect(find.text(domainError), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.bySemanticsLabel('Cannot read table'), findsOneWidget);
    expect(find.bySemanticsLabel('Retry table request'), findsOneWidget);

    await tester.tap(find.text('Retry table request'));
    await tester.pump();
    expect(retries, 1);

    final errorIcon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
    expect(errorIcon.color, AppTokens.dark.danger);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('renders loaded content without placeholder decoration',
      (tester) async {
    await tester.pumpWidget(
      _app(
        Brightness.light,
        const SizedBox(
          width: 300,
          height: 180,
          child: CodexStateShell(
            state: CodexContentState.content,
            content: ColoredBox(
              key: ValueKey('loaded-body'),
              color: Colors.transparent,
            ),
            message: 'Not displayed',
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('loaded-body')), findsOneWidget);
    expect(find.text('Not displayed'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.inbox_outlined), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
