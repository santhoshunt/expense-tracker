import 'package:flutter_test/flutter_test.dart';
import 'package:expense_tracker/services/budget.dart';

void main() {
  int? level(
    double spent,
    double cap,
    int last, {
    bool en80 = true,
    bool en90 = true,
    bool enOver = true,
  }) => budgetLevelToNotify(
    spent: spent,
    cap: cap,
    lastNotified: last,
    en80: en80,
    en90: en90,
    enOver: enOver,
  );

  test('no cap set → never notifies', () {
    expect(level(5000, 0, 0), isNull);
  });

  test('below 80% → nothing', () {
    expect(level(790, 1000, 0), isNull);
  });

  test('crossing 80/90/100 returns that level once', () {
    expect(level(800, 1000, 0), 80);
    expect(level(900, 1000, 80), 90);
    expect(level(1000, 1000, 90), 100);
    expect(level(1200, 1000, 100), isNull); // already over-notified
  });

  test('jumping straight past thresholds fires the highest crossed', () {
    // Nothing sent yet, spend lands at 130% → over.
    expect(level(1300, 1000, 0), 100);
    // 85% from zero → 80.
    expect(level(850, 1000, 0), 80);
  });

  test('disabled thresholds are skipped, next enabled one still fires', () {
    // 80 disabled: at 85% nothing; at 95% the 90 alert fires.
    expect(level(850, 1000, 0, en80: false), isNull);
    expect(level(950, 1000, 0, en80: false), 90);
    // All but over disabled: only fires at 100%.
    expect(level(950, 1000, 0, en80: false, en90: false), isNull);
    expect(level(1000, 1000, 0, en80: false, en90: false), 100);
  });

  test('alert text distinguishes warning from overshoot', () {
    final warn = budgetAlertText(
      level: 80,
      spent: 800,
      cap: 1000,
      money: (v) => v.toStringAsFixed(0),
    );
    expect(warn.title, contains('80%'));
    final over = budgetAlertText(
      level: 100,
      spent: 1100,
      cap: 1000,
      money: (v) => v.toStringAsFixed(0),
    );
    expect(over.title.toLowerCase(), contains('over'));
  });

  test('named alert text carries the custom budget name', () {
    final warn = budgetAlertText(
      level: 90,
      spent: 900,
      cap: 1000,
      money: (v) => v.toStringAsFixed(0),
      name: 'Personal spending',
    );
    expect(warn.title, contains('90%'));
    expect(warn.title, contains('Personal spending'));
    final over = budgetAlertText(
      level: 100,
      spent: 1100,
      cap: 1000,
      money: (v) => v.toStringAsFixed(0),
      name: 'Personal spending',
    );
    expect(over.title.toLowerCase(), contains('over'));
    expect(over.body, contains('Personal spending'));
  });

  test('custom budget alert keys are scoped per budget and month', () {
    final key = customBudgetAlertKey('bud_1', DateTime(2026, 8, 4));
    expect(key, 'budget_alert_fired_bud_1_2026-08');
    expect(customBudgetAlertKey('bud_2', DateTime(2026, 8)), isNot(key));
    expect(customBudgetAlertKey('bud_1', DateTime(2026, 9)), isNot(key));
  });
}
