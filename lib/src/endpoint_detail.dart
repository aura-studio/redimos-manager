// The right pane when an Endpoint (a DynamoDB backend, deduped across the
// instances that share it) is selected in the sidebar. Endpoints have no proxy,
// so instead of the instance's proxy-oriented tabs they get the storage views
// bound directly to the backend: Browser (the v1.2 R7 merge — a Tables sidebar
// + item Explorer in one two-pane view), PartiQL, and a DynamoDB Playground.
// On an AWS endpoint every view is read-only (the native layer re-guards writes
// regardless).
//
// Stage 15 (requirements 3.1–3.4): an endpoint is CLIENT-side storage access
// only. Even when its URL points at a Service's port, the engine's process
// state, metrics, and logs live on the Service entity — nothing here infers a
// binding from host/port text, and the tab set is fixed (Configure leads, per
// the restored v1 convention, then Overview / Browser / PartiQL / Playground).

import 'package:flutter/material.dart';

import 'endpoint_browser.dart';
import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'partiql_page.dart';
import 'playground_page.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_status.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

class EndpointDetailView extends StatefulWidget {
  final NativeCore core;
  final DdbEndpoint endpoint;
  // v2.3: the active screen index, driven by the HomePage-level MidBar tabs
  // (the per-view TabBar was lifted up so instance and endpoint chrome match).
  final int screenIndex;
  // R4.3: endpoint Edit entry (Overview header button), owned by HomePage.
  final VoidCallback? onEdit;
  // v1 configure-first: persists an edited identity tuple. Owned by HomePage,
  // which syncs every bound instance config via saveConfig (the endpoint is a
  // dedup view of those tuples, so the write goes through them).
  final Future<void> Function(DdbEndpoint saved)? onSaveEndpoint;
  // T12: HomePage's MidBar "＋ Item" CTA bridge into the Browser screen.
  final GlobalKey? browserKey;
  const EndpointDetailView(
      {super.key,
      required this.core,
      required this.endpoint,
      this.screenIndex = 0,
      this.onEdit,
      this.onSaveEndpoint,
      this.browserKey});

  @override
  State<EndpointDetailView> createState() => _EndpointDetailViewState();
}

class _EndpointDetailViewState extends State<EndpointDetailView> {
  DdbEndpoint get e => widget.endpoint;

