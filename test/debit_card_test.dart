import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/utils/format.dart';

import 'accounts_test_utils.dart';

/// Debit cards (1.41): a card linked to a bank account moves that bank's
/// balance, and net balance counts the money once. Every bank, number,
/// amount and merchant here is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  const sender = 'VM-ZETABK';
  const cardBody =
      'Your Zeta Bank Debit Card XX5678 was used for Rs.640.00 at '
      'Zeta Mart on 06-09-26.';
  const bankBody =
      'Rs.640.00 debited from a/c XX1234 on 06-09-26 at Zeta Mart.';
  // The keys the parser derives from those alerts.
  final cardKey = SmsTxnParser.accountKeyOf(sender, cardBody).$1!;
  final bankKey = SmsTxnParser.accountKeyOf(sender, bankBody).$1!;

  // In the past, so balances never depend on today's date.
  final sep5 = DateTime(2026, 9, 5, 10);
  final sep6 = DateTime(2026, 9, 6, 10);
  final sep7 = DateTime(2026, 9, 7, 10);

  ParsedTxn alert({
    required DateTime date,
    required double amount,
    required String acctKey,
    String body = bankBody,
    double? avlBal,
    bool debitCard = false,
    TxType type = TxType.expense,
    String? ref,
  }) => ParsedTxn(
    type: type,
    amount: amount,
    merchant: 'Zeta Mart',
    date: date,
    ref: ref,
    categoryId: type == TxType.expense ? 'other_expense' : 'other_income',
    sender: sender,
    rawBody: '$body ${date.toIso8601String()}',
    acctKey: acctKey,
    balanceAfter: avlBal,
    isDebitCard: debitCard,
  );

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Account acct(FinanceProvider p, String key) => p.accountForKey(key)!;

  group('parser', () {
    test('flags a debit card fragment, never an a/c one', () {
      final (key, isCard, isDebit) = SmsTxnParser.accountKeyAndKindOf(
        sender,
        cardBody,
      );
      expect(key, endsWith(':5678'));
      expect(isCard, isFalse);
      expect(isDebit, isTrue);

      final (aKey, aCard, aDebit) = SmsTxnParser.accountKeyAndKindOf(
        sender,
        bankBody,
      );
      expect(aKey, endsWith(':1234'));
      expect(aCard, isFalse);
      expect(aDebit, isFalse);

      // accountKeyOf keeps its shape: key and credit-card-ness.
      expect(SmsTxnParser.accountKeyOf(sender, cardBody), (key, false));
    });

    test('parse() carries the debit card flag', () {
      // A notification sender: the made-up bank's display name.
      final r = SmsTxnParser.parse(
        'Zeta Bank',
        'Your Zeta Bank Debit Card XX9876 was used for Rs.415.00 at '
            'Zeta Mart on 06-09-26.',
        sep6,
        relaxedSender: true,
      );
      expect(r, isNotNull);
      expect(r!.isDebitCard, isTrue);
      final a = SmsTxnParser.parse(
        'Zeta Bank',
        'Rs.415.00 debited from a/c XX4321 on 06-09-26 at Zeta Mart.',
        sep6,
        relaxedSender: true,
      );
      expect(a, isNotNull);
      expect(a!.isDebitCard, isFalse);
    });
  });

  group('figures', () {
    /// A bank (Avl Bal 50,000 on 5 Sep) and a card made as a bank, the way
    /// older builds made one: 1,200 with Avl Bal 48,800 on 6 Sep, then 300
    /// with no figure on 7 Sep.
    Future<(FinanceProvider, String, String)> bankAndOldCard() async {
      final p = await loaded();
      await p.addImported([
        alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
        alert(
          date: sep6,
          amount: 1200,
          acctKey: cardKey,
          body: cardBody,
          avlBal: 48800,
        ),
        alert(date: sep7, amount: 300, acctKey: cardKey, body: cardBody),
      ]);
      await p.confirmAllPending();
      return (p, acct(p, bankKey).id, acct(p, cardKey).id);
    }

    test('linking moves the bank balance by the card, net counts it once, '
        'and unlinking restores', () async {
      final (p, bankId, cardId) = await bankAndOldCard();
      expect(p.accountById(cardId)!.type, AccountType.bank);
      expect(p.accountBalance(p.accountById(bankId)!), 50000);
      // Both stated figures count: the same money twice.
      expect(p.bankBalanceTotal, 50000 + 48500);

      expect(
        await p.setAccountType(
          cardId,
          AccountType.debitCard,
          linkedAccountId: bankId,
        ),
        isTrue,
      );
      final bank = p.accountById(bankId)!;
      final card = p.accountById(cardId)!;
      expect(card.linkedAccountId, bankId);
      expect(p.linkedAccountOf(card)?.id, bankId);
      expect(p.linkedCardsOf(bank).map((a) => a.id), [cardId]);
      // The card's Avl Bal anchors the bank, then its 300 spend lowers it.
      expect(p.accountBalance(bank), 48500);
      expect(p.bankBalanceTotal, 48500);
      expect(p.netWorth, 48500);
      // The bank's rows take in the card's; the card keeps its own.
      expect(p.balanceTransactionCount(bank), 3);
      expect(p.balanceTransactionCount(card), 2);
      expect(p.transactionCountForAccount(bankId), 1);

      expect(await p.linkDebitCard(cardId, null), isTrue);
      expect(p.accountBalance(p.accountById(bankId)!), 50000);
      expect(p.bankBalanceTotal, 50000 + 48500);
      // An unlinked debit card counts like a bank.
      expect(p.accountById(cardId)!.isDebitCard, isTrue);
    });

    test('an Avl Bal on a card alert anchors the bank', () async {
      final p = await loaded();
      await p.addImported([
        alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
        // Made by its alert as a debit card, linked to the one bank.
        alert(
          date: sep6,
          amount: 640,
          acctKey: cardKey,
          body: cardBody,
          avlBal: 47000,
          debitCard: true,
        ),
      ]);
      await p.confirmAllPending();
      final bank = acct(p, bankKey);
      expect(acct(p, cardKey).linkedAccountId, bank.id);
      // 47,000, not 50,000 − 640: the card alert's figure is the bank's.
      expect(p.accountBalance(bank), 47000);
      final prov = p.accountProvenance(bank);
      expect(prov.source, BalanceSource.alert);
      expect(prov.asOf, sep6);
    });

    test('a card alert with Avl Bal, then the bank alert for the same spend '
        'without one, lowers the bank once', () async {
      Future<(FinanceProvider, int)> run({required bool linked}) async {
        final p = await loaded();
        await p.addImported([
          alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
          alert(
            date: sep6,
            amount: 640,
            acctKey: cardKey,
            body: cardBody,
            avlBal: 49360,
            debitCard: true,
          ),
        ]);
        if (!linked) {
          await p.linkDebitCard(acct(p, cardKey).id, null);
        }
        await p.confirmAllPending();
        // The account alert a minute later, after the card's anchor.
        final (added, _) = await p.addImported([
          alert(
            date: sep6.add(const Duration(minutes: 1)),
            amount: 640,
            acctKey: bankKey,
          ),
        ]);
        await p.confirmAllPending();
        return (p, added);
      }

      final (p, added) = await run(linked: true);
      expect(added, 0);
      expect(p.accountBalance(acct(p, bankKey)), 49360);
      expect(p.netWorth, 49360);

      // Unlinked, the two keys are two accounts: both alerts import.
      final (q, addedUnlinked) = await run(linked: false);
      expect(addedUnlinked, 1);
      expect(q.transactionCountForAccount(acct(q, bankKey).id), 2);
    });

    test('a ref-less card alert, then the account alert with a UPI ref, '
        'lowers the bank once', () async {
      // Inbox alerts both: the ref'd copy used to be checked only against
      // notification copies, so both rows imported.
      final p = await loaded();
      await p.addImported([
        alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
        alert(
          date: sep6,
          amount: 640,
          acctKey: cardKey,
          body: cardBody,
          debitCard: true,
        ),
      ]);
      await p.confirmAllPending();
      final (added, _) = await p.addImported([
        alert(
          date: sep6.add(const Duration(minutes: 1)),
          amount: 640,
          acctKey: bankKey,
          ref: '600000012345',
        ),
      ]);
      expect(added, 0);
      await p.confirmAllPending();
      expect(p.accountBalance(acct(p, bankKey)), 50000 - 640);

      // A second real 640 payment with its own ref, minutes later, imports.
      final (again, _) = await p.addImported([
        alert(
          date: sep6.add(const Duration(minutes: 9)),
          amount: 640,
          acctKey: bankKey,
          ref: '600000067890',
        ),
      ]);
      expect(again, 1);
    });

    test('a card the batch itself creates and links meets its bank twin in '
        'that batch', () async {
      final p = await loaded();
      final (added, _) = await p.addImported([
        alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
        alert(
          date: sep6,
          amount: 640,
          acctKey: cardKey,
          body: cardBody,
          avlBal: 49360,
          debitCard: true,
        ),
        alert(
          date: sep6.add(const Duration(minutes: 1)),
          amount: 640,
          acctKey: bankKey,
        ),
      ]);
      await p.confirmAllPending();
      expect(added, 2);
      expect(acct(p, cardKey).linkedAccountId, acct(p, bankKey).id);
      expect(p.accountBalance(acct(p, bankKey)), 49360);
    });

    test('a card alert on one card never swallows another card on the '
        'same bank', () async {
      final p = await loaded();
      final otherCard = '${cardKey.split(':').first}:9012';
      final otherBody = cardBody.replaceFirst('5678', '9012');
      await p.addImported([
        alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
        alert(
          date: sep6,
          amount: 640,
          acctKey: cardKey,
          body: cardBody,
          debitCard: true,
        ),
      ]);
      // A second card on the same bank, linked by its own first alert.
      await p.addImported([
        alert(
          date: sep5,
          amount: 75,
          acctKey: otherCard,
          body: otherBody,
          debitCard: true,
        ),
      ]);
      final bankId = acct(p, bankKey).id;
      expect(acct(p, cardKey).linkedAccountId, bankId);
      expect(acct(p, otherCard).linkedAccountId, bankId);
      final (added, _) = await p.addImported([
        alert(
          date: sep6.add(const Duration(minutes: 1)),
          amount: 640,
          acctKey: otherCard,
          body: otherBody,
          debitCard: true,
        ),
      ]);
      expect(added, 1);
    });

    test(
      'deleting the bank unlinks its cards; merging it moves them',
      () async {
        final p = await loaded();
        final a = await p.addAccount(
          name: 'Zeta Savings',
          type: AccountType.bank,
        );
        final b = await p.addAccount(
          name: 'Zeta Salary',
          type: AccountType.bank,
        );
        final card = await p.addAccount(
          name: 'Zeta Card',
          type: AccountType.debitCard,
        );
        expect(await p.linkDebitCard(card, a), isTrue);

        await p.mergeAccounts(a, b);
        expect(p.accountById(card)!.linkedAccountId, b);
        expect(p.linkedCardsOf(p.accountById(b)!).single.id, card);

        await p.deleteAccount(b);
        expect(p.accountById(card)!.linkedAccountId, isNull);
        expect(p.linkedAccountOf(p.accountById(card)!), isNull);
      },
    );

    test('a link only goes to another open bank account', () async {
      final p = await loaded();
      final bank = await p.addAccount(name: 'Zeta', type: AccountType.bank);
      final visa = await p.addAccount(
        name: 'Zeta Visa',
        type: AccountType.creditCard,
      );
      final card = await p.addAccount(
        name: 'Zeta Card',
        type: AccountType.debitCard,
      );
      expect(await p.linkDebitCard(card, card), isFalse);
      expect(await p.linkDebitCard(card, visa), isFalse);
      expect(await p.linkDebitCard(bank, bank), isFalse);
      expect(await p.linkDebitCard(card, bank), isTrue);
      // Away from Debit card the link clears.
      await p.setAccountType(card, AccountType.bank);
      expect(p.accountById(card)!.linkedAccountId, isNull);
      // A bank that stops being one unlinks its cards.
      await p.setAccountType(
        card,
        AccountType.debitCard,
        linkedAccountId: bank,
      );
      await p.setAccountType(bank, AccountType.savings);
      expect(p.accountById(card)!.linkedAccountId, isNull);
    });

    test('a bank fed only through its card stays in net balance', () async {
      final p = await loaded();
      final bank = await p.addAccount(
        name: 'Zeta Salary',
        type: AccountType.bank,
      );
      // A number an SMS made, with no row on it: an emptied account.
      await p.addAccountKey(bank, bankKey, byHand: false);
      expect(p.isOrphanedAccount(p.accountById(bank)!), isTrue);
      await p.addImported([
        alert(
          date: sep6,
          amount: 640,
          acctKey: cardKey,
          body: cardBody,
          avlBal: 20000,
          debitCard: true,
        ),
      ]);
      await p.confirmAllPending();
      final cardId = acct(p, cardKey).id;
      // The emptied bank is no candidate, so the card waits unlinked.
      expect(p.accountById(cardId)!.linkedAccountId, isNull);
      expect(await p.linkDebitCard(cardId, bank), isTrue);

      final b = p.accountById(bank)!;
      expect(p.isOrphanedAccount(b), isFalse);
      expect(p.accountBalance(b), 20000);
      expect(p.bankBalanceTotal, 20000);
    });

    test(
      'this month: the bank takes in its cards, the card keeps its own',
      () async {
        final p = await loaded();
        final now = DateTime.now();
        final day1 = DateTime(now.year, now.month, 1, 12);
        final bank = await p.addAccount(name: 'Zeta', type: AccountType.bank);
        final card = await p.addAccount(
          name: 'Zeta Card',
          type: AccountType.debitCard,
        );
        await p.linkDebitCard(card, bank);
        Future<void> spend(String account, double amount) async {
          final tx = await p.addTransaction(
            type: TxType.expense,
            categoryId: 'food',
            amount: amount,
            note: '',
            date: day1,
          );
          await p.assignAccount(tx, account);
        }

        await spend(bank, 200);
        await spend(card, 640);
        expect(p.accountSpentThisMonth(p.accountById(card)!), 640);
        expect(p.accountSpentThisMonth(p.accountById(bank)!), 840);
      },
    );
  });

  group('new debit card keys', () {
    test('link to the one bank on the code, else stay unlinked', () async {
      // None: unlinked.
      var p = await loaded();
      await p.addImported([
        alert(
          date: sep6,
          amount: 640,
          acctKey: cardKey,
          body: cardBody,
          debitCard: true,
        ),
      ]);
      var card = acct(p, cardKey);
      expect(card.type, AccountType.debitCard);
      expect(card.linkedAccountId, isNull);

      // One: linked.
      SharedPreferences.setMockInitialValues({});
      p = await loaded();
      await p.addImported([
        alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
        alert(
          date: sep6,
          amount: 640,
          acctKey: cardKey,
          body: cardBody,
          debitCard: true,
        ),
      ]);
      card = acct(p, cardKey);
      expect(card.linkedAccountId, acct(p, bankKey).id);

      // Two: unlinked, the tile asks.
      SharedPreferences.setMockInitialValues({});
      p = await loaded();
      final code = bankKey.split(':').first;
      await p.addImported([
        alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
        alert(date: sep5, amount: 900, acctKey: '$code:4321'),
        alert(
          date: sep6,
          amount: 640,
          acctKey: cardKey,
          body: cardBody,
          debitCard: true,
        ),
      ]);
      expect(acct(p, cardKey).linkedAccountId, isNull);
    });
  });

  group('one-time detection', () {
    /// Seeds the prefs with accounts made the pre-1.41 way: every key a
    /// Bank account. Returns after the detection flag is cleared again.
    Future<void> seedOld(List<ParsedTxn> alerts) async {
      final p = await loaded();
      await p.addImported(alerts);
      await p.confirmAllPending();
      for (final a in p.accounts) {
        if (a.type != AccountType.bank) {
          await p.setAccountType(a.id, AccountType.bank);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('debit_cards_detected_v1');
    }

    test('converts a debit-only bank account and links it without twins, '
        'once', () async {
      await seedOld([
        alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
        alert(date: sep6, amount: 640, acctKey: cardKey, body: cardBody),
        alert(date: sep7, amount: 300, acctKey: cardKey, body: cardBody),
      ]);
      final p = await loaded();
      final card = acct(p, cardKey);
      final bank = acct(p, bankKey);
      expect(card.type, AccountType.debitCard);
      expect(card.linkedAccountId, bank.id);
      expect(bank.type, AccountType.bank);
      // Rows never change.
      expect(p.transactionCountForAccount(card.id), 2);
      expect(p.accountBalance(bank), 50000 - 940);

      // Runs once: a card switched back stays a bank.
      await p.setAccountType(card.id, AccountType.bank);
      final again = await loaded();
      expect(acct(again, cardKey).type, AccountType.bank);
    });

    test('stays unlinked when a card row has a twin on the bank', () async {
      await seedOld([
        alert(date: sep5, amount: 500, acctKey: bankKey, avlBal: 50000),
        alert(date: sep6, amount: 640, acctKey: cardKey, body: cardBody),
        // The account alert for the same spend, two minutes on.
        alert(
          date: sep6.add(const Duration(minutes: 2)),
          amount: 640,
          acctKey: bankKey,
        ),
      ]);
      final p = await loaded();
      final card = acct(p, cardKey);
      expect(card.type, AccountType.debitCard);
      expect(card.linkedAccountId, isNull);
    });

    test('leaves a key with a/c and card alerts as a bank', () async {
      await seedOld([
        alert(date: sep6, amount: 640, acctKey: cardKey, body: cardBody),
        // An a/c alert on the very same number.
        alert(
          date: sep7,
          amount: 300,
          acctKey: cardKey,
          body: 'Rs.300.00 debited from a/c XX5678 on 07-09-26.',
        ),
      ]);
      final p = await loaded();
      expect(acct(p, cardKey).type, AccountType.bank);
    });
  });

  group('backup', () {
    test('v26 round-trips the link; a v25 backup still imports', () async {
      final p = await loaded();
      final bank = await p.addAccount(name: 'Zeta', type: AccountType.bank);
      final card = await p.addAccount(
        name: 'Zeta Card',
        type: AccountType.debitCard,
      );
      await p.linkDebitCard(card, bank);
      final data = jsonDecode(jsonEncode(p.exportData()));
      expect(data['version'], 26);

      SharedPreferences.setMockInitialValues({});
      final q = await loaded();
      await q.importData(data, replace: true);
      final back = q.accountById(card)!;
      expect(back.type, AccountType.debitCard);
      expect(back.linkedAccountId, bank);
      expect(q.linkedAccountOf(back)?.id, bank);

      // A v25 backup: no debit cards, no links.
      final v25 = {
        'app': 'expense_tracker',
        'version': 25,
        'transactions': <Object>[],
        'accounts': [
          {
            'id': 'z1',
            'name': 'Zeta',
            'type': 'bank',
            'keys': [bankKey],
          },
        ],
        'acctKinds': {bankKey: 'bank'},
      };
      SharedPreferences.setMockInitialValues({});
      final r = await loaded();
      await r.importData(v25, replace: true);
      expect(r.accountById('z1')!.type, AccountType.bank);
      expect(r.accountById('z1')!.linkedAccountId, isNull);
    });

    test(
      'a dangling link clears; a debit hint restores an unlinked card',
      () async {
        final p = await loaded();
        await p.importData({
          'app': 'expense_tracker',
          'version': 26,
          'transactions': <Object>[],
          'accounts': [
            {
              'id': 'c1',
              'name': 'Zeta Card',
              'type': 'debitCard',
              'keys': <String>[],
              'linkedAccountId': 'gone',
            },
          ],
        }, replace: false);
        expect(p.accountById('c1')!.linkedAccountId, isNull);

        // An orphan key with a debit hint comes back a debit card.
        final src = await loaded();
        await src.addImported([
          alert(
            date: sep6,
            amount: 640,
            acctKey: cardKey,
            body: cardBody,
            debitCard: true,
          ),
        ]);
        await src.confirmAllPending();
        final data =
            jsonDecode(jsonEncode(src.exportData())) as Map<String, dynamic>;
        expect((data['acctKinds'] as Map)[cardKey], 'debit');
        data['accounts'] = <Object>[];
        SharedPreferences.setMockInitialValues({});
        final q = await loaded();
        await q.importData(data, replace: true);
        final card = acct(q, cardKey);
        expect(card.type, AccountType.debitCard);
        expect(card.linkedAccountId, isNull);
      },
    );
  });

  group('screens', () {
    /// The bank "Zeta Savings" and a debit card on number 5678 linked to
    /// it, with a 640 spend on the card on the 1st of this month.
    Future<(FinanceProvider, String, String)> linked() async {
      final p = await loaded();
      final bank = await p.addAccount(
        name: 'Zeta Savings',
        type: AccountType.bank,
      );
      final card = await p.addAccount(
        name: 'Zeta Card',
        type: AccountType.debitCard,
      );
      await p.addAccountKey(card, cardKey);
      await p.linkDebitCard(card, bank);
      final now = DateTime.now();
      final tx = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 640,
        note: '',
        date: DateTime(now.year, now.month, 1, 12),
      );
      await p.assignAccount(tx, card);
      return (p, bank, card);
    }

    Widget foldedApp(FinanceProvider p) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: p),
        ChangeNotifierProvider.value(value: SettingsProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(body: AccountsScreen(onViewAccount: (_) {})),
      ),
    );

    testWidgets('the folded debit tile shows its month spend', (tester) async {
      final (p, _, _) = await linked();
      await tester.pumpWidget(foldedApp(p));
      await tester.pumpAndSettle();
      expect(find.text('${fmtMoney(640)} this month'), findsOneWidget);
      expect(find.text('Debit card · '), findsOneWidget);
      // One Cards section holds it.
      expect(find.text('CARDS'), findsOneWidget);
    });

    testWidgets('open, the card says where it draws from and the bank names '
        'the card', (tester) async {
      final (p, _, _) = await linked();
      await tester.pumpWidget(accountsApp(p));
      await tester.pumpAndSettle();
      expect(find.text('Draws from Zeta Savings'), findsOneWidget);
      expect(find.text('Includes debit card ••5678'), findsOneWidget);
    });

    testWidgets('an unlinked card says so and offers Link', (tester) async {
      final p = await loaded();
      await p.addAccount(name: 'Zeta Card', type: AccountType.debitCard);
      await tester.pumpWidget(accountsApp(p));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Not linked to a bank account. Its balance counts on its own.',
        ),
        findsOneWidget,
      );
      expect(find.text('Link'), findsOneWidget);
    });

    testWidgets('Change type to Debit card asks which bank it draws from', (
      tester,
    ) async {
      final p = await loaded();
      final bank = await p.addAccount(
        name: 'Zeta Savings',
        type: AccountType.bank,
      );
      final card = await p.addAccount(
        name: 'Zeta Card',
        type: AccountType.bank,
      );
      await tester.pumpWidget(accountsApp(p));
      await tester.pumpAndSettle();

      Future<void> openTypePicker() async {
        await tester.tap(find.text('More').at(1));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Change type…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Debit card'));
        await tester.pumpAndSettle();
        expect(find.text('Which account does it draw from?'), findsOneWidget);
      }

      // Dismissed: nothing changes.
      await openTypePicker();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(p.accountById(card)!.type, AccountType.bank);

      await openTypePicker();
      expect(find.text('Not linked yet'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Zeta Savings'),
        ),
      );
      await tester.pumpAndSettle();
      final after = p.accountById(card)!;
      expect(after.type, AccountType.debitCard);
      expect(after.linkedAccountId, bank);
    });

    testWidgets('New account keeps four types, no Debit card', (tester) async {
      final p = await loaded();
      await tester.pumpWidget(accountsApp(p));
      await tester.pumpAndSettle();
      showAddAccountDialog(tester.element(find.byType(AccountsScreen)));
      await tester.pumpAndSettle();
      final seg = tester.widget<SegmentedButton<AccountType>>(
        find.byType(SegmentedButton<AccountType>),
      );
      expect(seg.segments.map((s) => s.value), [
        AccountType.bank,
        AccountType.creditCard,
        AccountType.savings,
        AccountType.wallet,
      ]);
    });
  });
}
