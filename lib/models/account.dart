import 'package:flutter/material.dart';

/// A bank account, credit card or savings instrument (RD/FD/PPF) the app
/// tracks money against.
///
/// Transactions reference an account indirectly, by an **account key** like
/// `"HDFC:1234"` (bank code + last-4). An [Account] owns a set of those keys,
/// so merging two accounts is just a union of keys — the transactions
/// themselves never need rewriting.
enum AccountType {
  bank('Bank'),
  creditCard('Credit card'),

  /// Any savings/asset instrument — RD, FD, stocks, mutual funds, gold,
  /// property, crypto… The user names the kind ([Account.kind]) and picks an
  /// icon; deposits/purchases are "To savings" transactions and the current
  /// market value is kept via "Set balance".
  savings('Savings'),

  /// Money or points that can only be spent inside one platform (Amazon
  /// Pay, Zomato Money, Swiggy coins). Out of net balance, and its rows
  /// count in spending only when the user turns that on per row
  /// (`Tx.walletCounted`).
  wallet('Wallet');

  final String label;
  const AccountType(this.label);

  IconData get icon => switch (this) {
    bank => Icons.account_balance_outlined,
    creditCard => Icons.credit_card,
    savings => Icons.savings_outlined,
    wallet => Icons.account_balance_wallet_outlined,
  };
}

/// Icon options for savings/asset kinds — a fixed const map so icons stay
/// tree-shakeable (dynamic IconData from a stored codePoint would not).
const Map<String, IconData> kAssetIconChoices = {
  'savings': Icons.savings_outlined,
  'deposit': Icons.lock_outline,
  'stocks': Icons.candlestick_chart_outlined,
  'mutual_fund': Icons.pie_chart_outline,
  'gold': Icons.diamond_outlined,
  'property': Icons.home_work_outlined,
  'crypto': Icons.currency_bitcoin,
  'cash': Icons.payments_outlined,
  'wallet': Icons.account_balance_wallet_outlined,
};

class Account {
  final String id;
  final String name;
  final AccountType type;

  /// Account-match keys (`"<bankCode>:<last4>"`) that resolve to this account.
  final Set<String> keys;

  /// Keys from [keys] the user typed in (Linked numbers, the add dialog)
  /// rather than ones an SMS made. An account holding only these is waiting
  /// for its first alert, not emptied.
  final Set<String> linkedByHand;

  /// Total credit limit, cards only. When set, outstanding is derived as
  /// `creditLimit - availableLimit`; when null the app falls back to the
  /// largest available-limit ever seen.
  final double? creditLimit;

  /// User-entered figure: bank balance for banks, outstanding for cards,
  /// current value for savings/assets. Competes with SMS-reported figures by
  /// recency — a bank alert newer than [manualBalanceAt] wins again.
  final double? manualBalance;

  /// When [manualBalance] was entered.
  final DateTime? manualBalanceAt;

  /// Day of month (1–31) the card statement is generated, cards only.
  /// Days past a month's end clamp to its last day. Null = not set.
  final int? statementDay;

  /// Day of month (1–31) the card payment is due, cards only. Drives the
  /// "bill due" line, the dashboard Upcoming card and the due reminder.
  /// Days past a month's end clamp to its last day. Null = not set.
  final int? dueDay;

  /// `yyyy-MM` ([monthKey]) of the natural due date the user marked paid,
  /// cards only — mirrors `Reminder.lastPaidMonth`. While it matches the
  /// current cycle's due month, the bill line shows "Paid · next bill …" and
  /// the due notification stays silent; a stale value simply never matches
  /// again, so it self-expires with no cleanup.
  final String? billPaidMonth;

  /// User-defined kind of a savings/asset account ("RD", "Stocks", "Gold"…).
  /// Shown instead of the generic "Savings" label.
  final String? kind;

  /// Icon key into [kAssetIconChoices] for savings/asset accounts.
  final String? kindIcon;

  /// Savings goal: target amount for a savings/asset account. Drives the
  /// progress bar and the projected-completion line. Null = no goal.
  final double? goalAmount;

  /// When the user closed the account (matured FD, emptied asset…). A closed
  /// account leaves the open lists, pickers and totals but keeps its identity
  /// and keys, so its transaction history still resolves — unlike delete,
  /// which orphans the transactions. Null = open.
  final DateTime? closedAt;

  /// Wallets only: the platform the money lives on ("Amazon Pay"). [name]
  /// then holds which login it belongs to ("me"), so one service can carry
  /// any number of wallets.
  final String? service;

  /// Wallets only: holds points rather than money. Amounts are still stored
  /// in ₹; [pointValue] converts for display and entry.
  final bool holdsPoints;

  /// Points wallets only: ₹ per point.
  final double? pointValue;

  Account({
    required this.id,
    required this.name,
    required this.type,
    required this.keys,
    this.linkedByHand = const {},
    this.creditLimit,
    this.manualBalance,
    this.manualBalanceAt,
    this.statementDay,
    this.dueDay,
    this.billPaidMonth,
    this.kind,
    this.kindIcon,
    this.goalAmount,
    this.closedAt,
    this.service,
    this.holdsPoints = false,
    this.pointValue,
  });

  bool get isCard => type == AccountType.creditCard;

  bool get isWallet => type == AccountType.wallet;

  bool get isClosed => closedAt != null;

  /// Display label: the custom kind for savings/assets, the points/money
  /// split for wallets, else the type label.
  String get typeLabel => switch (type) {
    AccountType.savings when kind?.isNotEmpty ?? false => kind!,
    AccountType.wallet => holdsPoints ? 'Points wallet' : 'Wallet',
    _ => type.label,
  };