  // Screen list (Configure / Overview / Browser / PartiQL / Playground), one
  // per MidBar tab. Index-matched with HomePage._epTabLabels.
  List<Widget> get _screens {
    final cfg = e.toStorageConfig();
    return [
      // Configure — the endpoint identity editor (leads, per v1 convention).
      EndpointConfigPane(
        key: ValueKey('ep-config-${e.id}'),
        endpoint: e,
        onSave: widget.onSaveEndpoint,
      ),
      // Overview — backend metadata + a live reachability probe.
      EndpointOverviewPane(
        key: ValueKey('ep-overview-${e.id}'),
        core: widget.core,
        endpoint: e,
        config: cfg,
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final screens = _screens;
    final i = widget.screenIndex.clamp(0, screens.length - 1);
    // Keep every screen's state alive (scroll position, probe results, editor
    // contents) across tab switches — an IndexedStack does that without the
    // TabBarView the chrome used to own.
    return IndexedStack(
      index: i,
      children: [
        for (var screenIndex = 0; screenIndex < screens.length; screenIndex++)
          ExcludeFocus(
            key: ValueKey('endpoint-screen-$screenIndex-focus'),
            excluding: screenIndex != i,
            child: screens[screenIndex],
          ),
      ],
    );
  }
}

// The endpoint Overview: backend metadata + a live reachability probe. An
// endpoint is storage access, not a process (3.3): even a URL that points at
// a Service's port shows this same client-side view — the engine's state,
// metrics, and logs live on the Service entity.
class EndpointOverviewPane extends StatefulWidget {
  final NativeCore core;
  final DdbEndpoint endpoint;
  final RedimosConfig config;
  // R4.3/R4.4: opens the endpoint Edit dialog (owned by HomePage, which knows
  // how to persist the change via saveConfig and sync sibling instances).
  final VoidCallback? onEdit;
  const EndpointOverviewPane(
      {super.key,
      required this.core,
      required this.endpoint,
      required this.config,
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
      key: const ValueKey('endpoint-overview-scroll'),
      // Mockup .ov-wrap: 18px 22px padding, 14px column gap.
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // v2.3: warning/note banners pinned to the TOP of the screen.
        if (_isAws)
          _noteBanner(Icons.lock_outline, tr('ep.ovReadOnlyNote'), t.warning),
        if (_isAws) const SizedBox(height: 10),
        // An endpoint is client-side storage access; any engine process
        // behind the URL is owned by a Service, never surfaced here (3.3).
        // Mockup .note-banner is always the amber warning tint.
        _noteBanner(
            Icons.info_outline, tr('ep.ovNoProcessNote'), t.warning),
        const SizedBox(height: 14),
        // Backend identity card (mockup .ov-card: head band + ruled kv rows).
        _card(
          t,
          key: const ValueKey('endpoint-overview-backend-card'),
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
            _kv(t, 'Items',
                '—'), // R5.x: item counts need a per-table scan — not polled.
            // Mockup renders Status as a dot + label in the value cell.
            _reachRow(t, 'Status', _reachStatusWidget(t)),
          ],
        ),
        const SizedBox(height: 14),
        // Reachability card: four rows (Status / Tables / Latency / Error) +
        // a Recheck button in the head band.
        _card(
          t,
          key: const ValueKey('endpoint-overview-reachability-card'),
          head: Row(children: [
            _cardTitle(t, tr('ep.ovReachability')),
            const Spacer(),
            _cardAction(t,
                label: tr('ep.ovRecheck'), onTap: _probing ? null : _probe),
          ]),
          rows: [
            _reachRow(t, tr('ep.ovReachability'), _reachStatusWidget(t)),
            _reachRow(
                t,
                tr('ep.ovTablesCount'),
                Text(_tableCount == null ? '—' : '$_tableCount',
                    style: Ts.style(
                        size: Ts.md,
                        weight: FontWeight.w600,
                        color: t.text,
                        monoFont: true,
                        tabularNums: true))),
            _reachRow(
                t,
                'Latency',
                Text(_latencyMs == null ? '—' : '$_latencyMs ms',
                    style: Ts.style(
                        size: Ts.md,
                        weight: FontWeight.w600,
                        color: t.text,
                        monoFont: true,
                        tabularNums: true))),
            if (_error != null)
              _reachRow(
                  t,
                  'Error',
                  SelectableText(_error!,
                      style: Ts.style(
                          size: Ts.md,
                          weight: FontWeight.w600,
                          color: t.danger,
                          monoFont: true,
                          tabularNums: true))),
          ],
        ),
      ]),
    );
  }

  // Last 4 chars of an access key, so a credential is identifiable without
  // exposing it (the AWS console shows the same tail).
  String _tail(String s) {
    final trimmed = s.trim();
    return trimmed.length <= 4
        ? trimmed
        : trimmed.substring(trimmed.length - 4);
  }

  Widget _reachStatusWidget(AppTokens t) {
    if (_probing) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox.square(
          dimension: 13,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: t.text3,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          tr('ep.ovChecking'),
          style: Ts.style(
            size: Ts.md,
            weight: FontWeight.w600,
            color: t.text3,
          ),
        ),
      ]);
    }
    final label = _reachable ? tr('ep.ovReachable') : tr('ep.ovUnreachable');
    return CodexStatusIndicator(
      status: _reachable ? CodexStatus.success : CodexStatus.error,
      label: label,
      semanticLabel: label,
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
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12, height: 1.35, fontWeight: FontWeight.w500)),
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
                    size: Ts.md,
                    weight: FontWeight.w600,
                    color: t.text,
                    monoFont: true,
                    tabularNums: true)),
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

  Widget _card(
    AppTokens t, {
    Key? key,
    required Widget head,
    required List<Widget> rows,
  }) =>
      CodexSurface(
        key: key,
        variant: CodexSurfaceVariant.elevated,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: t.panel2,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: head,
              ),
            ),
            const CodexDivider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: rows[i],
                    ),
                    if (i < rows.length - 1) const CodexDivider(),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  Widget _cardTitle(AppTokens t, String label) => Text(
        label.toUpperCase(),
        style: Ts.style(
          size: Ts.xs,
          letterSpacing: 0.9,
          weight: FontWeight.w700,
          color: t.text3,
        ),
      );

  Widget _cardAction(
    AppTokens t, {
    required String label,
    VoidCallback? onTap,
  }) =>
      CodexButton(
        variant: CodexButtonVariant.secondary,
        semanticLabel: label,
        onPressed: onTap,
        label: Text(
          label,
          style: Ts.style(
            size: Ts.md,
            weight: FontWeight.w500,
            color: onTap == null ? t.text3 : t.text2,
          ),
        ),
      );
}

