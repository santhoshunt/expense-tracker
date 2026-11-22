import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/utils/format.dart';

/// Cockpit in v1.43.0: the Rules tab folds the built-in rules and can
/// restore them, and the add button hides on a downward scroll.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
  });

  tearDown(() => NotificationService.statusOverride = null);

  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<FinanceProvider> pumpRules(
    WidgetTester tester, {
    Size size = const Size(1080, 2400),
    Future<void> Function(FinanceProvider p)? seed,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    await seed?.call(p);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: const MaterialApp(
          home: ClassifiersScreen(initialTab: kCockpitTabRules),
        ),
      ),
    );
    await pumpThrough(tester);
    return p;
  }

  const restaurant = 'contains "restaurant"';
  final fold = find.textContaining('Built-in rules · ');

  testWidgets('built-in rules wait in a fold that a tap or a search opens', (
    tester,
  ) async {
    final p = await pumpRules(tester);
    final builtins = p.rules.where((r) => r.isBuiltIn).length;
    expect(builtins, greaterThan(0));
    expect(find.text('Built-in rules · $builtins'), findsOneWidget);
    expect(find.text(restaurant), findsNothing);
    // TalkBack hears the fold state.
    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(fold),
      isSemantics(hasExpandedState: true, isExpanded: false),
    );

    await tester.tap(fold);
    await pumpThrough(tester);
    expect(find.text(restaurant), findsOneWidget);
    expect(
      tester.getSemantics(fold),
      isSemantics(hasExpandedState: true, isExpanded: true),
    );
    semantics.dispose();
    await tester.tap(fold);
    await pumpThrough(tester);
    expect(find.text(restaurant), findsNothing);

    // A search shows the matching built-ins whatever the fold.
    await tester.enterText(find.byType(TextField), 'restaurant');
    await pumpThrough(tester);
    expect(find.text(restaurant), findsOneWidget);
    expect(find.text('Built-in rules · 1'), findsOneWidget);
  });

  testWidgets('folding drops selected built-ins from the selection', (
    tester,
  ) async {
    await pumpRules(tester);
    await tester.tap(fold);
    await pumpThrough(tester);
    await tester.longPress(find.text(restaurant));
    await pumpThrough(tester);
    expect(find.byTooltip('Clear selection'), findsOneWidget);

    await tester.tap(fold);
    await pumpThrough(tester);
    expect(find.byTooltip('Clear selection'), findsNothing);
  });

  testWidgets('Restore built-in rules brings back a deleted one, with Undo', (
    tester,
  ) async {
    late String id;
    final p = await pumpRules(
      tester,
      seed: (p) async {
        id = p.rules.firstWhere((r) => r.pattern == 'restaurant').id;
        await p.deleteRule(id);
      },
    );
    expect(p.rules.any((r) => r.id == id), isFalse);

    await tester.tap(find.text('Restore built-in rules'));
    await pumpThrough(tester);
    expect(find.text('Restore built-in rules?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await pumpThrough(tester);
    expect(find.text('Restored 1 built-in rule'), findsOneWidget);
    expect(p.rules.any((r) => r.id == id), isTrue);

    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);
    expect(p.rules.any((r) => r.id == id), isFalse);

    // Nothing to restore: said so, with no Undo.
    await p.restoreDefaultRules();
    await tester.tap(find.text('Restore built-in rules'));
    await pumpThrough(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await pumpThrough(tester);
    expect(find.text('Built-in rules are as they first were'), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('Undo after Restore built-in rules leaves past rows as they '
      'are', (tester) async {
    bool held(FinanceProvider p) => [
      ...p.pendingTransactions,
      ...p.transactions,
    ].any((t) => t.externalRef == 'PRIZE1');
    final p = await pumpRules(
      tester,
      seed: (p) async {
        await p.addImported([
          ParsedTxn(
            type: TxType.expense,
            amount: 100,
            merchant: 'Acme Prize',
            date: DateTime(2026, 7, 1, 13),
            ref: 'PRIZE1',
            categoryId: 'shopping',
            sender: 'VM-ACMEBK',
            rawBody: 'Rs.100 debited. PRIZE DRAW inside',
          ),
        ]);
        // A spam rule for that row, put back without a re-sort as the
        // Undo of a delete does, so the row is still waiting.
        await p.restoreRule(
          const ClassifierRule(
            id: 'r_prize',
            pattern: 'prize draw',
            categoryId: kSpamCategoryId,
          ),
          0,
        );
        await p.deleteRule(
          p.rules.firstWhere((r) => r.pattern == 'restaurant').id,
        );
      },
    );
    expect(held(p), isTrue);

    await tester.tap(find.text('Restore built-in rules'));
    await pumpThrough(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await pumpThrough(tester);
    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);
    expect(p.rules.any((r) => r.pattern == 'restaurant'), isFalse);
    expect(held(p), isTrue);
  });

  testWidgets('with every rule gone, the empty state offers Restore', (
    tester,
  ) async {
    final p = await pumpRules(
      tester,
      seed: (p) async {
        for (final r in List.of(p.rules)) {
          await p.deleteRule(r.id);
        }
      },
    );
    expect(p.rules, isEmpty);
    expect(find.textContaining('No rules yet.'), findsOneWidget);
    expect(find.text('Restore built-in rules'), findsOneWidget);
  });

  testWidgets('the add button hides on a downward scroll and returns on an '
      'upward one, always with its label', (tester) async {
    await pumpRules(tester, size: const Size(392, 872));
    await tester.tap(fold);
    await pumpThrough(tester);
    final add = find.text('New rule');
    expect(add.hitTestable(), findsOneWidget);

    final list = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(list, const Offset(0, -300));
    await pumpThrough(tester);
    expect(add.hitTestable(), findsNothing);

    await tester.drag(list, const Offset(0, 200));
    await pumpThrough(tester);
    expect(add.hitTestable(), findsOneWidget);
  });

  group('rule health', () {
    // A counted alert row dated [days] days before today. The rows read
    // the device clock, as the day headings do, so the dates are told
    // from today.
    Tx smsRow(
      String id,
      String body,
      int days, {
      TxType type = TxType.expense,
    }) {
      final now = DateTime.now();
      return Tx(
        id: id,
        type: type,
        categoryId: type == TxType.income ? 'other_income' : 'other_expense',
        amount: 250,
        note: '',
        date: DateTime(now.year, now.month, now.day - days, 12),
        source: TxSource.sms,
        smsBody: body,
        sender: 'AD-DEMOBK',
      );
    }

    Finder tileOf(String pattern) => find.ancestor(
      of: find.text('contains "$pattern"'),
      matching: find.byType(ListTile),
    );

    Finder inTile(String pattern, Finder what) =>
        find.descendant(of: tileOf(pattern), matching: what);

    const quiet = 'No match in 6 months';
    // The health line of a row wide enough for it: each part's words are
    // held together and the line breaks only after the dot (joinFacts).
    String reaches(String payments, String latest) =>
        joinFacts([payments, 'latest $latest']);
    const cardWords =
        'Common words such as restaurant, petrol and pharmacy. '
        'Checked after yours.';

    testWidgets('a rule row says how many payments it reaches and how '
        'lately, or that it has gone quiet', (tester) async {
      await pumpRules(
        tester,
        seed: (p) async {
          await p.restoreTransactions([
            smsRow('q1', 'Rs 250 paid to QUILLFERN', 3),
            smsRow('q2', 'Rs 250 paid to QUILLFERN again', 10),
            smsRow('z1', 'Rs 250 paid to ZEPHYRINE', 0),
            // One day past the limit, and the last day inside it.
            smsRow('m1', 'Rs 250 paid to MAPLEWORTH', kRuleQuietDays + 1),
            smsRow('t1', 'Rs 250 paid to TAMARISK', kRuleQuietDays),
          ]);
          for (final word in [
            'quillfern',
            'zephyrine',
            'mapleworth',
            'tamarisk',
            'meeravalli',
          ]) {
            await p.addRule(word, 'food');
          }
        },
      );

      expect(
        inTile('quillfern', find.text(reaches('2 payments', '3 days ago'))),
        findsOneWidget,
      );
      // No-break spaces inside each part, an ordinary one after the dot:
      // the line cannot split "2 / payments" or start with the dot.
      expect(
        reaches('2 payments', '3 days ago'),
        '2\u{00A0}payments\u{00A0}· latest\u{00A0}3\u{00A0}days\u{00A0}ago',
      );
      expect(
        inTile('zephyrine', find.text(reaches('1 payment', 'today'))),
        findsOneWidget,
      );
      expect(
        inTile('tamarisk', find.text(reaches('1 payment', '6 months ago'))),
        findsOneWidget,
      );
      expect(
        inTile('meeravalli', find.text('No payments yet')),
        findsOneWidget,
      );
      expect(find.text('No payments yet'), findsOneWidget);
      // The existing subtitle is still there, above the new line.
      expect(
        inTile('quillfern', find.text('→ Food & Dining (expense)')),
        findsOneWidget,
      );

      // Only the quiet rule carries the marker, and its words stay in the
      // subtitle's own colour.
      expect(inTile('mapleworth', find.text(quiet)), findsOneWidget);
      expect(find.text(quiet), findsOneWidget);
      final marker = find.byIcon(Icons.error_outline);
      expect(marker, findsOneWidget);
      expect(inTile('mapleworth', marker), findsOneWidget);
      expect(tester.widget<Icon>(marker).size, 14);
      // Level with its words.
      expect(
        tester.getCenter(marker).dy,
        moreOrLessEquals(tester.getCenter(find.text(quiet)).dy, epsilon: 0.5),
      );
      final context = tester.element(find.text(quiet));
      expect(
        DefaultTextStyle.of(context).style.color,
        DefaultTextStyle.of(
          tester.element(find.text('No payments yet')),
        ).style.color,
      );
      expect(tester.widget<Text>(find.text(quiet)).style, isNull);

      // A screen reader hears the line as part of the row, and the marker
      // adds no node of its own.
      final semantics = tester.ensureSemantics();
      final row = tester.getSemantics(find.text('contains "mapleworth"'));
      expect(row.label, contains('contains "mapleworth"'));
      expect(row.label, contains(quiet));
      expect(tester.getSemantics(marker).id, row.id);
      expect(
        tester.getSemantics(find.text('contains "quillfern"')).label,
        contains(reaches('2 payments', '3 days ago')),
      );
      semantics.dispose();
    });

    testWidgets('a spam rule row has no health line', (tester) async {
      await pumpRules(
        tester,
        seed: (p) async {
          await p.restoreTransactions([
            smsRow('s1', 'Rs 250 paid to MEERAVALLI', 2),
          ]);
          await p.addRule('meeravalli', kSpamCategoryId);
        },
      );
      expect(
        inTile('meeravalli', find.text('Spam, never imported')),
        findsOneWidget,
      );
      // The title and the subtitle, nothing under them.
      expect(inTile('meeravalli', find.byType(Text)), findsNWidgets(2));
      expect(find.text('No payments yet'), findsNothing);
      expect(find.textContaining('latest'), findsNothing);
    });

    testWidgets('a rule pair row adds up both of its rules', (tester) async {
      await pumpRules(
        tester,
        seed: (p) async {
          await p.restoreTransactions([
            smsRow('q1', 'Rs 250 paid to QUILLFERN', 5),
            smsRow('q2', 'Rs 250 paid to QUILLFERN again', 9),
            smsRow(
              'q3',
              'Rs 250 received from QUILLFERN',
              2,
              type: TxType.income,
            ),
            // Only the twin under the row has a payment.
            smsRow('m1', 'Rs 250 paid to MAPLEWORTH', 1),
          ]);
          await p.addRule('quillfern', 'food');
          await p.addRule('quillfern', 'other_income');
          await p.addRule('mapleworth', 'food');
          await p.addRule('mapleworth', 'other_income');
        },
      );
      expect(find.text('contains "quillfern"'), findsOneWidget);
      expect(
        inTile('quillfern', find.text(reaches('3 payments', '2 days ago'))),
        findsOneWidget,
      );
      expect(find.text('contains "mapleworth"'), findsOneWidget);
      expect(
        inTile('mapleworth', find.text(reaches('1 payment', 'yesterday'))),
        findsOneWidget,
      );
    });

    // v2.3.0 review: a backup restored on a new phone has rows with no
    // alert text, so no rule can be matched to them and every row read
    // "No payments yet".
    testWidgets('rule rows have no health line while no rule has any match', (
      tester,
    ) async {
      final p = await pumpRules(
        tester,
        seed: (p) async {
          final now = DateTime.now();
          await p.restoreTransactions([
            // As a restore leaves it: an alert row with no alert text.
            Tx(
              id: 'restored',
              type: TxType.expense,
              categoryId: 'food',
              amount: 250,
              note: '',
              date: DateTime(now.year, now.month, now.day - 2, 12),
              source: TxSource.sms,
              sender: 'AD-DEMOBK',
            ),
          ]);
          await p.addRule('meeravalli', 'food');
          await p.addRule('quillfern', 'food');
        },
      );
      expect(p.ruleUses, isEmpty);
      expect(find.text('No payments yet'), findsNothing);
      expect(find.text(quiet), findsNothing);
      expect(find.textContaining('latest'), findsNothing);
      // The title and the subtitle, nothing under them.
      expect(inTile('meeravalli', find.byType(Text)), findsNWidgets(2));

      // The first payment any rule reaches brings the line to every row.
      await p.restoreTransactions([
        smsRow('q1', 'Rs 250 paid to QUILLFERN', 1),
      ]);
      await pumpThrough(tester);
      expect(
        inTile('quillfern', find.text(reaches('1 payment', 'yesterday'))),
        findsOneWidget,
      );
      expect(
        inTile('meeravalli', find.text('No payments yet')),
        findsOneWidget,
      );
    });

    testWidgets('the Built-in rules card counts every built-in rule that '
        'never matched, and not during a search', (tester) async {
      final p = await pumpRules(
        tester,
        seed: (p) async {
          // One payment a rule of the user's own reaches: no built-in has
          // a match, and the ledger has alert history.
          await p.restoreTransactions([
            smsRow('q1', 'Rs 250 paid to QUILLFERN', 3),
          ]);
          await p.addRule('quillfern', 'food');
        },
      );
      final builtins = p.rules.where((r) => r.isBuiltIn).length;
      expect(
        find.text('$cardWords $builtins matched nothing in 6 months.'),
        findsOneWidget,
      );

      // A search narrows the title's count to the rules found, so the
      // sentence, which counts them all, is left out.
      await tester.enterText(find.byType(TextField), 'restaurant');
      await pumpThrough(tester);
      expect(find.text('Built-in rules · 1'), findsOneWidget);
      expect(find.text(cardWords), findsOneWidget);
      expect(find.textContaining('matched nothing'), findsNothing);

      // Cleared, it is back.
      await tester.enterText(find.byType(TextField), '');
      await pumpThrough(tester);
      expect(
        find.text('$cardWords $builtins matched nothing in 6 months.'),
        findsOneWidget,
      );
    });

    testWidgets('the Built-in rules card says nothing about matches while '
        'no rule has any', (tester) async {
      // No alert history at all: every built-in rule would count.
      final p = await pumpRules(tester);
      expect(p.ruleUses, isEmpty);
      expect(find.text(cardWords), findsOneWidget);
      expect(find.textContaining('matched nothing'), findsNothing);

      // Nor with rows restored from a backup, which carry no alert text.
      final now = DateTime.now();
      await p.restoreTransactions([
        Tx(
          id: 'restored',
          type: TxType.expense,
          categoryId: 'food',
          amount: 250,
          note: '',
          date: DateTime(now.year, now.month, now.day - 2, 12),
          source: TxSource.sms,
          sender: 'AD-DEMOBK',
        ),
      ]);
      await pumpThrough(tester);
      expect(p.ruleUses, isEmpty);
      expect(find.textContaining('matched nothing'), findsNothing);

      // The first payment a rule reaches brings the sentence.
      await p.restoreTransactions([smsRow('s1', 'Rs 250 paid to SWIGGY', 1)]);
      await pumpThrough(tester);
      final builtins = p.rules.where((r) => r.isBuiltIn).length;
      expect(
        find.text('$cardWords ${builtins - 1} matched nothing in 6 months.'),
        findsOneWidget,
      );
    });

    testWidgets('the Built-in rules card counts quiet rules, leaves spam '
        'rules out and says nothing at zero', (tester) async {
      final p = await pumpRules(
        tester,
        seed: (p) async {
          for (final r in List.of(p.rules)) {
            if (r.pattern != 'swiggy' && r.pattern != 'zomato') {
              await p.deleteRule(r.id);
            }
          }
          await p.restoreTransactions([
            smsRow('s1', 'Rs 250 paid to SWIGGY', 2),
            smsRow('z1', 'Rs 250 paid to ZOMATO', kRuleQuietDays + 1),
          ]);
        },
      );
      expect(find.text('Built-in rules · 2'), findsOneWidget);
      expect(
        find.text('$cardWords 1 matched nothing in 6 months.'),
        findsOneWidget,
      );

      // As a spam rule, the quiet one no longer counts.
      final zomato = p.rules.firstWhere((r) => r.pattern == 'zomato');
      await p.updateRule(zomato.copyWith(categoryId: kSpamCategoryId));
      await pumpThrough(tester);
      expect(find.text(cardWords), findsOneWidget);
      expect(find.textContaining('matched nothing'), findsNothing);

      // Back as it was, a payment today brings it under the limit.
      await p.updateRule(zomato);
      await pumpThrough(tester);
      expect(
        find.text('$cardWords 1 matched nothing in 6 months.'),
        findsOneWidget,
      );
      await p.restoreTransactions([smsRow('z2', 'Rs 250 paid to ZOMATO', 0)]);
      await pumpThrough(tester);
      expect(find.text(cardWords), findsOneWidget);
      expect(find.textContaining('matched nothing'), findsNothing);
    });

    testWidgets('the rule rows fit a 320dp screen at double text size', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpRules(
        tester,
        size: const Size(320, 568),
        seed: (p) async {
          await p.restoreTransactions([
            smsRow('q1', 'Rs 250 paid to QUILLFERN', 40),
            smsRow(
              'q2',
              'Rs 250 received from QUILLFERN',
              75,
              type: TxType.income,
            ),
            smsRow('m1', 'Rs 250 paid to MAPLEWORTH', kRuleQuietDays + 1),
          ]);
          await p.addRule('meeravalli', 'food');
          // A pair that also sets Paid to and tags: the longest subtitle.
          for (final category in ['food', 'other_income']) {
            await p.addRule(
              'quillfern',
              category,
              payee: 'Quillfern Teas',
              tags: ['Office', 'Team'],
            );
          }
          await p.addRule('mapleworth', 'food');
        },
      );
      expect(tester.takeException(), isNull);
      expect(find.text(quiet), findsOneWidget);
      // The marker sits beside the first line of its words, inside the row.
      final marker = tester.getRect(find.byIcon(Icons.error_outline));
      final words = tester.getRect(find.text(quiet));
      expect(marker.right, lessThanOrEqualTo(words.left));
      expect(marker.top, greaterThanOrEqualTo(words.top));
      expect(marker.bottom, lessThanOrEqualTo(words.bottom));
      expect(words.right, lessThanOrEqualTo(320));

      final list = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      // Neither part fits this row whole, so both keep their ordinary
      // spaces (held together they would be cut inside a word); the dot
      // still holds to the part before it.
      await tester.scrollUntilVisible(
        find.text('2 payments\u{00A0}· latest 1 month ago'),
        120,
        scrollable: list,
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('No payments yet'),
        120,
        scrollable: list,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
