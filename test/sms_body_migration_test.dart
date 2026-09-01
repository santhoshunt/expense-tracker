import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';

const _body = 'Rs.100 debited from a/c XX4321 on 01-07-26. Avl Bal Rs.7000.';

Tx _legacySmsTx({String id = 's1', String note = _body}) => Tx(
  id: id,
  type: TxType.expense,
  categoryId: 'other_expense',
  amount: 100,
  note: note,
  date: DateTime(2026, 7, 1, 10),
  source: TxSource.sms,
  sender: 'VM-ICICIB',
);

ParsedTxn _parsed({
  String ref = 'R1',
  String rawBody = 'Rs.100 debited at SWIGGY',
}) => ParsedTxn(
  type: TxType.expense,
  amount: 100,
  merchant: 'SWIGGY',
  date: DateTime(2026, 7, 1, 13),
  ref: ref,
  categoryId: 'other_expense',
  sender: 'VM-HDFCBK',
  rawBody: rawBody,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load migration moves the SMS body from note to smsBody', () async {
    final manual = Tx(
      id: 'm1',
      type: TxType.expense,
      categoryId: 'food',
      amount: 50,
      note: 'lunch with team',
      date: DateTime(2026, 7, 2, 12),
    );
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([_legacySmsTx().toJson(), manual.toJson()]),
      'accounts_migrated_v1': true,
      'accounts_migrated_v2': true,
      'accounts_migrated_v3': true,
      'accounts_migrated_v4': true,
    });
    final p = FinanceProvider();
    await p.load();

    Tx byId(String id) => p.transactions.firstWhere((t) => t.id == id);
    expect(byId('s1').smsBody, _body);
    expect(byId('s1').note, '');
    // Manual rows keep their note — nothing to move.
    expect(byId('m1').note, 'lunch with team');
    expect(byId('m1').smsBody, '');

    // One-shot and idempotent: a second load changes nothing further.
    final p2 = FinanceProvider();
    await p2.load();
    final again = p2.transactions.firstWhere((t) => t.id == 's1');
    expect(again.smsBody, _body);
    expect(again.note, '');
  });

  test('body move runs after the account migrations, which still see the '
      'body via the note fallback', () async {
    // NO migration flags: v1 must derive the account key and balance from
    // the body while it still lives in note, then v5 relocates it.
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([_legacySmsTx().toJson()]),
    });
    final p = FinanceProvider();
    await p.load();

    final acc = p.accounts.single;
    expect(acc.keys, contains('ICICI:4321'));
    expect(p.accountBalance(acc), 7000);
    final t = p.transactions.single;
    expect(t.acctKey, 'ICICI:4321');
    expect(t.balanceAfter, 7000);
    expect(t.smsBody, _body);
    expect(t.note, '');
  });

  test('pre-v5 backups normalize on import; v5 backups are trusted', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();

    await p.importData({
      'app': 'expense_tracker',
      'version': 4,
      'transactions': [_legacySmsTx().toJson()],
    }, replace: true);
    expect(p.transactions.single.smsBody, _body);
    expect(p.transactions.single.note, '');

    // A v5 payload where an sms row carries a genuine user note must keep it.
    await p.importData({
      'app': 'expense_tracker',
      'version': 5,
      'transactions': [
        {
          'id': 's2',
          'type': 'expense',
          'categoryId': 'other_expense',
          'amount': 100,
          'note': 'my own words',
          'smsBody': _body,
          'date': '2026-07-01T10:00:00.000',
          'source': 'sms',
          'sender': 'VM-ICICIB',
        },
      ],
    }, replace: true);
    expect(p.transactions.single.note, 'my own words');
    expect(p.transactions.single.smsBody, _body);
  });

  test('CSV export omits SMS text entirely', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([_parsed(rawBody: _body)]);
    await p.confirmTransaction(p.pendingTransactions.single.id);

    final csv = BackupService.buildCsv(p);
    final header = csv.split('\r\n').first;
    expect(header, isNot(contains('smsBody')));
    expect(header, contains('categoryName'));
    // The alert text must not appear anywhere in the file — not in its own
    // column, and not leaked into the note column either.
    expect(csv, isNot(contains('Avl Bal')));

    final restored = BackupService.txsFromCsv(csv).single;
    expect(restored.smsBody, isEmpty);
    expect(restored.note, isEmpty);
  });

  test(
    're-importing a current-format CSV keeps the user note in place',
    () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();
      await p.addImported([_parsed(rawBody: _body)]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      await p.updateTransaction(
        p.transactions.single.copyWith(note: 'my own words'),
      );

      // categoryName marks the file as new-format, so the legacy
      // note → smsBody migration must NOT fire on an sms-source row.
      final restored = BackupService.txsFromCsv(
        BackupService.buildCsv(p),
      ).single;
      expect(restored.source, TxSource.sms);
      expect(restored.note, 'my own words');
      expect(restored.smsBody, isEmpty);
    },
  );

  test('column-less legacy CSVs normalize the note into smsBody', () async {
    // Old export shape: body in the note column, no smsBody column.
    final legacyCsv =
        'id,date,type,category,amount,note,sender,source\r\n'
        '"s1","2026-07-01T10:00:00.000","expense","other_expense",100,'
        '"$_body","VM-ICICIB","sms"\r\n'
        '"m1","2026-07-02T12:00:00.000","expense","food",50,'
        '"lunch with team","","manual"';
    final legacy = BackupService.txsFromCsv(legacyCsv);
    final sms = legacy.firstWhere((t) => t.id == 's1');
    final manual = legacy.firstWhere((t) => t.id == 'm1');
    expect(sms.smsBody, _body);
    expect(sms.note, '');
    expect(manual.note, 'lunch with team');
    expect(manual.smsBody, '');
  });

  test('CSVs from the old exporter still restore smsBody verbatim', () async {
    // The smsBody column is no longer written, but files that have it must
    // keep round-tripping — and their notes must be left alone.
    final oldCsv =
        'id,date,type,category,amount,note,sender,source,smsBody\r\n'
        '"s1","2026-07-01T10:00:00.000","expense","other_expense",100,'
        '"my own words","VM-ICICIB","sms","$_body"';
    final restored = BackupService.txsFromCsv(oldCsv).single;
    expect(restored.smsBody, _body);
    expect(restored.note, 'my own words');
  });

  test('classifier rules match the SMS body, not the user note', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      _parsed(ref: 'A', rawBody: 'Rs.100 paid at CHAI KINGS via UPI'),
    ]);
    await p.confirmTransaction(p.pendingTransactions.single.id);

    // The user writes their own note over the confirmed row.
    final tx = p.transactions.single;
    await p.updateTransaction(tx.copyWith(note: 'evening snacks'));

    // A rule matching the body re-categorizes the row…
    await p.addRule('chai kings', 'food');
    expect(p.transactions.single.categoryId, 'food');

    // …and a rule matching only the user note does not.
    await p.addRule('evening snacks', 'shopping');
    expect(p.transactions.single.categoryId, 'food');
  });

  test('assign guard reads the body through the fallback for un-normalized '
      'rows', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    final hdfc = await p.addAccount(name: 'HDFC', type: AccountType.bank);
    await p.addAccountKey(hdfc, 'HDFC:1234');
    final other = await p.addAccount(name: 'Other', type: AccountType.bank);

    // importTransactions bypasses normalization by design — the body still
    // sits in note, and the guard must find it there.
    final legacy = Tx(
      id: 'x1',
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 100,
      note: 'Rs.100 debited from a/c XX1234. Avl Bal Rs.5000.',
      date: DateTime(2026, 7, 1, 10),
      source: TxSource.sms,
      sender: 'VM-HDFCBK',
      balanceAfter: 5000,
    );
    await p.importTransactions([legacy], replace: false);

    // Its own SMS names an account the target owns → the anchor travels.
    await p.assignAccount('x1', hdfc);
    expect(p.transactions.firstWhere((t) => t.id == 'x1').balanceAfter, 5000);

    // Moved on to a foreign account → the anchor must not follow.
    await p.assignAccount('x1', other);
    expect(p.transactions.firstWhere((t) => t.id == 'x1').balanceAfter, isNull);
  });

  test(
    'smsBody survives edits and JSON round-trips; key omitted when empty',
    () async {
      final sms = _legacySmsTx().migrateSmsBodyFromNote();
      expect(sms.smsBody, _body);

      // The edit sheet's save path can never clobber the raw SMS.
      final edited = sms.copyWith(note: 'user text', amount: 120);
      expect(edited.smsBody, _body);
      expect(edited.note, 'user text');

      final roundTrip = Tx.fromJson(
        jsonDecode(jsonEncode(edited.toJson())) as Map<String, dynamic>,
      );
      expect(roundTrip.smsBody, _body);
      expect(roundTrip.note, 'user text');

      // Manual rows pay nothing for the new field.
      final manual = Tx(
        id: 'm1',
        type: TxType.expense,
        categoryId: 'food',
        amount: 50,
        note: 'lunch',
        date: DateTime(2026, 7, 2, 12),
      );
      expect(manual.toJson().containsKey('smsBody'), isFalse);
      expect(manual.migrateSmsBodyFromNote(), same(manual));
    },
  );
}
