// The instance Configure screen (v2.3) — extracted from main.dart's
// ConfigEditor on 2026-08-06, re-aligned to the mockup (inst-config) on
// 2026-08-06. Five numbered sections, each a bordered/shadowed card with a
// panel-2 header band (cfg-num badge + title + right hint) over a strict
// two-column field grid. On/off behaviours use the mockup's custom 34×19
// switch. The pinned bottom bar carries a dirty indicator + Revert + Delete
// (danger) + Save primary CTA.
//
// Data honesty: the parameter set is aligned with v1's configure page —
// Name; Redis (Auth/Port/AutoRestart/Engine); Redimos (Table/Version/
// AutoCreate/MultiDB); DynamoDB (Region/Endpoint/credentials + mode switch);
// Extra flags rows. Every rendered field is persisted through _collect();
// v1 carried no others, so the old mockup-only placeholders are gone.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

class ConfigEditor extends StatefulWidget {
  final RedimosConfig config;
  final Future<void> Function(RedimosConfig) onSave;
  final Future<void> Function(RedimosConfig) onDelete;
  const ConfigEditor(
      {super.key,
      required this.config,
      required this.onSave,
      required this.onDelete});
  @override
  State<ConfigEditor> createState() => ConfigEditorState();
}

// Public state type: main.dart holds a GlobalKey<ConfigEditorState> for the
// dirty-check / save / applyTableName bridges.
class ConfigEditorState extends State<ConfigEditor>
    with AutomaticKeepAliveClientMixin {
  late final TextEditingController _name;
  late final TextEditingController _port;
  late final TextEditingController _table;
  late final TextEditingController _endpoint;
  late final TextEditingController _partitionID;
  late final TextEditingController _region;
  late final TextEditingController _ak;
  late final TextEditingController _sk;
  late final TextEditingController _sessionToken;
  late final TextEditingController _pass;
  // Extra flags as add/remove rows (the v1 grammar), section 5.
  late List<FlagKV> _extraFlags;
  final List<TextEditingController> _flagVals = [];

  // Selectable redimos flags (the ones not already covered by the fields
  // above) — the same list v1 offered.
  static const List<String> _flagKeys = [
    'databases',
    'consistency',
    'max-collection-result',
    'max-command-bytes',
    'retry-max-attempts',
    'delete-batch-size',
    'circuit-breaker-threshold',
    'inst-id',
    'scan-capacity',
    'metrics-addr',
    'slowlog-capacity',
    'request-log',
  ];
  late String _version;
  late bool _multiDb;
  late bool _localDdb; // drives the endpoint/AWS mode switch (v1 segmented ctrl)
  // DynamoDB target mode: 'endpoint' = a DynamoDB-compatible URL (Local/LocalStack/
  // custom), 'aws' = real AWS via region + credentials (endpoint cleared on save).
  late String _ddbMode;
  final _tableFocus = FocusNode();

  static String _ddbModeOf(RedimosConfig c) => c.endpoint.trim().isEmpty &&
          (c.accessKeyId.isNotEmpty ||
              c.secretKey.isNotEmpty ||
              c.region.isNotEmpty)
      ? 'aws'
      : 'endpoint';

  // Applied by the table-mismatch dialog (from the parent). Both leave the form
  // dirty so the user reviews and Saves before starting.
  void applyTableName(String name) {
    setState(() {
      _table.text = name;
      _table.selection = TextSelection.collapsed(offset: name.length);
    });
    _tableFocus.requestFocus();
  }

  void applyRecommended(String? version, bool? multiDb) {
    setState(() {
      if (version != null && version.isNotEmpty) _version = version;
      if (multiDb != null) _multiDb = multiDb;
    });
  }

  late bool _autoCreate;
  late bool _autoRestart;
  late String _runMode;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _name = TextEditingController(text: c.name);
    _port = TextEditingController(text: c.port.toString());
    _table = TextEditingController(text: c.table);
    _endpoint = TextEditingController(text: c.endpoint);
    _partitionID = TextEditingController(text: c.partitionID);
    _region = TextEditingController(text: c.region);
    _ak = TextEditingController(text: c.accessKeyId);
    _sk = TextEditingController(text: c.secretKey);
    _sessionToken = TextEditingController(text: c.sessionToken);
    _pass = TextEditingController(text: c.requirepass);
    _seedFlags(c.extraFlags);
    _version = c.version;
    _multiDb = c.multiDb;
    _localDdb = _ddbModeOf(c) == 'endpoint';
    _autoCreate = c.autoCreateTable;
    _autoRestart = c.autoRestart;
    _runMode = c.runMode.isEmpty ? 'native' : c.runMode;
    _ddbMode = _ddbModeOf(c);
  }

  @override
  void dispose() {
    for (final ctl in [
      _name,
      _port,
      _table,
      _endpoint,
      _partitionID,
      _region,
      _ak,
      _sk,
      _sessionToken,
      _pass,
    ]) {
      ctl.dispose();
    }
    for (final ctl in _flagVals) {
      ctl.dispose();
    }
    _tableFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ConfigEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent reuses this editor (GlobalKey) across configs; when the
    // underlying config changes, reload the form from it.
    if (oldWidget.config.id != widget.config.id) _resetControllers();
  }

  void _resetControllers() {
    final c = widget.config;
    _name.text = c.name;
    _port.text = c.port.toString();
    _table.text = c.table;
    _endpoint.text = c.endpoint;
    _partitionID.text = c.partitionID;
    _region.text = c.region;
    _ak.text = c.accessKeyId;
    _sk.text = c.secretKey;
    _sessionToken.text = c.sessionToken;
    _pass.text = c.requirepass;
    _seedFlags(c.extraFlags);
    setState(() {
      _version = c.version;
      _multiDb = c.multiDb;
      _localDdb = _ddbModeOf(c) == 'endpoint';
      _autoCreate = c.autoCreateTable;
      _autoRestart = c.autoRestart;
      _runMode = c.runMode.isEmpty ? 'native' : c.runMode;
      _ddbMode = _ddbModeOf(c);
    });
  }

  /// Whether the form differs from the saved config.
  bool get isDirty =>
      jsonEncode(_collect().toJson()) != jsonEncode(widget.config.toJson());

  Future<void> saveNow() => widget.onSave(_collect());

  // Rebuild the flag rows (and their value controllers) from a saved config.
  void _seedFlags(List<FlagKV> flags) {
    for (final ctl in _flagVals) {
      ctl.dispose();
    }
    _flagVals.clear();
    _extraFlags = [for (final f in flags) FlagKV(key: f.key, value: f.value)];
    for (final f in _extraFlags) {
      _flagVals.add(TextEditingController(text: f.value));
    }
  }

  void _addFlag() => setState(() {
        _extraFlags.add(FlagKV());
        _flagVals.add(TextEditingController());
      });

  void _removeFlag(int i) => setState(() {
        _flagVals[i].dispose();
        _flagVals.removeAt(i);
        _extraFlags.removeAt(i);
      });

  RedimosConfig _collect() {
    final c = widget.config.copy();
    c.name = _name.text.trim();
    c.port = int.tryParse(_port.text.trim()) ?? 0;
    c.table = _table.text.trim();
    // AWS mode must clear the endpoint — a lingering URL would keep redimos
    // pointed at the local/custom endpoint instead of real AWS.
    c.endpoint = _ddbMode == 'aws' ? '' : _endpoint.text.trim();
    c.partitionID = _partitionID.text.trim();
    c.region = _region.text.trim();
    c.accessKeyId = _ak.text.trim();
    c.secretKey = _sk.text;
    c.sessionToken = _sessionToken.text;
    c.requirepass = _pass.text;
    c.version = _version;
    c.multiDb = _multiDb;
    c.autoCreateTable = _autoCreate;
    c.autoRestart = _autoRestart;
    c.runMode = _runMode;
    c.extraFlags = [
      for (var i = 0; i < _extraFlags.length; i++)
        if (_extraFlags[i].key.trim().isNotEmpty)
          FlagKV(
              key: _extraFlags[i].key.trim(), value: _flagVals[i].text.trim()),
    ];
    return c;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final t = AppTokens.of(context);
    return Column(children: [
      // Scrollable field area — the pinned action bar below never moves.
      // Mockup .config-scroll: 18px/22px padding, 16px section gap.
      Expanded(
        child: SingleChildScrollView(
          key: const ValueKey('configure-scroll'),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // ── 1 · NAME (实例标识) ───────────────────────────
            _section(t, '1', 'Name', '实例标识', [
              _field(t, _name, 'Instance name'),
            ]),

            // ── 2 · REDIS (上游连接) — v1 parameter set ────────
            _section(t, '2', 'Redis', '上游连接', [
              _field(t, _pass, 'Password', obscure: true),
              _field(t, _port, 'Port', number: true),
              _switchField(t, 'AutoRestart', _autoRestart, '自动重启',
                  '不自动重启', (v) => setState(() => _autoRestart = v)),
              _selectField<String>(
                  t,
                  'Engine mode',
                  _runMode,
                  const [
                    ('native', 'redimos-core'),
                    ('docker', 'Docker image'),
                  ],
                  (v) => setState(() => _runMode = v ?? 'native')),
            ]),

            // ── 3 · REDIMOS (代理引擎) — v1 parameter set ──────
            _section(t, '3', 'Redimos', '代理引擎', [
              _field(t, _table, 'Table',
                  focusNode: _tableFocus, placeholder: 'redimos-prod'),
              _selectField<String>(
                  t,
                  tr('home.version'),
                  _version,
                  const [
                    ('v1', 'v1'),
                    ('v2', 'v2'),
                  ],
                  (v) => setState(() => _version = v ?? 'v2')),
              _switchField(t, tr('home.autoCreate'), _autoCreate, '自动建表',
                  '手动建表', (v) => setState(() => _autoCreate = v)),
              _switchField(t, tr('home.multiDb'), _multiDb, '多 DB', '单 DB',
                  (v) => setState(() => _multiDb = v)),
            ]),

            // ── 4 · DYNAMODB (持久化后端) ────────────────────
            _section(t, '4', 'DynamoDB', '持久化后端', [
              _field(t, _region, 'Region', placeholder: 'us-east-1'),
              _field(t, _endpoint, 'Endpoint override',
                  placeholder: '留空使用 AWS 默认',
                  onChanged: (_) => setState(() {
                        // Keep the backend-mode inference live: an empty
                        // endpoint means the AWS default resolver, a filled one
                        // a local/custom DynamoDB URL.
                        _ddbMode =
                            _endpoint.text.trim().isEmpty ? 'aws' : 'endpoint';
                        _localDdb = _ddbMode == 'endpoint';
                      })),
              _switchField(
                  t,
                  'Local DDB',
                  _localDdb,
                  '使用本地',
                  '使用远端',
                  (v) => setState(() {
                        _localDdb = v;
                        _ddbMode = v ? 'endpoint' : 'aws';
                      })),
              // Persisted credentials / behaviour kept from the original form
              // (the mockup omits them but they drive the real backend auth).
              _field(t, _ak, tr('home.accessKeyId')),
              _field(t, _sk, tr('home.secretAccessKey'), obscure: true),
              _field(t, _sessionToken, tr('home.sessionToken'), obscure: true),
            ]),

            // ── 5 · EXTRA FLAGS (透传参数) — v1-style add/remove rows ──
            _section(t, '5', 'Extra flags', '透传参数', [
              for (var i = 0; i < _extraFlags.length; i++) _flagRow(t, i),
              Align(
                alignment: Alignment.centerLeft,
                child: CodexButton(
                  variant: CodexButtonVariant.secondary,
                  semanticLabel: tr('home.addFlag'),
                  onPressed: _addFlag,
                  icon: const Icon(Icons.add, size: 15),
                  label: Text(tr('home.addFlag')),
                ),
              ),
            ], onecol: true),

            const SizedBox(height: 16),
          ]),
        ),
      ),
      _actionBar(t),
    ]);
  }

  // ---- section card (mockup .cfg-section) ----

  Widget _section(
      AppTokens t, String n, String title, String hint, List<Widget> fields,
      {bool onecol = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: CodexSurface(
        key: ValueKey('configure-section-$n'),
        variant: CodexSurfaceVariant.elevated,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: t.panel2,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.accent,
                      borderRadius: BorderRadius.circular(Dim.radiusS),
                    ),
                    child: Text(
                      n,
                      style: Ts.style(
                        size: Ts.xs,
                        color: t.onAccent,
                        weight: FontWeight.w700,
                        monoFont: true,
                        tabularNums: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    title.toUpperCase(),
                    style: Ts.style(
                      size: Ts.md,
                      letterSpacing: 0.9,
                      weight: FontWeight.w700,
                      color: t.text,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ts.style(size: Ts.xs, color: t.text3),
                  ),
                ]),
              ),
            ),
            const CodexDivider(),
            Padding(
              padding: const EdgeInsets.all(14),
              child: onecol
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < fields.length; i++) ...[
                          fields[i],
                          if (i < fields.length - 1) const SizedBox(height: 12),
                        ],
                      ],
                    )
                  : _grid(t, fields),
            ),
          ],
        ),
      ),
    );
  }

  // Strict 2-col grid: pair fields into rows with a 16px column gutter, 12px
  // row gap. An odd trailing field spans the left cell only.
  Widget _grid(AppTokens t, List<Widget> fields) {
    final rows = <Widget>[];
    for (var i = 0; i < fields.length; i += 2) {
      final left = fields[i];
      final right = i + 1 < fields.length ? fields[i + 1] : null;
      rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(child: right ?? const SizedBox.shrink()),
      ]));
      if (i + 2 < fields.length) rows.add(const SizedBox(height: 12));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  // ---- field primitives (mockup .field / .f-label / .f-input) ----

  Widget _field(AppTokens t, TextEditingController c, String label,
      {bool number = false,
      bool obscure = false,
      bool textarea = false,
      String? placeholder,
      FocusNode? focusNode,
      ValueChanged<String>? onChanged}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _fLabel(t, label),
      const SizedBox(height: 5),
      CodexTextField(
        controller: c,
        focusNode: focusNode,
        obscureText: obscure,
        keyboardType: textarea
            ? TextInputType.multiline
            : (number ? TextInputType.number : null),
        maxLines: textarea ? null : 1,
        expands: textarea,
        textAlignVertical: textarea ? TextAlignVertical.top : null,
        height: textarea ? 64 : Dim.ctlH,
        style: Ts.style(
          size: Ts.md,
          color: t.text,
          monoFont: true,
          height: textarea ? 1.5 : null,
        ),
        decoration: InputDecoration(
          hintText: placeholder,
          hintStyle: Ts.style(
            size: Ts.md,
            color: t.text3,
            monoFont: true,
          ),
          contentPadding: textarea
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
              : const EdgeInsets.symmetric(horizontal: 10),
        ),
        onChanged: onChanged ?? (_) => setState(() {}),
      ),
    ]);
  }

  // One flag row: dropdown over the known keys (left), value field (right),
  // remove button at the row's end — the v1 layout in house components.
  Widget _flagRow(AppTokens t, int i) {
    final style = Ts.style(size: Ts.md, color: t.text, monoFont: true);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _fLabel(t, 'Key'),
          const SizedBox(height: 5),
          CodexSelectField<String>(
            key: ValueKey('configure-flag-key-$i'),
            value: _flagKeys.contains(_extraFlags[i].key)
                ? _extraFlags[i].key
                : null,
            style: style,
            items: [
              for (final k in _flagKeys)
                DropdownMenuItem<String>(
                  value: k,
                  child:
                      Text(k, overflow: TextOverflow.ellipsis, style: style),
                ),
            ],
            onChanged: (v) => setState(() => _extraFlags[i].key = v ?? ''),
          ),
        ]),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: _field(t, _flagVals[i], 'Value'),
      ),
      const SizedBox(width: 8),
      SizedBox(
        height: Dim.ctlH,
        child: CodexIconButton(
          key: ValueKey('configure-flag-remove-$i'),
          semanticLabel: tr('tbl.remove'),
          tooltip: tr('tbl.remove'),
          onPressed: () => _removeFlag(i),
          icon: Icon(Icons.remove_circle_outline, size: 16, color: t.danger),
        ),
      ),
    ]);
  }

  Widget _fLabel(AppTokens t, String label) => Text(label.toUpperCase(),
      style: Ts.style(
          size: Ts.xs,
          weight: FontWeight.w600,
          letterSpacing: 0.5,
          color: t.text3,
          // mockup .f-label line box is 14px (11px Inter, CSS normal
          // leading); the global half-leading stamp renders taller and pushes
          // the input row 2px low against the mockup (CP 9.x inst-config).
          height: 14 / 11));

  Widget _selectField<T>(AppTokens t, String label, T? value,
      List<(T, String)> items, ValueChanged<T?> onChanged) {
    final style = Ts.style(size: Ts.md, color: t.text, monoFont: true);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _fLabel(t, label),
      const SizedBox(height: 5),
      CodexSelectField<T>(
        value: value,
        style: style,
        items: [
          for (final (itemValue, itemLabel) in items)
            DropdownMenuItem<T>(
              value: itemValue,
              child: Text(
                itemLabel,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
        ],
        onChanged: onChanged,
      ),
    ]);
  }

  // mockup .f-inline: a custom 34×19 switch + an inline text-2 caption.
  Widget _switchField(AppTokens t, String label, bool value, String captionOn,
      String captionOff, ValueChanged<bool> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _fLabel(t, label),
      const SizedBox(height: 5),
      // Mockup .f-inline row is switch-high (19), NOT input-high: sizing it to
      // ctlH stacked +11px per switch row and pushed every card below off its
      // mockup y (pixel-fidelity-v23 CP 9.x, inst-config round 2).
      SizedBox(
        height: 19,
        child: Row(children: [
          _switch(label, value, onChanged),
          const SizedBox(width: 8),
          Flexible(
            child: Text(value ? captionOn : captionOff,
                overflow: TextOverflow.ellipsis,
                style: Ts.style(size: Ts.md, color: t.text2)),
          ),
        ]),
      ),
    ]);
  }

  // Fixed 34×19 footprint: the transition changes paint/alignment only and
  // never moves neighbouring labels or fields.
  Widget _switch(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      _ConfigureSwitch(
        key: ValueKey('configure-switch-${label.toLowerCase()}'),
        label: label,
        value: value,
        onChanged: onChanged,
      );

  // ---- pinned action bar (mockup .config-actions) ----

  Widget _actionBar(AppTokens t) {
    return Container(
      key: const ValueKey('configure-action-bar'),
      height: 52,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(top: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Row(children: [
        if (isDirty) ...[
          Semantics(
            label: tr('home.unsavedChanges'),
            child: Container(
              width: 6,
              height: 6,
              decoration:
                  BoxDecoration(color: t.warning, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 7),
          Text(
            tr('home.unsavedChanges'),
            style: Ts.style(
              size: Ts.md,
              color: t.warning,
              weight: FontWeight.w600,
            ),
          ),
        ],
        const Spacer(),
        CodexButton(
          variant: CodexButtonVariant.secondary,
          semanticLabel: tr('home.revert'),
          onPressed: () {
            final wasDirty = isDirty;
            _resetControllers();
            if (wasDirty && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(tr('home.revertedChanges'))),
              );
            }
          },
          icon: const Icon(Icons.restore, size: 15),
          label: Text(tr('home.revert')),
        ),
        const SizedBox(width: 8),
        CodexButton(
          variant: CodexButtonVariant.danger,
          semanticLabel: tr('home.delete'),
          onPressed: _confirmDelete,
          icon: const Icon(Icons.delete_outline, size: 15),
          label: Text(tr('home.delete')),
        ),
        const SizedBox(width: 8),
        CodexButton(
          variant: CodexButtonVariant.primary,
          semanticLabel: tr('home.save'),
          onPressed: () => widget.onSave(_collect()),
          icon: const Icon(Icons.save_outlined, size: 15),
          label: Text(tr('home.save')),
        ),
      ]),
    );
  }

  // Delete needs an explicit confirmation — it permanently removes the config.
  Future<void> _confirmDelete() async {
    final name = widget.config.name.isEmpty
        ? tr('home.unnamedParen')
        : widget.config.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('home.deleteConfigTitle')),
        content: Text(
            '${tr('home.permanentlyRemove')} "$name"? ${tr('home.cannotBeUndone')}'),
        actions: [
          CodexButton(
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('home.cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            label: Text(tr('home.cancel')),
          ),
          CodexButton(
            variant: CodexButtonVariant.danger,
            semanticLabel: tr('home.delete'),
            onPressed: () => Navigator.pop(ctx, true),
            label: Text(tr('home.delete')),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDelete(widget.config);
  }
}

class _ConfigureSwitch extends StatefulWidget {
  const _ConfigureSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_ConfigureSwitch> createState() => _ConfigureSwitchState();
}

class _ConfigureSwitchState extends State<_ConfigureSwitch> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final keyName = widget.label.toLowerCase();
    return Semantics(
      label: widget.label,
      toggled: widget.value,
      button: true,
      onTap: () => widget.onChanged(!widget.value),
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => widget.onChanged(!widget.value),
          onFocusChange: (next) {
            if (_focused == next) return;
            setState(() => _focused = next);
          },
          splashFactory: NoSplash.splashFactory,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: t.hover,
          focusColor: Colors.transparent,
          child: AnimatedContainer(
            key: ValueKey('configure-switch-$keyName-focus-target'),
            duration: const Duration(milliseconds: 120),
            width: 34,
            height: 19,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: widget.value ? t.accent : t.border,
              border: Border.all(
                color: _focused ? t.focus : Colors.transparent,
                width: Dim.borderW,
              ),
            ),
            child: Align(
              alignment:
                  widget.value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 15,
                height: 15,
                decoration: BoxDecoration(
                  color: widget.value ? t.onAccent : t.panel,
                  shape: BoxShape.circle,
                  border: Border.all(color: t.hairline),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
