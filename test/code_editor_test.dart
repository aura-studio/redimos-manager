import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/code_editor.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: child),
    );

List<TextSpan> _spans(
  WidgetTester tester,
  CodeHighlightController controller,
) {
  final context = tester.element(find.byType(CodeField));
  return controller
      .buildTextSpan(
        context: context,
        style: tester.widget<TextField>(find.byType(TextField)).style,
        withComposing: false,
      )
      .children!
      .cast<TextSpan>()
      .toList();
}

TextSpan _spanWithText(List<TextSpan> spans, String text) =>
    spans.firstWhere((span) => span.text == text);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'CodeEditor uses semantic JS highlighting and bundled mono in ${brightness.name}',
      (tester) async {
        final controller = CodeHighlightController(
          text: 'const value = parse("42") + 7; // note',
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          _app(
            SizedBox(
                width: 520,
                height: 180,
                child: CodeField(controller: controller)),
            brightness: brightness,
          ),
        );

        final tokens = AppTokens.forBrightness(brightness);
        final style = tester.widget<TextField>(find.byType(TextField)).style!;
        expect(style.fontFamily, Ts.monoFamily);
        expect(style.fontFamilyFallback, Ts.monoFallback);
        expect(style.fontSize, kCodeFontSize);
        expect(style.height, kCodeLineHeight);
        expect(find.byType(CodexSurface), findsOneWidget);

        final spans = _spans(tester, controller);
        final keyword = _spanWithText(spans, 'const');
        final function = _spanWithText(spans, 'parse');
        final string = _spanWithText(spans, '"42"');
        final number = _spanWithText(spans, '7');
        final comment = _spanWithText(spans, '// note');
        expect(keyword.style?.color, tokens.accent);
        expect(keyword.style?.fontWeight, FontWeight.w600);
        expect(function.style?.color, tokens.focus);
        expect(string.style?.color, tokens.success);
        expect(number.style?.color, tokens.warning);
        expect(comment.style?.color, tokens.text3);
        expect(comment.style?.fontStyle, FontStyle.italic);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('CodeEditor switches to Go keywords without changing plain text',
      (tester) async {
    final controller = CodeHighlightController(
      text: 'func main() { value := append(items, 1) }',
      lang: 'go',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(SizedBox(
          width: 520, height: 180, child: CodeField(controller: controller))),
    );

    const tokens = AppTokens.dark;
    final spans = _spans(tester, controller);
    expect(_spanWithText(spans, 'func').style?.color, tokens.accent);
    expect(_spanWithText(spans, 'append').style?.color, tokens.accent);
    expect(_spanWithText(spans, 'main').style?.color, tokens.focus);
    final plain = spans.where((span) => span.text?.contains('value') ?? false);
    expect(plain, isNotEmpty);
    expect(plain.first.style?.color, tokens.text);
  });

  testWidgets('CodeEditor keeps line numbers aligned with soft-wrapped rows',
      (tester) async {
    final controller = CodeHighlightController(
      text: '${List.filled(120, 'w').join()}\nsecond',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(
        Center(
          child: SizedBox(
            width: 220,
            height: 180,
            child: CodeField(controller: controller),
          ),
        ),
      ),
    );

    final one = find.descendant(
      of: find.byType(CodeField),
      matching: find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == '1',
      ),
    );
    final two = find.descendant(
      of: find.byType(CodeField),
      matching: find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == '2',
      ),
    );
    expect(one, findsOneWidget);
    expect(two, findsOneWidget);
    expect(
      tester.getTopLeft(two).dy - tester.getTopLeft(one).dy,
      greaterThan(kCodeFontSize * kCodeLineHeight),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('CodeEditor forwards edits and focuses from empty pane space',
      (tester) async {
    final controller = CodeHighlightController(text: 'first');
    final focusNode = FocusNode();
    final changes = <String>[];
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 480,
          height: 260,
          child: CodeField(
            controller: controller,
            focusNode: focusNode,
            onChanged: changes.add,
          ),
        ),
      ),
    );

    await tester.tapAt(
        tester.getBottomRight(find.byType(CodeField)) - const Offset(20, 20));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), 'second\nline');
    await tester.pump();
    expect(controller.text, 'second\nline');
    expect(changes, contains('second\nline'));
    expect(find.text('2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
