import 'package:flutter/material.dart';

import '../utils/dates.dart';
import 'transaction.dart';

/// Days a dated tag budget stays listed as Ended after its last day.
const int kTripEndedDays = 7;

/// Where a dated tag budget stands on a given day: before its first day,
/// inside its dates, within [kTripEndedDays] after its last day, or past
/// that.
enum TripStage { upcoming, running, ended, gone }

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

  /// The tag whose rows count, in any category, as picked (compared through
  /// [tagKey]). Only with [BudgetMode.include] and no [categoryIds].
  final String? tag;

  /// The days a tag budget counts, both ends included, at midnight: one
  /// limit for the whole range instead of a monthly one. Only with a [tag].
  final DateTimeRange? range;

  const SpendBudget({
    required this.id,
    required this.name,
    required this.limit,
    required this.mode,
    required this.categoryIds,
    this.iconKey,
    this.tag,
    this.range,
  });

  /// The picked icon, or null for Automatic.
  IconData? get icon => kCategoryIconChoices[iconKey];

  /// [clearIconKey] true goes back to Automatic; [clearTag] and
  /// [clearRange] drop the tag and the dates.
  SpendBudget copyWith({
    String? name,
    double? limit,
    BudgetMode? mode,
    Set<String>? categoryIds,
    String? iconKey,
    bool clearIconKey = false,
    String? tag,
    bool clearTag = false,
    DateTimeRange? range,
    bool clearRange = false,
  }) => SpendBudget(
    id: id,
    name: name ?? this.name,
    limit: limit ?? this.limit,
    mode: mode ?? this.mode,
    categoryIds: categoryIds ?? this.categoryIds,
    iconKey: clearIconKey ? null : iconKey ?? this.iconKey,
    tag: clearTag ? null : tag ?? this.tag,
    range: clearRange ? null : range ?? this.range,
  );

  /// Whether a row dated [day] falls inside [range]; always true without
  /// one.
  bool coversDay(DateTime day) {
    final r = range;
    if (r == null) return true;
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(r.start) && !d.isAfter(r.end);
  }

  /// Whether [range] shares at least one day with [month]'s month; always
  /// true without one.
  bool touchesMonth(DateTime month) {
    final r = range;
    if (r == null) return true;
    final first = DateTime(month.year, month.month);
    final last = DateTime(month.year, month.month + 1, 0);
    return !r.end.isBefore(first) && !r.start.isAfter(last);
  }

  /// [range]'s stage on [now]'s day, or null for a monthly budget.
  TripStage? stageOn(DateTime now) {
    final r = range;
    if (r == null) return null;
    final today = DateTime(now.year, now.month, now.day);
    if (today.isBefore(r.start)) return TripStage.upcoming;
    if (!today.isAfter(r.end)) return TripStage.running;
    return daysCovered(r.end, today) <= kTripEndedDays + 1
        ? TripStage.ended
        : TripStage.gone;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'limit': limit,
    'mode': mode.name,
    'categoryIds': categoryIds.toList()..sort(),
    // Left out on Automatic, so older builds read the payload they always
    // did.
    if (iconKey != null) 'icon': iconKey,
    // Left out when unset, so a category budget's payload is unchanged.
    if (tag != null) 'tag': tag,
    if (range != null) 'from': _ymd(range!.start),
    if (range != null) 'to': _ymd(range!.end),
  };

  factory SpendBudget.fromJson(Map<String, dynamic> json) {
    final tag = normalizeTags([
      if (json['tag'] case final String t) t,
    ]).firstOrNull;
    // Dates count only with a tag, and only as a forward range.
    DateTimeRange? range;
    final from = DateTime.tryParse(json['from'] as String? ?? '');
    final to = DateTime.tryParse(json['to'] as String? ?? '');
    if (tag != null && from != null && to != null) {
      final start = DateTime(from.year, from.month, from.day);
      final end = DateTime(to.year, to.month, to.day);
      if (!end.isBefore(start)) range = DateTimeRange(start: start, end: end);
    }
    return SpendBudget(
      id: json['id'] as String,
      name: json['name'] as String,
      limit: (json['limit'] as num).toDouble(),
      mode: BudgetMode.values.byName(json['mode'] as String? ?? 'exclude'),
      categoryIds: {
        ...(json['categoryIds'] as List? ?? const []).cast<String>(),
      },
      // A key outside the choices (an older or newer build's) reads as
      // Automatic, so nothing asks for an icon that does not exist.
      iconKey: switch (json['icon']) {
        final String key when kCategoryIconChoices.containsKey(key) => key,
        _ => null,
      },
      tag: tag,
      range: range,
    );
  }
}

/// `yyyy-MM-dd` for a budget's stored dates.
String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// [b]'s icon: the one picked for it, else a tag for a tag budget, else its
/// one category's icon for a one-category "Only these" budget, else a
/// generic one.
IconData budgetIcon(SpendBudget b) =>
    b.icon ??
    (b.tag != null
        ? Icons.sell
        : b.mode == BudgetMode.include && b.categoryIds.length == 1
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
