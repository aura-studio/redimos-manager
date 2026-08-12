// The endpoint's **PartiQL** tab — a PartiQL statement editor modelled on the
// AWS console's PartiQL editor. The backing endpoint config has no single
// table (you name it in the statement); the templates use a placeholder table
// name. Statement templates (Scan / Query / Count / Insert / Update / Delete)
// stand in for the console's table-tree context menus; results render in Table
// view | JSON view with the console's status line (Completed/Failed · Started
// on · Elapsed time), client-side Find-items filtering, NextToken pagination,
// and the same Binary-as-readable-text enhancement as the Explorer. Write
// statements ask for confirmation first (the console runs them silently — we
// don't).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'code_editor.dart';
import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'ui_table.dart';
import 'ui_tokens.dart';

// Denser theme for this data surface — smaller controls / tighter tap targets.
ThemeData _denseTabTheme(BuildContext context) => Theme.of(context).copyWith(
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

Widget _semanticIconButton({
  required String label,
  required Widget icon,
  required VoidCallback? onPressed,
}) =>
    Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        button: true,
        enabled: onPressed != null,
        onTap: onPressed,
        excludeSemantics: true,
        child: IconButton(
          onPressed: onPressed,
          icon: icon,
        ),
      ),
    );

class PartiqlPageView extends StatefulWidget {
  final NativeCore core;
  final RedimosConfig config;
  const PartiqlPageView({super.key, required this.core, required this.config});

  @override
  State<PartiqlPageView> createState() => _PartiqlPageViewState();
}

