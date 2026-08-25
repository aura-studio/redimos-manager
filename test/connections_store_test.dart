import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/redis_connection.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('redimos-connections');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('connections round-trip through the prefs file', () {
    final saved = [
      const RedisConnection(
          id: 'conn-1',
          name: 'local',
          host: '127.0.0.1',
          port: 6380,
          password: 'pw',
          database: 3),
      const RedisConnection(id: 'conn-2', name: 'remote', host: '10.0.0.9'),
    ];
    saveConnections(saved, dir: dir);

    final loaded = loadConnections(dir: dir);
    expect(loaded, hasLength(2));
    expect(loaded[0].id, 'conn-1');
    expect(loaded[0].port, 6380);
    expect(loaded[0].password, 'pw');
    expect(loaded[0].database, 3);
    expect(loaded[1].host, '10.0.0.9');
    expect(loaded[1].tls, isFalse);
  });

  test('missing and corrupt files load as an empty list', () {
    expect(loadConnections(dir: dir), isEmpty);

    File('${dir.path}/connections.json').writeAsStringSync('{not json');
    expect(loadConnections(dir: dir), isEmpty);
  });

  test('save is atomic and the last write wins', () {
    saveConnections(const [RedisConnection(id: 'a')], dir: dir);
    saveConnections(const [RedisConnection(id: 'b')], dir: dir);

    final loaded = loadConnections(dir: dir);
    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'b');
    // The tmp file is renamed away on success.
    expect(File('${dir.path}/connections.json.tmp').existsSync(), isFalse);
  });
}
