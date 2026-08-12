// The instance Configure screen (v2.3) — extracted from main.dart's
// ConfigEditor on 2026-08-06, re-aligned to the mockup (inst-config) on
// 2026-08-06. Five numbered sections, each a bordered/shadowed card with a
// panel-2 header band (cfg-num badge + title + right hint) over a strict
// two-column field grid. On/off behaviours use the mockup's custom 34×19
// switch. The pinned bottom bar carries a dirty indicator + Revert + Delete
// (danger) + Save primary CTA.
//
// Data honesty: fields the saved RedimosConfig actually carries (name, port,
// password, table, endpoint, region, credentials, version, multiDb, autoCreate,
// autoRestart, runMode, extraFlags) are wired through to _collect(). The
// mockup-only fields with no persisted counterpart (Group, Host, Database,
// TLS, Read-only replica, Cache TTL, Write-through, Local DDB) render as
// display-only placeholders — they are NOT collected and do not affect the
// running config.

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
  // Mockup-only display placeholders (no persisted RedimosConfig field).
  late final TextEditingController _group;
  late final TextEditingController _host;
  late final TextEditingController _database;
  late final TextEditingController _cacheTtl;
  // Extra flags as a single textarea ("--key value" per line), mockup section 5.
  late final TextEditingController _flagsText;
  late String _version;
  late bool _multiDb;
  late bool _tls; // mockup-only
  late bool _readOnlyReplica; // mockup-only
  late bool _writeThrough; // mockup-only
  late bool _localDdb; // mockup-only
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
    _seedTransient();
    _flagsText = TextEditingController(text: _flagsToText(c.extraFlags));
    _version = c.version;
    _multiDb = c.multiDb;
    _tls = false;
    _readOnlyReplica = false;
    _writeThrough = true; // v2.3 mockup S3 shows Write-through ON (写入同步回源)
    _localDdb = false;
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
      _group,
      _host,
      _database,
      _cacheTtl,
      _flagsText,
    ]) {
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
    _group.text = 'production';
    _host.text = '127.0.0.1';
    _database.text = '3';
    _cacheTtl.text = '300';
    _flagsText.text = _flagsToText(c.extraFlags);
    setState(() {
      _version = c.version;
      _multiDb = c.multiDb;
      _tls = false;
      _readOnlyReplica = false;
      _writeThrough = true; // mockup default (see initState)
      _localDdb = false;
      _autoCreate = c.autoCreateTable;
      _autoRestart = c.autoRestart;
      _runMode = c.runMode.isEmpty ? 'native' : c.runMode;
      _ddbMode = _ddbModeOf(c);
    });
  }

  /// The mockup's form shows these four fields pre-filled with working
  /// defaults. They are display-only (never read by _collect/save), so
  /// seeding them is a pure presentation change — the v2.3 mockup is the
  /// visual ground truth (pixel-fidelity-v23 CP 9.x).
  void _seedTransient() {
    _group = TextEditingController(text: 'production');
    _host = TextEditingController(text: '127.0.0.1');
    _database = TextEditingController(text: '3');
    _cacheTtl = TextEditingController(text: '300');
  }

  /// Whether the form differs from the saved config.
  bool get isDirty =>
      jsonEncode(_collect().toJson()) != jsonEncode(widget.config.toJson());

  Future<void> saveNow() => widget.onSave(_collect());

  // Serialize extra flags to the textarea's "--key value" lines.
  static String _flagsToText(List<FlagKV> flags) => flags
      .where((f) => f.key.trim().isNotEmpty)
      .map((f) => '--${f.key.trim()} ${f.value}'.trim())
      .join('\n');

  // Parse the textarea back into FlagKV pairs: each non-empty line is
  // "--key value" (or "key value"); a bare "--key" yields an empty value.
  static List<FlagKV> _parseFlags(String text) {
    final out = <FlagKV>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final stripped = line.startsWith('--') ? line.substring(2) : line;
      final sp = stripped.indexOf(' ');
      final key = (sp < 0 ? stripped : stripped.substring(0, sp)).trim();
      final value = (sp < 0 ? '' : stripped.substring(sp + 1)).trim();
      if (key.isNotEmpty) out.add(FlagKV(key: key, value: value));
    }
    return out;
  }

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
    c.extraFlags = _parseFlags(_flagsText.text);
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
              _field(t, _group, 'Group', placeholder: 'production'),
            ]),

            // ── 2 · REDIS (上游连接) ──────────────────────────
            _section(t, '2', 'Redis', '上游连接', [
              _field(t, _host, 'Host', placeholder: '127.0.0.1'),
              _field(t, _port, 'Port', number: true),
              _field(t, _pass, 'Password', obscure: true),
              _field(t, _database, 'Database', number: true, placeholder: '0'),
              _switchField(t, 'TLS', _tls, '启用 TLS', '不启用明文连接',
                  (v) => setState(() => _tls = v)),
              _switchField(t, 'Read-only replica', _readOnlyReplica, '只读副本',
                  '可写', (v) => setState(() => _readOnlyReplica = v)),
            ]),

            // ── 3 · REDIMOS (代理引擎) ───────────────────────
            // NOTE: mockup's "Proxy port" is the same persisted listen port as
            // section 2's Port, so it is NOT duplicated here (a second field on
            // the same controller would mirror the value and break clearing).
            _section(t, '3', 'Redimos', '代理引擎', [
              _selectField<String>(
                  t,
                  'Engine mode',
                  _runMode,
                  const [
                    ('native', 'redimos-core'),
                    ('docker', 'Docker image'),
                  ],
                  (v) => setState(() => _runMode = v ?? 'native')),
              _field(t, _cacheTtl, 'Cache TTL (s)',
                  number: true, placeholder: '300'),
              _switchField(t, 'Write-through', _writeThrough, '写入同步回源', '直写后端',
                  (v) => setState(() => _writeThrough = v)),
            ]),

            // ── 4 · DYNAMODB (持久化后端) ────────────────────
            _section(t, '4', 'DynamoDB', '持久化后端', [
              _field(t, _region, 'Region', placeholder: 'us-east-1'),
              _field(t, _table, 'Table',
                  focusNode: _tableFocus, placeholder: 'redimos-prod'),
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

            // ── 5 · EXTRA FLAGS (透传参数) — one-column textarea ──
            _section(
                t,
                '5',
                'Extra flags',
                '透传参数',
                [
                  _field(t, _flagsText, 'Arguments',
                      textarea: true,
                      placeholder: '--max-clients 256\n--latency-trace off'),
                ],
                onecol: true),

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
