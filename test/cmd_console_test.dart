// Unit tests for the redis-cli console helpers, plus a live integration test
// that drives the RESP client against a real redimos when REDIMOS_TEST_PORT is
// set (see scratchpad/run_cmd_test.sh which starts one first).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/cmd_console.dart';

void main() {
  group('tokenize', () {
    test('simple whitespace split', () {
      expect(tokenize('SET k v'), ['SET', 'k', 'v']);
    });
    test('collapses repeated spaces', () {
      expect(tokenize('  PING   '), ['PING']);
    });
    test('double quotes keep spaces', () {
      expect(tokenize('SET k "a b c"'), ['SET', 'k', 'a b c']);
    });
    test('single quotes literal', () {
      expect(tokenize(r"SET k 'a\nb'"), ['SET', 'k', r'a\nb']);
    });
    test('double-quote escapes', () {
      expect(tokenize(r'SET k "a\nb\t"'), ['SET', 'k', 'a\nb\t']);
    });
    test('unbalanced quote is an error', () {
      expect(tokenize('SET k "oops'), isNull);
    });
  });

  group('formatReply (redis-cli style)', () {
    test('status without quotes', () => expect(formatReply(RespStatus('OK')), 'OK'));
    test('error', () => expect(formatReply(RespError('ERR nope')), '(error) ERR nope'));
    test('integer', () => expect(formatReply(7), '(integer) 7'));
    test('nil', () => expect(formatReply(null), '(nil)'));
    test('bulk string quoted', () => expect(formatReply('hi'), '"hi"'));
    test('bulk string escapes', () => expect(formatReply('a\nb'), r'"a\nb"'));
    test('flat array numbered', () {
      expect(formatReply(['a', 'b', 'c']), '1) "a"\n2) "b"\n3) "c"');
    });
    test('empty array', () => expect(formatReply(<Object?>[]), '(empty array)'));
    test('nested array indents', () {
      expect(formatReply([
        'x',
        [1, 2],
      ]), '1) "x"\n2) 1) (integer) 1\n   2) (integer) 2');
    });
  });

  test('RespParser handles a split bulk string across chunks', () {
    final p = RespParser();
    p.addBytes('\$5\r\nhel'.codeUnits);
    expect(identical(p.next(), RespParser.incomplete), isTrue);
    p.addBytes('lo\r\n'.codeUnits);
    expect(p.next(), 'hello');
  });

  final portStr = Platform.environment['REDIMOS_TEST_PORT'];
  test('live redis-cli round-trips against a real redimos', () async {
    if (portStr == null || portStr.isEmpty) {
      markTestSkipped('set REDIMOS_TEST_PORT to run the live test');
      return;
    }
    final port = int.parse(portStr);
    final c = RedisConsoleClient('127.0.0.1', port);
    await c.connect();
    addTearDown(c.close);

    expect(await c.command(['PING']), isA<RespStatus>());
    expect((await c.command(['SET', 'cli:k', 'hello'])), isA<RespStatus>());
    expect(await c.command(['GET', 'cli:k']), 'hello');
    expect(await c.command(['INCR', 'cli:n']), isA<int>());
    expect(await c.command(['GET', 'cli:absent-${DateTime.now().microsecondsSinceEpoch}']), isNull);
    expect(await c.command(['NOTACOMMAND']), isA<RespError>());
    // multi-value reply
    await c.command(['RPUSH', 'cli:list', 'a', 'b']);
    final range = await c.command(['LRANGE', 'cli:list', '0', '-1']);
    expect(range, isA<List>());
  }, timeout: const Timeout(Duration(seconds: 25)));
}
