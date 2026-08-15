// Stage 14: the three read-side Service detail tabs — Overview / Monitor /
// Logs. Configure lives in service_configure.dart (stage 13).
//
// House grammar: numbered-free info tiles (monitor_widgets.dart), shared
// status paint (ui_status.dart), shared button primitive (ui_primitives.dart).
// Everything is ID-addressed: Monitor reads ONE Service's ring buffer, Logs
// requests ONE Service's lines through ServicesState's generation guard, so a
// stale reply for a previously selected Service is dropped silently (9.6).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';
import 'models.dart';
import 'monitor_widgets.dart';
import 'services_state.dart';
import 'ui_primitives.dart';
import 'ui_states.dart';
import 'ui_status.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// One localized label per lifecycle state (9.7 distinct status rendering).
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

/// State → status paint. Transitional states share the warning tone; the
/// terminal-good state owns success; failures own the error tone.
CodexStatus serviceStatusOf(ServiceState s) => switch (s) {
      ServiceState.running => CodexStatus.running,
      ServiceState.preparing ||
      ServiceState.restarting ||
      ServiceState.stopping ||
      ServiceState.recovering =>
        CodexStatus.warning,
      ServiceState.stopped => CodexStatus.neutral,
      ServiceState.failed || ServiceState.error => CodexStatus.error,
    };

/// Engine-conditional data location (mirrors the Configure editor's reading).
String serviceDataLocation(ServiceConfig c) => switch (c.storage.mode) {
      ServiceStorageMode.memory => tr('svc.location.memory'),
      ServiceStorageMode.managed => tr('svc.location.managed'),
      ServiceStorageMode.custom => c.engine == ServiceEngine.java
          ? (c.storage.path.isEmpty ? tr('svc.storage.custom') : c.storage.path)
          : (c.storage.volume.isEmpty
              ? tr('svc.storage.custom')
              : c.storage.volume),
    };

String _uptimeLabel(String startedAtRfc3339) {
  if (startedAtRfc3339.isEmpty) return tr('svc.neverStarted');
  final started = DateTime.tryParse(startedAtRfc3339);
  if (started == null) return tr('svc.neverStarted');
  final d = DateTime.now().difference(started);
  if (d.isNegative) return tr('svc.neverStarted');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
  return '${s}s';
}

// ---------------------------------------------------------------------------
// Overview (14.1)
// ---------------------------------------------------------------------------

class ServiceOverviewTab extends StatelessWidget {
  final ServiceInfo service;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRestart;

