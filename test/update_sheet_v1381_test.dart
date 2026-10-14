import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/update_downloader.dart';
import 'package:expense_tracker/services/update_installer.dart';
import 'package:expense_tracker/services/update_service.dart';
import 'package:expense_tracker/widgets/update_sheet.dart';

ReleaseOption opt(String tag) => ReleaseOption(
  tag: tag,
  publishedAt: DateTime(2026, 10, 14),
  sizeBytes: 62 * 1024 * 1024,
  notes: 'What changed in $tag',
  downloadUrl: UpdateService.assetUrlFor(tag),
);

class _Installer implements UpdateInstaller {
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> openInstallSettings() async {}
  @override
  Future<String?> install(File apk) async => null;
}

class _Downloader extends UpdateDownloader {
  @override
  Future<File> download(
    ReleaseOption option, {
    void Function(int received, int total)? onProgress,
    DownloadCancel? cancel,
  }) async => File('${option.tag}.apk');

  @override
  Future<void> cleanup() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openSheet(WidgetTester tester, UpdateList updates) async {
    final settings = SettingsProvider();
    await settings.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showUpdateSheet(
                  context,
                  updates,
                  installer: _Installer(),
                  downloader: _Downloader(),
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
  }

  test('versions are written one way', () {
    expect(versionLabel('1.38.0'), 'v1.38.0');
    expect(versionLabel('v1.38.1'), 'v1.38.1');
    expect(versionLabel('V1.38.1'), 'v1.38.1');
  });

  testWidgets('one version: the title names it, its notes are open, and the '
      'installed version reads the same way', (tester) async {
    await openSheet(tester, UpdateList('1.38.0', [opt('v1.38.1')]));
    expect(find.text('Update to v1.38.1'), findsOneWidget);
    expect(find.text('Choose a version'), findsNothing);
    expect(find.text('On v1.38.0'), findsOneWidget);
    expect(find.text('On 1.38.0'), findsNothing);
    expect(find.text('What changed in v1.38.1'), findsOneWidget);
    expect(find.byTooltip('Hide notes'), findsOneWidget);

    // The notes still close.
    await tester.tap(find.byTooltip('Hide notes'));
    await tester.pump();
    expect(find.text('What changed in v1.38.1'), findsNothing);
  });

  testWidgets('one version has no radio; the notes line up with the version '
      'label', (tester) async {
    await openSheet(tester, UpdateList('1.38.0', [opt('v1.38.1')]));
    expect(find.byType(Radio<String>), findsNothing);
    expect(
      tester.getTopLeft(find.text('What changed in v1.38.1')).dx,
      tester.getTopLeft(find.text('v1.38.1')).dx,
    );
  });

  testWidgets('several versions: the open notes line up with the label', (
    tester,
  ) async {
    await openSheet(
      tester,
      UpdateList('1.37.0', [opt('v1.38.1'), opt('v1.38.0')]),
    );
    expect(find.byType(Radio<String>), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('What changed in v1.38.1')).dx,
      tester.getTopLeft(find.text('v1.38.1')).dx,
    );
  });

  testWidgets('the one-version title fits 320dp at 2x text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await openSheet(tester, UpdateList('1.38.0', [opt('v1.38.1')]));
    expect(tester.takeException(), isNull);
    expect(find.text('Update to v1.38.1'), findsOneWidget);
    expect(find.text('On v1.38.0'), findsOneWidget);
  });

  testWidgets('several versions: choose, with only the newest notes open', (
    tester,
  ) async {
    await openSheet(
      tester,
      UpdateList('1.37.0', [opt('v1.38.1'), opt('v1.38.0')]),
    );
    expect(find.text('Choose a version'), findsOneWidget);
    expect(find.text('On v1.37.0'), findsOneWidget);
    expect(find.text('What changed in v1.38.1'), findsOneWidget);
    expect(find.text('What changed in v1.38.0'), findsNothing);
    expect(find.text('v1.38.1'), findsOneWidget);
    expect(find.text('v1.38.0'), findsOneWidget);
  });
}
