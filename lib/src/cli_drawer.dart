// v2.3 CLI drawer — a collapsible panel pinned to the bottom of the Browse
// screen, rebuilt to the mockup's three-tab form (mockup .cli-tabs):
//   • CLI             — the interactive RESP console (round-trips timed)
//   • Command Helper  — a command reference / suggestion panel
//   • Profiler        — a slow-command sampler fed by the console's timings
// Reuses cmd_console's RedisConsoleClient / formatReply / tokenize (all
// already public) rather than re-implementing the wire protocol.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cmd_console.dart';
import 'ui_tokens.dart';

/// Curated common-command vocabulary for the Command Helper tab (the same
/// common subset cmd_console's suggestion chips use, made shareable here).
const kCliHelperCommands = [
  'PING', 'SET', 'GET', 'DEL', 'EXISTS', 'EXPIRE', 'TTL', 'TYPE',
  'KEYS', 'SCAN', 'HSET', 'HGET', 'HGETALL', 'LPUSH', 'RPUSH', 'LRANGE',
  'SADD', 'SMEMBERS', 'ZADD', 'ZRANGE', 'INCR', 'DECR', 'SELECT', 'DBSIZE',
  'INFO', 'FLUSHDB',
];

/// One profiled command execution (the Profiler tab's sample rows).
class _ProfileEntry {
  final String command;
  final int elapsedMs;
  final bool slow;
  const _ProfileEntry(this.command, this.elapsedMs)
      : slow = elapsedMs > 200;
}

enum _DrawerTab { cli, helper, profiler }

class CliDrawer extends StatefulWidget {
  final String host;
  final int port;
  final String? auth;
  const CliDrawer({super.key, required this.host, required this.port, this.auth});

  @override
  State<CliDrawer> createState() => _CliDrawerState();
}

class _CliDrawerState extends State<CliDrawer> {
  bool _open = false;
  _DrawerTab _tab = _DrawerTab.cli;
  RedisConsoleClient? _client;
  bool _connecting = false;
  String? _connError;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _lines = <_Line>[];
  final _history = <String>[];
  int _histIdx = -1;
  // Profiler: rolling sample of command round-trips (newest last), capped.
  final _profile = <_ProfileEntry>[];

