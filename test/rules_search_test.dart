import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  const food = ClassifierRule(id: 'r1', pattern: 'swiggy', categoryId: 'food');
  const multi = ClassifierRule(
    id: 'r2',
    pattern: 'chai corner | biryani hub',
    categoryId: 'food',
  );
  const spam = ClassifierRule(
    id: 'r3',
    pattern: 'win a prize',
    categoryId: kSpamCategoryId,
  );

  test('empty query matches everything', () {
    expect(ruleMatchesQuery(food, ''), isTrue);
    expect(ruleMatchesQuery(spam, ''), isTrue);
  });

  test('matches any OR-condition, not just the headline one', () {
    expect(ruleMatchesQuery(multi, 'biryani'), isTrue);
    expect(ruleMatchesQuery(multi, 'chai'), isTrue);
    expect(ruleMatchesQuery(multi, 'dosa'), isFalse);
  });

  test('matches the target category label, case-insensitively', () {
    // Queries arrive lowercased from the tab; labels are matched lowercase.
    expect(ruleMatchesQuery(food, 'dining'), isTrue);
    expect(ruleMatchesQuery(food, 'salary'), isFalse);
  });

  test('spam rules match "spam" and never hit categoryById', () {
    expect(ruleMatchesQuery(spam, 'spam'), isTrue);
    expect(ruleMatchesQuery(spam, 'prize'), isTrue);
    // 'spam' is not a real category id — the label must be the literal,
    // not the Other-income fallback categoryById would return.
    expect(ruleMatchesQuery(spam, 'other'), isFalse);
  });

  test('matches the Paid to and the tags a rule sets', () {
    const extras = ClassifierRule(
      id: 'r4',
      pattern: 'quillfern',
      categoryId: 'food',
      payee: 'Maple Teas',
      tags: ['Office', 'Goa trip'],
    );
    expect(ruleMatchesQuery(extras, 'maple'), isTrue);
    expect(ruleMatchesQuery(extras, 'office'), isTrue);
    expect(ruleMatchesQuery(extras, 'goa t'), isTrue);
    expect(ruleMatchesQuery(extras, 'reimbursable'), isFalse);
    // A rule that sets neither is found by its words and category only.
    expect(ruleMatchesQuery(food, 'maple'), isFalse);
  });

  test('what a rule also sets, in words', () {
    expect(ruleExtrasLabel('', const []), 'Nothing');
    expect(ruleExtrasLabel('Maple Teas', const []), 'Paid to');
    expect(ruleExtrasLabel('', const ['Office']), '1 tag');
    expect(ruleExtrasLabel('', const ['Office', 'Tea']), '2 tags');
    expect(ruleExtrasLabel('Maple Teas', const ['Office']), 'Paid to, 1 tag');
    expect(
      ruleExtrasLabel('Maple Teas', const ['Office', 'Tea', 'Team']),
      'Paid to, 3 tags',
    );
  });
}
