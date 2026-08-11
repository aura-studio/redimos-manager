// The "Browser" tab — an Another-Redis-Desktop-Manager-style key browser wired
// straight to the running redimos proxy's RESP port (127.0.0.1:<config port>).
//
// Left: glob search, namespace tree / flat toggle, SCAN pagination (load more /
// load all), multi-select batch delete, per-key and per-folder context menus.
// Right: a multi-tab key workspace; each tab is one open key with the five type
// editors (String / Hash / List / Set / ZSet), all with in-key pagination so a
// large key never loads at once, an in-key keyword filter, TTL, and writes.
//
// Connection management, CLI, and the INFO dashboard are intentionally left out
// (covered by the config list, the Cmd tab, and the Monitor tab). Key names are
// read-only because redimos rejects RENAME.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format_viewer.dart';
import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'resp_client.dart';
import 'cli_drawer.dart';
import 'ui_tokens.dart';

/// Rows loaded so far and the cursor to fetch more. One open key = one tab.
class _KeyTab {
  final String key;
  String type = '';
  int ttl = -1;
  bool loading = true;
  String? error;
  // The connection generation this tab's data was loaded under. If the proxy
  // drops and reconnects (e.g. a table recreate under us), this goes stale vs
  // _connGen and any write is refused so we can't resurrect deleted values.
  int loadGen = -1;

  // string
  final TextEditingController strCtrl = TextEditingController();
  String strFormat = 'Text';
  // The string value's EXACT bytes (binary-safe), for the format viewer's
  // decoders. Null until loaded.
  Uint8List? strBytes;

  // inline TTL editor (ARDM-style: TTL | <input> | reset | apply)
  final TextEditingController ttlCtrl = TextEditingController();

  // collections — each row is [a, b]:
  //   hash=(field,value)  list=(absIndex,value)  set=(member,'')  zset=(member,score)
  final List<List<String>> rows = [];
  int total = 0;
  String cursor = '0'; // hash/set: *SCAN cursor. list/zset: unused (index = rows.length)
  bool hasMore = false;
  bool loadingMore = false;
  bool mutating = false; // a write is in flight — freeze row edit/delete (positional
                         // list delete would drift if a second op raced it)
  String filter = '';
  bool desc = true; // zset display order — ARDM defaults to DESC
  int? sortCol; // 0 = first data column, 1 = second; null = server order
  bool sortAsc = true;

  _KeyTab(this.key);
  void dispose() {
    strCtrl.dispose();
    ttlCtrl.dispose();
  }
}

