import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/merchant_stats.dart';
import 'package:expense_tracker/services/recurring_detector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  var seq = 0;
  Tx sms(String merchant, {double amount = 100, DateTime? date}) => Tx(
    id: 't${seq++}',
    type: TxType.expense,
    categoryId: 'food',
    amount: amount,
    note: '',
    smsBody: 'Rs.$amount debited from a/c XX1234 to $merchant on 01-07-26.',
    date: date ?? DateTime(2026, 7, 2),
    source: TxSource.sms,
    sender: 'VM-HDFCBK',
  );

  test('identity is the direction-less half of the recurring key', () {
    final t = sms('FD NO 12345');
    expect(merchantIdentityOf(t), 'fd no 12345');
    expect(recurringKeyOf(t), 'expense|fd no 12345');
  });

  test('alias wins over the derived label in labels and top merchants', () {
    String? alias(String id) => id == 'fd no 12345' ? 'HDFC FD' : null;
    final t = sms('FD NO 12345');
    expect(merchantDisplayLabel(t), 'Fd No 12345');
    expect(merchantDisplayLabel(t, alias: alias), 'HDFC FD');

    final top = topMerchants(
      [t, sms('SWIGGY', amount: 50)],
      month: DateTime(2026, 7),
      alias: alias,
    );
    expect(top.first.label, 'HDFC FD');
    expect(top.last.label, 'Swiggy');
  });

  test('provider stores, clears and persists aliases', () async {
    final p = FinanceProvider();
    await p.load();
    await p.setMerchantAlias('fd no 12345', '  HDFC FD ');
    expect(p.merchantAlias('fd no 12345'), 'HDFC FD');
    expect(p.merchantAliasFor(sms('FD NO 12345')), 'HDFC FD');

    final p2 = FinanceProvider();
    await p2.load();
    expect(p2.merchantAlias('fd no 12345'), 'HDFC FD', reason: 'persisted');

    // Blank clears; a second clear is a quiet no-op.
    await p2.setMerchantAlias('fd no 12345', '');
    await p2.setMerchantAlias('fd no 12345', null);
    expect(p2.merchantAlias('fd no 12345'), isNull);
    final p3 = FinanceProvider();
    await p3.load();
    expect(p3.merchantAliases, isEmpty);
  });

  test(
    'backup carries aliases; replace overwrites, merge keeps existing',
    () async {
      final src = FinanceProvider();
      await src.load();
      await src.setMerchantAlias('fd no 12345', 'HDFC FD');
      await src.setMerchantAlias('swiggy', 'Swiggy (food)');
      final data = src.exportData();
      expect(data['version'], greaterThanOrEqualTo(12));
      expect(data['merchantAliases'], {
        'fd no 12345': 'HDFC FD',
        'swiggy': 'Swiggy (food)',
      });

      SharedPreferences.setMockInitialValues({});
      final dst = FinanceProvider();
      await dst.load();
      await dst.setMerchantAlias('swiggy', 'Local name');
      await dst.importData(data, replace: false);
      expect(
        dst.merchantAlias('swiggy'),
        'Local name',
        reason: 'existing wins',
      );
      expect(dst.merchantAlias('fd no 12345'), 'HDFC FD', reason: 'new added');

      await dst.importData(data, replace: true);
      expect(dst.merchantAlias('swiggy'), 'Swiggy (food)');

      // A pre-v12 backup leaves the device's aliases alone.
      final old = Map<String, dynamic>.from(data)..remove('merchantAliases');
      await dst.importData(old, replace: true);
      expect(dst.merchantAlias('swiggy'), 'Swiggy (food)');
    },
  );

  test('clearAll keeps aliases unless config is included', () async {
    final p = FinanceProvider();
    await p.load();
    await p.setMerchantAlias('swiggy', 'Swiggy');
    await p.clearAll();
    expect(p.merchantAlias('swiggy'), 'Swiggy');
    await p.clearAll(includeConfig: true);
    expect(p.merchantAliases, isEmpty);
  });
}
