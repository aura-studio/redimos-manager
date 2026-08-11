// The right pane when an Endpoint (a DynamoDB backend, deduped across the
// instances that share it) is selected in the sidebar. Endpoints have no proxy,
// so instead of the instance's proxy-oriented tabs they get the storage views
// bound directly to the backend: Browser (the v1.2 R7 merge — a Tables sidebar
// + item Explorer in one two-pane view), PartiQL, and a DynamoDB Playground.
// On an AWS endpoint every view is read-only (the native layer re-guards writes
// regardless).
//
// One exception to "an endpoint has no process": the kind=local endpoint that
// IS the managed Local DynamoDB engine. Since the 2026-08-05 separation
// (separate-monitor-logs) the engine's Monitor and Logs live HERE — as two
// extra tabs (DdbMonitorView / DdbLogsView, ddb_views.dart) — instead of mixed
// into whichever instance page happens to proxy it. `ddb != null` is what
// switches the tab set 4 ↔ 6.

import 'package:flutter/material.dart';

import 'ddb_views.dart';
import 'endpoint_browser.dart';
import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'partiql_page.dart';
import 'playground_page.dart';
import 'ui_tokens.dart';

class EndpointDetailView extends StatefulWidget {
  final NativeCore core;
  final DdbEndpoint endpoint;
  // Non-null iff this endpoint is bound to the managed Local DynamoDB engine
  // (kind=local + host:port match, decided by HomePage._ddbForEndpoint). When
  // set, the tab set gains Monitor + Logs hosting the engine's own telemetry.
  // The snapshot PERSISTS across engine stop/start (HomePage keeps the last
  // non-null rm_ddb_get result), so the tab count never flaps with lifecycle.
  final LocalDdbInfo? ddb;
  final List<double> ddbCpuHist;
  final List<double> ddbMemHist;
  final List<double> ddbDiskHist;
  // v2.3: the active screen index, driven by the HomePage-level MidBar tabs
  // (the per-view TabBar was lifted up so instance and endpoint chrome match).
  final int screenIndex;
  // R4.3: endpoint Edit entry (Overview header button), owned by HomePage.
  final VoidCallback? onEdit;
  // T12: HomePage's MidBar "＋ Item" CTA bridge into the Browser screen.
  final GlobalKey? browserKey;
  const EndpointDetailView(
      {super.key,
      required this.core,
      required this.endpoint,
      this.ddb,
      this.ddbCpuHist = const [],
      this.ddbMemHist = const [],
      this.ddbDiskHist = const [],
      this.screenIndex = 0,
      this.onEdit,
      this.browserKey});

  @override
  State<EndpointDetailView> createState() => _EndpointDetailViewState();
}

class _EndpointDetailViewState extends State<EndpointDetailView> {
  bool get _showDdb => widget.ddb != null;

  DdbEndpoint get e => widget.endpoint;

