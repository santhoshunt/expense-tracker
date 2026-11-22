import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/card_rewards.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/card_rewards_page.dart';
import 'package:expense_tracker/services/card_rewards.dart';
import 'package:expense_tracker/widgets/info_tip.dart';

import 'accounts_test_utils.dart';

/// A card whose rewards count whole ₹100s only: each payment earns on its
/// complete hundreds, the minimum still tests the real amount.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  const hundreds = CardRewards(baseRate: 1.5, wholeHundreds: true);
  const every = CardRewards(baseRate: 1.5);

  group('earnOn', () {
    test('earns on complete hundreds only', () {
      expect(hundreds.earnOn(null, 100), 1.5);
      expect(hundreds.earnOn(null, 180), 1.5);
      expect(hundreds.earnOn(null, 250), 3);
      expect(hundreds.earnOn(null, 99), 0);
      expect(hundreds.earnOn(null, 99.99), 0);
      expect(hundreds.earnOn(null, 299.99), 3);
      expect(hundreds.earnOn(null, 300.00), 4.5);
    });

    test('float noise just under ₹300 still counts three hundreds', () {
      // A ₹300 built by arithmetic can land a hair under 300.
      const noisy = 300 - 1e-9;
      expect(noisy < 300, isTrue);
      expect(hundreds.earnOn(null, noisy), 4.5);
    });

    test('a minimum tests the real amount, not the cut-down one', () {
      const r = CardRewards(
        groups: [
          RewardGroup(id: 'g1', categoryIds: {'food'}, rate: 5, minimum: 150),
        ],
        wholeHundreds: true,
      );
      final g = r.groupFor('food');
      expect(r.earnOn(g, 180), 5);
      expect(r.earnOn(g, 140), 0);
    });

    test('with the switch off every figure is as before', () {
      expect(every.earnOn(null, 180), closeTo(2.7, 1e-9));
      expect(every.earnOn(null, 99), closeTo(1.485, 1e-9));
      expect(every.earnOn(null, 250), 3.75);
    });
  });

  group('estimateRewards', () {
    test('hundreds per payment, summed, then rounded down', () {
      final e = estimateRewards(hundreds, [
        for (final amount in [100.0, 180.0, 199.0]) (group: null, amount: amount),
      ]);
      // 1.5 three times is 4.5, rounded down.
      expect(e.earned, 4);
      expect(
        estimateRewards(every, [
          for (final amount in [100.0, 180.0, 199.0])
            (group: null, amount: amount),
        ]).earned,
        // 1.5 + 2.7 + 2.985 is 7.185, rounded down.
        7,
      );
    });

    test('a cap still holds the group', () {
      const capped = CardRewards(
        groups: [RewardGroup(id: 'g1', categoryIds: {'food'}, rate: 10, cap: 25)],
        wholeHundreds: true,
      );
      final g = capped.groupFor('food');
      final two = estimateRewards(capped, [
        (group: g, amount: 180),
        (group: g, amount: 180),
      ]);
      expect(two.earned, 20);
      expect(two.capped, isFalse);
      final three = estimateRewards(capped, [
        for (var i = 0; i < 3; i++) (group: g, amount: 180.0),
      ]);
      expect(three.earned, 25);
      expect(three.capped, isTrue);
    });

    test('points with a ₹ value', () {
      const points = CardRewards(
        unit: RewardUnit.points,
        groups: [
          RewardGroup(id: 'g1', name: 'Dining', categoryIds: {'food'}, rate: 5),
        ],
        baseRate: 1.5,
        pointValue: 0.25,
        wholeHundreds: true,
      );
      final g = points.groupFor('food');
      final e = estimateRewards(points, [
        (group: g, amount: 480),
        (group: null, amount: 180),
      ]);
      // 4 hundreds at 5 is 20, plus 1.5: 21.5 rounded down.
      expect(e.earned, 21);
      expect(e.rupees, 5.25);
      const off = CardRewards(
        unit: RewardUnit.points,
        groups: [
          RewardGroup(id: 'g1', name: 'Dining', categoryIds: {'food'}, rate: 5),
        ],
        baseRate: 1.5,
        pointValue: 0.25,
      );
      final today = estimateRewards(off, [
        (group: off.groupFor('food'), amount: 480),
        (group: null, amount: 180),
      ]);
      // 24 + 2.7.
      expect(today.earned, 26);
      expect(today.rupees, 6.5);
    });
  });

  // A statement day ten days ahead, so a row yesterday sits in the current
  // cycle whatever today is. The clock is read once.
  final now = DateTime.now();
  final stmtDay = now.add(const Duration(days: 10)).day;
  final yesterday = DateTime(now.year, now.month, now.day - 1);

  Account card(CardRewards? rewards) => Account(
    id: 'card1',
    name: 'Demo Card One',
    type: AccountType.creditCard,
    keys: const {'DEMOBANK:4321'},
    statementDay: stmtDay,
    rewards: rewards,
  );

  Tx row(String id, TxType type, String categoryId, double amount, {
    String? refundOf,
  }) => Tx(
    id: id,
    type: type,
    categoryId: categoryId,
    amount: amount,
    note: '',
    date: yesterday,
    acctKey: 'DEMOBANK:4321',
    refundOf: refundOf,
  );

  Future<FinanceProvider> seeded(CardRewards? rewards, List<Tx> rows) async {
    SharedPreferences.setMockInitialValues({
      'accounts_v1': jsonEncode([card(rewards).toJson()]),
      'transactions_v1': jsonEncode([for (final t in rows) t.toJson()]),
    });
    final finance = FinanceProvider();
    await finance.load();
    return finance;
  }

  test('a partial refund is taken off before the cut to hundreds', () async {
    const fivePercent = CardRewards(baseRate: 5, wholeHundreds: true);
    final rows = [
      row('t1', TxType.expense, 'food', 220),
      row('r1', TxType.income, 'other_income', 40, refundOf: 't1'),
    ];
    final p = await seeded(fivePercent, rows);
    final a = p.accountById('card1')!;
    expect(p.refundedFor(p.transactions.firstWhere((t) => t.id == 't1')), 40);
    // ₹220 less ₹40 is ₹180: one hundred at 5%.
    expect(p.cardRewardsFor(a)!.earned, 5);
    // Without the refund, ₹220 is two hundreds.
    final plain = await seeded(fivePercent, [rows.first]);
    expect(plain.cardRewardsFor(plain.accountById('card1')!)!.earned, 10);
    // Switch off: 5% of ₹180.
    final off = await seeded(const CardRewards(baseRate: 5), rows);
    expect(off.cardRewardsFor(off.accountById('card1')!)!.earned, 9);
  });

  group('JSON', () {
    test('round trips, and off writes no key', () {
      final back = CardRewards.tryFromJson(
        jsonDecode(jsonEncode(hundreds.toJson())),
      )!;
      expect(back.wholeHundreds, isTrue);
      expect(hundreds.toJson()['wholeHundreds'], true);
      expect(every.toJson().containsKey('wholeHundreds'), isFalse);
    });

    test('missing or malformed reads as off', () {
      for (final value in [null, 'yes', 1, 'true', false]) {
        final r = CardRewards.tryFromJson({
          'baseRate': 1.5,
          'wholeHundreds': value,
        })!;
        expect(r.wholeHundreds, isFalse, reason: '$value');
      }
      expect(CardRewards.tryFromJson({'baseRate': 1.5})!.wholeHundreds, isFalse);
    });

    test('a backup carries the switch through a restore', () async {
      final p = await seeded(hundreds, const []);
      final data = jsonDecode(jsonEncode(p.exportData())) as Map<String, dynamic>;
      expect(data['version'], 35);
      SharedPreferences.setMockInitialValues({});
      final fresh = FinanceProvider();
      await fresh.load();
      await fresh.importData(data, replace: true);
      final r = fresh.accountById('card1')!.rewards!;
      expect(r.wholeHundreds, isTrue);
      expect(r.baseRate, 1.5);
    });
  });

  group('the rewards page', () {
    Widget app(FinanceProvider p) => ChangeNotifierProvider.value(
      value: p,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openCardRewards(context, 'card1'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    final switchRow = find.widgetWithText(SwitchListTile, 'Whole ₹100s only');
    bool shownOn(WidgetTester tester) =>
        tester.widget<SwitchListTile>(switchRow).value;

    testWidgets('the switch sits under the unit, saves, undoes and survives '
        'every other change', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const rules = CardRewards(
        groups: [
          RewardGroup(id: 'g1', name: 'Dining', categoryIds: {'food'}, rate: 5),
        ],
        baseRate: 1.5,
      );
      final p = await seeded(rules, const []);
      CardRewards saved() => p.accountById('card1')!.rewards!;
      await tester.pumpWidget(app(p));
      await open(tester);

      expect(switchRow, findsOneWidget);
      expect(find.text('A ₹180 payment earns on ₹100'), findsOneWidget);
      final y = tester.getTopLeft(switchRow).dy;
      expect(
        y,
        greaterThan(
          tester.getTopLeft(find.text('Rates are a percent of each spend.')).dy,
        ),
      );
      expect(y, lessThan(tester.getTopLeft(find.text('Reward groups')).dy));
      expect(shownOn(tester), isFalse);

      // On saves at once; Undo puts it back off.
      await tester.tap(switchRow);
      await tester.pumpAndSettle();
      expect(saved().wholeHundreds, isTrue);
      expect(shownOn(tester), isTrue);
      expect(find.text('Rewards now count whole ₹100s only'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(saved().wholeHundreds, isFalse);
      expect(shownOn(tester), isFalse);
      await tester.tap(switchRow);
      await tester.pumpAndSettle();
      expect(saved().wholeHundreds, isTrue);

      // A rate change keeps it.
      await tester.enterText(
        find.widgetWithText(TextField, 'Everything else'),
        '2',
      );
      await tester.pumpAndSettle();
      expect(saved().baseRate, 2);
      expect(saved().wholeHundreds, isTrue);

      // The unit switch and its Undo keep it.
      await tester.tap(find.text('Points'));
      await tester.pumpAndSettle();
      expect(saved().unit, RewardUnit.points);
      expect(saved().wholeHundreds, isTrue);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(saved().unit, RewardUnit.cashback);
      expect(saved().wholeHundreds, isTrue);

      // Deleting a group and its Undo keep it.
      await tester.tap(find.text('Dining · 5%'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Group actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete group'));
      await tester.pumpAndSettle();
      expect(saved().groups, isEmpty);
      expect(saved().wholeHundreds, isTrue);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(saved().groups.single.name, 'Dining');
      expect(saved().wholeHundreds, isTrue);

      // Leaving and coming back shows it on.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await open(tester);
      expect(shownOn(tester), isTrue);
    });

    testWidgets('on a card with no rates yet the switch holds until the '
        'first rate saves', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await seeded(null, const []);
      await tester.pumpWidget(app(p));
      await open(tester);
      await tester.tap(switchRow);
      await tester.pumpAndSettle();
      expect(p.accountById('card1')!.rewards, isNull);
      expect(shownOn(tester), isTrue);
      // Nothing saved, nothing to undo.
      expect(find.text('Undo'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'Everything else'),
        '1.5',
      );
      await tester.pumpAndSettle();
      expect(p.accountById('card1')!.rewards!.wholeHundreds, isTrue);
    });

    testWidgets('nothing overflows at 1.3x text on a 360dp screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final p = await seeded(
        const CardRewards(
          unit: RewardUnit.points,
          groups: [
            RewardGroup(
              id: 'g1',
              name: 'Dining',
              categoryIds: {'food'},
              rate: 5,
            ),
          ],
          baseRate: 1.5,
          wholeHundreds: true,
        ),
        const [],
      );
      await tester.pumpWidget(app(p));
      await open(tester);
      expect(switchRow, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('₹ per point (optional)'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the card tile tip', () {
    // The label is its own tip, so the InfoTip lives on the InfoLabel.
    String tipOf(WidgetTester tester) => tester
        .widget<InfoLabel>(
          find.byWidgetPredicate(
            (w) => w is InfoLabel && w.tip.title == 'Rewards estimate',
          ),
        )
        .tip
        .message;

    Future<void> pumpTile(WidgetTester tester, FinanceProvider p) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(accountsApp(p));
      await tester.pumpAndSettle();
    }

    testWidgets('says the card counts whole ₹100s only when it does', (
      tester,
    ) async {
      final p = await seeded(hundreds, [row('t1', TxType.expense, 'food', 180)]);
      await pumpTile(tester, p);
      expect(find.text('Cashback this cycle ≈ ₹1'), findsOneWidget);
      expect(tipOf(tester), contains(wholeHundredsNote));
      expect(
        tipOf(tester),
        contains(
          'A split payment earns once, on its total. This card counts whole '
          '₹100s only, so ₹180 earns as ₹100. The bank decides the real '
          'figure.',
        ),
      );
      // The tap lands on the tip's own target laid over the label.
      await tester.tap(
        find.text('Cashback this cycle ≈ ₹1'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(wholeHundredsNote), findsOneWidget);
    });

    testWidgets('and leaves it out when it does not', (tester) async {
      final p = await seeded(every, [row('t1', TxType.expense, 'food', 180)]);
      await pumpTile(tester, p);
      expect(find.text('Cashback this cycle ≈ ₹2'), findsOneWidget);
      expect(tipOf(tester), isNot(contains('₹100s')));
      expect(
        tipOf(tester),
        endsWith(
          'A split payment earns once, on its total. The bank decides the '
          'real figure.',
        ),
      );
    });
  });
}
