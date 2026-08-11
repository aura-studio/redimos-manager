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

import 'ui_tokens.dart';

// The "running / start" green lives in ui_tokens.dart (goGreen) — it is only
// used by the sidebar LocalDdbPanel, not by the dashboard grammar.

// v2.3 tile chrome (mockup .spark-tile/.info-tile): panel fill, 1px border,
// 8px radius, elev-2 drop shadow + a hairline top highlight. Flutter has no
// inset shadow, so the top inner highlight is faked by a 1px top border of the
// highlight colour stacked above the real border.
BoxDecoration tileDecoration(BuildContext context) {
  final t = AppTokens.of(context);
  final brightness = Theme.of(context).brightness;
  return BoxDecoration(
    color: t.panel,
    borderRadius: BorderRadius.circular(Dim.radiusM),
    border: Border.all(color: t.border),
    boxShadow: Depth.elev2(brightness),
  );
}

// The 1px top inner-highlight strip a tile paints over its own top border.
// Wrap a tile's child with this (Positioned at the top, inside the tile).
Widget topHighlightStrip(BuildContext context) {
  final t = AppTokens.of(context);
  return Positioned(
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
  );
}

// A section eyebrow: label on the left, a hairline rule stretching to
// the right edge (mockup .section-head::after), an optional badge right-aligned.
// The mockup's section-head has NO leading icon; the `icon` argument is kept
// only so existing call sites still compile — it is not rendered.
Widget sectionHeader(BuildContext context, IconData icon, String label,
    {String? badge}) {
  final t = AppTokens.of(context);
  return Row(children: [
    Text(label,
        style: Ts.style(
            size: Ts.xs,
            letterSpacing: 1.3,
            weight: FontWeight.w700,
            color: t.text3)),
    const SizedBox(width: 10),
    Expanded(child: Container(height: 1, color: t.hairline)),
    if (badge != null) ...[
      const SizedBox(width: 10),
      Text(badge, style: Ts.style(size: Ts.xs, color: t.text3)),
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

// Mockup .tile-grid: a 4-column grid with 12px gutters, wrapping into rows of
// four (8 tiles → 2 rows of 4). Each cell stretches to equal width.
Widget tileGrid(List<Widget> tiles) {
  const cols = 4;
  const gap = 12.0;
  final rows = <Widget>[];
  for (var r = 0; r < tiles.length; r += cols) {
    final chunk = tiles.sublist(r, r + cols > tiles.length ? tiles.length : r + cols);
    final cells = <Widget>[];
    for (var i = 0; i < cols; i++) {
      if (i > 0) cells.add(const SizedBox(width: gap));
      cells.add(Expanded(child: i < chunk.length ? chunk[i] : const SizedBox()));
    }
    rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells));
    rows.add(const SizedBox(height: gap));
  }
  if (rows.isNotEmpty) rows.removeLast(); // trailing gutter after the last row
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
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
  // v2.3 footer caption under the sparkline (e.g. "60s window"). Null = hidden.
  final String? footer;
  const SparkTile(
      {super.key,
      required this.label,
      required this.value,
      required this.data,
      required this.color,
      this.width = 220,
      this.sparkHeight = 26,
      this.footer});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    // Mockup .spark-tile: .st-top holds the label (recessed caps) on the left
    // and the big value on the right of the SAME row; the value is the v2.4
    // 20/700 tier, tabular-nums. Then the sparkline, then the foot caption.
    return Stack(children: [
      Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: tileDecoration(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(label.toUpperCase(),
                style: Ts.style(
                    size: Ts.md, weight: FontWeight.normal, color: t.text3)),
            const Spacer(),
            Text(value,
                style: Ts.style(
                    size: 20, weight: FontWeight.w700, color: t.text, tabularNums: true,
                    // Mockup .st-top b is MONO (JetBrains Mono) 20/700
                    // tabular — the v2.4 override only changed size/weight.
                    monoFont: true,
                    // Mockup .st-val line-height 1.2 — keeps the tile's total
                    // height (~129px) in step with the HTML render.
                    height: 1.2)),
          ]),
          const SizedBox(height: 6),
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
          if (footer != null) ...[
            const SizedBox(height: 6),
            Text(footer!,
                style: Ts.style(size: Ts.xs, color: t.text3, tabularNums: true, height: 1.2)),
          ],
        ]),
      ),
      topHighlightStrip(context),
    ]);
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
  // Optional semantic colour for the value (mockup .it-value.ok / .warn).
  final Color? valueColor;
  const InfoTile({super.key, required this.label, required this.value, this.fitReference, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    // Mockup .info-tile .it-value: v2.4 tier 15.5/700 tabular-nums.
    final valueStyle = Ts.style(
        size: Ts.xxl, weight: FontWeight.w700, color: valueColor ?? t.text, tabularNums: true);
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
    return Stack(children: [
      Container(
        // No pinned width: tiles stretch to their grid cell (mockup .info-tile
        // is flex:1 inside .tile-grid). Padding matches .info-tile 11px 14px.
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
        decoration: tileDecoration(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Label eyebrow (mockup .it-label): 11px text-3, .4px tracking, normal
          // weight, title case as authored (no uppercase transform).
          Text(label,
              style: Ts.style(size: Ts.xs, letterSpacing: 0.4, color: t.text3)),
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerLeft, child: valueWidget),
        ]),
      ),
      topHighlightStrip(context),
    ]);
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  _SparklinePainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final maxV = data.reduce(math.max);
    final minV = data.reduce(math.min);
    final span = maxV - minV;
    // Mockup svg.big: the line never touches the box edges — reserve a top
    // headroom and a small bottom inset (pixel-fidelity-v23 CP 9.x probe).
    const topInset = 12.0;
    const botInset = 14.0;
    final innerH = (size.height - topInset - botInset).clamp(0.0, size.height);
    final dx = size.width / (data.length - 1);
    final line = Path();
    for (var i = 0; i < data.length; i++) {
      final x = i * dx;
      final n = span <= 0 ? 0.5 : (data[i] - minV) / span;
      final y = topInset + (1 - n) * innerH;
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
    }
    final area = Path.from(line)
      ..lineTo((data.length - 1) * dx, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.14));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.data.length != data.length ||
      (data.isNotEmpty && old.data.isNotEmpty && old.data.last != data.last);
}
