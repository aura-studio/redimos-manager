// pixel-fidelity-v23 (task #50) — test-only in-process RESP2 server.
//
// BrowserPageView / CmdConsole / CliDrawer open REAL RESP sockets
// (RedisClient / RedisConsoleClient). Under `flutter test` there is no Redis
// to talk to, so those screens freeze on "Connecting…". This fake server
// mirrors the v2.3 mockup dataset (inst-browse / inst-console) closely enough
// that the capture channel renders the same data-loaded state as the mockups.
//
// Contract honored (see the explore findings recorded in tasks.md):
//  - RESP2 only; every command gets EXACTLY one reply, strictly FIFO —
//    both clients await reply-per-command, a missed reply = permanent spinner.
//  - No greeting bytes on connect; AUTH is only sent when configured
//    (fixtures leave requirepass empty), no PING/HELLO handshake.
//  - SCAN pages: never emit a non-terminal EMPTY page (browser's do-while
//    HSCAN/SSCAN loop would resend forever on an empty non-zero cursor).
//  - SELECT always answers +OK; unknown commands answer -ERR (never silence).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class FakeRespServer {
  ServerSocket? _server;
  final _sockets = <Socket>[];

  final List<List<String>> commands = [];
  final Map<String, String> errorsByCommand = {};

  int get port => _server?.port ?? 0;
  int get connectionCount => _sockets.length;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleSocket);
  }

  /// Real-async close — call from inside `tester.runAsync`.
  Future<void> close() async {
    for (final s in List<Socket>.of(_sockets)) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _sockets.clear();
    await _server?.close();
    _server = null;
  }

  /// Polls until at least [n] clients have connected (real timers — call
  /// from inside `tester.runAsync`).
  Future<void> waitForConnections(int n,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final deadline = DateTime.now().add(timeout);
    while (connectionCount < n) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
            'FakeRespServer: expected $n connections, got $connectionCount');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  // ------------------------------------------------------------------ socket

  void _handleSocket(Socket socket) {
    _sockets.add(socket);
    final pending = BytesBuilder(copy: false);
    socket.listen(
      (data) {
        pending.add(data);
        var bytes = pending.takeBytes();
        while (true) {
          final parsed = _tryParseCommand(bytes);
          if (parsed == null) break;
          final args = parsed.$1;
          bytes = bytes.sublist(parsed.$2);
          socket.add(_dispatch(args));
        }
        if (bytes.isNotEmpty) pending.add(bytes);
      },
      onDone: () => _sockets.remove(socket),
      onError: (_) => _sockets.remove(socket),
      cancelOnError: true,
    );
  }

  /// Parses ONE RESP2 command array off the head of [bytes].
  /// Returns (args, consumedBytes) or null when incomplete.
  (List<String>, int)? _tryParseCommand(Uint8List bytes) {
    var pos = 0;

    int? readLineEnd() {
      for (var i = pos; i + 1 < bytes.length; i++) {
        if (bytes[i] == 0x0D && bytes[i + 1] == 0x0A) return i;
      }
      return null;
    }

    String? readLine() {
      final end = readLineEnd();
      if (end == null) return null;
      final line = utf8.decode(bytes.sublist(pos, end), allowMalformed: true);
      pos = end + 2;
      return line;
    }

    if (bytes.isEmpty || bytes[0] != 0x2A /* '*' */) return null;
    final countLine = readLine();
    if (countLine == null) return null;
    final n = int.tryParse(countLine.substring(1));
    if (n == null || n < 0) return null;

    final args = <String>[];
    for (var i = 0; i < n; i++) {
      if (pos >= bytes.length || bytes[pos] != 0x24 /* '$' */) return null;
      final lenLine = readLine();
      if (lenLine == null) return null;
      final len = int.tryParse(lenLine.substring(1));
      if (len == null || len < 0) return null;
      if (pos + len + 2 > bytes.length) return null;
      args.add(
          utf8.decode(bytes.sublist(pos, pos + len), allowMalformed: true));
      pos += len + 2;
    }
    return (args, pos);
  }

  // ---------------------------------------------------------------- encoding

  static Uint8List _enc(String s) => Uint8List.fromList(utf8.encode(s));

  static Uint8List _status(String s) => _enc('+$s\r\n');
  static Uint8List _error(String s) => _enc('-$s\r\n');
  static Uint8List _int(int i) => _enc(':$i\r\n');

  static Uint8List _bulk(String? s) {
    if (s == null) return _enc(r'$-1' '\r\n');
    final b = utf8.encode(s);
    return Uint8List.fromList(
        [...utf8.encode('\$${b.length}\r\n'), ...b, 0x0D, 0x0A]);
  }

  static Uint8List _array(List<Uint8List> items) {
    final out = BytesBuilder(copy: false);
    out.add(_enc('*${items.length}\r\n'));
    for (final i in items) {
      out.add(i);
    }
    return out.takeBytes();
  }

  // ----------------------------------------------------------------- dataset

  /// The v2.3 mockup's key space (inst-browse sidebar):
  /// user:* (4 visible leaves), session:* 54, cache:product:* 312, plus five
  /// single keys. The app sidebar header shows `_keys.length` — 375 here, so
  /// it reads "375 keys+" (mockup's decorative "1,024" is unreachable without
  /// flooding the visible tree; recorded as a known data-state divergence).
  static final Map<String, String> keyTypes = () {
    final m = <String, String>{
      'user:1001': 'hash',
      'user:1002': 'hash',
      'user:1003': 'string',
      'user:1004:profile': 'string',
      'config:feature_flags': 'hash',
      'queue:email_jobs': 'list',
      'leaderboard:global': 'zset',
      'tags:article:77': 'set',
      'events:audit_stream': 'stream',
    };
    for (var i = 1; i <= 53; i++) {
      m['session:token:${i.toString().padLeft(3, '0')}'] = 'string';
    }
    m['session:token:9f3a'] = 'string';
    for (var i = 1; i <= 312; i++) {
      m['cache:product:p${i.toString().padLeft(3, '0')}'] = 'string';
    }
    return m;
  }();

  /// Mockup value pane for user:1001 (hash, 6 fields, insertion order kept —
  /// the vtable renders the HSCAN reply order verbatim).
  static const List<List<String>> user1001Fields = [
    ['name', 'Tony Chen'],
    ['email', 'tony@example.com'],
    ['plan', 'pro'],
    ['created_at', '1735689600'],
    ['last_login', '2026-08-05T06:12:44Z'],
    ['prefs', '{"theme":"dark","lang":"zh-CN"}'],
  ];

  static const List<String> emailJobs = [
    'job:send-welcome-email',
    'job:reset-password',
  ];

  // ---------------------------------------------------------------- dispatch

  Uint8List _dispatch(List<String> args) {
    if (args.isEmpty) return _error('ERR empty command');
    commands.add(List<String>.of(args));
    final cmd = args[0].toUpperCase();
    final configuredError = errorsByCommand[cmd];
    if (configuredError != null) return _error(configuredError);
    final key = args.length > 1 ? args[1] : '';

    switch (cmd) {
      case 'AUTH':
      case 'SELECT':
      case 'PING':
        return cmd == 'PING' ? _status('PONG') : _status('OK');
      case 'SCAN':
        return _scan(args);
      case 'KEYS':
        return _array(
            _matchGlob(args.length > 1 ? args[1] : '*').map(_bulk).toList());
      case 'DBSIZE':
        return _int(keyTypes.length);
      case 'TYPE':
        return _status(keyTypes[key] ?? 'none');
      case 'TTL':
      case 'PTTL':
        return _int(-1);
      case 'EXISTS':
        return _int(keyTypes.containsKey(key) ? 1 : 0);
      case 'HLEN':
        return _int(key == 'user:1001' ? user1001Fields.length : 0);
      case 'HSCAN':
        return _array([
          _bulk('0'), // terminal cursor — never a non-zero empty page
          _array([
            for (final f in user1001Fields) ...[_bulk(f[0]), _bulk(f[1])],
          ]),
        ]);
      case 'HGETALL':
        return _array([
          for (final f in user1001Fields) ...[_bulk(f[0]), _bulk(f[1])],
        ]);
      case 'HGET':
        final field = args.length > 2 ? args[2] : '';
        final hit = user1001Fields.where((f) => f[0] == field).toList();
        return _bulk(hit.isEmpty ? null : hit.first[1]);
      case 'LLEN':
        return _int(key == 'queue:email_jobs' ? emailJobs.length : 0);
      case 'LRANGE':
        return _array(emailJobs.map(_bulk).toList());
      case 'GET':
      case 'STRLEN':
        if (cmd == 'STRLEN') return _int(5);
        return _bulk(key == 'user:1003' ? 'ada' : null);
      case 'SET':
      case 'EXPIRE':
      case 'PERSIST':
      case 'DEL':
        return cmd == 'DEL' ? _int(1) : _status('OK');
      case 'MEMORY':
        // MEMORY USAGE user:1001 — the mockup console's third command.
        return _int(412);
      case 'INFO':
        return _bulk(
            '# Server\r\nredis_version:7.2.0\r\nuptime_in_seconds:8040\r\n');
      default:
        return _error("ERR unknown command '$cmd'");
    }
  }

  Uint8List _scan(List<String> args) {
    // SCAN <cursor> [MATCH pat] [COUNT n]
    var match = '*';
    for (var i = 1; i + 1 < args.length; i++) {
      if (args[i].toUpperCase() == 'MATCH') match = args[i + 1];
    }
    final keys = _matchGlob(match);
    // First page returns EVERYTHING with a non-zero cursor: the sidebar then
    // shows the full tree plus the mockup's Load more / Load all footer.
    return _array([
      _bulk('375'),
      _array(keys.map(_bulk).toList()),
    ]);
  }

  List<String> _matchGlob(String pattern) {
    if (pattern == '*' || pattern.isEmpty) return keyTypes.keys.toList();
    final escaped =
        RegExp.escape(pattern).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
    final re = RegExp('^$escaped\$');
    return keyTypes.keys.where((k) => re.hasMatch(k)).toList();
  }
}
