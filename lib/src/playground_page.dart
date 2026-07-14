// The "Playground" tab — run a small JavaScript (goja) or Go (yaegi) script
// against a running instance's Redis (`redis` host) or an endpoint's DynamoDB
// (`ddb` host), with a `console` for output. Both interpreters are sandboxed in
// the Go core (no fs/net/os beyond the injected host) and cancelled on timeout.
// Modelled on the PartiQL tab's editor/result idiom: a monospace editor, a
// language toggle, a sample-program dropdown, and a console + JSON-result panel.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'playground_samples.dart';

ThemeData _denseTabTheme(BuildContext context) => Theme.of(context).copyWith(
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

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
  final _script = TextEditingController();
  String _lang = 'js'; // 'js' | 'go'
  int? _sampleIdx; // index into the current kind's sample list
  bool _busy = false;

  List<String> _logs = const [];
  Object? _result;
  String? _error;
  int? _elapsedMs;
  DateTime? _startedAt;

  @override
  bool get wantKeepAlive => true;

  List<PlaygroundSample> get _samples => samplesForKind(widget.kind);

  bool get _isReadOnly {
    // AWS endpoints are read-only for the ddb host; surface that in the header.
    final c = widget.config;
    return widget.kind == 'ddb' &&
        c.endpoint.trim().isEmpty &&
        (c.accessKeyId.isNotEmpty || c.region.isNotEmpty);
  }

  @override
  void dispose() {
    _script.dispose();
    super.dispose();
  }

  void _loadSample(int idx) {
    final s = _samples[idx];
    setState(() {
      _sampleIdx = idx;
      _script.text = _lang == 'go' ? s.go : s.js;
    });
  }

  void _setLang(String lang) {
    setState(() {
      _lang = lang;
      // If a sample is loaded, swap to the same sample in the other language
      // (only when the editor still holds the untouched sample text).
      final i = _sampleIdx;
      if (i != null) {
        final s = _samples[i];
        final other = lang == 'go' ? s.js : s.go;
        if (_script.text.trim() == other.trim()) {
          _script.text = lang == 'go' ? s.go : s.js;
        }
      }
    });
  }

  Future<void> _run() async {
    final script = _script.text.trim();
    if (script.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _logs = const [];
      _result = null;
      _elapsedMs = null;
      _startedAt = DateTime.now();
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
      _logs = ((res['logs'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
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
    return Theme(
      data: _denseTabTheme(context),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _headerRow(),
          const SizedBox(height: 10),
          _editorCard(),
          if (_startedAt != null) ...[
            const SizedBox(height: 12),
            _statusLine(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            _errorBanner(),
          ],
          if (_logs.isNotEmpty) ...[
            const SizedBox(height: 12),
            _consoleCard(),
          ],
          if (_error == null && _result != null) ...[
            const SizedBox(height: 12),
            _resultCard(),
          ],
        ]),
      ),
    );
  }

  Widget _headerRow() {
    final scheme = Theme.of(context).colorScheme;
    final hostLabel = widget.kind == 'redis'
        ? '${tr('pg.hostRedis')} · 127.0.0.1:${widget.config.port}'
        : '${tr('pg.hostDdb')} · ${_ddbTargetLabel()}';
    return Row(children: [
      Icon(Icons.science_outlined, size: 18, color: scheme.primary),
      const SizedBox(width: 8),
      Text(tr('pg.title'),
          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
      const SizedBox(width: 12),
      Flexible(
        child: Text(hostLabel,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
      ),
      if (_isReadOnly) ...[
        const SizedBox(width: 8),
        _readOnlyChip(),
      ],
      const Spacer(),
      PopupMenuButton<int>(
        tooltip: tr('pg.samples'),
        onSelected: _loadSample,
        itemBuilder: (_) => [
          for (var i = 0; i < _samples.length; i++)
            PopupMenuItem(value: i, child: Text(tr(_samples[i].titleKey))),
        ],
        child: OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.dashboard_customize_outlined, size: 18),
          label: Text(tr('pg.samples')),
          style: OutlinedButton.styleFrom(disabledForegroundColor: scheme.primary),
        ),
      ),
    ]);
  }

  Widget _readOnlyChip() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lock_outline, size: 13, color: scheme.onTertiaryContainer),
        const SizedBox(width: 4),
        Text(tr('pg.readOnly'),
            style: TextStyle(fontSize: 11.5, color: scheme.onTertiaryContainer)),
      ]),
    );
  }

  String _ddbTargetLabel() {
    final c = widget.config;
    if (c.endpoint.trim().isNotEmpty) {
      final u = c.endpoint.replaceFirst(RegExp(r'^https?://'), '');
      return u;
    }
    return c.region.isEmpty ? 'AWS' : 'AWS · ${c.region}';
  }

  Card _card({required Widget child}) => Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(padding: const EdgeInsets.all(11), child: child),
      );

  Widget _editorCard() {
    final api = widget.kind == 'redis' ? 'redis' : 'ddb';
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _script,
          minLines: 6,
          maxLines: 20,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            hintText: _lang == 'go'
                ? '// $api.Scan(...) · console.Log(...)  — ${tr('pg.typeScript')}'
                : '// $api.scan(...) · console.log(...)  — ${tr('pg.typeScript')}',
            hintStyle: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.all(10),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Row(children: [
          FilledButton.icon(
            onPressed: _script.text.trim().isEmpty || _busy ? null : _run,
            icon: _busy
                ? const SizedBox(
                    width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow, size: 18),
            label: Text(tr('pg.run')),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _script.clear();
                      _sampleIdx = null;
                    }),
            child: Text(tr('pg.clear')),
          ),
          const Spacer(),
          Text('${tr('pg.language')}:  ',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'js', label: Text('JavaScript')),
              ButtonSegment(value: 'go', label: Text('Go')),
            ],
            selected: {_lang},
            onSelectionChanged: (s) => _setLang(s.first),
            showSelectedIcon: false,
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          widget.kind == 'redis' ? tr('pg.apiHintRedis') : tr('pg.apiHintDdb'),
          style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor),
        ),
      ]),
    );
  }

  String _fmtTs(DateTime t) =>
      '${t.year}/${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  Widget _statusLine() {
    final failed = _error != null;
    const okColor = Color(0xFF2E7D32);
    final color = failed ? Theme.of(context).colorScheme.error : okColor;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(failed ? Icons.cancel : Icons.check_circle, size: 18, color: color),
        const SizedBox(width: 6),
        Text(failed ? tr('pg.failed') : tr('pg.completed'),
            style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      ]),
      if (_startedAt != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('${tr('pg.startedOn')} ${_fmtTs(_startedAt!)}'
              '${_elapsedMs != null ? '   ·   ${tr('pg.elapsed')} ${_elapsedMs}ms' : ''}'),
        ),
    ]);
  }

  Widget _errorBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.error),
        color: scheme.error.withValues(alpha: 0.08),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.error_outline, color: scheme.error, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('pg.errorOccurred'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            SelectableText(_error!, style: const TextStyle(fontSize: 12.5)),
          ]),
        ),
      ]),
    );
  }

  Widget _consoleCard() => _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.terminal, size: 16, color: Theme.of(context).hintColor),
            const SizedBox(width: 6),
            Text('${tr('pg.console')} (${_logs.length})',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
              tooltip: tr('pg.copy'),
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () => _copy(_logs.join('\n')),
            ),
          ]),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _logs.join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4),
            ),
          ),
        ]),
      );

  Widget _resultCard() {
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(_result);
    } catch (_) {
      pretty = '$_result';
    }
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.data_object, size: 16, color: Theme.of(context).hintColor),
          const SizedBox(width: 6),
          Text(tr('pg.result'),
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            tooltip: tr('pg.copy'),
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () => _copy(pretty),
          ),
        ]),
        const SizedBox(height: 6),
        SelectableText(pretty,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
      ]),
    );
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('pg.copied'))));
  }

  Widget _center(IconData icon, String title, String subtitle) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ]),
      );
}
