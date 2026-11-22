import 'dart:convert';

import '../utils/dates.dart';

/// A set of Transactions filters saved under a name from the filters
/// sheet: what the sheet sets and the type tab. Search and sort are not in
/// it.
class SavedFilter {
  /// `flt_<microseconds>_<seq>`, minted by the provider.
  final String id;
  final String name;

  /// The type tab by name: all, income, expense or transfers.
  final String tab;
  final List<String> categories;
  final List<String> groups;
  final List<String> budgets;

  /// Tags by tagKey, as the filter holds them.
  final List<String> tags;
  final String? accountId;

  /// The month is whatever month it is when the filter is applied.
  final bool thisMonth;

  /// A fixed month; null when [thisMonth] or with a range.
  final DateTime? month;

  /// An inclusive day range, both ends set or neither. Exclusive with
  /// [month] and [thisMonth].
  final DateTime? rangeStart;
  final DateTime? rangeEnd;

  /// The range matches the date each row counts in, under [rangeLabel]
  /// (a dashboard year).
  final bool rangeCounted;
  final String? rangeLabel;
  final double? min;
  final double? max;

  const SavedFilter({
    required this.id,
    required this.name,
    this.tab = 'all',
    this.categories = const [],
    this.groups = const [],
    this.budgets = const [],
    this.tags = const [],
    this.accountId,
    this.thisMonth = false,
    this.month,
    this.rangeStart,
    this.rangeEnd,
    this.rangeCounted = false,
    this.rangeLabel,
    this.min,
    this.max,
  });

  SavedFilter copyWith({
    String? name,
    List<String>? categories,
    List<String>? tags,
    String? accountId,
  }) => SavedFilter(
    id: id,
    name: name ?? this.name,
    tab: tab,
    categories: categories ?? this.categories,
    groups: groups,
    budgets: budgets,
    tags: tags ?? this.tags,
    accountId: accountId ?? this.accountId,
    thisMonth: thisMonth,
    month: month,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    rangeCounted: rangeCounted,
    rangeLabel: rangeLabel,
    min: min,
    max: max,
  );

  /// Whether [other] stores the same filter: every part but the id and
  /// the name, lists in the order they are held.
  bool sameFilterAs(SavedFilter other) =>
      jsonEncode(_parts(this)) == jsonEncode(_parts(other));

  static Map<String, dynamic> _parts(SavedFilter f) => f.toJson()
    ..remove('id')
    ..remove('name');

  /// Unset parts are left out, so a filter stores only what it narrows.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'tab': tab,
    if (categories.isNotEmpty) 'categories': categories,
    if (groups.isNotEmpty) 'groups': groups,
    if (budgets.isNotEmpty) 'budgets': budgets,
    if (tags.isNotEmpty) 'tags': tags,
    if (accountId != null) 'accountId': accountId,
    if (thisMonth) 'thisMonth': true,
    if (month != null) 'month': monthKey(month!),
    if (rangeStart != null && rangeEnd != null) ...{
      'from': _ymd(rangeStart!),
      'to': _ymd(rangeEnd!),
      if (rangeCounted) 'rangeCounted': true,
      if (rangeLabel != null) 'rangeLabel': rangeLabel,
    },
    if (min != null) 'min': min,
    if (max != null) 'max': max,
  };

  /// Tolerant: null for an entry with no id or name; a missing or wrongly
  /// typed part reads as unset. A forward range wins over a month, and a
  /// fixed month over [thisMonth].
  static SavedFilter? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.trim().isEmpty) return null;
    List<String> strings(Object? v) => [
      if (v is List)
        for (final s in v)
          if (s is String && s.isNotEmpty) s,
    ];
    DateTime? day(Object? v) {
      final d = v is String ? DateTime.tryParse(v) : null;
      return d == null ? null : DateTime(d.year, d.month, d.day);
    }

    double? amount(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    var start = day(raw['from']);
    var end = day(raw['to']);
    if (start == null || end == null || end.isBefore(start)) {
      start = null;
      end = null;
    }
    final ranged = start != null;
    final monthRaw = raw['month'];
    final month = ranged || monthRaw is! String ? null : day('$monthRaw-01');
    final label = raw['rangeLabel'];
    final accountId = raw['accountId'];
    final tab = raw['tab'];
    return SavedFilter(
      id: id,
      name: name.trim(),
      tab: tab is String && tab.isNotEmpty ? tab : 'all',
      categories: strings(raw['categories']),
      groups: strings(raw['groups']),
      budgets: strings(raw['budgets']),
      tags: strings(raw['tags']),
      accountId: accountId is String && accountId.isNotEmpty ? accountId : null,
      thisMonth: !ranged && month == null && raw['thisMonth'] == true,
      month: month,
      rangeStart: start,
      rangeEnd: end,
      rangeCounted: ranged && raw['rangeCounted'] == true,
      rangeLabel: ranged && label is String && label.isNotEmpty ? label : null,
      min: amount(raw['min']),
      max: amount(raw['max']),
    );
  }
}

/// `yyyy-MM-dd` for a saved range's stored days.
String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
