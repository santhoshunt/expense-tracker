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
  savings('Savings');

  final String label;
  const AccountType(this.label);

  IconData get icon => switch (this) {
    bank => Icons.account_balance_outlined,
    creditCard => Icons.credit_card,
    savings => Icons.savings_outlined,
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

  /// User-defined kind of a savings/asset account ("RD", "Stocks", "Gold"…).
  /// Shown instead of the generic "Savings" label.
  final String? kind;

  /// Icon key into [kAssetIconChoices] for savings/asset accounts.
  final String? kindIcon;

  /// When the user closed the account (matured FD, emptied asset…). A closed
  /// account leaves the open lists, pickers and totals but keeps its identity
  /// and keys, so its transaction history still resolves — unlike delete,
  /// which orphans the transactions. Null = open.
  final DateTime? closedAt;

  Account({
    required this.id,
    required this.name,
    required this.type,
    required this.keys,
    this.creditLimit,
    this.manualBalance,
    this.manualBalanceAt,
    this.kind,
    this.kindIcon,
    this.closedAt,
  });

  bool get isCard => type == AccountType.creditCard;

  bool get isClosed => closedAt != null;

  /// Display label: the custom kind for savings/assets, else the type label.
  String get typeLabel =>
      (type == AccountType.savings && (kind?.isNotEmpty ?? false))
      ? kind!
      : type.label;

  /// Display icon: the chosen asset icon for savings/assets, else per type.
  IconData get icon =>
      (type == AccountType.savings ? kAssetIconChoices[kindIcon] : null) ??
      type.icon;

  Account copyWith({
    String? name,
    AccountType? type,
    Set<String>? keys,
    double? creditLimit,
    bool clearCreditLimit = false,
    double? manualBalance,
    DateTime? manualBalanceAt,
    bool clearManualBalance = false,
    String? kind,
    String? kindIcon,
    bool clearKind = false,
    DateTime? closedAt,
    bool clearClosedAt = false,
  }) => Account(
    id: id,
    name: name ?? this.name,
    type: type ?? this.type,
    keys: keys ?? this.keys,
    creditLimit: clearCreditLimit ? null : (creditLimit ?? this.creditLimit),
    manualBalance: clearManualBalance
        ? null
        : (manualBalance ?? this.manualBalance),
    manualBalanceAt: clearManualBalance
        ? null
        : (manualBalanceAt ?? this.manualBalanceAt),
    kind: clearKind ? null : (kind ?? this.kind),
    kindIcon: clearKind ? null : (kindIcon ?? this.kindIcon),
    closedAt: clearClosedAt ? null : (closedAt ?? this.closedAt),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'keys': keys.toList(),
    if (creditLimit != null) 'creditLimit': creditLimit,
    if (manualBalance != null) 'manualBalance': manualBalance,
    if (manualBalanceAt != null)
      'manualBalanceAt': manualBalanceAt!.toIso8601String(),
    if (kind != null) 'kind': kind,
    if (kindIcon != null) 'kindIcon': kindIcon,
    if (closedAt != null) 'closedAt': closedAt!.toIso8601String(),
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
      creditLimit: (json['creditLimit'] as num?)?.toDouble(),
      manualBalance: manualBalance,
      manualBalanceAt: manualBalanceAt,
      kind: json['kind'] as String?,
      kindIcon: json['kindIcon'] as String?,
      closedAt: json['closedAt'] is String
          ? DateTime.parse(json['closedAt'] as String)
          : null,
    );
  }

  /// Default display name for an auto-detected account, e.g. "HDFC ••1234".
  static String defaultName(String bankCode, String last4) =>
      '$bankCode ••$last4';
}
