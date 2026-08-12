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
import 'i18n.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_status.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

/// Curated common-command vocabulary for the Command Helper tab (the same
/// common subset cmd_console's suggestion chips use, made shareable here).
const kCliHelperCommands = [
  'PING',
  'SET',
  'GET',
  'DEL',
  'EXISTS',
  'EXPIRE',
  'TTL',
  'TYPE',
  'KEYS',
  'SCAN',
  'HSET',
  'HGET',
  'HGETALL',
  'LPUSH',
  'RPUSH',
  'LRANGE',
  'SADD',
  'SMEMBERS',
  'ZADD',
  'ZRANGE',
  'INCR',
  'DECR',
  'SELECT',
  'DBSIZE',
  'INFO',
  'FLUSHDB',
];

/// One profiled command execution (the Profiler tab's sample rows).
class _ProfileEntry {
  final String command;
  final int elapsedMs;
  final bool slow;
  const _ProfileEntry(this.command, this.elapsedMs) : slow = elapsedMs > 200;
}

enum _DrawerTab { cli, helper, profiler }

class CliDrawer extends StatefulWidget {
  final String host;
  final int port;
  final String? auth;
  const CliDrawer({
    super.key,
    required this.host,
    required this.port,
    this.auth,
  });

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
  final _helperScroll = ScrollController();
  final _profileScroll = ScrollController();
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
    _helperScroll.dispose();
    _profileScroll.dispose();
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
      setState(() => _lines
          .add(const _Line('(error) unbalanced quotes', _LineKind.error)));
      return;
    }
    await _ensureConnected();
    final c = _client;
    if (c == null) {
      setState(() => _lines.add(_Line(
          '(error) not connected${_connError != null ? ' — $_connError' : ''}',
          _LineKind.error)));
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
    if (_profile.length > 200) {
      _profile.removeRange(0, _profile.length - 200);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _recall(int dir) {
    if (_history.isEmpty) return;
    _histIdx = _histIdx < 0
        ? _history.length - 1
        : (_histIdx + dir).clamp(0, _history.length - 1);
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

  void _selectTab(_DrawerTab tab) {
    setState(() {
      _tab = tab;
      _open = true;
    });
    if (tab == _DrawerTab.cli) {
      _ensureConnected();
      _focus.requestFocus();
    }
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (_open) {
      _ensureConnected();
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Column(
      key: const ValueKey('cli-drawer'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const ValueKey('cli-drawer-header'),
          height: Dim.cliHeadH,
          decoration: BoxDecoration(
            color: tokens.panel,
            border: Border(top: BorderSide(color: tokens.border)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(children: [
            _cliTab(tokens, _DrawerTab.cli, '>_ CLI'),
            _cliTab(tokens, _DrawerTab.helper, 'Command Helper'),
            _cliTab(tokens, _DrawerTab.profiler, 'Profiler'),
            const Spacer(),
            _connectionState(tokens),
            const SizedBox(width: 10),
            _toggleChip(tokens),
          ]),
        ),
        if (_open)
          SizedBox(
            key: const ValueKey('cli-drawer-body'),
            height: 220,
            child: CodexSurface(
              variant: CodexSurfaceVariant.sunken,
              padding: EdgeInsets.zero,
              child: _tabBody(tokens),
            ),
          ),
      ],
    );
  }

  Widget _connectionState(AppTokens tokens) {
    if (_connecting) {
      return SizedBox.square(
        key: const ValueKey('cli-drawer-connecting'),
        dimension: 12,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: tokens.text3,
        ),
      );
    }
    final connected = _client != null;
    final label = connected
        ? '${tr('cmd.connectedTo')} ${widget.host}:${widget.port}'
        : _connError ?? tr('cmd.notConnected');
    return CodexStatusDot(
      key: const ValueKey('cli-drawer-connection'),
      status: connected
          ? CodexStatus.running
          : _connError != null
              ? CodexStatus.error
              : CodexStatus.neutral,
      semanticLabel: label,
      glow: connected,
    );
  }

  Widget _cliTab(AppTokens tokens, _DrawerTab tab, String label) {
    final active = _tab == tab;
    return Semantics(
      selected: active,
      button: true,
      child: InkWell(
        key: ValueKey('cli-drawer-tab-${tab.name}'),
        onTap: () => _selectTab(tab),
        child: Container(
          height: Dim.cliHeadH,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? tokens.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: Ts.style(
              size: Ts.md,
              weight: active ? FontWeight.w600 : FontWeight.normal,
              color: active ? tokens.text : tokens.text3,
              monoFont: tab == _DrawerTab.cli,
            ),
          ),
        ),
      ),
    );
  }

  Widget _toggleChip(AppTokens tokens) {
    return Semantics(
      button: true,
      expanded: _open,
      label: _open ? tr('home.close') : '>_ CLI',
      child: InkWell(
        key: const ValueKey('cli-drawer-toggle'),
        borderRadius: BorderRadius.circular(Dim.radiusS),
        onTap: _toggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: tokens.panel2,
                borderRadius: BorderRadius.circular(Dim.radiusS),
                border: Border.all(color: tokens.border),
              ),
              child: Text(
                '⌘`',
                style: Ts.style(
                  size: Ts.xs,
                  color: tokens.text3,
                  monoFont: true,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              _open ? Icons.expand_more : Icons.expand_less,
              size: 14,
              color: tokens.text3,
            ),
          ]),
        ),
      ),
    );
  }

  Widget _tabBody(AppTokens tokens) {
    switch (_tab) {
      case _DrawerTab.cli:
        return _cliBody(tokens);
      case _DrawerTab.helper:
        return _helperBody(tokens);
      case _DrawerTab.profiler:
        return _profilerBody(tokens);
    }
  }

  // ------------------------------------------------------------------ CLI ---

  Widget _cliBody(AppTokens tokens) {
    return Column(
      key: const ValueKey('cli-drawer-cli-body'),
      children: [
        Expanded(
          child: _lines.isEmpty
              ? Center(
                  child: Text(
                    'redis-cli · ${widget.host}:${widget.port}',
                    style: Ts.style(
                      size: Ts.xs,
                      color: tokens.text3,
                      monoFont: true,
                    ),
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('cli-drawer-output-scroll'),
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 9, 14, 6),
                  itemCount: _lines.length,
                  itemBuilder: (_, i) {
                    final line = _lines[i];
                    final color = switch (line.kind) {
                      _LineKind.prompt => tokens.success,
                      _LineKind.error => tokens.danger,
                      _LineKind.reply => tokens.text2,
                    };
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SelectableText(
                              line.text,
                              style: Ts.style(
                                size: Ts.md,
                                color: color,
                                monoFont: true,
                                height: 1.4,
                                weight: line.kind == _LineKind.prompt
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (line.elapsedMs != null)
                            Text(
                              '${line.elapsedMs} ms',
                              style: Ts.style(
                                size: Ts.xs,
                                color: tokens.text3,
                                monoFont: true,
                                tabularNums: true,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        const CodexDivider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 9),
          child: Row(children: [
            Text(
              '❯',
              style: Ts.style(
                size: Ts.md,
                weight: FontWeight.w700,
                color: tokens.success,
                monoFont: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Focus(
                onKeyEvent: (_, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    _recall(-1);
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    _recall(1);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: CodexTextField(
                  key: const ValueKey('cli-drawer-input'),
                  controller: _input,
                  focusNode: _focus,
                  onSubmitted: (_) => _submit(),
                  style: Ts.style(
                    size: Ts.md,
                    color: tokens.text,
                    monoFont: true,
                  ),
                  decoration: InputDecoration(
                    hintText: 'GET key …',
                    suffixIcon: Icon(
                      Icons.keyboard_return,
                      size: 14,
                      color: tokens.text3,
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  // --------------------------------------------------------- Command Helper ---

  Widget _helperBody(AppTokens tokens) {
    final raw = _input.text.trimLeft();
    final firstWord = raw.split(RegExp(r'\s+')).first.toUpperCase();
    final hits = firstWord.isEmpty
        ? kCliHelperCommands
        : kCliHelperCommands.where((c) => c.startsWith(firstWord)).toList();
    return Column(
      key: const ValueKey('cli-drawer-helper-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Text(
            firstWord.isEmpty
                ? 'Common commands — tap to insert into the CLI input'
                : 'Matching “$firstWord” — tap to insert',
            style: Ts.style(size: Ts.xs, color: tokens.text3),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey('cli-drawer-helper-scroll'),
            controller: _helperScroll,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final command in hits) _helperChip(command),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _helperChip(String command) => CodexButton(
        key: ValueKey('cli-drawer-helper-$command'),
        label: Text(
          command,
          style: Ts.style(size: Ts.md, monoFont: true),
        ),
        variant: CodexButtonVariant.secondary,
        semanticLabel: command,
        onPressed: () => _applyHelper(command),
      );

  // ---------------------------------------------------------------- Profiler ---

  Widget _profilerBody(AppTokens tokens) {
    if (_profile.isEmpty) {
      return Center(
        key: const ValueKey('cli-drawer-profiler-body'),
        child: Text(
          'No commands profiled yet — run some in the CLI tab',
          style: Ts.style(size: Ts.xs, color: tokens.text3, monoFont: true),
        ),
      );
    }
    // Newest first; slow commands (>200ms) highlighted.
    final rows = _profile.reversed.toList();
    final slowCount = _profile.where((entry) => entry.slow).length;
    return Column(
      key: const ValueKey('cli-drawer-profiler-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 8, 2),
          child: Row(children: [
            Text(
              '${_profile.length} profiled',
              style: Ts.style(
                size: Ts.xs,
                color: tokens.text3,
                monoFont: true,
                tabularNums: true,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$slowCount slow (>200 ms)',
              style: Ts.style(
                size: Ts.xs,
                color: slowCount > 0 ? tokens.warning : tokens.text3,
                monoFont: true,
                tabularNums: true,
              ),
            ),
            const Spacer(),
            CodexButton(
              key: const ValueKey('cli-drawer-profiler-clear'),
              label: Text(tr('cmd.clear')),
              variant: CodexButtonVariant.ghost,
              onPressed: () => setState(_profile.clear),
            ),
          ]),
        ),
        const CodexDivider(),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('cli-drawer-profiler-scroll'),
            controller: _profileScroll,
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final entry = rows[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(children: [
                  if (entry.slow) ...[
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 12,
                      color: tokens.warning,
                    ),
                    const SizedBox(width: 5),
                  ],
                  Expanded(
                    child: SelectableText(
                      entry.command,
                      style: Ts.style(
                        size: Ts.md,
                        color: entry.slow ? tokens.text : tokens.text2,
                        monoFont: true,
                        height: 1.4,
                      ),
                    ),
                  ),
                  Text(
                    '${entry.elapsedMs} ms',
                    style: Ts.style(
                      size: Ts.xs,
                      color: entry.slow ? tokens.warning : tokens.text3,
                      monoFont: true,
                      tabularNums: true,
                      weight: entry.slow ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ],
    );
  }
}

enum _LineKind { prompt, reply, error }

class _Line {
  final String text;
  final _LineKind kind;
  final int? elapsedMs;
  const _Line(this.text, this.kind, {this.elapsedMs});
}
