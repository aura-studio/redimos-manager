// The "PartiQL" tab — a PartiQL statement editor modelled on the AWS console's
// PartiQL editor, bound to the current config's table. Statement templates
// (Scan / Query / Count / Insert / Update / Delete) stand in for the console's
// table-tree context menus; results render in Table view | JSON view with the
// console's status line (Completed/Failed · Started on · Elapsed time),
// client-side Find-items filtering, NextToken pagination, and the same
// Binary-as-readable-text enhancement as the Table tab. Write statements ask
// for confirmation first (the console runs them silently — we don't).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'native.dart';

// Denser theme for this data tab — smaller controls / tighter tap targets.
ThemeData _denseTabTheme(BuildContext context) => Theme.of(context).copyWith(
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

class PartiqlPageView extends StatefulWidget {
  final NativeCore core;
  final RedimosConfig config;
  final bool running;
  const PartiqlPageView(
      {super.key, required this.core, required this.config, required this.running});

  @override
  State<PartiqlPageView> createState() => _PartiqlPageViewState();
}

class _PartiqlPageViewState extends State<PartiqlPageView>
    with AutomaticKeepAliveClientMixin {
  final _stmt = TextEditingController();
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
    if (old.config.id != widget.config.id || old.config.table != widget.config.table) {
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

  String get _q => '"${widget.config.table}"';

  List<(String, String)> get _templates => [
        ('Scan table', 'SELECT * FROM $_q'),
        ('Query by partition key', "SELECT * FROM $_q WHERE pk = ?"),
        ('Count items', 'SELECT COUNT(*) FROM $_q'),
        ('Insert item', "INSERT INTO $_q VALUE {'pk': ?, 'sk': ?}"),
        ('Update item', "UPDATE $_q SET attr = ? WHERE pk = ? AND sk = ?"),
        ('Delete item', 'DELETE FROM $_q WHERE pk = ? AND sk = ?'),
      ];

  bool get _isSelect =>
      _stmt.text.trimLeft().toUpperCase().startsWith('SELECT');

  // ---- execution ----

  Future<void> _run({bool resetPaging = true}) async {
    final stmt = _stmt.text.trim();
    if (stmt.isEmpty || _running) return;
    if (!_isSelect) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Run write statement?'),
          content: Text(
              'This statement can modify data in "${widget.config.table}".\n\n$stmt'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Run')),
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
    if (!widget.running) {
      return _center(Icons.play_circle_outline, 'Instance not running',
          'Start this config to run PartiQL statements against its table.');
    }
    if (widget.config.table.trim().isEmpty) {
      return _center(Icons.code, 'No table configured',
          'Set a Table name in Configure to run PartiQL statements.');
    }
    return Theme(
      data: _denseTabTheme(context),
      child: SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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

  Widget _headerRow() {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(Icons.code, size: 18, color: scheme.primary),
      const SizedBox(width: 8),
      const Text('PartiQL editor', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
      const SizedBox(width: 12),
      Text(widget.config.table,
          style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
      const Spacer(),
      PopupMenuButton<String>(
        tooltip: 'Statement templates',
        onSelected: (s) => setState(() => _stmt.text = s),
        itemBuilder: (_) => [
          for (final t in _templates) PopupMenuItem(value: t.$2, child: Text(t.$1)),
        ],
        child: OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.description_outlined, size: 18),
          label: const Text('Templates'),
          style: OutlinedButton.styleFrom(
            disabledForegroundColor: scheme.primary,
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

  Widget _editorCard() => _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _stmt,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13.5),
            decoration: InputDecoration(
              hintText: 'SELECT * FROM "${widget.config.table}" — type a PartiQL statement',
              hintStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.all(10),
            ),
            onChanged: (_) => setState(() {}), // Run enable/disable
          ),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton(
              onPressed: _stmt.text.trim().isEmpty || _running ? null : () => _run(),
              child: _running
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Run'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () => setState(() {
                _stmt.clear();
              }),
              child: const Text('Clear'),
            ),
            const Spacer(),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Table view')),
                ButtonSegment(value: true, label: Text('JSON view')),
              ],
              selected: {_jsonView},
              onSelectionChanged: (s) => setState(() => _jsonView = s.first),
              showSelectedIcon: false,
            ),
          ]),
        ]),
      );

  // ---- status + error ----

  String _fmtTs(DateTime t) =>
      '${t.year}/${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  Widget _statusLine() {
    final failed = _error != null;
    const okColor = Color(0xFF2E7D32);
    final color = failed ? Theme.of(context).colorScheme.error : okColor;
    final ms = failed ? null : _res?.timeMs;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(failed ? Icons.cancel : Icons.check_circle, size: 18, color: color),
        const SizedBox(width: 6),
        Text(failed ? 'Failed' : 'Completed',
            style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      ]),
      if (_startedAt != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Started on ${_fmtTs(_startedAt!)}'
              '${ms != null ? '   ·   Elapsed time ${ms}ms' : ''}'),
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
            const Text('An error occurred during the execution of the command.',
                style: TextStyle(fontWeight: FontWeight.w600)),
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
          .where((r) => r.cells.values.any((c) => c.repr.toLowerCase().contains(f)))
          .toList();
    }
    if (_sortCol != null) {
      rows = [...rows]..sort((a, b) {
          final cmp = (a.cells[_sortCol]?.repr ?? '').compareTo(b.cells[_sortCol]?.repr ?? '');
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
            child: Text('Items returned (${r.returned})',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Preferences',
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
            hintText: 'Find items',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            suffixIcon: _find.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () => setState(() => _find.clear()),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 4),
        Row(children: [
          IconButton(
            onPressed: _pageIdx == 0 || _running ? null : _prevPage,
            icon: const Icon(Icons.chevron_left, size: 20),
          ),
          Text('${_pageIdx + 1}'),
          IconButton(
            onPressed: r.hasNext && !_running ? _nextPage : null,
            icon: const Icon(Icons.chevron_right, size: 20),
          ),
          if (r.hasNext)
            TextButton(onPressed: _running ? null : _nextPage, child: const Text('Next page')),
        ]),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(children: [
                Icon(Icons.inbox_outlined, size: 36, color: Theme.of(context).hintColor),
                const SizedBox(height: 8),
                const Text('No items'),
                const SizedBox(height: 4),
                Text(
                    _find.text.isEmpty
                        ? 'The statement returned no items.'
                        : 'No items match the filter.',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
              ]),
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              headingRowHeight: 30,
              dataRowMinHeight: 28,
              dataRowMaxHeight: 34,
              columns: [
                for (final c in cols)
                  DataColumn(
                    label: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(c, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (_sortCol == c)
                        Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12),
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
                for (final r in rows)
                  DataRow(
                    onSelectChanged: (_) => _showItemJson(r),
                    cells: [for (final c in cols) DataCell(_cellWidget(r.cells[c]))],
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
            child: Text('Items returned (${_res!.returned})',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pretty));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Copied')));
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
            title: const Text('Preferences'),
            content: SizedBox(
              width: 320,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  TextButton(onPressed: () => setD(() => hidden.clear()), child: const Text('Select all')),
                  TextButton(onPressed: () => setD(() => hidden.addAll(cols)), child: const Text('Deselect all')),
                ]),
                for (final c in cols)
                  SwitchListTile(
                    value: !hidden.contains(c),
                    onChanged: (v) => setD(() => v ? hidden.remove(c) : hidden.add(c)),
                    title: Text(c, overflow: TextOverflow.ellipsis),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _hiddenCols
                      ..clear()
                      ..addAll(hidden);
                  });
                },
                child: const Text('Save changes'),
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
      pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(r.ddbJson));
    } catch (_) {
      pretty = r.ddbJson;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Expanded(child: Text('Item (DynamoDB JSON)')),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pretty));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
        ]),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(pretty,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
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
