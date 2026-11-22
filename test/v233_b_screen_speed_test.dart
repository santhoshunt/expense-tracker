import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/screens/search_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/utils/search_text.dart';

/// v2.3.3 speed fixes in the screens: each test pins what the user sees
/// and counts the work that used to repeat. Every name, digit and merchant
/// here is invented.

/// Counts the ledger reads and account lookups the screens make.
class _CountingFinance extends FinanceProvider {
  int ledgerReads = 0;
  int accountLookups = 0;

  @override
  List<Tx> get transactions {
    ledgerReads++;
    return super.transactions;
  }

  @override
  Account? accountForKey(String? key) {
    accountLookups++;
    return super.accountForKey(key);
  }
}

/// Counts reads of switches that only Home's own checks read: Payments to
/// check (the ledger listener's run and the Keep-tap sync), the weekly
/// digest (the open-time booking, also run on resume), and Unusual spending
/// and Price rises (their monitors read them first thing on each run).
class _CountingSettings extends SettingsProvider {
  int importChecksReads = 0;
  int weeklyDigestReads = 0;
  int unusualReads = 0;
  int priceRiseReads = 0;

  @override
  bool get importChecks {
    importChecksReads++;
    return super.importChecks;
  }

  @override
  bool get weeklyDigest {
    weeklyDigestReads++;
    return super.weeklyDigest;
  }

  @override
  bool get unusualAlerts {
    unusualReads++;
    return super.unusualAlerts;
  }

  @override
  bool get priceRiseAlerts {
    priceRiseReads++;
    return super.priceRiseAlerts;
  }
}

/// An invented bank alert, as an imported row.
Tx _alert(
  String id,
  String merchant,
  double amount,
  DateTime date, {
  TxType type = TxType.expense,
  String categoryId = 'food',
}) => Tx(
  id: id,
  type: type,
  categoryId: categoryId,
  amount: amount,
  note: '',
  smsBody:
      'Rs.${amount.toStringAsFixed(2)} debited from a/c XX4021 on '
      '02-07-26 at $merchant.',
  date: date,
  source: TxSource.sms,
  sender: 'VM-DEMOBK',
  acctKey: 'DEMO:4021',
);

/// A manual row whose tile title is [note].
Tx _manual(
  String id,
  String note,
  double amount,
  DateTime date, {
  TxType type = TxType.expense,
  String categoryId = 'food',
}) => Tx(
  id: id,
  type: type,
  categoryId: categoryId,
  amount: amount,
  note: note,
  date: date,
);

Future<_CountingFinance> _ledger(List<Tx> rows) async {
  SharedPreferences.setMockInitialValues({
    'transactions_v1': jsonEncode([for (final t in rows) t.toJson()]),
  });
  final p = _CountingFinance();
  await p.load();
  return p;
}

