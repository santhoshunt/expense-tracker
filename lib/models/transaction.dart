import 'package:flutter/material.dart';

import '../utils/figma_palette.dart';

enum TxType { income, expense }

class TxCategory {
  final String id;
  final String label;
  final IconData icon;
  final Color color;
  final TxType type;

  /// Moves money between the user's own accounts/instruments. Affects
  /// per-account balances but is excluded from every income/expense
  /// aggregate; [type] still gives the direction (expense = money out,
  /// income = money in).
  final bool isTransfer;

  const TxCategory({
    required this.id,
    required this.label,
    required this.icon,
    required this.color,
    required this.type,
    this.isTransfer = false,
  });

  /// Only user-created categories are serialized; the icon is stored by
  /// name (see [kCategoryIconChoices]) so icon tree-shaking keeps working.
  /// The transfer flag is omitted when false so older builds read the same
  /// payload they always did (and ignore the key when present).
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'type': type.name,
    if (isTransfer) 'transfer': true,
    'icon': kCategoryIconChoices.entries
        .firstWhere(
          (e) => e.value == icon,
          orElse: () => kCategoryIconChoices.entries.first,
        )
        .key,
    'color': color.toARGB32(),
  };

  factory TxCategory.fromJson(Map<String, dynamic> json) => TxCategory(
    id: json['id'] as String,
    label: json['label'] as String,
    type: TxType.values.byName(json['type'] as String),
    isTransfer: json['transfer'] as bool? ?? false,
    icon: kCategoryIconChoices[json['icon']] ?? Icons.category,
    color: Color(json['color'] as int),
  );
}

/// Icon options for user-created categories — a fixed const map so icons
/// stay tree-shakeable (dynamic IconData from a stored codePoint would not).
const Map<String, IconData> kCategoryIconChoices = {
  'category': Icons.category,
  'home': Icons.home,
  'groceries': Icons.shopping_cart,
  'cafe': Icons.local_cafe,
  'pets': Icons.pets,
  'child': Icons.child_care,
  'fitness': Icons.fitness_center,
  'travel': Icons.flight,
  'fuel': Icons.local_gas_station,
  'phone': Icons.smartphone,
  'wifi': Icons.wifi,
  'power': Icons.bolt,
  'water': Icons.water_drop,
  'rent': Icons.house,
  'tools': Icons.build,
  'work': Icons.work,
  'cash': Icons.payments,
  'savings': Icons.savings,
  'invest': Icons.trending_up,
  'heart': Icons.favorite,
  'star': Icons.star,
  'music': Icons.music_note,
  'game': Icons.sports_esports,
  'book': Icons.menu_book,
  // The built-in categories' own icons — present so overriding a built-in's
  // name/colour while keeping its icon survives serialization, and so these
  // icons are pickable like any other.
  'food': Icons.restaurant,
  'car': Icons.directions_car,
  'bag': Icons.shopping_bag,
  'bill': Icons.receipt_long,
  'movie': Icons.movie,
  'school': Icons.school,
  'card': Icons.credit_card,
  'transfer': Icons.sync_alt,
  'shop': Icons.storefront,
  'gift': Icons.card_giftcard,
  'cardOk': Icons.credit_score,
  'money': Icons.attach_money,
  'group': Icons.group,
};

/// Colour options for user-created categories.
const List<Color> kCategoryColorChoices = [
  FigmaPalette.primary,
  FigmaPalette.orange,
  FigmaPalette.green,
  FigmaPalette.blue,
  FigmaPalette.purple,
  FigmaPalette.pink,
  FigmaPalette.primaryLight,
  FigmaPalette.textMuted,
];

