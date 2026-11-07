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
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/widgets/editor_sheet.dart';

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
      final e = estimateRewards(rules, [
        (group: rules.groupFor('food'), amount: 3000),
        (group: rules.groupFor('transport'), amount: 1000),
        (group: rules.groupFor('bills'), amount: 2000),
      ]);
      // 300 + 50 + 20.
      expect(e.earned, 370);
      expect(e.capped, isFalse);
      expect(e.rupees, isNull);
    });

    test('the first group holding a category wins', () {
      final e = estimateRewards(rules, [
        (group: rules.groupFor('shopping'), amount: 1000),
      ]);
      expect(e.earned, 100);
    });

    test('a group stops at its cap and says so', () {
      final e = estimateRewards(rules, [
        (group: rules.groupFor('food'), amount: 3000),
        (group: rules.groupFor('shopping'), amount: 4000),
        (group: rules.groupFor('bills'), amount: 1000),
      ]);
      expect(e.earned, 510);
      expect(e.capped, isTrue);
    });

    test('rounds down, and skips amounts at or below 0', () {
      final e = estimateRewards(rules, [
        (group: rules.groupFor('bills'), amount: 199),
        (group: rules.groupFor('bills'), amount: 0),
        (group: rules.groupFor('bills'), amount: -500),
      ]);
      expect(e.earned, 1);
    });

    test('earnings that add up to a whole figure are not lost to float '
        'error', () {
      // Ten 0.1s sum to 0.9999999999999999 in doubles.
      const flat = CardRewards(baseRate: 1);
      final e = estimateRewards(flat, [
        for (var i = 0; i < 10; i++)
          (group: flat.groupFor('bills'), amount: 10.0),
      ]);
      expect(e.earned, 1);
      // The same inside a group, against its cap.
      const bills = CardRewards(
        groups: [
          RewardGroup(categoryIds: {'bills'}, rate: 1, cap: 1),
        ],
      );
      final capped = estimateRewards(bills, [
        for (var i = 0; i < 10; i++)
          (group: bills.groupFor('bills'), amount: 10.0),
      ]);
      expect(capped.earned, 1);
      expect(capped.capped, isTrue);
      // A real shortfall still rounds down.
      final short = estimateRewards(flat, [
        (group: flat.groupFor('bills'), amount: 99.6),
      ]);
      expect(short.earned, 0);
    });

    test('points: points per ₹100 and their ₹ value', () {
      const points = CardRewards(
        unit: RewardUnit.points,
        baseRate: 4,
        pointValue: 0.25,
      );
      final e = estimateRewards(points, [
        (group: points.groupFor('bills'), amount: 10000),
      ]);
      expect(e.earned, 400);
      expect(e.rupees, 100);
      const unvalued = CardRewards(unit: RewardUnit.points, baseRate: 4);
      final noValue = estimateRewards(unvalued, [
        (group: unvalued.groupFor('bills'), amount: 10000),
      ]);
      expect(noValue.rupees, isNull);
    });

    test('a charge under its group minimum earns nothing, not the base '
        'rate', () {
      const r = CardRewards(
        groups: [
          RewardGroup(id: 'gm', categoryIds: {'food'}, rate: 10, minimum: 100),
        ],
        baseRate: 1,
      );
      final g = r.groupFor('food');
      expect(estimateRewards(r, [(group: g, amount: 99)]).earned, 0);
      expect(estimateRewards(r, [(group: g, amount: 100)]).earned, 10);
    });
  });

  group('resolveRewardGroup', () {
    const a = RewardGroup(
      id: 'gA',
      name: 'Amazon',
      categoryIds: {},
      merchantWords: {'amazon'},
      rate: 5,
    );
    const b = RewardGroup(
      id: 'gB',
      name: 'Shopping',
      categoryIds: {'shopping'},
      rate: 2,
    );
    const r = CardRewards(groups: [a, b], baseRate: 1);

    test('a pick beats a remembered pick, which beats a merchant name, '
        'which beats a category', () {
      final picked = resolveRewardGroup(
        r,
        pick: 'gB',
        remembered: 'base',
        merchant: 'amazon',
        categoryIds: ['shopping'],
      );
      expect(picked.group, same(b));
      expect(picked.reason, RewardReason.picked);
      final remembered = resolveRewardGroup(
        r,
        remembered: 'gB',
        merchant: 'amazon',
        categoryIds: ['food'],
      );
      expect(remembered.group, same(b));
      expect(remembered.reason, RewardReason.remembered);
      final merchant = resolveRewardGroup(
        r,
        merchant: 'amazon',
        categoryIds: ['shopping'],
      );
      expect(merchant.group, same(a));
      expect(merchant.reason, RewardReason.merchant);
      final category = resolveRewardGroup(
        r,
        merchant: 'demo mart',
        categoryIds: ['shopping'],
      );
      expect(category.group, same(b));
      expect(category.reason, RewardReason.category);
      final rest = resolveRewardGroup(r, categoryIds: ['food']);
      expect(rest.group, isNull);
      expect(rest.reason, RewardReason.everythingElse);
    });

    test("a pick 'base' gives Everything else even for amazon", () {
      final m = resolveRewardGroup(
        r,
        pick: kEverythingElseRewardGroupId,
        merchant: 'amazon',
        categoryIds: ['shopping'],
      );
      expect(m.group, isNull);
      expect(m.reason, RewardReason.picked);
    });

    test('a pick naming no group falls through to the next rule', () {
      final m = resolveRewardGroup(
        r,
        pick: 'gone',
        merchant: 'amazon',
        categoryIds: ['shopping'],
      );
      expect(m.group, same(a));
      expect(m.reason, RewardReason.merchant);
    });

    test('merchant words match whole words only', () {
      const ola = CardRewards(
        groups: [
          RewardGroup(
            id: 'gO',
            categoryIds: {},
            merchantWords: {'ola'},
            rate: 5,
          ),
        ],
      );
      final m = resolveRewardGroup(
        ola,
        merchant: 'coca cola',
        categoryIds: ['food'],
      );
      expect(m.reason, RewardReason.everythingElse);
    });

    test('categories are tried in order', () {
      final m = resolveRewardGroup(
        r,
        categoryIds: ['transfer_out', 'shopping'],
      );
      expect(m.group, same(b));
      expect(m.categoryId, 'shopping');
    });
  });

  group('CardRewards JSON', () {
    test('round trips', () {
      const r = CardRewards(
        unit: RewardUnit.points,
        groups: [
          RewardGroup(
            id: 'g1',
            name: 'Dining',
            categoryIds: {'food'},
            merchantWords: {'swiggy', 'zomato'},
            rate: 10,
            cap: 500,
            minimum: 200,
          ),
        ],
        baseRate: 1.5,
        pointValue: 0.25,
      );
      final back = CardRewards.tryFromJson(jsonDecode(jsonEncode(r.toJson())))!;
      expect(back.unit, RewardUnit.points);
      expect(back.groups.single.id, 'g1');
      expect(back.groups.single.name, 'Dining');
      expect(back.groups.single.categoryIds, {'food'});
      expect(back.groups.single.merchantWords, {'swiggy', 'zomato'});
      expect(back.groups.single.rate, 10);
      expect(back.groups.single.cap, 500);
      expect(back.groups.single.minimum, 200);
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
            'merchantWords': ['Amazon.in', 7, '  '],
            'minimum': 0,
          },
        ],
        'baseRate': 'x',
        'pointValue': -2,
      })!;
      expect(r.unit, RewardUnit.cashback);
      expect(r.groups.single.categoryIds, {'shopping'});
      expect(r.groups.single.cap, isNull);
      expect(r.groups.single.id, 'g2');
      expect(r.groups.single.name, '');
      expect(r.groups.single.merchantWords, {'amazon in'});
      expect(r.groups.single.minimum, isNull);
      expect(r.baseRate, 0);
      expect(r.pointValue, isNull);
      expect(CardRewards.tryFromJson('nope'), isNull);
    });

    test("a legacy group's id names its card and is the same on every "
        'read', () {
      final json = {
        'id': 'card1',
        'name': 'Test card',
        'type': AccountType.creditCard.name,
        'keys': ['BANKA:1111'],
        'rewards': {
          'groups': [
            {
              'categoryIds': ['food'],
              'rate': 10,
            },
            {
              'categoryIds': ['shopping'],
              'rate': 5,
            },
          ],
          'baseRate': 1,
        },
      };
      List<String> ids(Account a) => [for (final g in a.rewards!.groups) g.id];
      final first = Account.fromJson(json);
      expect(ids(first), ['card1-g0', 'card1-g1']);
      expect(ids(Account.fromJson(json)), ['card1-g0', 'card1-g1']);
      final back = Account.fromJson(jsonDecode(jsonEncode(first.toJson())));
      expect(ids(back), ['card1-g0', 'card1-g1']);
    });
  });

  group('rewardMerchantOf', () {
    Tx paid({String payee = 'Amazon Pay', bool spam = false}) => Tx(
      id: 'm1',
      type: TxType.expense,
      categoryId: kPaidForOthersCategoryId,
      amount: 500,
      note: '',
      date: DateTime(2026, 7, 1),
      payee: payee,
      suspectedSpam: spam,
    );

    test('a transfer has a merchant; spam and a short payee do not', () {
      expect(rewardMerchantOf(paid()), 'amazon pay');
      expect(rewardMerchantOf(paid(spam: true)), isNull);
      expect(rewardMerchantOf(paid(payee: 'AB')), isNull);
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
          row('t9', kCardBillCategoryId, 3000, day),
        ])
          t.toJson(),
      ]),
    });
    final finance = FinanceProvider();
    await finance.load();
    return finance;
  }

  test('cardRewardsFor: spends, Paid for Others and unpaired transfers earn; '
      'card bills, unticked rows and income do not', () async {
    final finance = await seeded();
    final a = finance.accountById('card1')!;
    final e = finance.cardRewardsFor(a)!;
    // Group 300 + 400 capped at 500, transport 10, Paid for Others 20,
    // Transfer out 50.
    expect(e.earned, 580);
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

    expect(find.text('Cashback this cycle ≈ ₹580 · capped'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rewards…'));
    await tester.pumpAndSettle();
    expect(find.text('Test card rewards'), findsOneWidget);
    // The unnamed v2.0.x group goes by its categories.
    expect(
      find.text('Food & Dining, Shopping · 10% · cap ₹500'),
      findsOneWidget,
    );

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
    // Nothing saved, nothing to undo.
    expect(find.text('Undo'), findsNothing);
    expect(find.text('₹ per point (optional)'), findsOneWidget);
    await tester.tap(find.text('Cashback'));
    await tester.pumpAndSettle();
    expect(find.text('₹ per point (optional)'), findsNothing);

    // The pinned Save says what is missing, one thing at a time.
    final save = find.byKey(const ValueKey('editor-save'));
    final rateField = find.byKey(const ValueKey('reward-group-rate'));
    final minField = find.byKey(const ValueKey('reward-group-minimum'));
    final capField = find.byKey(const ValueKey('reward-group-cap'));
    await tester.tap(find.text('Add a group'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a name'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('reward-group-name')),
      'Dining',
    );
    await tester.enterText(rateField, '-2');
    await tester.pumpAndSettle();
    expect(find.text("A rate can't be below 0"), findsOneWidget);
    await tester.enterText(rateField, '10');
    await tester.enterText(minField, '0');
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a minimum above ₹0, or leave it blank'),
      findsOneWidget,
    );
    await tester.enterText(minField, '100');
    await tester.enterText(capField, '0');
    await tester.pumpAndSettle();
    expect(find.text('Enter a cap above 0, or leave it blank'), findsOneWidget);
    await tester.enterText(capField, '1,000');
    await tester.pumpAndSettle();
    expect(find.text('Pick a category or add a merchant word'), findsOneWidget);
    await tester.tap(find.text('Categories'));
    await tester.pumpAndSettle();
    expect(find.text('To sort'), findsNothing);
    expect(find.text('Transfer out'), findsNothing);
    await tester.tap(find.text('Food & Dining'));
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.byType(EditorSheetBody), findsNothing);
    final g = saved()!.groups.single;
    expect(g.name, 'Dining');
    expect(g.categoryIds, {'food'});
    expect(g.rate, 10);
    expect(g.minimum, 100);
    expect(g.cap, 1000);
    expect(g.id, startsWith('g'));
    // "min" and "cap" hold their amounts with a no-break space.
    expect(find.text('Dining · 10% · min ₹100 · cap ₹1,000'), findsOneWidget);
    expect(find.text('Food & Dining'), findsOneWidget);

    // A second group cannot take Food & Dining again.
    await tester.tap(find.text('Add a group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Categories'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(EditorSheetBody),
        matching: find.text('Food & Dining'),
      ),
      findsNothing,
    );
    await tester.binding.handlePopRoute();
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
    // Every rate now reads in points: Undo puts cashback back.
    expect(find.text('Rates now read as points per ₹100'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(saved()!.unit, RewardUnit.cashback);
    expect(find.text('Rates are a percent of each spend.'), findsOneWidget);
    await tester.tap(find.text('Points'));
    await tester.pumpAndSettle();
    expect(saved()!.unit, RewardUnit.points);
    // A points card's cap is in points.
    const pointsRow =
        'Dining · 10 points per ₹100 · min ₹100 · cap 1,000 points';
    expect(find.text(pointsRow), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, '₹ per point (optional)'),
      '0.25',
    );
    await tester.pumpAndSettle();
    expect(saved()!.pointValue, 0.25);

    // Delete group, then Undo puts it back.
    await tester.tap(find.text(pointsRow));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Group actions'));
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
    await tester.tap(find.text(pointsRow));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Group actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();
    expect(saved(), isNull);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(saved()!.unit, RewardUnit.points);
    expect(saved()!.groups.single.rate, 10);
    expect(saved()!.pointValue, 0.25);

    // A group of merchant words alone; a typed word counts without Add.
    await tester.tap(find.text('Add a group'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reward-group-name')),
      'Demo Shop',
    );
    await tester.enterText(rateField, '5');
    await tester.tap(find.text('Merchant words'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reward-group-word')),
      'Demo Shop',
    );
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    final groups = saved()!.groups;
    expect(groups, hasLength(2));
    expect(groups.last.name, 'Demo Shop');
    expect(groups.last.merchantWords, {'demo shop'});
    expect(groups.last.categoryIds, isEmpty);
  });

  testWidgets('the reward group sheet fits 320dp at 2x text', (tester) async {
    tester.view.physicalSize = const Size(320, 568) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final finance = await seeded();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: finance,
        child: MaterialApp(
          // Above the routes, so the sheet gets the text scale too.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const CardRewardsPage(accountId: 'card1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Below the fold of the page at this size.
    final row = find.text('Food & Dining, Shopping · 10% · cap ₹500');
    await tester.scrollUntilVisible(row, 100);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(EditorSheetBody), findsOneWidget);
    for (final fold in ['Categories', 'Merchant words']) {
      await tester.ensureVisible(find.text(fold));
      await tester.pumpAndSettle();
      await tester.tap(find.text(fold));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('editor-save')).hitTestable(),
        findsOneWidget,
      );
    }
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
