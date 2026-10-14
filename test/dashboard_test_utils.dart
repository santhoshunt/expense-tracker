import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/home_app_bar.dart';
import 'package:expense_tracker/widgets/dashboard_fold.dart';

/// The Dashboard's month selector and menu live in Home's app bar, which
/// the Dashboard feeds through AppNav. A DashboardScreen pumped without
/// HomeScreen sits in this bar so its arrows, month label and ⋯ entries
/// (Year view, PDF export, Customise) are reachable.
Widget dashboardShell(Widget dashboard) => Scaffold(
  appBar: AppBar(
    title: const DashboardMonthTitle(),
    actions: const [HomeMenu(tab: kHomeTabDashboard)],
  ),
  body: dashboard,
);

/// The figure under a balance-card stat label ('Income', 'Spent', 'Saved').
/// The dotted label opens its tip; the figure opens the rows. Up from the
/// label, the nearest InkWell is the tip's own, the next the stat column's.
Finder statFigure(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first,
  matching: find.byType(FittedBox),
);

/// Opens the app bar's ⋯ menu and picks [label].
Future<void> tapMenuItem(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Switches the Dashboard between Month and Year view through the ⋯ menu.
Future<void> toggleYearView(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
  final toYear = find.widgetWithText(ListTile, 'Year view');
  await tester.tap(
    toYear.evaluate().isNotEmpty
        ? toYear.last
        : find.widgetWithText(ListTile, 'Month view').last,
  );
  await tester.pumpAndSettle();
}

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
