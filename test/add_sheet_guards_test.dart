import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/card_rewards.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/widgets/dialog_expander.dart';

/// Regression tests for the add/edit sheet's two safety guards from the
/// audit fix round: the double-submit latch (duplicate ledger rows) and the
/// unsaved-changes pop guard (typed input lost to a stray dismissal).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Widget app(FinanceProvider provider) => ChangeNotifierProvider.value(
    value: provider,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showAddTransactionSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Future<void> openSheet(WidgetTester tester, FinanceProvider p) async {
    await tester.pumpWidget(app(p));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add transaction'), findsOneWidget);
  }

  testWidgets('double-tapping Add creates exactly one transaction', (
    tester,
  ) async {
    final p = await loaded();
    await openSheet(tester, p);

    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '250');
    await tester.pump();

    // Two taps with no settle in between — the second lands while the first
    // save's awaits are still in flight. The button sits below the fold on
    // the 600px test surface, so scroll it into view first.
    final add = find.widgetWithText(FilledButton, 'Add');
    await tester.ensureVisible(add);
    await tester.pump();
    await tester.tap(add);
    await tester.pump();
    await tester.tap(add, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(p.transactions.length, 1);
    expect(p.transactions.single.amount, 250);
  });

  testWidgets('a dirty sheet asks before discarding; Discard closes it', (
    tester,
  ) async {
    final p = await loaded();
    await openSheet(tester, p);

    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '99');
    await tester.pump();

    // System back (what the barrier tap and swipe-down also route through).
    final NavigatorState nav = tester.state(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();

    expect(find.text('Discard changes?'), findsOneWidget);
    expect(find.text('Add transaction'), findsOneWidget); // still open

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Add transaction'), findsOneWidget);

    await nav.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Add transaction'), findsNothing);
    expect(p.transactions, isEmpty);
  });

  testWidgets('a clean sheet closes without asking', (tester) async {
    final p = await loaded();
    await openSheet(tester, p);

    final NavigatorState nav = tester.state(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();

    expect(find.text('Discard changes?'), findsNothing);
    expect(find.text('Add transaction'), findsNothing);
  });

  /// An imported row on a card with rewards, with a tag and a sender: every
  /// group of the edit sheet shows for it.
  Future<(FinanceProvider, Tx)> cardRow() async {
    final p = await loaded();
    final card = await p.addAccount(
      name: 'Demo Card',
      type: AccountType.creditCard,
    );
    await p.setCardRewards(
      card,
      const CardRewards(
        groups: [
          RewardGroup(id: 'gF', name: 'Food', categoryIds: {'food'}, rate: 5),
        ],
        baseRate: 1,
      ),
    );
    await p.restoreTransactions([
      Tx(
        id: 'r1',
        type: TxType.expense,
        categoryId: 'food',
        amount: 640,
        note: '',
        payee: 'Sample Bistro',
        date: DateTime(2026, 9, 12, 13),
        source: TxSource.sms,
        smsBody: 'Rs 640 spent on card XX0000 at SAMPLE BISTRO',
        sender: 'AD-DEMOBK',
        tags: const ['Weekend'],
      ),
    ]);
    await p.assignAccount('r1', card);
    return (p, p.transactions.single);
  }

  /// Pumps an 'open' button for the sheet on [existing] (null: a new
  /// entry), at [textScale], and taps it.
  Future<void> openOn(
    WidgetTester tester,
    FinanceProvider p,
    Tx? existing, {
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: p,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showAddTransactionSheet(context, existing: existing),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Opens each group the sheet shows, in turn, running [after] once each
  /// is open.
  Future<void> openEachFold(
    WidgetTester tester, {
    void Function()? after,
  }) async {
    for (final name in ['split', 'rewards', 'extras', 'sms']) {
      final fold = find.byKey(ValueKey('fold-$name'));
      if (fold.evaluate().isEmpty) continue;
      // The header row, near its top: at 2x text with the keyboard up a
      // header can be taller than the visible scroll area, so its centre
      // sits under the pinned footer.
      final header = find
          .descendant(of: fold, matching: find.byType(InkWell))
          .first;
      await tester.ensureVisible(header);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getTopLeft(header) + const Offset(24, 16));
      await tester.pumpAndSettle();
      expect(tester.widget<DialogExpander>(fold).open, isTrue, reason: name);
      after?.call();
    }
  }

  testWidgets('opening a group changes nothing, so back closes without '
      'asking', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final (p, row) = await cardRow();

    for (final existing in [null, row]) {
      await openOn(tester, p, existing);
      await openEachFold(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    }
  });

  testWidgets('the sheet fits a small phone at 2x text with the keyboard up', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568) * 3;
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280 * 3);
    addTearDown(tester.view.reset);
    final (p, row) = await cardRow();
    final save = find.byKey(const ValueKey('editor-save'));
    void fits() {
      expect(tester.takeException(), isNull);
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(568 - 280));
      expect(save.hitTestable(), findsOneWidget);
    }

    // A new entry, a group split new entry, and the imported card row.
    for (final (existing, split) in [
      (null, false),
      (null, true),
      (row, false),
    ]) {
      await openOn(tester, p, existing, textScale: 2);
      fits();
      if (split) {
        final fold = find.byKey(const ValueKey('fold-split'));
        await tester.ensureVisible(fold);
        await tester.pumpAndSettle();
        await tester.tap(fold);
        await tester.pumpAndSettle();
        final groupSplit = find.text('Group split payment');
        await tester.ensureVisible(groupSplit);
        await tester.pumpAndSettle();
        await tester.tap(groupSplit);
        await tester.pumpAndSettle();
        fits();
        // Closed again, so the loop below opens it first.
        await tester.ensureVisible(find.text('Split'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Split'));
        await tester.pumpAndSettle();
      }
      await openEachFold(tester, after: fits);
      // The button takes the tap: errors on the new entries, a save on
      // the edit, and the sheet goes either way after back.
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Back drops the keyboard first on a phone; then the sheet goes,
      // through Discard on the split entry.
      tester.view.resetViewInsets();
      if (find.byType(BottomSheet).evaluate().isNotEmpty) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        if (find.text('Discard').evaluate().isNotEmpty) {
          await tester.tap(find.text('Discard'));
          await tester.pumpAndSettle();
        }
      }
      expect(find.byType(BottomSheet), findsNothing);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280 * 3);
    }
  });

  testWidgets('a Count in fits a small phone at 2x text', (tester) async {
    tester.view.physicalSize = const Size(320, 568) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final (p, row) = await cardRow();
    await p.setCountInForMany({row.id}, DateTime(2026, 10, 1, 9, 30));
    await openOn(tester, p, p.transactions.single, textScale: 2);
    // One group opens at a time: the extras group, where Count in sits.
    final header = find
        .descendant(
          of: find.byKey(const ValueKey('fold-extras')),
          matching: find.byType(InkWell),
        )
        .first;
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getTopLeft(header) + const Offset(24, 16));
    await tester.pumpAndSettle();
    final line = find.textContaining('Counts in ');
    await tester.ensureVisible(line);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(line, findsOneWidget);
    // The title keeps a readable width beside the clear button.
    expect(
      tester.getSize(find.text('Count in another date')).width,
      greaterThan(100),
    );
    expect(find.byTooltip('Count on its own date'), findsOneWidget);
  });

  // The sheet's own drag popped the route directly, past the guard.
  testWidgets('dragging the handle down asks on a dirty sheet and closes a '
      'clean one', (tester) async {
    final p = await loaded();
    await openSheet(tester, p);
    final handle = find.byKey(const ValueKey('editor-sheet-handle'));

    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '99');
    await tester.pump();
    await tester.drag(handle, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    expect(find.text('Add transaction'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '');
    await tester.pump();
    await tester.drag(handle, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    expect(find.text('Add transaction'), findsNothing);
  });
}