  /// The name pickers and lists show: "Amazon Pay · me" for a wallet with a
  /// service, else [name].
  String get displayName {
    final s = service?.trim() ?? '';
    return isWallet && s.isNotEmpty ? '$s · $name' : name;
  }

  /// [rupees] as points on a points wallet with a value per point; null
  /// otherwise.
  double? pointsOf(double rupees) {
    final v = pointValue;
    return isWallet && holdsPoints && v != null && v > 0 ? rupees / v : null;
  }

  /// Display icon: the chosen asset icon for savings/assets, else per type.
  IconData get icon =>
      (type == AccountType.savings ? kAssetIconChoices[kindIcon] : null) ??
      type.icon;

  Account copyWith({
    String? name,
    AccountType? type,
    Set<String>? keys,
    Set<String>? linkedByHand,
    double? creditLimit,
    bool clearCreditLimit = false,
    double? manualBalance,
    DateTime? manualBalanceAt,
    bool clearManualBalance = false,
    int? statementDay,
    bool clearStatementDay = false,
    int? dueDay,
    bool clearDueDay = false,
    String? billPaidMonth,
    bool clearBillPaidMonth = false,
    String? kind,
    String? kindIcon,
    bool clearKind = false,
    double? goalAmount,
    bool clearGoalAmount = false,
    DateTime? closedAt,
    bool clearClosedAt = false,
    String? service,
    bool clearService = false,
    bool? holdsPoints,
    double? pointValue,
    bool clearPointValue = false,
  }) => Account(
    id: id,
    name: name ?? this.name,
    type: type ?? this.type,
    keys: keys ?? this.keys,
    linkedByHand: linkedByHand ?? this.linkedByHand,
    creditLimit: clearCreditLimit ? null : (creditLimit ?? this.creditLimit),
    manualBalance: clearManualBalance
        ? null
        : (manualBalance ?? this.manualBalance),
    manualBalanceAt: clearManualBalance
        ? null
        : (manualBalanceAt ?? this.manualBalanceAt),
    statementDay: clearStatementDay
        ? null
        : (statementDay ?? this.statementDay),
    dueDay: clearDueDay ? null : (dueDay ?? this.dueDay),
    billPaidMonth: clearBillPaidMonth
        ? null
        : (billPaidMonth ?? this.billPaidMonth),
    kind: clearKind ? null : (kind ?? this.kind),
    kindIcon: clearKind ? null : (kindIcon ?? this.kindIcon),
    goalAmount: clearGoalAmount ? null : (goalAmount ?? this.goalAmount),
    closedAt: clearClosedAt ? null : (closedAt ?? this.closedAt),
    service: clearService ? null : (service ?? this.service),
    holdsPoints: holdsPoints ?? this.holdsPoints,
    pointValue: clearPointValue ? null : (pointValue ?? this.pointValue),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'keys': keys.toList(),
    if (linkedByHand.isNotEmpty) 'linkedByHand': linkedByHand.toList(),
    if (creditLimit != null) 'creditLimit': creditLimit,
    if (manualBalance != null) 'manualBalance': manualBalance,
    if (manualBalanceAt != null)
      'manualBalanceAt': manualBalanceAt!.toIso8601String(),
    if (statementDay != null) 'statementDay': statementDay,
    if (dueDay != null) 'dueDay': dueDay,
    if (billPaidMonth != null) 'billPaidMonth': billPaidMonth,
    if (kind != null) 'kind': kind,
    if (kindIcon != null) 'kindIcon': kindIcon,
    if (goalAmount != null) 'goalAmount': goalAmount,
    if (closedAt != null) 'closedAt': closedAt!.toIso8601String(),
    if (service != null) 'service': service,
    if (holdsPoints) 'holdsPoints': true,
    if (pointValue != null) 'pointValue': pointValue,
  };

  factory Account.fromJson(Map<String, dynamic> json) {
    final manualBalance = (json['manualBalance'] as num?)?.toDouble();
    final rawAt = json['manualBalanceAt'];
    // [manualBalance] and [manualBalanceAt] are written as a pair, but a
    // hand-edited or older backup can carry the figure without the timestamp.
    // Treat that as "entered at the beginning of time" so recency comparisons
    // stay total — a null here used to be dereferenced on every balance read.
    final manualBalanceAt = rawAt is String
        ? DateTime.parse(rawAt)
        : (manualBalance == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(0));
    return Account(
      id: json['id'] as String,
      name: json['name'] as String,
      type:
          AccountType.values.asNameMap()[json['type'] as String?] ??
          AccountType.bank,
      keys: {for (final k in (json['keys'] as List? ?? const [])) k as String},
      linkedByHand: {
        for (final k in (json['linkedByHand'] as List? ?? const []))
          k as String,
      },
      creditLimit: (json['creditLimit'] as num?)?.toDouble(),
      manualBalance: manualBalance,
      manualBalanceAt: manualBalanceAt,
      statementDay: (json['statementDay'] as num?)?.toInt(),
      dueDay: (json['dueDay'] as num?)?.toInt(),
      billPaidMonth: json['billPaidMonth'] as String?,
      kind: json['kind'] as String?,
      kindIcon: json['kindIcon'] as String?,
      goalAmount: (json['goalAmount'] as num?)?.toDouble(),
      closedAt: json['closedAt'] is String
          ? DateTime.parse(json['closedAt'] as String)
          : null,
      service: json['service'] is String ? json['service'] as String : null,
      holdsPoints: json['holdsPoints'] == true,
      pointValue: switch (json['pointValue']) {
        final num v when v.isFinite && v > 0 => v.toDouble(),
        _ => null,
      },
    );
  }

  /// Default display name for an auto-detected account, e.g. "HDFC ••1234".
  static String defaultName(String bankCode, String last4) =>
      '$bankCode ••$last4';
}
