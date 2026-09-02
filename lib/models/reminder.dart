/// A user-defined monthly bill the SMS detector cannot see (cash, a new
/// payee, "send money home"). Shown in the dashboard's Upcoming card and
/// notified by UpcomingMonitor alongside detected recurring payments.
class Reminder {
  final String id;
  final String name;

  /// 1..31; clamps to the month's last day when it is shorter.
  final int dayOfMonth;

  /// Optional expected amount, for the Upcoming row and the notification.
  final double? expectedAmount;

  /// Expense-typed category (transfer categories such as "To savings" are
  /// fine — a reminder to move money is still money going out).
  final String categoryId;

  /// `yyyy-MM` of the DUE DATE last marked paid; the reminder then skips to
  /// the following month. Null when never marked.
  final String? lastPaidMonth;

  const Reminder({
    required this.id,
    required this.name,
    required this.dayOfMonth,
    required this.categoryId,
    this.expectedAmount,
    this.lastPaidMonth,
  });

  Reminder copyWith({
    String? name,
    int? dayOfMonth,
    double? expectedAmount,
    bool clearExpectedAmount = false,
    String? categoryId,
    String? lastPaidMonth,
    bool clearLastPaidMonth = false,
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
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'dayOfMonth': dayOfMonth,
    'categoryId': categoryId,
    if (expectedAmount != null) 'expectedAmount': expectedAmount,
    if (lastPaidMonth != null) 'lastPaidMonth': lastPaidMonth,
  };

  /// Tolerant: a hand-edited or older file must not break loading. The day
  /// clamps into 1..31 and a non-finite or non-positive amount is dropped.
  factory Reminder.fromJson(Map<String, dynamic> json) {
    final rawAmount = (json['expectedAmount'] as num?)?.toDouble();
    final amount = rawAmount != null && rawAmount.isFinite && rawAmount > 0
        ? rawAmount
        : null;
    return Reminder(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      dayOfMonth: ((json['dayOfMonth'] as num?)?.toInt() ?? 1).clamp(1, 31),
      categoryId: json['categoryId'] as String? ?? 'other_expense',
      expectedAmount: amount,
      lastPaidMonth: json['lastPaidMonth'] as String?,
    );
  }
}
