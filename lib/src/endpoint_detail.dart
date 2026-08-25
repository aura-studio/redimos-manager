// The right pane when an Endpoint (a DynamoDB backend, deduped across the
// instances that share it) is selected in the sidebar. Three screens, v1
// convention restored: Configure leads (a two-mode identity editor — local
// Endpoint URL vs online AWS credentials), then the storage views split the
// way v1 had them: the Endpoint page (every table on the backend) and the
// Table page (item browser/editor for the selected table). On an AWS
// endpoint the Table view is read-only (the native layer re-guards writes
// regardless).
//
// Stage 15 (requirements 3.1–3.4): an endpoint is CLIENT-side storage access
// only. Even when its URL points at a Service's port, the engine's process
// state, metrics, and logs live on the Service entity — nothing here infers
// a binding from host/port text.

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'table_page.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

class EndpointDetailView extends StatefulWidget {
  final NativeCore core;
  final DdbEndpoint endpoint;
  // v2.3: the active screen index, driven by the HomePage-level MidBar tabs
  // (the per-view TabBar was lifted up so instance and endpoint chrome match).
  final int screenIndex;
  // v1 configure-first: persists an edited identity tuple. Owned by HomePage,
  // which syncs every bound instance config via saveConfig (the endpoint is a
  // dedup view of those tuples, so the write goes through them).
  final Future<void> Function(DdbEndpoint saved)? onSaveEndpoint;
  // Deletes every instance config bound to this endpoint's tuple (the core
  // stops each running instance first). Owned by HomePage.
  final Future<void> Function()? onDeleteEndpoint;
  // The Endpoint page's row tap bridges into the Table page: HomePage owns
  // both the screen index and the selected-table state (v1 _browseTable).
  final String? selectedTable;
  final void Function(String table)? onOpenTable;
  const EndpointDetailView(
      {super.key,
      required this.core,
      required this.endpoint,
      this.screenIndex = 0,
      this.onSaveEndpoint,
      this.onDeleteEndpoint,
      this.selectedTable,
      this.onOpenTable});

  @override
  State<EndpointDetailView> createState() => _EndpointDetailViewState();
}

class _EndpointDetailViewState extends State<EndpointDetailView> {
  DdbEndpoint get e => widget.endpoint;

