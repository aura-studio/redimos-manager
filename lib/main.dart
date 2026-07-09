import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'src/models.dart';
import 'src/native.dart';

void main() {
  runApp(const RedimosManagerApp());
}

class RedimosManagerApp extends StatelessWidget {
  const RedimosManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Redimos Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF3B6EA5),
        brightness: Brightness.dark,
        fontFamily: 'monospace',
      ),
      home: const HomePage(),
    );
  }
}

/// The app mark: a steel-blue squircle with a white hexagon (a nod to the
/// DynamoDB store) crossed by a horizontal "wire" (the RESP/db0 proxy layer),
/// capped with a green live-dot — the running-instance colour used throughout.
class RedimosLogo extends StatelessWidget {
  const RedimosLogo({super.key, this.size = 30});
  final double size;
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: const CustomPaint(painter: _LogoPainter()));
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.shortestSide / 256.0);
    const rect = Rect.fromLTWH(8, 8, 240, 240);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(60)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF5A93D4), Color(0xFF2C5B91)],
        ).createShader(rect),
    );
    final hex = Path();
    for (var i = 0; i < 6; i++) {
      final a = (-90 + 60 * i) * math.pi / 180;
      final x = 128 + 80 * math.cos(a);
      final y = 128 + 80 * math.sin(a);
      i == 0 ? hex.moveTo(x, y) : hex.lineTo(x, y);
    }
    hex.close();
    canvas.drawPath(hex, Paint()..color = Colors.white);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(66, 116, 124, 24), const Radius.circular(12)),
      Paint()..color = const Color(0xFF3A6AA6),
    );
    canvas.drawCircle(const Offset(176, 128), 12, Paint()..color = const Color(0xFF46D38A));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  NativeCore? _core;
  String? _loadError;

  List<RedimosConfig> _configs = [];
  Settings _settings = Settings();
  Map<String, InstanceStatus> _status = {};
  String? _selectedId;
  Timer? _poll;
  bool _logsExpanded = false;

  @override
  void initState() {
    super.initState();
    try {
      _core = NativeCore();
      _reload();
      _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _refresh());
    } catch (e) {
      _loadError = '$e';
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _reload() {
    final data = _core!.load();
    setState(() {
      _configs = data.configs;
      _settings = data.settings;
      _selectedId ??= _configs.isNotEmpty ? _configs.first.id : null;
    });
    _refresh();
  }

  void _refresh() {
    if (_core == null) return;
    setState(() => _status = _core!.status());
  }

  RedimosConfig? get _selected {
    for (final c in _configs) {
      if (c.id == _selectedId) return c;
    }
    return null;
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade800 : null,
      duration: const Duration(seconds: 3),
    ));
  }

  void _newConfig() {
    final c = RedimosConfig(name: 'new-config', port: _nextFreePort());
    setState(() {
      _configs = [..._configs, c];
      _selectedId = c.id; // empty id => unsaved; editor saves it
      // give the unsaved one a temporary marker id so it's selectable
    });
    // assign a temp local id so selection works before first save
    if (c.id.isEmpty) {
      c.id = 'unsaved-${DateTime.now().microsecondsSinceEpoch}';
      _selectedId = c.id;
      setState(() {});
    }
  }

  int _nextFreePort() {
    final used = _configs.map((c) => c.port).toSet();
    var p = 6379;
    while (used.contains(p)) {
      p++;
    }
    return p;
  }

  Future<void> _save(RedimosConfig edited) async {
    try {
      final toSave = edited.copy();
      if (toSave.id.startsWith('unsaved-')) toSave.id = '';
      final id = _core!.saveConfig(toSave);
      _selectedId = id;
      _reload();
      _toast('Saved "${edited.name}"');
    } catch (e) {
      _toast('Save failed: $e', error: true);
    }
  }

  Future<void> _delete(RedimosConfig c) async {
    if (c.id.startsWith('unsaved-')) {
      setState(() {
        _configs.removeWhere((x) => x.id == c.id);
        _selectedId = _configs.isNotEmpty ? _configs.first.id : null;
      });
      return;
    }
    try {
      _core!.deleteConfig(c.id);
      _selectedId = null;
      _reload();
      _toast('Deleted "${c.name}"');
    } catch (e) {
      _toast('Delete failed: $e', error: true);
    }
  }

  void _startStop(RedimosConfig c) {
    if (c.id.startsWith('unsaved-')) {
      _toast('Save the config before starting it', error: true);
      return;
    }
    // "active" = running OR in a supervisor restart backoff — either way the
    // button stops it (Stop also cancels a pending auto-restart).
    final s = _status[c.id]?.status;
    final active = s == 'running' || s == 'restarting';
    try {
      if (active) {
        _core!.stop(c.id);
      } else {
        setState(() {
          _selectedId = c.id;
          _logsExpanded = true;
        });
        _core!.start(c.id);
      }
      _refresh();
    } catch (e) {
      _toast('${active ? "Stop" : "Start"} failed: $e', error: true);
    }
  }

  Future<void> _openSettings() async {
    final updated = await showDialog<Settings>(
      context: context,
      builder: (_) => _SettingsDialog(settings: _settings),
    );
    if (updated != null) {
      try {
        _core!.setSettings(updated);
        _reload();
        _toast('Settings saved');
      } catch (e) {
        _toast('Settings failed: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) return _errorScaffold();
    return Scaffold(
      appBar: AppBar(
        title: const Row(mainAxisSize: MainAxisSize.min, children: [
          RedimosLogo(size: 26),
          SizedBox(width: 11),
          Text('Redimos Manager'),
        ]),
        actions: [
          IconButton(
            tooltip: 'Stop all',
            icon: const Icon(Icons.stop_circle_outlined),
            onPressed: () {
              _core?.stopAll();
              _refresh();
            },
          ),
          IconButton(
            tooltip: 'Binary paths (Settings)',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 320, child: _configList()),
          const VerticalDivider(width: 1),
          Expanded(child: _detail()),
        ],
      ),
    );
  }

  Widget _errorScaffold() => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 16),
              const Text('Could not load the native core (redimos_core.dll).'),
              const SizedBox(height: 8),
              SelectableText('$_loadError',
                  style: const TextStyle(color: Colors.orangeAccent)),
              const SizedBox(height: 16),
              const Text(
                'Build it with scripts/build_native.ps1 and place the library '
                'next to the app executable, or set REDIMOS_CORE_LIB.',
                textAlign: TextAlign.center,
              ),
            ]),
          ),
        ),
      );

  Widget _configList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: FilledButton.icon(
            onPressed: _newConfig,
            icon: const Icon(Icons.add),
            label: const Text('New config'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _configs.isEmpty
              ? const Center(child: Text('No configs yet'))
              : ListView.builder(
                  itemCount: _configs.length,
                  itemBuilder: (_, i) => _configTile(_configs[i]),
                ),
        ),
      ],
    );
  }

  Widget _configTile(RedimosConfig c) {
    final st = _status[c.id];
    final running = st?.isRunning ?? false;
    final active = running || st?.status == 'restarting';
    return Material(
      color: c.id == _selectedId
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
          : Colors.transparent,
      child: ListTile(
        dense: true,
        leading: _statusDot(st?.status ?? 'stopped'),
        title: Text(c.name.isEmpty ? '(unnamed)' : c.name,
            overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${c.version} · :${c.port}'
          '${running ? " · pid ${st!.pid}" : ""}'
          '${st?.status == "restarting" ? " · restarting…" : ""}'
          '${(st?.restarts ?? 0) > 0 ? " · ↻${st!.restarts}" : ""}',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: IconButton(
          tooltip: active ? 'Stop' : 'Start',
          icon: Icon(active ? Icons.stop : Icons.play_arrow,
              color: active ? Colors.redAccent : Colors.greenAccent),
          onPressed: () => _startStop(c),
        ),
        onTap: () => setState(() => _selectedId = c.id),
      ),
    );
  }

  Widget _statusDot(String status) {
    final color = switch (status) {
      'running' => Colors.greenAccent,
      'restarting' => Colors.amberAccent,
      'error' => Colors.redAccent,
      'failed' => Colors.redAccent,
      'exited' => Colors.orangeAccent,
      _ => Colors.grey,
    };
    return Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }

  Widget _detail() {
    final c = _selected;
    if (c == null) {
      return const Center(child: Text('Select or create a config'));
    }
    final logsConfigId = c.id.startsWith('unsaved-') ? null : c.id;
    // This embedder mis-distributes vertical flex (Expanded) and even fixed
    // heights when maximized, but lays out *natural* heights correctly. So the
    // editor and the logs pane live together in one scroll view, each sized to
    // its content; the logs pane expands/collapses by showing/hiding its body.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConfigEditor(
            key: ValueKey(c.id),
            config: c,
            onSave: _save,
            onDelete: _delete,
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 8),
          LogsView(
            core: _core!,
            configId: logsConfigId,
            status: _status[c.id],
            expanded: _logsExpanded,
            onToggle: () => setState(() => _logsExpanded = !_logsExpanded),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Config editor
// ---------------------------------------------------------------------------

class ConfigEditor extends StatefulWidget {
  final RedimosConfig config;
  final Future<void> Function(RedimosConfig) onSave;
  final Future<void> Function(RedimosConfig) onDelete;
  const ConfigEditor(
      {super.key, required this.config, required this.onSave, required this.onDelete});
  @override
  State<ConfigEditor> createState() => _ConfigEditorState();
}

class _ConfigEditorState extends State<ConfigEditor> {
  late final TextEditingController _name;
  late final TextEditingController _port;
  late final TextEditingController _table;
  late final TextEditingController _endpoint;
  late final TextEditingController _partitionID;
  late final TextEditingController _region;
  late final TextEditingController _ak;
  late final TextEditingController _sk;
  late final TextEditingController _sessionToken;
  late final TextEditingController _source;
  late final TextEditingController _pass;
  late String _version;
  late bool _multiDb;
  late bool _autoCreate;
  late bool _autoRestart;
  late List<FlagKV> _extraFlags;
  final List<TextEditingController> _flagVals = [];

  // Selectable redimos flags (the ones not already covered by the fields above).
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
    _source = TextEditingController(text: c.source);
    _pass = TextEditingController(text: c.requirepass);
    _version = c.version;
    _multiDb = c.multiDb;
    _autoCreate = c.autoCreateTable;
    _autoRestart = c.autoRestart;
    _extraFlags = c.extraFlags.map((f) => FlagKV(key: f.key, value: f.value)).toList();
    for (final f in _extraFlags) {
      _flagVals.add(TextEditingController(text: f.value));
    }
  }

  @override
  void dispose() {
    for (final ctl in [_name, _port, _table, _endpoint, _partitionID, _region, _ak, _sk, _sessionToken, _source, _pass]) {
      ctl.dispose();
    }
    for (final ctl in _flagVals) {
      ctl.dispose();
    }
    super.dispose();
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
    c.endpoint = _endpoint.text.trim();
    c.partitionID = _partitionID.text.trim();
    c.region = _region.text.trim();
    c.accessKeyId = _ak.text.trim();
    c.secretKey = _sk.text;
    c.sessionToken = _sessionToken.text;
    c.source = _source.text.trim();
    c.requirepass = _pass.text;
    c.version = _version;
    c.multiDb = _multiDb;
    c.autoCreateTable = _autoCreate;
    c.autoRestart = _autoRestart;
    c.extraFlags = [
      for (var i = 0; i < _extraFlags.length; i++)
        if (_extraFlags[i].key.trim().isNotEmpty)
          FlagKV(key: _extraFlags[i].key.trim(), value: _flagVals[i].text.trim()),
    ];
    return c;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth.isFinite ? cons.maxWidth : 880.0;
      final cw = w.clamp(300.0, 900.0).toDouble();
      final half = ((cw - 12) / 2).toDouble();
      final redisAuthW = (cw - 264).clamp(140.0, 900.0).toDouble();
      final redimosTableW = (cw - 396).clamp(140.0, 620.0).toDouble();
      final urlW = (cw - 364).clamp(140.0, 620.0).toDouble();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 1 · Name ─────────────────────────────────────────
          _sectionHead('1', 'Name', cw),
          SizedBox(width: cw, child: _field(_name, 'Name')),

          // ── 2 · Redis (the RESP endpoint this proxy exposes) ──
          _sectionHead('2', 'Redis', cw),
          Row(children: [
            SizedBox(width: redisAuthW, child: _field(_pass, 'Auth', obscure: true)),
            const SizedBox(width: 12),
            SizedBox(width: 100, child: _field(_port, 'Port', number: true)),
            const SizedBox(width: 12),
            SizedBox(
              width: 140,
              child: DropdownButtonFormField<bool>(
                initialValue: _autoRestart,
                isDense: true,
                decoration: _dd('Auto-restart'),
                items: const [
                  DropdownMenuItem(value: true, child: Text('On')),
                  DropdownMenuItem(value: false, child: Text('Off')),
                ],
                onChanged: (v) => setState(() => _autoRestart = v ?? true),
              ),
            ),
          ]),

          // ── 3 · Redimos (proxy line + behaviour + backing table) ──
          _sectionHead('3', 'Redimos', cw),
          Row(children: [
            SizedBox(width: redimosTableW, child: _field(_table, 'Table')),
            const SizedBox(width: 12),
            SizedBox(
              width: 130,
              child: DropdownButtonFormField<bool>(
                initialValue: _autoCreate,
                isDense: true,
                decoration: _dd('Auto Create'),
                items: const [
                  DropdownMenuItem(value: true, child: Text('On')),
                  DropdownMenuItem(value: false, child: Text('Off')),
                ],
                onChanged: (v) => setState(() => _autoCreate = v ?? false),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: DropdownButtonFormField<String>(
                initialValue: _version,
                isDense: true,
                decoration: _dd('Version'),
                items: const [
                  DropdownMenuItem(value: 'v1', child: Text('v1')),
                  DropdownMenuItem(value: 'v2', child: Text('v2')),
                ],
                onChanged: (v) => setState(() => _version = v ?? 'v2'),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              child: DropdownButtonFormField<bool>(
                initialValue: _multiDb,
                isDense: true,
                decoration: _dd('Multi DB'),
                items: const [
                  DropdownMenuItem(value: true, child: Text('On')),
                  DropdownMenuItem(value: false, child: Text('Off')),
                ],
                onChanged: (v) => setState(() => _multiDb = v ?? false),
              ),
            ),
          ]),

          // ── 4 · DynamoDB (endpoint + credentials) ────────────
          _sectionHead('4', 'DynamoDB', cw),
          _subLabel('Endpoint'),
          Row(children: [
            SizedBox(width: urlW, child: _field(_endpoint, 'Url')),
            const SizedBox(width: 12),
            SizedBox(width: 160, child: _field(_partitionID, 'PartitionID')),
            const SizedBox(width: 12),
            SizedBox(width: 180, child: _field(_region, 'SigningRegion')),
          ]),
          const SizedBox(height: 14),
          _subLabel('Credentials'),
          Row(children: [
            SizedBox(width: half, child: _field(_ak, 'AccessKeyID')),
            const SizedBox(width: 12),
            SizedBox(width: half, child: _field(_sk, 'SecretAccessKey', obscure: true)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(width: half, child: _field(_sessionToken, 'SessionToken', obscure: true)),
            const SizedBox(width: 12),
            SizedBox(width: half, child: _field(_source, 'Source')),
          ]),

          // ── 5 · Extra flags ──────────────────────────────────
          _sectionHead('5', 'Extra flags', cw),
          for (var i = 0; i < _extraFlags.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                SizedBox(
                  width: 240,
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        _flagKeys.contains(_extraFlags[i].key) ? _extraFlags[i].key : null,
                    isDense: true,
                    decoration: _dd('Key'),
                    items: _flagKeys
                        .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                        .toList(),
                    onChanged: (v) => setState(() => _extraFlags[i].key = v ?? ''),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: (cw - 302).clamp(120.0, 620.0).toDouble(),
                  child: _field(_flagVals[i], 'Value'),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                  onPressed: () => _removeFlag(i),
                ),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _addFlag,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add flag'),
            ),
          ),

          const SizedBox(height: 24),
          Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('Save'),
              onPressed: () => widget.onSave(_collect()),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: () => widget.onDelete(widget.config),
            ),
          ]),
        ],
      );
    });
  }

  // A numbered section header: badge + uppercase title + a hairline rule.
  Widget _sectionHead(String n, String title, double cw) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0x264D82C4),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(n,
                  style: const TextStyle(color: Color(0xFF7FA9DC), fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Text(title.toUpperCase(),
                style: const TextStyle(
                    fontSize: 12, letterSpacing: 1.3, color: Color(0xFF9FB3C8), fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          Container(width: cw, height: 1, color: const Color(0xFF272D38)),
        ]),
      );

  // A sub-group label (endpoint / credentials) inside a section.
  Widget _subLabel(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: const TextStyle(
                fontSize: 12.5, color: Color(0xFF8B98A8), fontWeight: FontWeight.w600, letterSpacing: 0.3)),
      );

  // Shared decoration for the top-row dropdowns (Version / Multi DB) so their
  // box height and floating label match the text fields beside them.
  InputDecoration _dd(String label) => InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      );

  Widget _field(TextEditingController c, String label,
      {bool number = false, bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: number ? TextInputType.number : null,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

class LogsView extends StatefulWidget {
  final NativeCore core;
  final String? configId;
  final InstanceStatus? status;
  final bool expanded;
  final VoidCallback onToggle;
  const LogsView({
    super.key,
    required this.core,
    required this.configId,
    required this.status,
    required this.expanded,
    required this.onToggle,
  });
  @override
  State<LogsView> createState() => _LogsViewState();
}

class _LogsViewState extends State<LogsView> {
  List<String> _lines = [];
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _pull();
    _t = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pull());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _pull() {
    if (widget.configId == null) {
      if (_lines.isNotEmpty) setState(() => _lines = []);
      return;
    }
    try {
      final l = widget.core.logs(widget.configId!);
      if (l.length != _lines.length) {
        setState(() => _lines = l);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.status;
    // Show a bounded tail so the (naturally-sized) panel never grows without
    // limit. Natural heights lay out reliably in this embedder where fixed
    // heights / Expanded do not, so the whole detail pane scrolls as one.
    const maxTail = 200;
    final tail = _lines.length > maxTail
        ? _lines.sublist(_lines.length - maxTail)
        : _lines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: widget.onToggle,
          child: Container(
            color: Colors.black.withValues(alpha: 0.25),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Icon(widget.expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, size: 18),
              const SizedBox(width: 6),
              const Icon(Icons.terminal, size: 16),
              const SizedBox(width: 8),
              Text('logs', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              if (st != null)
                Text(
                  st.isRunning
                      ? 'running · pid ${st.pid} · ${st.uptimeSec}s'
                      : st.status + (st.exitMsg.isNotEmpty ? ' · ${st.exitMsg}' : ''),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
            ]),
          ),
        ),
        if (widget.expanded)
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.all(10),
            child: tail.isEmpty
                ? const Text('(no output)', style: TextStyle(color: Colors.grey))
                : SelectableText(
                    tail.join('\n'),
                    style: const TextStyle(
                        fontSize: 12, height: 1.4, color: Color(0xFFC8E1CB)),
                  ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Settings dialog (binary paths)
// ---------------------------------------------------------------------------

class _SettingsDialog extends StatefulWidget {
  final Settings settings;
  const _SettingsDialog({required this.settings});
  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _v1;
  late final TextEditingController _v2;

  @override
  void initState() {
    super.initState();
    _v1 = TextEditingController(text: widget.settings.redimosV1Path);
    _v2 = TextEditingController(text: widget.settings.redimosV2Path);
  }

  @override
  void dispose() {
    _v1.dispose();
    _v2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('redimos binary paths'),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Absolute path to each redimos executable. A config picks one via its '
            'redimo version. On Windows these are redimos.exe files.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _v1,
            decoration: const InputDecoration(labelText: 'redimos v1 binary', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _v2,
            decoration: const InputDecoration(labelText: 'redimos v2 binary', border: OutlineInputBorder()),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(
              context, Settings(redimosV1Path: _v1.text.trim(), redimosV2Path: _v2.text.trim())),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
