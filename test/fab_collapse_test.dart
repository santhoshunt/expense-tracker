import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/home_app_bar.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/widgets/glossy.dart';

/// v1.43.0: the Add button is a round button docked in a notch at the nav
/// bar's right end. It no longer folds while a list scrolls; TalkBack and
/// a long-press name it by its tooltip.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('Add docks in the bar notch, clear of the tabs, and stays put '
      'while the list scrolls', (tester) async {
    final semantics = tester.ensureSemantics();
    final finance = FinanceProvider();
    await finance.load();
    final now = DateTime.now();
    for (var i = 0; i < 40; i++) {
      await finance.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100.0 + i,
        note: 'row $i',
        date: DateTime(now.year, now.month, 1),
      );
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Transactions').last);
    await settle(tester);

    Matcher pressable(String label) =>
        isSemantics(label: label, isButton: true, hasTapAction: true);

    final add = find.byType(GlassRoundButton);
    expect(add, findsOneWidget);
    expect(tester.getSemantics(add), pressable('Add transaction'));
    expect(tester.getSize(add), const Size(56, 56));
    // Docked: its centre sits on the bar's top edge, in the bar's right
    // end, and no tab lies under it.
    final bar = tester.getRect(find.byType(BottomAppBar));
    final button = tester.getRect(add);
    expect(button.center.dy, moreOrLessEquals(bar.top, epsilon: 1));
    expect(button.left, greaterThan(bar.right - 88));
    expect(
      tester.getRect(find.byType(NavigationBar)).right,
      lessThanOrEqualTo(bar.right - 88 + 0.5),
    );

    // Mid-screen is the list.
    await tester.dragFrom(const Offset(400, 420), const Offset(0, -300));
    await settle(tester);
    expect(tester.getRect(add), button, reason: 'no fold while scrolling');
    expect(tester.getSemantics(add), pressable('Add transaction'));

    // On Accounts the same button adds an account.
    await tester.tap(find.text('Accounts').last);
    await settle(tester);
    expect(tester.getSemantics(add), pressable('New account'));
    semantics.dispose();
  });

  testWidgets('Android back retraces tab switches before leaving the app', (
    tester,
  ) async {
    final finance = FinanceProvider();
    await finance.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await settle(tester);
    Future<void> systemBack() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/navigation',
        const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
        (_) {},
      );
      await settle(tester);
    }

    // The Dashboard's title is its month selector; the other tabs show
    // their name.
    String title() =>
        find
            .descendant(
              of: find.byType(AppBar),
              matching: find.byType(DashboardMonthTitle),
            )
            .evaluate()
            .isNotEmpty
        ? 'Dashboard'
        : tester
              .widget<Text>(
                find
                    .descendant(
                      of: find.byType(AppBar),
                      matching: find.byType(Text),
                    )
                    .first,
              )
              .data!;

    expect(title(), 'Dashboard');
    await tester.tap(find.text('Transactions').last);
    await settle(tester);
    await tester.tap(find.text('Accounts').last);
    await settle(tester);
    expect(title(), 'Accounts');

    await systemBack();
    expect(title(), 'Transactions');
    await systemBack();
    expect(title(), 'Dashboard');
    // Nothing left to retrace: back now reaches the system, which closes
    // the app, and the tab stays put.
    final platformCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await systemBack();
    expect(title(), 'Dashboard');
    expect(platformCalls, contains('SystemNavigator.pop'));
  });
}
