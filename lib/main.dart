import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/cmd_console.dart';
import 'src/models.dart';
import 'src/native.dart';

void main() {
  _loadThemeMode();
  runApp(const RedimosManagerApp());
}

/// App-wide light/dark selection, toggled from the app bar.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.dark);

// The theme choice is persisted next to the Go core's store, in ~/.redimos/theme.
File? _themeFile() {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return null;
  return File('$home${Platform.pathSeparator}.redimos${Platform.pathSeparator}theme');
}

void _loadThemeMode() {
  try {
    final f = _themeFile();
    if (f != null && f.existsSync()) {
      appThemeMode.value =
          f.readAsStringSync().trim() == 'light' ? ThemeMode.light : ThemeMode.dark;
    }
  } catch (_) {}
}

void _saveThemeMode(ThemeMode m) {
  try {
    final f = _themeFile();
    if (f == null) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(m == ThemeMode.light ? 'light' : 'dark');
  } catch (_) {}
}

ThemeData _appTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF3B6EA5),
      brightness: b,
      fontFamily: 'monospace',
    );

class RedimosManagerApp extends StatelessWidget {
  const RedimosManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (_, mode, __) => MaterialApp(
        title: 'Redimos Manager',
        debugShowCheckedModeBanner: false,
        theme: _appTheme(Brightness.light),
        darkTheme: _appTheme(Brightness.dark),
        themeMode: mode,
        home: const HomePage(),
      ),
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

/// Stylised "Redimos Manager" logotype: the geometric Righteous display face,
/// its glyphs filled with a blue→cyan→green gradient echoing the logo, over a
/// soft blue glow. "Manager" is tracked wider and slightly dimmed so the two
/// words read as a mark rather than plain text.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    const glow = [
      Shadow(color: Color(0x555FA8E8), blurRadius: 12),
      Shadow(color: Color(0x3346D38A), blurRadius: 18),
    ];
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF8FC6FF), Color(0xFF5A93D4), Color(0xFF33C1D6), Color(0xFF46D38A)],
        stops: [0.0, 0.4, 0.72, 1.0],
      ).createShader(rect),
      child: const Text.rich(
        TextSpan(children: [
          TextSpan(text: 'Redimos', style: TextStyle(letterSpacing: 0.5)),
          TextSpan(
            text: '  Manager',
            style: TextStyle(letterSpacing: 2.0, color: Color(0xCCFFFFFF)),
          ),
        ]),
        style: TextStyle(
          fontFamily: 'Righteous',
          fontSize: 22,
          height: 1.0,
          color: Colors.white,
          shadows: glow,
        ),
      ),
    );
  }
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
  Map<String, InstanceStatus> _status = {};
  String? _selectedId;
  Timer? _poll;

  // Rolling CPU / memory history per config id, fed by the status poll and
  // drawn as sparklines in the monitor panel.
  static const _histCap = 90;
  final Map<String, List<double>> _cpuHist = {};
  final Map<String, List<double>> _memHist = {};
  final Map<String, List<double>> _opsHist = {}; // redimos ops/s (from /metrics)

  LocalDdbInfo? _ddb; // Local DynamoDB snapshot, refreshed with the status poll

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
      _selectedId ??= _configs.isNotEmpty ? _configs.first.id : null;
    });
    _refresh();
  }

  void _refresh() {
    if (_core == null) return;
    final st = _core!.status();
    for (final s in st.values) {
      if (!s.isRunning) continue;
      (_cpuHist[s.id] ??= []).add(s.cpuPercent);
      (_memHist[s.id] ??= []).add(s.memBytes / (1024 * 1024));
      (_opsHist[s.id] ??= []).add(s.opsPerSec);
      if (_cpuHist[s.id]!.length > _histCap) _cpuHist[s.id]!.removeAt(0);
      if (_memHist[s.id]!.length > _histCap) _memHist[s.id]!.removeAt(0);
      if (_opsHist[s.id]!.length > _histCap) _opsHist[s.id]!.removeAt(0);
    }
    LocalDdbInfo? ddb;
    try {
      ddb = _core!.ddbGet();
    } catch (_) {}
    setState(() {
      _status = st;
      if (ddb != null) _ddb = ddb;
    });
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
        setState(() => _selectedId = c.id);
        _core!.start(c.id);
      }
      _refresh();
    } catch (e) {
      _toast('${active ? "Stop" : "Start"} failed: $e', error: true);
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
          _Wordmark(),
        ]),
        actions: [
          IconButton(
            tooltip: appThemeMode.value == ThemeMode.dark ? 'Light theme' : 'Dark theme',
            icon: Icon(appThemeMode.value == ThemeMode.dark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
            onPressed: () {
              appThemeMode.value =
                  appThemeMode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
              _saveThemeMode(appThemeMode.value);
            },
          ),
          IconButton(
            tooltip: 'Stop all',
            icon: const Icon(Icons.stop_circle_outlined),
            onPressed: () {
              _core?.stopAll();
              _refresh();
            },
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
        const Divider(height: 1),
        LocalDdbPanel(
          core: _core!,
          info: _ddb,
          onMutated: _refresh,
          onNewLocalConfig: _newLocalConfig,
        ),
      ],
    );
  }

  /// One-click config pointed at the running Local DynamoDB: local endpoint,
  /// auto-create the table, supervised.
  void _newLocalConfig(int ddbPort) {
    final c = RedimosConfig(
      name: 'local-ddb',
      version: 'v2',
      port: _nextFreePort(),
      table: 'redis-data',
      endpoint: 'http://localhost:$ddbPort',
      region: 'us-east-1',
      autoCreateTable: true,
      autoRestart: true,
    );
    try {
      final id = _core!.saveConfig(c);
      _reload();
      setState(() => _selectedId = id);
      _toast('Created "local-ddb" pointed at :$ddbPort');
    } catch (e) {
      _toast('Create failed: $e', error: true);
    }
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
          '${running ? " · ${st!.cpuPercent.toStringAsFixed(1)}% · ${(st.memBytes / (1024 * 1024)).round()}MB" : ""}'
          '${st?.status == "restarting" ? " · restarting…" : ""}'
          '${(st?.restarts ?? 0) > 0 ? " · ↻${st!.restarts}" : ""}',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: IconButton(
          tooltip: active ? 'Stop' : 'Start',
          icon: Icon(active ? Icons.stop : Icons.play_arrow,
              color: active ? Colors.redAccent : goGreen(context)),
          onPressed: () => _startStop(c),
        ),
        onTap: () => setState(() => _selectedId = c.id),
      ),
    );
  }

  Widget _statusDot(String status) {
    final color = switch (status) {
      'running' => goGreen(context),
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
    final st = _status[c.id];
    // configure / monitor / logs / cmd as switchable tabs. The controller sits
    // above the per-config content so the chosen tab is kept when you switch
    // between configs in the sidebar.
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            // Four equal-width tabs sharing the full width.
            labelColor: Theme.of(context).colorScheme.primary,
            unselectedLabelColor: Theme.of(context).textTheme.bodySmall?.color,
            indicatorColor: Theme.of(context).colorScheme.primary,
            indicatorWeight: 2.5,
            tabs: [
              _tab(Icons.tune, 'Configure'),
              _tab(Icons.insights, 'Monitor'),
              _tab(Icons.terminal, 'Logs'),
              _tab(Icons.chevron_right, 'Cmd'),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // configure
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ConfigEditor(
                    key: ValueKey(c.id),
                    config: c,
                    onSave: _save,
                    onDelete: _delete,
                  ),
                ),
                // monitor
                MonitorView(
                  status: st,
                  cpuHist: _cpuHist[c.id] ?? const [],
                  memHist: _memHist[c.id] ?? const [],
                  opsHist: _opsHist[c.id] ?? const [],
                  embedded: true,
                ),
                // logs
                LogsView(
                  core: _core!,
                  configId: logsConfigId,
                  status: st,
                  embedded: true,
                ),
                // cmd — interactive redis-cli against the running proxy
                CmdConsole(
                  key: ValueKey('cmd-${c.id}'),
                  host: '127.0.0.1',
                  port: c.port,
                  auth: c.requirepass.isEmpty ? null : c.requirepass,
                  running: st?.isRunning ?? false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tab(IconData icon, String label) => Tab(
        height: 42,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16),
          const SizedBox(width: 7),
          Text(label),
        ]),
      );
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
  late String _runMode;
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
    _runMode = c.runMode.isEmpty ? 'native' : c.runMode;
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
    c.runMode = _runMode;
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
      // Fill the available width (no right gap) — only a min guard, no max cap.
      final cw = w.clamp(300.0, 4000.0).toDouble();
      const dropW = 140.0; // one width for every inline dropdown (and Port)
      // Auth / Table / Url / AccessKeyID / SessionToken share one leading-field
      // width so every left-column field lines up on both edges; each row's
      // trailing controls fill the rest and flush right.
      final leadW = (cw - 36 - dropW * 3).clamp(140.0, 4000.0).toDouble();
      final redisAuthW = leadW;
      final redimosTableW = leadW;
      final urlW = leadW;
      // PartitionID + SigningRegion split the remainder of the endpoint row so
      // Url lines up with Table/Auth (and they get wider than before).
      final endW = ((cw - leadW - 24) / 2).clamp(120.0, 4000.0).toDouble();
      // The right credential field fills whatever is left after the leadW column.
      final credRightW = (cw - leadW - 12).clamp(120.0, 4000.0).toDouble();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 1 · Name ─────────────────────────────────────────
          _sectionHead('1', 'Name', topPad: 6),
          SizedBox(width: cw, child: _field(_name, 'Name')),

          // ── 2 · Redis (the RESP endpoint this proxy exposes) ──
          _sectionHead('2', 'Redis'),
          Row(children: [
            SizedBox(width: redisAuthW, child: _field(_pass, 'Auth', obscure: true)),
            const SizedBox(width: 12),
            SizedBox(width: dropW, child: _field(_port, 'Port', number: true)),
            const SizedBox(width: 12),
            SizedBox(
              width: dropW,
              child: DropdownButtonFormField<bool>(
                initialValue: _autoRestart,
                isDense: true,
                decoration: _dd('AutoRestart'),
                items: const [
                  DropdownMenuItem(value: true, child: Text('On')),
                  DropdownMenuItem(value: false, child: Text('Off')),
                ],
                onChanged: (v) => setState(() => _autoRestart = v ?? true),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: dropW,
              child: DropdownButtonFormField<String>(
                initialValue: _runMode,
                isDense: true,
                decoration: _dd('RunMode'),
                items: const [
                  DropdownMenuItem(value: 'native', child: Text('Native')),
                  DropdownMenuItem(value: 'docker', child: Text('Docker')),
                ],
                onChanged: (v) => setState(() => _runMode = v ?? 'native'),
              ),
            ),
          ]),

          // ── 3 · Redimos (proxy line + behaviour + backing table) ──
          _sectionHead('3', 'Redimos'),
          Row(children: [
            SizedBox(width: redimosTableW, child: _field(_table, 'Table')),
            const SizedBox(width: 12),
            SizedBox(
              width: dropW,
              child: DropdownButtonFormField<bool>(
                initialValue: _autoCreate,
                isDense: true,
                decoration: _dd('AutoCreate'),
                items: const [
                  DropdownMenuItem(value: true, child: Text('On')),
                  DropdownMenuItem(value: false, child: Text('Off')),
                ],
                onChanged: (v) => setState(() => _autoCreate = v ?? false),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: dropW,
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
              width: dropW,
              child: DropdownButtonFormField<bool>(
                initialValue: _multiDb,
                isDense: true,
                decoration: _dd('MultiDB'),
                items: const [
                  DropdownMenuItem(value: true, child: Text('On')),
                  DropdownMenuItem(value: false, child: Text('Off')),
                ],
                onChanged: (v) => setState(() => _multiDb = v ?? false),
              ),
            ),
          ]),

          // ── 4 · DynamoDB (endpoint + credentials) ────────────
          _sectionHead('4', 'DynamoDB'),
          Row(children: [
            SizedBox(width: urlW, child: _field(_endpoint, 'Url')),
            const SizedBox(width: 12),
            SizedBox(width: endW, child: _field(_partitionID, 'PartitionID')),
            const SizedBox(width: 12),
            SizedBox(width: endW, child: _field(_region, 'SigningRegion')),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            SizedBox(width: leadW, child: _field(_ak, 'AccessKeyID')),
            const SizedBox(width: 12),
            SizedBox(width: credRightW, child: _field(_sk, 'SecretAccessKey', obscure: true)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(width: leadW, child: _field(_sessionToken, 'SessionToken', obscure: true)),
            const SizedBox(width: 12),
            SizedBox(width: credRightW, child: _field(_source, 'Source')),
          ]),

          // ── 5 · Extra flags ──────────────────────────────────
          _sectionHead('5', 'Extra flags'),
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
                  width: (cw - 302).clamp(120.0, 4000.0).toDouble(),
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

          // Separate the config fields from the actions.
          const SizedBox(height: 22),
          const Divider(height: 1),
          const SizedBox(height: 18),
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
              onPressed: _confirmDelete,
            ),
          ]),
        ],
      );
    });
  }

  // Delete needs an explicit confirmation — it permanently removes the config.
  Future<void> _confirmDelete() async {
    final name = widget.config.name.isEmpty ? '(unnamed)' : widget.config.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete config?'),
        content: Text('Permanently remove "$name"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDelete(widget.config);
  }

  // A numbered section header: a rounded number badge + uppercase eyebrow
  // label. No rule line — the badge + spacing group each title WITH its content
  // instead of a hairline cutting between them, and it adapts to the theme.
  Widget _sectionHead(String n, String title, {double topPad = 24}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(top: topPad, bottom: 12),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(n,
              style: TextStyle(color: scheme.primary, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Text(title.toUpperCase(),
            style: TextStyle(
                fontSize: 12.5,
                letterSpacing: 1.4,
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
      ]),
    );
  }

  // A sub-group label (endpoint / credentials) inside a section.

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
  final VoidCallback? onToggle;
  final bool embedded; // headerless body that fills the tab and scrolls
  const LogsView({
    super.key,
    required this.core,
    required this.configId,
    required this.status,
    this.expanded = true,
    this.onToggle,
    this.embedded = false,
  });
  @override
  State<LogsView> createState() => _LogsViewState();
}

class _LogsViewState extends State<LogsView> {
  List<String> _lines = [];
  Timer? _t;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _pull();
    _t = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pull());
  }

  @override
  void dispose() {
    _t?.cancel();
    _scroll.dispose();
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
        if (widget.embedded) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
          });
        }
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
    if (widget.embedded) {
      final scheme = Theme.of(context).colorScheme;
      return Container(
        color: scheme.surfaceContainerLowest,
        padding: const EdgeInsets.all(12),
        alignment: Alignment.topLeft,
        child: tail.isEmpty
            ? Text('(no output)',
                style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color))
            : SingleChildScrollView(
                controller: _scroll,
                child: SelectableText(
                  tail.join('\n'),
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                      color: scheme.onSurface),
                ),
              ),
      );
    }
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
// Monitor (per-child graphical monitoring: CPU / memory / uptime / restarts)
// ---------------------------------------------------------------------------