  @override
  void dispose() {
    _client?.close();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _ensureConnected() async {
    if (_client != null || _connecting) return;
    setState(() {
      _connecting = true;
      _connError = null;
    });
    final c = RedisConsoleClient(widget.host, widget.port, auth: widget.auth);
    try {
      await c.connect();
      if (!mounted) {
        c.close();
        return;
      }
      setState(() {
        _client = c;
        _connecting = false;
      });
      c.onClosed = (e) {
        if (!mounted) return;
        setState(() {
          _client = null;
          _connError = '$e';
        });
      };
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _connError = '$e';
      });
    }
  }

  Future<void> _submit() async {
    final raw = _input.text.trim();
    if (raw.isEmpty) return;
    _input.clear();
    _history.add(raw);
    _histIdx = -1;
    setState(() => _lines.add(_Line('❯ $raw', _LineKind.prompt)));
    final args = tokenize(raw);
    if (args == null || args.isEmpty) {
      setState(() => _lines.add(const _Line('(error) unbalanced quotes', _LineKind.error)));
      return;
    }
    await _ensureConnected();
    final c = _client;
    if (c == null) {
      setState(() => _lines.add(_Line('(error) not connected${_connError != null ? ' — $_connError' : ''}', _LineKind.error)));
      _scrollToEnd();
      return;
    }
    // Round-trip timing feeds both the per-line elapsed readout and the
    // Profiler tab's slow-command sample.
    final sw = Stopwatch()..start();
    try {
      final r = await c.command(args);
      if (!mounted) return;
      final ms = sw.elapsedMilliseconds;
      setState(() {
        _lines.add(_Line(formatReply(r), _LineKind.reply, elapsedMs: ms));
        _recordProfile(raw, ms);
      });
    } catch (e) {
      if (!mounted) return;
      final ms = sw.elapsedMilliseconds;
      setState(() {
        _lines.add(_Line('(error) $e', _LineKind.error, elapsedMs: ms));
        _recordProfile(raw, ms);
      });
    }
    _scrollToEnd();
  }

  void _recordProfile(String command, int ms) {
    _profile.add(_ProfileEntry(command, ms));
    if (_profile.length > 200) _profile.removeRange(0, _profile.length - 200);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
      }
    });
  }

  void _recall(int dir) {
    if (_history.isEmpty) return;
    _histIdx = _histIdx < 0 ? _history.length - 1 : (_histIdx + dir).clamp(0, _history.length - 1);
    _input.text = _history[_histIdx];
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  void _applyHelper(String cmd) {
    // Insert the helper command into the CLI input and jump back to the CLI tab.
    setState(() {
      _tab = _DrawerTab.cli;
      _open = true;
      _input.value = TextEditingValue(
        text: '$cmd ',
        selection: TextSelection.collapsed(offset: cmd.length + 1),
      );
    });
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final brightness = Theme.of(context).brightness;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // Mockup .cli-tabs: 32px three-tab strip + right-aligned toggle.
      Container(
        height: Dim.cliHeadH,
        decoration: BoxDecoration(
          color: t.panel,
          border: Border(top: BorderSide(color: t.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          _cliTab(t, _DrawerTab.cli, '>_ CLI'),
          _cliTab(t, _DrawerTab.helper, 'Command Helper'),
          _cliTab(t, _DrawerTab.profiler, 'Profiler'),
          const Spacer(),
          // Connection state for the CLI tab.
          if (_connecting)
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: t.text3))
          else
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _client != null ? t.success : (_connError != null ? t.danger : t.text3),
              ),
            ),
          const SizedBox(width: 10),
          // Mockup .cli-toggle: kbd ⌘` chip + ▾ glyph toggling the drawer.
          _toggleChip(t),
        ]),
      ),
      if (_open)
        Container(
          height: 220,
          decoration: BoxDecoration(color: t.panel2),
          child: Column(children: [
            // Sunken well top-edge reverse inner shadow (mockup .cli-body).
            Container(height: 3, decoration: Depth.wellTopCli(brightness)),
            Expanded(child: _tabBody(t)),
          ]),
        ),
    ]);
  }

  Widget _cliTab(AppTokens t, _DrawerTab tab, String label) {
    final active = _tab == tab;
    return InkWell(
      onTap: () => setState(() {
        _tab = tab;
        _open = true;
        if (tab == _DrawerTab.cli) {
          _ensureConnected();
          _focus.requestFocus();
        }
      }),
      child: Container(
        height: Dim.cliHeadH,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                color: active ? t.accent : Colors.transparent, width: 2),
          ),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: Ts.style(
                size: Ts.md,
                weight: active ? FontWeight.w500 : FontWeight.normal,
                color: active ? t.text : t.text3,
                monoFont: tab == _DrawerTab.cli)),
      ),
    );
  }

  Widget _toggleChip(AppTokens t) {
    return InkWell(
      borderRadius: BorderRadius.circular(Dim.radiusS),
      onTap: () => setState(() {
        _open = !_open;
        if (_open) {
          _ensureConnected();
          _focus.requestFocus();
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          // Mockup .kbd chip.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: t.panel,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: t.border),
            ),
            child: Text('⌘`', style: Ts.style(size: Ts.xs, color: t.text3, monoFont: true)),
          ),
          const SizedBox(width: 6),
          Icon(_open ? Icons.expand_more : Icons.expand_less, size: 14, color: t.text3),
        ]),
      ),
    );
  }

  Widget _tabBody(AppTokens t) {
    switch (_tab) {
      case _DrawerTab.cli:
        return _cliBody(t);
      case _DrawerTab.helper:
        return _helperBody(t);
      case _DrawerTab.profiler:
        return _profilerBody(t);
    }
  }

  // ------------------------------------------------------------------ CLI ---

  Widget _cliBody(AppTokens t) {
    return Column(children: [
      Expanded(
        child: _lines.isEmpty
            ? Center(
                child: Text('redis-cli · ${widget.host}:${widget.port}',
                    style: Ts.style(size: Ts.xs, color: t.text3, monoFont: true)))
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(14, 9, 14, 6),
                itemCount: _lines.length,
                itemBuilder: (_, i) {
                  final l = _lines[i];
                  final color = switch (l.kind) {
                    // Mockup: prompt '❯' is success, replies text-2, errors danger.
                    _LineKind.prompt => t.success,
                    _LineKind.error => t.danger,
                    _LineKind.reply => t.text2,
                  };
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Text(l.text,
                            style: Ts.style(
                                size: Ts.md,
                                color: color,
                                monoFont: true,
                                height: 1.4,
                                weight: l.kind == _LineKind.prompt ? FontWeight.w700 : FontWeight.normal)),
                      ),
                      // Mockup .cli-ms: right-aligned elapsed readout.
                      if (l.elapsedMs != null)
                        Text('${l.elapsedMs} ms',
                            style: Ts.style(size: Ts.xs, color: t.text3, monoFont: true, tabularNums: true)),
                    ]),
                  );
                },
              ),
      ),
      // Input line — the last .cli-line inside the same panel-2 well (mockup):
      // '❯' success 700 + command text + accent block cursor, no separate bar.
      Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 9),
        child: Row(children: [
          Text('❯', style: Ts.style(size: Ts.md, weight: FontWeight.w700, color: t.success, monoFont: true)),
          const SizedBox(width: 8),
          Expanded(
            child: KeyboardListener(
              focusNode: FocusNode(skipTraversal: true),
              onKeyEvent: (e) {
                if (e is KeyDownEvent) {
                  if (e.logicalKey == LogicalKeyboardKey.arrowUp) _recall(-1);
                  if (e.logicalKey == LogicalKeyboardKey.arrowDown) _recall(1);
                }
              },
              child: TextField(
                controller: _input,
                focusNode: _focus,
                onSubmitted: (_) => _submit(),
                style: Ts.style(size: Ts.md, color: t.text, monoFont: true),
                decoration: InputDecoration(
                  isDense: true,
                  // Shield from the theme-level .f-input contentPadding
                  // (CP 7.6): the CLI row's own padding positions the caret
                  // line; the borderless input adds none.
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  hintText: 'GET key …',
                  hintStyle: Ts.style(size: Ts.md, color: t.text3, monoFont: true),
                ),
              ),
            ),
          ),
          // Mockup .cursor: an accent block cursor trailing the active line.
          Text('▍', style: Ts.style(size: Ts.md, color: t.accent, monoFont: true)),
        ]),
      ),
    ]);
  }

  // --------------------------------------------------------- Command Helper ---

  Widget _helperBody(AppTokens t) {
    final raw = _input.text.trimLeft();
    final firstWord = raw.split(RegExp(r'\s+')).first.toUpperCase();
    final hits = firstWord.isEmpty
        ? kCliHelperCommands
        : kCliHelperCommands.where((c) => c.startsWith(firstWord)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
        child: Text(
            firstWord.isEmpty
                ? 'Common commands — tap to insert into the CLI input'
                : 'Matching “$firstWord” — tap to insert',
            style: Ts.style(size: Ts.xs, color: t.text3)),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in hits) _helperChip(t, c),
          ]),
        ),
      ),
    ]);
  }

  Widget _helperChip(AppTokens t, String cmd) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _applyHelper(cmd),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: t.panel,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: t.border),
        ),
        child: Text(cmd, style: Ts.style(size: Ts.md, color: t.accent, monoFont: true)),
      ),
    );
  }

  // ---------------------------------------------------------------- Profiler ---

  Widget _profilerBody(AppTokens t) {
    if (_profile.isEmpty) {
      return Center(
        child: Text('No commands profiled yet — run some in the CLI tab',
            style: Ts.style(size: Ts.xs, color: t.text3, monoFont: true)),
      );
    }
    // Newest first; slow commands (>200ms) highlighted.
    final rows = _profile.reversed.toList();
    final slowCount = _profile.where((e) => e.slow).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
        child: Row(children: [
          Text('${_profile.length} profiled', style: Ts.style(size: Ts.xs, color: t.text3, monoFont: true, tabularNums: true)),
          const SizedBox(width: 12),
          Text('$slowCount slow (>200 ms)',
              style: Ts.style(size: Ts.xs, color: slowCount > 0 ? t.warning : t.text3, monoFont: true, tabularNums: true)),
          const Spacer(),
          InkWell(
            onTap: () => setState(_profile.clear),
            child: Text('Clear', style: Ts.style(size: Ts.xs, color: t.accent)),
          ),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          itemCount: rows.length,
          itemBuilder: (_, i) {
            final e = rows[i];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: Row(children: [
                if (e.slow) ...[
                  Icon(Icons.warning_amber_rounded, size: 12, color: t.warning),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Text(e.command,
                      overflow: TextOverflow.ellipsis,
                      style: Ts.style(size: Ts.md, color: e.slow ? t.text : t.text2, monoFont: true, height: 1.4)),
                ),
                Text('${e.elapsedMs} ms',
                    style: Ts.style(
                        size: Ts.xs,
                        color: e.slow ? t.warning : t.text3,
                        monoFont: true,
                        tabularNums: true,
                        weight: e.slow ? FontWeight.w600 : FontWeight.normal)),
              ]),
            );
          },
        ),
      ),
    ]);
  }
}

enum _LineKind { prompt, reply, error }

class _Line {
  final String text;
  final _LineKind kind;
  final int? elapsedMs;
  const _Line(this.text, this.kind, {this.elapsedMs});
}
