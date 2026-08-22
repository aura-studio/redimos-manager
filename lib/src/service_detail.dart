// v1.2: the two read-side Service detail tabs — Monitor / Logs. Configure
// lives in service_configure.dart. The Overview tab (lifecycle buttons) is
// gone: start/stop live on the sidebar cards only, and restart has no entry
// point anywhere (requirements 4.3, 8.1).
//
// House grammar: monitor_widgets.dart tiles (SparkTile/InfoTile), shared
// status paint (ui_status.dart), severity parsing reused from logs_page.dart.
// Everything is ID-addressed: Monitor reads ONE Service's ring buffer, Logs
// requests ONE Service's lines through ServicesState's generation guard, so a
// stale reply for a previously selected Service is dropped silently.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';
import 'logs_page.dart' show parseLogLevel, levelColor;
import 'models.dart';
import 'monitor_widgets.dart';
import 'services_state.dart';
import 'ui_primitives.dart';
import 'ui_states.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// One localized label per lifecycle state (distinct status rendering).
String serviceStateLabel(ServiceState s) => switch (s) {
      ServiceState.stopped => tr('svc.state.stopped'),
      ServiceState.preparing => tr('svc.state.preparing'),
      ServiceState.running => tr('svc.state.running'),
      ServiceState.restarting => tr('svc.state.restarting'),
      ServiceState.stopping => tr('svc.state.stopping'),
      ServiceState.failed => tr('svc.state.failed'),
      ServiceState.error => tr('svc.state.error'),
      ServiceState.recovering => tr('svc.state.recovering'),
    };

/// The engine default host port applied when a Service configures 0.
int serviceDefaultPort(ServiceEngine e) =>
    e == ServiceEngine.localStack ? 4566 : 8000;

/// Uptime tile value: 「3m 16s」 style; 「—」 when never started.
String serviceUptimeValue(String startedAtRfc3339, {DateTime? now}) {
  if (startedAtRfc3339.isEmpty) return '—';
  final started = DateTime.tryParse(startedAtRfc3339);
  if (started == null) return '—';
  final d = (now ?? DateTime.now()).difference(started);
  if (d.isNegative) return '—';
  return fmtUptime(d.inSeconds);
}

/// Latency tile value: probe RTT or 「—」 until a probe succeeds.
String serviceLatencyValue(double? latencyMs) => latencyMs == null
    ? '—'
    : '${latencyMs < 10 ? latencyMs.toStringAsFixed(1) : latencyMs.round().toString()} ms';

/// Port tile value: 0 renders the engine's effective default port (7.3).
String servicePortValue(ServiceConfig c) =>
    '${c.port == 0 ? serviceDefaultPort(c.engine) : c.port}';

/// Errors tile value: the count of ERROR-severity lines held in the log
/// buffer — the same rule as the Logs screen's ERROR chip; 「—」 until a
/// runtime exists (-1).
String serviceErrorValue(ServiceRuntime rt) =>
    rt.errorCount < 0 ? '—' : '${rt.errorCount}';

// ---------------------------------------------------------------------------
// Monitor (requirement 7: three spark cards over seven info tiles)
// ---------------------------------------------------------------------------

class ServiceMonitorTab extends StatefulWidget {
  final ServiceInfo service;

  /// The ring buffer for THIS Service ID only — never a shared buffer.
  final ServiceHistory history;

  const ServiceMonitorTab({
    super.key,
    required this.service,
    required this.history,
  });

  @override
  State<ServiceMonitorTab> createState() => _ServiceMonitorTabState();
}

class _ServiceMonitorTabState extends State<ServiceMonitorTab> {
  // Dismissal is per-error-text: dismissing one error never hides a NEW one
  // (requirement 8.2).
  String? _dismissedError;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final service = widget.service;
    final history = widget.history;
    final cfg = service.config;
    final rt = service.runtime;

    final live = history.isNotEmpty;
    final cpu = live ? history.cpuPercent.last : null;
    final mem = live ? history.memMb.last : null;
    final disk = live ? history.diskBytesPerSec.last : null;

    final err = rt.error;
    final showBanner = err.isNotEmpty && err != _dismissedError;

