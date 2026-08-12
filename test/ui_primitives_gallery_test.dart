import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_states.dart';
import 'package:redimos_manager/src/ui_status.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_table.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'golden_fonts.dart';

const _logicalSize = Size(1280, 800);
const _diagnosticDirectoryVariable = 'REDIMOS_PRIMITIVES_GALLERY_DIR';
const _diagnosticRoot = '/Users/tony/Documents/Claude';
const _materialDefaultColors = <Color>[
  Color(0xFF2196F3),
  Color(0xFF3F51B5),
  Color(0xFF00BCD4),
  Color(0xFF6750A4),
];

void main() {
  setUpAll(loadGoldenFonts);

  for (final brightness in Brightness.values) {
    testWidgets('renders the complete primitive gallery in $brightness',
        (tester) async {
      final controllers = _GalleryStateControllers();
      addTearDown(controllers.dispose);
      final shotKey = GlobalKey();

      await _pumpGallery(tester, brightness, controllers, shotKey);

      expect(find.byKey(const ValueKey('primitive-gallery')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('primitive-gallery'))),
        _logicalSize,
      );
      for (final key in _requiredGalleryKeys) {
        expect(find.byKey(key), findsOneWidget, reason: '$key in $brightness');
      }
      for (final status in CodexStatus.values) {
        expect(find.text(_statusLabel(status)), findsWidgets);
      }
      for (final state in CodexContentState.values) {
        expect(
          find.byKey(ValueKey('state-${state.name}')),
          findsOneWidget,
        );
      }
      expect(find.byType(CodexButton), findsNWidgets(10));
      expect(find.byType(CodexIconButton), findsNWidgets(5));
      expect(find.byType(CodexTableRow), findsNWidgets(5));
      expect(find.byType(CodexStateShell), findsNWidgets(4));
      expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
      _expectThemeHasNoMaterialDefaultColors(tester, brightness);
      _expectIsolatedControlsUseInjectedFont(tester);
      expect(tester.takeException(), isNull);

      await _writeDiagnosticPngIfRequested(tester, shotKey, brightness);
    });
  }

  testWidgets('light and dark galleries retain identical section geometry',
      (tester) async {
    final controllers = _GalleryStateControllers();
    addTearDown(controllers.dispose);
    final shotKey = GlobalKey();

    await _pumpGallery(tester, Brightness.dark, controllers, shotKey);
    final darkBounds = <ValueKey<String>, Rect>{
      for (final key in _geometryKeys) key: tester.getRect(find.byKey(key)),
    };

    await _pumpGallery(tester, Brightness.light, controllers, shotKey);

    for (final key in _geometryKeys) {
      expect(tester.getRect(find.byKey(key)), darkBounds[key], reason: '$key');
    }
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpGallery(
  WidgetTester tester,
  Brightness brightness,
  _GalleryStateControllers controllers,
  GlobalKey shotKey,
) async {
  tester.view.physicalSize = _logicalSize * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(brightness, fontFamily: kGoldenUiFont),
      home: RepaintBoundary(
        key: shotKey,
        child: Scaffold(
          body: _PrimitiveGallery(controllers: controllers),
        ),
      ),
    ),
  );
  await tester.pump();
}

void _expectThemeHasNoMaterialDefaultColors(
  WidgetTester tester,
  Brightness brightness,
) {
  final context =
      tester.element(find.byKey(const ValueKey('primitive-gallery')));
  final theme = Theme.of(context);
  final tokens = theme.extension<AppTokens>();
  expect(tokens, isNotNull);
  expect(tokens, AppTokens.forBrightness(brightness));
  expect(theme.colorScheme.primary, tokens!.accent);
  expect(theme.colorScheme.surface, tokens.panel);

  final resolvedColors = <Color?>[
    theme.filledButtonTheme.style?.backgroundColor?.resolve({}),
    theme.filledButtonTheme.style?.backgroundColor?.resolve({
      WidgetState.hovered,
    }),
    theme.outlinedButtonTheme.style?.foregroundColor?.resolve({}),
    theme.outlinedButtonTheme.style?.side?.resolve({})?.color,
    theme.textButtonTheme.style?.foregroundColor?.resolve({}),
    theme.iconButtonTheme.style?.foregroundColor?.resolve({}),
    theme.textSelectionTheme.cursorColor,
    theme.textSelectionTheme.selectionHandleColor,
    theme.inputDecorationTheme.prefixIconColor,
  ];
  expect(resolvedColors, isNot(contains(isNull)));
  for (final color in resolvedColors.cast<Color>()) {
    expect(
      _materialDefaultColors,
      isNot(contains(color)),
      reason: 'Material default color $color leaked into $brightness gallery',
    );
  }
  expect(resolvedColors.first, tokens.accent);
  expect(theme.splashFactory, NoSplash.splashFactory);
  expect(theme.highlightColor, Colors.transparent);
}

