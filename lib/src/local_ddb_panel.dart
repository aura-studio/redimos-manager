// CP 9.x: extracted from main.dart so the home chrome (src/home_chrome.dart)
// and the pixel-capture channel can use the sidebar dock without importing
// main.dart. Code moved verbatim.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_status.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

// ---------------------------------------------------------------------------
// Local DynamoDB panel (sidebar dock): 3 engines × 2 storage modes
// ---------------------------------------------------------------------------

class LocalDdbPanel extends StatefulWidget {
  final NativeCore core;
  final LocalDdbInfo? info;
  final VoidCallback onMutated;
  const LocalDdbPanel({
    super.key,
    required this.core,
    required this.info,
    required this.onMutated,
  });

  @override
  State<LocalDdbPanel> createState() => _LocalDdbPanelState();
}

class _LocalDdbPanelState extends State<LocalDdbPanel> {
  final _port = TextEditingController();
  final _store = TextEditingController(); // volume (docker) / dataDir (java)
  bool _seeded = false;
  bool _expanded = false; // collapsed by default → just the status line

  @override
  void dispose() {
    _port.dispose();
    _store.dispose();
    super.dispose();
  }

  LocalDdbConfig get _cfg => widget.info?.config ?? LocalDdbConfig();

  void _seedOnce() {
    if (_seeded || widget.info == null) return;
    _seeded = true;
    _port.text = '${_cfg.port}';
    _store.text = _cfg.engine == 'java' ? _cfg.dataDir : _cfg.volume;
  }

  void _commit({String? engine, String? storage}) {
    final c = _cfg;
    final next = LocalDdbConfig(
      engine: engine ?? c.engine,
      storage: storage ?? c.storage,
      port: int.tryParse(_port.text.trim()) ?? c.port,
      dataDir: c.dataDir,
      volume: c.volume,
    );
    // Engine switch: follow the new engine's default port if the field still
    // holds the previous engine's default.
    if (engine != null && engine != c.engine) {
      final wasDefault = next.port == 8000 || next.port == 4566;
      if (wasDefault) {
        next.port = engine == 'localstack' ? 4566 : 8000;
        _port.text = '${next.port}';
      }
      _store.text = engine == 'java' ? next.dataDir : next.volume;
    }
    final sv = _store.text.trim();
    if (next.engine == 'java') {
      next.dataDir = sv;
    } else {
      next.volume = sv;
    }
    try {
      widget.core.ddbSet(next);
      widget.onMutated();
    } catch (_) {}
  }

