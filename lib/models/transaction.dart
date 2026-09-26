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

/// "No colour": the muted grey, which every category badge (a 15% wash of
/// the colour behind an icon in it) renders as a neutral chip. The built-in
/// "Other" categories use it too.
const Color kNoCategoryColor = FigmaPalette.textMuted;

/// Hue columns of [kCategoryColorChoices], in order.
const List<String> kCategoryHueNames = [
  'Coral',
  'Sunset',
  'Amber',
  'Mint',
  'Teal',
  'Sky',
  'Iris',
  'Rose',
];

/// Colour options for categories: three rows (light, base, deep) of the
/// eight [kCategoryHueNames] columns. The base row holds the kit hues the
/// built-ins use, and Coral light is [FigmaPalette.primaryLight], so every
/// built-in colour stays pickable. Deep tones clear 3:1 against the dark
/// card surface, where category glyphs are drawn in these colours.
const List<Color> kCategoryColorChoices = [
  // Light (35% toward white)
  FigmaPalette.primaryLight,
  Color(0xFFFFCFA3),
  Color(0xFFF9D68C),
  Color(0xFF8DE1C8),
  Color(0xFF77D9D0),
  Color(0xFF9BCCF9),
  Color(0xFFB8B7FE),
  Color(0xFFFFAAC3),
  // Base
  FigmaPalette.primary,
  FigmaPalette.orange,
  Color(0xFFF5C04E),
  FigmaPalette.green,
  Color(0xFF2EC4B6),
  FigmaPalette.blue,
  FigmaPalette.purple,
  FigmaPalette.pink,
  // Deep (22% toward black)
  Color(0xFFB76152),
  Color(0xFFC78D59),
  Color(0xFFBF963D),
  Color(0xFF3EA385),
  Color(0xFF24998E),
  Color(0xFF4F89C0),
  Color(0xFF7270C6),
  Color(0xFFC7617F),
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
  // A friend paying back their part of a split bill: money in, but a
  // transfer, since the bill's friends' portion never counted as spend.
  TxCategory(
    id: kRepaidToMeCategoryId,
    label: 'Repaid to me',
    icon: Icons.group,
    color: FigmaPalette.purple,
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

  /// Transfer pairing: the two legs of one own-account move (bank debit +
  /// savings/card credit) share this id. Both legs also sit in transfer
  /// categories, so every category-based aggregate is already correct; the
  /// link exists for display, for delete/unpair bookkeeping, and to stop the
  /// savings-account sign inversion (see FinanceProvider._computeFigures).
  /// Null for the ordinary single-row case.
  final String? pairId;

  /// User labels that cut across categories ("Goa trip", "Reimbursable"),
  /// already normalized by [normalizeTags]. Empty for most rows.
  final List<String> tags;

  /// Who else was in a group split and what each owes, summing to
  /// [frontedAmount]. Empty for plain rows and for splits entered without
  /// names, which count toward nobody's balance.
  final List<SplitShare> people;

  /// On a [kRepaidToMeCategoryId] row: the person paying back. Null
  /// everywhere else.
  final String? repaidBy;

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
    this.pairId,
    this.tags = const [],
    this.people = const [],
    this.repaidBy,
  });

  TxCategory get category => categoryById(categoryId, fallbackType: type);

  /// Whether this split names who owes what.
  bool get tracksPeople => people.isNotEmpty;

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
      pairId: pairId,
      tags: tags,
      people: people,
      repaidBy: repaidBy,
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
    String? pairId,
    bool clearPairId = false,
    List<String>? tags,
    List<SplitShare>? people,
    String? repaidBy,
    bool clearRepaidBy = false,
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
    pairId: clearPairId ? null : (pairId ?? this.pairId),
    tags: tags == null ? this.tags : normalizeTags(tags),
    people: people == null ? this.people : List.unmodifiable(people),
    repaidBy: clearRepaidBy ? null : (repaidBy ?? this.repaidBy),
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
    if (pairId != null) 'pairId': pairId,
    if (tags.isNotEmpty) 'tags': tags,
    if (people.isNotEmpty) 'people': [for (final p in people) p.toJson()],
    if (repaidBy != null) 'repaidBy': repaidBy,
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
    pairId: json['pairId'] as String?,
    // Tolerant: a hand-edited or foreign backup may hold anything here.
    tags: switch (json['tags']) {
      final List<dynamic> list => normalizeTags(list.whereType<String>()),
      _ => const [],
    },
    people: switch (json['people']) {
      final List<dynamic> list => List.unmodifiable([
        for (final e in list) ?SplitShare.tryFromJson(e),
      ]),
      _ => const [],
    },
    repaidBy: json['repaidBy'] is String ? json['repaidBy'] as String : null,
  );
}

/// One person's part of a group split ([Tx.people]).
class SplitShare {
  final String name;
  final double amount;

