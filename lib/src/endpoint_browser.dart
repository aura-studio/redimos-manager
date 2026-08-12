// The endpoint "Browser" tab (v1.2 R7) — the endpoint's storage surfaces
// merged into one two-pane view: a compact **Tables** sidebar on the left (the
// endpoint's table list + lifecycle ops in each row's right-click menu) and
// the item **Explorer** on the right (table_page's Scan/Query + item editor),
// driven by the table selected on the left.
//
// The sidebar drives rm_ep_list_tables + TableLifecycle (table_lifecycle.dart
// owns the ops, guards and friction ladders). The Explorer runs with
// allowOverrideWrites on non-AWS endpoints: an endpoint is the authority on
// its own data, so item writes are offered there (with the same raw-write
// confirmation); on AWS endpoints every destructive affordance is hidden and
// the native layer re-guards regardless.

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'table_lifecycle.dart';
import 'table_page.dart';
import 'ui_primitives.dart';
import 'ui_states.dart';
import 'ui_surfaces.dart';
import 'ui_table.dart';
import 'ui_tokens.dart';

class EndpointBrowserView extends StatefulWidget {
  final NativeCore core;

  /// The endpoint's synthesized storage config (toStorageConfig; table == '').
  final RedimosConfig config;
  final DdbEndpoint endpoint;
  const EndpointBrowserView(
      {super.key,
      required this.core,
      required this.config,
      required this.endpoint});

  @override
  State<EndpointBrowserView> createState() => EndpointBrowserViewState();
}