Widget _host(FinanceProvider p, SettingsProvider s, Widget home) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<FinanceProvider>.value(value: p),
        ChangeNotifierProvider<SettingsProvider>.value(value: s),
        Provider<DriveBackupService>(create: (_) => DriveBackupService()),
      ],
      child: MaterialApp(home: home),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    // The tests read only differences, but no count carries over.
    searchTextBuilds = 0;
    transactionsPipelineRuns = 0;
  });

  tearDown(() {
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    homeClock = DateTime.now;
  });

  group('row search text', () {
    test('is built once per row and again only when what it reads changes', () {
      final day = DateTime(2026, 7, 2, 10);
      final t = _alert('a', 'ORBIT MART', 120, day);
      String? alias;
      String? lookup(String identity) => alias;
      // The text matches the uncached one in every state below.
      String direct(String account) => searchHaystack(
        t,
        accountName: account,
        merchantAlias: merchantIdentityOf(t) == null ? null : alias,
      );
      final start = searchTextBuilds;

      final first = rowSearchText(
        t,
        accountName: 'Demo Savings',
        alias: lookup,
      );
      expect(first, direct('Demo Savings'));
      expect(
        rowSearchText(t, accountName: 'Demo Savings', alias: lookup),
        same(first),
      );
      expect(searchTextBuilds - start, 1);

      // The account renamed.
      expect(
        rowSearchText(t, accountName: 'Household', alias: lookup),
        allOf(contains('household'), equals(direct('Household'))),
      );
      expect(searchTextBuilds - start, 2);

      // The merchant given a name.
      alias = 'Corner Shop';
      expect(
        rowSearchText(t, accountName: 'Household', alias: lookup),
        allOf(contains('corner shop'), equals(direct('Household'))),
      );
      expect(searchTextBuilds - start, 3);

      // The category renamed: the row itself is the same object.
      setBuiltinOverrides({
        'food': const TxCategory(
          id: 'food',
          label: 'Meals Out',
          icon: Icons.restaurant,
          color: Colors.orange,
          type: TxType.expense,
        ),
      });
      expect(
        rowSearchText(t, accountName: 'Household', alias: lookup),
        allOf(contains('meals out'), equals(direct('Household'))),
      );
      expect(searchTextBuilds - start, 4);

      // The category made a transfer: the row no longer has a merchant
      // identity, so the merchant's name drops out.
      setBuiltinOverrides({
        'food': const TxCategory(
          id: 'food',
          label: 'Meals Out',
          icon: Icons.restaurant,
          color: Colors.orange,
          type: TxType.expense,
          isTransfer: true,
        ),
      });
      final transfer = rowSearchText(
        t,
        accountName: 'Household',
        alias: lookup,
      );
      expect(transfer, isNot(contains('corner shop')));
      expect(transfer, direct('Household'));
      expect(searchTextBuilds - start, 5);
      rowSearchText(t, accountName: 'Household', alias: lookup);
      expect(searchTextBuilds - start, 5);
    });

    testWidgets('an edit rebuilds the search text of that row only', (
      tester,
    ) async {
      final rows = [
        for (var i = 0; i < 40; i++)
          _alert(
            'r$i',
            i.isEven ? 'ORBIT MART' : 'TANGO TAXI',
            100.0 + i,
            DateTime(2026, 7, 1 + i % 20, 9),
          ),
      ];
      final p = await _ledger(rows);
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(
        _host(p, s, const Scaffold(body: TransactionsScreen())),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'orbit');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Orbit Mart'), findsWidgets);
      expect(find.text('Tango Taxi'), findsNothing);

      final before = searchTextBuilds;
      // The newest Tango Taxi row, its note now naming the search.
      final edited = p.transactions.firstWhere((t) => t.id == 'r39');
      await p.updateTransaction(edited.copyWith(note: 'orbit refill'));
      await tester.pumpAndSettle();
      // The old screens dropped every row's text on any change.
      expect(searchTextBuilds - before, 1);
      expect(find.text('Tango Taxi'), findsOneWidget);
    });
  });

  group('Home ledger listener', () {
    // Home's own clock, moved only with the test's fake time.
    late DateTime now;
    setUp(() {
      now = DateTime(2026, 7, 14, 10);
      homeClock = () => now;
    });

    /// Advances Home's clock and the fake timers together.
    Future<void> wait(WidgetTester tester, Duration d) async {
      now = now.add(d);
      await tester.pump(d);
    }

    void resume(WidgetTester tester) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    Future<(FinanceProvider, _CountingSettings)> mountHome(
      WidgetTester tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      for (var i = 0; i < 5; i++) {
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 80.0 + i,
          note: 'snack $i',
          date: DateTime(2026, 7, 1 + i, 12),
        );
      }
      final s = _CountingSettings();
      await s.load();
      await tester.pumpWidget(_host(p, s, const HomeScreen()));
      await tester.pump();
      await wait(tester, const Duration(seconds: 1));
      return (p, s);
    }

    testWidgets('five changes in a row run the checks once', (tester) async {
      final (p, s) = await mountHome(tester);
      final before = s.importChecksReads;
      for (final t in p.transactions.toList()) {
        await p.updateTransaction(t.copyWith(note: '${t.note} edited'));
      }
      expect(s.importChecksReads - before, 0, reason: 'none inside the burst');
      await wait(tester, const Duration(milliseconds: 300));
      // The old listener ran all of them on each of the five changes.
      expect(s.importChecksReads - before, 1);

      // A later change runs them again.
      await p.updateTransaction(p.transactions.first.copyWith(note: 'later'));
      await wait(tester, const Duration(milliseconds: 300));
      expect(s.importChecksReads - before, 2);

      // Changes 200 ms apart, as a save's storage writes space them, wait
      // for a quiet quarter second and then run once.
      await p.updateTransaction(p.transactions.first.copyWith(note: 'one'));
      await wait(tester, const Duration(milliseconds: 200));
      await p.updateTransaction(p.transactions.first.copyWith(note: 'two'));
      await wait(tester, const Duration(milliseconds: 200));
      expect(s.importChecksReads - before, 2);
      await wait(tester, const Duration(milliseconds: 100));
      expect(s.importChecksReads - before, 3);
    });

    testWidgets('changes that never pause still run the checks 750 ms after '
        'the first', (tester) async {
      final (p, s) = await mountHome(tester);
      final before = s.importChecksReads;
      // A change every 200 ms: no quiet quarter second ever comes.
      for (var i = 0; i < 4; i++) {
        await p.updateTransaction(p.transactions.first.copyWith(note: 'c$i'));
        await wait(tester, const Duration(milliseconds: 200));
      }
      // 800 ms in: the run fell due at 750 ms, before the fifth change.
      expect(s.importChecksReads - before, 1);
      await p.updateTransaction(p.transactions.first.copyWith(note: 'c4'));
      await wait(tester, const Duration(milliseconds: 300));
      expect(s.importChecksReads - before, 2);
    });

    testWidgets('a run still waiting when the app goes to the background '
        'runs at once', (tester) async {
      final (p, s) = await mountHome(tester);
      final before = s.importChecksReads;
      await p.updateTransaction(p.transactions.first.copyWith(note: 'away'));
      expect(s.importChecksReads - before, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      // The old code waited for its timer, which a swiped-away app may
      // never reach.
      expect(s.importChecksReads - before, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await wait(tester, const Duration(milliseconds: 800));
      expect(s.importChecksReads - before, 1, reason: 'no second run');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await wait(tester, const Duration(seconds: 1));
    });

    testWidgets('a run still waiting when Home goes is dropped with its '
        'timer', (tester) async {
      final (p, s) = await mountHome(tester);
      final before = s.importChecksReads;
      await p.updateTransaction(p.transactions.first.copyWith(note: 'gone'));
      await tester.pumpWidget(const SizedBox());
      await wait(tester, const Duration(milliseconds: 800));
      // The test framework fails a test that ends with a timer pending.
      expect(s.importChecksReads - before, 0);
    });

    testWidgets('the first resume after opening runs the unusual spending and '
        'price-rise checks', (tester) async {
      final (_, s) = await mountHome(tester);
      final unusual = s.unusualReads;
      final priceRise = s.priceRiseReads;
      resume(tester);
      expect(s.unusualReads - unusual, greaterThanOrEqualTo(1));
      expect(s.priceRiseReads - priceRise, greaterThanOrEqualTo(1));
      await wait(tester, const Duration(seconds: 1));
    });

    testWidgets('a second resume within five seconds skips the open-time '
        'work but still applies Keep taps', (tester) async {
      final (_, s) = await mountHome(tester);
      resume(tester);
      await wait(tester, const Duration(seconds: 2));
      final digest = s.weeklyDigestReads;
      final keep = s.importChecksReads;
      resume(tester);
      expect(s.weeklyDigestReads - digest, 0, reason: 'booking skipped');
      expect(s.importChecksReads - keep, 1, reason: 'Keep taps applied');

      // Past the throttle a resume does the open-time work again.
      await wait(tester, const Duration(seconds: 5));
      resume(tester);
      expect(s.weeklyDigestReads - digest, 1);
      expect(s.importChecksReads - keep, 2);
      await wait(tester, const Duration(seconds: 1));
    });

    testWidgets('a resume on a new day is never skipped', (tester) async {
      now = DateTime(2026, 7, 31, 23, 59, 58);
      final (_, s) = await mountHome(tester);
      now = DateTime(2026, 7, 31, 23, 59, 58);
      resume(tester);
      final digest = s.weeklyDigestReads;
      // Four seconds later, past midnight.
      await wait(tester, const Duration(seconds: 4));
      expect(now.day, 1);
      resume(tester);
      expect(s.weeklyDigestReads - digest, 1);
      await wait(tester, const Duration(seconds: 1));
    });
  });

  group('search result pages', () {
    testWidgets('a long page builds the rows on screen only, in date order '
        'under month and day headers', (tester) async {
      final rows = [
        for (var i = 0; i < 400; i++)
          _manual(
            'm$i',
            'row$i',
            10.0 + i,
            DateTime(2026, 6, 1, 8).add(Duration(hours: 3 * i)),
          ),
      ];
      final p = await _ledger(rows);
      final s = SettingsProvider();
      await s.load();
      var notes = 0;
      await tester.pumpWidget(
        _host(
          p,
          s,
          SearchPaymentsPage(
            title: '"row"',
            rowsOf: (f) => f.transactions,
            transactionsRequest: const TxFilterRequest(query: 'row'),
            matchNoteOf: (t) {
              notes++;
              return null;
            },
          ),
        ),
      );
      await tester.pump();
      // The old page worked out all 400 notes before it showed.
      expect(notes, lessThan(60));
      expect(find.textContaining('400 payments'), findsOneWidget);

      // Newest first: the last row added leads, under its month and day.
      final newest = rows.last.date;
      expect(find.text(DateFormat('MMMM yyyy').format(newest)), findsOneWidget);
      expect(find.text(DateFormat('EEE d MMM').format(newest)), findsOneWidget);
      double top(String s) => tester.getTopLeft(find.text(s)).dy;
      expect(top('row399'), lessThan(top('row398')));

      // Amount, high to low, then the next pick back: the same rows, and the
      // day headers return.
      await tester.tap(find.byTooltip('Sort by'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Amount · high to low'));
      await tester.pumpAndSettle();
      expect(find.text(DateFormat('EEE d MMM').format(newest)), findsNothing);
      expect(top('row399'), lessThan(top('row398')));
      expect(find.textContaining('400 payments'), findsOneWidget);
    });

    testWidgets('the cap and Show all are as before, and a chip switch does '
        'not search the ledger again', (tester) async {
      final now = DateTime.now();
      final rows = [
        for (var i = 0; i < 35; i++)
          _manual(
            'z$i',
            'quorbit $i',
            20.0 + i,
            DateTime(2026, 7, 1, 8).add(Duration(hours: 5 * i)),
          ),
        _manual('x', 'unrelated', 50, DateTime(now.year, now.month, 1)),
      ];
      final p = await _ledger(rows);
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(_host(p, s, const SearchScreen()));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'quorbit');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.textContaining('35 payments'), findsOneWidget);

      final reads = p.ledgerReads;
      await tester.tap(find.text('Merchants'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      // The old screen searched the whole ledger again on each build.
      expect(p.ledgerReads - reads, 0);

      final showAll = find.text('Show all 35 payments');
      await tester.scrollUntilVisible(
        showAll,
        300,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .last,
      );
      await tester.ensureVisible(showAll);
      await tester.pumpAndSettle();
      await tester.tap(showAll);
      await tester.pumpAndSettle();
      expect(find.byType(SearchPaymentsPage), findsOneWidget);
      expect(find.textContaining('35 payments'), findsOneWidget);
      expect(showAll, findsNothing);
    });

    testWidgets('the Cockpit Results search runs once per change', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = [
        for (var i = 0; i < 80; i++)
          _alert(
            'c$i',
            i.isEven ? 'ORBIT MART' : 'TANGO TAXI',
            30.0 + i,
            DateTime(2026, 7, 1 + i % 25, 9),
          ),
      ];
      final p = await _ledger(rows);
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(
        _host(p, s, const ClassifiersScreen(initialTab: 0)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tap(find.text('Results'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.enterText(
        find.widgetWithText(TextField, 'Search transactions'),
        'orbit',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('Tango Taxi'), findsNothing);

      final lookups = p.accountLookups;
      final tab = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_TransactionsTab',
      );
      tester.element(tab).markNeedsBuild();
      await tester.pump();
      // The old tab looked every row's account up again on each build.
      expect(p.accountLookups - lookups, lessThan(rows.length ~/ 2));
      expect(find.text('Orbit Mart'), findsWidgets);
    });
  });

  group('Transactions tab', () {
    testWidgets('the Filters sheet counts again only when the draft '
        'changes', (tester) async {
      final p = await _ledger([
        _manual('a', 'lunch', 100, DateTime(2026, 7, 1, 13)),
        _manual(
          'b',
          'cab',
          200,
          DateTime(2026, 7, 2, 9),
          categoryId: 'transport',
        ),
      ]);
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(
        _host(p, s, const Scaffold(body: TransactionsScreen())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('filters-section-categories')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Show 2'), findsOneWidget);

      final reads = p.ledgerReads;
      final field = find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(TextField),
          )
          .first;
      for (var i = 0; i < 10; i++) {
        await tester.enterText(field, i.isEven ? 'tr' : 'tra');
        await tester.pump();
      }
      // The old sheet counted the ledger on each of these rebuilds.
      expect(p.ledgerReads - reads, 0);

      final transport = find.widgetWithText(FilterChip, 'Transport');
      await tester.ensureVisible(transport);
      await tester.pump();
      await tester.tap(transport);
      await tester.pump();
      expect(p.ledgerReads - reads, 1);
      expect(find.text('Show 1'), findsOneWidget);
    });

    testWidgets('with two rows selected a rebuild walks the ledger once', (
      tester,
    ) async {
      final p = await _ledger([
        _manual(
          'e',
          'powerbill',
          1200,
          DateTime(2026, 9, 15, 10),
          categoryId: 'bills',
        ),
        _manual(
          'i',
          'billrefund',
          1200,
          DateTime(2026, 9, 17, 10),
          type: TxType.income,
          categoryId: 'other_income',
        ),
      ]);
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(
        _host(p, s, const Scaffold(body: TransactionsScreen())),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.longPress(find.textContaining('powerbill'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.textContaining('billrefund'));
      await tester.pump(const Duration(milliseconds: 300));

      final reads = p.ledgerReads;
      final screen = tester.element(find.byType(TransactionsScreen));
      for (var i = 0; i < 3; i++) {
        (screen as StatefulElement).markNeedsBuild();
        await tester.pump();
      }
      // Build reads the ledger once; the old Link refund check read it a
      // second time on every build.
      expect(p.ledgerReads - reads, 3);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('bulk-more-link-refund')),
        findsOneWidget,
      );
    });

    testWidgets('month headers name the month, and the year when it is not '
        'this one', (tester) async {
      final now = DateTime.now();
      final thisMonth = DateTime(now.year, now.month, 1, 9);
      final older = DateTime(now.year - 1, 7, 4, 9);
      final p = await _ledger([
        _manual('n', 'nowrow', 40, thisMonth),
        _manual('o', 'oldrow', 60, older),
      ]);
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(
        _host(p, s, const Scaffold(body: TransactionsScreen())),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(DateFormat('MMMM').format(thisMonth).toUpperCase()),
        findsOneWidget,
      );
      expect(find.text('oldrow'), findsOneWidget);
      expect(
        find.text(DateFormat('MMMM yyyy').format(older).toUpperCase()),
        findsWidgets,
      );
    });
  });
}
