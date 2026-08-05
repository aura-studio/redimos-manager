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

import 'code_editor.dart';
import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'playground_samples.dart';
import 'ui_theme.dart';

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

  @override
  bool get wantKeepAlive => true;

  List<PlaygroundSample> get _samples => samplesForKind(widget.kind);

  // Mirrors the core's gate exactly — ddbHost.readOnly() is awsModeForEndpoint:
  // the empty endpoint (default AWS resolver) OR an explicit AWS host, creds
  // irrelevant. Anything looser makes the chip claim "writable" for an endpoint
  // the core refuses every write on. Only the ddb host is gated; the redis host
  // writes through the proxy, so kind=='redis' is genuinely writable even when
  // the proxy's own backend is AWS.
  bool get _isReadOnly {
    if (widget.kind != 'ddb') return false;
    final ep = widget.config.endpoint.trim();
    if (ep.isEmpty) return true; // default AWS resolver
    final host = (Uri.tryParse(ep)?.host ?? '').toLowerCase();
    return host == 'amazonaws.com' ||
        host.endsWith('.amazonaws.com') ||
        host.endsWith('.amazonaws.com.cn');
  }

  bool get _writable => !_isReadOnly;

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
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      _toolbar(),
      const Divider(height: 1),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
          Container(width: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          Expanded(flex: 45, child: _outputPanel()),
        ]),
      ),
    ]);
  }

  // ---- toolbar ----

  Widget _toolbar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        _langPill(),
        const SizedBox(width: 12),
        _sampleButton(),
        const SizedBox(width: 12),
        _runButton(),
        const Spacer(),
        // Flexible here, not just inside the chip: a Row hands its non-flex
        // children unbounded main-axis constraints, so the chip would take its
        // full intrinsic width and its internal Flexible/ellipsis could never
        // engage on a long config name in a narrow pane.
        Flexible(child: _backendChip()),
      ]),
    );
  }

  Widget _langPill() {
    final scheme = Theme.of(context).colorScheme;
    Widget seg(String value, String label) {
      final on = _lang == value;
      return InkWell(
        onTap: on ? null : () => _setLang(value),
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: on ? Accents.teal : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: on ? Colors.white : scheme.onSurfaceVariant)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('js', 'JS'),
        seg('go', 'Go'),
      ]),
    );
  }

  Widget _sampleButton() {
    final scheme = Theme.of(context).colorScheme;
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
              style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant)),
        ),
        for (var i = 0; i < _samples.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                margin: const EdgeInsets.only(top: 5, right: 10),
                width: 7,
                height: 7,
                decoration:
                    const BoxDecoration(color: Accents.teal, shape: BoxShape.circle),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr(_samples[i].titleKey),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(tr(_samples[i].descKey),
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('pg.samplesMenu'), style: const TextStyle(fontSize: 12.5)),
          const SizedBox(width: 6),
          Icon(Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
        ]),
      ),
    );
  }

  Widget _runButton() {
    return FilledButton.icon(
      onPressed: _script.text.trim().isEmpty || _busy ? null : _run,
      icon: _busy
          ? const SizedBox(
              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.play_arrow, size: 18),
      label: Text(tr('pg.run')),
      style: FilledButton.styleFrom(
        backgroundColor: Accents.indigo,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }

  Widget _backendChip() {
    final scheme = Theme.of(context).colorScheme;
    final name = widget.config.name.isEmpty
        ? (widget.kind == 'redis' ? ':${widget.config.port}' : tr('pg.hostDdb'))
        : widget.config.name;
    final accent = _writable ? Accents.teal : Accents.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
        color: accent.withValues(alpha: 0.08),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.arrow_forward, size: 13, color: accent),
        const SizedBox(width: 6),
        Text('${tr('pg.backendLabel')} ',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        Flexible(
          child: Text(name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
        ),
        Text('  ·  ', style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        Text(_writable ? tr('pg.writable') : tr('pg.readOnly'),
            style: TextStyle(fontSize: 11.5, color: accent, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  // ---- output panel ----

  Widget _outputPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            Text(tr('pg.output'),
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
            const Spacer(),
            if (_hasRun && !_busy) _statusChip(),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: !_hasRun
              ? _center(Icons.play_circle_outline, '', tr('pg.emptyOutput'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final line in _logs) _consoleLine(line),
                    if (_error != null) _errorBox(),
                    if (_error == null && _result != null) ...[
                      if (_logs.isNotEmpty) const SizedBox(height: 10),
                      _resultWidget(_result),
                      const SizedBox(height: 10),
                      _doneFooter(),
                    ],
                    // _run clears logs/result/error before awaiting, so without
                    // this the empty-output branch below would paint "✓ done"
                    // for the whole 8s timeout window, while the run is still in
                    // flight. The header chip already gates on !_busy.
                    if (_busy)
                      _runningRow()
                    else if (_error == null && _result == null && _logs.isEmpty)
                      _doneFooter(),
                  ]),
                ),
        ),
      ]),
    );
  }

  Widget _statusChip() {
    final failed = _error != null;
    final color = failed ? Theme.of(context).colorScheme.error : Accents.green;
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
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 7),
      Text(parts.join('  ·  ').toUpperCase(),
          style: TextStyle(
              fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600, color: color)),
    ]);
  }

  Widget _consoleLine(String line) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    final isErr = line.startsWith('ERROR:');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('↳ ',
            style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: muted?.withValues(alpha: 0.6))),
        Expanded(
          child: SelectableText(line,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.4,
                  color: isErr ? Theme.of(context).colorScheme.error : null)),
        ),
      ]),
    );
  }

  Widget _runningRow() {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
          width: 11,
          height: 11,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: muted)),
      const SizedBox(width: 8),
      Text(tr('pg.running'),
          style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: muted)),
    ]);
  }

  Widget _doneFooter() {
    final rows = _result is List
        ? (_result as List).length
        : (_result is Map ? (_result as Map).length : null);
    final txt = rows != null
        ? '✓ ${tr('pg.doneRows')} · $rows ${tr('pg.rowsUnit')}'
        : '✓ ${tr('pg.doneRows')}';
    return Text(txt,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Accents.green));
  }

  Widget _errorBox() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.error.withValues(alpha: 0.6)),
        color: scheme.error.withValues(alpha: 0.08),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.error_outline, color: scheme.error, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(_error!,
              style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
        ),
      ]),
    );
  }

  // ---- result rendering ----

  Widget _resultWidget(Object? r) {
    // array of objects → a multi-column table
    if (r is List && r.isNotEmpty && r.every((e) => e is Map)) {
      final cols = <String>[];
      for (final row in r) {
        for (final k in (row as Map).keys) {
          final key = k.toString();
          if (!cols.contains(key)) cols.add(key);
        }
      }
      return _table(cols, [for (final row in r) (row as Map).cast<dynamic, dynamic>()]);
    }
    // plain object → a key / value table
    if (r is Map && r.isNotEmpty) {
      return _table(['key', 'value'],
          [for (final e in r.entries) {'key': e.key, 'value': e.value}]);
    }
    // fallback → pretty JSON
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(r);
    } catch (_) {
      pretty = '$r';
    }
    return SelectableText(pretty,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4));
  }

  Widget _table(List<String> cols, List<Map> rows) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(dynamic v, {required bool header}) {
      if (header) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(v.toString(),
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
        );
      }
      final isNum = v is num;
      final txt = v == null
          ? '—'
          : (v is Map || v is List ? _compactJson(v) : v.toString());
      // SelectableText, matching the console lines and the JSON fallback: this
      // is the only result surface a value can land on (ddbScanAggregate returns
      // rows), so a plain Text would make it the one uncopyable one. It takes no
      // `overflow`, hence clipping at maxLines rather than an ellipsis.
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: SelectableText(txt,
            maxLines: 3,
            style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: isNum ? Accents.amber : null)),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicWidth(
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(
              horizontalInside:
                  BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
            ),
            children: [
              TableRow(
                decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.4)),
                children: [for (final c in cols) cell(c, header: true)],
              ),
              for (final row in rows)
                TableRow(children: [for (final c in cols) cell(row[c], header: false)]),
            ],
          ),
        ),
      ),
    );
  }

  String _compactJson(dynamic v) {
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
