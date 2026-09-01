/// Built-in keyword → category mappings, seeded into the user's classifier
/// rules on first launch (ids prefixed `builtin_`). They used to be
/// hard-coded inside the SMS parser; as real rules they are visible,
/// editable and deletable in the Classifiers page, and user-created rules
/// always outrank them (rules are matched first-in-list).
const Map<String, String> kDefaultKeywordCategories = {
  'swiggy': 'food',
  'zomato': 'food',
  'dominos': 'food',
  'mcdonald': 'food',
  'kfc': 'food',
  'pizza': 'food',
  'restaurant': 'food',
  'uber': 'transport',
  'ola': 'transport',
  'rapido': 'transport',
  'irctc': 'transport',
  'redbus': 'transport',
  'metro': 'transport',
  'petrol': 'transport',
  'fuel': 'transport',
  'hpcl': 'transport',
  'iocl': 'transport',
  'bpcl': 'transport',
  'amazon': 'shopping',
  'flipkart': 'shopping',
  'myntra': 'shopping',
  'ajio': 'shopping',
  'meesho': 'shopping',
  'netflix': 'entertainment',
  'spotify': 'entertainment',
  'hotstar': 'entertainment',
  'bookmyshow': 'entertainment',
  'prime video': 'entertainment',
  'airtel': 'bills',
  'jio': 'bills',
  'vodafone': 'bills',
  'bsnl': 'bills',
  'electricity': 'bills',
  'bescom': 'bills',
  'tneb': 'bills',
  'broadband': 'bills',
  'recharge': 'bills',
  'dth': 'bills',
  'pharmacy': 'health',
  'apollo': 'health',
  'medplus': 'health',
  'hospital': 'health',
  'clinic': 'health',
  'netmeds': 'health',
  'udemy': 'education',
  'coursera': 'education',
  'school': 'education',
  'college': 'education',
  'salary': 'salary',
  'sal credit': 'salary',
  'dividend': 'investment',
  'interest': 'investment',
};

/// Phrases that mark a message as *not* an actual completed transaction —
/// seeded into the user's import rules on first launch (kind: ignore).
const List<String> kDefaultIgnorePhrases = [
  'otp',
  'one time password',
  'one-time password',
  'will be debited',
  'will be deducted',
  'has requested',
  'requested money',
  'payment request',
  'collect request',
  'failed',
  'declined',
  // 'reversed' removed: dropping reversal alerts left the ORIGINAL debit
  // uncancelled forever — a refund now imports (as income) for review.
  'could not be',
  'insufficient',
  // 'is due' / 'due on' removed: they rejected genuine completed-EMI debits
  // whose footer says "Next EMI due on …". Pure reminders still fail the
  // debit/credit-verb check, and the future-date guard handles due dates.
  'amount due',
  'e-statement',
  // 'statement' intentionally omitted: too broad — Yes Bank and many others
  // include "For statement enquiry call …" in the footer of genuine alerts.
];

/// Signals that a parsed transaction is likely promotional or informational
/// noise — seeded as import rules (kind: spamSignal). These never reject a
/// message; they flag it for individual review.
const List<String> kDefaultSpamSignals = [
  'offer',
  'cashback',
  'win ',
  'reward',
  'voucher',
  'earn',
  't&c',
  'apply now',
  'know more',
  'missed call',
  'increasing the limit',
  'raise the limit',
  'upgrade',
  'pre-approved',
  'personal loan',
  'standing instruction',
  'mandate',
  'pay instantly',
  'http://',
  'https://',
  'congratulations',
];
