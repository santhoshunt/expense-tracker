import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/screens/category_management.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/widgets/budget_dialog.dart';
import 'package:expense_tracker/widgets/reminder_editor_dialog.dart';
import 'package:expense_tracker/widgets/review_sheet.dart';

import 'accounts_test_utils.dart';

/// v1.43.7 screen fixes: a closed card's bill line, Undo after pairing and
/// unpairing, Undo of a bulk category on one transfer leg, the edit sheet's
/// double pop, a deleted account's filter, the review id a bulk refund
/// link takes, the confirm Undo's subscription mark, duplicate group names
/// and amounts with paise in the budget and reminder editors. Invented
/// names, senders and amounts only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
  });

  tearDown(() => NotificationService.statusOverride = null);

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Future<FinanceProvider> withRows(List<Tx> rows) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions(rows);
    return p;
  }

  Future<SettingsProvider> settings() async {
    final s = SettingsProvider();
    await s.load();
    return s;
  }

  Widget app(FinanceProvider p, SettingsProvider s, Widget home) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(home: home),
      );

  /// Home, then a pushed "Middle page" whose button runs [onOpen]: a second
  /// pop from the sheet or dialog above would close this page.
  Future<void> pumpMiddle(
    WidgetTester tester,
    FinanceProvider p,
    SettingsProvider s,
    void Function(BuildContext context) onOpen,
  ) async {
    await tester.pumpWidget(
      app(
        p,
        s,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: Builder(
                        builder: (ctx) => Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Middle page'),
                              TextButton(
                                onPressed: () => onOpen(ctx),
                                child: const Text('open'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  NavigatorState rootNav(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator).first);

  ButtonStyleButton button(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first,
      );

  Tx row(FinanceProvider p, String id) => [
    ...p.transactions,
    ...p.pendingTransactions,
  ].singleWhere((t) => t.id == id);

  // Two legs of one move, already paired.
  Tx outLeg({String? pairId = 'pair_t'}) => Tx(
    id: 'leg-out',
    type: TxType.expense,
    categoryId: kTransferOutCategoryId,
    amount: 5000,
    note: 'billdebit',
    date: DateTime(2026, 9, 15, 10),
    pairId: pairId,
  );
  Tx inLeg({String? pairId = 'pair_t'}) => Tx(
    id: 'leg-in',
    type: TxType.income,
    categoryId: kTransferInCategoryId,
    amount: 5000,
    note: 'cardack',
    date: DateTime(2026, 9, 18, 10),
    pairId: pairId,
  );

  group('closed card', () {
    testWidgets('a closed card with a due day and dues renders', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      final id = await p.addAccount(
        name: 'Demo Card',
        type: AccountType.creditCard,
      );
      await p.setCardCycle(id, dueDay: 5);
      await p.setManualBalance(id, 4000);
      await p.closeAccount(id);
      final card = p.closedAccounts.single;
      expect(card.dueDay, 5);
      expect(p.accountOutstanding(card)!, greaterThan(0));

      await tester.pumpWidget(accountsApp(p));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Demo Card', skipOffstage: false), findsWidgets);
    });
  });

  group('pairing Undo', () {
    testWidgets('bulk Pair then Undo gives a split back its people', (
      tester,
    ) async {
      final p = await withRows([
        Tx(
          id: 'leg-out',
          type: TxType.expense,
          categoryId: 'food',
          amount: 5000,
          note: 'billdebit',
          date: DateTime(2026, 9, 15, 10),
          myShare: 2000,
          people: const [SplitShare(name: 'Asha', amount: 3000)],
        ),
        Tx(
          id: 'leg-in',
          type: TxType.income,
          categoryId: 'other_income',
          amount: 5000,
          note: 'cardack',
          date: DateTime(2026, 9, 18, 10),
        ),
      ]);
      expect(row(p, 'leg-out').people, hasLength(1));
      await tester.pumpWidget(
        app(p, await settings(), const Scaffold(body: TransactionsScreen())),
      );
      await tester.pump(const Duration(milliseconds: 700));

      await tester.longPress(find.textContaining('billdebit'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.textContaining('cardack'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bulk-more-pair')));
      await tester.pumpAndSettle();
      expect(row(p, 'leg-out').pairId, isNotNull);
      expect(row(p, 'leg-out').people, isEmpty);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      final out = row(p, 'leg-out');
      expect(out.pairId, isNull);
      expect(out.categoryId, 'food');
      expect(out.myShare, 2000);
      expect(out.people.map((s) => (s.name, s.amount)), [('Asha', 3000.0)]);
      expect(row(p, 'leg-in').categoryId, 'other_income');
    });

    testWidgets('review sheet Pair then Undo puts both legs back in review', (
      tester,
    ) async {
      tall(tester);
      final p = await withRows([
        Tx(
          id: 'q-out',
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 5000,
          note: '',
          date: DateTime(2026, 10, 13, 12, 0),
          sender: 'VM-DEMOBK',
          acctKey: 'DEMOBK:1111',
          pending: true,
        ),
        Tx(
          id: 'q-in',
          type: TxType.income,
          categoryId: 'other_income',
          amount: 5000,
          note: '',
          date: DateTime(2026, 10, 13, 12, 2),
          sender: 'VM-DEMOCC',
          acctKey: 'DEMOCC:2222',
          pending: true,
        ),
      ]);
      await tester.pumpWidget(
        app(
          p,
          await settings(),
          Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showReviewSheet(context),
                  child: const Text('open review'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Looks like a transfer'), findsOneWidget);

      await tester.ensureVisible(find.text('Pair'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();
      expect(p.pendingTransactions, isEmpty);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect({for (final t in p.pendingTransactions) t.id}, {'q-out', 'q-in'});
      expect(row(p, 'q-out').categoryId, 'other_expense');
      expect(row(p, 'q-out').pairId, isNull);
    });

    testWidgets('edit sheet Unpair then Undo restores the same pair', (
      tester,
    ) async {
      tall(tester);
      final p = await withRows([outLeg(), inLeg()]);
      await pumpMiddle(
        tester,
        p,
        await settings(),
        (ctx) => showAddTransactionSheet(ctx, existing: row(p, 'leg-out')),
      );
      await tester.tap(find.text('Unpair'));
      await tester.pumpAndSettle();
      expect(row(p, 'leg-out').pairId, isNull);
      expect(find.text('Middle page'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(row(p, 'leg-out').pairId, 'pair_t');
      expect(row(p, 'leg-in').pairId, 'pair_t');
      expect(row(p, 'leg-out').userCategorized, isFalse);
    });
  });

  group('bulk category Undo on one transfer leg', () {
    testWidgets('Transactions: Undo keeps the pair', (tester) async {
      final p = await withRows([outLeg(), inLeg()]);
      await tester.pumpWidget(
        app(p, await settings(), const Scaffold(body: TransactionsScreen())),
      );
      await tester.pump(const Duration(milliseconds: 700));

      await tester.longPress(find.textContaining('billdebit'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Set category'));
      await tester.pumpAndSettle();
      final food = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Food & Dining'),
      );
      await tester.ensureVisible(food);
      await tester.pumpAndSettle();
      await tester.tap(food);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();
      expect(row(p, 'leg-out').categoryId, 'food');
      expect(row(p, 'leg-in').pairId, isNull);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(row(p, 'leg-out').pairId, 'pair_t');
      expect(row(p, 'leg-in').pairId, 'pair_t');
      expect(row(p, 'leg-out').categoryId, kTransferOutCategoryId);
    });

    testWidgets('Cockpit Results: Undo keeps the pair', (tester) async {
      tester.view.physicalSize = const Size(392, 872);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await withRows([outLeg(), inLeg()]);
      await tester.pumpWidget(
        app(
          p,
          await settings(),
          const ClassifiersScreen(initialTab: kCockpitTabTransactions),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      await tester.tap(find.text('billdebit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Food & Dining').last);
      await tester.pumpAndSettle();
      expect(row(p, 'leg-out').categoryId, 'food');
      expect(row(p, 'leg-in').pairId, isNull);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(row(p, 'leg-out').pairId, 'pair_t');
      expect(row(p, 'leg-in').pairId, 'pair_t');
    });
  });

  group('edit sheet closing', () {
    Tx plain() => Tx(
      id: 'tea',
      type: TxType.expense,
      categoryId: 'food',
      amount: 120,
      note: 'Tea corner',
      date: DateTime(2026, 9, 10, 9),
    );

    testWidgets('back during a save leaves the page under the sheet', (
      tester,
    ) async {
      tall(tester);
      final p = await withRows([plain()]);
      await pumpMiddle(
        tester,
        p,
        await settings(),
        (ctx) => showAddTransactionSheet(ctx, existing: row(p, 'tea')),
      );
      expect(find.text('Edit transaction'), findsOneWidget);
      final nav = rootNav(tester);
      // Back in the same turn as the tap, while the save awaits.
      button(tester, 'Save changes').onPressed!();
      unawaited(nav.maybePop());
      await tester.pumpAndSettle();
      expect(find.text('Edit transaction'), findsNothing);
      expect(find.text('Middle page'), findsOneWidget);
    });

    testWidgets('a delete whose sheet already closed keeps the page and '
        'still offers Undo', (tester) async {
      tall(tester);
      final p = await withRows([plain()]);
      await pumpMiddle(
        tester,
        p,
        await settings(),
        (ctx) => showAddTransactionSheet(ctx, existing: row(p, 'tea')),
      );
      final nav = rootNav(tester);
      button(tester, 'Delete transaction').onPressed!();
      // The sheet goes before the delete finishes.
      nav.pop();
      await tester.pumpAndSettle();
      expect(p.transactions, isEmpty);
      expect(find.text('Middle page'), findsOneWidget);
      expect(find.textContaining('Deleted'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(p.transactions.single.id, 'tea');
    });

    testWidgets('a second Unpair tap does nothing', (tester) async {
      tall(tester);
      final p = await withRows([outLeg(), inLeg()]);
      await pumpMiddle(
        tester,
        p,
        await settings(),
        (ctx) => showAddTransactionSheet(ctx, existing: row(p, 'leg-out')),
      );
      final unpair = button(tester, 'Unpair');
      unpair.onPressed!();
      unpair.onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('Middle page'), findsOneWidget);
      expect(find.text('Unpaired'), findsOneWidget);
    });

    testWidgets('Unpair never shows "other leg missing" while closing', (
      tester,
    ) async {
      tall(tester);
      final p = await withRows([outLeg(), inLeg()]);
      await pumpMiddle(
        tester,
        p,
        await settings(),
        (ctx) => showAddTransactionSheet(ctx, existing: row(p, 'leg-out')),
      );
      expect(find.text('Paired transfer'), findsOneWidget);
      await tester.tap(find.text('Unpair'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.text('other leg missing'), findsNothing);
      }
      await tester.pumpAndSettle();
    });

    testWidgets('the add account dialog dismissed mid-save keeps the page', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await pumpMiddle(
        tester,
        p,
        await settings(),
        (ctx) => showAddAccountDialog(ctx),
      );
      await tester.enterText(find.byType(TextField).first, 'Demo Bank');
      await tester.pump();
      final nav = rootNav(tester);
      button(tester, 'Create').onPressed!();
      // A barrier tap in the same turn: the dialog goes first.
      nav.pop();
      await tester.pumpAndSettle();
      expect(find.text('Middle page'), findsOneWidget);
      expect(p.accounts.map((a) => a.name), contains('Demo Bank'));
    });
  });

  testWidgets('a deleted account drops its Transactions filter', (
    tester,
  ) async {
    final p = await withRows([
      Tx(
        id: 'on-bank',
        type: TxType.expense,
        categoryId: 'food',
        amount: 300,
        note: 'bank lunch',
        date: DateTime(2026, 9, 12, 13),
      ),
      Tx(
        id: 'cash',
        type: TxType.expense,
        categoryId: 'food',
        amount: 80,
        note: 'cash snack',
        date: DateTime(2026, 9, 11, 16),
      ),
    ]);
    final bank = await p.addAccount(name: 'Demo Bank', type: AccountType.bank);
    await p.assignAccount('on-bank', bank);
    final s = await settings();
    Widget screen(TxFilterRequest? req, int token) => app(
      p,
      s,
      Scaffold(
        body: TransactionsScreen(request: req, filterToken: token),
      ),
    );
    await tester.pumpWidget(screen(null, 0));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpWidget(screen(TxFilterRequest(accountId: bank), 1));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.textContaining('bank lunch'), findsOneWidget);
    expect(find.textContaining('cash snack'), findsNothing);

    await p.deleteAccount(bank);
    await tester.pumpAndSettle();
    expect(find.textContaining('bank lunch'), findsOneWidget);
    expect(find.textContaining('cash snack'), findsOneWidget);
    expect(find.textContaining('Account ·'), findsNothing);
  });

  testWidgets('bulk Link as refund Undo puts the refund back in review', (
    tester,
  ) async {
    final p = await withRows([
      Tx(
        id: 'buy',
        type: TxType.expense,
        categoryId: 'shopping',
        amount: 900,
        note: 'Gadget Hub',
        date: DateTime(2026, 9, 25, 18, 30),
      ),
      Tx(
        id: 'back',
        type: TxType.income,
        categoryId: 'other_income',
        amount: 900,
        note: 'money back',
        date: DateTime(2026, 10, 2, 10),
      ),
    ]);
    await p.restoreRefundReviewId('back');
    expect(p.refundReviewIds, contains('back'));
    await tester.pumpWidget(
      app(p, await settings(), const Scaffold(body: TransactionsScreen())),
    );
    await tester.pump(const Duration(milliseconds: 700));

    await tester.longPress(find.textContaining('Gadget Hub'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.textContaining('money back'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bulk-more-link-refund')));
    await tester.pumpAndSettle();
    expect(row(p, 'back').refundOf, 'buy');
    expect(p.refundReviewIds, isNot(contains('back')));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row(p, 'back').refundOf, isNull);
    expect(p.refundReviewIds, contains('back'));
  });

  testWidgets('Saved and confirmed Undo also takes back the subscription '
      'mark', (tester) async {
    tall(tester);
    final now = DateTime.now();
    final p = await withRows([
      Tx(
        id: 'sub',
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 499,
        note: 'Streamly',
        sender: 'VM-DEMOBK',
        date: DateTime(now.year, now.month, now.day - 3, 9),
        pending: true,
      ),
    ]);
    await tester.pumpWidget(
      app(
        p,
        await settings(),
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showAddTransactionSheet(context, existing: row(p, 'sub')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, 'Subscription');
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save and confirm');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(row(p, 'sub').pending, isFalse);
    expect(p.subscriptionPins, isNotEmpty);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row(p, 'sub').pending, isTrue);
    expect(p.subscriptionPins, isEmpty);
  });

  group('group names', () {
    Future<FinanceProvider> openGroupDialog(WidgetTester tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addGroup(label: 'Leisure', color: kNoCategoryColor);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showGroupDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return p;
    }

    const error = 'A group with this name already exists';

    testWidgets('a name another group has shows an error and blocks Create', (
      tester,
    ) async {
      final p = await openGroupDialog(tester);
      final before = p.groups.length;
      await tester.enterText(find.byType(TextField), ' leisure ');
      await tester.pump();
      expect(find.text(error), findsOneWidget);
      expect(button(tester, 'Create').onPressed, isNull);
      await tester.tap(find.text('Create'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(p.groups.length, before);
    });

    testWidgets('creating a unique group never flashes the error', (
      tester,
    ) async {
      final p = await openGroupDialog(tester);
      await tester.enterText(find.byType(TextField), 'Garden');
      await tester.pump();
      await tester.tap(find.text('Create'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.text(error), findsNothing);
      }
      await tester.pumpAndSettle();
      expect(p.groups.where((g) => g.label == 'Garden'), hasLength(1));
    });
  });

  group('amounts with paise', () {
    Future<void> openWith(
      WidgetTester tester,
      FinanceProvider p,
      Future<void> Function(BuildContext context) onOpen,
    ) async {
      await tester.pumpWidget(
        app(
          p,
          await settings(),
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => onOpen(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the budget editor keeps a limit of 2500.5', (tester) async {
      tall(tester);
      final p = FinanceProvider();
      await p.load();
      await p.addBudget(
        name: 'Eating out',
        limit: 2500.5,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      await openWith(
        tester,
        p,
        (context) => showBudgetDialog(context, existing: p.budgets.single),
      );
      expect(find.widgetWithText(TextField, '2500.5'), findsOneWidget);
      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(p.budgets.single.limit, 2500.5);
    });

    testWidgets('the reminder editor keeps an amount of 799.5', (tester) async {
      tall(tester);
      final p = FinanceProvider();
      await p.load();
      await p.addReminder(
        name: 'Gym',
        dayOfMonth: 5,
        expectedAmount: 799.5,
        categoryId: 'other_expense',
      );
      await openWith(
        tester,
        p,
        (context) => showReminderEditor(context, existing: p.reminders.single),
      );
      expect(find.widgetWithText(TextField, '799.5'), findsOneWidget);
      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(p.reminders.single.expectedAmount, 799.5);
    });
  });
}
