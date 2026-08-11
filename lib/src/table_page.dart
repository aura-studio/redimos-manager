// The DynamoDB item **Explorer** — modelled on the AWS console's Explore-items
// page, adapted for redimos tables (Binary keys shown as readable UTF-8 text,
// base64 on hover). Hosted as the right pane of the endpoint Browser
// (endpoint_browser.dart), pointed at the Tables-sidebar selection via
// tableOverride. Scan / Query with projection, sort-key conditions, filters,
// DynamoDB-style pagination, column preferences, checkbox multi-select with an
// Actions menu (Edit / Duplicate / Delete items / Export to CSV), pk links into
// a full-page Form|JSON item editor, and a Create item button. Item writes are
// offered on non-AWS endpoints (allowOverrideWrites) and carry the redimos
// raw-write confirmation. All data comes from the Go core over FFI.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';
import 'item_editor.dart';
import 'models.dart';
import 'native.dart';
import 'ui_tokens.dart';

// The second tuple element is an i18n key (translated at render), not display text.
const _skConds = [
  ('eq', 'tbl.condEq'),
  ('le', 'tbl.condLe'),
  ('lt', 'tbl.condLt'),
  ('ge', 'tbl.condGe'),
  ('gt', 'tbl.condGt'),
  ('between', 'tbl.condBetween'),
  ('begins_with', 'tbl.condBeginsWith'),
];

