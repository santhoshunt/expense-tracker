import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/utils/format.dart';

import 'dashboard_test_utils.dart';

/// The Trends comparison chart sheet and the collapsible account cards.
/// Amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<void> pump(
    WidgetTester tester,
    FinanceProvider p,
    Widget home, {
    Size size = const Size(400, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = SettingsProvider();
    await s.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(body: home),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<FinanceProvider> ledger() async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 900,
      note: 'last month',
      date: DateTime(now.year, now.month - 1, 1),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 400,
      note: 'this month',
      // Midnight on the 1st: never ahead of the clock.
      date: DateTime(now.year, now.month, 1),
    );
    return p;
  }

  for (final (width, scale) in [(400.0, 1.0), (320.0, 2.0)]) {
    testWidgets('a comparison card opens the chart, ${width}dp x$scale', (
      tester,
    ) async {
      final p = await ledger();
      await pump(
        tester,
        p,
        const DashboardScreen(),
        size: Size(width, 900),
        textScale: scale,
      );
      await openDashboardView(tester, 'Trends');
      await openDashboardSection(tester, 'previousMonth');
      final see = find.text('See chart').first;
      await tester.ensureVisible(see);
      await tester.pumpAndSettle();
      await tester.tap(see);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('This month vs'), findsOneWidget);
      // The Forecast key shows only with an everyday estimate (the card's
      // too): this ledger's thin history has none, which the series tests
      // cover.
      expect(find.text('This month'), findsOneWidget);
    });
  }

  group('account cards', () {
    Future<FinanceProvider> accounts() async {
      final p = FinanceProvider();
      await p.load();
      final bank = await p.addAccount(name: 'HDFC', type: AccountType.bank);
      await p.setManualBalance(bank, 52340);
      final card = await p.addAccount(
        name: 'ICICI Card',
        type: AccountType.creditCard,
        creditLimit: 100000,
      );
      await p.setManualBalance(card, 12062);
      return p;
    }

    testWidgets('start collapsed: a name and one figure', (tester) async {
      final p = await accounts();
      String? opened;
      await pump(
        tester,
        p,
        AccountsScreen(onViewAccount: (id) => opened = id),
        size: const Size(400, 1400),
      );
      expect(find.text(fmtMoney(52340)), findsWidgets);
      expect(find.text('${fmtMoney(12062)} due'), findsOneWidget);
      expect(
        find.widgetWithText(TextButton, 'View transactions').hitTestable(),
        findsNothing,
      );

      // A tap opens the card, and it stays open after a rebuild.
      await tester.tap(find.text('HDFC'));
      await tester.pumpAndSettle();
      final view = find.widgetWithText(TextButton, 'View transactions');
      expect(view.hitTestable(), findsOneWidget);
      final s = tester
          .element(find.byType(AccountsScreen))
          .read<SettingsProvider>();
      expect(s.isAccountExpanded(p.accounts.first.id), isTrue);
      await tester.tap(view.hitTestable());
      await tester.pumpAndSettle();
      expect(opened, p.accounts.first.id);
    });

    testWidgets('collapsed cards fit 320dp at text x2', (tester) async {
      final p = await accounts();
      await pump(
        tester,
        p,
        AccountsScreen(onViewAccount: (_) {}),
        size: const Size(320, 1400),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