class MonitorView extends StatelessWidget {
  final InstanceStatus? status;
  final List<double> cpuHist;
  final List<double> memHist;
  final List<double> opsHist;
  final bool expanded;
  final VoidCallback? onToggle;
  final bool embedded; // headerless, always-shown tiles (for the tab layout)
  const MonitorView({
    super.key,
    required this.status,
    required this.cpuHist,
    required this.memHist,
    required this.opsHist,
    this.expanded = true,
    this.onToggle,
    this.embedded = false,
  });

  String _fmtUptime(int s) {
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
    return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  }

  Widget _tiles(InstanceStatus? st, bool running) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _SparkTile(
          label: 'CPU',
          value: running ? '${st!.cpuPercent.toStringAsFixed(1)} %' : '—',
          data: cpuHist,
          color: const Color(0xFF7FB2E6),
        ),
        _SparkTile(
          label: 'Memory',
          value: running ? '${(st!.memBytes / (1024 * 1024)).round()} MB' : '—',
          data: memHist,
          color: const Color(0xFF57CF92),
        ),
        _SparkTile(
          label: 'Ops/s',
          value: running && st!.metricsOk ? st.opsPerSec.toStringAsFixed(0) : '—',
          data: opsHist,
          color: const Color(0xFFD9A85B),
        ),
        _InfoTile(label: 'Uptime', value: running ? _fmtUptime(st!.uptimeSec) : '—'),
        _InfoTile(label: 'Restarts', value: '${st?.restarts ?? 0}'),
        _InfoTile(
            label: (st?.runMode ?? 'native') == 'docker' ? 'Container' : 'PID',
            value: running ? '${st!.pid}' : '—'),
        _InfoTile(
            label: 'Run mode',
            value: (st?.runMode ?? 'native') == 'docker' ? 'Docker' : 'Native'),
        _InfoTile(
            label: 'Auto-restart',
            value: (st?.autoRestart ?? false) ? 'On' : 'Off'),
        // ── redimos /metrics ───────────────────────────────
        _InfoTile(
            label: 'Latency',
            value: running && st!.metricsOk
                ? '${st.avgLatencyMs.toStringAsFixed(2)} ms'
                : '—'),
        _InfoTile(
            label: 'Throttled',
            value: running && st!.metricsOk ? '${st.throttled}' : '—'),
        _InfoTile(
            label: 'Health',
            value: !running || !st!.metricsOk
                ? '—'
                : st.healthy
                    ? (st.ready ? 'Ready' : 'Healthy')
                    : 'Down'),
      ],
    );
  }

  // Dashboard layout for the tab: three sparkline cards fill the width across
  // the top, the smaller info tiles sit in a grid below.
  Widget _dashboard(BuildContext context, InstanceStatus? st, bool running) {
    Widget spark(String label, String value, List<double> data, Color color) =>
        _SparkTile(label: label, value: value, data: data, color: color, width: null, sparkHeight: 48);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: spark('CPU', running ? '${st!.cpuPercent.toStringAsFixed(1)} %' : '—',
                    cpuHist, const Color(0xFF7FB2E6))),
            const SizedBox(width: 12),
            Expanded(
                child: spark('Memory', running ? '${(st!.memBytes / (1024 * 1024)).round()} MB' : '—',
                    memHist, const Color(0xFF57CF92))),
            const SizedBox(width: 12),
            Expanded(
                child: spark('Ops/s', running && st!.metricsOk ? st.opsPerSec.toStringAsFixed(0) : '—',
                    opsHist, const Color(0xFFD9A85B))),
          ]),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 12, children: [
          _InfoTile(label: 'Uptime', value: running ? _fmtUptime(st!.uptimeSec) : '—'),
          _InfoTile(label: 'Restarts', value: '${st?.restarts ?? 0}'),
          _InfoTile(
              label: (st?.runMode ?? 'native') == 'docker' ? 'Container' : 'PID',
              value: running ? '${st!.pid}' : '—'),
          _InfoTile(
              label: 'RunMode',
              value: (st?.runMode ?? 'native') == 'docker' ? 'Docker' : 'Native'),
          _InfoTile(label: 'AutoRestart', value: (st?.autoRestart ?? false) ? 'On' : 'Off'),
          _InfoTile(
              label: 'Latency',
              value: running && st!.metricsOk ? '${st.avgLatencyMs.toStringAsFixed(2)} ms' : '—'),
          _InfoTile(label: 'Throttled', value: running && st!.metricsOk ? '${st.throttled}' : '—'),
          _InfoTile(
              label: 'Health',
              value: !running || !st!.metricsOk
                  ? '—'
                  : st.healthy
                      ? (st.ready ? 'Ready' : 'Healthy')
                      : 'Down'),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = status;
    final running = st?.isRunning ?? false;
    if (embedded) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: _dashboard(context, st, running),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onToggle,
          child: Container(
            color: Colors.black.withValues(alpha: 0.25),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, size: 18),
              const SizedBox(width: 6),
              const Icon(Icons.insights, size: 16),
              const SizedBox(width: 8),
              Text('monitor', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              if (st != null)
                Text(
                  running
                      ? '${st.cpuPercent.toStringAsFixed(1)}% · ${(st.memBytes / (1024 * 1024)).round()}MB'
                          '${st.metricsOk ? " · ${st.opsPerSec.toStringAsFixed(0)} ops/s" : ""}'
                          '${st.restarts > 0 ? " · ↻${st.restarts}" : ""}'
                      : st.status,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
            ]),
          ),
        ),
        if (expanded)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
            child: _tiles(st, running),
          ),
      ],
    );
  }
}

