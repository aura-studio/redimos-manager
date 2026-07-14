// The right pane when an Endpoint (a DynamoDB backend, deduped across the
// instances that share it) is selected in the sidebar. Endpoints have no proxy,
// so instead of the instance's proxy-oriented tabs they get the storage views
// bound directly to the backend: Tables (the endpoint's table list + lifecycle),
// Explorer (item browser), PartiQL, and a DynamoDB Playground. Browsing a table
// from the Tables list jumps to the Explorer focused on it. On an AWS endpoint
// every view is read-only (the native layer re-guards writes regardless).

import 'package:flutter/material.dart';

import 'endpoint_page.dart';
import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'partiql_page.dart';
import 'playground_page.dart';
import 'table_page.dart';

class EndpointDetailView extends StatefulWidget {
  final NativeCore core;
  final DdbEndpoint endpoint;
  const EndpointDetailView({super.key, required this.core, required this.endpoint});

  @override
  State<EndpointDetailView> createState() => _EndpointDetailViewState();
}

class _EndpointDetailViewState extends State<EndpointDetailView>
    with TickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);

  // Explorer target when the user Browses a table from the Tables list.
  String? _browseTable;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  DdbEndpoint get e => widget.endpoint;

  String _hostOf(String url) {
    final u = url.replaceFirst(RegExp(r'^https?://'), '');
    final slash = u.indexOf('/');
    return slash < 0 ? u : u.substring(0, slash);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = e.toStorageConfig();
    final kindLabel = switch (e.kind) {
      'aws' => e.region.isEmpty ? 'AWS' : 'AWS · ${e.region}',
      'local' => 'Local DynamoDB · ${_hostOf(e.endpoint)}',
      _ => e.endpoint,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 50,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Icon(Icons.dns_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: 9),
            Text(e.name.isEmpty ? tr('config.unnamed') : e.name,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            Text(kindLabel,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color)),
          ]),
        ),
      ),
      const Divider(height: 1),
      SizedBox(
        height: 50,
        child: TabBar(
          controller: _tabs,
          labelColor: scheme.primary,
          unselectedLabelColor: Theme.of(context).textTheme.bodySmall?.color,
          indicatorColor: scheme.primary,
          indicatorWeight: 2.5,
          dividerColor: Colors.transparent,
          tabs: [
            _tab(Icons.dashboard_outlined, tr('tab.overview')),
            _tab(Icons.folder_open, tr('tab.endpoint')),
            _tab(Icons.table_chart, tr('tab.table')),
            _tab(Icons.code, tr('tab.partiql')),
            _tab(Icons.science_outlined, tr('tab.playground')),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: TabBarView(
          controller: _tabs,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            // Overview — backend metadata + a live reachability probe (an endpoint
            // has no managed process, so this stands in for Monitor/Logs)
            _EndpointOverview(
              key: ValueKey('ep-overview-${e.id}'),
              core: widget.core,
              endpoint: e,
              config: cfg,
            ),
            // Tables — the endpoint's table list + lifecycle (recreate/purge/…)
            EndpointPageView(
              key: ValueKey('ep-tables-${e.id}'),
              core: widget.core,
              config: cfg,
              running: true, // storage views connect to DynamoDB directly
              onOpenTable: (name) {
                setState(() => _browseTable = name == cfg.table ? null : name);
                _tabs.animateTo(1);
              },
            ),
            // Explorer — DynamoDB item browser, optionally focused on a browsed table
            TablePageView(
              key: ValueKey('ep-explore-${e.id}'),
              core: widget.core,
              config: cfg,
              running: true,
              tableOverride: _browseTable,
              onExitBrowse: () => setState(() => _browseTable = null),
            ),
            // PartiQL — statement editor bound to the endpoint
            PartiqlPageView(
              key: ValueKey('ep-partiql-${e.id}'),
              core: widget.core,
              config: cfg,
              running: true,
              allowNoTable: true,
            ),
            // Playground — JS/Go against the endpoint's DynamoDB
            PlaygroundView(
              key: ValueKey('ep-playground-${e.id}'),
              core: widget.core,
              config: cfg,
              kind: 'ddb',
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _tab(IconData icon, String label) => Tab(
        height: 40,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16),
          const SizedBox(width: 7),
          Text(label),
        ]),
      );
}

// The endpoint Overview: backend metadata + a live reachability probe. An
// endpoint is storage, not a process, so this replaces the instance's
// Monitor/Logs tabs with something meaningful for a backend (is it reachable,
// how many tables, how fast).
class _EndpointOverview extends StatefulWidget {
  final NativeCore core;
  final DdbEndpoint endpoint;
  final RedimosConfig config;
  const _EndpointOverview(
      {super.key, required this.core, required this.endpoint, required this.config});

  @override
  State<_EndpointOverview> createState() => _EndpointOverviewState();
}

class _EndpointOverviewState extends State<_EndpointOverview>
    with AutomaticKeepAliveClientMixin {
  bool _probing = true;
  bool _reachable = false;
  int? _tableCount;
  int? _latencyMs;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    setState(() {
      _probing = true;
      _error = null;
    });
    final start = DateTime.now();
    final r = await widget.core.epListTables(widget.config);
    if (!mounted) return;
    final ms = DateTime.now().difference(start).inMilliseconds;
    setState(() {
      _probing = false;
      _latencyMs = ms;
      if (r['ok'] == true) {
        _reachable = true;
        _tableCount = ((r['tables'] as List?) ?? const []).length;
        _error = null;
      } else {
        _reachable = false;
        _tableCount = null;
        _error = r['error']?.toString() ?? 'unreachable';
      }
    });
  }

  bool get _isAws => widget.endpoint.kind == 'aws';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final e = widget.endpoint;
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _kv(tr('ep.ovBackend'), _backendLabel()),
            const SizedBox(height: 10),
            _kv(tr('ep.ovEndpoint'),
                e.endpoint.trim().isEmpty ? tr('ep.ovAwsDefault') : e.endpoint),
            if (e.region.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              _kv(tr('ep.ovRegion'), e.region),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        _card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(tr('ep.ovReachability'),
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton.icon(
                onPressed: _probing ? null : _probe,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(tr('ep.ovRecheck')),
              ),
            ]),
            const SizedBox(height: 8),
            _reachabilityRow(scheme),
            if (_error != null) ...[
              const SizedBox(height: 8),
              SelectableText(_error!,
                  style: TextStyle(fontSize: 12, color: scheme.error)),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        if (_isAws) _noteBanner(Icons.lock_outline, tr('ep.ovReadOnlyNote'), scheme.tertiary),
        if (_isAws) const SizedBox(height: 10),
        _noteBanner(Icons.info_outline, tr('ep.ovNoProcessNote'), scheme.outline),
      ]),
    );
  }

  String _backendLabel() {
    final e = widget.endpoint;
    return switch (e.kind) {
      'aws' => e.region.isEmpty ? 'AWS' : 'AWS · ${e.region}',
      'local' => 'Local DynamoDB',
      _ => 'DynamoDB-compatible',
    };
  }

  Widget _reachabilityRow(ColorScheme scheme) {
    if (_probing) {
      return Row(children: [
        const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text(tr('ep.ovChecking')),
      ]);
    }
    const okColor = Color(0xFF2E7D32);
    final color = _reachable ? okColor : scheme.error;
    final parts = <String>[];
    if (_reachable && _tableCount != null) {
      parts.add('$_tableCount ${tr('ep.ovTablesCount')}');
    }
    if (_latencyMs != null) parts.add('${_latencyMs}ms');
    return Row(children: [
      Icon(_reachable ? Icons.check_circle : Icons.cancel, size: 18, color: color),
      const SizedBox(width: 6),
      Text(_reachable ? tr('ep.ovReachable') : tr('ep.ovUnreachable'),
          style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      if (parts.isNotEmpty) ...[
        const SizedBox(width: 8),
        Text('·  ${parts.join('  ·  ')}',
            style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
      ],
    ]);
  }

  Widget _noteBanner(IconData icon, String text, Color color) => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 12, height: 1.35)),
          ),
        ]),
      );

  Widget _kv(String k, String v) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(k,
                style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(v,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ),
        ],
      );

  Widget _card({required Widget child}) => Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(padding: const EdgeInsets.all(12), child: child),
      );
}
