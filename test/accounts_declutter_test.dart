import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/glossy.dart';
import 'package:expense_tracker/widgets/grouped_surface.dart';

import 'accounts_test_utils.dart';

/// The 1.37 Accounts layout: type pills, one surface per section, and the
/// account options under More in the open card.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  /// The Accounts screen with every card folded.
  Widget foldedApp(FinanceProvider p) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider.value(value: SettingsProvider()),
    ],
    child: MaterialApp(
      home: Scaffold(body: AccountsScreen(onViewAccount: (_) {})),
    ),
  );

  testWidgets('a folded row has no options button; open, More holds the '
      'account menu', (tester) async {
    final p = await loaded();
    await p.addAccount(name: 'HDFC', type: AccountType.bank);
    await tester.pumpWidget(foldedApp(p));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.more_vert), findsNothing);
    // The open card's content stays mounted at zero height while folded.
    expect(find.byTooltip('Account options').hitTestable(), findsNothing);
    expect(find.text('More').hitTestable(), findsNothing);

    await tester.tap(find.text('HDFC'));
    await tester.pumpAndSettle();
    expect(find.text('View transactions').hitTestable(), findsOneWidget);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Set balance…'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);

    // An item runs as it did from the old menu.
    await tester.tap(find.text('Set balance…'));
    await tester.pumpAndSettle();
    expect(find.text('Current balance'), findsOneWidget);
  });

  testWidgets('the type pills switch the list, and a swipe moves the pill', (
    tester,
  ) async {
    final p = await loaded();
    await p.addAccount(name: 'HDFC', type: AccountType.bank);
    await p.addAccount(name: 'Visa', type: AccountType.creditCard);
    await tester.pumpWidget(foldedApp(p));
    await tester.pumpAndSettle();

    expect(find.byType(ChipTabs<AccountType?>), findsOneWidget);
    expect(find.text('HDFC'), findsOneWidget);
    expect(find.text('Visa'), findsOneWidget);

    await tester.tap(find.text('Cards'));
    await tester.pumpAndSettle();
    expect(find.text('Visa'), findsOneWidget);
    expect(find.text('HDFC'), findsNothing);
    // The pill's own node, which carries its label and selected state.
    bool selected(String label) =>
        tester
            .widgetList<Semantics>(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(Semantics),
              ),
            )
            .firstWhere((s) => s.properties.label == label)
            .properties
            .selected ??
        false;
    expect(selected('Cards'), isTrue);
    expect(selected('All'), isFalse);

    // Swiping back to Banks moves the selection with the page.
    await tester.fling(find.text('Visa'), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('HDFC'), findsOneWidget);
    expect(selected('Banks'), isTrue);
    expect(selected('Cards'), isFalse);
  });

  testWidgets('accounts of one type draw as one surface, rounded at the ends', (
    tester,
  ) async {
    final p = await loaded();
    for (final name in ['Bank A', 'Bank B', 'Bank C']) {
      await p.addAccount(name: name, type: AccountType.bank);
    }
    await p.addAccount(name: 'Visa', type: AccountType.creditCard);
    await tester.pumpWidget(foldedApp(p));
    await tester.pumpAndSettle();

    final rows = tester
        .widgetList<GroupedSurface>(find.byType(GroupedSurface))
        .map((s) => (s.first, s.last))
        .toList();
    // Banks: three rows in one run; Credit cards: a run of one.
    expect(rows, [(true, false), (false, false), (false, true), (true, true)]);
  });

  testWidgets('figures are in the plain text colour', (tester) async {
    final p = await loaded();
    final card = await p.addAccount(name: 'Visa', type: AccountType.creditCard);
    await p.setManualBalance(card, 12000);
    await tester.pumpWidget(accountsApp(p));
    await tester.pumpAndSettle();

    final scheme = Theme.of(
      tester.element(find.byType(AccountsScreen)),
    ).colorScheme;
    final figures = tester.widgetList<Text>(find.text(fmtMoney(12000)));
    expect(figures, isNotEmpty);
    for (final t in figures) {
      expect(t.style?.color, isNot(scheme.error));
    }
    expect(
      figures.where((t) => t.style?.color == scheme.onSurface),
      isNotEmpty,
      reason: 'the open card shows the outstanding in onSurface',
    );
  });
}
