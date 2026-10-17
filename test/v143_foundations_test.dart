import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/undo_snackbar.dart';

/// v1.43.0 foundations: whole-rupee and day-heading formats, the Paid to
/// field through the helpers, the provider and the backup, the review
/// queue, undoable category and group deletes, Restore built-in rules and
/// the toast host. Every name and amount here is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  final now = DateTime.now();
  DateTime daysAgo(int n) => DateTime(now.year, now.month, now.day - n, 12);

  group('formats', () {
    test('fmtMoneyWhole rounds to rupees with the true minus', () {
      expect(fmtMoneyWhole(142500.4), '₹1,42,500');
      expect(fmtMoneyWhole(-1200.6), '−₹1,201');
      expect(fmtMoneyWhole(-0.4), '₹0');
    });

    test('fmtDayHeading names today, yesterday, then the day', () {
      final at = DateTime(2026, 10, 17, 10);
      expect(fmtDayHeading(DateTime(2026, 10, 17, 1), now: at), 'Today');
      expect(fmtDayHeading(DateTime(2026, 10, 16, 23), now: at), 'Yesterday');
      expect(fmtDayHeading(DateTime(2026, 10, 15), now: at), 'Thu 15 Oct');
      expect(fmtDayHeading(DateTime(2025, 10, 15), now: at), 'Wed 15 Oct 2025');
      // Across a year end, yesterday is still Yesterday.
      expect(
        fmtDayHeading(DateTime(2026, 12, 31), now: DateTime(2027, 1, 1, 8)),
        'Yesterday',
      );
    });
  });

  group('payee', () {
    Tx manual({String payee = '', String note = '', TxType? type}) => Tx(
      id: 'm',
      type: type ?? TxType.expense,
      categoryId: type == TxType.income ? 'other_income' : 'food',
      amount: 90,
      note: note,
      date: DateTime(2026, 10, 3, 13),
      payee: payee,
    );

    test('normalizePayee collapses spaces and caps the length', () {
      expect(normalizePayee('  Kappa   Cafe \n'), 'Kappa Cafe');
      expect(normalizePayee('x' * 80).length, kMaxPayeeLength);
    });

    test('JSON keeps a payee and leaves the key out when empty', () {
      expect(manual().toJson().containsKey('payee'), isFalse);
      final json = manual(payee: 'Kappa Cafe').toJson();
      expect(json['payee'], 'Kappa Cafe');
      expect(Tx.fromJson(json).payee, 'Kappa Cafe');
      expect(manual(payee: 'A').copyWith(note: 'b').payee, 'A');
    });

    test('a payee names the merchant before the note', () {
      final paid = manual(payee: 'Sample Mess', note: 'dinner');
      expect(merchantIdentityOf(paid), 'sample mess');
      // An older row whose note named the place joins the same merchant.
      expect(merchantIdentityOf(manual(note: 'Sample Mess')), 'sample mess');
      expect(merchantLabelOrNull(manual(payee: 'kappa CAFE')), 'kappa CAFE');
      expect(merchantLabelOrNull(manual(note: 'kappa CAFE')), 'Kappa Cafe');
    });

    test('rowTitleOf: payee, else the note line as typed, else null', () {
      expect(
        rowTitleOf(manual(payee: 'Kappa Cafe', note: 'lunch')),
        'Kappa Cafe',
      );
      expect(
        rowTitleOf(manual(note: 'City Metro recharge\nsecond line')),
        'City Metro recharge',
      );
      expect(rowTitleOf(manual()), isNull);
      expect(
        rowTitleOf(
          manual(payee: 'Kappa Cafe'),
          alias: (id) => id == 'kappa cafe' ? 'Kappa' : null,
        ),
        'Kappa',
      );
    });

    test('CSV round trip keeps the payee', () {
      final csv = BackupService.buildCsvOf([manual(payee: 'Kappa Cafe')]);
      expect(csv.split('\r\n').first, endsWith(',payee'));
      expect(BackupService.txsFromCsv(csv).single.payee, 'Kappa Cafe');
    });

    test(
      'addTransaction stores the payee tidied; rowTitleFor reads it',
      () async {
        final p = await loaded();
        final id = await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 120,
          note: 'lunch',
          date: daysAgo(1),
          payee: '  Kappa   Cafe ',
        );
        final t = p.transactions.firstWhere((t) => t.id == id);
        expect(t.payee, 'Kappa Cafe');
        expect(p.rowTitleFor(t), 'Kappa Cafe');
        expect(p.exportData()['version'], 28);
        // The stored ledger keeps it across a restart.
        final again = await loaded();
        expect(
          again.transactions.firstWhere((t) => t.id == id).payee,
          'Kappa Cafe',
        );
      },
    );

    test('recentPayees: newest first, distinct, manual, of the type', () async {
      final p = await loaded();
      Future<void> add(
        int ago, {
        String payee = '',
        String note = '',
        TxType type = TxType.expense,
        String categoryId = 'food',
      }) => p.addTransaction(
        type: type,
        categoryId: categoryId,
        amount: 50,
        note: note,
        date: daysAgo(ago),
        payee: payee,
      );
      await add(1, payee: 'Sample Mess');
      await add(2, note: 'Corner Shop');
      await add(3, payee: 'sample mess');
      await add(4, note: 'a note far too long to be anyone at all, ' * 3);
      await add(
        5,
        payee: 'Delta Pay',
        type: TxType.income,
        categoryId: 'other_income',
      );
      expect(p.recentPayees(TxType.expense), ['Sample Mess', 'Corner Shop']);
      expect(p.recentPayees(TxType.income), ['Delta Pay']);
    });
  });

  group('review queue', () {
    Map<String, dynamic> pendingRow(
      String id,
      double amount, {
      bool spam = false,
    }) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: amount,
      note: '',
      smsBody: 'Rs.$amount debited from a/c XX4321 to VPA demo@upi',
      date: daysAgo(2),
      source: TxSource.sms,
      pending: true,
      suspectedSpam: spam,
    ).toJson();

    Future<FinanceProvider> withPending() async {
      final p = await loaded();
      await p.importData({
        'app': 'expense_tracker',
        'version': 28,
        'transactions': [
          pendingRow('a', 110),
          pendingRow('b', 220),
          pendingRow('s', 330, spam: true),
        ],
        'accounts': <Object>[],
      }, replace: false);
      return p;
    }

    test('counts imports, spam and the rows no suggestion shows', () async {
      final p = await withPending();
      final q = p.reviewQueue(const {});
      expect(q.pending.map((t) => t.id), unorderedEquals(['a', 'b']));
      expect(q.spam.single.id, 's');
      expect(q.rows, hasLength(2));
      expect(q.reviewCount, 2);
      expect(q.badgeCount, 3);
      expect(p.reviewCount(const {}), 3);
      expect(identical(p.reviewQueue(const {}), q), isTrue);
    });

    test('an empty ledger has an empty queue and a zero badge', () async {
      final p = await loaded();
      expect(p.reviewQueue(const {}).isEmpty, isTrue);
      expect(p.reviewCount(const {}), 0);
    });

    test(
      'Confirm all returns the rows as they were; Undo puts them back',
      () async {
        final p = await withPending();
        final rows = await p.confirmAllPending();
        expect(rows.map((t) => t.id), unorderedEquals(['a', 'b']));
        expect(rows.every((t) => t.pending), isTrue);
        expect(p.pendingCount, 1, reason: 'spam stays');
        await p.restoreEditedTransactions(rows);
        expect(p.pendingCount, 3);
        // With only spam waiting, nothing is confirmed and nothing returned.
        await p.confirmAllPending();
        expect(await p.confirmAllPending(), isEmpty);
      },
    );
  });

  group('undoable deletes', () {
    test(
      'a category comes back with its rows, rule, group and budget',
      () async {
        final p = await loaded();
        final cat = await p.addCategory(
          label: 'Pets',
          type: TxType.expense,
          icon: Icons.pets,
          color: Colors.teal,
        );
        final row = await p.addTransaction(
          type: TxType.expense,
          categoryId: cat,
          amount: 400,
          note: 'Vetco',
          date: daysAgo(3),
        );
        await p.addRule('vetco', cat);
        final group = await p.addGroup(label: 'Care', color: Colors.blue);
        await p.assignCategoryToGroup(cat, group);
        await p.addBudget(
          name: 'Pets',
          limit: 2000,
          mode: BudgetMode.include,
          categoryIds: {cat},
        );

        final d = await p.deleteCategory(cat);
        expect(
          p.transactions.firstWhere((t) => t.id == row).categoryId,
          'other_expense',
        );
        expect(p.rules.any((r) => r.categoryId == cat), isFalse);
        expect(p.groupIdOf(cat), isNull);
        expect(p.budgets.single.categoryIds, isNot(contains(cat)));

        await p.restoreCategory(d);
        expect(customCategories.any((c) => c.id == cat), isTrue);
        expect(p.transactions.firstWhere((t) => t.id == row).categoryId, cat);
        expect(p.rules.first.categoryId, cat);
        expect(p.groupIdOf(cat), group);
        expect(p.budgets.single.categoryIds, contains(cat));
      },
    );

    test('a group comes back with members not moved meanwhile', () async {
      final p = await loaded();
      final group = await p.addGroup(label: 'Care', color: Colors.blue);
      final other = await p.addGroup(label: 'Fun', color: Colors.pink);
      await p.assignCategoryToGroup('health', group);
      await p.assignCategoryToGroup('education', group);
      final d = await p.deleteGroup(group);
      expect(d, isNotNull);
      expect(await p.deleteGroup('nope'), isNull);
      await p.assignCategoryToGroup('education', other);

      await p.restoreGroup(d!);
      expect(p.groups.any((g) => g.id == group), isTrue);
      expect(p.groupIdOf('health'), group);
      expect(p.groupIdOf('education'), other);
    });
  });

  group('Restore built-in rules', () {
    test('puts back a deleted built-in and counts it', () async {
      final p = await loaded();
      final seeded = p.rules.where((r) => r.isBuiltIn).length;
      expect(p.rules.any((r) => r.id == 'builtin_swiggy'), isTrue);
      await p.deleteRule('builtin_swiggy');
      expect(await p.restoreDefaultRules(), 1);
      expect(p.rules.where((r) => r.isBuiltIn), hasLength(seeded));
      expect(await p.restoreDefaultRules(), 0);
    });

    test("a user's opposite direction twin does not keep it out", () async {
      final p = await loaded();
      await p.deleteRule('builtin_swiggy');
      await p.addRule('Swiggy', 'other_income');
      expect(await p.restoreDefaultRules(), 1);
      expect(p.rules.any((r) => r.id == 'builtin_swiggy'), isTrue);
      // A same direction rule of the user's does keep it out.
      await p.deleteRule('builtin_zomato');
      await p.addRule('zomato', 'shopping');
      expect(await p.restoreDefaultRules(), 0);
      expect(p.rules.any((r) => r.id == 'builtin_zomato'), isFalse);
    });

    test(
      'counts a built-in that one of your rules takes the place of',
      () async {
        final p = await loaded();
        expect(p.rules.any((r) => r.id == 'builtin_restaurant'), isTrue);
        await p.addRule('Restaurant', 'shopping');
        // Removed and not seeded again: still a change, so Undo is offered.
        expect(await p.restoreDefaultRules(), 1);
        expect(p.rules.any((r) => r.id == 'builtin_restaurant'), isFalse);
        expect(await p.restoreDefaultRules(), 0);
      },
    );
  });

  testWidgets('a toast shown inside a ToastHost draws there and frees taps '
      'once it closes', (tester) async {
    late BuildContext inner;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToastHost(
            child: Builder(
              builder: (c) {
                inner = c;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    IgnorePointer strip() => tester.widget<IgnorePointer>(
      find.byWidgetPredicate((w) => w is IgnorePointer && w.child is Scaffold),
    );
    expect(strip().ignoring, isTrue);

    showAppToast(inner, 'Linked as a refund');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ToastHost),
        matching: find.text('Linked as a refund'),
      ),
      findsOneWidget,
    );
    expect(strip().ignoring, isFalse);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Linked as a refund'), findsNothing);
    expect(strip().ignoring, isTrue);
  });

  // clearSnackBars drops queued pills without completing them, so a count
  // of open pills used to stick above zero after quick toasts and the
  // strip kept swallowing taps on the sheet's bottom buttons.
  testWidgets('the strip frees taps after toasts replace a queued one', (
    tester,
  ) async {
    late BuildContext inner;
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToastHost(
            child: Builder(
              builder: (c) {
                inner = c;
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: TextButton(
                    key: const ValueKey('under-strip'),
                    onPressed: () => taps++,
                    child: const Text('Under the strip'),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('under-strip'));

    // The first pill starts its entry; the second then waits behind it, and
    // the third's clearSnackBars drops the second without completing it.
    // Partway in: a pill still at its start would hide at once instead.
    showAppToast(inner, 'First toast');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    showAppToast(inner, 'Second toast');
    showAppToast(inner, 'Third toast');
    await tester.pumpAndSettle();
    // A pill is up: the strip takes the tap.
    await tester.tap(button, warnIfMissed: false);
    expect(taps, 0);

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
    expect(find.text('Third toast'), findsNothing);
    expect(
      tester
          .widget<IgnorePointer>(
            find.byWidgetPredicate(
              (w) => w is IgnorePointer && w.child is Scaffold,
            ),
          )
          .ignoring,
      isTrue,
    );
    await tester.tap(button);
    expect(taps, 1);
  });
}
