// A minimal RESP client with typed command helpers, for the Browser tab (and
// anything else that needs to talk Redis to a running redimos proxy). Speaks
// RESP over a plain TCP socket to 127.0.0.1:<port>, same transport the Cmd
// console uses. Kept self-contained (its own tiny parser) so the working Cmd
// page stays untouched.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class RespStatus {
  final String text;
  RespStatus(this.text);
}

class RespError {
  final String message;
  RespError(this.message);
}

class _Parsed {
  final Object? value;
  final int end;
  _Parsed(this.value, this.end);
}

/// Incremental RESP parser over a growing byte buffer.
class RespParser {
  static final Object incomplete = Object();
  final List<int> _buf = [];

  void addBytes(List<int> b) => _buf.addAll(b);

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

  String _decode(int a, int b) => utf8.decode(_buf.sublist(a, b), allowMalformed: true);

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
        final e = _crlf(i + 1);
        return e < 0 ? null : _Parsed(RespStatus(_decode(i, e)), e + 2);
    }
  }
}

/// A RESP command failed (server -ERR reply or transport error).
class RedisException implements Exception {
  final String message;
  RedisException(this.message);
  @override
  String toString() => message;
}

/// One page of a SCAN family cursor walk.
class ScanPage {
  final String cursor; // "0" = walk complete
  final List<String> items;
  ScanPage(this.cursor, this.items);
  bool get done => cursor == '0';
}

/// RESP client with typed helpers for the key browser.
class RedisClient {
  final String host;
  final int port;
  final String? auth;
  Socket? _sock;
  final _parser = RespParser();
  final Queue<Completer<Object?>> _pending = Queue();
  bool connected = false;
  void Function(Object error)? onClosed;

  RedisClient(this.host, this.port, {this.auth});

