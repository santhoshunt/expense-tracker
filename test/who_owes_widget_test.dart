import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/screens/people_screen.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/animated_fold.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

import 'dashboard_test_utils.dart';

/// Who owes you in the UI: the split rows in the add sheet, the row's
/// "to get back" line, the Today card and the People page's actions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 9);

  Widget withProviders(FinanceProvider p, Widget home) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: MaterialApp(home: home),
  );

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  /// A ₹3,000 dinner: Arun and Priya owe ₹1,000 each, or Arun alone with
  /// [alone].
  Future<String> dinner(FinanceProvider p, {bool alone = false}) =>
      p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 3000,
        note: 'Dinner',
        date: today,
        people: [
          const SplitShare(name: 'Arun', amount: 1000),
          if (!alone) const SplitShare(name: 'Priya', amount: 1000),
        ],
      );

  /// System back: what a barrier tap and a swipe-down route through too.
  Future<void> back(WidgetTester tester) async {
    final NavigatorState nav = tester.state(find.byType(Navigator).last);
    await nav.maybePop();
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester, FinanceProvider p) async {
    await tester.pumpWidget(
      withProviders(
        p,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddTransactionSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  group('add sheet', () {
    testWidgets('names people, splits evenly with the paise to you, saves', (
      tester,
    ) async {
      final p = await loaded();
      await openSheet(tester, p);
      await tester.enterText(field('Amount'), '1000');
      await tapVisible(tester, find.text('Group split payment'));
      await tapVisible(tester, find.text('Add who owes what'));
      await tester.enterText(field('Name'), 'Arun');
      await tapVisible(tester, find.text('Add person'));
      await tester.enterText(field('Name').last, 'Priya');
      await tapVisible(tester, find.text('Split evenly'));
      expect(find.text('333.33'), findsNWidgets(2));
      expect(find.text('Your share ${fmtMoney(333.34)}'), findsOneWidget);

      await tapVisible(tester, find.widgetWithText(FilledButton, 'Add'));
      final t = p.transactions.single;
      expect(t.myShare, 333.34);
      expect(t.people, const [
        SplitShare(name: 'Arun', amount: 333.33),
        SplitShare(name: 'Priya', amount: 333.33),
      ]);
    });

    testWidgets('too much owed, or a name twice, blocks the save', (
      tester,
    ) async {
      final p = await loaded();
      await openSheet(tester, p);
      await tester.enterText(field('Amount'), '1000');
      await tapVisible(tester, find.text('Group split payment'));
      await tapVisible(tester, find.text('Add who owes what'));
      await tester.enterText(field('Name'), 'Arun');
      await tester.enterText(field('Owes'), '1200');
      await tester.pump();
      expect(
        find.text("People's amounts add up to more than the bill"),
        findsOneWidget,
        reason: 'live, before saving',
      );
      await tapVisible(tester, find.widgetWithText(FilledButton, 'Add'));
      expect(p.transactions, isEmpty);

      await tester.enterText(field('Owes'), '300');
      await tapVisible(tester, find.text('Add person'));
      await tester.enterText(field('Name').last, 'arun');
      await tester.enterText(field('Owes').last, '300');
      await tapVisible(tester, find.widgetWithText(FilledButton, 'Add'));
      expect(find.text('arun is listed twice'), findsOneWidget);
      expect(p.transactions, isEmpty);
    });

    testWidgets('a changed amount owed counts as unsaved', (tester) async {
      final p = await loaded();
      final id = await dinner(p);
      await tester.pumpWidget(
        withProviders(
          p,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddTransactionSheet(
                  context,
                  existing: p.transactions.firstWhere((t) => t.id == id),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Owes').first, '900');
      await tester.pump();
      await back(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
    });
  });

  testWidgets('a split row says what is still to come back', (tester) async {
    final p = await loaded();
    final id = await dinner(p);
    Widget tile() => withProviders(
      p,
      Scaffold(
        body: Consumer<FinanceProvider>(
          builder: (_, f, _) =>
              TransactionTile(tx: f.transactions.firstWhere((t) => t.id == id)),
        ),
      ),
    );
    await tester.pumpWidget(tile());
    await tester.pump();
    expect(
      find.text('${fmtMoney(2000)} to get back · Arun, Priya'),
      findsOneWidget,
    );

    await p.settleShares('Arun');
    await p.settleShares('Priya');
    await tester.pump();
    expect(find.text('Settled · Arun, Priya'), findsOneWidget);
  });

  group('Today card and People page', () {
    Future<void> pumpDashboard(WidgetTester tester, FinanceProvider p) async {
      await tester.pumpWidget(
        withProviders(p, const Scaffold(body: DashboardScreen())),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the card shows while someone owes you and opens the page', (
      tester,
    ) async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 90,
        note: 'coffee',
        date: today,
      );
      await pumpDashboard(tester, p);
      expect(find.text('Owed to you'), findsNothing);

      await dinner(p);
      await tester.pumpAndSettle();
      expect(find.text('Owed to you'), findsOneWidget);
      expect(find.text(fmtMoney(2000)), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Recent transactions'),
        300,
        scrollable: verticalScrollable(),
      );
      expect(
        tester.getTopLeft(find.text('Owed to you')).dy,
        lessThan(tester.getTopLeft(find.text('Recent transactions')).dy),
      );

      await tapVisible(tester, find.text('Owed to you'));
      expect(find.text('Who owes you'), findsOneWidget);
      expect(find.text('Arun'), findsOneWidget);
      expect(find.text('Priya'), findsOneWidget);
    });

    Future<void> openPerson(
      WidgetTester tester,
      FinanceProvider p,
      String name,
    ) async {
      await tester.pumpWidget(withProviders(p, const PeopleScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    double owed(FinanceProvider p, String key) =>
        p.peopleBalances.firstWhere((b) => b.key == key).owed;

    // Arun alone: settling the only person owing swaps the list for the
    // empty state, which unmounts the row the sheet was opened from. The
    // Undo toast must still show.
    testWidgets('Record repayment opens the sheet filled in, with Undo', (
      tester,
    ) async {
      final p = await loaded();
      await dinner(p, alone: true);
      await openPerson(tester, p, 'Arun');
      expect(find.text('Owes you ${fmtMoney(1000)}'), findsOneWidget);
      await tester.tap(find.text('Record repayment'));
      await tester.pumpAndSettle();

      expect(find.text('1000.00'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Arun'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(FilledButton, 'Add'));
      expect(owed(p, 'arun'), 0);
      expect(find.text('Recorded a repayment from Arun'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(owed(p, 'arun'), 1000);
    });

    testWidgets('Link a payment you received, with Undo', (tester) async {
      final p = await loaded();
      await dinner(p);
      final gift = await p.addTransaction(
        type: TxType.income,
        categoryId: 'gift',
        amount: 1000,
        note: 'UPI Priya',
        date: today,
      );
      await openPerson(tester, p, 'Priya');
      await tester.tap(find.text('Link a payment you received'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('UPI Priya'));
      await tester.pumpAndSettle();
      expect(owed(p, 'priya'), 0);
      expect(
        p.transactions.firstWhere((t) => t.id == gift).categoryId,
        kRepaidToMeCategoryId,
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(owed(p, 'priya'), 1000);
      expect(p.transactions.firstWhere((t) => t.id == gift).categoryId, 'gift');
    });

    testWidgets('Mark all settled folds the person away, with Undo', (
      tester,
    ) async {
      final p = await loaded();
      await dinner(p, alone: true);
      await openPerson(tester, p, 'Arun');
      await tester.tap(find.text('Mark all settled'));
      await tester.pumpAndSettle();
      expect(owed(p, 'arun'), 0);
      // The sheet closes so the Undo toast isn't hidden under it.
      expect(find.text('Mark all settled'), findsNothing);
      expect(find.text('Marked Arun settled'), findsOneWidget);

      // Arun sits in the folded Settled list.
      expect(find.text('Everyone is settled up.'), findsOneWidget);
      expect(find.text('Settled (1)'), findsOneWidget);
      AnimatedFold fold() => tester.widget<AnimatedFold>(
        find.ancestor(
          of: find.text('Arun'),
          matching: find.byType(AnimatedFold),
        ),
      );
      expect(fold().collapsed, isTrue);
      await tester.tap(find.text('Settled (1)'));
      await tester.pumpAndSettle();
      expect(fold().collapsed, isFalse);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(owed(p, 'arun'), 1000);
      expect(find.text('Settled (1)'), findsNothing);
    });
  });
}
