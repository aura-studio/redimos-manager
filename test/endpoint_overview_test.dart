import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/endpoint_detail.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_status.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';

class _OverviewCore extends FakeNativeCore {
  final responses = <Map<String, dynamic>>[];
  final pending = <Completer<Map<String, dynamic>>>[];
  final configs = <RedimosConfig>[];
  final unexpectedCalls = <Symbol>[];

  @override
  Future<Map<String, dynamic>> epListTables(RedimosConfig config) {
    configs.add(config);
    if (responses.isNotEmpty) {
      return Future.value(responses.removeAt(0));
    }
    final load = Completer<Map<String, dynamic>>();
    pending.add(load);
    return load.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls.add(invocation.memberName);
    return super.noSuchMethod(invocation);
  }
}

const _awsEndpoint = DdbEndpoint(
  id: 'endpoint-aws',
  name: 'Production AWS',
  kind: 'url',
  endpoint: 'https://dynamodb.us-west-2.amazonaws.com',
  partitionID: 'aws',
  region: 'us-west-2',
  accessKeyId: 'AKIA1234567890WXYZ',
  secretKey: 'never-render-this-secret',
  sessionToken: 'never-render-this-session-token',
);

Widget _app({
  required Brightness brightness,
  required _OverviewCore core,
  DdbEndpoint endpoint = _awsEndpoint,
  VoidCallback? onEdit,
}) =>
    MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(
        body: EndpointOverviewPane(
          core: core,
          endpoint: endpoint,
          config: endpoint.toStorageConfig(),
          onEdit: onEdit,
        ),
      ),
    );

Future<void> _pumpOverview(
  WidgetTester tester, {
  required Brightness brightness,
  required _OverviewCore core,
  DdbEndpoint endpoint = _awsEndpoint,
  VoidCallback? onEdit,
  bool settleProbe = true,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(
    brightness: brightness,
    core: core,
    endpoint: endpoint,
    onEdit: onEdit,
  ));
  if (settleProbe) {
    // Keep fake time fixed so the DateTime-based latency remains deterministic.
    await tester.pump();
    await tester.pump();
  }
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'Endpoint Overview renders successful metadata in ${brightness.name}',
      (tester) async {
        final core = _OverviewCore()
          ..responses.addAll([
            {
              'ok': true,
              'tables': const [
                {'name': 'users'},
                {'name': 'sessions'},
              ],
            },
            {
              'ok': true,
              'tables': const [
                {'name': 'users'},
              ],
            },
          ]);
        var editCalls = 0;

        await _pumpOverview(
          tester,
          brightness: brightness,
          core: core,
          onEdit: () => editCalls++,
        );

        expect(find.byType(CodexSurface), findsNWidgets(2));
        expect(find.byType(CodexButton), findsNWidgets(2));
        expect(find.byType(CodexStatusIndicator), findsNWidgets(2));
        expect(
          find.byKey(const ValueKey('endpoint-overview-backend-card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('endpoint-overview-reachability-card')),
          findsOneWidget,
        );
        expect(find.text('Production AWS'), findsOneWidget);
        expect(find.text('DynamoDB-compatible'), findsOneWidget);
        expect(find.text(_awsEndpoint.endpoint), findsOneWidget);
        expect(find.text('us-west-2'), findsOneWidget);
        expect(find.text('AK •••WXYZ'), findsOneWidget);
        expect(find.text(_awsEndpoint.accessKeyId), findsNothing);
        expect(find.textContaining(_awsEndpoint.secretKey), findsNothing);
        expect(find.textContaining(_awsEndpoint.sessionToken), findsNothing);
        expect(find.text(tr('ep.ovReadOnlyNote')), findsOneWidget);
        expect(find.text(tr('ep.ovReachable')), findsNWidgets(2));
        expect(find.textContaining(RegExp(r'^\d+ ms$')), findsOneWidget);
        expect(core.configs, hasLength(1));
        expect(core.configs.single.endpoint, _awsEndpoint.endpoint);
        expect(core.configs.single.region, _awsEndpoint.region);
        expect(core.configs.single.accessKeyId, _awsEndpoint.accessKeyId);
        expect(core.unexpectedCalls, isEmpty,
            reason: 'Overview may only call the read-only table-list probe');

        await tester.tap(find.widgetWithText(OutlinedButton, 'Edit'));
        expect(editCalls, 1);

        await tester.tap(
          find.widgetWithText(OutlinedButton, tr('ep.ovRecheck')),
        );
        await tester.pump();
        await tester.pump();
        expect(core.configs, hasLength(2));
        expect(find.text(tr('ep.ovReachable')), findsNWidgets(2));
        expect(core.unexpectedCalls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Endpoint Overview renders an AWS probe failure without secrets',
      (tester) async {
    const endpoint = DdbEndpoint(
      id: 'endpoint-cn',
      name: 'China AWS',
      kind: 'url',
      endpoint: 'https://dynamodb.cn-north-1.amazonaws.com.cn',
      region: 'cn-north-1',
      accessKeyId: 'AKIAFAIL1234TAIL',
      secretKey: 'failure-secret-must-stay-hidden',
    );
    final core = _OverviewCore()
      ..responses.add({
        'ok': false,
        'error': 'AccessDenied: read-only probe failed',
      });

    await _pumpOverview(
      tester,
      brightness: Brightness.dark,
      core: core,
      endpoint: endpoint,
    );

    expect(find.text(tr('ep.ovReadOnlyNote')), findsOneWidget,
        reason: 'explicit amazonaws.com.cn URLs must remain read-only');
    expect(find.text(tr('ep.ovUnreachable')), findsNWidgets(2));
    expect(find.text('AccessDenied: read-only probe failed'), findsOneWidget);
    expect(find.text('AK •••TAIL'), findsOneWidget);
    expect(find.text(endpoint.accessKeyId), findsNothing);
    expect(find.textContaining(endpoint.secretKey), findsNothing);
    expect(core.configs, hasLength(1));
    expect(core.unexpectedCalls, isEmpty,
        reason: 'a failed AWS probe must not fall through to a mutation');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Endpoint Overview keeps Re-check disabled while probing',
      (tester) async {
    final core = _OverviewCore();

    await _pumpOverview(
      tester,
      brightness: Brightness.light,
      core: core,
      settleProbe: false,
    );

    expect(core.configs, hasLength(1));
    expect(core.pending, hasLength(1));
    expect(find.text(tr('ep.ovChecking')), findsNWidgets(2));
    final recheck = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, tr('ep.ovRecheck')),
    );
    expect(recheck.onPressed, isNull);
    expect(core.configs, hasLength(1),
        reason: 'disabled Re-check cannot start a second concurrent probe');

    core.pending.single.complete({
      'ok': true,
      'tables': const <Map<String, dynamic>>[],
    });
    await tester.pump();
    await tester.pump();

    expect(find.text(tr('ep.ovReachable')), findsNWidgets(2));
    expect(core.unexpectedCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
