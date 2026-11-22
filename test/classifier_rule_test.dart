import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/sms_parser.dart';

ClassifierRule rule(String pattern) =>
    ClassifierRule(id: 'r', pattern: pattern, categoryId: 'food');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('word-boundary matching', () {
    test('does not fire inside a word: "RD Ac" vs "Card Account"', () {
      final r = rule('RD Ac');
      expect(
        r.matches(
          'Dear Customer, Payment of INR 43,817.26 has been received on '
          'your ICICI Bank Credit Card Account 4xxx7031 on 31-JUL-26.',
        ),
        isFalse,
      );
      expect(
        r.matches(
          'ICICI Bank Acc XX246 debited Rs. 5,000.00 on 01-Aug-26 InfoTo '
          'RD Ac no 1.Avl Bal Rs. 7,412.30.',
        ),
        isTrue,
      );
    });

    test('still matches at text edges and around punctuation/digits', () {
      expect(rule('swiggy').matches('paid to SWIGGY'), isTrue);
      expect(rule('swiggy').matches('SWIGGY.in order'), isTrue);
      expect(rule('swiggy').matches('to swiggy8 wallet'), isTrue);
      expect(rule('swiggy').matches('theswiggystore'), isFalse);
      // Pattern edges that aren't letters skip the boundary check.
      expect(
        rule('kiwicashback@axisbank').matches('via kiwicashback@axisbank!'),
        isTrue,
      );
      expect(rule('  chai corner  ').matches('at CHAI CORNER today'), isTrue);
    });
  });

  group('OR-conditions ("|" separated alternatives)', () {
    test('matches when any alternative matches, with mixed spacing', () {
      final r = rule('chai | food|biryani');
      expect(r.patterns, ['chai', 'food', 'biryani']);
      expect(r.matches('paid at CHAI point'), isTrue);
      expect(r.matches('Swiggy food order'), isTrue);
      expect(r.matches('Ambur BIRYANI, UPI Ref 123'), isTrue);
      expect(r.matches('paid to SWIGGY'), isFalse);
    });

    test('boundary rules apply per alternative, not to the joined string', () {
      final r = rule('chai | corner');
      expect(r.matches('theCHAIshop'), isFalse); // inside a word
      expect(r.matches('CHAI CORNER today'), isTrue);
    });

    test('empty segments are ignored', () {
      expect(rule('chai |').patterns, ['chai']);
      expect(rule('chai |').matches('chai time'), isTrue);
      expect(rule('|').patterns, isEmpty);
      expect(rule('|').matches('anything'), isFalse);
      // Single pattern without '|' behaves exactly as before.
      expect(rule('swiggy').patterns, ['swiggy']);
    });
  });

  group('manual category wins over rules', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    ParsedTxn parsed(String body, {TxType type = TxType.income}) => ParsedTxn(
      type: type,
      amount: 43817.26,
      merchant: 'ICICI',
      date: DateTime(2026, 7, 31, 3, 12),
      ref: 'R1',
      categoryId: type == TxType.income ? 'other_income' : 'other_expense',
      sender: 'AX-ICICIT-S',
      rawBody: body,
    );

    test('re-apply skips rows the user classified by hand', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        parsed('Payment received on your account. Thank you kindly.'),
      ]);
      await p.confirmTransaction(p.pendingTransactions.single.id);

      // The user moves it to Card payment by hand (the review flow).
      final tx = p.transactions.single;
      await p.updateTransaction(
        tx.copyWith(categoryId: 'card_payment', type: TxType.income),
      );
      expect(p.transactions.single.userCategorized, isTrue);

      // An income rule that matches the body would previously stomp this.
      await p.addRule('thank you', 'investment');
      expect(p.transactions.single.categoryId, 'card_payment');

      // The lock survives persistence.
      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.transactions.single.userCategorized, isTrue);
    });

    test('rows the user never touched are still re-classified', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        parsed('Payment received on your account. Thank you kindly.'),
      ]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      await p.addRule('thank you', 'investment');
      expect(p.transactions.single.categoryId, 'investment');
    });

    test('bulk edit also locks the category', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([parsed('Some unmatched body text.')]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      await p.setCategoryForMany({p.transactions.single.id}, 'gift');
      expect(p.transactions.single.userCategorized, isTrue);
      await p.addRule('unmatched body', 'investment');
      expect(p.transactions.single.categoryId, 'gift');
    });

    test('editing amount or note alone does not lock the category', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([parsed('Some body.')]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      final tx = p.transactions.single;
      await p.updateTransaction(tx.copyWith(note: 'my note'));
      expect(p.transactions.single.userCategorized, isFalse);
    });

    test(
      'a wrong-direction rule no longer shadows a later correct rule',
      () async {
        final p = FinanceProvider();
        await p.load();
        // Mis-targeted user rule: swiggy → salary (income) sits ABOVE the
        // seeded swiggy → food (expense). It used to be returned as "the"
        // match, fail the type check, and block the food rule silently.
        await p.addRule('swiggy', 'salary');
        await p.addImported([
          parsed('Paid Rs.450 to SWIGGY order.', type: TxType.expense),
        ]);
        expect(p.pendingTransactions.single.categoryId, 'food');
      },
    );
  });

  group('Paid to and tags on a rule', () {
    const plain = ClassifierRule(
      id: 'r',
      pattern: 'quillfern',
      categoryId: 'food',
    );

    test('JSON writes them only when set and reads them back', () {
      expect(plain.setsMore, isFalse);
      expect(plain.toJson().keys, ['id', 'pattern', 'categoryId']);

      final full = plain.copyWith(
        payee: '  Quillfern   Teas ',
        tags: ['Office', 'office', ' Tea '],
      );
      expect(full.payee, 'Quillfern Teas');
      expect(full.tags, ['Office', 'Tea'], reason: 'cleaned as row tags are');
      expect(full.setsMore, isTrue);

      final back = ClassifierRule.fromJson(
        jsonDecode(jsonEncode(full.toJson())) as Map<String, dynamic>,
      );
      expect(back.id, 'r');
      expect(back.pattern, 'quillfern');
      expect(back.categoryId, 'food');
      expect(back.payee, 'Quillfern Teas');
      expect(back.tags, ['Office', 'Tea']);
    });

    test('a missing or wrongly typed value reads as empty', () {
      final base = <String, dynamic>{
        'id': 'r',
        'pattern': 'quillfern',
        'categoryId': 'food',
      };
      expect(ClassifierRule.fromJson(base).setsMore, isFalse);

      final wrong = ClassifierRule.fromJson({
        ...base,
        'payee': 7,
        'tags': 'Office',
      });
      expect(wrong.payee, isEmpty);
      expect(wrong.tags, isEmpty);

      final mixed = ClassifierRule.fromJson({
        ...base,
        'payee': null,
        'tags': ['Office', 7, null, 'Tea'],
      });
      expect(mixed.payee, isEmpty);
      expect(mixed.tags, ['Office', 'Tea']);
    });

    test('copyWith keeps a field on null and clears it on empty', () {
      final full = plain.copyWith(payee: 'Quillfern Teas', tags: ['Office']);
      final moved = full.copyWith(categoryId: 'shopping');
      expect(moved.payee, 'Quillfern Teas');
      expect(moved.tags, ['Office']);
      final cleared = full.copyWith(payee: '', tags: const []);
      expect(cleared.setsMore, isFalse);
      expect(full.copyWith(payee: '').tags, ['Office']);
    });
  });

  group('a rule that also sets Paid to and tags', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    Future<FinanceProvider> loaded() async {
      final p = FinanceProvider();
      await p.load();
      return p;
    }

    ParsedTxn alert(String body, {String ref = 'R1', double amount = 320}) =>
        ParsedTxn(
          type: TxType.expense,
          amount: amount,
          merchant: 'DEMO',
          date: DateTime(2026, 9, 12, 13),
          ref: ref,
          categoryId: 'other_expense',
          sender: 'AD-DEMOBK',
          rawBody: body,
        );

    // A confirmed SMS row no rule has sorted yet.
    Tx smsRow(
      String id,
      String body, {
      String payee = '',
      List<String> tags = const [],
      String categoryId = 'other_expense',
      bool userCategorized = false,
      String note = '',
      TxType type = TxType.expense,
    }) => Tx(
      id: id,
      type: type,
      categoryId: categoryId,
      amount: 250,
      note: note,
      date: DateTime(2026, 9, 12, 13),
      source: TxSource.sms,
      smsBody: body,
      sender: 'AD-DEMOBK',
      payee: payee,
      tags: tags,
      userCategorized: userCategorized,
    );

    Tx row(FinanceProvider p, String id) =>
        p.transactions.singleWhere((t) => t.id == id);

    test('an import takes the Paid to and tags with the category', () async {
      final p = await loaded();
      await p.addRule(
        'quillfern',
        'food',
        payee: ' Quillfern  Teas ',
        tags: ['Office', 'office'],
      );
      final rule = p.rules.first;
      expect(rule.payee, 'Quillfern Teas');
      expect(rule.tags, ['Office']);

      await p.addImported([
        alert('Rs 320.00 debited to QUILLFERN TEAS. Ref R1'),
        alert(
          'Rs 410.00 debited to MAPLEWORTH DEPOT. Ref R2',
          ref: 'R2',
          amount: 410,
        ),
      ]);
      // Counted at once or waiting for review, the row has them.
      final rows = [...p.transactions, ...p.pendingTransactions];
      final hit = rows.singleWhere((t) => t.smsBody.contains('QUILLFERN'));
      expect(hit.categoryId, 'food');
      expect(hit.payee, 'Quillfern Teas');
      expect(hit.tags, ['Office']);
      // A row the rule does not match gets neither.
      final miss = rows.singleWhere((t) => t.smsBody.contains('MAPLEWORTH'));
      expect(miss.payee, isEmpty);
      expect(miss.tags, isEmpty);
    });

    test('a rule that sets nothing more leaves a sorted row alone', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('a', 'Rs 250 paid to QUILLFERN', tags: const ['Team']),
      ]);
      final before = row(p, 'a');
      final applied = await p.addRule('quillfern', 'other_expense');
      expect(applied.reclassifiedRows, isEmpty);
      expect(identical(row(p, 'a'), before), isTrue);
    });

    test('saving a rule fills past rows, never a typed Paid to, and adds '
        'tags up to the cap', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('empty', 'Rs 250 paid to QUILLFERN TEAS'),
        smsRow(
          'typed',
          'Rs 250 paid to QUILLFERN TEAS at noon',
          payee: 'Tea with Meera',
          tags: const ['Team'],
        ),
        smsRow(
          'full',
          'Rs 250 paid to QUILLFERN TEAS again',
          tags: const ['One', 'Two', 'Three', 'Four'],
        ),
        smsRow('other', 'Rs 250 paid to MAPLEWORTH DEPOT'),
      ]);
      final applied = await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Teas',
        tags: ['Office', 'Tea'],
      );

      expect(row(p, 'empty').payee, 'Quillfern Teas');
      expect(row(p, 'empty').tags, ['Office', 'Tea']);
      expect(row(p, 'empty').categoryId, 'food');
      // What the user typed stays; the tags go after the row's own.
      expect(row(p, 'typed').payee, 'Tea with Meera');
      expect(row(p, 'typed').tags, ['Team', 'Office', 'Tea']);
      // Five at most: the row's four, then the rule's first.
      expect(row(p, 'full').tags, ['One', 'Two', 'Three', 'Four', 'Office']);
      expect(row(p, 'full').tags, hasLength(kMaxTagsPerTx));
      expect(row(p, 'other').payee, isEmpty);
      expect(row(p, 'other').tags, isEmpty);
      expect(applied.reclassified, 3);
      expect(applied.reclassifiedRows.map((t) => t.id).toSet(), {
        'empty',
        'typed',
        'full',
      });
    });

    test('a row changed only in Paid to or tags is written, kept for Undo, '
        'and not counted as reclassified', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('a', 'Rs 250 paid to QUILLFERN TEAS', categoryId: 'food'),
      ]);
      await p.addRule('quillfern', 'food');
      final rule = p.rules.first;
      final before = List.of(p.rules);

      final applied = await p.updateRule(
        rule.copyWith(payee: 'Quillfern Teas', tags: ['Office']),
      );
      expect(applied.reclassified, 0);
      expect(applied.reclassifiedRows.single.id, 'a');
      expect(applied.reclassifiedRows.single.payee, isEmpty);
      expect(row(p, 'a').payee, 'Quillfern Teas');
      expect(row(p, 'a').tags, ['Office']);

      // The stored ledger has it too.
      final again = await loaded();
      expect(row(again, 'a').payee, 'Quillfern Teas');
      expect(again.rules.first.tags, ['Office']);

      // Undo, as the rule sheet's toast does it.
      await p.restoreRules(before, reapply: false);
      await p.restoreEditedTransactions(applied.reclassifiedRows);
      expect(p.rules.first.setsMore, isFalse);
      expect(row(p, 'a').payee, isEmpty);
      expect(row(p, 'a').tags, isEmpty);

      // Saving the same rule twice changes nothing the second time.
      await p.updateRule(rule.copyWith(payee: 'Quillfern Teas'));
      final second = await p.updateRule(rule.copyWith(payee: 'Quillfern Teas'));
      expect(second.reclassifiedRows, isEmpty);
    });

    test('rows categorised by hand and rows with no alert text are '
        'skipped', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow(
          'hand',
          'Rs 250 paid to QUILLFERN TEAS',
          categoryId: 'shopping',
          userCategorized: true,
        ),
        smsRow('restored', ''),
        Tx(
          id: 'manual',
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 250,
          note: 'quillfern',
          date: DateTime(2026, 9, 12, 13),
        ),
      ]);
      final applied = await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Teas',
        tags: ['Office'],
      );
      expect(applied.reclassifiedRows, isEmpty);
      for (final id in ['hand', 'restored', 'manual']) {
        expect(row(p, id).payee, isEmpty, reason: id);
        expect(row(p, id).tags, isEmpty, reason: id);
      }
      expect(row(p, 'hand').categoryId, 'shopping');
    });

    test('the dry-run count follows first match wins and the same '
        'skips', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('a', 'Rs 250 paid to QUILLFERN TEAS'),
        smsRow('b', 'Rs 250 paid to QUILLFERN TEAS by UPI'),
        // Already as the rule would leave it.
        smsRow(
          'same',
          'Rs 250 paid to QUILLFERN TEAS twice',
          payee: 'Quillfern Teas',
          tags: const ['Office'],
        ),
        smsRow(
          'hand',
          'Rs 250 paid to QUILLFERN TEAS once',
          userCategorized: true,
        ),
        smsRow('restored', ''),
        smsRow('other', 'Rs 250 paid to MAPLEWORTH DEPOT'),
      ]);
      ClassifierRule candidate({
        String id = 'new',
        String pattern = 'quillfern',
        String categoryId = 'food',
        String payee = 'Quillfern Teas',
        List<String> tags = const ['Office'],
      }) => ClassifierRule(
        id: id,
        pattern: pattern,
        categoryId: categoryId,
        payee: payee,
        tags: tags,
      );

      expect(p.ruleExtrasChangeCount(candidate()), 2);
      // Nothing to set, a spam rule, the wrong direction: no row changes.
      expect(p.ruleExtrasChangeCount(candidate(payee: '', tags: [])), 0);
      expect(
        p.ruleExtrasChangeCount(candidate(categoryId: kSpamCategoryId)),
        0,
      );
      expect(p.ruleExtrasChangeCount(candidate(categoryId: 'salary')), 0);
      // The count leaves the ledger and the rules as they were.
      expect(row(p, 'a').payee, isEmpty);
      expect(p.rules.any((r) => r.id == 'new'), isFalse);

      // An older rule sits below a newer one that claims row b.
      await p.addRule('quillfern', 'food');
      final older = p.rules.first;
      await p.addRule('upi', 'transport');
      expect(
        p.ruleExtrasChangeCount(
          candidate(id: older.id),
          replacingRuleId: older.id,
        ),
        1,
        reason: 'edited in place, the rule above keeps row b',
      );
      expect(
        p.ruleExtrasChangeCount(candidate()),
        2,
        reason: 'a new rule goes first',
      );
    });

    test('saving another rule does not put back a tag taken off a row by '
        'hand', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('r', 'Rs 250 paid to QUILLFERN TEAS', categoryId: 'food'),
      ]);
      await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Teas',
        tags: ['Office'],
      );
      expect(row(p, 'r').payee, 'Quillfern Teas');
      expect(row(p, 'r').tags, ['Office']);

      // As the edit sheet saves it. The category is as it was, so the row
      // is not marked as sorted by hand.
      await p.updateTransaction(
        row(p, 'r').copyWith(payee: '', tags: const []),
      );
      expect(row(p, 'r').userCategorized, isFalse);
      final kept = row(p, 'r');

      // A new rule, an edit, a merge and a re-sorting restore, none of
      // them of the quillfern rule.
      final added = await p.addRule('mapleworth', 'shopping');
      expect(added.reclassifiedRows, isEmpty);
      await p.updateRule(
        p.rules.first.copyWith(pattern: 'mapleworth | meeravalli'),
      );
      await p.addRule('zephyrine', 'shopping');
      await p.mergeRules({p.rules[0].id, p.rules[1].id});
      await p.restoreRules(List.of(p.rules));
      expect(identical(row(p, 'r'), kept), isTrue);
      expect(row(p, 'r').payee, isEmpty);
      expect(row(p, 'r').tags, isEmpty);

      // Saving the rule itself sets its fields again.
      final own = p.rules.firstWhere((r) => r.pattern == 'quillfern');
      final applied = await p.updateRule(own);
      expect(applied.reclassified, 0);
      expect(applied.reclassifiedRows.single.id, 'r');
      expect(row(p, 'r').payee, 'Quillfern Teas');
      expect(row(p, 'r').tags, ['Office']);
    });

    test('a row a save newly gives to another rule takes that rule\'s Paid '
        'to and tags', () async {
      final p = await loaded();
      await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Teas',
        tags: ['Office'],
      );
      // Loaded after the rule: one row no rule has sorted, and one already
      // in the rule's category.
      await p.restoreTransactions([
        smsRow('late', 'Rs 250 paid to QUILLFERN TEAS'),
        smsRow(
          'sorted',
          'Rs 250 paid to QUILLFERN TEAS today',
          categoryId: 'food',
        ),
      ]);

      final applied = await p.addRule('mapleworth', 'shopping');
      expect(row(p, 'late').categoryId, 'food');
      expect(row(p, 'late').payee, 'Quillfern Teas');
      expect(row(p, 'late').tags, ['Office']);
      expect(applied.reclassified, 1);
      expect(applied.reclassifiedRows.single.id, 'late');
      // The rule was not the one saved, and the row did not move.
      expect(row(p, 'sorted').payee, isEmpty);
      expect(row(p, 'sorted').tags, isEmpty);
    });

    test('the dry-run count is the number of rows the save then changes in '
        'Paid to or tags', () async {
      final p = await loaded();
      await p.addRule('quillfern', 'food', tags: ['Office']);
      await p.restoreTransactions([
        smsRow('m1', 'Rs 250 paid to MAPLEWORTH DEPOT'),
        // Its own Paid to, and the tag the rule will add.
        smsRow(
          'm2',
          'Rs 250 paid to MAPLEWORTH DEPOT again',
          payee: 'Depot',
          tags: const ['Home'],
        ),
        // The quillfern rule's, not yet sorted by it.
        smsRow('late', 'Rs 250 paid to QUILLFERN TEAS'),
        // The quillfern rule's already, its tag taken off by hand.
        smsRow(
          'sorted',
          'Rs 250 paid to QUILLFERN TEAS today',
          categoryId: 'food',
        ),
        smsRow('out', 'Rs 250 sent to MEERAVALLI by UPI'),
        smsRow(
          'in',
          'Rs 250 received from MEERAVALLI by UPI',
          type: TxType.income,
          categoryId: 'other_income',
        ),
      ]);
      Map<String, String> fields() => {
        for (final t in p.transactions) t.id: '${t.payee}|${t.tags}',
      };
      // Runs [save] and returns how many rows it changed in Paid to or tags.
      Future<int> changedBy(Future<void> Function() save) async {
        final before = fields();
        await save();
        final after = fields();
        return before.keys.where((id) => before[id] != after[id]).length;
      }

      // A rule that sets nothing: the save still sorts the late row, which
      // takes the quillfern rule's tag.
      const plain = ClassifierRule(
        id: 'new',
        pattern: 'zephyrine',
        categoryId: 'shopping',
      );
      expect(p.ruleExtrasChangeCount(plain), 1);
      expect(await changedBy(() => p.addRule('zephyrine', 'shopping')), 1);
      expect(row(p, 'late').tags, ['Office']);
      expect(row(p, 'sorted').tags, isEmpty);

      // A new rule that sets both: m2 keeps its Paid to and has the tag.
      final maple = plain.copyWith(
        pattern: 'mapleworth',
        payee: 'Maple Depot',
        tags: ['Home'],
      );
      expect(p.ruleExtrasChangeCount(maple), 1);
      expect(
        await changedBy(
          () => p.addRule(
            'mapleworth',
            'shopping',
            payee: 'Maple Depot',
            tags: ['Home'],
          ),
        ),
        1,
      );

      // Edited in place: both of its rows gain the new tag.
      final saved = p.rules.first;
      final edited = saved.copyWith(tags: ['Home', 'Bulk']);
      expect(p.ruleExtrasChangeCount(edited, replacingRuleId: saved.id), 2);
      expect(await changedBy(() => p.updateRule(edited)), 2);

      // A new pair, saved one rule after the other.
      const out = ClassifierRule(
        id: 'new',
        pattern: 'meeravalli',
        categoryId: 'food',
        payee: 'Meera',
      );
      final back = out.copyWith(categoryId: 'salary');
      expect(p.ruleExtrasChangeCount(out), 1);
      expect(p.ruleExtrasChangeCount(out, twin: back), 2);
      expect(
        await changedBy(() async {
          await p.addRule('meeravalli', 'food', payee: 'Meera');
          await p.addRule('meeravalli', 'salary', payee: 'Meera');
        }),
        2,
      );
    });

    test('a rule in a transfer category fills no Paid to and still adds its '
        'tags', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('t1', 'Rs 250 paid to QUILLFERN CHIT'),
      ]);
      const candidate = ClassifierRule(
        id: 'new',
        pattern: 'quillfern',
        categoryId: kSavingsTransferCategoryId,
        payee: 'Quillfern Chit',
        tags: ['Chit'],
      );
      expect(p.ruleExtrasChangeCount(candidate), 1);
      // The Paid to alone changes no row.
      expect(p.ruleExtrasChangeCount(candidate.copyWith(tags: const [])), 0);

      await p.addRule(
        'quillfern',
        kSavingsTransferCategoryId,
        payee: 'Quillfern Chit',
        tags: ['Chit'],
      );
      expect(row(p, 't1').categoryId, kSavingsTransferCategoryId);
      expect(row(p, 't1').payee, isEmpty);
      expect(row(p, 't1').tags, ['Chit']);

      // A new import the same.
      await p.addImported([
        alert('Rs 320.00 debited to QUILLFERN CHIT. Ref R1'),
      ]);
      final imported = [
        ...p.transactions,
        ...p.pendingTransactions,
      ].singleWhere((t) => t.id != 't1');
      expect(imported.categoryId, kSavingsTransferCategoryId);
      expect(imported.payee, isEmpty);
      expect(imported.tags, ['Chit']);
    });

    test('a Paid to is not filled where it would rename the merchant a row '
        'goes by', () async {
      final p = await loaded();
      await p.restoreTransactions([
        // The alert names no merchant: the row goes by its note.
        smsRow(
          'noted',
          'Rs 250 debited for QUILLFERN order 4411',
          note: 'Milk round',
        ),
        // No merchant and no note: the row goes by nothing yet.
        smsRow('bare', 'Rs 250 debited for QUILLFERN order 4412'),
        // The alert names the merchant, whatever the Paid to says.
        smsRow('named', 'Rs 250 paid to QUILLFERN DAIRY'),
        // A note that reads as the Paid to does.
        smsRow(
          'same',
          'Rs 250 debited for QUILLFERN order 4413',
          note: 'quillfern dairy',
        ),
      ]);
      expect(alertMerchantOf(row(p, 'noted')), isEmpty);
      expect(merchantIdentityOf(row(p, 'noted')), 'milk round');
      expect(merchantIdentityOf(row(p, 'bare')), isNull);
      expect(alertMerchantOf(row(p, 'named')), isNotEmpty);
      final keys = {
        for (final id in ['noted', 'named', 'same'])
          id: subscriptionKeyOf(row(p, id)),
      };
      expect(keys['noted'], 'expense|milk round');

      const candidate = ClassifierRule(
        id: 'new',
        pattern: 'quillfern',
        categoryId: 'food',
        payee: 'Quillfern Dairy',
        tags: ['Milk'],
      );
      // All four take the tag; without it, the noted row does not change.
      expect(p.ruleExtrasChangeCount(candidate), 4);
      expect(p.ruleExtrasChangeCount(candidate.copyWith(tags: const [])), 3);

      await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Dairy',
        tags: ['Milk'],
      );
      expect(row(p, 'noted').payee, isEmpty);
      expect(row(p, 'noted').tags, ['Milk']);
      expect(row(p, 'bare').payee, 'Quillfern Dairy');
      expect(row(p, 'named').payee, 'Quillfern Dairy');
      expect(row(p, 'same').payee, 'Quillfern Dairy');
      for (final id in keys.keys) {
        expect(subscriptionKeyOf(row(p, id)), keys[id], reason: id);
      }
    });

    test('Restore built-in rules resets a built-in that was given a Paid '
        'to', () async {
      final p = await loaded();
      final builtin = p.rules.firstWhere((r) => r.isBuiltIn);
      await p.updateRule(builtin.copyWith(payee: 'Quillfern Teas'));
      expect(p.rules.firstWhere((r) => r.id == builtin.id).setsMore, isTrue);

      expect(await p.restoreDefaultRules(), 1);
      expect(p.rules.firstWhere((r) => r.id == builtin.id).setsMore, isFalse);
      expect(await p.restoreDefaultRules(), 0);

      await p.updateRule(builtin.copyWith(tags: ['Office']));
      expect(await p.restoreDefaultRules(), 1);
    });
  });

  group('what a rule reaches (ruleUses)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    Future<FinanceProvider> loaded() async {
      final p = FinanceProvider();
      await p.load();
      return p;
    }

    // A counted SMS row, by default one no rule has sorted yet.
    Tx smsRow(
      String id,
      String body, {
      int day = 12,
      TxType type = TxType.expense,
      String? categoryId,
      bool pending = false,
      bool suspectedSpam = false,
      bool userCategorized = false,
    }) => Tx(
      id: id,
      type: type,
      categoryId:
          categoryId ??
          (type == TxType.income ? 'other_income' : 'other_expense'),
      amount: 250,
      note: '',
      date: DateTime(2026, 9, day, 13),
      source: TxSource.sms,
      smsBody: body,
      sender: 'AD-DEMOBK',
      pending: pending,
      suspectedSpam: suspectedSpam,
      userCategorized: userCategorized,
    );

    String idOf(FinanceProvider p, String pattern) =>
        p.rules.firstWhere((r) => r.pattern == pattern).id;

    test('counts each rule\'s rows and keeps the latest date', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('q1', 'Rs 250 paid to QUILLFERN', day: 4),
        smsRow('q2', 'Rs 250 paid to QUILLFERN again', day: 21),
        smsRow('q3', 'Rs 250 paid to QUILLFERN once more', day: 9),
        smsRow('m1', 'Rs 250 paid to MAPLEWORTH', day: 2),
        smsRow('s1', 'Rs 250 paid to SWIGGY', day: 15),
        smsRow('none', 'Rs 250 paid to a name no rule knows'),
      ]);
      await p.addRule('quillfern', 'food');
      await p.addRule('mapleworth', 'shopping');
      await p.addRule('meeravalli', 'food');

      final uses = p.ruleUses;
      expect(uses[idOf(p, 'quillfern')], (
        count: 3,
        last: DateTime(2026, 9, 21, 13),
      ));
      expect(uses[idOf(p, 'mapleworth')], (
        count: 1,
        last: DateTime(2026, 9, 2, 13),
      ));
      // A built-in rule is counted like any other.
      expect(uses[idOf(p, 'swiggy')], (
        count: 1,
        last: DateTime(2026, 9, 15, 13),
      ));
      // A rule that wins no row has no entry.
      expect(uses.containsKey(idOf(p, 'meeravalli')), isFalse);
      expect(uses, hasLength(3));
      // Worked out once per change.
      expect(identical(p.ruleUses, uses), isTrue);
    });

    test('the first rule that matches wins the row, and only a rule of the '
        'row\'s direction', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('both', 'Rs 250 paid to QUILLFERN MAPLEWORTH'),
        smsRow('one', 'Rs 250 paid to QUILLFERN', day: 14),
        smsRow(
          'in',
          'Rs 250 received from QUILLFERN',
          day: 16,
          type: TxType.income,
        ),
      ]);
      await p.addRule('quillfern', 'food');
      // A newer rule goes above the older one.
      await p.addRule('mapleworth', 'shopping');
      expect(p.rules.first.pattern, 'mapleworth');

      var uses = p.ruleUses;
      expect(uses[idOf(p, 'mapleworth')]!.count, 1);
      expect(uses[idOf(p, 'quillfern')], (
        count: 1,
        last: DateTime(2026, 9, 14, 13),
      ));

      // An income rule for the same word, on top: it takes the money-in
      // row and leaves the spending rows with the rule below it.
      await p.addRule('quillfern', 'other_income');
      final incomeRule = p.rules.first;
      expect(incomeRule.categoryId, 'other_income');
      uses = p.ruleUses;
      expect(uses[incomeRule.id], (count: 1, last: DateTime(2026, 9, 16, 13)));
      final spendRule = p.rules.firstWhere(
        (r) => r.pattern == 'quillfern' && r.categoryId == 'food',
      );
      expect(uses[spendRule.id]!.count, 1);
    });

    test('spam suspects, rows added by hand and rows with no alert text are '
        'left out; a row waiting for review counts', () async {
      final p = await loaded();
      await p.addRule('quillfern', 'food');
      await p.restoreTransactions([
        smsRow(
          'suspect',
          'Rs 250 paid to QUILLFERN today',
          pending: true,
          suspectedSpam: true,
        ),
        smsRow('restored', ''),
        Tx(
          id: 'manual',
          type: TxType.expense,
          categoryId: 'food',
          amount: 250,
          note: 'quillfern',
          date: DateTime(2026, 9, 12, 13),
        ),
      ]);
      expect(p.ruleUses, isEmpty);

      // Waiting for review, the row is already one the rule reaches.
      await p.restoreTransactions([
        smsRow('waiting', 'Rs 250 paid to QUILLFERN', day: 14, pending: true),
      ]);
      final id = idOf(p, 'quillfern');
      expect(p.ruleUses[id], (count: 1, last: DateTime(2026, 9, 14, 13)));
      // Confirmed, it still counts once.
      await p.confirmTransaction('waiting');
      expect(p.ruleUses[id]!.count, 1);
    });

    test('a rule in a transfer category, whose rows always wait for review, '
        'shows them', () async {
      final p = await loaded();
      await p.addRule('quillfern', kSavingsTransferCategoryId);
      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 320,
          merchant: 'DEMO',
          date: DateTime(2026, 9, 18, 10),
          ref: 'R1',
          categoryId: 'other_expense',
          sender: 'AD-DEMOBK',
          rawBody: 'Rs 320.00 debited to QUILLFERN. Ref R1',
        ),
      ]);
      final row = p.pendingTransactions.single;
      expect(row.categoryId, kSavingsTransferCategoryId);
      expect(p.ruleUses[idOf(p, 'quillfern')], (
        count: 1,
        last: DateTime(2026, 9, 18, 10),
      ));
    });

    test('a row whose category was picked by hand still counts', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow(
          'hand',
          'Rs 250 paid to QUILLFERN',
          categoryId: 'shopping',
          userCategorized: true,
        ),
      ]);
      await p.addRule('quillfern', 'food');
      expect(p.transactions.single.categoryId, 'shopping');
      expect(p.ruleUses[idOf(p, 'quillfern')], (
        count: 1,
        last: DateTime(2026, 9, 12, 13),
      ));
    });

    test('a spam rule has no entry, and keeps the rows it wins from the '
        'rules below it', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('kept', 'Rs 250 paid to QUILLFERN MEERAVALLI'),
        smsRow('plain', 'Rs 250 paid to QUILLFERN', day: 14),
      ]);
      await p.addRule('quillfern', 'food');
      await p.addRule('meeravalli', kSpamCategoryId);
      // A counted row that is no longer new is not dropped by a spam rule.
      expect(p.transactions, hasLength(2));

      final uses = p.ruleUses;
      expect(uses.containsKey(idOf(p, 'meeravalli')), isFalse);
      expect(uses[idOf(p, 'quillfern')], (
        count: 1,
        last: DateTime(2026, 9, 14, 13),
      ));
    });

    test('the map follows a new import and a rule edit', () async {
      final p = await loaded();
      await p.restoreTransactions([
        smsRow('q1', 'Rs 250 paid to QUILLFERN', day: 4),
        smsRow('m1', 'Rs 250 paid to MAPLEWORTH', day: 6),
      ]);
      await p.addRule('quillfern', 'food');
      final id = idOf(p, 'quillfern');
      expect(p.ruleUses[id], (count: 1, last: DateTime(2026, 9, 4, 13)));

      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 320,
          merchant: 'DEMO',
          date: DateTime(2026, 9, 18, 10),
          ref: 'R1',
          categoryId: 'other_expense',
          sender: 'AD-DEMOBK',
          rawBody: 'Rs 320.00 debited to QUILLFERN. Ref R1',
        ),
      ]);
      // Counted at once or confirmed from review, the row is in.
      await p.confirmAllPending();
      expect(p.ruleUses[id], (count: 2, last: DateTime(2026, 9, 18, 10)));

      // The rule's words changed: it now reaches the other row only.
      await p.updateRule(
        p.rules.firstWhere((r) => r.id == id).copyWith(pattern: 'mapleworth'),
      );
      expect(p.ruleUses, {id: (count: 1, last: DateTime(2026, 9, 6, 13))});

      await p.deleteRule(id);
      expect(p.ruleUses, isEmpty);
    });
  });
}