  Future<void> connect() async {
    _sock = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    connected = true;
    _sock!.listen(_onData,
        onError: (Object e) => _fail(e),
        onDone: () => _fail('connection closed by server'),
        cancelOnError: true);
    if (auth != null && auth!.trim().isNotEmpty) {
      await command(['AUTH', auth!]);
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

  /// Raw command → raw reply (String / int / List / null / RespStatus / RespError).
  Future<Object?> command(List<String> args) {
    final s = _sock;
    if (s == null || !connected) return Future.error(RedisException('not connected'));
    final c = Completer<Object?>();
    _pending.add(c);
    s.add(_encode(args));
    return c.future;
  }

  /// Command that throws [RedisException] on an -ERR reply.
  Future<Object?> call(List<String> args) async {
    final r = await command(args);
    if (r is RespError) throw RedisException(r.message);
    return r;
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
      _pending.removeFirst().completeError(e is RedisException ? e : RedisException('$e'));
    }
    if (wasConnected) onClosed?.call(e);
  }

  void close() {
    connected = false;
    _sock?.destroy();
    _sock = null;
    _pending.clear();
  }

  // ---- typed helpers ----

  String _s(Object? v) => v is RespStatus ? v.text : (v?.toString() ?? '');

  Future<void> select(int db) => call(['SELECT', '$db']).then((_) {});

  /// One SCAN page. redimos disables KEYS, so listing always goes through SCAN.
  Future<ScanPage> scan(String cursor, {String match = '*', int count = 200}) async {
    final r = await call(['SCAN', cursor, 'MATCH', match, 'COUNT', '$count']);
    final list = (r as List?) ?? [];
    final cur = list.isNotEmpty ? _s(list[0]) : '0';
    final keys = list.length > 1 ? ((list[1] as List?) ?? []).map(_s).toList() : <String>[];
    return ScanPage(cur, keys);
  }

  Future<String> type(String key) async => _s(await call(['TYPE', key]));

  Future<int> ttl(String key) async => (await call(['TTL', key]) as int?) ?? -1;

  Future<void> expire(String key, int seconds) => call(['EXPIRE', key, '$seconds']);
  Future<void> persist(String key) => call(['PERSIST', key]);
  Future<void> del(String key) => call(['DEL', key]);

  Future<String?> get(String key) async => (await call(['GET', key])) as String?;
  Future<void> set(String key, String value) => call(['SET', key, value]);

  Future<Map<String, String>> hgetall(String key) async {
    final list = (await call(['HGETALL', key]) as List?) ?? [];
    final out = <String, String>{};
    for (var i = 0; i + 1 < list.length; i += 2) {
      out[_s(list[i])] = _s(list[i + 1]);
    }
    return out;
  }

  Future<void> hset(String key, String field, String value) => call(['HSET', key, field, value]);
  Future<void> hdel(String key, String field) => call(['HDEL', key, field]);

  Future<List<String>> lrange(String key, int start, int stop) async =>
      ((await call(['LRANGE', key, '$start', '$stop']) as List?) ?? []).map(_s).toList();
  Future<void> rpush(String key, String value) => call(['RPUSH', key, value]);
  Future<void> lset(String key, int index, String value) => call(['LSET', key, '$index', value]);
  Future<void> lrem(String key, int count, String value) => call(['LREM', key, '$count', value]);

  Future<List<String>> smembers(String key) async =>
      ((await call(['SMEMBERS', key]) as List?) ?? []).map(_s).toList();
  Future<void> sadd(String key, String member) => call(['SADD', key, member]);
  Future<void> srem(String key, String member) => call(['SREM', key, member]);

  /// ZSet as ordered (member, score) pairs (ascending by score).
  Future<List<(String, String)>> zrange(String key, int start, int stop) async {
    final list = (await call(['ZRANGE', key, '$start', '$stop', 'WITHSCORES']) as List?) ?? [];
    final out = <(String, String)>[];
    for (var i = 0; i + 1 < list.length; i += 2) {
      out.add((_s(list[i]), _s(list[i + 1])));
    }
    return out;
  }

  Future<void> zadd(String key, String score, String member) => call(['ZADD', key, score, member]);
  Future<void> zrem(String key, String member) => call(['ZREM', key, member]);

  // ---- in-key pagination helpers (so large keys don't load all at once) ----

  Future<int> llen(String key) async => (await call(['LLEN', key]) as int?) ?? 0;
  Future<int> hlen(String key) async => (await call(['HLEN', key]) as int?) ?? 0;
  Future<int> scard(String key) async => (await call(['SCARD', key]) as int?) ?? 0;
  Future<int> zcard(String key) async => (await call(['ZCARD', key]) as int?) ?? 0;
  Future<void> lpush(String key, String value) => call(['LPUSH', key, value]);

  /// One HSCAN page: (nextCursor, [(field, value)]). Cursor "0" = walk complete.
  Future<(String, List<(String, String)>)> hscan(String key, String cursor,
      {String match = '*', int count = 200}) async {
    final r = await call(['HSCAN', key, cursor, 'MATCH', match, 'COUNT', '$count']);
    final list = (r as List?) ?? [];
    final cur = list.isNotEmpty ? _s(list[0]) : '0';
    final flat = list.length > 1 ? ((list[1] as List?) ?? const []) : const [];
    final out = <(String, String)>[];
    for (var i = 0; i + 1 < flat.length; i += 2) {
      out.add((_s(flat[i]), _s(flat[i + 1])));
    }
    return (cur, out);
  }

  /// One SSCAN page: (nextCursor, [member]). Cursor "0" = walk complete.
  Future<(String, List<String>)> sscan(String key, String cursor,
      {String match = '*', int count = 200}) async {
    final r = await call(['SSCAN', key, cursor, 'MATCH', match, 'COUNT', '$count']);
    final list = (r as List?) ?? [];
    final cur = list.isNotEmpty ? _s(list[0]) : '0';
    final items = list.length > 1 ? ((list[1] as List?) ?? const []).map(_s).toList() : <String>[];
    return (cur, items);
  }
}