  // Screen list (Overview / Browser / PartiQL / Playground [+ Monitor + Logs]),
  // one per MidBar tab. Index-matched with HomePage._endpointTabLabels.
  List<Widget> get _screens {
    final cfg = e.toStorageConfig();
    return [
      // Overview — backend metadata + a live reachability probe.
      EndpointOverviewPane(
        key: ValueKey('ep-overview-${e.id}'),
        core: widget.core,
        endpoint: e,
        config: cfg,
        managedEngine: _showDdb,
        onEdit: widget.onEdit,
      ),
      // Browser — the Tables list + item Explorer in one two-pane view.
      EndpointBrowserView(
        key: widget.browserKey ?? ValueKey('ep-browser-${e.id}'),
        core: widget.core,
        config: cfg,
        endpoint: e,
      ),
      // PartiQL — statement editor bound to the endpoint
      PartiqlPageView(
        key: ValueKey('ep-partiql-${e.id}'),
        core: widget.core,
        config: cfg,
      ),
      // Playground — JS/Go against the endpoint's DynamoDB
      PlaygroundView(
        key: ValueKey('ep-playground-${e.id}'),
        core: widget.core,
        config: cfg,
        kind: 'ddb',
      ),
      if (_showDdb) ...[
        // Monitor — the managed Local DynamoDB engine's own dashboard.
        DdbMonitorView(
          key: ValueKey('ep-ddbmon-${e.id}'),
          ddb: widget.ddb,
          cpuHist: widget.ddbCpuHist,
          memHist: widget.ddbMemHist,
          diskHist: widget.ddbDiskHist,
        ),
        // Logs — the engine's live log tail (rm_ddb_logs)
        DdbLogsView(
          key: ValueKey('ep-ddblog-${e.id}'),
          core: widget.core,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final screens = _screens;
    final i = widget.screenIndex.clamp(0, screens.length - 1);
    // Keep every screen's state alive (scroll position, probe results, editor
    // contents) across tab switches — an IndexedStack does that without the
    // TabBarView the chrome used to own.
    return IndexedStack(index: i, children: screens);
  }
}

// The endpoint Overview: backend metadata + a live reachability probe. An
// endpoint is normally storage, not a process, so this stands in for the
// instance's Monitor/Logs tabs with something meaningful for a backend (is it
// reachable, how many tables, how fast). The one backend that IS a managed
// process — the Local DynamoDB engine — gets its Monitor/Logs as real tabs on
// this page (managedEngine: true), and its note banner says so instead.
class EndpointOverviewPane extends StatefulWidget {
  final NativeCore core;
  final DdbEndpoint endpoint;
  final RedimosConfig config;
  // True iff this endpoint is bound to the managed Local DynamoDB engine.
  final bool managedEngine;
  // R4.3/R4.4: opens the endpoint Edit dialog (owned by HomePage, which knows
  // how to persist the change via saveConfig and sync sibling instances).
  final VoidCallback? onEdit;
  const EndpointOverviewPane(
      {super.key,
      required this.core,
      required this.endpoint,
      required this.config,
      this.managedEngine = false,
      this.onEdit});

  @override
  State<EndpointOverviewPane> createState() => _EndpointOverviewPaneState();
}

class _EndpointOverviewPaneState extends State<EndpointOverviewPane>
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

  // Mirror of the native `awsModeForEndpoint`: empty endpoint (default AWS
  // resolver) OR an amazonaws.com host. `kind == 'aws'` alone would miss an
  // explicit AWS URL — the native endpointKind only returns 'aws' for the
  // empty endpoint, classifying a URL as 'url' — and then the read-only note
  // would silently disappear for that endpoint.
  bool get _isAws {
    final ep = widget.endpoint.endpoint.trim();
    if (ep.isEmpty) return true;
    final host = (Uri.tryParse(ep)?.host ?? '').toLowerCase();
    return host == 'amazonaws.com' ||
        host.endsWith('.amazonaws.com') ||
        host.endsWith('.amazonaws.com.cn');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final e = widget.endpoint;
    final t = AppTokens.of(context);
    return SingleChildScrollView(
      // Mockup .ov-wrap: 18px 22px padding, 14px column gap.
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // v2.3: warning/note banners pinned to the TOP of the screen.
        if (_isAws) _noteBanner(Icons.lock_outline, tr('ep.ovReadOnlyNote'), t.warning),
        if (_isAws) const SizedBox(height: 10),
        // Honesty guard: "an endpoint is storage, not a managed process" is
        // false for the engine-bound endpoint — its process Monitor/Logs live
        // in this very page's tabs since the 2026-08-05 separation. Mockup
        // .note-banner is always the amber warning tint.
        _noteBanner(
            widget.managedEngine ? Icons.dns : Icons.info_outline,
            widget.managedEngine
                ? tr('ep.ovLocalEngineNote')
                : tr('ep.ovNoProcessNote'),
            t.warning),
        const SizedBox(height: 14),
        // Backend identity card (mockup .ov-card: head band + ruled kv rows).
        _card(t,
          head: Row(children: [
            _cardTitle(t, tr('ep.ovBackend')),
            const Spacer(),
            if (widget.onEdit != null)
              _cardAction(t, label: 'Edit', onTap: widget.onEdit),
          ]),
          rows: [
            _kv(t, 'Name', e.name.isEmpty ? '—' : e.name),
            _kv(t, 'Type', _backendLabel()),
            _kv(t, tr('ep.ovEndpoint'),
                e.endpoint.trim().isEmpty ? tr('ep.ovAwsDefault') : e.endpoint),
            if (e.region.trim().isNotEmpty) _kv(t, tr('ep.ovRegion'), e.region),
            if (e.accessKeyId.trim().isNotEmpty)
              _kv(t, 'Credential', 'AK •••${_tail(e.accessKeyId)}'),
            _kv(t, 'Tables', _tableCount == null ? '—' : '$_tableCount'),
            _kv(t, 'Items', '—'), // R5.x: item counts need a per-table scan — not polled.
            // Mockup renders Status as a dot + label in the value cell.
            _reachRow(t, 'Status', _reachStatusWidget(t)),
          ],
        ),
        const SizedBox(height: 14),
        // Reachability card: four rows (Status / Tables / Latency / Error) +
        // a Recheck button in the head band.
        _card(t,
          head: Row(children: [
            _cardTitle(t, tr('ep.ovReachability')),
            const Spacer(),
            _cardAction(t, label: tr('ep.ovRecheck'), onTap: _probing ? null : _probe),
          ]),
          rows: [
            _reachRow(t, tr('ep.ovReachability'), _reachStatusWidget(t)),
            _reachRow(t, tr('ep.ovTablesCount'),
                Text(_tableCount == null ? '—' : '$_tableCount',
                    style: Ts.style(
                        size: Ts.md, weight: FontWeight.w600, color: t.text,
                        monoFont: true, tabularNums: true))),
            _reachRow(t, 'Latency',
                Text(_latencyMs == null ? '—' : '$_latencyMs ms',
                    style: Ts.style(
                        size: Ts.md, weight: FontWeight.w600, color: t.text,
                        monoFont: true, tabularNums: true))),
            if (_error != null)
              _reachRow(t, 'Error',
                  SelectableText(_error!,
                      style: Ts.style(size: Ts.md, weight: FontWeight.w600, color: t.danger,
                          monoFont: true, tabularNums: true))),
          ],
        ),
      ]),
    );
  }

