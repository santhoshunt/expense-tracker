import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/services/upcoming_items.dart';
import 'package:expense_tracker/services/upcoming_monitor.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/utils/money_colors.dart';
import 'package:expense_tracker/widgets/balance_breakdown.dart';

import 'dashboard_test_utils.dart';
import 'upcoming_monitor_test.dart' show FakeNotifications;

/// A credit card can be in credit: a full payment followed by a refund
/// leaves the bank owing the user. Every name, number and amount here is
/// invented.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  const key = 'DEMO:4523';
  final setAt = DateTime(2026, 7, 10, 9);

  Tx row(
    String id,
    double amount, {
    required DateTime date,
    TxType type = TxType.income,
    double? balanceAfter,
  }) => Tx(
    id: id,
    type: type,
    categoryId: type == TxType.expense ? 'other_expense' : 'other_income',
    amount: amount,
    note: '',
    smsBody: 'Rs.$amount',
    date: date,
    source: TxSource.sms,
    sender: 'VM-DEMOBK',
    acctKey: key,
    balanceAfter: balanceAfter,
  );

  Account card({
    String id = 'c1',
    String name = 'Demo Card One',
    Set<String> keys = const {},
    double? creditLimit,
    double? manual,
    int? dueDay,
  }) => Account(
    id: id,
    name: name,
    type: AccountType.creditCard,
    keys: keys,
    creditLimit: creditLimit,
    manualBalance: manual,
    manualBalanceAt: manual == null ? null : setAt,
    dueDay: dueDay,
  );

  Account bank(double balance) => Account(
    id: 'b1',
    name: 'Demo Bank',
    type: AccountType.bank,
    keys: const {},
    manualBalance: balance,
    manualBalanceAt: setAt,
  );

  Future<FinanceProvider> load({
    List<Tx> txs = const [],
    required List<Account> accounts,
  }) async {
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([for (final t in txs) t.toJson()]),
      'accounts_v1': jsonEncode([for (final a in accounts) a.toJson()]),
    });
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  /// Set at ₹2,000 owed, paid in full, then a ₹500 refund: ₹500 in credit.
  Future<FinanceProvider> refundedCard({int? dueDay}) => load(
    txs: [
      row('pay', 2000, date: DateTime(2026, 7, 11)),
      row('refund', 500, date: DateTime(2026, 7, 12)),
    ],
    accounts: [
      card(
        keys: const {key},
        creditLimit: 100000,
        manual: 2000,
        dueDay: dueDay,
      ),
    ],
  );

  group('figures', () {
    test('a set figure, paid in full, then a refund goes into credit', () async {
      final p = await refundedCard();
      final c = p.accountById('c1')!;
      expect(p.accountOutstanding(c), -500);
      // Available runs past the limit by the credit.
      expect(p.accountAvailable(c), 100500);
      expect(p.cardOutstandingTotal, 0);
      expect(p.cardOutstandingCount, 0);
      expect(p.cardCreditTotal, 500);
      expect(p.netWorth, 500);
    });

    /// Two alerts (the newer stating less available, so the guess does not
    /// collapse onto it) and a ₹1,500 payment after them.
    List<Tx> alertRows() => [
      row(
        'a1',
        200,
        type: TxType.expense,
        date: DateTime(2026, 7, 1),
        balanceAfter: 100000,
      ),
      row(
        'a2',
        300,
        type: TxType.expense,
        date: DateTime(2026, 7, 2),
        balanceAfter: 99000,
      ),
      row('pay', 1500, date: DateTime(2026, 7, 3)),
    ];

    test('an alert figure with a set credit limit goes into credit', () async {
      final p = await load(
        txs: alertRows(),
        accounts: [card(keys: const {key}, creditLimit: 100000)],
      );
      final c = p.accountById('c1')!;
      expect(p.accountOutstanding(c), -500);
      expect(p.accountAvailable(c), 100500);
      expect(p.cardCreditTotal, 500);
    });

    test('an alert figure with an estimated limit stays at zero', () async {
      final p = await load(
        txs: alertRows(),
        accounts: [card(keys: const {key})],
      );
      final c = p.accountById('c1')!;
      expect(p.creditLimitIsEstimated(c), isTrue);
      expect(p.accountOutstanding(c), 0);
      expect(p.accountAvailable(c), 100000);
      expect(p.cardCreditTotal, 0);
    });

    test('total due ignores a card in credit; net balance adds the credit', () async {
      final p = await load(
        accounts: [
          bank(10000),
          card(id: 'c1', manual: -500),
          card(id: 'c2', name: 'Demo Card Two', manual: 3000),
        ],
      );
      expect(p.cardOutstandingTotal, 3000);
      expect(p.cardOutstandingCount, 1);
      expect(p.cardCreditTotal, 500);
      expect(p.netWorth, 10000 - 3000 + 500);
    });

    test('a credit under half a paisa counts as none', () async {
      final p = await load(
        accounts: [bank(10000), card(manual: -0.003)],
      );
      expect(p.cardCreditTotal, 0);
      expect(p.cardOutstandingTotal, 0);
      expect(p.netWorth, 10000);
    });
  });

  test('parseAmount reads a hyphen and a true minus alike', () {
    expect(parseAmount('-500'), -500);
    expect(parseAmount('−500'), -500);
    expect(parseAmount('₹ −1,250.50'), -1250.5);
    expect(parseAmount('500'), 500);
    // Only a leading minus: one inside the number is no number.
    expect(parseAmount('5−00'), isNull);
  });

  group('bills', () {
    test('a card in credit has no bill row; one that owes does', () async {
      final p = await load(
        accounts: [
          card(id: 'c1', manual: -500, dueDay: 5),
          card(id: 'c2', name: 'Demo Card Two', manual: 3000, dueDay: 5),
        ],
      );
      final bills = buildUpcomingItems(
        p,
        hits: const [],
        hidden: const {},
        now: DateTime.now(),
      ).where((i) => i.kind == UpcomingKind.cardBill);
      expect(bills.map((i) => i.card!.id), ['c2']);
    });

    test('a card in credit gets no due alert; one that owes does', () async {
      final notifications = FakeNotifications();
      // One clock read: both due days and the check share it.
      final now = DateTime.now();
      final p = await load(
        accounts: [
          card(id: 'c1', manual: -500, dueDay: now.day),
          card(id: 'c2', name: 'Demo Card Two', manual: 3000, dueDay: now.day),
        ],
      );
      final settings = SettingsProvider();
      await settings.load();
      await UpcomingMonitor(
        notifications: notifications,
      ).check(p, settings, now: now);
      expect(notifications.shown, hasLength(1));
      expect(notifications.shown.single.$2, startsWith('Demo Card Two'));
    });
  });

  group('accounts screen', () {
    Widget app(FinanceProvider p, {bool expanded = true}) {
      final s = SettingsProvider();
      if (expanded) {
        for (final a in p.accounts) {
          s.setAccountExpanded(a.id, true);
        }
      }
      return MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          home: Scaffold(body: AccountsScreen(onViewAccount: (_) {})),
        ),
      );
    }

    void tall(WidgetTester tester, {double width = 800}) {
      tester.view.physicalSize = Size(width, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Finder tileFigure(String text) => find.byWidgetPredicate(
      (w) => w is Text && w.data == text && w.style?.fontSize == 20,
    );

    Color green(WidgetTester tester) =>
        moneyColor(tester.element(find.byType(AccountsScreen)), type: TxType.income);

    testWidgets('the tile shows a credit balance in green', (tester) async {
      tall(tester);
      final p = await refundedCard(dueDay: 5);
      await tester.pumpWidget(app(p));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Credit balance'), findsOneWidget);
      expect(find.text('Outstanding'), findsNothing);
      final figure = tileFigure(fmtMoney(500));
      expect(figure, findsOneWidget);
      final style = tester.widget<Text>(figure).style!;
      expect(style.color, green(tester));
      expect(style.fontWeight, FontWeight.w800);
      // The provenance line stays as it is.
      expect(
        find.text('Set by you · ${fmtDateMaybeTime(setAt)} + 2 txns since'),
        findsOneWidget,
      );
      expect(
        find.text('Available ${fmtMoney(100500)} of ${fmtMoney(100000)}'),
        findsOneWidget,
      );
      expect(
        find.text('No dues · ${fmtMoney(500)} comes off the next bill'),
        findsOneWidget,
      );
      // No minus anywhere on the tile.
      expect(find.textContaining('−'), findsNothing);
    });

    testWidgets('a card owing nothing reads as before', (tester) async {
      tall(tester);
      final p = await load(accounts: [card(manual: 0, dueDay: 5)]);
      await tester.pumpWidget(app(p));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Outstanding'), findsOneWidget);
      expect(find.text('Credit balance'), findsNothing);
      final figure = tileFigure(fmtMoney(0));
      expect(figure, findsOneWidget);
      expect(
        tester.widget<Text>(figure).style!.color,
        Theme.of(tester.element(figure)).colorScheme.onSurface,
      );
      expect(find.text('No dues'), findsOneWidget);
      expect(find.text('Credit on cards'), findsNothing);
    });

    testWidgets('the list row and net lines show the credit in green', (
      tester,
    ) async {
      tall(tester);
      final p = await refundedCard();
      await tester.pumpWidget(app(p, expanded: false));
      await tester.pump(const Duration(milliseconds: 400));

      final words = find.text(' credit balance');
      expect(words, findsOneWidget);
      final figure = find.descendant(
        of: find.ancestor(of: words, matching: find.byType(Row)).first,
        matching: find.text(fmtMoney(500)),
      );
      expect(figure, findsOneWidget);
      expect(tester.widget<Text>(figure).style!.color, green(tester));
      expect(find.textContaining(' due'), findsNothing);
      expect(find.text('Nothing due'), findsNothing);

      // The net balance's lines add up to the headline.
      final line = find.text('Credit on cards');
      expect(line, findsOneWidget);
      final amount = find.descendant(
        of: find.ancestor(of: line, matching: find.byType(Row)).first,
        matching: find.text(fmtMoney(500)),
      );
      expect(amount, findsOneWidget);
      expect(tester.widget<Text>(amount).style!.color, green(tester));
      expect(find.textContaining('Due on'), findsNothing);
    });

    testWidgets('net lines with no card in credit read as before', (
      tester,
    ) async {
      tall(tester);
      final p = await load(accounts: [bank(10000), card(manual: 3000)]);
      await tester.pumpWidget(app(p, expanded: false));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('In 1 bank'), findsOneWidget);
      expect(find.text('Due on 1 card'), findsOneWidget);
      expect(find.text('Credit on cards'), findsNothing);
    });

    testWidgets('Set outstanding takes a minus and says so', (tester) async {
      tall(tester);
      final p = await load(accounts: [card(manual: -500)]);
      await tester.pumpWidget(app(p));
      await tester.pump(const Duration(milliseconds: 400));

      Future<void> open() async {
        await tester.tap(find.text('More'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Set outstanding…'));
        await tester.pumpAndSettle();
      }

      final save = find.widgetWithText(FilledButton, 'Save');
      await open();
      expect(
        find.text(
          'Now ${fmtMoney(500)} in credit · set by you on '
          '${fmtDateCompact(setAt)}',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Leave blank to clear it. A minus means the bank owes you.'),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.keyboardType,
        const TextInputType.numberWithOptions(decimal: true, signed: true),
      );
      // The true minus the app prints, which saves back unchanged.
      expect(field.controller!.text, '−500.00');

      await tester.enterText(find.byType(TextField), '-750');
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(p.accountById('c1')!.manualBalance, -750);
      expect(
        find.text('Demo Card One set to ${fmtMoney(750)} in credit'),
        findsOneWidget,
      );
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(p.accountById('c1')!.manualBalance, -500);
      expect(p.accountById('c1')!.manualBalanceAt, setAt);

      await open();
      await tester.enterText(find.byType(TextField), '−250');
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(p.accountById('c1')!.manualBalance, -250);
    });

    group('limit hint', () {
      const hint =
          "The bank states more available than this card's limit. If the "
          'limit went up, set the new one.';

      /// An alert stating [available] on a card with a ₹1,00,000 limit
      /// entered by the user, then [extra] rows.
      Future<FinanceProvider> alerted(
        double available, {
        List<Tx> extra = const [],
        double? manual,
      }) => load(
        txs: [
          row(
            'alert',
            200,
            type: TxType.expense,
            date: DateTime(2026, 7, 1),
            balanceAfter: available,
          ),
          ...extra,
        ],
        accounts: [
          card(keys: const {key}, creditLimit: 100000, manual: manual),
        ],
      );

      testWidgets('an alert above the entered limit asks about the limit', (
        tester,
      ) async {
        tall(tester);
        final p = await alerted(120000);
        expect(p.accountOutstanding(p.accountById('c1')!), -20000);
        await tester.pumpWidget(app(p));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Credit balance'), findsOneWidget);
        expect(find.text(hint), findsOneWidget);
        await tester.tap(find.text('Set credit limit…'));
        await tester.pumpAndSettle();
        expect(find.text('Credit limit'), findsOneWidget);
      });

      testWidgets('no hint for a credit from a figure the user set', (
        tester,
      ) async {
        tall(tester);
        // The same alert, but the user's figure (set after it) wins.
        final p = await alerted(120000, manual: -500);
        expect(p.accountOutstanding(p.accountById('c1')!), -500);
        await tester.pumpWidget(app(p));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Credit balance'), findsOneWidget);
        expect(find.text(hint), findsNothing);
      });

      testWidgets('no hint for a credit only from rows after the alert', (
        tester,
      ) async {
        tall(tester);
        final p = await alerted(
          99000,
          extra: [row('pay', 1500, date: DateTime(2026, 7, 2))],
        );
        expect(p.accountOutstanding(p.accountById('c1')!), -500);
        await tester.pumpWidget(app(p));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Credit balance'), findsOneWidget);
        expect(find.text(hint), findsNothing);
      });

      testWidgets('no hint for a card that owes', (tester) async {
        tall(tester);
        // Above the limit at the alert, but spends since put it in debt.
        final p = await alerted(
          120000,
          extra: [
            row(
              'spend',
              25000,
              type: TxType.expense,
              date: DateTime(2026, 7, 2),
            ),
          ],
        );
        expect(p.accountOutstanding(p.accountById('c1')!), 5000);
        await tester.pumpWidget(app(p));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Outstanding'), findsOneWidget);
        expect(find.text(hint), findsNothing);
      });

      testWidgets('the hint fits at 1.3x text on a narrow screen', (
        tester,
      ) async {
        tall(tester, width: 360);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final p = await alerted(120000);
        await tester.pumpWidget(app(p));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text(hint), findsOneWidget);
        expect(find.text('Set credit limit…'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('a bank keeps its number pad and helper', (tester) async {
      tall(tester);
      final p = await load(accounts: [bank(4200)]);
      await tester.pumpWidget(app(p));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set balance…'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).keyboardType,
        const TextInputType.numberWithOptions(decimal: true),
      );
      expect(find.text('Leave blank to clear it'), findsOneWidget);
    });

    testWidgets('the tile and dialog fit at 1.3x text on a narrow screen', (
      tester,
    ) async {
      tall(tester, width: 360);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final p = await refundedCard(dueDay: 5);
      await tester.pumpWidget(app(p));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Credit balance'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set outstanding…'));
      await tester.pumpAndSettle();
      expect(
        find.text('Leave blank to clear it. A minus means the bank owes you.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('net balance explanations', () {
    Future<void> openBreakdown(WidgetTester tester, FinanceProvider p) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: p),
            ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showBalanceBreakdownSheet(context, p),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the breakdown adds a credit line only with one', (
      tester,
    ) async {
      final p = await load(
        accounts: [
          bank(10000),
          card(id: 'c1', manual: -500),
          card(id: 'c2', name: 'Demo Card Two', manual: 3000),
        ],
      );
      await openBreakdown(tester, p);
      expect(find.text('Credit on cards'), findsOneWidget);
      expect(find.text('+${fmtMoney(500)}'), findsOneWidget);
      expect(find.text('−${fmtMoney(3000)}'), findsOneWidget);
      expect(find.text(fmtMoney(7500)), findsOneWidget);
    });

    testWidgets('the breakdown reads as before with no card in credit', (
      tester,
    ) async {
      final p = await load(accounts: [bank(10000), card(manual: 3000)]);
      await openBreakdown(tester, p);
      expect(find.text('Credit on cards'), findsNothing);
      expect(find.text(fmtMoney(7000)), findsOneWidget);
    });

    testWidgets('the Net balance tip spells out the credit', (tester) async {
      final now = DateTime.now();
      recapClock = () => DateTime(now.year, now.month, 20, 10);
      addTearDown(() => recapClock = DateTime.now);
      final p = FinanceProvider();
      await p.load();
      final b = await p.addAccount(name: 'Demo Bank', type: AccountType.bank);
      await p.setManualBalance(b, 50000);
      final owes = await p.addAccount(
        name: 'Demo Card Two',
        type: AccountType.creditCard,
      );
      await p.setManualBalance(owes, 12000);
      final credit = await p.addAccount(
        name: 'Demo Card One',
        type: AccountType.creditCard,
      );
      await p.setManualBalance(credit, -500);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: p),
            ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          ],
          child: MaterialApp(home: dashboardShell(DashboardScreen())),
        ),
      );
      await tester.pumpAndSettle();
      final tip = find.bySemanticsLabel('About Net balance today');
      await tester.scrollUntilVisible(
        tip,
        200,
        scrollable: verticalScrollable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(tip);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Now: ${fmtMoney(50000)} in banks − ${fmtMoney(12000)} on cards '
          '+ ${fmtMoney(500)} credit on cards = ${fmtMoney(38500)}',
        ),
        findsOneWidget,
      );
    });

    /// What the pdf package prints while [build] runs: it reports a glyph
    /// its font lacks with print(), in debug builds.
    Future<List<String>> printsOf(Future<void> Function() build) async {
      final lines = <String>[];
      await runZoned(
        build,
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => lines.add(line),
        ),
      );
      return lines;
    }

    test('the PDF report draws every sign with a glyph its font has', () async {
      // The capture works: a true minus in the report's font is reported.
      final font = pw.Font.ttf(
        await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
      );
      final control = await printsOf(() async {
        final doc = pw.Document(theme: pw.ThemeData.withFont(base: font));
        doc.addPage(pw.Page(build: (_) => pw.Text('− 1')));
        await doc.save();
      });
      expect(control, [contains('Unable to find a font')]);

      // A card that owes, a card in credit and a bank below zero.
      final p = await load(
        accounts: [
          bank(-2500),
          card(id: 'c1', manual: -500),
          card(id: 'c2', name: 'Demo Card Two', manual: 12340),
        ],
      );
      late List<int> bytes;
      final lines = await printsOf(
        () async => bytes = await BackupService.buildPdf(p),
      );
      expect(bytes.sublist(0, 4), [0x25, 0x50, 0x44, 0x46]);
      expect(lines.where((l) => l.contains('Unable to find a font')), isEmpty);
    });
  });
}