// Public state: HomePage's MidBar "＋ Item" CTA reaches createItem() via a key.
class EndpointBrowserViewState extends State<EndpointBrowserView>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _tables = [];
  bool _awsMode = false;
  final _filter = TextEditingController();
  bool _busy = false;
  int _loadGeneration = 0;

  /// The table selected in the sidebar; drives the Explorer pane on the right.
  String? _selected;

  late TableLifecycle _lc;
  int _entityGeneration = 0;

  @override
  bool get wantKeepAlive => true;

  TableLifecycle _newLifecycle(int generation) => TableLifecycle(
        core: widget.core,
        config: widget.config,
        toast: (message, {error = false}) {
          if (mounted && generation == _entityGeneration) {
            _toast(message, error: error);
          }
        },
        onChanged: () {
          if (mounted && generation == _entityGeneration) _load();
        },
        setBusy: (busy) {
          if (mounted && generation == _entityGeneration) {
            setState(() => _busy = busy);
          }
        },
      );

  @override
  void initState() {
    super.initState();
    _lc = _newLifecycle(_entityGeneration);
    _load();
  }

  @override
  void didUpdateWidget(EndpointBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_storageContextChanged(oldWidget.config, widget.config) ||
        oldWidget.endpoint.id != widget.endpoint.id) {
      _entityGeneration++;
      _loadGeneration++;
      _selected = null;
      _explorerState = null;
      _filter.clear();
      _tables = [];
      _awsMode = false;
      _busy = false;
      _lc = _newLifecycle(_entityGeneration);
      _load();
    } else {
      _lc.config = widget.config;
    }
  }

  bool _storageContextChanged(RedimosConfig a, RedimosConfig b) =>
      a.id != b.id ||
      a.endpoint != b.endpoint ||
      a.partitionID != b.partitionID ||
      a.region != b.region ||
      a.accessKeyId != b.accessKeyId ||
      a.secretKey != b.secretKey ||
      a.sessionToken != b.sessionToken ||
      a.source != b.source;

  @override
  void dispose() {
    _entityGeneration++;
    _loadGeneration++;
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final loadGeneration = ++_loadGeneration;
    final entityGeneration = _entityGeneration;
    final config = widget.config;
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await widget.core.epListTables(config);
    if (!mounted ||
        loadGeneration != _loadGeneration ||
        entityGeneration != _entityGeneration) {
      return;
    }
    setState(() {
      _loading = false;
      if (r['ok'] == true) {
        _tables = ((r['tables'] as List?) ?? [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _awsMode = r['awsMode'] == true;
        _error = null;
        // Drop the selection if its table vanished (e.g. just deleted from the
        // sidebar menu) so the Explorer falls back to the pick-a-table hint.
        if (_selected != null &&
            !_tables
                .any((t) => t['name'] == _selected && t['missing'] != true)) {
          _selected = null;
          _explorerState = null;
        }
      } else {
        _error = r['error']?.toString() ?? tr('ep.failedToListTables');
      }
    });
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _filter.text.trim().toLowerCase();
    if (q.isEmpty) return _tables;
    return _tables
        .where((t) => (t['name']?.toString().toLowerCase() ?? '').contains(q))
        .toList();
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // v2.3: the Tables sidebar narrows to the design's 230px.
      SizedBox(width: Dim.tablesSideW, child: _sidebar()),
      const CodexDivider(axis: Axis.vertical),
      Expanded(child: _explorerPane()),
    ]);
  }

  // ---- left pane: the Tables sidebar ----

  Widget _sidebar() {
    final tok = AppTokens.of(context);
    final brightness = Theme.of(context).brightness;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tok.panel,
        boxShadow: Depth.elevSide(brightness),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          key: const ValueKey('endpoint-browser-sidebar-header'),
          height: 34,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  child: Row(children: [
                    Text('${_tables.length} ',
                        style: Ts.style(
                            size: Ts.sm,
                            weight: FontWeight.w600,
                            color: tok.text,
                            monoFont: true,
                            tabularNums: true)),
                    Text('tables',
                        style: Ts.style(
                            size: Ts.sm, color: tok.text2, monoFont: true)),
                    const Spacer(),
                    CodexIconButton(
                      semanticLabel: tr('ep.refresh'),
                      tooltip: tr('ep.refresh'),
                      onPressed: _busy || _loading ? null : _load,
                      icon: const Icon(Icons.refresh, size: 16),
                    ),
                  ]),
                ),
              ),
              const CodexDivider(),
            ],
          ),
        ),
        if (_awsMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Row(children: [
              Icon(Icons.lock_outline, size: 13, color: tok.warning),
              const SizedBox(width: 5),
              Expanded(
                child: Text(tr('ep.awsReadOnly'),
                    style: Ts.style(size: Ts.xs, color: tok.warning)),
              ),
            ]),
          ),
        Expanded(child: _list()),
        _sideFoot(),
      ]),
    );
  }

  // Creating a table still has no native operation. The reserved action only
  // explains that boundary and never attempts a partial write.
  Widget _sideFoot() => SizedBox(
        key: const ValueKey('endpoint-browser-sidebar-footer'),
        height: 42,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const CodexDivider(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                child: CodexButton(
                  semanticLabel: '＋ Table',
                  onPressed: _awsMode || _busy
                      ? null
                      : () => _toast(
                          'Creating tables needs engine support (rm_table_create) — not available yet.'),
                  icon: const Icon(Icons.add, size: 14),
                  label: Text('＋ Table',
                      style: Ts.style(size: Ts.md, weight: FontWeight.w500)),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _list() {
    final rows = _filtered;
    final state = _loading
        ? CodexContentState.loading
        : _error != null
            ? CodexContentState.error
            : rows.isEmpty
                ? CodexContentState.empty
                : CodexContentState.content;
    final filtered = _filter.text.trim();
    return CodexStateShell(
      key: const ValueKey('endpoint-browser-table-state'),
      state: state,
      content: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
        itemCount: rows.length,
        itemBuilder: (_, i) => _tableRow(rows[i]),
      ),
      message: state == CodexContentState.error
          ? tr('ep.cannotListTables')
          : state == CodexContentState.empty
              ? tr('ep.noTables')
              : '',
      detail: state == CodexContentState.error
          ? _error
          : state == CodexContentState.empty
              ? filtered.isEmpty
                  ? tr('ep.noTablesHint')
                  : '${tr('ep.noTablesMatch')} “$filtered”.'
              : null,
      retryLabel: tr('ep.retry'),
      onRetry: state == CodexContentState.error ? _load : null,
      bodyPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    );
  }

  // Mockup .tbl-node: fixed 30px row — a leading accent ⛁ glyph + the mono
  // 12px table name (500, 600 when selected) + a right-aligned .cnt. Selected
  // row = neutral selection fill + a 2px inset left accent bar; the name keeps
  // its colour. Lifecycle actions move off the row onto the right-click menu
  // (the mockup has no status dot / kind badge / ⋮ button).
  Widget _tableRow(Map<String, dynamic> t) {
    final tok = AppTokens.of(context);
    final name = t['name']?.toString() ?? '?';
    final missing = t['missing'] == true;
    final selected = !missing && _selected == name;
    final menu = _menuChildren(t, missing: missing);

    Widget content({MenuController? controller}) => ClipRRect(
          borderRadius: BorderRadius.circular(Dim.radiusS),
          child: CodexTableRow(
            selected: selected,
            semanticLabel:
                missing ? '$name ${tr('ep.missing')}' : _tooltipFor(t),
            onTap: missing ? null : () => _selectTable(name),
            onSecondaryTapUp: controller == null
                ? null
                : (_) =>
                    controller.isOpen ? controller.close() : controller.open(),
            children: [
              const SizedBox(width: 12),
              Text('⛁', style: Ts.style(size: 13, color: tok.accent)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: Ts.style(
                    size: Ts.md,
                    weight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: missing ? tok.text3 : tok.text,
                    monoFont: true,
                  ).copyWith(
                    fontStyle: missing ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ),
              if (missing) ...[
                const SizedBox(width: 4),
                Text(tr('ep.missing'),
                    style: Ts.style(size: 9.5, color: tok.text3)),
              ] else ...[
                const SizedBox(width: 8),
                Text(
                  _countShort(t),
                  style: Ts.style(
                    size: Ts.xs,
                    color: selected ? tok.text2 : tok.text3,
                    weight: selected ? FontWeight.w600 : FontWeight.normal,
                    monoFont: true,
                    tabularNums: true,
                  ),
                ),
              ],
              const SizedBox(width: 12),
            ],
          ),
        );

    final row = menu.isEmpty
        ? content()
        : MenuAnchor(
            builder: (ctx, controller, _) => content(controller: controller),
            menuChildren: menu,
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Tooltip(
        waitDuration: const Duration(milliseconds: 600),
        message: missing ? '$name ${tr('ep.missing')}' : _tooltipFor(t),
        child: row,
      ),
    );
  }

  // Right-click / ⋮ lifecycle menu via TableLifecycle: AWS shows nothing
  // destructive; Browse (select) works anywhere; Purge/Delete act on any table;
  // Recreate/Provision need a bound config to author the schema.
  List<Widget> _menuChildren(Map<String, dynamic> t, {required bool missing}) {
    if (_awsMode) {
      return const []; // AWS: read-only — selection happens on click
    }
    final name = t['name']?.toString() ?? '';
    final usedBy = ((t['usedBy'] as List?) ?? []).cast<Map>();
    final boundId = TableLifecycle.authoringConfig(
        usedBy, t['kind']?.toString(), widget.config.id);
    if (missing) {
      return [
        if (boundId != null)
          MenuItemButton(
            leadingIcon: const Icon(Icons.add_circle_outline, size: 18),
            onPressed: _busy
                ? null
                : () => _lc.recreate(context, boundId, provision: true),
            child: Text(tr('ep.provision')),
          ),
      ];
    }
    final scheme = Theme.of(context).colorScheme;
    return [
      MenuItemButton(
        leadingIcon: const Icon(Icons.visibility_outlined, size: 18),
        onPressed: () => _selectTable(name),
        child: Text(tr('ep.browse')),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.cleaning_services_outlined, size: 18),
        onPressed: _busy ? null : () => _lc.purge(context, name),
        child: Text(tr('ep.purgeItems')),
      ),
      if (boundId != null)
        MenuItemButton(
          leadingIcon: const Icon(Icons.restart_alt, size: 18),
          onPressed: _busy
              ? null
              : () => _lc.recreate(context, boundId, provision: false),
          child: Text(tr('ep.recreateTable')),
        ),
      MenuItemButton(
        leadingIcon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
        onPressed: _busy ? null : () => _lc.delete(context, name),
        child:
            Text(tr('ep.deleteTable'), style: TextStyle(color: scheme.error)),
      ),
    ];
  }

  // ---- right pane: the Explorer ----

  void _selectTable(String name) {
    if (_selected == name) return;
    setState(() {
      _selected = name;
      _explorerState = null;
    });
  }

  // The live Explorer state, registered via onExplorerReady so the HomePage
  // MidBar "＋ Item" CTA (idx 1) can open the current table's create flow.
  TablePageViewState? _explorerState;

  /// MidBar bridge: create an item in the table currently selected in the
  /// sidebar. False when nothing is selected (HomePage falls back to a toast).
  bool createItem() {
    final st = _explorerState;
    if (_selected == null || st == null) return false;
    st.createItem();
    return true;
  }

  Widget _explorerPane() {
    final sel = _selected;
    if (sel == null) {
      return _center(Icons.touch_app_outlined, tr('epb.noTableSelected'),
          _awsMode ? tr('epb.pickTableHintAws') : tr('epb.pickTableHint'));
    }
    return TablePageView(
      key: ValueKey('epb-explore-${widget.endpoint.id}-$sel'),
      onExplorerReady: (st) => _explorerState = st,
      core: widget.core,
      config: widget.config,
      tableOverride: sel,
      // The endpoint is the authority on its own data: on non-AWS backends the
      // Explorer offers item writes here (with the raw-write confirmation);
      // on AWS the view stays read-only.
      allowOverrideWrites: !_awsMode,
    );
  }

  // ---- small helpers ----

  // Mockup .tbl-node .cnt is a COMPACT count (12.4k / 3.1k / 892), not a
  // comma-grouped integer.
  String _countShort(Map<String, dynamic> t) {
    final items = (t['itemCount'] as num?)?.toInt();
    if (items == null || items < 0) return '';
    return _fmtCompact(items);
  }

  static String _fmtCompact(int v) {
    if (v < 1000) return '$v';
    String unit(double x, String u) {
      final s = (x * 10).round() / 10;
      return '${s % 1 == 0 ? s.toInt() : s}$u';
    }

    if (v < 1000000) return unit(v / 1000, 'k');
    return unit(v / 1000000, 'M');
  }

  String _tooltipFor(Map<String, dynamic> t) {
    final parts = <String>[t['name']?.toString() ?? '?'];
    final pk = t['pkName']?.toString() ?? '';
    final sk = t['skName']?.toString() ?? '';
    if (pk.isNotEmpty) parts.add(pk + (sk.isEmpty ? '' : ' + $sk'));
    final items = (t['itemCount'] as num?)?.toInt();
    if (items != null && items >= 0) {
      parts.add(trp('ep.nItems', {'n': TableLifecycle.fmtInt(items)}));
    }
    final size = (t['sizeBytes'] as num?)?.toInt();
    if (size != null && size > 0) parts.add(TableLifecycle.fmtBytes(size));
    return parts.join(' · ');
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    final tok = AppTokens.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? tok.danger : null,
      duration: const Duration(seconds: 3),
    ));
  }

  Widget _center(IconData icon, String title, String subtitle,
      {Widget? action}) {
    final tok = AppTokens.of(context);
    return CodexSurface(
      key: const ValueKey('endpoint-browser-explorer-empty'),
      variant: CodexSurfaceVariant.sunken,
      padding: EdgeInsets.zero,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 32, color: tok.text3),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: Ts.style(
                    size: Ts.lg, weight: FontWeight.w600, color: tok.text2)),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Text(subtitle,
                  textAlign: TextAlign.center,
                  style: Ts.style(size: Ts.md, color: tok.text3)),
            ),
            if (action != null) ...[const SizedBox(height: 16), action],
          ]),
        ),
      ),
    );
  }
}