const List<TxCategory> kCategories = [
  // Expense categories
  TxCategory(
    id: 'food',
    label: 'Food & Dining',
    icon: Icons.restaurant,
    color: FigmaPalette.primary,
    type: TxType.expense,
  ),
  TxCategory(
    id: 'transport',
    label: 'Transport',
    icon: Icons.directions_car,
    color: FigmaPalette.blue,
    type: TxType.expense,
  ),
  TxCategory(
    id: 'shopping',
    label: 'Shopping',
    icon: Icons.shopping_bag,
    color: FigmaPalette.purple,
    type: TxType.expense,
  ),
  TxCategory(
    id: 'bills',
    label: 'Bills & Utilities',
    icon: Icons.receipt_long,
    color: FigmaPalette.orange,
    type: TxType.expense,
  ),
  TxCategory(
    id: 'health',
    label: 'Health',
    icon: Icons.favorite,
    color: FigmaPalette.pink,
    type: TxType.expense,
  ),
  TxCategory(
    id: 'entertainment',
    label: 'Entertainment',
    icon: Icons.movie,
    color: FigmaPalette.green,
    type: TxType.expense,
  ),
  TxCategory(
    id: 'education',
    label: 'Education',
    icon: Icons.school,
    color: FigmaPalette.primaryLight,
    type: TxType.expense,
  ),
  // The bank-side debit of a credit-card bill payment. Its mirror image is
  // the `card_payment` income on the card account — the two net out.
  TxCategory(
    id: kCardBillCategoryId,
    label: 'Card bill',
    icon: Icons.credit_card,
    color: FigmaPalette.textMuted,
    type: TxType.expense,
    isTransfer: true,
  ),
  // Money leaving for another of the user's own accounts.
  TxCategory(
    id: kTransferOutCategoryId,
    label: 'Transfer out',
    icon: Icons.sync_alt,
    color: FigmaPalette.blue,
    type: TxType.expense,
    isTransfer: true,
  ),
  // Money moved into a savings instrument (RD/FD/PPF) — not spending, but
  // tracked separately as savings.
  TxCategory(
    id: kSavingsTransferCategoryId,
    label: 'To savings',
    icon: Icons.savings,
    color: FigmaPalette.orange,
    type: TxType.expense,
    isTransfer: true,
  ),
  // The friends' portion of a bill the user fronted — money that went out
  // but is expected back, so a transfer, not spend. Rows rarely carry this
  // category directly; group-split remainders are attributed to it inside
  // the totals engine (see Tx.myShare).
  TxCategory(
    id: kPaidForOthersCategoryId,
    label: 'Paid for Others',
    icon: Icons.group,
    color: FigmaPalette.purple,
    type: TxType.expense,
    isTransfer: true,
  ),
  TxCategory(
    id: 'other_expense',
    label: 'Other',
    icon: Icons.category,
    color: FigmaPalette.textMuted,
    type: TxType.expense,
  ),
  // Income categories
  TxCategory(
    id: 'salary',
    label: 'Salary',
    icon: Icons.payments,
    color: FigmaPalette.green,
    type: TxType.income,
  ),
  TxCategory(
    id: 'business',
    label: 'Business',
    icon: Icons.storefront,
    color: FigmaPalette.orange,
    type: TxType.income,
  ),
  TxCategory(
    id: 'investment',
    label: 'Investments',
    icon: Icons.trending_up,
    color: FigmaPalette.blue,
    type: TxType.income,
  ),
  TxCategory(
    id: 'gift',
    label: 'Gifts',
    icon: Icons.card_giftcard,
    color: FigmaPalette.purple,
    type: TxType.income,
  ),
  // Issuer-side confirmation that a card bill payment was received.
  TxCategory(
    id: kCardPaymentCategoryId,
    label: 'Card payment',
    icon: Icons.credit_score,
    color: FigmaPalette.textMuted,
    type: TxType.income,
    isTransfer: true,
  ),
  // Money arriving from another of the user's own accounts.
  TxCategory(
    id: kTransferInCategoryId,
    label: 'Transfer in',
    icon: Icons.sync_alt,
    color: FigmaPalette.blue,
    type: TxType.income,
    isTransfer: true,
  ),
  // Must stay last: categoryById falls back to kCategories.last.
  TxCategory(
    id: 'other_income',
    label: 'Other',
    icon: Icons.attach_money,
    color: FigmaPalette.textMuted,
    type: TxType.income,
  ),
];

