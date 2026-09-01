import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';

Future<FinanceProvider> seededProvider() async {
  final p = FinanceProvider();
  await p.load();
  await p.addTransaction(
    type: TxType.income,
    categoryId: 'salary',
    amount: 50000,
    note: 'July salary',
    date: DateTime(2026, 7, 1),
  );
  await p.addTransaction(
    type: TxType.expense,
    categoryId: 'food',
    amount: 640,
    note: 'Dinner',
    date: DateTime(2026, 7, 2),
  );
  await p.addTransaction(
    type: TxType.expense,
    categoryId: kSavingsTransferCategoryId,
    amount: 7500,
    note: 'RD instalment',
    date: DateTime(2026, 7, 3),
  );
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The category registries are process-wide statics; a test that adds a
    // custom category or renames a built-in must not leak into the next.
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  test('export → replace-import round-trips all data', () async {
    final source = await seededProvider();
    final json = jsonEncode(source.exportData());

    SharedPreferences.setMockInitialValues({});
    final target = FinanceProvider();
    await target.load();
    final txAdded = await target.importData(
      jsonDecode(json) as Map<String, dynamic>,
      replace: true,
    );

    expect(txAdded, 3);
    expect(target.totalIncome, source.totalIncome);
    expect(target.totalExpense, source.totalExpense);
    expect(target.totalSavingsTransfers, source.totalSavingsTransfers);
    expect(target.balance, source.balance);
  });

  test('merge import skips entries that already exist', () async {
    final p = await seededProvider();
    final backup = p.exportData();

    // Re-importing its own backup adds nothing.
    var txAdded = await p.importData(backup, replace: false);
    expect(txAdded, 0);
    expect(p.transactions.length, 3);

    // A backup with one unknown transaction adds exactly that one.
    final extra = Map<String, dynamic>.from(backup);
    extra['transactions'] = [
      ...(backup['transactions'] as List),
      {
        'id': 'foreign-id-1',
        'type': 'expense',
        'categoryId': 'transport',
        'amount': 120.0,
        'note': 'Bus pass',
        'date': DateTime(2026, 6, 20).toIso8601String(),
      },
    ];
    txAdded = await p.importData(extra, replace: false);
    expect(txAdded, 1);
    expect(p.transactions.length, 4);
  });

  test('replace import overwrites existing data', () async {
    final p = await seededProvider();
    final backup = p.exportData();

    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'shopping',
      amount: 999,
      note: 'Post-backup purchase',
      date: DateTime(2026, 7, 4),
    );
    expect(p.transactions.length, 4);

    await p.importData(backup, replace: true);
    expect(p.transactions.length, 3);
    expect(
      p.transactions.any((t) => t.note == 'Post-backup purchase'),
      isFalse,
    );
  });

  test('invalid payloads are rejected without touching data', () async {
    final p = await seededProvider();

    expect(
      () => p.importData({'foo': 'bar'}, replace: true),
      throwsFormatException,
    );
    expect(
      () => p.importData({
        'app': 'expense_tracker',
        'transactions': [
          {'id': 'x'}, // missing mandatory fields
        ],
      }, replace: true),
      throwsA(anything),
    );
    // Original data intact after both failures.
    expect(p.transactions.length, 3);
  });

  test('PDF report renders with data', () async {
    final p = await seededProvider();
    final bytes = await BackupService.buildPdf(p);
    expect(bytes.length, greaterThan(1000));
    // %PDF magic header
    expect(bytes.sublist(0, 4), [0x25, 0x50, 0x44, 0x46]);
  });

  test('PDF report renders when empty', () async {
    final p = FinanceProvider();
    await p.load();
    final bytes = await BackupService.buildPdf(p);
    expect(bytes.length, greaterThan(500));
  });

  group('CSV', () {
    test('export → import round-trips all transactions', () async {
      final source = await seededProvider();
      final csv = BackupService.buildCsv(source);

      SharedPreferences.setMockInitialValues({});
      final target = FinanceProvider();
      await target.load();
      final added = await target.importTransactions(
        BackupService.txsFromCsv(csv),
        replace: true,
      );

      expect(added, 3);
      expect(target.totalIncome, source.totalIncome);
      expect(target.totalExpense, source.totalExpense);
      expect(target.totalSavingsTransfers, source.totalSavingsTransfers);
    });

    test('quoted fields with commas, quotes, and newlines survive', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 99,
        note: 'Line one,\n"quoted", line two',
        date: DateTime(2026, 7, 1),
        sender: 'VM-HDFCBK',
      );
      final txs = BackupService.txsFromCsv(BackupService.buildCsv(p));
      expect(txs.single.note, 'Line one,\n"quoted", line two');
      expect(txs.single.sender, 'VM-HDFCBK');
    });

    test('merge import skips existing ids', () async {
      final p = await seededProvider();
      final csv = BackupService.buildCsv(p);
      final added = await p.importTransactions(
        BackupService.txsFromCsv(csv),
        replace: false,
      );
      expect(added, 0);
      expect(p.transactions.length, 3);
    });

    test('buildCsvOf exports exactly the given rows, in the given order', () {
      final rows = [
        Tx(
          id: 'b',
          type: TxType.expense,
          categoryId: 'food',
          amount: 200,
          note: 'Second on screen',
          date: DateTime(2026, 7, 1),
        ),
        Tx(
          id: 'a',
          type: TxType.expense,
          categoryId: 'food',
          amount: 100,
          note: 'First on screen',
          date: DateTime(2026, 7, 5),
        ),
      ];
      final lines = BackupService.buildCsvOf(rows).split('\r\n');
      expect(lines, hasLength(3), reason: 'header + the two rows, no extras');
      expect(lines[0].split(',').first, 'id');
      expect(lines[1], contains('"b"'));
      expect(lines[2], contains('"a"'), reason: 'caller order kept, not date');
    });

    test('full-history buildCsv still includes pending rows', () async {
      final p = await seededProvider();
      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 55,
          merchant: 'SHOP',
          date: DateTime(2026, 7, 9),
          ref: 'R9',
          categoryId: 'other_expense',
          sender: 'VM-HDFCBK',
          rawBody: 'Rs.55 debited from a/c XX1234.',
          acctKey: 'HDFC:1234',
        ),
      ]);
      expect(p.pendingCount, 1);
      final csv = BackupService.buildCsv(p);
      // 3 confirmed + 1 pending + header.
      expect(csv.split('\r\n'), hasLength(5));
    });

    test('CSV without mandatory columns is rejected', () {
      expect(
        () => BackupService.txsFromCsv('id,note\n1,hello'),
        throwsFormatException,
      );
      expect(
        () => BackupService.txsFromCsv(
          'date,type,amount\n2026-07-01,expense,not-a-number',
        ),
        throwsFormatException,
      );
    });

    test('minimal CSV (date,type,amount) imports with defaults', () async {
      final txs = BackupService.txsFromCsv(
        'date,type,amount\r\n2026-07-01T10:00:00,expense,123.45',
      );
      expect(txs.single.amount, 123.45);
      expect(txs.single.categoryId, 'other_expense');
      expect(txs.single.source, TxSource.manual);
    });

    test('categoryName carries custom and renamed built-in labels', () async {
      final p = FinanceProvider();
      await p.load();
      final customId = await p.addCategory(
        label: 'Chai runs',
        type: TxType.expense,
        icon: Icons.local_cafe,
        color: Colors.brown,
      );
      await p.overrideBuiltinCategory(
        id: 'food',
        label: 'Meals out',
        icon: Icons.restaurant,
        color: Colors.orange,
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: customId,
        amount: 40,
        note: 'chai',
        date: DateTime(2026, 7, 1),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 500,
        note: 'dinner',
        date: DateTime(2026, 7, 2),
      );

      // The bytes the export menu actually writes: this runs the real
      // compute() hop, where the worker isolate sees only the default
      // category registry — the labels must have been resolved before it.
      final rows = BackupService.parseCsv(
        utf8.decode(await BackupService.csvBytes(p)),
      );
      final header = rows.first;
      final idCol = header.indexOf('category');
      final nameCol = header.indexOf('categoryName');
      expect(nameCol, greaterThan(-1));
      expect(header, isNot(contains('smsBody')));
      final names = {for (final r in rows.skip(1)) r[idCol]: r[nameCol]};
      expect(names[customId], 'Chai runs');
      expect(names['food'], 'Meals out');
    });

    test('an edited categoryName cannot remap the row', () async {
      // The id column stays authoritative — a label changed in a spreadsheet
      // must not move the transaction to another category.
      final txs = BackupService.txsFromCsv(
        'id,date,type,category,categoryName,amount,note\r\n'
        '"t1","2026-07-01T10:00:00.000","expense","food","Groceries",99,"x"',
      );
      expect(txs.single.categoryId, 'food');
    });
  });
}
