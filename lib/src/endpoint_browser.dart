// The endpoint "Endpoint" tab (v1.2 redesign) — every table on the backend,
// full width, in the shape v1's EndpointPageView had: a header with the table
// count + refresh, the table list, and the "＋ Table" foot CTA. A row tap
// bridges into the Table tab via onOpenTable — HomePage owns the screen index
// and the selected table (mirroring v1's _browseTable).
//
// Lifecycle ops stay on the right-click menu (table_lifecycle.dart owns the
// ops, guards and friction ladders). On AWS backends the list is read-only:
// no menu ops, no table creation, and a lock banner.

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'table_lifecycle.dart';
import 'ui_primitives.dart';
import 'ui_states.dart';
import 'ui_surfaces.dart';
import 'ui_table.dart';
import 'ui_tokens.dart';

class EndpointTablesView extends StatefulWidget {
  final NativeCore core;

  /// The endpoint's synthesized storage config (toStorageConfig; table == '').
  final RedimosConfig config;
  final DdbEndpoint endpoint;

  /// Row tap / Browse menu item bridges into the Table tab.
  final void Function(String table)? onOpenTable;
  const EndpointTablesView(
      {super.key,
      required this.core,
      required this.config,
      required this.endpoint,
      this.onOpenTable});

  @override
  State<EndpointTablesView> createState() => _EndpointTablesViewState();
}

class _EndpointTablesViewState extends State<EndpointTablesView>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _tables = [];
  bool _awsMode = false;
  bool _busy = false;
  int _loadGeneration = 0;

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
  void didUpdateWidget(EndpointTablesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_storageContextChanged(oldWidget.config, widget.config) ||
        oldWidget.endpoint.id != widget.endpoint.id) {
      _entityGeneration++;
      _loadGeneration++;
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
      } else {
        _error = r['error']?.toString() ?? tr('ep.failedToListTables');
      }
    });
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppTokens.of(context);
    // Same page grammar as the Configure / Service screens: the house 22/18
    // gutter around ONE elevated section card — panel2 head band (count +
    // title + refresh), the table-list body, panel2 foot band with the
    // reserved ＋ Table CTA right-aligned like every other action bar.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: CodexSurface(
        variant: CodexSurfaceVariant.elevated,
        padding: EdgeInsets.zero,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _head(t),
          const CodexDivider(),
          if (_awsMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Row(children: [
                Icon(Icons.lock_outline, size: 13, color: t.warning),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(tr('ep.awsReadOnly'),
                      style: Ts.style(size: Ts.xs, color: t.warning)),
                ),
              ]),
            ),
          Expanded(child: _list()),
          _foot(t),
        ]),
      ),
    );
  }

  // Section-card head band: mono count + uppercase title on panel2, refresh
  // on the right (mirrors _section in service_configure.dart / the endpoint
  // Configure pane, minus the number badge — this is a list, not a form).
  Widget _head(AppTokens t) => Container(
        key: const ValueKey('endpoint-tables-header'),
        height: 40,
        color: t.panel2,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: [
          Text('${_tables.length}',
              style: Ts.style(
                  size: Ts.md,
                  weight: FontWeight.w700,
                  color: t.text,
                  monoFont: true,
                  tabularNums: true)),
          const SizedBox(width: 8),
          Text(tr('ep.tables').toUpperCase(),
              style: Ts.style(
                  size: Ts.md,
                  letterSpacing: 0.9,
                  weight: FontWeight.w700,
                  color: t.text)),
          const Spacer(),
          CodexIconButton(
            semanticLabel: tr('ep.refresh'),
            tooltip: tr('ep.refresh'),
            onPressed: _busy || _loading ? null : _load,
            icon: const Icon(Icons.refresh, size: 16),
          ),
        ]),
      );

  // Creating a table still has no native operation. The reserved action only
  // explains that boundary and never attempts a partial write.
  Widget _foot(AppTokens t) => Container(
        key: const ValueKey('endpoint-tables-footer'),
        height: 46,
        decoration: BoxDecoration(
          color: t.panel2,
          border: Border(top: BorderSide(color: t.hairline)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          const Spacer(),
          CodexButton(
            semanticLabel: '＋ Table',
            onPressed: _awsMode || _busy
                ? null
                : () => _toast(
                    'Creating tables needs engine support (rm_table_create) — not available yet.'),
            label: Text('＋ Table',
                style: Ts.style(size: Ts.md, weight: FontWeight.w500)),
          ),
        ]),
      );

  Widget _list() {
    final rows = _tables;
    final state = _loading
        ? CodexContentState.loading
        : _error != null
            ? CodexContentState.error
            : rows.isEmpty
                ? CodexContentState.empty
                : CodexContentState.content;
    return CodexStateShell(
      key: const ValueKey('endpoint-tables-state'),
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
              ? tr('ep.noTablesHint')
              : null,
      retryLabel: tr('ep.retry'),
      onRetry: state == CodexContentState.error ? _load : null,
      bodyPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    );
  }

  // Mockup .tbl-node: fixed 30px row — a leading accent ⛁ glyph + the mono
  // 12px table name (500) + a right-aligned .cnt. Lifecycle actions live on
  // the right-click menu (the mockup has no status dot / kind badge / ⋮).
  Widget _tableRow(Map<String, dynamic> t) {
    final tok = AppTokens.of(context);
    final name = t['name']?.toString() ?? '?';
    final missing = t['missing'] == true;
    final menu = _menuChildren(t, missing: missing);

    Widget content({MenuController? controller}) => ClipRRect(
          borderRadius: BorderRadius.circular(Dim.radiusS),
          child: CodexTableRow(
            selected: false,
            semanticLabel:
                missing ? '$name ${tr('ep.missing')}' : _tooltipFor(t),
            onTap: missing ? null : () => _openTable(name),
            onSecondaryTapUp: controller == null
                ? null
                : (_) =>
                    controller.isOpen ? controller.close() : controller.open(),
            children: [
              const SizedBox(width: 12),
              Icon(Icons.table_chart_outlined, size: 15, color: tok.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: Ts.style(
                    size: Ts.md,
                    weight: FontWeight.w500,
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
                    color: tok.text3,
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

  void _openTable(String name) => widget.onOpenTable?.call(name);

  // Right-click lifecycle menu via TableLifecycle: AWS shows nothing
  // destructive; Browse bridges into the Table tab; Purge/Delete act on any
  // table; Recreate/Provision need a bound config to author the schema.
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
        onPressed: () => _openTable(name),
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
}