/// User-created categories, populated by FinanceProvider on load. A module
/// registry (not provider state) because [Tx.category] and [categoryById]
/// are used from contexts without provider access.
final List<TxCategory> _customCategories = [];

List<TxCategory> get customCategories => List.unmodifiable(_customCategories);

void setCustomCategories(Iterable<TxCategory> categories) {
  _customCategories
    ..clear()
    ..addAll(categories);
  _rebuildTransferIds();
  _invalidateCategoryCaches();
}

/// User edits to built-in categories, keyed by id. Built-ins are const so
/// edits live here. An override may change anything — including
/// [TxCategory.type] and [TxCategory.isTransfer]; the provider re-types
/// existing rows when the direction changes so aggregates stay consistent.
Map<String, TxCategory> _builtinOverrides = {};

Map<String, TxCategory> get builtinOverrides =>
    Map.unmodifiable(_builtinOverrides);

void setBuiltinOverrides(Map<String, TxCategory> overrides) {
  _builtinOverrides = Map.of(overrides);
  // Overrides can toggle isTransfer, so this writer must rebuild the
  // transfer set too — not just setCustomCategories.
  _rebuildTransferIds();
  _invalidateCategoryCaches();
}

/// O(1) transfer lookups for the per-transaction hot loops in totals and
/// filters — rebuilt by BOTH registry writers. Derived from the effective
/// (override-applied) definitions, never from the const seed alone, so an
/// override can add or remove transfer-ness on a built-in.
void _rebuildTransferIds() {
  _transferCategoryIds = {
    for (final c in kCategories)
      if ((_builtinOverrides[c.id] ?? c).isTransfer) c.id,
    for (final c in _customCategories)
      if (c.isTransfer) c.id,
  };
}

/// Cached views over the registry. [categoryById] runs per transaction in
/// totals, filters, rule re-application and exports, so both the combined
/// list and the id lookup are built once per registry write instead of per
/// call.
List<TxCategory>? _allCategoriesCache;
Map<String, TxCategory>? _categoryByIdCache;

void _invalidateCategoryCaches() {
  _allCategoriesCache = null;
  _categoryByIdCache = null;
}

/// Built-in (with any user overrides applied) + user-created categories —
/// what pickers should offer.
List<TxCategory> get allCategories =>
    _allCategoriesCache ??= List.unmodifiable([
      for (final c in kCategories) _builtinOverrides[c.id] ?? c,
      ..._customCategories,
    ]);

TxCategory categoryById(String id, {TxType? fallbackType}) {
  final cache = _categoryByIdCache ??= {for (final c in allCategories) c.id: c};
  // Fallback for unknown ids is the OVERRIDE-APPLIED "Other", not the
  // pristine const — a renamed/restyled Other must show its edits
  // everywhere. Direction-aware when the caller knows the row's type: a
  // dangling custom-category id on an EXPENSE row (e.g. after a corrupt
  // custom-categories blob resets the registry) must not render under
  // Other-income's identity.
  final fallbackId = fallbackType == TxType.expense
      ? 'other_expense'
      : kCategories.last.id;
  return cache[id] ?? cache[fallbackId] ?? kCategories.last;
}

/// Where a transaction came from.
enum TxSource { manual, sms }

class Tx {
  final String id;
  final TxType type;
  final String categoryId;
  final double amount;

  /// Free-text user note. Historically SMS imports stored the raw alert here;
  /// that text now lives in [smsBody] and this field is user text only.
  final String note;

  /// The raw SMS/notification body this row was imported from — kept verbatim
  /// so account keys, balances and classifier rules can always be re-derived.
  /// Empty for manual entries.
  final String smsBody;
  final DateTime date;
  final TxSource source;

  /// Who the money moved to/from — free text. SMS imports fill this with the
  /// SMS sender id (bank DLT code or phone number) automatically.
  final String sender;

