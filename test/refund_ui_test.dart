import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

/// v1.42.0 refund rows and the edit sheet: the purchase and refund tiles,
/// a save that confirms a row in review, and Make rule from the SMS text.
/// Invented merchants, accounts and alerts only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<void> pump(WidgetTester tester, FinanceProvider p, Widget home) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: MaterialApp(home: Scaffold(body: home)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Tx purchase(String id, double amount, String note) => Tx(
    id: id,
    type: TxType.expense,
    categoryId: 'shopping',
    amount: amount,
    note: note,
    date: DateTime(2026, 9, 25, 18, 30),
  );

  Tx refund(String id, double amount, String of, DateTime date) => Tx(
    id: id,
    type: TxType.income,
    categoryId: 'other_income',
    amount: amount,
    note: '',
    smsBody: 'Refund of Rs $amount credited to a/c XX4321. -Demo Bank',
    source: TxSource.sms,
    sender: 'VM-DEMOBK',
    date: date,
    refundOf: of,
  );

  testWidgets('a purchase names its refund, and the refund its purchase', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      purchase('full', 1200, 'Gadget Hub'),
      purchase('part', 1500, 'Shoe Lane'),
      refund('r-full', 1200, 'full', DateTime(2026, 10, 4, 11)),
      refund('r-part', 500, 'part', DateTime(2026, 10, 6, 9)),
    ]);
    Tx row(String id) => p.transactions.firstWhere((t) => t.id == id);
    expect(p.isLinkedRefund(row('r-full')), isTrue);
    expect(p.isLinkedRefund(row('r-part')), isTrue);

    await pump(
      tester,
      p,
      ListView(
        children: [
          for (final id in ['full', 'part', 'r-full', 'r-part'])
            TransactionTile(tx: row(id)),
        ],
      ),
    );

    // The purchase keeps its amount; the line under it says what came
    // back and when.
    expect(find.text('Refunded in full · 4 Oct'), findsOneWidget);
    expect(find.text('${fmtMoney(500)} refunded · 6 Oct'), findsOneWidget);
    expect(find.text('−${fmtMoney(1200)}'), findsOneWidget);
    expect(find.text('−${fmtMoney(1500)}'), findsOneWidget);

    // The refund leads with what it refunds.
    expect(find.text('Refund · Gadget Hub'), findsOneWidget);
    expect(find.text('Refund · Shoe Lane'), findsOneWidget);
    expect(find.text('For 25 Sep purchase'), findsNWidgets(2));
  });

  testWidgets('with no merchant on either side, the refund names the '
      "purchase's category", (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      purchase('buy', 700, ''),
      Tx(
        id: 'back',
        type: TxType.income,
        categoryId: 'other_income',
        amount: 700,
        note: '',
        date: DateTime(2026, 10, 2, 10),
        refundOf: 'buy',
      ),
    ]);
    Tx row(String id) => p.transactions.firstWhere((t) => t.id == id);
    expect(p.isLinkedRefund(row('back')), isTrue);
    expect(p.merchantLabelFor(row('buy')), isNull);
    expect(p.merchantLabelFor(row('back')), isNull);
    await pump(tester, p, TransactionTile(tx: row('back')));
    expect(
      find.text('Refund · ${categoryById('shopping').label}'),
      findsOneWidget,
    );
    expect(find.text(categoryById('other_income').label), findsNothing);
  });

  testWidgets('a linked refund amount is plain, not income green', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      purchase('buy', 900, 'Gadget Hub'),
      refund('back', 900, 'buy', DateTime(2026, 10, 2, 10)),
      // The same refund with no link: still income.
      refund(
        'loose',
        300,
        'gone',
        DateTime(2026, 10, 3, 10),
      ).copyWith(clearRefundOf: true),
    ]);
    Tx row(String id) => p.transactions.firstWhere((t) => t.id == id);
    await pump(
      tester,
      p,
      ListView(
        children: [
          TransactionTile(tx: row('back')),
          TransactionTile(tx: row('loose')),
        ],
      ),
    );

    final context = tester.element(find.byType(ListView));
    final scheme = Theme.of(context).colorScheme;
    final green = AppColors.of(context).green;
    Color? colorOf(String text) =>
        tester.widget<Text>(find.text(text)).style?.color;
    expect(colorOf('+${fmtMoney(900)}'), scheme.onSurface);
    expect(colorOf('+${fmtMoney(900)}'), isNot(green));
    expect(colorOf('+${fmtMoney(300)}'), green);
  });

  Widget opener(FinanceProvider p, String id) => Builder(
    builder: (context) => TextButton(
      onPressed: () => showAddTransactionSheet(
        context,
        existing: [
          ...p.transactions,
          ...p.pendingTransactions,
        ].firstWhere((t) => t.id == id),
      ),
      child: const Text('open'),
    ),
  );

  Tx inReview() => Tx(
    id: 'rev',
    type: TxType.expense,
    categoryId: 'food',
    amount: 250,
    note: '',
    smsBody: 'Rs 250.00 debited from a/c XX4321 at TASTY CORNER on 05-10',
    source: TxSource.sms,
    sender: 'VM-DEMOBK',
    date: DateTime(2026, 10, 5, 13),
    pending: true,
  );

  testWidgets('saving a row in review confirms it, and Undo puts it back', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([inReview()]);
    await pump(tester, p, opener(p, 'rev'));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(p.pendingTransactions, isEmpty);
    expect(p.transactions.single.id, 'rev');
    expect(find.text('Saved and confirmed'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.transactions, isEmpty);
    expect(p.pendingTransactions.single.id, 'rev');
  });

  testWidgets('Unlink keeps the sheet open and offers Undo', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      purchase('buy', 900, 'Gadget Hub'),
      refund('back', 900, 'buy', DateTime(2026, 10, 2, 10)),
    ]);
    await pump(tester, p, opener(p, 'back'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final unlink = find.widgetWithText(TextButton, 'Unlink');
    await tester.ensureVisible(unlink);
    await tester.pumpAndSettle();
    await tester.tap(unlink);
    await tester.pumpAndSettle();

    expect(p.transactions.firstWhere((t) => t.id == 'back').refundOf, isNull);
    // Still the edit sheet, now offering the link again.
    expect(find.text('Edit transaction'), findsOneWidget);
    expect(find.text('Link to a purchase'), findsOneWidget);
    expect(find.text('Unlinked'), findsOneWidget);

    // The toast sits under the open sheet; it outlasts closing it.
    Navigator.of(tester.element(find.text('Edit transaction'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.transactions.firstWhere((t) => t.id == 'back').refundOf, 'buy');
  });

  testWidgets('a row in review that names a purchase shows no broken link', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      purchase('buy', 900, 'Gadget Hub'),
      refund(
        'rev',
        900,
        'buy',
        DateTime(2026, 10, 2, 10),
      ).copyWith(pending: true),
      // Control: a confirmed one whose purchase is gone.
      refund('lost', 300, 'gone', DateTime(2026, 10, 3, 10)),
    ]);
    expect(p.refundLinkBroken(p.pendingTransactions.single), isFalse);
    await pump(
      tester,
      p,
      Column(children: [opener(p, 'rev'), opener(p, 'lost')]),
    );
    await tester.tap(find.text('open').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit transaction'), findsOneWidget);
    expect(find.text('Not linked: the purchase changed'), findsNothing);
    expect(find.text('Unlink'), findsNothing);

    Navigator.of(tester.element(find.text('Edit transaction'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('open').last);
    await tester.pumpAndSettle();
    expect(find.text('Not linked: the purchase changed'), findsOneWidget);
  });

  testWidgets('Undo of Link in the sheet puts a past refund back up for '
      'review', (tester) async {
    SharedPreferences.setMockInitialValues({
      'refunds_linked_v1': true,
      'refund_suggest_ids_v1': ['back'],
    });
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      purchase('buy', 900, 'Gadget Hub'),
      refund(
        'back',
        900,
        'buy',
        DateTime(2026, 10, 2, 10),
      ).copyWith(clearRefundOf: true),
    ]);
    expect(p.refundReviewIds, {'back'});
    await pump(tester, p, opener(p, 'back'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final link = find.text('Link to a purchase');
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Gadget Hub · '));
    await tester.pumpAndSettle();

    expect(
      p.isLinkedRefund(p.transactions.firstWhere((t) => t.id == 'back')),
      isTrue,
    );
    expect(p.refundReviewIds, isEmpty);
    expect(find.text('Linked as a refund'), findsOneWidget);

    Navigator.of(tester.element(find.text('Edit transaction'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.transactions.firstWhere((t) => t.id == 'back').refundOf, isNull);
    expect(p.refundReviewIds, {'back'});
  });

  testWidgets('saving a confirmed row says nothing about confirming', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([inReview().copyWith(pending: false)]);
    await pump(tester, p, opener(p, 'rev'));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Saved and confirmed'), findsNothing);
    expect(p.transactions.single.pending, isFalse);
  });

  testWidgets('Make rule shows for a selection of 3 or more characters and '
      'opens New rule with it', (tester) async {
    final p = FinanceProvider();
    await p.load();
    final row = inReview();
    await p.restoreTransactions([row]);
    await pump(tester, p, opener(p, 'rev'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final field = find.descendant(
      of: find.widgetWithText(TextFormField, 'Original SMS'),
      matching: find.byType(EditableText),
    );
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(field);

    Future<void> select(String part) async {
      final start = row.smsBody.indexOf(part);
      state.hideToolbar();
      state.userUpdateTextEditingValue(
        TextEditingValue(
          text: row.smsBody,
          selection: TextSelection(
            baseOffset: start,
            extentOffset: start + part.length,
          ),
        ),
        SelectionChangedCause.longPress,
      );
      await tester.pump();
      state.showToolbar();
      await tester.pumpAndSettle();
    }

    // Two characters besides the spaces: the usual buttons only.
    await select(' at ');
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Make rule'), findsNothing);

    await select('TASTY CORNER');
    expect(find.text('Make rule'), findsOneWidget);
    await tester.tap(find.text('Make rule'));
    await tester.pumpAndSettle();

    // The rule dialog opens over the sheet with the selection as its text.
    expect(find.text('New rule'), findsOneWidget);
    expect(find.text('TASTY CORNER'), findsOneWidget);
    expect(find.text('Edit transaction'), findsOneWidget);
  });
}