// The endpoint Configure screen (v1 convention: Configure leads the tab row).
// R4.3/R4.4 lifted into a pane: edit the identity tuple (name / endpoint /
// region), then persist through HomePage's onSaveEndpoint, which syncs every
// bound instance config via saveConfig - the endpoint itself is a dedup view
// of those tuples, so the write goes through them.
class EndpointConfigPane extends StatefulWidget {
  final DdbEndpoint endpoint;
  final Future<void> Function(DdbEndpoint saved)? onSave;
  const EndpointConfigPane({super.key, required this.endpoint, this.onSave});

  @override
  State<EndpointConfigPane> createState() => _EndpointConfigPaneState();
}

class _EndpointConfigPaneState extends State<EndpointConfigPane>
    with AutomaticKeepAliveClientMixin {
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _region;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.endpoint.name);
    _endpoint = TextEditingController(text: widget.endpoint.endpoint);
    _region = TextEditingController(text: widget.endpoint.region);
  }

  @override
  void didUpdateWidget(EndpointConfigPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-seed only when the endpoint itself changes; poll-driven rebuilds
    // must not clobber in-progress edits (mirrors ServiceConfigEditor 13.2).
    if (oldWidget.endpoint.id != widget.endpoint.id) _reseed();
  }

  void _reseed() {
    final e = widget.endpoint;
    _name.text = e.name;
    _endpoint.text = e.endpoint;
    _region.text = e.region;
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _region.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final e = widget.endpoint;
    final saved = DdbEndpoint(
      id: e.id,
      name: _name.text.trim(),
      kind: e.kind,
      endpoint: _endpoint.text.trim(),
      partitionID: e.partitionID,
      region: _region.text.trim(),
      accessKeyId: e.accessKeyId,
      secretKey: e.secretKey,
      sessionToken: e.sessionToken,
      source: e.source,
    );
    setState(() => _busy = true);
    try {
      await widget.onSave?.call(saved);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppTokens.of(context);
    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          key: const ValueKey('ep-config-scroll'),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _section(t, tr('ep.cfgSection'), [
                  _field(t, _name, tr('ep.cfgName'),
                      key: const ValueKey('ep-config-name')),
                  _field(t, _endpoint, tr('ep.ovEndpoint'),
                      key: const ValueKey('ep-config-endpoint')),
                  _field(t, _region, tr('ep.ovRegion'),
                      key: const ValueKey('ep-config-region')),
                ]),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline, size: 14, color: t.text3),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      tr('ep.cfgSyncNote'),
                      key: const ValueKey('ep-config-sync-note'),
                      style: Ts.style(size: Ts.sm, color: t.text3),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
              ]),
        ),
      ),
      _actionBar(t),
    ]);
  }

  // Same house grammar as ServiceConfigEditor: numbered-less section card
  // (head band + ruled body), fields stacked single-column.
  Widget _section(AppTokens t, String title, List<Widget> fields) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: CodexSurface(
        key: ValueKey('ep-config-section-${title.hashCode}'),
        variant: CodexSurfaceVariant.elevated,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: t.panel2,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text(
                  title.toUpperCase(),
                  style: Ts.style(
                    size: Ts.md,
                    letterSpacing: 0.9,
                    weight: FontWeight.w700,
                    color: t.text,
                  ),
                ),
              ),
            ),
            const CodexDivider(),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < fields.length; i++) ...[
                    fields[i],
                    if (i < fields.length - 1) const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(AppTokens t, TextEditingController c, String label, {Key? key}) {
    return Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: Ts.style(
                  size: Ts.xs,
                  weight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: t.text3,
                  height: 14 / 11)),
          const SizedBox(height: 5),
          CodexTextField(
            key: key == null ? null : ValueKey('${(key as ValueKey).value}-input'),
            controller: c,
            height: Dim.ctlH,
            style: Ts.style(size: Ts.md, color: t.text, monoFont: true),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
        ]);
  }

  Widget _actionBar(AppTokens t) {
    return Container(
      key: const ValueKey('ep-config-action-bar'),
      height: 52,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(top: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Row(children: [
        const Spacer(),
        CodexButton(
          key: const ValueKey('ep-config-revert'),
          variant: CodexButtonVariant.secondary,
          semanticLabel: tr('home.revert'),
          onPressed: _busy ? null : _reseed,
          icon: const Icon(Icons.restore, size: 15),
          label: Text(tr('home.revert')),
        ),
        const SizedBox(width: 8),
        CodexButton(
          key: const ValueKey('ep-config-save'),
          variant: CodexButtonVariant.primary,
          semanticLabel: tr('home.save'),
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.save_outlined, size: 15),
          label: Text(tr('home.save')),
        ),
      ]),
    );
  }
}
