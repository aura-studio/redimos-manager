import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/format_viewer.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'fake_core.dart';
import 'viewport_assertions.dart';

class _FormatCall {
  const _FormatCall({required this.format, required this.valueB64});

  final String format;
  final String valueB64;
}

class _CustomCall {
  const _CustomCall({
    required this.command,
    required this.params,
    required this.valueB64,
    required this.key,
    required this.field,
    required this.score,
    required this.member,
    required this.timeoutMs,
  });

  final String command;
  final String params;
  final String valueB64;
  final String key;
  final String field;
  final String score;
  final String member;
  final int timeoutMs;
}

class _FormatCore extends FakeNativeCore {
  final formatCalls = <_FormatCall>[];
  final customCalls = <_CustomCall>[];
  final formatResponses = <Future<Map<String, dynamic>>>[];
  final customResponses = <Future<Map<String, dynamic>>>[];
  final persisted = <List<CustomFormatter>>[];
  List<CustomFormatter> stored = const [];

  @override
  Future<Map<String, dynamic>> formatValue({
    required String format,
    required String valueB64,
  }) {
    formatCalls.add(_FormatCall(format: format, valueB64: valueB64));
    return formatResponses.removeAt(0);
  }

  @override
  Future<Map<String, dynamic>> formatCustom({
    required String command,
    required String params,
    required String valueB64,
    String key = '',
    String field = '',
    String score = '',
    String member = '',
    int timeoutMs = 5000,
  }) {
    customCalls.add(_CustomCall(
      command: command,
      params: params,
      valueB64: valueB64,
      key: key,
      field: field,
      score: score,
      member: member,
      timeoutMs: timeoutMs,
    ));
    return customResponses.removeAt(0);
  }

  @override
  List<CustomFormatter> getFormatters() => List.of(stored);

  @override
  void setFormatters(List<CustomFormatter> formatters) {
    stored = List.of(formatters);
    persisted.add(List.of(formatters));
  }
}

Map<String, dynamic> _decoded({
  String detected = 'Text',
  String text = 'decoded text',
  bool editable = true,
  bool printable = true,
}) =>
    {
      'ok': true,
      'detected': detected,
      'text': text,
      'size': utf8.encode(text).length,
      'sizeHuman': '${utf8.encode(text).length}B',
      'printable': printable,
      'editable': editable,
    };

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: child),
    );

