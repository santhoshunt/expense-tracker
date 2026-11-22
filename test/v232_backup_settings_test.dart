import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The failing store below extends the plugin's in-memory store, which only
// the platform interface exports. shared_preferences brings it in.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/recurring_detector.dart';

/// The in-memory store, except that every write reports false while
/// [failWrites] is on, as Android's commit() does when it cannot write.
class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore() : super.empty();

  bool failWrites = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      failWrites ? false : super.setValue(valueType, key, value);
}

/// CSV export and import, settings writes and the restore's Auto-import
/// check. Every name, number and alert text is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FinanceProvider.useIsolateCodec = false;
  });

  const alertBody =
      'Rs.450.00 spent on card XX7731 at KETTLE NOOK on 05-09-26. '
      'Avl lmt Rs.20,000.00';

  Tx smsRow({String id = 's1', String body = alertBody, String merchant = ''}) =>
      Tx(
        id: id,
        type: TxType.expense,
        categoryId: 'food',
        amount: 450,
        note: '',
        smsBody: body,
        smsMerchant: merchant,
        date: DateTime(2026, 9, 5, 12),
        source: TxSource.sms,
        sender: 'VM-KTLBNK',
        acctKey: 'KTL:7731',
      );

  Tx manualRow(String id, {String note = 'tea', String? rewardGroup,
          DateTime? pickedAt, double? balanceAfter}) =>
      Tx(
        id: id,
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: note,
        date: DateTime(2026, 9, 6, 12),
        rewardGroup: rewardGroup,
        rewardPickedAt: pickedAt,
        balanceAfter: balanceAfter,
      );

  group('a CSV round trip', () {
    test('keeps the merchant of an SMS row and a reward pick', () async {
      final merchant = alertMerchantOf(smsRow());
      // Otherwise the test would pass with nothing to carry.
      expect(merchant, isNotEmpty);
      final pickedAt = DateTime(2026, 9, 6, 13, 15);
      final bytes = await BackupService.csvBytesOf([
        smsRow(),
        manualRow('m1', rewardGroup: 'grp_dining', pickedAt: pickedAt),
        manualRow('m2'),
      ]);
      final (txs, kinds) = BackupService.csvImportOf(utf8.decode(bytes));

      final p = FinanceProvider();
      await p.load();
      await p.importTransactions(txs, replace: true, acctKinds: kinds);
      Tx row(String id) => [
        ...p.transactions,
        ...p.pendingTransactions,
      ].singleWhere((t) => t.id == id);

      expect(row('s1').smsBody, isEmpty, reason: 'alert text stays home');
      expect(row('s1').smsMerchant, merchant);
      expect(alertMerchantOf(row('s1')), merchant);
      expect(row('m1').rewardGroup, 'grp_dining');
      expect(row('m1').rewardPickedAt, pickedAt);
      expect(row('m2').rewardGroup, isNull);
      expect(row('m2').rewardPickedAt, isNull);
      expect(row('m2').smsMerchant, isEmpty);
    });

    test('keeps the merchant of a row restored without its alert', () {
      final csv = BackupService.buildCsvOf([
        smsRow(body: '', merchant: 'Kettle Nook'),
      ]);
      final back = BackupService.txsFromCsv(csv).single;
      expect(back.smsMerchant, 'Kettle Nook');
      expect(alertMerchantOf(back), 'Kettle Nook');
    });

    test('a pick time with no pick is not read', () {
      final csv = BackupService.buildCsvOf([manualRow('m1')]).replaceFirst(
        RegExp(r'"",""$', multiLine: true),
        '"","2026-09-06T13:15:00.000"',
      );
      final back = BackupService.txsFromCsv(csv).single;
      expect(back.rewardGroup, isNull);
      expect(back.rewardPickedAt, isNull);
    });

    test('an older file without the three columns still imports', () {
      final csv = BackupService.buildCsvOf([
        smsRow(),
        manualRow('m1', rewardGroup: 'grp_dining'),
      ]);
      String dropLast3(String line) {
        var end = line.length;
        for (var i = 0; i < 3; i++) {
          end = line.lastIndexOf(',', end - 1);
        }
        return line.substring(0, end);
      }

      final old = [
        for (final line in csv.split('\r\n')) dropLast3(line),
      ].join('\r\n');
      expect(old.split('\r\n').first, endsWith(',noCashback'));
      final back = {for (final t in BackupService.txsFromCsv(old)) t.id: t};
      expect(back['s1']!.smsMerchant, isEmpty);
      expect(back['m1']!.rewardGroup, isNull);
    });
  });

  group('the CSV formula guard', () {
    String noteCell(String csv) {
      final rows = BackupService.parseCsv(csv);
      return rows[1][rows.first.indexOf('note')];
    }

    for (final (label, note) in [
      ('an equals sign', '=1+2'),
      ('a tab before an equals sign', '\t=1+2'),
      ('spaces before an equals sign', '   =1+2'),
      ('a no-break space before a plus', '\u{00A0}+1'),
      ('a control character before a minus', '\x01-1'),
      ('a carriage return before an at sign', '\r@SUM(A1)'),
      ('a leading tab', '\tsplit bill'),
      ('a leading carriage return', '\rsplit bill'),
      ('a note that starts with a minus', '-500 cash back'),
      ('an apostrophe before an equals sign', "'=quoted"),
      ('two apostrophes before an equals sign', "''=twice"),
    ]) {
      test('guards $label and gives it back as typed', () {
        final csv = BackupService.buildCsvOf([manualRow('m1', note: note)]);
        expect(noteCell(csv), "'$note");
        expect(BackupService.txsFromCsv(csv).single.note, note);
      });
    }

    for (final note in ["'plain", 'plain - text', '  spaced']) {
      test('leaves "$note" alone', () {
        final csv = BackupService.buildCsvOf([manualRow('m1', note: note)]);
        expect(noteCell(csv), note);
        // Leading spaces were always trimmed on import.
        expect(BackupService.txsFromCsv(csv).single.note, note.trimLeft());
      });
    }

    test('a note that is only a tab still reads back empty', () {
      final csv = BackupService.buildCsvOf([manualRow('m1', note: '\t')]);
      expect(BackupService.txsFromCsv(csv).single.note, isEmpty);
    });

    test('a negative number column is written as a number', () {
      final csv = BackupService.buildCsvOf([
        manualRow('m1', balanceAfter: -120.5),
      ]);
      final rows = BackupService.parseCsv(csv);
      expect(rows[1][rows.first.indexOf('balanceAfter')], '-120.50');
      expect(BackupService.txsFromCsv(csv).single.balanceAfter, -120.5);
    });
  });

  group('a settings write that storage refuses', () {
    late List<String> logs;
    late _FailingStore store;

    setUp(() {
      logs = [];
      final old = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => logs.add('$message');
      addTearDown(() {
        debugPrint = old;
        SharedPreferences.setMockInitialValues({});
      });
      store = _FailingStore();
    });

    Future<SettingsProvider> loaded() async {
      final s = SettingsProvider();
      await s.load();
      SharedPreferencesStorePlatform.instance = store;
      return s;
    }

    test('reaches the failure log, for one write and for several', () async {
      final s = await loaded();
      store.failWrites = true;
      final other = s.mode == ThemeMode.light
          ? ThemeMode.dark
          : ThemeMode.light;
      await s.setMode(other);
      expect(
        logs.where((l) => l.startsWith('Settings persist failed')),
        hasLength(1),
      );
      await s.setAlertThreshold(80, false);
      expect(
        logs.last,
        startsWith('Settings persist failed (alert thresholds)'),
      );
      // The value in memory stands either way.
      expect(s.mode, other);
    });

    test('a write that lands logs nothing', () async {
      final s = await loaded();
      await s.setMode(
        s.mode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light,
      );
      await s.setAlertThreshold(80, false);
      expect(logs.where((l) => l.startsWith('Settings persist failed')), isEmpty);
    });
  });

  group('a restore that changes Auto-import', () {
    /// A phone on [before] that restores a backup on [mode].
    Future<SettingsProvider> restored(
      AutoImportFrequency before,
      AutoImportFrequency mode,
    ) async {
      final s = SettingsProvider();
      await s.load();
      await s.setAutoImport(before);
      await s.applyBackupMap({'autoImport': mode.name});
      return s;
    }

    test('Every SMS refused goes back to the mode the phone had', () async {
      final s = await restored(
        AutoImportFrequency.daily,
        AutoImportFrequency.everySms,
      );
      var asks = 0;
      final kept = await keepRestoredAutoImport(
        s,
        before: AutoImportFrequency.daily,
        askReceiveSms: () async {
          asks++;
          return false;
        },
      );
      expect(kept, isFalse);
      expect(asks, 1);
      expect(s.autoImport, AutoImportFrequency.daily);
      final again = SettingsProvider();
      await again.load();
      expect(again.autoImport, AutoImportFrequency.daily, reason: 'stored');
    });

    test('Every SMS granted is kept', () async {
      final s = await restored(
        AutoImportFrequency.off,
        AutoImportFrequency.everySms,
      );
      final kept = await keepRestoredAutoImport(
        s,
        before: AutoImportFrequency.off,
        askReceiveSms: () async => true,
      );
      expect(kept, isTrue);
      expect(s.autoImport, AutoImportFrequency.everySms);
    });

    test('an ask that fails counts as refused', () async {
      final s = await restored(
        AutoImportFrequency.weekly,
        AutoImportFrequency.everySms,
      );
      final kept = await keepRestoredAutoImport(
        s,
        before: AutoImportFrequency.weekly,
        askReceiveSms: () async => throw StateError('no platform answer'),
      );
      expect(kept, isFalse);
      expect(s.autoImport, AutoImportFrequency.weekly);
    });

    test('the modes the page sets without an ask are applied as restored, '
        'and Every SMS kept from before asks nothing', () async {
      var asks = 0;
      Future<bool> ask() async {
        asks++;
        return false;
      }

      for (final (before, mode) in [
        (AutoImportFrequency.off, AutoImportFrequency.daily),
        (AutoImportFrequency.off, AutoImportFrequency.weekly),
        (AutoImportFrequency.off, AutoImportFrequency.everyOpen),
        (AutoImportFrequency.everySms, AutoImportFrequency.off),
        (AutoImportFrequency.everySms, AutoImportFrequency.everySms),
      ]) {
        final s = await restored(before, mode);
        expect(
          await keepRestoredAutoImport(s, before: before, askReceiveSms: ask),
          isTrue,
          reason: '$before to $mode',
        );
        expect(s.autoImport, mode, reason: '$before to $mode');
      }
      expect(asks, 0);
    });
  });
}
