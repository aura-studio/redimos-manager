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
  late final TabController _tabs = TabController(length: 4, vsync: this);

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
