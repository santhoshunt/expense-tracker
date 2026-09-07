import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/providers/finance_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Account cycle fields', () {
    test('JSON round-trip carries statementDay and dueDay', () {
      final a = Account(
        id: 'a1',
        name: 'HDFC Card',
        type: AccountType.creditCard,
        keys: {'HDFC:1234'},
        statementDay: 28,
        dueDay: 15,
      );
      final restored = Account.fromJson(a.toJson());
      expect(restored.statementDay, 28);
      expect(restored.dueDay, 15);
    });

    test('absent keys read back as null (older backups)', () {
      final a = Account.fromJson({
        'id': 'a1',
        'name': 'Card',
        'type': 'creditCard',
        'keys': ['HDFC:1234'],
      });
      expect(a.statementDay, isNull);
      expect(a.dueDay, isNull);
    });

    test('copyWith sets and clears independently', () {
      final a = Account(
        id: 'a1',
        name: 'Card',
        type: AccountType.creditCard,
        keys: const {},
        statementDay: 28,
        dueDay: 15,
      );
      final cleared = a.copyWith(clearDueDay: true);
      expect(cleared.statementDay, 28);
      expect(cleared.dueDay, isNull);
      final changed = a.copyWith(dueDay: 20);
      expect(changed.dueDay, 20);
      expect(changed.statementDay, 28);
    });
  });

  group('FinanceProvider.setCardCycle', () {
    test('sets, persists, and clears', () async {
      final p = FinanceProvider();
      await p.load();
      final id = await p.addAccount(
        name: 'HDFC Card',
        type: AccountType.creditCard,
      );

      await p.setCardCycle(id, statementDay: 28, dueDay: 15);
      expect(p.accountById(id)!.statementDay, 28);
      expect(p.accountById(id)!.dueDay, 15);

      // Survives a reload.
      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.accountById(id)!.dueDay, 15);

      // Null clears both.
      await p.setCardCycle(id);
      expect(p.accountById(id)!.statementDay, isNull);
      expect(p.accountById(id)!.dueDay, isNull);
    });

    test('rejects out-of-range days wholesale', () async {
      final p = FinanceProvider();
      await p.load();
      final id = await p.addAccount(name: 'Card', type: AccountType.creditCard);
      await p.setCardCycle(id, statementDay: 28, dueDay: 15);

      await p.setCardCycle(id, statementDay: 0, dueDay: 10);
      await p.setCardCycle(id, statementDay: 5, dueDay: 32);
      expect(p.accountById(id)!.statementDay, 28, reason: 'unchanged');
      expect(p.accountById(id)!.dueDay, 15, reason: 'unchanged');
    });

    test('unknown account id is a no-op', () async {
      final p = FinanceProvider();
      await p.load();
      await p.setCardCycle('nope', dueDay: 10); // must not throw
    });
  });

  group('billPaidMonth', () {
    test('JSON round-trip; absent key reads back null', () {
      final a = Account(
        id: 'a1',
        name: 'Card',
        type: AccountType.creditCard,
        keys: const {},
        billPaidMonth: '2026-09',
      );
      expect(Account.fromJson(a.toJson()).billPaidMonth, '2026-09');
      final old = Account.fromJson({
        'id': 'a1',
        'name': 'Card',
        'type': 'creditCard',
        'keys': <String>[],
      });
      expect(old.billPaidMonth, isNull);
    });

    test('copyWith sets and clears independently of the cycle days', () {
      final a = Account(
        id: 'a1',
        name: 'Card',
        type: AccountType.creditCard,
        keys: const {},
        dueDay: 10,
        billPaidMonth: '2026-09',
      );
      final cleared = a.copyWith(clearBillPaidMonth: true);
      expect(cleared.billPaidMonth, isNull);
      expect(cleared.dueDay, 10);
      expect(a.copyWith(dueDay: 12).billPaidMonth, '2026-09');
    });

    test('mark / clear / raw set persist across reload', () async {
      final p = FinanceProvider();
      await p.load();
      final id = await p.addAccount(name: 'Card', type: AccountType.creditCard);

      await p.markCardBillPaid(id, DateTime(2026, 9, 10));
      expect(p.accountById(id)!.billPaidMonth, '2026-09');

      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.accountById(id)!.billPaidMonth, '2026-09');

      await p.clearCardBillPaid(id);
      expect(p.accountById(id)!.billPaidMonth, isNull);

      // The raw primitive restores an arbitrary previous value (Undo path).
      await p.setCardBillPaidMonth(id, '2026-08');
      expect(p.accountById(id)!.billPaidMonth, '2026-08');
      await p.setCardBillPaidMonth('nope', '2026-08'); // no-op, must not throw
    });
  });
}
