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
import 'ui_tokens.dart';

class ConfigEditor extends StatefulWidget {
  final RedimosConfig config;
  final Future<void> Function(RedimosConfig) onSave;
  final Future<void> Function(RedimosConfig) onDelete;
  const ConfigEditor(
      {super.key, required this.config, required this.onSave, required this.onDelete});
  @override
  State<ConfigEditor> createState() => ConfigEditorState();
}

// Public state type: main.dart holds a GlobalKey<ConfigEditorState> for the
// dirty-check / save / applyTableName bridges.
class ConfigEditorState extends State<ConfigEditor> {
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

  static String _ddbModeOf(RedimosConfig c) =>
      c.endpoint.trim().isEmpty &&
              (c.accessKeyId.isNotEmpty || c.secretKey.isNotEmpty || c.region.isNotEmpty)
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
      _name, _port, _table, _endpoint, _partitionID, _region, _ak, _sk,
      _sessionToken, _pass, _group, _host, _database, _cacheTtl, _flagsText,
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
    final t = AppTokens.of(context);
    final brightness = Theme.of(context).brightness;
    return Column(children: [
      // Scrollable field area — the pinned action bar below never moves.
      // Mockup .config-scroll: 18px/22px padding, 16px section gap.
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // ── 1 · NAME (实例标识) ───────────────────────────
            _section(t, brightness, '1', 'Name', '实例标识', [
              _field(t, _name, 'Instance name'),
              _field(t, _group, 'Group', placeholder: 'production'),
            ]),

            // ── 2 · REDIS (上游连接) ──────────────────────────
            _section(t, brightness, '2', 'Redis', '上游连接', [
              _field(t, _host, 'Host', placeholder: '127.0.0.1'),
              _field(t, _port, 'Port', number: true),
              _field(t, _pass, 'Password', obscure: true),
              _field(t, _database, 'Database', number: true, placeholder: '0'),
              _switchField(t, 'TLS', _tls, '启用 TLS', '不启用明文连接',
                  (v) => setState(() => _tls = v)),
              _switchField(t, 'Read-only replica', _readOnlyReplica, '只读副本', '可写',
                  (v) => setState(() => _readOnlyReplica = v)),
            ]),

            // ── 3 · REDIMOS (代理引擎) ───────────────────────
            // NOTE: mockup's "Proxy port" is the same persisted listen port as
            // section 2's Port, so it is NOT duplicated here (a second field on
            // the same controller would mirror the value and break clearing).
            _section(t, brightness, '3', 'Redimos', '代理引擎', [
              _selectField<String>(t, 'Engine mode', _runMode, const [
                ('native', 'redimos-core'),
                ('docker', 'Docker image'),
              ], (v) => setState(() => _runMode = v ?? 'native')),
              _field(t, _cacheTtl, 'Cache TTL (s)', number: true, placeholder: '300'),
              _switchField(t, 'Write-through', _writeThrough, '写入同步回源', '直写后端',
                  (v) => setState(() => _writeThrough = v)),
            ]),

            // ── 4 · DYNAMODB (持久化后端) ────────────────────
            _section(t, brightness, '4', 'DynamoDB', '持久化后端', [
              _field(t, _region, 'Region', placeholder: 'us-east-1'),
              _field(t, _table, 'Table', focusNode: _tableFocus, placeholder: 'redimos-prod'),
              _field(t, _endpoint, 'Endpoint override', placeholder: '留空使用 AWS 默认',
                  onChanged: (_) => setState(() {
                        // Keep the backend-mode inference live: an empty
                        // endpoint means the AWS default resolver, a filled one
                        // a local/custom DynamoDB URL.
                        _ddbMode = _endpoint.text.trim().isEmpty ? 'aws' : 'endpoint';
                        _localDdb = _ddbMode == 'endpoint';
                      })),
              _switchField(t, 'Local DDB', _localDdb, '使用本地', '使用远端',
                  (v) => setState(() {
                        _localDdb = v;
                        _ddbMode = v ? 'endpoint' : 'aws';
                      })),
              // Persisted credentials / behaviour kept from the original form
              // (the mockup omits them but they drive the real backend auth).
              _field(t, _ak, tr('home.accessKeyId')),
              _field(t, _sk, tr('home.secretAccessKey'), obscure: true),
              _field(t, _sessionToken, tr('home.sessionToken'), obscure: true),
              _selectField<String>(t, tr('home.version'), _version, const [
                ('v1', 'v1'),
                ('v2', 'v2'),
              ], (v) => setState(() => _version = v ?? 'v2')),
              _switchField(t, tr('home.autoCreate'), _autoCreate, '自动建表', '手动建表',
                  (v) => setState(() => _autoCreate = v)),
              _switchField(t, tr('home.multiDb'), _multiDb, '多 DB', '单 DB',
                  (v) => setState(() => _multiDb = v)),
            ]),

            // ── 5 · EXTRA FLAGS (透传参数) — one-column textarea ──
            _section(t, brightness, '5', 'Extra flags', '透传参数', [
              _field(t, _flagsText, 'Arguments', textarea: true,
                  placeholder: '--max-clients 256\n--latency-trace off'),
            ], onecol: true),

            const SizedBox(height: 16),
          ]),
        ),
      ),
      _actionBar(t),
    ]);
  }

  // ---- section card (mockup .cfg-section) ----

  Widget _section(AppTokens t, Brightness brightness, String n, String title,
      String hint, List<Widget> fields,
      {bool onecol = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Stack(children: [
        Container(
          decoration: BoxDecoration(
            color: t.panel,
            borderRadius: BorderRadius.circular(Dim.radiusM),
            border: Border.all(color: t.border),
            boxShadow: Depth.elev2(brightness),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Dim.radiusM - 1),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // .cfg-head band: panel-2 + hairline bottom border + soft highlight.
              Container(
                decoration: BoxDecoration(
                  color: t.panel2,
                  border: Border(bottom: BorderSide(color: t.hairline)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  // .cfg-num: 20px solid accent chip, white 11px mono numeral
                  // (dark theme flips to white fill + near-black text).
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: brightness == Brightness.dark
                          ? const Color(0xFFF5F7FB)
                          : t.accent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(n,
                        style: Ts.style(
                            size: 11,
                            color: brightness == Brightness.dark
                                ? const Color(0xFF10142E)
                                : t.onAccent,
                            weight: FontWeight.w700,
                            monoFont: true)),
                  ),
                  const SizedBox(width: 10),
                  // .cfg-title: 12px/700, .9px tracking.
                  Text(title.toUpperCase(),
                      style: Ts.style(
                          size: Ts.md, letterSpacing: 0.9, weight: FontWeight.w700, color: t.text)),
                  const Spacer(),
                  // .cfg-hint: right-aligned 11px caption.
                  Text(hint, style: Ts.style(size: Ts.xs, color: t.text3)),
                ]),
              ),
              // .cfg-body: 2-col grid, 12px row / 16px col gap, 14px padding.
              Padding(
                padding: const EdgeInsets.all(14),
                child: onecol
                    ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (var i = 0; i < fields.length; i++) ...[
                          fields[i],
                          if (i < fields.length - 1) const SizedBox(height: 12),
                        ],
                      ])
                    : _grid(t, fields),
              ),
            ]),
          ),
        ),
        // 1px top inner highlight.
        Positioned(
          left: 1, right: 1, top: 0,
          child: IgnorePointer(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                color: t.highlight,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(Dim.radiusM - 1)),
              ),
            ),
          ),
        ),
      ]),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
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
      const SizedBox(height: 5), // mockup .field gap
      SizedBox(
        height: textarea ? 64 : Dim.ctlH, // ctl-h = 30
        child: TextField(
          controller: c,
          focusNode: focusNode,
          obscureText: obscure,
          keyboardType: textarea
              ? TextInputType.multiline
              : (number ? TextInputType.number : null),
          maxLines: textarea ? null : 1,
          expands: textarea,
          textAlignVertical: textarea ? TextAlignVertical.top : null,
          // mockup .f-input: mono 12px everywhere.
          style: Ts.style(size: Ts.md, color: t.text, monoFont: true, height: textarea ? 1.5 : null),
          decoration: _inputDeco(t, placeholder: placeholder, textarea: textarea),
          onChanged: onChanged ?? (_) => setState(() {}), // refresh dirty live
        ),
      ),
    ]);
  }

  InputDecoration _inputDeco(AppTokens t, {String? placeholder, bool textarea = false}) {
    OutlineInputBorder border(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(Dim.radiusS),
          borderSide: BorderSide(color: c),
        );
    return InputDecoration(
      isDense: true,
      hintText: placeholder,
      hintStyle: Ts.style(size: Ts.md, color: t.text3, monoFont: true),
      filled: true,
      fillColor: t.panel,
      border: border(t.border),
      enabledBorder: border(t.border),
      // mockup .f-input:focus: accent ring + soft glow.
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Dim.radiusS),
        borderSide: BorderSide(color: t.focus, width: 1.5),
      ),
      contentPadding: textarea
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
          // vertical 6: the outline container sizes to text+padding (isDense),
          // so 18px text + 6+6 fills the 30px ctl-h box — the mockup's
          // .f-input is a full-height 30px box.
          : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    );
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

  // f-select: a boxed dropdown styled like a field input (mono 12px).
  Widget _selectField<T>(AppTokens t, String label, T? value,
      List<(T, String)> items, ValueChanged<T?> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _fLabel(t, label),
      const SizedBox(height: 5),
      SizedBox(
        height: Dim.ctlH,
        child: DropdownButtonFormField<T>(
          initialValue: value,
          isDense: true,
          style: Ts.style(size: Ts.md, color: t.text, monoFont: true),
          decoration: _inputDeco(t),
          // Explicit style on the item text: the inherited chain renders the
          // blocky fallback face in widget tests (same disease as the R3
          // styleFrom buttons — convergence-plan R3).
          items: [
            for (final (v, l) in items)
              DropdownMenuItem(
                  value: v,
                  child: Text(l,
                      overflow: TextOverflow.ellipsis,
                      style: Ts.style(size: Ts.md, color: t.text, monoFont: true)))
          ],
          onChanged: onChanged,
        ),
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
          _switch(t, value, onChanged),
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

  // mockup .switch: 34×19 pill, white knob, inset track shadow; off = border
  // grey with the knob on the left, on = accent with the knob on the right.
  Widget _switch(AppTokens t, bool value, ValueChanged<bool> onChanged) {
    final brightness = Theme.of(context).brightness;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 34,
        height: 19,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: value ? t.accent : t.border,
          boxShadow: [
            BoxShadow(
              color: (brightness == Brightness.dark ? Colors.black : const Color(0xFF173369))
                  .withValues(alpha: 0.25),
              offset: const Offset(0, 1),
              blurRadius: 2,
            ),
          ],
        ),
        child: Align(
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 15,
            height: 15,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }

  // ---- pinned action bar (mockup .config-actions) ----

  Widget _actionBar(AppTokens t) {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(top: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Row(children: [
        if (isDirty) ...[
          // .dirty-dot: 6px warning dot + note.
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: t.warning, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(tr('home.unsavedChanges'),
              style: Ts.style(size: Ts.md, color: t.warning, weight: FontWeight.w600)),
        ],
        const Spacer(),
        // .abtn Revert (neutral, text-only, 26px).
        _abtn(t, label: tr('home.revert'), onTap: () {
          final wasDirty = isDirty;
          _resetControllers();
          if (wasDirty && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(tr('home.revertedChanges'))),
            );
          }
        }),
        const SizedBox(width: 8),
        // .abtn.danger: ⌫ Delete instance.
        _abtn(t,
            label: '⌫ ${tr('home.delete')}',
            danger: true,
            onTap: _confirmDelete),
        const SizedBox(width: 8),
        _saveButton(t),
      ]),
    );
  }

  // mockup .abtn: a small 26px text button; .danger = danger text + 35% border.
  Widget _abtn(AppTokens t,
      {required String label, required VoidCallback onTap, bool danger = false}) {
    final color = danger ? t.danger : t.text2;
    return InkWell(
      borderRadius: BorderRadius.circular(Dim.radiusS),
      onTap: onTap,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Dim.radiusS),
          border: Border.all(
              color: danger ? t.danger.withValues(alpha: 0.35) : t.border),
        ),
        child: Text(label,
            style: Ts.style(size: Ts.md, weight: FontWeight.w600, color: color)),
      ),
    );
  }

  // v2.3 primary CTA (.pbtn): 32px, accent fill + white text, inset highlight
  // + drop shadow; dark theme flips to a white fill + near-black text.
  Widget _saveButton(AppTokens t) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFFF5F7FB) : t.accent;
    final fg = dark ? const Color(0xFF10142E) : t.onAccent;
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Dim.radiusS),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF173369).withValues(alpha: dark ? 0.5 : 0.22),
            offset: const Offset(0, 1),
            blurRadius: 2,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(Dim.radiusS),
          onTap: () => widget.onSave(_collect()),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.save, size: 15, color: fg),
              const SizedBox(width: 6),
              Text(tr('home.save'),
                  style: Ts.style(size: Ts.md, weight: FontWeight.w600, color: fg)),
            ]),
          ),
        ),
      ),
    );
  }

  // Delete needs an explicit confirmation — it permanently removes the config.
  Future<void> _confirmDelete() async {
    final name = widget.config.name.isEmpty ? tr('home.unnamedParen') : widget.config.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('home.deleteConfigTitle')),
        content: Text('${tr('home.permanentlyRemove')} "$name"? ${tr('home.cannotBeUndone')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('home.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('home.delete')),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDelete(widget.config);
  }
}
