// The "Endpoint" tab — a dynamodb-admin-style landing page listing every table
// on the selected config's endpoint (Name / key schema / indexes / item count /
// size / status), with a redimos-kind badge, the configs that use each table,
// and "ghost" rows for tables a config is bound to but that don't exist yet.
//
// Read-only listing (native rm_ep_list_tables talks to DynamoDB directly, so it
// works whether or not the proxy is running). Destructive actions obey the same
// hard wall as elsewhere: Recreate/Provision only for redimos-bound tables on an
// explicit endpoint; AWS mode is strictly read-only. Delete-of-unbound-tables and
// raw Create are deferred (Phase 2/3) — kept out to add no new destructive FFI.

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'table_lifecycle.dart';

const _green = Color(0xFF3BA55D);

class EndpointPageView extends StatefulWidget {
  final NativeCore core;
  final RedimosConfig config;
  final bool running;
  final void Function(String table) onOpenTable;
  const EndpointPageView({
    super.key,
    required this.core,
    required this.config,
    required this.running,
    required this.onOpenTable,
  });

  @override
  State<EndpointPageView> createState() => _EndpointPageViewState();
}

class _EndpointPageViewState extends State<EndpointPageView>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _tables = [];
  bool _awsMode = false;
  bool _loopback = false;
  String _endpoint = '';
  final _filter = TextEditingController();
  bool _busy = false;

  // Purge/Recreate/Provision/Delete flows live in TableLifecycle (shared with
  // the endpoint Browser's Tables sidebar); this view keeps its list + dialogs
  // presentation while the ops/guards stay identical.
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
  void didUpdateWidget(EndpointPageView old) {
    super.didUpdateWidget(old);
    _lc.config = widget.config; // ops read it at call time — keep it fresh
    if (old.config.id != widget.config.id ||
        old.config.endpoint != widget.config.endpoint ||
        old.config.table != widget.config.table ||
        old.running != widget.running) { // refresh used-by dots when run state flips
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
        _loopback = r['loopback'] == true;
        _endpoint = r['endpoint']?.toString() ?? '';
        _error = null;
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _header(),
      if (_awsMode) _awsBanner(),
      const Divider(height: 1),
      Expanded(child: _body()),
    ]);
  }

  Widget _header() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Row(children: [
        Icon(Icons.folder_open, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Text(tr('ep.tables'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(width: 10),
        _endpointChip(),
        const Spacer(),
        SizedBox(
          width: 200,
          child: TextField(
            controller: _filter,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: tr('ep.filterTables'),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: tr('ep.refresh'),
          onPressed: _busy || _loading ? null : _load,
          icon: const Icon(Icons.refresh, size: 20),
        ),
      ]),
    );
  }

  Widget _endpointChip() {
    if (_awsMode) {
      return _chip(Icons.cloud_outlined, tr('ep.awsReadOnly'), Colors.amber.shade700);
    }
    final label = _endpoint.isEmpty ? tr('ep.endpoint') : _endpoint;
    return _chip(_loopback ? Icons.lan_outlined : Icons.public,
        _loopback ? '${tr('ep.localLoopback')} · $label' : label,
        _loopback ? _green : Colors.orange.shade700);
  }

  Widget _chip(IconData icon, String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 11.5, color: color)),
        ]),
      );

  Widget _awsBanner() => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
        ),
        child: Row(children: [
          Icon(Icons.warning_amber, size: 18, color: Colors.amber.shade800),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('ep.awsModeBanner'),
              style: TextStyle(fontSize: 12.5, color: Colors.amber.shade900),
            ),
          ),
        ]),
      );

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _center(Icons.error_outline, tr('ep.cannotListTables'), _error!,
          action: FilledButton.icon(
              onPressed: _load, icon: const Icon(Icons.refresh), label: Text(tr('ep.retry'))));
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return _center(Icons.inbox_outlined, tr('ep.noTables'),
          _filter.text.trim().isEmpty
              ? tr('ep.noTablesHint')
              : '${tr('ep.noTablesMatch')} “${_filter.text.trim()}”.');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _tableRow(rows[i]),
    );
  }

  Widget _tableRow(Map<String, dynamic> t) {
    final scheme = Theme.of(context).colorScheme;
    final name = t['name']?.toString() ?? '?';
    final missing = t['missing'] == true;
    final status = t['status']?.toString() ?? '';
    final kind = t['kind']?.toString() ?? 'raw';
    final usedBy = ((t['usedBy'] as List?) ?? []).cast<Map>();
    final itemCount = (t['itemCount'] as num?)?.toInt();
    final sizeBytes = (t['sizeBytes'] as num?)?.toInt();

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Row(children: [
          _statusDot(missing ? 'missing' : status),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: !missing
                      ? InkWell(
                          onTap: () => widget.onOpenTable(name),
                          child: Text(name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: scheme.primary,
                                  decoration: TextDecoration.underline)),
                        )
                      : Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontStyle: missing ? FontStyle.italic : FontStyle.normal,
                              color: missing ? scheme.onSurfaceVariant : null)),
                ),
                if (missing) ...[
                  const SizedBox(width: 6),
                  Text(tr('ep.missing'), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                ],
                const SizedBox(width: 8),
                _kindBadge(kind),
              ]),
              const SizedBox(height: 3),
              Wrap(spacing: 8, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (!missing) Text(_keyLine(t), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                for (final u in usedBy) _usedByChip(u),
              ]),
            ]),
          ),
          const SizedBox(width: 10),
          if (!missing)
            Text(_countLine(itemCount, sizeBytes),
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 10),
          _rowActions(t, missing: missing, usedBy: usedBy),
        ]),
      ),
    );
  }

  Widget _rowActions(Map<String, dynamic> t,
      {required bool missing, required List<Map> usedBy}) {
    final scheme = Theme.of(context).colorScheme;
    final name = t['name']?.toString() ?? '';
    // The config that AUTHORS this table's schema on recreate/provision. Native
    // rebuilds with the passed config's version, so pick deliberately: the config
    // we're viewing first (its version is what the Table tab shows), else one
    // whose version matches the row's detected kind, else the first bound config.
    // Otherwise a v1+v2 shared-table misconfig could rebuild with the wrong keys.
    final String? boundId =
        TableLifecycle.authoringConfig(usedBy, t['kind']?.toString(), widget.config.id);
    final canLifecycle = !_awsMode; // endpoint mode → destructive ops allowed

    final children = <Widget>[];
    if (missing) {
      // A bound-but-missing table can only be Provisioned (needs a config's schema).
      if (canLifecycle && boundId != null) {
        children.add(_actionBtn(tr('ep.provision'), scheme.primary,
            _busy ? null : () => _lc.recreate(context, boundId, provision: true)));
      }
    } else {
      // Browse works for ANY existing table (AWS or endpoint) — the sole AWS action.
      children.add(_actionBtn(tr('ep.browse'), null, () => widget.onOpenTable(name)));
      // Purge / Recreate / Delete live behind an overflow menu, endpoint mode only.
      if (canLifecycle) {
        children.add(_opsMenu(name, boundId));
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(width: 7),
        children[i],
      ]
    ]);
  }

  // Overflow menu with the destructive table ops (endpoint mode only). Purge and
  // Delete act on any table (they take the endpoint + table name); Recreate needs a
  // redimos-bound config to author the rebuilt schema, so it only appears when bound.
  Widget _opsMenu(String table, String? boundId) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      builder: (context, controller, child) => IconButton(
        icon: const Icon(Icons.more_vert, size: 20),
        tooltip: tr('ep.tableOperations'),
        visualDensity: VisualDensity.compact,
        onPressed: _busy
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.cleaning_services_outlined, size: 18),
          onPressed: _busy ? null : () => _lc.purge(context, table),
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
          onPressed: _busy ? null : () => _lc.delete(context, table),
          child: Text(tr('ep.deleteTable'), style: TextStyle(color: scheme.error)),
        ),
      ],
    );
  }

  Widget _actionBtn(String label, Color? color, VoidCallback? onTap) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          foregroundColor: color,
          side: color == null ? null : BorderSide(color: color),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );

  Widget _kindBadge(String kind) {
    final (Color c, String label) = switch (kind) {
      'v2' => (const Color(0xFF3B6EA5), 'redimos v2'),
      'v1' => (Colors.amber.shade700, 'redimos v1'),
      _ => (Theme.of(context).colorScheme.onSurfaceVariant, 'raw'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _usedByChip(Map u) {
    final running = u['running'] == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 7, color: running ? _green : Colors.grey),
        const SizedBox(width: 5),
        Text('${u['name']}', style: const TextStyle(fontSize: 10.5)),
      ]),
    );
  }

  Widget _statusDot(String status) {
    final color = switch (status.toUpperCase()) {
      'ACTIVE' => _green,
      'CREATING' || 'UPDATING' => Colors.amber,
      'DELETING' => Colors.orange,
      'MISSING' => Colors.grey,
      _ => Colors.grey,
    };
    return Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }

  String _keyLine(Map<String, dynamic> t) {
    final pk = t['pkName']?.toString() ?? '';
    final pt = t['pkType']?.toString() ?? '';
    final sk = t['skName']?.toString() ?? '';
    final stp = t['skType']?.toString() ?? '';
    final gsi = (t['gsiCount'] as num?)?.toInt() ?? 0;
    final lsi = (t['lsiCount'] as num?)?.toInt() ?? 0;
    final parts = <String>[];
    if (pk.isNotEmpty) parts.add('$pk${pt.isEmpty ? '' : ' ($pt)'}');
    if (sk.isNotEmpty) parts.add('$sk${stp.isEmpty ? '' : ' ($stp)'}');
    var s = parts.join(' · ');
    final idx = <String>[];
    if (lsi > 0) idx.add('$lsi LSI');
    if (gsi > 0) idx.add('$gsi GSI');
    if (idx.isNotEmpty) s = '$s · ${idx.join(' · ')}';
    return s;
  }

  String _countLine(int? items, int? size) {
    final parts = <String>[];
    if (items != null && items >= 0) parts.add(trp('ep.nItems', {'n': TableLifecycle.fmtInt(items)}));
    if (size != null && size > 0) parts.add(TableLifecycle.fmtBytes(size));
    return parts.join(' · ');
  }

  // ---- helpers ----

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
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          if (action != null) ...[const SizedBox(height: 16), action],
        ]),
      );
}