  const ServiceOverviewTab({
    super.key,
    required this.service,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final cfg = service.config;
    final rt = service.runtime;
    final state = rt.state;

    // 9.7 valid actions per state: start only from a cold/failed state, stop
    // only while live, restart only while running. Transitional states accept
    // no action — the buttons stay visible but disabled.
    final canStart = state == ServiceState.stopped ||
        state == ServiceState.failed ||
        state == ServiceState.error;
    final canStop = rt.isLive;
    final canRestart = state == ServiceState.running;

    final identity = cfg.engine == ServiceEngine.java
        ? (rt.pid > 0 ? 'PID ${rt.pid}' : tr('svc.neverStarted'))
        : (rt.containerId.isEmpty
            ? tr('svc.neverStarted')
            : rt.containerId.length > 12
                ? rt.containerId.substring(0, 12)
                : rt.containerId);

    return SingleChildScrollView(
      key: const ValueKey('service-overview-scroll'),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Header: name + distinct status badge for every lifecycle state.
        Row(children: [
          Flexible(
            child: Text(
              cfg.name.isEmpty ? tr('service.unnamed') : cfg.name,
              key: const ValueKey('service-overview-name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ts.style(size: Ts.lg, weight: FontWeight.w700, color: t.text),
            ),
          ),
          const SizedBox(width: 10),
          CodexStatusBadge(
            key: const ValueKey('service-overview-state-badge'),
            status: serviceStatusOf(state),
            label: serviceStateLabel(state),
          ),
        ]),
        // 9.8: a lifecycle failure renders in-context — never replaces the shell.
        if (rt.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CodexSurface(
              key: const ValueKey('service-overview-error'),
              variant: CodexSurfaceVariant.elevated,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${tr('svc.lastError')}${rt.errorCode.isEmpty ? '' : ' · ${rt.errorCode}'}',
                    style: Ts.style(
                        size: Ts.sm, weight: FontWeight.w700, color: t.danger),
                  ),
                  const SizedBox(height: 4),
                  Text(rt.error,
                      style: Ts.style(size: Ts.sm, color: t.text, monoFont: true)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        tileGrid([
          InfoTile(
            key: const ValueKey('service-overview-engine'),
            label: tr('svc.engine').toUpperCase(),
            value: cfg.engine.wire,
          ),
          InfoTile(
            key: const ValueKey('service-overview-port'),
            label: tr('svc.port').toUpperCase(),
            value: '${cfg.port}',
          ),
          InfoTile(
            key: const ValueKey('service-overview-location'),
            label: tr('svc.dataLocation').toUpperCase(),
            value: serviceDataLocation(cfg),
          ),
          InfoTile(
            key: const ValueKey('service-overview-uptime'),
            label: tr('svc.uptime').toUpperCase(),
            value: _uptimeLabel(rt.startedAt),
          ),
          InfoTile(
            key: const ValueKey('service-overview-identity'),
            label: tr('svc.runtimeIdentity').toUpperCase(),
            value: identity,
          ),
          // Readiness / health keep status paint even when stopped: the
          // badges simply read "not ready" / "unhealthy".
          CodexSurface(
            key: const ValueKey('service-overview-readiness'),
            variant: CodexSurfaceVariant.elevated,
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('svc.readiness').toUpperCase(),
                    style:
                        Ts.style(size: Ts.xs, letterSpacing: 0.4, color: t.text3)),
                const SizedBox(height: 6),
                CodexStatusIndicator(
                  status: rt.ready ? CodexStatus.success : CodexStatus.neutral,
                  label: rt.ready ? tr('svc.ready') : tr('svc.notReady'),
                ),
              ],
            ),
          ),
          CodexSurface(
            key: const ValueKey('service-overview-health'),
            variant: CodexSurfaceVariant.elevated,
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('svc.health').toUpperCase(),
                    style:
                        Ts.style(size: Ts.xs, letterSpacing: 0.4, color: t.text3)),
                const SizedBox(height: 6),
                CodexStatusIndicator(
                  status: rt.healthy ? CodexStatus.success : CodexStatus.neutral,
                  label: rt.healthy ? tr('svc.healthy') : tr('svc.unhealthy'),
                ),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          CodexButton(
            key: const ValueKey('service-overview-start'),
            variant: CodexButtonVariant.primary,
            semanticLabel: tr('svc.start'),
            onPressed: canStart ? onStart : null,
            icon: const Icon(Icons.play_arrow, size: 15),
            label: Text(tr('svc.start')),
          ),
          const SizedBox(width: 8),
          CodexButton(
            key: const ValueKey('service-overview-stop'),
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('svc.stop'),
            onPressed: canStop ? onStop : null,
            icon: const Icon(Icons.stop, size: 15),
            label: Text(tr('svc.stop')),
          ),
          const SizedBox(width: 8),
          CodexButton(
            key: const ValueKey('service-overview-restart'),
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('svc.restart'),
            onPressed: canRestart ? onRestart : null,
            icon: const Icon(Icons.refresh, size: 15),
            label: Text(tr('svc.restart')),
          ),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Monitor (14.2)
// ---------------------------------------------------------------------------

class ServiceMonitorTab extends StatelessWidget {
  final ServiceInfo service;

  /// The ring buffer for THIS Service ID only — never a shared buffer (9.3).
  final ServiceHistory history;

  const ServiceMonitorTab({
    super.key,
    required this.service,
    required this.history,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    if (history.isEmpty) {
      // A stopped/never-sampled Service shows the explicit no-data state.
      return Padding(
        padding: const EdgeInsets.all(16),
        child: CodexStateShell(
          key: const ValueKey('service-monitor-empty'),
          state: CodexContentState.empty,
          content: const SizedBox.shrink(),
          message: tr('svc.monitorEmpty'),
          icon: Icon(Icons.monitor_heart_outlined, size: 24, color: t.text3),
        ),
      );
    }
    final cpu = history.cpuPercent.last;
    final mem = history.memMb.last;
    final disk = history.diskBytesPerSec.last;
    return SingleChildScrollView(
      key: const ValueKey('service-monitor-scroll'),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SparkTile(
          key: const ValueKey('service-monitor-cpu'),
          label: tr('svc.cpu'),
          value: '${cpu.toStringAsFixed(1)}%',
          data: history.cpuPercent,
          color: t.accent,
          width: null, // stretch: the Column hands down a tight width
          sparkHeight: 52, // stretched tiles need the tall band (main.dart spark())
        ),
        const SizedBox(height: 12),
        SparkTile(
          key: const ValueKey('service-monitor-mem'),
          label: tr('svc.memory'),
          value: '${mem.toStringAsFixed(0)} MB',
          data: history.memMb,
          color: t.success,
          width: null,
          sparkHeight: 52,
        ),
        const SizedBox(height: 12),
        SparkTile(
          key: const ValueKey('service-monitor-disk'),
          label: tr('svc.disk'),
          value: '${disk.toStringAsFixed(0)} B/s',
          data: history.diskBytesPerSec,
          color: t.warning,
          width: null,
          sparkHeight: 52,
        ),
        const SizedBox(height: 12),
        // Health / readiness strip: the current probe state next to the charts.
        CodexSurface(
          key: const ValueKey('service-monitor-probes'),
          variant: CodexSurfaceVariant.elevated,
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            CodexStatusIndicator(
              status: service.runtime.ready
                  ? CodexStatus.success
                  : CodexStatus.neutral,
              label:
                  service.runtime.ready ? tr('svc.ready') : tr('svc.notReady'),
            ),
            const SizedBox(width: 16),
            CodexStatusIndicator(
              status: service.runtime.healthy
                  ? CodexStatus.success
                  : CodexStatus.neutral,
              label: service.runtime.healthy
                  ? tr('svc.healthy')
                  : tr('svc.unhealthy'),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Logs (14.3)
// ---------------------------------------------------------------------------

class ServiceLogsTab extends StatefulWidget {
  final ServiceInfo service;

  /// State owner: requestLogs() carries the generation guard that discards a
  /// stale reply after the selection changed (9.6, 12.4).
  final ServicesState state;

  const ServiceLogsTab({super.key, required this.service, required this.state});

  @override
  State<ServiceLogsTab> createState() => _ServiceLogsTabState();
}

class _ServiceLogsTabState extends State<ServiceLogsTab> {
  List<String> _lines = const [];
  String? _error;
  bool _loading = false;

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
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted || _loading) return;
    setState(() => _loading = true);
    try {
      final lines = await widget.state.requestLogs(_id);
      if (lines == null || !mounted) return; // stale — drop silently (9.6)
      setState(() {
        _lines = lines;
        _error = null;
      });
    } on ServiceApiException catch (e) {
      // Error is preserved IN CONTEXT; previous lines stay visible (14.3).
      if (mounted) setState(() => _error = '${e.code}: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('svc.copied'))));
  }

  void _clearView() {
    // View-only clear: the core-side log buffer is untouched (9.4).
    setState(() => _lines = const []);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      // Action row: refresh / copy / clear-view.
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
                child: ListView.builder(
                  key: const ValueKey('service-logs-list'),
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
                  itemCount: _lines.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      _lines[i],
                      style: Ts.style(
                          size: Ts.sm, color: t.text, monoFont: true),
                    ),
                  ),
                ),
              ),
      ),
    ]);
  }
}
