import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/home_app_bar.dart';

/// v1.39.0: the ⋮ menu's rows are 44dp, and the menu is as wide as its
/// longest label rather than stretching toward its widest step. A row's
/// trailing ("i") stays at the right edge and keeps its own tap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final owner = Object();
  tearDown(() => AppNav.instance.pageMenu.detach(owner));

  /// [HomeMenu] alone in an app bar, on the Accounts tab, with [actions]
  /// published for it, then opened.
  Future<void> openMenu(
    WidgetTester tester,
    List<PageMenuAction> actions, {
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AppNav.instance.pageMenu.publish(owner, kHomeTabAccounts, actions);
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(actions: const [HomeMenu(tab: kHomeTabAccounts)]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
  }

  Finder rows() => find.byWidgetPredicate((w) => w is PopupMenuItem);
  Finder row(String label) =>
      find.ancestor(of: find.text(label), matching: rows());

  var rowTaps = 0;
  var tipTaps = 0;
  setUp(() {
    rowTaps = 0;
    tipTaps = 0;
  });

  List<PageMenuAction> shortActions() => [
    PageMenuAction(
      icon: Icons.date_range,
      label: 'Year',
      onTap: () => rowTaps++,
      trailing: IconButton(
        tooltip: 'About Year',
        icon: const Icon(Icons.info_outline, size: 20),
        onPressed: () => tipTaps++,
      ),
    ),
    PageMenuAction(icon: Icons.checklist, label: 'Select', onTap: () {}),
  ];

  testWidgets('rows are at least 44dp and under 56dp', (tester) async {
    await openMenu(tester, shortActions());
    final all = rows().evaluate().toList();
    // Year, Select, then Cockpit and Who owes you.
    expect(all, hasLength(4));
    for (final e in all) {
      final h = tester.getSize(find.byWidget(e.widget)).height;
      expect(h, greaterThanOrEqualTo(44));
      expect(h, lessThan(56));
    }
    // A row without a trailing is the 44dp minimum at normal text.
    expect(tester.getSize(row('Who owes you')).height, 44);
  });

  // The test font draws every glyph a full em wide, so "Who owes you"
  // (v1.43.0, was "People") alone reaches Flutter's 280dp menu cap at 1x;
  // on a phone's real font it is about half that. At 0.75x the App rows
  // leave room under the cap, which is what these two tests measure.
  testWidgets('short labels make a menu narrower than 280dp', (tester) async {
    await openMenu(tester, shortActions(), textScale: 0.75);
    expect(tester.getSize(row('Who owes you')).width, lessThan(280));
  });

  testWidgets('a longer label widens the menu to fit it', (tester) async {
    await openMenu(tester, shortActions(), textScale: 0.75);
    final short = tester.getSize(row('Who owes you')).width;
    await tester.tapAt(const Offset(5, 880));
    await tester.pumpAndSettle();
    await openMenu(tester, textScale: 0.75, [
      ...shortActions(),
      PageMenuAction(
        icon: Icons.add,
        label: 'Balance sheet for the year',
        onTap: () {},
      ),
    ]);
    expect(tester.getSize(row('Who owes you')).width, greaterThan(short));
  });

  testWidgets('the trailing sits at the right edge and has its own tap', (
    tester,
  ) async {
    // A longer row makes the menu wider than the Year row's own content.
    await openMenu(tester, [
      ...shortActions(),
      PageMenuAction(icon: Icons.add, label: 'Balance sheet', onTap: () {}),
    ]);
    final rowBox = tester.getRect(row('Year'));
    final tip = find.byTooltip('About Year');
    final tipBox = tester.getRect(
      find.ancestor(of: tip, matching: find.byType(IconButton)).first,
    );
    // Only the row's 12dp end padding lies past the trailing.
    expect(rowBox.right - tipBox.right, inInclusiveRange(0, 12.5));
    // Every row is one menu width, so the trailing follows the menu's
    // edge, not the end of its short label.
    expect(rowBox.width, tester.getSize(row('Balance sheet')).width);

    await tester.tap(tip);
    await tester.pumpAndSettle();
    expect(tipTaps, 1);
    expect(rowTaps, 0);
    expect(row('Year'), findsOneWidget, reason: 'the menu stays open');

    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(rowTaps, 1);
    expect(find.text('App'), findsNothing, reason: 'the menu closed');
  });

  testWidgets('rows grow with large text', (tester) async {
    await openMenu(tester, shortActions(), textScale: 3);
    expect(tester.getSize(row('Who owes you')).height, greaterThan(44));
    expect(tester.takeException(), isNull);
  });
}
