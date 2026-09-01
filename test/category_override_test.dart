import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Both registries are module-global; reset between tests.
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  test(
    'cosmetic override keeps the base type/transfer when not specified',
    () async {
      final p = await loaded();
      await p.overrideBuiltinCategory(
        id: 'food',
        label: 'Meals',
        icon: Icons.local_cafe,
        color: Colors.teal,
      );

      final c = categoryById('food');
      expect(c.label, 'Meals');
      expect(c.icon, Icons.local_cafe);
      expect(c.type, TxType.expense); // unchanged when omitted
      expect(c.isTransfer, isFalse);
      // The picker list shows the override in the built-in's slot.
      expect(allCategories.where((c) => c.id == 'food'), hasLength(1));
      expect(p.isBuiltinOverridden('food'), isTrue);
    },
  );

  test('a direction flip re-types existing rows and moves totals', () async {
    final p = await loaded();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'lunch',
      date: DateTime(2026, 8, 1),
    );
    expect(p.expenseInMonth(DateTime(2026, 8)), 500);

    await p.overrideBuiltinCategory(
      id: 'food',
      label: 'Food & Dining',
      icon: Icons.restaurant,
      color: Colors.teal,
      type: TxType.income,
    );

    expect(categoryById('food').type, TxType.income);
    // Row re-typed: the invariant tx.type == category.type holds.
    expect(p.transactions.single.type, TxType.income);
    expect(p.expenseInMonth(DateTime(2026, 8)), 0);
    expect(p.incomeInMonth(DateTime(2026, 8)), 500);

    // Reset restores the definition AND re-types the rows back.
    await p.resetBuiltinCategory('food');
    expect(categoryById('food').type, TxType.expense);
    expect(p.transactions.single.type, TxType.expense);
    expect(p.expenseInMonth(DateTime(2026, 8)), 500);
  });

  test('transfer toggle moves money between Spent and Transfers', () async {
    final p = await loaded();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'savings_out',
      amount: 1000,
      note: 'RD',
      date: DateTime(2026, 8, 1),
    );
    // As a transfer: excluded from expense, counted as savings.
    expect(isTransferCategory('savings_out'), isTrue);
    expect(p.expenseInMonth(DateTime(2026, 8)), 0);

    await p.overrideBuiltinCategory(
      id: 'savings_out',
      label: 'To savings',
      icon: Icons.savings,
      color: Colors.teal,
      isTransfer: false,
    );
    // Un-transferred: plain expense, no double count as savings.
    expect(isTransferCategory('savings_out'), isFalse);
    expect(p.expenseInMonth(DateTime(2026, 8)), 1000);

    await p.resetBuiltinCategory('savings_out');
    expect(isTransferCategory('savings_out'), isTrue);
    expect(p.expenseInMonth(DateTime(2026, 8)), 0);
  });

  test('flipping a grouped built-in to plain income detaches it', () async {
    final p = await loaded();
    final gid = await p.addGroup(label: 'Needs', color: Colors.teal);
    await p.assignCategoryToGroup('food', gid);
    expect(p.groupIdOf('food'), gid);

    await p.overrideBuiltinCategory(
      id: 'food',
      label: 'Food & Dining',
      icon: Icons.restaurant,
      color: Colors.teal,
      type: TxType.income,
    );
    expect(p.groupIdOf('food'), isNull);
  });

  test('the fallback Other categories cannot be flipped', () async {
    final p = await loaded();
    await p.overrideBuiltinCategory(
      id: 'other_expense',
      label: 'Misc',
      icon: Icons.category,
      color: Colors.teal,
      type: TxType.income,
      isTransfer: true,
    );
    final c = categoryById('other_expense');
    expect(c.label, 'Misc'); // cosmetics apply…
    expect(c.type, TxType.expense); // …structure does not
    expect(c.isTransfer, isFalse);
  });

  test('override survives a reload; reset restores the original', () async {
    final p = await loaded();
    await p.overrideBuiltinCategory(
      id: 'savings_out',
      label: 'RD deposit',
      icon: Icons.savings,
      color: Colors.teal,
    );

    setBuiltinOverrides(const {}); // simulate a fresh process
    final p2 = await loaded();
    expect(categoryById('savings_out').label, 'RD deposit');
    // Transfer-ness held, so aggregates are untouched.
    expect(isTransferCategory('savings_out'), isTrue);

    await p2.resetBuiltinCategory('savings_out');
    expect(categoryById('savings_out').label, 'To savings');
    expect(p2.isBuiltinOverridden('savings_out'), isFalse);
  });

  test(
    'overrides ride the backup: v7 export, replace-import restores',
    () async {
      final p = await loaded();
      await p.overrideBuiltinCategory(
        id: 'food',
        label: 'Meals',
        icon: Icons.restaurant,
        color: Colors.teal,
      );
      final data = p.exportData();
      expect(data['version'], greaterThanOrEqualTo(7));

      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
      final p2 = await loaded();
      await p2.importData(data, replace: true);
      expect(categoryById('food').label, 'Meals');
    },
  );

  test(
    'imported overrides carry flips; invented ids and Other flips do not',
    () async {
      final p = await loaded();
      await p.importData({
        'app': 'expense_tracker',
        'version': 9,
        'transactions': const [],
        'builtinOverrides': [
          {
            'id': 'food',
            'label': 'Refunds',
            'type': 'income', // flips are backup-portable now
            'icon': 'cafe',
            'color': 0xFF000000,
          },
          {
            'id': 'other_income',
            'label': 'Misc in',
            'type': 'expense', // fallback ids stay anchored
            'icon': 'cafe',
            'color': 0xFF000000,
          },
          {
            'id': 'not_a_builtin',
            'label': 'Ghost',
            'type': 'expense',
            'icon': 'cafe',
            'color': 0xFF000000,
          },
        ],
      }, replace: true);

      expect(categoryById('food').label, 'Refunds');
      expect(categoryById('food').type, TxType.income);
      expect(categoryById('other_income').label, 'Misc in');
      expect(categoryById('other_income').type, TxType.income);
      expect(allCategories.any((c) => c.id == 'not_a_builtin'), isFalse);
    },
  );

  test('a flipped override round-trips the backup with its rows', () async {
    final p = await loaded();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'lunch',
      date: DateTime(2026, 8, 1),
    );
    await p.overrideBuiltinCategory(
      id: 'food',
      label: 'Refunds',
      icon: Icons.restaurant,
      color: Colors.teal,
      type: TxType.income,
    );
    final data = p.exportData();

    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    final p2 = await loaded();
    await p2.importData(data, replace: true);
    expect(categoryById('food').type, TxType.income);
    expect(p2.transactions.single.type, TxType.income);
  });

  test('merge import of a flip re-types existing LOCAL rows', () async {
    final p = await loaded();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'local lunch',
      date: DateTime(2026, 8, 1),
    );
    await p.importData({
      'app': 'expense_tracker',
      'version': 9,
      'transactions': const [],
      'builtinOverrides': [
        {
          'id': 'food',
          'label': 'Refunds',
          'type': 'income',
          'icon': 'cafe',
          'color': 0xFF000000,
        },
      ],
    }, replace: false);

    expect(categoryById('food').type, TxType.income);
    // The device row existed BEFORE the merge — it must follow the flip.
    expect(p.transactions.single.type, TxType.income);
  });

  test('SMS import re-targets when its category guess was flipped', () async {
    final p = await loaded();
    // User flipped card_bill to income; the parser still emits it for
    // expense-direction card-bill alerts.
    await p.overrideBuiltinCategory(
      id: 'card_bill',
      label: 'Card bill',
      icon: Icons.credit_card,
      color: Colors.teal,
      type: TxType.income,
      isTransfer: false,
    );
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 2500,
        merchant: 'HDFC CARD',
        date: DateTime(2026, 8, 2, 10),
        ref: 'R99',
        categoryId: 'card_bill',
        sender: 'VM-HDFCBK',
        // Neutral body: must not trip any seeded keyword rule, so the
        // parser's category guess (card_bill) is what reaches the check.
        rawBody: 'Rs.2500 debited from A/c XX1234 ref 99',
      ),
    ]);
    // Imports land in the review queue, not the confirmed list.
    final row = p.pendingTransactions.single;
    // The parsed direction is authoritative — the row keeps type expense
    // and falls back to the type-correct Other.
    expect(row.type, TxType.expense);
    expect(row.categoryId, 'other_expense');
  });

  test('merge import keeps the device edit on collision', () async {
    final p = await loaded();
    await p.overrideBuiltinCategory(
      id: 'food',
      label: 'Mine',
      icon: Icons.restaurant,
      color: Colors.teal,
    );
    await p.importData({
      'app': 'expense_tracker',
      'version': 7,
      'transactions': const [],
      'builtinOverrides': [
        {
          'id': 'food',
          'label': 'Theirs',
          'type': 'expense',
          'icon': 'cafe',
          'color': 0xFF000000,
        },
        {
          'id': 'transport',
          'label': 'Commute',
          'type': 'expense',
          'icon': 'car',
          'color': 0xFF000000,
        },
      ],
    }, replace: false);

    expect(categoryById('food').label, 'Mine');
    expect(categoryById('transport').label, 'Commute'); // filled the gap
  });
}
