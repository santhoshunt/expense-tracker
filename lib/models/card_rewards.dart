/// What a credit card pays back: cash, or points the user may value in ₹.
enum RewardUnit { cashback, points }

/// The pick (`Tx.rewardGroup`) that names Everything else, the base rate.
const String kEverythingElseRewardGroupId = 'base';

/// A merchant name or word as reward groups compare them: lowercase, each
/// run of characters outside a-z and 0-9 one space, trimmed.
String rewardWordText(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// A fresh id for a new reward group.
String newRewardGroupId() => 'g${DateTime.now().microsecondsSinceEpoch}';

/// A rate for payments in some categories or to some merchants, with an
/// optional minimum per payment and cap per cycle ("10% on Food, Dining,
/// Groceries and Shopping, up to ₹1,000 a cycle").
class RewardGroup {
  /// Names the group in a payment's pick, so a rename keeps every pick.
  final String id;

  /// What the user calls it ("Dining"); empty on a group saved before
  /// names existed.
  final String name;
  final Set<String> categoryIds;

  /// Merchant names that earn here, as [rewardWordText] writes them.
  final Set<String> merchantWords;

  /// Percent for a cashback card; points per ₹100 for a points card.
  final double rate;

  /// Most a cycle can earn in this group, in ₹ (cashback) or points. Null
  /// means no cap.
  final double? cap;

  /// The least a payment must be, in ₹, to earn here. Null means none.
  final double? minimum;

  const RewardGroup({
    this.id = '',
    this.name = '',
    required this.categoryIds,
    this.merchantWords = const {},
    required this.rate,
    this.cap,
    this.minimum,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    if (name.isNotEmpty) 'name': name,
    'categoryIds': categoryIds.toList(),
    if (merchantWords.isNotEmpty) 'merchantWords': merchantWords.toList(),
    'rate': rate,
    if (cap != null) 'cap': cap,
    if (minimum != null) 'minimum': minimum,
  };

  /// Null for a malformed entry, so one bad group never drops the rest. A
  /// group with no id (saved before ids existed) gets
  /// `<idPrefix>g<index>`, its place in the stored list, the same on every
  /// read.
  static RewardGroup? tryFromJson(
    Object? json, {
    int index = 0,
    String idPrefix = '',
  }) {
    if (json is! Map) return null;
    final rate = json['rate'];
    if (rate is! num || !rate.isFinite || rate < 0) return null;
    final id = json['id'];
    final name = json['name'];
    final ids = json['categoryIds'];
    final words = json['merchantWords'];
    final cap = json['cap'];
    final minimum = json['minimum'];
    return RewardGroup(
      id: id is String && id.isNotEmpty ? id : '${idPrefix}g$index',
      name: name is String ? name.trim().replaceAll(RegExp(r'\s+'), ' ') : '',
      categoryIds: {
        if (ids is List)
          for (final id in ids)
            if (id is String) id,
      },
      merchantWords: {
        if (words is List)
          for (final w in words)
            if (w is String && rewardWordText(w).isNotEmpty) rewardWordText(w),
      },
      rate: rate.toDouble(),
      cap: cap is num && cap.isFinite && cap > 0 ? cap.toDouble() : null,
      minimum: minimum is num && minimum.isFinite && minimum > 0
          ? minimum.toDouble()
          : null,
    );
  }
}

/// A credit card's reward rules ([Account.rewards]).
class CardRewards {
  final RewardUnit unit;

  /// Checked in order: a merchant name, then a category, picks the first
  /// group that holds it.
  final List<RewardGroup> groups;

  /// The rate for every category no group names ("Everything else"), in
  /// the same unit as the groups.
  final double baseRate;

  /// Points cards only: ₹ per point, so the estimate can show its value.
  final double? pointValue;

  const CardRewards({
    this.unit = RewardUnit.cashback,
    this.groups = const [],
    this.baseRate = 0,
    this.pointValue,
  });

  /// The group [categoryId] earns in, or null for the base rate.
  RewardGroup? groupFor(String categoryId) {
    for (final g in groups) {
      if (g.categoryIds.contains(categoryId)) return g;
    }
    return null;
  }

  /// The group with [id], or null for an empty id or none.
  RewardGroup? groupById(String id) {
    if (id.isEmpty) return null;
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// [g]'s rate, or the base rate for Everything else (null).
  double rateOf(RewardGroup? g) => g?.rate ?? baseRate;

  /// Whether [amount] reaches [g]'s minimum; always true with none.
  bool meetsMinimum(RewardGroup? g, double amount) {
    final min = g?.minimum;
    return min == null || amount >= min - 1e-6;
  }

  /// What a payment of [amount] earns in [g] (null: Everything else) before
  /// any cap: nothing under the group's minimum.
  double earnOn(RewardGroup? g, double amount) =>
      meetsMinimum(g, amount) ? amount * rateOf(g) / 100 : 0;

  Map<String, dynamic> toJson() => {
    'unit': unit.name,
    'groups': [for (final g in groups) g.toJson()],
    'baseRate': baseRate,
    if (pointValue != null) 'pointValue': pointValue,
  };

  /// Tolerant of a hand-edited or foreign backup: anything unreadable
  /// falls back to its default.
  /// [idPrefix] goes before a legacy group's id ([RewardGroup.tryFromJson]),
  /// so it names the card.
  static CardRewards? tryFromJson(Object? json, {String idPrefix = ''}) {
    if (json is! Map) return null;
    final base = json['baseRate'];
    final value = json['pointValue'];
    final groups = json['groups'];
    return CardRewards(
      unit: RewardUnit.values.asNameMap()[json['unit']] ?? RewardUnit.cashback,
      groups: List.unmodifiable([
        if (groups is List)
          for (final (i, g) in groups.indexed)
            ?RewardGroup.tryFromJson(g, index: i, idPrefix: idPrefix),
      ]),
      baseRate: base is num && base.isFinite && base >= 0 ? base.toDouble() : 0,
      pointValue: value is num && value.isFinite && value > 0
          ? value.toDouble()
          : null,
    );
  }
}
