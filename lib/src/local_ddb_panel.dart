// CP 9.x: extracted from main.dart so the home chrome (src/home_chrome.dart)
// and the pixel-capture channel can use the sidebar dock without importing
// main.dart. Code moved verbatim.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: Colors.red.shade800,
      ));
    }
  }

  void _showLogs() {
    final lines = widget.core.ddbLogs();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('home.localDdbLogs')),
        content: SizedBox(
          width: 720,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              lines.isEmpty ? tr('home.noOutput') : lines.join('\n'),
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('home.close'))),
        ],
      ),
    );
  }

  (Color, String) _pill(BuildContext context, String status) => switch (status) {
        'running' => (goGreen(context), tr('home.running')),
        'preparing' => (Colors.amberAccent, tr('home.preparing')),
        'restarting' => (Colors.amberAccent, tr('home.restarting')),
        'error' => (Colors.redAccent, tr('home.error')),
        'failed' => (Colors.redAccent, tr('home.failed')),
        _ => (Colors.grey, tr('home.stopped')),
      };

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    _seedOnce();
    final cfg = _cfg;
    final status = info?.status ?? 'stopped';
    final active = info?.isActive ?? false;
    final (dotColor, pillText) = _pill(context, status);
    final dockerOk = info?.dockerOk ?? false;
    final javaOk = info?.javaOk ?? false;

    final engineItems = <DropdownMenuItem<String>>[
      DropdownMenuItem(
        value: 'java',
        enabled: javaOk,
        child: Text('Java · local${javaOk ? "" : "  ${tr('home.noJre')}"}',
            style: TextStyle(color: javaOk ? null : Colors.grey)),
      ),
      DropdownMenuItem(
        value: 'docker',
        enabled: dockerOk,
        child: Text('Docker · dynamodb-local${dockerOk ? "" : "  ${tr('home.noDocker')}"}',
            style: TextStyle(color: dockerOk ? null : Colors.grey)),
      ),
      DropdownMenuItem(
        value: 'localstack',
        enabled: dockerOk,
        child: Text('Docker · LocalStack${dockerOk ? "" : "  ${tr('home.noDocker')}"}',
            style: TextStyle(color: dockerOk ? null : Colors.grey)),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(builder: (context) {
            // Status figures; "Running" is implied by the green dot so it's dropped.
            final statsText = active && status == 'running'
                ? ':${cfg.port}'
                    ' · ${info!.cpuPercent.toStringAsFixed(1)}%'
                    ' · ${(info.memBytes / (1024 * 1024)).round()}MB'
                    '${info.restarts > 0 ? " · ↻${info.restarts}" : ""}'
                : pillText;
            final stats = Text(statsText,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.grey));
            // Bottom-docked panel grows upward: up-chevron to expand, down to collapse.
            final head = <Widget>[
              Icon(_expanded ? Icons.expand_more : Icons.expand_less, size: 18, color: Colors.grey),
              const SizedBox(width: 4),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(tr('home.localDynamoDb'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            ];
            // Tight icon button: zero padding + small hit box, so the one-line
            // collapsed layout has as much room as possible for the figures.
            final button = _expanded
                ? IconButton(
                    tooltip: tr('home.logsTooltip'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    icon: const Icon(Icons.terminal, size: 16),
                    onPressed: _showLogs,
                  )
                : IconButton(
                    tooltip: active ? tr('config.stop') : tr('config.start'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    icon: Icon(active ? Icons.stop : Icons.play_arrow,
                        size: 18, color: active ? Colors.redAccent : goGreen(context)),
                    onPressed: () => _startStop(active),
                  );
            return InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              // Expanded: title row + stats on its own line below (room to spare).
              // Collapsed: everything on one compact line, stats inline before the button.
              child: _expanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [...head, const Spacer(), button]),
                        Padding(padding: const EdgeInsets.only(left: 30, bottom: 2), child: stats),
                      ],
                    )
                  // Fixed 30px row → panel total 8+30+10 = 48px, matching the Cmd
                  // input row so the two top dividers line up across the split.
                  : SizedBox(
                      height: 30,
                      child: Row(children: [
                        ...head,
                        const SizedBox(width: 8),
                        // Expanded (not Spacer + Flexible): the stats take all the
                        // room left of the button instead of being squeezed to the
                        // right edge, so the figures show in full.
                        Expanded(child: stats),
                        const SizedBox(width: 2),
                        button,
                      ]),
                    ),
            );
          }),
          // Slide the body open/closed instead of snapping.
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
          if (!active) ...[
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: cfg.engine,
              isDense: true,
              decoration: InputDecoration(
                labelText: tr('home.engine'),
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              items: engineItems,
              onChanged: (v) {
                if (v != null) _commit(engine: v);
              },
            ),
            const SizedBox(height: 10),
            Row(children: [
              if (cfg.engine != 'localstack')
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: cfg.storage == 'persist' ? 'persist' : 'memory',
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: tr('home.storage'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    items: [
                      DropdownMenuItem(value: 'memory', child: Text(tr('home.inMemory'))),
                      DropdownMenuItem(value: 'persist', child: Text(tr('home.persisted'))),
                    ],
                    onChanged: (v) {
                      if (v != null) _commit(storage: v);
                    },
                  ),
                )
              else
                Expanded(
                  child: Text(tr('home.storageManagedByLocalstack'),
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ),
              const SizedBox(width: 8),
              SizedBox(
                width: 86,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr('home.port'),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                  onSubmitted: (_) => _commit(),
                ),
              ),
            ]),
            if (cfg.engine != 'localstack' && cfg.storage == 'persist') ...[
              const SizedBox(height: 10),
              TextField(
                controller: _store,
                decoration: InputDecoration(
                  labelText: cfg.engine == 'java' ? tr('home.dataDir') : tr('home.volume'),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                onSubmitted: (_) => _commit(),
              ),
            ],
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: active
                  ? OutlinedButton.icon(
                      icon: const Icon(Icons.stop, size: 16),
                      label: Text(tr('home.stop')),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          visualDensity: VisualDensity.compact),
                      onPressed: () => _startStop(true),
                    )
                  : FilledButton.icon(
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: Text(tr('home.start')),
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      onPressed: () => _startStop(false),
                    ),
            ),
            if (status == 'running') ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: tr('home.copyEndpoint'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: 'http://localhost:${cfg.port}'));
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