class _PartiqlPageViewState extends State<PartiqlPageView>
    with AutomaticKeepAliveClientMixin {
  // v2.3: the statement editor takes the shared token-highlighted CodeField
  // (Playground grammar; PartiQL sits close enough to JS for the highlighter).
  late final CodeHighlightController _stmt =
      CodeHighlightController(lang: 'js');
  final _find = TextEditingController();
  bool _running = false;
  bool _jsonView = false;
  PartiqlResult? _res;
  String? _error;
  DateTime? _startedAt;
  final _tokens = <String?>[null]; // NextToken per page (index 0 = first page)
  int _pageIdx = 0;
  final _hiddenCols = <String>{};
  String? _sortCol;
  bool _sortAsc = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(PartiqlPageView old) {
    super.didUpdateWidget(old);
    if (old.config.id != widget.config.id ||
        old.config.table != widget.config.table) {
      setState(() {
        _stmt.clear();
        _res = null;
        _error = null;
        _resetPaging();
      });
    }
  }

  @override
  void dispose() {
    _stmt.dispose();
    _find.dispose();
    super.dispose();
  }

  void _resetPaging() {
    _tokens
      ..clear()
      ..add(null);
    _pageIdx = 0;
  }

  // ---- templates (console's table/attribute ⋮ menus, adapted) ----

  String get _tbl =>
      widget.config.table.trim().isEmpty ? 'your_table' : widget.config.table;
  String get _q => '"$_tbl"';

  List<(String, String)> get _templates => [
        (tr('pq.tplScanTable'), 'SELECT * FROM $_q'),
        (tr('pq.tplQueryByPk'), "SELECT * FROM $_q WHERE pk = ?"),
        (tr('pq.tplCountItems'), 'SELECT COUNT(*) FROM $_q'),
        // Write templates only off AWS — on an AWS endpoint they would run
        // into the read-only wall anyway (R7).
        if (!_awsMode) ...[
          (tr('pq.tplInsertItem'), "INSERT INTO $_q VALUE {'pk': ?, 'sk': ?}"),
          (
            tr('pq.tplUpdateItem'),
            "UPDATE $_q SET attr = ? WHERE pk = ? AND sk = ?"
          ),
          (tr('pq.tplDeleteItem'), 'DELETE FROM $_q WHERE pk = ? AND sk = ?'),
        ],
      ];

  bool get _isSelect =>
      _stmt.text.trimLeft().toUpperCase().startsWith('SELECT');

  // AWS mode (no endpoint) is read-only for writes — same wall as the Table /
  // Browser views: the manager can't tell a test account from production, so
  // only SELECT may run. The native partiqlExec re-guards regardless.
  bool get _awsMode {
    final ep = widget.config.endpoint.trim();
    if (ep.isEmpty) return true; // default AWS resolver
    final host = (Uri.tryParse(ep)?.host ?? '').toLowerCase();
    return host == 'amazonaws.com' ||
        host.endsWith('.amazonaws.com') ||
        host.endsWith(
            '.amazonaws.com.cn'); // explicit AWS host (incl. China partition)
  }

  // ---- execution ----

  Future<void> _run({bool resetPaging = true}) async {
    final stmt = _stmt.text.trim();
    if (stmt.isEmpty || _running) return;
    if (!_isSelect) {
      if (_awsMode) {
        // R7: AWS endpoints are read-only for destructive ops — refuse here
        // instead of running the statement (native re-guards as well).
        setState(() {
          _res = null;
          _startedAt = null;
          _error = tr('pq.awsReadOnlyReject');
        });
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('pq.runWriteTitle')),
          content: Text(trp('pq.modifyDataWarning',
              {'table': widget.config.table, 'stmt': stmt})),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('pq.cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('pq.run'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (resetPaging) _resetPaging();
    setState(() {
      _running = true;
      _error = null;
      _startedAt = DateTime.now();
    });
    await Future.delayed(const Duration(milliseconds: 16));
    final res = widget.core.partiql({
      'config': widget.config.toJson(),
      'statement': stmt,
      'limit': 50,
      'nextToken': _tokens[_pageIdx] ?? '',
    });
    if (!mounted) return;
    setState(() {
      _running = false;
      if (res.ok) {
        _res = res;
        _error = null;
        _sortCol = null;
      } else {
        _error = res.error ?? 'statement failed';
      }
    });
  }

  void _nextPage() {
    if (_res?.hasNext != true) return;
    if (_pageIdx == _tokens.length - 1) _tokens.add(_res!.nextToken);
    _pageIdx++;
    _run(resetPaging: false);
  }

  void _prevPage() {
    if (_pageIdx == 0) return;
    _pageIdx--;
    _run(resetPaging: false);
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Theme(
        data: _denseTabTheme(context),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _headerRow(),
            const SizedBox(height: 10),
            _editorCard(),
            if (_error != null || _res != null) ...[
              const SizedBox(height: 12),
              _statusLine(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              _errorBanner(),
            ],
            if (_error == null && _res != null) ...[
              const SizedBox(height: 12),
              _jsonView ? _jsonCard() : _resultsCard(),
            ],
          ]),
        ));
  }

  // v2.3: the big in-page title folds into the MidBar's PartiQL tab — what
  // stays is the context chrome (AWS read-only chip + templates menu).
  Widget _headerRow() {
    final tok = AppTokens.of(context);
    return Row(children: [
      if (_awsMode) ...[
        Chip(
          visualDensity: VisualDensity.compact,
          avatar: Icon(Icons.lock_outline, size: 15, color: tok.warning),
          label:
              Text(tr('ep.awsReadOnly'), style: TextStyle(color: tok.warning)),
        ),
      ],
      const Spacer(),
      PopupMenuButton<String>(
        tooltip: tr('pq.statementTemplates'),
        onSelected: (s) => setState(() => _stmt.text = s),
        itemBuilder: (_) => [
          for (final t in _templates)
            PopupMenuItem(value: t.$2, child: Text(t.$1)),
        ],
        child: OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.description_outlined, size: 18),
          label: Text(tr('pq.templates')),
          style: OutlinedButton.styleFrom(
            disabledForegroundColor: tok.accent,
          ),
        ),
      ),
    ]);
  }

  Card _card({required Widget child}) => Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(padding: const EdgeInsets.all(11), child: child),
      );

  Widget _editorCard() {
    final t = AppTokens.of(context);
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // v2.3: the editor takes the token palette (shared with Playground).
        SizedBox(
          height: 120,
          child: CodeField(
            controller: _stmt,
            hintText:
                'SELECT * FROM "${widget.config.table}" — ${tr('pq.typeStatement')}',
            onChanged: (_) => setState(() {}), // Run enable/disable
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          _runCta(t),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: () => setState(() {
              _stmt.clear();
            }),
            child: Text(tr('pq.clear')),
          ),
          const Spacer(),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(tr('pq.tableView'))),
              ButtonSegment(value: true, label: Text(tr('pq.jsonView'))),
            ],
            selected: {_jsonView},
            onSelectionChanged: (s) => setState(() => _jsonView = s.first),
            showSelectedIcon: false,
          ),
        ]),
      ]),
    );
  }

  // Shared warm-accent CTA grammar, matching the Playground Run button and
  // the MidBar end group.
  Widget _runCta(AppTokens t) {
    final bg = t.accent;
    final fg = t.onAccent;
    return SizedBox(
      height: Dim.ctlH,
      child: FilledButton(
        onPressed: _stmt.text.trim().isEmpty || _running ? null : () => _run(),
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          minimumSize: const Size(0, Dim.ctlH),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        child: _running
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg))
            : Text(tr('pq.run'),
                style: Ts.style(size: Ts.md, weight: FontWeight.w600)),
      ),
    );
  }

  // ---- status + error ----

  String _fmtTs(DateTime t) =>
      '${t.year}/${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  Widget _statusLine() {
    final failed = _error != null;
    final t = AppTokens.of(context);
    final color = failed ? t.danger : t.success;
    final ms = failed ? null : _res?.timeMs;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(failed ? Icons.cancel : Icons.check_circle,
            size: 18, color: color),
        const SizedBox(width: 6),
        Text(failed ? tr('pq.failed') : tr('pq.completed'),
            style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      ]),
      if (_startedAt != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
              '${tr('pq.startedOn')} ${_fmtTs(_startedAt!)}'
              '${ms != null ? '   ·   ${tr('pq.elapsedTime')} ${ms}ms' : ''}',
              style: Ts.style(size: Ts.md, color: t.text2, tabularNums: true)),
        ),
    ]);
  }

  Widget _errorBanner() {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.danger),
        color: t.danger.withValues(alpha: 0.08),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.error_outline, color: t.danger, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('pq.errorOccurred'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            SelectableText(_error!, style: const TextStyle(fontSize: 12.5)),
          ]),
        ),
      ]),
    );
  }

  // ---- results ----

  List<TableItem> _visibleRows() {
    var rows = _res!.rows;
    final f = _find.text.trim().toLowerCase();
    if (f.isNotEmpty) {
      rows = rows
          .where((r) =>
              r.cells.values.any((c) => c.repr.toLowerCase().contains(f)))
          .toList();
    }
    if (_sortCol != null) {
      rows = [...rows]..sort((a, b) {
          final cmp = (a.cells[_sortCol]?.repr ?? '')
              .compareTo(b.cells[_sortCol]?.repr ?? '');
          return _sortAsc ? cmp : -cmp;
        });
    }
    return rows;
  }

  Widget _resultsCard() {
    final r = _res!;
    final cols = r.cols.where((c) => !_hiddenCols.contains(c)).toList();
    final rows = _visibleRows();
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${tr('pq.itemsReturned')} (${r.returned})',
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          _semanticIconButton(
            label: tr('pq.preferences'),
            onPressed: _openPreferences,
            icon: const Icon(Icons.settings, size: 18),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _find,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: tr('pq.findItems'),
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            suffixIcon: _find.text.isEmpty
                ? null
                : _semanticIconButton(
                    label: tr('pq.clear'),
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () => setState(() => _find.clear()),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 4),
        Row(children: [
          _semanticIconButton(
            label: MaterialLocalizations.of(context).previousPageTooltip,
            onPressed: _pageIdx == 0 || _running ? null : _prevPage,
            icon: const Icon(Icons.chevron_left, size: 20),
          ),
          Text('${_pageIdx + 1}'),
          _semanticIconButton(
            label: MaterialLocalizations.of(context).nextPageTooltip,
            onPressed: r.hasNext && !_running ? _nextPage : null,
            icon: const Icon(Icons.chevron_right, size: 20),
          ),
          if (r.hasNext)
            TextButton(
                onPressed: _running ? null : _nextPage,
                child: Text(tr('pq.nextPage'))),
        ]),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(children: [
                Icon(Icons.inbox_outlined,
                    size: 36, color: Theme.of(context).hintColor),
                const SizedBox(height: 8),
                Text(tr('pq.noItems')),
                const SizedBox(height: 4),
                Text(
                    _find.text.isEmpty
                        ? tr('pq.noItemsFromStatement')
                        : tr('pq.noItemsMatchFilter'),
                    style: TextStyle(
                        fontSize: 12, color: Theme.of(context).hintColor)),
              ]),
            ),
          )
        else
          CodexHorizontalScrollView(
            child: DataTable(
              columnSpacing: 16,
              headingRowHeight: 30,
              dataRowMinHeight: 28,
              dataRowMaxHeight: 34,
              columns: [
                for (final c in cols)
                  DataColumn(
                    label: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(c,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (_sortCol == c)
                        Icon(
                            _sortAsc
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                            size: 12),
                    ]),
                    onSort: (_, __) => setState(() {
                      if (_sortCol == c) {
                        _sortAsc = !_sortAsc;
                      } else {
                        _sortCol = c;
                        _sortAsc = true;
                      }
                    }),
                  ),
              ],
              rows: [
                for (var i = 0; i < rows.length; i++)
                  DataRow(
                    // v2.3: zebra on panel2 (endpoint chrome convergence).
                    color: WidgetStatePropertyAll(
                        i.isOdd ? AppTokens.of(context).panel2 : null),
                    onSelectChanged: (_) => _showItemJson(rows[i]),
                    cells: [
                      for (final c in cols)
                        DataCell(_cellWidget(rows[i].cells[c]))
                    ],
                  ),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _cellWidget(AttrCell? cell) {
    if (cell == null) return const SizedBox.shrink();
    final text = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Text(cell.repr, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    if (cell.isBinary && cell.printable && cell.b64 != null) {
      return Tooltip(message: 'base64: ${cell.b64}', child: text);
    }
    return text;
  }

  Widget _jsonCard() {
    final rows = _visibleRows();
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ')
          .convert([for (final r in rows) jsonDecode(r.ddbJson)]);
    } catch (_) {
      pretty = '[]';
    }
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${tr('pq.itemsReturned')} (${_res!.returned})',
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          _semanticIconButton(
            label: tr('pq.copy'),
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pretty));
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(tr('pq.copied'))));
            },
          ),
        ]),
        const SizedBox(height: 8),
        SelectableText(pretty,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
      ]),
    );
  }

  void _openPreferences() {
    final cols = _res?.cols ?? [];
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final hidden = {..._hiddenCols};
        return StatefulBuilder(builder: (ctx, setD) {
          return AlertDialog(
            title: Text(tr('pq.preferences')),
            content: SizedBox(
              width: 320,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      TextButton(
                          onPressed: () => setD(() => hidden.clear()),
                          child: Text(tr('pq.selectAll'))),
                      TextButton(
                          onPressed: () => setD(() => hidden.addAll(cols)),
                          child: Text(tr('pq.deselectAll'))),
                    ]),
                    for (final c in cols)
                      SwitchListTile(
                        value: !hidden.contains(c),
                        onChanged: (v) =>
                            setD(() => v ? hidden.remove(c) : hidden.add(c)),
                        title: Text(c, overflow: TextOverflow.ellipsis),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                  ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(tr('pq.cancel'))),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _hiddenCols
                      ..clear()
                      ..addAll(hidden);
                  });
                },
                child: Text(tr('pq.saveChanges')),
              ),
            ],
          );
        });
      },
    );
  }

  void _showItemJson(TableItem r) {
    String pretty;
    try {
      pretty =
          const JsonEncoder.withIndent('  ').convert(jsonDecode(r.ddbJson));
    } catch (_) {
      pretty = r.ddbJson;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Expanded(child: Text(tr('pq.itemDdbJson'))),
          _semanticIconButton(
            label: tr('pq.copy'),
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pretty));
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(tr('pq.copied'))));
            },
          ),
        ]),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(pretty,
                style:
                    const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(tr('pq.close')))
        ],
      ),
    );
  }
}
