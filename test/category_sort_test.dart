import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/settings_provider.dart';

/// The persisted "Categories vs usual" sort preference.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('preference persists and rides the backup map', () async {
    final s = SettingsProvider();
    await s.load();
    expect(s.categorySort, CategorySort.biggestChange, reason: 'default');

    await s.setCategorySort(CategorySort.mostUnusual);
    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.categorySort, CategorySort.mostUnusual);

    expect(s.toBackupMap()['categorySort'], 'mostUnusual');
    final fresh = SettingsProvider();
    await fresh.load();
    await fresh.applyBackupMap({'categorySort': 'highestSpend'});
    expect(fresh.categorySort, CategorySort.highestSpend);
  });

  test('a garbage stored value falls back to the default', () async {
    SharedPreferences.setMockInitialValues({'category_sort_v1': 'not_a_sort'});
    final s = SettingsProvider();
    await s.load();
    expect(s.categorySort, CategorySort.biggestChange);

    // A garbage backup value keeps the current one too.
    await s.setCategorySort(CategorySort.highestSpend);
    await s.applyBackupMap({'categorySort': 42});
    expect(s.categorySort, CategorySort.highestSpend);
  });
}