const _filterConds = [
  ('eq', 'tbl.condEq'),
  ('ne', 'tbl.condNe'),
  ('le', 'tbl.condLe'),
  ('lt', 'tbl.condLt'),
  ('ge', 'tbl.condGe'),
  ('gt', 'tbl.condGt'),
  ('between', 'tbl.condBetween'),
  ('exists', 'tbl.condExists'),
  ('not_exists', 'tbl.condNotExists'),
  ('contains', 'tbl.condContains'),
  ('not_contains', 'tbl.condNotContains'),
  ('begins_with', 'tbl.condBeginsWith'),
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

// A denser theme for the data surfaces (Explorer / PartiQL / Browser): smaller
// controls and tighter tap targets so these dense query/browse surfaces read as
// compact and refined instead of chunky. Applied at each surface's root.
ThemeData _denseTabTheme(BuildContext context) => Theme.of(context).copyWith(
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

class TablePageView extends StatefulWidget {
  final NativeCore core;
  final RedimosConfig config;
  // The endpoint Browser's Tables-sidebar selection: browse THAT table on the
  // endpoint instead of config.table (which is empty for endpoint storage
  // configs).
  final String? tableOverride;

  /// Endpoint Browser mode: the override IS the view's purpose (the endpoint is
  /// the authority on its own data), so item writes are offered for the override
  /// table on non-AWS endpoints; on AWS the view stays read-only.
  final bool allowOverrideWrites;

  /// The endpoint Browser's bridge into this state (its MidBar "＋ Item" CTA
  /// → [TablePageViewState.createItem]); called once the state exists.
  final void Function(TablePageViewState)? onExplorerReady;
  const TablePageView(
      {super.key,
      required this.core,
      required this.config,
      this.tableOverride,
      this.allowOverrideWrites = false,
      this.onExplorerReady});

  @override
  State<TablePageView> createState() => TablePageViewState();
}

// Public state: the endpoint Browser reaches createItem() through onExplorerReady.
class TablePageViewState extends State<TablePageView>
    with AutomaticKeepAliveClientMixin {
  TableMeta? _meta;
  String? _metaError;
  bool _loadingMeta = false;

  // query form
  // Flat (endpoint Browser) mode starts with the advanced form collapsed —
  // the valuepane head's SCAN FILTER is the everyday tool; the classic
  // instance Browse keeps the form open as before. `late` so _flat (via
  // widget) is readable at first use.
  late bool _panelOpen = !_flat;
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
  // v2.3 endpoint Browser: the single SCAN FILTER box in the valuepane head
  // (client-side contains-filter over the loaded page's cell reprs; the full
  // Scan/Query form still lives in the collapsed advanced card).
  final _scanFilter = TextEditingController();

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
    widget.onExplorerReady?.call(this);
    _loadMeta();
  }

  @override
  void didUpdateWidget(TablePageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.id != widget.config.id ||
        oldWidget.config.table != widget.config.table ||
        oldWidget.config.endpoint != widget.config.endpoint ||
        oldWidget.tableOverride != widget.tableOverride) {
      _resetAll();
      _loadMeta();
    }
  }

  @override
  void dispose() {
    _scanFilter.dispose();
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
    _scanFilter.clear();
    _sortDesc = false;
    for (final f in _filters) {
      f.dispose();
    }
    _filters.clear();
    _panelOpen = !_flat;
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
        _metaError = m.error ?? tr('tbl.failedDescribeTable');
      }
    });
    if (m.ok) _run(); // auto-scan on open, like the console's Autopreview
  }

  TableTarget? get _target =>
      (_meta != null && _targetIdx < _meta!.targets.length) ? _meta!.targets[_targetIdx] : null;

  // v2.3 endpoint Browser = the flat item table: the header strip, the
  // advanced Scan/Query card and the in-page Create button are all folded
  // into the valuepane head (endpoint mode only; an instance's own Browse
  // keeps the full form, where Scan/Query IS the workflow).
  bool get _flat => widget.tableOverride != null;

  // MidBar bridge (T12): the endpoint Browser's "＋ Item" end-group CTA calls
  // this; it is exactly the toolbar's Create-item flow.
  void createItem() {
    if (_canWriteItems) _openEditor(from: null, isNew: true);
  }

  // Rows surviving the valuepane-head SCAN FILTER (client-side, case
  // insensitive, matched against any visible cell's repr — the scan itself is
  // unchanged, this only narrows what's rendered).
  List<TableItem> _visibleRows(TablePage p) {
    final q = _scanFilter.text.trim().toLowerCase();
    final rows = _sortedRows(p.rows);
    if (q.isEmpty) return rows;
    return rows
        .where((r) => r.cells.values.any((c) => c.repr.toLowerCase().contains(q)))
        .toList();
  }

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
        _pageError = page.error ?? tr('tbl.queryFailed');
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
    // Gate on the EFFECTIVE table (override included) so the Explorer — whose
    // config.table is empty — becomes usable the moment a table is picked in
    // the Browser's Tables sidebar.
    if (_effTable.trim().isEmpty) {
      return _center(Icons.table_chart_outlined, tr('tbl.noTableConfigured'),
          tr('tbl.setTableNameToBrowse'));
    }
    return Theme(
      data: _denseTabTheme(context),
      child: SingleChildScrollView(
      padding: EdgeInsets.all(_flat ? 0 : 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // The header (AWS read-only chip / foreign-browse controls) always
        // renders, even when the table can't be read — so the safety state
        // stays legible and a table that was just deleted can still be
        // recreated from here. In flat mode the valuepane head carries the
        // table name + refresh, so the strip collapses to the AWS chip.
        if (!_flat || _awsMode) _headerRow(),
        if (!_flat || _awsMode) const SizedBox(height: 12),
        if (_loadingMeta && _meta == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 60),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_metaError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: _center(Icons.error_outline, tr('tbl.cannotReadTable'), _metaError!,
                action: FilledButton.icon(
                    onPressed: _loadMeta,
                    icon: const Icon(Icons.refresh),
                    label: Text(tr('tbl.retry')))),
          )
        else ...[
          // Flat mode: the advanced Scan/Query form is one tap away (the
          // valuepane head's tune toggle) but never in the way — the single
          // SCAN FILTER box covers the common case.
          if (!_flat || _panelOpen)
            Padding(
              padding: _flat ? const EdgeInsets.all(12) : EdgeInsets.zero,
              child: _queryCard(),
            ),
          if (!_flat && _pageError != null) ...[
            const SizedBox(height: 12),
            _banner(),
          ],
          if (_flat && _pageError != null)
            Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: _banner()),
          if (_page != null) ...[
            if (!_flat) const SizedBox(height: 12),
            _resultsCard(),
          ],
        ],
      ]),
    ));
  }

  // AWS mode (no endpoint) is read-only for item writes: the manager can't tell a
  // test account from production. Destructive table lifecycle (recreate / provision
  // / delete) lives in the endpoint Browser's Tables sidebar (table_lifecycle.dart)
  // — this page is just the item browser/editor (AWS-console "Explore items" parity).
  bool get _awsMode {
    final ep = widget.config.endpoint.trim();
    if (ep.isEmpty) return true; // default AWS resolver
    final host = (Uri.tryParse(ep)?.host ?? '').toLowerCase();
    return host == 'amazonaws.com' ||
        host.endsWith('.amazonaws.com') ||
        host.endsWith('.amazonaws.com.cn'); // explicit AWS host (incl. China partition)
  }

  // Browse-any-table: the endpoint Browser's Tables sidebar points this view at
  // the selected table on the same endpoint. It is browsed via a config copy with
  // the table swapped; endpoint/creds stay the config's own. Writes on the
  // override table are offered when allowOverrideWrites is set (non-AWS).
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
      // The endpoint Browser owns its selection, so no transient browse chrome
      // shows there; on AWS the amber chip below carries the read-only message.
      if (_awsMode) ...[
        const SizedBox(width: 10),
        Chip(
          visualDensity: VisualDensity.compact,
          avatar: Icon(Icons.lock_outline, size: 15, color: Colors.amber.shade700),
          label: Text(tr('ep.awsReadOnly'),
              style: TextStyle(color: Colors.amber.shade700)),
        ),
      ],
      const Spacer(),
      OutlinedButton.icon(
        onPressed: _running ? null : () => _meta == null ? _loadMeta() : _run(),
        icon: const Icon(Icons.refresh, size: 18),
        label: Text(tr('tbl.refresh')),
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
              Text(tr('tbl.scanOrQueryItems'),
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ]),
          ),
          if (!_panelOpen)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(tr('tbl.expandToQueryOrScan'),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ),
          if (_panelOpen) ...[
            const SizedBox(height: 10),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(tr('tbl.scan')), icon: const Icon(Icons.list, size: 16)),
                ButtonSegment(value: true, label: Text(tr('tbl.query')), icon: const Icon(Icons.search, size: 16)),
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
                    : Text(tr('tbl.run')),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: _reset, child: Text(tr('tbl.reset'))),
            ]),
          ],
        ]),
      );

  Widget _targetDropdown() {
    final targets = _meta!.targets;
    return _labeled(
      tr('tbl.selectTableOrIndex'),
      DropdownButtonFormField<int>(
        initialValue: _targetIdx,
        isDense: true,
        decoration: _dec(),
        items: [
          for (var i = 0; i < targets.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(targets[i].isTable
                  ? '${tr('tbl.tableLabel')} - ${targets[i].name}'
                  : '${tr('tbl.indexLabel')} - ${targets[i].name}'),
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
        tr('tbl.selectAttributeProjection'),
        DropdownButtonFormField<String>(
          initialValue: _projection,
          isDense: true,
          decoration: _dec(),
          items: [
            DropdownMenuItem(value: 'all', child: Text(tr('tbl.allAttributes'))),
            DropdownMenuItem(value: 'specific', child: Text(tr('tbl.specificAttributes'))),
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
              decoration: _dec(hint: tr('tbl.enterAttributeName')),
              onSubmitted: (_) => _addProjectAttr(),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _addProjectAttr, child: Text(tr('tbl.addAttribute'))),
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
      Text(tr('tbl.partitionKey'), style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(flex: 2, child: _readonlyAttr(t.pk.name)),
        const SizedBox(width: 12),
        Expanded(
          flex: 5,
          child: TextField(controller: _pk, decoration: _dec(hint: tr('tbl.enterAttributeValue'))),
        ),
      ]),
      if (t.sk != null) ...[
        const SizedBox(height: 16),
        Text(tr('tbl.sortKey'), style: const TextStyle(fontWeight: FontWeight.w600)),
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
                for (final c in _skConds) DropdownMenuItem(value: c.$1, child: Text(tr(c.$2))),
              ],
              onChanged: (v) => setState(() => _skOp = v ?? 'eq'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Column(children: [
              TextField(controller: _skV1, decoration: _dec(hint: tr('tbl.enterAttributeValue'))),
              if (_skOp == 'between') ...[
                const SizedBox(height: 6),
                TextField(controller: _skV2, decoration: _dec(hint: tr('tbl.and'))),
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
          Text(tr('tbl.sortDescending')),
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
        TextSpan(text: tr('tbl.filters'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        TextSpan(
            text: tr('tbl.optional'),
            style: TextStyle(fontStyle: FontStyle.italic, fontSize: 13, color: scheme.onSurfaceVariant)),
      ])),
      const SizedBox(height: 10),
      if (_filters.isNotEmpty) ...[
        Row(children: [
          Expanded(flex: _fFlex[0], child: Text(tr('tbl.attributeName'), style: label)),
          const SizedBox(width: 10),
          Expanded(flex: _fFlex[1], child: Text(tr('tbl.condition'), style: label)),
          const SizedBox(width: 10),
          Expanded(flex: _fFlex[2], child: Text(tr('tbl.type'), style: label)),
          const SizedBox(width: 10),
          Expanded(flex: _fFlex[3], child: Text(tr('tbl.value'), style: label)),
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
        label: Text(tr('tbl.addFilter')),
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
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 16),
              prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              hintText: tr('tbl.enterAttributeName'),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
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
            items: [for (final c in _filterConds) DropdownMenuItem(value: c.$1, child: Text(tr(c.$2)))],
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
              ? TextField(enabled: false, decoration: _dec(hint: tr('tbl.notRequired')))
              : f.needsTwo
                  ? Row(children: [
                      Expanded(child: TextField(controller: f.v1, decoration: _dec(hint: tr('tbl.enterAttributeValue')))),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(tr('tbl.and')),
                      ),
                      Expanded(child: TextField(controller: f.v2, decoration: _dec(hint: tr('tbl.enterAttributeValue')))),
                    ])
                  : TextField(controller: f.v1, decoration: _dec(hint: tr('tbl.enterAttributeValue'))),
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
              child: Text(tr('tbl.remove'), maxLines: 1),
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

  // Whether item-level writes are offered here (endpoint mode, base table only;
  // a foreign table is writable only in the endpoint Browser, where the endpoint
  // is the authority on its own data — an instance browsing another table stays
  // read-only).
  bool get _canWriteItems {
    final t = _target;
    return !_awsMode &&
        (!_foreignBrowse || widget.allowOverrideWrites) &&
        (t == null || t.isTable);
  }

  Widget _resultsCard() {
    final p = _page!;
    final cols = p.cols.where((c) => !_hiddenCols.contains(c)).toList();
    final rows = _visibleRows(p);
    final t = _target;
    final selCount = _checked.length;
    // The toolbar row: flat mode renders the v2.3 valuepane head (table name
    // + key summary + SCAN FILTER + advanced toggle + pagination + ＋ Item);
    // the instance Browse keeps the AWS-console "Items returned" toolbar.
    final head = _flat ? _valuepaneHead(t) : _toolbar(t, p, rows, selCount);
    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        head,
        if (!_flat) const SizedBox(height: 8),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(children: [
                Icon(Icons.inbox_outlined, size: 36, color: Theme.of(context).hintColor),
                const SizedBox(height: 8),
                Text(tr('tbl.noItems')),
                const SizedBox(height: 4),
                Text(tr('tbl.noItemsToDisplay'),
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
              // Mockup .vtable td height = var(--row-h) = 30, fixed.
              dataRowMinHeight: 30,
              dataRowMaxHeight: 30,
              // Mockup shows no checkbox column — selection is by row click.
              showCheckboxColumn: false,
              onSelectAll: (v) => setState(() {
                _checked.clear();
                if (v == true) _checked.addAll(rows.map((r) => r.ddbJson));
              }),
              columns: [
                // v2.3 flat table leads with a 34px right-aligned line-number
                // gutter (mockup .vtable .ln); the gutter header stays empty.
                if (_flat)
                  const DataColumn(label: SizedBox(width: 34)),
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
                for (var i = 0; i < rows.length; i++)
                  _dataRow(t, rows[i], i, cols),
              ],
            ),
          ),
      ]);
    if (_flat) {
      // v2.3 valuepane: borderless flat surface (the endpoint Browser's own
      // pane border is the frame) instead of the rounded card.
      return body;
    }
    return _card(child: body);
  }

  DataRow _dataRow(TableTarget? t, TableItem r, int i, List<String> cols) {
    final tok = AppTokens.of(context);
    final selected = _checked.contains(r.ddbJson);
    return DataRow(
      selected: selected,
      // v2.3: selection fill + zebra on panel2.
      color: WidgetStateProperty.resolveWith((_) {
        if (selected) return tok.selection;
        return (_flat && i.isOdd) ? tok.panel2 : null;
      }),
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
        if (_flat)
          DataCell(Container(
            width: 34,
            height: 30, // fill the row so the 2px bar reads as a left indicator
            decoration: BoxDecoration(
              border: Border(
                  left: BorderSide(
                      color: selected ? tok.accent : Colors.transparent, width: 2)),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 6),
            child: Text('${i + 1}',
                textAlign: TextAlign.right,
                style: Ts.style(size: Ts.xs, color: tok.text3, monoFont: true, tabularNums: true)),
          )),
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
    );
  }

  // The v2.3 valuepane head: table name (15.5/700) + PK/SK summary + the
  // single SCAN FILTER box + advanced-form toggle; refresh / pagination /
  // preferences / Actions / ＋ Item on the right.
  Widget _valuepaneHead(TableTarget? t) {
    final tok = AppTokens.of(context);
    final p = _page!;
    // CP 9.x: inside the home chrome the valuepane is ~735px wide and this
    // row's fixed children (filter box + right cluster) no longer fit. The
    // wide layout (goldens / full screen) keeps the 200px filter box.
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 800;
      return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tok.panel2,
        border: Border(bottom: BorderSide(color: tok.hairline)),
      ),
      child: Row(children: [
        // Mockup .vp-title: the table name is a small uppercase eyebrow
        // (11/600/text-3), NOT a large prominent heading.
        Flexible(
          child: Text(_effTable.toUpperCase(),
              overflow: TextOverflow.ellipsis,
              style: Ts.style(
                  size: Ts.xs, weight: FontWeight.w600, letterSpacing: .8, color: tok.text3)),
        ),
        if (t != null) ...[
          const SizedBox(width: 14),
          // Mockup .empty-note: "PK <b>user#</b> · SK <b>profile</b>" — sans
          // (the PK/SK values stay non-mono, the strong is just 600 text).
          // Plain Texts instead of TextSpan children: the capture channel
          // rasterizes rich runs as .notdef blocks (CP 9.x).
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('PK ', style: Ts.style(size: Ts.md, color: tok.text3)),
            Text(t.pk.name,
                style: Ts.style(size: Ts.md, weight: FontWeight.w600, color: tok.text)),
            if (t.sk != null) ...[
              Text(' · SK ', style: Ts.style(size: Ts.md, color: tok.text3)),
              Text(t.sk!.name,
                  style: Ts.style(size: Ts.md, weight: FontWeight.w600, color: tok.text)),
            ],
          ]),
        ],
        const SizedBox(width: 16),
        SizedBox(
          width: compact ? 132 : 200,
          height: 26,
          child: TextField(
            controller: _scanFilter,
            onChanged: (_) => setState(() {}),
            style: Ts.style(size: Ts.sm, monoFont: true, letterSpacing: .6),
            decoration: InputDecoration(
              isDense: true,
              // No i18n key for this one — the design's own placeholder.
              hintText: 'SCAN FILTER…',
              hintStyle: Ts.style(size: Ts.sm, color: tok.text3, monoFont: true, letterSpacing: .6),
              prefixIcon: Icon(Icons.search, size: 14, color: tok.text3),
              prefixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 26),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Dim.radiusS),
                  borderSide: BorderSide(color: tok.border)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Dim.radiusS),
                  borderSide: BorderSide(color: tok.border)),
            ),
          ),
        ),
        IconButton(
          // The advanced Scan/Query card (projection / key conditions / typed
          // filters) — folded away in flat mode, one tap back.
          tooltip: tr('tbl.scanOrQueryItems'),
          visualDensity: VisualDensity.compact,
          isSelected: _panelOpen,
          icon: const Icon(Icons.tune, size: 17),
          onPressed: () => setState(() => _panelOpen = !_panelOpen),
        ),
        const Spacer(),
        Text('${p.returned}',
            style: Ts.style(size: Ts.md, weight: FontWeight.w600, color: tok.text2, tabularNums: true)),
        IconButton(
          tooltip: tr('tbl.refresh'),
          visualDensity: VisualDensity.compact,
          onPressed: _running ? null : () => _run(),
          icon: const Icon(Icons.refresh, size: 17),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: _pageIdx == 0 || _running ? null : _prevPage,
          icon: const Icon(Icons.chevron_left, size: 20),
        ),
        Text('${_pageIdx + 1}', style: Ts.style(size: Ts.md, tabularNums: true)),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: p.hasNext && !_running ? _nextPage : null,
          icon: const Icon(Icons.chevron_right, size: 20),
        ),
        IconButton(
          tooltip: tr('tbl.preferences'),
          visualDensity: VisualDensity.compact,
          onPressed: _openPreferences,
          icon: const Icon(Icons.settings, size: 17),
        ),
        if (_canWriteItems) ...[
          const SizedBox(width: 4),
          _selectionMenu(),
          const SizedBox(width: 6),
          _ghostButton(Icons.add, tr('tbl.createItem'),
              () => _openEditor(from: null, isNew: true)),
        ],
      ]),
    );
    });
  }

  // Ghost button (v2.3 .abtn.ghost — the ＋ Item grammar): a quiet 26px
  // outlined action, no fill.
  Widget _ghostButton(IconData icon, String label, VoidCallback onPressed) {
    final tok = AppTokens.of(context);
    return SizedBox(
      height: 26,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 14),
        label: Text(label, style: Ts.style(size: Ts.md, weight: FontWeight.w500)),
        style: OutlinedButton.styleFrom(
          foregroundColor: tok.text2,
          side: BorderSide(color: tok.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Dim.radiusS)),
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
      ),
    );
  }

  // The Actions menu (Edit / Duplicate / Delete / Export) — shared by the
  // valuepane head and the classic toolbar.
  Widget _selectionMenu() {
    final p = _page!;
    final cols = p.cols.where((c) => !_hiddenCols.contains(c)).toList();
    final rows = _visibleRows(p);
    final selCount = _checked.length;
    return MenuAnchor(
      builder: (ctx, ctrl, _) => OutlinedButton.icon(
        onPressed: () => ctrl.isOpen ? ctrl.close() : ctrl.open(),
        icon: const Icon(Icons.arrow_drop_down, size: 18),
        label: Text(tr('tbl.actions')),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: selCount == 1 ? () => _openEditor(from: _selectedItem(rows), isNew: false) : null,
          child: Text(tr('tbl.editItem')),
        ),
        MenuItemButton(
          onPressed: selCount == 1 ? () => _openEditor(from: _selectedItem(rows), isNew: true) : null,
          child: Text(tr('tbl.duplicateItem')),
        ),
        MenuItemButton(
          onPressed: selCount >= 1 ? () => _deleteSelected(rows) : null,
          child: Text(tr('tbl.deleteItems')),
        ),
        const Divider(height: 4),
        MenuItemButton(
          onPressed: rows.isEmpty ? null : () => _exportCsv(cols, rows),
          child: Text(tr('tbl.exportToCsv')),
        ),
      ],
    );
  }

  // The classic (instance Browse) toolbar — the AWS Explore-items layout.
  Widget _toolbar(TableTarget? t, TablePage p, List<TableItem> rows, int selCount) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${tr('tbl.itemsReturned')} (${p.returned})',
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
            tooltip: tr('tbl.refresh'),
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
            tooltip: tr('tbl.preferences'),
            onPressed: _openPreferences,
            icon: const Icon(Icons.settings, size: 18),
          ),
          if (_canWriteItems) ...[
            const SizedBox(width: 6),
            _selectionMenu(),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _openEditor(from: null, isNew: true),
              child: Text(tr('tbl.createItem')),
            ),
          ],
        ]);
  }

  // The partition-key cell — rendered as a link (the DataCell.onTap opens it).
  // Mockup .vtable .pk: plain mono weight-600 text in --text (NOT a coloured
  // underlined link). The cell's onTap still opens the item editor/viewer.
  Widget _pkText(AttrCell? cell) {
    final tok = AppTokens.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Text(
        cell?.repr ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Ts.style(
            size: Ts.md, weight: FontWeight.w600, monoFont: true, tabularNums: true, color: tok.text),
      ),
    );
  }

  TableItem? _selectedItem(List<TableItem> rows) {
    for (final r in rows) {
      if (_checked.contains(r.ddbJson)) return r;
    }
    return null;
  }

  // Mockup .vtable thead th: small uppercase letterspaced text-3 header — no
  // type-name suffix. Sorting arrow preserved.
  Widget _colHeader(String c) {
    final tok = AppTokens.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(c.toUpperCase(),
          style: Ts.style(
              size: 10.5, weight: FontWeight.w600, letterSpacing: .7, color: tok.text3)),
      if (_sortCol == c)
        Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: tok.text3),
    ]);
  }

  Widget _cellWidget(AttrCell? cell) {
    final tok = AppTokens.of(context);
    if (cell == null) return const SizedBox.shrink();
    // Mockup .vtable .mono: every data cell is mono 12px tabular.
    final text = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Text(cell.repr,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Ts.style(size: Ts.md, monoFont: true, tabularNums: true, color: tok.text2)),
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
            title: Text(tr('tbl.preferences')),
            content: SizedBox(
              width: 460,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(tr('tbl.pageSize'), style: const TextStyle(fontWeight: FontWeight.w600)),
                    RadioGroup<int>(
                      groupValue: size,
                      onChanged: (v) => setD(() => size = v ?? size),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final s in _pageSizes)
                          RadioListTile<int>(
                            value: s,
                            title: Text('$s ${tr('tbl.itemsWord')}'),
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
                      TextButton(onPressed: () => setD(() => hidden.clear()), child: Text(tr('tbl.selectAll'))),
                      TextButton(onPressed: () => setD(() => hidden.addAll(cols)), child: Text(tr('tbl.deselectAll'))),
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
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('tbl.cancel'))),
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
                child: Text(tr('tbl.saveChanges')),
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
        _toast(tr('tbl.projectionKeyMissing'), error: true);
        return;
      }
      final res = widget.core.tableGetItem(_effCfg, key);
      if (res['ok'] == true && res['item'] is Map) {
        initial = (res['item'] as Map).cast<String, dynamic>();
      } else {
        _toast('${tr('tbl.couldntFetchItem')}: ${res['error'] ?? 'error'}', error: true);
        return;
      }
    }
    if (!mounted) return;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ItemEditorPage(
        table: _effTable,
        target: t,
        isNew: isNew,
        initial: initial,
        onSave: (av) async {
          if (!await _confirmRawWrite('Write')) return ''; // '' = cancelled
          final res = widget.core.tablePutItem(_effCfg, av);
          return res['ok'] == true ? null : '${res['error'] ?? tr('tbl.saveFailed')}';
        },
      ),
    ));
    if (!mounted || saved != true) return;
    _toast(isNew ? tr('tbl.itemCreated') : tr('tbl.itemSaved'));
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
          Expanded(child: Text(tr('tbl.itemDdbJson'))),
          IconButton(
            tooltip: tr('tbl.copy'),
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pretty));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('tbl.copied'))));
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
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('tbl.close')))],
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
        _toast(tr('tbl.missingKeyAttrs'), error: true);
        return;
      }
      keys.add(k);
    }
    final scheme = Theme.of(context).colorScheme;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${tr('tbl.delete')} ${keys.length} ${tr('tbl.itemsParen')}?'),
        content: SizedBox(
          width: 440,
          child: Text(
            'This permanently deletes ${keys.length} item(s) from "$_effTable", '
            'writing directly to DynamoDB and bypassing redimos’s encoding — for redimos data, '
            'prefer the Browser or Console tab.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('tbl.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('tbl.delete')),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    var failed = 0;
    for (final k in keys) {
      final res = widget.core.tableDeleteItem(_effCfg, k);
      if (res['ok'] != true) failed++;
    }
    if (!mounted) return;
    _toast(failed == 0
        ? '${tr('tbl.deleted')} ${keys.length} ${tr('tbl.itemsParen')}'
        : '${tr('tbl.deleted')} ${keys.length - failed}, $failed ${tr('tbl.failed')}', error: failed > 0);
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
      final path = '$home/Downloads/redimos-$_effTable-$ts.csv';
      await File(path).writeAsString(csv);
      _toast('${tr('tbl.exported')} ${rows.length} ${tr('tbl.rowsSuffix')} → $path');
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: csv));
      _toast(tr('tbl.csvClipboardFallback'));
    }
  }

  // Strong confirmation before a raw item write on a redimos table.
  Future<bool> _confirmRawWrite(String verb) async {
    final scheme = Theme.of(context).colorScheme;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$verb a raw item on a redimos table?'),
        content: SizedBox(
          width: 430,
          child: Text(tr('tbl.rawWriteBody')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('tbl.cancel'))),
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