void _expectIsolatedControlsUseInjectedFont(WidgetTester tester) {
  final context = tester.element(
    find.byKey(const ValueKey('primitive-gallery')),
  );
  final theme = Theme.of(context);
  final expectedFont = theme.textTheme.bodyMedium?.fontFamily;

  expect(expectedFont, kGoldenUiFont);
  expect(
    theme.filledButtonTheme.style?.textStyle?.resolve({})?.fontFamily,
    expectedFont,
  );
  expect(
    theme.outlinedButtonTheme.style?.textStyle?.resolve({})?.fontFamily,
    expectedFont,
  );
  expect(
    theme.textButtonTheme.style?.textStyle?.resolve({})?.fontFamily,
    expectedFont,
  );

  final dropdown = tester.widget<DropdownButton<String>>(
    find.byType(DropdownButton<String>),
  );
  expect(dropdown.style?.fontFamily, expectedFont);
}

Future<void> _writeDiagnosticPngIfRequested(
  WidgetTester tester,
  GlobalKey shotKey,
  Brightness brightness,
) async {
  final rawDirectory = Platform.environment[_diagnosticDirectoryVariable];
  if (rawDirectory == null || rawDirectory.trim().isEmpty) return;

  final directory = Directory(rawDirectory).absolute;
  final root = Directory(_diagnosticRoot).absolute.path;
  final path = directory.path;
  if (path != root && !path.startsWith('$root${Platform.pathSeparator}')) {
    fail(
      '$_diagnosticDirectoryVariable must be an absolute directory inside '
      '$_diagnosticRoot; received $rawDirectory',
    );
  }
  directory.createSync(recursive: true);
  final bytes = await _boundaryPng(tester, shotKey);
  File('${directory.path}/ui-primitives-${brightness.name}.png')
      .writeAsBytesSync(bytes);
}

