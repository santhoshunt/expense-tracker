import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/services/sms_parser.dart';

void main() {
  group('SmsTxnParser.merchantOf', () {
    test('helpline footers are not merchants', () {
      // A dispute/helpline sentence follows the same "to" keyword as a payee
      // and used to surface as "Dispute Call 18002662" in Top merchants.
      expect(
        SmsTxnParser.merchantOf(
          'ICICI Bank Acc XX879 debited Rs.5,000.00 on 01-Aug-26. '
          'To dispute call 18002662.',
        ),
        '',
      );
      expect(
        SmsTxnParser.merchantOf(
          'Rs.250 debited from Ac XX1234 on 02-Sep-26. '
          'Info: for disputes call 99999999',
        ),
        '',
      );
      expect(
        SmsTxnParser.merchantOf(
          'Rs.99 debited on 02-Sep-26. Not you? SMS BLOCK to 9840909000',
        ),
        '',
      );
    });

    test('a footer earlier in the body does not hide the real payee', () {
      expect(
        SmsTxnParser.merchantOf(
          'INR 1,200.00 spent from Card XX3010 at AMAZON on 01-07-26. '
          'To dispute call 18002662.',
        ),
        'AMAZON',
      );
    });

    test('an account fragment is skipped, not fatal', () {
      // Previously the first capture ("Card XX3010") was rejected and the
      // body yielded no merchant at all.
      expect(
        SmsTxnParser.merchantOf(
          'INR 640.00 spent from Card XX3010 at ZOMATO on 01-07-26',
        ),
        'ZOMATO',
      );
    });

    test('ordinary payees still extract', () {
      expect(
        SmsTxnParser.merchantOf(
          'Rs.1,249.50 debited from a/c XX1234 on 01-07-26 at SWIGGY '
          'Ref No 615243342718. Not you? Call 18002586161.',
        ),
        'SWIGGY',
      );
      // The capture stops at the first "." (an end-of-sentence marker in
      // most alerts), so a dotted VPA keeps only its first segment.
      expect(
        SmsTxnParser.merchantOf(
          'INR 499.00 debited from A/c XX5678 via UPI to merchant.name@okaxis '
          'on 05-Jul-26.',
        ),
        'merchant',
      );
      // Digit-only VPAs/phone numbers are dropped at the source.
      expect(
        SmsTxnParser.merchantOf(
          'Rs.3000 debited from a/c XX1234 to 9215676766 on 02-09-26.',
        ),
        '',
      );
    });
  });
}
