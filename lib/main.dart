import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/finance_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/home_screen.dart';
import 'services/drive_backup_service.dart';
import 'services/notification_service.dart';
import 'utils/app_theme.dart';
import 'widgets/keyboard_unfocus.dart';
import 'widgets/lock_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Log-and-continue for anything unhandled. Without the platform hook, a
  // single stray async error (a platform channel hiccup, an isolate death)
  // takes the whole app down; with it, the failure is logged and the UI
  // stays up — the data-layer guards surface anything that matters.
  FlutterError.onError = FlutterError.presentError;
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled: $error\n$stack');
    return true;
  };
  // Prepare the local-notifications channel up front; permission is requested
  // later, from Settings, when the user enables budget alerts. Best-effort:
  // a platform failure here must not stop the app from launching at all.
  try {
    await NotificationService.instance.init();
  } catch (e) {
    debugPrint('Notification init failed: $e');
  }
  runApp(const ExpenseTrackerApp());
}

class ExpenseTrackerApp extends StatelessWidget {
  const ExpenseTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => FinanceProvider()..load()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        // One shared instance: Home triggers the scheduled upload and the
        // cloud import; Settings owns connect/frequency/status.
        Provider<DriveBackupService>(create: (_) => DriveBackupService()),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) => MaterialApp(
          title: 'Expense Tracker',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: settings.accent,
          ),
          darkTheme: buildAppTheme(
            brightness: Brightness.dark,
            accent: settings.accent,
          ),
          themeMode: settings.mode,
          // Mode/accent changes cross-fade instead of snapping.
          themeAnimationDuration: const Duration(milliseconds: 400),
          themeAnimationCurve: Curves.easeOutCubic,
          // App-wide: kill the stray selection handle left behind when the
          // keyboard is minimized with the system gesture (field keeps focus,
          // handle keeps painting — see UnfocusOnKeyboardDismiss).
          builder: (context, child) =>
              UnfocusOnKeyboardDismiss(child: child ?? const SizedBox()),
          home: const _Root(),
        ),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final loaded =
        context.select<FinanceProvider, bool>((f) => f.loaded) &&
        context.select<SettingsProvider, bool>((s) => s.loaded);
    if (!loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Inside MaterialApp (theme, Navigator) and below the providers, so the
    // gate can read SettingsProvider and its lock screen is themed.
    return const LockGate(child: HomeScreen());
  }
}