  /// Bank reference / UPI transaction id, used to deduplicate SMS imports.
  final String? externalRef;

  /// SMS imports start pending and are excluded from totals until the user
  /// confirms them in the review queue.
  final bool pending;

  /// Pending import flagged as likely promotional noise — reviewed one by
  /// one, excluded from "Confirm all".
  final bool suspectedSpam;

  /// The user picked this row's category by hand. Classifier rules being
  /// (re-)applied to history must never override a manual correction.
  final bool userCategorized;

  /// Account-match key `"<bankCode>:<last4>"` this transaction belongs to,
  /// derived from the SMS (or assigned manually). Null when unknown.
  final String? acctKey;

  /// The `Avl Bal` (bank) or `Avl Lmt` (card) figure the alert reported right
  /// after this transaction — the authoritative account balance/limit at that
  /// moment. Null when the SMS carried no such figure.
  final double? balanceAfter;

  /// Group split: the user's own portion of a bill they paid in full. Null
  /// means not a split. Only the share counts as spend; the remainder
  /// ([frontedAmount]) is attributed to [kPaidForOthersCategoryId] by the
  /// totals engine. Only meaningful on expense-typed, non-transfer rows —
  /// inert (ignored) anywhere else.
  final double? myShare;

  const Tx({
    required this.id,
    required this.type,
    required this.categoryId,
    required this.amount,
    required this.note,
    this.smsBody = '',
    required this.date,
    this.source = TxSource.manual,
    this.sender = '',
    this.externalRef,
    this.pending = false,
    this.suspectedSpam = false,
    this.userCategorized = false,
    this.acctKey,
    this.balanceAfter,
    this.myShare,
  });

  TxCategory get category => categoryById(categoryId, fallbackType: type);

  /// Whether this row is a group split (the user fronted the full [amount]
  /// but only [myShare] of it is their own spending).
  bool get isSplit => myShare != null;

  /// What this row contributes to spend aggregates: the user's own share for
  /// splits, the full amount otherwise.
  double get spendAmount => myShare ?? amount;

  /// The fronted remainder of a split — money owed back by the group. Zero
  /// for non-split rows.
  double get frontedAmount => myShare == null ? 0 : amount - myShare!;

  /// The SMS text behind this row — [smsBody], falling back to [note] for
  /// rows persisted before smsBody existed or ingested un-normalized.
  String get smsText => smsBody.isNotEmpty ? smsBody : note;

  /// Moves a legacy raw-SMS-in-note payload into [smsBody]. Returns `this`
  /// unchanged (identical) for manual rows, already-migrated rows, and rows
  /// with nothing to move — callers can cheaply `identical()`-check.
  Tx migrateSmsBodyFromNote() {
    if (source != TxSource.sms || smsBody.isNotEmpty || note.isEmpty) {
      return this;
    }
    return Tx(
      id: id,
      type: type,
      categoryId: categoryId,
      amount: amount,
      note: '',
      smsBody: note,
      date: date,
      source: source,
      sender: sender,
      externalRef: externalRef,
      pending: pending,
      suspectedSpam: suspectedSpam,
      userCategorized: userCategorized,
      acctKey: acctKey,
      balanceAfter: balanceAfter,
      myShare: myShare,
    );
  }

