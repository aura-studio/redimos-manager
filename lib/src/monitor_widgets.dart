// Shared monitor-dashboard primitives — the sparkline / info-tile grammar used
// by the instance Monitor tab (the REDIMOS section in lib/main.dart) and by
// the Local DynamoDB engine's own Monitor view on the local endpoint page
// (lib/src/ddb_views.dart). Extracted from main.dart on 2026-08-05 when the
// engine telemetry was separated off the instance page
// (separate-monitor-logs): the native surface was always entity-disjoint
// (rm_status/rm_logs vs rm_ddb_get/rm_ddb_logs); only the Dart composition
// mixed them, and this file is what both hosts now draw from.

import 'dart:math' as math;

import 'package:flutter/material.dart';

// The "running / start" green lives in main.dart (goGreen) — it is only used
// by the sidebar LocalDdbPanel, not by the dashboard grammar.

Color _tileColor(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHighest;
Color? _tileLabelColor(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.color;

// A section eyebrow: icon + label on the left, an optional badge right-aligned.
// The badge carries state that has no tile of its own (currently "adopted").
Widget sectionHeader(BuildContext context, IconData icon, String label,
    {String? badge}) {
  final scheme = Theme.of(context).colorScheme;
  return Row(children: [
    Icon(icon, size: 16, color: scheme.onSurfaceVariant),
    const SizedBox(width: 8),
    Text(label,
        style: TextStyle(
            fontSize: 12,
            letterSpacing: 1.3,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant)),
    if (badge != null) ...[
      const Spacer(),
      Text(badge,
          style: TextStyle(
              fontSize: 11, color: Theme.of(context).textTheme.bodySmall?.color)),
    ],
  ]);
}

// Lay out a fixed set of info tiles as equal-width columns that fill the whole
// pane (every tile the same size, the row stretching edge-to-edge) in both the
// initial window and full screen — instead of fixed-width tiles clustered on
// the left. 12px gutters between tiles.
Widget tileRow(List<Widget> tiles) {
  final children = <Widget>[];
  for (var i = 0; i < tiles.length; i++) {
    if (i > 0) children.add(const SizedBox(width: 12));
    children.add(Expanded(child: tiles[i]));
  }
  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: children);
}

String fmtUptime(int s) {
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
  return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
}

// Bytes/sec → a compact human rate (e.g. "0 B/s", "812 KB/s", "3.4 MB/s").
String fmtRate(double bytesPerSec) {
  final b = bytesPerSec;
  if (b < 1024) return '${b.round()} B/s';
  if (b < 1024 * 1024) return '${(b / 1024).round()} KB/s';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

// Log-tail refresh gate: the native log rings are capped, so once full their
// LENGTH never changes while their content keeps shifting — a length-only
// gate would freeze the displayed tail on the snapshot taken when the ring
// filled. Compare content instead (used by the instance Logs tab and the
// engine Logs tab alike).
bool linesEqual(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// DDB Engine tile label: "runtime · product" (mirrors the config dropdown
// labels, so the tile says both how it runs and which backend, e.g.
// "Docker · LocalStack"). Also the fit reference shared by every info tile so
// all values render at one identical, width-adaptive size.
String ddbEngineLabel(String engine) => switch (engine) {
      'docker' => 'Docker · dynamodb-local',
      'localstack' => 'Docker · LocalStack',
      _ => 'Java · local',
    };

class SparkTile extends StatelessWidget {
  final String label;
  final String value;
  final List<double> data;
  final Color color;
  final double? width; // null = fill the parent (e.g. inside Expanded)
  final double sparkHeight;
  const SparkTile(
      {super.key,
      required this.label,
      required this.value,
      required this.data,
      required this.color,
      this.width = 220,
      this.sparkHeight = 26});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: _tileColor(context),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, color: _tileLabelColor(context))),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        SizedBox(
          height: sparkHeight,
          width: double.infinity,
          // Snapshot copy: the histories feeding the tiles are mutated IN
          // PLACE by the poll loop (add + removeAt(0) at the 90-sample cap),
          // so a painter holding the same list object would compare old==new
          // forever in shouldRepaint and the sparkline would freeze once the
          // cap is reached. Copying makes the old/new comparison by-value.
          child: CustomPaint(painter: _SparklinePainter(List.of(data), color)),
        ),
      ]),
    );
  }
}

class InfoTile extends StatelessWidget {
  final String label;
  final String value;
  // When set, the value is scaled to fit one line via a FittedBox whose width is
  // pinned to this reference string. Every tile of the same width passing the
  // SAME reference scales by the same factor → identical font size, no wrapping,
  // no truncation, no taller tile. Used to keep the two Engine tiles equal.
  final String? fitReference;
  const InfoTile({super.key, required this.label, required this.value, this.fitReference});

  @override
  Widget build(BuildContext context) {
    const valueStyle = TextStyle(fontSize: 17, fontWeight: FontWeight.w500);
    Widget valueWidget;
    if (fitReference == null) {
      valueWidget = Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: valueStyle);
    } else {
      // Stack an invisible copy of the (longer) reference under the value so the
      // FittedBox always scales against the reference's width — both Engine tiles
      // therefore shrink by the exact same factor.
      valueWidget = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Stack(children: [
          Opacity(
            opacity: 0,
            child: Text(fitReference!, maxLines: 1, softWrap: false, style: valueStyle),
          ),
          Text(value, maxLines: 1, softWrap: false, style: valueStyle),
        ]),
      );
    }
    return Container(
      width: 132,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: _tileColor(context),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, color: _tileLabelColor(context))),
        const SizedBox(height: 4),
        Align(alignment: Alignment.centerLeft, child: valueWidget),
      ]),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  _SparklinePainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    var maxV = data.reduce(math.max);
    if (maxV <= 0) maxV = 1;
    final dx = size.width / (data.length - 1);
    final line = Path();
    for (var i = 0; i < data.length; i++) {
      final x = i * dx;
      final y = size.height - (data[i] / maxV).clamp(0.0, 1.0) * size.height;
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
    }
    final area = Path.from(line)
      ..lineTo((data.length - 1) * dx, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.10));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.data.length != data.length ||
      (data.isNotEmpty && old.data.isNotEmpty && old.data.last != data.last);
}
