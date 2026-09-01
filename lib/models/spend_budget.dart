/// How a [SpendBudget] decides which expense rows count toward it.
enum BudgetMode {
  /// Only the picked categories count.
  include,

  /// All (non-transfer) spending counts except the picked categories.
  exclude,
}

/// A user-defined monthly spend limit alongside the overall monthly cap —
/// e.g. "Personal spending" that excludes family categories.
///
/// [categoryIds] holds category ids, not group ids, so the budget stays
/// deterministic when group memberships change.
class SpendBudget {
  final String id;
  final String name;
  final double limit;
  final BudgetMode mode;
  final Set<String> categoryIds;

  const SpendBudget({
    required this.id,
    required this.name,
    required this.limit,
    required this.mode,
    required this.categoryIds,
  });

  SpendBudget copyWith({
    String? name,
    double? limit,
    BudgetMode? mode,
    Set<String>? categoryIds,
  }) => SpendBudget(
    id: id,
    name: name ?? this.name,
    limit: limit ?? this.limit,
    mode: mode ?? this.mode,
    categoryIds: categoryIds ?? this.categoryIds,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'limit': limit,
    'mode': mode.name,
    'categoryIds': categoryIds.toList()..sort(),
  };

  factory SpendBudget.fromJson(Map<String, dynamic> json) => SpendBudget(
    id: json['id'] as String,
    name: json['name'] as String,
    limit: (json['limit'] as num).toDouble(),
    mode: BudgetMode.values.byName(json['mode'] as String? ?? 'exclude'),
    categoryIds: {...(json['categoryIds'] as List? ?? const []).cast<String>()},
  );
}