  void _startStop(bool active) {
    try {
      if (active) {
        widget.core.ddbStop();
      } else {
        _commit(); // persist any pending field edits before launching
        widget.core.ddbStart();
      }
      widget.onMutated();
    } catch (e) {
      final tokens = AppTokens.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          backgroundColor: tokens.danger,
        ),
      );
    }
  }

  void _showLogs() {
    final lines = widget.core.ddbLogs();
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final tokens = AppTokens.of(ctx);
        return AlertDialog(
          key: const ValueKey('local-ddb-logs-dialog'),
          title: Text(tr('home.localDdbLogs')),
          content: SizedBox(
            width: 720,
            height: 420,
            child: CodexSurface(
              variant: CodexSurfaceVariant.sunken,
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                key: const ValueKey('local-ddb-logs-scroll'),
                child: SelectableText(
                  lines.isEmpty ? tr('home.noOutput') : lines.join('\n'),
                  key: const ValueKey('local-ddb-logs-content'),
                  style: Ts.style(
                    size: Ts.sm,
                    height: 1.4,
                    color: tokens.text,
                    monoFont: true,
                  ),
                ),
              ),
            ),
          ),
          actions: [
            CodexButton(
              label: Text(tr('home.close')),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        );
      },
    );
  }

  (CodexStatus, String) _status(String status) => switch (status) {
        'running' => (CodexStatus.running, tr('home.running')),
        'preparing' => (CodexStatus.warning, tr('home.preparing')),
        'restarting' => (CodexStatus.warning, tr('home.restarting')),
        'error' => (CodexStatus.error, tr('home.error')),
        'failed' => (CodexStatus.danger, tr('home.failed')),
        _ => (CodexStatus.stopped, tr('home.stopped')),
      };

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    _seedOnce();
    final cfg = _cfg;
    final status = info?.status ?? 'stopped';
    final active = info?.isActive ?? false;
    final (semanticStatus, statusText) = _status(status);
    final tokens = AppTokens.of(context);
    final dockerOk = info?.dockerOk ?? false;
    final javaOk = info?.javaOk ?? false;

    final engineItems = <DropdownMenuItem<String>>[
      DropdownMenuItem(
        value: 'java',
        enabled: javaOk,
        child: Text(
          'Java · local${javaOk ? "" : "  ${tr('home.noJre')}"}',
          style: Ts.style(
            size: Ts.sm,
            color: javaOk ? tokens.text : tokens.text3,
          ),
        ),
      ),
      DropdownMenuItem(
        value: 'docker',
        enabled: dockerOk,
        child: Text(
          'Docker · dynamodb-local${dockerOk ? "" : "  ${tr('home.noDocker')}"}',
          style: Ts.style(
            size: Ts.sm,
            color: dockerOk ? tokens.text : tokens.text3,
          ),
        ),
      ),
      DropdownMenuItem(
        value: 'localstack',
        enabled: dockerOk,
        child: Text(
          'Docker · LocalStack${dockerOk ? "" : "  ${tr('home.noDocker')}"}',
          style: Ts.style(
            size: Ts.sm,
            color: dockerOk ? tokens.text : tokens.text3,
          ),
        ),
      ),
    ];

    return Padding(
      key: const ValueKey('local-ddb-panel'),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(builder: (context) {
            // Status figures; "Running" is implied by the status dot.
            final statsText = active && status == 'running'
                ? ':${cfg.port}'
                    ' · ${info!.cpuPercent.toStringAsFixed(1)}%'
                    ' · ${(info.memBytes / (1024 * 1024)).round()}MB'
                    '${info.restarts > 0 ? " · ↻${info.restarts}" : ""}'
                : statusText;
            final stats = Text(
              statsText,
              key: const ValueKey('local-ddb-stats'),
              overflow: TextOverflow.ellipsis,
              style: Ts.style(
                size: Ts.xs,
                color: tokens.text3,
                monoFont: active && status == 'running',
                tabularNums: active && status == 'running',
              ),
            );
            // Bottom-docked panel grows upward: up-chevron to expand, down to collapse.
            final head = <Widget>[
              Icon(
                _expanded ? Icons.expand_more : Icons.expand_less,
                size: 18,
                color: tokens.text3,
              ),
              const SizedBox(width: 5),
              CodexStatusDot(
                key: const ValueKey('local-ddb-status'),
                status: semanticStatus,
                semanticLabel: statusText,
                glow: status == 'running',
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Tooltip(
                  message: tr('home.localDynamoDb'),
                  child: Text(
                    tr('home.localDynamoDb'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ts.style(
                      size: Ts.md,
                      weight: FontWeight.w600,
                      color: tokens.text,
                    ),
                  ),
                ),
              ),
            ];
            final button = _expanded
                ? CodexIconButton(
                    key: const ValueKey('local-ddb-logs-action'),
                    tooltip: tr('home.logsTooltip'),
                    semanticLabel: tr('home.logsTooltip'),
                    icon: const Icon(Icons.terminal, size: 16),
                    onPressed: _showLogs,
                  )
                : CodexIconButton(
                    key: const ValueKey('local-ddb-collapsed-action'),
                    tooltip: active ? tr('config.stop') : tr('config.start'),
                    semanticLabel:
                        active ? tr('config.stop') : tr('config.start'),
                    variant: active
                        ? CodexButtonVariant.danger
                        : CodexButtonVariant.ghost,
                    icon: Icon(
                      active ? Icons.stop : Icons.play_arrow,
                      size: 18,
                      color: active ? tokens.danger : tokens.success,
                    ),
                    onPressed: () => _startStop(active),
                  );
            return InkWell(
              key: const ValueKey('local-ddb-toggle'),
              borderRadius: BorderRadius.circular(Dim.radiusS),
              onTap: () => setState(() => _expanded = !_expanded),
              // Expanded: title row + stats on its own line below (room to spare).
              // Collapsed: everything on one compact line, stats inline before the button.
              child: _expanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [...head, const Spacer(), button]),
                        Padding(
                          padding: const EdgeInsets.only(left: 30, bottom: 2),
                          child: stats,
                        ),
                      ],
                    )
                  // Fixed 30px row → panel total 8+30+10 = 48px, matching the Cmd
                  // input row so the two top dividers line up across the split.
                  : SizedBox(
                      height: Dim.ctlH,
                      child: Row(children: [
                        ...head,
                        const SizedBox(width: 8),
                        Expanded(child: stats),
                        const SizedBox(width: 2),
                        button,
                      ]),
                    ),
            );
          }),
          // Expansion intentionally snaps to its final bounds. Interpolating this
          // height pushes the entity list on every animation frame.
          SizedBox(
            key: const ValueKey('local-ddb-body'),
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!active) ...[
                        const SizedBox(height: 8),
                        CodexSelectField<String>(
                          key: const ValueKey('local-ddb-engine'),
                          value: cfg.engine,
                          decoration: InputDecoration(
                            labelText: tr('home.engine'),
                          ),
                          items: engineItems,
                          onChanged: (value) {
                            if (value != null) {
                              _commit(engine: value);
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        Row(children: [
                          if (cfg.engine != 'localstack')
                            Expanded(
                              child: CodexSelectField<String>(
                                key: const ValueKey('local-ddb-storage'),
                                value: cfg.storage == 'persist'
                                    ? 'persist'
                                    : 'memory',
                                decoration: InputDecoration(
                                  labelText: tr('home.storage'),
                                ),
                                items: [
                                  DropdownMenuItem(
                                    value: 'memory',
                                    child: Text(tr('home.inMemory')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'persist',
                                    child: Text(tr('home.persisted')),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    _commit(storage: value);
                                  }
                                },
                              ),
                            )
                          else
                            Expanded(
                              child: Text(
                                tr('home.storageManagedByLocalstack'),
                                style: Ts.style(
                                  size: Ts.xs,
                                  color: tokens.text3,
                                ),
                              ),
                            ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 86,
                            child: CodexTextField(
                              key: const ValueKey('local-ddb-port'),
                              controller: _port,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: tr('home.port'),
                              ),
                              style: Ts.style(
                                size: Ts.sm,
                                color: tokens.text,
                                monoFont: true,
                                tabularNums: true,
                              ),
                              onSubmitted: (_) => _commit(),
                            ),
                          ),
                        ]),
                        if (cfg.engine != 'localstack' &&
                            cfg.storage == 'persist') ...[
                          const SizedBox(height: 8),
                          CodexTextField(
                            key: const ValueKey('local-ddb-store'),
                            controller: _store,
                            decoration: InputDecoration(
                              labelText: cfg.engine == 'java'
                                  ? tr('home.dataDir')
                                  : tr('home.volume'),
                            ),
                            style: Ts.style(
                              size: Ts.sm,
                              color: tokens.text,
                              monoFont: true,
                            ),
                            onSubmitted: (_) => _commit(),
                          ),
                        ],
                      ],
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                          child: CodexButton(
                            key: const ValueKey('local-ddb-primary-action'),
                            semanticLabel:
                                active ? tr('home.stop') : tr('home.start'),
                            variant: active
                                ? CodexButtonVariant.danger
                                : CodexButtonVariant.primary,
                            icon: Icon(
                              active ? Icons.stop : Icons.play_arrow,
                              size: 16,
                            ),
                            label: Text(
                              active ? tr('home.stop') : tr('home.start'),
                            ),
                            onPressed: () => _startStop(active),
                          ),
                        ),
                        if (status == 'running') ...[
                          const SizedBox(width: 8),
                          CodexIconButton(
                            key: const ValueKey('local-ddb-copy-endpoint'),
                            tooltip: tr('home.copyEndpoint'),
                            semanticLabel: tr('home.copyEndpoint'),
                            variant: CodexButtonVariant.secondary,
                            icon: const Icon(Icons.copy, size: 16),
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(
                                  text: 'http://localhost:${cfg.port}',
                                ),
                              );
                            },
                          ),
                        ],
                      ]),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
