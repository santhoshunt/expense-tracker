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
    pattern: 'chai kings | biryani hub',
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
}
