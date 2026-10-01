import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

/// Alert shapes from published samples of banks across India, reworded
/// and with made-up numbers, plus the one-time re-derivation of stored rows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final smsDate = DateTime(2026, 9, 12, 10, 30);

  ParsedTxn parse(String sender, String body) =>
      SmsTxnParser.parse(sender, body, smsDate, relaxedSender: true)!;

  group('account key', () {
    test('ICICI "Acc XX512" keys the account and keeps the balance', () {
      final r = parse(
        'JD-ICICIT-S',
        'ICICI Bank Acc XX512 debited Rs. 2,150.00 on 12-Sep-26 '
            'InfoBIL*INFT*ABC1.Avl Bal Rs. 8,400.10.To dispute call '
            '18002662 or SMS BLOCK 512 to 9215676766',
      );
      expect(r.type, TxType.expense);
      expect(r.amount, 2150);
      expect(r.acctKey, 'ICICI:512');
      expect(r.balanceAfter, 8400.10);
    });

    test('a mask ending in more digits takes the last four', () {
      expect(
        parse(
          'VM-PNBSMS',
          'Your A/c XXXXXXXX00341234 debited INR 500.00 on 01-09-26.',
        ).acctKey,
        'PNB:1234',
      );
      expect(
        parse(
          'VM-INDUSB',
          'INR 1,101.53 debited from your A/C 201***123456 on 02-09-26.',
        ).acctKey,
        'INDUS:3456',
      );
    });

    test('a mask straight after the keyword', () {
      expect(
        parse(
          'VM-BOIIND',
          'Rs.300.00 debited A/cXX5468 on 03-09-26 towards UPI.',
        ).acctKey,
        'BOI:5468',
      );
    });

    test("the remitter's account is not the user's", () {
      final r = parse(
        'VM-CANBNK',
        'An amount of INR 5,000.00 has been credited to XXXX6785 on '
            '04-09-26 towards NEFT. Sender A/c XXXX9108, AXIS BANK. Total '
            'Avail.Bal INR 12,000.00',
      );
      expect(r.type, TxType.income);
      expect(r.acctKey, 'CANBNK:6785');
      expect(r.balanceAfter, 12000);
    });

    test('a bare account number is never sliced', () {
      expect(
        parse(
          'VM-AUBANK',
          'Rs.250.00 debited from A/c 1234567890 on 05-09-26.',
        ).acctKey,
        isNull,
      );
    });
  });

  group('amount and balance', () {
    test('"Rs..50" is 50 paise, not the balance', () {
      final r = parse(
        'AD-UCOBNK',
        'Your UCO Bank A/c XX4321 has been Debited with Rs..50 by '
            'Transfer.Avl Bal in your A/c is Rs.1,234.56.',
      );
      expect(r.amount, 0.5);
      expect(r.acctKey, 'UCO:4321');
    });

    test('SBI "debited by 150.0" has no currency prefix', () {
      final r = parse(
        'AD-SBIUPI',
        'Dear UPI user A/C X1234 debited by 150.0 on date 05Sep26 trf to '
            'SWIGGY Refno 406512345678. If not u? call 1800111109',
      );
      expect(r.amount, 150);
      expect(r.type, TxType.expense);
      expect(r.acctKey, 'SBI:1234');
      expect(r.ref, '406512345678');
    });

    test('Union "Rs:354.00" and an unprefixed "Bal"', () {
      final r = parse(
        'VM-UNIONB',
        'Your SB A/c *1234 Debited for Rs:354.00 on 09-09-26 by Charges. '
            'Bal Rs:12,000.00',
      );
      expect(r.amount, 354);
      expect(r.acctKey, 'UNION:1234');
      expect(r.balanceAfter, 12000);
    });

    test('a minimum balance threshold is not the balance', () {
      final r = parse(
        'VM-HDFCBK',
        'Rs.500.00 debited from A/c XX1234 towards non-maintenance of '
            'Minimum Average Balance Rs.5000.00',
      );
      expect(r.amount, 500);
      expect(r.balanceAfter, isNull);
    });
  });

  group('direction', () {
    test('"Dr." and "Cr." before an amount', () {
      final dr = parse(
        'VM-CANBNK',
        'Acct XX1234 Dr. INR 260.00 on 07-09-26 towards UPI. '
            'Bal INR 5,000.00 CR',
      );
      expect(dr.type, TxType.expense);
      expect(dr.amount, 260);
      expect(dr.balanceAfter, 5000);
      final cr = parse(
        'VM-AUBANK',
        'Rs.500.00 Cr. to A/c XX9876 on 08-09-26 by NEFT.',
      );
      expect(cr.type, TxType.income);
    });

    test('"<payee> has received … from your A/c" is money out', () {
      final r = parse(
        'AD-FEDBNK',
        'ACME TRADERS has received Rs 600.00 from your A/c XX3343 via NEFT '
            'on 05-09-26. Ref no. FDRLM12345678',
      );
      expect(r.type, TxType.expense);
      expect(r.acctKey, 'FEDBNK:3343');
      expect(r.ref, 'FDRLM12345678');
    });

    test('"credited to the beneficiary account" is money out', () {
      final r = parse(
        'VM-ICICIB',
        'ICICI BANK NEFT Transaction with reference number IN1234567890 '
            'for Rs. 2,050.00 has been credited to the beneficiary account '
            'on 06-09-26',
      );
      expect(r.type, TxType.expense);
      expect(r.ref, 'IN1234567890');
    });

    test('cashback "sent to your" account is money in', () {
      final r = parse(
        'VM-KOTAKB',
        'Cashback of Rs.50.00 has been sent to your Kotak Bank A/c x5555. '
            'Credited on 14-09-26',
      );
      expect(r.type, TxType.income);
      expect(r.acctKey, 'KOTAK:5555');
    });

    test('HDFC "Txn Rs.X On … Card" is a spend', () {
      final r = parse(
        'VM-HDFCBK',
        'Txn Rs.506.90 On HDFC Bank Card 8174 At SHOP@ybl by UPI '
            '512345678901 On 10-09',
      );
      expect(r.type, TxType.expense);
      expect(r.acctKey, 'HDFC:8174');
      expect(r.isCard, isTrue);
    });

    test('"will be reversed if unauthorised" stays a debit', () {
      final r = parse(
        'VM-HDFCBK',
        'Rs.200.00 debited from A/c XX1234 on 01-09-26. If unauthorised, '
            'it will be reversed.',
      );
      expect(r.type, TxType.expense);
    });

    test('"Rs.1100credited" with no space', () {
      final r = parse(
        'AD-FEDBNK',
        'Hi,Rs.1100credited in your A/c XX7788 on 11-09-26 by IMPS.',
      );
      expect(r.type, TxType.income);
      expect(r.amount, 1100);
    });
  });

  group('should not import', () {
    for (final body in [
      'Payment of INR 1,577 on Kotak Credit Card xx2222 is due on '
          '13-10-26. Min due: INR 100. Ignore if paid.',
      // Has a debit verb, so only the phrase keeps it out.
      'Rs 14,972 is blocked in A/c XX1234 for the IPO; it is debited only '
          'on allotment.',
      'NACH Mandate : Rs. 100000.00 UMRN:HDFC0000000123 received today '
          'for processing.',
    ]) {
      test(body.substring(0, 30), () {
        expect(SmsTxnParser.parse('VM-HDFCBK', body, smsDate), isNull);
      });
    }
  });

  group('ref', () {
    test('a word after "UPI" is not a ref', () {
      expect(
        parse(
          'VM-HDFCBK',
          'Rs.99.00 debited from A/c XX1234 for UPI Mandate AutoPay '
              'Retrieval Ref No.371940562813',
        ).ref,
        '371940562813',
      );
    });
  });

  group('readings that must not change meaning', () {
    test('a UPI ID is the payee, never the ref', () {
      expect(
        parse(
          'VM-HDFCBK',
          'Rs.200.00 debited from A/c XX1234 to UPI ID shop123@ybl on '
              '12-09-26. UPI Ref 612345678901',
        ).ref,
        '612345678901',
      );
    });

    test('an outstanding loan figure is not the balance', () {
      final r = parse(
        'VM-HDFCBK',
        'Rs.5,000.00 debited from A/c XX1234 towards EMI of Loan A/c XX9999. '
            'Outstanding Bal Rs.2,45,000.00',
      );
      expect(r.amount, 5000);
      expect(r.balanceAfter, isNull);
      expect(r.acctKey, 'HDFC:1234');
    });

    test('the Avl figure wins over an earlier bare one', () {
      expect(
        SmsTxnParser.balanceAfterOf(
          'Total Outstanding Bal Rs.12,000. Avl Lmt Rs.88,000',
        ),
        88000,
      );
    });

    test('a dot before a whole amount is not paise', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'INR.5000.00 debited from A/c XX1234 on 12-09-26.',
        smsDate,
      );
      expect(r?.amount, 5000);
    });

    test("a remitter's masked account is not the user's", () {
      expect(
        parse(
          'VM-HDFCBK',
          'Rs.500.00 received from XXXXXX7890 via IMPS on 12-09-26.',
        ).acctKey,
        isNull,
      );
    });

    test('money "sent to your" card beside a debit stays a debit', () {
      final r = parse(
        'VM-HDFCBK',
        'INR 10,000.00 debited from A/c XX1234. Amount sent to your Credit '
            'Card XX5678 will be credited within 24 hrs.',
      );
      expect(r.type, TxType.expense);
    });

    test('"Rs 1 Cr to spend" is no credit', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Win Rs 1 Cr to spend on your next trip',
        smsDate,
      );
      expect(r, isNull);
    });

    test('a rewards balance is not the account balance', () {
      expect(
        SmsTxnParser.balanceAfterOf(
          'Rs.100.00 spent on HDFC Bank Card 1234. Rewards Bal 500',
        ),
        isNull,
      );
    });

    test('"Txn … will be reversed if unauthorised" is a spend', () {
      final r = parse(
        'VM-HDFCBK',
        'Txn Rs.300.00 On HDFC Bank Card 1234 At SHOP on 12-09-26. Will be '
            'reversed if unauthorised.',
      );
      expect(r.type, TxType.expense);
    });

    test('details "sent to your registered email" stay a debit', () {
      final r = parse(
        'VM-HDFCBK',
        'Rs.2,000.00 debited from A/c XX1234 on 12-09-26. Amount credited to '
            'beneficiary. Transaction details sent to your registered email.',
      );
      expect(r.type, TxType.expense);
    });

    test("a balance's CR is no credit", () {
      final r = parse(
        'VM-PNBSMS',
        'Avl Bal INR 5,000.00 CR. INR 200.00 debited from A/c XX1234 on '
            '12-09-26.',
      );
      expect(r.type, TxType.expense);
      expect(r.amount, 200);
      expect(r.balanceAfter, 5000);
    });

    test('"Txn … credited … as refund" is money in', () {
      final r = parse(
        'VM-HDFCBK',
        'Txn Rs.500.00 credited to HDFC Bank Card 1234 on 12-09-26 as refund.',
      );
      expect(r.type, TxType.income);
    });
  });

  group('banks by name', () {
    test('Indian Bank is one bank among the banks in India', () {
      expect(SmsTxnParser.bankCodeOf('Indian Bank'), 'INDBNK');
      expect(SmsTxnParser.bankCodeOf('VM-INDBNK'), 'INDBNK');
      expect(SmsTxnParser.bankCodeOf('South Indian Bank'), 'SIBSMS');
      expect(SmsTxnParser.bankCodeOf('VM-SIBSMS'), 'SIBSMS');
      expect(SmsTxnParser.bankCodeOf('Indian Overseas Bank'), 'IOB');
      expect(SmsTxnParser.bankCodeOf('Bank of India'), 'BOI');
      expect(SmsTxnParser.bankCodeOf('Central Bank of India'), 'CENTBK');
      expect(SmsTxnParser.bankCodeOf('Union Bank of India'), 'UNION');
      expect(SmsTxnParser.bankCodeOf('State Bank of India'), 'SBI');
      expect(SmsTxnParser.dedupBankOf('South Indian Bank'), 'SIBSMS');
      expect(SmsTxnParser.dedupBankOf('VM-SIBSMS'), 'SIBSMS');
    });

    test("a South Indian Bank fragment in an Indian Bank alert is foreign", () {
      const body =
          'NEFT of Rs.500.00 credited to South Indian Bank A/c XX1234 from '
          'your a/c XX2222 on 12-09-26.';
      expect(SmsTxnParser.accountKeyOf('VM-INDBNK', body).$1, 'INDBNK:2222');
      // What 1.27 stored, for the migration to recognise.
      expect(
        SmsTxnParser.accountKeyOfV127('VM-INDBNK', body).$1,
        'INDBNK:1234',
      );
    });
  });

  group('re-derivation of stored rows (v5)', () {
    Map<String, Object> prefs(List<Tx> txs, List<Account> accounts) => {
      'transactions_v1': jsonEncode([for (final t in txs) t.toJson()]),
      'accounts_v1': jsonEncode([for (final a in accounts) a.toJson()]),
      'accounts_migrated_v1': true,
      'accounts_migrated_v2': true,
      'accounts_migrated_v3': true,
      'accounts_migrated_v4': true,
    };
    Tx sms(
      String id,
      String sender,
      String body, {
      String? key,
      String? ref,
      double? balance,
    }) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 100,
      note: '',
      smsBody: body,
      date: DateTime(2026, 9, 1, 10),
      source: TxSource.sms,
      sender: sender,
      acctKey: key,
      externalRef: ref,
      balanceAfter: balance,
    );
    Future<FinanceProvider> load() async {
      final p = FinanceProvider();
      await p.load();
      return p;
    }

    Tx byId(FinanceProvider p, String id) => [
      ...p.transactions,
      ...p.pendingTransactions,
    ].firstWhere((t) => t.id == id);

    test(
      'a machine key follows the new derivation on the same account',
      () async {
        SharedPreferences.setMockInitialValues(
          prefs(
            [
              sms(
                'i',
                'VM-INDUSB',
                'INR 1,101.53 debited from your A/C 201***123456 on 02-09-26.',
                key: 'INDUS:201',
              ),
            ],
            [
              Account(
                id: 'acc_i',
                name: 'INDUS ••201',
                type: AccountType.bank,
                keys: {'INDUS:201'},
                manualBalance: 5000,
                manualBalanceAt: DateTime(2026, 8, 1),
              ),
            ],
          ),
        );
        final p = await load();
        expect(byId(p, 'i').acctKey, 'INDUS:3456');
        expect(p.accounts, hasLength(1));
        final a = p.accounts.single;
        expect(a.keys, containsAll(['INDUS:201', 'INDUS:3456']));
        expect(a.name, 'INDUS ••3456');
        expect(a.manualBalance, 5000);
      },
    );

    test(
      'an unkeyed ICICI "Acc" row joins its account with its balance',
      () async {
        SharedPreferences.setMockInitialValues(
          prefs(
            [
              sms(
                'c',
                'JD-ICICIT-S',
                'ICICI Bank Acc XX246 debited Rs. 100.00 on 01-Sep-26 '
                    'InfoBIL*INFT*ABC1.Avl Bal Rs. 9,876.45.',
                // As 1.27 imported it: the figure read, no account.
                balance: 9876.45,
              ),
              // A figure only the new patterns read joins it too.
              sms(
                'n',
                'JD-ICICIT-S',
                'ICICI Bank Acc XX246 debited Rs. 50.00 on 02-Sep-26. '
                    'Avb Bal Rs. 9,826.45.',
              ),
              // A figure 1.27 read that an edit cleared stays cleared.
              sms(
                'e',
                'JD-ICICIT-S',
                'ICICI Bank Acc XX246 debited Rs. 20.00 on 03-Sep-26. '
                    'Avl Bal Rs. 9,806.45.',
              ),
            ],
            [
              Account(
                id: 'acc_c',
                name: 'ICICI ••246',
                type: AccountType.bank,
                keys: {'ICICI:246'},
              ),
            ],
          ),
        );
        final p = await load();
        expect(byId(p, 'c').acctKey, 'ICICI:246');
        expect(byId(p, 'c').balanceAfter, 9876.45);
        expect(byId(p, 'n').acctKey, 'ICICI:246');
        expect(byId(p, 'n').balanceAfter, 9826.45);
        expect(byId(p, 'e').acctKey, 'ICICI:246');
        expect(byId(p, 'e').balanceAfter, isNull);
        expect(p.accounts, hasLength(1));
      },
    );

    test('one old key for two real accounts splits into two', () async {
      SharedPreferences.setMockInitialValues(
        prefs(
          [
            sms(
              'a',
              'VM-INDUSB',
              'INR 100.00 debited from your A/C 201***123456 on 02-09-26.',
              key: 'INDUS:201',
            ),
            sms(
              'b',
              'VM-INDUSB',
              'INR 200.00 debited from your A/C 201***987654 on 03-09-26.',
              key: 'INDUS:201',
            ),
          ],
          [
            Account(
              id: 'acc_i',
              name: 'Savings',
              type: AccountType.bank,
              keys: {'INDUS:201'},
            ),
          ],
        ),
      );
      final p = await load();
      expect(byId(p, 'a').acctKey, 'INDUS:3456');
      expect(byId(p, 'b').acctKey, 'INDUS:7654');
      final owners = {
        for (final k in ['INDUS:3456', 'INDUS:7654'])
          p.accounts.firstWhere((a) => a.keys.contains(k)).id,
      };
      expect(owners, hasLength(2), reason: 'never fused into one tile');
    });

    test('an old key still in use keeps its account to itself', () async {
      SharedPreferences.setMockInitialValues(
        prefs(
          [
            // 1.27 keyed this self-transfer to the receiving account.
            sms(
              't',
              'VM-BOIIND',
              'Rs.5000.00 debited A/cXX5468 and credited to A/c XX9999 via '
                  'IMPS on 04-09-26.',
              key: 'BOI:9999',
            ),
            sms(
              'r',
              'VM-BOIIND',
              'Rs.100.00 credited to A/c XX9999 on 05-09-26 by NEFT.',
              key: 'BOI:9999',
            ),
          ],
          [
            Account(
              id: 'acc_9',
              name: 'BOI ••9999',
              type: AccountType.bank,
              keys: {'BOI:9999'},
            ),
          ],
        ),
      );
      final p = await load();
      expect(byId(p, 't').acctKey, 'BOI:5468');
      expect(byId(p, 'r').acctKey, 'BOI:9999');
      final nine = p.accounts.firstWhere((a) => a.id == 'acc_9');
      expect(nine.keys, {'BOI:9999'});
      expect(nine.name, 'BOI ••9999');
    });

    test(
      'a newly keyed row does not beat the old account to its key',
      () async {
        SharedPreferences.setMockInitialValues(
          prefs(
            [
              sms(
                'k',
                'VM-INDUSB',
                'INR 100.00 debited from your A/C 201***123456 on 02-09-26.',
                key: 'INDUS:201',
              ),
              // 1.27 read no account here; 1.28 reads the same one.
              sms(
                'u',
                'VM-INDUSB',
                'Sent Rs.50.00 from XXXXXX3456 to SHOP on 03-09-26.',
              ),
            ],
            [
              Account(
                id: 'acc_i',
                name: 'Savings',
                type: AccountType.bank,
                keys: {'INDUS:201'},
              ),
            ],
          ),
        );
        final p = await load();
        expect(p.accounts, hasLength(1));
        expect(byId(p, 'k').acctKey, 'INDUS:3456');
        expect(byId(p, 'u').acctKey, 'INDUS:3456');
        expect(p.accounts.single.keys, contains('INDUS:3456'));
        // Once only: a second start changes nothing.
        final again = await load();
        expect(again.accounts, hasLength(1));
        expect(byId(again, 'u').acctKey, 'INDUS:3456');
      },
    );

    test('hand-made choices stay', () async {
      SharedPreferences.setMockInitialValues(
        prefs(
          [
            // Taken off its account by hand: 1.27 could key it.
            sms('u', 'VM-HDFCBK', 'Rs.100 debited from a/c XX1234.'),
            // Filed under another account by hand.
            sms(
              'h',
              'JD-ICICIT-S',
              'ICICI Bank Acc XX246 debited Rs. 100.00 on 01-Sep-26.',
              key: 'ICICI:999',
            ),
          ],
          [
            Account(
              id: 'acc_h',
              name: 'Joint',
              type: AccountType.bank,
              keys: {'ICICI:999'},
            ),
          ],
        ),
      );
      final p = await load();
      expect(byId(p, 'u').acctKey, isNull);
      expect(byId(p, 'h').acctKey, 'ICICI:999');
    });

    test('a chimera key is cleared and a stale ref refreshed', () async {
      SharedPreferences.setMockInitialValues(
        prefs([
          sms(
            'x',
            'VM-INDBNK',
            'NEFT of Rs.100.00 credited to South Indian Bank A/c XX1234 on '
                '12-09-26.',
            key: 'INDBNK:1234',
          ),
          sms(
            'r',
            'VM-HDFCBK',
            'Rs.99.00 debited from A/c XX1234 for UPI Mandate AutoPay '
                'Retrieval Ref No.371940562813',
            key: 'HDFC:1234',
            ref: 'Mandate',
          ),
        ], const []),
      );
      final p = await load();
      expect(byId(p, 'x').acctKey, isNull);
      expect(byId(p, 'r').externalRef, '371940562813');
    });
  });

  test('a rescan of a stored message does not import it again', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    const body =
        'ACME TRADERS has received Rs 600.00 from your A/c XX3343 via NEFT '
        'on 05-09-26.';
    final at = DateTime(2026, 9, 5, 10);
    ParsedTxn copy(TxType type, String ref) => ParsedTxn(
      type: type,
      amount: 600,
      merchant: 'ACME TRADERS',
      date: at,
      ref: ref,
      categoryId: type == TxType.expense ? 'other_expense' : 'other_income',
      sender: 'AD-FEDBNK',
      rawBody: body,
    );
    // Stored by an older parser as income with another ref…
    await p.addImported([copy(TxType.income, 'OLD123')]);
    // …then read again, now as an expense.
    final (added, _) = await p.addImported([copy(TxType.expense, 'NEW456')]);
    expect(added, 0);
    expect(p.pendingTransactions, hasLength(1));
  });
}
