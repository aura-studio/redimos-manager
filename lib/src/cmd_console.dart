// An interactive redis-cli-style console for a running redimos instance.
//
// Speaks RESP directly over a TCP socket to 127.0.0.1:<port> (the RESP port the
// proxy exposes — for docker run-mode it is published 1:1 on the host, so the
// same address works). Type a command, see the reply, redis-cli formatting.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';

// ---------------------------------------------------------------------------
// RESP reply model + parser
// ---------------------------------------------------------------------------

/// A RESP simple status reply (`+OK`), printed without quotes (unlike a bulk
/// string, which redis-cli quotes).
class RespStatus {
  final String text;
  RespStatus(this.text);
}

/// A RESP error reply (`-ERR ...`).
class RespError {
  final String message;
  RespError(this.message);
}

class _Parsed {
  final Object? value;
  final int end; // absolute index just past this element
  _Parsed(this.value, this.end);
}

/// Incremental RESP parser over a growing byte buffer.
class RespParser {
  static final Object incomplete = Object();
  final List<int> _buf = [];

  void addBytes(List<int> b) => _buf.addAll(b);

  /// Returns the next fully-parsed reply, or [incomplete] if more bytes are
  /// needed. A legitimate nil reply is returned as `null`.
  Object? next() {
    final p = _parseAt(0);
    if (p == null) return incomplete;
    _buf.removeRange(0, p.end);
    return p.value;
  }

  int _crlf(int from) {
    for (var j = from; j + 1 < _buf.length; j++) {
      if (_buf[j] == 0x0D && _buf[j + 1] == 0x0A) return j;
    }
    return -1;
  }

  String _decode(int a, int b) =>
      utf8.decode(_buf.sublist(a, b), allowMalformed: true);

  _Parsed? _parseAt(int i) {
    if (i >= _buf.length) return null;
    final t = _buf[i];
    switch (t) {
      case 0x2B: // '+'
        final e = _crlf(i + 1);
        return e < 0 ? null : _Parsed(RespStatus(_decode(i + 1, e)), e + 2);
      case 0x2D: // '-'
        final e = _crlf(i + 1);
        return e < 0 ? null : _Parsed(RespError(_decode(i + 1, e)), e + 2);
      case 0x3A: // ':'
        final e = _crlf(i + 1);
        return e < 0 ? null : _Parsed(int.tryParse(_decode(i + 1, e)) ?? 0, e + 2);
      case 0x24: // '$' bulk string
        final e = _crlf(i + 1);
        if (e < 0) return null;
        final len = int.tryParse(_decode(i + 1, e)) ?? -1;
        if (len < 0) return _Parsed(null, e + 2);
        final start = e + 2;
        final endData = start + len;
        if (endData + 2 > _buf.length) return null;
        return _Parsed(_decode(start, endData), endData + 2);
      case 0x2A: // '*' array
        final e = _crlf(i + 1);
        if (e < 0) return null;
        final count = int.tryParse(_decode(i + 1, e)) ?? -1;
        if (count < 0) return _Parsed(null, e + 2);
        var pos = e + 2;
        final items = <Object?>[];
        for (var k = 0; k < count; k++) {
          final p = _parseAt(pos);
          if (p == null) return null;
          items.add(p.value);
          pos = p.end;
        }
        return _Parsed(items, pos);
      default:
        // Inline / unexpected — consume one line so we never deadlock.
        final e = _crlf(i + 1);
        return e < 0 ? null : _Parsed(RespStatus(_decode(i, e)), e + 2);
    }
  }
}

// ---------------------------------------------------------------------------
// Socket client
// ---------------------------------------------------------------------------

class RedisConsoleClient {
  final String host;
  final int port;
  final String? auth;
  Socket? _sock;
  final _parser = RespParser();
  final Queue<Completer<Object?>> _pending = Queue();
  bool connected = false;
  void Function(Object error)? onClosed;

  RedisConsoleClient(this.host, this.port, {this.auth});

