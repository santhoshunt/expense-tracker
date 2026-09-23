import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/widgets/glossy.dart';

/// The Add button folds to its icon while a list scrolls down and comes
/// back on the way up; folded or not, TalkBack can still press it.
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

    Matcher pressable() =>
        isSemantics(label: 'Add', isButton: true, hasTapAction: true);

    expect(find.text('Add'), findsOneWidget);
    expect(tester.getSemantics(find.byType(GlassButton)), pressable());

    // Mid-screen is the list (the header cards sit above it).
    await tester.dragFrom(const Offset(400, 420), const Offset(0, -300));
    await settle(tester);
    expect(find.text('Add'), findsNothing, reason: 'folded to its icon');
    expect(
      tester.getSemantics(find.byType(GlassButton)),
      pressable(),
      reason: 'still named and pressable when folded',
    );

    await tester.dragFrom(const Offset(400, 300), const Offset(0, 200));
    await settle(tester);
    expect(find.text('Add'), findsOneWidget);
    semantics.dispose();
  });
}