// The "running / start" green. greenAccent is bright on dark surfaces but too
// pale on a light background, so use a deeper green there.
Color goGreen(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.greenAccent
    : const Color(0xFF12994F);

Color _tileColor(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHighest;
Color? _tileLabelColor(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.color;

class _SparkTile extends StatelessWidget {
  final String label;
  final String value;
  final List<double> data;
  final Color color;
  final double? width; // null = fill the parent (e.g. inside Expanded)
  final double sparkHeight;
  const _SparkTile(
      {required this.label,
      required this.value,
      required this.data,
      required this.color,
      this.width = 220,
      this.sparkHeight = 26});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: _tileColor(context),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, color: _tileLabelColor(context))),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        SizedBox(
          height: sparkHeight,
          width: double.infinity,
          child: CustomPaint(painter: _SparklinePainter(data, color)),
        ),
      ]),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String label;
  final String value;
  const _InfoTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 132,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: _tileColor(context),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, color: _tileLabelColor(context))),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  _SparklinePainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    var maxV = data.reduce(math.max);
    if (maxV <= 0) maxV = 1;
    final dx = size.width / (data.length - 1);
    final line = Path();
    for (var i = 0; i < data.length; i++) {
      final x = i * dx;
      final y = size.height - (data[i] / maxV).clamp(0.0, 1.0) * size.height;
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
    }
    final area = Path.from(line)
      ..lineTo((data.length - 1) * dx, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.10));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.data.length != data.length ||
      (data.isNotEmpty && old.data.isNotEmpty && old.data.last != data.last);
}