  Future<void> connect() async {
    _sock = await Socket.connect(host, port,
        timeout: const Duration(seconds: 5));
    connected = true;
    _sock!.listen(_onData,
        onError: (Object e) => _fail(e),
        onDone: () => _fail('connection closed by server'),
        cancelOnError: true);
    if (auth != null && auth!.trim().isNotEmpty) {
      await command(['AUTH', auth!]); // best-effort; error shows as a reply
    }
  }

  void _onData(Uint8List data) {
    _parser.addBytes(data);
    while (_pending.isNotEmpty) {
      final v = _parser.next();
      if (identical(v, RespParser.incomplete)) break;
      _pending.removeFirst().complete(v);
    }
  }

  Future<Object?> command(List<String> args) {
    final s = _sock;
    if (s == null || !connected) return Future.error('not connected');
    final c = Completer<Object?>();
    _pending.add(c);
    s.add(_encode(args));
    return c.future;
  }

  List<int> _encode(List<String> args) {
    final b = BytesBuilder();
    b.add(utf8.encode('*${args.length}\r\n'));
    for (final a in args) {
      final bytes = utf8.encode(a);
      b.add(utf8.encode('\$${bytes.length}\r\n'));
      b.add(bytes);
      b.add(const [0x0D, 0x0A]);
    }
    return b.takeBytes();
  }

  void _fail(Object e) {
    final wasConnected = connected;
    connected = false;
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completeError(e);
    }
    if (wasConnected) onClosed?.call(e);
  }

  void close() {
    connected = false;
    _sock?.destroy();
    _sock = null;
    _pending.clear();
  }
}

// ---------------------------------------------------------------------------
// redis-cli-style reply formatting
// ---------------------------------------------------------------------------

String formatReply(Object? r) => _fmt(r);

String _fmt(Object? r) {
  if (r == null) return '(nil)';
  if (r is RespError) return '(error) ${r.message}';
  if (r is RespStatus) return r.text;
  if (r is int) return '(integer) $r';
  if (r is String) return '"${_escape(r)}"';
  if (r is List) {
    if (r.isEmpty) return '(empty array)';
    final width = r.length.toString().length;
    final sb = StringBuffer();
    for (var i = 0; i < r.length; i++) {
      final prefix = '${(i + 1).toString().padLeft(width)}) ';
      final lines = _fmt(r[i]).split('\n');
      sb.write(prefix + lines.first);
      for (var k = 1; k < lines.length; k++) {
        sb.write('\n${' ' * prefix.length}${lines[k]}');
      }
      if (i < r.length - 1) sb.write('\n');
    }
    return sb.toString();
  }
  return r.toString();
}

String _escape(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    switch (r) {
      case 0x5C:
        sb.write(r'\\');
      case 0x22:
        sb.write(r'\"');
      case 0x0A:
        sb.write(r'\n');
      case 0x0D:
        sb.write(r'\r');
      case 0x09:
        sb.write(r'\t');
      default:
        if (r < 0x20) {
          sb.write('\\x${r.toRadixString(16).padLeft(2, '0')}');
        } else {
          sb.writeCharCode(r);
        }
    }
  }
  return sb.toString();
}

/// Splits a command line into arguments, honouring single/double quotes
/// (double quotes support \-escapes), like redis-cli's sdssplitargs.
List<String>? tokenize(String line) {
  final out = <String>[];
  final cur = StringBuffer();
  var i = 0;
  var inWord = false;
  while (i < line.length) {
    final ch = line[i];
    if (ch == '"') {
      inWord = true;
      i++;
      while (i < line.length && line[i] != '"') {
        if (line[i] == r'\' && i + 1 < line.length) {
          final n = line[i + 1];
          cur.write(switch (n) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            _ => n,
          });
          i += 2;
        } else {
          cur.write(line[i]);
          i++;
        }
      }
      if (i >= line.length) return null; // unbalanced quote
      i++; // closing quote
    } else if (ch == "'") {
      inWord = true;
      i++;
      while (i < line.length && line[i] != "'") {
        cur.write(line[i]);
        i++;
      }
      if (i >= line.length) return null;
      i++;
    } else if (ch == ' ' || ch == '\t') {
      if (inWord) {
        out.add(cur.toString());
        cur.clear();
        inWord = false;
      }
      i++;
    } else {
      inWord = true;
      cur.write(ch);
      i++;
    }
  }
  if (inWord) out.add(cur.toString());
  return out;
}

