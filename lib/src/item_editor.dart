// Full-page item editor modelled on the AWS console's "Create item" / "Edit
// item" pages (Explore items → pk link / Create item): a Form|JSON view toggle,
// the JSON view with a "View DynamoDB JSON" switch (attribute-value maps vs
// simplified JSON), and a form view of attribute rows with an "Add new
// attribute" typed menu. Key attributes are locked while editing (like AWS —
// duplicate the item to change its key).
//
// Writes go through the caller-supplied onSave (which owns the redimos strong
// confirmation + PutItem), so this page stays a pure editor.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

/// AWS console attribute types offered by "Add new attribute".
const _attrTypes = [
  ('S', 'String'),
  ('N', 'Number'),
  ('B', 'Binary'),
  ('BOOL', 'Boolean'),
  ('NULL', 'Null'),
  ('M', 'Map'),
  ('L', 'List'),
  ('SS', 'String Set'),
  ('NS', 'Number Set'),
];

class _Attr {
  final TextEditingController name;
  final TextEditingController value;
  String type;
  bool boolVal = true;
  final bool isKey;
  _Attr(String n, this.type, String v, {this.isKey = false})
      : name = TextEditingController(text: n),
        value = TextEditingController(text: v);
  void dispose() {
    name.dispose();
    value.dispose();
  }
}

class ItemEditorPage extends StatefulWidget {
  final String table;
  final TableTarget target; // key schema (pk / sk names + types)
  final bool isNew; // create/duplicate vs edit
  final Map<String, dynamic> initial; // DynamoDB-JSON attribute-value map
  /// Persists the item; returns null on success or an error message.
  final Future<String?> Function(Map<String, dynamic> item) onSave;

  const ItemEditorPage({
    super.key,
    required this.table,
    required this.target,
    required this.isNew,
    required this.initial,
    required this.onSave,
  });

  @override
  State<ItemEditorPage> createState() => _ItemEditorPageState();
}

class _ItemEditorPageState extends State<ItemEditorPage> {
  bool _formView = true;
  bool _ddbJson = true; // JSON view: attribute-value maps vs simplified
  bool _saving = false;
  final _json = TextEditingController();
  final List<_Attr> _attrs = [];

  @override
  void initState() {
    super.initState();
    _attrsFromAv(widget.initial);
  }

  @override
  void dispose() {
    _json.dispose();
    for (final a in _attrs) {
      a.dispose();
    }
    super.dispose();
  }

  // ---- model conversions ----

  void _attrsFromAv(Map<String, dynamic> av) {
    for (final a in _attrs) {
      a.dispose();
    }
    _attrs.clear();
    final t = widget.target;
    // Key attributes first, always present.
    for (final k in [t.pk, if (t.sk != null) t.sk!]) {
      final v = av[k.name];
      _attrs.add(_Attr(k.name, k.type, _scalarOf(v, k.type), isKey: true));
    }
    for (final e in av.entries) {
      if (e.key == t.pk.name || e.key == t.sk?.name) continue;
      final m = e.value;
      if (m is! Map || m.isEmpty) continue;
      final type = m.keys.first.toString();
      final row = _Attr(e.key, _attrTypes.any((x) => x.$1 == type) ? type : 'S',
          _scalarOf(m, type));
      if (type == 'BOOL') row.boolVal = m['BOOL'] == true;
      _attrs.add(row);
    }
  }

  String _scalarOf(dynamic avEntry, String type) {
    if (avEntry is! Map) return '';
    final v = avEntry[type];
    switch (type) {
      case 'S':
      case 'N':
      case 'B':
        return v?.toString() ?? '';
      case 'BOOL':
      case 'NULL':
        return '';
      default: // M / L / sets — edited as the JSON of their AV content
        return v == null ? '' : jsonEncode(v);
    }
  }

