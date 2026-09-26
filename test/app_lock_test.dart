import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/app_lock_service.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';

class FakeLock extends AppLockService {
  bool supported = true;
  bool result = false;

  /// When set, what the next attempts end in; otherwise [result] decides
  /// between success and a plain failure.
  UnlockOutcome? outcome;
  int attempts = 0;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<UnlockOutcome> unlock() async {
    attempts++;
    return outcome ?? (result ? UnlockOutcome.success : UnlockOutcome.failed);
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

  group('what an unlock attempt reports', () {
    Future<UnlockOutcome> throwing(LocalAuthExceptionCode code) =>
        AppLockService.runUnlock(
          () async => throw LocalAuthException(code: code),
        );

    test('true and false', () async {
      expect(
        await AppLockService.runUnlock(() async => true),
        UnlockOutcome.success,
      );
      expect(
        await AppLockService.runUnlock(() async => false),
        UnlockOutcome.failed,
      );
    });

    test('local_auth 3 throws on a cancel or a lockout', () async {
      for (final code in [
        LocalAuthExceptionCode.userCanceled,
        LocalAuthExceptionCode.systemCanceled,
        LocalAuthExceptionCode.timeout,
        LocalAuthExceptionCode.authInProgress,
        LocalAuthExceptionCode.userRequestedFallback,
      ]) {
        expect(await throwing(code), UnlockOutcome.cancelled, reason: '$code');
      }
      expect(
        await throwing(LocalAuthExceptionCode.temporaryLockout),
        UnlockOutcome.lockedOut,
      );
      expect(
        await throwing(LocalAuthExceptionCode.biometricLockout),
        UnlockOutcome.lockedOut,
      );
      expect(
        await throwing(LocalAuthExceptionCode.noCredentialsSet),
        UnlockOutcome.noScreenLock,
      );
      expect(
        await throwing(LocalAuthExceptionCode.deviceError),
        UnlockOutcome.failed,
      );
    });

    test('only a missing screen lock lets the app open unprompted', () async {
      for (final code in LocalAuthExceptionCode.values) {
        final outcome = await throwing(code);
        expect(
          outcome == UnlockOutcome.noScreenLock,
          code == LocalAuthExceptionCode.noCredentialsSet,
          reason: '$code',
        );
        expect(outcome, isNot(UnlockOutcome.success), reason: '$code');
      }
    });

    test('a channel error is a plain failure', () async {
      expect(
        await AppLockService.runUnlock(
          () async => throw PlatformException(code: 'x'),
        ),
        UnlockOutcome.failed,
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
      expect(appLocked.value, isFalse, reason: 'launch actions may run');
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
      expect(appLocked.value, isTrue);

      lock.result = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('CONTENT'), findsOneWidget);
      expect(lock.attempts, 2);
      expect(appLocked.value, isFalse);
    });

    testWidgets('a re-lock covers popups over the page and unlocking '
        'returns to them', (tester) async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled_v1': true});
      final settings = SettingsProvider();
      await settings.load();
      final lock = FakeLock()..result = true;
      var now = DateTime(2026, 9, 1, 12);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            // As in main.dart: around the Navigator, so every route is
            // behind the lock screen.
            builder: (context, child) =>
                LockGate(service: lock, clock: () => now, child: child!),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(content: Text('POPUP')),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('POPUP'), findsOneWidget);

      // Away for 3 minutes, then back: locked, and the popup is hidden.
      lock.result = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.text('POPUP'), findsNothing);
      expect(appLocked.value, isTrue, reason: 'the re-lock is announced');

      // Unlocking brings back the same page with the popup still open.
      lock.result = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('POPUP'), findsOneWidget);
      expect(find.text('Unlock'), findsNothing);
      expect(appLocked.value, isFalse);
    });

    testWidgets('a lockout says why; the next success clears it', (
      tester,
    ) async {
      final lock = FakeLock()..outcome = UnlockOutcome.lockedOut;
      SharedPreferences.setMockInitialValues({'app_lock_enabled_v1': true});
      final settings = SettingsProvider();
      await settings.load();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            home: LockGate(service: lock, child: const Text('CONTENT')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      const line = 'Too many fingerprint attempts. Unlock with your PIN.';
      expect(find.text(line), findsOneWidget);
      expect(find.text('CONTENT'), findsNothing);

      lock.outcome = UnlockOutcome.success;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('CONTENT'), findsOneWidget);
      expect(find.text(line), findsNothing);
    });

    testWidgets('a plain failure asks to try again', (tester) async {
      await pumpGate(tester, enabled: true);
      expect(find.text('Unlock'), findsOneWidget);
      expect(
        find.text("Couldn't check your fingerprint or PIN. Try again."),
        findsOneWidget,
      );
    });

    testWidgets('a cancel stays locked and says nothing', (tester) async {
      final (lock, _) = await pumpGate(tester, enabled: true);
      lock.outcome = UnlockOutcome.cancelled;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.textContaining('Too many'), findsNothing);
      expect(find.textContaining("Couldn't check"), findsNothing);
    });

    testWidgets('no screen lock left opens the app, says why, keeps the '
        'setting', (tester) async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled_v1': true});
      final settings = SettingsProvider();
      await settings.load();
      final lock = FakeLock()..outcome = UnlockOutcome.noScreenLock;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            builder: (context, child) => LockGate(service: lock, child: child!),
            home: const Scaffold(body: Text('CONTENT')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('CONTENT'), findsOneWidget);
      expect(appLocked.value, isFalse);
      expect(find.textContaining('needs a screen lock'), findsOneWidget);
      expect(settings.appLock, isTrue, reason: 'back once a lock exists');
    });

    testWidgets('waits for settings to load before deciding', (tester) async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled_v1': true});
      final settings = SettingsProvider();
      final lock = FakeLock();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            builder: (context, child) => LockGate(service: lock, child: child!),
            home: const Text('CONTENT'),
          ),
        ),
      );
      expect(lock.attempts, 0, reason: 'preference not known yet');
      await settings.load();
      await tester.pumpAndSettle();
      expect(lock.attempts, 1);
      expect(find.text('CONTENT'), findsNothing);
      expect(find.text('Unlock'), findsOneWidget);
    });
  });
}
