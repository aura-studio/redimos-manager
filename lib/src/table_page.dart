// The "Table" tab — a read-only DynamoDB item browser modelled on the AWS
// console's Explore-items page, adapted for redimos tables (Binary keys shown as
// readable UTF-8 text, base64 on hover). Scan / Query with projection, sort-key
// conditions, filters, DynamoDB-style pagination, column preferences, and a
// per-item DynamoDB-JSON dialog. All data comes from the Go core's
// rm_table_meta / rm_table_page over FFI.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

class TablePageView extends StatefulWidget {
  final NativeCore core;
  final RedimosConfig config;
  final bool running;
  const TablePageView(
      {super.key, required this.core, required this.config, required this.running});

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
        old.config.endpoint != widget.config.endpoint) {
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
    final m = widget.core.tableMeta(widget.config);
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
      'config': widget.config.toJson(),
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
      return _center(Icons.table_chart_outlined, 'Instance not running',
          'Start this config to browse its DynamoDB table.');
    }
    if (widget.config.table.trim().isEmpty) {
      return _center(Icons.table_chart_outlined, 'No table configured',
          'Set a Table name in Configure to browse it.');
    }
    if (_loadingMeta && _meta == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_metaError != null) {
      return _center(Icons.error_outline, 'Cannot read table', _metaError!,
          action: FilledButton.icon(
              onPressed: _loadMeta, icon: const Icon(Icons.refresh), label: const Text('Retry')));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _headerRow(),
        const SizedBox(height: 12),
        _queryCard(),
        if (_page != null || _pageError != null) ...[
          const SizedBox(height: 12),
          _banner(),
        ],
        if (_page != null) ...[
          const SizedBox(height: 12),
          _resultsCard(),
        ],
      ]),
    );
  }

  Widget _headerRow() => Row(children: [
        Icon(Icons.table_chart, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(widget.config.table,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _running ? null : () => _run(),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Refresh'),
        ),
      ]);

  Card _card({required Widget child}) => Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );

  Widget _queryCard() => _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: () => setState(() => _panelOpen = !_panelOpen),
            child: Row(children: [
              Icon(_panelOpen ? Icons.expand_more : Icons.chevron_right, size: 20),
              const SizedBox(width: 4),
              const Text('Scan or query items',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ]),
          ),
          if (!_panelOpen)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text('Expand to query or scan items.',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ),
          if (_panelOpen) ...[
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Scan'), icon: Icon(Icons.list, size: 16)),
                ButtonSegment(value: true, label: Text('Query'), icon: Icon(Icons.search, size: 16)),
              ],
              selected: {_isQuery},
              onSelectionChanged: (s) => setState(() => _isQuery = s.first),
            ),
            const SizedBox(height: 14),
            _targetDropdown(),
            const SizedBox(height: 12),
            _projectionRow(),
            if (_isQuery) ...[
              const SizedBox(height: 16),
              _queryKeys(),
            ],
            const SizedBox(height: 8),
            _filtersSection(),
            const SizedBox(height: 16),
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

  Widget _filtersSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(height: 24),
      Text('Filters ', style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
      const SizedBox(height: 10),
      for (var i = 0; i < _filters.length; i++) _filterRow(i),
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
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: _labeled(
              'Attribute name',
              TextField(controller: f.attr, decoration: _dec(hint: 'Enter attribute name')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _labeled(
              'Condition',
              DropdownButtonFormField<String>(
                initialValue: f.op,
                isDense: true,
                decoration: _dec(),
                items: [for (final c in _filterConds) DropdownMenuItem(value: c.$1, child: Text(c.$2))],
                onChanged: (v) => setState(() => f.op = v ?? 'eq'),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: _labeled(
              'Type',
              DropdownButtonFormField<String>(
                initialValue: f.type,
                isDense: true,
                decoration: _dec(),
                items: [for (final t in _filterTypes) DropdownMenuItem(value: t.$1, child: Text(t.$2))],
                onChanged: f.needsValue ? (v) => setState(() => f.type = v ?? 'S') : null,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _labeled(
              'Value',
              f.needsValue
                  ? Column(children: [
                      TextField(controller: f.v1, decoration: _dec(hint: 'Enter attribute value')),
                      if (f.needsTwo) ...[
                        const SizedBox(height: 6),
                        TextField(controller: f.v2, decoration: _dec(hint: 'and')),
                      ],
                    ])
                  : TextField(enabled: false, decoration: _dec(hint: 'Not required')),
            ),
          ),
        ]),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton(
            onPressed: () => setState(() {
              _filters.removeAt(i).dispose();
            }),
            child: const Text('Remove'),
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
    final p = _page!;
    const ok = Color(0xFF2E7D32);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ok),
        color: ok.withValues(alpha: 0.10),
      ),
      child: Row(children: [
        const Icon(Icons.check_circle, color: ok, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Completed · Items returned: ${p.returned} · Items scanned: ${p.scanned} · '
            'Efficiency: ${(p.efficiency * 100).round()}% · ${p.timeMs} ms',
          ),
        ),
      ]),
    );
  }

  Widget _resultsCard() {
    final p = _page!;
    final cols = p.cols.where((c) => !_hiddenCols.contains(c)).toList();
    final rows = _sortedRows(p.rows);
    final t = _target;
    final title = (t != null && !t.isTable)
        ? 'Index: ${t.name} (${widget.config.table})'
        : 'Table: ${widget.config.table}';
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('$title — Items returned (${p.returned})',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _running ? null : () => _run(),
            icon: const Icon(Icons.refresh, size: 18),
          ),
          IconButton(
            tooltip: 'Preferences',
            onPressed: _openPreferences,
            icon: const Icon(Icons.settings, size: 18),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          IconButton(
            onPressed: _pageIdx == 0 || _running ? null : _prevPage,
            icon: const Icon(Icons.chevron_left, size: 20),
          ),
          Text('${_pageIdx + 1}'),
          IconButton(
            onPressed: p.hasNext && !_running ? null : (p.hasNext ? _nextPage : null),
            icon: Icon(Icons.chevron_right,
                size: 20, color: p.hasNext ? null : Theme.of(context).disabledColor),
          ),
          if (p.hasNext)
            TextButton(onPressed: _running ? null : _nextPage, child: const Text('Next page')),
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
              columnSpacing: 28,
              headingRowHeight: 40,
              dataRowMinHeight: 38,
              dataRowMaxHeight: 44,
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
                    onSelectChanged: (_) => _showItemJson(r),
                    cells: [for (final c in cols) DataCell(_cellWidget(r.cells[c]))],
                  ),
              ],
            ),
          ),
      ]),
    );
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

  void _showItemJson(TableItem r) {
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
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Copied')));
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

  // ---- small helpers ----

  InputDecoration _dec({String? hint}) => InputDecoration(
        isDense: true,
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      );

  Widget _labeled(String label, Widget field) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        const SizedBox(height: 4),
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