Future<void> _pumpViewer(
  WidgetTester tester,
  _FormatCore core, {
  required Uint8List bytes,
  Brightness brightness = Brightness.dark,
  List<CustomFormatter> formatters = const [],
  Future<List<CustomFormatter>?> Function()? onManage,
  Future<void> Function(String)? onSave,
}) async {
  tester.view.physicalSize = const Size(900, 560);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _app(
      brightness,
      Padding(
        padding: const EdgeInsets.all(20),
        child: FormatViewer(
          core: core,
          bytes: bytes,
          formatters: formatters,
          onManage: onManage ?? () async => null,
          redisKey: 'user:7',
          field: 'profile',
          score: '12.5',
          member: 'member-7',
          onSave: onSave,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _selectFormat(WidgetTester tester, String format) async {
  final dropdown = tester
      .widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
  dropdown.onChanged!(format);
  await tester.pump();
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'FormatViewer preserves exact bytes and editable Text in ${brightness.name}',
      (tester) async {
        final bytes = Uint8List.fromList([0, 1, 2, 0xE4, 0xB8, 0xAD]);
        final core = _FormatCore()
          ..formatResponses.add(Future.value(_decoded(text: 'initial 中')));
        final saved = <String>[];
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

        await _pumpViewer(
          tester,
          core,
          bytes: bytes,
          brightness: brightness,
          onSave: (value) async => saved.add(value),
        );

        expect(core.formatCalls, hasLength(1));
        expect(core.formatCalls.single.format, 'Auto');
        expect(core.formatCalls.single.valueB64, base64.encode(bytes));
        expect(find.byType(CodexSelectField<String>), findsOneWidget);
        final editor = tester.widget<TextField>(find.byType(TextField));
        expect(editor.style?.fontFamily, Ts.monoFamily);
        expect(editor.style?.fontFamilyFallback, Ts.monoFallback);
        expect(editor.controller?.text, 'initial 中');

        await tester.enterText(find.byType(TextField), 'unsaved 中');
        await tester.pump();
        await tester.tap(find.widgetWithText(TextButton, tr('fmt.copy')));
        await tester.pump();
        expect(
          (clipboardCall?.arguments as Map<Object?, Object?>?)?['text'],
          'unsaved 中',
        );

        await tester.tap(find.widgetWithText(FilledButton, tr('fmt.save')));
        await tester.pump();
        expect(saved, ['unsaved 中']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
      'FormatViewer forwards custom formatter context and renders result',
      (tester) async {
    final bytes = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
    const formatter = CustomFormatter(
      name: 'Pretty',
      command: '/usr/local/bin/pretty',
      params: '--hex {HEX} --key {KEY}',
    );
    final core = _FormatCore()
      ..formatResponses.add(Future.value(_decoded(text: 'initial')))
      ..customResponses.add(Future.value({
        'ok': true,
        'text': 'custom decoded',
        'size': 4,
        'sizeHuman': '4B',
        'printable': false,
      }));

    await _pumpViewer(
      tester,
      core,
      bytes: bytes,
      formatters: const [formatter],
    );
    await _selectFormat(tester, 'Pretty');
    await tester.pump();

    expect(core.customCalls, hasLength(1));
    final call = core.customCalls.single;
    expect(call.command, formatter.command);
    expect(call.params, formatter.params);
    expect(call.valueB64, base64.encode(bytes));
    expect(call.key, 'user:7');
    expect(call.field, 'profile');
    expect(call.score, '12.5');
    expect(call.member, 'member-7');
    expect(call.timeoutMs, 5000);
    expect(find.text('custom decoded'), findsOneWidget);
    expect(find.text('[Hex]'), findsOneWidget);
    expect(find.byType(CodexSurface), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FormatViewer ignores an old decode after a newer selection',
      (tester) async {
    final auto = Completer<Map<String, dynamic>>();
    final hex = Completer<Map<String, dynamic>>();
    final core = _FormatCore()
      ..formatResponses.addAll([auto.future, hex.future]);

    await _pumpViewer(
      tester,
      core,
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    expect(core.formatCalls.single.format, 'Auto');

    await _selectFormat(tester, 'Hex');
    expect(core.formatCalls.map((call) => call.format), ['Auto', 'Hex']);

    hex.complete({
      'ok': true,
      'text': '01 02 03',
      'size': 3,
      'sizeHuman': '3B',
      'printable': false,
    });
    await tester.pump();
    expect(find.text('01 02 03'), findsOneWidget);

    auto.complete(_decoded(text: 'stale auto result'));
    await tester.pump();
    expect(find.text('stale auto result'), findsNothing);
    expect(find.text('01 02 03'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FormatViewer keeps oversize values local and read-only',
      (tester) async {
    final core = _FormatCore();
    final bytes = Uint8List(20 * 1024 * 1024 + 1)
      ..setRange(0, 7, utf8.encode('preview'));

    await _pumpViewer(
      tester,
      core,
      bytes: bytes,
      onSave: (_) async => fail('oversize preview must not save'),
    );

    expect(core.formatCalls, isEmpty);
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .onChanged,
      isNull,
    );
    expect(find.textContaining('too large to format'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, tr('fmt.save')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Custom formatter manager validates and persists a new formatter',
      (tester) async {
    final core = _FormatCore();
    List<CustomFormatter>? result;

    await tester.pumpWidget(
      _app(
        Brightness.dark,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showCustomFormatterManager(context, core);
              },
              child: const Text('Open manager'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open manager'));
    await tester.pumpAndSettle();
    expect(find.text(tr('fmt.customFormatter')), findsOneWidget);
    expect(find.byType(CodexSurface), findsOneWidget);
    expectInsideTestViewport(tester, find.byType(AlertDialog));
    expectHitTestable(
      tester,
      find.widgetWithText(OutlinedButton, tr('fmt.new')),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, tr('fmt.new')));
    await tester.pumpAndSettle();
    expect(find.text(tr('fmt.nameLabel')), findsOneWidget);
    expectInsideTestViewport(tester, find.byType(AlertDialog).last);
    expectHitTestable(
      tester,
      find.widgetWithText(FilledButton, tr('fmt.ok')),
    );

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'Text');
    await tester.enterText(fields.at(1), '/usr/bin/pretty');
    await tester.enterText(fields.at(2), '--value {VALUE}');
    await tester.tap(find.widgetWithText(FilledButton, tr('fmt.ok')));
    await tester.pump();
    expect(find.text(tr('fmt.nameCollides')), findsOneWidget);
    expectInsideTestViewport(
      tester,
      find.byType(AlertDialog).last,
      reason: 'validation feedback must not push the edit dialog off screen',
    );
    expectHitTestable(
      tester,
      find.widgetWithText(FilledButton, tr('fmt.ok')),
    );
    expect(core.persisted, isEmpty);

    await tester.enterText(fields.at(0), 'Pretty');
    await tester.tap(find.widgetWithText(FilledButton, tr('fmt.ok')));
    await tester.pumpAndSettle();
    expect(core.persisted, hasLength(1));
    expect(core.persisted.single, hasLength(1));
    expect(core.persisted.single.single.name, 'Pretty');
    expect(core.persisted.single.single.command, '/usr/bin/pretty');
    expect(core.persisted.single.single.params, '--value {VALUE}');

    await tester.tap(find.widgetWithText(FilledButton, tr('fmt.close')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.single.name, 'Pretty');
    expect(tester.takeException(), isNull);
  });
}
