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

import 'models.dart';

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
        throw const FormatException('an attribute is missing its name');
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
        return (inner as List).map((x) => num.tryParse(x.toString()) ?? x).toList();
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
    if (v is Map) return {'M': v.map((k, x) => MapEntry(k.toString(), _simpleToAv(x)))};
    return {'S': '$v'};
  }

  // ---- view switching (form <-> json <-> ddb/simple) ----

  Map<String, dynamic>? _currentAv({required bool fromForm}) {
    try {
      if (fromForm) return _avFromAttrs();
      final decoded = jsonDecode(_json.text);
      if (decoded is! Map) throw const FormatException('top level must be an object');
      final m = decoded.cast<String, dynamic>();
      if (_ddbJson) return m;
      return m.map((k, v) => MapEntry(k, _simpleToAv(v)));
    } catch (e) {
      _toast('$e', error: true);
      return null;
    }
  }

  void _setJsonText(Map<String, dynamic> av) {
    final body = _ddbJson
        ? av
        : av.map((k, v) => MapEntry(k, _avToSimple(v)));
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
        _toast('Key attribute "${k.name}" must have a ${k.type} value', error: true);
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(width: 4),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.isNew ? 'Create item' : 'Edit item',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                Text(widget.table,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
              const Spacer(),
              if (!_formView) ...[
                const Text('View DynamoDB JSON', style: TextStyle(fontSize: 12.5)),
                const SizedBox(width: 6),
                Switch(value: _ddbJson, onChanged: _switchDdbJson),
                const SizedBox(width: 16),
              ],
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Form')),
                  ButtonSegment(value: false, label: Text('JSON')),
                ],
                selected: {_formView},
                onSelectionChanged: (s) => _switchView(s.first),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: _formView ? _formBody() : _jsonBody()),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(widget.isNew ? 'Create item' : 'Save changes'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _jsonBody() => Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _json,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
        ),
      );

  Widget _formBody() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        Text('Attributes', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
        const SizedBox(height: 4),
        const Row(children: [
          Expanded(flex: 3, child: Text('Attribute name', style: TextStyle(fontSize: 12))),
          SizedBox(width: 10),
          Expanded(flex: 2, child: Text('Type', style: TextStyle(fontSize: 12))),
          SizedBox(width: 10),
          Expanded(flex: 4, child: Text('Value', style: TextStyle(fontSize: 12))),
          SizedBox(width: 40),
        ]),
        const SizedBox(height: 6),
        for (var i = 0; i < _attrs.length; i++) _attrRow(i),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: MenuAnchor(
            builder: (ctx, ctrl, _) => OutlinedButton.icon(
              onPressed: () => ctrl.isOpen ? ctrl.close() : ctrl.open(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add new attribute'),
            ),
            menuChildren: [
              for (final t in _attrTypes)
                MenuItemButton(
                  onPressed: () => setState(() {
                    final a = _Attr('', t.$1, '');
                    if (t.$1 == 'M') a.value.text = '{}';
                    if (t.$1 == 'L' || t.$1 == 'SS' || t.$1 == 'NS') a.value.text = '[]';
                    _attrs.add(a);
                  }),
                  child: Text(t.$2),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _attrRow(int i) {
    final a = _attrs[i];
    final scheme = Theme.of(context).colorScheme;
    final keyLocked = a.isKey && !widget.isNew; // AWS: keys immutable on edit
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          flex: 3,
          child: TextField(
            controller: a.name,
            enabled: !a.isKey, // key names come from the schema
            decoration: _dec(
              hint: 'Attribute name',
              suffix: a.isKey
                  ? Tooltip(
                      message: a == _attrs.first ? 'Partition key' : 'Sort key',
                      child: Icon(Icons.key, size: 14, color: scheme.primary))
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            initialValue: a.type,
            isDense: true,
            decoration: _dec(),
            items: [
              for (final t in _attrTypes)
                DropdownMenuItem(value: t.$1, child: Text(t.$2)),
            ],
            onChanged: a.isKey ? null : (v) => setState(() => a.type = v ?? 'S'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(flex: 4, child: _valueField(a, keyLocked)),
        SizedBox(
          width: 40,
          child: a.isKey
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() => _attrs.removeAt(i).dispose()),
                ),
        ),
      ]),
    );
  }

  Widget _valueField(_Attr a, bool locked) {
    switch (a.type) {
      case 'BOOL':
        return Row(children: [
          Checkbox(
            value: a.boolVal,
            onChanged: locked ? null : (v) => setState(() => a.boolVal = v ?? false),
            visualDensity: VisualDensity.compact,
          ),
          Text('${a.boolVal}'),
        ]);
      case 'NULL':
        return TextField(enabled: false, decoration: _dec(hint: 'null'));
      default:
        return TextField(
          controller: a.value,
          enabled: !locked,
          style: a.type == 'M' || a.type == 'L' || a.type == 'SS' || a.type == 'NS'
              ? const TextStyle(fontFamily: 'monospace', fontSize: 12.5)
              : null,
          decoration: _dec(
              hint: switch (a.type) {
            'N' => 'Number',
            'B' => 'base64',
            'M' => '{"attr": {"S": "value"}}',
            'L' => '[{"S": "value"}]',
            'SS' => '["a", "b"]',
            'NS' => '["1", "2"]',
            _ => 'Value',
          }),
        );
    }
  }

  InputDecoration _dec({String? hint, Widget? suffix}) => InputDecoration(
        isDense: true,
        hintText: hint,
        suffixIcon: suffix,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      );

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade800 : null,
      duration: const Duration(seconds: 3),
    ));
  }
}
