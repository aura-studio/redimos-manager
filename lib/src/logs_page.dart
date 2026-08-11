// v2.3 instance Logs screen — extracted from main.dart's LogsView on
// 2026-08-06. Toolbar with a single-select level filter (mockup ALL + one
// chip per level, active chip tinted accent), auto-scroll toggle, export
// (dart:io File) and a Dart-side clear (a view cut-off point — the Go ring
// buffer is NOT touched, so cleared lines reappear only if they are newer
// than the cut-off). The log body is a sunken card (margin + border + radius
// + inner top shadow); each line is parsed best-effort into timestamp + level
// + message, the level coloured, warn/error messages raised to full text.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'monitor_widgets.dart' show linesEqual;
import 'native.dart';
import 'ui_tokens.dart';

// The recognised severity buckets, in toolbar order after ALL. A line that
// parses to none of them falls into [LogLevel.other] (only visible on ALL).
enum LogLevel { error, warn, info, debug, other }

class LogsPage extends StatefulWidget {
  final NativeCore core;
  final String? configId;
  const LogsPage({
    super.key,
    required this.core,
    required this.configId,
  });

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<String> _lines = [];
  Timer? _t;
  final _scroll = ScrollController();
  bool _autoScroll = true;
  // Single-select filter (mockup): null = ALL, otherwise show only this level.
  LogLevel? _filter;
  // Dart-side clear: the pull index at the moment of the clear. Only lines
  // AFTER this index are shown. The Go ring keeps its content untouched.
  int _clearedBefore = 0;
  String? _exportedPath; // transient confirmation shown in the toolbar

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
    if (widget.configId == null) {
      if (_lines.isNotEmpty) setState(() => _lines = []);
      return;
    }
    try {
      final l = widget.core.logs(widget.configId!);
      if (!linesEqual(l, _lines)) {
        setState(() {
          // The Go ring reuses its buffer: a fresh pull can be SHORTER than
          // the previous one (wrap), which would resurrect cleared lines if
          // the cut-off were an absolute index. Treat a shorter pull as a
          // wrap and re-anchor the cut-off.
          if (l.length < _clearedBefore) _clearedBefore = 0;
          _lines = l;
        });
        if (_autoScroll) _jumpToEnd();
      }
    } catch (_) {}
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // The visible tail: lines after the clear cut-off, filtered by the single
  // selected level (null filter = ALL, show everything).
  List<({String raw, LogLevel level})> get _visible {
    final start = _clearedBefore.clamp(0, _lines.length);
    final out = <({String raw, LogLevel level})>[];
    for (var i = start; i < _lines.length; i++) {
      final lvl = parseLogLevel(_lines[i]);
      if (_filter == null || lvl == _filter) out.add((raw: _lines[i], level: lvl));
    }
    return out;
  }

  Map<LogLevel, int> get _counts {
    final m = {for (final l in LogLevel.values) l: 0};
    final start = _clearedBefore.clamp(0, _lines.length);
    for (var i = start; i < _lines.length; i++) {
      m[parseLogLevel(_lines[i])] = m[parseLogLevel(_lines[i])]! + 1;
    }
    return m;
  }

