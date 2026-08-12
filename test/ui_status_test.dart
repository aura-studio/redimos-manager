import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_status.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('maps status aliases to semantic colors in $brightness',
        (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        _app(
          brightness,
          Builder(builder: (value) {
            context = value;
            return const SizedBox();
          }),
        ),
      );

      final tokens = AppTokens.forBrightness(brightness);
      expect(codexStatusColor(context, CodexStatus.running), tokens.success);
      expect(codexStatusColor(context, CodexStatus.success), tokens.success);
      expect(codexStatusColor(context, CodexStatus.warning), tokens.warning);
      expect(codexStatusColor(context, CodexStatus.danger), tokens.danger);
      expect(codexStatusColor(context, CodexStatus.error), tokens.danger);
      expect(codexStatusColor(context, CodexStatus.stopped), tokens.danger);
      expect(codexStatusColor(context, CodexStatus.neutral), tokens.text3);

      for (final status in CodexStatus.values) {
        expect(codexStatusColor(context, status), isNot(tokens.accent));
      }
    });

    testWidgets('keeps status dot geometry and semantics in $brightness',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          brightness,
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CodexStatusDot(
                key: ValueKey('plain-dot'),
                status: CodexStatus.running,
                semanticLabel: 'Redis running',
              ),
              SizedBox(width: 12),
              CodexStatusDot(
                key: ValueKey('glow-dot'),
                status: CodexStatus.stopped,
                semanticLabel: 'Redis stopped',
                glow: true,
              ),
            ],
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(const ValueKey('plain-dot'))),
        const Size.square(7),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('glow-dot'))),
        const Size.square(7),
      );
      expect(find.bySemanticsLabel('Redis running'), findsOneWidget);
      expect(find.bySemanticsLabel('Redis stopped'), findsOneWidget);

      final decorations = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((widget) => widget.decoration)
          .whereType<BoxDecoration>();
      expect(decorations.any((value) => value.boxShadow == null), isTrue);
      expect(decorations.any((value) => value.boxShadow?.length == 1), isTrue);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('keeps badge footprint stable across statuses in $brightness',
        (tester) async {
      await tester.pumpWidget(
        _app(
          brightness,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final status in CodexStatus.values) ...[
                CodexStatusBadge(
                  key: ValueKey('badge-${status.name}'),
                  status: status,
                  label: 'Status',
                  semanticLabel: '${status.name} status',
                ),
                if (status != CodexStatus.values.last) const SizedBox(width: 6),
              ],
            ],
          ),
        ),
      );

      final sizes = [
        for (final status in CodexStatus.values)
          tester.getSize(find.byKey(ValueKey('badge-${status.name}'))),
      ];
      expect(sizes.toSet(), hasLength(1));
      expect(sizes.first.height, 20);
      for (final status in CodexStatus.values) {
        expect(find.bySemanticsLabel('${status.name} status'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders accessible inline status indicator in $brightness',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          brightness,
          const CodexStatusIndicator(
            status: CodexStatus.warning,
            label: 'Degraded',
            semanticLabel: 'Backend degraded',
            glow: true,
          ),
        ),
      );

      expect(find.text('Degraded'), findsOneWidget);
      expect(find.bySemanticsLabel('Backend degraded'), findsOneWidget);
      expect(find.byType(CodexStatusDot), findsOneWidget);
      expect(tester.getSize(find.byType(CodexStatusDot)), const Size.square(7));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }
}
