import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show Importance;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/notification_service.dart';

Widget app(FinanceProvider provider) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: provider),
    ChangeNotifierProvider(create: (_) => SettingsProvider()),
    Provider<DriveBackupService>(create: (_) => DriveBackupService()),
  ],
  child: const MaterialApp(home: HomeScreen()),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => NotificationService.statusOverride = null);

  group('notificationStatusFrom', () {
    test(
      'init failure and a null platform answer are unavailable, not blocked',
      () {
        expect(
          notificationStatusFrom(
            initFailed: true,
            appEnabled: true,
            channelImportance: null,
          ),
          NotificationStatus.unavailable,
        );
        expect(
          notificationStatusFrom(
            initFailed: false,
            appEnabled: null,
            channelImportance: null,
          ),
          NotificationStatus.unavailable,
        );
      },
    );

    test('app switch off is appBlocked; muted channel is channelBlocked', () {
      expect(
        notificationStatusFrom(
          initFailed: false,
          appEnabled: false,
          channelImportance: Importance.high,
        ),
        NotificationStatus.appBlocked,
      );
      expect(
        notificationStatusFrom(
          initFailed: false,
          appEnabled: true,
          channelImportance: Importance.none,
        ),
        NotificationStatus.channelBlocked,
      );
    });

    test('enabled with a live channel or no channel yet', () {
      expect(
        notificationStatusFrom(
          initFailed: false,
          appEnabled: true,
          channelImportance: Importance.high,
        ),
        NotificationStatus.enabled,
      );
      expect(
        notificationStatusFrom(
          initFailed: false,
          appEnabled: true,
          channelImportance: null,
        ),
        NotificationStatus.enabled,
      );
    });
  });

  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<FinanceProvider> withBudget() async {
    final p = FinanceProvider();
    await p.load();
    // A custom budget makes "hasCap" true; alerts default to on.
    await p.addBudget(
      name: 'Eating out',
      limit: 2000,
      mode: BudgetMode.include,
      categoryIds: {'food'},
    );
    return p;
  }

  testWidgets('app-level block explains the settings path and offers Request', (
    tester,
  ) async {
    NotificationService.statusOverride = () async =>
        NotificationStatus.appBlocked;
    final p = await withBudget();
    await tester.pumpWidget(app(p));
    await tester.tap(find.byTooltip('Settings'));
    await pumpThrough(tester);
    final hint = find.textContaining('turned off for this app');
    await tester.scrollUntilVisible(
      hint,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(hint, findsOneWidget);
    expect(find.text('Request'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
  });

  testWidgets('plugin failure is reported as such, with no button', (
    tester,
  ) async {
    NotificationService.statusOverride = () async =>
        NotificationStatus.unavailable;
    final p = await withBudget();
    await tester.pumpWidget(app(p));
    await tester.tap(find.byTooltip('Settings'));
    await pumpThrough(tester);
    final hint = find.textContaining('could not be initialised');
    await tester.scrollUntilVisible(
      hint,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(hint, findsOneWidget);
    expect(find.text('Request'), findsNothing);
  });

  testWidgets('enabled shows no warning row', (tester) async {
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
    final p = await withBudget();
    await tester.pumpWidget(app(p));
    await tester.tap(find.byTooltip('Settings'));
    await pumpThrough(tester);
    await tester.scrollUntilVisible(
      find.text('Budget alerts'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await pumpThrough(tester);
    expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);
  });
}
