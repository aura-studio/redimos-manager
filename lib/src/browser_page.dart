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
      child: Row(children: [
        SizedBox(width: 288, child: _leftPanel()),
        const VerticalDivider(width: 1),
        Expanded(child: _rightPanel()),
      ]),
    );
  }

  // ---- left panel ----

  Widget _leftPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Row(children: [
          Tooltip(
            message: widget.config.multiDb
                ? tr('br.selectDatabase')
                : tr('br.multiDbOff'),
            child: DropdownButton<int>(
              value: _db,
              underline: const SizedBox.shrink(),
              items: [for (var i = 0; i < 16; i++) DropdownMenuItem(value: i, child: Text('DB$i'))],
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _db = v);
                await _client?.select(v);
                if (!mounted) return;
                _reload();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: _newKeyDialog,
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('br.newKey')),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(36)),
            ),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: TextField(
          controller: _search,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: 'Glob pattern, e.g. user:*',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            suffixIcon: IconButton(
              tooltip: tr('br.search'),
              icon: const Icon(Icons.arrow_forward, size: 18),
              onPressed: _reload,
            ),
          ),
          onSubmitted: (_) => _reload(),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          Text('${_keys.length} ${tr('br.keysUnit')}${_scanDone ? '' : '+'}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const Spacer(),
          IconButton(
            tooltip: _selectMode ? tr('br.exitSelect') : tr('br.selectMultiple'),
            visualDensity: VisualDensity.compact,
            isSelected: _selectMode,
            icon: Icon(_selectMode ? Icons.check_box : Icons.check_box_outlined, size: 18),
            onPressed: () => setState(() {
              _selectMode = !_selectMode;
              if (!_selectMode) _checked.clear();
            }),
          ),
          IconButton(
            tooltip: _tree ? tr('br.flatView') : tr('br.treeView'),
            visualDensity: VisualDensity.compact,
            icon: Icon(_tree ? Icons.account_tree : Icons.list, size: 18),
            onPressed: () => setState(() => _tree = !_tree),
          ),
          IconButton(
            tooltip: tr('br.refresh'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _reload,
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
          color: scheme.errorContainer,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Text('${_checked.length} ${tr('br.selected')}', style: TextStyle(color: scheme.onErrorContainer)),
            const Spacer(),
            TextButton(
              onPressed: () => setState(_checked.clear),
              child: Text(tr('br.clear')),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: scheme.error),
              onPressed: _batchDelete,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: Text(tr('br.delete')),
            ),
          ]),
        ),
      if (!_scanDone)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _scanning ? null : _scanMore,
                child: _scanning
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(tr('br.loadMore')),
              ),
            ),
            const SizedBox(width: 8),
            // ARDM's "load all" is a red filled button — it walks the whole keyspace.
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: scheme.error, foregroundColor: scheme.onError),
              onPressed: _scanning ? null : _loadAllConfirm,
              child: Text(tr('br.loadAll')),
            ),
          ]),
        ),
    ]);
  }

  List<Widget> _flatNodes() => [
        for (final k in _keys) _leaf(k, k, 0),
      ];

  Widget _leaf(String key, String label, int depth) {
    final sel = key == _selected;
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
        color: sel ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15) : null,
        padding: EdgeInsets.fromLTRB(12.0 + depth * 16, 7, 8, 7),
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
          // ARDM leaves are plain text (no key glyph), indented under folders.
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
        ]),
      ),
    );
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
      const Divider(height: 1),
      Expanded(child: _detail(_tabs[_active])),
    ]);
  }

  Widget _tabStrip() {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 38,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _tabs.length,
        itemBuilder: (ctx, i) {
          final active = i == _active;
          return InkWell(
            onTap: () => setState(() => _active = i),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(
                color: active ? scheme.primary.withValues(alpha: 0.12) : null,
                border: Border(
                  bottom: BorderSide(
                    color: active ? scheme.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(_tabs[i].key,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
                ),
                IconButton(
                  tooltip: tr('br.close'),
                  visualDensity: VisualDensity.compact,
                  iconSize: 14,
                  icon: const Icon(Icons.close),
                  onPressed: () => _closeTab(i),
                ),
              ]),
            ),
          );
        },
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

  // ARDM-style header: [type | key name  ⎘] [TTL | <secs> ↺ ✓] [🗑][↻][</>]
  Widget _keyHeader(_KeyTab t) {
    final scheme = Theme.of(context).colorScheme;
    final border = Border.all(color: scheme.outlineVariant);

    // A prefix segment of an input-look group (like ARDM's "Hash" / "TTL").
    Widget seg(String label) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            border: Border(right: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)),
        );

    // ARDM's square colored action buttons (delete red / refresh green / cmd blue).
    Widget squareBtn(Color color, IconData icon, String tooltip, VoidCallback onTap) => Tooltip(
          message: tooltip,
          child: Material(
            color: color,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onTap,
              child: SizedBox(width: 44, height: 36, child: Icon(icon, size: 17, color: Colors.white)),
            ),
          ),
        );

    void applyTtl() {
      final s = int.tryParse(t.ttlCtrl.text.trim());
      // 0 / blank / negative → persist (EXPIRE key 0 would delete the key).
      _guard(() => s == null || s <= 0 ? _client!.persist(t.key) : _client!.expire(t.key, s));
    }

    return SizedBox(
      height: 36,
      child: Row(children: [
        // key group: type badge + read-only name + copy
        Expanded(
          child: Container(
            decoration: BoxDecoration(border: border, borderRadius: BorderRadius.circular(6)),
            clipBehavior: Clip.antiAlias,
            child: Row(children: [
              seg(_typeLabel(t.type)),
              const SizedBox(width: 10),
              Expanded(
                child: Tooltip(
                  message: tr('br.renameNotSupported'),
                  child: Text(t.key,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              IconButton(
                tooltip: tr('br.copyKeyName'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _copy(t.key, tr('br.keyNameCopied')),
                icon: Icon(Icons.copy, size: 14, color: scheme.onSurfaceVariant),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 10),
        // TTL group: label + inline seconds input + reset + apply
        Container(
          decoration: BoxDecoration(border: border, borderRadius: BorderRadius.circular(6)),
          clipBehavior: Clip.antiAlias,
          child: Row(children: [
            seg('TTL'),
            SizedBox(
              width: 76,
              child: TextField(
                controller: t.ttlCtrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 9),
                ),
                onSubmitted: (_) => applyTtl(),
              ),
            ),
            IconButton(
              tooltip: tr('br.reset'),
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => t.ttlCtrl.text = '${t.ttl}'),
              icon: Icon(Icons.history, size: 15, color: scheme.onSurfaceVariant),
            ),
            IconButton(
              tooltip: tr('br.applyTtl'),
              visualDensity: VisualDensity.compact,
              onPressed: applyTtl,
              icon: Icon(Icons.check, size: 16, color: scheme.primary),
            ),
          ]),
        ),
        const SizedBox(width: 10),
        squareBtn(const Color(0xFFE25B5B), Icons.delete_outline, tr('br.deleteKey'), () => _deleteKeys([t.key])),
        const SizedBox(width: 6),
        squareBtn(const Color(0xFF57B36A), Icons.refresh, tr('br.refresh'), _refreshTab),
        const SizedBox(width: 6),
        squareBtn(const Color(0xFF4A8FE0), Icons.code, tr('br.copyAsCommand'),
            () => _copy(_keyCommand(t), tr('br.commandCopied'))),
      ]),
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
    final f = t.filter.trim().toLowerCase();
    var visible = f.isEmpty
        ? t.rows
        : t.rows.where((r) => r[0].toLowerCase().contains(f) || r[1].toLowerCase().contains(f)).toList();
    final scheme = Theme.of(context).colorScheme;

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
    final idHeader = 'ID (${tr('br.total')}: ${t.total})';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        FilledButton(onPressed: onAdd, child: Text(tr('br.addNewLine'))),
        // ARDM shows a DESC/ASC order toggle for zsets, DESC first.
        if (scoreFirst) ...[
          const SizedBox(width: 10),
          SegmentedButton<bool>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(value: true, label: Text(tr('br.desc')), icon: const Icon(Icons.arrow_drop_down)),
              ButtonSegment(value: false, label: Text(tr('br.asc')), icon: const Icon(Icons.arrow_drop_up)),
            ],
            selected: {t.desc},
            onSelectionChanged: (s) => _setZsetOrder(t, s.first),
          ),
        ],
      ]),
      const SizedBox(height: 10),
      if (visible.isEmpty)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: Text(t.filter.isEmpty ? tr('br.empty') : tr('br.noMatchInLoadedRows'),
                style: const TextStyle(color: Colors.grey)),
          ),
        )
      else
        // Fill the pane width like ARDM (long values still get a horizontal
        // scroll once the intrinsic width exceeds the viewport).
        LayoutBuilder(
          builder: (ctx, box) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: box.maxWidth),
              child: DataTable(
            columnSpacing: 16,
            headingRowHeight: 30,
            dataRowMinHeight: 28,
            dataRowMaxHeight: 34,
            sortColumnIndex: t.sortCol == null ? null : t.sortCol! + 1,
            sortAscending: t.sortAsc,
            columns: [
              DataColumn(label: Text(idHeader, style: const TextStyle(fontWeight: FontWeight.w600))),
              for (var j = 0; j < dataCols.length; j++)
                DataColumn(
                  label: Text(dataCols[j], style: const TextStyle(fontWeight: FontWeight.w600)),
                  onSort: (_, asc) => setState(() {
                    t.sortCol = j;
                    t.sortAsc = asc;
                  }),
                ),
              // ARDM puts the keyword filter in the table header, over the actions.
              DataColumn(
                label: SizedBox(
                  width: 190,
                  child: TextField(
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: tr('br.keywordSearch'),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    onChanged: (v) => setState(() => t.filter = v),
                  ),
                ),
              ),
            ],
            rows: [
              for (var i = 0; i < visible.length; i++)
                _dataRow(t, i, visible[i],
                    scoreFirst: scoreFirst, numbered: numbered, singleColumn: singleColumn,
                    disabled: t.mutating, onEdit: rowEdit, onDelete: rowDelete),
            ],
              ),
            ),
          ),
        ),
      if (t.hasMore)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: t.loadingMore ? null : () => _loadMoreRows(t),
              child: t.loadingMore
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('${tr('br.loadMore')}  (${t.rows.length}/${t.total})'),
            ),
          ),
        ),
      if (f.isNotEmpty && t.hasMore)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(tr('br.filterLoadedOnly'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ),
    ]);
  }

  DataRow _dataRow(
    _KeyTab t,
    int i,
    List<String> row, {
    required bool scoreFirst,
    required bool numbered,
    required bool singleColumn,
    required bool disabled,
    required void Function(List<String>) onEdit,
    required Future<void> Function(List<String>) onDelete,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // display cells: scoreFirst (zset) shows [score(b), member(a)]; set shows
    // [member]; else [a, b] — key off the type flag, NOT whether the value is
    // empty (an empty hash/list value must still emit its column, or the
    // DataCell count won't match the header and DataTable asserts).
    final cells = scoreFirst
        ? [row[1], row[0]]
        : (singleColumn ? [row[0]] : [row[0], row[1]]);
    // ARDM renders all four row action icons in the same accent blue.
    final iconColor = disabled ? scheme.outline : const Color(0xFF4A8FE0);
    return DataRow(
      // zebra striping like ARDM
      color: WidgetStatePropertyAll(
          i.isOdd ? scheme.surfaceContainerHigh.withValues(alpha: 0.45) : null),
      cells: [
        if (numbered) DataCell(Text('${i + 1}', style: TextStyle(color: Theme.of(context).hintColor))),
        for (final c in cells)
          DataCell(ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(c, maxLines: 2, overflow: TextOverflow.ellipsis),
          )),
        DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: tr('br.viewFormatValue'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.description_outlined, size: 15, color: iconColor),
            onPressed: () => _viewValue(t, row),
          ),
          IconButton(
            tooltip: tr('br.copyValue'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.copy, size: 14, color: iconColor),
            // The row's VALUE: hash value / list element (row[1]); set/zset member (row[0]).
            onPressed: () => _copy(scoreFirst || singleColumn ? row[0] : row[1], tr('br.valueCopied')),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: tr('br.edit'),
            icon: Icon(Icons.edit, size: 15, color: iconColor),
            onPressed: disabled ? null : () => onEdit(row),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: tr('br.delete'),
            icon: Icon(Icons.delete_outline, size: 15, color: iconColor),
            // Disabled while a write is in flight so a second (positional) delete
            // can't fire against a stale, shifted index.
            onPressed: disabled ? null : () => _guard(() => onDelete(row)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: tr('br.copyAsCommand'),
            icon: Icon(Icons.code, size: 15, color: iconColor),
            onPressed: () => _copy(_rowCommand(t, row), tr('br.commandCopied')),
          ),
        ])),
      ],
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
        content: Text('Scan and delete every key under "$prefix:" ? This cannot be undone.'),
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
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        onSecondaryTapDown: (d) => _menu(d.globalPosition),
        onLongPress: () => _menu(null),
        child: Padding(
          padding: EdgeInsets.fromLTRB(8.0 + widget.depth * 16, 7, 8, 7),
          child: Row(children: [
            Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 2),
            Icon(Icons.folder, size: 14, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text(widget.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
            Text('(${widget.count})', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
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