  /// Marked settled by hand (paid outside the app, or let go): left out of
  /// the person's balance.
  final bool settled;

  /// On a settled share: how much of it their repayments had already paid
  /// when it was settled. Those repayments stay spent on it, so settling a
  /// part-paid bill never frees them to pay the next one.
  final double paid;

  const SplitShare({
    required this.name,
    required this.amount,
    this.settled = false,
    this.paid = 0,
  });

  SplitShare copyWith({
    String? name,
    double? amount,
    bool? settled,
    double? paid,
  }) => SplitShare(
    name: name ?? this.name,
    amount: amount ?? this.amount,
    settled: settled ?? this.settled,
    paid: paid ?? this.paid,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'amount': amount,
    if (settled) 'settled': true,
    if (settled && paid > 0) 'paid': paid,
  };

  /// Null for anything that isn't a name with a number. Range and duplicate
  /// rules are the provider's sanitizer's job.
  static SplitShare? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final amount = json['amount'];
    if (name is! String || amount is! num) return null;
    final paid = json['paid'];
    return SplitShare(
      name: name,
      amount: amount.toDouble(),
      settled: json['settled'] == true,
      paid: paid is num ? paid.toDouble() : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SplitShare &&
      other.name == name &&
      other.amount == amount &&
      other.settled == settled &&
      other.paid == paid;

  @override
  int get hashCode => Object.hash(name, amount, settled, paid);
}

/// Most people one split can name.
const int kMaxSplitPeople = 10;

/// Longest person name, in characters.
const int kMaxPersonNameLength = 30;

/// A person's name as stored: whitespace collapsed, `|` and `:` removed (the
/// CSV cell's separators), capped at [kMaxPersonNameLength] characters.
String normalizePersonName(String raw) {
  var n = raw
      .replaceAll(RegExp(r'[|:]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (n.characters.length > kMaxPersonNameLength) {
    n = n.characters.take(kMaxPersonNameLength).toString().trim();
  }
  return n;
}

/// How people are matched: "arun" and "Arun" are one person.
String personKey(String name) => name.toLowerCase();

/// Most tags one transaction can carry.
const int kMaxTagsPerTx = 5;

/// Longest tag, in characters.
const int kMaxTagLength = 30;

/// Tags as stored: whitespace collapsed, `|` removed (the CSV separator),
/// blanks dropped, each capped at [kMaxTagLength], duplicates dropped
/// ignoring case (the first spelling wins), at most [kMaxTagsPerTx].
List<String> normalizeTags(Iterable<String> raw) {
  final out = <String>[];
  final seen = <String>{};
  for (final r in raw) {
    var t = r.replaceAll('|', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) continue;
    // By grapheme, as the text field counts: cutting UTF-16 units could
    // split an emoji and store a lone surrogate.
    if (t.characters.length > kMaxTagLength) {
      t = t.characters.take(kMaxTagLength).toString().trim();
    }
    if (!seen.add(tagKey(t))) continue;
    out.add(t);
    if (out.length == kMaxTagsPerTx) break;
  }
  return List.unmodifiable(out);
}

/// How tags are matched: "goa trip" and "Goa Trip" are one tag.
String tagKey(String tag) => tag.toLowerCase();

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

/// Money in from a friend paying back their part of a split ([Tx.repaidBy]).
/// A transfer, never income: the fronted part it returns was never spend.
const String kRepaidToMeCategoryId = 'repaid_to_me';

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
  kRepaidToMeCategoryId,
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

/// Order- and case-insensitive form of a rule's OR-conditions, so two rules
/// typed as "amma | family" and "Family | AMMA" count as the same pattern.
String normalizedRulePattern(String pattern) {
  final parts = [
    for (final p in pattern.split('|'))
      if (p.trim().isNotEmpty) p.trim().toLowerCase(),
  ]..sort();
  return parts.join(' | ');
}

/// The rule that classifies the SAME pattern for the opposite money
/// direction, or null.
///
/// The matcher only applies a rule whose category direction agrees with the
/// parsed direction of the alert, so "amma → Family support (expense)" and
/// "amma → From family (income)" together classify both ways. The Rules UI
/// creates and shows such twins as one "rule pair"; nothing is stored, the
/// pair is recognised from the two rows. Spam rules have no direction and
/// never pair.
ClassifierRule? directionSiblingOf(
  ClassifierRule rule,
  List<ClassifierRule> rules,
) {
  if (rule.isSpamRule) return null;
  final key = normalizedRulePattern(rule.pattern);
  if (key.isEmpty) return null;
  final type = categoryById(rule.categoryId).type;
  for (final r in rules) {
    if (r.id == rule.id || r.isSpamRule) continue;
    if (categoryById(r.categoryId).type == type) continue;
    if (normalizedRulePattern(r.pattern) == key) return r;
  }
  return null;
}
