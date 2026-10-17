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
}
