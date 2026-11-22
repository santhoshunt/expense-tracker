import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/update_downloader.dart';
import 'package:expense_tracker/services/update_installer.dart';
import 'package:expense_tracker/services/update_service.dart';
import 'package:expense_tracker/widgets/update_sheet.dart';

ReleaseOption _opt(String tag) => ReleaseOption(
  tag: tag,
  publishedAt: DateTime(2026, 4, 3),
  sizeBytes: 57 * 1024 * 1024,
  notes: 'What changed in $tag',
  downloadUrl: UpdateService.assetUrlFor(tag),
);

class _Installer implements UpdateInstaller {
  /// The answers to canInstall, in turn; the last one repeats. An
  /// Exception is thrown instead of returned.
  final List<Object> answers;

  /// When set, install waits for it.
  Completer<String?>? pending;
  int installs = 0;

  _Installer(this.answers);

  @override
  Future<bool> canInstall() async {
    final a = answers.length > 1 ? answers.removeAt(0) : answers.first;
    if (a is Exception) throw a;
    return a as bool;
  }

  @override
  Future<void> openInstallSettings() async {}

  @override
  Future<String?> install(File apk) async {
    installs++;
    return pending?.future;
  }
}

class _Downloader extends UpdateDownloader {
  int cleanups = 0;

  @override
  Future<File> download(
    ReleaseOption option, {
    void Function(int received, int total)? onProgress,
    DownloadCancel? cancel,
  }) async => File('${option.tag}.apk');

  @override
  Future<void> cleanup() async => cleanups++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  // A case that leaves the app in the background would stall the next
  // case's install on the wait for the app to come back.
  tearDown(
    () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    ),
  );

  Future<GlobalKey<NavigatorState>> openSheet(
    WidgetTester tester,
    _Installer installer,
    _Downloader downloader,
  ) async {
    final settings = SettingsProvider();
    await settings.load();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          navigatorKey: nav,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showUpdateSheet(
                  context,
                  UpdateList('1.40.0', [_opt('v1.41.0')]),
                  installer: installer,
                  downloader: downloader,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return nav;
  }

  Future<void> tapButton(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
  }

  testWidgets('a permission check that throws leaves the sheet usable', (
    tester,
  ) async {
    final installer = _Installer([
      false,
      PlatformException(code: 'channel-gone'),
    ]);
    await openSheet(tester, installer, _Downloader());
    await tapButton(tester, 'Download & install');
    await tester.pumpAndSettle();
    expect(find.textContaining('Android needs your OK first'), findsOneWidget);

    // Back from the system settings page, and the check throws.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('Android needs your OK first'), findsOneWidget);

    await tapButton(tester, 'Back');
    await tester.pumpAndSettle();
    // The check throws on the tap too: the sheet explains the switch again.
    await tapButton(tester, 'Download & install');
    await tester.pumpAndSettle();
    expect(find.textContaining('Android needs your OK first'), findsOneWidget);
  });

  testWidgets('the sheet closes itself, not a page pushed over it', (
    tester,
  ) async {
    final installer = _Installer([true])..pending = Completer<String?>();
    final nav = await openSheet(tester, installer, _Downloader());
    await tapButton(tester, 'Download & install');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(installer.installs, 1);

    // A home-screen widget opens a page while the install runs.
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Pushed page')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    installer.pending!.complete(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Pushed page'), findsOneWidget);
    expect(find.byType(UpdateSheet, skipOffstage: false), findsNothing);
  });

  testWidgets('closing the sheet while it waits for the app to come back '
      'still clears the download', (tester) async {
    final installer = _Installer([true]);
    final downloader = _Downloader();
    final nav = await openSheet(tester, installer, downloader);
    // The download finishes with the app in the background.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tapButton(tester, 'Download & install');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Checking and installing'), findsOneWidget);

    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byType(UpdateSheet), findsNothing);
    expect(downloader.cleanups, 1);
    expect(installer.installs, 0);
  });
}
