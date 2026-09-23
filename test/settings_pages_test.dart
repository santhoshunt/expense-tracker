import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';

/// The Settings root lists its groups, and each group opens its own page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Bounded pumps: the Drive section on Backup and data keeps an
  /// indeterminate progress bar up while the sign-in state loads (never
  /// resolves under tests), so pumpAndSettle would time out, also while
  /// that page pops.
  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    final finance = FinanceProvider();
    await finance.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpThrough(tester);
  }

  testWidgets('root lists the groups and each opens its page', (tester) async {
    await pumpSettings(tester);

    // Group title to a heading near the top of its page. Widget tests run as
    // Android, so the SMS group is offered.
    const pages = {
      'Appearance': 'Dark theme',
      'SMS import': 'Automatic SMS import',
      'Backup and data': 'Cloud backup',
      'Privacy': 'App lock',
      'Categories and rules': 'Category order',
      'About': 'Check for updates',
    };
    for (final title in pages.keys) {
      expect(find.text(title), findsOneWidget, reason: title);
    }

    for (final MapEntry(key: title, value: heading) in pages.entries) {
      await tester.tap(find.text(title));
      await pumpThrough(tester);
      expect(find.widgetWithText(AppBar, title), findsOneWidget);
      expect(find.text(heading), findsOneWidget, reason: title);

      await tester.pageBack();
      await pumpThrough(tester);
      expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    }
  });

  testWidgets('Move glow with tilt switch toggles the setting', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Appearance'));
    await pumpThrough(tester);

    const label = 'Move glow with tilt';
    await tester.scrollUntilVisible(
      find.text(label),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    final toggle = find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
      matching: find.byType(Switch),
    );
    final settings = tester
        .element(find.byType(SettingsGroupPage))
        .read<SettingsProvider>();
    expect(settings.tiltGlow, isTrue, reason: 'on by default');
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await pumpThrough(tester);
    expect(settings.tiltGlow, isFalse);
    // The pushed page watches the provider itself, so the switch follows.
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await pumpThrough(tester);
    expect(settings.tiltGlow, isTrue);
  });
}