// Denser theme for this data tab — smaller controls / tighter tap targets.
ThemeData _denseTabTheme(BuildContext context) => Theme.of(context).copyWith(
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

class BrowserPageView extends StatefulWidget {
  final RedimosConfig config;
  final bool running;
  final NativeCore core;
  const BrowserPageView(
      {super.key, required this.config, required this.running, required this.core});

  @override
  State<BrowserPageView> createState() => _BrowserPageViewState();
}

class _BrowserPageViewState extends State<BrowserPageView>
    with AutomaticKeepAliveClientMixin {
  static const int _pageSize = 200;

  RedisClient? _client;
  bool _connecting = false;
  String? _connError;
  Timer? _reconnect;
  int _connGen = 0; // bumped on disconnect/config-change so a stale in-flight connect bails
  int _delSeq = 0; // uniquifier for positional list-delete sentinels

  // left panel
  final _search = TextEditingController();
  bool _tree = true;
  int _db = 0;
  final _keys = <String>[];
  String _cursor = '0';
  bool _scanning = false;
  bool _scanDone = false;

  // multi-select
  bool _selectMode = false;
  final _checked = <String>{};

  // custom value formatters (persisted natively; shared by every FormatViewer)
  List<CustomFormatter> _formatters = [];

  // right panel — multi-tab key workspace
  final _tabs = <_KeyTab>[];
  int _active = -1;

  String? get _selected => _active >= 0 && _active < _tabs.length ? _tabs[_active].key : null;
  _KeyTab? get _activeTab => _active >= 0 && _active < _tabs.length ? _tabs[_active] : null;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _formatters = widget.core.getFormatters();
    if (widget.running) _connect();
  }

  /// Open the custom-formatter manager and adopt the updated list app-wide.
  Future<List<CustomFormatter>?> _manageFormatters() async {
    final updated = await showCustomFormatterManager(context, widget.core);
    if (updated != null && mounted) setState(() => _formatters = updated);
    return updated ?? _formatters;
  }

  @override
  void didUpdateWidget(BrowserPageView old) {
    super.didUpdateWidget(old);
    if (old.config.id != widget.config.id || old.config.port != widget.config.port) {
      _disconnect();
      _resetAll();
      if (widget.running) _connect();
    } else if (widget.running && !old.running) {
      _connect();
    } else if (!widget.running && old.running) {
      _disconnect();
    }
  }

  @override
  void dispose() {
    _reconnect?.cancel();
    _client?.close();
    _search.dispose();
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }

  // ---- connection ----

  Future<void> _connect() async {
    if (_connecting || (_client?.connected ?? false)) return;
    final gen = ++_connGen;
    setState(() {
      _connecting = true;
      _connError = null;
    });
    final c = RedisClient('127.0.0.1', widget.config.port,
        auth: widget.config.requirepass.isEmpty ? null : widget.config.requirepass);
    c.onClosed = (_) {
      if (!mounted || gen != _connGen) return;
      setState(() => _client = null);
      _scheduleReconnect();
    };
    try {
      await c.connect();
      if (widget.config.multiDb && _db > 0) await c.select(_db);
      // A newer connect (config switch / disconnect) superseded this one — drop it.
      if (gen != _connGen || !mounted) {
        c.close();
        return;
      }
      setState(() {
        _client = c;
        _connecting = false;
      });
      _reload();
      // A reconnect after a drop (the proxy was restarted, e.g. a table recreate)
      // leaves open key-tabs and any multi-select holding pre-restart data. Refresh
      // the tabs against the live server and drop stale selection so nothing stale
      // can be written or batch-deleted. No-op on a first / config-switch connect:
      // _tabs is empty and selection is already cleared by _resetAll.
      for (final t in List<_KeyTab>.of(_tabs)) {
        _loadTab(t);
      }
      if (_selectMode || _checked.isNotEmpty) {
        setState(() {
          _selectMode = false;
          _checked.clear();
        });
      }
    } catch (e) {
      if (gen != _connGen || !mounted) {
        c.close();
        return;
      }
      setState(() {
        _connecting = false;
        _connError = '$e';
      });
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnect?.cancel();
    if (!mounted || !widget.running) return;
    _reconnect = Timer(const Duration(seconds: 2), () {
      if (mounted && widget.running && !(_client?.connected ?? false)) _connect();
    });
  }

  void _disconnect() {
    _connGen++; // supersede any in-flight _connect and clear the connecting latch
    _connecting = false;
    _reconnect?.cancel();
    _client?.close();
    if (mounted) setState(() => _client = null);
  }

  void _resetAll() {
    _resetLeft();
    for (final t in _tabs) {
      t.dispose();
    }
    _tabs.clear();
    _active = -1;
    _selectMode = false;
    _checked.clear();
  }

  // ---- left: key scan ----

  void _resetLeft() {
    _keys.clear();
    _cursor = '0';
    _scanDone = false;
  }

  Future<void> _reload() async {
    _resetLeft();
    await _scanMore();
  }

  Future<void> _scanMore() async {
    final c = _client;
    if (c == null || _scanning) return;
    setState(() => _scanning = true);
    final match = _search.text.trim().isEmpty ? '*' : _search.text.trim();
    try {
      final page = await c.scan(_cursor, match: match, count: 300);
      if (!mounted) return;
      setState(() {
        _keys.addAll(page.items);
        _cursor = page.cursor;
        _scanDone = page.done;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _connError = '$e';
      });
    }
  }

  Future<void> _loadAll() async {
    var guard = 0;
    while (!_scanDone && guard++ < 1000) {
      await _scanMore();
      if (!mounted) return;
    }
  }

  // ---- open / load a key tab ----

  void _openKey(String key) {
    final i = _tabs.indexWhere((t) => t.key == key);
    if (i >= 0) {
      setState(() => _active = i);
      return;
    }
    final t = _KeyTab(key);
    setState(() {
      _tabs.add(t);
      _active = _tabs.length - 1;
    });
    _loadTab(t);
  }

  void _closeTab(int i) {
    final t = _tabs[i];
    t.dispose();
    setState(() {
      _tabs.removeAt(i);
      if (_tabs.isEmpty) {
        _active = -1;
      } else if (_active >= _tabs.length) {
        _active = _tabs.length - 1;
      } else if (_active > i) {
        _active--;
      }
    });
  }

  Future<void> _loadTab(_KeyTab t) async {
    final c = _client;
    if (c == null) return;
    setState(() {
      t.loading = true;
      t.error = null;
      t.rows.clear();
      t.cursor = '0';
      t.hasMore = false;
      t.loadGen = _connGen; // data is fresh as of the current connection
    });
    try {
      final type = await c.type(t.key);
      final ttl = await c.ttl(t.key);
      t.type = type;
      t.ttl = ttl;
      t.ttlCtrl.text = '$ttl';
      switch (type) {
        case 'string':
          final bytes = await c.getBytes(t.key);
          final v = (await c.get(t.key)) ?? '';
          if (!_tabs.contains(t)) return; // tab closed mid-load → strCtrl disposed
          t.strCtrl.text = v;
          t.strBytes = bytes ?? Uint8List(0);
          t.strFormat = 'Text';
        case 'hash':
          t.total = await c.hlen(t.key);
          await _hashPage(t);
        case 'set':
          t.total = await c.scard(t.key);
          await _setPage(t);
        case 'list':
          t.total = await c.llen(t.key);
          await _listPage(t);
        case 'zset':
          t.total = await c.zcard(t.key);
          await _zsetPage(t);
        default: // 'none' — the key no longer exists (e.g. removed by a recreate)
          if (!_tabs.contains(t)) return;
          t.strCtrl.text = '';
          t.error = tr('br.keyNoLongerExists');
      }
      // Tab may have been closed (and its controller disposed) mid-load.
      if (!mounted || !_tabs.contains(t)) return;
      setState(() => t.loading = false);
    } catch (e) {
      if (!mounted || !_tabs.contains(t)) return;
      setState(() {
        t.loading = false;
        t.error = '$e';
      });
    }
  }

  Future<void> _hashPage(_KeyTab t) async {
    final before = t.rows.length;
    do {
      final (cur, pairs) = await _client!.hscan(t.key, t.cursor, count: _pageSize);
      t.cursor = cur;
      for (final p in pairs) {
        t.rows.add([p.$1, p.$2]);
      }
    } while (t.rows.length == before && t.cursor != '0');
    t.hasMore = t.cursor != '0';
  }

  Future<void> _setPage(_KeyTab t) async {
    final before = t.rows.length;
    do {
      final (cur, items) = await _client!.sscan(t.key, t.cursor, count: _pageSize);
      t.cursor = cur;
      for (final m in items) {
        t.rows.add([m, '']);
      }
    } while (t.rows.length == before && t.cursor != '0');
    t.hasMore = t.cursor != '0';
  }

  Future<void> _listPage(_KeyTab t) async {
    final start = t.rows.length;
    final items = await _client!.lrange(t.key, start, start + _pageSize - 1);
    for (var i = 0; i < items.length; i++) {
      t.rows.add(['${start + i}', items[i]]);
    }
    // A short page means we hit the end; don't trust a snapshot `total` that a
    // concurrent writer may have changed (else Load more can stick or hide data).
    t.hasMore = items.length == _pageSize;
  }

  Future<void> _zsetPage(_KeyTab t) async {
    final start = t.rows.length;
    final pairs = t.desc
        ? await _client!.zrevrange(t.key, start, start + _pageSize - 1)
        : await _client!.zrange(t.key, start, start + _pageSize - 1);
    for (final p in pairs) {
      t.rows.add([p.$1, p.$2]); // (member, score)
    }
    t.hasMore = pairs.length == _pageSize;
  }

  /// Flip a zset tab between DESC/ASC and reload its window from scratch.
  Future<void> _setZsetOrder(_KeyTab t, bool desc) async {
    if (t.desc == desc) return;
    t.desc = desc;
    await _loadTab(t);
  }

  Future<void> _loadMoreRows(_KeyTab t) async {
    if (t.loadingMore || !t.hasMore) return;
    setState(() => t.loadingMore = true);
    try {
      switch (t.type) {
        case 'hash':
          await _hashPage(t);
        case 'set':
          await _setPage(t);
        case 'list':
          await _listPage(t);
        case 'zset':
          await _zsetPage(t);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    if (mounted) setState(() => t.loadingMore = false);
  }

  Future<void> _refreshTab() async {
    final t = _activeTab;
    if (t != null) await _loadTab(t);
  }

  /// Run a write, then reload the *tab it was issued from* (captured now, so a
  /// tab switch during the await doesn't refresh — and clobber — the wrong tab).
  /// Marks the tab `mutating` for the duration so a second row edit/delete can't
  /// race (a positional list delete would target a stale, shifted index).
  Future<void> _guard(Future<void> Function() op) async {
    final t = _activeTab;
    // If the proxy dropped and reconnected under us (a table recreate restarts it),
    // this tab's cached values predate the current connection. Refuse the write —
    // issuing it would resurrect stale data into a possibly-emptied table — and
    // reload the tab against the live server instead.
    if (t != null && t.loadGen != _connGen) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('br.reconnectedReloaded'))));
      }
      if (_tabs.contains(t)) await _loadTab(t);
      return;
    }
    if (t != null && mounted) setState(() => t.mutating = true);
    try {
      await op();
      if (t != null && _tabs.contains(t)) await _loadTab(t);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (t != null && mounted) setState(() => t.mutating = false);
    }
  }

  /// Delete a list element by absolute index (LREM-by-value would delete the
  /// first equal element, not the row the user clicked). Tag the slot with a
  /// unique sentinel then remove that sentinel.
  Future<void> _lremAt(String key, int index) async {
    final sentinel = '__redimos_rmdel_${_delSeq++}_${DateTime.now().microsecondsSinceEpoch}__';
    await _client!.lset(key, index, sentinel);
    await _client!.lrem(key, 1, sentinel);
  }

  Future<void> _copy(String text, [String? label]) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(label ?? tr('br.copied')), duration: const Duration(milliseconds: 900)),
      );
    }
  }

  // ---- copy-as-command (ARDM parity: row </> and header </>) ----

  /// Double-quote an argument the way ARDM's "Copy as command" does.
  String _cq(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// The redis command recreating ONE row of a collection key.
  String _rowCommand(_KeyTab t, List<String> row) => switch (t.type) {
        'hash' => 'HSET ${_cq(t.key)} ${_cq(row[0])} ${_cq(row[1])}',
        'list' => 'RPUSH ${_cq(t.key)} ${_cq(row[1])}',
        'set' => 'SADD ${_cq(t.key)} ${_cq(row[0])}',
        'zset' => 'ZADD ${_cq(t.key)} ${row[1]} ${_cq(row[0])}', // score unquoted
        _ => '',
      };

  /// The redis command recreating the whole key from its loaded rows, in the
  /// current display order — same output as ARDM's blue header </> button.
  String _keyCommand(_KeyTab t) => switch (t.type) {
        'string' => 'SET ${_cq(t.key)} ${_cq(t.strCtrl.text)}',
        'hash' => 'HSET ${_cq(t.key)} ${t.rows.map((r) => '${_cq(r[0])} ${_cq(r[1])}').join(' ')}',
        'list' => 'RPUSH ${_cq(t.key)} ${t.rows.map((r) => _cq(r[1])).join(' ')}',
        'set' => 'SADD ${_cq(t.key)} ${t.rows.map((r) => _cq(r[0])).join(' ')}',
        'zset' => 'ZADD ${_cq(t.key)} ${t.rows.map((r) => '${r[1]} ${_cq(r[0])}').join(' ')}',
        _ => '',
      };

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.running) {
      return _center(Icons.play_circle_outline, tr('br.instanceNotRunning'),
          tr('br.startToBrowse'));
    }
    if (_client == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 34, height: 34, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 16),
          Text(_connError ?? tr('br.connecting')),
          Text('127.0.0.1:${widget.config.port}',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      );
    }
    return Theme(
      data: _denseTabTheme(context),
      child: Column(children: [
        Expanded(
          child: Row(children: [
            // Mockup .sidebar: elev-side soft right-edge shadow over the border.
            Container(
              width: Dim.sidebarW,
              decoration: BoxDecoration(
                boxShadow: Depth.elevSide(Theme.of(context).brightness),
              ),
              child: _leftPanel(),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _rightPanel()),
          ]),
        ),
        // v2.3 CLI drawer: collapsible RESP console pinned to the Browse floor.
        CliDrawer(host: '127.0.0.1', port: widget.config.port),
      ]),
    );
  }

  // ---- left panel ----

  Widget _leftPanel() {
    final tok = AppTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Mockup .filter-row: DB f-select + search box on ONE row.
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Row(children: [
          _dbSelect(tok),
          const SizedBox(width: 6),
          Expanded(child: _searchBox(tok)),
        ]),
      ),
      // The mockup's ＋ New Key lives in the MidBar mend, not the sidebar —
      // the MidBar CTA bridge (startCreateKey → _newKeyDialog) covers it, so
      // the sidebar keeps the design's filter-row → side-tools rhythm.
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          // Mockup .side-tools .count: mono, 600 + tabular-nums (v2.4).
          Text('${_keys.length} ${tr('br.keysUnit')}${_scanDone ? '' : '+'}',
              style: Ts.style(size: Ts.sm, weight: FontWeight.w600, color: tok.text2,
                  monoFont: true, tabularNums: true)),
          const Spacer(),
          // Mockup .seg: segmented 树/平铺 control.
          _viewSeg(tok),
          const SizedBox(width: 4),
          _sideToolBtn(
            tooltip: _selectMode ? tr('br.exitSelect') : tr('br.selectMultiple'),
            icon: _selectMode ? Icons.check_box : Icons.check_box_outlined,
            on: _selectMode,
            tok: tok,
            onTap: () => setState(() {
              _selectMode = !_selectMode;
              if (!_selectMode) _checked.clear();
            }),
          ),
          _sideToolBtn(
            tooltip: tr('br.refresh'),
            icon: Icons.refresh,
            on: false,
            tok: tok,
            onTap: _reload,
          ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: _keys.isEmpty
            ? Center(
                child: Text(_scanning ? tr('br.scanning') : tr('br.noKeys'),
                    style: const TextStyle(color: Colors.grey)))
            : ListView(children: _tree ? _treeNodes() : _flatNodes()),
      ),
      if (_selectMode && _checked.isNotEmpty)
        Container(
          color: Theme.of(context).colorScheme.errorContainer,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Text('${_checked.length} ${tr('br.selected')}',
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
            const Spacer(),
            TextButton(
              onPressed: () => setState(_checked.clear),
              child: Text(tr('br.clear')),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: _batchDelete,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: Text(tr('br.delete')),
            ),
          ]),
        ),
      // Mockup .side-foot: two 26px outlined abtn chips; Load all keeps the
      // outlined look with danger text + danger-tinted border (not a solid fill).
      if (!_scanDone)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          child: Row(children: [
            Expanded(
              child: _sideFootBtn(
                tok,
                label: _scanning ? null : tr('br.loadMore'),
                onTap: _scanning ? null : _scanMore,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _sideFootBtn(
                tok,
                label: _scanning ? null : tr('br.loadAll'),
                danger: true,
                onTap: _scanning ? null : _loadAllConfirm,
              ),
            ),
          ]),
        ),
    ]);
  }

  // Mockup .side-foot .abtn: 26px-tall outlined chip; .load-all is danger text
  // + 30%-danger border, still outlined.
  Widget _sideFootBtn(AppTokens tok,
      {String? label, bool danger = false, VoidCallback? onTap}) {
    final color = danger ? tok.danger : tok.text2;
    return InkWell(
      borderRadius: BorderRadius.circular(Dim.radiusS),
      onTap: onTap,
      child: Container(
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tok.panel,
          borderRadius: BorderRadius.circular(Dim.radiusS),
          border: Border.all(
              color: danger ? tok.danger.withValues(alpha: 0.35) : tok.border),
        ),
        child: label == null
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: color))
            : Text(label,
                style: Ts.style(size: Ts.md, weight: FontWeight.w500, color: color)),
      ),
    );
  }

  // Mockup .seg: 26px segmented control for tree/flat.
  Widget _viewSeg(AppTokens tok) {
    Widget segBtn({required IconData icon, required bool on, required VoidCallback onTap, required String tooltip}) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: 30,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? tok.selection : Colors.transparent),
            child: Icon(icon, size: 15, color: on ? tok.accent : tok.text3),
          ),
        ),
      );
    }

    return Container(
      height: 26,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Dim.radiusS),
        border: Border.all(color: tok.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        segBtn(
            icon: Icons.account_tree,
            on: _tree,
            tooltip: tr('br.treeView'),
            onTap: () => setState(() => _tree = true)),
        Container(width: 1, height: 26, color: tok.border),
        segBtn(
            icon: Icons.list,
            on: !_tree,
            tooltip: tr('br.flatView'),
            onTap: () => setState(() => _tree = false)),
      ]),
    );
  }

  // Mockup .ibtn: 26x26 icon button, .on = selection bg + accent.
  Widget _sideToolBtn({
    required String tooltip,
    required IconData icon,
    required bool on,
    required AppTokens tok,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(Dim.radiusS),
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? tok.selection : Colors.transparent,
            borderRadius: BorderRadius.circular(Dim.radiusS),
          ),
          child: Icon(icon, size: 15, color: on ? tok.accent : tok.text2),
        ),
      ),
    );
  }

  // Mockup .f-select: 30px-tall mono 12px bordered chip + caret for the DB picker.
  Widget _dbSelect(AppTokens tok) {
    return Tooltip(
      message: widget.config.multiDb ? tr('br.selectDatabase') : tr('br.multiDbOff'),
      child: Container(
        height: Dim.ctlH,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: tok.panel,
          borderRadius: BorderRadius.circular(Dim.radiusS),
          border: Border.all(color: tok.border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: _db,
            isDense: true,
            icon: Icon(Icons.arrow_drop_down, size: 16, color: tok.text3),
            style: Ts.style(size: Ts.md, color: tok.text2, monoFont: true),
            items: [
              for (var i = 0; i < 16; i++)
                DropdownMenuItem(value: i, child: Text('DB$i')),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _db = v);
              await _client?.select(v);
              if (!mounted) return;
              _reload();
            },
          ),
        ),
      ),
    );
  }

  // Mockup .search: 30px-tall bordered box, search icon + mono 12px input.
  Widget _searchBox(AppTokens tok) {
    return Container(
      height: Dim.ctlH,
      decoration: BoxDecoration(
        color: tok.panel,
        borderRadius: BorderRadius.circular(Dim.radiusS),
        border: Border.all(color: tok.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Icon(Icons.search, size: 15, color: tok.text3),
        const SizedBox(width: 6),
        Expanded(
          child: TextField(
            controller: _search,
            style: Ts.style(size: Ts.md, color: tok.text, monoFont: true),
            decoration: InputDecoration(
              isDense: true,
              // Shield from the theme-level .f-input contentPadding (CP 7.6):
              // the bordered container already provides the mockup .search
              // padding; the inner input is borderless with none of its own.
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              hintText: 'Glob pattern, e.g. user:*',
              hintStyle: Ts.style(size: Ts.md, color: tok.text3, monoFont: true),
            ),
            onSubmitted: (_) => _reload(),
          ),
        ),
        InkWell(
          onTap: _reload,
          child: Icon(Icons.arrow_forward, size: 14, color: tok.text3),
        ),
      ]),
    );
  }

  List<Widget> _flatNodes() => [
        for (final k in _keys) _leaf(k, k, 0),
      ];

  Widget _leaf(String key, String label, int depth) {
    final sel = key == _selected;
    final tok = AppTokens.of(context);
    final type = _tabType(key);
    return InkWell(
      onTap: () {
        if (_selectMode) {
          setState(() => _checked.contains(key) ? _checked.remove(key) : _checked.add(key));
        } else {
          _openKey(key);
        }
      },
      onSecondaryTapDown: (d) => _keyMenu(key, d.globalPosition),
      onLongPress: () => _keyMenu(key, null),
      child: Container(
        height: Dim.rowH,
        // v2.3: selection fill + 2px left accent indicator.
        decoration: BoxDecoration(
          color: sel ? tok.selection : null,
          border: sel ? Border(left: BorderSide(color: tok.accent, width: 2)) : null,
          borderRadius: BorderRadius.circular(Dim.radiusS),
        ),
        // Mockup .node.key: padding-left 24px base, 40px when nested (deep).
        padding: EdgeInsets.only(left: depth > 0 ? 40 : 24, right: 8),
        child: Row(children: [
          if (_selectMode)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                _checked.contains(key) ? Icons.check_box : Icons.check_box_outline_blank,
                size: 15,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          // Mockup: each key row leads with a small 18x18 type badge.
          if (type != null && type.isNotEmpty) ...[
            _leafBadge(tok, type),
            const SizedBox(width: 7),
          ],
          // Mockup .kname: mono 12px, ellipsis.
          Expanded(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: Ts.style(size: Ts.md, color: tok.text, monoFont: true,
                    weight: sel ? FontWeight.w600 : FontWeight.normal)),
          ),
        ]),
      ),
    );
  }

  // Mockup .badge: 18x18 single-letter pastel chip leading each key row.
  Widget _leafBadge(AppTokens tok, String type) {
    final c = tok.typeColors(type);
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.border),
      ),
      child: Text(_leafTypeLetter(type),
          style: Ts.style(size: 10, weight: FontWeight.w700, color: c.fg, monoFont: true)),
    );
  }

  String _leafTypeLetter(String type) => switch (type.toLowerCase()) {
        'string' => 'S',
        'hash' => 'H',
        'list' => 'L',
        'set' => '⊕',
        'zset' => 'Z',
        'stream' => 'T',
        'json' => 'J',
        _ => type.isEmpty ? '?' : type[0].toUpperCase(),
      };

  // Type of an open key's tab (loaded lazily); empty/unknown until its tab loads.
  String? _tabType(String key) {
    for (final t in _tabs) {
      if (t.key == key) return t.type.isEmpty ? null : t.type;
    }
    return null;
  }

  Future<void> _keyMenu(String key, Offset? at) async {
    final pos = at ?? const Offset(200, 200);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, overlay.size.width - pos.dx, 0),
      items: [
        PopupMenuItem(value: 'open', child: Text(tr('br.open'))),
        PopupMenuItem(value: 'copy', child: Text(tr('br.copyName'))),
        PopupMenuItem(value: 'delete', child: Text(tr('br.delete'))),
      ],
    );
    switch (choice) {
      case 'open':
        _openKey(key);
      case 'copy':
        await _copy(key, tr('br.keyNameCopied'));
      case 'delete':
        await _deleteKeys([key]);
    }
  }

  // Namespace tree grouped on ':'.
  List<Widget> _treeNodes() {
    final root = <String, dynamic>{};
    for (final k in _keys) {
      final parts = k.split(':');
      var node = root;
      for (var i = 0; i < parts.length - 1; i++) {
        node = (node.putIfAbsent('/$i/${parts[i]}', () => <String, dynamic>{})) as Map<String, dynamic>;
      }
      node[parts.last] = k; // leaf: value is the full key
    }
    return _renderBranch(root, 0, '');
  }

  List<Widget> _renderBranch(Map<String, dynamic> node, int depth, String prefix) {
    final branches = <String>[];
    final leaves = <MapEntry<String, String>>[];
    node.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        branches.add(k);
      } else {
        leaves.add(MapEntry(k, v as String));
      }
    });
    branches.sort();
    leaves.sort((a, b) => a.key.compareTo(b.key));
    final out = <Widget>[];
    for (final b in branches) {
      final name = b.substring(b.indexOf('/', 1) + 1);
      final child = node[b] as Map<String, dynamic>;
      final childPrefix = prefix.isEmpty ? name : '$prefix:$name';
      out.add(_Folder(
        name: name,
        count: _countLeaves(child),
        depth: depth,
        onDelete: () => _deleteFolder(childPrefix),
        children: _renderBranch(child, depth + 1, childPrefix),
      ));
    }
    for (final l in leaves) {
      // ARDM shows the FULL key name on tree leaves, not just the last segment.
      out.add(_leaf(l.value, l.value, depth));
    }
    return out;
  }

  int _countLeaves(Map<String, dynamic> node) {
    var n = 0;
    node.forEach((_, v) => n += v is Map<String, dynamic> ? _countLeaves(v) : 1);
    return n;
  }

  // ---- right panel: tab strip + active detail ----

  Widget _rightPanel() {
    if (_tabs.isEmpty) {
      return _center(Icons.vpn_key, tr('br.noKeySelected'), tr('br.pickKey'));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _tabStrip(),
      // The active tab's card bottom edge merges into this body band.
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: AppTokens.of(context).panel,
            border: Border(top: BorderSide(color: AppTokens.of(context).border)),
          ),
          child: _detail(_tabs[_active]),
        ),
      ),
    ]);
  }

  // Mockup .ktabs: 30px top-rounded bordered tab cards (active = panel bg +
  // full border, no bottom edge → merges into the detail body), 2px gap, plus a
  // trailing ghost "add" tile.
  Widget _tabStrip() {
    final tok = AppTokens.of(context);
    return Container(
      color: tok.bg,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: SizedBox(
        height: 30,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: _tabs.length + 1, // +1 = the trailing "add" ghost tile
          itemBuilder: (ctx, i) {
            if (i == _tabs.length) return _addTabTile(tok);
            final active = i == _active;
            return Padding(
              padding: const EdgeInsets.only(right: 2),
              child: _ktab(tok, i, active),
            );
          },
        ),
      ),
    );
  }

  Widget _ktab(AppTokens tok, int i, bool active) {
    return InkWell(
      onTap: () => setState(() => _active = i),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(Dim.radiusS)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.only(left: 12, right: 6),
        decoration: BoxDecoration(
          color: active ? tok.panel : Colors.transparent,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(Dim.radiusS)),
          border: Border(
            top: BorderSide(color: active ? tok.border : Colors.transparent),
            left: BorderSide(color: active ? tok.border : Colors.transparent),
            right: BorderSide(color: active ? tok.border : Colors.transparent),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(_tabs[i].key,
                overflow: TextOverflow.ellipsis,
                style: Ts.style(
                    size: Ts.md,
                    monoFont: true,
                    weight: active ? FontWeight.w600 : FontWeight.normal,
                    color: active ? tok.text : tok.text2)),
          ),
          const SizedBox(width: 6),
          // Mockup .ktab-x: a small × glyph, text-3.
          InkWell(
            onTap: () => _closeTab(i),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Text('×',
                  style: Ts.style(size: Ts.md, color: tok.text3, height: 1)),
            ),
          ),
        ]),
      ),
    );
  }

  // Mockup .ktab-add: 30px-wide centred ghost tile at the end of the strip.
  Widget _addTabTile(AppTokens tok) {
    return Tooltip(
      message: tr('br.pickKey'),
      child: InkWell(
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('br.pickKey')), duration: const Duration(seconds: 2))),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Dim.radiusS)),
        child: SizedBox(
          width: 30,
          child: Center(
            child: Text('＋', style: Ts.style(size: Ts.md, color: tok.text3)),
          ),
        ),
      ),
    );
  }

  Widget _detail(_KeyTab t) {
    if (t.loading) return const Center(child: CircularProgressIndicator());
    if (t.error != null) return _center(Icons.error_outline, tr('br.cannotReadKey'), t.error!);
    // The string editor fills the pane height (ARDM's textarea does), so it
    // lays out without an outer scroll; collection tables keep the scroll.
    if (t.type == 'string') {
      return Padding(
        padding: const EdgeInsets.all(11),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _keyHeader(t),
          const SizedBox(height: 16),
          Expanded(child: _stringEditor(t)),
        ]),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(11),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _keyHeader(t),
        const SizedBox(height: 16),
        _typeEditor(t),
      ]),
    );
  }

  // Mockup .keycard: big 20px type badge + inline 16px mono 700 keyname (no
  // surrounding box) + a key-meta row, with TTL group + actions pushed right.
  Widget _keyHeader(_KeyTab t) {
    final tok = AppTokens.of(context);

    void applyTtl() {
      final s = int.tryParse(t.ttlCtrl.text.trim());
      // 0 / blank / negative → persist (EXPIRE key 0 would delete the key).
      _guard(() => s == null || s <= 0 ? _client!.persist(t.key) : _client!.expire(t.key, s));
    }

    return SizedBox(
      // Mockup .keycard renders 47px tall (detail-body pad 14 + keycard 47 +
      // gap 12 lands the valuepane top border at the mockup's y=408).
      height: 47,
      // CP 9.x: inside the home chrome the pane is ~630px wide and the right
      // cluster (TTL group + 3 action chips) overflows by ~13px; tighten the
      // chip padding when narrow. The wide layout (goldens) stays untouched.
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 800;
        return Row(children: [
        _typeBadgeBig(tok, t.type),
        const SizedBox(width: 10),
        // Inline keyname (mockup .keyname): 16px mono 700, no surrounding box.
        Flexible(
          child: Tooltip(
            message: tr('br.renameNotSupported'),
            child: Text(t.key,
                overflow: TextOverflow.ellipsis,
                style: Ts.style(
                    size: 16, weight: FontWeight.w700, color: tok.text,
                    monoFont: true, letterSpacing: -0.1)),
          ),
        ),
        IconButton(
          tooltip: tr('br.copyKeyName'),
          visualDensity: VisualDensity.compact,
          onPressed: () => _copy(t.key, tr('br.keyNameCopied')),
          icon: Icon(Icons.copy, size: 13, color: tok.text3),
        ),
        // Mockup .key-meta: mono labels + 600 mono values, only when loaded.
        if (!t.loading && t.error == null) _keyMeta(tok, t, compact: compact),
        const Spacer(),
        // Mockup .key-actions: TTL group + copy-as-command + Refresh + Delete.
        _ttlGroup(tok, t, applyTtl, compact: compact),
        SizedBox(width: compact ? 4 : 6),
        _abtn(tok,
            label: tr('br.copyAsCommand'),
            icon: Icons.code,
            compact: compact,
            onTap: () => _copy(_keyCommand(t), tr('br.commandCopied'))),
        SizedBox(width: compact ? 4 : 6),
        _abtn(tok,
            label: tr('br.refresh'),
            icon: Icons.refresh,
            compact: compact,
            onTap: _refreshTab),
        SizedBox(width: compact ? 4 : 6),
        _abtn(tok,
            label: tr('br.deleteKey'),
            icon: Icons.delete_outline,
            danger: true,
            compact: compact,
            onTap: () => _deleteKeys([t.key])),
      ]);
      }),
    );
  }

  // Mockup .key-meta: Fields / Size with mono 600 text-2 values.
  Widget _keyMeta(AppTokens tok, _KeyTab t, {bool compact = false}) {
    Widget item(String label, String value) => Padding(
          padding: EdgeInsets.only(left: compact ? 8 : 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('$label ',
                style: Ts.style(size: Ts.md, color: tok.text3)),
            Text(value,
                style: Ts.style(size: Ts.md, weight: FontWeight.w600, color: tok.text2,
                    monoFont: true, tabularNums: true)),
          ]),
        );
    final countLabel = switch (t.type) {
      'hash' => 'Fields',
      'list' || 'set' || 'zset' => 'Members',
      _ => null,
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (countLabel != null) item(countLabel, '${t.total}'),
      if (t.type == 'string' && t.strBytes != null)
        item('Size', _fmtBytes(t.strBytes!.length)),
    ]);
  }

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // Mockup .ttl-group: 26px-tall bordered box, TTL label + 64px mono input +
  // accent Apply.
  Widget _ttlGroup(AppTokens tok, _KeyTab t, VoidCallback applyTtl,
      {bool compact = false}) {
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: tok.panel,
        borderRadius: BorderRadius.circular(Dim.radiusS),
        border: Border.all(color: tok.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('TTL', style: Ts.style(size: Ts.sm, color: tok.text3)),
        const SizedBox(width: 6),
        SizedBox(
          width: compact ? 44 : 56,
          child: TextField(
            controller: t.ttlCtrl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: Ts.style(size: Ts.md, color: tok.text, monoFont: true, tabularNums: true),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 4),
            ),
            onSubmitted: (_) => applyTtl(),
          ),
        ),
        const SizedBox(width: 4),
        InkWell(
          onTap: applyTtl,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Text('Apply',
                style: Ts.style(size: Ts.sm, weight: FontWeight.w600, color: tok.accent)),
          ),
        ),
      ]),
    );
  }

  // Mockup .abtn: 26px-tall outlined chip (12px 500 text-2); .danger keeps the
  // outlined look with danger text + 35% danger border. [compact] (CP 9.x:
  // narrow pane inside the home chrome) tightens the horizontal padding so the
  // keycard head's right cluster fits; the wide layout keeps 11px.
  Widget _abtn(AppTokens tok,
      {required String label, IconData? icon, bool danger = false, bool compact = false, VoidCallback? onTap}) {
    final color = danger ? tok.danger : tok.text2;
    return InkWell(
      borderRadius: BorderRadius.circular(Dim.radiusS),
      onTap: onTap,
      child: Container(
        height: 26,
        padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 11),
        decoration: BoxDecoration(
          color: tok.panel,
          borderRadius: BorderRadius.circular(Dim.radiusS),
          border: Border.all(
              color: danger ? tok.danger.withValues(alpha: 0.35) : tok.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(label, style: Ts.style(size: Ts.md, weight: FontWeight.w500, color: color)),
        ]),
      ),
    );
  }

  // Mockup .badge.big: 20px-tall uppercase mono chip (pastel fill + border).
  Widget _typeBadgeBig(AppTokens tok, String type) {
    final c = tok.typeColors(type);
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.border),
      ),
      child: Text(_typeLabel(type).toUpperCase(),
          style: Ts.style(size: 10, weight: FontWeight.w700, color: c.fg,
              monoFont: true, letterSpacing: 0.8)),
    );
  }

  String _typeLabel(String type) => switch (type) {
        'string' => 'String',
        'hash' => 'Hash',
        'list' => 'List',
        'set' => 'Set',
        'zset' => 'Zset',
        _ => type,
      };

  Widget _typeEditor(_KeyTab t) {
    switch (t.type) {
      case 'string':
        return _stringEditor(t);
      case 'hash':
        return _collectionEditor(t, [tr('br.key'), tr('br.value')],
            onAdd: () => _fieldValueDialog(tr('br.addNewLine'),
                onSubmit: (f, v) => _client!.hset(t.key, f, v)),
            rowEdit: (r) => _fieldValueDialog(tr('br.editLine'),
                field: r[0], value: r[1], fieldLocked: true,
                onSubmit: (f, v) => _client!.hset(t.key, f, v)),
            rowDelete: (r) => _client!.hdel(t.key, r[0]));
      case 'list':
        return _collectionEditor(t, ['#', tr('br.value')], numbered: false,
            onAdd: () => _listAddDialog(t.key),
            rowEdit: (r) => _singleValueDialog(tr('br.editLine'), value: r[1],
                onSubmit: (v) => _client!.lset(t.key, int.parse(r[0]), v)),
            rowDelete: (r) => _lremAt(t.key, int.parse(r[0])));
      case 'set':
        return _collectionEditor(t, [tr('br.member')], singleColumn: true,
            onAdd: () => _singleValueDialog(tr('br.addNewLine'), onSubmit: (v) => _client!.sadd(t.key, v)),
            rowEdit: (r) => _singleValueDialog(tr('br.editLine'), value: r[0],
                onSubmit: (v) async {
                  await _client!.sadd(t.key, v);
                  if (v != r[0]) await _client!.srem(t.key, r[0]);
                }),
            rowDelete: (r) => _client!.srem(t.key, r[0]));
      case 'zset':
        return _collectionEditor(t, [tr('br.score'), tr('br.member')], scoreFirst: true,
            onAdd: () => _scoreMemberDialog(tr('br.addNewLine'),
                onSubmit: (s, m) => _client!.zadd(t.key, s, m)),
            rowEdit: (r) => _scoreMemberDialog(tr('br.editLine'), score: r[1], member: r[0], memberLocked: true,
                onSubmit: (s, m) => _client!.zadd(t.key, s, m)),
            rowDelete: (r) => _client!.zrem(t.key, r[0]));
      default:
        return Text('${tr('br.unsupportedType')}: ${t.type}');
    }
  }

  // -- string -- (ARDM-style format viewer over the value's EXACT bytes, so
  // gzip/msgpack/protobuf/… decode faithfully; Text is the editable format).
  Widget _stringEditor(_KeyTab t) {
    final bytes = t.strBytes ?? Uint8List.fromList(utf8.encode(t.strCtrl.text));
    return FormatViewer(
      key: ValueKey('str-${t.key}'),
      core: widget.core,
      bytes: bytes,
      formatters: _formatters,
      onManage: _manageFormatters,
      redisKey: t.key,
      onSave: (text) => _guard(() => _client!.set(t.key, text)),
    );
  }

  /// Open a read-only format viewer over one collection value's exact bytes.
  /// Used by the row "view" action for hash/list values (binary-safe re-fetch)
  /// and set/zset members (the member text is the value).
  Future<void> _viewValue(_KeyTab t, List<String> row) async {
    Uint8List bytes;
    String field = '', member = '', score = '';
    try {
      switch (t.type) {
        case 'hash':
          field = row[0];
          bytes = (await _client!.hgetBytes(t.key, row[0])) ?? Uint8List(0);
        case 'list':
          bytes = (await _client!.lindexBytes(t.key, int.parse(row[0]))) ?? Uint8List(0);
        case 'set':
          member = row[0];
          bytes = Uint8List.fromList(utf8.encode(row[0]));
        case 'zset':
          member = row[0];
          score = row[1];
          bytes = Uint8List.fromList(utf8.encode(row[0]));
        default:
          bytes = Uint8List.fromList(utf8.encode(row.length > 1 ? row[1] : row[0]));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 720,
          height: 540,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: Text('${tr('br.view')} · ${t.key}${field.isNotEmpty ? ' · $field' : ''}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: tr('br.close'),
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: FormatViewer(
                  core: widget.core,
                  bytes: bytes,
                  formatters: _formatters,
                  onManage: _manageFormatters,
                  redisKey: t.key,
                  field: field,
                  member: member,
                  score: score,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // -- shared collection editor (hash / list / set / zset) --
  // Mockup .valuepane: a bordered card (elev-2 + top highlight) holding a
  // panel-2 head band (eyebrow title + inline filter + ghost add) over a custom
  // table (zebra, mono cells, selected-row accent bar, three-glyph actions).
  Widget _collectionEditor(
    _KeyTab t,
    List<String> columns, {
    required VoidCallback onAdd,
    required void Function(List<String>) rowEdit,
    required Future<void> Function(List<String>) rowDelete,
    bool scoreFirst = false,
    bool numbered = true,
    bool singleColumn = false,
  }) {
    final tok = AppTokens.of(context);
    final brightness = Theme.of(context).brightness;
    final f = t.filter.trim().toLowerCase();
    var visible = f.isEmpty
        ? t.rows
        : t.rows.where((r) => r[0].toLowerCase().contains(f) || r[1].toLowerCase().contains(f)).toList();

    // Column-header sorting over the loaded rows (display column → row slot).
    // zset: col0=score(r[1]) col1=member(r[0]); list (!numbered): the only data
    // column is the value (r[1], r[0] is the absolute index); else r[0]/r[1].
    String cellOf(List<String> r, int col) => scoreFirst
        ? (col == 0 ? r[1] : r[0])
        : (!numbered ? r[1] : (col == 0 ? r[0] : r[1]));
    if (t.sortCol != null) {
      int cmp(List<String> a, List<String> b) {
        final x = cellOf(a, t.sortCol!), y = cellOf(b, t.sortCol!);
        final nx = num.tryParse(x), ny = num.tryParse(y);
        final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
        return t.sortAsc ? c : -c;
      }
      visible = [...visible]..sort(cmp);
    }

    // Data columns: hash Field/Value, list Value, set Member, zset Score/Member.
    final dataCols = numbered ? columns : columns.sublist(1);

    // Keep copy/view for parity but route the three visible actions to
    // edit / copy / delete (mockup .rowact ✎ ⧉ ⌫). View + copy-as-command stay
    // reachable via the key's FormatViewer (string) — collection rows drop them
    // to match the mockup's three-glyph action cell.

    return Stack(children: [
      Container(
        decoration: BoxDecoration(
          color: tok.panel,
          borderRadius: BorderRadius.circular(Dim.radiusM),
          border: Border.all(color: tok.border),
          boxShadow: Depth.elev2(brightness),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Dim.radiusM - 1),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Head band (mockup .valuepane-head): panel-2 + bottom hairline.
            Container(
              decoration: BoxDecoration(
                color: tok.panel2,
                border: Border(bottom: BorderSide(color: tok.hairline)),
              ),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(children: [
                // Mockup .vp-title: 11px 600 uppercase eyebrow.
                Text(_valuePaneTitle(t).toUpperCase(),
                    style: Ts.style(size: Ts.xs, weight: FontWeight.w600,
                        letterSpacing: 0.8, color: tok.text3)),
                const SizedBox(width: 12),
                // zset keeps its DESC/ASC order toggle in the band.
                if (scoreFirst) _zsetOrderSeg(tok, t),
                const Spacer(),
                // Mockup .filter-input: 200px 26px mono 11px.
                SizedBox(
                  width: 200,
                  height: 26,
                  child: TextField(
                    style: Ts.style(size: Ts.xs, color: tok.text, monoFont: true, letterSpacing: 0.6),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: tr('br.keywordSearch').toUpperCase(),
                      hintStyle: Ts.style(size: Ts.xs, color: tok.text3, monoFont: true, letterSpacing: 0.6),
                      filled: true,
                      fillColor: tok.panel,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Dim.radiusS),
                        borderSide: BorderSide(color: tok.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Dim.radiusS),
                        borderSide: BorderSide(color: tok.focus),
                      ),
                    ),
                    onChanged: (v) => setState(() => t.filter = v),
                  ),
                ),
                const SizedBox(width: 8),
                // Mockup .abtn.ghost ＋ Field.
                _ghostAddBtn(tok, onAdd),
              ]),
            ),
            // Table body.
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: Text(t.filter.isEmpty ? tr('br.empty') : tr('br.noMatchInLoadedRows'),
                      style: Ts.style(size: Ts.md, color: tok.text3)),
                ),
              )
            else
              _valueTable(tok, t, visible, dataCols,
                  scoreFirst: scoreFirst, numbered: numbered, singleColumn: singleColumn,
                  disabled: t.mutating, onEdit: rowEdit, onDelete: rowDelete),
            if (t.hasMore)
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: tok.hairline)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _abtn(tok,
                      label: '${tr('br.loadMore')}  (${t.rows.length}/${t.total})',
                      onTap: t.loadingMore ? null : () => _loadMoreRows(t)),
                ),
              ),
            if (f.isNotEmpty && t.hasMore)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(tr('br.filterLoadedOnly'),
                    style: Ts.style(size: Ts.xs, color: tok.text3)),
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
              color: tok.highlight,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(Dim.radiusM - 1)),
            ),
          ),
        ),
      ),
    ]);
  }

  String _valuePaneTitle(_KeyTab t) => switch (t.type) {
        'hash' => 'Value',
        'list' => 'Elements',
        'set' => 'Members',
        'zset' => 'Members',
        _ => 'Value',
      };

  // Mockup .abtn.ghost: dashed-border 26px add chip.
  Widget _ghostAddBtn(AppTokens tok, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(Dim.radiusS),
      onTap: onTap,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: tok.panel,
          borderRadius: BorderRadius.circular(Dim.radiusS),
          border: Border.all(color: tok.border, style: BorderStyle.solid),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add, size: 13, color: tok.text2),
          const SizedBox(width: 4),
          Text(tr('br.addNewLine'),
              style: Ts.style(size: Ts.md, weight: FontWeight.w500, color: tok.text2)),
        ]),
      ),
    );
  }

  Widget _zsetOrderSeg(AppTokens tok, _KeyTab t) {
    return SegmentedButton<bool>(
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: [
        ButtonSegment(value: true, label: Text(tr('br.desc')), icon: const Icon(Icons.arrow_drop_down)),
        ButtonSegment(value: false, label: Text(tr('br.asc')), icon: const Icon(Icons.arrow_drop_up)),
      ],
      selected: {t.desc},
      onSelectionChanged: (s) => _setZsetOrder(t, s.first),
    );
  }

  // Mockup .vtable: sticky uppercase eyebrow header over zebra rows with mono
  // cells, a selected-row accent bar, and a three-glyph action cell.
  Widget _valueTable(
    AppTokens tok,
    _KeyTab t,
    List<List<String>> visible,
    List<String> dataCols, {
    required bool scoreFirst,
    required bool numbered,
    required bool singleColumn,
    required bool disabled,
    required void Function(List<String>) onEdit,
    required Future<void> Function(List<String>) onDelete,
  }) {
    final columns = <_VCol>[
      if (numbered) const _VCol.ln('#'),
      for (var j = 0; j < dataCols.length; j++)
        _VCol.data(dataCols[j], j, pk: j == 0),
      const _VCol.actions(),
    ];

    return LayoutBuilder(
      builder: (ctx, box) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // IntrinsicWidth: the horizontal viewport hands its child an
        // UNBOUNDED width, and a stretch Column under it would force that
        // infinity onto every row (layout crash). IntrinsicWidth resolves a
        // finite tight width = max(rows' natural width, container width), so
        // the table fills the pane and only scrolls when content overflows.
        child: IntrinsicWidth(
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: box.maxWidth),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _vHead(tok, t, columns),
              for (var i = 0; i < visible.length; i++)
                _vRow(tok, t, i, visible[i], columns,
                    scoreFirst: scoreFirst, numbered: numbered, singleColumn: singleColumn,
                    disabled: disabled, onEdit: onEdit, onDelete: onDelete),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _vHead(AppTokens tok, _KeyTab t, List<_VCol> columns) {
    return Container(
      decoration: BoxDecoration(
        color: tok.panel,
        border: Border(bottom: BorderSide(color: tok.border)),
      ),
      child: Row(children: [
        for (final c in columns)
          _vHeadCell(tok, t, c),
      ]),
    );
  }

  Widget _vHeadCell(AppTokens tok, _KeyTab t, _VCol c) {
    // Mockup .vtable thead th: 10.5px 600 uppercase ls .7px text-3, padding 7/12.
    final label = Padding(
      padding: EdgeInsets.only(left: c.isLn ? 0 : 12, right: 12, top: 7, bottom: 7),
      child: Text(c.label.toUpperCase(),
          style: Ts.style(size: 10.5, weight: FontWeight.w600,
              letterSpacing: 0.7, color: tok.text3)),
    );
    final sortable = c.sortCol != null;
    final sorted = sortable && t.sortCol == c.sortCol;
    Widget child = label;
    if (sortable) {
      child = InkWell(
        onTap: () => setState(() {
          if (t.sortCol == c.sortCol) {
            t.sortAsc = !t.sortAsc;
          } else {
            t.sortCol = c.sortCol;
            t.sortAsc = true;
          }
        }),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          label,
          if (sorted)
            Icon(t.sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                size: 11, color: tok.text3),
        ]),
      );
    }
    // Mockup .vtable: .ln 34px, Field .w-180 fixed, Value flex, .w-120 actions.
    if (c.isLn) return SizedBox(width: 34, child: Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.only(right: 8), child: child)));
    if (c.isActions) return SizedBox(width: 120, child: child);
    if (c.pk) return SizedBox(width: 180, child: child);
    return Expanded(child: child);
  }

  Widget _vRow(
    AppTokens tok,
    _KeyTab t,
    int i,
    List<String> row,
    List<_VCol> columns, {
    required bool scoreFirst,
    required bool numbered,
    required bool singleColumn,
    required bool disabled,
    required void Function(List<String>) onEdit,
    required Future<void> Function(List<String>) onDelete,
  }) {
    final cells = scoreFirst
        ? [row[1], row[0]]
        : (singleColumn ? [row[0]] : [row[0], row[1]]);
    final zebra = i.isOdd;
    final rowBg = zebra ? tok.panel2 : tok.panel;
    final valueTextColor = disabled ? tok.text3 : tok.text;

    Widget cellWidget(_VCol c) {
      if (c.isLn) {
        // Mockup .vtable .ln: 34px mono 11px text-3 right-aligned.
        return SizedBox(
          width: 34,
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text('${i + 1}',
                  style: Ts.style(size: Ts.xs, color: tok.text3, monoFont: true, tabularNums: true)),
            ),
          ),
        );
      }
      if (c.isActions) {
        return SizedBox(
          width: 120,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _rowAct(tok, const Icon(Icons.mode_edit_outlined, size: 13), tr('br.edit'),
                  disabled ? null : () => onEdit(row)),
              const SizedBox(width: 4),
              // Tap copies the value; long-press copies the recreating command.
              _rowActCmd(tok, const Icon(Icons.content_copy, size: 13), tr('br.copyValue'),
                  onTap: () => _copy(scoreFirst || singleColumn ? row[0] : row[1], tr('br.valueCopied')),
                  onLongPress: () => _copy(_rowCommand(t, row), tr('br.commandCopied'))),
              const SizedBox(width: 4),
              // Mockup .rowact: ALL three glyphs are text-3 (even delete).
              _rowAct(tok, Text('⌫', style: Ts.style(size: Ts.md, height: 1)), tr('br.delete'),
                  disabled ? null : () => _guard(() => onDelete(row))),
            ]),
          ),
        );
      }
      final text = cells[c.sortCol!];
      // Mockup .vtable .mono cells (+ pk 600 on the first data column). Tapping
      // a value cell opens the read-only format viewer (kept from the old
      // "view" row action — the mockup's three-glyph cell has no view button,
      // so the viewer lives behind the value itself).
      final cell = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: InkWell(
            onTap: () => _viewValue(t, row),
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ts.style(
                    size: Ts.md,
                    color: valueTextColor,
                    monoFont: true,
                    tabularNums: true,
                    weight: c.pk ? FontWeight.w600 : FontWeight.normal)),
          ),
        ),
      );
      // Field/PK column is fixed .w-180 in the mockup; Value stays flex.
      if (c.pk && !singleColumn) return SizedBox(width: 180, child: cell);
      return Expanded(child: cell);
    }

    return Container(
      height: Dim.rowH,
      decoration: BoxDecoration(
        color: rowBg,
        border: Border(bottom: BorderSide(color: tok.hairline)),
      ),
      child: Row(children: [for (final c in columns) cellWidget(c)]),
    );
  }

  // Mockup .rowact: a plain 13px text-3 glyph button (✎/⧉ are Material icons —
  // the literal glyphs are not in Inter and rasterise as tofu bars).
  Widget _rowAct(AppTokens tok, Widget glyph, String tooltip, VoidCallback? onTap) {
    final color = onTap == null ? tok.text3.withValues(alpha: 0.4) : tok.text3;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: IconTheme(
            data: IconThemeData(size: 13, color: color),
            child: DefaultTextStyle(
              style: Ts.style(size: Ts.md, color: color, height: 1),
              child: glyph,
            ),
          ),
        ),
      ),
    );
  }

  // A rowact glyph with a distinct long-press action (copy value vs copy cmd).
  Widget _rowActCmd(AppTokens tok, Widget glyph, String tooltip,
      {VoidCallback? onTap, VoidCallback? onLongPress}) {
    final color = onTap == null ? tok.text3.withValues(alpha: 0.4) : tok.text3;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: IconTheme(
            data: IconThemeData(size: 13, color: color),
            child: DefaultTextStyle(
              style: Ts.style(size: Ts.md, color: color, height: 1),
              child: glyph,
            ),
          ),
        ),
      ),
    );
  }

  // ---- deletes ----

  Future<void> _deleteKeys(List<String> keys) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(keys.length == 1 ? tr('br.deleteKeyQ') : '${tr('br.delete')} ${keys.length} ${tr('br.keysQ')}'),
        content: Text(keys.length == 1
            ? 'Permanently delete "${keys.first}"? This cannot be undone.'
            : '${tr('br.permDelete')} ${keys.length} ${tr('br.keysQCannotUndo')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('br.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('br.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    var failed = 0;
    for (final k in keys) {
      try {
        await _client!.del(k);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      // Remember which tab is active by key — indices shift as we remove tabs
      // before it, so a plain clamp would land on the wrong tab.
      final activeKey = _active >= 0 && _active < _tabs.length ? _tabs[_active].key : null;
      _keys.removeWhere(keys.contains);
      _checked.removeAll(keys);
      for (var i = _tabs.length - 1; i >= 0; i--) {
        if (keys.contains(_tabs[i].key)) {
          _tabs[i].dispose();
          _tabs.removeAt(i);
        }
      }
      _active = _tabs.isEmpty
          ? -1
          : (activeKey == null ? 0 : _tabs.indexWhere((t) => t.key == activeKey));
      if (_active < 0) _active = _tabs.isEmpty ? -1 : 0;
    });
    if (failed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$failed ${tr('br.keysCouldNotDelete')}')));
    }
  }

  Future<void> _batchDelete() => _deleteKeys(_checked.toList());

  Future<void> _deleteFolder(String prefix) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('br.deleteWholeFolder')),
        content: Text(trp('br.deleteFolderBody', {'prefix': prefix})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('br.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('br.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Escape glob metacharacters so a folder like `user[admin]` matches literally
    // (SCAN MATCH is a glob: unescaped `[ ] * ?` would over- or under-match), then
    // belt-and-braces filter on the literal prefix.
    final literal = '$prefix:';
    final matchPrefix = prefix.replaceAllMapped(RegExp(r'[\\*?\[\]^]'), (m) => '\\${m[0]}');
    final toDel = <String>[];
    var cursor = '0';
    var guard = 0;
    try {
      do {
        final page = await _client!.scan(cursor, match: '$matchPrefix:*', count: 500);
        toDel.addAll(page.items.where((k) => k.startsWith(literal)));
        cursor = page.cursor;
      } while (cursor != '0' && guard++ < 1000);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    for (final k in toDel) {
      try {
        await _client!.del(k);
      } catch (_) {}
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('br.deleted')} ${toDel.length} ${tr('br.keyPlural')}')));
    _reload();
  }

  Future<void> _loadAllConfirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('br.loadAllKeysQ')),
        content: Text(tr('br.loadAllWarning')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('br.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('br.loadAll'))),
        ],
      ),
    );
    if (ok == true) await _loadAll();
  }

  // ---- dialogs ----

  // Public bridge so the HomePage-level MidBar "New Key" CTA can open the
  // same dialog the in-page button does (v2.3 chrome lifted the CTA up).
  void startCreateKey() => _newKeyDialog();

  Future<void> _newKeyDialog() async {
    final nameCtrl = TextEditingController();
    final valCtrl = TextEditingController();
    String type = 'string';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: Text(tr('br.newKey')),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('br.keyName'), border: const OutlineInputBorder())),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: InputDecoration(labelText: tr('br.type'), border: const OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'string', child: Text('String')),
                  DropdownMenuItem(value: 'hash', child: Text('Hash')),
                  DropdownMenuItem(value: 'list', child: Text('List')),
                  DropdownMenuItem(value: 'set', child: Text('Set')),
                  DropdownMenuItem(value: 'zset', child: Text('ZSet')),
                ],
                onChanged: (v) => setD(() => type = v ?? 'string'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: valCtrl,
                decoration: InputDecoration(
                  labelText: switch (type) {
                    'hash' => tr('br.fieldEqValue'),
                    'zset' => tr('br.scoreEqMember'),
                    _ => tr('br.firstValue'),
                  },
                  border: const OutlineInputBorder(),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('br.cancel'))),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final c = _client;
                if (c == null) {
                  Navigator.pop(ctx);
                  return;
                }
                final v = valCtrl.text.trim();
                // A new String key does SET, which silently replaces an existing
                // key of ANY type. (Other types fail with WRONGTYPE, caught below.)
                if (type == 'string') {
                  String existing;
                  try {
                    existing = await c.type(name);
                  } catch (_) {
                    existing = 'none'; // connection dropped mid-dialog; skip the precheck
                  }
                  if (existing != 'none' && existing.isNotEmpty && ctx.mounted) {
                    final go = await showDialog<bool>(
                      context: ctx,
                      builder: (c2) => AlertDialog(
                        title: Text(tr('br.overwriteKeyQ')),
                        content: Text('A "$existing" key named "$name" already exists. '
                            'Creating a String will replace it. Continue?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c2, false), child: Text(tr('br.cancel'))),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Theme.of(c2).colorScheme.error),
                            onPressed: () => Navigator.pop(c2, true),
                            child: Text(tr('br.overwrite')),
                          ),
                        ],
                      ),
                    );
                    if (go != true) return;
                  }
                }
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                await _guardTop(() async {
                  switch (type) {
                    case 'string':
                      await c.set(name, v.isEmpty ? '' : v);
                    case 'hash':
                      final p = v.split('=');
                      await c.hset(name, p.first, p.length > 1 ? p.sublist(1).join('=') : '');
                    case 'list':
                      await c.rpush(name, v);
                    case 'set':
                      await c.sadd(name, v);
                    case 'zset':
                      final p = v.split('=');
                      await c.zadd(name, p.first.isEmpty ? '0' : p.first, p.length > 1 ? p.sublist(1).join('=') : '');
                  }
                });
                if (!mounted) return;
                if (!_keys.contains(name)) setState(() => _keys.insert(0, name));
                _openKey(name);
              },
              child: Text(tr('br.create')),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _guardTop(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _listAddDialog(String key) async {
    final ctrl = TextEditingController();
    String where = 'tail';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: Text(tr('br.addNewLine')),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: ctrl, minLines: 3, maxLines: 10,
                  decoration: InputDecoration(labelText: tr('br.value'), border: const OutlineInputBorder())),
              const SizedBox(height: 12),
              Row(children: [
                Text(tr('br.pushAt')),
                const SizedBox(width: 8),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'head', label: Text(tr('br.head'))),
                    ButtonSegment(value: 'tail', label: Text(tr('br.tail'))),
                  ],
                  selected: {where},
                  onSelectionChanged: (s) => setD(() => where = s.first),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('br.cancel'))),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _guard(() => where == 'head' ? _client!.lpush(key, ctrl.text) : _client!.rpush(key, ctrl.text));
              },
              child: Text(tr('br.add')),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _singleValueDialog(String title,
      {String? value, required Future<void> Function(String) onSubmit}) async {
    final ctrl = TextEditingController(text: value ?? '');
    await _formDialog(title, [ctrl], (v) => onSubmit(v[0]),
        labels: [tr('br.value')], multiline: const [true]);
  }

  Future<void> _fieldValueDialog(String title,
      {String? field, String? value, bool fieldLocked = false,
      required Future<void> Function(String, String) onSubmit}) async {
    final f = TextEditingController(text: field ?? '');
    final v = TextEditingController(text: value ?? '');
    await _formDialog(title, [f, v], (x) => onSubmit(x[0], x[1]),
        labels: [tr('br.field'), tr('br.value')], locked: [fieldLocked, false], multiline: const [false, true]);
  }

  Future<void> _scoreMemberDialog(String title,
      {String? score, String? member, bool memberLocked = false,
      required Future<void> Function(String, String) onSubmit}) async {
    final s = TextEditingController(text: score ?? '');
    final m = TextEditingController(text: member ?? '');
    await _formDialog(title, [s, m], (x) => onSubmit(x[0], x[1]),
        labels: [tr('br.score'), tr('br.member')], locked: [false, memberLocked], multiline: const [false, true]);
  }

  Future<void> _formDialog(String title, List<TextEditingController> ctrls,
      Future<void> Function(List<String>) onSubmit,
      {required List<String> labels, List<bool>? locked, List<bool>? multiline}) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < ctrls.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              // ARDM's Edit Line shows Size + Copy above the value area.
              if (multiline != null && multiline[i])
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: ctrls[i],
                    builder: (c2, v, _) => Row(children: [
                      Text('${tr('br.size')}: ${utf8.encode(v.text).length}B',
                          style: TextStyle(fontSize: 12, color: Theme.of(c2).hintColor)),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () => _copy(v.text, tr('br.valueCopied')),
                        icon: const Icon(Icons.copy, size: 13),
                        label: Text(tr('br.copy'), style: const TextStyle(fontSize: 12)),
                      ),
                      const Spacer(),
                    ]),
                  ),
                ),
              TextField(
                controller: ctrls[i],
                enabled: locked == null || !locked[i],
                minLines: (multiline != null && multiline[i]) ? 8 : 1,
                maxLines: (multiline != null && multiline[i]) ? 16 : 1,
                decoration: InputDecoration(labelText: labels[i], border: const OutlineInputBorder()),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('br.cancel'))),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _guard(() => onSubmit(ctrls.map((c) => c.text).toList()));
            },
            child: Text(tr('br.ok')),
          ),
        ],
      ),
    );
  }

  Widget _center(IconData icon, String title, String subtitle) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ]),
      );
}

