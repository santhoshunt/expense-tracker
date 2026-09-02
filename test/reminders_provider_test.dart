import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/utils/dates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  test('add / update / mark paid / delete persist across reload', () async {
    final p = FinanceProvider();
    await p.load();
    final id = await p.addReminder(
      name: '  Money to home ',
      dayOfMonth: 40,
      expectedAmount: 5000,
      categoryId: 'other_expense',
    );
    var r = p.reminders.single;
    expect(r.id, id);
    expect(r.name, 'Money to home');
    expect(r.dayOfMonth, 31, reason: 'clamped');
    expect(r.expectedAmount, 5000);

    await p.updateReminder(
      r.copyWith(dayOfMonth: 5, clearExpectedAmount: true),
    );
    r = p.reminders.single;
    expect(r.dayOfMonth, 5);
    expect(r.expectedAmount, isNull);

    final due = DateTime(2026, 9, 5);
    await p.markReminderPaid(id, due);
    expect(p.reminders.single.lastPaidMonth, monthKey(due));

    final p2 = FinanceProvider();
    await p2.load();
    expect(p2.reminders.single.lastPaidMonth, '2026-09', reason: 'persisted');

    await p2.clearReminderPaid(id);
    expect(p2.reminders.single.lastPaidMonth, isNull);

    await p2.deleteReminder(id);
    expect(p2.reminders, isEmpty);
    await p2.restoreReminder(r);
    expect(p2.reminders.single.id, id);
    final p3 = FinanceProvider();
    await p3.load();
    expect(p3.reminders, hasLength(1));
  });

  test('income or unknown categories fall back to Other expense', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addReminder(name: 'a', dayOfMonth: 1, categoryId: 'salary');
    await p.addReminder(name: 'b', dayOfMonth: 1, categoryId: 'no_such_cat');
    await p.addReminder(
      name: 'c',
      dayOfMonth: 1,
      categoryId: kSavingsTransferCategoryId,
    );
    expect(p.reminders[0].categoryId, 'other_expense');
    expect(p.reminders[1].categoryId, 'other_expense');
    expect(
      p.reminders[2].categoryId,
      kSavingsTransferCategoryId,
      reason: 'expense-typed transfers are money out',
    );
  });

  test('deleting a category remaps its reminders', () async {
    final p = FinanceProvider();
    await p.load();
    final catId = await p.addCategory(
      label: 'Tuition',
      type: TxType.expense,
      icon: Icons.school,
      color: Colors.blue,
    );
    await p.addReminder(name: 'Fees', dayOfMonth: 10, categoryId: catId);
    await p.deleteCategory(catId, moveTo: 'education');
    expect(p.reminders.single.categoryId, 'education');
    await p.deleteCategory('education');
    expect(p.reminders.single.categoryId, 'other_expense');
  });

  test(
    'backup v13 carries reminders; replace overwrites, merge adds new',
    () async {
      final src = FinanceProvider();
      await src.load();
      final id = await src.addReminder(
        name: 'EB bill',
        dayOfMonth: 12,
        expectedAmount: 1200,
        categoryId: 'utilities',
      );
      final data = src.exportData();
      expect(data['version'], greaterThanOrEqualTo(13));
      expect((data['reminders'] as List).single['id'], id);

      SharedPreferences.setMockInitialValues({});
      final dst = FinanceProvider();
      await dst.load();
      final local = await dst.addReminder(
        name: 'Rent',
        dayOfMonth: 1,
        categoryId: 'housing',
      );
      await dst.importData(data, replace: false);
      expect(dst.reminders.map((r) => r.id), containsAll([local, id]));

      await dst.importData(data, replace: true);
      expect(dst.reminders.map((r) => r.id), [id]);

      // A pre-v13 backup leaves the device's reminders alone.
      final old = Map<String, dynamic>.from(data)..remove('reminders');
      await dst.importData(old, replace: true);
      expect(dst.reminders.map((r) => r.id), [id]);
    },
  );

  test('clearAll keeps reminders unless config is included', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addReminder(name: 'x', dayOfMonth: 1, categoryId: 'other_expense');
    await p.clearAll();
    expect(p.reminders, hasLength(1));
    await p.clearAll(includeConfig: true);
    expect(p.reminders, isEmpty);
  });
}
