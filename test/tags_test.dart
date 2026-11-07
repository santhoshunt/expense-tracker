import 'dart:convert';

import 'package:flutter/widgets.dart' show Color, StringCharacters;
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

    test('totals count your share and money-out transfers', () async {
      final (p, _, _) = await seeded();
      final s = p.tagSummaries.single;
      expect(s.tag, 'Goa trip', reason: 'one tag, first spelling');
      expect(s.spent, 5400, reason: 'your 400 share + the 5000 transfer');
      expect(s.count, 2);
      expect(s.first, DateTime(2026, 9, 12));
      expect(s.last, DateTime(2026, 9, 16));
      expect(p.allTags.single.count, 2);
    });

    test('By tags: month money out, both tags counted, transfers in', () async {
      final (p, _, _) = await seeded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 600,
        note: 'Cab',
        date: DateTime(2026, 9, 14),
        tags: ['Goa trip', 'Work'],
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 90,
        note: 'Snack',
        date: DateTime(2026, 10, 2),
        tags: ['Work'],
      );
      final sep = p.expenseByTagInMonth(DateTime(2026, 9));
      expect([for (final t in sep) t.tag], ['Goa trip', 'Work']);
      expect(
        sep.first.spent,
        6000,
        reason: 'your 400 share + the 600 cab + the 5000 money-out transfer',
      );
      expect(sep.last.spent, 600);
      expect(p.expenseByTagInMonth(DateTime(2026, 10)).single.spent, 90);
      final year = p.expenseByTagInYear(2026);
      expect(
        [for (final t in year) (t.tag, t.spent)],
        [('Goa trip', 6000.0), ('Work', 690.0)],
      );
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

  group('colours', () {
    const green = Color(0xFF50D1AA);
    const pink = Color(0xFFFF7CA3);

    Future<FinanceProvider> tagged() async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: 'Lunch',
        date: DateTime(2026, 9, 12),
        tags: ['Goa trip', 'Work'],
      );
      return p;
    }

    test('a colour persists and matches any spelling of the tag', () async {
      final p = await tagged();
      await p.setTagColor('goa TRIP', green);
      expect(p.tagColor('Goa trip'), green);
      final again = FinanceProvider();
      await again.load();
      expect(again.tagColor('Goa trip'), green);
      await again.setTagColor('Goa trip', null);
      expect(again.tagColor('Goa trip'), isNull);
    });

    test(
      'a rename takes the colour along, unless the target has one',
      () async {
        final p = await tagged();
        await p.setTagColor('Goa trip', green);
        await p.renameTag('Goa trip', 'Holiday');
        expect(p.tagColor('Holiday'), green);
        expect(p.tagColor('Goa trip'), isNull);

        await p.setTagColor('Work', pink);
        await p.renameTag('Holiday', 'Work');
        expect(
          p.tagColor('Work'),
          pink,
          reason: 'the merge target keeps its own',
        );
      },
    );

    test(
      'a delete drops the colour, and the Undo snapshot restores both',
      () async {
        final p = await tagged();
        await p.setTagColor('Goa trip', green);
        final colours = p.tagColorSnapshot;
        final before = await p.deleteTag('Goa trip');
        expect(p.tagColor('Goa trip'), isNull);
        await p.restoreEditedTransactions(before);
        await p.restoreTagColors(colours);
        expect(p.tagColor('Goa trip'), green);
        expect(p.allTags.map((u) => u.tag), contains('Goa trip'));
      },
    );

    test('the backup carries colours and restores them', () async {
      final p = await tagged();
      await p.setTagColor('Work', pink);
      final data = p.exportData();
      expect(data['version'], 33);
      final fresh = FinanceProvider();
      await fresh.load();
      await fresh.importData(data, replace: true);
      expect(fresh.tagColor('Work'), pink);
    });

    test(
      'colours of tags no row carries are dropped at the next load',
      () async {
        final p = await tagged();
        await p.setTagColor('Goa trip', green);
        await p.setTagsForMany(
          {p.transactions.single.id},
          remove: {'Goa trip'},
        );
        expect(p.tagColor('Goa trip'), green, reason: 'kept for an Undo');
        final again = FinanceProvider();
        await again.load();
        expect(again.tagColor('Goa trip'), isNull);
      },
    );
  });

  group('saved tags', () {
    const teal = Color(0xFF00897B);

    test('a saved tag persists with no payments, keeps its colour through '
        'the prune, and follows a rename and a delete', () async {
      final p = FinanceProvider();
      await p.load();
      expect(await p.addSavedTag('Goa trip', teal), isTrue);
      expect(await p.addSavedTag('goa TRIP', null), isFalse);
      expect(await p.addSavedTag('   ', null), isFalse);

      final again = FinanceProvider();
      await again.load();
      expect(again.emptyTags, ['Goa trip']);
      expect(again.tagColor('Goa trip'), teal);

      await again.renameTag('Goa trip', 'Goa');
      expect(again.savedTags, ['Goa']);
      expect(again.tagColor('Goa'), teal);
      await again.deleteTag('Goa');
      expect(again.savedTags, isEmpty);
      await again.restoreSavedTags(['Goa']);
      expect(again.savedTags, ['Goa']);
      expect(again.emptyTags, ['Goa']);
    });

    test('the backup carries saved tags: replace takes them, merge adds the '
        'missing ones, a factory reset clears them', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addSavedTag('Goa trip', null);
      final data = p.exportData();
      expect(data['tagNames'], ['Goa trip']);

      SharedPreferences.setMockInitialValues({});
      final other = FinanceProvider();
      await other.load();
      await other.addSavedTag('Diwali', null);
      await other.importData(data, replace: true);
      expect(other.savedTags, ['Goa trip']);

      await other.addSavedTag('Diwali', null);
      await other.importData({
        ...data,
        'tagNames': ['goa TRIP', 'Wedding'],
      }, replace: false);
      expect(other.savedTags, ['Goa trip', 'Diwali', 'Wedding']);

      // A backup from before saved tags keeps the device's.
      await other.importData({...data}..remove('tagNames'), replace: true);
      expect(other.savedTags, ['Goa trip', 'Diwali', 'Wedding']);

      await other.clearAll();
      expect(other.savedTags, hasLength(3));
      await other.clearAll(includeConfig: true);
      expect(other.savedTags, isEmpty);
    });

    test(
      'suggestions hold at most four saved tags among the first eight',
      () async {
        final p = FinanceProvider();
        await p.load();
        for (var i = 0; i < 10; i++) {
          await p.addTransaction(
            type: TxType.expense,
            categoryId: 'food',
            amount: 100,
            note: 'Lunch',
            date: DateTime(2026, 9, 1 + i),
            tags: ['Used $i'],
          );
        }
        final saved = [for (var i = 0; i < 6; i++) 'Saved $i'];
        for (final t in saved) {
          await p.addSavedTag(t, null);
        }

        final picks = p.tagSuggestions;
        expect(picks.take(4), everyElement(startsWith('Used ')));
        expect(picks.skip(4).take(4), everyElement(startsWith('Saved ')));
        expect(picks, hasLength(16));
        expect(picks.toSet(), hasLength(16));
      },
    );
  });
}
