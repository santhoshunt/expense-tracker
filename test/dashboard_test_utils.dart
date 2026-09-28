import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/dashboard_fold.dart';

/// The dashboard is split into Overview / Trends / Breakdown sub-tabs, so a
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

/// Trends and Breakdown fold most sections by default: scrolls to
/// [section]'s fold (a DashboardSection name, e.g. 'merchants') and opens it
/// when folded, so the test can reach its cards.
Future<void> openDashboardSection(WidgetTester tester, String section) async {
  final fold = find.byKey(ValueKey('fold-$section'));
  await tester.scrollUntilVisible(fold, 300, scrollable: verticalScrollable());
  await tester.pumpAndSettle();
  if (!tester.widget<DashboardFold>(fold).open) {
    await tester.tap(
      find.descendant(of: fold, matching: find.byType(InkWell)).first,
    );
    await tester.pumpAndSettle();
  }
}
