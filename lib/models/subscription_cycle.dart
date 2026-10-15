/// How often a subscription the user marked by hand repeats. The automatic
/// detector only finds monthly patterns; a mark also covers quarterly,
/// half-yearly and yearly plans.
enum SubscriptionCycle {
  monthly('Monthly', 1, 30),
  quarterly('Quarterly', 3, 91),
  halfYearly('Half-yearly', 6, 182),
  yearly('Yearly', 12, 365);

  final String label;

  /// Calendar months from one payment to the next.
  final int months;

  /// The same gap in days: the interval a marked plan reports. Costs come
  /// from [paymentsPerYear], not from this.
  final int approxDays;

  const SubscriptionCycle(this.label, this.months, this.approxDays);

  /// Payments in a year: 12, 4, 2 or 1.
  int get paymentsPerYear => 12 ~/ months;

  /// What a payment of [amount] costs over a year.
  double yearlyCost(double amount) => amount * paymentsPerYear;

  /// The payment after one made on [last]: the same day [months] later,
  /// or that month's last day when it is shorter (31 Jan monthly → 28 Feb).
  DateTime nextAfter(DateTime last) {
    final target = DateTime(last.year, last.month + months);
    final lastDay = DateTime(target.year, target.month + 1, 0).day;
    return DateTime(
      target.year,
      target.month,
      last.day > lastDay ? lastDay : last.day,
    );
  }
}
