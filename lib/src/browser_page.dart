// The "Browser" tab — an Another-Redis-Desktop-Manager-style key browser wired
// straight to the running redimos proxy's RESP port (127.0.0.1:<config port>).
// Left: glob search, namespace tree / flat toggle, SCAN pagination. Right: the
// five type editors (String / Hash / List / Set / ZSet) with TTL, delete, and
// common writes. Connection management, CLI, and the INFO dashboard are left out
// (already covered by the config list, the Cmd tab, and the Monitor tab).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'models.dart';
import 'resp_client.dart';

class BrowserPageView extends StatefulWidget {
  final RedimosConfig config;
  final bool running;
  const BrowserPageView({super.key, required this.config, required this.running});

  @override
  State<BrowserPageView> createState() => _BrowserPageViewState();
}

class _BrowserPageViewState extends State<BrowserPageView>
    with AutomaticKeepAliveClientMixin {
  RedisClient? _client;
  bool _connecting = false;
  String? _connError;
  Timer? _reconnect;

  // left panel
  final _search = TextEditingController();
  bool _tree = true;
  int _db = 0;
  final _keys = <String>[];
  String _cursor = '0';
  bool _scanning = false;
  bool _scanDone = false;
  String? _selected;

  // right panel (key detail)
  bool _loadingKey = false;
  String? _keyType;
  int _keyTtl = -1;
  String? _detailError;
  String _strFormat = 'Text';
  final _strCtrl = TextEditingController();
  Map<String, String> _hash = {};
  List<String> _list = [];
  List<String> _set = [];
  List<(String, String)> _zset = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.running) _connect();
  }

  @override
  void didUpdateWidget(BrowserPageView old) {
    super.didUpdateWidget(old);
    if (old.config.id != widget.config.id || old.config.port != widget.config.port) {
      _disconnect();
      _resetLeft();
      _selected = null;
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
    _strCtrl.dispose();
    super.dispose();
  }

  // ---- connection ----

  Future<void> _connect() async {
    if (_connecting || (_client?.connected ?? false)) return;
    setState(() {
      _connecting = true;
      _connError = null;
    });
    final c = RedisClient('127.0.0.1', widget.config.port,
        auth: widget.config.requirepass.isEmpty ? null : widget.config.requirepass);
    c.onClosed = (_) {
      if (!mounted) return;
      setState(() => _client = null);
      _scheduleReconnect();
    };
    try {
      await c.connect();
      if (widget.config.multiDb && _db > 0) await c.select(_db);
      if (!mounted) {
        c.close();
        return;
      }
      setState(() {
        _client = c;
        _connecting = false;
      });
      _reload();
    } catch (e) {
      if (!mounted) return;
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
    _reconnect?.cancel();
    _client?.close();
    if (mounted) setState(() => _client = null);
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

  // ---- right: key detail ----

  Future<void> _openKey(String key) async {
    final c = _client;
    if (c == null) return;
    setState(() {
      _selected = key;
      _loadingKey = true;
      _detailError = null;
      _keyType = null;
    });
    try {
      final t = await c.type(key);
      final ttl = await c.ttl(key);
      String? sv;
      Map<String, String> hv = {};
      List<String> lv = [], setv = [];
      List<(String, String)> zv = [];
      switch (t) {
        case 'string':
          sv = await c.get(key);
        case 'hash':
          hv = await c.hgetall(key);
        case 'list':
          lv = await c.lrange(key, 0, 999);
        case 'set':
          setv = await c.smembers(key);
        case 'zset':
          zv = await c.zrange(key, 0, -1);
      }
      if (!mounted) return;
      setState(() {
        _loadingKey = false;
        _keyType = t;
        _keyTtl = ttl;
        _strCtrl.text = sv ?? '';
        _strFormat = 'Text';
        _hash = hv;
        _list = lv;
        _set = setv;
        _zset = zv;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingKey = false;
        _detailError = '$e';
      });
    }
  }

  Future<void> _refreshKey() async {
    if (_selected != null) await _openKey(_selected!);
  }

  Future<void> _guard(Future<void> Function() op) async {
    try {
      await op();
      await _refreshKey();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.running) {
      return _center(Icons.storage, 'Instance not running',
          'Start this config to browse its keyspace.');
    }
    if (_client == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 34, height: 34, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 16),
          Text(_connError ?? 'Connecting…'),
          Text('127.0.0.1:${widget.config.port}',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      );
    }
    return Row(children: [
      SizedBox(width: 320, child: _leftPanel()),
      const VerticalDivider(width: 1),
      Expanded(child: _rightPanel()),
    ]);
  }

  // ---- left panel ----

  Widget _leftPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Row(children: [
          if (widget.config.multiDb) ...[
            DropdownButton<int>(
              value: _db,
              underline: const SizedBox.shrink(),
              items: [for (var i = 0; i < 16; i++) DropdownMenuItem(value: i, child: Text('DB$i'))],
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _db = v);
                await _client?.select(v);
                _reload();
              },
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: FilledButton.icon(
              onPressed: _newKeyDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Key'),
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
              tooltip: 'Search',
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
          Text('${_keys.length} keys${_scanDone ? '' : '+'}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const Spacer(),
          IconButton(
            tooltip: _tree ? 'Flat view' : 'Tree view',
            visualDensity: VisualDensity.compact,
            icon: Icon(_tree ? Icons.account_tree : Icons.list, size: 18),
            onPressed: () => setState(() => _tree = !_tree),
          ),
          IconButton(
            tooltip: 'Refresh',
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
                child: Text(_scanning ? 'Scanning…' : 'No keys',
                    style: const TextStyle(color: Colors.grey)))
            : ListView(children: _tree ? _treeNodes() : _flatNodes()),
      ),
      if (!_scanDone)
        Padding(
          padding: const EdgeInsets.all(8),
          child: OutlinedButton(
            onPressed: _scanning ? null : _scanMore,
            child: _scanning
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Load more'),
          ),
        ),
    ]);
  }

  List<Widget> _flatNodes() => [
        for (final k in _keys) _leaf(k, k, 0),
      ];

  Widget _leaf(String key, String label, int depth) {
    final sel = key == _selected;
    return InkWell(
      onTap: () => _openKey(key),
      child: Container(
        color: sel ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15) : null,
        padding: EdgeInsets.fromLTRB(12.0 + depth * 16, 7, 8, 7),
        child: Row(children: [
          Icon(Icons.vpn_key, size: 13, color: Theme.of(context).hintColor),
          const SizedBox(width: 6),
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
        ]),
      ),
    );
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
    return _renderBranch(root, 0);
  }

  List<Widget> _renderBranch(Map<String, dynamic> node, int depth) {
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
      out.add(_Folder(
        name: name,
        count: _countLeaves(child),
        depth: depth,
        children: _renderBranch(child, depth + 1),
      ));
    }
    for (final l in leaves) {
      out.add(_leaf(l.value, l.key, depth));
    }
    return out;
  }

  int _countLeaves(Map<String, dynamic> node) {
    var n = 0;
    node.forEach((_, v) => n += v is Map<String, dynamic> ? _countLeaves(v) : 1);
    return n;
  }

  // ---- right panel ----

  Widget _rightPanel() {
    if (_selected == null) {
      return _center(Icons.vpn_key, 'No key selected', 'Pick a key on the left to view it.');
    }
    if (_loadingKey) return const Center(child: CircularProgressIndicator());
    if (_detailError != null) {
      return _center(Icons.error_outline, 'Cannot read key', _detailError!);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _keyHeader(),
        const SizedBox(height: 16),
        _typeEditor(),
      ]),
    );
  }

  Widget _keyHeader() {
    final scheme = Theme.of(context).colorScheme;
    final ttlText = _keyTtl < 0 ? 'No expiry' : '${_keyTtl}s';
    return Row(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text((_keyType ?? '?').toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer)),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Tooltip(
          message: 'redimos does not support RENAME — key names are read-only here',
          child: Text(_selected!, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        onPressed: _editTtlDialog,
        icon: const Icon(Icons.schedule, size: 16),
        label: Text('TTL: $ttlText'),
      ),
      const SizedBox(width: 6),
      IconButton(tooltip: 'Refresh', onPressed: _refreshKey, icon: const Icon(Icons.refresh, size: 18)),
      IconButton(
        tooltip: 'Delete key',
        onPressed: _deleteKeyDialog,
        icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
      ),
    ]);
  }

  Widget _typeEditor() {
    switch (_keyType) {
      case 'string':
        return _stringEditor();
      case 'hash':
        return _hashEditor();
      case 'list':
        return _listEditor();
      case 'set':
        return _setEditor();
      case 'zset':
        return _zsetEditor();
      default:
        return Text('Unsupported type: $_keyType');
    }
  }

  // -- string --
  Widget _stringEditor() {
    String display = _strCtrl.text;
    if (_strFormat == 'JSON') {
      try {
        display = const JsonEncoder.withIndent('  ').convert(jsonDecode(_strCtrl.text));
      } catch (_) {}
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        DropdownButton<String>(
          value: _strFormat,
          items: const [
            DropdownMenuItem(value: 'Text', child: Text('Text')),
            DropdownMenuItem(value: 'JSON', child: Text('JSON')),
          ],
          onChanged: (v) => setState(() => _strFormat = v ?? 'Text'),
        ),
        const SizedBox(width: 12),
        Text('Size: ${utf8.encode(_strCtrl.text).length}B',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        const Spacer(),
        FilledButton(
          onPressed: () => _guard(() => _client!.set(_selected!, _strCtrl.text)),
          child: const Text('Save'),
        ),
      ]),
      const SizedBox(height: 8),
      _strFormat == 'JSON'
          ? Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(display, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            )
          : TextField(
              controller: _strCtrl,
              minLines: 6,
              maxLines: 20,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(12),
              ),
              onChanged: (_) => setState(() {}),
            ),
    ]);
  }

  // -- hash --
  Widget _hashEditor() {
    final entries = _hash.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return _collectionCard(
      total: entries.length,
      onAdd: () => _fieldValueDialog('Add field', onSubmit: (f, v) => _client!.hset(_selected!, f, v)),
      columns: const ['Field', 'Value'],
      rows: [
        for (final e in entries)
          _row([e.key, e.value],
              onEdit: () => _fieldValueDialog('Edit field',
                  field: e.key, value: e.value, fieldLocked: true,
                  onSubmit: (f, v) => _client!.hset(_selected!, f, v)),
              onDelete: () => _client!.hdel(_selected!, e.key)),
      ],
    );
  }

  // -- list --
  Widget _listEditor() {
    return _collectionCard(
      total: _list.length,
      onAdd: () => _singleValueDialog('Push value', onSubmit: (v) => _client!.rpush(_selected!, v)),
      columns: const ['#', 'Value'],
      rows: [
        for (var i = 0; i < _list.length; i++)
          _row(['$i', _list[i]],
              onEdit: () => _singleValueDialog('Edit value', value: _list[i],
                  onSubmit: (v) => _client!.lset(_selected!, i, v)),
              onDelete: () => _client!.lrem(_selected!, 1, _list[i])),
      ],
    );
  }

  // -- set --
  Widget _setEditor() {
    final members = [..._set]..sort();
    return _collectionCard(
      total: members.length,
      onAdd: () => _singleValueDialog('Add member', onSubmit: (v) => _client!.sadd(_selected!, v)),
      columns: const ['Member'],
      rows: [
        for (final m in members)
          _row([m], onDelete: () => _client!.srem(_selected!, m)),
      ],
    );
  }

  // -- zset --
  Widget _zsetEditor() {
    return _collectionCard(
      total: _zset.length,
      onAdd: () => _scoreMemberDialog('Add member',
          onSubmit: (s, m) => _client!.zadd(_selected!, s, m)),
      columns: const ['Score', 'Member'],
      rows: [
        for (final e in _zset)
          _row([e.$2, e.$1],
              onEdit: () => _scoreMemberDialog('Edit score', score: e.$2, member: e.$1, memberLocked: true,
                  onSubmit: (s, m) => _client!.zadd(_selected!, s, m)),
              onDelete: () => _client!.zrem(_selected!, e.$1)),
      ],
    );
  }

  Widget _collectionCard({
    required int total,
    required VoidCallback onAdd,
    required List<String> columns,
    required List<DataRow> rows,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add, size: 16), label: const Text('Add')),
        const SizedBox(width: 12),
        Text('Total: $total', style: TextStyle(color: Theme.of(context).hintColor)),
      ]),
      const SizedBox(height: 10),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 32,
          headingRowHeight: 38,
          dataRowMinHeight: 36,
          dataRowMaxHeight: 46,
          columns: [
            for (final c in columns) DataColumn(label: Text(c, style: const TextStyle(fontWeight: FontWeight.w600))),
            const DataColumn(label: Text('')),
          ],
          rows: rows,
        ),
      ),
    ]);
  }

  DataRow _row(List<String> cells, {VoidCallback? onEdit, Future<void> Function()? onDelete}) {
    return DataRow(cells: [
      for (final c in cells)
        DataCell(ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(c, maxLines: 2, overflow: TextOverflow.ellipsis),
        )),
      DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
        if (onEdit != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit, size: 16),
            onPressed: onEdit,
          ),
        if (onDelete != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.delete_outline, size: 16, color: Theme.of(context).colorScheme.error),
            onPressed: () => _guard(onDelete),
          ),
      ])),
    ]);
  }

  // ---- dialogs ----

  Future<void> _editTtlDialog() async {
    final ctrl = TextEditingController(text: _keyTtl < 0 ? '' : '$_keyTtl');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set TTL'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Seconds (blank = persist)', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              final s = int.tryParse(ctrl.text.trim());
              _guard(() => s == null || s < 0 ? _client!.persist(_selected!) : _client!.expire(_selected!, s));
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteKeyDialog() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete key?'),
        content: Text('Permanently delete "$_selected"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _client!.del(_selected!);
        setState(() {
          _keys.remove(_selected);
          _selected = null;
          _keyType = null;
        });
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _newKeyDialog() async {
    final nameCtrl = TextEditingController();
    final valCtrl = TextEditingController();
    String type = 'string';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: const Text('New Key'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Key name', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
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
                    'hash' => 'field=value',
                    'zset' => 'score=member',
                    _ => 'first value',
                  },
                  border: const OutlineInputBorder(),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx);
                final v = valCtrl.text.trim();
                await _guardTop(() async {
                  switch (type) {
                    case 'string':
                      await _client!.set(name, v.isEmpty ? '' : v);
                    case 'hash':
                      final p = v.split('=');
                      await _client!.hset(name, p.first, p.length > 1 ? p.sublist(1).join('=') : '');
                    case 'list':
                      await _client!.rpush(name, v);
                    case 'set':
                      await _client!.sadd(name, v);
                    case 'zset':
                      final p = v.split('=');
                      await _client!.zadd(name, p.first.isEmpty ? '0' : p.first, p.length > 1 ? p.sublist(1).join('=') : '');
                  }
                });
                if (!_keys.contains(name)) setState(() => _keys.insert(0, name));
                await _openKey(name);
              },
              child: const Text('Create'),
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

  Future<void> _singleValueDialog(String title,
      {String? value, required Future<void> Function(String) onSubmit}) async {
    final ctrl = TextEditingController(text: value ?? '');
    await _formDialog(title, [ctrl], (v) => onSubmit(v[0]),
        labels: const ['Value']);
  }

  Future<void> _fieldValueDialog(String title,
      {String? field, String? value, bool fieldLocked = false,
      required Future<void> Function(String, String) onSubmit}) async {
    final f = TextEditingController(text: field ?? '');
    final v = TextEditingController(text: value ?? '');
    await _formDialog(title, [f, v], (x) => onSubmit(x[0], x[1]),
        labels: const ['Field', 'Value'], locked: [fieldLocked, false]);
  }

  Future<void> _scoreMemberDialog(String title,
      {String? score, String? member, bool memberLocked = false,
      required Future<void> Function(String, String) onSubmit}) async {
    final s = TextEditingController(text: score ?? '');
    final m = TextEditingController(text: member ?? '');
    await _formDialog(title, [s, m], (x) => onSubmit(x[0], x[1]),
        labels: const ['Score', 'Member'], locked: [false, memberLocked]);
  }

  Future<void> _formDialog(String title, List<TextEditingController> ctrls,
      Future<void> Function(List<String>) onSubmit,
      {required List<String> labels, List<bool>? locked}) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < ctrls.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              TextField(
                controller: ctrls[i],
                enabled: locked == null || !locked[i],
                decoration: InputDecoration(labelText: labels[i], border: const OutlineInputBorder()),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _guard(() => onSubmit(ctrls.map((c) => c.text).toList()));
            },
            child: const Text('Save'),
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
  final List<Widget> children;
  const _Folder({required this.name, required this.count, required this.depth, required this.children});

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
}