// ---------------------------------------------------------------------------
// Console widget
// ---------------------------------------------------------------------------

enum _Kind { prompt, reply, error, info }

class _OutLine {
  final String text;
  final _Kind kind;
  _OutLine(this.text, this.kind);
}

class CmdConsole extends StatefulWidget {
  final String host;
  final int port;
  final String? auth;
  final bool running;
  // Failure cause surfaced from the supervisor (e.g. a redimos startup backend
  // check that keeps failing). Non-null while the instance is restarting/failed;
  // shown so a crash-loop doesn't look like a silent "Reconnecting…".
  final String? statusReason;
  const CmdConsole({
    super.key,
    required this.host,
    required this.port,
    required this.running,
    this.auth,
    this.statusReason,
  });

  @override
  State<CmdConsole> createState() => _CmdConsoleState();
}

class _CmdConsoleState extends State<CmdConsole>
    with AutomaticKeepAliveClientMixin {
  RedisConsoleClient? _client;
  final List<_OutLine> _out = [];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final List<String> _history = [];
  int _histIdx = -1;
  bool _connecting = false;
  bool _everConnected = false; // distinguishes "Connecting…" from "Reconnecting…"
  int _db = 0;
  Timer? _reconnectTimer; // auto-reconnect while the instance is meant to be up

  @override
  void initState() {
    super.initState();
    if (widget.running) _connect();
  }

  @override
  void didUpdateWidget(CmdConsole old) {
    super.didUpdateWidget(old);
    // Reconnect when the target endpoint changes, or when the instance comes up.
    if (old.port != widget.port || old.host != widget.host || old.auth != widget.auth) {
      _disconnect(silent: true);
      _out.clear();
      _db = 0;
      if (widget.running) _connect();
    } else if (widget.running && !old.running) {
      _connect();
    } else if (!widget.running && old.running) {
      _disconnect();
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _client?.close();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  // Auto-reconnect: when the socket drops (e.g. the instance restarted) but the
  // config is still meant to be running, keep retrying every second until the
  // proxy is back up. Cancelled when the instance is stopped or the widget dies.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (!mounted || !widget.running) return;
    _reconnectTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && widget.running && !(_client?.connected ?? false)) {
        _connect(retry: true);
      }
    });
  }

  Future<void> _connect({bool retry = false}) async {
    if (_connecting || (_client?.connected ?? false)) return;
    setState(() {
      _connecting = true;
    });
    final c = RedisConsoleClient(widget.host, widget.port, auth: widget.auth);
    c.onClosed = (e) {
      if (!mounted) return;
      // The instance dropped (restarted / backend cycled). No noisy log line —
      // the build swaps to a centered "Reconnecting…" spinner instead.
      setState(() => _client = null);
      _scheduleReconnect();
    };
    try {
      await c.connect();
      if (!mounted) {
        c.close();
        return;
      }
      setState(() {
        _client = c;
        _connecting = false;
        _everConnected = true;
      });
      _focus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      setState(() => _connecting = false);
      _scheduleReconnect(); // keep trying (silently) while the instance is running
    }
  }

  void _disconnect({bool silent = false}) {
    _reconnectTimer?.cancel();
    _client?.close();
    if (mounted) {
      setState(() => _client = null);
    } else {
      _client = null;
    }
  }

  void _append(String text, _Kind kind) {
    for (final line in text.split('\n')) {
      _out.add(_OutLine(line, kind));
    }
    // cap scrollback
    if (_out.length > 5000) _out.removeRange(0, _out.length - 5000);
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  String get _prompt =>
      '${widget.host}:${widget.port}${_db > 0 ? '[$_db]' : ''}> ';

  void _refocus() {
    // Keep typing after a command: return focus to the input on the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _submit(String raw) async {
    final line = raw.trim();
    _input.clear();
    _histIdx = -1;
    _refocus();
    if (line.isEmpty) return;
    _history.add(line);

    // local conveniences
    final lower = line.toLowerCase();
    if (lower == 'clear' || lower == 'cls') {
      setState(() => _out.clear());
      _refocus();
      return;
    }

    setState(() => _append('$_prompt$line', _Kind.prompt));

    final args = tokenize(line);
    if (args == null || args.isEmpty) {
      setState(() => _append('(error) ${tr('cmd.unbalancedQuotes')}', _Kind.error));
      return;
    }

    final client = _client;
    if (client == null || !client.connected) {
      setState(() => _append('(error) ${tr('cmd.notConnectedStart')}', _Kind.error));
      return;
    }

    try {
      final reply = await client.command(args);
      if (!mounted) return;
      setState(() {
        final isErr = reply is RespError;
        _append(formatReply(reply), isErr ? _Kind.error : _Kind.reply);
        // track SELECT so the prompt reflects the current DB
        if (args[0].toUpperCase() == 'SELECT' &&
            reply is RespStatus &&
            args.length > 1) {
          _db = int.tryParse(args[1]) ?? _db;
        }
      });
      _refocus();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _append('(error) $e', _Kind.error);
      });
      _refocus();
    }
  }

  void _recall(int dir) {
    if (_history.isEmpty) return;
    if (_histIdx == -1) _histIdx = _history.length;
    _histIdx = (_histIdx + dir).clamp(0, _history.length);
    final text = _histIdx >= _history.length ? '' : _history[_histIdx];
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Color _color(_Kind k, bool dark) => switch (k) {
        _Kind.prompt => dark ? const Color(0xFF9FB6D0) : const Color(0xFF3A5A7D),
        _Kind.reply => dark ? const Color(0xFFC8E1CB) : const Color(0xFF1F7A3D),
        _Kind.error => dark ? const Color(0xFFFF8A80) : const Color(0xFFC62828),
        _Kind.info => dark ? const Color(0xFF7C8592) : const Color(0xFF6B7280),
      };

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    if (!widget.running) {
      final reason = widget.statusReason;
      if (reason != null && reason.isNotEmpty) {
        // The proxy is restarting/failed with a known cause — show it instead of
        // the generic "not running" hint, so the real problem is in front of you.
        return _placeholder(
          icon: Icons.error_outline,
          title: tr('cmd.instanceFailedToStart'),
          subtitle: reason,
          tint: Colors.redAccent,
        );
      }
      return _placeholder(
        icon: Icons.play_circle_outline,
        title: tr('cmd.instanceNotRunning'),
        subtitle: tr('cmd.startConfigHint'),
      );
    }

    final connected = _client?.connected ?? false;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Terminal palette, theme-aware. Dark keeps the classic near-black console;
    // light uses a soft off-white so the Cmd tab isn't a black hole in a light UI.
    final termBg = dark ? const Color(0xFF0B0E13) : const Color(0xFFF7F8FA);

    // Not connected yet (initial connect or an in-progress reconnect): a centered
    // spinner, and the console is not operable until it's back.
    if (!connected) {
      return Container(color: termBg, child: _loadingView());
    }
    final inputBg = dark ? const Color(0xFF0E1116) : const Color(0xFFEDEFF3);
    final inputText = dark ? Colors.white : const Color(0xFF1B1F24);
    final hintColor = dark ? const Color(0xFF55606E) : const Color(0xFF98A0AC);
    final promptColor = connected
        ? (dark ? const Color(0xFF7FB2E6) : const Color(0xFF2F6FB3))
        : Colors.grey;
    const accent = Color(0xFF4F93D6);
    return Container(
      color: termBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // scrollback — or a terminal-style welcome banner before any command
          Expanded(
            child: _out.isEmpty
                ? _welcome(dark)
                : Scrollbar(
                    controller: _scroll,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      itemCount: _out.length,
                      itemBuilder: (_, i) {
                        final l = _out[i];
                        return SelectableText(
                          l.text.isEmpty ? ' ' : l.text,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            height: 1.35,
                            color: _color(l.kind, dark),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          const Divider(height: 1),
          // input row — fixed height so its top divider lines up with the
          // Local DynamoDB panel's divider across the sidebar split (both 48px).
          Container(
            color: inputBg,
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  _connecting ? '${tr('cmd.connectingPrompt')} ' : _prompt,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    color: promptColor,
                  ),
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent) {
                        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                          _recall(-1);
                          return KeyEventResult.handled;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                          _recall(1);
                          return KeyEventResult.handled;
                        }
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      autofocus: true,
                      enabled: connected,
                      style: TextStyle(
                          fontFamily: 'monospace', fontSize: 12.5, color: inputText),
                      cursorColor: accent,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: connected
                            ? tr('cmd.typeCommandHint')
                            : tr('cmd.notConnected'),
                        hintStyle: TextStyle(color: hintColor, fontSize: 12.5),
                      ),
                      onSubmitted: _submit,
                    ),
                  ),
                ),
                if (!connected && !_connecting)
                  TextButton(
                    onPressed: _connect,
                    child: Text(tr('cmd.reconnect')),
                  )
                else
                  IconButton(
                    tooltip: tr('cmd.clear'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    icon: const Icon(Icons.clear_all, size: 18),
                    onPressed: () => setState(() => _out.clear()),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Empty-console welcome: a small redis-cli-style banner + clickable example
  // commands, so a connected-but-idle console isn't just a blank board.
  Widget _welcome(bool dark) {
    final ink = dark ? const Color(0xFFC7D0DC) : const Color(0xFF3A424D);
    final muted = dark ? const Color(0xFF6B7686) : const Color(0xFF8A93A0);
    final accent = dark ? const Color(0xFF7FB2E6) : const Color(0xFF2F6FB3);
    final mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.55, color: muted);
    const examples = [
      'PING',
      'SET greeting "hello"',
      'GET greeting',
      'SCAN 0 COUNT 20',
      'TYPE greeting',
      'INFO server',
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.terminal, size: 18, color: accent),
          const SizedBox(width: 8),
          Text('redimos-cli',
              style: TextStyle(
                  fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w700, color: ink)),
        ]),
        const SizedBox(height: 10),
        Text('${tr('cmd.connectedTo')} ${widget.host}:${widget.port} ${tr('cmd.redisCompatible')}', style: mono),
        Text(tr('cmd.scanTip'), style: mono),
        const SizedBox(height: 16),
        Text(tr('cmd.tryCommand'),
            style: mono.copyWith(color: ink)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in examples) _cmdChip(c, dark),
        ]),
        const SizedBox(height: 18),
        Text(tr('cmd.historyHint'),
            style: mono.copyWith(fontSize: 11.5)),
      ]),
    );
  }

  // A clickable example-command chip: inserts the command into the input.
  Widget _cmdChip(String cmd, bool dark) {
    final bg = dark ? const Color(0xFF161B22) : Colors.white;
    final border = dark ? const Color(0xFF283040) : const Color(0xFFDCE0E6);
    final fg = dark ? const Color(0xFF9DB8DE) : const Color(0xFF2F6FB3);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        _input.text = cmd;
        _input.selection = TextSelection.collapsed(offset: cmd.length);
        _focus.requestFocus();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border),
        ),
        child: Text(cmd, style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: fg)),
      ),
    );
  }

  // Centered loading view shown while (re)connecting — mirrors _placeholder's
  // layout but with a spinner. The console stays non-interactive until connected.
  Widget _loadingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 18),
          Text(_everConnected ? tr('cmd.reconnecting') : tr('cmd.connecting'),
              style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Text('${widget.host}:${widget.port}',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _placeholder(
      {required IconData icon,
      required String title,
      required String subtitle,
      Color? tint}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: tint ?? Colors.grey),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 6),
            SelectableText(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: Colors.grey, height: 1.4)),
          ],
        ),
      ),
    );
  }
}