  /// Builds the DynamoDB-JSON item from the form rows; throws FormatException.
  Map<String, dynamic> _avFromAttrs() {
    final out = <String, dynamic>{};
    for (final a in _attrs) {
      final name = a.name.text.trim();
      if (name.isEmpty) {
        throw FormatException(tr('item.attrMissingName'));
      }
      if (out.containsKey(name)) {
        throw FormatException('duplicate attribute "$name"');
      }
      final v = a.value.text;
      switch (a.type) {
        case 'S':
          out[name] = {'S': v};
        case 'N':
          if (num.tryParse(v.trim()) == null) {
            throw FormatException('"$name": "$v" is not a number');
          }
          out[name] = {'N': v.trim()};
        case 'B':
          out[name] = {'B': v.trim()};
        case 'BOOL':
          out[name] = {'BOOL': a.boolVal};
        case 'NULL':
          out[name] = {'NULL': true};
        default: // M / L / SS / NS — value field holds the AV content JSON
          try {
            out[name] = {a.type: jsonDecode(v)};
          } catch (e) {
            throw FormatException('"$name": invalid JSON for ${a.type}: $e');
          }
      }
    }
    return out;
  }

  // Simplified JSON (the console's non-DynamoDB view). Lossy for B / sets on
  // the way back — same caveat as the console.
  dynamic _avToSimple(dynamic v) {
    if (v is! Map) return v;
    final type = v.keys.isEmpty ? '' : v.keys.first.toString();
    final inner = v[type];
    switch (type) {
      case 'S':
      case 'B':
        return inner;
      case 'N':
        return num.tryParse(inner.toString()) ?? inner;
      case 'BOOL':
        return inner == true;
      case 'NULL':
        return null;
      case 'M':
        return (inner as Map).map((k, x) => MapEntry(k, _avToSimple(x)));
      case 'L':
        return (inner as List).map(_avToSimple).toList();
      case 'SS':
      case 'BS':
        return inner;
      case 'NS':
        return (inner as List)
            .map((x) => num.tryParse(x.toString()) ?? x)
            .toList();
      default:
        return v;
    }
  }

  dynamic _simpleToAv(dynamic v) {
    if (v == null) return {'NULL': true};
    if (v is bool) return {'BOOL': v};
    if (v is num) return {'N': '$v'};
    if (v is String) return {'S': v};
    if (v is List) return {'L': v.map(_simpleToAv).toList()};
    if (v is Map) {
      return {'M': v.map((k, x) => MapEntry(k.toString(), _simpleToAv(x)))};
    }
    return {'S': '$v'};
  }

  // ---- view switching (form <-> json <-> ddb/simple) ----

  Map<String, dynamic>? _currentAv({required bool fromForm}) {
    try {
      if (fromForm) return _avFromAttrs();
      final decoded = jsonDecode(_json.text);
      if (decoded is! Map) {
        throw FormatException(tr('item.topLevelMustBeObject'));
      }
      final m = decoded.cast<String, dynamic>();
      if (_ddbJson) return m;
      return m.map((k, v) => MapEntry(k, _simpleToAv(v)));
    } catch (e) {
      _toast('$e', error: true);
      return null;
    }
  }

  void _setJsonText(Map<String, dynamic> av) {
    final body = _ddbJson ? av : av.map((k, v) => MapEntry(k, _avToSimple(v)));
    _json.text = const JsonEncoder.withIndent('  ').convert(body);
  }

  void _switchView(bool toForm) {
    if (toForm == _formView) return;
    final av = _currentAv(fromForm: _formView);
    if (av == null) return; // parse error — stay
    setState(() {
      if (toForm) {
        _attrsFromAv(av);
      } else {
        _setJsonText(av);
      }
      _formView = toForm;
    });
  }

  void _switchDdbJson(bool on) {
    if (on == _ddbJson) return;
    final av = _currentAv(fromForm: false);
    if (av == null) return;
    setState(() {
      _ddbJson = on;
      _setJsonText(av);
    });
  }

