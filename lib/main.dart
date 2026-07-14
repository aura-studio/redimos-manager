import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/browser_page.dart';
import 'src/cmd_console.dart';
import 'src/endpoint_detail.dart';
import 'src/endpoint_page.dart';
import 'src/i18n.dart';
import 'src/models.dart';
import 'src/native.dart';
import 'src/partiql_page.dart';
import 'src/playground_page.dart';
import 'src/table_page.dart';

void main() {
  _loadThemeMode();
  loadAppLang();
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

// Root sidebar collapse state, persisted next to the theme/locale in ~/.redimos.
File? _navFile() {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return null;
  return File('$home${Platform.pathSeparator}.redimos${Platform.pathSeparator}nav');
}

bool _loadNavCollapsed() {
  try {
    final f = _navFile();
    return f != null && f.existsSync() && f.readAsStringSync().trim() == 'collapsed';
  } catch (_) {
    return false;
  }
}

void _saveNavCollapsed(bool collapsed) {
  try {
    final f = _navFile();
    if (f == null) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(collapsed ? 'collapsed' : 'expanded');
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
    // Rebuild the whole app on a theme OR language change, so every widget that
    // reads tr() re-localises and the theme re-applies.
    return AnimatedBuilder(
      animation: Listenable.merge([appThemeMode, appLang]),
      builder: (_, __) => MaterialApp(
        title: 'Redimos Manager',
        debugShowCheckedModeBanner: false,
        theme: _appTheme(Brightness.light),
        darkTheme: _appTheme(Brightness.dark),
        themeMode: appThemeMode.value,
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

  List<RedimosConfig> _configs = []; // the Instances section (each config = one instance)
  // v1.2: endpoints grouped by backend (from the core's split view).
  List<DdbEndpoint> _endpoints = [];
  Map<String, InstanceStatus> _status = {};
  String? _selectedId;
  // When an endpoint (not an instance) is selected, this holds its id and the
  // right pane shows the endpoint's storage views instead of the instance tabs.
  String? _selEndpointId;
  // Root sidebar collapse (v1.2): a ~200px panel ↔ a 52px rail. Persisted.
  bool _navCollapsed = _loadNavCollapsed();
  // Endpoint tab "Browse" on a table that isn't the config's own points the Table
  // tab at it (read-only). Keyed by config id so switching configs drops the override
  // without a manual clear at every selection site.
  String? _browseTable;
  String? _browseForId;
  // Configs that were running at the last AppBar "Stop all". While non-empty and
  // nothing is running, the Stop-all button becomes a green "restore" triangle.
  List<String> _stopAllSnapshot = [];
  Timer? _poll;
  // Lets the parent inspect / save the editor form before leaving it.
  final _editorKey = GlobalKey<_ConfigEditorState>();
  // Right-pane tabs (Configure / Monitor / Logs / Endpoint / Table / PartiQL /
  // Console / Browser / Playground) — owned here so flows can jump between tabs.
  late final TabController _tabs = TabController(length: 9, vsync: this);

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
      _endpoints = data.endpoints;
      _stopAllSnapshot = data.stopAllSnapshot;
      if (_selectedId == null && _selEndpointId == null && _configs.isNotEmpty) {
        _selectedId = _configs.first.id;
      }
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
        title: Text(tr('home.unsavedChanges')),
        content: Text(tr('home.unsavedChangesBody')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: Text(tr('home.cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: Text(tr('home.dontSave'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(tr('home.save'))),
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
      _toast('${tr('home.saved')} "${edited.name}"');
    } catch (e) {
      _toast('${tr('home.saveFailed')}: $e', error: true);
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
      _toast('${tr('home.deleted')} "${c.name}"');
    } catch (e) {
      _toast('${tr('home.deleteFailed')}: $e', error: true);
    }
  }

  void _startStop(RedimosConfig c) async {
    if (c.id.startsWith('unsaved-')) {
      _toast(tr('home.saveBeforeStart'), error: true);
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
        _toast('${tr('home.stopFailed')}: $e', error: true);
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
      _toast('${tr('home.startFailed')}: $e', error: true);
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
        title: Text(tr('home.tableMismatchTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ins.detail),
            const SizedBox(height: 12),
            Text(
              tr('home.startingAnyway'),
              style: const TextStyle(fontSize: 12.5),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: Text(tr('home.cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'rename'),
              child: Text(tr('home.changeTableName'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'recommend'),
              child: Text(tr('home.useRecommendedConfig'))),
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
      _toast(tr('home.tableRenamedHint'));
    } else if (choice == 'recommend') {
      st.applyRecommended(
          ins.tableVersion.isEmpty ? null : ins.tableVersion,
          ins.tableMultiDbKnown ? ins.tableMultiDb : null);
      _toast(tr('home.configUpdatedHint'));
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
          PopupMenuButton<AppLang>(
            tooltip: tr('app.language'),
            icon: const Icon(Icons.language_outlined),
            onSelected: (l) {
              appLang.value = l;
              saveAppLang(l);
            },
            itemBuilder: (_) => [
              // Language names show natively, not translated.
              _langMenuItem(AppLang.zh, '中文'),
              _langMenuItem(AppLang.en, 'English'),
            ],
          ),
          PopupMenuButton<ThemeMode>(
            tooltip: tr('app.theme'),
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
              _themeMenuItem(ThemeMode.light, Icons.light_mode_outlined, tr('theme.light')),
              _themeMenuItem(ThemeMode.dark, Icons.dark_mode_outlined, tr('theme.dark')),
              _themeMenuItem(ThemeMode.system, Icons.brightness_auto_outlined, tr('theme.system')),
            ],
          ),
          _stopAllButton(),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _navCollapsed ? 58 : 232,
            child: _navCollapsed ? _navRail() : _configList(),
          ),
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
              Text(tr('home.coreLoadFailed')),
              const SizedBox(height: 8),
              SelectableText('$_loadError',
                  style: const TextStyle(color: Colors.orangeAccent)),
              const SizedBox(height: 16),
              Text(
                tr('home.coreBuildHint'),
                textAlign: TextAlign.center,
              ),
            ]),
          ),
        ),
      );

  // AppBar action: stop-all / restore toggle. When anything is running it stops
  // all (recording the running set); when nothing is running but a set was
  // recorded, it becomes a green triangle that restores exactly that set.
  Widget _stopAllButton() {
    final anyRunning =
        _status.values.any((s) => s.isRunning || s.status == 'restarting');
    if (anyRunning) {
      return IconButton(
        tooltip: tr('app.stopAll'),
        icon: const Icon(Icons.stop_circle_outlined),
        onPressed: _stopAll,
      );
    }
    if (_stopAllSnapshot.isNotEmpty) {
      // Default icon colour (matches the outlined stop icon) — not green, so the
      // AppBar style stays consistent.
      return IconButton(
        tooltip: '${tr('app.startAll')} — ${tr('home.restore')} ${_stopAllSnapshot.length} ${tr('home.configsSuffix')}',
        icon: const Icon(Icons.play_circle_outline),
        onPressed: _restoreAll,
      );
    }
    return IconButton(
      tooltip: tr('app.stopAll'),
      icon: const Icon(Icons.stop_circle_outlined),
      onPressed: null, // nothing running, nothing to restore
    );
  }

  void _stopAll() {
    final snap = _core?.stopAll() ?? [];
    setState(() => _stopAllSnapshot = snap);
    _refresh();
    if (snap.isNotEmpty) {
      _toast('${tr('home.stopped')} ${snap.length} ${tr('home.configsSuffix')} — ${tr('home.tapToRestore')}');
    }
  }

  void _restoreAll() {
    final started = _core?.restoreAll() ?? [];
    setState(() => _stopAllSnapshot = []);
    _refresh();
    _toast('${tr('home.restored')} ${started.length} ${tr('home.configsSuffix')}');
  }

  void _toggleNav() {
    setState(() => _navCollapsed = !_navCollapsed);
    _saveNavCollapsed(_navCollapsed);
  }

  void _selectEndpoint(String id) {
    setState(() {
      _selEndpointId = id;
      _selectedId = null;
    });
  }

  Widget _configList() {
    return Column(
      children: [
        // Header: New config + collapse toggle. 50px so the rule below lines up
        // with the tab bar's rule across the split.
        SizedBox(
          height: 50,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 3, 8, 9),
            child: Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _newConfig,
                  icon: const Icon(Icons.add),
                  label: Text(tr('config.new')),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(38)),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: tr('nav.collapse'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_left, size: 20),
                onPressed: _toggleNav,
              ),
            ]),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: (_configs.isEmpty && _endpoints.isEmpty)
              ? Center(child: Text(tr('nav.noneYet')))
              : ListView(children: [
                  _navSection(tr('nav.instances'), const Color(0xFFB26A12)),
                  for (final c in _configs) _configTile(c),
                  _navSection(tr('nav.endpoints'), const Color(0xFF0E7F86)),
                  for (final e in _endpoints) _endpointTile(e),
                ]),
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

  // A small colored section header in the sidebar (Instances / Endpoints).
  Widget _navSection(String label, Color color) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 4),
        child: Row(children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w600,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
        ]),
      );

  Widget _endpointTile(DdbEndpoint e) {
    final sel = e.id == _selEndpointId;
    final (badge, badgeColor) = switch (e.kind) {
      'local' => ('LOCAL', const Color(0xFF0E7F86)),
      'aws' => ('AWS', const Color(0xFFB26A12)),
      _ => ('URL', Theme.of(context).colorScheme.primary),
    };
    final sub = switch (e.kind) {
      'aws' => e.region.isEmpty ? 'AWS' : 'AWS · ${e.region}',
      'local' => 'Local · ${_hostOf(e.endpoint)}',
      _ => e.endpoint,
    };
    return Material(
      color: sel ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15) : Colors.transparent,
      child: ListTile(
        dense: true,
        leading: Container(width: 12, height: 12,
            decoration: const BoxDecoration(color: Color(0xFF0E7F86), shape: BoxShape.circle)),
        title: Text(e.name.isEmpty ? tr('config.unnamed') : e.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(sub, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(color: badgeColor, borderRadius: BorderRadius.circular(4)),
          child: Text(badge, style: const TextStyle(fontSize: 8.5, color: Colors.white, fontWeight: FontWeight.w700)),
        ),
        onTap: () => _selectEndpoint(e.id),
      ),
    );
  }

  String _hostOf(String url) {
    final u = Uri.tryParse(url);
    return (u != null && u.host.isNotEmpty) ? (u.hasPort ? '${u.host}:${u.port}' : u.host) : url;
  }

  // Collapsed sidebar: a narrow rail of status dots with an expand toggle.
  Widget _navRail() {
    Widget item({required Color dot, required String label, required bool selected, required VoidCallback onTap}) =>
        Tooltip(
          message: label,
          waitDuration: const Duration(milliseconds: 300),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(9),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                border: selected
                    ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
                    : Border.all(color: Colors.transparent, width: 2),
                color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10) : null,
              ),
              alignment: Alignment.center,
              child: Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            ),
          ),
        );
    return Column(children: [
      SizedBox(
        height: 50,
        child: Center(
          child: IconButton(
            tooltip: tr('nav.expand'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: _toggleNav,
          ),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView(children: [
          const SizedBox(height: 4),
          Container(height: 2, margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              color: const Color(0xFFB26A12).withValues(alpha: 0.6)),
          for (final c in _configs)
            item(
              dot: _statusColor(_status[c.id]?.status ?? 'stopped'),
              label: c.name.isEmpty ? tr('config.unnamed') : c.name,
              selected: c.id == _selectedId,
              onTap: () async {
                if (c.id == _selectedId) return;
                if (await _confirmLeaveEditor()) {
                  setState(() {
                    _selectedId = c.id;
                    _selEndpointId = null;
                  });
                }
              },
            ),
          Container(height: 2, margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              color: const Color(0xFF0E7F86).withValues(alpha: 0.6)),
          for (final e in _endpoints)
            item(
              dot: const Color(0xFF0E7F86),
              label: e.name.isEmpty ? tr('config.unnamed') : e.name,
              selected: e.id == _selEndpointId,
              onTap: () => _selectEndpoint(e.id),
            ),
        ]),
      ),
    ]);
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
        title: Text(c.name.isEmpty ? tr('config.unnamed') : c.name,
            overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${c.version} · :${c.port}'
          '${running ? " · ${st!.cpuPercent.toStringAsFixed(1)}% · ${(st.memBytes / (1024 * 1024)).round()}MB" : ""}'
          '${st?.status == "restarting" ? " · restarting…" : ""}'
          '${(st?.restarts ?? 0) > 0 ? " · ↻${st!.restarts}" : ""}',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: IconButton(
          tooltip: active ? tr('config.stop') : tr('config.start'),
          icon: Icon(active ? Icons.stop : Icons.play_arrow,
              color: active ? Colors.redAccent : goGreen(context)),
          onPressed: () => _startStop(c),
        ),
        onTap: () async {
          if (c.id == _selectedId) return;
          if (await _confirmLeaveEditor()) {
            setState(() {
              _selectedId = c.id;
              _selEndpointId = null;
            });
          }
        },
      ),
    );
  }

  Color _statusColor(String status) => switch (status) {
        'running' => goGreen(context),
        'restarting' => Colors.amberAccent,
        'error' => Colors.redAccent,
        'failed' => Colors.redAccent,
        'exited' => Colors.orangeAccent,
        _ => Colors.grey,
      };

  Widget _statusDot(String status) => Container(
      width: 12, height: 12,
      decoration: BoxDecoration(color: _statusColor(status), shape: BoxShape.circle));

  // Right pane for a selected endpoint: its own tab set (Tables · Explorer ·
  // PartiQL · Playground) bound directly to the DynamoDB backend — see
  // EndpointDetailView.
  Widget _endpointDetail(DdbEndpoint e) => EndpointDetailView(
        key: ValueKey('endpoint-detail-${e.id}'),
        core: _core!,
        endpoint: e,
      );

  Widget _detail() {
    // Endpoint selected → its storage views (see _endpointDetail).
    if (_selEndpointId != null) {
      for (final e in _endpoints) {
        if (e.id == _selEndpointId) return _endpointDetail(e);
      }
    }
    final c = _selected;
    if (c == null) {
      return Center(child: Text(tr('config.pick')));
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
              // Eight equal-width tabs sharing the full width.
              labelColor: Theme.of(context).colorScheme.primary,
              unselectedLabelColor: Theme.of(context).textTheme.bodySmall?.color,
              indicatorColor: Theme.of(context).colorScheme.primary,
              indicatorWeight: 2.5,
              // Drop the tab bar's own M3 divider so it doesn't double up.
              dividerColor: Colors.transparent,
              tabs: [
                _tab(Icons.tune, tr('tab.configure')),
                _tab(Icons.insights, tr('tab.monitor')),
                _tab(Icons.terminal, tr('tab.logs')),
                _tab(Icons.folder_open, tr('tab.endpoint')),
                _tab(Icons.table_chart, tr('tab.table')),
                _tab(Icons.code, tr('tab.partiql')),
                _tab(Icons.chevron_right, tr('tab.console')),
                _tab(Icons.travel_explore, tr('tab.browser')),
                _tab(Icons.science_outlined, tr('tab.playground')),
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
                // logs — plus the Local DynamoDB engine's log when this config
                // is wired to it (mirrors the Monitor tab's two sections)
                LogsView(
                  core: _core!,
                  configId: logsConfigId,
                  status: st,
                  embedded: true,
                  ddb: _usesLocalDdb(c) ? _ddb : null,
                ),
                // endpoint — dynamodb-admin-style table list for this config's
                // endpoint (Name/keys/indexes/count/kind/used-by + recreate)
                EndpointPageView(
                  key: ValueKey('endpoint-${c.id}'),
                  core: _core!,
                  config: c,
                  running: st?.isRunning ?? false,
                  onOpenTable: (name) {
                    // Point the Table tab at this row's table (read-only when it
                    // isn't the config's own), then jump to it. Browsing the config's
                    // OWN table must NOT set the override — otherwise it lingers and,
                    // if the config's table is later renamed, spuriously re-enters
                    // read-only foreign-browse of the old name.
                    setState(() {
                      if (name == c.table) {
                        _browseTable = null;
                        _browseForId = null;
                      } else {
                        _browseTable = name;
                        _browseForId = c.id;
                      }
                    });
                    _tabs.animateTo(4);
                  },
                ),
                // table — DynamoDB item browser (Explore-items style). tableOverride
                // lets the Endpoint tab browse any table on the same endpoint.
                TablePageView(
                  key: ValueKey('table-${c.id}'),
                  core: _core!,
                  config: c,
                  running: st?.isRunning ?? false,
                  tableOverride: _browseForId == c.id ? _browseTable : null,
                  onExitBrowse: () => setState(() {
                    _browseTable = null;
                    _browseForId = null;
                  }),
                ),
                // partiql — statement editor (console PartiQL-editor style)
                PartiqlPageView(
                  key: ValueKey('partiql-${c.id}'),
                  core: _core!,
                  config: c,
                  running: st?.isRunning ?? false,
                ),
                // cmd — interactive redis-cli against the running proxy
                CmdConsole(
                  key: ValueKey('cmd-${c.id}'),
                  host: '127.0.0.1',
                  port: c.port,
                  auth: c.requirepass.isEmpty ? null : c.requirepass,
                  running: st?.isRunning ?? false,
                  // Surface the crash-loop cause (e.g. a failing startup backend
                  // check) so a proxy that can't reach its table isn't a silent
                  // spinner. Only while it's actually down for a known reason.
                  statusReason: (st != null &&
                          !st.isRunning &&
                          st.exitMsg.isNotEmpty &&
                          (st.status == 'restarting' ||
                              st.status == 'failed' ||
                              st.status == 'error'))
                      ? st.exitMsg
                      : null,
                ),
                // browser — Redis key browser over the proxy (ARDM style)
                BrowserPageView(
                  key: ValueKey('browser-${c.id}'),
                  config: c,
                  running: st?.isRunning ?? false,
                  core: _core!,
                ),
                // playground — run a JS/Go script against the proxy's Redis
                PlaygroundView(
                  key: ValueKey('playground-${c.id}'),
                  core: _core!,
                  config: c,
                  kind: 'redis',
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

  PopupMenuItem<AppLang> _langMenuItem(AppLang l, String label) {
    final selected = appLang.value == l;
    final color = selected ? Theme.of(context).colorScheme.primary : null;
    return PopupMenuItem<AppLang>(
      value: l,
      child: Row(children: [
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
    _ddbMode = _ddbModeOf(c);
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
      _ddbMode = _ddbModeOf(c);
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
    // AWS mode must clear the endpoint — a lingering URL would keep redimos
    // pointed at the local/custom endpoint instead of real AWS.
    c.endpoint = _ddbMode == 'aws' ? '' : _endpoint.text.trim();
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
      // Strict two-column grid: the content splits into two equal 50% halves
      // separated by one 12px gutter. Every field snaps to this grid —
      //   • Name spans the full width (both halves);
      //   • the leading field of each row (Auth / Table / Url / AccessKeyID /
      //     SessionToken) fills the LEFT half;
      //   • the right half is subdivided per row: three equal thirds for
      //     Port + the two dropdowns (so Port is ⅓ of a half), two equal
      //     halves for PartitionID + SigningRegion, or one full half for
      //     SecretAccessKey / Source.
      // Because each right-half subdivision sums back to exactly one half, every
      // field's left/right edges line up on the same two column boundaries.
      const gap = 12.0;
      final halfW = ((cw - gap) / 2).clamp(120.0, 4000.0).toDouble();
      final dropW = ((halfW - gap * 2) / 3).clamp(64.0, 2000.0).toDouble(); // ⅓ of a half
      final leadW = halfW;         // AccessKeyID / SessionToken (left half)
      final redisAuthW = halfW;    // Auth (left half)
      final redimosTableW = halfW; // Table (left half)
      final credRightW = halfW;    // SecretAccessKey / Source (right half)
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
          _sectionHead('1', tr('home.name'), topPad: 6),
          SizedBox(width: cw, child: _field(_name, tr('home.name'))),

          // ── 2 · Redis (the RESP endpoint this proxy exposes) ──
          _sectionHead('2', 'Redis'),
          Row(children: [
            SizedBox(width: redisAuthW, child: _field(_pass, tr('home.auth'), obscure: true)),
            const SizedBox(width: 12),
            SizedBox(width: dropW, child: _field(_port, tr('home.port'), number: true)),
            const SizedBox(width: 12),
            SizedBox(
              width: dropW,
              child: DropdownButtonFormField<bool>(
                initialValue: _autoRestart,
                isDense: true,
                decoration: _dd(tr('home.autoRestart')),
                items: [
                  DropdownMenuItem(value: true, child: Text(tr('home.on'))),
                  DropdownMenuItem(value: false, child: Text(tr('home.off'))),
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
                decoration: _dd(tr('home.engine')),
                items: [
                  DropdownMenuItem(value: 'native', child: Text(tr('home.native'))),
                  const DropdownMenuItem(value: 'docker', child: Text('Docker')),
                ],
                onChanged: (v) => setState(() => _runMode = v ?? 'native'),
              ),
            ),
          ]),

          // ── 3 · Redimos (proxy line + behaviour + backing table) ──
          _sectionHead('3', 'Redimos'),
          Row(children: [
            SizedBox(width: redimosTableW, child: _field(_table, tr('home.table'), focusNode: _tableFocus)),
            const SizedBox(width: 12),
            SizedBox(
              width: dropW,
              child: DropdownButtonFormField<String>(
                initialValue: _version,
                isDense: true,
                decoration: _dd(tr('home.version')),
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
                initialValue: _autoCreate,
                isDense: true,
                decoration: _dd(tr('home.autoCreate')),
                items: [
                  DropdownMenuItem(value: true, child: Text(tr('home.on'))),
                  DropdownMenuItem(value: false, child: Text(tr('home.off'))),
                ],
                onChanged: (v) => setState(() => _autoCreate = v ?? false),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: dropW,
              child: DropdownButtonFormField<bool>(
                initialValue: _multiDb,
                isDense: true,
                decoration: _dd(tr('home.multiDb')),
                items: [
                  DropdownMenuItem(value: true, child: Text(tr('home.on'))),
                  DropdownMenuItem(value: false, child: Text(tr('home.off'))),
                ],
                onChanged: (v) => setState(() => _multiDb = v ?? false),
              ),
            ),
          ]),

          // ── 4 · DynamoDB (target: endpoint URL vs real AWS) ───
          _sectionHead('4', 'DynamoDB'),
          // Mini tab switch: Endpoint = a DynamoDB-compatible URL (Local /
          // LocalStack / custom); AWS = real AWS via region + credentials.
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(
                    value: 'endpoint',
                    label: Text(tr('home.endpoint')),
                    icon: const Icon(Icons.link, size: 15)),
                const ButtonSegment(
                    value: 'aws',
                    label: Text('AWS'),
                    icon: Icon(Icons.cloud_outlined, size: 15)),
              ],
              selected: {_ddbMode},
              onSelectionChanged: (s) => setState(() => _ddbMode = s.first),
            ),
          ),
          const SizedBox(height: 14),
          if (_ddbMode == 'endpoint')
            // Endpoint mode: the URL is all that's needed.
            Row(children: [
              SizedBox(width: cw, child: _field(_endpoint, tr('home.url'))),
            ])
          else ...[
            // AWS mode: region + the credential triple.
            Row(children: [
              SizedBox(width: leadW, child: _field(_region, tr('home.region'))),
              const SizedBox(width: 12),
              SizedBox(width: credRightW, child: _field(_ak, tr('home.accessKeyId'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              SizedBox(width: leadW, child: _field(_sk, tr('home.secretAccessKey'), obscure: true)),
              const SizedBox(width: 12),
              SizedBox(width: credRightW, child: _field(_sessionToken, tr('home.sessionToken'), obscure: true)),
            ]),
          ],

          // ── 5 · Extra flags ──────────────────────────────────
          _sectionHead('5', tr('home.extraFlags')),
          for (var i = 0; i < _extraFlags.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                SizedBox(
                  width: leadW, // Key → left half (same column as Auth/Table/Url)
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        _flagKeys.contains(_extraFlags[i].key) ? _extraFlags[i].key : null,
                    isDense: true,
                    decoration: _dd(tr('home.key')),
                    items: _flagKeys
                        .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                        .toList(),
                    onChanged: (v) => setState(() => _extraFlags[i].key = v ?? ''),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  // Value fills the right half, reserving 52px (4px gap + the
                  // 48px remove button) so the row still totals the grid width.
                  width: (halfW - 52).clamp(90.0, 4000.0).toDouble(),
                  child: _field(_flagVals[i], tr('home.value')),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: tr('home.remove'),
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
              label: Text(tr('home.addFlag')),
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
                  label: Text(tr('home.save')),
                  onPressed: () => widget.onSave(_collect()),
                ),
                const SizedBox(width: 12),
                // Restore: discard unsaved edits, reverting fields to the saved config.
                OutlinedButton.icon(
                  icon: const Icon(Icons.restore),
                  label: Text(tr('home.revert')),
                  onPressed: () {
                    final wasDirty = isDirty;
                    _resetControllers();
                    if (wasDirty && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr('home.revertedChanges'))),
                      );
                    }
                  },
                ),
                const Spacer(),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: Text(tr('home.delete')),
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
  // Non-null when the selected config is wired to the managed Local DynamoDB:
  // the embedded tab then shows a second LOCAL DYNAMODB log section (mirrors
  // the Monitor tab's two-section layout).
  final LocalDdbInfo? ddb;
  const LogsView({
    super.key,
    required this.core,
    required this.configId,
    required this.status,
    this.expanded = true,
    this.onToggle,
    this.embedded = false,
    this.ddb,
  });
  @override
  State<LogsView> createState() => _LogsViewState();
}

class _LogsViewState extends State<LogsView> {
  List<String> _lines = [];
  List<String> _ddbLines = [];
  Timer? _t;
  final _scroll = ScrollController();
  final _ddbScroll = ScrollController();
  // Per-section collapse state for the embedded two-section layout.
  bool _redimosOpen = true;
  bool _ddbOpen = true;

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
    _ddbScroll.dispose();
    super.dispose();
  }

  void _jumpToEnd(ScrollController sc) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (sc.hasClients) sc.jumpTo(sc.position.maxScrollExtent);
    });
  }

  void _pull() {
    if (widget.configId == null) {
      if (_lines.isNotEmpty) setState(() => _lines = []);
    } else {
      try {
        final l = widget.core.logs(widget.configId!);
        if (l.length != _lines.length) {
          setState(() => _lines = l);
          if (widget.embedded) _jumpToEnd(_scroll);
        }
      } catch (_) {}
    }
    // The backing engine's own log, shown alongside when this config uses it.
    if (widget.ddb != null) {
      try {
        final l = widget.core.ddbLogs();
        if (l.length != _ddbLines.length) {
          setState(() => _ddbLines = l);
          if (widget.embedded) _jumpToEnd(_ddbScroll);
        }
      } catch (_) {}
    } else if (_ddbLines.isNotEmpty) {
      setState(() => _ddbLines = []);
    }
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
      final ddb = widget.ddb;
      final ddbTail = _ddbLines.length > maxTail
          ? _ddbLines.sublist(_ddbLines.length - maxTail)
          : _ddbLines;

      Widget logCard(List<String> lines, ScrollController sc) => Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.all(12),
            alignment: Alignment.topLeft,
            child: lines.isEmpty
                ? Text(tr('home.noOutput'),
                    style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color))
                : SingleChildScrollView(
                    controller: sc,
                    child: SelectableText(
                      lines.join('\n'),
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.4,
                          color: scheme.onSurface),
                    ),
                  ),
          );

      // Section header in the Monitor tab's idiom (icon + letter-spaced label),
      // with a collapse chevron (same icon as the sidebar dock's) on the left
      // and the process's status line on the right. Tapping toggles the section.
      Widget header(IconData icon, String label, String? line, bool open,
              VoidCallback onToggle) =>
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(open ? Icons.expand_more : Icons.expand_less,
                    size: 18, color: Colors.grey),
                const SizedBox(width: 6),
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1.3,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
                const Spacer(),
                if (line != null)
                  Text(line, style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ]),
            ),
          );

      final stLine = st == null
          ? null
          : (st.isRunning
              ? 'running · pid ${st.pid} · ${st.uptimeSec}s'
              : st.status + (st.exitMsg.isNotEmpty ? ' · ${st.exitMsg}' : ''));
      final ddbLine = ddb == null
          ? null
          : (ddb.status == 'running'
              ? 'running · pid ${ddb.pid} · ${ddb.uptimeSec}s'
              : ddb.status + (ddb.exitMsg.isNotEmpty ? ' · ${ddb.exitMsg}' : ''));

      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          header(Icons.dns, 'REDIMOS', stLine, _redimosOpen, () {
            setState(() => _redimosOpen = !_redimosOpen);
            if (_redimosOpen) _jumpToEnd(_scroll);
          }),
          if (_redimosOpen) ...[
            const SizedBox(height: 8),
            Expanded(child: logCard(tail, _scroll)),
          ],
          // Second section when this config is wired to the managed Local
          // DynamoDB — same split as the Monitor tab.
          if (ddb != null) ...[
            const SizedBox(height: 14),
            header(Icons.storage, 'LOCAL DYNAMODB', ddbLine, _ddbOpen, () {
              setState(() => _ddbOpen = !_ddbOpen);
              if (_ddbOpen) _jumpToEnd(_ddbScroll);
            }),
            if (_ddbOpen) ...[
              const SizedBox(height: 8),
              Expanded(child: logCard(ddbTail, _ddbScroll)),
            ],
          ],
        ]),
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
              Text(tr('home.logs'), style: Theme.of(context).textTheme.labelLarge),
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
                ? Text(tr('home.noOutput'), style: const TextStyle(color: Colors.grey))
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
          label: tr('home.cpu'),
          value: running ? '${st!.cpuPercent.toStringAsFixed(1)} %' : '—',
          data: cpuHist,
          color: const Color(0xFF7FB2E6),
        ),
        _SparkTile(
          label: tr('home.memory'),
          value: running ? '${(st!.memBytes / (1024 * 1024)).round()} MB' : '—',
          data: memHist,
          color: const Color(0xFF57CF92),
        ),
        _SparkTile(
          label: tr('home.opsPerSec'),
          value: running && st!.metricsOk ? st.opsPerSec.toStringAsFixed(0) : '—',
          data: opsHist,
          color: const Color(0xFFD9A85B),
        ),
        _InfoTile(label: tr('home.uptime'), value: running ? _fmtUptime(st!.uptimeSec) : '—'),
        _InfoTile(label: tr('home.restarts'), value: '${st?.restarts ?? 0}'),
        _InfoTile(label: tr('home.port'), value: running ? '${st!.port}' : '—'),
        _InfoTile(
            label: tr('home.engine'),
            value: (st?.runMode ?? 'native') == 'docker' ? 'Docker' : tr('home.native')),
        _InfoTile(
            label: tr('home.autoRestartLabel'),
            value: (st?.autoRestart ?? false) ? tr('home.on') : tr('home.off')),
        // ── redimos /metrics ───────────────────────────────
        _InfoTile(
            label: tr('home.latency'),
            value: running && st!.metricsOk
                ? '${st.avgLatencyMs.toStringAsFixed(2)} ms'
                : '—'),
        _InfoTile(
            label: tr('home.throttled'),
            value: running && st!.metricsOk ? '${st.throttled}' : '—'),
        _InfoTile(
            label: tr('home.health'),
            value: !running || !st!.metricsOk
                ? '—'
                : st.healthy
                    ? (st.ready ? tr('home.ready') : tr('home.healthy'))
                    : tr('home.down')),
      ],
    );
  }

  // A section eyebrow: icon + label on the left, a status string on the right.
  Widget _sectionHeader(BuildContext context, IconData icon, String label) {
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
    ]);
  }

  // The longest tile value on screen (the DDB "runtime · product" engine label);
  // shared as the fit reference by every info tile in both sections so all
  // values render at one identical, width-adaptive size. Null (no local DDB
  // section) means nothing long is on screen — tiles stay at the full 17px.
  String? get _fitRef => ddb != null ? _ddbEngineLabel(ddb!.config.engine) : null;

  // Lay out a fixed set of info tiles as equal-width columns that fill the whole
  // pane (every tile the same size, the row stretching edge-to-edge) in both the
  // initial window and full screen — instead of fixed-width tiles clustered on
  // the left. 12px gutters between tiles.
  Widget _tileRow(List<Widget> tiles) {
    final children = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      if (i > 0) children.add(const SizedBox(width: 12));
      children.add(Expanded(child: tiles[i]));
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  // Dashboard layout for the tab: a section header, three sparkline cards across
  // the top, the smaller info tiles in a grid below.
  Widget _dashboard(BuildContext context, InstanceStatus? st, bool running) {
    Widget spark(String label, String value, List<double> data, Color color) =>
        _SparkTile(label: label, value: value, data: data, color: color, width: null, sparkHeight: 48);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(context, Icons.dns, 'REDIMOS'),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: spark(tr('home.cpu'), running ? '${st!.cpuPercent.toStringAsFixed(1)} %' : '—',
                    cpuHist, const Color(0xFF7FB2E6))),
            const SizedBox(width: 12),
            Expanded(
                child: spark(tr('home.memory'), running ? '${(st!.memBytes / (1024 * 1024)).round()} MB' : '—',
                    memHist, const Color(0xFF57CF92))),
            const SizedBox(width: 12),
            Expanded(
                child: spark(tr('home.opsPerSec'), running && st!.metricsOk ? st.opsPerSec.toStringAsFixed(0) : '—',
                    opsHist, const Color(0xFFD9A85B))),
          ]),
        ),
        const SizedBox(height: 12),
        // Every tile in BOTH rows shares one fit reference — the longest value
        // on screen (the DDB engine label). All values therefore render at one
        // identical size: full 17px when the reference fits the tile width,
        // uniformly smaller when the window narrows. No tile ever stands out
        // bigger or smaller than its neighbours.
        _tileRow([
          // Dynamic metrics first …
          _InfoTile(label: tr('home.uptime'), fitReference: _fitRef, value: running ? _fmtUptime(st!.uptimeSec) : '—'),
          _InfoTile(label: tr('home.restarts'), fitReference: _fitRef, value: '${st?.restarts ?? 0}'),
          _InfoTile(
              label: tr('home.latency'),
              fitReference: _fitRef,
              value: running && st!.metricsOk ? '${st.avgLatencyMs.toStringAsFixed(2)} ms' : '—'),
          // Status (col 4) mirrors the DDB section's Status tile so the two rows
          // align on this column too.
          _InfoTile(label: tr('home.status'), fitReference: _fitRef, value: running ? tr('home.running') : (st?.status ?? 'stopped')),
          _InfoTile(
              label: tr('home.health'),
              fitReference: _fitRef,
              value: !running || !st!.metricsOk
                  ? '—'
                  : st.healthy
                      ? (st.ready ? tr('home.ready') : tr('home.healthy'))
                      : tr('home.down')),
          // … fixed / static values last. Show the RESP Port rather than a
          // PID/Container id: in docker run-mode the value was still the host
          // PID (never the container id), so the "Container" label was wrong —
          // and the port is the more useful thing to see here anyway.
          _InfoTile(label: tr('home.port'), fitReference: _fitRef, value: running ? '${st!.port}' : '—'),
          _InfoTile(
              label: tr('home.engine'),
              fitReference: _fitRef,
              value: (st?.runMode ?? 'native') == 'docker' ? 'Docker' : tr('home.native')),
        ]),
        if (ddb != null) _ddbSection(context, ddb!),
      ],
    );
  }

  // A separated "Local DynamoDB" section — the backing engine's own metrics,
  // kept distinct from the redimos instance metrics above.
  Widget _ddbSection(BuildContext context, LocalDdbInfo d) {
    final up = d.status == 'running';
    // "runtime · product" — mirrors the config dropdown labels so the tile says
    // both how it runs and which backend (e.g. "Docker · LocalStack").
    final engine = _ddbEngineLabel(d.config.engine);
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
        _sectionHeader(context, Icons.storage, 'LOCAL DYNAMODB'),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: spark(tr('home.cpu'), up ? '${d.cpuPercent.toStringAsFixed(1)} %' : '—',
                    ddbCpuHist, const Color(0xFF7FB2E6))),
            const SizedBox(width: 12),
            Expanded(
                child: spark(tr('home.memory'), up ? '${(d.memBytes / (1024 * 1024)).round()} MB' : '—',
                    ddbMemHist, const Color(0xFF57CF92))),
            const SizedBox(width: 12),
            Expanded(
                child: spark(tr('home.diskIo'), up ? _fmtRate(d.diskPerSec) : '—',
                    ddbDiskHist, const Color(0xFFD9A85B))),
          ]),
        ),
        const SizedBox(height: 12),
        _tileRow([
          // Dynamic first … These 7 tiles mirror the redimos section's 7 so the
          // two rows align column-for-column: Uptime · Restarts · Latency · (a
          // section-specific pair) · Port · Engine. Every tile shares the same
          // fit reference (the engine label) so both rows render at one size.
          _InfoTile(label: tr('home.uptime'), fitReference: engine, value: up ? _fmtUptime(d.uptimeSec) : '—'),
          _InfoTile(label: tr('home.restarts'), fitReference: engine, value: '${d.restarts}'),
          // Latency sits at column 3 to line up with the redimos Latency tile.
          // DynamoDB Local / LocalStack expose no latency metric, so it's a
          // placeholder ('—') that keeps the columns aligned.
          _InfoTile(label: tr('home.latency'), fitReference: engine, value: '—'),
          _InfoTile(label: tr('home.status'), fitReference: engine, value: up ? tr('home.running') : d.status),
          // Health (col 5) lines up with the redimos Health tile. DDB exposes no
          // health endpoint, so this is derived from the running state.
          _InfoTile(label: tr('home.health'), fitReference: engine, value: up ? tr('home.ready') : tr('home.down')),
          // Port + Engine last, aligning with the redimos section's Port + Engine
          // tiles above. (DDB says "Engine" because the choice is a different
          // backend product — dynamodb-local vs LocalStack — not just a run mode.)
          _InfoTile(label: tr('home.port'), fitReference: engine, value: '${d.config.port}'),
          _InfoTile(label: tr('home.engine'), fitReference: engine, value: engine),
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
              Text(tr('home.monitor'), style: Theme.of(context).textTheme.labelLarge),
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

// DDB Engine tile label: "runtime · product". Shared so the redimos Engine tile
// can fit itself to the same reference and render at the same size.
String _ddbEngineLabel(String engine) => switch (engine) {
      'docker' => 'Docker · dynamodb-local',
      'localstack' => 'Docker · LocalStack',
      _ => 'Java · local',
    };

class _InfoTile extends StatelessWidget {
  final String label;
  final String value;
  // When set, the value is scaled to fit one line via a FittedBox whose width is
  // pinned to this reference string. Every tile of the same width passing the
  // SAME reference scales by the same factor → identical font size, no wrapping,
  // no truncation, no taller tile. Used to keep the two Engine tiles equal.
  final String? fitReference;
  const _InfoTile({required this.label, required this.value, this.fitReference});

  @override
  Widget build(BuildContext context) {
    const valueStyle = TextStyle(fontSize: 17, fontWeight: FontWeight.w500);
    Widget valueWidget;
    if (fitReference == null) {
      valueWidget = Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: valueStyle);
    } else {
      // Stack an invisible copy of the (longer) reference under the value so the
      // FittedBox always scales against the reference's width — both Engine tiles
      // therefore shrink by the exact same factor.
      valueWidget = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Stack(children: [
          Opacity(
            opacity: 0,
            child: Text(fitReference!, maxLines: 1, softWrap: false, style: valueStyle),
          ),
          Text(value, maxLines: 1, softWrap: false, style: valueStyle),
        ]),
      );
    }
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
        Align(alignment: Alignment.centerLeft, child: valueWidget),
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
        title: Text(tr('home.localDdbLogs')),
        content: SizedBox(
          width: 720,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              lines.isEmpty ? tr('home.noOutput') : lines.join('\n'),
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('home.close'))),
        ],
      ),
    );
  }

  (Color, String) _pill(BuildContext context, String status) => switch (status) {
        'running' => (goGreen(context), tr('home.running')),
        'preparing' => (Colors.amberAccent, tr('home.preparing')),
        'restarting' => (Colors.amberAccent, tr('home.restarting')),
        'error' => (Colors.redAccent, tr('home.error')),
        'failed' => (Colors.redAccent, tr('home.failed')),
        _ => (Colors.grey, tr('home.stopped')),
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
        child: Text('Java · local${javaOk ? "" : "  ${tr('home.noJre')}"}',
            style: TextStyle(color: javaOk ? null : Colors.grey)),
      ),
      DropdownMenuItem(
        value: 'docker',
        enabled: dockerOk,
        child: Text('Docker · dynamodb-local${dockerOk ? "" : "  ${tr('home.noDocker')}"}',
            style: TextStyle(color: dockerOk ? null : Colors.grey)),
      ),
      DropdownMenuItem(
        value: 'localstack',
        enabled: dockerOk,
        child: Text('Docker · LocalStack${dockerOk ? "" : "  ${tr('home.noDocker')}"}',
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
              Text(tr('home.localDynamoDb'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            ];
            // Tight icon button: zero padding + small hit box, so the one-line
            // collapsed layout has as much room as possible for the figures.
            final button = _expanded
                ? IconButton(
                    tooltip: tr('home.logsTooltip'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    icon: const Icon(Icons.terminal, size: 16),
                    onPressed: _showLogs,
                  )
                : IconButton(
                    tooltip: active ? tr('config.stop') : tr('config.start'),
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
              decoration: InputDecoration(
                labelText: tr('home.engine'),
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                    decoration: InputDecoration(
                      labelText: tr('home.storage'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    items: [
                      DropdownMenuItem(value: 'memory', child: Text(tr('home.inMemory'))),
                      DropdownMenuItem(value: 'persist', child: Text(tr('home.persisted'))),
                    ],
                    onChanged: (v) {
                      if (v != null) _commit(storage: v);
                    },
                  ),
                )
              else
                Expanded(
                  child: Text(tr('home.storageManagedByLocalstack'),
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ),
              const SizedBox(width: 8),
              SizedBox(
                width: 86,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr('home.port'),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                  labelText: cfg.engine == 'java' ? tr('home.dataDir') : tr('home.volume'),
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
                      label: Text(tr('home.stop')),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          visualDensity: VisualDensity.compact),
                      onPressed: () => _startStop(true),
                    )
                  : FilledButton.icon(
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: Text(tr('home.start')),
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      onPressed: () => _startStop(false),
                    ),
            ),
            if (status == 'running') ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: tr('home.copyEndpoint'),
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
