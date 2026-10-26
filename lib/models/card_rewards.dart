/// What a credit card pays back: cash, or points the user may value in ₹.
enum RewardUnit { cashback, points }

/// Categories that earn one rate on a card, with an optional cap per
/// statement cycle ("10% on Food, Dining, Groceries and Shopping, up to
/// ₹1,000 a cycle").
class RewardGroup {
  final Set<String> categoryIds;

  /// Percent for a cashback card; points per ₹100 for a points card.
  final double rate;

  /// Most a cycle can earn in this group, in ₹ (cashback) or points. Null
  /// means no cap.
  final double? cap;

  const RewardGroup({required this.categoryIds, required this.rate, this.cap});

  Map<String, dynamic> toJson() => {
    'categoryIds': categoryIds.toList(),
    'rate': rate,
    if (cap != null) 'cap': cap,
  };

  /// Null for a malformed entry, so one bad group never drops the rest.
  static RewardGroup? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final rate = json['rate'];
    if (rate is! num || !rate.isFinite || rate < 0) return null;
    final ids = json['categoryIds'];
    final cap = json['cap'];
    return RewardGroup(
      categoryIds: {
        if (ids is List)
          for (final id in ids)
            if (id is String) id,
      },
      rate: rate.toDouble(),
      cap: cap is num && cap.isFinite && cap > 0 ? cap.toDouble() : null,
    );
  }
}

/// A credit card's reward rules ([Account.rewards]).
class CardRewards {
  final RewardUnit unit;

  /// Checked in order: a category in two groups earns the first one's rate.
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

  double rateFor(String categoryId) => groupFor(categoryId)?.rate ?? baseRate;

  /// What [amount] spent in [categoryId] earns before any cap.
  double earnOn(String categoryId, double amount) =>
      amount * rateFor(categoryId) / 100;

  Map<String, dynamic> toJson() => {
    'unit': unit.name,
    'groups': [for (final g in groups) g.toJson()],
    'baseRate': baseRate,
    if (pointValue != null) 'pointValue': pointValue,
  };

  /// Tolerant of a hand-edited or foreign backup: anything unreadable
  /// falls back to its default.
  static CardRewards? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final base = json['baseRate'];
    final value = json['pointValue'];
    final groups = json['groups'];
    return CardRewards(
      unit: RewardUnit.values.asNameMap()[json['unit']] ?? RewardUnit.cashback,
      groups: List.unmodifiable([
        if (groups is List)
          for (final g in groups) ?RewardGroup.tryFromJson(g),
      ]),
      baseRate: base is num && base.isFinite && base >= 0 ? base.toDouble() : 0,
      pointValue: value is num && value.isFinite && value > 0
          ? value.toDouble()
          : null,
    );
  }
}
