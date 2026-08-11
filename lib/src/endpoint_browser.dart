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
import 'ui_tokens.dart';

class EndpointBrowserView extends StatefulWidget {
  final NativeCore core;

  /// The endpoint's synthesized storage config (toStorageConfig; table == '').
  final RedimosConfig config;
  final DdbEndpoint endpoint;
  const EndpointBrowserView(
      {super.key, required this.core, required this.config, required this.endpoint});

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

  /// The table selected in the sidebar; drives the Explorer pane on the right.
  String? _selected;

  late final TableLifecycle _lc = TableLifecycle(
    core: widget.core,
    config: widget.config,
    toast: _toast,
    onChanged: _load,
    setBusy: (b) {
      if (mounted) setState(() => _busy = b);
    },
  );

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(EndpointBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _lc.config = widget.config; // ops read it at call time — keep it fresh
    if (oldWidget.config.id != widget.config.id ||
        oldWidget.config.endpoint != widget.config.endpoint) {
      _selected = null;
      _load();
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await widget.core.epListTables(widget.config);
    if (!mounted) return;
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
            !_tables.any((t) => t['name'] == _selected && t['missing'] != true)) {
          _selected = null;
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
      const VerticalDivider(width: 1),
      Expanded(child: _explorerPane()),
    ]);
  }

  // ---- left pane: the Tables sidebar ----

  Widget _sidebar() {
    final tok = AppTokens.of(context);
    final brightness = Theme.of(context).brightness;
    // Mockup .tables-side: a compact .side-tools row (count + refresh, NO title
    // text / folder icon / filter box), the tbl-node tree, then a ＋Table foot.
    // Right-edge soft shadow (var(--elev-side)).
    return Container(
      decoration: BoxDecoration(boxShadow: Depth.elevSide(brightness)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // .side-tools: 7px/12px padding, hairline bottom border.
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tok.hairline)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(children: [
            // .count: mono text-2, the number emphasized (text + 600 tabular).
            // Plain Texts, not Text.rich — the capture channel rasterizes rich
            // runs as .notdef blocks (pixel-fidelity-v23 CP 9.x).
            Text('${_tables.length} ',
                style: Ts.style(
                    size: Ts.sm, weight: FontWeight.w600, color: tok.text, monoFont: true, tabularNums: true)),
            Text('tables', style: Ts.style(size: Ts.sm, color: tok.text2, monoFont: true)),
            const Spacer(),
            // .ibtn refresh.
            InkWell(
              borderRadius: BorderRadius.circular(Dim.radiusS),
              onTap: _busy || _loading ? null : _load,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.refresh, size: 16, color: tok.text3),
              ),
            ),
          ]),
        ),
        if (_awsMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Row(children: [
              Icon(Icons.lock_outline, size: 13, color: tok.warning),
              const SizedBox(width: 5),
              Expanded(
                child: Text(tr('ep.awsReadOnly'),
                    style: TextStyle(fontSize: 11, color: tok.warning)),
              ),
            ]),
          ),
        Expanded(child: _list()),
        _sideFoot(),
      ]),
    );
  }

  // v2.3 ＋Table foot entry. R5.2 reservation: creating a table needs a native
  // rm_table_create call the Go core doesn't expose yet — the button stays
  // visible (the design's grammar) but only explains, it never half-creates.
  Widget _sideFoot() {
    final tok = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tok.hairline)),
      ),
      child: SizedBox(
        height: 26,
        child: OutlinedButton.icon(
          onPressed: _awsMode || _busy
              ? null
              : () => _toast(
                  'Creating tables needs engine support (rm_table_create) — not available yet.'),
          icon: const Icon(Icons.add, size: 14),
          // No i18n key for a create-table action (R5.2 reservation) — the
          // design's own label.
          label: Text('＋ Table', style: Ts.style(size: Ts.md, weight: FontWeight.w500)),
          style: OutlinedButton.styleFrom(
            foregroundColor: tok.text2,
            side: BorderSide(color: tok.border),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Dim.radiusS)),
          ),
        ),
      ),
    );
  }

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _center(Icons.error_outline, tr('ep.cannotListTables'), _error!,
          action: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(tr('ep.retry'))));
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return _center(
          Icons.inbox_outlined,
          tr('ep.noTables'),
          _filter.text.trim().isEmpty
              ? tr('ep.noTablesHint')
              : '${tr('ep.noTablesMatch')} “${_filter.text.trim()}”.');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      itemCount: rows.length,
      itemBuilder: (_, i) => _tableRow(rows[i]),
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

    Widget content({MenuController? controller}) => Material(
          color: selected ? tok.selection : Colors.transparent,
          borderRadius: BorderRadius.circular(Dim.radiusS),
          child: InkWell(
            borderRadius: BorderRadius.circular(Dim.radiusS),
            onTap: missing ? null : () => setState(() => _selected = name),
            onSecondaryTapUp: controller == null
                ? null
                : (_) => controller.isOpen ? controller.close() : controller.open(),
            child: SizedBox(
              height: Dim.rowH, // 30
              child: Stack(children: [
                // .sel inset 2px left accent bar.
                if (selected)
                  Positioned(
                    left: 0, top: 0, bottom: 0, width: 2,
                    child: Container(color: tok.accent),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                  child: Row(children: [
                    // .tbl-ico: accent ⛁ leading glyph.
                    Text('⛁', style: Ts.style(size: 13, color: tok.accent)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: Ts.style(
                            size: Ts.md, // 12
                            weight: selected ? FontWeight.w600 : FontWeight.w500,
                            color: missing ? tok.text3 : tok.text,
                            monoFont: true,
                          ).copyWith(
                              fontStyle:
                                  missing ? FontStyle.italic : FontStyle.normal)),
                    ),
                    if (missing) ...[
                      const SizedBox(width: 4),
                      Text(tr('ep.missing'), style: Ts.style(size: 9.5, color: tok.text3)),
                    ] else ...[
                      // .cnt: right-aligned 11px count (text-2/600 when selected).
                      const SizedBox(width: 8),
                      Text(_countShort(t),
                          style: Ts.style(
                              size: Ts.xs, // 11
                              color: selected ? tok.text2 : tok.text3,
                              weight: selected ? FontWeight.w600 : FontWeight.normal,
                              monoFont: true,
                              tabularNums: true)),
                    ],
                  ]),
                ),
              ]),
            ),
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
    if (_awsMode) return const []; // AWS: read-only — selection happens on click
    final name = t['name']?.toString() ?? '';
    final usedBy = ((t['usedBy'] as List?) ?? []).cast<Map>();
    final boundId =
        TableLifecycle.authoringConfig(usedBy, t['kind']?.toString(), widget.config.id);
    if (missing) {
      return [
        if (boundId != null)
          MenuItemButton(
            leadingIcon: const Icon(Icons.add_circle_outline, size: 18),
            onPressed: _busy ? null : () => _lc.recreate(context, boundId, provision: true),
            child: Text(tr('ep.provision')),
          ),
      ];
    }
    final scheme = Theme.of(context).colorScheme;
    return [
      MenuItemButton(
        leadingIcon: const Icon(Icons.visibility_outlined, size: 18),
        onPressed: () => setState(() => _selected = name),
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
          onPressed: _busy ? null : () => _lc.recreate(context, boundId, provision: false),
          child: Text(tr('ep.recreateTable')),
        ),
      MenuItemButton(
        leadingIcon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
        onPressed: _busy ? null : () => _lc.delete(context, name),
        child: Text(tr('ep.deleteTable'), style: TextStyle(color: scheme.error)),
      ),
    ];
  }

  // ---- right pane: the Explorer ----

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
      key: ValueKey('epb-explore-${widget.endpoint.id}'),
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
    if (items != null && items >= 0) parts.add(trp('ep.nItems', {'n': TableLifecycle.fmtInt(items)}));
    final size = (t['sizeBytes'] as num?)?.toInt();
    if (size != null && size > 0) parts.add(TableLifecycle.fmtBytes(size));
    return parts.join(' · ');
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade800 : null,
      duration: const Duration(seconds: 3),
    ));
  }

  Widget _center(IconData icon, String title, String subtitle, {Widget? action}) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          if (action != null) ...[const SizedBox(height: 16), action],
        ]),
      );
}
