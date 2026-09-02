import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  ClassifierRule rule(String id, String pattern, String cat) =>
      ClassifierRule(id: id, pattern: pattern, categoryId: cat);

  group('normalizedRulePattern', () {
    test('ignores case, spacing and condition order', () {
      expect(normalizedRulePattern('Amma | family'), 'amma | family');
      expect(normalizedRulePattern(' FAMILY |amma '), 'amma | family');
      expect(normalizedRulePattern('amma||'), 'amma');
    });
  });

  group('directionSiblingOf', () {
    test('finds the opposite-direction twin of the same pattern', () {
      final out = rule('a', 'amma', 'food');
      final inn = rule('b', 'AMMA', 'salary');
      final other = rule('c', 'amma', 'transport'); // same direction
      final spam = rule('d', 'amma', kSpamCategoryId);
      final rules = [other, spam, out, inn];
      expect(directionSiblingOf(out, rules)?.id, 'b');
      // Two expense twins exist for the income rule; the earlier one in
      // list order wins, matching the matcher's own priority.
      expect(directionSiblingOf(inn, rules)?.id, 'c');
      expect(directionSiblingOf(inn, [out, inn])?.id, 'a');
      // Same-direction duplicates and spam rules never pair.
      expect(directionSiblingOf(other, [other, out]), isNull);
      expect(directionSiblingOf(spam, rules), isNull);
      expect(directionSiblingOf(out, [out, spam]), isNull);
    });

    test('pattern must match after normalisation, not loosely', () {
      final out = rule('a', 'amma', 'food');
      final near = rule('b', 'amma pay', 'salary');
      expect(directionSiblingOf(out, [out, near]), isNull);
    });
  });

  test(
    'a rule pair classifies each money direction to its own category',
    () async {
      final p = FinanceProvider();
      await p.load();
      // Same keyword, one expense target and one income target.
      await p.addRule('amma', 'food');
      await p.addRule('amma', 'salary');

      ParsedTxn alert(TxType type, String body) => ParsedTxn(
        type: type,
        amount: 500,
        merchant: 'AMMA',
        date: DateTime(2026, 7, 1, 12),
        ref: type == TxType.expense ? 'R1' : 'R2',
        categoryId: type == TxType.expense ? 'other_expense' : 'other_income',
        sender: 'VM-HDFCBK',
        rawBody: body,
      );
      await p.addImported([
        alert(
          TxType.expense,
          'Rs.500 debited from a/c XX1 to AMMA on 01-07-26',
        ),
        alert(
          TxType.income,
          'Rs.500 credited to a/c XX1 from AMMA on 01-07-26',
        ),
      ]);
      final pending = p.pendingTransactions;
      expect(pending, hasLength(2));
      final sent = pending.singleWhere((t) => t.type == TxType.expense);
      final got = pending.singleWhere((t) => t.type == TxType.income);
      expect(sent.categoryId, 'food');
      expect(got.categoryId, 'salary');
    },
  );
}
