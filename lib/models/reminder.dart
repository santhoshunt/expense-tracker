import 'subscription_cycle.dart';

/// A user-defined bill the SMS detector cannot see (cash, a new payee,
/// "send money home"). Shown in the dashboard's Upcoming card and notified
/// by UpcomingMonitor alongside detected recurring payments. With [autoAdd]
/// it records the expense itself on each due day.
class Reminder {
  final String id;
  final String name;

  /// 1..31; clamps to the month's last day when it is shorter.
  final int dayOfMonth;

  /// Optional expected amount, for the Upcoming row and the notification.
  /// Required while [autoAdd] is on, and what an SMS must match to mark the
  /// reminder paid.
  final double? expectedAmount;

  /// Expense-typed category (transfer categories such as "To savings" are
  /// fine — a reminder to move money is still money going out).
  final String categoryId;

  /// `yyyy-MM` of the DUE DATE last marked paid; the reminder then skips to
  /// the following period. Null when never marked.
  final String? lastPaidMonth;

  /// How often it repeats.
  final SubscriptionCycle cycle;

  /// A month (1..12) an occurrence falls in: with a quarterly [cycle] the
  /// months three apart from it, with a yearly one this month only.
  /// Ignored for monthly.
  final int anchorMonth;

  /// Adds the expense on each due day instead of waiting to be marked paid.
  final bool autoAdd;

  /// The account an added expense is booked to; null for none.
  final String? accountId;

  /// `yyyy-MM-dd` from which [autoAdd] may add: the day it was switched
  /// on, so turning it on never back-fills earlier months.
  final String? autoSince;

  /// `yyyy-MM-dd` the reminder was made; null for one made before 1.32.
  /// Its occurrences in earlier months never count as due or overdue.
  final String? createdOn;

  const Reminder({
    required this.id,
    required this.name,
    required this.dayOfMonth,
    required this.categoryId,
    this.expectedAmount,
    this.lastPaidMonth,
    this.cycle = SubscriptionCycle.monthly,
    this.anchorMonth = 1,
    this.autoAdd = false,
    this.accountId,
    this.autoSince,
    this.createdOn,
  });

  Reminder copyWith({
    String? name,
    int? dayOfMonth,
    double? expectedAmount,
    bool clearExpectedAmount = false,
    String? categoryId,
    String? lastPaidMonth,
    bool clearLastPaidMonth = false,
    SubscriptionCycle? cycle,
    int? anchorMonth,
    bool? autoAdd,
    String? accountId,
    bool clearAccountId = false,
    String? autoSince,
    String? createdOn,
  }) => Reminder(
    id: id,
    name: name ?? this.name,
    dayOfMonth: dayOfMonth ?? this.dayOfMonth,
    expectedAmount: clearExpectedAmount
        ? null
        : (expectedAmount ?? this.expectedAmount),
    categoryId: categoryId ?? this.categoryId,
    lastPaidMonth: clearLastPaidMonth
        ? null
        : (lastPaidMonth ?? this.lastPaidMonth),
    cycle: cycle ?? this.cycle,
    anchorMonth: anchorMonth ?? this.anchorMonth,
    autoAdd: autoAdd ?? this.autoAdd,
    accountId: clearAccountId ? null : (accountId ?? this.accountId),
    autoSince: autoSince ?? this.autoSince,
    createdOn: createdOn ?? this.createdOn,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'dayOfMonth': dayOfMonth,
    'categoryId': categoryId,
    if (expectedAmount != null) 'expectedAmount': expectedAmount,
    if (lastPaidMonth != null) 'lastPaidMonth': lastPaidMonth,
    if (cycle != SubscriptionCycle.monthly) 'cycle': cycle.name,
    if (cycle != SubscriptionCycle.monthly) 'anchorMonth': anchorMonth,
    if (autoAdd) 'autoAdd': true,
    if (accountId != null) 'accountId': accountId,
    if (autoSince != null) 'autoSince': autoSince,
    if (createdOn != null) 'createdOn': createdOn,
  };

  /// Tolerant: a hand-edited or older file must not break loading. The day
  /// clamps into 1..31, a non-finite or non-positive amount is dropped, an
  /// unknown cycle reads as monthly and the anchor clamps into 1..12.
  factory Reminder.fromJson(Map<String, dynamic> json) {
    final rawAmount = (json['expectedAmount'] as num?)?.toDouble();
    final amount = rawAmount != null && rawAmount.isFinite && rawAmount > 0
        ? rawAmount
        : null;
    final cycleName = json['cycle'];
    final cycle = SubscriptionCycle.values.firstWhere(
      (c) => c.name == cycleName,
      orElse: () => SubscriptionCycle.monthly,
    );
    return Reminder(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      dayOfMonth: ((json['dayOfMonth'] as num?)?.toInt() ?? 1).clamp(1, 31),
      categoryId: json['categoryId'] as String? ?? 'other_expense',
      expectedAmount: amount,
      lastPaidMonth: json['lastPaidMonth'] as String?,
      cycle: cycle,
      anchorMonth: ((json['anchorMonth'] as num?)?.toInt() ?? 1).clamp(1, 12),
      autoAdd: json['autoAdd'] == true,
      accountId: json['accountId'] as String?,
      autoSince: json['autoSince'] as String?,
      createdOn: json['createdOn'] as String?,
    );
  }
}
