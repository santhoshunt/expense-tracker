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

/// The Add button floats over the page above a full-width bar. It folds to
/// its icon while a list scrolls down and comes back on the way up; folded
/// or not, TalkBack can still press it. (v1.43.0 docked it in a notch;
/// v1.43.1 puts the floating button back.)
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

  testWidgets('scrolling the Transactions list folds and unfolds Add', (
    tester,
  ) async {
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

    expect(find.text('Add'), findsOneWidget);
    expect(tester.getSemantics(find.byType(GlassButton)), pressable('Add'));
    // Above the bar, which spans the full width again.
    final bar = tester.getRect(find.byType(NavigationBar));
    expect(tester.getRect(find.byType(GlassButton)).bottom, lessThan(bar.top));
    expect(
      bar.width,
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
    );

    // Mid-screen is the list (the header cards sit above it).
    await tester.dragFrom(const Offset(400, 420), const Offset(0, -300));
    await settle(tester);
    expect(find.text('Add'), findsNothing, reason: 'folded to its icon');
    expect(
      tester.getSemantics(find.byType(GlassButton)),
      pressable('Add'),
      reason: 'still named and pressable when folded',
    );

    await tester.dragFrom(const Offset(400, 300), const Offset(0, 200));
    await settle(tester);
    expect(find.text('Add'), findsOneWidget);

    // On Accounts the same button adds an account, unfolded again.
    await tester.tap(find.text('Accounts').last);
    await settle(tester);
    expect(find.text('New account'), findsOneWidget);
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
