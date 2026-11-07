import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/app_nav.dart';

import 'accounts_test_utils.dart';

/// v2.1.0 Card cycle widget taps on Accounts: a card far down the Cards
/// page is scrolled into view, and a tap while Accounts already shows does
/// not wait for the next touch. Invented card names only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The provider and the new cards' ids.
  Future<(FinanceProvider, List<String>)> withCards(int n) async {
    final p = FinanceProvider();
    await p.load();
    final cards = [
      for (var i = 1; i <= n; i++)
        await p.addAccount(name: 'Card $i', type: AccountType.creditCard),
    ];
    return (p, cards);
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('the last of eight open cards is scrolled into view', (
    tester,
  ) async {
    phone(tester);
    final (p, cards) = await withCards(8);
    await tester.pumpWidget(accountsApp(p));
    await tester.pumpAndSettle();
    final last = find.text('Card 8').hitTestable();
    expect(last, findsNothing, reason: 'starts below the fold');

    AppNav.instance.showAccountCard(cards.last);
    await tester.pumpAndSettle();
    expect(last, findsOneWidget);
  });

  testWidgets('a tap arriving after its frame asks for the next one', (
    tester,
  ) async {
    phone(tester);
    final (p, cards) = await withCards(8);
    await tester.pumpWidget(accountsApp(p));
    await tester.pumpAndSettle();
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);

    // Home runs showAccountCard in a frame's post-frame phase.
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => AppNav.instance.showAccountCard(cards.last),
    );
    SchedulerBinding.instance.scheduleFrame();
    await tester.pump();
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue);

    await tester.pumpAndSettle();
    expect(find.text('Card 8').hitTestable(), findsOneWidget);
  });
}
