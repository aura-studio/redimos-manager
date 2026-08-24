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
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_states.dart';
import 'ui_surfaces.dart';
import 'ui_table.dart';
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

Widget _semanticIconButton({
  required String label,
  required Widget icon,
  required VoidCallback? onPressed,
  VisualDensity? visualDensity,
  bool? selected,
}) =>
    Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        button: true,
        enabled: onPressed != null,
        selected: selected,
        onTap: onPressed,
        excludeSemantics: true,
        child: IconButton(
          visualDensity: visualDensity,
          isSelected: selected,
          onPressed: onPressed,
          icon: icon,
        ),
      ),
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
  // Flat mode: the scan filter lives in a right-hand sidebar instead of the
  // crowded valuepane head. A view preference (like _pageSize) — survives
  // table changes; closing the sidebar clears the filter so hidden filtering
  // can never silently narrow the grid.
  bool _filterSidebarOpen = true;

  void _toggleFilterSidebar() => setState(() {
        _filterSidebarOpen = !_filterSidebarOpen;
        if (!_filterSidebarOpen && _scanFilter.text.isNotEmpty) {
          _scanFilter.clear();
        }
      });

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
  int _entityGeneration = 0;
  int _metaGeneration = 0;
  int _runGeneration = 0;
  bool _editorOpen = false;
  String? _editorTable;
  TableTarget? _editorTarget;
  bool _editorIsNew = false;
  Map<String, dynamic> _editorInitial = const {};
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
      _entityGeneration++;
      _metaGeneration++;
      _runGeneration++;
      _resetAll();
      _loadMeta();
    }
  }

  @override
  void dispose() {
    _entityGeneration++;
    _metaGeneration++;
    _runGeneration++;
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
    _projectInput.clear();
    _pk.clear();
    _skOp = 'eq';
    _skV1.clear();
    _skV2.clear();
    _scanFilter.clear();
    _sortDesc = false;
    for (final f in _filters) {
      f.dispose();
    }
    _filters.clear();
    _panelOpen = !_flat;
    _running = false;
    _page = null;
    _pageError = null;
    _stack
      ..clear()
      ..add(null);
    _pageIdx = 0;
    _hiddenCols.clear();
    _sortCol = null;
    _sortAsc = true;
    _checked.clear();
    _editorOpen = false;
    _editorTarget = null;
    _editorInitial = const {};
    // _pageSize is a user preference and intentionally survives table changes.
  }

  Future<void> _loadMeta() async {
    final metaGeneration = ++_metaGeneration;
    final entityGeneration = _entityGeneration;
    final config = _effCfg;
    setState(() {
      _meta = null;
      _metaError = null;
    });
    await Future.delayed(const Duration(milliseconds: 16));
    if (!mounted ||
        metaGeneration != _metaGeneration ||
        entityGeneration != _entityGeneration) {
      return;
    }
    final m = widget.core.tableMeta(config);
    if (!mounted ||
        metaGeneration != _metaGeneration ||
        entityGeneration != _entityGeneration) {
      return;
    }
    setState(() {
      if (m.ok) {
        _meta = m;
        _metaError = null;
      } else {
        _meta = null;
        _metaError = m.error ?? tr('tbl.failedDescribeTable');
      }
    });
    if (m.ok &&
        metaGeneration == _metaGeneration &&
        entityGeneration == _entityGeneration) {
      _run(); // auto-scan on open, like the console's Autopreview
    }
  }

  TableTarget? get _target =>
      (_meta != null && _targetIdx < _meta!.targets.length)
          ? _meta!.targets[_targetIdx]
          : null;

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
        .where(
            (r) => r.cells.values.any((c) => c.repr.toLowerCase().contains(q)))
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
      'skCond':
          (_isQuery && _skV1.text.trim().isNotEmpty && (_target?.sk != null))
              ? {'op': _skOp, 'v1': _skV1.text, 'v2': _skV2.text}
              : null,
      'scanForward': !_sortDesc,
      'filters': [
        for (final f in _filters)
          if (f.attr.text.trim().isNotEmpty)
            {
              'attr': f.attr.text.trim(),
              'type': f.type,
              'op': f.op,
              'v1': f.v1.text,
              'v2': f.v2.text
            },
      ],
      'limit': _pageSize,
      'startKey': startKey,
    };
  }

  Future<void> _run({bool resetPaging = true}) async {
    if (_meta == null) return;
    final runGeneration = ++_runGeneration;
    final entityGeneration = _entityGeneration;
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
    if (!mounted ||
        runGeneration != _runGeneration ||
        entityGeneration != _entityGeneration) {
      return;
    }
    final request = _buildReq(_stack[_pageIdx]);
    final page = widget.core.tablePage(request);
    if (!mounted ||
        runGeneration != _runGeneration ||
        entityGeneration != _entityGeneration) {
      return;
    }
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
    final noTable = _effTable.trim().isEmpty;
    final state = noTable
        ? CodexContentState.empty
        : _metaError != null
            ? CodexContentState.error
            : _meta == null
                ? CodexContentState.loading
                : CodexContentState.content;
    final showHeader = !noTable && (!_flat || _awsMode);

    return Theme(
      data: _denseTabTheme(context),
      child: Stack(children: [
        CodexStateShell(
        key: const ValueKey('table-page-state'),
        state: state,
        toolbar: showHeader
            ? Padding(
                key: const ValueKey('table-page-header'),
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
                child: _headerRow(),
              )
            : null,
        headerGap: showHeader ? 12 : 0,
        message: noTable
            ? tr('tbl.noTableConfigured')
            : state == CodexContentState.error
                ? tr('tbl.cannotReadTable')
                : '',
        detail: noTable ? tr('tbl.setTableNameToBrowse') : _metaError,
        retryLabel: tr('tbl.retry'),
        onRetry: state == CodexContentState.error ? _loadMeta : null,
        icon: noTable ? const Icon(Icons.table_chart_outlined, size: 22) : null,
        bodyPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        content: state != CodexContentState.content
            ? const SizedBox.shrink()
            : SingleChildScrollView(
                key: ValueKey('table-scroll-${widget.config.id}-$_effTable'),
                // The same 22/18 page gutter every other v1.2 screen uses;
                // the data surfaces sit inside elevated section cards.
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Flat mode: the advanced Scan/Query form is one tap away
                    // (the valuepane head's tune toggle) but never in the way —
                    // the single SCAN FILTER box covers the common case.
                    if (!_flat || _panelOpen) _queryCard(),
                    if (_pageError != null) ...[
                      const SizedBox(height: 12),
                      _banner(),
                    ],
                    if (_page != null) ...[
                      const SizedBox(height: 12),
                      _resultsRow(),
                    ],
                  ],
                ),
              ),
        ),
        if (_editorOpen) ...[
          Positioned.fill(
            child: ModalBarrier(
              dismissible: false,
              color: Colors.black.withValues(alpha: 0.28),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
              child: CodexSurface(
                variant: CodexSurfaceVariant.elevated,
                padding: EdgeInsets.zero,
                child: ItemEditorPage(
                  key: ValueKey('item-editor-${_editorTable ?? ''}'),
                  table: _editorTable ?? _effTable,
                  target: _editorTarget!,
                  isNew: _editorIsNew,
                  initial: _editorInitial,
                  onSave: (av) async {
                    if (!await _confirmRawWrite('Write')) return '';
                    final res = widget.core.tablePutItem(_effCfg, av);
                    return res['ok'] == true
                        ? null
                        : '${res['error'] ?? tr('tbl.saveFailed')}';
                  },
                  onCancel: () => setState(() => _editorOpen = false),
                  onCompleted: (saved) {
                    final wasNew = _editorIsNew;
                    setState(() => _editorOpen = false);
                    if (!saved) return;
                    _toast(wasNew
                        ? tr('tbl.itemCreated')
                        : tr('tbl.itemSaved'));
                    _run(resetPaging: false);
                  },
                ),
              ),
            ),
          ),
        ],
      ]),
    );
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
        host.endsWith(
            '.amazonaws.com.cn'); // explicit AWS host (incl. China partition)
  }

  // Browse-any-table: the endpoint Browser's Tables sidebar points this view at
  // the selected table on the same endpoint. It is browsed via a config copy with
  // the table swapped; endpoint/creds stay the config's own. Writes on the
  // override table are offered when allowOverrideWrites is set (non-AWS).
  bool get _foreignBrowse =>
      widget.tableOverride != null &&
      widget.tableOverride != widget.config.table;
  String get _effTable => widget.tableOverride ?? widget.config.table;
  RedimosConfig get _effCfg => _foreignBrowse
      ? (widget.config.copy()..table = widget.tableOverride!)
      : widget.config;

  Widget _headerRow() {
    final t = AppTokens.of(context);
    return Row(children: [
      Icon(Icons.table_chart, size: 16, color: t.accent),
      const SizedBox(width: 8),
      Flexible(
        child: Text(_effTable,
            overflow: TextOverflow.ellipsis,
            style: Ts.style(
                size: Ts.md,
                weight: FontWeight.w700,
                color: t.text,
                monoFont: true)),
      ),
      // The endpoint Browser owns its selection, so no transient browse chrome
      // shows there; on AWS the inline warning carries the read-only message.
      if (_awsMode) ...[
        const SizedBox(width: 10),
        Icon(Icons.lock_outline, size: 13, color: t.warning),
        const SizedBox(width: 5),
        Text(tr('ep.awsReadOnly'),
            style: Ts.style(size: Ts.xs, color: t.warning)),
      ],
      const Spacer(),
      CodexButton(
        variant: CodexButtonVariant.secondary,
        semanticLabel: tr('tbl.refresh'),
        onPressed: _running ? null : () => _meta == null ? _loadMeta() : _run(),
        icon: const Icon(Icons.refresh, size: 14),
        label: Text(tr('tbl.refresh')),
      ),
    ]);
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    final t = AppTokens.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? t.danger : null,
      duration: const Duration(seconds: 3),
    ));
  }

  // Section-card grammar (service_configure._section / endpoint Configure):
  // panel2 head band with an uppercase title, ruled body. The collapse toggle
  // lives on the whole head band.
  Widget _queryCard() {
    final t = AppTokens.of(context);
    return CodexSurface(
      variant: CodexSurfaceVariant.elevated,
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => setState(() => _panelOpen = !_panelOpen),
          child: Container(
            color: t.panel2,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Icon(_panelOpen ? Icons.expand_more : Icons.chevron_right,
                  size: 16, color: t.text3),
              const SizedBox(width: 8),
              Text(tr('tbl.scanOrQueryItems').toUpperCase(),
                  style: Ts.style(
                      size: Ts.md,
                      letterSpacing: 0.9,
                      weight: FontWeight.w700,
                      color: t.text)),
            ]),
          ),
        ),
        const CodexDivider(),
        if (!_panelOpen)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(tr('tbl.expandToQueryOrScan'),
                style: Ts.style(size: Ts.sm, color: t.text3)),
          )
        else
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                            value: false,
                            label: Text(tr('tbl.scan')),
                            icon: const Icon(Icons.list, size: 16)),
                        ButtonSegment(
                            value: true,
                            label: Text(tr('tbl.query')),
                            icon: const Icon(Icons.search, size: 16)),
                      ],
                      selected: {_isQuery},
                      onSelectionChanged: (s) =>
                          setState(() => _isQuery = s.first),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _targetDropdown(),
                  const SizedBox(height: 12),
                  _projectionRow(),
                  if (_isQuery) ...[
                    const SizedBox(height: 12),
                    _queryKeys(),
                  ],
                  const SizedBox(height: 12),
                  _filtersSection(),
                  const SizedBox(height: 12),
                  Row(children: [
                    CodexButton(
                      variant: CodexButtonVariant.primary,
                      semanticLabel: tr('tbl.run'),
                      onPressed: _running ? null : () => _run(),
                      label: _running
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(tr('tbl.run')),
                    ),
                    const SizedBox(width: 8),
                    CodexButton(
                      variant: CodexButtonVariant.ghost,
                      semanticLabel: tr('tbl.reset'),
                      onPressed: _reset,
                      label: Text(tr('tbl.reset')),
                    ),
                  ]),
                ]),
          ),
      ]),
    );
  }

  Widget _targetDropdown() {
    final targets = _meta!.targets;
    final style = Ts.style(size: Ts.sm, color: AppTokens.of(context).text);
    return _labeled(
      tr('tbl.selectTableOrIndex'),
      CodexSelectField<int>(
        value: _targetIdx,
        style: style,
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
    final t = AppTokens.of(context);
    final style = Ts.style(size: Ts.sm, color: t.text);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _labeled(
        tr('tbl.selectAttributeProjection'),
        CodexSelectField<String>(
          value: _projection,
          style: style,
          items: [
            DropdownMenuItem(value: 'all', child: Text(tr('tbl.allAttributes'))),
            DropdownMenuItem(
                value: 'specific', child: Text(tr('tbl.specificAttributes'))),
          ],
          onChanged: (v) => setState(() => _projection = v ?? 'all'),
        ),
      ),
      if (_projection == 'specific') ...[
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: CodexTextField(
              controller: _projectInput,
              style: Ts.style(size: Ts.sm, color: t.text, monoFont: true),
              decoration: InputDecoration(hintText: tr('tbl.enterAttributeName')),
              onSubmitted: (_) => _addProjectAttr(),
            ),
          ),
          const SizedBox(width: 8),
          CodexButton(
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('tbl.addAttribute'),
            onPressed: _addProjectAttr,
            label: Text(tr('tbl.addAttribute')),
          ),
        ]),
        if (_projectAttrs.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final a in _projectAttrs) _attrChip(t, a)],
          ),
        ],
      ],
    ]);
  }

  // Token chip (the house grammar has no Material Chip on data surfaces):
  // panel2 pill with a hairline border and a quiet close glyph.
  Widget _attrChip(AppTokens t, String a) => Container(
        decoration: BoxDecoration(
          color: t.panel2,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(Dim.radiusS),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(a, style: Ts.style(size: Ts.sm, color: t.text2, monoFont: true)),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => setState(() => _projectAttrs.remove(a)),
            child: Icon(Icons.close, size: 12, color: t.text3),
          ),
        ]),
      );

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
    final tok = AppTokens.of(context);
    if (t == null) return const SizedBox.shrink();
    final mono = Ts.style(size: Ts.sm, color: tok.text, monoFont: true);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _labelText(tr('tbl.partitionKey')),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(flex: 2, child: _readonlyAttr(t.pk.name)),
        const SizedBox(width: 12),
        Expanded(
          flex: 5,
          child: CodexTextField(
              controller: _pk,
              style: mono,
              decoration:
                  InputDecoration(hintText: tr('tbl.enterAttributeValue'))),
        ),
      ]),
      if (t.sk != null) ...[
        const SizedBox(height: 16),
        _labelText(tr('tbl.sortKey')),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 2, child: _readonlyAttr(t.sk!.name)),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: CodexSelectField<String>(
              value: _skOp,
              style: mono,
              items: [
                for (final c in _skConds)
                  DropdownMenuItem(value: c.$1, child: Text(tr(c.$2))),
              ],
              onChanged: (v) => setState(() => _skOp = v ?? 'eq'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Column(children: [
              CodexTextField(
                  controller: _skV1,
                  style: mono,
                  decoration: InputDecoration(
                      hintText: tr('tbl.enterAttributeValue'))),
              if (_skOp == 'between') ...[
                const SizedBox(height: 6),
                CodexTextField(
                    controller: _skV2,
                    style: mono,
                    decoration: InputDecoration(hintText: tr('tbl.and'))),
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
          Text(tr('tbl.sortDescending'),
              style: Ts.style(size: Ts.sm, color: tok.text2)),
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
    final t = AppTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const CodexDivider(),
      const SizedBox(height: 12),
      Row(children: [
        Text(tr('tbl.filters'),
            style: Ts.style(size: Ts.md, weight: FontWeight.w700, color: t.text)),
        const SizedBox(width: 8),
        Text(tr('tbl.optional'),
            style: Ts.style(size: Ts.sm, color: t.text3)
                .copyWith(fontStyle: FontStyle.italic)),
      ]),
      const SizedBox(height: 10),
      if (_filters.isNotEmpty) ...[
        Row(children: [
          Expanded(
              flex: _fFlex[0], child: _labelText(tr('tbl.attributeName'))),
          const SizedBox(width: 10),
          Expanded(flex: _fFlex[1], child: _labelText(tr('tbl.condition'))),
          const SizedBox(width: 10),
          Expanded(flex: _fFlex[2], child: _labelText(tr('tbl.type'))),
          const SizedBox(width: 10),
          Expanded(flex: _fFlex[3], child: _labelText(tr('tbl.value'))),
          const SizedBox(width: 10),
          const SizedBox(width: _fRemoveW),
        ]),
        const SizedBox(height: 6),
        for (var i = 0; i < _filters.length; i++) _filterRow(i),
        const SizedBox(height: 4),
      ],
      CodexButton(
        variant: CodexButtonVariant.secondary,
        semanticLabel: tr('tbl.addFilter'),
        onPressed: () => setState(() => _filters.add(_FilterRow())),
        icon: const Icon(Icons.add, size: 14),
        label: Text(tr('tbl.addFilter')),
      ),
    ]);
  }

  Widget _filterRow(int i) {
    final t = AppTokens.of(context);
    final f = _filters[i];
    final mono = Ts.style(size: Ts.sm, color: t.text, monoFont: true);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: _fFlex[0],
          child: CodexTextField(
            controller: f.attr,
            style: mono,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 16),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
              hintText: tr('tbl.enterAttributeName'),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: _fFlex[1],
          child: CodexSelectField<String>(
            value: f.op,
            style: mono,
            items: [
              for (final c in _filterConds)
                DropdownMenuItem(value: c.$1, child: Text(tr(c.$2)))
            ],
            onChanged: (v) => setState(() => f.op = v ?? 'eq'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: _fFlex[2],
          child: CodexSelectField<String>(
            value: f.type,
            enabled: f.needsValue,
            style: mono,
            items: [
              for (final ty in _filterTypes)
                DropdownMenuItem(value: ty.$1, child: Text(ty.$2))
            ],
            onChanged:
                f.needsValue ? (v) => setState(() => f.type = v ?? 'S') : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: _fFlex[3],
          child: !f.needsValue
              ? CodexTextField(
                  enabled: false,
                  decoration: InputDecoration(hintText: tr('tbl.notRequired')))
              : f.needsTwo
                  ? Row(children: [
                      Expanded(
                          child: CodexTextField(
                              controller: f.v1,
                              style: mono,
                              decoration: InputDecoration(
                                  hintText: tr('tbl.enterAttributeValue')))),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(tr('tbl.and'),
                            style: Ts.style(size: Ts.sm, color: t.text3)),
                      ),
                      Expanded(
                          child: CodexTextField(
                              controller: f.v2,
                              style: mono,
                              decoration: InputDecoration(
                                  hintText: tr('tbl.enterAttributeValue')))),
                    ])
                  : CodexTextField(
                      controller: f.v1,
                      style: mono,
                      decoration: InputDecoration(
                          hintText: tr('tbl.enterAttributeValue'))),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: _fRemoveW,
          child: CodexButton(
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('tbl.remove'),
            onPressed: () => setState(() => _filters.removeAt(i).dispose()),
            label: Text(tr('tbl.remove'), maxLines: 1),
          ),
        ),
      ]),
    );
  }

  // ---- result banner + grid ----

  Widget _banner() {
    final t = AppTokens.of(context);
    if (_pageError != null) {
      // Same shape as the Service Monitor's error banner.
      return CodexSurface(
        variant: CodexSurfaceVariant.elevated,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(children: [
          Icon(Icons.error_outline, color: t.danger, size: 16),
          const SizedBox(width: 8),
          Expanded(
              child: Text(_pageError!,
                  style: Ts.style(size: Ts.sm, color: t.text, monoFont: true))),
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
    final table = rows.isEmpty ? _emptyRows() : _dataTable(t, rows, cols);
    if (_flat) {
      // v2.3 valuepane as a section card: the valuepane head IS the panel2
      // head band; the data rows fill the ruled body.
      return CodexSurface(
        variant: CodexSurfaceVariant.elevated,
        padding: EdgeInsets.zero,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [head, table]),
      );
    }
    return CodexSurface(
      variant: CodexSurfaceVariant.elevated,
      padding: const EdgeInsets.all(11),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        head,
        const SizedBox(height: 8),
        table,
      ]),
    );
  }

  Widget _emptyRows() {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(children: [
          Icon(Icons.inbox_outlined, size: 36, color: t.text3),
          const SizedBox(height: 8),
          Text(tr('tbl.noItems'),
              style: Ts.style(size: Ts.md, color: t.text2)),
          const SizedBox(height: 4),
          Text(tr('tbl.noItemsToDisplay'),
              style: Ts.style(size: Ts.sm, color: t.text3)),
        ]),
      ),
    );
  }

  Widget _dataTable(TableTarget? t, List<TableItem> rows, List<String> cols) =>
        CodexHorizontalScrollView(
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
              if (_flat) const DataColumn(label: SizedBox(width: 34)),
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
        );

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
                      color: selected ? tok.accent : Colors.transparent,
                      width: 2)),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 6),
            child: Text('${i + 1}',
                textAlign: TextAlign.right,
                style: Ts.style(
                    size: Ts.xs,
                    color: tok.text3,
                    monoFont: true,
                    tabularNums: true)),
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

  // Flat mode lays the results card and the filter sidebar out as sibling
  // section cards (the house grammar) instead of crowding the valuepane head.
  Widget _resultsRow() {
    final card = _resultsCard();
    if (!_flat || !_filterSidebarOpen) return card;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: card),
      const SizedBox(width: 12),
      SizedBox(width: 248, child: _filterSidebarCard()),
    ]);
  }

  // Right-hand filter sidebar (flat mode): a section card with the SCAN
  // FILTER box and the advanced Scan/Query form toggle.
  Widget _filterSidebarCard() {
    final tok = AppTokens.of(context);
    return CodexSurface(
      variant: CodexSurfaceVariant.elevated,
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: tok.panel2,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(tr('tbl.filters').toUpperCase(),
              style: Ts.style(
                  size: Ts.md,
                  letterSpacing: 0.9,
                  weight: FontWeight.w700,
                  color: tok.text)),
        ),
        const CodexDivider(),
        Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _labelText('SCAN FILTER'),
            const SizedBox(height: 8),
            SizedBox(
              height: Dim.ctlH,
              child: TextField(
                controller: _scanFilter,
                onChanged: (_) => setState(() {}),
                style: Ts.style(size: Ts.sm, color: tok.text, monoFont: true),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('tbl.filters'),
                  hintStyle: Ts.style(size: Ts.sm, color: tok.text3),
                  prefixIcon: Icon(Icons.search, size: 14, color: tok.text3),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 28, minHeight: 26),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: CodexButton(
                variant: CodexButtonVariant.secondary,
                semanticLabel: tr('tbl.scanOrQueryItems'),
                onPressed: () => setState(() => _panelOpen = !_panelOpen),
                icon:
                    Icon(_panelOpen ? Icons.expand_less : Icons.tune, size: 15),
                label: Text(tr('tbl.scanOrQueryItems')),
              ),
            ),
          ]),
        ),
      ]),
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
                    size: Ts.xs,
                    weight: FontWeight.w600,
                    letterSpacing: .8,
                    color: tok.text3)),
          ),
          if (!compact && t != null) ...[
            const SizedBox(width: 14),
            // Mockup .empty-note: "PK <b>user#</b> · SK <b>profile</b>" — sans
            // (the PK/SK values stay non-mono, the strong is just 600 text).
            // Plain Texts instead of TextSpan children: the capture channel
            // rasterizes rich runs as .notdef blocks (CP 9.x).
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('PK ', style: Ts.style(size: Ts.md, color: tok.text3)),
              Text(t.pk.name,
                  style: Ts.style(
                      size: Ts.md, weight: FontWeight.w600, color: tok.text)),
              if (t.sk != null) ...[
                Text(' · SK ', style: Ts.style(size: Ts.md, color: tok.text3)),
                Text(t.sk!.name,
                    style: Ts.style(
                        size: Ts.md, weight: FontWeight.w600, color: tok.text)),
              ],
            ]),
          ],
          const Spacer(),
          Text('${p.returned}',
              style: Ts.style(
                  size: Ts.md,
                  weight: FontWeight.w600,
                  color: tok.text2,
                  tabularNums: true)),
          _semanticIconButton(
            label: tr('tbl.refresh'),
            visualDensity: VisualDensity.compact,
            onPressed: _running ? null : () => _run(),
            icon: const Icon(Icons.refresh, size: 17),
          ),
          _semanticIconButton(
            label: MaterialLocalizations.of(context).previousPageTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: _pageIdx == 0 || _running ? null : _prevPage,
            icon: const Icon(Icons.chevron_left, size: 20),
          ),
          Text('${_pageIdx + 1}',
              style: Ts.style(size: Ts.md, tabularNums: true)),
          _semanticIconButton(
            label: MaterialLocalizations.of(context).nextPageTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: p.hasNext && !_running ? _nextPage : null,
            icon: const Icon(Icons.chevron_right, size: 20),
          ),
          _semanticIconButton(
            label: tr('tbl.preferences'),
            visualDensity: VisualDensity.compact,
            onPressed: _openPreferences,
            icon: const Icon(Icons.settings, size: 17),
          ),
          _semanticIconButton(
            label: tr('tbl.filters'),
            visualDensity: VisualDensity.compact,
            selected: _filterSidebarOpen,
            onPressed: _toggleFilterSidebar,
            icon: const Icon(Icons.filter_list, size: 18),
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
        label:
            Text(label, style: Ts.style(size: Ts.md, weight: FontWeight.w500)),
        style: OutlinedButton.styleFrom(
          foregroundColor: tok.text2,
          side: BorderSide(color: tok.border),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Dim.radiusS)),
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
      builder: (ctx, ctrl, _) => CodexButton(
        variant: CodexButtonVariant.secondary,
        semanticLabel: tr('tbl.actions'),
        onPressed: () => ctrl.isOpen ? ctrl.close() : ctrl.open(),
        icon: const Icon(Icons.arrow_drop_down, size: 18),
        label: Text(tr('tbl.actions')),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: selCount == 1
              ? () => _openEditor(from: _selectedItem(rows), isNew: false)
              : null,
          child: Text(tr('tbl.editItem')),
        ),
        MenuItemButton(
          onPressed: selCount == 1
              ? () => _openEditor(from: _selectedItem(rows), isNew: true)
              : null,
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
  Widget _toolbar(
      TableTarget? t, TablePage p, List<TableItem> rows, int selCount) {
    final tok = AppTokens.of(context);
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tr('tbl.itemsReturned')} (${p.returned})',
              style: Ts.style(
                  size: Ts.md, weight: FontWeight.w600, color: tok.text)),
          Text(
            '${t != null && !t.isTable ? 'Index ${t.name} · ' : ''}'
            'Items scanned: ${p.scanned} · ${(p.efficiency * 100).round()}% · ${p.timeMs} ms'
            '${selCount > 0 ? ' · $selCount selected' : ''}',
            style: Ts.style(size: Ts.xs, color: tok.text3),
          ),
        ]),
      ),
      _semanticIconButton(
        label: tr('tbl.refresh'),
        onPressed: _running ? null : () => _run(),
        icon: const Icon(Icons.refresh, size: 17),
      ),
      _semanticIconButton(
        label: MaterialLocalizations.of(context).previousPageTooltip,
        onPressed: _pageIdx == 0 || _running ? null : _prevPage,
        icon: const Icon(Icons.chevron_left, size: 20),
      ),
      Text('${_pageIdx + 1}',
          style: Ts.style(size: Ts.md, tabularNums: true)),
      _semanticIconButton(
        label: MaterialLocalizations.of(context).nextPageTooltip,
        onPressed: p.hasNext && !_running ? _nextPage : null,
        icon: const Icon(Icons.chevron_right, size: 20),
      ),
      _semanticIconButton(
        label: tr('tbl.preferences'),
        onPressed: _openPreferences,
        icon: const Icon(Icons.settings, size: 17),
      ),
      if (_canWriteItems) ...[
        const SizedBox(width: 6),
        _selectionMenu(),
        const SizedBox(width: 8),
        CodexButton(
          variant: CodexButtonVariant.primary,
          semanticLabel: tr('tbl.createItem'),
          onPressed: () => _openEditor(from: null, isNew: true),
          label: Text(tr('tbl.createItem')),
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
            size: Ts.md,
            weight: FontWeight.w600,
            monoFont: true,
            tabularNums: true,
            color: tok.text),
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
              size: 10.5,
              weight: FontWeight.w600,
              letterSpacing: .7,
              color: tok.text3)),
      if (_sortCol == c)
        Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
            size: 12, color: tok.text3),
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
          style: Ts.style(
              size: Ts.md,
              monoFont: true,
              tabularNums: true,
              color: tok.text2)),
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
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr('tbl.pageSize'),
                            style: Ts.style(
                                size: Ts.md,
                                weight: FontWeight.w600,
                                color: AppTokens.of(context).text)),
                        RadioGroup<int>(
                          groupValue: size,
                          onChanged: (v) => setD(() => size = v ?? size),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
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
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(children: [
                          CodexButton(
                              variant: CodexButtonVariant.ghost,
                              semanticLabel: tr('tbl.selectAll'),
                              onPressed: () => setD(() => hidden.clear()),
                              label: Text(tr('tbl.selectAll'))),
                          CodexButton(
                              variant: CodexButtonVariant.ghost,
                              semanticLabel: tr('tbl.deselectAll'),
                              onPressed: () => setD(() => hidden.addAll(cols)),
                              label: Text(tr('tbl.deselectAll'))),
                        ]),
                        for (final c in cols)
                          SwitchListTile(
                            value: !hidden.contains(c),
                            onChanged: (v) => setD(
                                () => v ? hidden.remove(c) : hidden.add(c)),
                            title: Text(c, overflow: TextOverflow.ellipsis),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                      ]),
                ),
              ]),
            ),
            actions: [
              CodexButton(
                  variant: CodexButtonVariant.ghost,
                  semanticLabel: tr('tbl.cancel'),
                  onPressed: () => Navigator.pop(ctx),
                  label: Text(tr('tbl.cancel'))),
              CodexButton(
                variant: CodexButtonVariant.primary,
                semanticLabel: tr('tbl.saveChanges'),
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
                label: Text(tr('tbl.saveChanges')),
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
  Future<void> _openEditor(
      {required TableItem? from, required bool isNew}) async {
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
        _toast('${tr('tbl.couldntFetchItem')}: ${res['error'] ?? 'error'}',
            error: true);
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _editorOpen = true;
      _editorTable = _effTable;
      _editorTarget = t;
      _editorIsNew = isNew;
      _editorInitial = initial;
    });
  }

  /// Read-only DynamoDB-JSON viewer (AWS mode / index targets).
  void _showItemViewer(TableItem r) {
    String pretty;
    try {
      pretty =
          const JsonEncoder.withIndent('  ').convert(jsonDecode(r.ddbJson));
    } catch (_) {
      pretty = r.ddbJson;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Expanded(child: Text(tr('tbl.itemDdbJson'))),
          _semanticIconButton(
            label: tr('tbl.copy'),
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pretty));
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(tr('tbl.copied'))));
            },
          ),
        ]),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(pretty,
                style: Ts.style(
                    size: Ts.sm, color: AppTokens.of(context).text, monoFont: true)),
          ),
        ),
        actions: [
          CodexButton(
              variant: CodexButtonVariant.ghost,
              semanticLabel: tr('tbl.close'),
              onPressed: () => Navigator.pop(ctx),
              label: Text(tr('tbl.close')))
        ],
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
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:
            Text('${tr('tbl.delete')} ${keys.length} ${tr('tbl.itemsParen')}?'),
        content: SizedBox(
          width: 440,
          child: Text(
            'This permanently deletes ${keys.length} item(s) from "$_effTable", '
            'writing directly to DynamoDB and bypassing redimos’s encoding — for redimos data, '
            'prefer the Browser or Console tab.',
          ),
        ),
        actions: [
          CodexButton(
              variant: CodexButtonVariant.ghost,
              semanticLabel: tr('tbl.cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              label: Text(tr('tbl.cancel'))),
          CodexButton(
            variant: CodexButtonVariant.danger,
            semanticLabel: tr('tbl.delete'),
            onPressed: () => Navigator.pop(ctx, true),
            label: Text(tr('tbl.delete')),
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
    _toast(
        failed == 0
            ? '${tr('tbl.deleted')} ${keys.length} ${tr('tbl.itemsParen')}'
            : '${tr('tbl.deleted')} ${keys.length - failed}, $failed ${tr('tbl.failed')}',
        error: failed > 0);
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
      _toast(
          '${tr('tbl.exported')} ${rows.length} ${tr('tbl.rowsSuffix')} → $path');
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: csv));
      _toast(tr('tbl.csvClipboardFallback'));
    }
  }

  // Strong confirmation before a raw item write on a redimos table.
  Future<bool> _confirmRawWrite(String verb) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$verb a raw item on a redimos table?'),
        content: SizedBox(
          width: 430,
          child: Text(tr('tbl.rawWriteBody')),
        ),
        actions: [
          CodexButton(
              variant: CodexButtonVariant.ghost,
              semanticLabel: tr('tbl.cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              label: Text(tr('tbl.cancel'))),
          CodexButton(
            variant: CodexButtonVariant.danger,
            semanticLabel: '$verb anyway',
            onPressed: () => Navigator.pop(ctx, true),
            label: Text('$verb anyway'),
          ),
        ],
      ),
    );
    return go == true;
  }

  // ---- small helpers ----

  // House label grammar (endpoint Configure _field): recessed uppercase
  // eyebrow over the control.
  Text _labelText(String label) => Text(label.toUpperCase(),
      style: Ts.style(
          size: Ts.xs,
          weight: FontWeight.w600,
          letterSpacing: 0.5,
          color: AppTokens.of(context).text3,
          height: 14 / 11));

  Widget _labeled(String label, Widget field) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _labelText(label),
        const SizedBox(height: 5),
        field,
      ]);

  Widget _readonlyAttr(String name) {
    final t = AppTokens.of(context);
    return Container(
      height: Dim.ctlH,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: t.panel2,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(Dim.radiusS),
      ),
      child: Text(name.isEmpty ? '—' : name,
          style:
              Ts.style(size: Ts.sm, color: t.text2, monoFont: true)),
    );
  }
}