  Future<void> _save() async {
    final av = _currentAv(fromForm: _formView);
    if (av == null) return;
    final t = widget.target;
    for (final k in [t.pk, if (t.sk != null) t.sk!]) {
      final entry = av[k.name];
      final val = entry is Map ? entry[k.type] : null;
      if (val == null || val.toString().isEmpty) {
        _toast('Key attribute "${k.name}" must have a ${k.type} value',
            error: true);
        return;
      }
    }
    setState(() => _saving = true);
    final err = await widget.onSave(av);
    if (!mounted) return;
    setState(() => _saving = false);
    if (err == null) {
      Navigator.of(context).pop(true);
    } else if (err.isNotEmpty) {
      _toast(err, error: true);
    } // '' = user cancelled the confirm — stay on the page silently
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final actionLabel =
        widget.isNew ? tr('item.createItem') : tr('item.saveChanges');
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: const ValueKey('item-editor-header'),
              height: 60,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
                child: Row(
                  children: [
                    CodexIconButton(
                      semanticLabel: tr('item.cancel'),
                      tooltip: tr('item.cancel'),
                      icon: const Icon(Icons.arrow_back, size: 17),
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.isNew
                                ? tr('item.createItem')
                                : tr('item.editItem'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Ts.style(
                              size: Ts.lg,
                              weight: FontWeight.w700,
                              color: tokens.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.table,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Ts.style(
                              size: Ts.xs,
                              color: tokens.text3,
                              monoFont: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!_formView) ...[
                      Text(
                        tr('item.viewDdbJson'),
                        style: Ts.style(size: Ts.sm, color: tokens.text2),
                      ),
                      const SizedBox(width: 6),
                      Switch(value: _ddbJson, onChanged: _switchDdbJson),
                      const SizedBox(width: 16),
                    ],
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: true,
                          label: Text(tr('item.formTab')),
                        ),
                        const ButtonSegment(value: false, label: Text('JSON')),
                      ],
                      selected: {_formView},
                      onSelectionChanged: (selection) =>
                          _switchView(selection.first),
                    ),
                  ],
                ),
              ),
            ),
            const CodexDivider(),
            Expanded(
              key: const ValueKey('item-editor-body'),
              child: _formView ? _formBody() : _jsonBody(),
            ),
            const CodexDivider(),
            SizedBox(
              key: const ValueKey('item-editor-footer'),
              height: 52,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    CodexButton(
                      semanticLabel: tr('item.cancel'),
                      variant: CodexButtonVariant.ghost,
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(false),
                      label: Text(tr('item.cancel')),
                    ),
                    const SizedBox(width: 10),
                    CodexButton(
                      key: const ValueKey('item-editor-save'),
                      semanticLabel: actionLabel,
                      variant: CodexButtonVariant.primary,
                      onPressed: _saving ? null : _save,
                      label: _saving
                          ? SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: tokens.onAccent,
                              ),
                            )
                          : Text(actionLabel),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _jsonBody() => Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) => CodexTextField(
            key: const ValueKey('item-editor-json-field'),
            controller: _json,
            maxLines: null,
            minLines: null,
            expands: true,
            height: constraints.maxHeight,
            textAlignVertical: TextAlignVertical.top,
            style: Ts.style(
              size: Ts.sm,
              color: AppTokens.of(context).text,
              monoFont: true,
            ),
          ),
        ),
      );

  Widget _formBody() {
    final tokens = AppTokens.of(context);
    return ListView(
      key: const ValueKey('item-editor-form-list'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        CodexSectionHeader(label: tr('item.attributes')),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                tr('item.attributeName'),
                style: Ts.style(size: Ts.xs, color: tokens.text3),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: Text(
                tr('item.type'),
                style: Ts.style(size: Ts.xs, color: tokens.text3),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 4,
              child: Text(
                tr('item.value'),
                style: Ts.style(size: Ts.xs, color: tokens.text3),
              ),
            ),
            const SizedBox(width: 40),
          ],
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < _attrs.length; i++) _attrRow(i),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: MenuAnchor(
            builder: (context, controller, child) => CodexButton(
              key: const ValueKey('item-editor-add-attribute'),
              semanticLabel: tr('item.addNewAttribute'),
              variant: CodexButtonVariant.secondary,
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.add, size: 16),
              label: Text(tr('item.addNewAttribute')),
            ),
            menuChildren: [
              for (final type in _attrTypes)
                MenuItemButton(
                  onPressed: () => setState(() {
                    final attr = _Attr('', type.$1, '');
                    if (type.$1 == 'M') attr.value.text = '{}';
                    if (type.$1 == 'L' || type.$1 == 'SS' || type.$1 == 'NS') {
                      attr.value.text = '[]';
                    }
                    _attrs.add(attr);
                  }),
                  child: Text(type.$2),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _attrRow(int index) {
    final attr = _attrs[index];
    final tokens = AppTokens.of(context);
    final keyLocked =
        attr.isKey && !widget.isNew; // AWS: keys immutable on edit
    return Padding(
      key: ValueKey('item-editor-attr-$index'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: CodexTextField(
              key: ValueKey('item-editor-attr-name-$index'),
              controller: attr.name,
              enabled: !attr.isKey, // key names come from the schema
              decoration: InputDecoration(
                hintText: tr('item.attributeName'),
                suffixIcon: attr.isKey
                    ? Tooltip(
                        message: attr == _attrs.first
                            ? tr('item.partitionKey')
                            : tr('item.sortKey'),
                        child: Icon(Icons.key, size: 14, color: tokens.accent),
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: CodexSelectField<String>(
              key: ObjectKey(attr),
              value: attr.type,
              items: [
                for (final type in _attrTypes)
                  DropdownMenuItem(value: type.$1, child: Text(type.$2)),
              ],
              onChanged: attr.isKey
                  ? null
                  : (value) => setState(() => attr.type = value ?? 'S'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(flex: 4, child: _valueField(attr, keyLocked, index)),
          SizedBox(
            width: 40,
            child: attr.isKey
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.centerRight,
                    child: CodexIconButton(
                      semanticLabel: tr('item.remove'),
                      tooltip: tr('item.remove'),
                      variant: CodexButtonVariant.ghost,
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(
                        () => _attrs.removeAt(index).dispose(),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _valueField(_Attr attr, bool locked, int index) {
    switch (attr.type) {
      case 'BOOL':
        return SizedBox(
          height: Dim.ctlH,
          child: Row(
            children: [
              Checkbox(
                value: attr.boolVal,
                onChanged: locked
                    ? null
                    : (value) => setState(() => attr.boolVal = value ?? false),
                visualDensity: VisualDensity.compact,
              ),
              Text(
                '${attr.boolVal}',
                style: Ts.style(
                  size: Ts.md,
                  color: AppTokens.of(context).text2,
                  monoFont: true,
                ),
              ),
            ],
          ),
        );
      case 'NULL':
        return const CodexTextField(
          enabled: false,
          decoration: InputDecoration(hintText: 'null'),
        );
      default:
        final mono = attr.type == 'N' ||
            attr.type == 'B' ||
            attr.type == 'M' ||
            attr.type == 'L' ||
            attr.type == 'SS' ||
            attr.type == 'NS';
        return CodexTextField(
          key: ValueKey('item-editor-attr-value-$index'),
          controller: attr.value,
          enabled: !locked,
          style: mono
              ? Ts.style(
                  size: Ts.sm,
                  color: AppTokens.of(context).text,
                  monoFont: true,
                  tabularNums: attr.type == 'N',
                )
              : null,
          decoration: InputDecoration(
            hintText: switch (attr.type) {
              'N' => 'Number',
              'B' => 'base64',
              'M' => '{"attr": {"S": "value"}}',
              'L' => '[{"S": "value"}]',
              'SS' => '["a", "b"]',
              'NS' => '["1", "2"]',
              _ => tr('item.value'),
            },
          ),
        );
    }
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    final tokens = AppTokens.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? tokens.danger : null,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