  Tx copyWith({
    TxType? type,
    String? categoryId,
    double? amount,
    String? note,
    DateTime? date,
    String? sender,
    bool? pending,
    bool? userCategorized,
    String? acctKey,
    bool clearAcctKey = false,
    double? balanceAfter,
    // The stated balance describes the account the SMS was about. When a
    // transaction is reassigned to a different account that figure must not
    // travel with it — as an "anchor" it would overwrite the target account's
    // balance with another bank's number.
    bool clearBalanceAfter = false,
    double? myShare,
    bool clearMyShare = false,
  }) => Tx(
    id: id,
    type: type ?? this.type,
    categoryId: categoryId ?? this.categoryId,
    amount: amount ?? this.amount,
    note: note ?? this.note,
    // Carried verbatim like source: no edit path may clobber the raw SMS.
    smsBody: smsBody,
    date: date ?? this.date,
    source: source,
    sender: sender ?? this.sender,
    externalRef: externalRef,
    pending: pending ?? this.pending,
    suspectedSpam: suspectedSpam,
    userCategorized: userCategorized ?? this.userCategorized,
    acctKey: clearAcctKey ? null : (acctKey ?? this.acctKey),
    balanceAfter: clearBalanceAfter
        ? null
        : (balanceAfter ?? this.balanceAfter),
    myShare: clearMyShare ? null : (myShare ?? this.myShare),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'categoryId': categoryId,
    'amount': amount,
    'note': note,
    if (smsBody.isNotEmpty) 'smsBody': smsBody,
    'date': date.toIso8601String(),
    'source': source.name,
    if (sender.isNotEmpty) 'sender': sender,
    if (externalRef != null) 'externalRef': externalRef,
    if (pending) 'pending': pending,
    if (suspectedSpam) 'suspectedSpam': suspectedSpam,
    if (userCategorized) 'userCategorized': userCategorized,
    if (acctKey != null) 'acctKey': acctKey,
    if (balanceAfter != null) 'balanceAfter': balanceAfter,
    if (myShare != null) 'myShare': myShare,
  };

  factory Tx.fromJson(Map<String, dynamic> json) => Tx(
    id: json['id'] as String,
    type: TxType.values.byName(json['type'] as String),
    categoryId: json['categoryId'] as String,
    amount: (json['amount'] as num).toDouble(),
    note: json['note'] as String? ?? '',
    smsBody: json['smsBody'] as String? ?? '',
    date: DateTime.parse(json['date'] as String),
    source: TxSource.values.byName(json['source'] as String? ?? 'manual'),
    sender: json['sender'] as String? ?? '',
    externalRef: json['externalRef'] as String?,
    pending: json['pending'] as bool? ?? false,
    suspectedSpam: json['suspectedSpam'] as bool? ?? false,
    userCategorized: json['userCategorized'] as bool? ?? false,
    acctKey: json['acctKey'] as String?,
    balanceAfter: (json['balanceAfter'] as num?)?.toDouble(),
    myShare: (json['myShare'] as num?)?.toDouble(),
  );
}

/// Special classifier target: a matching SMS is confirmed spam and is never
/// imported at all.
const String kSpamCategoryId = 'spam';

/// Bank-side expense of a credit-card bill payment ("debited towards your
/// credit card"). Excluded from the monthly budget: the underlying card
/// swipes were already counted as expenses.
const String kCardBillCategoryId = 'card_bill';

/// Issuer-side income of a credit-card bill payment ("payment received on
/// your credit card") — credited to the card account.
const String kCardPaymentCategoryId = 'card_payment';

/// Own-account transfers: bank → bank movements the user (or a rule)
/// classifies explicitly.
const String kTransferOutCategoryId = 'transfer_out';
const String kTransferInCategoryId = 'transfer_in';

/// Money moved to a savings instrument (RD/FD/PPF). Excluded from expenses
/// like any transfer, but additionally surfaced as "saved" — it reduces
/// disposable income.
const String kSavingsTransferCategoryId = 'savings_out';

/// The friends' portion of a group bill the user paid in full ([Tx.myShare]).
/// A transfer: the money left the account but is owed back, so it must not
/// count as spend — yet stays tracked, not unaccounted.
const String kPaidForOthersCategoryId = 'paid_for_others';

/// Built-in categories that move money between the user's own accounts. They
/// stay in the ledger for auditing (and per-account balances), but are
/// excluded from every income/expense aggregate — counting them would inflate
/// both sides. User-created categories join in via [TxCategory.isTransfer].
const Set<String> kTransferCategoryIds = {
  kCardBillCategoryId,
  kCardPaymentCategoryId,
  kTransferOutCategoryId,
  kTransferInCategoryId,
  kSavingsTransferCategoryId,
  kPaidForOthersCategoryId,
};

