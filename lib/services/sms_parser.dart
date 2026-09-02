import 'package:intl/intl.dart' hide TextDirection;

import '../models/default_rules.dart';
import '../models/transaction.dart';

/// A financial transaction extracted from a bank/UPI alert SMS.
class ParsedTxn {
  final TxType type;
  final double amount;
  final String merchant;
  final DateTime date;
  final String? ref;
  final String categoryId;

  /// SMS sender id the alert came from (bank DLT code or phone number).
  final String sender;

  /// Full original SMS text, stored in the transaction note for reference.
  final String rawBody;

  /// The message parsed as a transaction but carries promotional/informational
  /// signals — it must be reviewed individually, never bulk-confirmed.
  final bool spamSuspect;

  /// Account-match key `"<bankCode>:<last4>"` derived from the alert, or null
  /// when no account/card fragment was found.
  final String? acctKey;

  /// The `Avl Bal` (bank) or `Avl Lmt` (card) figure the alert reported, or
  /// null when absent.
  final double? balanceAfter;

  /// Whether the account fragment named a card (vs a bank account).
  final bool isCard;

  const ParsedTxn({
    required this.type,
    required this.amount,
    required this.merchant,
    required this.date,
    required this.ref,
    required this.categoryId,
    this.sender = '',
    this.rawBody = '',
    this.spamSuspect = false,
    this.acctKey,
    this.balanceAfter,
    this.isCard = false,
  });
}

/// Rule-based parser for Indian bank / UPI transaction alerts.
///
/// Pure string logic — no platform dependencies — so it is fully unit-testable.
/// Formats vary per bank but share vocabulary, so extraction is per-field
/// (amount, direction, merchant, date, ref) rather than one regex per bank.
class SmsTxnParser {
  /// Bank / payment-app codes that appear in DLT sender ids like
  /// `VM-HDFCBK-S` or `AD-SBIUPI`. Data, not code: extend freely.
  static const Set<String> _bankCodes = {
    'HDFC',
    'ICICI',
    'SBI',
    'SBIUPI',
    'SBIINB',
    'AXIS',
    'AXISBK',
    'KOTAK',
    'IDFC',
    'IDFCFB',
    'YESBNK',
    'INDUS',
    'INDBNK', // Indian Bank
    'IDBI',
    'CENTBK', // Central Bank of India
    'MAHABK', // Bank of Maharashtra
    'PNB',
    'BOB',
    'BOI',
    'CANBNK',
    'UNION',
    'UCO',
    'IOB',
    'FEDBNK',
    'RBL',
    'AUBANK',
    'DBS',
    'HSBC',
    'CITI',
    'SCB',
    'PAYTM',
    'PHONPE',
    'GPAY',
    'AMAZONP',
    'MOBIKW',
    'FREECH',
    'BHIMPAY',
    'SLICEIT',
    'ONECRD',
  };

  static final RegExp _senderShape = RegExp(
    r'^[A-Z]{2}-?([A-Z0-9]{3,9})(-[A-Z])?$',
    caseSensitive: false,
  );