  // Screen list (Configure / Table), one per MidBar tab. The endpoint's table
  // list moved into the Table screen's sidebar, so the old Endpoint tab is
  // gone. Index-matched with HomePage._epTabLabels.
  List<Widget> get _screens {
    final cfg = e.toStorageConfig();
    return [
      // Configure — the endpoint identity editor (leads, per v1 convention).
      EndpointConfigPane(
        key: ValueKey('ep-config-${e.id}'),
        endpoint: e,
        core: widget.core,
        onSave: widget.onSaveEndpoint,
        onDelete: widget.onDeleteEndpoint,
      ),
      // Table — the item browser/editor; its sidebar lists every table on the
      // endpoint and row taps bridge through onOpenTable.
      TablePageView(
        key: ValueKey('ep-table-${e.id}'),
        core: widget.core,
        config: cfg,
        tableOverride: widget.selectedTable,
        endpointMode: true,
        allowOverrideWrites: e.kind != 'aws',
        onOpenTable: widget.onOpenTable,
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
    return SizedBox.expand(
      child: IndexedStack(
        index: i,
        children: [
          for (var screenIndex = 0; screenIndex < screens.length; screenIndex++)
            ExcludeFocus(
              key: ValueKey('endpoint-screen-$screenIndex-focus'),
              excluding: screenIndex != i,
              child: screens[screenIndex],
            ),
        ],
      ),
    );
  }
}

class EndpointConfigPane extends StatefulWidget {
  final DdbEndpoint endpoint;
  // Enables the Connection section's Test-connection probe; absent in the
  // standalone config-pane tests.
  final NativeCore? core;
  final Future<void> Function(DdbEndpoint saved)? onSave;
  final Future<void> Function()? onDelete;
  const EndpointConfigPane(
      {super.key,
      required this.endpoint,
      this.core,
      this.onSave,
      this.onDelete});

  @override
  State<EndpointConfigPane> createState() => _EndpointConfigPaneState();
}

// The Configure pane edits the endpoint's identity tuple. Two modes behind a
// segment control (v1.2 redesign): Endpoint mode points at a local URL; AWS
// mode carries Region/AccessKeyId/SecretKey/SessionToken. Saving one mode
// blanks the other half of the tuple so the bound instance configs flip
// cleanly between a local backend and real AWS.
enum _EpMode { endpoint, aws }

_EpMode _modeFor(DdbEndpoint e) => e.kind == 'aws' || e.accessKeyId.isNotEmpty
    ? _EpMode.aws
    : _EpMode.endpoint;

class _EndpointConfigPaneState extends State<EndpointConfigPane>
    with AutomaticKeepAliveClientMixin {
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _region;
  late final TextEditingController _ak;
  late final TextEditingController _sk;
  late final TextEditingController _token;
  late _EpMode _mode;
  bool _busy = false;
  bool _testing = false;
  bool? _testOk;
  String? _testMsg;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final e = widget.endpoint;
    _name = TextEditingController(text: e.name);
    _endpoint = TextEditingController(text: e.endpoint);
    _region = TextEditingController(text: e.region);
    _ak = TextEditingController(text: e.accessKeyId);
    _sk = TextEditingController(text: e.secretKey);
    _token = TextEditingController(text: e.sessionToken);
    _mode = _modeFor(e);
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
    _ak.text = e.accessKeyId;
    _sk.text = e.secretKey;
    _token.text = e.sessionToken;
    _mode = _modeFor(e);
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _region.dispose();
    _ak.dispose();
    _sk.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final e = widget.endpoint;
    final isAws = _mode == _EpMode.aws;
    final saved = DdbEndpoint(
      id: e.id,
      name: _name.text.trim(),
      // Endpoint mode must shed a stale 'aws' kind or the Table view stays
      // read-only against the now-local backend.
      kind: isAws ? 'aws' : (e.kind == 'aws' ? 'url' : e.kind),
      endpoint: isAws ? '' : _endpoint.text.trim(),
      partitionID: e.partitionID,
      region: isAws ? _region.text.trim() : '',
      accessKeyId: isAws ? _ak.text.trim() : '',
      secretKey: isAws ? _sk.text.trim() : '',
      sessionToken: isAws ? _token.text.trim() : '',
      source: e.source,
    );
    setState(() => _busy = true);
    try {
      await widget.onSave?.call(saved);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Single destructive confirmation, then HomePage deletes every bound
  // instance config (the endpoint itself is a dedup view and vanishes with
  // them). No data-cleanup tier — instance configs own no managed data.
  Future<void> _confirmDelete() async {
    final e = widget.endpoint;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('ep-delete-dialog'),
        title: Text(tr('ep.deleteTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${tr('ep.cfgName')}: ${e.name}'),
            Text('${tr('ep.ovEndpoint')}: ${e.endpoint}'),
            const SizedBox(height: 12),
            Text(tr('ep.deleteBody')),
          ],
        ),
        actions: [
          CodexButton(
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('home.cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            label: Text(tr('home.cancel')),
          ),
          CodexButton(
            key: const ValueKey('ep-delete-confirm'),
            variant: CodexButtonVariant.danger,
            semanticLabel: tr('home.delete'),
            onPressed: () => Navigator.pop(ctx, true),
            label: Text(tr('home.delete')),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.onDelete?.call();
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
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _section(t, '1', tr('ep.cfgSection'), [
              _field(t, _name, tr('ep.cfgName'),
                  key: const ValueKey('ep-config-name')),
            ]),
            _section(
                t,
                '2',
                tr('ep.connSection'),
                [
                  if (_mode == _EpMode.endpoint)
                    _field(t, _endpoint, tr('ep.ovEndpoint'),
                        key: const ValueKey('ep-config-endpoint')),
                  if (_mode == _EpMode.aws) ...[
                    _field(t, _region, tr('ep.ovRegion'),
                        key: const ValueKey('ep-config-region')),
                    _field(t, _ak, tr('home.accessKeyId'),
                        key: const ValueKey('ep-config-ak')),
                    _field(t, _sk, tr('home.secretAccessKey'),
                        key: const ValueKey('ep-config-sk')),
                    _field(t, _token, tr('home.sessionToken'),
                        key: const ValueKey('ep-config-token')),
                  ],
                ],
                lead: _connectionLead(t)),
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

  // Local-URL vs online-AWS switch; the save button commits whichever mode
  // is showing and blanks the other half of the tuple.
  Widget _modeSeg() {
    return Align(
      key: const ValueKey('ep-config-mode'),
      alignment: Alignment.centerLeft,
      child: SegmentedButton<_EpMode>(
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: [
          ButtonSegment(
              value: _EpMode.endpoint,
              label: Text(tr('ep.modeEndpoint')),
              icon: const Icon(Icons.link, size: 14)),
          ButtonSegment(
              value: _EpMode.aws,
              label: Text(tr('ep.modeAws')),
              icon: const Icon(Icons.cloud_outlined, size: 14)),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => setState(() => _mode = s.first),
      ),
    );
  }

  // The identity tuple as currently typed (unsaved) — the same shape _save
  // persists, reused to probe the backend without writing anything.
  DdbEndpoint _draft() {
    final e = widget.endpoint;
    final isAws = _mode == _EpMode.aws;
    return DdbEndpoint(
      id: e.id,
      name: _name.text.trim(),
      kind: isAws ? 'aws' : (e.kind == 'aws' ? 'url' : e.kind),
      endpoint: isAws ? '' : _endpoint.text.trim(),
      partitionID: e.partitionID,
      region: isAws ? _region.text.trim() : '',
      accessKeyId: isAws ? _ak.text.trim() : '',
      secretKey: isAws ? _sk.text.trim() : '',
      sessionToken: isAws ? _token.text.trim() : '',
      source: e.source,
    );
  }

  // Probe the backend described by the current field values via ListTables;
  // reports reachability + table count without persisting.
  Future<void> _testConnection() async {
    final core = widget.core;
    if (core == null) return;
    setState(() {
      _testing = true;
      _testOk = null;
      _testMsg = null;
    });
    final r = await core.epListTables(_draft().toStorageConfig());
    if (!mounted) return;
    setState(() {
      _testing = false;
      if (r['ok'] == true) {
        _testOk = true;
        _testMsg = trp('ep.testConnectionOk',
            {'n': '${((r['tables'] as List?) ?? []).length}'});
      } else {
        _testOk = false;
        _testMsg = r['error']?.toString() ?? tr('ep.testConnectionFailed');
      }
    });
  }

  // Mode switch plus the Test-connection probe and its result line.
  Widget _connectionLead(AppTokens t) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _modeSeg(),
        const Spacer(),
        if (widget.core != null)
          CodexButton(
            key: const ValueKey('ep-test-connection'),
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('ep.testConnection'),
            onPressed: _testing ? null : _testConnection,
            icon: const Icon(Icons.network_check, size: 15),
            label: Text(tr('ep.testConnection')),
          ),
      ]),
      if (_testing || _testMsg != null) ...[
        const SizedBox(height: 10),
        Row(children: [
          if (_testing)
            SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: t.accent),
            )
          else
            Icon(
                _testOk == true
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                size: 14,
                color: _testOk == true ? t.success : t.danger),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _testing ? tr('ep.ovChecking') : (_testMsg ?? ''),
              style: Ts.style(
                size: Ts.sm,
                color: _testing
                    ? t.text3
                    : (_testOk == true ? t.success : t.danger),
                monoFont: !_testing && _testOk != true,
              ),
            ),
          ),
        ]),
      ],
    ]);
  }

  // Same house grammar as ServiceConfigEditor: numbered section card (badge
  // head band + ruled body) over a two-column field grid.
  Widget _section(AppTokens t, String n, String title, List<Widget> fields,
      {Widget? lead}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: CodexSurface(
        key: ValueKey('ep-config-section-$n'),
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
                child: Row(children: [
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.accent,
                      borderRadius: BorderRadius.circular(Dim.radiusS),
                    ),
                    child: Text(
                      n,
                      style: Ts.style(
                        size: Ts.xs,
                        color: t.onAccent,
                        weight: FontWeight.w700,
                        monoFont: true,
                        tabularNums: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    title.toUpperCase(),
                    style: Ts.style(
                      size: Ts.md,
                      letterSpacing: 0.9,
                      weight: FontWeight.w700,
                      color: t.text,
                    ),
                  ),
                ]),
              ),
            ),
            const CodexDivider(),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (lead != null) ...[lead, const SizedBox(height: 12)],
                  _grid(fields),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(List<Widget> fields) {
    final rows = <Widget>[];
    for (var i = 0; i < fields.length; i += 2) {
      final left = fields[i];
      final right = i + 1 < fields.length ? fields[i + 1] : null;
      rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(child: right ?? const SizedBox.shrink()),
      ]));
      if (i + 2 < fields.length) rows.add(const SizedBox(height: 12));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _field(AppTokens t, TextEditingController c, String label,
      {Key? key}) {
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
            key: key == null
                ? null
                : ValueKey('${(key as ValueKey).value}-input'),
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
          onPressed: _busy
              ? null
              : () {
                  _reseed();
                  setState(() {});
                },
          icon: const Icon(Icons.restore, size: 15),
          label: Text(tr('home.revert')),
        ),
        const SizedBox(width: 8),
        CodexButton(
          key: const ValueKey('ep-config-delete'),
          variant: CodexButtonVariant.danger,
          semanticLabel: tr('home.delete'),
          onPressed: _busy ? null : _confirmDelete,
          icon: const Icon(Icons.delete_outline, size: 15),
          label: Text(tr('home.delete')),
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
