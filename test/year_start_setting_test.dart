import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/settings_provider.dart';

/// The persisted "Year starts in" preference.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to January', () async {
    final s = SettingsProvider();
    await s.load();
    expect(s.yearStart, YearStart.january);
    expect(s.yearStart.month, 1);
  });

  test('setYearStart notifies and persists', () async {
    final s = SettingsProvider();
    await s.load();
    var notified = 0;
    s.addListener(() => notified++);

    await s.setYearStart(YearStart.april);
    expect(s.yearStart, YearStart.april);
    expect(notified, 1);

    // Picking the current value again is a no-op.
    await s.setYearStart(YearStart.april);
    expect(notified, 1);

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.yearStart, YearStart.april);
    expect(reloaded.yearStart.month, 4);
  });

  test('rides the backup map', () async {
    final s = SettingsProvider();
    await s.load();
    await s.setYearStart(YearStart.april);
    final backup = s.toBackupMap();
    expect(backup['yearStart'], 'april');

    SharedPreferences.setMockInitialValues({});
    final fresh = SettingsProvider();
    await fresh.load();
    expect(fresh.yearStart, YearStart.january);
    await fresh.applyBackupMap(backup);
    expect(fresh.yearStart, YearStart.april);

    // The restore is persisted, not only held in memory.
    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.yearStart, YearStart.april);
  });

  test('an unknown or mistyped backup value keeps the current one', () async {
    final s = SettingsProvider();
    await s.load();
    await s.setYearStart(YearStart.april);

    await s.applyBackupMap({'yearStart': 'july'});
    expect(s.yearStart, YearStart.april);
    await s.applyBackupMap({'yearStart': 4});
    expect(s.yearStart, YearStart.april);
    await s.applyBackupMap({});
    expect(s.yearStart, YearStart.april);
  });

  test('a garbage stored value falls back to January', () async {
    SharedPreferences.setMockInitialValues({'year_start_v1': 'not_a_month'});
    final s = SettingsProvider();
    await s.load();
    expect(s.yearStart, YearStart.january);
  });
}
