import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/services/launch_actions.dart';

/// The native names the widgets send (QuickActions.kt) reach their
/// actions. Kept apart from launch_actions_test.dart, which pumps Home.
void main() {
  test('the v1.38.1 widgets name their actions', () {
    // Quick actions: Expense, Income and Import SMS.
    expect(LaunchActions.fromName('add_expense'), LaunchAction.addExpense);
    expect(LaunchActions.fromName('add_income'), LaunchAction.addIncome);
    expect(LaunchActions.fromName('import_sms'), LaunchAction.importSms);
    // Recent opens the Transactions tab; Budgets list the Budgets section.
    expect(
      LaunchActions.fromName('open_transactions'),
      LaunchAction.openTransactions,
    );
    expect(LaunchActions.fromName('open_budgets'), LaunchAction.openBudgets);
  });

  test('the v1.41.0 widgets name their actions', () {
    // Big bills opens its sheet; This week the digest on the current week,
    // not the Monday note's action, which needs a week handed over.
    expect(LaunchActions.fromName('open_big_bills'), LaunchAction.openBigBills);
    expect(
      LaunchActions.fromName('open_weekly_digest'),
      LaunchAction.openThisWeek,
    );
  });

  test('the v1.43.0 This week review count opens the review', () {
    expect(LaunchActions.fromName('open_review'), LaunchAction.openReview);
  });
}