  static final RegExp _amountRe = RegExp(
    r'(?:rs\.?|inr|₹)\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );

  // Trailing bare `upi` alternative covers Indian Bank's "UPI:309711253923".
  static final RegExp _refRe = RegExp(
    r'(?:upi\s*ref(?:erence)?(?:\s*no)?|ref(?:erence)?(?:\s*no)?|txn\s*id|transaction\s*id|upi)\s*[.:# ]\s*([A-Za-z0-9]{6,25})',
    caseSensitive: false,
  );

  static final RegExp _merchantRe = RegExp(
    r"\b(?:at|to|from|towards|info:?|vpa)\s+([A-Za-z0-9@._'&*\- ]{2,50}?)(?=\s+(?:on|via|ref|upi|avl|bal|a/c|ac|dt)\b|[.,;\n]|$)",
    caseSensitive: false,
  );

  // Account/card fragment: "a/c XX1234", "A/C X5678", "account no. 1234",
  // "Card xxxx1234", "Credit Card XX3010", "Credit Card Account 4xxx3010",
  // "Credit Card ending with 1234". Captures the trailing 3-4 digits; group 1
  // is the "card" keyword when present (bank vs card hint).
  //
  // Two shapes needed widening for credit-card *payment* confirmations:
  //   * ICICI writes "Credit Card Account 4xxx3010" — the keyword is followed
  //     by another noun, and the mask is digit-prefixed rather than "XX"-led.
  //     The optional noun is consumed inside the same match so group 1 still
  //     reports card-ness (falling through to the bare `account` alternative
  //     would create a *bank* account for a card).
  //   * HDFC writes "ENDING WITH 1234".
  // A digit prefix is only accepted when mask characters follow it, so a bare
  // long account number can never be sliced mid-way.
  static final RegExp _acctKeyRe = RegExp(
    r'\b(?:(credit\s+card|debit\s+card|card)|a\/?c|acct|account)\b'
    r'(?:\s+(?:account|acct|a\/?c|no\.?|number))?'
    r'(?:\s*(?:no\.?|number|ending(?:\s+(?:in|with))?))?'
    r'[\s:.#-]*(?:\d{1,6}\s*(?:x+|\*+)|x+|\*+|ending)?\s*(\d{3,4})\b',
    caseSensitive: false,
  );

  // Post-transaction figure: "Avl Bal Rs.X", "Available Balance INR X",
  // "Avl Lmt INR X", "Avl Limit: X", "AVAILABLE LIMIT IS RS. X". Group 1 is
  // the amount. The optional `is`/`of` matters: HDFC's card-payment
  // confirmation is the one that states the *post-payment* limit, and without
  // it the figure was dropped.
  static final RegExp _balanceAfterRe = RegExp(
    r'(?:avl|available|avbl|a\/v)\.?\s*(?:bal(?:ance)?|lmt|limit|lim)\.?'
    r'\s*(?:is|of)?\s*[:.]?\s*(?:rs\.?|inr|₹)?\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );

  // Verbs are matched on word boundaries: a bare `credit` would also match
  // "Credit Card" and turn card promos into six-figure incomes.
  static final RegExp _expenseVerbRe = RegExp(
    // "used" covers Yes Bank / many debit-card alerts: "has been used for Rs X"
    // "charged" covers card-swipe confirmations: "Rs X charged to your card"
    r'\b(debited|spent|sent|paid|withdrawn|purchase|deducted|charged|used)\b',
    caseSensitive: false,
  );
  static final RegExp _incomeVerbRe = RegExp(
    r'\b(credited|received|deposited|refunded|refund)\b',
    caseSensitive: false,
  );

  /// Credit-card bill payments are money moving between the user's own
  /// accounts, recorded as two ordinary transactions that net out: the
  /// bank-side debit imports as a `card_bill` expense on the bank account,
  /// and the issuer-side confirmation ("payment received on your credit
  /// card") as a `card_payment` income on the card account. This pattern
  /// only picks the category; direction still comes from the verbs. Card
  /// *spends* ("spent on ... credit card") don't match it.
  static final RegExp _cardBillPaymentRe = RegExp(
    r'received\s+(?:on|towards|for)\s+your\s+.{0,40}\bcard\b'
    r'|payment\s+.{0,60}?\breceived\b.{0,60}?\bcredit\s+card'
    r'|towards\s+(?:your\s+)?.{0,30}\bcredit\s+card\s+(?:bill|payment|xx)'
    r'|thank\s+you\s+for\s+your\s+payment'
    r'|we\s+have\s+received\s+your\s+payment',
    caseSensitive: false,
  );

  /// Bank codes the parser can produce in account keys — the choices offered
  /// when manually linking an account/card number in the Accounts UI.
  static List<String> get knownBankCodes => _bankCodes.toList()..sort();

  /// Timestamp rendering for the "Test a message" diagnosis only.
  static final DateFormat _explainFormat = DateFormat('d MMM yyyy, h:mm a');

  /// Stage 1 filter: does the sender id look like a bank/payment-app DLT id?
  static bool senderLooksFinancial(String sender) {
    final m = _senderShape.firstMatch(sender.trim());
    if (m == null) return false;
    final code = m.group(1)!.toUpperCase();
    return _bankCodes.any((b) => code.contains(b) || b.contains(code));
  }

  /// Notification-captured (RCS) senders are brand names like "Yes Bank",
  /// not DLT codes — matched by name instead of shape. Only consulted for
  /// notification captures, never for raw inbox SMS.
  ///
  /// Kept permissive: false positives just fail the body check; false negatives
  /// silently drop real transactions. Added acronym-only senders (SBI, PNB,
  /// IDBI, YES) for RCS senders that omit the word "Bank".
  // No bare `yes` / `bob` / `union`: those are common personal names and
  // words, and a contact named "Bob" texting "I paid Rs.500" imported as a
  // phantom expense. The two-token bank forms ("Yes Bank", "Bank of
  // Baroda", "Union Bank") all match via the `bank` alternative.
  static final RegExp _brandSenderRe = RegExp(
    r'bank|hdfc|icici|axis|kotak|paytm|phonepe|google pay|gpay|cred\b'
    r'|slice|idfc|indusind|rbl|citi|hsbc|canara|bhim|mobikwik|freecharge'
    r'|\bsbi\b|\bpnb\b|\bboi\b|\bidbi\b|\baubank\b'
    r'|\bfederal\b|\buco\b|\biob\b|\bscb\b|\bubs\b',
    caseSensitive: false,
  );

  static bool senderLooksBankBrand(String sender) =>
      _brandSenderRe.hasMatch(sender);

  /// Normalised bank code for an SMS sender, used to build account keys.
  /// From a DLT id (`VM-HDFCBK-S` → `HDFC`) the matching known bank code is
  /// returned; for a brand-name RCS sender ("Yes Bank") the first bank code
  /// whose name appears is used, else an upper-cased alphanumeric squash of
  /// the sender so distinct senders still get distinct keys.
  static String bankCodeOf(String sender) {
    final s = sender.trim();
    final m = _senderShape.firstMatch(s);
    if (m != null) {
      final code = m.group(1)!.toUpperCase();
      for (final b in _bankCodes) {
        if (code.contains(b) || b.contains(code)) return b;
      }
    }
    final upper = s.toUpperCase();
    for (final b in _bankCodes) {
      if (upper.contains(b)) return b;
    }
    // Yes Bank brand → YESBNK etc.: map common brand words to codes. Every
    // brand missing here silently mints a *separate* squash-coded account
    // ("Indian Bank" → INDIANBANK:2080) alongside the DLT-coded one
    // (INDBNK:2080), splitting one real account across two tiles.
    // INDUSIND must stay above INDIAN: first contains-match wins.
    const brandMap = {
      'YES': 'YESBNK',
      'HDFC': 'HDFC',
      'ICICI': 'ICICI',
      'AXIS': 'AXIS',
      'KOTAK': 'KOTAK',
      'SBI': 'SBI',
      'IDFC': 'IDFC',
      'INDUSIND': 'INDUS',
      'INDIAN': 'INDBNK',
      'IDBI': 'IDBI',
      'FEDERAL': 'FEDBNK',
      'CANARA': 'CANBNK',
      'UNION': 'UNION',
      'CENTRAL': 'CENTBK',
      'BARODA': 'BOB',
      'RBL': 'RBL',
      'CITI': 'CITI',
      'HSBC': 'HSBC',
      'PAYTM': 'PAYTM',
      'PHONEPE': 'PHONPE',
    };
    for (final e in brandMap.entries) {
      if (upper.contains(e.key)) return e.value;
    }
    return upper.replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  /// Bank names as they appear in message text, mapped to the same codes
  /// [bankCodeOf] produces for senders. Order matters: "Union Bank of India"
  /// and "Central Bank of India" must match before the bare "Bank of India".
  static final List<(RegExp, String)> _bodyBankNames = [
    (RegExp(r'\bicici\b', caseSensitive: false), 'ICICI'),
    (RegExp(r'\bhdfc\b', caseSensitive: false), 'HDFC'),
    (RegExp(r'\bsbi\b|\bstate\s+bank\b', caseSensitive: false), 'SBI'),
    (RegExp(r'\baxis\b', caseSensitive: false), 'AXIS'),
    (RegExp(r'\bkotak\b', caseSensitive: false), 'KOTAK'),
    (RegExp(r'\byes\s+bank\b', caseSensitive: false), 'YESBNK'),
    (RegExp(r'\bindian\s+bank\b', caseSensitive: false), 'INDBNK'),
    (RegExp(r'\bindusind\b', caseSensitive: false), 'INDUS'),
    (RegExp(r'\bidfc\b', caseSensitive: false), 'IDFC'),
    (RegExp(r'\bidbi\b', caseSensitive: false), 'IDBI'),
    (RegExp(r'\bpnb\b|\bpunjab\s+national\b', caseSensitive: false), 'PNB'),
    (RegExp(r'\bcanara\b', caseSensitive: false), 'CANBNK'),
    (RegExp(r'\bfederal\b', caseSensitive: false), 'FEDBNK'),
    (RegExp(r'\brbl\b', caseSensitive: false), 'RBL'),
    (RegExp(r'\bciti\b', caseSensitive: false), 'CITI'),
    (RegExp(r'\bhsbc\b', caseSensitive: false), 'HSBC'),
    (RegExp(r'\bunion\s+bank\b', caseSensitive: false), 'UNION'),
    (
      RegExp(r'\bcentral\s+bank\s+of\s+india\b', caseSensitive: false),
      'CENTBK',
    ),
    (RegExp(r'\bbank\s+of\s+baroda\b', caseSensitive: false), 'BOB'),
    (RegExp(r'\bbank\s+of\s+india\b', caseSensitive: false), 'BOI'),
  ];

  static String? _bodyBankCode(String text) {
    for (final (re, code) in _bodyBankNames) {
      if (re.hasMatch(text)) return code;
    }
    return null;
  }

  /// Extracts the account/card key and card hint from an alert body.
  /// Returns (key, isCard) or (null, false) when no usable fragment exists.
  ///
  /// A fragment introduced by ANOTHER bank's name is the other side of a
  /// transfer — "credited to ICICI Bank Account XXX879" inside an Indian Bank
  /// alert describes the beneficiary, not the sender's account. Keying it to
  /// the sending bank used to mint a chimera ("INDBNK:879"): an account that
  /// doesn't exist, wearing one bank's name and the other's digits. Such
  /// fragments are skipped; if the body names no fragment of the sender's
  /// own, the transaction simply gets no account key.
  static (String?, bool) accountKeyOf(String sender, String body) {
    final senderCode = bankCodeOf(sender);
    for (final m in _acctKeyRe.allMatches(body)) {
      // The bank name sits directly before the fragment keyword
      // ("ICICI Bank Account…", "YES BANK Card…") — a short window is
      // deliberate, anything wider would catch unrelated mentions.
      final windowStart = m.start < 24 ? 0 : m.start - 24;
      final named = _bodyBankCode(body.substring(windowStart, m.start));
      if (named != null && named != senderCode) continue;
      // "Debit Card" spends from a BANK account — treating any card keyword
      // as credit-card-ness minted a credit-card account, which hid the
      // account's real cash from netWorth and flagged a bogus
      // "missing credit limit".
      final keyword = m.group(1)?.toLowerCase();
      final isCard = keyword != null && !keyword.contains('debit');
      return ('$senderCode:${m.group(2)!}', isCard);
    }
    return (null, false);
  }

  /// The pre-foreign-check keying: first fragment + sender's bank code,
  /// unconditionally. Kept ONLY so the one-time re-key migration can tell a
  /// machine-derived key (equal to this) from a hand-assigned one (anything
  /// else) — do not use for new imports.
  static (String?, bool) legacyAccountKeyOf(String sender, String body) {
    final m = _acctKeyRe.firstMatch(body);
    if (m == null) return (null, false);
    return ('${bankCodeOf(sender)}:${m.group(2)!}', m.group(1) != null);
  }

  /// Extracts the `Avl Bal` / `Avl Lmt` figure, or null when absent.
  static double? balanceAfterOf(String body) {
    final m = _balanceAfterRe.firstMatch(body);
    if (m == null) return null;
    return double.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  /// Stage 2 filter: does the body look like a completed transaction alert?
  /// [ignorePhrases] defaults to the built-ins; the import service passes the
  /// user's editable import rules instead.
  static bool bodyLooksTransactional(
    String body, {
    List<String> ignorePhrases = kDefaultIgnorePhrases,
  }) {
    // Word-boundary matching, same as classifier rules — raw `contains`
    // let signals fire inside words ("earn" in "Learn more").
    for (final p in ignorePhrases) {
      if (patternMatchesText(p, body)) return false;
    }
    if (!_amountRe.hasMatch(body)) return false;
    return _expenseVerbRe.hasMatch(body) || _incomeVerbRe.hasMatch(body);
  }

  /// Whether the body carries promo/informational signals. [spamSignals]
  /// defaults to the built-ins; the import service passes the user's rules.
  static bool looksLikeSpam(
    String body, {
    List<String> spamSignals = kDefaultSpamSignals,
  }) => spamSignals.any((s) => patternMatchesText(s, body));

  /// First currency-prefixed number that is NOT the `Avl Bal` / `Avl Lmt`
  /// figure. A bare `_amountRe.firstMatch` took whichever prefixed number
  /// came first, so a body stating the balance before the amount — or one
  /// whose transaction amount carries no Rs/₹ prefix at all — imported the
  /// balance as the money amount and anchored the direction verb off it.
  /// Null when the only prefixed numbers ARE balance figures: refusing the
  /// import beats minting a known-wrong row.
  static RegExpMatch? _pickAmountMatch(String body) {
    final balanceSpans = [
      for (final m in _balanceAfterRe.allMatches(body)) (m.start, m.end),
    ];
    for (final m in _amountRe.allMatches(body)) {
      final insideBalance = balanceSpans.any(
        (s) => m.start >= s.$1 && m.end <= s.$2,
      );
      if (!insideBalance) return m;
    }
    return null;
  }

  /// Parse one message. Returns null when it is not a usable transaction
  /// (fails the filters, or amount/direction cannot be extracted).
  ///
  /// [relaxedSender] additionally accepts brand-name senders ("Yes Bank") —
  /// used for notification-captured RCS alerts, which carry the display name
  /// rather than a DLT code.
  static ParsedTxn? parse(
    String sender,
    String body,
    DateTime smsDate, {
    bool relaxedSender = false,
    List<String> ignorePhrases = kDefaultIgnorePhrases,
    List<String> spamSignals = kDefaultSpamSignals,
  }) {
    final senderOk =
        senderLooksFinancial(sender) ||
        (relaxedSender && senderLooksBankBrand(sender));
    if (!senderOk) return null;
    if (!bodyLooksTransactional(body, ignorePhrases: ignorePhrases)) {
      return null;
    }

    final amountMatch = _pickAmountMatch(body);
    if (amountMatch == null) return null;
    final amount = double.tryParse(amountMatch.group(1)!.replaceAll(',', ''));
    if (amount == null || amount <= 0) return null;

    var type = _direction(body, amountMatch.start);
    if (type == null) return null;
    // "NEFT of Rs.X credited to ICICI Bank Account XXX879" from an Indian
    // Bank sender: the credit verb describes the BENEFICIARY's side — the
    // money left the user, and importing it as income inflated totalIncome
    // permanently.
    if (type == TxType.income && _creditIsOutward(sender, body)) {
      type = TxType.expense;
    }
    // Reversal confirmations restate the original debit ("Rs.500 debited …
    // has been reversed and credited back"), so the nearest-verb heuristic
    // picks the debit — but the alert is about money RETURNING. Importing
    // it as a second expense would double the loss.
    if (type == TxType.expense &&
        _reversalRe.hasMatch(body) &&
        _incomeVerbRe.hasMatch(body)) {
      type = TxType.income;
    }

    final merchant = _merchant(body);
    final ref = _refRe.firstMatch(body)?.group(1);
    final date = resolveDateTime(body, smsDate);
    // Categorisation is rule-driven (built-in keyword mappings are seeded as
    // editable ClassifierRules), except credit-card bill payments, which the
    // parser recognises structurally: issuer-side confirmations become
    // `card_payment` income and bank-side debits `card_bill` expense.
    final String categoryId;
    if (_cardBillPaymentRe.hasMatch(body)) {
      categoryId = type == TxType.income
          ? kCardPaymentCategoryId
          : kCardBillCategoryId;
    } else {
      categoryId = type == TxType.expense ? 'other_expense' : 'other_income';
    }
    final (acctKey, isCard) = accountKeyOf(sender, body);

    return ParsedTxn(
      type: type,
      amount: amount,
      merchant: merchant,
      date: date,
      ref: ref,
      categoryId: categoryId,
      sender: sender.trim(),
      rawBody: body.trim(),
      spamSuspect: looksLikeSpam(body, spamSignals: spamSignals),
      acctKey: acctKey,
      balanceAfter: balanceAfterOf(body),
      isCard: isCard,
    );
  }

  /// Step-by-step diagnosis of how [parse] treats one message — backs the
  /// "Test a message" tool in the Classifiers → Import tab. Mirrors the real
  /// pipeline (dedup against existing transactions is not simulated).
  static String explain(
    String sender,
    String body,
    DateTime smsDate, {
    List<String> ignorePhrases = kDefaultIgnorePhrases,
    List<String> spamSignals = kDefaultSpamSignals,
  }) {
    final strictOk = senderLooksFinancial(sender);
    final brandOk = senderLooksBankBrand(sender);
    if (!strictOk && !brandOk) {
      return 'Not imported — sender "$sender" is not recognised as a bank or '
          'payment app.';
    }

    // Same boundary matcher as bodyLooksTransactional, or this tool reports
    // a rejection ("due" inside "overdue") for messages the real pipeline
    // imports — the diagnostic must never contradict the pipeline.
    for (final p in ignorePhrases) {
      if (p.isNotEmpty && patternMatchesText(p, body)) {
        return 'Not imported — matches the ignore rule "$p".';
      }
    }

    final amountMatch = _pickAmountMatch(body);
    if (amountMatch == null) {
      return _amountRe.hasMatch(body)
          ? 'Not imported — the only amount found is the balance/limit '
                'figure, not a transaction amount.'
          : 'Not imported — no amount (Rs / INR / ₹) found.';
    }
    final amount = double.tryParse(amountMatch.group(1)!.replaceAll(',', ''));
    if (amount == null || amount <= 0) {
      return 'Not imported — the amount could not be read.';
    }

    final type = _direction(body, amountMatch.start);
    if (type == null) {
      return 'Not imported — no debit verb (debited, spent, paid…) or '
          'credit verb (credited, received…) found.';
    }

    final result = parse(
      sender,
      body,
      smsDate,
      relaxedSender: true,
      ignorePhrases: ignorePhrases,
      spamSignals: spamSignals,
    )!;
    final cat = categoryById(result.categoryId);
    // Same boundary matcher as the real check, or the reported signal can
    // disagree with the one that actually fired.
    final spamHit = result.spamSuspect
        ? spamSignals.firstWhere(
            (s) => patternMatchesText(s, body),
            orElse: () => '',
          )
        : '';

    final timeSource =
        _bodyTimeOfDay(body, near: _dateRe.firstMatch(body)?.end) != null
        ? 'from the message'
        : (_dateRe.hasMatch(body)
              ? 'date from the message, time of arrival'
              : 'time of arrival');

    final parts = <String>[
      'Imports as ${result.type == TxType.expense ? 'expense' : 'income'} '
          'of ₹${result.amount.toStringAsFixed(2)} · ${cat.label}',
      'Dated: ${_explainFormat.format(result.date)} ($timeSource)',
      if (result.acctKey != null)
        'Account: ${result.acctKey}${result.isCard ? ' (card)' : ''}'
      else
        'Account: none detected',
      if (result.balanceAfter != null)
        'Reported balance/limit: ₹${result.balanceAfter!.toStringAsFixed(2)}',
      if (result.ref != null) 'Reference: ${result.ref}',
      if (result.spamSuspect)
        'Flagged as suspected spam (matches "$spamHit") — individual review',
      if (type == TxType.income && result.type == TxType.expense)
        'Note: "credited to" names another bank — treated as an outward '
            'transfer (money leaving your account).',
      if (type == TxType.expense && result.type == TxType.income)
        'Note: reversal alert — imported as money returned, not a second '
            'expense.',
      if (!strictOk)
        'Note: sender only matches as a brand name — imported via '
            'notification capture, not inbox SMS scans.',
    ];
    return parts.join('\n');
  }

  /// Income or expense — from the account holder's perspective. When a message
  /// contains both kinds of verb (UPI "debited from X and credited to Y"),
  /// the verb closest to the amount wins.
  static TxType? _direction(String body, int amountIndex) {
    int? bestDist;
    TxType? best;
    void scan(RegExp verbRe, TxType t) {
      for (final m in verbRe.allMatches(body)) {
        final d = (m.start - amountIndex).abs();
        if (bestDist == null || d < bestDist!) {
          bestDist = d;
          best = t;
        }
      }
    }

    scan(_expenseVerbRe, TxType.expense);
    scan(_incomeVerbRe, TxType.income);
    return best;
  }

  static final RegExp _creditedToRe = RegExp(
    r'\bcredited\s+to\b',
    caseSensitive: false,
  );

  static final RegExp _reversalRe = RegExp(
    r'\brevers(?:ed|al)\b',
    caseSensitive: false,
  );

  /// True when a credit verb in the body describes the OTHER side of an
  /// outward transfer: "credited to `<some other bank's>` account". The
  /// receiving bank's name must follow "credited to" directly; "credited to
  /// your …" is the user's own inward credit and never flips.
  static bool _creditIsOutward(String sender, String body) {
    final senderCode = bankCodeOf(sender);
    for (final m in _creditedToRe.allMatches(body)) {
      final windowEnd = m.end + 32 > body.length ? body.length : m.end + 32;
      final segment = body.substring(m.end, windowEnd);
      if (RegExp(r'^\s*your\b', caseSensitive: false).hasMatch(segment)) {
        continue;
      }
      final named = _bodyBankCode(segment);
      if (named != null && named != senderCode) return true;
    }
    return false;
  }

  /// Extracts the payee/merchant name from an alert body (`''` when none).
  /// Public: recurring-payment detection re-derives merchant identity from
  /// stored bodies, since [Tx] deliberately has no merchant field.
  static String merchantOf(String body) => _merchant(body);

  /// Account/card fragments that the keyword regex can pick up first, e.g.
  /// "from Card XX3010 at AMAZON" → "Card XX3010".
  static final RegExp _accountFragmentRe = RegExp(
    r'^(a/?c|acct|account|card)\b',
    caseSensitive: false,
  );

  /// Helpline footers: "To dispute call 18002662", "Not you? SMS BLOCK to
  /// 98…", "For disputes call …". They follow the same to/at/from keywords
  /// as a payee, so they surfaced as merchants ("Dispute Call 18002662").
  static final RegExp _footerRe = RegExp(
    r'\b(disputes?|call|sms|block|helpline|contact|enquir(?:y|ies)|customer\s*care|toll\s*free|not\s+you|unauthori[sz]ed)\b',
    caseSensitive: false,
  );

  static String _merchant(String body) {
    // First ACCEPTABLE capture, not first capture: an account fragment or a
    // footer earlier in the body must not hide the real payee after it.
    // A rejected capture can swallow the next keyword ("from Card XX3010 at
    // AMAZON" is one match), so the search resumes just past the rejected
    // keyword rather than past the whole match.
    for (var from = 0; ;) {
      final it = _merchantRe.allMatches(body, from).iterator;
      if (!it.moveNext()) return '';
      final m = it.current;
      from = m.start + 1;
      var name = m.group(1)!.trim();
      // UPI VPA like `merchant.name@okaxis` → keep the readable part.
      if (name.contains('@')) name = name.split('@').first;
      name = name
          .replaceAll(RegExp(r'[._*]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (name.isEmpty) continue;
      if (_accountFragmentRe.hasMatch(name)) continue;
      if (_footerRe.hasMatch(name)) continue;
      // No letters = a phone number, VPA number or bank reference ("SMS
      // BLOCK to 9840909000"), never a payee.
      if (!RegExp('[A-Za-z]').hasMatch(name)) continue;
      return name;
    }
  }

  static final List<DateFormat> _dateFormats = [
    DateFormat('dd-MM-yy'),
    DateFormat('dd-MM-yyyy'),
    DateFormat('dd/MM/yy'),
    DateFormat('dd/MM/yyyy'),
    DateFormat('dd-MMM-yy'),
    DateFormat('dd-MMM-yyyy'),
    DateFormat('ddMMMyy'),
  ];

  static final RegExp _dateRe = RegExp(
    // Standard format: "on 05-07-26" / "on 05Jul26" / "on 14-4-2026" —
    // the month component allows a single digit (HDFC writes "14-4-2026").
    r'\bon\s+(\d{1,2}[-/][A-Za-z0-9]{1,3}[-/]\d{2,4}|\d{1,2}[A-Za-z]{3}\d{2,4})'
    // Yes Bank / some banks: "06-07-2026 02:07:35 pm" — date immediately
    // precedes a time stamp, no "on" required.
    r'|\s(\d{2}[-/]\d{2}[-/]\d{4})\s+\d{1,2}:\d{2}:\d{2}',
    caseSensitive: false,
  );

  // Clock time inside the body: "02:07:35 pm", "18:45", "at 11:23 hrs".
  // A bank reference like "UPI:614963611754" cannot match — the pattern
  // requires digits *before* the colon.
  static final RegExp _timeRe = RegExp(
    r'\b(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?|hrs?)?',
    caseSensitive: false,
  );

  /// Zero-pads a single-digit day/month so the numeric [_dateFormats] patterns
  /// accept it. Alphabetic months ("31-MAY-26") are left untouched — the
  /// second group only matches when the month is numeric.
  static String _padDayMonth(String raw) => raw.replaceFirstMapped(
    RegExp(r'^(\d{1,2})([-/])(\d{1,2})([-/])'),
    (m) => '${m[1]!.padLeft(2, '0')}${m[2]}${m[3]!.padLeft(2, '0')}${m[4]}',
  );

  static DateTime? _parseDate(String raw) {
    final padded = _padDayMonth(raw);
    for (final f in _dateFormats) {
      try {
        final d = f.parseLoose(padded);
        // Guard against two-digit-year parses landing in the far past/future.
        if (d.year > 2000 && d.year < 2100) return d;
      } catch (_) {
        // try next format
      }
    }
    return null;
  }

  /// Time-of-day stated in the body, or null when none is present.
  ///
  /// When [near] is given, a time starting within 20 characters after that
  /// offset wins — that is the "06-07-2026 02:07:35 pm" shape, where the clock
  /// time belongs to the date just matched. Otherwise the first time-looking
  /// token in the body is used.
  static Duration? _bodyTimeOfDay(String body, {int? near}) {
    Match? pick;
    for (final m in _timeRe.allMatches(body)) {
      if (near != null && m.start >= near && m.start - near <= 20) {
        pick = m;
        break;
      }
      pick ??= m;
    }
    if (pick == null) return null;
    var hour = int.tryParse(pick.group(1)!);
    final minute = int.tryParse(pick.group(2)!);
    final second = int.tryParse(pick.group(3) ?? '') ?? 0;
    if (hour == null || minute == null) return null;
    final suffix = pick.group(4)?.toLowerCase().replaceAll('.', '');
    if (suffix == 'pm' && hour < 12) hour += 12;
    if (suffix == 'am' && hour == 12) hour = 0;
    if (hour > 23 || minute > 59 || second > 59) return null;
    return Duration(hours: hour, minutes: minute, seconds: second);
  }

  /// The timestamp to record for an alert. Precedence:
  ///
  /// 1. date **and** clock time from the body — the most precise thing we have;
  /// 2. body date + the arrival time-of-day — the alert names a day but no
  ///    clock time, and the moment it arrived is the closest approximation;
  /// 3. the arrival timestamp verbatim, when the body names no date.
  ///
  /// Rule 2 matters: a body-dated alert used to collapse to midnight, which
  /// made same-day ordering arbitrary and made the ref-less duplicate check
  /// (same type + amount + sender within 3 minutes) swallow genuinely distinct
  /// transactions from the same day.
  static DateTime resolveDateTime(String body, DateTime smsDate) {
    final m = _dateRe.firstMatch(body);
    final raw = m == null ? null : (m.group(1) ?? m.group(2));
    final date = raw == null ? null : _parseDate(raw);
    if (date == null) return smsDate;
    // A transaction alert can only describe something that already happened.
    // A body date materially after the arrival time is a *due* date ("EMI
    // debited … next due on 05-09-26"), and stamping the row forward would
    // let it out-rank every newer bank figure — and any manually set balance
    // — for weeks. Trust the arrival timestamp instead. One day of slack
    // covers midnight-edge and clock-skew cases.
    if (DateTime(
      date.year,
      date.month,
      date.day,
    ).isAfter(smsDate.add(const Duration(days: 1)))) {
      return smsDate;
    }
    final tod = _bodyTimeOfDay(body, near: m!.end);
    if (tod != null) return DateTime(date.year, date.month, date.day).add(tod);
    return DateTime(
      date.year,
      date.month,
      date.day,
      smsDate.hour,
      smsDate.minute,
      smsDate.second,
    );
  }

  /// Re-stamps a stored transaction date with the clock time its original SMS
  /// body carried, or null when the body states none. Used to backfill history
  /// imported before timestamps were recorded — the SMS arrival time is not
  /// stored anywhere, but a body time can still be recovered.
  static DateTime? dateWithBodyTime(DateTime date, String body) {
    final m = _dateRe.firstMatch(body);
    final tod = _bodyTimeOfDay(body, near: m?.end);
    if (tod == null) return null;
    return DateTime(date.year, date.month, date.day).add(tod);
  }
}
