import 'package:flutter/material.dart';

import 'transaction.dart';

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

  /// The [kCategoryIconChoices] key the user picked for this budget, or
  /// null for Automatic ([budgetIcon]'s rule).
  final String? iconKey;

  const SpendBudget({
    required this.id,
    required this.name,
    required this.limit,
    required this.mode,
    required this.categoryIds,
    this.iconKey,
  });

  /// The picked icon, or null for Automatic.
  IconData? get icon => kCategoryIconChoices[iconKey];

  /// [clearIconKey] true goes back to Automatic.
  SpendBudget copyWith({
    String? name,
    double? limit,
    BudgetMode? mode,
    Set<String>? categoryIds,
    String? iconKey,
    bool clearIconKey = false,
  }) => SpendBudget(
    id: id,
    name: name ?? this.name,
    limit: limit ?? this.limit,
    mode: mode ?? this.mode,
    categoryIds: categoryIds ?? this.categoryIds,
    iconKey: clearIconKey ? null : iconKey ?? this.iconKey,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'limit': limit,
    'mode': mode.name,
    'categoryIds': categoryIds.toList()..sort(),
    // Left out on Automatic, so older builds read the payload they always
    // did.
    if (iconKey != null) 'icon': iconKey,
  };

  factory SpendBudget.fromJson(Map<String, dynamic> json) => SpendBudget(
    id: json['id'] as String,
    name: json['name'] as String,
    limit: (json['limit'] as num).toDouble(),
    mode: BudgetMode.values.byName(json['mode'] as String? ?? 'exclude'),
    categoryIds: {...(json['categoryIds'] as List? ?? const []).cast<String>()},
    // A key outside the choices (an older or newer build's) reads as
    // Automatic, so nothing asks for an icon that does not exist.
    iconKey: switch (json['icon']) {
      final String key when kCategoryIconChoices.containsKey(key) => key,
      _ => null,
    },
  );
}

/// [b]'s icon: the one picked for it, else its one category's icon for a
/// one-category "Only these" budget, else a generic one.
IconData budgetIcon(SpendBudget b) =>
    b.icon ??
    (b.mode == BudgetMode.include && b.categoryIds.length == 1
        ? categoryById(b.categoryIds.single, fallbackType: TxType.expense).icon
        : Icons.category_outlined);

/// [budgetIcon] as a [kCategoryIconChoices] key, for the home-screen
/// widgets: the picked key, else the one category's key, else [fallback].
/// A dangling category id falls back to Other as in [budgetIcon], so the
/// app and the widget agree.
String budgetIconKey(SpendBudget b, {required String fallback}) =>
    b.iconKey ??
    (b.mode == BudgetMode.include && b.categoryIds.length == 1
        ? categoryById(
            b.categoryIds.single,
            fallbackType: TxType.expense,
          ).iconKey
        : fallback);
