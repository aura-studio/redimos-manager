// The "Playground" tab — run a small JavaScript (goja) or Go (yaegi) script
// against a running instance's Redis (`redis` host) or an endpoint's DynamoDB
// (`ddb` host), with a `console` for output. Both interpreters are sandboxed in
// the Go core (no fs/net/os beyond the injected host) and cancelled on timeout.
//
// Layout (v1.2 restyle): a toolbar (JS/Go toggle · sample dropdown · Run ·
// backend chip) over a split of a line-numbered, syntax-highlighted editor and a
// structured OUTPUT panel (status line · console · rendered return value).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'code_editor.dart';
import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'playground_samples.dart';
import 'ui_tokens.dart';

class PlaygroundView extends StatefulWidget {
  final NativeCore core;
  final RedimosConfig config;

  /// 'redis' → connect to the running proxy on the config's port; 'ddb' → talk
  /// to the config's DynamoDB backend directly (no proxy needed).
  final String kind;

  /// For kind=='redis' only: the proxy must be up. Ignored for kind=='ddb'.
  final bool running;

  const PlaygroundView({
    super.key,
    required this.core,
    required this.config,
    required this.kind,
    this.running = true,
  });

  @override
  State<PlaygroundView> createState() => _PlaygroundViewState();
}

class _PlaygroundViewState extends State<PlaygroundView>
    with AutomaticKeepAliveClientMixin {
  late final CodeHighlightController _script = CodeHighlightController(lang: 'js');
  final _editorFocus = FocusNode();
  String _lang = 'js'; // 'js' | 'go'
  int? _sampleIdx;
  bool _busy = false;

  List<String> _logs = const [];
  Object? _result;
  bool _hasRun = false;
  String? _error;
  int? _elapsedMs;
  DateTime? _lastRunAt; // for the toolbar's last-run summary

  @override
  bool get wantKeepAlive => true;

  // MidBar endGroup bridge: the screen's primary action must be reachable from
  // the global MidBar CTA (v2.3), same as the toolbar Run button.
  void runScript() => _run();

  List<PlaygroundSample> get _samples => samplesForKind(widget.kind);

  @override
  void dispose() {
    _script.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  void _loadSample(int idx) {
    final s = _samples[idx];
    setState(() {
      _sampleIdx = idx;
      _script.text = (_lang == 'go' ? s.go : s.js).trim();
    });
  }

  void _setLang(String lang) {
    setState(() {
      _lang = lang;
      _script.lang = lang;
      final i = _sampleIdx;
      if (i != null) {
        final s = _samples[i];
        final other = (lang == 'go' ? s.js : s.go).trim();
        if (_script.text.trim() == other) {
          _script.text = (lang == 'go' ? s.go : s.js).trim();
        }
      }
    });
  }

  Future<void> _run() async {
    final script = _script.text.trim();
    if (script.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _hasRun = true;
      _error = null;
      _logs = const [];
      _result = null;
      _elapsedMs = null;
    });
    final c = widget.config;
    final res = await widget.core.playgroundRun(
      kind: widget.kind,
      lang: _lang,
      script: script,
      port: c.port,
      auth: c.requirepass,
      config: c,
      timeoutMs: 8000,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastRunAt = DateTime.now();
      _logs =
          ((res['logs'] as List?) ?? const []).map((e) => e.toString()).toList();
      _elapsedMs = (res['elapsedMs'] as num?)?.toInt();
      if (res['ok'] == true) {
        _result = res['result'];
        _error = null;
      } else {
        _error = res['error']?.toString() ?? 'run failed';
      }
    });
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.kind == 'redis' && !widget.running) {
      return _center(Icons.play_circle_outline, tr('pg.instanceNotRunning'),
          tr('pg.instanceNotRunningSub'));
    }
    final t = AppTokens.of(context);
    return Column(children: [
      _toolbar(t),
      Divider(height: 1, color: t.hairline),
      // Mockup .play-wrap: a VERTICAL split — editor (flex 55) over output
      // (flex 45) with a 1px border between, not a side-by-side Row.
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            flex: 55,
            child: CodeField(
              controller: _script,
              focusNode: _editorFocus,
              onChanged: (_) => setState(() {}),
              hintText: _lang == 'go'
                  ? '// ${widget.kind == 'redis' ? 'redis.Scan' : 'ddb.ScanAll'}(...) · console.Log(...)'
                  : '// ${widget.kind == 'redis' ? 'redis.scan' : 'ddb.scanAll'}(...) · console.log(...)',
            ),
          ),
          Container(height: 1, color: t.border),
          Expanded(flex: 45, child: _outputPanel(t)),
        ]),
      ),
    ]);
  }

  // ---- toolbar ----

  // Mockup .play-toolbar: 44px, panel bg, hairline bottom border.
  Widget _toolbar(AppTokens t) {
    return Container(
      height: Dim.midBarH, // 44
      color: t.panel,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        _langSeg(t),
        const SizedBox(width: 12),
        _sampleButton(t),
        const Spacer(),
        // Last-run summary (v2.3), right of the samples menu. Mockup .run-status.
        if (_lastRunAt != null && !_busy) ...[
          _lastRunSummary(t),
          const SizedBox(width: 12),
        ],
        _runButton(t),
      ]),
    );
  }

  // Mockup .run-status: a status dot + "上次运行 <time> · <elapsed>" in mono
  // (e.g. "● 上次运行 08:12:44 · 128 ms"; the dot and glyph flip on failure).
  Widget _lastRunSummary(AppTokens t) {
    final at = _lastRunAt!;
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final ss = at.second.toString().padLeft(2, '0');
    final failed = _error != null;
    final parts = <String>['$hh:$mm:$ss'];
    if (!failed) {
      final r = _result;
      if (r is List) parts.add('${r.length} ${tr('pg.rowsUnit')}');
      if (r is Map) parts.add('${r.length} ${tr('pg.rowsUnit')}');
    }
    if (_elapsedMs != null) parts.add('${_elapsedMs}ms');
    final color = failed ? t.danger : t.text3;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: failed ? t.danger : t.success, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text('上次运行 ${parts.join(' · ')}',
          style: Ts.style(
              size: Ts.sm, color: color, monoFont: true, tabularNums: true)),
    ]);
  }

  // Mockup .lang-seg: a 28px inline segmented control — a 1px-bordered rounded
  // box, the two halves separated by a right border (no pill), the active half
  // filled accent with on-accent text (12px/600), the inactive half text-3.
  Widget _langSeg(AppTokens t) {
    Widget seg(String value, String label, {required bool last}) {
      final on = _lang == value;
      return InkWell(
        onTap: on ? null : () => _setLang(value),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: on ? t.accent : Colors.transparent,
            border: last ? null : Border(right: BorderSide(color: t.border)),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: Ts.style(
                  size: Ts.md, // 12
                  weight: FontWeight.w600,
                  color: on ? t.onAccent : t.text3)),
        ),
      );
    }

    return Container(
      height: 28,
      decoration: BoxDecoration(
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(Dim.radiusS),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('js', 'JS', last: false),
        seg('go', 'Go', last: true),
      ]),
    );
  }

  Widget _sampleButton(AppTokens t) {
    final catKey = widget.kind == 'redis' ? 'pg.catRedis' : 'pg.catDdb';
    return PopupMenuButton<int>(
      tooltip: tr('pg.samplesMenu'),
      position: PopupMenuPosition.under,
      onSelected: _loadSample,
      constraints: const BoxConstraints(minWidth: 300, maxWidth: 340),
      itemBuilder: (_) => [
        PopupMenuItem<int>(
          enabled: false,
          height: 30,
          child: Text(tr(catKey),
              style: Ts.style(
                  size: Ts.xs, letterSpacing: 1.2, weight: FontWeight.w700, color: t.text3)),
        ),
        for (var i = 0; i < _samples.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                margin: const EdgeInsets.only(top: 5, right: 10),
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr(_samples[i].titleKey),
                      style: Ts.style(size: Ts.xl, weight: FontWeight.w600, color: t.text)),
                  const SizedBox(height: 2),
                  Text(tr(_samples[i].descKey),
                      style: Ts.style(size: Ts.xs, color: t.text3)),
                ]),
              ),
            ]),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: t.panel2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('pg.samplesMenu'), style: Ts.style(size: Ts.lg, color: t.text2)),
          const SizedBox(width: 6),
          Icon(Icons.expand_more, size: 16, color: t.text3),
        ]),
      ),
    );
  }

  // v2.3 primary CTA: dark theme flips to a white fill + near-black text (same
  // grammar as the MidBar endGroup CTA in main.dart).
  Widget _runButton(AppTokens t) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFFF5F7FB) : t.accent;
    final fg = dark ? const Color(0xFF10142E) : t.onAccent;
    return SizedBox(
      // Mockup .pbtn: 32px tall, radius-sm 6, 14px horizontal padding.
      height: 32,
      child: FilledButton.icon(
        onPressed: _script.text.trim().isEmpty || _busy ? null : _run,
        icon: _busy
            ? SizedBox(
                width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
            : Icon(Icons.play_arrow, size: 16, color: fg),
        label: Text(tr('pg.run'),
            style: Ts.style(size: Ts.md, weight: FontWeight.w600)),
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Dim.radiusS)),
        ),
      ),
    );
  }

  // ---- output panel ----

  // Mockup .output: panel bg with a two-tone .output-head band (panel-2 +
  // hairline bottom border) carrying an eyebrow title + a done-chip status.
  Widget _outputPanel(AppTokens t) {
    return Container(
      color: t.panel,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          decoration: BoxDecoration(
            color: t.panel2,
            border: Border(bottom: BorderSide(color: t.hairline)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [
            // Mockup .op-title: 11px/600 uppercase, .8px tracking, text-3.
            Text(tr('pg.output').toUpperCase(),
                style: Ts.style(
                    size: Ts.xs, letterSpacing: 0.8, weight: FontWeight.w600, color: t.text3)),
            const SizedBox(width: 10),
            if (_hasRun && !_busy) _statusChip(t),
            const Spacer(),
            if (_hasRun && !_busy)
              _outputIcon(t, Icons.copy_outlined, tr('br.copy'), _copyOutput),
          ]),
        ),
        Expanded(
          child: !_hasRun
              ? _center(Icons.play_circle_outline, '', tr('pg.emptyOutput'))
              // Mockup .output-body: mono 12px log-rows.
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (var i = 0; i < _logs.length; i++) _logRow(i, _logs[i], t),
                    if (_error != null) _errorBox(t),
                    if (_error == null && _result != null) ...[
                      if (_logs.isNotEmpty) const SizedBox(height: 10),
                      _resultWidget(_result, t),
                      const SizedBox(height: 10),
                      _doneFooter(t),
                    ],
                    // _run clears logs/result/error before awaiting, so without
                    // this the empty-output branch below would paint "✓ done"
                    // for the whole 8s timeout window, while the run is still in
                    // flight. The header chip already gates on !_busy.
                    if (_busy)
                      _runningRow(t)
                    else if (_error == null && _result == null && _logs.isEmpty)
                      _doneFooter(t),
                  ]),
                ),
        ),
      ]),
    );
  }

  Widget _outputIcon(AppTokens t, IconData icon, String tooltip, VoidCallback onTap) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      icon: Icon(icon, size: 15, color: t.text3),
      onPressed: onTap,
    );
  }

  void _copyOutput() {
    final sb = StringBuffer();
    for (final l in _logs) {
      sb.writeln(l);
    }
    if (_error != null) {
      sb.writeln(_error);
    } else if (_result != null) {
      try {
        sb.write(const JsonEncoder.withIndent('  ').convert(_result));
      } catch (_) {
        sb.write('$_result');
      }
    }
    Clipboard.setData(ClipboardData(text: sb.toString().trimRight()));
  }

  Widget _statusChip(AppTokens t) {
    final failed = _error != null;
    final color = failed ? t.danger : t.success;
    final parts = <String>[failed ? tr('pg.errored') : tr('pg.ran')];
    if (!failed) {
      // Count what was RETURNED, in container-neutral units. "keys"/"items" would
      // name the backend's own nouns, and a script's return value has no such
      // relationship to it: an aggregate over 5000 Redis keys returns 12 rows.
      final r = _result;
      if (r is List) {
        parts.add('${r.length} ${tr('pg.rowsUnit')}');
      } else if (r is Map) {
        parts.add('${r.length} ${tr('pg.rowsUnit')}');
      }
    }
    if (_elapsedMs != null) parts.add('${_elapsedMs}ms');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(parts.join('  ·  '),
            style: Ts.style(
                size: Ts.xs, weight: FontWeight.w700, color: color, monoFont: true, tabularNums: true)),
      ]),
    );
  }

  // Mockup .output-body .log-row: a right-aligned 20px line index (text-3) +
  // the line text (text-2), 10px gap, 2px vertical padding, mono 12px.
  Widget _logRow(int i, String line, AppTokens t) {
    final isErr = line.startsWith('ERROR:');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 20,
          child: Text('${i + 1}',
              textAlign: TextAlign.right,
              style: Ts.style(size: Ts.md, color: t.text3, monoFont: true, height: 1.4)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SelectableText(line,
              style: Ts.style(
                  size: Ts.md,
                  height: 1.4,
                  monoFont: true,
                  color: isErr ? t.danger : t.text2)),
        ),
      ]),
    );
  }

  Widget _runningRow(AppTokens t) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
          width: 11,
          height: 11,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: t.text3)),
      const SizedBox(width: 8),
      Text(tr('pg.running'),
          style: Ts.style(size: Ts.md, monoFont: true, color: t.text3)),
    ]);
  }

  Widget _doneFooter(AppTokens t) {
    final rows = _result is List
        ? (_result as List).length
        : (_result is Map ? (_result as Map).length : null);
    final txt = rows != null
        ? '✓ ${tr('pg.doneRows')} · $rows ${tr('pg.rowsUnit')}'
        : '✓ ${tr('pg.doneRows')}';
    return Text(txt,
        style: Ts.style(size: Ts.md, monoFont: true, color: t.success, tabularNums: true));
  }

  Widget _errorBox(AppTokens t) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.danger.withValues(alpha: 0.6)),
        color: t.danger.withValues(alpha: 0.08),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.error_outline, color: t.danger, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(_error!,
              style: Ts.style(size: Ts.lg, monoFont: true, color: t.text)),
        ),
      ]),
    );
  }

  // ---- result rendering ----

  Widget _resultWidget(Object? r, AppTokens t) {
    // Mockup has no bordered result table — the return value is rendered as
    // more .log-row lines in the same mono output body. Flatten whatever came
    // back to a compact per-row form (array of objects → one row per object,
    // plain object → one row per key, fallback → pretty-JSON lines).
    final lines = <String>[];
    if (r is List) {
      for (final e in r) {
        lines.add(_compactJson(e));
      }
    } else if (r is Map) {
      for (final e in r.entries) {
        lines.add('${e.key}: ${_compactJson(e.value)}');
      }
    } else {
      String pretty;
      try {
        pretty = const JsonEncoder.withIndent('  ').convert(r);
      } catch (_) {
        pretty = '$r';
      }
      lines.addAll(pretty.split('\n'));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < lines.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 20,
              child: Text('${i + 1}',
                  textAlign: TextAlign.right,
                  style: Ts.style(size: Ts.md, color: t.text3, monoFont: true, height: 1.4)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SelectableText(lines[i],
                  style: Ts.style(size: Ts.md, height: 1.4, monoFont: true, color: t.text2)),
            ),
          ]),
        ),
    ]);
  }

  // Compact one-line form for a result cell: scalars as-is, containers as
  // single-line JSON, null as an em-dash (matching the rest of the output).
  String _compactJson(dynamic v) {
    if (v == null) return '—';
    if (v is num || v is bool) return '$v';
    if (v is String) return v;
    try {
      return jsonEncode(v);
    } catch (_) {
      return '$v';
    }
  }

  Widget _center(IconData icon, String title, String subtitle) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 36, color: Colors.grey),
            if (title.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontSize: 14)),
            ],
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
      );
}