  // Last 4 chars of an access key, so a credential is identifiable without
  // exposing it (the AWS console shows the same tail).
  String _tail(String s) {
    final trimmed = s.trim();
    return trimmed.length <= 4 ? trimmed : trimmed.substring(trimmed.length - 4);
  }

  Widget _reachStatusWidget(AppTokens t) {
    if (_probing) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: t.text3)),
        const SizedBox(width: 8),
        Text(tr('ep.ovChecking'), style: Ts.style(size: Ts.md, weight: FontWeight.w600, color: t.text3)),
      ]);
    }
    final color = _reachable ? t.success : t.danger;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 7),
      Text(_reachable ? tr('ep.ovReachable') : tr('ep.ovUnreachable'),
          style: Ts.style(size: Ts.md, weight: FontWeight.w600, color: color)),
    ]);
  }

  String _backendLabel() {
    final e = widget.endpoint;
    return switch (e.kind) {
      'aws' => e.region.isEmpty ? 'AWS' : 'AWS · ${e.region}',
      'local' => 'Local DynamoDB',
      _ => 'DynamoDB-compatible',
    };
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
            // Mockup .note-banner body weight 500.
            child: Text(text, style: const TextStyle(fontSize: 12, height: 1.35, fontWeight: FontWeight.w500)),
          ),
        ]),
      );

  // Mockup .kv-row: 150px recessed key column, 600 mono tabular value; the
  // hairline rule between rows comes from the card body builder, not here.
  Widget _kv(AppTokens t, String k, String v) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(k, style: Ts.style(size: Ts.md, color: t.text3)),
          ),
          Expanded(
            child: SelectableText(v,
                style: Ts.style(
                    size: Ts.md, weight: FontWeight.w600, color: t.text, monoFont: true, tabularNums: true)),
          ),
        ],
      );

  // A reachability detail row (label left, live value widget right). Same
  // 150px key column as _kv so both cards' rows align.
  Widget _reachRow(AppTokens t, String k, Widget v) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 150,
            child: Text(k, style: Ts.style(size: Ts.md, color: t.text3)),
          ),
          Expanded(child: v),
        ],
      );

  // Mockup .ov-card: border + radius + elev-2 + top highlight, with a two-tone
  // header band (panel-2 bg + hairline bottom border) capping the card. Rows
  // are separated by hairline rules (mockup .kv-row border-bottom).
  Widget _card(AppTokens t, {required Widget head, required List<Widget> rows}) {
    final brightness = Theme.of(context).brightness;
    return Stack(children: [
      Container(
        decoration: BoxDecoration(
          color: t.panel,
          borderRadius: BorderRadius.circular(Dim.radiusM),
          border: Border.all(color: t.border),
          boxShadow: Depth.elev2(brightness),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Dim.radiusM - 1),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Header band (panel-2 + hairline bottom border).
            Container(
              decoration: BoxDecoration(
                color: t.panel2,
                border: Border(bottom: BorderSide(color: t.hairline)),
              ),
              // Mockup .ov-head band: 10px vertical padding.
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: head,
            ),
            // Ruled kv body (mockup .kv-row: 9px 14px padding, hairline between).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < rows.length; i++) ...[
                  Padding(padding: const EdgeInsets.symmetric(vertical: 9), child: rows[i]),
                  if (i < rows.length - 1) Divider(height: 1, color: t.hairline),
                ],
              ]),
            ),
          ]),
        ),
      ),
      // 1px top inner highlight.
      Positioned(
        left: 1, right: 1, top: 0,
        child: IgnorePointer(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              color: t.highlight,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(Dim.radiusM - 1)),
            ),
          ),
        ),
      ),
    ]);
  }

  // Mockup .ov-head title: 11/700 uppercase, .9px tracking, text-3.
  Widget _cardTitle(AppTokens t, String label) => Text(label.toUpperCase(),
      style: Ts.style(size: Ts.xs, letterSpacing: 0.9, weight: FontWeight.w700, color: t.text3));

  // Mockup .ov-head .abtn: a 26px bordered box with 12/500 text-2 label — no
  // icon in the HTML render, unlike the old accent icon+text affordance.
  Widget _cardAction(AppTokens t, {required String label, VoidCallback? onTap}) {
    final enabled = onTap != null;
    final color = enabled ? t.text2 : t.text3;
    return InkWell(
      borderRadius: BorderRadius.circular(Dim.radiusS),
      onTap: onTap,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: t.panel,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(Dim.radiusS),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: Ts.style(size: Ts.md, weight: FontWeight.w500, color: color)),
      ),
    );
  }
}
