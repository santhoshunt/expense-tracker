import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

ClassifierRule rule(String pattern) =>
    ClassifierRule(id: 'r', pattern: pattern, categoryId: 'food');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('word-boundary matching', () {
    test('does not fire inside a word: "RD Ac" vs "Card Account"', () {
      final r = rule('RD Ac');
      expect(
        r.matches(
          'Dear Customer, Payment of INR 51,624.49 has been received on '
          'your ICICI Bank Credit Card Account 4xxx3010 on 31-JUL-26.',
        ),
        isFalse,
      );
      expect(
        r.matches(
          'ICICI Bank Acc XX879 debited Rs. 5,000.00 on 01-Aug-26 InfoTo '
          'RD Ac no 1.Avl Bal Rs. 8,668.22.',
        ),
        isTrue,
      );
    });

    test('still matches at text edges and around punctuation/digits', () {
      expect(rule('swiggy').matches('paid to SWIGGY'), isTrue);
      expect(rule('swiggy').matches('SWIGGY.in order'), isTrue);
      expect(rule('swiggy').matches('to swiggy8 wallet'), isTrue);
      expect(rule('swiggy').matches('theswiggystore'), isFalse);
      // Pattern edges that aren't letters skip the boundary check.
      expect(
        rule('kiwicashback@axisbank').matches('via kiwicashback@axisbank!'),
        isTrue,
      );
      expect(rule('  chai kings  ').matches('at CHAI KINGS today'), isTrue);
    });
  });

  group('OR-conditions ("|" separated alternatives)', () {
    test('matches when any alternative matches, with mixed spacing', () {
      final r = rule('chai | food|biryani');
      expect(r.patterns, ['chai', 'food', 'biryani']);
      expect(r.matches('paid at CHAI point'), isTrue);
      expect(r.matches('Swiggy food order'), isTrue);
      expect(r.matches('Ambur BIRYANI, UPI Ref 123'), isTrue);
      expect(r.matches('paid to SWIGGY'), isFalse);
    });

    test('boundary rules apply per alternative, not to the joined string', () {
      final r = rule('chai | kings');
      expect(r.matches('theCHAIshop'), isFalse); // inside a word
      expect(r.matches('CHAI KINGS today'), isTrue);
    });

    test('empty segments are ignored', () {
      expect(rule('chai |').patterns, ['chai']);
      expect(rule('chai |').matches('chai time'), isTrue);
      expect(rule('|').patterns, isEmpty);
      expect(rule('|').matches('anything'), isFalse);
      // Single pattern without '|' behaves exactly as before.
      expect(rule('swiggy').patterns, ['swiggy']);
    });
  });

  group('manual category wins over rules', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    ParsedTxn parsed(String body, {TxType type = TxType.income}) => ParsedTxn(
      type: type,
      amount: 51624.49,
      merchant: 'ICICI',
      date: DateTime(2026, 7, 31, 3, 12),
      ref: 'R1',
      categoryId: type == TxType.income ? 'other_income' : 'other_expense',
      sender: 'AX-ICICIT-S',
      rawBody: body,
    );

    test('re-apply skips rows the user classified by hand', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        parsed('Payment received on your account. Thank you kindly.'),
      ]);
      await p.confirmTransaction(p.pendingTransactions.single.id);

      // The user moves it to Card payment by hand (the review flow).
      final tx = p.transactions.single;
      await p.updateTransaction(
        tx.copyWith(categoryId: 'card_payment', type: TxType.income),
      );
      expect(p.transactions.single.userCategorized, isTrue);

      // An income rule that matches the body would previously stomp this.
      await p.addRule('thank you', 'investment');
      expect(p.transactions.single.categoryId, 'card_payment');

      // The lock survives persistence.
      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.transactions.single.userCategorized, isTrue);
    });

    test('rows the user never touched are still re-classified', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        parsed('Payment received on your account. Thank you kindly.'),
      ]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      await p.addRule('thank you', 'investment');
      expect(p.transactions.single.categoryId, 'investment');
    });

    test('bulk edit also locks the category', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([parsed('Some unmatched body text.')]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      await p.setCategoryForMany({p.transactions.single.id}, 'gift');
      expect(p.transactions.single.userCategorized, isTrue);
      await p.addRule('unmatched body', 'investment');
      expect(p.transactions.single.categoryId, 'gift');
    });

    test('editing amount or note alone does not lock the category', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([parsed('Some body.')]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      final tx = p.transactions.single;
      await p.updateTransaction(tx.copyWith(note: 'my note'));
      expect(p.transactions.single.userCategorized, isFalse);
    });

    test(
      'a wrong-direction rule no longer shadows a later correct rule',
      () async {
        final p = FinanceProvider();
        await p.load();
        // Mis-targeted user rule: swiggy → salary (income) sits ABOVE the
        // seeded swiggy → food (expense). It used to be returned as "the"
        // match, fail the type check, and block the food rule silently.
        await p.addRule('swiggy', 'salary');
        await p.addImported([
          parsed('Paid Rs.450 to SWIGGY order.', type: TxType.expense),
        ]);
        expect(p.pendingTransactions.single.categoryId, 'food');
      },
    );
  });
}
