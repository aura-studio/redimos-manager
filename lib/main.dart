import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import 'src/browser_page.dart';
import 'src/cmd_console.dart';
import 'src/configure_page.dart';
import 'src/endpoint_detail.dart';
import 'src/home_chrome.dart';
import 'src/i18n.dart';
import 'src/logs_page.dart';
import 'src/models.dart';
import 'src/monitor_widgets.dart';
import 'src/native.dart';
import 'src/playground_page.dart';
import 'src/service_configure.dart';
import 'src/service_detail.dart';
import 'src/services_state.dart';
import 'src/ui_states.dart';
import 'src/ui_surfaces.dart';
import 'src/ui_theme.dart';
import 'src/ui_tokens.dart';

void main() {
  loadAppLang();
  runApp(const RedimosManagerApp());
}

class RedimosManagerApp extends StatelessWidget {
  const RedimosManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild the whole app on a language change so every widget that reads
    // tr() re-localises. The app ships a single light theme; the dark paint
    // tokens survive only as the pixel-evidence capture layer.
    return AnimatedBuilder(
      animation: appLang,
      builder: (_, __) => MaterialApp(
        title: 'Redimos Manager',
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        scrollBehavior: appScrollBehavior,
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  NativeCore? _core;
  String? _loadError;

  List<RedimosConfig> _configs =
      []; // the Instances section (each config = one instance)
  // v1.2: endpoints grouped by backend (from the core's split view).
  List<DdbEndpoint> _endpoints = [];
  Map<String, InstanceStatus> _status = {};
  String? _selectedId;
  // When an endpoint (not an instance) is selected, this holds its id and the
  // right pane shows the endpoint's storage views instead of the instance tabs.
  String? _selEndpointId;
  // v2.3: which rail entry is active — the entity sidebar shows ONLY that
  // kind's entities (instances or endpoints), never mixed.
  EntityKind _entityKind = EntityKind.instance;
  // v2.3: active screen index on the endpoint detail's MidBar tabs (the tab
  // controller lives there no longer — the chrome is HomePage-level now).
  int _epScreenIndex = 0;
  // Sidebar card currently under the pointer (reveals its start/stop control).
  String? _hoveredCardId;
  // Configs that were running at the last AppBar "Stop all". While non-empty and
  // nothing is running, the Stop-all button becomes a green "restore" triangle.
  List<String> _stopAllSnapshot = [];
  Timer? _poll;
  // Lets the parent inspect / save the editor form before leaving it.
  final _editorKey = GlobalKey<ConfigEditorState>();
  // Right-pane tabs (Configure / Monitor / Logs / Console / Browser /
  // Playground) — owned here so flows can jump between tabs. The endpoint-bound
  // storage views (Endpoint / Table / PartiQL) live on the endpoint detail,
  // which owns them outright (2026-08-05 trim).
  late final TabController _tabs = TabController(length: 6, vsync: this);

  // Rolling CPU / memory history per config id, fed by the status poll and
  // drawn as sparklines in the monitor panel.
  static const _histCap = 90;
  final Map<String, List<double>> _cpuHist = {};
  final Map<String, List<double>> _memHist = {};
  final Map<String, List<double>> _opsHist =
      {}; // redimos ops/s (from /metrics)

  // Stage 11: central multi-Service state (list / selection / tab / per-ID
  // history), refreshed by the SAME 1.5 s timer as the instance status — one
  // poller for everything, never one timer per Service (requirement 12.5).
  // The rail / sidebar / detail tabs land on top of it in stages 12–14.
  ServicesState? _svcState;

  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // Repaint the MidBar underline + top-bar screen name on tab changes.
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
    // Debug-only UI self-test hook: open a specific instance tab at launch so
    // screenshots can reach screens whose MidBar tabs synthetic OS clicks
    // never land on (see the v2.3 self-test). Release builds ignore the env.
    if (kDebugMode) {
      final i = int.tryParse(Platform.environment['REDIMOS_INITIAL_TAB'] ?? '');
      if (i != null) _tabs.index = i.clamp(0, 5);
    }
    try {
      _core = NativeCore();
      _svcState = ServicesState(_core!);
      // Selection / tab / history changes rebuild the chrome and detail; the
      // poller's refresh() lands through the same notify (stage 12).
      _svcState!.addListener(() {
        if (mounted) setState(() {});
      });
      _reload();
      _poll =
          Timer.periodic(const Duration(milliseconds: 1500), (_) => _refresh());
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
    _svcState?.dispose();
    _lifecycle?.dispose();
    _poll?.cancel();
    super.dispose();
  }

  void _reload() {
    final data = _core!.load();
    setState(() {
      _configs = data.configs;
      _endpoints = data.endpoints;
      // Stage 12: the typed V2 snapshot carries both ID namespaces; fall back
      // to the legacy flat list only for stores written before it existed.
      final v2 = data.stopAllSnapshotV2;
      _stopAllSnapshot = v2.isEmpty
          ? data.stopAllSnapshot
          : [...v2.instances, ...v2.services];
      if (_selectedId == null &&
          _selEndpointId == null &&
          _configs.isNotEmpty) {
        _selectedId = _configs.first.id;
      }
    });
    // Debug-only companion to the REDIMOS_INITIAL_TAB hook in initState: pick
    // the initially selected instance by name (self-test screenshots).
    if (kDebugMode) {
      final n = Platform.environment['REDIMOS_INITIAL_INSTANCE'];
      if (n != null && n.isNotEmpty) {
        final hit = _configs.where((c) => c.name == n);
        if (hit.isNotEmpty) setState(() => _selectedId = hit.first.id);
      }
    }
    _refresh();
  }

  void _refresh() {
    if (_core == null) return;
    // Stage 11: the same tick also refreshes the full Service snapshot (12.5).
    // Fire-and-forget: its generation guard drops the reply if a newer refresh
    // or the dispose overtakes it (12.4).
    final svc = _svcState;
    if (svc != null) unawaited(svc.refresh());
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
    setState(() {
      _status = st;
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: Text(tr('home.cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              child: Text(tr('home.dontSave'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: Text(tr('home.save'))),
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: Text(tr('home.cancel'))),
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
      st.applyRecommended(ins.tableVersion.isEmpty ? null : ins.tableVersion,
          ins.tableMultiDbKnown ? ins.tableMultiDb : null);
      _toast(tr('home.configUpdatedHint'));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) return _errorScaffold();
    // Stage 12: the ACTIVE entity kind (rail) routes the chrome and detail —
    // each kind keeps its own selection, so switching never loses one (12.6).
    final isSvc = _entityKind == EntityKind.service;
    final isEp = !isSvc && _entityKind == EntityKind.endpoint;
    // CP 9.x: the chrome (rail / entity sidebar / top bar / mid bar / status
    // bar) lives in src/home_chrome.dart so the pixel-capture channel can wrap
    // the very same widgets around its content screens.
    return Scaffold(
      body: HomeChrome(
        state: ChromeState(
          entityKind: _entityKind,
          configs: _configs,
          endpoints: _endpoints,
          statuses: _status,
          selectedConfigId: _selectedId,
          selectedEndpointId: _selEndpointId,
          hoveredCardId: _hoveredCardId,
          entityQuery: _entityQuery,
          tabLabels:
              isSvc ? _serviceTabLabels() : isEp ? _epTabLabels() : _instanceTabLabels(),
          tabIndex: isSvc
              ? (_svcState?.selectedTab ?? 0)
              : isEp
                  ? _epScreenIndex
                  : _tabs.index,
          stopAllSnapshot: _stopAllSnapshot,
          lang: appLang.value,
          services: _svcState?.services ?? const [],
          selectedServiceId: _svcState?.selectedId,
        ),
        cb: ChromeCallbacks(
          onEntityKind: (k) => setState(() => _entityKind = k),
          onSelectConfig: _selectInstance,
          onSelectEndpoint: _selectEndpoint,
          onSelectService: _selectService,
          onHoverCard: (h) => setState(() => _hoveredCardId = h),
          onQueryChanged: (v) => setState(() => _entityQuery = v),
          onNewConfig: _newConfig,
          onNewService: _newService,
          onMidTab: (i) => _onMidTab(i, isEp),
          onStartStop: _startStop,
          onServiceStartStop: _serviceStartStop,
          onStopAll: _stopAll,
          onRestoreAll: _restoreAll,
          onLang: (l) {
            appLang.value = l;
            saveAppLang(l);
          },
        ),
        midBarCta: _midBarCta(),
        child: _detail(),
      ),
    );
  }

  void _onMidTab(int i, bool isEp) {
    if (_entityKind == EntityKind.service) {
      _svcState?.selectedTab = i; // notifies → listener rebuilds
      return;
    }
    if (isEp) {
      setState(() => _epScreenIndex = i);
    } else {
      _tabs.animateTo(i);
      setState(() {}); // refresh the MidBar's active underline + top-bar name
    }
  }

  Widget _midBarCta() {
    // Context CTA in the end group. Wired screens get a live action; the rest
    // reserve the slot (per-screen wiring lands in T4–T13). Stage 12: route by
    // the ACTIVE entity kind — the Service area has no CTA yet (stage 13 adds
    // the Configure action bar inside its own screen instead).
    if (_entityKind == EntityKind.service) return const SizedBox(width: 8);
    final isEp = _entityKind == EntityKind.endpoint;
    final idx = isEp ? _epScreenIndex : _tabs.index;
    if (!isEp && idx == 0) {
      // Browse → New Key
      final c = _selected;
      if (c != null) {
        return chromeCta(
            context, Icons.add, tr('br.newKey'), () => _focusBrowserNewKey(c));
      }
    }
    if (!isEp && idx == 4) {
      // Playground → Run (same v2.3 CTA grammar, same action as the toolbar's)
      final st = _playgroundKey.currentState;
      if (st != null) {
        return chromeCta(context, Icons.play_arrow, tr('pg.run'),
            () => (st as dynamic).runScript());
      }
    }
    if (isEp && idx == 1) {
      // Endpoint Browser → ＋ Item (T12; opens the selected table's create
      // flow via the key bridge). No i18n key for this label. The leading
      // plus comes from the icon — the literal must NOT repeat it (the
      // mockup .pbtn shows a single plus; pixel-fidelity-v23 CP 9.x).
      return chromeCta(context, Icons.add, 'Item', () {
        final st = _epBrowserKey.currentState;
        if (st != null && (st as dynamic).createItem() == true) return;
        _toast('Select a table first');
      });
    }
    return const SizedBox(width: 8);
  }

  // A GlobalKey into the instance Browser page so the MidBar CTA can reach its
  // New-Key flow (the in-page button and the CTA open the same dialog).
  final GlobalKey _browserKey = GlobalKey();
  // Same bridge for the instance Playground screen's Run action (T9).
  final GlobalKey _playgroundKey = GlobalKey();
  // Same bridge for the endpoint Browser screen's ＋ Item action (T12).
  final GlobalKey _epBrowserKey = GlobalKey();

  void _focusBrowserNewKey(RedimosConfig c) {
    final st = _browserKey.currentState;
    if (st != null) (st as dynamic).startCreateKey();
  }

  // ---- screen-name + tab-label helpers (single source for top bar & mid bar) ----

  // v2.3 mockups label the instance tab 'Browse' but the endpoint tab
  // 'Browser'; the two screens must not share one i18n value. Reuse the
  // existing 'ep.browse' ('Browse') key for the instance side — no new keys.
  static const _instanceTabKeys = [
    'ep.browse',
    'tab.console',
    'tab.monitor',
    'tab.logs',
    'tab.playground',
    'tab.configure'
  ];
  List<String> _instanceTabLabels() =>
      [for (final k in _instanceTabKeys) tr(k)];

  // Stage 15 (3.1–3.4): the endpoint screens are exactly these four client-
  // side tabs, always — no engine-derived Monitor/Logs extras.
  static const _epTabKeys = [
    'tab.overview',
    'tab.browser',
    'tab.partiql',
    'tab.playground'
  ];
  List<String> _epTabLabels() => [for (final k in _epTabKeys) tr(k)];

  // Stage 12: the Service detail's four fixed screens (stage 14 fills them).
  static const _serviceTabKeys = [
    'tab.overview',
    'tab.monitor',
    'tab.logs',
    'tab.configure'
  ];
  List<String> _serviceTabLabels() =>
      [for (final k in _serviceTabKeys) tr(k)];

  DdbEndpoint? get _selEndpoint {
    for (final e in _endpoints) {
      if (e.id == _selEndpointId) return e;
    }
    return null;
  }

  Widget _errorScaffold() {
    final t = AppTokens.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline, size: 48, color: t.danger),
            const SizedBox(height: 16),
            Text(tr('home.coreLoadFailed')),
            const SizedBox(height: 8),
            SelectableText('$_loadError', style: TextStyle(color: t.warning)),
            const SizedBox(height: 16),
            Text(
              tr('home.coreBuildHint'),
              textAlign: TextAlign.center,
            ),
          ]),
        ),
      ),
    );
  }

  void _stopAll() {
    final res = _core?.stopAll();
    // Stage 7/12: the typed snapshot names BOTH ID namespaces, so the Restore
    // affordance survives for Services too (never confuses the two kinds).
    final snap = res?.snapshot;
    final ids = [
      ...?snap?.instances,
      ...?snap?.services,
    ];
    setState(() => _stopAllSnapshot = ids);
    _refresh();
    if (ids.isNotEmpty) {
      _toast(
          '${tr('home.stopped')} ${ids.length} ${tr('home.configsSuffix')} — ${tr('home.tapToRestore')}');
    }
  }

  void _restoreAll() {
    final started = _core?.restoreAll().restored ?? [];
    setState(() => _stopAllSnapshot = []);
    _refresh();
    _toast(
        '${tr('home.restored')} ${started.length} ${tr('home.configsSuffix')}');
  }

  void _selectEndpoint(String id) {
    // Stage 12: switching kinds no longer clears the other kind's selection —
    // each entity keeps its own selected ID (12.6). The kind is what routes.
    setState(() {
      if (id != _selEndpointId) {
        _epScreenIndex = 0; // fresh pick resets the endpoint's MidBar screen
      }
      _selEndpointId = id;
      _entityKind = EntityKind.endpoint;
    });
  }

  String _entityQuery = '';

  Future<void> _selectInstance(RedimosConfig c) async {
    if (c.id == _selectedId && _entityKind == EntityKind.instance) return;
    if (await _confirmLeaveEditor()) {
      setState(() {
        _selectedId = c.id;
        _entityKind = EntityKind.instance;
      });
    }
  }

  // Stage 12: Service selection lives entirely in ServicesState (ID-keyed);
  // HomePage only flips the active kind so chrome + detail re-route.
  void _selectService(String id) {
    _svcState?.select(id);
    setState(() => _entityKind = EntityKind.service);
  }

  // Stage 13: create persists a default Service through the core, selects it,
  // and lands directly on its Configure tab so the user can finish the setup
  // (name / engine / port / storage) in place — no modal detour.
  void _newService() {
    final core = _core;
    final svc = _svcState;
    if (core == null || svc == null) return;
    try {
      final usedPorts =
          svc.services.map((s) => s.config.port).toSet();
      var port = 8000;
      while (usedPorts.contains(port)) {
        port++;
      }
      final saved = core.serviceSave(ServiceConfig(
        name: 'new-service',
        engine: ServiceEngine.java,
        port: port,
      ));
      unawaited(svc.refresh());
      _selectService(saved.id);
      svc.selectedTab = 3; // land on Configure (9.5)
    } on ServiceApiException catch (e) {
      _toast('${tr('home.saveFailed')}: ${e.code}');
    } catch (e) {
      _toast('${tr('home.saveFailed')}: $e');
    }
  }

  // Card-level start/stop (mirror of the instance cards): toggle by live
  // state, then let the next snapshot paint the truth.
  Future<void> _serviceStartStop(ServiceInfo s) async {
    final core = _core;
    final svc = _svcState;
    if (core == null || svc == null) return;
    try {
      if (s.runtime.isLive) {
        core.serviceStop(s.id);
      } else {
        core.serviceStart(s.id);
      }
    } on ServiceApiException catch (e) {
      _toast('${s.config.name}: ${e.code}');
    } catch (e) {
      _toast('${s.config.name}: $e');
    }
    unawaited(svc.refresh());
  }

  // Right pane for a selected endpoint: its own tab set (Overview · Browser ·
  // PartiQL · Playground) bound directly to the DynamoDB backend — see
  // EndpointDetailView. Stage 15 (3.1–3.4): client-side views only; an engine
  // process behind the URL belongs to a Service entity and is never inferred
  // here from host/port text.
  Widget _endpointDetail(DdbEndpoint e) => EndpointDetailView(
        key: ValueKey('endpoint-detail-${e.id}'),
        core: _core!,
        endpoint: e,
        screenIndex: _epScreenIndex,
        onEdit: () => _editEndpoint(e),
        browserKey: _epBrowserKey,
      );

  // T11 R4.3/R4.4: edit an endpoint's identity fields and persist the change
  // to every instance config bound to this endpoint (the same tuple), through
  // saveConfig so it lands on disk; sibling instances sharing the tuple are
  // synced one by one.
  Future<void> _editEndpoint(DdbEndpoint e) async {
    final nameCtl = TextEditingController(text: e.name);
    final endpointCtl = TextEditingController(text: e.endpoint);
    final regionCtl = TextEditingController(text: e.region);
    final saved = await showDialog<DdbEndpoint>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit endpoint'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtl,
              decoration:
                  const InputDecoration(labelText: 'Name', isDense: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: endpointCtl,
              decoration: InputDecoration(
                  labelText: tr('ep.ovEndpoint'), isDense: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: regionCtl,
              decoration:
                  InputDecoration(labelText: tr('ep.ovRegion'), isDense: true),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('home.cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(
                ctx,
                DdbEndpoint(
                  id: e.id,
                  name: nameCtl.text.trim(),
                  kind: e.kind,
                  endpoint: endpointCtl.text.trim(),
                  partitionID: e.partitionID,
                  region: regionCtl.text.trim(),
                  accessKeyId: e.accessKeyId,
                  secretKey: e.secretKey,
                  sessionToken: e.sessionToken,
                  source: e.source,
                )),
            child: Text(tr('home.save')),
          ),
        ],
      ),
    );
    nameCtl.dispose();
    endpointCtl.dispose();
    regionCtl.dispose();
    if (saved == null) return;
    // Persist: write the edited tuple into every bound instance config (the
    // endpoint is a dedup view of those tuples, so the write goes through them).
    var synced = 0;
    try {
      for (final c in _configs) {
        if (c.endpoint == e.endpoint &&
            c.region == e.region &&
            c.accessKeyId == e.accessKeyId) {
          final cc = c.copy();
          cc.endpoint = saved.endpoint;
          cc.region = saved.region;
          _core!.saveConfig(cc);
          synced++;
        }
      }
      _reload();
      _toast(
          '${tr('home.saved')} "${saved.name}"${synced > 0 ? ' · $synced' : ''}');
    } catch (err) {
      _toast('${tr('home.saveFailed')}: $err', error: true);
    }
  }

  Widget _detail() {
    // Stage 12: the ACTIVE entity kind routes the detail pane; every kind
    // keeps its own selection, so switching kinds never loses state (12.6).
    if (_entityKind == EntityKind.endpoint) {
      final e = _selEndpoint;
      if (e != null) return _endpointDetail(e);
      return Center(child: Text(tr('config.pick')));
    }
    if (_entityKind == EntityKind.service) return _serviceDetail();
    final c = _selected;
    if (c == null) {
      return Center(child: Text(tr('config.pick')));
    }
    final logsConfigId = c.id.startsWith('unsaved-') ? null : c.id;
    final st = _status[c.id];
    // v2.3 tab order: Browse / Console / Monitor / Logs / Playground /
    // Configure. The TabController stays (it preserves per-tab state and lets
    // flows jump between tabs); only its on-screen chrome moved to the MidBar.
    final screens = <Widget>[
      // browser — Redis key browser over the proxy (ARDM style)
      BrowserPageView(
        key: _browserKey,
        config: c,
        running: st?.isRunning ?? false,
        core: _core!,
      ),
      // console — interactive redis-cli against the running proxy
      CmdConsole(
        key: ValueKey('cmd-${c.id}'),
        host: '127.0.0.1',
        port: c.port,
        auth: c.requirepass.isEmpty ? null : c.requirepass,
        running: st?.isRunning ?? false,
        // v2.3 mockup .inst-crumb shows the instance name, not host:port.
        instanceName: c.name,
        // The console's RESP socket stays up when the DynamoDB backend
        // dies, so no "Reconnecting" state ever appears — commands just
        // start failing. /readyz is what reports backend usability.
        backendDegraded: st != null && st.isRunning && st.healthy && !st.ready,
        // The cause behind that dot, when redimos reports one. Passed
        // whenever present rather than gated on backendDegraded: the
        // console also raises the dot optimistically from an error
        // reply, ahead of the health signal, and that path deserves the
        // cause too once a sample carries it.
        backendError: st?.backendError,
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
      // monitor — the redimos proxy's own telemetry only; the Local
      // DynamoDB engine's dashboard lives on the local endpoint page
      MonitorView(
        status: st,
        cpuHist: _cpuHist[c.id] ?? const [],
        memHist: _memHist[c.id] ?? const [],
        opsHist: _opsHist[c.id] ?? const [],
        embedded: true,
        instanceName: c.name,
      ),
      // logs — the proxy's own log tail (v2.3 screen, src/logs_page.dart)
      LogsPage(
        core: _core!,
        configId: logsConfigId,
      ),
      // playground — run a JS/Go script against the proxy's Redis
      PlaygroundView(
        key: _playgroundKey,
        core: _core!,
        config: c,
        kind: 'redis',
        running: st?.isRunning ?? false,
      ),
      // configure (scrolls its own fields, pins the action bar)
      ConfigEditor(
        key: _editorKey,
        config: c,
        onSave: _save,
        onDelete: _delete,
      ),
    ];
    final activeIndex = _tabs.index;
    return TabBarView(
      controller: _tabs,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var screenIndex = 0; screenIndex < screens.length; screenIndex++)
          ExcludeFocus(
            key: ValueKey('instance-screen-$screenIndex-focus'),
            excluding: screenIndex != activeIndex,
            child: screens[screenIndex],
          ),
      ],
    );
  }

  // Stage 14: the four Service detail tabs are all live. Overview carries the
  // lifecycle actions; Monitor reads the per-ID history ring; Logs requests
  // through ServicesState's generation guard; Configure hosts the CRUD editor.
  Widget _serviceDetail() {
    final svc = _svcState;
    final s = svc?.selected;
    if (s == null) return Center(child: Text(tr('service.pick')));
    return switch (svc!.selectedTab) {
      0 => ServiceOverviewTab(
          key: ValueKey('service-overview-${s.id}'),
          service: s,
          onStart: () => _serviceLifecycle(s, 'start'),
          onStop: () => _serviceLifecycle(s, 'stop'),
          onRestart: () => _serviceLifecycle(s, 'restart'),
        ),
      1 => ServiceMonitorTab(
          key: ValueKey('service-monitor-${s.id}'),
          service: s,
          history: svc.historyOf(s.id),
        ),
      2 => ServiceLogsTab(
          key: ValueKey('service-logs-${s.id}'),
          service: s,
          state: svc,
        ),
      _ => ServiceConfigEditor(
          key: ValueKey('service-configure-${s.id}'),
          service: s,
          peers: svc.services.where((p) => p.id != s.id).toList(),
          core: _core!,
          onSaved: (_) => unawaited(svc.refresh()),
          onDeleted: (id) {
            svc.onServiceDeleted(id);
            unawaited(svc.refresh());
          },
        ),
    };
  }

  // Overview lifecycle actions: typed by op, errors toast in the Service's
  // context (9.8), and the next snapshot paints the resulting state.
  void _serviceLifecycle(ServiceInfo s, String op) {
    final core = _core;
    final svc = _svcState;
    if (core == null || svc == null) return;
    try {
      switch (op) {
        case 'start':
          core.serviceStart(s.id);
        case 'stop':
          core.serviceStop(s.id);
        case 'restart':
          core.serviceRestart(s.id);
      }
    } on ServiceApiException catch (e) {
      _toast('${s.config.name}: ${e.code}');
    } catch (e) {
      _toast('${s.config.name}: $e');
    }
    unawaited(svc.refresh());
  }
}