    return SingleChildScrollView(
      key: const ValueKey('service-monitor-scroll'),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Startup/runtime failure surfaces at the top of Monitor — Overview no
        // longer exists, so this banner is the error's only home (8.2).
        if (showBanner)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: CodexSurface(
              key: const ValueKey('service-monitor-error-banner'),
              variant: CodexSurfaceVariant.elevated,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(children: [
                Icon(Icons.error_outline, size: 16, color: t.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${tr('svc.lastError')}${rt.errorCode.isEmpty ? '' : ' · ${rt.errorCode}'}',
                        style: Ts.style(
                            size: Ts.sm, weight: FontWeight.w700, color: t.danger),
                      ),
                      const SizedBox(height: 2),
                      Text(err,
                          style: Ts.style(
                              size: Ts.sm, color: t.text, monoFont: true)),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('service-monitor-error-dismiss'),
                  icon: Icon(Icons.close, size: 14, color: t.text3),
                  tooltip: '',
                  onPressed: () => setState(() => _dismissedError = err),
                ),
              ]),
            ),
          ),
        // Top row: three spark cards — CPU / Memory / Disk I/O (7.1). They
        // stay on ONE line at 1280px (7.4): Expanded thirds, never wrapping.
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: SparkTile(
              key: const ValueKey('service-monitor-cpu'),
              label: tr('svc.cpu'),
              value: cpu == null ? '—' : '${cpu.toStringAsFixed(1)}%',
              data: history.cpuPercent,
              color: t.accent,
              width: null,
              sparkHeight: 52,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SparkTile(
              key: const ValueKey('service-monitor-mem'),
              label: tr('svc.memory'),
              value: mem == null ? '—' : '${mem.toStringAsFixed(0)} MB',
              data: history.memMb,
              color: t.success,
              width: null,
              sparkHeight: 52,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SparkTile(
              key: const ValueKey('service-monitor-disk'),
              label: tr('svc.disk'),
              value: disk == null ? '—' : fmtRate(disk),
              data: history.diskBytesPerSec,
              color: t.warning,
              width: null,
              sparkHeight: 52,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        // Bottom rows: eight info tiles in fixed order (7.2 + the v1.2
        // errors tile); the 4-column grid wraps into two rows at 1280px
        // without overflow (7.4).
        tileGrid([
          InfoTile(
            key: const ValueKey('service-monitor-uptime'),
            label: tr('svc.uptime').toUpperCase(),
            value: serviceUptimeValue(rt.startedAt),
          ),
          InfoTile(
            key: const ValueKey('service-monitor-restarts'),
            label: tr('svc.restarts').toUpperCase(),
            value: '${rt.restarts}',
          ),
          InfoTile(
            key: const ValueKey('service-monitor-latency'),
            label: tr('svc.latency').toUpperCase(),
            value: serviceLatencyValue(rt.latencyMs),
          ),
          InfoTile(
            key: const ValueKey('service-monitor-status'),
            label: tr('svc.status').toUpperCase(),
            value: serviceStateLabel(rt.state),
            valueColor: switch (rt.state) {
              ServiceState.running => t.success,
              ServiceState.failed || ServiceState.error => t.danger,
              ServiceState.stopped => t.text3,
              _ => t.warning,
            },
          ),
          InfoTile(
            key: const ValueKey('service-monitor-health'),
            label: tr('svc.health').toUpperCase(),
            value: rt.ready ? tr('svc.ready') : tr('svc.notReady'),
            valueColor: rt.ready ? t.success : t.warning,
          ),
          InfoTile(
            key: const ValueKey('service-monitor-port'),
            label: tr('svc.port').toUpperCase(),
            value: servicePortValue(cfg),
          ),
          InfoTile(
            key: const ValueKey('service-monitor-engine'),
            label: tr('svc.engine').toUpperCase(),
            value: ddbEngineLabel(cfg.engine.wire),
            fitReference: ddbEngineLabel('docker'),
          ),
          InfoTile(
            key: const ValueKey('service-monitor-errors'),
            label: tr('svc.errorCount').toUpperCase(),
            value: serviceErrorValue(rt),
            valueColor: rt.errorCount > 0 ? t.danger : null,
          ),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Logs (requirement 10: severity colouring + auto-scroll)
// ---------------------------------------------------------------------------

class ServiceLogsTab extends StatefulWidget {
  final ServiceInfo service;

  /// State owner: requestLogs() carries the generation guard that discards a
  /// stale reply after the selection changed.
  final ServicesState state;

  const ServiceLogsTab({super.key, required this.service, required this.state});

  @override
  State<ServiceLogsTab> createState() => ServiceLogsTabState();
}

class ServiceLogsTabState extends State<ServiceLogsTab> {
  List<String> _lines = const [];
  String? _error;
  bool _loading = false;

  final ScrollController scroll = ScrollController();

  /// Follow the tail while the view sits at the bottom; a manual scroll up
  /// pauses following until the user returns to the bottom (10.2, 10.3).
  bool autoScroll = true;

  String get _id => widget.service.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ServiceLogsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service.id != _id) {
      // Selection changed: reset the view first, then load the new target.
      _lines = const [];
      _error = null;
      autoScroll = true;
      _load();
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted || _loading) return;
    setState(() => _loading = true);
    try {
      final lines = await widget.state.requestLogs(_id);
      if (lines == null || !mounted) return; // stale — drop silently
      setState(() {
        _lines = lines;
        _error = null;
      });
      _maybeAutoscroll();
    } on ServiceApiException catch (e) {
      // Error is preserved IN CONTEXT; previous lines stay visible.
      if (mounted) setState(() => _error = '${e.code}: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _maybeAutoscroll() {
    if (!autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is UserScrollNotification) {
      // forward == the content moves down == the user scrolled UP.
      if (n.direction == ScrollDirection.forward) autoScroll = false;
    } else if (n is ScrollUpdateNotification && scroll.hasClients) {
      final p = scroll.position;
      if (p.pixels >= p.maxScrollExtent - 24) autoScroll = true;
    }
    return false;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('svc.copied'))));
  }

  void _clearView() {
    // View-only clear: the core-side log buffer is untouched.
    setState(() => _lines = const []);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      // Action row: refresh / copy / clear-view (10.4).
      Container(
        key: const ValueKey('service-logs-actions'),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        alignment: Alignment.centerRight,
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          CodexButton(
            key: const ValueKey('service-logs-refresh'),
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('svc.refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh, size: 14),
            label: Text(tr('svc.refresh')),
          ),
          const SizedBox(width: 8),
          CodexButton(
            key: const ValueKey('service-logs-copy'),
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('svc.copy'),
            onPressed: _lines.isEmpty ? null : _copy,
            icon: const Icon(Icons.copy_all_outlined, size: 14),
            label: Text(tr('svc.copy')),
          ),
          const SizedBox(width: 8),
          CodexButton(
            key: const ValueKey('service-logs-clear'),
            variant: CodexButtonVariant.ghost,
            semanticLabel: tr('svc.clearView'),
            onPressed: _lines.isEmpty ? null : _clearView,
            icon: const Icon(Icons.clear_all, size: 14),
            label: Text(tr('svc.clearView')),
          ),
        ]),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
          child: Text(
            '${tr('svc.logsLoadFailed')}: $_error',
            key: const ValueKey('service-logs-error'),
            style: Ts.style(size: Ts.sm, color: t.danger),
          ),
        ),
      Expanded(
        child: _lines.isEmpty && !_loading
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: CodexStateShell(
                  key: const ValueKey('service-logs-empty'),
                  state: CodexContentState.empty,
                  content: const SizedBox.shrink(),
                  message: tr('svc.logsEmpty'),
                  icon: Icon(Icons.article_outlined,
                      size: 24, color: t.text3),
                ),
              )
            : SelectionArea(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScrollNotification,
                  child: ListView.builder(
                    key: const ValueKey('service-logs-list'),
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
                    itemCount: _lines.length,
                    itemBuilder: (context, i) {
                      final line = _lines[i];
                      // Severity colouring (10.1): the instance Logs parser is
                      // the single source of truth for level → token.
                      final color = levelColor(parseLogLevel(line), t);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          line,
                          style: Ts.style(
                              size: Ts.sm, color: color, monoFont: true),
                        ),
                      );
                    },
                  ),
                ),
              ),
      ),
    ]);
  }
}
