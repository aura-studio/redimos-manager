import 'package:flutter_test/flutter_test.dart';

void expectInsideTestViewport(
  WidgetTester tester,
  Finder finder, {
  String? reason,
}) {
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
  expect(rect.left, greaterThanOrEqualTo(0), reason: reason);
  expect(rect.top, greaterThanOrEqualTo(0), reason: reason);
  expect(rect.right, lessThanOrEqualTo(viewport.width), reason: reason);
  expect(rect.bottom, lessThanOrEqualTo(viewport.height), reason: reason);
}

void expectHitTestable(
  WidgetTester tester,
  Finder finder, {
  String? reason,
}) {
  expect(finder, findsOneWidget);
  expect(finder.hitTestable(), findsOneWidget, reason: reason);
  expectInsideTestViewport(tester, finder, reason: reason);
}
