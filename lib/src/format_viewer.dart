// The ARDM-style value format viewer: a dropdown that decodes a redis value as
// Text / Hex / Json / Binary / Msgpack / PHPSerialize / JavaSerialize / Pickle /
// Brotli / Gzip / Deflate / DeflateRaw / Protobuf, plus user-defined custom
// formatters, with a Size tag, a [Hex] binary tag, and a Copy button. Decoding
// runs in the Go core (native.formatValue / formatCustom) over the value's EXACT
// bytes, so binary payloads decode faithfully. On first load the encoding is
// auto-detected (same precedence as ARDM) and shown as the selected format.
//
// Text is the one editable format (when an onSave callback is supplied); every
// other format is a read-only decoded view — matching how the String editor and
// the row "view value" dialog use this widget.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

/// The built-in formats, in dropdown order (matches ARDM's list).
const List<String> kBuiltinFormats = [
  'Text',
  'Hex',
  'Json',
  'Binary',
  'Msgpack',
  'PHPSerialize',
  'JavaSerialize',
  'Pickle',
  'Brotli',
  'Gzip',
  'Deflate',
  'DeflateRaw',
  'Protobuf',
];

const String _kCustomizeSentinel = '__customize__';

class FormatViewer extends StatefulWidget {
  final NativeCore core;

  /// The value's EXACT bytes (binary-safe). Decoding is done over these.
  final Uint8List bytes;

  /// Persisted custom formatters (extra dropdown entries).
  final List<CustomFormatter> formatters;

  /// Open the custom-formatter manager; the returned list (if non-null) replaces
  /// the dropdown's custom entries.
  final Future<List<CustomFormatter>?> Function() onManage;

  // Template context for custom formatters.
  final String redisKey;
  final String field;
  final String score;
  final String member;

  /// When non-null, the Text format is editable and this saves the edited text.
  final Future<void> Function(String)? onSave;

  const FormatViewer({
    super.key,
    required this.core,
    required this.bytes,
    required this.formatters,
    required this.onManage,
    this.redisKey = '',
    this.field = '',
    this.score = '',
    this.member = '',
    this.onSave,
  });

  @override
  State<FormatViewer> createState() => _FormatViewerState();
}

class _FormatViewerState extends State<FormatViewer> {
  late List<CustomFormatter> _formatters;
  String _format = 'Text';
  final _edit = TextEditingController();

  bool _loading = true;
  String _decoded = '';
  String _error = '';
  int _size = 0;
  String _sizeHuman = '0';
  bool _printable = true;
  // Whether the native decoder says this value is editable as Text (false for
  // non-UTF-8 bytes, whose Text view is mojibake and must not be saved back).
  bool _nativeEditable = true;
  // The edit buffer is seeded from the decoded text exactly once per value, so
  // switching format away from Text and back never clobbers unsaved edits.
  bool _editSeeded = false;

  // A monotonically increasing token so a slow decode that finishes after the
  // user switched format (or the bytes changed) is ignored.
  int _reqSeq = 0;

  bool get _editableText =>
      widget.onSave != null && _format == 'Text' && _nativeEditable;

  @override
  void initState() {
    super.initState();
    _formatters = List.of(widget.formatters);
    _autoDetectAndDecode();
  }

  @override
  void didUpdateWidget(FormatViewer old) {
    super.didUpdateWidget(old);
    // New value bytes (e.g. the row/key changed) → re-detect from scratch.
    if (!_bytesEqual(old.bytes, widget.bytes)) {
      _autoDetectAndDecode();
    }
    if (old.formatters != widget.formatters) {
      setState(() => _formatters = List.of(widget.formatters));
    }
  }

