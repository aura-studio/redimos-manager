import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/cmd_console.dart';
import 'src/models.dart';
import 'src/native.dart';

void main() {
  _loadThemeMode();
  runApp(const RedimosManagerApp());
}

/// App-wide theme selection (Light / Dark / System), chosen from the app bar.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.system);

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
      appThemeMode.value = switch (f.readAsStringSync().trim()) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    }
  } catch (_) {}
}

void _saveThemeMode(ThemeMode m) {
  try {
    final f = _themeFile();
    if (f == null) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(switch (m) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  } catch (_) {}
}

ThemeData _appTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF3B6EA5),
      brightness: b,
      fontFamily: 'monospace',
      // One consistent weight/colour for every rule in the app (sidebar splits,
      // tab bar, section separators) so no line looks bolder than another.
      dividerTheme: DividerThemeData(
        thickness: 1,
        space: 1,
        color: b == Brightness.dark ? const Color(0x33FFFFFF) : const Color(0x1F000000),
      ),
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

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  NativeCore? _core;
  String? _loadError;

  List<RedimosConfig> _configs = [];
  Map<String, InstanceStatus> _status = {};
  String? _selectedId;
  Timer? _poll;
  // Lets the parent inspect / save the editor form before leaving it.
  final _editorKey = GlobalKey<_ConfigEditorState>();
  // Right-pane tabs (Configure / Monitor / Logs / Cmd) — owned here so the
  // table-mismatch flow can jump back to Configure.
  late final TabController _tabs = TabController(length: 4, vsync: this);

  // Rolling CPU / memory history per config id, fed by the status poll and
  // drawn as sparklines in the monitor panel.
  static const _histCap = 90;
  final Map<String, List<double>> _cpuHist = {};
  final Map<String, List<double>> _memHist = {};
  final Map<String, List<double>> _opsHist = {}; // redimos ops/s (from /metrics)
  // The Local DynamoDB child's own CPU / memory history (singleton).
  final List<double> _ddbCpuHist = [];
  final List<double> _ddbMemHist = [];
  final List<double> _ddbDiskHist = []; // disk I/O bytes/sec

  LocalDdbInfo? _ddb; // Local DynamoDB snapshot, refreshed with the status poll

  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    try {
      _core = NativeCore();
      _reload();
      _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _refresh());
      // Kill every managed child before the app exits, so redimos / Local
      // DynamoDB processes don't outlive the app and orphan-hold their ports.
      _lifecycle = AppLifecycleListener(
        onExitRequested: () async {
          _core?.shutdown();
          return AppExitResponse.exit;
        },
      );
    } catch (e) {
      _loadError = '$e';
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _lifecycle?.dispose();
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
    if (ddb != null && ddb.status == 'running') {
      _ddbCpuHist.add(ddb.cpuPercent);
      _ddbMemHist.add(ddb.memBytes / (1024 * 1024));
      _ddbDiskHist.add(ddb.diskPerSec);
      if (_ddbCpuHist.length > _histCap) _ddbCpuHist.removeAt(0);
      if (_ddbMemHist.length > _histCap) _ddbMemHist.removeAt(0);
      if (_ddbDiskHist.length > _histCap) _ddbDiskHist.removeAt(0);
    }
    setState(() {
      _status = st;
      if (ddb != null) _ddb = ddb;
    });
  }

  // A config is wired to the managed Local DynamoDB when its endpoint points at
  // that engine's port on localhost.
  bool _usesLocalDdb(RedimosConfig c) {
    final ddb = _ddb;
    if (ddb == null) return false;
    final ep = c.endpoint.toLowerCase();
    if (ep.isEmpty) return false;
    final p = ddb.config.port;
    return ep.contains('localhost:$p') || ep.contains('127.0.0.1:$p');
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

  /// If the config editor has unsaved edits, prompt to save / discard / cancel.
  /// Returns true when it is OK to proceed (saved or discarded), false to abort.
  Future<bool> _confirmLeaveEditor() async {
    final st = _editorKey.currentState;
    if (st == null || !st.isDirty) return true;
    if (!mounted) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text(
            'This config has unsaved changes. Do you want to save them before continuing?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text("Don't save")),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (choice == 'save') {
      await st.saveNow();
      return true;
    }
    return choice == 'discard';
  }

  Future<void> _newConfig() async {
    if (!await _confirmLeaveEditor()) return;
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

  void _startStop(RedimosConfig c) async {
    if (c.id.startsWith('unsaved-')) {
      _toast('Save the config before starting it', error: true);
      return;
    }
    // "active" = running OR in a supervisor restart backoff — either way the
    // button stops it (Stop also cancels a pending auto-restart).
    final s = _status[c.id]?.status;
    final active = s == 'running' || s == 'restarting';
    if (active) {
      try {
        _core!.stop(c.id);
        _refresh();
      } catch (e) {
        _toast('Stop failed: $e', error: true);
      }
      return;
    }
    // Starting: the proxy runs the *saved* config, so offer to save unsaved edits first.
    if (!await _confirmLeaveEditor()) return;
    // Pre-flight: if the target table already holds data written under a
    // different version / MultiDB, warn before we crash-loop on a schema clash.
    final saved = _configs.firstWhere((x) => x.id == c.id, orElse: () => c);
    final inspect = _core!.inspectTable(saved);
    if (inspect.mismatch && mounted) {
      await _showTableMismatch(saved, inspect);
      return; // let the user resolve it, then Start again
    }
    try {
      setState(() => _selectedId = c.id);
      _core!.start(c.id);
      _refresh();
    } catch (e) {
      _toast('Start failed: $e', error: true);
    }
  }

  // Suggest a fresh table name for the mismatched config: strip a trailing
  // -v1/-v2 then append the config's own version, so a v1 config gets a distinct
  // v1 table rather than reusing the incompatible one.
  String _suggestTableName(RedimosConfig c) {
    var base = c.table;
    for (final s in ['-v1', '-v2']) {
      if (base.endsWith(s)) base = base.substring(0, base.length - s.length);
    }
    var name = '$base-${c.version}';
    if (name == c.table) name = '${c.table}-new';
    return name;
  }

  Future<void> _showTableMismatch(RedimosConfig c, TableInspect ins) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Table format mismatch'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ins.detail),
            const SizedBox(height: 12),
            const Text(
              'Starting anyway would fail or corrupt the data. Choose how to fix it:',
              style: TextStyle(fontSize: 12.5),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'rename'),
              child: const Text('Change table name')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'recommend'),
              child: const Text('Use recommended config')),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return;
    // Jump to the Configure tab, then edit the fields once the editor is mounted
    // (a short delay lets the tab animation settle so the editor state exists).
    setState(() => _selectedId = c.id);
    _tabs.animateTo(0);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final st = _editorKey.currentState;
    if (st == null || !mounted) return;
    if (choice == 'rename') {
      st.applyTableName(_suggestTableName(c));
      _toast('Table renamed — Save, then Start again');
    } else if (choice == 'recommend') {
      st.applyRecommended(
          ins.tableVersion.isEmpty ? null : ins.tableVersion,
          ins.tableMultiDbKnown ? ins.tableMultiDb : null);
      _toast('Config updated to match the data — Save, then Start again');
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
          PopupMenuButton<ThemeMode>(
            tooltip: 'Theme',
            icon: Icon(switch (appThemeMode.value) {
              ThemeMode.light => Icons.light_mode_outlined,
              ThemeMode.dark => Icons.dark_mode_outlined,
              ThemeMode.system => Icons.brightness_auto_outlined,
            }),
            onSelected: (m) {
              appThemeMode.value = m;
              _saveThemeMode(m);
            },
            itemBuilder: (_) => [
              _themeMenuItem(ThemeMode.light, Icons.light_mode_outlined, 'Light'),
              _themeMenuItem(ThemeMode.dark, Icons.dark_mode_outlined, 'Dark'),
              _themeMenuItem(ThemeMode.system, Icons.brightness_auto_outlined, 'System'),
            ],
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
        // Fixed 50px header — same explicit height as the tab bar, so the thin
        // rule below lines up with the tab bar's rule across the split.
        SizedBox(
          height: 50,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.icon(
              onPressed: _newConfig,
              icon: const Icon(Icons.add),
              label: const Text('New config'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
            ),
          ),
        ),
        const Divider(height: 1), // thin sidebar rule
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
        onTap: () async {
          if (c.id == _selectedId) return;
          if (await _confirmLeaveEditor()) setState(() => _selectedId = c.id);
        },
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
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Fixed 50px — same explicit height as the sidebar's "New config"
          // header, so the thin rule below lines up across the split.
          SizedBox(
            height: 50,
            child: TabBar(
              controller: _tabs,
              // Four equal-width tabs sharing the full width.
              labelColor: Theme.of(context).colorScheme.primary,
              unselectedLabelColor: Theme.of(context).textTheme.bodySmall?.color,
              indicatorColor: Theme.of(context).colorScheme.primary,
              indicatorWeight: 2.5,
              // Drop the tab bar's own M3 divider so it doesn't double up.
              dividerColor: Colors.transparent,
              tabs: [
                _tab(Icons.tune, 'Configure'),
                _tab(Icons.insights, 'Monitor'),
                _tab(Icons.terminal, 'Logs'),
                _tab(Icons.chevron_right, 'Cmd'),
              ],
            ),
          ),
          const Divider(height: 1), // thin rule under the tabs
          Expanded(
            child: TabBarView(
              controller: _tabs,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // configure (scrolls its own fields, pins the action bar)
                ConfigEditor(
                  key: _editorKey,
                  config: c,
                  onSave: _save,
                  onDelete: _delete,
                ),
                // monitor
                MonitorView(
                  status: st,
                  cpuHist: _cpuHist[c.id] ?? const [],
                  memHist: _memHist[c.id] ?? const [],
                  opsHist: _opsHist[c.id] ?? const [],
                  embedded: true,
                  ddb: _usesLocalDdb(c) ? _ddb : null,
                  ddbCpuHist: _ddbCpuHist,
                  ddbMemHist: _ddbMemHist,
                  ddbDiskHist: _ddbDiskHist,
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
    );
  }

  PopupMenuItem<ThemeMode> _themeMenuItem(ThemeMode m, IconData icon, String label) {
    final selected = appThemeMode.value == m;
    final color = selected ? Theme.of(context).colorScheme.primary : null;
    return PopupMenuItem<ThemeMode>(
      value: m,
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color, fontWeight: selected ? FontWeight.w600 : null)),
        const Spacer(),
        if (selected) Icon(Icons.check, size: 16, color: color),
      ]),
    );
  }

  Widget _tab(IconData icon, String label) => Tab(
        // Compact so the bold rule sits tight under the tab labels.
        height: 40,
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
  final _tableFocus = FocusNode();

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
    _tableFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ConfigEditor old) {
    super.didUpdateWidget(old);
    // The parent reuses this editor (GlobalKey) across configs; when the
    // underlying config changes, reload the form from it.
    if (old.config.id != widget.config.id) _resetControllers();
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
    _source.text = c.source;
    _pass.text = c.requirepass;
    for (final ctl in _flagVals) {
      ctl.dispose();
    }
    _flagVals.clear();
    setState(() {
      _version = c.version;
      _multiDb = c.multiDb;
      _autoCreate = c.autoCreateTable;
      _autoRestart = c.autoRestart;
      _runMode = c.runMode.isEmpty ? 'native' : c.runMode;
      _extraFlags = c.extraFlags.map((f) => FlagKV(key: f.key, value: f.value)).toList();
      for (final f in _extraFlags) {
        _flagVals.add(TextEditingController(text: f.value));
      }
    });
  }

  /// Whether the form differs from the saved config.
  bool get isDirty =>
      jsonEncode(_collect().toJson()) != jsonEncode(widget.config.toJson());

  Future<void> saveNow() => widget.onSave(_collect());

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
      // Fill the whole config pane, and size everything as a PROPORTION of it so
      // the form scales uniformly with the window (initial size and full screen
      // look identical, just bigger/smaller). Subtract the 16px horizontal
      // padding on each side of the scroll view so the row width matches the
      // real content area — otherwise the trailing column overflows the pane and
      // clips at the window edge.
      final cw = (w - 32).clamp(360.0, 6000.0).toDouble();
      // Each inline dropdown (and Port) is a fixed fraction of the row so the
      // columns keep their ratio at any width.
      final dropW = ((cw - 36) * 0.13).clamp(110.0, 400.0).toDouble();
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
        children: [
          // Scrollable field area — the pinned action bar below never moves.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
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
            SizedBox(width: redimosTableW, child: _field(_table, 'Table', focusNode: _tableFocus)),
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

          const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          // Pinned action bar: locked to the bottom (never scrolls), 48px tall so
          // its top divider lines up with the Local DynamoDB panel's divider.
          const Divider(height: 1),
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                FilledButton.icon(
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                  onPressed: () => widget.onSave(_collect()),
                ),
                const SizedBox(width: 12),
                // Restore: discard unsaved edits, reverting fields to the saved config.
                OutlinedButton.icon(
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore'),
                  onPressed: () {
                    final wasDirty = isDirty;
                    _resetControllers();
                    if (wasDirty && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Reverted unsaved changes')),
                      );
                    }
                  },
                ),
                const Spacer(),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
                  onPressed: _confirmDelete,
                ),
              ]),
            ),
          ),
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
      {bool number = false, bool obscure = false, FocusNode? focusNode}) {
    return TextField(
      controller: c,
      focusNode: focusNode,
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
  // The managed Local DynamoDB, shown as its own section when this config points
  // at it. null = the config isn't wired to the local engine.
  final LocalDdbInfo? ddb;
  final List<double> ddbCpuHist;
  final List<double> ddbMemHist;
  final List<double> ddbDiskHist;
  const MonitorView({
    super.key,
    required this.status,
    required this.cpuHist,
    required this.memHist,
    required this.opsHist,
    this.expanded = true,
    this.onToggle,
    this.embedded = false,
    this.ddb,
    this.ddbCpuHist = const [],
    this.ddbMemHist = const [],
    this.ddbDiskHist = const [],
  });

  String _fmtUptime(int s) {
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
    return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  }

  // Bytes/sec → a compact human rate (e.g. "0 B/s", "812 KB/s", "3.4 MB/s").
  String _fmtRate(double bytesPerSec) {
    final b = bytesPerSec;
    if (b < 1024) return '${b.round()} B/s';
    if (b < 1024 * 1024) return '${(b / 1024).round()} KB/s';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB/s';
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

  // A section eyebrow: icon + label on the left, a status string on the right.
  Widget _sectionHeader(BuildContext context, IconData icon, String label, String status) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 16, color: scheme.onSurfaceVariant),
      const SizedBox(width: 8),
      Text(label,
          style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.3,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant)),
      const Spacer(),
      Text(status, style: TextStyle(fontSize: 11, color: Theme.of(context).textTheme.bodySmall?.color)),
    ]);
  }

  // Dashboard layout for the tab: a section header, three sparkline cards across
  // the top, the smaller info tiles in a grid below.
  Widget _dashboard(BuildContext context, InstanceStatus? st, bool running) {
    Widget spark(String label, String value, List<double> data, Color color) =>
        _SparkTile(label: label, value: value, data: data, color: color, width: null, sparkHeight: 48);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
            context,
            Icons.dns,
            'REDIMOS',
            running
                ? 'Running · :${st!.port}${st.adopted ? ' · adopted' : ''}'
                : (st?.status ?? 'stopped')),
        const SizedBox(height: 12),
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
          // Dynamic metrics first …
          _InfoTile(label: 'Uptime', value: running ? _fmtUptime(st!.uptimeSec) : '—'),
          _InfoTile(label: 'Restarts', value: '${st?.restarts ?? 0}'),
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
          // … fixed / static values last.
          _InfoTile(
              label: (st?.runMode ?? 'native') == 'docker' ? 'Container' : 'PID',
              value: running ? '${st!.pid}' : '—'),
          _InfoTile(
              label: 'RunMode',
              value: (st?.runMode ?? 'native') == 'docker' ? 'Docker' : 'Native'),
        ]),
        if (ddb != null) _ddbSection(context, ddb!),
      ],
    );
  }

  // A separated "Local DynamoDB" section — the backing engine's own metrics,
  // kept distinct from the redimos instance metrics above.
  Widget _ddbSection(BuildContext context, LocalDdbInfo d) {
    final up = d.status == 'running';
    final engine = switch (d.config.engine) {
      'docker' => 'Docker',
      'localstack' => 'LocalStack',
      _ => 'Java',
    };
    // Same sparkHeight (48) as the redimos dashboard so every chart box across
    // both sections is an identical size.
    Widget spark(String label, String value, List<double> data, Color color) =>
        _SparkTile(label: label, value: value, data: data, color: color, width: null, sparkHeight: 48);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        const Divider(height: 1),
        const SizedBox(height: 14),
        _sectionHeader(context, Icons.storage, 'LOCAL DYNAMODB',
            up ? 'Running · :${d.config.port}${d.adopted ? ' · adopted' : ''}' : d.status),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: spark('CPU', up ? '${d.cpuPercent.toStringAsFixed(1)} %' : '—',
                    ddbCpuHist, const Color(0xFF7FB2E6))),
            const SizedBox(width: 12),
            Expanded(
                child: spark('Memory', up ? '${(d.memBytes / (1024 * 1024)).round()} MB' : '—',
                    ddbMemHist, const Color(0xFF57CF92))),
            const SizedBox(width: 12),
            Expanded(
                child: spark('Disk I/O', up ? _fmtRate(d.diskPerSec) : '—',
                    ddbDiskHist, const Color(0xFFD9A85B))),
          ]),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 12, children: [
          // Dynamic first …
          _InfoTile(label: 'Uptime', value: up ? _fmtUptime(d.uptimeSec) : '—'),
          _InfoTile(label: 'Restarts', value: '${d.restarts}'),
          _InfoTile(label: 'Status', value: up ? 'Running' : d.status),
          // … fixed config last. PID is second-to-last and RunMode last, so both
          // line up with the redimos section's PID and RunMode tiles above.
          _InfoTile(label: 'Storage', value: d.config.storage == 'persist' ? 'Persisted' : 'In-mem'),
          _InfoTile(label: 'Port', value: '${d.config.port}'),
          _InfoTile(label: 'PID', value: up && d.pid > 0 ? '${d.pid}' : '—'),
          _InfoTile(label: 'RunMode', value: engine),
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
  const LocalDdbPanel({
    super.key,
    required this.core,
    required this.info,
    required this.onMutated,
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
          Builder(builder: (context) {
            // Status figures; "Running" is implied by the green dot so it's dropped.
            final statsText = active && status == 'running'
                ? ':${cfg.port}'
                    ' · ${info!.cpuPercent.toStringAsFixed(1)}%'
                    ' · ${(info.memBytes / (1024 * 1024)).round()}MB'
                    '${info.restarts > 0 ? " · ↻${info.restarts}" : ""}'
                : pillText;
            final stats = Text(statsText,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.grey));
            // Bottom-docked panel grows upward: up-chevron to expand, down to collapse.
            final head = <Widget>[
              Icon(_expanded ? Icons.expand_more : Icons.expand_less, size: 18, color: Colors.grey),
              const SizedBox(width: 4),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text('Local DynamoDB',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            ];
            // Tight icon button: zero padding + small hit box, so the one-line
            // collapsed layout has as much room as possible for the figures.
            final button = _expanded
                ? IconButton(
                    tooltip: 'Logs',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    icon: const Icon(Icons.terminal, size: 16),
                    onPressed: _showLogs,
                  )
                : IconButton(
                    tooltip: active ? 'Stop' : 'Start',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    icon: Icon(active ? Icons.stop : Icons.play_arrow,
                        size: 18, color: active ? Colors.redAccent : goGreen(context)),
                    onPressed: () => _startStop(active),
                  );
            return InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              // Expanded: title row + stats on its own line below (room to spare).
              // Collapsed: everything on one compact line, stats inline before the button.
              child: _expanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [...head, const Spacer(), button]),
                        Padding(padding: const EdgeInsets.only(left: 30, bottom: 2), child: stats),
                      ],
                    )
                  // Fixed 30px row → panel total 8+30+10 = 48px, matching the Cmd
                  // input row so the two top dividers line up across the split.
                  : SizedBox(
                      height: 30,
                      child: Row(children: [
                        ...head,
                        const SizedBox(width: 8),
                        // Expanded (not Spacer + Flexible): the stats take all the
                        // room left of the button instead of being squeezed to the
                        // right edge, so the figures show in full.
                        Expanded(child: stats),
                        const SizedBox(width: 2),
                        button,
                      ]),
                    ),
            );
          }),
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
                labelText: 'RunMode',
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
