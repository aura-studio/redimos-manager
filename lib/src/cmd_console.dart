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
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_states.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

// The redimos proxy's reply for ANY storage-layer error — deliberately generic
// and lossy on its side, so it can never diagnose the cause. Matched verbatim
// (exact ASCII, never a localized or normalized form) and used ONLY to flip the
// degraded dot early; /readyz stays the source of truth.
const _kBackendErrorReply = 'ERR backend error, retry later';

/// How long a backend-error reply keeps the degraded dot lit on its own. Covers
/// the health signal's worst-case lag: redimos re-probes its backend every 10s,
/// the manager scrapes every 3s, the UI polls every 1.5s.
const _kBackendErrorLatch = Duration(seconds: 15);

/// The degraded dot's tooltip text, given the cause redimos reports for its
/// failing backend check (null/empty = it reports none).
///
/// The generic wording describes only the OBSERVED SIGNAL, because neither
/// trigger identifies a cause on its own: healthy && !ready is equally an IAM
/// loss or a deleted table with DynamoDB perfectly reachable, and the
/// error-reply path ([_kBackendErrorReply]) is lossy by construction. So a cause
/// is only ever appended when redimos itself supplies one, and the generic
/// sentence stays in front of it — that sentence explains the CONSEQUENCE, which
/// a raw AWS error string does not. With no cause, this says exactly what it said
/// before the cause was plumbed through: no less, and nothing invented.
String backendDegradedTooltip(String? backendError) {
  final generic = tr('cmd.backendDegraded');
  if (backendError == null || backendError.isEmpty) return generic;
  return '$generic\n\n${trp('cmd.backendDegradedCause', {
        'err': backendError
      })}';
}

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
        return e < 0
            ? null
            : _Parsed(int.tryParse(_decode(i + 1, e)) ?? 0, e + 2);
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
    _sock =
        await Socket.connect(host, port, timeout: const Duration(seconds: 5));
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
  // For prompt lines this is the COMMAND head only (the prompt prefix is kept
  // separately so a block card can style the two parts differently).
  final String text;
  final String promptPrefix;
  final _Kind kind;
  // Round-trip time for the command this prompt line issued (ms). Null on
  // non-prompt lines. >200ms marks a slow command (v2.3 R4.1).
  final int? elapsedMs;
  const _OutLine(this.text, this.kind,
      {this.promptPrefix = '', this.elapsedMs});
}

