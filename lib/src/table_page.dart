// The "Table" tab — a DynamoDB item browser modelled on the AWS console's
// Explore-items page, adapted for redimos tables (Binary keys shown as readable
// UTF-8 text, base64 on hover). Scan / Query with projection, sort-key
// conditions, filters, DynamoDB-style pagination, column preferences, checkbox
// multi-select with an Actions menu (Edit / Duplicate / Delete items / Export to
// CSV), pk links into a full-page Form|JSON item editor, and a Create item
// button. Item writes are endpoint-mode only and carry the redimos raw-write
// confirmation. All data comes from the Go core over FFI.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'item_editor.dart';
import 'models.dart';
import 'native.dart';

const _skConds = [
  ('eq', 'Equal to'),
  ('le', 'Less than or equal to'),
  ('lt', 'Less than'),
  ('ge', 'Greater than or equal to'),
  ('gt', 'Greater than'),
  ('between', 'Between'),
  ('begins_with', 'Begins with'),
];

const _filterConds = [
  ('eq', 'Equal to'),
  ('ne', 'Not equal to'),
  ('le', 'Less than or equal to'),
  ('lt', 'Less than'),
  ('ge', 'Greater than or equal to'),
  ('gt', 'Greater than'),
  ('between', 'Between'),
  ('exists', 'Exists'),
  ('not_exists', 'Not exists'),
  ('contains', 'Contains'),
  ('not_contains', 'Not contains'),
  ('begins_with', 'Begins with'),
];

const _filterTypes = [
  ('S', 'String'),
  ('N', 'Number'),
  ('B', 'Binary'),
  ('BOOL', 'Boolean'),
  ('NULL', 'Null'),
];

const _pageSizes = [10, 25, 50, 100, 200, 300];

class _FilterRow {
  final attr = TextEditingController();
  final v1 = TextEditingController();
  final v2 = TextEditingController();
  String type = 'S';
  String op = 'eq';
  void dispose() {
    attr.dispose();
    v1.dispose();
    v2.dispose();
  }

  bool get needsValue => op != 'exists' && op != 'not_exists';
  bool get needsTwo => op == 'between';
}