// ---------------------------------------------------------------------------
// Local DynamoDB panel (sidebar dock): 3 engines × 2 storage modes
// ---------------------------------------------------------------------------

class LocalDdbPanel extends StatefulWidget {
  final NativeCore core;
  final LocalDdbInfo? info;
  final VoidCallback onMutated;
  final void Function(int ddbPort) onNewLocalConfig;
  const LocalDdbPanel({
    super.key,
    required this.core,
    required this.info,
    required this.onMutated,
    required this.onNewLocalConfig,
  });

  @override
  State<LocalDdbPanel> createState() => _LocalDdbPanelState();
}

class _LocalDdbPanelState extends State<LocalDdbPanel> {
  final _port = TextEditingController();
  final _store = TextEditingController(); // volume (docker) / dataDir (java)
  bool _seeded = false;
  bool _expanded = false; // collapsed by default → just the status line

  @override
  void dispose() {
    _port.dispose();
    _store.dispose();
    super.dispose();
  }

  LocalDdbConfig get _cfg => widget.info?.config ?? LocalDdbConfig();

  void _seedOnce() {
    if (_seeded || widget.info == null) return;
    _seeded = true;
    _port.text = '${_cfg.port}';
    _store.text = _cfg.engine == 'java' ? _cfg.dataDir : _cfg.volume;
  }

