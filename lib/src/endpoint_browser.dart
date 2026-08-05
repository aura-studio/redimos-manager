// The endpoint "Browser" tab (v1.2 R7) — the endpoint's three former storage
// tabs merged into one two-pane view: a compact **Tables** sidebar on the left
// (the endpoint's table list + lifecycle ops in each row's right-click menu)
// and the item **Explorer** on the right (table_page's Scan/Query + item
// editor), driven by the table selected on the left.
//
// The sidebar reuses rm_ep_list_tables + TableLifecycle (same ops, guards and
// friction ladders as the full-width Endpoint tab). The Explorer runs with
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

const _green = Color(0xFF3BA55D);

class EndpointBrowserView extends StatefulWidget {
  final NativeCore core;

  /// The endpoint's synthesized storage config (toStorageConfig; table == '').
  final RedimosConfig config;
  final DdbEndpoint endpoint;
  const EndpointBrowserView(
      {super.key, required this.core, required this.config, required this.endpoint});

  @override
  State<EndpointBrowserView> createState() => _EndpointBrowserViewState();
}

class _EndpointBrowserViewState extends State<EndpointBrowserView>
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
  void didUpdateWidget(EndpointBrowserView old) {
    super.didUpdateWidget(old);
    _lc.config = widget.config; // ops read it at call time — keep it fresh
    if (old.config.id != widget.config.id ||
        old.config.endpoint != widget.config.endpoint) {
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
      SizedBox(width: 264, child: _sidebar()),
      const VerticalDivider(width: 1),
      Expanded(child: _explorer()),
    ]);
  }

  // ---- left pane: the Tables sidebar ----

  Widget _sidebar() {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        child: Row(children: [
          Icon(Icons.folder_open, size: 16, color: scheme.primary),
          const SizedBox(width: 7),
          Text(tr('ep.tables'),
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
          if (!_loading && _error == null) ...[
            const SizedBox(width: 6),
            Text('${_tables.length}',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          ],
          const Spacer(),
          IconButton(
            tooltip: tr('ep.refresh'),
            visualDensity: VisualDensity.compact,
            onPressed: _busy || _loading ? null : _load,
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ]),
      ),
      if (_awsMode)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(children: [
            Icon(Icons.lock_outline, size: 13, color: Colors.amber.shade700),
            const SizedBox(width: 5),
            Expanded(
              child: Text(tr('ep.awsReadOnly'),
                  style: TextStyle(fontSize: 11, color: Colors.amber.shade700)),
            ),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: TextField(
          controller: _filter,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 16),
            prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            hintText: tr('ep.filterTables'),
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
          ),
        ),
      ),
      const Divider(height: 1),
      Expanded(child: _list()),
    ]);
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

  Widget _tableRow(Map<String, dynamic> t) {
    final scheme = Theme.of(context).colorScheme;
    final name = t['name']?.toString() ?? '?';
    final missing = t['missing'] == true;
    final selected = !missing && _selected == name;
    final menu = _menuChildren(t, missing: missing);

    Widget content({MenuController? controller}) => Material(
          color: selected ? scheme.primary.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: missing ? null : () => setState(() => _selected = name),
            onSecondaryTapUp: controller == null
                ? null
                : (_) => controller.isOpen ? controller.close() : controller.open(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
              child: Row(children: [
                _statusDot(missing ? 'missing' : (t['status']?.toString() ?? '')),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                        fontStyle: missing ? FontStyle.italic : FontStyle.normal,
                        color: missing
                            ? scheme.onSurfaceVariant
                            : (selected ? scheme.primary : null),
                      )),
                ),
                if (missing) ...[
                  const SizedBox(width: 4),
                  Text(tr('ep.missing'),
                      style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant)),
                ] else ...[
                  const SizedBox(width: 4),
                  Text(_countShort(t),
                      style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
                ],
                const SizedBox(width: 2),
                _kindDot(t['kind']?.toString() ?? 'raw'),
                if (controller != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: tr('ep.tableOperations'),
                    icon: const Icon(Icons.more_vert, size: 16),
                    onPressed: _busy
                        ? null
                        : () => controller.isOpen ? controller.close() : controller.open(),
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

  // Right-click / ⋮ lifecycle menu. Same ops, guards and flows as the
  // full-width Endpoint tab: AWS shows nothing destructive; Browse (select)
  // works anywhere; Purge/Delete act on any table; Recreate/Provision need a
  // bound config to author the schema.
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

  Widget _explorer() {
    final sel = _selected;
    if (sel == null) {
      return _center(Icons.touch_app_outlined, tr('epb.noTableSelected'),
          _awsMode ? tr('epb.pickTableHintAws') : tr('epb.pickTableHint'));
    }
    return TablePageView(
      key: ValueKey('epb-explore-${widget.endpoint.id}'),
      core: widget.core,
      config: widget.config,
      running: true, // storage views connect to DynamoDB directly
      tableOverride: sel,
      // The endpoint is the authority on its own data: on non-AWS backends the
      // Explorer offers item writes here (with the raw-write confirmation),
      // unlike an instance browsing a foreign table read-only.
      allowOverrideWrites: !_awsMode,
    );
  }

  // ---- small helpers ----

  Widget _statusDot(String status) {
    final color = switch (status.toUpperCase()) {
      'ACTIVE' => _green,
      'CREATING' || 'UPDATING' => Colors.amber,
      'DELETING' => Colors.orange,
      'MISSING' => Colors.grey,
      _ => Colors.grey,
    };
    return Container(
        width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }

  Widget _kindDot(String kind) {
    final (Color c, String label) = switch (kind) {
      'v2' => (const Color(0xFF3B6EA5), 'v2'),
      'v1' => (Colors.amber.shade700, 'v1'),
      _ => (Theme.of(context).colorScheme.onSurfaceVariant, 'raw'),
    };
    return Tooltip(
      message: kind == 'raw' ? 'raw' : 'redimos $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: c)),
      ),
    );
  }

  String _countShort(Map<String, dynamic> t) {
    final items = (t['itemCount'] as num?)?.toInt();
    if (items == null || items < 0) return '';
    return TableLifecycle.fmtInt(items);
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
