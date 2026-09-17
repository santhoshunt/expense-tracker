import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dashboard is split into Overview / Trends / Breakdown sub-tabs, so a
/// section assertion has to start on the right one. The segmented control
/// sits at the top of the list, and rows above the viewport read as offstage
/// to finders, so a scrolled page has to come back up first.
Future<void> openDashboardView(WidgetTester tester, String view) async {
  await tester.scrollUntilVisible(
    find.text(view),
    -400,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text(view));
  await tester.pumpAndSettle();
}
