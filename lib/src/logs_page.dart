// Instance Logs screen. The Codex surface layer is intentionally kept separate
// from the native log lifecycle: polling, filtering, clear cut-off, export, and
// auto-scroll continue to operate on the same Go ring snapshots.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'monitor_widgets.dart' show linesEqual;
import 'native.dart';
import 'ui_primitives.dart';
import 'ui_states.dart';
import 'ui_surfaces.dart';
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

class _LogsPageState extends State<LogsPage>
    with AutomaticKeepAliveClientMixin {
  List<String> _lines = [];
  Timer? _t;
  Timer? _exportTimer;
  final _scroll = ScrollController();
  bool _autoScroll = true;
  LogLevel? _filter;
  // Dart-side clear: the pull index at the moment of the clear. Only lines
  // AFTER this index are shown. The Go ring keeps its content untouched.
  int _clearedBefore = 0;
  String? _exportedPath;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _pull();
    _t = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pull());
  }

  @override
  void didUpdateWidget(LogsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configId != widget.configId) {
      _exportTimer?.cancel();
      _exportTimer = null;
      _lines = [];
      _filter = null;
      _clearedBefore = 0;
      _exportedPath = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _pull();
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    _exportTimer?.cancel();
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
          // A wrapped native ring can be shorter than the prior snapshot.
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

  List<({String raw, LogLevel level})> get _visible {
    final start = _clearedBefore.clamp(0, _lines.length);
    final out = <({String raw, LogLevel level})>[];
    for (var i = start; i < _lines.length; i++) {
      final lvl = parseLogLevel(_lines[i]);
      if (_filter == null || lvl == _filter) {
        out.add((raw: _lines[i], level: lvl));
      }
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
    final configId = widget.configId;
    try {
      final dir = Directory.systemTemp;
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final f =
          File('${dir.path}${Platform.pathSeparator}redimos-logs-$ts.log');
      await f.writeAsString(vis.map((e) => e.raw).join('\n'));
      if (!mounted || widget.configId != configId) return;
      _exportTimer?.cancel();
      setState(() => _exportedPath = f.path);
      _exportTimer = Timer(const Duration(seconds: 6), () {
        _exportTimer = null;
        if (mounted && widget.configId == configId) {
          setState(() => _exportedPath = null);
        }
      });
    } catch (_) {}
  }

  void _clear() {
    _exportTimer?.cancel();
    _exportTimer = null;
    setState(() {
      _clearedBefore = _lines.length;
      _exportedPath = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final t = AppTokens.of(context);
    final vis = _visible;
    final counts = _counts;

    return ColoredBox(
      color: t.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(t, counts),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CodexStateShell(
                    key: const ValueKey('logs-state-shell'),
                    state: vis.isEmpty
                        ? CodexContentState.empty
                        : CodexContentState.content,
                    message: tr('home.noOutput'),
                    icon: const Icon(Icons.subject_outlined, size: 22),
                    bodyPadding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 24,
                    ),
                    content: CodexSurface(
                      variant: CodexSurfaceVariant.sunken,
                      padding: EdgeInsets.zero,
                      child: ListView.builder(
                        key: const ValueKey('logs-list'),
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        itemCount: vis.length,
                        itemBuilder: (_, i) => _logLine(vis[i], t),
                      ),
                    ),
                  ),
                  if (_exportedPath != null)
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: _exportConfirmation(t),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(AppTokens t, Map<LogLevel, int> counts) {
    final total = counts.values.fold(0, (a, b) => a + b);
    return SizedBox(
      height: 42,
      child: ColoredBox(
        color: t.panel,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _levelChip(null, total, t),
                    const SizedBox(width: 6),
                    for (final lvl in [
                      LogLevel.info,
                      LogLevel.warn,
                      LogLevel.error,
                      LogLevel.debug,
                    ]) ...[
                      _levelChip(lvl, counts[lvl] ?? 0, t),
                      const SizedBox(width: 6),
                    ],
                    const Spacer(),
                    CodexButton(
                      key: const ValueKey('logs-auto-scroll'),
                      variant: _autoScroll
                          ? CodexButtonVariant.primary
                          : CodexButtonVariant.secondary,
                      onPressed: () => setState(() {
                        _autoScroll = !_autoScroll;
                        if (_autoScroll) _jumpToEnd();
                      }),
                      icon: Icon(
                        _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                        size: 14,
                      ),
                      label: const Text('自动滚动'),
                    ),
                    const SizedBox(width: 8),
                    CodexButton(
                      key: const ValueKey('logs-export'),
                      onPressed: _export,
                      icon: const Icon(Icons.download_outlined, size: 14),
                      label: const Text('导出'),
                    ),
                    const SizedBox(width: 8),
                    CodexButton(
                      key: const ValueKey('logs-clear'),
                      onPressed: _clear,
                      icon: const Icon(Icons.clear_all, size: 14),
                      label: const Text('清空'),
                    ),
                  ],
                ),
              ),
            ),
            const CodexDivider(),
          ],
        ),
      ),
    );
  }

  Widget _exportConfirmation(AppTokens t) => CodexSurface(
        variant: CodexSurfaceVariant.elevated,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 14, color: t.success),
            const SizedBox(width: 7),
            Expanded(
              child: SelectableText(
                _exportedPath!,
                maxLines: 1,
                style: Ts.style(
                  size: Ts.xs,
                  color: t.text2,
                  monoFont: true,
                ),
              ),
            ),
          ],
        ),
      );

  // There is no domain-free shared chip primitive; keep the fixed 24px filter
  // footprint while using shared semantic paint and accessible selected state.
  Widget _levelChip(LogLevel? lvl, int count, AppTokens t) {
    final on = _filter == lvl;
    final label = lvl == null ? 'ALL' : logLevelName(lvl).toUpperCase();
    return Semantics(
      button: true,
      selected: on,
      label: '$label ${_fmtCount(count)}',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: Ts.style(
                    size: Ts.sm,
                    weight: on ? FontWeight.w600 : FontWeight.normal,
                    color: on ? t.accent : t.text2,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _fmtCount(count),
                  style: Ts.style(
                    size: 10.5,
                    color: (on ? t.accent : t.text2).withValues(alpha: 0.75),
                    monoFont: true,
                    tabularNums: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmtCount(int v) {
    final s = v.toString();
    return s.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  }

  Widget _logLine(({String raw, LogLevel level}) e, AppTokens t) {
    final parsed = splitLogLine(e.raw);
    final lvlColor = levelColor(e.level, t);
    final raise = e.level == LogLevel.warn || e.level == LogLevel.error;
    return Semantics(
      container: true,
      label: '${logLevelName(e.level)} ${parsed.msg}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.25, horizontal: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (parsed.ts != null)
              ExcludeSemantics(
                child: Text(
                  '${parsed.ts}  ',
                  style: Ts.style(
                    size: Ts.sm,
                    color: t.text3,
                    monoFont: true,
                    tabularNums: true,
                    height: 1.5,
                  ),
                ),
              ),
            SizedBox(
              width: 44,
              child: ExcludeSemantics(
                child: Text(
                  logLevelName(e.level).toUpperCase(),
                  style: Ts.style(
                    size: Ts.xs,
                    weight: FontWeight.w700,
                    color: lvlColor,
                    monoFont: true,
                    height: 1.5,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ExcludeSemantics(
                child: SelectableText(
                  parsed.msg,
                  style: Ts.style(
                    size: Ts.sm,
                    color: raise ? t.text : t.text2,
                    monoFont: true,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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

// Warning/error are operational states. Informational and diagnostic levels
// stay neutral instead of borrowing the brand accent.
Color levelColor(LogLevel l, AppTokens t) => switch (l) {
      LogLevel.error => t.danger,
      LogLevel.warn => t.warning,
      LogLevel.info => t.text2,
      LogLevel.debug => t.text3,
      LogLevel.other => t.text3,
    };

final _levelRe = RegExp(r'\b(error|err|warn|warning|info|debug|trace|fatal)\b',
    caseSensitive: false);

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
  final lvlM = RegExp(
      r'^\[?(error|err|warn|warning|info|debug|trace|fatal)\]?\s*:?\s*',
      caseSensitive: false);
  final lm = lvlM.firstMatch(rest);
  return (ts: m.group(1), msg: lm == null ? rest : rest.substring(lm.end));
}
