import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/endpoint_detail.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';

// The Configure pane's identity editor has two modes behind a segment
// control: Endpoint (a local URL) and AWS (Region + credentials). These
// tests pin the field show/hide per mode and the save semantics — the
// active mode commits, the other half of the tuple is blanked.

const _localEndpoint = DdbEndpoint(
  id: 'e1',
  name: 'Local backend',
  kind: 'local',
  endpoint: 'http://127.0.0.1:8123',
  region: 'us-west-2',
);

const _awsEndpoint = DdbEndpoint(
  id: 'e2',
  name: 'AWS backend',
  kind: 'aws',
  region: 'us-east-1',
  accessKeyId: 'AKIA-TEST',
  secretKey: 'secret-test',
  sessionToken: 'token-test',
);

Future<void> _pump(
  WidgetTester tester,
  DdbEndpoint endpoint, {
  Future<void> Function(DdbEndpoint saved)? onSave,
}) async {
  tester.view.physicalSize = const Size(900, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.dark),
      home: Scaffold(
        body: EndpointConfigPane(endpoint: endpoint, onSave: onSave),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  testWidgets('a local endpoint starts in Endpoint mode, URL only',
      (tester) async {
    await _pump(tester, _localEndpoint);

    expect(find.byKey(const ValueKey('ep-config-endpoint')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-config-region')), findsNothing);
    expect(find.byKey(const ValueKey('ep-config-ak')), findsNothing);
    expect(find.byKey(const ValueKey('ep-config-sk')), findsNothing);
    expect(find.byKey(const ValueKey('ep-config-token')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.descendant(
            of: find.byKey(const ValueKey('ep-config-endpoint-input')),
            matching: find.byType(TextField),
          ))
          .controller!
          .text,
      'http://127.0.0.1:8123',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an AWS endpoint starts in AWS mode with credential fields',
      (tester) async {
    await _pump(tester, _awsEndpoint);

    expect(find.byKey(const ValueKey('ep-config-endpoint')), findsNothing);
    expect(find.byKey(const ValueKey('ep-config-region')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-config-ak')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-config-sk')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-config-token')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.descendant(
            of: find.byKey(const ValueKey('ep-config-ak-input')),
            matching: find.byType(TextField),
          ))
          .controller!
          .text,
      'AKIA-TEST',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching modes swaps the visible fields', (tester) async {
    await _pump(tester, _localEndpoint);

    await tester.tap(find.text(tr('ep.modeAws')));
    await tester.pump();
    expect(find.byKey(const ValueKey('ep-config-endpoint')), findsNothing);
    expect(find.byKey(const ValueKey('ep-config-region')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-config-ak')), findsOneWidget);

    await tester.tap(find.text(tr('ep.modeEndpoint')));
    await tester.pump();
    expect(find.byKey(const ValueKey('ep-config-endpoint')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-config-ak')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving Endpoint mode blanks the AWS half of the tuple',
      (tester) async {
    DdbEndpoint? saved;
    await _pump(tester, _awsEndpoint, onSave: (e) async => saved = e);

    // Flip the AWS endpoint to a local URL.
    await tester.tap(find.text(tr('ep.modeEndpoint')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('ep-config-endpoint-input')),
        'http://127.0.0.1:9999');
    await tester.tap(find.byKey(const ValueKey('ep-config-save')));
    await tester.pump();

    expect(saved, isNotNull);
    expect(saved!.endpoint, 'http://127.0.0.1:9999');
    expect(saved!.kind, 'url', reason: 'the stale aws kind must be shed');
    expect(saved!.region, '');
    expect(saved!.accessKeyId, '');
    expect(saved!.secretKey, '');
    expect(saved!.sessionToken, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving AWS mode blanks the endpoint URL', (tester) async {
    DdbEndpoint? saved;
    await _pump(tester, _localEndpoint, onSave: (e) async => saved = e);

    await tester.tap(find.text(tr('ep.modeAws')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('ep-config-region-input')), 'eu-west-1');
    await tester.enterText(
        find.byKey(const ValueKey('ep-config-ak-input')), 'AKIA-NEW');
    await tester.enterText(
        find.byKey(const ValueKey('ep-config-sk-input')), 'secret-new');
    await tester.tap(find.byKey(const ValueKey('ep-config-save')));
    await tester.pump();

    expect(saved, isNotNull);
    expect(saved!.kind, 'aws');
    expect(saved!.endpoint, '');
    expect(saved!.region, 'eu-west-1');
    expect(saved!.accessKeyId, 'AKIA-NEW');
    expect(saved!.secretKey, 'secret-new');
    expect(saved!.sessionToken, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('test connection probes the draft and reports the table count',
      (tester) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: Scaffold(
        body: EndpointConfigPane(
            endpoint: _localEndpoint, core: FakeNativeCore()),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ep-test-connection')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump();
    expect(find.textContaining('Connected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