/// Effective transfer ids (override-applied built-ins + flagged customs),
/// kept in sync by [setCustomCategories] and [setBuiltinOverrides] via
/// [_rebuildTransferIds]. Seeded with the const defaults for the window
/// before either writer runs.
Set<String> _transferCategoryIds = {...kTransferCategoryIds};

bool isTransferCategory(String categoryId) =>
    _transferCategoryIds.contains(categoryId);

/// User-defined categorisation rule: when an SMS body contains [pattern]
/// (case-insensitive), the imported transaction gets [categoryId] — or is
/// dropped entirely when [categoryId] is [kSpamCategoryId].
bool _isPatternLetter(int codeUnit) =>
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

bool _isPatternDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// Case-insensitive contains with edge boundaries — the matcher behind
/// classifier rules AND the importer's ignore phrases / spam signals.
///
/// A pattern edge that is a letter must sit on a letter boundary in the
/// text (plain `contains` mis-fired inside words: "RD Ac" matched
/// "ca**rd ac**count" in every credit-card alert; the spam signal "earn"
/// fired on "**Learn** more"). A digit edge likewise needs a digit
/// boundary, so a rule on an account's last-4 like "2080" can't fire
/// inside "UPI Ref 30**2080**123456". A letter may still neighbour a digit
/// ("swiggy" matches inside "swiggy8") — pinned by tests. Other edge
/// characters (symbols, spaces) match anywhere.
bool patternMatchesText(String pattern, String text) {
  final p = pattern.toLowerCase().trim();
  if (p.isEmpty) return false;
  final t = text.toLowerCase();
  final first = p.codeUnitAt(0);
  final last = p.codeUnitAt(p.length - 1);
  bool clashes(int edge, int neighbour) =>
      (_isPatternLetter(edge) && _isPatternLetter(neighbour)) ||
      (_isPatternDigit(edge) && _isPatternDigit(neighbour));
  var from = 0;
  while (true) {
    final i = t.indexOf(p, from);
    if (i == -1) return false;
    final okStart = i == 0 || !clashes(first, t.codeUnitAt(i - 1));
    final end = i + p.length;
    final okEnd = end == t.length || !clashes(last, t.codeUnitAt(end));
    if (okStart && okEnd) return true;
    from = i + 1;
  }
}

class ClassifierRule {
  final String id;
  final String pattern;
  final String categoryId;

  const ClassifierRule({
    required this.id,
    required this.pattern,
    required this.categoryId,
  });

  bool get isSpamRule => categoryId == kSpamCategoryId;

  /// Seeded from the built-in keyword defaults rather than created by the
  /// user. Built-ins categorise but never override the spam heuristic.
  bool get isBuiltIn => id.startsWith('builtin_');

  /// OR-alternatives: [pattern] may hold several conditions separated by
  /// `|` ("chai | biryani" → matches either). Stored as one string so the
  /// backup schema, merge-by-id and every addRule/updateRule call site stay
  /// untouched. Empty segments are ignored.
  List<String> get patterns => [
    for (final p in pattern.split('|'))
      if (p.trim().isNotEmpty) p.trim(),
  ];

  /// True when any alternative matches — see [patternMatchesText] for the
  /// per-alternative boundary rules.
  bool matches(String text) => patterns.any((p) => patternMatchesText(p, text));

  ClassifierRule copyWith({String? pattern, String? categoryId}) =>
      ClassifierRule(
        id: id,
        pattern: pattern ?? this.pattern,
        categoryId: categoryId ?? this.categoryId,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'pattern': pattern,
    'categoryId': categoryId,
  };

  factory ClassifierRule.fromJson(Map<String, dynamic> json) => ClassifierRule(
    id: json['id'] as String,
    pattern: json['pattern'] as String,
    categoryId: json['categoryId'] as String,
  );
}
