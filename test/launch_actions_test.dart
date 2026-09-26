import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';
import 'package:expense_tracker/widgets/monthly_recap_card.dart';

/// Shortcut, tile and notification actions: they wait for the app lock,
/// run once, and land on top of whatever is open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    LaunchActions.instance.resetForTest();
    appLocked.value = false;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(LaunchActions.channel, null);
    LaunchActions.instance.resetForTest();
    appLocked.value = true;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    Future<void> Function(FinanceProvider)? seed,
  }) async {
    final finance = FinanceProvider();
    await finance.load();
    await seed?.call(finance);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await settle(tester);
  }

  // The add sheet's amount field.
  final addSheet = find.widgetWithText(TextFormField, 'Amount');

  testWidgets('a cold-start action waits for unlock, then runs once', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      LaunchActions.channel,
      (call) async => call.method == 'takeLaunchAction' ? 'add_expense' : null,
    );
    appLocked.value = true;
    await LaunchActions.instance.init();
    expect(LaunchActions.instance.pending.value, LaunchAction.addExpense);

    await pumpHome(tester);
    expect(addSheet, findsNothing, reason: 'still locked');

    appLocked.value = false;
    await settle(tester);
    expect(addSheet, findsOneWidget);
    expect(LaunchActions.instance.pending.value, isNull);

    // Closing the sheet and relocking does not replay it.
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    appLocked.value = true;
    appLocked.value = false;
    await settle(tester);
    expect(addSheet, findsNothing);
  });

  testWidgets('a warm launch from the native side opens the sheet', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      LaunchActions.channel,
      (call) async => null,
    );
    await LaunchActions.instance.init();
    await pumpHome(tester);
    expect(addSheet, findsNothing);

    await messenger.handlePlatformMessage(
      LaunchActions.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('launchAction', 'add_expense'),
      ),
      (_) {},
    );
    await settle(tester);
    expect(addSheet, findsOneWidget);
  });

  testWidgets('the sheet opens over an open page, which stays', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    expect(find.text('Appearance'), findsOneWidget);

    LaunchActions.instance.pending.value = LaunchAction.addExpense;
    await settle(tester);
    expect(addSheet, findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget, reason: 'not popped');
  });

  group('the recap notification', () {
    final now = DateTime.now();
    tearDown(() => recapClock = DateTime.now);

    Future<void> seed(FinanceProvider p) async {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 250,
        note: 'this month',
        date: DateTime(now.year, now.month, 1),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 400,
        note: 'last month',
        date: DateTime(now.year, now.month - 1, 2),
      );
    }

    /// Leaves the Dashboard on Trends, goes to Transactions, then taps the
    /// note: the view it lands on is the one the note chose.
    Future<void> tapNotification(WidgetTester tester) async {
      await pumpHome(tester, seed: seed);
      await tester.tap(find.text('Trends'));
      await settle(tester);
      await tester.tap(find.text('Transactions').last);
      await settle(tester);
      expect(find.text('Breakdown'), findsNothing);

      LaunchActions.instance.onNotificationPayload(kRecapPayload);
      await settle(tester);
      expect(
        find.text('Breakdown'),
        findsOneWidget,
        reason: 'on the Dashboard',
      );
      expect(LaunchActions.instance.pending.value, isNull);
    }

    testWidgets('in the recap week opens the recap on the Overview', (
      tester,
    ) async {
      recapClock = () => DateTime(now.year, now.month, 3, 10);
      await tapNotification(tester);
      // Back from Trends: its comparison is gone, the recap is showing.
      expect(find.text('This month vs last month'), findsNothing);
      expect(find.byType(MonthlyRecapCard), findsOneWidget);
    });

    testWidgets('after it opens this month so far on Trends', (tester) async {
      recapClock = () => DateTime(now.year, now.month, 20, 10);
      await tapNotification(tester);
      expect(find.byType(MonthPaceCard), findsOneWidget);
      expect(find.text('This month vs last month'), findsOneWidget);
    });
  });

  test('unknown native names and payloads are ignored', () {
    expect(LaunchActions.fromName('add_expense'), LaunchAction.addExpense);
    expect(LaunchActions.fromName('import_sms'), LaunchAction.importSms);
    expect(LaunchActions.fromName('delete_everything'), isNull);
    expect(LaunchActions.fromName(null), isNull);
    LaunchActions.instance.onNotificationPayload('budget');
    expect(LaunchActions.instance.pending.value, isNull);
  });
}
