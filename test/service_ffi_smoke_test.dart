// Stage 10.5: Dart FFI smoke for the seven new Service symbols. Runs against
// the real c-shared dylib and a FAKE JRE (written by this test), fully
// sandboxed via REDIMOS_STORE_PATH — it never touches ~/.redimos.
//
// The Go core reads its environment at library load, so the sandbox must be
// arranged BEFORE the process starts. When the environment is missing the
// whole file skips with the runner invocation instead of failing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/native.dart';

void main() {
  final env = Platform.environment;
  final libPath = env['REDIMOS_CORE_LIB'] ?? '';
  final storePath = env['REDIMOS_STORE_PATH'] ?? '';
  final javaHome = env['JAVA_HOME'] ?? '';

  final ready = libPath.isNotEmpty &&
      File(libPath).existsSync() &&
      storePath.isNotEmpty &&
      javaHome.isNotEmpty;

  group('Service FFI smoke', () {
    if (!ready) {
      test('skipped: sandbox environment missing', () {
        // ignore: avoid_print
        print('run with: REDIMOS_CORE_LIB=<dylib> '
            'REDIMOS_STORE_PATH=<sandbox>/store.json '
            'JAVA_HOME=<sandbox>/fakejdk flutter test '
            'test/service_ffi_smoke_test.dart');
      });
      return;
    }

    late NativeCore core;
    const port = 39177;

    setUpAll(() {
      // Seed the sandbox BEFORE the dylib loads: fake jar dir + store settings
      // pointing at it, and the fake JRE whose -version probe passes and
      // whose runtime binds the Service port (a tiny TCP listener).
      final sandbox = File(storePath).parent.path;
      final jarDir = Directory('$sandbox/fakejar')..createSync(recursive: true);
      File('${jarDir.path}/DynamoDBLocal.jar').writeAsBytesSync(const [0]);
      File(storePath).writeAsStringSync(
          '{"settings":{"dynamoDbLocalDir":"${jarDir.path}"}}');
      final binDir = Directory('$javaHome/bin')..createSync(recursive: true);
      final java = File('${binDir.path}/java');
      java.writeAsStringSync('''
#!/bin/bash
for a in "\$@"; do
  case "\$a" in -version|--version) echo 'fake 17'; exit 0 ;; esac
done
port=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-port" ]; then port="\$a"; fi
  prev="\$a"
done
exec python3 -c '
import socket, sys, time, signal
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(16)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    time.sleep(1)
' "\$port"
''');
      // Windows has no chmod; the smoke is a macOS/Linux dev tool.
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['+x', java.path]);
      }
      core = NativeCore();
    });

    tearDownAll(() {
      core.shutdown();
    });

    test('list/create/start/logs/restart/stop/delete closed loop', () {
      // 1. list starts empty.
      var listed = core.services();
      expect(listed.services, isEmpty);
      expect(listed.errors, isEmpty);

      // 2. create.
      final created = core.serviceSave(ServiceConfig(
        name: 'ffi-smoke',
        engine: ServiceEngine.java,
        port: port,
      ));
      expect(created.id, isNotEmpty);
      expect(created.config.name, 'ffi-smoke');
      expect(created.runtime.state, ServiceState.stopped);
      final id = created.id;

      // 3. it appears in the list.
      listed = core.services();
      expect(listed.services.map((s) => s.id), contains(id));

      // 4. duplicate name carries the taxonomy code.
      try {
        core.serviceSave(ServiceConfig(name: 'ffi-smoke', port: port + 1));
        fail('duplicate name must throw');
      } on ServiceApiException catch (e) {
        expect(e.code, 'duplicate_name');
      }

      // 5. start → running with readiness proven.
      final started = core.serviceStart(id);
      expect(started.runtime.state, ServiceState.running);
      expect(started.runtime.ready, true);
      expect(started.config.desiredRunning, true);

      // 6. start again is an invalid transition.
      try {
        core.serviceStart(id);
        fail('start-while-running must throw');
      } on ServiceApiException catch (e) {
        expect(e.code, 'invalid_transition');
      }

      // 7. logs come back (the launch line at least).
      final lines = core.serviceLogs(id);
      expect(lines, isNotEmpty);

      // 8. restart stays running.
      final restarted = core.serviceRestart(id);
      expect(restarted.runtime.state, ServiceState.running);

      // 9. Stop All snapshots the Service namespace; restore brings it back.
      final stopRes = core.stopAll();
      expect(stopRes.snapshot.services, contains(id));
      final restoreRes = core.restoreAll();
      expect(restoreRes.restored.map((e) => '${e.kind}:${e.id}'),
          contains('service:$id'));
      final afterRestore = core.services().services.firstWhere((s) => s.id == id);
      expect(afterRestore.runtime.state, ServiceState.running);

      // 10. stop, delete (data preserved by default), list empty again.
      final stopped = core.serviceStop(id);
      expect(stopped.runtime.state, ServiceState.stopped);
      final del = core.serviceDelete(id, deleteData: false);
      expect(del.dataCleaned, false);
      expect(core.services().services, isEmpty);

      // 11. ghost operations carry the taxonomy codes.
      try {
        core.serviceStart('no-such-service');
        fail('ghost start must throw');
      } on ServiceApiException catch (e) {
        expect(e.code, 'service_not_found');
      }
      try {
        core.services();
        core.serviceDelete('no-such-service', deleteData: false);
        fail('ghost delete must throw');
      } on ServiceApiException catch (e) {
        expect(e.code, 'service_not_found');
      }
    });
  });
}
