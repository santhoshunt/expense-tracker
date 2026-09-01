import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/services/sms_parser.dart';

void main() {
  final smsDate = DateTime(2026, 7, 2, 10, 30);

  group('sender filter', () {
    test('accepts bank DLT sender ids', () {
      expect(SmsTxnParser.senderLooksFinancial('VM-HDFCBK'), isTrue);
      expect(SmsTxnParser.senderLooksFinancial('AD-SBIUPI'), isTrue);
      expect(SmsTxnParser.senderLooksFinancial('JX-ICICIB-S'), isTrue);
      expect(SmsTxnParser.senderLooksFinancial('VK-PAYTM'), isTrue);
      expect(SmsTxnParser.senderLooksFinancial('BP-AXISBK-S'), isTrue);
    });

    test('rejects personal numbers and unknown senders', () {
      expect(SmsTxnParser.senderLooksFinancial('+919876543210'), isFalse);
      expect(SmsTxnParser.senderLooksFinancial('9876543210'), isFalse);
      expect(SmsTxnParser.senderLooksFinancial('VM-MYNTRA'), isFalse);
      expect(SmsTxnParser.senderLooksFinancial('DM-OLACAB'), isFalse);
    });
  });

  group('non-transaction rejection', () {
    test('OTP messages are rejected', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Your OTP for txn of Rs.4500.00 at Amazon is 482913. '
            'Do not share it with anyone.',
        smsDate,
      );
      expect(r, isNull);
    });

    test('future-dated e-mandate alerts are rejected', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.649.00 will be debited from your a/c on 05-07-26 towards '
            'Netflix subscription.',
        smsDate,
      );
      expect(r, isNull);
    });

    test('UPI collect requests are rejected', () {
      final r = SmsTxnParser.parse(
        'AD-SBIUPI',
        'Ramesh Kumar has requested Rs.2000.00 from you on UPI. '
            'Approve or decline in your app.',
        smsDate,
      );
      expect(r, isNull);
    });

    test('failed transactions are rejected', () {
      final r = SmsTxnParser.parse(
        'VM-ICICIB',
        'Your txn of Rs.1200.00 at Flipkart has failed. Amount will be '
            'refunded in 3 days.',
        smsDate,
      );
      expect(r, isNull);
    });

    test('promos with amounts are rejected', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Get cashback of Rs.500 when you spend Rs.5000 with your card! '
            'Offer valid till 31-07-26.',
        smsDate,
      );
      expect(r, isNull);
    });

    test('credit-limit promos are rejected (no bare "credit" verb match)', () {
      final r = SmsTxnParser.parse(
        'VM-ICICIB',
        'Manage spends effectively by increasing the limit on ICICI Bank '
            'Credit Card XX3010 from Rs300000 to Rs360000. SMS CRLIM 3010 '
            'to 5676766 to raise the limit',
        smsDate,
      );
      expect(r, isNull);
    });

    test('standing-instruction notices are rejected', () {
      final r = SmsTxnParser.parse(
        'VM-ICICIB',
        'We have successfully processed payment of INR 159.00 to Merchant '
            'Google Play, as per Standing Instruction YHQwWMgkSi on '
            '05/05/2026 for ICICI Bank Credit Card 3010.',
        smsDate,
      );
      expect(r, isNull);
    });

    test('balance-due reminders are rejected', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Payment of Rs.12,340.00 is due on 15-07-26 for your credit card '
            'ending 4523.',
        smsDate,
      );
      expect(r, isNull);
    });

    test('genuine card spends still parse', () {
      final r = SmsTxnParser.parse(
        'VM-ICICIB',
        'INR 500.00 spent on ICICI Bank Credit Card XX9005 on 04-Jul-26 '
            'at AMAZON. Avl Limit: INR 2,15,000.00.',
        smsDate,
      )!;
      expect(r.type, TxType.expense);
      expect(r.amount, 500.00);
    });
  });

  group('credit-card bill payments', () {
    // A bill payment is the user's own money moving between accounts. Both
    // sides import as ordinary transactions that net out: issuer-side
    // confirmation → card_payment income on the card, bank-side debit →
    // card_bill expense on the bank account.
    test('issuer-side confirmation imports as card_payment income', () {
      final r = SmsTxnParser.parse(
        'VM-ICICIB',
        'Payment of Rs 18,480.73 has been received on your ICICI Bank '
            'Credit Card XXxxxx through Bharat Bill Payment System '
            'on 30-JUN-26.',
        smsDate,
      )!;
      expect(r.type, TxType.income);
      expect(r.amount, 18480.73);
      expect(r.categoryId, kCardPaymentCategoryId);
      // "XXxxxx" carries no digits, so no account key can be derived.
      expect(r.acctKey, isNull);
      expect(r.date.day, 30);
      expect(r.date.month, 6);
    });

    test('confirmation with card digits lands on the card account', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Thank you for your payment of Rs.9,999.00 towards your HDFC Bank '
            'Credit Card XX4523 received on 01-07-26.',
        smsDate,
      )!;
      expect(r.type, TxType.income);
      expect(r.categoryId, kCardPaymentCategoryId);
      expect(r.acctKey, 'HDFC:4523');
      expect(r.isCard, isTrue);
    });

    test('bank-side debit imports as card_bill expense on the bank a/c', () {
      final r = SmsTxnParser.parse(
        'VM-ICICIB',
        'Rs.5,000.00 debited from a/c XX1234 on 01-07-26 towards your '
            'ICICI Credit Card XX9005 payment. Ref 123456789012.',
        smsDate,
      )!;
      expect(r.type, TxType.expense);
      expect(r.amount, 5000.00);
      expect(r.categoryId, kCardBillCategoryId);
      // First account fragment wins: the bank a/c, not the card.
      expect(r.acctKey, 'ICICI:1234');
      expect(r.isCard, isFalse);
    });

    test('confirmation reporting Avl Lmt updates the card limit figure', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Payment of Rs.9,999.00 received on your HDFC Bank Credit Card '
            'XX4523 on 01-07-26. Avl Lmt INR 1,95,000.00.',
        smsDate,
      )!;
      expect(r.type, TxType.income);
      expect(r.categoryId, kCardPaymentCategoryId);
      expect(r.balanceAfter, 195000.00);
    });

    // Real messages for three issuers. Each used to import attached to no
    // account (or with its stated limit discarded), so the payment could never
    // bring the card's outstanding down.
    test('ICICI "Credit Card Account 4xxx3010" resolves to the card', () {
      final r = SmsTxnParser.parse(
        'AX-ICICIT-S',
        'Dear Customer, Payment of INR 3,591.69 has been received on your '
            'ICICI Bank Credit Card Account 4xxx3010 on 31-MAY-26.Thank you.',
        smsDate,
      )!;
      expect(r.type, TxType.income);
      expect(r.amount, 3591.69);
      expect(r.categoryId, kCardPaymentCategoryId);
      // Digit-prefixed mask, and the keyword is followed by "Account" — the
      // card hint must survive both, or a *bank* account gets auto-created.
      expect(r.acctKey, 'ICICI:3010');
      expect(r.isCard, isTrue);
    });

    test('HDFC "ENDING WITH" + "AVAILABLE LIMIT IS" both parse', () {
      final r = SmsTxnParser.parse(
        'AD-HDFCBK-S',
        'DEAR HDFCBANK CARDMEMBER, PAYMENT OF Rs. 1498.00 RECEIVED TOWARDS '
            'YOUR CREDIT CARD ENDING WITH 9012 ON 14-4-2026.YOUR AVAILABLE '
            'LIMIT IS RS. 138000.00',
        smsDate,
      )!;
      expect(r.type, TxType.income);
      expect(r.amount, 1498.00);
      expect(r.categoryId, kCardPaymentCategoryId);
      expect(r.acctKey, 'HDFC:9012');
      expect(r.isCard, isTrue);
      // The filler word "IS" used to make this figure unreadable.
      expect(r.balanceAfter, 138000.00);
      // Single-digit month.
      expect(r.date.day, 14);
      expect(r.date.month, 4);
      expect(r.date.year, 2026);
    });

    test('YES BANK "Credit Card ending 8312" resolves to the card', () {
      final r = SmsTxnParser.parse(
        'AX-YESBNK-S',
        'Dear Cardmember, payment of Rs.6,870.44 is received towards your '
            'YES BANK Credit Card ending 8312. It will reflect in your '
            'Credit Card within 1-2 working days',
        smsDate,
      )!;
      expect(r.type, TxType.income);
      expect(r.amount, 6870.44);
      expect(r.categoryId, kCardPaymentCategoryId);
      expect(r.acctKey, 'YESBNK:8312');
      expect(r.isCard, isTrue);
      // No limit stated — the ledger has to carry this one.
      expect(r.balanceAfter, isNull);
    });
  });

  group('timestamps', () {
    test('body date + body clock time wins', () {
      // Arrival is later the same day: the body's own timestamp is more
      // precise and must win over the arrival time.
      final r = SmsTxnParser.parse(
        'AX-YESBNK-S',
        'INR 2,550.00 spent on YES BANK Card xxxx @UPI_RAMJI CABLES AND N '
            '06-07-2026 02:07:35 pm. Avl Lmt INR 290,541.59.',
        DateTime(2026, 7, 6, 18, 22),
      )!;
      expect(r.date, DateTime(2026, 7, 6, 14, 7, 35));
    });

    test('24-hour body time needs no am/pm suffix', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.99.00 debited from a/c XX1234 on 02-07-26 18:45 at JIO RECHARGE.',
        smsDate,
      )!;
      expect(r.date, DateTime(2026, 7, 2, 18, 45));
    });

    test('body date with no time takes the arrival time of day', () {
      final r = SmsTxnParser.parse(
        'AX-ICICIT-S',
        'Dear Customer, Acct XX8712 is credited with Rs 360.00 on 29-May-26 '
            'from AKASH POM. UPI:614963611754-ICICI Bank.',
        DateTime(2026, 5, 29, 20, 56),
      )!;
      // Used to collapse to midnight, discarding the 8:56 pm it arrived at.
      expect(r.date, DateTime(2026, 5, 29, 20, 56));
      // The ref digits must not be mistaken for a clock time.
      expect(r.ref, '614963611754');
    });

    test('no body date falls back to the arrival timestamp verbatim', () {
      final r = SmsTxnParser.parse(
        'VM-KOTAKB',
        'Rs.320.00 spent using Kotak card XX9012 at MCDONALDS. '
            'Avl limit Rs.45,680.',
        smsDate,
      )!;
      expect(r.date, smsDate);
    });

    test('12 am / 12 pm map correctly', () {
      final midnight = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.10.00 debited from a/c XX1234 on 02-07-26 12:05:00 am.',
        smsDate,
      )!;
      expect(midnight.date, DateTime(2026, 7, 2, 0, 5));
      final noon = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.10.00 debited from a/c XX1234 on 02-07-26 12:05:00 pm.',
        smsDate,
      )!;
      expect(noon.date, DateTime(2026, 7, 2, 12, 5));
    });

    test('dateWithBodyTime re-stamps stored history, or returns null', () {
      expect(
        SmsTxnParser.dateWithBodyTime(
          DateTime(2026, 7, 6),
          'INR 2,550.00 spent on YES BANK Card xxxx 06-07-2026 02:07:35 pm.',
        ),
        DateTime(2026, 7, 6, 14, 7, 35),
      );
      expect(
        SmsTxnParser.dateWithBodyTime(
          DateTime(2026, 7, 6),
          'Rs.320.00 spent using Kotak card XX9012 at MCDONALDS.',
        ),
        isNull,
      );
    });
  });

  group('debit parsing', () {
    test('card swipe with merchant, date and ref', () {
      const body =
          'Rs.1,249.50 debited from a/c XX1234 on 01-07-26 at SWIGGY '
          'Ref No 615243342718. Not you? Call 18002586161.';
      final r = SmsTxnParser.parse('VM-HDFCBK', body, smsDate)!;
      expect(r.type, TxType.expense);
      expect(r.amount, 1249.50);
      expect(r.merchant.toLowerCase(), contains('swiggy'));
      expect(r.date.day, 1);
      expect(r.date.month, 7);
      expect(r.ref, '615243342718');
      expect(r.categoryId, 'other_expense');
      // Sender id and the full original message ride along for the note.
      expect(r.sender, 'VM-HDFCBK');
      expect(r.rawBody, body);
    });

    test('UPI debit with VPA merchant', () {
      final r = SmsTxnParser.parse(
        'AD-SBIUPI',
        'Dear UPI user A/C X5678 debited by Rs.450.00 on date 02Jul26 '
            'trf to uber.rides@okaxis UPI Ref No 552319876543.',
        smsDate,
      )!;
      expect(r.type, TxType.expense);
      expect(r.amount, 450.00);
      expect(r.merchant.toLowerCase(), contains('uber'));
      expect(r.ref, '552319876543');
      expect(r.categoryId, 'other_expense');
    });

    test('debited-and-credited UPI message resolves to expense', () {
      final r = SmsTxnParser.parse(
        'VM-ICICIB',
        'INR 899.00 debited from your a/c and credited to '
            'flipkart@icici on 30-06-2026. UPI Ref: 517892345671.',
        smsDate,
      )!;
      expect(r.type, TxType.expense);
      expect(r.categoryId, 'other_expense');
    });

    test('amount with lakh-style commas', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.1,00,000.00 debited from a/c XX1234 on 28-06-26 towards '
            'RTGS transfer Ref No HDFCR52026062812345.',
        smsDate,
      )!;
      expect(r.amount, 100000.00);
    });
  });

  group('credit parsing', () {
    test('salary credit categorized as salary income', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.85,000.00 credited to a/c XX1234 on 01-07-26 towards '
            'SALARY JUNE. Avl bal Rs.1,42,318.55.',
        smsDate,
      )!;
      expect(r.type, TxType.income);
      expect(r.amount, 85000.00);
      expect(r.categoryId, 'other_income');
    });

    test('UPI credit received from person', () {
      final r = SmsTxnParser.parse(
        'AD-SBIUPI',
        'Your a/c X5678 credited Rs.1,500.00 on 02Jul26 by transfer '
            'from ramesh.k@oksbi UPI Ref 519234567890.',
        smsDate,
      )!;
      expect(r.type, TxType.income);
      expect(r.amount, 1500.00);
      expect(r.categoryId, 'other_income');
    });
  });

  group('spam suspicion', () {
    test('mandate/autopay debits parse but are flagged as suspects', () {
      final r = SmsTxnParser.parse(
        'VM-ICICIB',
        'Rs 249.00 debited from ICICI Bank Savings Account XX879 towards '
            'Google Play for UPI Mandate AutoPay Retrieval Ref No.288653641496',
        smsDate,
      )!;
      expect(r.type, TxType.expense);
      expect(r.spamSuspect, isTrue);
    });

    test('messages with promo links are flagged as suspects', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Alert! Rs. 245 refunded by PYU*Swiggy Food Bangalore IND & adjusted '
            'against HDFC Bank Credit Card 9631 View updated balance here: '
            'https://hdfcbk.io/HDFCBK/s/0RMe5PAv',
        smsDate,
      )!;
      expect(r.spamSuspect, isTrue);
    });

    test('plain transactions are not flagged', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.1,249.50 debited from a/c XX1234 on 01-07-26 at SWIGGY '
            'Ref No 615243342718.',
        smsDate,
      )!;
      expect(r.spamSuspect, isFalse);
    });
  });

  group('Yes Bank card formats', () {
    test('real "spent on YES BANK Card @UPI_" alert parses fully', () {
      // Exact message reported as not importing — proves the parser accepts
      // it; the import failure is upstream (message not in the SMS provider).
      final r = SmsTxnParser.parse(
        'AX-YESBNK-S',
        'INR 2,550.00 spent on YES BANK Card xxxx @UPI_RAMJI CABLES AND N '
            '06-07-2026 02:07:35 pm. Avl Lmt INR 290,541.59. '
            'SMS BLKCC 8385 to 9840909000 if not you',
        DateTime(2026, 7, 6, 18, 22),
      )!;
      expect(r.type, TxType.expense);
      expect(r.amount, 2550.00);
      // Timestamp-adjacent date (no "on" prefix) is extracted correctly.
      expect(r.date.year, 2026);
      expect(r.date.month, 7);
      expect(r.date.day, 6);
    });

    test('"used for" debit card alert parses as expense', () {
      // Yes Bank's standard debit-card swipe alert uses "used for", not
      // "debited". Previously rejected because "used" was absent from the
      // expense-verb list — caused all card swipes from Yes Bank to be silently
      // dropped during import.
      final r = SmsTxnParser.parse(
        'VK-YESBNK',
        'Your YES BANK Debit Card XX5678 has been used for Rs.850.00 '
            'at AMAZON on 05-Jul-26. Avl Bal: Rs.24,315.00. '
            'For statement enquiry call 18001200.',
        smsDate,
      )!;
      expect(r.type, TxType.expense);
      expect(r.amount, 850.00);
      expect(r.categoryId, 'other_expense');
    });

    test('"charged to card" alert parses as expense', () {
      final r = SmsTxnParser.parse(
        'VK-YESBNK',
        'Rs.1,200.00 charged to your YES BANK Credit Card XX5678 '
            'at SWIGGY on 05-Jul-26. Avl Limit: Rs.48,800.00.',
        smsDate,
      )!;
      expect(r.type, TxType.expense);
      expect(r.amount, 1200.00);
      expect(r.categoryId, 'other_expense');
    });

    test('"statement enquiry" footer does not reject transaction', () {
      // "statement" was in _rejectPhrases — any Yes Bank message with a
      // "For statement enquiry, call us" footer was silently dropped.
      final r = SmsTxnParser.parse(
        'VK-YESBNK',
        'INR 499.00 debited from A/c XX5678 via UPI to merchant@okaxis '
            'on 05-Jul-26. Ref 512345678901. '
            'For statement enquiry call 18001200.',
        smsDate,
      );
      expect(r, isNotNull);
      expect(r!.amount, 499.00);
    });
  });

  group('Indian Bank formats', () {
    test('debit alert parses with account key and UPI ref', () {
      // Exact message reported as not importing: INDBNK was missing from the
      // bank-code allowlist, so the sender check rejected everything.
      final r = SmsTxnParser.parse(
        'BV-INDBNK-S',
        'A/c *2080 debited Rs. 238.32 on 03-07-26 to BOOKMYSHOW. '
            'UPI:309711253923. Not you? SMS BLOCK to 9289592895, '
            'Dial 1930 for Cyber Fraud - Indian Bank',
        smsDate,
      )!;
      expect(r.type, TxType.expense);
      expect(r.amount, 238.32);
      expect(r.acctKey, 'INDBNK:2080');
      expect(r.isCard, isFalse);
      expect(r.ref, '309711253923');
      expect(r.date.day, 3);
      expect(r.date.month, 7);
    });

    test('a future body date is not trusted — arrival time wins', () {
      // An alert can only describe something that already happened, so a
      // body date materially after arrival (a due date, or a bank-side
      // mis-print) must not be stamped forward: such a row would out-rank
      // every newer bank figure and any manually set balance for weeks.
      final r = SmsTxnParser.parse(
        'BV-INDBNK-S',
        'Rs.5,000.00 debited from A/c *2080 on 05-09-26 towards loan a/c. '
            'Avl Bal Rs.15,000.00.',
        smsDate,
      )!;
      expect(r.date, smsDate);
      expect(r.balanceAfter, 15000.00);
    });

    test('"Sent" debit alert carries account key AND Avl Bal', () {
      // Exact message reported as not moving the balance (01-08-2026).
      final r = SmsTxnParser.parse(
        'BV-INDBNK-S',
        'Sent Rs.95.00 from A/c *2080 on 31-07-26 to Ms SINDHUJA  J..'
            'Avl Bal Rs.20146.51.Not you?SMS BLOCK to 999382328 -Indian Bank',
        DateTime(2026, 7, 31, 18, 5),
      )!;
      expect(r.type, TxType.expense);
      expect(r.amount, 95.00);
      expect(r.acctKey, 'INDBNK:2080');
      expect(r.isCard, isFalse);
      expect(r.balanceAfter, 20146.51);
      expect(r.date.day, 31);
      expect(r.date.month, 7);
    });

    test('brand sender "Indian Bank" maps to INDBNK, not a squash code', () {
      // Notification-captured alerts carry the display name, not a DLT id.
      // A missing brand mapping used to squash it to "INDIANBANK:2080" — a
      // second account for the same real one, so balances split across tiles.
      expect(SmsTxnParser.bankCodeOf('Indian Bank'), 'INDBNK');
      final (key, _) = SmsTxnParser.accountKeyOf(
        'Indian Bank',
        'Sent Rs.95.00 from A/c *2080 on 31-07-26 to Ms SINDHUJA  J..'
            'Avl Bal Rs.20146.51.Not you?SMS BLOCK to 999382328 -Indian Bank',
      );
      expect(key, 'INDBNK:2080');
    });

    test('credit alert parses (cashback flagged for review, not dropped)', () {
      final r = SmsTxnParser.parse(
        'BV-INDBNK-S',
        'Rs.15.00 credited to a/c *2080 on 04/07/2026 by a/c linked to VPA '
            'kiwicashback@axisbank (UPI Ref no 559086771856).Indian Bank',
        smsDate,
      )!;
      expect(r.type, TxType.income);
      expect(r.amount, 15.00);
      expect(r.acctKey, 'INDBNK:2080');
      expect(r.ref, '559086771856');
      // "cashback" inside a VPA (kiwi**cashback**@axisbank) is a merchant
      // name, not a promo — boundary matching no longer flags it. A
      // free-standing "cashback" still does.
      expect(r.spamSuspect, isFalse);
      expect(
        SmsTxnParser.looksLikeSpam('Get 5% cashback on every spend'),
        isTrue,
      );
    });
  });

  group('account / balance extraction', () {
    test('bank a/c fragment → key with last-4, not a card', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.1,249.50 debited from a/c XX1234 on 01-07-26 at SWIGGY '
            'Ref No 615243342718. Avl Bal Rs.42,318.55.',
        smsDate,
      )!;
      expect(r.acctKey, 'HDFC:1234');
      expect(r.isCard, isFalse);
      expect(r.balanceAfter, 42318.55);
    });

    test('credit card fragment → card hint + Avl Lmt as balanceAfter', () {
      final r = SmsTxnParser.parse(
        'VM-ICICIB',
        'INR 500.00 spent on ICICI Bank Credit Card XX9005 on 04-Jul-26 '
            'at AMAZON. Avl Limit: INR 2,15,000.00.',
        smsDate,
      )!;
      expect(r.acctKey, 'ICICI:9005');
      expect(r.isCard, isTrue);
      expect(r.balanceAfter, 215000.00);
    });

    test('real Yes Bank card format extracts limit', () {
      final r = SmsTxnParser.parse(
        'AX-YESBNK-S',
        'INR 2,550.00 spent on YES BANK Card X1234 @UPI_RAMJI CABLES AND N '
            '06-07-2026 02:07:35 pm. Avl Lmt INR 290,541.59. '
            'SMS BLKCC 8385 to 9840909000 if not you',
        smsDate,
      )!;
      expect(r.acctKey, 'YESBNK:1234');
      expect(r.isCard, isTrue);
      expect(r.balanceAfter, 290541.59);
    });

    test('no account digits → null key, still parses', () {
      final r = SmsTxnParser.parse(
        'AD-SBIUPI',
        'Your a/c credited Rs.1,500.00 by transfer from ramesh@oksbi '
            'UPI Ref 519234567890.',
        smsDate,
      )!;
      expect(r.acctKey, isNull);
      expect(r.balanceAfter, isNull);
    });

    // A fragment introduced by ANOTHER bank's name is the counterparty of a
    // transfer, not the sender's own account. Keying it to the sending bank
    // minted a chimera ("INDBNK:879" — Indian Bank's name, ICICI's digits)
    // that then hoovered up messages meant for the other account.
    test('fragment naming another bank is skipped, not keyed to sender', () {
      final (key, isCard) = SmsTxnParser.accountKeyOf(
        'BV-INDBNK-S',
        'NEFT of Rs.25,000.00 credited to ICICI Bank Account XXX879 on '
            '01-08-26. Ref INDBN12345678.',
      );
      expect(key, isNull);
      expect(isCard, isFalse);
    });

    test('own fragment still wins when a foreign one appears first', () {
      final (key, isCard) = SmsTxnParser.accountKeyOf(
        'BV-INDBNK-S',
        'Transfer to ICICI Bank Account XXX879 done. Rs.25,000.00 debited '
            'from A/c *2080 on 01-08-26.',
      );
      expect(key, 'INDBNK:2080');
      expect(isCard, isFalse);
    });

    test('own bank named before the fragment is kept', () {
      final (key, _) = SmsTxnParser.accountKeyOf(
        'AX-ICICIT-S',
        'ICICI Bank Account XXX879 credited:Rs. 25,000.00 on 01-Aug-26. '
            'Info NEFT. Available Balance is Rs. 1,10,000.00.',
      );
      expect(key, 'ICICI:879');
    });

    test('legacy derivation still reports the pre-fix chimera key', () {
      // The v3 re-key migration relies on this to recognise machine-derived
      // keys; if legacyAccountKeyOf ever changes, the migration goes blind.
      final (key, _) = SmsTxnParser.legacyAccountKeyOf(
        'BV-INDBNK-S',
        'NEFT of Rs.25,000.00 credited to ICICI Bank Account XXX879 on '
            '01-08-26.',
      );
      expect(key, 'INDBNK:879');
    });
  });

  group('notification-captured (RCS) senders', () {
    const rcsBody =
        'INR 2,550.00 spent on YES BANK Card xxxx @UPI_RAMJI CABLES AND N '
        '06-07-2026 02:07:35 pm. Avl Lmt INR 290,541.59. '
        'SMS BLKCC 8385 to 9840909000 if not you';

    test('brand-name sender accepted only in relaxed mode', () {
      // RCS business chats show "Yes Bank", not a DLT code — the strict
      // sender check must keep rejecting it for raw inbox SMS, while the
      // notification-capture path accepts it.
      expect(SmsTxnParser.parse('Yes Bank', rcsBody, smsDate), isNull);
      final r = SmsTxnParser.parse(
        'Yes Bank',
        rcsBody,
        smsDate,
        relaxedSender: true,
      )!;
      expect(r.type, TxType.expense);
      expect(r.amount, 2550.00);
    });

    test('relaxed mode still rejects non-financial senders', () {
      expect(
        SmsTxnParser.parse(
          'Mom',
          'I sent Rs.500 to you for the groceries',
          smsDate,
          relaxedSender: true,
        ),
        isNull,
      );
    });
  });

  group('fallbacks', () {
    test('missing date falls back to SMS timestamp', () {
      final r = SmsTxnParser.parse(
        'VM-KOTAKB',
        'Rs.320.00 spent using Kotak card XX9012 at MCDONALDS. '
            'Avl limit Rs.45,680.',
        smsDate,
      )!;
      expect(r.date, smsDate);
      expect(r.categoryId, 'other_expense');
    });

    test('missing ref yields null ref, still parses', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.99.00 debited from a/c XX1234 on 02-07-26 at JIO RECHARGE.',
        smsDate,
      )!;
      expect(r.ref, isNull);
      expect(r.categoryId, 'other_expense');
    });

    test('unknown merchant defaults to other_expense', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.750.00 debited from a/c XX1234 on 02-07-26 at RK TRADERS '
            'Ref No 715243342710.',
        smsDate,
      )!;
      expect(r.categoryId, 'other_expense');
    });
  });

  group('audit regressions', () {
    test('"Debit Card" spends key to a BANK account, not a credit card', () {
      final (key, isCard) = SmsTxnParser.accountKeyOf(
        'AX-YESBNK-S',
        'Your YES BANK Debit Card XX5678 has been used for Rs.850.00 at '
            'AMAZON on 05-Jul-26. Avl Bal: Rs.24,315.00.',
      );
      expect(key, 'YESBNK:5678');
      // isCard=true minted a credit-card account, hiding ₹24k of real cash
      // from netWorth and flagging a bogus "missing credit limit".
      expect(isCard, isFalse);

      // A genuine credit card still keys as a card.
      final (cardKey, cardIsCard) = SmsTxnParser.accountKeyOf(
        'AX-ICICIT-S',
        'Payment of Rs.5,000 received on your ICICI Bank Credit Card '
            'Account 4xxx3010.',
      );
      expect(cardKey, 'ICICI:3010');
      expect(cardIsCard, isTrue);
    });

    test('outward NEFT "credited to <other bank>" imports as EXPENSE', () {
      final r = SmsTxnParser.parse(
        'BV-INDBNK-S',
        'NEFT of Rs.25,000.00 credited to ICICI Bank Account XXX879 on '
            '01-08-26. Ref INDBN12345678.',
        smsDate,
      )!;
      // Money LEFT the user's Indian Bank account — importing this as
      // income inflated totalIncome by ₹25,000 permanently.
      expect(r.type, TxType.expense);
      // The foreign-bank guard still withholds the account key (the
      // fragment describes the beneficiary's account).
      expect(r.acctKey, isNull);
    });

    test('"credited to your …" is a genuine inward credit — never flips', () {
      final r = SmsTxnParser.parse(
        'BV-INDBNK-S',
        'Rs.10,000.00 credited to your a/c *2080 on 01-08-26 by NEFT from '
            'ICICI Bank. Avl Bal Rs.30,000.00.',
        smsDate,
      )!;
      expect(r.type, TxType.income);
    });

    test('reversal alerts import (as income) instead of being dropped', () {
      // Dropping them left the ORIGINAL debit uncancelled forever.
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.500.00 debited on 01-07-26 at SHOP has been reversed and '
            'credited back to a/c XX1234. Avl Bal Rs.20,646.51.',
        smsDate,
      );
      expect(r, isNotNull);
      expect(r!.type, TxType.income);
    });

    test('completed EMI debit with a "next due" footer imports', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Rs.5,000.00 debited towards EMI for loan a/c 1234. '
            'Next EMI due on 05-09-26.',
        smsDate,
      );
      expect(r, isNotNull);
      expect(r!.type, TxType.expense);
      // The future "due on" date must not stamp the row forward.
      expect(r.date, smsDate);
    });

    test('a pure payment reminder (no completed verb) is still rejected', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        'Reminder: your loan EMI of Rs.5,000.00 is due on 05-09-26. '
            'Please maintain sufficient balance.',
        smsDate,
      );
      expect(r, isNull);
    });

    test('spam signals respect word boundaries', () {
      expect(
        SmsTxnParser.looksLikeSpam('Learn more about our services'),
        isFalse,
        reason: '"earn" must not fire inside "Learn"',
      );
      expect(SmsTxnParser.looksLikeSpam('Earn 5% on every spend'), isTrue);
    });

    test('a personal contact named Bob is not a bank brand', () {
      expect(SmsTxnParser.senderLooksBankBrand('Bob'), isFalse);
      expect(SmsTxnParser.senderLooksBankBrand('Yes'), isFalse);
      expect(SmsTxnParser.senderLooksBankBrand('Yes Bank'), isTrue);
      expect(SmsTxnParser.senderLooksBankBrand('Bank of Baroda'), isTrue);
    });
  });
}
