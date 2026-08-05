// The managed Local DynamoDB engine's own Monitor and Logs views. Hosted by
// the local endpoint detail page (lib/src/endpoint_detail.dart) since the
// engine telemetry was separated off the instance tabs on 2026-08-05
// (separate-monitor-logs): an instance shows only its redimos proxy, and the
// engine surfaces live on the endpoint that IS the engine. The data arrives
// on the engine-dedicated native surface (rm_ddb_get / rm_ddb_logs), which
// was always entity-disjoint from the proxy's rm_status / rm_logs.

import 'dart:async';

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'monitor_widgets.dart';
import 'native.dart';

// The engine dashboard — the content the instance Monitor tab's old
// "LOCAL DYNAMODB" section rendered, now full-page. Same tiles, same guards:
// the Latency tile keys off probeOk (a timed ListTables round-trip measured
// by the native probe loop, not scraped from /metrics), the PID tile requires
// pid > 0 (an ADOPTED docker/localstack engine is never assigned a pid), and
// the Port tile shows the LIVE port while up (rm_ddb_set persists a new port
// without restarting, so config.port can name an unbound port) falling back
// to the configured one when stopped.
class DdbMonitorView extends StatelessWidget {
  final LocalDdbInfo? ddb;
  final List<double> cpuHist;
  final List<double> memHist;
  final List<double> diskHist;
  const DdbMonitorView(
      {super.key,
      required this.ddb,
      required this.cpuHist,
      required this.memHist,
      required this.diskHist});

  @override
  Widget build(BuildContext context) {
    final d = ddb;
    if (d == null) {
      // No engine snapshot at all (never configured). The tab itself only
      // exists for an endpoint bound to the engine, so this is a transient
      // first-frame state — keep it minimal.
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.storage, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          Text(tr('home.stopped'), style: const TextStyle(fontSize: 14)),
        ]),
      );
    }
    final up = d.status == 'running';
    // "runtime · product" — mirrors the config dropdown labels so the tile
    // says both how it runs and which backend (e.g. "Docker · LocalStack").
    final engine = ddbEngineLabel(d.config.engine);
    // Same sparkHeight (48) as the redimos dashboard so every chart box on
    // either entity's page is an identical size.
    Widget spark(String label, String value, List<double> data, Color color) =>
        SparkTile(label: label, value: value, data: data, color: color, width: null, sparkHeight: 48);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        sectionHeader(context, Icons.storage, 'LOCAL DYNAMODB',
            badge: d.adopted ? tr('home.adopted') : null),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: spark(tr('home.cpu'), up ? '${d.cpuPercent.toStringAsFixed(1)} %' : '—',
                    cpuHist, const Color(0xFF7FB2E6))),
            const SizedBox(width: 12),
            Expanded(
                child: spark(tr('home.memory'), up ? '${(d.memBytes / (1024 * 1024)).round()} MB' : '—',
                    memHist, const Color(0xFF57CF92))),
            const SizedBox(width: 12),
            Expanded(
                child: spark(tr('home.diskIo'), up ? fmtRate(d.diskPerSec) : '—',
                    diskHist, const Color(0xFFD9A85B))),
          ]),
        ),
        const SizedBox(height: 12),
        // Every tile shares one fit reference — the engine label — so all
        // values render at one identical, width-adaptive size (the same rule
        // the redimos dashboard applies on the instance page).
        tileRow([
          // Dynamic first …
          InfoTile(label: tr('home.uptime'), fitReference: engine, value: up ? fmtUptime(d.uptimeSec) : '—'),
          InfoTile(label: tr('home.restarts'), fitReference: engine, value: '${d.restarts}'),
          // Unlike the redimos Latency tile (scraped from redimos's own
          // /metrics), this number is MEASURED by the native probe loop: a
          // timed ListTables round-trip against the engine. The two are
          // therefore not comparable across engines — LocalStack is
          // intrinsically slower than java. Gated on probeOk exactly as the
          // redimos tile gates on metricsOk.
          InfoTile(
              label: tr('home.latency'),
              fitReference: engine,
              value: up && d.probeOk ? '${d.latencyMs.toStringAsFixed(2)} ms' : '—'),
          InfoTile(label: tr('home.status'), fitReference: engine, value: up ? tr('home.running') : d.status),
          // The `d.pid > 0` guard is load-bearing, not defensive: an ADOPTED
          // docker/localstack DDB is never assigned a pid (tryAdoptDocker),
          // so it reads 0 for its whole life. Note that in docker mode this
          // is the `docker run` CLI shim's host pid, not the container's.
          InfoTile(label: tr('home.pid'), fitReference: engine, value: up && d.pid > 0 ? '${d.pid}' : '—'),
          // The LIVE port while up — the port the Latency tile actually
          // probed: rm_ddb_set persists a new port without restarting, so
          // config.port can name a port nothing is bound to. Falls back to
          // the configured one when stopped, which is then the only port
          // there is.
          InfoTile(
              label: tr('home.port'),
              fitReference: engine,
              value: up && d.port > 0 ? '${d.port}' : '${d.config.port}'),
          // "Engine" (not a run-mode label) because the choice is a different
          // backend product — dynamodb-local vs LocalStack — not just a mode.
          InfoTile(label: tr('home.engine'), fitReference: engine, value: engine),
        ]),
      ]),
    );
  }
}

// The engine's live log tail — the content the instance Logs tab's old second
// LOCAL DYNAMODB section rendered, now full-page. Same behaviour: 1200ms poll
// of rm_ddb_logs, bounded 200-line tail, auto-scroll-to-end, monospace card.
class DdbLogsView extends StatefulWidget {
  final NativeCore core;
  const DdbLogsView({super.key, required this.core});

  @override
  State<DdbLogsView> createState() => _DdbLogsViewState();
}

class _DdbLogsViewState extends State<DdbLogsView> {
  List<String> _lines = [];
  Timer? _t;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _pull();
    _t = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pull());
  }

  @override
  void dispose() {
    _t?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _pull() {
    try {
      final l = widget.core.ddbLogs();
      if (!linesEqual(l, _lines)) {
        setState(() => _lines = l);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A bounded tail so the log never grows without limit (same bound the
    // instance Logs tab applies).
    const maxTail = 200;
    final tail = _lines.length > maxTail
        ? _lines.sublist(_lines.length - maxTail)
        : _lines;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.all(12),
        alignment: Alignment.topLeft,
        child: tail.isEmpty
            ? Text(tr('home.noOutput'),
                style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color))
            : SingleChildScrollView(
                controller: _scroll,
                child: SelectableText(
                  tail.join('\n'),
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                      color: scheme.onSurface),
                ),
              ),
      ),
    );
  }
}
