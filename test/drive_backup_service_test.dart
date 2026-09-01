import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';

/// Counts exportData calls so tests can pin WHEN the snapshot is taken.
class _ProbeProvider extends FinanceProvider {
  int exportCalls = 0;

  @override
  Map<String, dynamic> exportData() {
    exportCalls++;
    return super.exportData();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isDue', () {
    final now = DateTime(2026, 8, 10, 9);

    test('never backed up → due', () {
      expect(DriveBackupService.isDue(null, 'daily', now), isTrue);
    });

    test('clock moved backwards (future last) → due', () {
      expect(
        DriveBackupService.isDue(
          now.add(const Duration(days: 2)),
          'daily',
          now,
        ),
        isTrue,
      );
    });

    test('daily: due after 23h, not before', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(hours: 23)),
          'daily',
          now,
        ),
        isTrue,
      );
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(hours: 22)),
          'daily',
          now,
        ),
        isFalse,
      );
    });

    test('weekly: due after 6 days, not before', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 6)),
          'weekly',
          now,
        ),
        isTrue,
      );
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 5)),
          'weekly',
          now,
        ),
        isFalse,
      );
    });

    test('monthly: due after 28 days, not before', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 28)),
          'monthly',
          now,
        ),
        isTrue,
      );
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 27)),
          'monthly',
          now,
        ),
        isFalse,
      );
    });

    test('unknown frequency falls back to daily', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 1)),
          'bogus',
          now,
        ),
        isTrue,
      );
    });
  });

  group('gzip payload round-trip', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    test('a full exportData survives encode → decode intact', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 123.45,
        note: 'gym · lunch',
        date: DateTime(2026, 8, 1, 12, 30),
      );
      await p.addRule('chai kings', 'food');
      final data = p.exportData();

      final bytes = encodeBackupGz(data);
      final decoded = decodeBackupGz(bytes);

      expect(decoded['app'], 'expense_tracker');
      expect(decoded['version'], data['version']);
      expect(
        (decoded['transactions'] as List).length,
        (data['transactions'] as List).length,
      );
      // And the round-tripped payload is importable.
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
      final p2 = FinanceProvider();
      await p2.load();
      final added = await p2.importData(decoded, replace: true);
      expect(added, 1);
      expect(p2.transactions.single.note, 'gym · lunch');
      expect(p2.rules.any((r) => r.pattern == 'chai kings'), isTrue);
    });

    test('garbage bytes are rejected with FormatException', () {
      expect(
        () => decodeBackupGz(Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsFormatException,
      );
    });
  });

  group('uploadNow race hardening', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    test('snapshots the ledger before any network call', () async {
      final p = _ProbeProvider();
      await p.load();
      final svc = DriveBackupService();
      // No platform channel under tests → sign-in fails inside _api(),
      // AFTER the snapshot. exportCalls == 1 proves snapshot-first order.
      final f = svc.uploadNow(p);
      expect(p.exportCalls, 1);
      await expectLater(f, throwsA(anything));
    });

    test('a second uploadNow joins the in-flight one', () async {
      final p = _ProbeProvider();
      await p.load();
      final svc = DriveBackupService();
      final f1 = svc.uploadNow(p);
      final f2 = svc.uploadNow(p);
      expect(identical(f1, f2), isTrue);
      expect(p.exportCalls, 1); // not double-encoded
      await expectLater(f1, throwsA(anything));
      // After completion the slot is free again — a new call runs fresh.
      final f3 = svc.uploadNow(p);
      expect(identical(f1, f3), isFalse);
      await expectLater(f3, throwsA(anything));
    });

    test('a failed upload records drive_last_error', () async {
      final p = _ProbeProvider();
      await p.load();
      final svc = DriveBackupService();
      await expectLater(svc.uploadNow(p), throwsA(anything));
      expect(await svc.lastError(), isNotNull);
    });
  });

  group('backup file name', () {
    test('is prefix-matched, iso-sortable, and extension-tagged', () {
      final name = DriveBackupService.backupFileName(
        DateTime(2026, 8, 10, 9, 5, 3),
      );
      expect(name, 'expense_tracker_backup_2026-08-10T09-05-03.json.gz');
      // Lexicographic order == chronological order (retention relies on
      // createdTime, but the names must not mislead a human sorting them).
      final later = DriveBackupService.backupFileName(DateTime(2026, 8, 11, 8));
      expect(name.compareTo(later), lessThan(0));
    });
  });
}
