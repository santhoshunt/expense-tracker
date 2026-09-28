import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/import_health.dart';
import 'package:expense_tracker/services/safe_to_spend.dart';
import 'package:expense_tracker/widgets/import_health_banner.dart';
import 'package:expense_tracker/widgets/spending_heatmap.dart';

/// The Overview's import warning and the Breakdown heatmap's amounts and
/// bill dots.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Widget app(FinanceProvider p, SettingsProvider s, Widget child) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      );

  Future<(FinanceProvider, SettingsProvider)> providers() async {
    final p = FinanceProvider();
    await p.load();
    final s = SettingsProvider();
    await s.load();
    return (p, s);
  }

  group('import warning', () {
    testWidgets('shows, lists samples, and dismisses', (tester) async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        kImportHealthKey: jsonEncode({
          'HDFC': {
            'unread': [
              now.subtract(const Duration(days: 3)).millisecondsSinceEpoch,
              now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
            ],
            'samples': [
              {
                'at': now
                    .subtract(const Duration(days: 1))
                    .millisecondsSinceEpoch,
                'sender': 'VM-HDFCBK',
                'body': 'A/c XX1234 debited. Avl Bal Rs.5,000.00',
              },
            ],
          },
        }),
      });
      final (p, s) = await providers();
      await tester.pumpWidget(app(p, s, const ImportHealthBanner()));
      await tester.pumpAndSettle();
      expect(
        find.text('2 HDFC alerts in 14 days could not be read'),
        findsOneWidget,
      );

      await tester.tap(find.text('See alerts'));
      await tester.pumpAndSettle();
      expect(
        find.text('A/c XX1234 debited. Avl Bal Rs.5,000.00'),
        findsOneWidget,
      );
      Navigator.of(
        tester.element(find.text('Bank alerts not importing')),
      ).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('See alerts'), findsNothing);
      final health = await ImportHealth.load();
      expect(health.banks['HDFC']!.dismissedAt, isNotNull);
    });

    testWidgets('nothing to say, nothing shown', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final (p, s) = await providers();
      await tester.pumpWidget(app(p, s, const ImportHealthBanner()));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);
    });
  });

  group('heatmap', () {
    final month = DateTime(2026, 9);

    Future<FinanceProvider> spent() async {
      SharedPreferences.setMockInitialValues({});
      final (p, _) = await providers();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 1200,
        note: 'Dinner',
        date: DateTime(2026, 9, 10, 20),
      );
      return p;
    }

    testWidgets('a spend day shows its amount; a bill day a dot and its bill', (
      tester,
    ) async {
      final p = await spent();
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(
        app(
          p,
          s,
          SpendingHeatmap(
            month: month,
            bills: [
              DueBill(due: DateTime(2026, 9, 25), label: 'Rent', amount: 18000),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('₹1.2K'), findsOneWidget);
      // The one bill day carries the dot.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).shape == BoxShape.circle,
        ),
        findsOneWidget,
      );

      // Screen readers get the tap too: the cell's label hides the InkWell.
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp(r'^25 '))),
        isSemantics(hasTapAction: true, isButton: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp(r'^12 '))),
        isSemantics(hasTapAction: false, isButton: false),
      );
      semantics.dispose();

      await tester.tap(find.bySemanticsLabel(RegExp(r'^25 .*1 bill due')));
      await tester.pumpAndSettle();
      expect(find.text('Due'), findsOneWidget);
      expect(find.text('Rent'), findsOneWidget);
    });

    testWidgets('a day with neither cannot be tapped', (tester) async {
      final p = await spent();
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(app(p, s, SpendingHeatmap(month: month)));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel(RegExp(r'^12 ')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('large text in a narrow screen does not overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await spent();
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 900),
            textScaler: TextScaler.linear(1.6),
          ),
          child: app(
            p,
            s,
            SpendingHeatmap(
              month: month,
              bills: [
                DueBill(due: DateTime(2026, 9, 10), label: 'Rent', amount: 1),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