  void _commit({String? engine, String? storage}) {
    final c = _cfg;
    final next = LocalDdbConfig(
      engine: engine ?? c.engine,
      storage: storage ?? c.storage,
      port: int.tryParse(_port.text.trim()) ?? c.port,
      dataDir: c.dataDir,
      volume: c.volume,
    );
    // Engine switch: follow the new engine's default port if the field still
    // holds the previous engine's default.
    if (engine != null && engine != c.engine) {
      final wasDefault = next.port == 8000 || next.port == 4566;
      if (wasDefault) {
        next.port = engine == 'localstack' ? 4566 : 8000;
        _port.text = '${next.port}';
      }
      _store.text = engine == 'java' ? next.dataDir : next.volume;
    }
    final sv = _store.text.trim();
    if (next.engine == 'java') {
      next.dataDir = sv;
    } else {
      next.volume = sv;
    }
    try {
      widget.core.ddbSet(next);
      widget.onMutated();
    } catch (_) {}
  }

  void _startStop(bool active) {
    try {
      if (active) {
        widget.core.ddbStop();
      } else {
        _commit(); // persist any pending field edits before launching
        widget.core.ddbStart();
      }
      widget.onMutated();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: Colors.red.shade800,
      ));
    }
  }

  void _showLogs() {
    final lines = widget.core.ddbLogs();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Local DynamoDB logs'),
        content: SizedBox(
          width: 720,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              lines.isEmpty ? '(no output)' : lines.join('\n'),
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  (Color, String) _pill(BuildContext context, String status) => switch (status) {
        'running' => (goGreen(context), 'Running'),
        'preparing' => (Colors.amberAccent, 'Preparing…'),
        'restarting' => (Colors.amberAccent, 'Restarting…'),
        'error' => (Colors.redAccent, 'Error'),
        'failed' => (Colors.redAccent, 'Failed'),
        _ => (Colors.grey, 'Stopped'),
      };

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    _seedOnce();
    final cfg = _cfg;
    final status = info?.status ?? 'stopped';
    final active = info?.isActive ?? false;
    final (dotColor, pillText) = _pill(context, status);
    final dockerOk = info?.dockerOk ?? false;
    final javaOk = info?.javaOk ?? false;

    final engineItems = <DropdownMenuItem<String>>[
      DropdownMenuItem(
        value: 'java',
        enabled: javaOk,
        child: Text('Java · local${javaOk ? "" : "  (no JRE)"}',
            style: TextStyle(color: javaOk ? null : Colors.grey)),
      ),
      DropdownMenuItem(
        value: 'docker',
        enabled: dockerOk,
        child: Text('Docker · dynamodb-local${dockerOk ? "" : "  (no Docker)"}',
            style: TextStyle(color: dockerOk ? null : Colors.grey)),
      ),
      DropdownMenuItem(
        value: 'localstack',
        enabled: dockerOk,
        child: Text('Docker · LocalStack${dockerOk ? "" : "  (no Docker)"}',
            style: TextStyle(color: dockerOk ? null : Colors.grey)),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(children: [
              Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: Colors.grey),
              const SizedBox(width: 4),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text('Local DynamoDB',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const Spacer(),
              Text(
                active && status == 'running'
                    ? '$pillText · :${cfg.port}'
                        '${info!.restarts > 0 ? " · ↻${info.restarts}" : ""}'
                    : pillText,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              if (_expanded)
                IconButton(
                  tooltip: 'Logs',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.terminal, size: 16),
                  onPressed: _showLogs,
                )
              else
                IconButton(
                  tooltip: active ? 'Stop' : 'Start',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(active ? Icons.stop : Icons.play_arrow,
                      size: 18, color: active ? Colors.redAccent : goGreen(context)),
                  onPressed: () => _startStop(active),
                ),
            ]),
          ),
          // Slide the body open/closed instead of snapping.
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
          if (!active) ...[
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: cfg.engine,
              isDense: true,
              decoration: const InputDecoration(
                labelText: 'Engine',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              items: engineItems,
              onChanged: (v) {
                if (v != null) _commit(engine: v);
              },
            ),
            const SizedBox(height: 10),
            Row(children: [
              if (cfg.engine != 'localstack')
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: cfg.storage == 'persist' ? 'persist' : 'memory',
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Storage',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'memory', child: Text('In-memory')),
                      DropdownMenuItem(value: 'persist', child: Text('Persisted')),
                    ],
                    onChanged: (v) {
                      if (v != null) _commit(storage: v);
                    },
                  ),
                )
              else
                const Expanded(
                  child: Text('storage: managed by LocalStack',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ),
              const SizedBox(width: 8),
              SizedBox(
                width: 86,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                  onSubmitted: (_) => _commit(),
                ),
              ),
            ]),
            if (cfg.engine != 'localstack' && cfg.storage == 'persist') ...[
              const SizedBox(height: 10),
              TextField(
                controller: _store,
                decoration: InputDecoration(
                  labelText: cfg.engine == 'java' ? 'Data dir' : 'Volume',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                onSubmitted: (_) => _commit(),
              ),
            ],
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: active
                  ? OutlinedButton.icon(
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('Stop'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          visualDensity: VisualDensity.compact),
                      onPressed: () => _startStop(true),
                    )
                  : FilledButton.icon(
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('Start'),
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      onPressed: () => _startStop(false),
                    ),
            ),
            if (status == 'running') ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Copy endpoint',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: 'http://localhost:${cfg.port}'));
                },
              ),
              IconButton(
                tooltip: 'New config pointed at this endpoint',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_link, size: 18),
                onPressed: () => widget.onNewLocalConfig(cfg.port),
              ),
            ],
          ]),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
