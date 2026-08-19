import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 280, child: child),
        ),
      ),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('keeps text and search geometry fixed in $brightness',
        (tester) async {
      final controller = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      var searches = 0;

      await tester.pumpWidget(
        _app(
          brightness,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CodexTextField(
                key: const ValueKey('text'),
                controller: controller,
                focusNode: focusNode,
                decoration: const InputDecoration(
                  hintText: 'Port',
                  prefixIcon: Icon(Icons.numbers, size: 15),
                  suffixIcon: Icon(Icons.check, size: 15),
                ),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 8),
              CodexSearchField(
                key: const ValueKey('search'),
                hintText: 'Search keys',
                searchLabel: 'Run search',
                onSearch: () => searches++,
              ),
            ],
          ),
        ),
      );

      expect(
          tester.getSize(find.byKey(const ValueKey('text'))).height, Dim.ctlH);
      expect(
        tester.getSize(find.byKey(const ValueKey('search'))).height,
        Dim.ctlH,
      );
      expect(find.byIcon(Icons.numbers), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.bySemanticsLabel('Run search'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('text')), '63x79');
      expect(controller.text, '6379');
      focusNode.requestFocus();
      await tester.pump();
      expect(
          tester.getSize(find.byKey(const ValueKey('text'))).height, Dim.ctlH);

      await tester.tap(find.bySemanticsLabel('Run search'));
      await tester.pump();
      expect(searches, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('preserves form validation contracts in $brightness',
        (tester) async {
      final formKey = GlobalKey<FormState>();
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final changes = <String>[];
      String? saved;

      await tester.pumpWidget(
        _app(
          brightness,
          Form(
            key: formKey,
            child: CodexTextFormField(
              key: const ValueKey('form-field'),
              controller: controller,
              decoration: const InputDecoration(hintText: 'Name'),
              validator: (value) =>
                  value == null || value.isEmpty ? 'Required' : null,
              onChanged: changes.add,
              onSaved: (value) => saved = value,
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(TextField)).height, Dim.ctlH);
      expect(formKey.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);
      expect(tester.getSize(find.byType(TextField)).height, Dim.ctlH);

      final tokens = AppTokens.forBrightness(brightness);
      final errored = tester.widget<TextField>(find.byType(TextField));
      final errorBorder =
          errored.decoration!.enabledBorder! as OutlineInputBorder;
      expect(errorBorder.borderSide.color, tokens.danger);

      await tester.enterText(find.byType(TextField), 'cache-a');
      expect(changes, ['cache-a']);
      expect(formKey.currentState!.validate(), isTrue);
      formKey.currentState!.save();
      expect(saved, 'cache-a');

      controller.text = '';
      await tester.pump();
      expect(formKey.currentState!.validate(), isFalse);
      controller.text = 'programmatic';
      await tester.pump();
      expect(formKey.currentState!.validate(), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('forwards search submission in $brightness', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final submissions = <String>[];
      final changes = <String>[];

      await tester.pumpWidget(
        _app(
          brightness,
          CodexSearchField(
            controller: controller,
            hintText: 'Glob pattern',
            onChanged: changes.add,
            onSubmitted: submissions.add,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'user:*');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(controller.text, 'user:*');
      expect(changes, ['user:*']);
      expect(submissions, ['user:*']);
      expect(tester.getSize(find.byType(CodexSearchField)).height, Dim.ctlH);
    });

    testWidgets('keeps select geometry and nullable callback in $brightness',
        (tester) async {
      String? selected;
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _app(
          brightness,
          CodexSelectField<String>(
            key: const ValueKey('select'),
            value: 'alpha',
            focusNode: focusNode,
            items: const [
              DropdownMenuItem(value: 'alpha', child: Text('Alpha')),
              DropdownMenuItem(value: 'beta', child: Text('Beta')),
            ],
            onChanged: (value) => selected = value,
          ),
        ),
      );

      expect(tester.getSize(find.byKey(const ValueKey('select'))).height,
          Dim.ctlH);
      focusNode.requestFocus();
      await tester.pump();
      expect(tester.getSize(find.byKey(const ValueKey('select'))).height,
          Dim.ctlH);

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta').last);
      await tester.pumpAndSettle();

      expect(selected, 'beta');
      expect(find.text('Beta'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders disabled text and select controls in $brightness',
        (tester) async {
      await tester.pumpWidget(
        _app(
          brightness,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CodexTextField(
                key: ValueKey('disabled-text'),
                enabled: false,
                decoration: InputDecoration(hintText: 'Disabled'),
              ),
              const SizedBox(height: 8),
              CodexSelectField<String>(
                key: const ValueKey('disabled-select'),
                value: 'alpha',
                enabled: false,
                items: const [
                  DropdownMenuItem(value: 'alpha', child: Text('Alpha')),
                ],
                onChanged: (_) => fail('disabled select called its callback'),
              ),
            ],
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(const ValueKey('disabled-text'))).height,
        Dim.ctlH,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('disabled-select'))).height,
        Dim.ctlH,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        tester
            .widget<CodexSelectField<String>>(
              find.byType(CodexSelectField<String>),
            )
            .enabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