// One column descriptor for the value table: the line-number gutter, a data
// column (sortable), or the trailing actions cell.
class _VCol {
  final String label;
  final int? sortCol; // data column index; null for gutter/actions
  final bool pk; // first data column — 600 weight (mockup .pk)
  final bool isLn;
  final bool isActions;
  const _VCol.ln(this.label)
      : sortCol = null,
        pk = false,
        isLn = true,
        isActions = false;
  const _VCol.data(this.label, this.sortCol, {this.pk = false})
      : isLn = false,
        isActions = false;
  const _VCol.actions()
      : label = 'ACTIONS', // mockup thead shows the literal Actions th
        sortCol = null,
        pk = false,
        isLn = false,
        isActions = true;
}

// A collapsible namespace folder in the key tree.
class _Folder extends StatefulWidget {
  final String name;
  final int count;
  final int depth;
  final VoidCallback onDelete;
  final List<Widget> children;
  const _Folder({
    required this.name,
    required this.count,
    required this.depth,
    required this.onDelete,
    required this.children,
  });

  @override
  State<_Folder> createState() => _FolderState();
}

class _FolderState extends State<_Folder> {
  bool _open = true;
  @override
  Widget build(BuildContext context) {
    final tok = AppTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        onSecondaryTapDown: (d) => _menu(d.globalPosition),
        onLongPress: () => _menu(null),
        child: Container(
          height: Dim.rowH,
          padding: EdgeInsets.only(left: 8.0 + widget.depth * 16, right: 8),
          child: Row(children: [
            // Mockup .node folder: twisty + name only (no folder icon).
            SizedBox(
              width: 12,
              child: Text(_open ? '▾' : '▸',
                  style: Ts.style(size: 10, color: tok.text3)),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(widget.name,
                  overflow: TextOverflow.ellipsis,
                  style: Ts.style(size: Ts.lg, weight: FontWeight.w500, color: tok.text)),
            ),
            Text('${widget.count}',
                style: Ts.style(size: Ts.xs, color: tok.text3, monoFont: true, tabularNums: true)),
          ]),
        ),
      ),
      if (_open) ...widget.children,
    ]);
  }

  Future<void> _menu(Offset? at) async {
    final pos = at ?? const Offset(200, 200);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, overlay.size.width - pos.dx, 0),
      items: [
        PopupMenuItem(value: 'delete', child: Text(tr('br.scanDeleteFolder'))),
      ],
    );
    if (choice == 'delete') widget.onDelete();
  }
}
