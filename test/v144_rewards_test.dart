import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/card_rewards.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/card_rewards_page.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/card_rewards.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';

import 'accounts_test_utils.dart';

/// Card cycles, the rewards estimate, the rewards page, its Settings entry
/// and the card tile's estimate lines.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Account card({int? statementDay, CardRewards? rewards}) => Account(
    id: 'card1',
    name: 'Test card',
    type: AccountType.creditCard,
    keys: const {'BANKA:1111'},
    statementDay: statementDay,
    rewards: rewards,
  );

  group('cardCycleOf', () {
    test(
      'mid-cycle runs from the day after the last statement to the next',
      () {
        final c = cardCycleOf(
          card(statementDay: 15),
          DateTime(2026, 10, 20, 9),
        );
        expect(c.start, DateTime(2026, 10, 16));
        expect(c.end, DateTime(2026, 11, 15));
      },
    );

    test('the statement day itself closes the cycle', () {
      final c = cardCycleOf(card(statementDay: 15), DateTime(2026, 10, 15));
      expect(c.start, DateTime(2026, 9, 16));
      expect(c.end, DateTime(2026, 10, 15));
    });

    test('back steps whole cycles', () {
      final a = card(statementDay: 15);
      final now = DateTime(2026, 10, 10);
      final one = cardCycleOf(a, now, back: 1);
      expect(one.start, DateTime(2026, 8, 16));
      expect(one.end, DateTime(2026, 9, 15));
      final two = cardCycleOf(a, now, back: 2);
      expect(two.start, DateTime(2026, 7, 16));
      expect(two.end, DateTime(2026, 8, 15));
    });

    test('a day past the month end uses the last day', () {
      final a = card(statementDay: 31);
      final feb = cardCycleOf(a, DateTime(2027, 2, 10));
      expect(feb.start, DateTime(2027, 2, 1));
      expect(feb.end, DateTime(2027, 2, 28));
      final mar = cardCycleOf(a, DateTime(2027, 3, 1));
      expect(mar.start, DateTime(2027, 3, 1));
      expect(mar.end, DateTime(2027, 3, 31));
    });

    test('cycles cross the year', () {
      final a = card(statementDay: 5);
      final now = cardCycleOf(a, DateTime(2027, 1, 3));
      expect(now.start, DateTime(2026, 12, 6));
      expect(now.end, DateTime(2027, 1, 5));
      final last = cardCycleOf(a, DateTime(2027, 1, 3), back: 1);
      expect(last.start, DateTime(2026, 11, 6));
      expect(last.end, DateTime(2026, 12, 5));
      final dec = cardCycleOf(a, DateTime(2026, 12, 20));
      expect(dec.end, DateTime(2027, 1, 5));
    });

    test('no statement day: the calendar month', () {
      final a = card();
      final now = cardCycleOf(a, DateTime(2027, 1, 20));
      expect(now.start, DateTime(2027, 1, 1));
      expect(now.end, DateTime(2027, 1, 31));
      final last = cardCycleOf(a, DateTime(2027, 1, 20), back: 1);
      expect(last.start, DateTime(2026, 12, 1));
      expect(last.end, DateTime(2026, 12, 31));
    });

    test('inCardCycle holds the whole end day', () {
      final c = cardCycleOf(card(statementDay: 15), DateTime(2026, 10, 20));
      expect(inCardCycle(c, DateTime(2026, 10, 16)), isTrue);
      expect(inCardCycle(c, DateTime(2026, 10, 15, 23, 59)), isFalse);
      expect(inCardCycle(c, DateTime(2026, 11, 15, 23, 59)), isTrue);
      expect(inCardCycle(c, DateTime(2026, 11, 16)), isFalse);
    });
  });

  group('estimateRewards', () {
    const rules = CardRewards(
      groups: [
        RewardGroup(categoryIds: {'food', 'shopping'}, rate: 10, cap: 500),
        RewardGroup(categoryIds: {'shopping', 'transport'}, rate: 5),
      ],
      baseRate: 1,
    );

    test('groups, the base rate and a cap', () {
      final e = estimateRewards(rules, const [
        (categoryId: 'food', amount: 3000),
        (categoryId: 'transport', amount: 1000),
        (categoryId: 'bills', amount: 2000),
      ]);
      // 300 + 50 + 20.
      expect(e.earned, 370);
      expect(e.capped, isFalse);
      expect(e.rupees, isNull);
    });

    test('the first group holding a category wins', () {
      final e = estimateRewards(rules, const [
        (categoryId: 'shopping', amount: 1000),
      ]);
      expect(e.earned, 100);
    });

    test('a group stops at its cap and says so', () {
      final e = estimateRewards(rules, const [
        (categoryId: 'food', amount: 3000),
        (categoryId: 'shopping', amount: 4000),
        (categoryId: 'bills', amount: 1000),
      ]);
      expect(e.earned, 510);
      expect(e.capped, isTrue);
    });

    test('rounds down, and skips amounts at or below 0', () {
      final e = estimateRewards(rules, const [
        (categoryId: 'bills', amount: 199),
        (categoryId: 'bills', amount: 0),
        (categoryId: 'bills', amount: -500),
      ]);
      expect(e.earned, 1);
    });

    test('earnings that add up to a whole figure are not lost to float '
        'error', () {
      // Ten 0.1s sum to 0.9999999999999999 in doubles.
      final e = estimateRewards(const CardRewards(baseRate: 1), [
        for (var i = 0; i < 10; i++) (categoryId: 'bills', amount: 10.0),
      ]);
      expect(e.earned, 1);
      // The same inside a group, against its cap.
      final capped = estimateRewards(
        const CardRewards(
          groups: [
            RewardGroup(categoryIds: {'bills'}, rate: 1, cap: 1),
          ],
        ),
        [for (var i = 0; i < 10; i++) (categoryId: 'bills', amount: 10.0)],
      );
      expect(capped.earned, 1);
      expect(capped.capped, isTrue);
      // A real shortfall still rounds down.
      final short = estimateRewards(const CardRewards(baseRate: 1), const [
        (categoryId: 'bills', amount: 99.6),
      ]);
      expect(short.earned, 0);
    });

    test('points: points per ₹100 and their ₹ value', () {
      const points = CardRewards(
        unit: RewardUnit.points,
        baseRate: 4,
        pointValue: 0.25,
      );
      final e = estimateRewards(points, const [
        (categoryId: 'bills', amount: 10000),
      ]);
      expect(e.earned, 400);
      expect(e.rupees, 100);
      final noValue = estimateRewards(
        const CardRewards(unit: RewardUnit.points, baseRate: 4),
        const [(categoryId: 'bills', amount: 10000)],
      );
      expect(noValue.rupees, isNull);
    });
  });

  group('CardRewards JSON', () {
    test('round trips', () {
      const r = CardRewards(
        unit: RewardUnit.points,
        groups: [
          RewardGroup(categoryIds: {'food'}, rate: 10, cap: 500),
        ],
        baseRate: 1.5,
        pointValue: 0.25,
      );
      final back = CardRewards.tryFromJson(jsonDecode(jsonEncode(r.toJson())))!;
      expect(back.unit, RewardUnit.points);
      expect(back.groups.single.categoryIds, {'food'});
      expect(back.groups.single.rate, 10);
      expect(back.groups.single.cap, 500);
      expect(back.baseRate, 1.5);
      expect(back.pointValue, 0.25);
    });

    test('reads bad values as defaults and drops bad groups', () {
      final r = CardRewards.tryFromJson({
        'unit': 'stars',
        'groups': [
          {
            'categoryIds': ['food'],
            'rate': -1,
          },
          'junk',
          {
            'categoryIds': ['shopping', 7],
            'rate': 5,
            'cap': 0,
          },
        ],
        'baseRate': 'x',
        'pointValue': -2,
      })!;
      expect(r.unit, RewardUnit.cashback);
      expect(r.groups.single.categoryIds, {'shopping'});
      expect(r.groups.single.cap, isNull);
      expect(r.baseRate, 0);
      expect(r.pointValue, isNull);
      expect(CardRewards.tryFromJson('nope'), isNull);
    });
  });

  group('labels', () {
    test('rates, summary and the card tile lines', () {
      expect(rewardRateLabel(RewardUnit.cashback, 1.5), '1.5%');
      expect(rewardRateLabel(RewardUnit.points, 1), '1 point per ₹100');
      expect(rewardRateLabel(RewardUnit.points, 4), '4 points per ₹100');
      expect(
        cardRewardsSummary(const CardRewards(baseRate: 1)),
        '1% on everything else',
      );
      expect(
        cardRewardsSummary(
          const CardRewards(
            groups: [
              RewardGroup(categoryIds: {'food'}, rate: 10),
            ],
            baseRate: 1,
          ),
        ),
        '1 group · 1% on everything else',
      );

      final cashback = card(
        statementDay: 15,
        rewards: const CardRewards(baseRate: 1),
      );
      final cycle = cardCycleOf(cashback, DateTime(2026, 10, 20));
      const est = RewardEstimate(earned: 1324, capped: true);
      expect(
        rewardEstimateLine(cashback, est),
        'Cashback this cycle ≈ ₹1,324 · capped',
      );
      expect(
        rewardCycleLine(
          cashback,
          cycle,
          const RewardEstimate(earned: 290, capped: false),
        ),
        'Cycle 16 Oct to 15 Nov · last cycle ₹290',
      );
      final points = card(
        rewards: const CardRewards(unit: RewardUnit.points, pointValue: 0.25),
      );
      expect(
        rewardEstimateLine(
          points,
          const RewardEstimate(earned: 1250, capped: false, rupees: 312.5),
        ),
        'Points this month ≈ 1,250 · ≈ ₹313',
      );
      expect(
        rewardCycleLine(
          points,
          cardCycleOf(points, DateTime(2026, 10, 20)),
          const RewardEstimate(earned: 40, capped: false),
        ),
        'Last month 40 points',
      );
    });

    test('reward groups offer spending and Paid for Others, not To sort or '
        'other transfers', () {
      expect(isRewardCategory(categoryById('food')), isTrue);
      expect(isRewardCategory(categoryById(kPaidForOthersCategoryId)), isTrue);
      expect(isRewardCategory(categoryById(kTransferOutCategoryId)), isFalse);
      expect(isRewardCategory(categoryById(kToSortExpenseId)), isFalse);
      expect(isRewardCategory(categoryById('salary')), isFalse);
    });
  });

  // A statement day ten days ahead, so rows a few whole days back sit in
  // the current cycle whatever today is.
  final now = DateTime.now();
  final stmtDay = now.add(const Duration(days: 10)).day;
  const tenPercent = CardRewards(
    groups: [
      RewardGroup(categoryIds: {'food', 'shopping'}, rate: 10, cap: 500),
    ],
    baseRate: 1,
  );

  Tx row(
    String id,
    String categoryId,
    double amount,
    DateTime date, {
    TxType type = TxType.expense,
    bool cashbackOff = false,
  }) => Tx(
    id: id,
    type: type,
    categoryId: categoryId,
    amount: amount,
    note: '',
    date: date,
    acctKey: 'BANKA:1111',
    cashbackOff: cashbackOff,
  );

  /// The card with this cycle's rows and one row last cycle.
  Future<FinanceProvider> seeded({CardRewards? rewards = tenPercent}) async {
    final a = card(statementDay: stmtDay, rewards: rewards);
    final cycle = cardCycleOf(a, now);
    final day = DateTime(now.year, now.month, now.day - 1);
    final lastCycle = cycle.start.subtract(const Duration(days: 2));
    SharedPreferences.setMockInitialValues({
      'accounts_v1': jsonEncode([a.toJson()]),
      'transactions_v1': jsonEncode([
        for (final t in [
          row('t1', 'food', 3000, day),
          row('t2', 'shopping', 4000, day),
          row('t3', 'transport', 1000, day),
          row('t4', kPaidForOthersCategoryId, 2000, day),
          row('t5', kTransferOutCategoryId, 5000, day),
          row('t6', 'transport', 800, day, cashbackOff: true),
          row('t7', 'salary', 9000, day, type: TxType.income),
          row('t8', 'food', 1000, lastCycle),
        ])
          t.toJson(),
      ]),
    });
    final finance = FinanceProvider();
    await finance.load();
    return finance;
  }

  test('cardRewardsFor: spends and Paid for Others earn; transfers, untick'
      'ed rows and income do not', () async {
    final finance = await seeded();
    final a = finance.accountById('card1')!;
    final e = finance.cardRewardsFor(a)!;
    // Group 300 + 400 capped at 500, transport 10, Paid for Others 20.
    expect(e.earned, 530);
    expect(e.capped, isTrue);
    expect(finance.cardRewardsFor(a, back: 1)!.earned, 100);
    await finance.setCardRewards('card1', null);
    expect(finance.cardRewardsFor(finance.accountById('card1')!), isNull);
  });

  testWidgets('the card tile shows the estimate, the cycle and Rewards…', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final finance = await seeded();
    await tester.pumpWidget(accountsApp(finance));
    await tester.pumpAndSettle();

    expect(find.text('Cashback this cycle ≈ ₹530 · capped'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rewards…'));
    await tester.pumpAndSettle();
    expect(find.text('Test card rewards'), findsOneWidget);
    expect(find.text('10%'), findsOneWidget);

    // Without rewards the tile has no estimate.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await finance.setCardRewards('card1', null);
    await tester.pumpAndSettle();
    expect(find.textContaining('Cashback this'), findsNothing);
  });

  testWidgets('the rewards page builds groups with inline errors and saves '
      'each change', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final finance = await seeded(rewards: null);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: finance,
        child: const MaterialApp(home: CardRewardsPage(accountId: 'card1')),
      ),
    );
    await tester.pumpAndSettle();
    CardRewards? saved() => finance.accountById('card1')!.rewards;

    // The unit alone saves nothing: no rate yet.
    await tester.tap(find.text('Points'));
    await tester.pumpAndSettle();
    expect(saved(), isNull);
    expect(find.text('₹ per point (optional)'), findsOneWidget);
    await tester.tap(find.text('Cashback'));
    await tester.pumpAndSettle();
    expect(find.text('₹ per point (optional)'), findsNothing);

    await tester.tap(find.text('Add a group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a rate'), findsOneWidget);
    expect(find.text('Pick at least one category'), findsOneWidget);
    expect(find.text('To sort'), findsNothing);
    expect(find.text('Transfer out'), findsNothing);

    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, '-2');
    await tester.pumpAndSettle();
    expect(find.text("A rate can't be below 0"), findsOneWidget);
    await tester.enterText(fields.first, '10');
    await tester.enterText(fields.last, '0');
    await tester.pumpAndSettle();
    expect(find.text('Enter a cap above 0, or leave it blank'), findsOneWidget);
    await tester.enterText(fields.last, '1,000');
    await tester.tap(find.text('Food & Dining'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    final g = saved()!.groups.single;
    expect(g.categoryIds, {'food'});
    expect(g.rate, 10);
    expect(g.cap, 1000);
    expect(find.text('10%'), findsOneWidget);
    expect(find.text('Food & Dining\nUp to ₹1,000 a cycle'), findsOneWidget);

    // A second group cannot take Food & Dining again.
    await tester.tap(find.text('Add a group'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Food & Dining'),
      ),
      findsNothing,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Everything else: a bad entry errors and keeps the saved rate.
    final base = find.widgetWithText(TextField, 'Everything else');
    await tester.enterText(base, '1.5');
    await tester.pumpAndSettle();
    expect(saved()!.baseRate, 1.5);
    await tester.enterText(base, '-1');
    await tester.pumpAndSettle();
    expect(find.text("A rate can't be below 0"), findsOneWidget);
    expect(saved()!.baseRate, 1.5);
    await tester.enterText(base, '1');
    await tester.pumpAndSettle();

    // Points with a value per point.
    await tester.tap(find.text('Points'));
    await tester.pumpAndSettle();
    expect(saved()!.unit, RewardUnit.points);
    expect(find.text('10 points per ₹100'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, '₹ per point (optional)'),
      '0.25',
    );
    await tester.pumpAndSettle();
    expect(saved()!.pointValue, 0.25);

    // Delete group, then Undo puts it back.
    await tester.tap(find.text('10 points per ₹100'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();
    expect(saved()!.groups, isEmpty);
    expect(saved()!.baseRate, 1);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(saved()!.groups.single.categoryIds, {'food'});
    expect(saved()!.pointValue, 0.25);

    // The only group with no base rate: deleting it clears the rules, and
    // Undo brings back the unit and point value too.
    await tester.enterText(base, '');
    await tester.pumpAndSettle();
    expect(saved()!.baseRate, 0);
    await tester.tap(find.text('10 points per ₹100'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();
    expect(saved(), isNull);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(saved()!.unit, RewardUnit.points);
    expect(saved()!.groups.single.rate, 10);
    expect(saved()!.pointValue, 0.25);
  });

  testWidgets('Settings lists the cards under Card rewards', (tester) async {
    final finance = await seeded(rewards: null);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('0 of 1 card set up'), findsOneWidget);
    await tester.tap(find.text('Card rewards'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Test card'), findsOneWidget);
    expect(find.text('Not set up'), findsOneWidget);

    await finance.setCardRewards('card1', tenPercent);
    await tester.pump();
    expect(find.text('1 group · 1% on everything else'), findsOneWidget);

    await tester.tap(find.text('Test card'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Test card rewards'), findsOneWidget);
  });
}