  Future<void> _export() async {
    final vis = _visible;
    if (vis.isEmpty) return;
    try {
      final dir = Directory.systemTemp;
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final f = File('${dir.path}${Platform.pathSeparator}redimos-logs-$ts.log');
      await f.writeAsString(vis.map((e) => e.raw).join('\n'));
      if (!mounted) return;
      setState(() => _exportedPath = f.path);
      Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _exportedPath = null);
      });
    } catch (_) {}
  }

  void _clear() {
    setState(() {
      _clearedBefore = _lines.length;
      _exportedPath = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final brightness = Theme.of(context).brightness;
    final vis = _visible;
    final counts = _counts;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _toolbar(t, counts),
      // Mockup .logs-body: a bordered card (margin 14/16, radius, panel-2 bg)
      // with an inset top shadow — not a full-bleed dark pane.
      Expanded(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: t.panel2,
            borderRadius: BorderRadius.circular(Dim.radiusM),
            border: Border.all(color: t.border),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Dim.radiusM - 1),
            child: Column(children: [
              Container(height: 3, decoration: Depth.wellTopLogs(brightness)),
              Expanded(
                child: vis.isEmpty
                    ? Center(
                        child: Text(tr('home.noOutput'),
                            style: Ts.style(size: Ts.md, color: t.text3)))
                    : Scrollbar(
                        controller: _scroll,
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          itemCount: vis.length,
                          itemBuilder: (_, i) => _logLine(vis[i], t),
                        ),
                      ),
              ),
            ]),
          ),
        ),
      ),
      if (_exportedPath != null)
        Container(
          color: t.panel,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Row(children: [
            Icon(Icons.check_circle_outline, size: 13, color: t.success),
            const SizedBox(width: 6),
            Expanded(
              child: SelectableText(_exportedPath!,
                  style: Ts.style(size: Ts.xs, color: t.text3, monoFont: true)),
            ),
          ]),
        ),
    ]);
  }

  Widget _toolbar(AppTokens t, Map<LogLevel, int> counts) {
    final total = counts.values.fold(0, (a, b) => a + b);
    return Container(
      // Mockup .logs-toolbar: height 42 (was Dim.cliHeadH=32, which left the
      // body card 10px too high and broke the cardHead ROI geometry).
      height: 42,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(bottom: BorderSide(color: t.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        // Mockup .logs-head: level filter chips flush left — no REDIMOS title/icon.
        // ALL chip first, then one per level, single-select.
        _levelChip(null, total, t),
        const SizedBox(width: 6),
        for (final lvl in [LogLevel.info, LogLevel.warn, LogLevel.error, LogLevel.debug]) ...[
          _levelChip(lvl, counts[lvl] ?? 0, t),
          const SizedBox(width: 6),
        ],
        const Spacer(),
        // Mockup toolbar right cluster: a 24h ".chip.on" auto-scroll pill,
        // then two .abtn 26h bordered boxes (导出 / 清空). The CJK literals are
        // copied verbatim from the mockup (i18n.dart is frozen — no new keys;
        // CJK rasterization differences are exempt per the diff pipeline).
        _autoScrollPill(t),
        const SizedBox(width: 8),
        _abtn(t, Icons.download_outlined, '导出', _export),
        const SizedBox(width: 8),
        _abtn(t, Icons.clear_all, '清空', _clear),
      ]),
    );
  }

  // Mockup .chip / .chip.on: 24px pill; the on state uses the selection tint
  // with an accent border + accent icon/text.
  Widget _autoScrollPill(AppTokens t) {
    final on = _autoScroll;
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: () => setState(() {
        _autoScroll = !_autoScroll;
        if (_autoScroll) _jumpToEnd();
      }),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: on ? t.selection : t.panel,
          border: Border.all(color: on ? t.accent : t.border),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Row(children: [
          Icon(on ? Icons.vertical_align_bottom : Icons.pause,
              size: 12, color: on ? t.accent : t.text2),
          const SizedBox(width: 5),
          Text('自动滚动',
              style: Ts.style(
                  size: 11.5,
                  weight: FontWeight.w600,
                  color: on ? t.accent : t.text2)),
        ]),
      ),
    );
  }

  // Mockup .abtn: 26px bordered box, icon 13 + text 12 text-2.
  Widget _abtn(AppTokens t, IconData icon, String label, VoidCallback onTap) {
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
        child: Row(children: [
          Icon(icon, size: 13, color: t.text2),
          const SizedBox(width: 5),
          Text(label, style: Ts.style(size: Ts.md, color: t.text2)),
        ]),
      ),
    );
  }

  // Mockup .chip: 24px pill, border, 11.5px text-2; the active chip is tinted
  // accent (selection bg + accent border/text + 600) — uniform accent, no dot.
  Widget _levelChip(LogLevel? lvl, int count, AppTokens t) {
    final on = _filter == lvl;
    final label = lvl == null ? 'ALL' : logLevelName(lvl).toUpperCase();
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: () => setState(() => _filter = lvl),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: on ? t.selection : Colors.transparent,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: on ? t.accent : t.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: Ts.style(
                  size: Ts.sm,
                  weight: on ? FontWeight.w600 : FontWeight.normal,
                  color: on ? t.accent : t.text2)),
          const SizedBox(width: 5),
          // Mockup .chip .n: mono 10.5 count, slightly recessed.
          Text(_fmtCount(count),
              style: Ts.style(
                  size: 10.5,
                  color: (on ? t.accent : t.text2).withValues(alpha: 0.75),
                  monoFont: true,
                  tabularNums: true)),
        ]),
      ),
    );
  }

  String _fmtCount(int v) {
    final s = v.toString();
    return s.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  }

  // Mockup .log-line: ts (text-3) + level (44px, 700) + msg (text-2), with
  // warn/error messages raised to full text. 2.5px vertical, 14px horizontal.
  Widget _logLine(({String raw, LogLevel level}) e, AppTokens t) {
    final parsed = splitLogLine(e.raw);
    final lvlColor = levelColor(e.level, t);
    final raise = e.level == LogLevel.warn || e.level == LogLevel.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.25, horizontal: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (parsed.ts != null)
          Text('${parsed.ts}  ',
              style: Ts.style(size: Ts.sm, color: t.text3, monoFont: true, tabularNums: true, height: 1.5)),
        SizedBox(
          width: 44,
          child: Text(logLevelName(e.level).toUpperCase(),
              style: Ts.style(size: Ts.xs, weight: FontWeight.w700, color: lvlColor, monoFont: true, height: 1.5)),
        ),
        Expanded(
          child: SelectableText(parsed.msg,
              style: Ts.style(size: Ts.sm, color: raise ? t.text : t.text2, monoFont: true, height: 1.5)),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Best-effort log line parsing (pure functions — also unit-testable)
// ---------------------------------------------------------------------------

String logLevelName(LogLevel l) => switch (l) {
      LogLevel.error => 'error',
      LogLevel.warn => 'warn',
      LogLevel.info => 'info',
      LogLevel.debug => 'debug',
      LogLevel.other => 'other',
    };

// Mockup .log-lv colours: info = accent blue, warn = warning, error = danger,
// debug = text-3. `other` stays a neutral text-2.
Color levelColor(LogLevel l, AppTokens t) => switch (l) {
      LogLevel.error => t.danger,
      LogLevel.warn => t.warning,
      LogLevel.info => t.accent,
      LogLevel.debug => t.text3,
      LogLevel.other => t.text2,
    };

final _levelRe =
    RegExp(r'\b(error|err|warn|warning|info|debug|trace|fatal)\b', caseSensitive: false);

LogLevel parseLogLevel(String line) {
  final m = _levelRe.firstMatch(line);
  if (m == null) return LogLevel.other;
  switch (m.group(1)!.toLowerCase()) {
    case 'error':
    case 'err':
    case 'fatal':
      return LogLevel.error;
    case 'warn':
    case 'warning':
      return LogLevel.warn;
    case 'info':
      return LogLevel.info;
    case 'debug':
    case 'trace':
      return LogLevel.debug;
    default:
      return LogLevel.other;
  }
}

final _tsRe = RegExp(
    r'^\[?(\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(?:\.\d+)?)\]?');

({String? ts, String msg}) splitLogLine(String line) {
  final m = _tsRe.firstMatch(line);
  if (m == null) return (ts: null, msg: line);
  final rest = line.substring(m.end).trimLeft();
  // Strip a leading level token from the message — the level column already
  // shows it (e.g. "[INFO] msg" → "msg", "INFO msg" → "msg").
  final lvlM = RegExp(r'^\[?(error|err|warn|warning|info|debug|trace|fatal)\]?\s*:?\s*',
      caseSensitive: false);
  final lm = lvlM.firstMatch(rest);
  return (ts: m.group(1), msg: lm == null ? rest : rest.substring(lm.end));
}