// A denser theme for the data tabs (Table / PartiQL / Browser): smaller controls
// and tighter tap targets so these dense query/browse surfaces read as compact and
// refined instead of chunky. Applied at each tab's root.
ThemeData _denseTabTheme(BuildContext context) => Theme.of(context).copyWith(
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

class TablePageView extends StatefulWidget {
  final NativeCore core;
  final RedimosConfig config;
  final bool running;
  // When set (via the Endpoint tab's Browse on a table that isn't this config's),
  // the tab browses THAT table on the same endpoint instead of config.table, and
  // is read-only (item writes stay tied to the config's own table). onExitBrowse
  // returns to the config's table.
  final String? tableOverride;
  final VoidCallback? onExitBrowse;
  const TablePageView(
      {super.key,
      required this.core,
      required this.config,
      required this.running,
      this.tableOverride,
      this.onExitBrowse});

  @override
  State<TablePageView> createState() => _TablePageViewState();
}

class _TablePageViewState extends State<TablePageView>
    with AutomaticKeepAliveClientMixin {
  TableMeta? _meta;
  String? _metaError;
  bool _loadingMeta = false;

  // query form
  bool _panelOpen = true;
  bool _isQuery = false;
  int _targetIdx = 0;
  String _projection = 'all';
  final _projectAttrs = <String>[];
  final _projectInput = TextEditingController();
  final _pk = TextEditingController();
  String _skOp = 'eq';
  final _skV1 = TextEditingController();
  final _skV2 = TextEditingController();
  bool _sortDesc = false;
  final _filters = <_FilterRow>[];

  // results
  bool _running = false;
  TablePage? _page;
  String? _pageError;
  final _stack = <Map<String, dynamic>?>[null]; // startKey per page
  int _pageIdx = 0;
  int _pageSize = 50;
  final _hiddenCols = <String>{};
  String? _sortCol;
  bool _sortAsc = true;
  // Multi-select (AWS Explore items checkboxes), keyed by the row's DynamoDB
  // JSON — stable for the lifetime of one loaded page.
  final _checked = <String>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadMeta();
  }

  @override
  void didUpdateWidget(TablePageView old) {
    super.didUpdateWidget(old);
    if (old.config.id != widget.config.id ||
        old.config.table != widget.config.table ||
        old.config.endpoint != widget.config.endpoint ||
        old.tableOverride != widget.tableOverride) {
      _resetAll();
      _loadMeta();
    }
  }

  @override
  void dispose() {
    _projectInput.dispose();
    _pk.dispose();
    _skV1.dispose();
    _skV2.dispose();
    for (final f in _filters) {
      f.dispose();
    }
    super.dispose();
  }

  void _resetAll() {
    _meta = null;
    _metaError = null;
    _targetIdx = 0;
    _isQuery = false;
    _projection = 'all';
    _projectAttrs.clear();
    _pk.clear();
    _skV1.clear();
    _skV2.clear();
    _sortDesc = false;
    for (final f in _filters) {
      f.dispose();
    }
    _filters.clear();
    _page = null;
    _pageError = null;
    _stack
      ..clear()
      ..add(null);
    _pageIdx = 0;
    _hiddenCols.clear();
    _sortCol = null;
  }

  Future<void> _loadMeta() async {
    setState(() {
      _loadingMeta = true;
      _metaError = null;
    });
    await Future.delayed(const Duration(milliseconds: 16));
    final m = widget.core.tableMeta(_effCfg);
    if (!mounted) return;
    setState(() {
      _loadingMeta = false;
      if (m.ok) {
        _meta = m;
        _metaError = null;
      } else {
        _meta = null;
        _metaError = m.error ?? 'failed to describe table';
      }
    });
    if (m.ok) _run(); // auto-scan on open, like the console's Autopreview
  }

  TableTarget? get _target =>
      (_meta != null && _targetIdx < _meta!.targets.length) ? _meta!.targets[_targetIdx] : null;

  Map<String, dynamic> _buildReq(Map<String, dynamic>? startKey) {
    final t = _target;
    return {
      'config': _effCfg.toJson(),
      'op': _isQuery ? 'query' : 'scan',
      'index': (t == null || t.isTable) ? '' : t.name,
      'projection': _projection,
      'projectAttrs': _projectAttrs,
      'pkValue': _pk.text.trim(),
      'skCond': (_isQuery && _skV1.text.trim().isNotEmpty && (_target?.sk != null))
          ? {'op': _skOp, 'v1': _skV1.text, 'v2': _skV2.text}
          : null,
      'scanForward': !_sortDesc,
      'filters': [
        for (final f in _filters)
          if (f.attr.text.trim().isNotEmpty)
            {'attr': f.attr.text.trim(), 'type': f.type, 'op': f.op, 'v1': f.v1.text, 'v2': f.v2.text},
      ],
      'limit': _pageSize,
      'startKey': startKey,
    };
  }

  Future<void> _run({bool resetPaging = true}) async {
    if (_meta == null) return;
    if (resetPaging) {
      _stack
        ..clear()
        ..add(null);
      _pageIdx = 0;
    }
    setState(() {
      _running = true;
      _pageError = null;
      _checked.clear(); // selection is per loaded page
    });
    await Future.delayed(const Duration(milliseconds: 16));
    final page = widget.core.tablePage(_buildReq(_stack[_pageIdx]));
    if (!mounted) return;
    setState(() {
      _running = false;
      if (page.ok) {
        _page = page;
        _pageError = null;
        _sortCol = null;
      } else {
        _pageError = page.error ?? 'query failed';
      }
    });
  }

  void _nextPage() {
    if (_page?.hasNext != true) return;
    if (_pageIdx == _stack.length - 1) _stack.add(_page!.lastKey);
    _pageIdx++;
    _run(resetPaging: false);
  }

  void _prevPage() {
    if (_pageIdx == 0) return;
    _pageIdx--;
    _run(resetPaging: false);
  }

  void _reset() {
    setState(() {
      _projection = 'all';
      _projectAttrs.clear();
      _pk.clear();
      _skV1.clear();
      _skV2.clear();
      _skOp = 'eq';
      _sortDesc = false;
      for (final f in _filters) {
        f.dispose();
      }
      _filters.clear();
    });
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.running) {
      return _center(Icons.play_circle_outline, 'Instance not running',
          'Start this config to browse its DynamoDB table.');
    }
    if (widget.config.table.trim().isEmpty) {
      return _center(Icons.table_chart_outlined, 'No table configured',
          'Set a Table name in Configure to browse it.');
    }
    return Theme(
      data: _denseTabTheme(context),
      child: SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // The header (AWS lock chip / Endpoint danger controls) always renders,
        // even when the table can't be read — so the safety state stays legible
        // and a table that was just deleted can still be recreated from here.
        _headerRow(),
        const SizedBox(height: 12),
        if (_loadingMeta && _meta == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 60),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_metaError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: _center(Icons.error_outline, 'Cannot read table', _metaError!,
                action: FilledButton.icon(
                    onPressed: _loadMeta,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'))),
          )
        else ...[
          _queryCard(),
          // AWS console shows no success banner — scan stats live in the results
          // card's caption; only errors get a banner.
          if (_pageError != null) ...[
            const SizedBox(height: 12),
            _banner(),
          ],
          if (_page != null) ...[
            const SizedBox(height: 12),
            _resultsCard(),
          ],
        ],
      ]),
    ));
  }

  // AWS mode (no endpoint) is read-only for item writes: the manager can't tell a
  // test account from production. Destructive table lifecycle (recreate / provision
  // / delete) lives entirely in the Endpoint tab, which is endpoint-mode only — this
  // page is just the item browser/editor (AWS-console "Explore items" parity).
  bool get _awsMode {
    final ep = widget.config.endpoint.trim();
    if (ep.isEmpty) return true; // default AWS resolver
    final host = (Uri.tryParse(ep)?.host ?? '').toLowerCase();
    return host == 'amazonaws.com' || host.endsWith('.amazonaws.com'); // explicit AWS host
  }

  // Browse-any-table: the Endpoint tab can point this tab at another table on the
  // same endpoint. Then we browse that table (read-only) via a config copy with the
  // table swapped; the endpoint/creds stay the config's own.
  bool get _foreignBrowse =>
      widget.tableOverride != null && widget.tableOverride != widget.config.table;
  String get _effTable => widget.tableOverride ?? widget.config.table;
  RedimosConfig get _effCfg =>
      _foreignBrowse ? (widget.config.copy()..table = widget.tableOverride!) : widget.config;

  Widget _headerRow() {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(Icons.table_chart, size: 18, color: scheme.primary),
      const SizedBox(width: 8),
      Flexible(
        child: Text(_effTable,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
      ),
      if (_foreignBrowse) ...[
        const SizedBox(width: 10),
        const Chip(
          visualDensity: VisualDensity.compact,
          avatar: Icon(Icons.visibility_outlined, size: 15),
          label: Text('Browsing · read-only'),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: () => widget.onExitBrowse?.call(),
          icon: const Icon(Icons.arrow_back, size: 16),
          label: Text('Back to ${widget.config.table}'),
        ),
      ],
      const Spacer(),
      OutlinedButton.icon(
        onPressed: _running ? null : () => _meta == null ? _loadMeta() : _run(),
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('Refresh'),
      ),
    ]);
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade800 : null,
      duration: const Duration(seconds: 3),
    ));
  }

  Card _card({required Widget child}) => Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(padding: const EdgeInsets.all(11), child: child),
      );

  Widget _queryCard() => _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: () => setState(() => _panelOpen = !_panelOpen),
            child: Row(children: [
              Icon(_panelOpen ? Icons.expand_more : Icons.chevron_right, size: 20),
              const SizedBox(width: 4),
              const Text('Scan or query items',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ]),
          ),
          if (!_panelOpen)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text('Expand to query or scan items.',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ),
          if (_panelOpen) ...[
            const SizedBox(height: 10),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Scan'), icon: Icon(Icons.list, size: 16)),
                ButtonSegment(value: true, label: Text('Query'), icon: Icon(Icons.search, size: 16)),
              ],
              selected: {_isQuery},
              onSelectionChanged: (s) => setState(() => _isQuery = s.first),
            ),
            const SizedBox(height: 9),
            _targetDropdown(),
            const SizedBox(height: 12),
            _projectionRow(),
            if (_isQuery) ...[
              const SizedBox(height: 10),
              _queryKeys(),
            ],
            const SizedBox(height: 8),
            _filtersSection(),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton(
                onPressed: _running ? null : () => _run(),
                child: _running
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Run'),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: _reset, child: const Text('Reset')),
            ]),
          ],
        ]),
      );

  Widget _targetDropdown() {
    final targets = _meta!.targets;
    return _labeled(
      'Select a table or index',
      DropdownButtonFormField<int>(
        initialValue: _targetIdx,
        isDense: true,
        decoration: _dec(),
        items: [
          for (var i = 0; i < targets.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(targets[i].isTable
                  ? 'Table - ${targets[i].name}'
                  : 'Index - ${targets[i].name}'),
            ),
        ],
        onChanged: (v) => setState(() {
          _targetIdx = v ?? 0;
          _skOp = 'eq';
        }),
      ),
    );
  }

  Widget _projectionRow() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _labeled(
        'Select attribute projection',
        DropdownButtonFormField<String>(
          initialValue: _projection,
          isDense: true,
          decoration: _dec(),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All attributes')),
            DropdownMenuItem(value: 'specific', child: Text('Specific attributes')),
          ],
          onChanged: (v) => setState(() => _projection = v ?? 'all'),
        ),
      ),
      if (_projection == 'specific') ...[
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _projectInput,
              decoration: _dec(hint: 'Enter attribute name'),
              onSubmitted: (_) => _addProjectAttr(),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _addProjectAttr, child: const Text('Add attribute')),
        ]),
        if (_projectAttrs.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in _projectAttrs)
                Chip(
                  label: Text(a),
                  onDeleted: () => setState(() => _projectAttrs.remove(a)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ],
    ]);
  }

  void _addProjectAttr() {
    final a = _projectInput.text.trim();
    if (a.isEmpty || _projectAttrs.contains(a)) return;
    setState(() {
      _projectAttrs.add(a);
      _projectInput.clear();
    });
  }

  Widget _queryKeys() {
    final t = _target;
    if (t == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Partition key', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(flex: 2, child: _readonlyAttr(t.pk.name)),
        const SizedBox(width: 12),
        Expanded(
          flex: 5,
          child: TextField(controller: _pk, decoration: _dec(hint: 'Enter attribute value')),
        ),
      ]),
      if (t.sk != null) ...[
        const SizedBox(height: 16),
        const Text('Sort key ', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 2, child: _readonlyAttr(t.sk!.name)),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              initialValue: _skOp,
              isDense: true,
              decoration: _dec(),
              items: [
                for (final c in _skConds) DropdownMenuItem(value: c.$1, child: Text(c.$2)),
              ],
              onChanged: (v) => setState(() => _skOp = v ?? 'eq'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Column(children: [
              TextField(controller: _skV1, decoration: _dec(hint: 'Enter attribute value')),
              if (_skOp == 'between') ...[
                const SizedBox(height: 6),
                TextField(controller: _skV2, decoration: _dec(hint: 'and')),
              ],
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Checkbox(
            value: _sortDesc,
            onChanged: (v) => setState(() => _sortDesc = v ?? false),
            visualDensity: VisualDensity.compact,
          ),
          const Text('Sort descending'),
        ]),
      ],
    ]);
  }

  // Filters — matches the AWS Explore-items layout verbatim: header "Filters –
  // optional", one horizontal row per filter under shared column headers, fields
  // in the order [Attribute name] [Condition] [Type] [Value] [Remove], and an
  // "Add filter" button.
  static const _fFlex = [4, 3, 2, 4]; // attribute / condition / type / value
  static const double _fRemoveW = 104;

  Widget _filtersSection() {
    final scheme = Theme.of(context).colorScheme;
    final label = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(height: 24),
      Text.rich(TextSpan(children: [
        const TextSpan(text: 'Filters', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        TextSpan(
            text: '  – optional',
            style: TextStyle(fontStyle: FontStyle.italic, fontSize: 13, color: scheme.onSurfaceVariant)),
      ])),
      const SizedBox(height: 10),
      if (_filters.isNotEmpty) ...[
        Row(children: [
          Expanded(flex: _fFlex[0], child: Text('Attribute name', style: label)),
          const SizedBox(width: 10),
          Expanded(flex: _fFlex[1], child: Text('Condition', style: label)),
          const SizedBox(width: 10),
          Expanded(flex: _fFlex[2], child: Text('Type', style: label)),
          const SizedBox(width: 10),
          Expanded(flex: _fFlex[3], child: Text('Value', style: label)),
          const SizedBox(width: 10),
          const SizedBox(width: _fRemoveW),
        ]),
        const SizedBox(height: 6),
        for (var i = 0; i < _filters.length; i++) _filterRow(i),
        const SizedBox(height: 4),
      ],
      OutlinedButton.icon(
        onPressed: () => setState(() => _filters.add(_FilterRow())),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Add filter'),
      ),
    ]);
  }

  Widget _filterRow(int i) {
    final f = _filters[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: _fFlex[0],
          child: TextField(
            controller: f.attr,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 16),
              prefixIconConstraints: BoxConstraints(minWidth: 32, minHeight: 32),
              hintText: 'Enter attribute name',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: _fFlex[1],
          child: DropdownButtonFormField<String>(
            initialValue: f.op,
            isDense: true,
            decoration: _dec(),
            items: [for (final c in _filterConds) DropdownMenuItem(value: c.$1, child: Text(c.$2))],
            onChanged: (v) => setState(() => f.op = v ?? 'eq'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: _fFlex[2],
          child: DropdownButtonFormField<String>(
            initialValue: f.type,
            isDense: true,
            decoration: _dec(),
            items: [for (final t in _filterTypes) DropdownMenuItem(value: t.$1, child: Text(t.$2))],
            onChanged: f.needsValue ? (v) => setState(() => f.type = v ?? 'S') : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: _fFlex[3],
          child: !f.needsValue
              ? TextField(enabled: false, decoration: _dec(hint: 'Not required'))
              : f.needsTwo
                  ? Row(children: [
                      Expanded(child: TextField(controller: f.v1, decoration: _dec(hint: 'Enter attribute value'))),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('and'),
                      ),
                      Expanded(child: TextField(controller: f.v2, decoration: _dec(hint: 'Enter attribute value'))),
                    ])
                  : TextField(controller: f.v1, decoration: _dec(hint: 'Enter attribute value')),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: _fRemoveW,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: OutlinedButton(
              onPressed: () => setState(() => _filters.removeAt(i).dispose()),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 44),
              ),
              child: const Text('Remove', maxLines: 1),
            ),
          ),
        ),
      ]),
    );
  }

  // ---- result banner + grid ----

  Widget _banner() {
    final scheme = Theme.of(context).colorScheme;
    if (_pageError != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.error),
        ),
        child: Row(children: [
          Icon(Icons.error_outline, color: scheme.error, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(_pageError!, style: TextStyle(color: scheme.onErrorContainer))),
        ]),
      );
    }
    return const SizedBox.shrink(); // success shows no banner (AWS parity)
  }

  // Whether item-level writes are offered here (endpoint mode, base table only,
  // and not while browsing another table read-only via the Endpoint tab).
  bool get _canWriteItems {
    final t = _target;
    return !_awsMode && !_foreignBrowse && (t == null || t.isTable);
  }

  Widget _resultsCard() {
    final p = _page!;
    final cols = p.cols.where((c) => !_hiddenCols.contains(c)).toList();
    final rows = _sortedRows(p.rows);
    final t = _target;
    final scheme = Theme.of(context).colorScheme;
    final selCount = _checked.length;
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // AWS Explore-items toolbar: "Items returned (N)" left; refresh,
        // pagination, preferences, Actions and Create item on the right.
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Items returned (${p.returned})',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              Text(
                '${t != null && !t.isTable ? 'Index ${t.name} · ' : ''}'
                'Items scanned: ${p.scanned} · ${(p.efficiency * 100).round()}% · ${p.timeMs} ms'
                '${selCount > 0 ? ' · $selCount selected' : ''}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ]),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _running ? null : () => _run(),
            icon: const Icon(Icons.refresh, size: 18),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: _pageIdx == 0 || _running ? null : _prevPage,
            icon: const Icon(Icons.chevron_left, size: 20),
          ),
          Text('${_pageIdx + 1}'),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: p.hasNext && !_running ? _nextPage : null,
            icon: const Icon(Icons.chevron_right, size: 20),
          ),
          IconButton(
            tooltip: 'Preferences',
            onPressed: _openPreferences,
            icon: const Icon(Icons.settings, size: 18),
          ),
          if (_canWriteItems) ...[
            const SizedBox(width: 6),
            MenuAnchor(
              builder: (ctx, ctrl, _) => OutlinedButton.icon(
                onPressed: () => ctrl.isOpen ? ctrl.close() : ctrl.open(),
                icon: const Icon(Icons.arrow_drop_down, size: 18),
                label: const Text('Actions'),
              ),
              menuChildren: [
                MenuItemButton(
                  onPressed: selCount == 1 ? () => _openEditor(from: _selectedItem(rows), isNew: false) : null,
                  child: const Text('Edit item'),
                ),
                MenuItemButton(
                  onPressed: selCount == 1 ? () => _openEditor(from: _selectedItem(rows), isNew: true) : null,
                  child: const Text('Duplicate item'),
                ),
                MenuItemButton(
                  onPressed: selCount >= 1 ? () => _deleteSelected(rows) : null,
                  child: const Text('Delete items'),
                ),
                const Divider(height: 4),
                MenuItemButton(
                  onPressed: rows.isEmpty ? null : () => _exportCsv(cols, rows),
                  child: const Text('Export to CSV'),
                ),
              ],
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _openEditor(from: null, isNew: true),
              child: const Text('Create item'),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(children: [
                Icon(Icons.inbox_outlined, size: 36, color: Theme.of(context).hintColor),
                const SizedBox(height: 8),
                const Text('No items'),
                const SizedBox(height: 4),
                Text('No items to display. Adjust the scan or query above.',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
              ]),
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              headingRowHeight: 30,
              dataRowMinHeight: 28,
              dataRowMaxHeight: 34,
              onSelectAll: (v) => setState(() {
                _checked.clear();
                if (v == true) _checked.addAll(rows.map((r) => r.ddbJson));
              }),
              columns: [
                for (final c in cols)
                  DataColumn(
                    label: _colHeader(c),
                    onSort: (_, __) => setState(() {
                      if (_sortCol == c) {
                        _sortAsc = !_sortAsc;
                      } else {
                        _sortCol = c;
                        _sortAsc = true;
                      }
                    }),
                  ),
              ],
              rows: [
                for (final r in rows)
                  DataRow(
                    selected: _checked.contains(r.ddbJson),
                    // Checkbox / row click = select (AWS behaviour); the pk cell
                    // is the link that opens the item.
                    onSelectChanged: (v) => setState(() {
                      if (v == true) {
                        _checked.add(r.ddbJson);
                      } else {
                        _checked.remove(r.ddbJson);
                      }
                    }),
                    cells: [
                      for (final c in cols)
                        c == t?.pk.name
                            ? DataCell(
                                _pkText(r.cells[c]),
                                // onTap here wins over the row's onSelectChanged,
                                // so the pk cell is the item link while the rest of
                                // the row / checkbox handles selection.
                                onTap: () => _canWriteItems
                                    ? _openEditor(from: r, isNew: false)
                                    : _showItemViewer(r),
                              )
                            : DataCell(_cellWidget(r.cells[c])),
                    ],
                  ),
              ],
            ),
          ),
      ]),
    );
  }

  // The partition-key cell — rendered as a link (the DataCell.onTap opens it).
  Widget _pkText(AttrCell? cell) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Text(
        cell?.repr ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary.withValues(alpha: 0.4)),
      ),
    );
  }

  TableItem? _selectedItem(List<TableItem> rows) {
    for (final r in rows) {
      if (_checked.contains(r.ddbJson)) return r;
    }
    return null;
  }

  Widget _colHeader(String c) {
    final t = _target;
    String? typ;
    if (t != null) {
      if (t.pk.name == c) typ = t.pk.type;
      if (t.sk?.name == c) typ = t.sk!.type;
    }
    final typeName = {'S': 'String', 'N': 'Number', 'B': 'Binary'}[typ];
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(c, style: const TextStyle(fontWeight: FontWeight.w600)),
      if (typeName != null)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text('($typeName)',
              style: TextStyle(
                  fontStyle: FontStyle.italic, fontSize: 11, color: Theme.of(context).hintColor)),
        ),
      if (_sortCol == c)
        Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12),
    ]);
  }

  Widget _cellWidget(AttrCell? cell) {
    if (cell == null) return const SizedBox.shrink();
    final text = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Text(cell.repr, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    if (cell.isBinary && cell.printable && cell.b64 != null) {
      return Tooltip(message: 'base64: ${cell.b64}', child: text);
    }
    return text;
  }

  List<TableItem> _sortedRows(List<TableItem> rows) {
    if (_sortCol == null) return rows;
    final sorted = [...rows];
    sorted.sort((a, b) {
      final av = a.cells[_sortCol]?.repr ?? '';
      final bv = b.cells[_sortCol]?.repr ?? '';
      final cmp = av.compareTo(bv);
      return _sortAsc ? cmp : -cmp;
    });
    return sorted;
  }

  // ---- dialogs ----

  void _openPreferences() {
    final cols = _page?.cols ?? [];
    showDialog<void>(
      context: context,
      builder: (ctx) {
        int size = _pageSize;
        final hidden = {..._hiddenCols};
        return StatefulBuilder(builder: (ctx, setD) {
          return AlertDialog(
            title: const Text('Preferences'),
            content: SizedBox(
              width: 460,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    const Text('Page size', style: TextStyle(fontWeight: FontWeight.w600)),
                    RadioGroup<int>(
                      groupValue: size,
                      onChanged: (v) => setD(() => size = v ?? size),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final s in _pageSizes)
                          RadioListTile<int>(
                            value: s,
                            title: Text('$s items'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                      ]),
                    ),
                  ]),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      TextButton(onPressed: () => setD(() => hidden.clear()), child: const Text('Select all')),
                      TextButton(onPressed: () => setD(() => hidden.addAll(cols)), child: const Text('Deselect all')),
                    ]),
                    for (final c in cols)
                      SwitchListTile(
                        value: !hidden.contains(c),
                        onChanged: (v) => setD(() => v ? hidden.remove(c) : hidden.add(c)),
                        title: Text(c, overflow: TextOverflow.ellipsis),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                  ]),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  final resize = size != _pageSize;
                  setState(() {
                    _pageSize = size;
                    _hiddenCols
                      ..clear()
                      ..addAll(hidden);
                  });
                  if (resize) _run();
                },
                child: const Text('Save changes'),
              ),
            ],
          );
        });
      },
    );
  }

  // ---- item flows (AWS Explore-items parity) ----

  /// Opens the full-page item editor. Edit and Duplicate first re-fetch the FULL
  /// item via GetItem — a Save is a PutItem full-replace, so editing the
  /// (possibly projection-truncated) scan result would silently drop the
  /// attributes the scan didn't return.
  Future<void> _openEditor({required TableItem? from, required bool isNew}) async {
    final t = _target;
    if (t == null || !_canWriteItems) return;
    var initial = <String, dynamic>{};
    if (from != null) {
      final key = _keyOf(from);
      if (key == null) {
        _toast('This result doesn’t include the item’s full key (projection) — '
            'switch to “All attributes” first.', error: true);
        return;
      }
      final res = widget.core.tableGetItem(widget.config, key);
      if (res['ok'] == true && res['item'] is Map) {
        initial = (res['item'] as Map).cast<String, dynamic>();
      } else {
        _toast('Couldn’t fetch the full item: ${res['error'] ?? 'error'}', error: true);
        return;
      }
    }
    if (!mounted) return;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ItemEditorPage(
        table: widget.config.table,
        target: t,
        isNew: isNew,
        initial: initial,
        onSave: (av) async {
          if (!await _confirmRawWrite('Write')) return ''; // '' = cancelled
          final res = widget.core.tablePutItem(widget.config, av);
          return res['ok'] == true ? null : '${res['error'] ?? 'save failed'}';
        },
      ),
    ));
    if (!mounted || saved != true) return;
    _toast(isNew ? 'Item created' : 'Item saved');
    _run(resetPaging: false);
  }

  /// Read-only DynamoDB-JSON viewer (AWS mode / index targets).
  void _showItemViewer(TableItem r) {
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(r.ddbJson));
    } catch (_) {
      pretty = r.ddbJson;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Expanded(child: Text('Item (DynamoDB JSON)')),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pretty));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
        ]),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(pretty,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  // Extract the primary-key attribute-value map from an item's DynamoDB-JSON, or
  // null if the key isn't fully present (e.g. projected away).
  Map<String, dynamic>? _keyOf(TableItem r) {
    final t = _target;
    if (t == null) return null;
    try {
      final m = (jsonDecode(r.ddbJson) as Map).cast<String, dynamic>();
      if (m[t.pk.name] == null) return null;
      final key = <String, dynamic>{t.pk.name: m[t.pk.name]};
      if (t.sk != null) {
        if (m[t.sk!.name] == null) return null;
        key[t.sk!.name] = m[t.sk!.name];
      }
      return key;
    } catch (_) {
      return null;
    }
  }

  /// Actions → Delete items: bulk-delete every checked row (single merged
  /// confirmation carrying the redimos raw-write warning).
  Future<void> _deleteSelected(List<TableItem> rows) async {
    final items = rows.where((r) => _checked.contains(r.ddbJson)).toList();
    if (items.isEmpty) return;
    final keys = <Map<String, dynamic>>[];
    for (final r in items) {
      final k = _keyOf(r);
      if (k == null) {
        _toast('A selected item is missing its key attributes (projection?)', error: true);
        return;
      }
      keys.add(k);
    }
    final scheme = Theme.of(context).colorScheme;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${keys.length} item(s)?'),
        content: SizedBox(
          width: 440,
          child: Text(
            'This permanently deletes ${keys.length} item(s) from "${widget.config.table}", '
            'writing directly to DynamoDB and bypassing redimos’s encoding — for redimos data, '
            'prefer the Browser or Console tab.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    var failed = 0;
    for (final k in keys) {
      final res = widget.core.tableDeleteItem(widget.config, k);
      if (res['ok'] != true) failed++;
    }
    if (!mounted) return;
    _toast(failed == 0
        ? 'Deleted ${keys.length} item(s)'
        : 'Deleted ${keys.length - failed}, $failed failed', error: failed > 0);
    _run(resetPaging: false);
  }

  /// Actions → Export to CSV: the current page's visible columns/rows, written
  /// to ~/Downloads (falls back to the clipboard if the write fails).
  Future<void> _exportCsv(List<String> cols, List<TableItem> rows) async {
    String q(String s) => '"${s.replaceAll('"', '""')}"';
    final buf = StringBuffer()..writeln(cols.map(q).join(','));
    for (final r in rows) {
      buf.writeln(cols.map((c) => q(r.cells[c]?.repr ?? '')).join(','));
    }
    final csv = buf.toString();
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) throw const FileSystemException('no HOME');
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '$home/Downloads/redimos-${widget.config.table}-$ts.csv';
      await File(path).writeAsString(csv);
      _toast('Exported ${rows.length} row(s) → $path');
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: csv));
      _toast('Couldn’t write to Downloads — CSV copied to clipboard instead');
    }
  }

  // Strong confirmation before a raw item write on a redimos table.
  Future<bool> _confirmRawWrite(String verb) async {
    final scheme = Theme.of(context).colorScheme;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$verb a raw item on a redimos table?'),
        content: const SizedBox(
          width: 430,
          child: Text(
            'This writes directly to DynamoDB, bypassing redimos’s key/value encoding. '
            'An item that doesn’t match redimos’s format can corrupt what the proxy reads — '
            'for redimos data, prefer the Browser or Console tab. Continue anyway?',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('$verb anyway'),
          ),
        ],
      ),
    );
    return go == true;
  }

  // ---- small helpers ----

  InputDecoration _dec({String? hint}) => InputDecoration(
        isDense: true,
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      );

  Widget _labeled(String label, Widget field) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
        const SizedBox(height: 3),
        field,
      ]);

  Widget _readonlyAttr(String name) => InputDecorator(
        decoration: _dec(),
        child: Text(name.isEmpty ? '—' : name),
      );

  Widget _center(IconData icon, String title, String subtitle, {Widget? action}) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          if (action != null) ...[const SizedBox(height: 16), action],
        ]),
      );
}
