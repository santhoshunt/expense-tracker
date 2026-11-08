import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/services/launch_actions.dart';

/// The native names the widgets send (QuickActions.kt) reach their
/// actions. Kept apart from launch_actions_test.dart, which pumps Home.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('the v2.1.0 widgets name their actions', () {
    expect(LaunchActions.fromName('open_ahead'), LaunchAction.openAhead);
    expect(LaunchActions.fromName('open_search'), LaunchAction.openSearch);
  });

  test('the v2.2.0 widgets name their actions', () {
    // Trip budget with nothing on Overview's Budgets: Cockpit's Budgets tab.
    expect(
      LaunchActions.fromName('open_budgets_tab'),
      LaunchAction.openBudgetsTab,
    );
    // Cash in hand: Count cash over Accounts.
    expect(
      LaunchActions.fromName('open_count_cash'),
      LaunchAction.openCountCash,
    );
    // Subscriptions: Cockpit's Subscriptions tab, as the price-rise alert.
    expect(
      LaunchActions.fromName('open_subscriptions'),
      LaunchAction.openSubscriptions,
    );
    // Who owes you: the people page, once.
    expect(LaunchActions.fromName('open_people'), LaunchAction.openPeople);
  });

  group('the Card cycle widget', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    setUp(LaunchActions.instance.resetForTest);
    tearDown(() {
      messenger.setMockMethodCallHandler(LaunchActions.channel, null);
      LaunchActions.instance.resetForTest();
    });

    Future<void> launch(String name) async {
      messenger.setMockMethodCallHandler(
        LaunchActions.channel,
        (call) async => call.method == 'takeLaunchAction' ? name : null,
      );
      await LaunchActions.instance.init();
    }

    test('names its card after open_card:', () async {
      await launch('open_card:c1');
      expect(LaunchActions.instance.pending.value, LaunchAction.openCard);
      expect(LaunchActions.instance.takeCardId(), 'c1');
      expect(LaunchActions.instance.takeCardId(), isNull, reason: 'once');
    });

    test('with no card id is ignored', () async {
      await launch('open_card:');
      expect(LaunchActions.instance.pending.value, isNull);
    });
  });
}