// Command completion vocabulary for the suggestion chips. A curated common
// subset (matching the _welcome examples), not the full Redis command set.
const _kConsoleCommands = [
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

class CmdConsole extends StatefulWidget {
  final String host;
  final int port;
  final String? auth;
  final bool running;
  // Failure cause surfaced from the supervisor (e.g. a redimos startup backend
  // check that keeps failing). Non-null while the instance is restarting/failed;
  // shown so a crash-loop doesn't look like a silent "Reconnecting…".
  final String? statusReason;
  // The proxy is up but its DynamoDB backend is not (healthy && !ready). The
  // RESP socket survives a backend outage, so nothing else in this widget can
  // notice one — commands simply start failing.
  final bool backendDegraded;
  // The cause redimos itself reports for that failing check (its /readyz body's
  // backend_error), when it reports one. Null/empty is the common case, not an
  // anomaly: the local optimistic path below (_sawBackendErrorAt) raises the dot
  // from a command's error reply alone, with no health sample behind it, and an
  // older redimos publishes no cause at all. So this refines the tooltip when
  // present and the generic wording must stand on its own when absent.
  final String? backendError;

  /// The instance's display name for the toolbar identity chip (mockup
  /// .inst-crumb shows "<b>prod-redis-01</b> · db3", not host:port). Null
  /// keeps the legacy host:port chip.
  final String? instanceName;

  /// Seeded connection-age label for the toolbar note ("RESP3 · 已连接 2h 14m"
  /// in the mockup). Null hides the note.
  final String? connectedLabel;

  /// The DB index the chip starts on (mockup shows "· db3"). Real sessions
  /// always open on db0; the capture seeds the mockup's value.
  final int initialDb;
  const CmdConsole({
    super.key,
    required this.host,
    required this.port,
    required this.running,
    this.auth,
    this.statusReason,
    this.backendDegraded = false,
    this.backendError,
    this.instanceName,
    this.connectedLabel,
    this.initialDb = 0,
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
  bool _everConnected =
      false; // distinguishes "Connecting…" from "Reconnecting…"
  int _db = 0;
  Timer? _reconnectTimer; // auto-reconnect while the instance is meant to be up
  // Completion tray: visible before the first command (or via the History
  // button), hidden once a command is submitted or Esc is pressed.
  bool _showChips = true;
  // Set when a command comes back with the proxy's backend-error reply, to show
  // the degraded dot ahead of the health signal (see _kBackendErrorReply). Held
  // as a timestamp, not a bool: the health signal it defers to lags by up to
  // ~14.5s, so the flag has to outlive that window to be worth anything.
  DateTime? _sawBackendErrorAt;

  @override
  void initState() {
    super.initState();
    _db = widget.initialDb;
    if (widget.running) _connect();
  }

  @override
  void didUpdateWidget(CmdConsole old) {
    super.didUpdateWidget(old);
    // Retire the optimistic flag only once it has outlived the health signal's
    // worst-case lag. Clearing it on any non-degraded rebuild would fire on the
    // first 1.5s status poll — long before the signal could have caught up — so
    // the flag would never bridge the very window it exists for. Past the latch,
    // a still-healthy signal means the error really was a one-off.
    final sawAt = _sawBackendErrorAt;
    if (sawAt != null &&
        !widget.backendDegraded &&
        DateTime.now().difference(sawAt) > _kBackendErrorLatch) {
      _sawBackendErrorAt = null;
    }
    // Reconnect when the target endpoint changes, or when the instance comes up.
    if (old.port != widget.port ||
        old.host != widget.host ||
        old.auth != widget.auth) {
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

  void _append(String text, _Kind kind,
      [int? elapsedMs, String promptPrefix = '']) {
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      // elapsedMs / prompt prefix attach to the FIRST line of a multi-line
      // append only (the prompt head); continuation lines stay timeless.
      _out.add(_OutLine(lines[i], kind,
          promptPrefix: i == 0 ? promptPrefix : '',
          elapsedMs: i == 0 ? elapsedMs : null));
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
    _histIdx = -1;
    _refocus();
    if (line.isEmpty) return;
    _history.add(line);
    _showChips = false; // an explicit command dismisses the completion tray

    // local conveniences
    final lower = line.toLowerCase();
    if (lower == 'clear' || lower == 'cls') {
      _clearOut();
      _refocus();
      return;
    }

    final args = tokenize(line);
    if (args == null || args.isEmpty) {
      setState(() {
        _input.clear();
        _append(line, _Kind.prompt, null, _prompt);
        _append('(error) ${tr('cmd.unbalancedQuotes')}', _Kind.error);
      });
      return;
    }

    final client = _client;
    if (client == null || !client.connected) {
      setState(() {
        _input.clear();
        _append(line, _Kind.prompt, null, _prompt);
        _append('(error) ${tr('cmd.notConnectedStart')}', _Kind.error);
      });
      return;
    }
    _input.clear();

    // Round-trip timing (v2.3 R4.1): the prompt line's elapsed badge is filled
    // in once the reply lands; >200ms marks a slow command.
    final sw = Stopwatch()..start();
    try {
      final reply = await client.command(args);
      if (!mounted) return;
      final ms = sw.elapsedMilliseconds;
      setState(() {
        final isErr = reply is RespError;
        _append(line, _Kind.prompt, ms, _prompt);
        _append(formatReply(reply), isErr ? _Kind.error : _Kind.reply);
        // The health signal lags by up to ~14.5s, so the error reaches the
        // console while the dot is still dark. Light it now; the latch keeps it
        // lit across that window (see _kBackendErrorLatch). The reply is only a
        // latency reducer — it is deliberately generic and can never diagnose a
        // cause, so the health signal stays the source of truth.
        if (isErr && reply.message == _kBackendErrorReply) {
          _sawBackendErrorAt = DateTime.now();
        }
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
      final ms = sw.elapsedMilliseconds;
      setState(() {
        _append(line, _Kind.prompt, ms, _prompt);
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

  // The suggestion chip vocabulary shown above the input, filtered by the
  // current first word (case-insensitive prefix). Empty input shows the full
  // common set (capped).
  List<String> get _chipSuggestions {
    final raw = _input.text.trimLeft();
    final firstWord = raw.split(RegExp(r'\s+')).first.toUpperCase();
    final hits = firstWord.isEmpty
        ? _kConsoleCommands
        : _kConsoleCommands.where((c) => c.startsWith(firstWord)).toList();
    return hits.take(8).toList();
  }

  void _applyChip(String cmd) {
    // Replace only the first word; preserve any arguments already typed.
    final raw = _input.text;
    final rest = raw.trimLeft().contains(RegExp(r'\s'))
        ? raw.trimLeft().substring(raw.trimLeft().indexOf(RegExp(r'\s')))
        : '';
    final next = '$cmd$rest${rest.isEmpty ? ' ' : ''}';
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _focus.requestFocus();
  }

  void _insertHistory(String cmd) {
    _input.value = TextEditingValue(
      text: cmd,
      selection: TextSelection.collapsed(offset: cmd.length),
    );
    _focus.requestFocus();
  }

  void _clearOut() => setState(() => _out.clear());

  // Mockup .cmd-out: ok/error replies are bold (700), others normal.
  Color _color(_Kind k, AppTokens t) => switch (k) {
        _Kind.prompt => t.text2,
        _Kind.reply => t.success,
        _Kind.error => t.danger,
        _Kind.info => t.text3,
      };

  FontWeight _weight(_Kind k) => switch (k) {
        _Kind.reply => FontWeight.w700,
        _Kind.error => FontWeight.w700,
        _ => FontWeight.normal,
      };

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final t = AppTokens.of(context);
    final connected = _client?.connected ?? false;
    final reason = widget.statusReason;
    final failed = !widget.running && reason != null && reason.isNotEmpty;
    final state = failed
        ? CodexContentState.error
        : !widget.running
            ? CodexContentState.empty
            : connected
                ? CodexContentState.content
                : CodexContentState.loading;
    final promptColor = connected ? t.accent : t.text3;

    // Fold _out into render items ONCE: a stamped prompt line absorbs its
    // output lines (up to the next prompt) into one command-block card.
    final streamItems = <Widget>[];
    for (var i = 0; i < _out.length;) {
      final l = _out[i];
      if (l.kind == _Kind.prompt && l.elapsedMs != null) {
        final j = _blockEnd(i);
        streamItems.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _commandBlock(i, j, t),
        ));
        i = j + 1;
      } else {
        streamItems.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: SelectableText(
            l.text.isEmpty ? ' ' : l.text,
            style: Ts.style(
              size: Ts.lg,
              color: _color(l.kind, t),
              monoFont: true,
              height: 1.35,
            ),
          ),
        ));
        i++;
      }
    }

    return ColoredBox(
      color: t.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // These anchors remain mounted while the bounded viewport changes state.
          _toolbar(t, connected),
          const CodexDivider(),
          Expanded(
            child: CodexStateShell(
              key: const ValueKey('cmd-console-state'),
              state: state,
              content: CodexSurface(
                variant: CodexSurfaceVariant.sunken,
                padding: EdgeInsets.zero,
                child: _out.isEmpty
                    ? _welcome(t)
                    : ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                        children: streamItems,
                      ),
              ),
              message: failed
                  ? tr('cmd.instanceFailedToStart')
                  : !widget.running
                      ? tr('cmd.instanceNotRunning')
                      : _everConnected
                          ? tr('cmd.reconnecting')
                          : tr('cmd.connecting'),
              detail: failed
                  ? reason
                  : !widget.running
                      ? tr('cmd.startConfigHint')
                      : '${widget.host}:${widget.port}',
              icon: !widget.running && !failed
                  ? const Icon(Icons.play_circle_outline, size: 22)
                  : null,
              bodyPadding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            ),
          ),
          // The completion/history slot keeps its footprint when dismissed, so
          // command submission and Escape never move the viewport or input anchor.
          SizedBox(
            height: 32,
            child: ColoredBox(
              color: t.panel,
              child: Visibility(
                visible: _showChips,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: ExcludeFocus(
                  key: const ValueKey('cmd-console-helper-focus'),
                  excluding: !_showChips || !connected,
                  child: IgnorePointer(
                    ignoring: !connected,
                    child: _chipTray(t),
                  ),
                ),
              ),
            ),
          ),
          const CodexDivider(),
          Container(
            key: const ValueKey('cmd-console-input-anchor'),
            color: t.panel,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (widget.backendDegraded || _sawBackendErrorAt != null) ...[
                  Tooltip(
                    message: backendDegradedTooltip(widget.backendError),
                    waitDuration: const Duration(milliseconds: 250),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: t.warning,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  _connecting ? '${tr('cmd.connectingPrompt')} ' : _prompt,
                  style: Ts.style(
                    size: Ts.lg,
                    color: promptColor,
                    monoFont: true,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (!connected) return KeyEventResult.ignored;
                      if (event is KeyDownEvent) {
                        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                          _recall(-1);
                          return KeyEventResult.handled;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                          _recall(1);
                          return KeyEventResult.handled;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.escape) {
                          setState(() => _showChips = false);
                          return KeyEventResult.handled;
                        }
                      }
                      return KeyEventResult.ignored;
                    },
                    child: CodexTextField(
                      controller: _input,
                      focusNode: _focus,
                      autofocus: connected,
                      enabled: connected,
                      onChanged: (_) => setState(() {}),
                      style: Ts.style(
                        size: Ts.lg,
                        weight: FontWeight.w600,
                        color: t.text,
                        monoFont: true,
                      ),
                      decoration: InputDecoration(
                        hintText: connected
                            ? tr('cmd.typeCommandHint')
                            : tr('cmd.notConnected'),
                        hintStyle: Ts.style(
                          size: Ts.lg,
                          color: t.text3,
                          monoFont: true,
                        ),
                      ),
                      onSubmitted: _submit,
                    ),
                  ),
                ),
                if (widget.running && !connected && !_connecting) ...[
                  const SizedBox(width: 8),
                  CodexButton(
                    semanticLabel: tr('cmd.reconnect'),
                    onPressed: _connect,
                    icon: const Icon(Icons.refresh, size: 15),
                    label: Text(tr('cmd.reconnect')),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // v2.3 console toolbar: connection identity + state on the left, History /
  // Clear on the right. (The screen breadcrumb lives in the global TopBar.)
  Widget _toolbar(AppTokens t, bool connected) {
    return Container(
      key: const ValueKey('cmd-console-toolbar-anchor'),
      height: 42, // mockup .console-toolbar 42h (logs_page precedent)
      color: t.panel,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        // Mockup .console-toolbar left: a 28px .inst-crumb-style chip with a
        // status dot before the identity text (pixel-fidelity-v23 CP 9.x).
        // Mockup .console-toolbar left: a .inst-crumb chip — status dot +
        // bold instance name + "· dbN" (no >_ glyph, no RESP pill). Legacy
        // host:port chip when no instance name is provided.
        Container(
          height: 28, // mockup .inst-crumb inline height:28
          padding: EdgeInsets.symmetric(
              horizontal: widget.instanceName != null ? 12 : 10),
          decoration: BoxDecoration(
            color: t.panel2,
            borderRadius: BorderRadius.circular(Dim.radiusS),
            border: Border.all(color: t.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 7,
                height: 7, // mockup .dot
                decoration: BoxDecoration(
                    color: connected ? t.success : t.text3,
                    shape: BoxShape.circle)),
            if (widget.instanceName != null) ...[
              const SizedBox(width: 8), // mockup .inst-crumb gap:8
              Text(widget.instanceName!,
                  style: Ts.style(
                      size: 12.5, weight: FontWeight.w600, color: t.text)),
              const SizedBox(width: 8),
              Text('· db$_db',
                  style: Ts.style(
                      size: 12.5, weight: FontWeight.w600, color: t.text)),
            ] else ...[
              const SizedBox(width: 7),
              Text('>_',
                  style: Ts.style(
                      size: Ts.md,
                      weight: FontWeight.w700,
                      color: t.accent,
                      monoFont: true)),
              const SizedBox(width: 6),
              Text('${widget.host}:${widget.port}${_db > 0 ? ' · db$_db' : ''}',
                  style: Ts.style(
                      size: Ts.sm,
                      color: t.text2,
                      monoFont: true,
                      tabularNums: true)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: connected ? t.selection : t.panel,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: connected ? t.success : t.border),
                ),
                child: Text('RESP',
                    style: Ts.style(
                        size: Ts.xs,
                        weight: FontWeight.w700,
                        color: connected ? t.success : t.text3)),
              ),
            ],
          ]),
        ),
        // Mockup .empty-note after the crumb: "RESP3 · 已连接 <b>2h 14m</b>".
        if (widget.connectedLabel != null) ...[
          const SizedBox(width: 8),
          Text('RESP3 · 已连接 ', style: Ts.style(size: Ts.md, color: t.text3)),
          Text(widget.connectedLabel!,
              style: Ts.style(
                  size: Ts.md, weight: FontWeight.w600, color: t.text2)),
        ],
        const Spacer(),
        CodexButton(
          semanticLabel: 'History',
          onPressed: () => setState(() => _showChips = !_showChips),
          icon: Icon(
            Icons.history,
            size: 14,
            color: _showChips ? t.accent : t.text2,
          ),
          label: const Text('History'),
        ),
        const SizedBox(width: 8),
        CodexButton(
          semanticLabel: tr('cmd.clear'),
          onPressed: _clearOut,
          icon: const Icon(Icons.clear_all, size: 14),
          label: Text(tr('cmd.clear')),
        ),
      ]),
    );
  }

  // The completion tray above the input: suggestion chips on the left, recent
  // history (most recent last) on the right when there is room.
  Widget _chipTray(AppTokens t) {
    final chips = _chipSuggestions;
    final recent = _history.length <= 1
        ? const <String>[]
        : _history.reversed.take(4).toList();
    return Container(
      color: t.panel,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final c in chips) ...[
                _chip(c, t, onTap: () => _applyChip(c), filled: true),
                const SizedBox(width: 6),
              ],
            ]),
          ),
        ),
        if (recent.isNotEmpty) ...[
          const SizedBox(width: 10),
          Icon(Icons.history, size: 13, color: t.text3),
          const SizedBox(width: 5),
          for (final h in recent) ...[
            _chip(h, t, onTap: () => _insertHistory(h), filled: false),
            const SizedBox(width: 6),
          ],
        ],
      ]),
    );
  }

  Widget _chip(String label, AppTokens t,
      {required VoidCallback onTap, required bool filled}) {
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: filled ? t.selection : Colors.transparent,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: filled ? t.accent : t.border),
        ),
        child: Text(label,
            overflow: TextOverflow.ellipsis,
            style: Ts.style(
                size: Ts.xs,
                color: filled ? t.accent : t.text3,
                monoFont: true,
                tabularNums: true)),
      ),
    );
  }

  // Index of the last scrollback line belonging to the command block that
  // starts at prompt line [i] (i.e. the line before the next prompt, or the
  // final line).
  int _blockEnd(int i) {
    var j = i;
    while (j + 1 < _out.length && _out[j + 1].kind != _Kind.prompt) {
      j++;
    }
    return j;
  }

  // One command block card (mockup .cmd-block): a bordered card with a panel-2
  // head band (prompt + command left, elapsed badge right, >200ms warning) over
  // the command's output lines. Blocks are spaced 12px apart (the stream's
  // padding/gap come from the ListView, not here).
  Widget _commandBlock(int start, int end, AppTokens t) {
    final head = _out[start];
    final slow = head.elapsedMs! > 200;
    return CodexSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              color: t.panel2,
              border: Border(bottom: BorderSide(color: t.hairline)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
            child: Row(children: [
              Expanded(
                child: Row(children: [
                  if (head.promptPrefix.isNotEmpty)
                    Text(
                      head.promptPrefix,
                      style: Ts.style(
                        size: Ts.md,
                        color: t.accent,
                        monoFont: true,
                        height: 1.35,
                      ),
                    ),
                  Flexible(
                    child: SelectableText(
                      head.text.isEmpty ? ' ' : head.text,
                      style: Ts.style(
                        size: Ts.lg,
                        weight: FontWeight.w600,
                        color: t.text,
                        monoFont: true,
                        height: 1.35,
                      ),
                    ),
                  ),
                ]),
              ),
              if (slow) ...[
                Icon(Icons.warning_amber_rounded, size: 13, color: t.warning),
                const SizedBox(width: 4),
              ],
              Text(
                '${head.elapsedMs} ms',
                style: Ts.style(
                  size: Ts.sm,
                  weight: FontWeight.w600,
                  color: slow ? t.warning : t.text2,
                  monoFont: true,
                  tabularNums: true,
                ),
              ),
            ]),
          ),
          if (end > start)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var k = start + 1; k <= end; k++)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: SelectableText(
                        _out[k].text.isEmpty ? ' ' : _out[k].text,
                        style: Ts.style(
                          size: Ts.md,
                          color: _color(_out[k].kind, t),
                          weight: _weight(_out[k].kind),
                          monoFont: true,
                          height: 1.4,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // Empty-console welcome: a compact redis-cli banner and shared action
  // primitives, painted entirely from the active Codex token set.
  Widget _welcome(AppTokens t) {
    const examples = [
      'PING',
      'SET greeting "hello"',
      'GET greeting',
      'SCAN 0 COUNT 20',
      'TYPE greeting',
      'INFO server',
    ];
    final mono = Ts.style(
      size: 12.5,
      height: 1.55,
      color: t.text3,
      monoFont: true,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.terminal, size: 18, color: t.accent),
            const SizedBox(width: 8),
            Text(
              'redimos-cli',
              style: Ts.style(
                size: Ts.lg,
                weight: FontWeight.w700,
                color: t.text,
                monoFont: true,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Text(
            '${tr('cmd.connectedTo')} ${widget.host}:${widget.port} ${tr('cmd.redisCompatible')}',
            style: mono,
          ),
          Text(tr('cmd.scanTip'), style: mono),
          const SizedBox(height: 16),
          Text(tr('cmd.tryCommand'), style: mono.copyWith(color: t.text)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final command in examples) _cmdChip(command, t)],
          ),
          const SizedBox(height: 18),
          Text(
            tr('cmd.historyHint'),
            style: mono.copyWith(fontSize: Ts.md),
          ),
        ],
      ),
    );
  }

  Widget _cmdChip(String command, AppTokens t) => CodexButton(
        semanticLabel: command,
        onPressed: () {
          _input.text = command;
          _input.selection = TextSelection.collapsed(offset: command.length);
          _focus.requestFocus();
        },
        label: Text(
          command,
          style: Ts.style(
            size: Ts.sm,
            color: t.text2,
            monoFont: true,
          ),
        ),
      );
}
