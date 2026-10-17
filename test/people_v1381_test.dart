import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/people_screen.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/glossy.dart';

/// People rows and the person sheet in v1.38.1: days without times, and
/// the actions lined up with the bills.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> withDinner() async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 1600,
      note: 'Team dinner',
      date: DateTime(2026, 10, 7, 21),
      people: const [SplitShare(name: 'Arun Kumar', amount: 800)],
    );
    return p;
  }

  Future<void> pumpPeople(WidgetTester tester, FinanceProvider p) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: const MaterialApp(home: PeopleScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a person row gives the oldest bill as a day, no time', (
    tester,
  ) async {
    await pumpPeople(tester, await withDinner());
    expect(
      find.text(joinFacts(['1 open bill', 'oldest 7 Oct'])),
      findsOneWidget,
    );
    expect(find.textContaining('9:00 PM'), findsNothing);
  });

  testWidgets('the card sits 16dp in, as on Settings and Cockpit', (
    tester,
  ) async {
    await pumpPeople(tester, await withDinner());
    final card = find.ancestor(
      of: find.text('Arun Kumar'),
      matching: find.byType(FrostedPanel),
    );
    expect(tester.getTopLeft(card).dx, 16);
  });

  testWidgets('at 320dp with 2x text the amount sits under the subtitle and '
      'nothing overflows', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final p = await withDinner();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 1200,
      note: 'Movie night',
      date: DateTime(2026, 10, 9, 19),
      people: const [SplitShare(name: 'Meena', amount: 600)],
    );
    await pumpPeople(tester, p);
    expect(tester.takeException(), isNull);

    // No avatar beside the name; the amount is below the subtitle.
    expect(find.byType(CircleAvatar), findsNothing);
    final subtitle = find.text(joinFacts(['1 open bill', 'oldest 7 Oct']));
    final amount = find.text(fmtMoney(800));
    expect(
      tester.getTopLeft(amount).dy,
      greaterThan(tester.getBottomLeft(subtitle).dy - 1),
    );
    expect(tester.getTopLeft(amount).dx, tester.getTopLeft(subtitle).dx);
    // The name has the row's width: it is not cut to "M…".
    final name = tester.renderObject<RenderParagraph>(
      find.descendant(of: find.text('Meena'), matching: find.byType(RichText)),
    );
    expect(name.didExceedMaxLines, isFalse);
  });

  testWidgets('the sheet lines its actions up with its bills, and dates its '
      'bills without a time', (tester) async {
    await pumpPeople(tester, await withDinner());
    await tester.tap(find.text('Arun Kumar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('7 Oct · '), findsOneWidget);
    expect(find.textContaining('9:00 PM'), findsNothing);

    final billLeft = tester.getTopLeft(find.text('Team dinner')).dx;
    final openBillsLeft = tester.getTopLeft(find.text('Open bills')).dx;
    for (final icon in [Icons.payments_outlined, Icons.link, Icons.task_alt]) {
      expect(
        tester.getTopLeft(find.byIcon(icon)).dx,
        billLeft,
        reason: '$icon',
      );
    }
    expect(openBillsLeft, billLeft);
  });
}
