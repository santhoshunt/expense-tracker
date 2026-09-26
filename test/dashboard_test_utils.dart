import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dashboard is split into Today / Month / Trends / Breakdown sub-tabs, so a
/// section assertion has to start on the right one. The tab bar is pinned
/// above the pager, so its labels are always tappable.
Future<void> openDashboardView(WidgetTester tester, String view) async {
  await tester.tap(find.text(view));
  await tester.pumpAndSettle();
}

/// First VERTICAL scrollable on screen: the page's list, never the pager.
/// The dashboard, transactions and accounts screens each wrap their pages in
/// a horizontal PageView, so `find.byType(Scrollable).first` resolves to the
/// pager — and scrollUntilVisible would then drag sideways (it takes its
/// direction from the scrollable's axis). Finders skip offstage widgets by
/// default, so hidden tabs and routes don't interfere.
Finder verticalScrollable() => find
    .byWidgetPredicate(
      (w) =>
          w is Scrollable &&
          axisDirectionToAxis(w.axisDirection) == Axis.vertical,
    )
    .first;