  @override
  void dispose() {
    _edit.dispose();
    super.dispose();
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // Past this size we don't base64-encode/ship the value across the FFI boundary
  // (the encode would run on the UI isolate); show a bounded local preview
  // instead, mirroring the native oversize cap.
  static const int _kOversizeBytes = 20 * 1024 * 1024;
  static const int _kOversizePreview = 20000;

  bool get _oversize => widget.bytes.length > _kOversizeBytes;

  bool _isCustom(String name) => _formatters.any((f) => f.name == name);

  Future<void> _autoDetectAndDecode() async {
    _editSeeded =
        false; // a fresh value → allow the edit buffer to reseed from it
    if (_oversize) {
      _showOversizeLocally();
      return;
    }
    final seq = ++_reqSeq;
    setState(() => _loading = true);
    final r = await widget.core
        .formatValue(format: 'Auto', valueB64: base64.encode(widget.bytes));
    if (!mounted || seq != _reqSeq) return;
    final detected = (r['detected'] as String?) ?? 'Text';
    setState(() {
      _format = kBuiltinFormats.contains(detected) ? detected : 'Text';
      _applyResult(r);
      _seedEditIfText();
    });
  }

  Future<void> _decodeAs(String format) async {
    if (_oversize) {
      // Selector is disabled when oversize, but guard anyway.
      _showOversizeLocally();
      return;
    }
    final seq = ++_reqSeq;
    setState(() {
      _format = format;
      _loading = true;
      _error = '';
    });

    Map<String, dynamic> r;
    if (_isCustom(format)) {
      final f = _formatters.firstWhere((x) => x.name == format);
      r = await widget.core.formatCustom(
        command: f.command,
        params: f.params,
        valueB64: base64.encode(widget.bytes),
        key: widget.redisKey,
        field: widget.field,
        score: widget.score,
        member: widget.member,
      );
    } else {
      r = await widget.core
          .formatValue(format: format, valueB64: base64.encode(widget.bytes));
    }
    if (!mounted || seq != _reqSeq) return;
    setState(() {
      _applyResult(r);
      _seedEditIfText();
    });
  }

  /// Seed the editable buffer from the decoded text exactly ONCE per value, so a
  /// later away-and-back to Text doesn't wipe unsaved edits.
  void _seedEditIfText() {
    if (_format == 'Text' && !_editSeeded) {
      _edit.text = _decoded;
      _editSeeded = true;
    }
  }

  /// Render an oversize value locally (first N bytes) without base64-encoding the
  /// whole thing; read-only, and the selector is disabled.
  void _showOversizeLocally() {
    final slice = widget.bytes.length > _kOversizePreview
        ? widget.bytes.sublist(0, _kOversizePreview)
        : widget.bytes;
    final human = _humanSize(widget.bytes.length);
    setState(() {
      _reqSeq++; // cancel any in-flight decode
      _loading = false;
      _format = 'Text';
      _decoded = '${utf8.decode(slice, allowMalformed: true)}\n\n'
          '… (value is $human, showing first $_kOversizePreview bytes — too large to format)';
      _error = '';
      _size = widget.bytes.length;
      _sizeHuman = human;
      _printable = true;
      _nativeEditable = false; // never save a truncated preview back
      _editSeeded = true;
    });
  }

  static String _humanSize(int n) {
    if (n < 1024) return '${n}B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var v = n / 1024;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    final s = v.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
    return '$s${units[i]}';
  }

  void _applyResult(Map<String, dynamic> r) {
    _loading = false;
    _decoded = (r['text'] as String?) ?? '';
    _error = (r['ok'] == true) ? '' : ((r['error'] as String?) ?? '');
    _size = (r['size'] as int?) ?? widget.bytes.length;
    _sizeHuman = (r['sizeHuman'] as String?) ?? '$_size';
    _printable = (r['printable'] as bool?) ?? true;
    // Text editability is decided natively (non-UTF-8 → read-only); custom/other
    // formats omit the flag and are read-only regardless.
    _nativeEditable = (r['editable'] as bool?) ?? false;
  }

  Future<void> _onSelect(String? v) async {
    if (v == null || v == _format) return;
    if (v == _kCustomizeSentinel) {
      final updated = await widget.onManage();
      if (!mounted) return;
      if (updated != null) {
        setState(() => _formatters = updated);
        // If the active custom format was just deleted/renamed away, re-sync the
        // body with the dropdown's fallback so label and content agree.
        if (!kBuiltinFormats.contains(_format) && !_isCustom(_format)) {
          await _autoDetectAndDecode();
        }
      }
      return; // otherwise keep the current format
    }
    await _decodeAs(v);
  }

  Future<void> _copy() async {
    final text = _editableText ? _edit.text : _decoded;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('fmt.copied')),
          duration: const Duration(milliseconds: 900)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _bar(tokens),
      const SizedBox(height: 8),
      Expanded(child: _body(tokens)),
      if (widget.onSave != null) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: CodexButton(
            variant: CodexButtonVariant.primary,
            semanticLabel: tr('fmt.save'),
            // Only Text edits are saved (other formats are read-only decoded views).
            onPressed: _editableText ? () => widget.onSave!(_edit.text) : null,
            label: Text(tr('fmt.save')),
          ),
        ),
      ],
    ]);
  }

  Widget _bar(AppTokens tokens) {
    // Dedupe by value: a custom formatter whose name collides with a built-in
    // (or another custom) would otherwise create two items sharing one value and
    // trip DropdownButton's single-match assertion. Built-ins always win.
    final seen = <String>{...kBuiltinFormats};
    final items = <DropdownMenuItem<String>>[
      for (final f in kBuiltinFormats)
        DropdownMenuItem(value: f, child: Text(f)),
      for (final f in _formatters)
        if (seen.add(f.name))
          DropdownMenuItem(value: f.name, child: Text(f.name)),
      DropdownMenuItem(
        value: _kCustomizeSentinel,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.edit_outlined, size: 14),
          const SizedBox(width: 4),
          Text(tr('fmt.customize')),
        ]),
      ),
    ];
    // The selected value must exist in items (a since-deleted custom name won't).
    final value = items.any((i) => i.value == _format) ? _format : 'Text';

    return SizedBox(
      height: Dim.ctlH,
      child: Row(children: [
        SizedBox(
          width: 190,
          child: CodexSelectField<String>(
            value: value,
            items: items,
            enabled: !_oversize,
            // ARDM disables the selector for oversize values (we show a preview).
            onChanged: _oversize ? null : _onSelect,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.account_tree_outlined, size: 15),
            ),
          ),
        ),
        const SizedBox(width: 10),
        if (!_printable) ...[
          _tag('[Hex]', tokens),
          const SizedBox(width: 8),
        ],
        _tag('${tr('fmt.size')}: $_sizeHuman', tokens),
        const SizedBox(width: 8),
        CodexButton(
          variant: CodexButtonVariant.ghost,
          semanticLabel: tr('fmt.copy'),
          onPressed: _copy,
          icon: const Icon(Icons.copy_outlined, size: 14),
          label: Text(tr('fmt.copy')),
        ),
        if (_loading) ...[
          const SizedBox(width: 8),
          SizedBox.square(
            dimension: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: tokens.accent,
            ),
          ),
        ],
      ]),
    );
  }

  Widget _tag(String text, AppTokens tokens) => Container(
        constraints: const BoxConstraints(minHeight: 20),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: tokens.panel2,
          border: Border.all(color: tokens.border, width: Dim.borderW),
          borderRadius: BorderRadius.circular(Dim.radiusS),
        ),
        child: Text(
          text,
          style: Ts.style(
            size: Ts.xs,
            color: tokens.text2,
            monoFont: true,
            tabularNums: true,
          ),
        ),
      );

  Widget _body(AppTokens tokens) {
    final monoStyle = Ts.style(
      size: Ts.lg,
      color: tokens.text,
      monoFont: true,
    );
    if (_editableText) {
      return LayoutBuilder(
        builder: (context, constraints) => CodexTextField(
          controller: _edit,
          expands: true,
          minLines: null,
          maxLines: null,
          height: constraints.maxHeight,
          style: monoStyle,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.all(12),
          ),
        ),
      );
    }
    final Widget content;
    if (_error.isNotEmpty && _decoded.isEmpty) {
      content = SelectableText(
        _error,
        style: monoStyle.copyWith(color: tokens.warning),
      );
    } else {
      content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error,
              style: Ts.style(
                size: Ts.md,
                color: tokens.warning,
                monoFont: true,
              ),
            ),
          ),
        SelectableText(_decoded, style: monoStyle),
      ]);
    }
    return CodexSurface(
      variant: CodexSurfaceVariant.sunken,
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: Align(alignment: Alignment.topLeft, child: content),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Custom-formatter manager (ARDM's "Custom Formatter" dialog): a table of
// {Name, Formatter} with New/Edit/Delete, backed by native persistence.
// ---------------------------------------------------------------------------

/// Show the manager. Returns the (possibly edited) list, or null if nothing
/// changed. The list is persisted natively as edits are applied.
Future<List<CustomFormatter>?> showCustomFormatterManager(
    BuildContext context, NativeCore core) async {
  return showDialog<List<CustomFormatter>>(
    context: context,
    builder: (ctx) => _CustomFormatterManager(core: core),
  );
}

class _CustomFormatterManager extends StatefulWidget {
  final NativeCore core;
  const _CustomFormatterManager({required this.core});

  @override
  State<_CustomFormatterManager> createState() =>
      _CustomFormatterManagerState();
}

class _CustomFormatterManagerState extends State<_CustomFormatterManager> {
  late List<CustomFormatter> _list;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _list = widget.core.getFormatters();
  }

  Future<void> _persist() async {
    try {
      widget.core.setFormatters(_list);
      _dirty = true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${tr('fmt.saveFailed')}: $e')));
      }
    }
  }

  Future<void> _editOrNew({CustomFormatter? existing, int? index}) async {
    // Names that would collide (built-ins + other customs); the entry being
    // edited is allowed to keep its own name.
    final reserved = <String>{
      ...kBuiltinFormats,
      for (final f in _list)
        if (f.name != existing?.name) f.name,
    };
    final result = await showDialog<CustomFormatter>(
      context: context,
      builder: (ctx) =>
          _FormatterEditDialog(existing: existing, reserved: reserved),
    );
    if (result == null) return;
    setState(() {
      if (index != null) {
        _list[index] = result;
      } else {
        _list.add(result);
      }
    });
    await _persist();
  }

  Future<void> _delete(int index) async {
    setState(() => _list.removeAt(index));
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final headerStyle = Ts.style(
      size: Ts.sm,
      weight: FontWeight.w700,
      color: tokens.text3,
      letterSpacing: 0.6,
    );
    return AlertDialog(
      title: Text(tr('fmt.customFormatter')),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CodexButton(
              onPressed: () => _editOrNew(),
              icon: const Icon(Icons.add, size: 16),
              label: Text(tr('fmt.new')),
            ),
            const SizedBox(height: 12),
            Row(children: [
              SizedBox(
                width: 140,
                child: Text(tr('fmt.name'), style: headerStyle),
              ),
              Expanded(
                child: Text(tr('fmt.formatter'), style: headerStyle),
              ),
              SizedBox(
                width: 90,
                child: Text(tr('fmt.operation'), style: headerStyle),
              ),
            ]),
            const SizedBox(height: 6),
            const CodexDivider(),
            const SizedBox(height: 6),
            CodexSurface(
              variant: CodexSurfaceVariant.sunken,
              padding: EdgeInsets.zero,
              child: _list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          tr('fmt.noData'),
                          style: Ts.style(size: Ts.md, color: tokens.text3),
                        ),
                      ),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _list.length,
                        separatorBuilder: (_, __) => const CodexDivider(),
                        itemBuilder: (ctx, i) {
                          final f = _list[i];
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
                            child: Row(children: [
                              SizedBox(
                                width: 140,
                                child: Text(
                                  f.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: Ts.style(
                                    size: Ts.md,
                                    color: tokens.text,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${f.command} ${f.params}',
                                  overflow: TextOverflow.ellipsis,
                                  style: Ts.style(
                                    size: 12.5,
                                    color: tokens.text2,
                                    monoFont: true,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 68,
                                child: Row(children: [
                                  CodexIconButton(
                                    icon: const Icon(Icons.edit, size: 16),
                                    semanticLabel: tr('fmt.edit'),
                                    onPressed: () =>
                                        _editOrNew(existing: f, index: i),
                                  ),
                                  CodexIconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 16),
                                    semanticLabel: tr('fmt.delete'),
                                    variant: CodexButtonVariant.danger,
                                    onPressed: () => _delete(i),
                                  ),
                                ]),
                              ),
                            ]),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        CodexButton(
          variant: CodexButtonVariant.primary,
          onPressed: () => Navigator.pop(context, _dirty ? _list : null),
          label: Text(tr('fmt.close')),
        ),
      ],
    );
  }
}

