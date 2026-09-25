import 'dart:convert';

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';

/// Tags on transactions: how they are cleaned, stored, exported and edited
/// in bulk, and what the Tags tab totals count.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  group('normalizeTags', () {
    test('trims, collapses spaces and drops blanks', () {
      expect(normalizeTags(['  Goa   trip ', '', '   ']), ['Goa trip']);
    });

    test('dedupes ignoring case, keeping the first spelling', () {
      expect(normalizeTags(['Goa trip', 'goa TRIP', 'Work']), [
        'Goa trip',
        'Work',
      ]);
    });

    test('caps length by character, never splitting an emoji', () {
      final t = normalizeTags(['a${'😀' * 40}']).single;
      expect(t.characters.length, kMaxTagLength);
      // No lone surrogate: survives UTF-8 unchanged.
      expect(utf8.decode(utf8.encode(t)), t);
    });

    test('removes the CSV separator and caps length and count', () {
      expect(normalizeTags(['a|b']), ['a b']);
      final long = 'x' * 40;
      expect(normalizeTags([long]).single, hasLength(kMaxTagLength));
      expect(
        normalizeTags([for (var i = 0; i < 8; i++) 't$i']),
        hasLength(kMaxTagsPerTx),
      );
    });
  });

  group('storage', () {
    final base = Tx(
      id: 'a',
      type: TxType.expense,
      categoryId: 'food',
      amount: 100,
      note: '',
      date: DateTime(2026, 9, 1),
    );

    test('JSON writes tags only when present and reads them back', () {
      expect(base.toJson().containsKey('tags'), isFalse);
      final tagged = base.copyWith(tags: ['Goa trip', 'Work']);
      final back = Tx.fromJson(tagged.toJson());
      expect(back.tags, ['Goa trip', 'Work']);
    });

    test('a foreign or broken tags value reads as none', () {
      final json = base.toJson()..['tags'] = 'Goa trip';
      expect(Tx.fromJson(json).tags, isEmpty);
      final mixed = base.toJson()..['tags'] = ['Goa trip', 7, null];
      expect(Tx.fromJson(mixed).tags, ['Goa trip']);
    });

    test('the SMS body migration keeps tags', () {
      final legacy = Tx(
        id: 'b',
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: 'Rs 100 debited',
        date: DateTime(2026, 9, 1),
        source: TxSource.sms,
        tags: const ['Goa trip'],
      );
      expect(legacy.migrateSmsBodyFromNote().tags, ['Goa trip']);
    });

    test('CSV round trip keeps tags', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 250,
        note: 'Beach shack',
        date: DateTime(2026, 9, 14),
        tags: ['Goa trip', '=Reimbursable'],
      );
      final csv = BackupService.buildCsv(p);
      final rows = BackupService.txsFromCsv(csv);
      expect(rows.single.tags, ['Goa trip', '=Reimbursable']);
    });
  });

  group('provider', () {
    Future<(FinanceProvider, String, String)> seeded() async {
      final p = FinanceProvider();
      await p.load();
      final a = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 1200,
        note: 'Dinner',
        date: DateTime(2026, 9, 12),
        myShare: 400,
        tags: ['Goa trip'],
      );
      final b = await p.addTransaction(
        type: TxType.expense,
        categoryId: kTransferOutCategoryId,
        amount: 5000,
        note: 'To my other account',
        date: DateTime(2026, 9, 16),
        tags: ['goa TRIP'],
      );
      return (p, a, b);
    }

    test('totals count only your share and leave transfers out', () async {
      final (p, _, _) = await seeded();
      final s = p.tagSummaries.single;
      expect(s.tag, 'Goa trip', reason: 'one tag, first spelling');
      expect(s.spent, 400);
      expect(s.count, 2);
      expect(s.first, DateTime(2026, 9, 12));
      expect(s.last, DateTime(2026, 9, 16));
      expect(p.allTags.single.count, 2);
    });

    test('bulk add and remove, with Undo', () async {
      final (p, a, b) = await seeded();
      final before = await p.setTagsForMany(
        {a, b},
        add: {'Reimbursable'},
        remove: {'Goa trip'},
      );
      expect(before, hasLength(2));
      Tx row(String id) => p.transactions.firstWhere((t) => t.id == id);
      expect(row(a).tags, ['Reimbursable']);
      expect(row(b).tags, ['Reimbursable']);
      await p.restoreEditedTransactions(before);
      expect(row(a).tags, ['Goa trip']);
      expect(row(b).tags, ['goa TRIP']);
    });

    test(
      'rename merges into an existing tag, and Undo splits it back',
      () async {
        final (p, a, _) = await seeded();
        await p.setTagsForMany({a}, add: {'Holiday'});
        final before = await p.renameTag('Goa trip', 'holiday');
        expect([for (final u in p.allTags) u.tag], ['holiday']);
        Tx row(String id) => p.transactions.firstWhere((t) => t.id == id);
        expect(row(a).tags, ['holiday'], reason: 'merged, no duplicate');
        await p.restoreEditedTransactions(before);
        expect(row(a).tags, ['Goa trip', 'Holiday']);
      },
    );

    test('delete takes a tag off every row, with Undo', () async {
      final (p, _, _) = await seeded();
      final before = await p.deleteTag('GOA TRIP');
      expect(before, hasLength(2));
      expect(p.allTags, isEmpty);
      await p.restoreEditedTransactions(before);
      expect(p.allTags.single.count, 2);
    });

    test('tags on pending imports stay out until confirmed', () async {
      final p = FinanceProvider();
      await p.load();
      await p.importTransactions([
        Tx(
          id: 'sms1',
          type: TxType.expense,
          categoryId: 'food',
          amount: 300,
          note: '',
          date: DateTime(2026, 9, 20),
          source: TxSource.sms,
          pending: true,
          tags: const ['Goa trip'],
        ),
      ], replace: false);
      expect(p.allTags, isEmpty, reason: 'hub, filter and Tags tab agree');
      expect(p.tagSummaries, isEmpty);
      await p.confirmTransaction('sms1');
      expect(p.allTags.single.tag, 'Goa trip');
      expect(p.tagSummaries.single.spent, 300);
    });

    test('an edit that changes nothing reports nothing', () async {
      final (p, a, _) = await seeded();
      expect(await p.setTagsForMany({a}, add: {'goa trip'}), isEmpty);
      expect(await p.deleteTag('Nope'), isEmpty);
    });
  });
}
