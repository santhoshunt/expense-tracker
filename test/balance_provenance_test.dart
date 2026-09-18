import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/utils/format.dart';

import 'dashboard_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Tx row(
    String id,
    double amount, {
    required DateTime date,
    String acct = 'HDFC:1111',
    TxType type = TxType.expense,
    bool pending = false,
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
    sender: 'VM-HDFCBK',
    acctKey: acct,
    pending: pending,
    balanceAfter: balanceAfter,
  );

  Future<FinanceProvider> load({
    required List<Tx> txs,
    List<Account> accounts = const [],
  }) async {
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([for (final t in txs) t.toJson()]),
      if (accounts.isNotEmpty)
        'accounts_v1': jsonEncode([for (final a in accounts) a.toJson()]),
    });
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  final anchorAt = DateTime(2026, 7, 1, 10);

  group('accountProvenance', () {
    test(
      'alert: rows after the anchor count, same-timestamp ones too',
      () async {
        final p = await load(
          txs: [
            row('before', 100, date: DateTime(2026, 6, 20)),
            row('anchor', 200, date: anchorAt, balanceAfter: 5000),
            // Exact same timestamp, later insertion — the index rule counts it.
            row('tie', 50, date: anchorAt),
            row('later', 75, date: DateTime(2026, 7, 5)),
          ],
        );
        final id = await p.addAccount(name: 'Bank', type: AccountType.bank);
        await p.addAccountKey(id, 'HDFC:1111');
        final acct = p.accountById(id)!;

        final prov = p.accountProvenance(acct);
        expect(prov.source, BalanceSource.alert);
        expect(prov.asOf, anchorAt);
        expect(prov.rowsSince, 2, reason: 'tie + later');
        expect(prov.blocker, isNull);
        expect(p.accountBalance(acct), 5000 - 50 - 75);
      },
    );

    test(
      'manual: strictly-after rule; row at the exact timestamp skipped',
      () async {
        final manualAt = DateTime(2026, 7, 10, 9);
        final p = await load(
          txs: [
            row('at', 100, date: manualAt),
            row('after', 40, date: DateTime(2026, 7, 10, 9, 0, 1)),
          ],
          accounts: [
            Account(
              id: 'b1',
              name: 'Bank',
              type: AccountType.bank,
              keys: const {'HDFC:1111'},
              manualBalance: 9000,
              manualBalanceAt: manualAt,
            ),
          ],
        );
        final acct = p.accountById('b1')!;
        final prov = p.accountProvenance(acct);
        expect(prov.source, BalanceSource.manual);
        expect(prov.asOf, manualAt);
        expect(prov.rowsSince, 1);
        expect(p.accountBalance(acct), 9000 - 40);
      },
    );

    test('ledger: counts every non-pending, non-future row', () async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final p = await load(
        txs: [
          row('a', 100, date: DateTime(2026, 7, 1)),
          row('b', 60, date: DateTime(2026, 7, 2), type: TxType.income),
          row('pending', 10, date: DateTime(2026, 7, 3), pending: true),
          row('future', 10, date: tomorrow),
        ],
      );
      final id = await p.addAccount(name: 'Bank', type: AccountType.bank);
      await p.addAccountKey(id, 'HDFC:1111');
      final prov = p.accountProvenance(p.accountById(id)!);
      expect(prov.source, BalanceSource.ledger);
      expect(prov.asOf, isNull);
      expect(prov.rowsSince, 2);
    });

    test('card blockers: noAlert vs limitUnknown', () async {
      // Limit set, but no row ever stated a balance → only "Set outstanding"
      // can help.
      final p1 = await load(
        txs: [row('spend', 500, date: DateTime(2026, 7, 2))],
        accounts: [
          Account(
            id: 'c1',
            name: 'Card',
            type: AccountType.creditCard,
            keys: const {'HDFC:1111'},
            creditLimit: 100000,
          ),
        ],
      );
      final card1 = p1.accountById('c1')!;
      expect(p1.accountOutstanding(card1), isNull);
      expect(p1.accountProvenance(card1).blocker, OutstandingBlocker.noAlert);

      // Estimated limit collapsed onto the newest alert → the real credit
      // limit is what is missing.
      final p2 = await load(
        txs: [row('anchor', 500, date: anchorAt, balanceAfter: 60000)],
        accounts: [
          Account(
            id: 'c2',
            name: 'Card 2',
            type: AccountType.creditCard,
            keys: const {'HDFC:1111'},
          ),
        ],
      );
      final card2 = p2.accountById('c2')!;
      expect(p2.accountOutstanding(card2), isNull);
      expect(
        p2.accountProvenance(card2).blocker,
        OutstandingBlocker.limitUnknown,
      );

      // A computable outstanding carries no blocker.
      await p2.setCreditLimit('c2', 100000);
      expect(p2.accountOutstanding(card2), 40000);
      expect(p2.accountProvenance(card2).blocker, isNull);
    });
  });

  group('accounts screen line', () {
    Widget app(FinanceProvider p) => ChangeNotifierProvider.value(
      value: p,
      child: MaterialApp(
        home: Scaffold(body: AccountsScreen(onViewAccount: (_) {})),
      ),
    );

    testWidgets('bank tile says alert + N txns since', (tester) async {
      final p = await load(
        txs: [
          row('anchor', 200, date: anchorAt, balanceAfter: 5000),
          row('s1', 50, date: DateTime(2026, 7, 5)),
          row('s2', 25, date: DateTime(2026, 7, 6)),
        ],
      );
      final id = await p.addAccount(name: 'Bank', type: AccountType.bank);
      await p.addAccountKey(id, 'HDFC:1111');
      await tester.pumpWidget(app(p));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text(
          'From bank alert · ${fmtDateMaybeTime(anchorAt)}'
          ' + 2 txns since',
        ),
        findsOneWidget,
      );
    });

    testWidgets('card with a limit but no alert offers Set outstanding', (
      tester,
    ) async {
      final p = await load(
        txs: [row('spend', 500, date: DateTime(2026, 7, 2))],
        accounts: [
          Account(
            id: 'c1',
            name: 'Card',
            type: AccountType.creditCard,
            keys: const {'HDFC:1111'},
            creditLimit: 100000,
          ),
        ],
      );
      await tester.pumpWidget(app(p));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text("No bank alert has stated this card's balance yet."),
        findsOneWidget,
      );
      expect(find.text('Set outstanding…'), findsOneWidget);
      expect(find.text("Set credit limit to see what's owed"), findsNothing);

      await tester.tap(find.text('Set outstanding…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Set outstanding'), findsOneWidget);
      expect(find.text('Current outstanding'), findsOneWidget);
    });

    testWidgets('the All view groups accounts by type under headers', (
      tester,
    ) async {
      final p = await load(
        txs: const [],
        accounts: [
          Account(
            id: 'b1',
            name: 'My Bank',
            type: AccountType.bank,
            keys: const {'HDFC:1111'},
          ),
          Account(
            id: 'c1',
            name: 'My Card',
            type: AccountType.creditCard,
            keys: const {'HDFC:2222'},
          ),
          Account(
            id: 's1',
            name: 'My RD',
            type: AccountType.savings,
            keys: const {'HDFC:3333'},
          ),
        ],
      );
      await tester.pumpWidget(app(p));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('BANKS', skipOffstage: false), findsOneWidget);
      expect(find.text('CREDIT CARDS', skipOffstage: false), findsOneWidget);
      expect(
        find.text('SAVINGS & ASSETS', skipOffstage: false),
        findsOneWidget,
      );

      // A filtered view IS one type — no headers there. Settle: during the
      // page slide the outgoing All page (with its headers) is still alive.
      await tester.tap(find.text('Banks'));
      await tester.pumpAndSettle();
      expect(find.text('BANKS', skipOffstage: false), findsNothing);
      expect(find.text('My Bank'), findsOneWidget);
    });

    testWidgets('a swipe on the list steps the type filter', (tester) async {
      final p = await load(
        txs: [row('anchor', 200, date: anchorAt, balanceAfter: 5000)],
        accounts: [
          Account(
            id: 'b1',
            name: 'My Bank',
            type: AccountType.bank,
            keys: const {'HDFC:1111'},
          ),
          Account(
            id: 's1',
            name: 'My FD',
            type: AccountType.savings,
            keys: const {'HDFC:3333'},
          ),
        ],
      );
      await tester.pumpWidget(app(p));
      await tester.pumpAndSettle();
      expect(find.text('BANKS'), findsOneWidget);

      // Swipe left on a row: the drag falls through to the PageView.
      await tester.fling(find.text('My Bank'), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('BANKS'), findsNothing, reason: 'flat filtered view');
      expect(find.text('My Bank'), findsOneWidget);
      expect(find.text('My FD'), findsNothing);

      // Tapping a tab animates there; pumpAndSettle proves it terminates.
      await tester.tap(find.text('Savings'));
      await tester.pumpAndSettle();
      expect(find.text('My FD'), findsOneWidget);
      expect(find.text('My Bank'), findsNothing);

      // The Cards page is empty — its blank space still swipes back.
      await tester.tap(find.text('Cards'));
      await tester.pumpAndSettle();
      expect(find.textContaining('accounts yet'), findsOneWidget);
      await tester.flingFrom(
        const Offset(400, 400),
        const Offset(300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('My Bank'), findsOneWidget);
    });

    testWidgets('a long provenance line wraps on a narrow screen', (
      tester,
    ) async {
      // 320 logical px — narrower than the longest line at 12px, so it must
      // break onto a second line. An overflow (clipping) would throw and
      // fail the test on its own; the height check proves it wrapped.
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = await load(
        txs: [
          row('anchor', 200, date: anchorAt, balanceAfter: 5000),
          for (var d = 2; d <= 12; d++)
            row('s$d', 10, date: DateTime(2026, 7, d)),
        ],
      );
      final id = await p.addAccount(name: 'Bank', type: AccountType.bank);
      await p.addAccountKey(id, 'HDFC:1111');
      await tester.pumpWidget(app(p));
      await tester.pump(const Duration(milliseconds: 400));

      final line =
          'From bank alert · ${fmtDateMaybeTime(anchorAt)}'
          ' + 11 txns since';
      final text = find.text(line);
      await tester.scrollUntilVisible(
        text,
        300,
        scrollable: verticalScrollable(),
      );
      await tester.pump();
      final height = tester.getSize(text).height;
      final oneLine = tester
          .renderObject<RenderParagraph>(text)
          .preferredLineHeight;
      expect(
        height,
        greaterThan(oneLine * 1.5),
        reason: 'the line should wrap to at least two lines, not clip',
      );
    });
  });
}