// ---------------------------------------------------------------------------
// Monitor (per-child graphical monitoring: CPU / memory / uptime / restarts)
// ---------------------------------------------------------------------------

class MonitorView extends StatefulWidget {
  // R5.1: KEYSPACE dashboard section — reserved interface, hidden by default.
  // The per-db key counts (db0:keys=…,expires=…) are only available by issuing
  // INFO keyspace over RESP; a polled dashboard feed needs engine support
  // (a metrics endpoint field). Flip this flag once such a feed exists.
  static const bool _showKeyspaceSection = false;

  final InstanceStatus? status;
  final List<double> cpuHist;
  final List<double> memHist;
  final List<double> opsHist;
  final bool expanded;
  final VoidCallback? onToggle;
  final bool embedded; // headerless, always-shown tiles (for the tab layout)
  final String instanceName; // the config's name — for the mockup page headline
  const MonitorView({
    super.key,
    required this.status,
    required this.cpuHist,
    required this.memHist,
    required this.opsHist,
    this.expanded = true,
    this.onToggle,
    this.embedded = false,
    this.instanceName = '',
  });

  @override
  State<MonitorView> createState() => _MonitorViewState();
}

class _MonitorViewState extends State<MonitorView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // UNREACHABLE: only the embedded==false branch of build() calls this, and the
  // sole MonitorView construction passes embedded: true. Its Latency/Health tiles
  // are stale duplicates — the live grid is _dashboard. Kept (not deleted) so the
  // collapsible non-embedded layout still compiles; edit _dashboard, not this.
  Widget _tiles(BuildContext context, InstanceStatus? st, bool running) {
    final tokens = AppTokens.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        SparkTile(
          label: tr('home.cpu'),
          value: running ? '${st!.cpuPercent.toStringAsFixed(1)} %' : '—',
          data: widget.cpuHist,
          color: tokens.accent,
        ),
        SparkTile(
          label: tr('home.memory'),
          value: running ? '${(st!.memBytes / (1024 * 1024)).round()} MB' : '—',
          data: widget.memHist,
          color: tokens.success,
        ),
        SparkTile(
          label: tr('home.opsPerSec'),
          value:
              running && st!.metricsOk ? st.opsPerSec.toStringAsFixed(0) : '—',
          data: widget.opsHist,
          color: tokens.warning,
        ),
        InfoTile(
            label: tr('home.uptime'),
            value: running ? fmtUptime(st!.uptimeSec) : '—'),
        InfoTile(label: tr('home.restarts'), value: '${st?.restarts ?? 0}'),
        InfoTile(label: tr('home.port'), value: running ? '${st!.port}' : '—'),
        InfoTile(
            label: tr('home.engine'),
            value: (st?.runMode ?? 'native') == 'docker'
                ? 'Docker'
                : tr('home.native')),
        InfoTile(
            label: tr('home.autoRestartLabel'),
            value: (st?.autoRestart ?? false) ? tr('home.on') : tr('home.off')),
        // ── redimos /metrics ───────────────────────────────
        InfoTile(
            label: tr('home.latency'),
            value: running && st!.metricsOk
                ? '${st.avgLatencyMs.toStringAsFixed(2)} ms'
                : '—'),
        InfoTile(
            label: tr('home.throttled'),
            value: running && st!.metricsOk ? '${st.throttled}' : '—'),
        InfoTile(
            label: tr('home.health'),
            value: !running || !st!.metricsOk
                ? '—'
                : st.healthy
                    ? (st.ready ? tr('home.ready') : tr('home.healthy'))
                    : tr('home.down')),
      ],
    );
  }

  // The longest tile value on screen — the proxy's own Engine tile value
  // ("Docker" / the native label). With the Local DynamoDB section gone from
  // this view (its dashboard now lives on the local endpoint page), the proxy
  // engine label is the fit reference every tile shares so all values render
  // at one identical, width-adaptive size.
  String get _fitRef => (widget.status?.runMode ?? 'native') == 'docker'
      ? 'Docker'
      : tr('home.native');

  // Thousands-grouped integer (mockup "1,208") for the OPS/S spark value.
  static String _fmtInt(int v) {
    final s = v.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  // Dashboard layout for the tab (v2.3/v2.4 mockup): REDIMOS spark cards with
  // footers, INSTANCE as a 4-column info-tile grid, KEYSPACE held behind the
  // R5.1 interface flag.
  Widget _dashboard(BuildContext context, InstanceStatus? st, bool running) {
    final t = AppTokens.of(context);
    // Mockup spark colours come from the theme tokens: CPU=accent, MEMORY=
    // success, OPS=warning.
    final sparkAccent = t.accent;
    final sparkSuccess = t.success;
    final sparkWarning = t.warning;
    Widget spark(String label, String value, List<double> data, Color color,
            {String? footer}) =>
        SparkTile(
            label: label,
            value: value,
            data: data,
            color: color,
            width: null,
            sparkHeight: 52,
            footer: footer);
    // Semantic value colours for the two health-ish tiles (mockup .it-value.ok).
    final okGreen = t.success;
    final statusColor = running ? okGreen : t.danger;
    final healthValue = !running || !st!.metricsOk
        ? '—'
        : st.healthy
            ? (st.ready ? tr('home.ready') : tr('home.healthy'))
            : tr('home.down');
    final healthColor =
        healthValue == '—' ? null : (st!.healthy ? okGreen : t.danger);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Mockup monitor head: ONE section-head (hairline rule via
        // sectionHeader) titled "REDIMOS · <INSTANCE-NAME>" — the old plain
        // Text eyebrow above a separate REDIMOS header drew two bands.
        sectionHeader(
            context,
            Icons.dns,
            widget.instanceName.isEmpty
                ? 'REDIMOS'
                : 'REDIMOS · ${widget.instanceName.toUpperCase()}',
            badge: (st?.adopted ?? false) ? tr('home.adopted') : null),
        const SizedBox(height: 13), // head→spark-grid gap (probe-aligned)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: spark(
                    tr('home.cpu'),
                    running ? '${st!.cpuPercent.toStringAsFixed(1)}%' : '—',
                    widget.cpuHist,
                    sparkAccent,
                    footer: '-15 min · now')),
            const SizedBox(width: 12),
            Expanded(
                child: spark(
                    tr('home.memory'),
                    running
                        ? '${(st!.memBytes / (1024 * 1024)).round()} MB'
                        : '—',
                    widget.memHist,
                    sparkSuccess,
                    footer: 'maxmemory 2 GB · 20.6% used')),
            const SizedBox(width: 12),
            Expanded(
                child: spark(
                    tr('home.opsPerSec'),
                    running && st!.metricsOk
                        ? _fmtInt(st.opsPerSec.round())
                        : '—',
                    widget.opsHist,
                    sparkWarning,
                    footer: 'reads 74% · writes 26%')),
          ]),
        ),
        const SizedBox(height: 16), // .monitor-wrap gap:16
        sectionHeader(context, Icons.info_outline, 'INSTANCE'),
        const SizedBox(height: 16),
        // 4-column grid (mockup .tile-grid). The real model exposes 7 INSTANCE
        // metrics (no live "Clients" count), so the grid wraps 4 + 3. Every
        // tile shares one fit reference so all values render at one size.
        tileGrid([
          InfoTile(
              label: tr('home.uptime'),
              fitReference: _fitRef,
              value: running ? fmtUptime(st!.uptimeSec) : '—'),
          InfoTile(
              label: tr('home.restarts'),
              fitReference: _fitRef,
              value: '${st?.restarts ?? 0}'),
          InfoTile(
              label: tr('home.latency'),
              fitReference: _fitRef,
              // Mockup .it-value "0.4 ms" — one decimal, no trailing zeros.
              value: running && st!.metricsOk
                  ? '${(st.avgLatencyMs * 10).round() / 10} ms'
                  : '—'),
          InfoTile(
              label: tr('home.port'),
              fitReference: _fitRef,
              value: running ? '${st!.port}' : '—'),
          InfoTile(
              label: tr('home.status'),
              fitReference: _fitRef,
              valueColor: statusColor,
              value: running ? tr('home.running') : (st?.status ?? 'stopped')),
          InfoTile(
              label: tr('home.health'),
              fitReference: _fitRef,
              valueColor: healthColor,
              value: healthValue),
          InfoTile(
              label: tr('home.engine'), fitReference: _fitRef, value: _fitRef),
        ]),
        // R5.1 KEYSPACE section: the per-db key counts live behind the Go
        // engine's INFO keyspace reply (already reachable via Console), but a
        // polled dashboard feed needs engine support. Interface is reserved
        // behind this flag; flip it once a feed exists.
        if (MonitorView._showKeyspaceSection) ...[
          const SizedBox(height: 20),
          sectionHeader(context, Icons.key_outlined, 'KEYSPACE'),
          const SizedBox(height: 12),
          // _keyspaceTiles(st) — reserved.
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final st = widget.status;
    final running = st?.isRunning ?? false;
    if (widget.embedded) {
      if (st == null) {
        return CodexStateShell(
          key: const ValueKey('monitor-empty-state'),
          state: CodexContentState.empty,
          message: tr('fmt.noData'),
          icon: const Icon(Icons.insights_outlined, size: 22),
          content: const SizedBox.shrink(),
          bodyPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        );
      }
      return SingleChildScrollView(
        key: ValueKey('monitor-scroll-${st.id}'),
        // Mockup .monitor-wrap: padding 18px 22px (pixel-fidelity-v23 CP 9.x).
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
        child: _dashboard(context, st, running),
      );
    }

    final tokens = AppTokens.of(context);
    return CodexSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            key: const ValueKey('monitor-toggle-anchor'),
            color: tokens.panel2,
            child: InkWell(
              onTap: widget.onToggle,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  Icon(
                    widget.expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    size: 18,
                    color: tokens.text2,
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.insights, size: 16, color: tokens.accent),
                  const SizedBox(width: 8),
                  Text(
                    tr('home.monitor'),
                    style: Ts.style(
                      size: Ts.md,
                      weight: FontWeight.w600,
                      color: tokens.text,
                    ),
                  ),
                  const Spacer(),
                  if (st != null)
                    Text(
                      running
                          ? '${st.cpuPercent.toStringAsFixed(1)}% · ${(st.memBytes / (1024 * 1024)).round()}MB'
                              '${st.metricsOk ? " · ${st.opsPerSec.toStringAsFixed(0)} ops/s" : ""}'
                              '${st.restarts > 0 ? " · ↻${st.restarts}" : ""}'
                          : st.status,
                      style: Ts.style(
                        size: Ts.xs,
                        color: tokens.text3,
                        monoFont: true,
                        tabularNums: true,
                      ),
                    ),
                ]),
              ),
            ),
          ),
          if (widget.expanded) ...[
            const CodexDivider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
              child: _tiles(context, st, running),
            ),
          ],
        ],
      ),
    );
  }
}