Future<Uint8List> _boundaryPng(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

class _GalleryStateControllers {
  final idle = WidgetStatesController();
  final hovered = WidgetStatesController({WidgetState.hovered});
  final focused = WidgetStatesController({WidgetState.focused});
  final pressed = WidgetStatesController({WidgetState.pressed});
  final disabled = WidgetStatesController({WidgetState.disabled});
  final tableHovered = WidgetStatesController({WidgetState.hovered});

  List<MapEntry<String, WidgetStatesController>> get actionStates => [
        MapEntry('Idle', idle),
        MapEntry('Hover', hovered),
        MapEntry('Focus', focused),
        MapEntry('Pressed', pressed),
        MapEntry('Disabled', disabled),
      ];

  void dispose() {
    idle.dispose();
    hovered.dispose();
    focused.dispose();
    pressed.dispose();
    disabled.dispose();
    tableHovered.dispose();
  }
}

class _PrimitiveGallery extends StatelessWidget {
  const _PrimitiveGallery({required this.controllers});

  final _GalleryStateControllers controllers;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return ColoredBox(
      key: const ValueKey('primitive-gallery'),
      color: tokens.bg,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 28,
              child: Row(
                children: [
                  Text(
                    'CODEX UI PRIMITIVES',
                    style: Ts.style(
                      size: Ts.lg,
                      weight: FontWeight.w700,
                      color: tokens.text,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(child: CodexDivider()),
                  const SizedBox(width: 10),
                  CodexStatusIndicator(
                    status: CodexStatus.running,
                    label: Theme.of(context).brightness.name.toUpperCase(),
                    glow: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        _ActionGallery(controllers: controllers),
                        const SizedBox(height: 8),
                        const _FieldGallery(),
                        const SizedBox(height: 8),
                        const _SurfaceGallery(),
                        const SizedBox(height: 8),
                        const Expanded(child: _StatusGallery()),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      children: [
                        _TableGallery(controllers: controllers),
                        const SizedBox(height: 8),
                        const Expanded(child: _StateGallery()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionGallery extends StatelessWidget {
  const _ActionGallery({required this.controllers});

  final _GalleryStateControllers controllers;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('gallery-actions'),
        height: 126,
        child: CodexSurface(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CodexSectionHeader(label: 'ACTIONS / STATES'),
              const SizedBox(height: 6),
              Row(
                children: [
                  const CodexButton(
                    key: ValueKey('action-primary'),
                    variant: CodexButtonVariant.primary,
                    onPressed: _noop,
                    icon: Icon(Icons.play_arrow, size: 14),
                    label: Text('Primary'),
                  ),
                  const SizedBox(width: 6),
                  const CodexButton(
                    key: ValueKey('action-secondary'),
                    onPressed: _noop,
                    label: Text('Secondary'),
                  ),
                  const SizedBox(width: 6),
                  const CodexButton(
                    key: ValueKey('action-ghost'),
                    variant: CodexButtonVariant.ghost,
                    onPressed: _noop,
                    label: Text('Ghost'),
                  ),
                  const SizedBox(width: 6),
                  const CodexButton(
                    key: ValueKey('action-danger'),
                    variant: CodexButtonVariant.danger,
                    onPressed: _noop,
                    label: Text('Danger'),
                  ),
                  const Spacer(),
                  for (final variant in CodexButtonVariant.values) ...[
                    CodexIconButton(
                      key: ValueKey('icon-${variant.name}'),
                      variant: variant,
                      semanticLabel: '${variant.name} icon action',
                      onPressed: _noop,
                      icon: const Icon(Icons.refresh, size: 14),
                    ),
                    if (variant != CodexButtonVariant.values.last)
                      const SizedBox(width: 4),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final entry in controllers.actionStates) ...[
                    Expanded(
                      child: CodexButton(
                        key:
                            ValueKey('action-state-${entry.key.toLowerCase()}'),
                        statesController: entry.value,
                        onPressed: entry.key == 'Disabled' ? null : _noop,
                        label: Text(entry.key),
                      ),
                    ),
                    if (entry != controllers.actionStates.last)
                      const SizedBox(width: 5),
                  ],
                ],
              ),
            ],
          ),
        ),
      );
}

class _FieldGallery extends StatelessWidget {
  const _FieldGallery();

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('gallery-fields'),
        height: 132,
        child: CodexSurface(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CodexSectionHeader(label: 'FIELDS / VALIDATION'),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Expanded(
                    child: CodexTextField(
                      key: ValueKey('field-text'),
                      decoration: InputDecoration(hintText: 'Redis key'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: CodexSearchField(
                      key: ValueKey('field-search'),
                      hintText: 'Filter keys',
                      onSearch: _noop,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: CodexSelectField<String>(
                      key: const ValueKey('field-select'),
                      value: 'all',
                      items: const [
                        DropdownMenuItem(
                            value: 'all', child: Text('All types')),
                        DropdownMenuItem(value: 'hash', child: Text('Hash')),
                      ],
                      onChanged: (_) {},
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: CodexTextField(
                      key: ValueKey('field-error'),
                      hasError: true,
                      decoration: InputDecoration(hintText: 'Invalid port'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: CodexTextField(
                      key: ValueKey('field-disabled'),
                      enabled: false,
                      decoration: InputDecoration(hintText: 'Disabled'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: CodexTextFormField(
                      key: const ValueKey('field-form-error'),
                      initialValue: '',
                      autovalidateMode: AutovalidateMode.always,
                      validator: (_) => 'Value is required',
                      decoration: const InputDecoration(hintText: 'Required'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

class _SurfaceGallery extends StatelessWidget {
  const _SurfaceGallery();

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('gallery-surfaces'),
        height: 104,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final variant in CodexSurfaceVariant.values) ...[
              Expanded(
                child: CodexSurface(
                  key: ValueKey('surface-${variant.name}'),
                  variant: variant,
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CodexSectionHeader(label: variant.name.toUpperCase()),
                      const SizedBox(height: 7),
                      Text(
                        'Warm neutral surface',
                        style: Ts.style(
                          size: Ts.sm,
                          color: AppTokens.of(context).text2,
                        ),
                      ),
                      const Spacer(),
                      const CodexDivider(),
                    ],
                  ),
                ),
              ),
              if (variant != CodexSurfaceVariant.values.last)
                const SizedBox(width: 6),
            ],
          ],
        ),
      );
}

class _StatusGallery extends StatelessWidget {
  const _StatusGallery();

  @override
  Widget build(BuildContext context) => CodexSurface(
        key: const ValueKey('gallery-statuses'),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const CodexSectionHeader(label: 'OPERATIONAL STATUS'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final status in CodexStatus.values)
                  CodexStatusBadge(
                    status: status,
                    label: _statusLabel(status),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const CodexStatusDot(
                  status: CodexStatus.running,
                  semanticLabel: 'Running dot',
                  glow: true,
                ),
                const SizedBox(width: 12),
                for (final status in [
                  CodexStatus.success,
                  CodexStatus.warning,
                  CodexStatus.error,
                  CodexStatus.neutral,
                ]) ...[
                  CodexStatusIndicator(
                    status: status,
                    label: _statusLabel(status),
                  ),
                  const SizedBox(width: 12),
                ],
              ],
            ),
          ],
        ),
      );
}

class _TableGallery extends StatelessWidget {
  const _TableGallery({required this.controllers});

  final _GalleryStateControllers controllers;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('gallery-table'),
        height: 320,
        child: CodexSurface(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CodexSectionHeader(label: 'TABLE / SCROLL / STATES'),
              const SizedBox(height: 6),
              Expanded(
                child: CodexTableViewport(
                  child: SizedBox(
                    width: 720,
                    child: Column(
                      children: [
                        const CodexTableHeader(
                          children: [
                            CodexTableHeaderCell(label: 'State', width: 112),
                            CodexTableHeaderCell(label: 'Key', flex: 1),
                            CodexTableHeaderCell(
                              label: 'Count',
                              width: 96,
                              alignment: Alignment.centerRight,
                            ),
                          ],
                        ),
                        _row('Normal', 'orders:normal', '1,248'),
                        _row('Striped', 'orders:striped', '2,496',
                            striped: true),
                        _row(
                          'Hovered',
                          'orders:hovered',
                          '3,744',
                          statesController: controllers.tableHovered,
                        ),
                        _row(
                          'Selected',
                          'orders:selected',
                          '4,992',
                          selected: true,
                        ),
                        _row(
                          'Disabled',
                          'orders:disabled',
                          '6,240',
                          enabled: false,
                        ),
                        const Row(
                          children: [
                            Expanded(
                              child: CodexTablePlaceholder.loading(
                                key: ValueKey('table-loading'),
                                message: 'Loading rows',
                                height: 84,
                              ),
                            ),
                            CodexDivider(axis: Axis.vertical),
                            Expanded(
                              child: CodexTablePlaceholder.empty(
                                key: ValueKey('table-empty'),
                                message: 'No matching rows',
                                height: 84,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  static CodexTableRow _row(
    String state,
    String key,
    String count, {
    bool striped = false,
    bool selected = false,
    bool enabled = true,
    WidgetStatesController? statesController,
  }) =>
      CodexTableRow(
        key: ValueKey('table-row-${state.toLowerCase()}'),
        striped: striped,
        selected: selected,
        enabled: enabled,
        statesController: statesController,
        children: [
          CodexTableCell(value: state, width: 112, emphasized: selected),
          CodexTableCell(
            value: key,
            kind: CodexTableCellKind.identifier,
            flex: 1,
          ),
          CodexTableCell(
            value: count,
            kind: CodexTableCellKind.numeric,
            width: 96,
            alignment: Alignment.centerRight,
          ),
        ],
      );
}

class _StateGallery extends StatelessWidget {
  const _StateGallery();

  @override
  Widget build(BuildContext context) => CodexSurface(
        key: const ValueKey('gallery-content-states'),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const CodexSectionHeader(label: 'BOUNDED CONTENT STATES'),
            const SizedBox(height: 6),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(child: _state(CodexContentState.content)),
                        const SizedBox(height: 6),
                        Expanded(child: _state(CodexContentState.empty)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(child: _state(CodexContentState.loading)),
                        const SizedBox(height: 6),
                        Expanded(child: _state(CodexContentState.error)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  static Widget _state(CodexContentState state) => CodexStateShell(
        key: ValueKey('state-${state.name}'),
        state: state,
        toolbar: SizedBox(
          height: 18,
          child: Text(
            state.name.toUpperCase(),
            style: Ts.style(size: Ts.xs, weight: FontWeight.w700),
          ),
        ),
        filters: const SizedBox(
          height: 18,
          child: CodexTextField(
            enabled: false,
            height: 18,
            decoration: InputDecoration(hintText: 'Persistent filter'),
          ),
        ),
        content: const CodexSurface(
          variant: CodexSurfaceVariant.sunken,
          padding: EdgeInsets.all(8),
          child: Center(child: Text('Loaded content')),
        ),
        message: switch (state) {
          CodexContentState.content => 'Loaded content',
          CodexContentState.loading => 'Loading records',
          CodexContentState.empty => 'No records',
          CodexContentState.error => 'Cannot load records',
        },
        detail: state == CodexContentState.error
            ? 'ERR request 23'
            : state == CodexContentState.empty
                ? 'Change the active filter.'
                : null,
        retryLabel: state == CodexContentState.error ? 'Retry' : null,
        onRetry: state == CodexContentState.error ? _noop : null,
        bodyPadding: const EdgeInsets.all(6),
        headerGap: 3,
      );
}

const _requiredGalleryKeys = <ValueKey<String>>[
  ValueKey('gallery-actions'),
  ValueKey('action-primary'),
  ValueKey('action-secondary'),
  ValueKey('action-ghost'),
  ValueKey('action-danger'),
  ValueKey('action-state-idle'),
  ValueKey('action-state-hover'),
  ValueKey('action-state-focus'),
  ValueKey('action-state-pressed'),
  ValueKey('action-state-disabled'),
  ValueKey('gallery-fields'),
  ValueKey('field-text'),
  ValueKey('field-search'),
  ValueKey('field-select'),
  ValueKey('field-error'),
  ValueKey('field-disabled'),
  ValueKey('field-form-error'),
  ValueKey('gallery-surfaces'),
  ValueKey('surface-standard'),
  ValueKey('surface-elevated'),
  ValueKey('surface-sunken'),
  ValueKey('gallery-statuses'),
  ValueKey('gallery-table'),
  ValueKey('table-row-normal'),
  ValueKey('table-row-striped'),
  ValueKey('table-row-hovered'),
  ValueKey('table-row-selected'),
  ValueKey('table-row-disabled'),
  ValueKey('table-loading'),
  ValueKey('table-empty'),
  ValueKey('gallery-content-states'),
];

const _geometryKeys = <ValueKey<String>>[
  ValueKey('primitive-gallery'),
  ValueKey('gallery-actions'),
  ValueKey('gallery-fields'),
  ValueKey('gallery-surfaces'),
  ValueKey('gallery-statuses'),
  ValueKey('gallery-table'),
  ValueKey('gallery-content-states'),
];

String _statusLabel(CodexStatus status) => switch (status) {
      CodexStatus.running => 'Running',
      CodexStatus.success => 'Success',
      CodexStatus.warning => 'Warning',
      CodexStatus.danger => 'Danger',
      CodexStatus.error => 'Error',
      CodexStatus.stopped => 'Stopped',
      CodexStatus.neutral => 'Neutral',
    };

void _noop() {}
