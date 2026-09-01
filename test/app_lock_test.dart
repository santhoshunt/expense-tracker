import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/app_lock_service.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';

class FakeLock extends AppLockService {
  bool supported = true;
  bool result = false;
  int attempts = 0;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<bool> authenticate() async {
    attempts++;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shouldLock', () {
    final now = DateTime(2026, 9, 1, 12, 0);

    test('disabled never locks', () {
      expect(
        shouldLock(
          enabled: false,
          backgroundedAt: now.subtract(const Duration(hours: 1)),
          now: now,
        ),
        isFalse,
      );
    });

    test('never backgrounded never locks', () {
      expect(
        shouldLock(enabled: true, backgroundedAt: null, now: now),
        isFalse,
      );
    });

    test('a quick app switch stays unlocked', () {
      expect(
        shouldLock(
          enabled: true,
          backgroundedAt: now.subtract(const Duration(minutes: 1)),
          now: now,
        ),
        isFalse,
      );
    });

    test('away past the threshold re-locks', () {
      expect(
        shouldLock(
          enabled: true,
          backgroundedAt: now.subtract(const Duration(minutes: 3)),
          now: now,
        ),
        isTrue,
      );
      expect(
        shouldLock(
          enabled: true,
          backgroundedAt: now.subtract(const Duration(minutes: 2)),
          now: now,
        ),
        isTrue,
        reason: 'threshold itself counts',
      );
    });
  });

  group('LockGate', () {
    Future<(FakeLock, SettingsProvider)> pumpGate(
      WidgetTester tester, {
      required bool enabled,
      bool authResult = false,
    }) async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled_v1': enabled});
      final settings = SettingsProvider();
      await settings.load();
      final lock = FakeLock()..result = authResult;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            home: LockGate(service: lock, child: const Text('CONTENT')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (lock, settings);
    }

    testWidgets('disabled shows the child immediately, no prompt', (
      tester,
    ) async {
      final (lock, _) = await pumpGate(tester, enabled: false);
      expect(find.text('CONTENT'), findsOneWidget);
      expect(lock.attempts, 0);
    });

    testWidgets(
      'enabled starts locked and auto-prompts; failure stays locked',
      (tester) async {
        final (lock, _) = await pumpGate(tester, enabled: true);
        expect(lock.attempts, 1, reason: 'auto-attempt on start');
        expect(find.text('CONTENT'), findsNothing);
        expect(find.text('Unlock'), findsOneWidget);
      },
    );

    testWidgets('successful auto-attempt reveals the child', (tester) async {
      await pumpGate(tester, enabled: true, authResult: true);
      expect(find.text('CONTENT'), findsOneWidget);
    });

    testWidgets('retry via the Unlock button', (tester) async {
      final (lock, _) = await pumpGate(tester, enabled: true);
      expect(find.text('CONTENT'), findsNothing);

      lock.result = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('CONTENT'), findsOneWidget);
      expect(lock.attempts, 2);
    });
  });
}
