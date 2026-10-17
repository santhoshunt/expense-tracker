import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';

/// Settings, SMS import: the Capture RCS alerts row. Its own file, since
/// the row remembers the last access check for the whole test run.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('a tap waits for the access check, and the tip takes a 48dp '
      'target', (tester) async {
    const channel = MethodChannel('expense_tracker/sms');
    final access = Completer<bool>();
    var opened = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'notifHasAccess':
          return access.future;
        case 'notifOpenSettings':
          opened++;
          return null;
      }
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

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
    await tester.tap(find.text('SMS import'));
    await pumpThrough(tester);

    expect(
      tester.getSize(find.bySemanticsLabel('About Capture RCS alerts')),
      const Size(48, 48),
    );

    // Still checking: the tap opens nothing.
    await tester.tap(find.text('Capture RCS alerts'));
    await pumpThrough(tester);
    expect(opened, 0);

    // No access: the tap opens notification access.
    access.complete(false);
    await pumpThrough(tester);
    await tester.tap(find.text('Capture RCS alerts'));
    await pumpThrough(tester);
    expect(opened, 1);
  });
}