class _FormatterEditDialog extends StatefulWidget {
  final CustomFormatter? existing;

  /// Names that are already taken (built-ins + other customs) and must be rejected.
  final Set<String> reserved;
  const _FormatterEditDialog({this.existing, this.reserved = const {}});

  @override
  State<_FormatterEditDialog> createState() => _FormatterEditDialogState();
}

class _FormatterEditDialogState extends State<_FormatterEditDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _command =
      TextEditingController(text: widget.existing?.command ?? '');
  late final TextEditingController _params =
      TextEditingController(text: widget.existing?.params ?? '');
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _params.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final command = _command.text.trim();
    if (name.isEmpty || command.isEmpty) {
      setState(() => _err = tr('fmt.nameCommandRequired'));
      return;
    }
    if (widget.reserved.contains(name)) {
      setState(() => _err = tr('fmt.nameCollides'));
      return;
    }
    Navigator.pop(context,
        CustomFormatter(name: name, command: command, params: _params.text));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final labelStyle = Ts.style(
      size: Ts.sm,
      weight: FontWeight.w600,
      color: tokens.text2,
    );
    final monoStyle = Ts.style(
      size: Ts.md,
      color: tokens.text,
      monoFont: true,
    );
    return AlertDialog(
      title: Text(widget.existing == null ? tr('fmt.new') : tr('fmt.edit')),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('fmt.nameLabel'), style: labelStyle),
            const SizedBox(height: 5),
            CodexTextField(
              controller: _name,
              hasError: _err != null,
              // Renaming is safe: the manager replaces by index and persists the
              // whole list (nothing is keyed by name in storage).
              decoration: const InputDecoration(),
            ),
            const SizedBox(height: 14),
            Text(tr('fmt.commandLabel'), style: labelStyle),
            const SizedBox(height: 5),
            CodexTextField(
              controller: _command,
              hasError: _err != null,
              style: monoStyle,
              decoration: const InputDecoration(hintText: '/bin/bash'),
            ),
            const SizedBox(height: 14),
            Text(tr('fmt.params'), style: labelStyle),
            const SizedBox(height: 5),
            CodexTextField(
              controller: _params,
              style: monoStyle,
              decoration: const InputDecoration(
                hintText: '--value "{VALUE}"',
              ),
            ),
            const SizedBox(height: 9),
            Text(
              'Templates: {VALUE} raw value · {HEX} lowercase hex · {HEX_FILE} temp file of hex '
              '(large values) · {KEY} · {FIELD} · {SCORE} · {MEMBER}. Params are split into argv '
              'tokens and passed to the command directly (no shell).',
              style: Ts.style(size: Ts.xs, color: tokens.text3),
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(
                _err!,
                style: Ts.style(size: Ts.md, color: tokens.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        CodexButton(
          variant: CodexButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
          label: Text(tr('fmt.cancel')),
        ),
        CodexButton(
          variant: CodexButtonVariant.primary,
          onPressed: _submit,
          label: Text(tr('fmt.ok')),
        ),
      ],
    );
  }
}
