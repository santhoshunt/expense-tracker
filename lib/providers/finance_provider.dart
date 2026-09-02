import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/account.dart';
import '../models/category_group.dart';
import '../models/default_rules.dart';
import '../models/import_rule.dart';
import '../models/spend_budget.dart';
import '../models/transaction.dart';
import '../services/budget.dart';
import '../services/sms_parser.dart';
import '../utils/figma_palette.dart';

/// Income / expense / savings totals for one month, plus the per-category
/// expense breakdown and the transfer flows — all produced in a single pass.
class _MonthTotals {
  final double income;
  final double expense;

  /// Savings outflow ONLY while the savings category is a transfer — the
  /// balance formula subtracts this beside [expense], so it must be zero
  /// when the rows already count as expense.
  final double savings;

  /// Savings outflow regardless of transfer-ness — the DISPLAY figure. When
  /// the user un-transfers the savings category the money sits inside
  /// [expense], but the Saved card must keep showing it.
  final double savingsOutflow;
  final List<MapEntry<TxCategory, double>> byCategory;

  /// Money moved in/out via transfer categories — excluded from income and
  /// expense, but surfaced on their own for the transfers dashboard.
  final double transferIn;
  final double transferOut;
  final List<MapEntry<TxCategory, double>> transfersByCategory;

  /// Expense-DIRECTION transfer outflows only (row type, not category
  /// type) — what budget/group math may count. [transfersByCategory] stays
  /// gross both-directions for the Transfers display section.
  final List<MapEntry<TxCategory, double>> transferOutByCategory;

  const _MonthTotals({
    required this.income,
    required this.expense,
    required this.savings,
    required this.savingsOutflow,
    required this.byCategory,
    required this.transferIn,
    required this.transferOut,
    required this.transfersByCategory,
    required this.transferOutByCategory,
  });
}

/// Where an account's displayed balance currently comes from — surfaced on
/// the tile so "why is it showing this number" never has to be guessed.
enum BalanceSource { manual, alert, ledger }

/// Every figure the UI shows for one account, produced in a single pass over
/// that account's transactions instead of one pass per figure.
class _AccountFigures {
  final double balance;
  final BalanceSource balanceSource;
  final DateTime? balanceAsOf;
  final double? creditLimit;
  final bool limitIsEstimated;
  final double? outstanding;
  final double? available;
  final double spentThisMonth;
  final int txCount;

  const _AccountFigures({
    required this.balance,
    required this.balanceSource,
    required this.balanceAsOf,
    required this.creditLimit,
    required this.limitIsEstimated,
    required this.outstanding,
    required this.available,
    required this.spentThisMonth,
    required this.txCount,
  });
}

/// Memoised views over the provider's raw lists.
///
/// Thrown away wholesale whenever the provider notifies — see
/// [FinanceProvider.notifyListeners] — so there is no per-field invalidation to
/// forget. Every field is computed lazily on first read, which matters because
/// all three tabs stay mounted and re-read the same figures on every change.
class _Derived {
  /// Confirmed transactions paired with their insertion index in
  /// `_transactions`, ordered oldest → newest by `(date, insertionIndex)`.
  ///
  /// The insertion index is the tie-break for transactions sharing a
  /// timestamp. It is stable across every id scheme in play (generated,
  /// `csv_…` rows, ids restored from a backup), which a string compare on
  /// `Tx.id` is not — `…_9` sorts after `…_10`.
  List<(Tx, int)>? ordered;
  List<Tx>? confirmed;
  List<Tx>? pending;
  int? pendingCount;
  Map<String, List<Tx>>? byAccount;
  Map<String, Account>? accountById;

  /// Confirmed transactions bucketed by `year*12 + month`, in [ordered]
  /// order. Lets [FinanceProvider._monthTotals] walk one month's rows
  /// instead of the whole ledger — the dashboard, the six-month chart and
  /// the budget monitor together ask for ~8 months per change.
  Map<int, List<Tx>>? byMonth;
  final Map<int, _MonthTotals> months = {};
  final Map<String, _AccountFigures> accountFigures = {};
  _MonthTotals? allTime;

  /// Whole-ledger weekday averages — the heatmap card re-requests this on
  /// every rebuild (scroll re-entry recreates the element), and it was the
  /// one full-ledger fold without a slot here.
  List<double>? weekdayAvg;
}

class FinanceProvider extends ChangeNotifier {
  static const _txKey = 'transactions_v1';
  static const _rulesKey = 'classifier_rules_v1';
  static const _rulesSeededKey = 'builtin_rules_seeded_v1';
  static const _accountsKey = 'accounts_v1';
  static const _accountsMigratedKey = 'accounts_migrated_v1';
  static const _accountsMigratedV2Key = 'accounts_migrated_v2';
  static const _accountsMigratedV3Key = 'accounts_migrated_v3';
  static const _accountsMigratedV4Key = 'accounts_migrated_v4';
  static const _smsBodyMigratedKey = 'sms_body_migrated_v1';
  static const _importRulesKey = 'import_rules_v1';
  static const _importRulesSeededKey = 'import_rules_seeded_v1';
  static const _importRulesPrunedKey = 'import_rules_pruned_v1';
  static const _customCategoriesKey = 'custom_categories_v1';
  static const _builtinOverridesKey = 'builtin_category_overrides_v1';
  static const _groupsKey = 'category_groups_v1';
  static const _groupsSeededKey = 'category_groups_seeded_v1';
  static const _budgetsKey = 'spend_budgets_v1';

  final List<Tx> _transactions = [];
  final List<ClassifierRule> _rules = [];
  final List<Account> _accounts = [];
  final List<ImportRule> _importRules = [];
  final List<CategoryGroup> _groups = [];

  /// categoryId → groupId. Kept separate from [TxCategory] so the const
  /// built-in categories can be grouped with the same mechanism as custom
  /// ones.
  final Map<String, String> _groupAssignments = {};
  final List<SpendBudget> _budgets = [];
  bool _loaded = false;

  bool get loaded => _loaded;

  _Derived _d = _Derived();

  /// Identity token that is replaced on every notification. Screens compare
  /// it with [identical] to memoise their own derived pipelines (filtering,
  /// grouping, sorting) across rebuilds that didn't change any data — e.g.
  /// selection taps and scroll-driven setStates.
  Object get revision => _d;

  /// Clearing the derived cache here — rather than in each mutation — makes it
  /// impossible to forget: every mutation already notifies.
  ///
  /// The one invariant to preserve: never mutate `_transactions`, `_accounts`
  /// or `_keyIndex` without notifying afterwards.
  @override
  void notifyListeners() {
    _d = _Derived();
    super.notifyListeners();
  }

  /// Confirmed transactions with their insertion index, oldest first.
  /// See [_Derived.ordered] for why the index is the tie-break.
  List<(Tx, int)> get _ordered => _d.ordered ??= () {
    final list = <(Tx, int)>[];
    for (var i = 0; i < _transactions.length; i++) {
      if (!_transactions[i].pending) list.add((_transactions[i], i));
    }
    list.sort((a, b) {
      final d = a.$1.date.compareTo(b.$1.date);
      return d != 0 ? d : a.$2.compareTo(b.$2);
    });
    return list;
  }();

  /// Confirmed transactions, newest first. Pending SMS imports are excluded —
  /// they live in [pendingTransactions] until reviewed.
  List<Tx> get transactions =>
      _d.confirmed ??= [for (final (t, _) in _ordered.reversed) t];

  /// SMS imports awaiting user review, newest first.
  List<Tx> get pendingTransactions {
    final cached = _d.pending;
    if (cached != null) return cached;
    final list = _transactions.where((t) => t.pending).toList();
    list.sort((a, b) => b.date.compareTo(a.date));
    return _d.pending = list;
  }

  /// Number of pending imports, without materialising or sorting the list —
  /// the app bar badge reads this on every change.
  int get pendingCount =>
      _d.pendingCount ??= _transactions.where((t) => t.pending).length;

  /// Total entries held, confirmed and pending. Cheap: no filtering or sorting.
  int get transactionCount => _transactions.length;

  bool get hasTransactions => _transactions.isNotEmpty;

  List<ClassifierRule> get rules => List.unmodifiable(_rules);

  List<Account> get accounts => List.unmodifiable(_accounts);

  /// Accounts shown in lists, pickers and totals. Closed accounts are only
  /// dropped HERE — [accounts] stays complete so "does the user have
  /// accounts at all" checks (dashboard mode, balance breakdown) don't flip
  /// when the last open account closes, and [accountById]/[accountForKey]
  /// keep resolving history.
  List<Account> get openAccounts =>
      List.unmodifiable(_accounts.where((a) => !a.isClosed));

  List<Account> get closedAccounts =>
      List.unmodifiable(_accounts.where((a) => a.isClosed));

  List<ImportRule> get importRules => List.unmodifiable(_importRules);

  /// Active ignore phrases, passed to the SMS parser on every scan.
  List<String> get ignorePhrases => [
    for (final r in _importRules)
      if (r.kind == ImportRuleKind.ignore) r.pattern,
  ];

  /// Active spam signals, passed to the SMS parser on every scan.
  List<String> get spamSignals => [
    for (final r in _importRules)
      if (r.kind == ImportRuleKind.spamSignal) r.pattern,
  ];

  double get totalIncome => _allTime.income;
  double get totalExpense => _allTime.expense;

  /// All-time money moved into savings instruments (`savings_out`).
  double get totalSavingsTransfers => _allTime.savings;

  /// Ledger fallback balance: savings transfers are not expenses, but the
  /// money is no longer disposable, so they subtract here too.
  double get balance => totalIncome - totalExpense - totalSavingsTransfers;

  _MonthTotals get _allTime =>
      _d.allTime ??= _totals([for (final (t, _) in _ordered) t]);

  /// Confirmed transactions bucketed by month — see [_Derived.byMonth].
  Map<int, List<Tx>> get _byMonth => _d.byMonth ??= () {
    final buckets = <int, List<Tx>>{};
    for (final (t, _) in _ordered) {
      (buckets[t.date.year * 12 + t.date.month] ??= []).add(t);
    }
    return buckets;
  }();

  /// Months holding at least one confirmed transaction, newest first — the
  /// dashboard's month jump offers these.
  List<DateTime> get monthsWithData {
    final keys = _byMonth.keys.toList()..sort((a, b) => b.compareTo(a));
    return keys.map((k) {
      final m = k % 12 == 0 ? 12 : k % 12;
      return DateTime((k - m) ~/ 12, m);
    }).toList();
  }

  /// Totals for [month], memoised per month — the dashboard and the six-month
  /// chart between them ask for the same months repeatedly on every change.
  _MonthTotals _monthTotals(DateTime month) =>
      _d.months[month.year * 12 + month.month] ??= _totals(
        _byMonth[month.year * 12 + month.month] ?? const [],
      );

  /// One pass producing every income/expense/savings figure for [rows].
  ///
  /// Own-account transfers (card bills/payments, bank-to-bank moves) are
  /// excluded from the income and expense sides: the money never left the
  /// user, so counting it inflates both. They remain in the ledger and in
  /// per-account views for auditing. `savings_out` is a transfer too, but is
  /// additionally surfaced on its own — it reduces disposable income.
  _MonthTotals _totals(List<Tx> rows) {
    var income = 0.0;
    var expense = 0.0;
    var savings = 0.0;
    var savingsOutflow = 0.0;
    var transferIn = 0.0;
    var transferOut = 0.0;
    final byCategory = <String, double>{};
    final transfersBy = <String, double>{};
    final transfersOutBy = <String, double>{};
    for (final t in rows) {
      // Only money moving OUT counts as saved — an income-typed row in this
      // category (import-reachable) would otherwise inflate `savings` and
      // make `balance` subtract money that actually came in.
      if (t.categoryId == kSavingsTransferCategoryId &&
          t.type == TxType.expense) {
        // Display figure: the Saved card shows savings whether or not the
        // category is (still) a transfer.
        savingsOutflow += t.amount;
        // Balance figure: only while a transfer — un-transferred rows land
        // in `expense` below, and `balance = income − expense − savings`
        // must not subtract them twice.
        if (isTransferCategory(t.categoryId)) savings += t.amount;
      }
      if (isTransferCategory(t.categoryId)) {
        if (t.type == TxType.income) {
          transferIn += t.amount;
        } else {
          transferOut += t.amount;
          // Row-direction bucket for budget/group math — must agree with
          // countsTowardBudget's per-row type check.
          transfersOutBy[t.categoryId] =
              (transfersOutBy[t.categoryId] ?? 0) + t.amount;
        }
        transfersBy[t.categoryId] = (transfersBy[t.categoryId] ?? 0) + t.amount;
        continue; // byCategory stays transfer-free — income/expense untouched
      }
      if (t.type == TxType.income) {
        income += t.amount;
      } else {
        // Group splits: only the user's own share is spend; the fronted
        // remainder is money owed back, attributed to Paid for Others so it
        // stays tracked (transfers section) without inflating expense.
        // Display buckets ONLY (transferOut + transfersBy): the remainder
        // has no backing row, so it must stay out of transfersOutBy — the
        // row-direction bucket budget/group math folds. An include-mode
        // budget with the Paid for Others chip used to show ₹375 "spent"
        // while its tap-through list (countsTowardBudget, which can only
        // test the row's real category) came back empty.
        expense += t.spendAmount;
        byCategory[t.categoryId] =
            (byCategory[t.categoryId] ?? 0) + t.spendAmount;
        final fronted = t.frontedAmount;
        if (fronted > 0) {
          transferOut += fronted;
          transfersBy[kPaidForOthersCategoryId] =
              (transfersBy[kPaidForOthersCategoryId] ?? 0) + fronted;
        }
      }
    }
    List<MapEntry<TxCategory, double>> sorted(
      Map<String, double> m, {
      TxType? fallbackType,
    }) {
      final entries = m.entries.map((e) {
        final cat = categoryById(e.key, fallbackType: fallbackType);
        // Keep the RAW bucket id even when the definition fell back to
        // "Other": dashboard rows deep-link a category filter by this id,
        // and the ledger rows still carry the dangling id — resolving the
        // key would send the tap to a filter that matches nothing.
        final key = cat.id == e.key
            ? cat
            : TxCategory(
                id: e.key,
                label: cat.label,
                icon: cat.icon,
                color: cat.color,
                type: cat.type,
                isTransfer: cat.isTransfer,
              );
        return MapEntry(key, e.value);
      }).toList();
      entries.sort((a, b) => b.value.compareTo(a.value));
      return entries;
    }

    return _MonthTotals(
      income: income,
      expense: expense,
      savings: savings,
      savingsOutflow: savingsOutflow,
      byCategory: sorted(byCategory, fallbackType: TxType.expense),
      transferIn: transferIn,
      transferOut: transferOut,
      transfersByCategory: sorted(transfersBy),
      transferOutByCategory: sorted(transfersOutBy),
    );
  }

  double incomeInMonth(DateTime month) => _monthTotals(month).income;

  double expenseInMonth(DateTime month) => _monthTotals(month).expense;

  /// Monthly spend for budget purposes. Transfers are already excluded from
  /// [expenseInMonth]; this alias survives for call sites and future
  /// budget-specific exclusions.
  double budgetSpentInMonth(DateTime month) => expenseInMonth(month);

  /// Money moved into savings instruments during [month].
  double savingsTransfersInMonth(DateTime month) => _monthTotals(month).savings;

  /// Savings-category outflow during [month] regardless of the category's
  /// transfer flag — the Saved card's display figure. Differs from
  /// [savingsTransfersInMonth] only when the user un-transferred the
  /// category (the money then also counts inside expense).
  double savingsOutflowInMonth(DateTime month) =>
      _monthTotals(month).savingsOutflow;

  /// Spend per day-of-month for [month] — the heatmap's cells. Uses the
  /// canonical money-out predicate (expense-typed, non-transfer), so the
  /// days sum to the Spent card. Confirmed rows only.
  Map<int, double> expenseByDayInMonth(DateTime month) {
    final rows = _byMonth[month.year * 12 + month.month];
    if (rows == null) return const {};
    final byDay = <int, double>{};
    for (final t in rows) {
      if (t.type != TxType.expense || isTransferCategory(t.categoryId)) {
        continue;
      }
      byDay[t.date.day] = (byDay[t.date.day] ?? 0) + t.spendAmount;
    }
    return byDay;
  }

  /// Confirmed money-out rows on one calendar [day] — the heatmap's
  /// day-tap sheet.
  List<Tx> expensesOnDay(DateTime day) => [
    for (final t in transactions)
      if (t.type == TxType.expense &&
          !isTransferCategory(t.categoryId) &&
          t.date.year == day.year &&
          t.date.month == day.month &&
          t.date.day == day.day)
        t,
  ];

  /// Average money-out per weekday (index 0 = Monday … 6 = Sunday) across
  /// the whole confirmed history. Each weekday's total is divided by how
  /// many times that weekday OCCURRED between the first transaction and
  /// today — quiet Mondays drag the Monday average down, so this answers
  /// "which days do I usually spend more", not "which days have I ever
  /// spent on".
  List<double> avgExpenseByWeekday() => _d.weekdayAvg ??= _weekdayAvg();

  List<double> _weekdayAvg() {
    final rows = _ordered;
    if (rows.isEmpty) return List.filled(7, 0);
    final totals = List<double>.filled(7, 0);
    var first = rows.first.$1.date;
    for (final (t, _) in rows) {
      if (t.date.isBefore(first)) first = t.date;
      if (t.type != TxType.expense || isTransferCategory(t.categoryId)) {
        continue;
      }
      totals[t.date.weekday - 1] += t.spendAmount;
    }
    final start = DateTime(first.year, first.month, first.day);
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    final days = end.difference(start).inDays + 1;
    // Occurrences of each weekday in [start, end]: every weekday appears
    // days ~/ 7 times, plus one for each weekday in the leftover span.
    final counts = List<int>.filled(7, days ~/ 7);
    for (var i = 0; i < days % 7; i++) {
      counts[(start.weekday - 1 + i) % 7]++;
    }
    return [
      for (var w = 0; w < 7; w++) counts[w] == 0 ? 0 : totals[w] / counts[w],
    ];
  }

  /// Expense totals per category for the given month, largest first.
  List<MapEntry<TxCategory, double>> expenseByCategory(DateTime month) =>
      _monthTotals(month).byCategory;

  /// Money that arrived via transfer categories during [month].
  double transferInInMonth(DateTime month) => _monthTotals(month).transferIn;

  /// Money that left via transfer categories during [month].
  double transferOutInMonth(DateTime month) => _monthTotals(month).transferOut;

  /// Transfer totals per category (both directions) for [month], largest
  /// first.
  List<MapEntry<TxCategory, double>> transfersByCategoryInMonth(
    DateTime month,
  ) => _monthTotals(month).transfersByCategory;

  /// Spending per parent group for [month], largest first. The null group is
  /// the "Other" bucket: groupable categories with no assignment.
  ///
  /// Only money-out rows count — plain expenses plus expense-typed transfer
  /// rows whose category is grouped (per the user's rule, a grouped transfer
  /// simply adds to its group's sum). Money-in transfers are not spend and
  /// are ignored here. Plain income categories are never groupable.
  List<(CategoryGroup?, double)> groupSpendInMonth(DateTime month) {
    final t = _monthTotals(month);
    final sums = <String?, double>{};
    for (final e in t.byCategory) {
      final g = _groupAssignments[e.key.id];
      sums[g] = (sums[g] ?? 0) + e.value;
    }
    // Row-direction bucket, not the gross transfersByCategory filtered by
    // the CATEGORY's type: an income-typed row in an expense transfer
    // category (import-reachable) must not inflate its group's spend.
    for (final e in t.transferOutByCategory) {
      final g = _groupAssignments[e.key.id];
      sums[g] = (sums[g] ?? 0) + e.value;
    }
    final byId = {for (final g in _groups) g.id: g};
    final result = <(CategoryGroup?, double)>[
      for (final e in sums.entries)
        // A dangling assignment (group deleted) lands in "Other" too.
        (e.key == null ? null : byId[e.key], e.value),
    ];
    result.sort((a, b) => b.$2.compareTo(a.$2));
    return result;
  }

  /// What counts as spent toward [b] during [month].
  ///
  /// Include mode: only the picked categories, and a picked money-out
  /// transfer category counts too. Exclude mode: all non-transfer spending
  /// except the picked categories — transfers never count unless explicitly
  /// included via include mode.
  /// Whether one transaction counts toward [b] — the row-level twin of
  /// [budgetSpentFor]; the two must stay in agreement.
  bool countsTowardBudget(Tx t, SpendBudget b) {
    if (t.type != TxType.expense) return false;
    switch (b.mode) {
      case BudgetMode.include:
        return b.categoryIds.contains(t.categoryId);
      case BudgetMode.exclude:
        return !isTransferCategory(t.categoryId) &&
            !b.categoryIds.contains(t.categoryId);
    }
  }

  double budgetSpentFor(SpendBudget b, DateTime month) {
    var sum = 0.0;
    for (final e in budgetBreakdownFor(b, month)) {
      sum += e.value;
    }
    return sum;
  }

  /// Per-category composition of [budgetSpentFor] — the budget detail
  /// sheet's pie. Built from the same buckets, so its sum always equals
  /// the bar's figure by construction. Uses the row-direction transfer
  /// bucket (not the gross one filtered by category type), keeping the
  /// figure in agreement with [countsTowardBudget]'s per-row semantics.
  List<MapEntry<TxCategory, double>> budgetBreakdownFor(
    SpendBudget b,
    DateTime month,
  ) {
    final t = _monthTotals(month);
    final entries = switch (b.mode) {
      BudgetMode.include => <MapEntry<TxCategory, double>>[
        for (final e in t.byCategory)
          if (b.categoryIds.contains(e.key.id)) e,
        for (final e in t.transferOutByCategory)
          if (b.categoryIds.contains(e.key.id)) e,
      ],
      BudgetMode.exclude => <MapEntry<TxCategory, double>>[
        for (final e in t.byCategory)
          if (!b.categoryIds.contains(e.key.id)) e,
      ],
    };
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  /// Collection names whose stored blob failed to decode during [load] and
  /// was skipped. Non-empty means the user should be told (the home screen
  /// shows a banner) — the alternative used to be an unhandled throw and a
  /// permanent loading spinner on every launch.
  final List<String> _loadWarnings = [];
  List<String> get loadWarnings => List.unmodifiable(_loadWarnings);

  /// Runs one collection's decode; on ANY failure the collection is left in
  /// [reset]'s state and the name is recorded, so a single corrupted blob
  /// can never prevent the rest of the data from loading.
  Future<void> _guardedLoad(
    String name,
    Future<void> Function() decode,
    void Function() reset, {
    Future<void> Function()? quarantine,
  }) async {
    try {
      await decode();
    } catch (_) {
      reset();
      _loadWarnings.add(name);
      // Keep the unreadable bytes under a side key: the next successful
      // save overwrites the live key with the reset (empty) state, and
      // without a copy the original data would be gone for good — even an
      // out-of-band repair becomes impossible.
      try {
        await quarantine?.call();
      } catch (_) {}
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _loadWarnings.clear();
    final txRaw = prefs.getString(_txKey);
    if (txRaw != null) {
      await _guardedLoad(
        'transactions',
        () async {
          final decoded = (await _decodeTxBlob(
            txRaw,
          )).map((e) => Tx.fromJson(e as Map<String, dynamic>)).toList();
          _transactions
            ..clear()
            ..addAll(decoded);
        },
        _transactions.clear,
        quarantine: () => prefs.setString('${_txKey}_corrupt', txRaw),
      );
    }
    final rulesRaw = prefs.getString(_rulesKey);
    if (rulesRaw != null) {
      await _guardedLoad('rules', () async {
        final decoded = (jsonDecode(rulesRaw) as List)
            .map((e) => ClassifierRule.fromJson(e as Map<String, dynamic>))
            .toList();
        _rules
          ..clear()
          ..addAll(decoded);
      }, _rules.clear);
    }
    final accountsRaw = prefs.getString(_accountsKey);
    if (accountsRaw != null) {
      await _guardedLoad('accounts', () async {
        final decoded = (jsonDecode(accountsRaw) as List)
            .map((e) => Account.fromJson(e as Map<String, dynamic>))
            .toList();
        _accounts
          ..clear()
          ..addAll(decoded);
      }, _accounts.clear);
    }
    final importRulesRaw = prefs.getString(_importRulesKey);
    if (importRulesRaw != null) {
      await _guardedLoad('import rules', () async {
        final decoded = (jsonDecode(importRulesRaw) as List)
            .map((e) => ImportRule.fromJson(e as Map<String, dynamic>))
            .toList();
        _importRules
          ..clear()
          ..addAll(decoded);
      }, _importRules.clear);
    }
    final customCatsRaw = prefs.getString(_customCategoriesKey);
    if (customCatsRaw != null) {
      await _guardedLoad('categories', () async {
        setCustomCategories(
          (jsonDecode(customCatsRaw) as List)
              .map((e) => TxCategory.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      }, () => setCustomCategories(const []));
    }
    final overridesRaw = prefs.getString(_builtinOverridesKey);
    if (overridesRaw != null) {
      await _guardedLoad('category styles', () async {
        setBuiltinOverrides({
          for (final e in jsonDecode(overridesRaw) as List)
            (e as Map<String, dynamic>)['id'] as String: TxCategory.fromJson(e),
        });
      }, () => setBuiltinOverrides(const {}));
    }
    final groupsRaw = prefs.getString(_groupsKey);
    if (groupsRaw != null) {
      await _guardedLoad(
        'groups',
        () async {
          final blob = jsonDecode(groupsRaw) as Map<String, dynamic>;
          final groups = (blob['groups'] as List? ?? const [])
              .map((e) => CategoryGroup.fromJson(e as Map<String, dynamic>))
              .toList();
          final assignments = Map<String, String>.from(
            blob['assignments'] as Map? ?? const {},
          );
          _groups
            ..clear()
            ..addAll(groups);
          _groupAssignments
            ..clear()
            ..addAll(assignments);
        },
        () {
          _groups.clear();
          _groupAssignments.clear();
        },
      );
    }
    final budgetsRaw = prefs.getString(_budgetsKey);
    if (budgetsRaw != null) {
      await _guardedLoad('budgets', () async {
        final decoded = (jsonDecode(budgetsRaw) as List)
            .map((e) => SpendBudget.fromJson(e as Map<String, dynamic>))
            .toList();
        _budgets
          ..clear()
          ..addAll(decoded);
      }, _budgets.clear);
    }
    // Index must be live before backfill so _ensureAccount sees existing keys.
    _rebuildKeyIndex();
    // Seeding + migrations are best-effort: a failure mid-way (disk full,
    // an isolate dying during a persist) must not prevent the app from
    // opening — flags follow data, so an aborted pass simply re-runs.
    try {
      // One-time seeding of the built-in keyword classifications as editable
      // rules. Appended after any existing user rules so user rules keep
      // priority (first match wins). Existing history is left untouched — it
      // was already categorised by the same keywords at import time.
      // Seed data is persisted BEFORE the done-flag is recorded (the same
      // crash-safety invariant the migrations below follow): a crash in
      // between re-runs the seed instead of leaving built-ins permanently
      // absent behind a flag that says they exist.
      if (!(prefs.getBool(_rulesSeededKey) ?? false)) {
        _seedDefaultRules();
        await _persist(rules: true);
        await prefs.setBool(_rulesSeededKey, true);
      }
      // One-time seeding of the parser's ignore phrases and spam signals as
      // editable import rules.
      if (!(prefs.getBool(_importRulesSeededKey) ?? false)) {
        _seedDefaultImportRules();
        await _persist(importRules: true);
        await prefs.setBool(_importRulesSeededKey, true);
      }
      // One-shot removal of retired built-in ignore phrases: 'reversed'
      // dropped refund alerts (leaving the original debit uncancelled) and
      // 'is due'/'due on' rejected completed-EMI debits with a "next due"
      // footer. Only rules still in factory form (built-in id AND unchanged
      // pattern) are removed — anything the user edited is theirs.
      if (!(prefs.getBool(_importRulesPrunedKey) ?? false)) {
        const retired = ['reversed', 'is due', 'due on'];
        final before = _importRules.length;
        _importRules.removeWhere(
          (r) =>
              r.kind == ImportRuleKind.ignore &&
              retired.contains(r.pattern) &&
              r.id == _builtinImportRuleId(r.pattern, ImportRuleKind.ignore),
        );
        if (_importRules.length != before) await _persist(importRules: true);
        await prefs.setBool(_importRulesPrunedKey, true);
      }
      // One-time seeding of the starter parent groups. The flag — not the data —
      // gates reseeding, so deleting or renaming Needs/Wants sticks.
      if (!(prefs.getBool(_groupsSeededKey) ?? false)) {
        if (_groups.isEmpty && _groupAssignments.isEmpty) {
          _seedDefaultGroups();
          await _persist(groups: true);
        }
        await prefs.setBool(_groupsSeededKey, true);
      }
      // The migration passes below mark what they touched instead of each
      // persisting; one combined write at the end replaces the up-to-five full
      // ledger re-encodes a first launch after an upgrade used to cost. The
      // done-flags are only recorded after that write lands, so a crash
      // mid-load re-runs the passes instead of silently skipping them.
      var migrationTxDirty = false;
      var migrationAccountsDirty = false;
      final migrationFlags = <String>[];
      // One-time backfill: derive account keys + balances for SMS transactions
      // imported before account tracking existed, by re-reading their stored
      // SMS body. Auto-creates the discovered accounts.
      if (!(prefs.getBool(_accountsMigratedKey) ?? false)) {
        var changed = false;
        for (var i = 0; i < _transactions.length; i++) {
          final t = _transactions[i];
          if (t.source != TxSource.sms || t.acctKey != null) continue;
          final (key, isCard) = SmsTxnParser.accountKeyOf(t.sender, t.smsText);
          final bal = SmsTxnParser.balanceAfterOf(t.smsText);
          if (key == null && bal == null) continue;
          _transactions[i] = t.copyWith(acctKey: key, balanceAfter: bal);
          if (key != null) _ensureAccount(key, isCard: isCard);
          changed = true;
        }
        migrationFlags.add(_accountsMigratedKey);
        if (changed || _accounts.isNotEmpty) {
          migrationTxDirty = true;
          migrationAccountsDirty = true;
        }
      }
      // One-time re-derivation: account-key, balance and timestamp extraction all
      // widened after existing data was imported (digit-prefixed card masks like
      // "4xxx3010", "ending with 1234", "AVAILABLE LIMIT IS RS. X", single-digit
      // months, and body clock times). Re-read every stored SMS body and fill in
      // what was missed — never overwriting a value that is already set, since an
      // acctKey may have been assigned by hand. Without this pass, card payments
      // already in the ledger would stay attached to no account.
      if (!(prefs.getBool(_accountsMigratedV2Key) ?? false)) {
        var changed = false;
        for (var i = 0; i < _transactions.length; i++) {
          final t = _transactions[i];
          if (t.source != TxSource.sms || t.smsText.isEmpty) continue;
          String? key;
          var isCard = false;
          if (t.acctKey == null) {
            final derived = SmsTxnParser.accountKeyOf(t.sender, t.smsText);
            key = derived.$1;
            isCard = derived.$2;
          }
          final bal = t.balanceAfter == null
              ? SmsTxnParser.balanceAfterOf(t.smsText)
              : null;
          // Midnight means no time was ever recorded. Only a body clock time is
          // recoverable — the SMS arrival time was never stored.
          final stamped = (t.date.hour == 0 && t.date.minute == 0)
              ? SmsTxnParser.dateWithBodyTime(t.date, t.smsText)
              : null;
          if (key == null && bal == null && stamped == null) continue;
          _transactions[i] = t.copyWith(
            acctKey: key,
            balanceAfter: bal,
            date: stamped,
          );
          if (key != null) _ensureAccount(key, isCard: isCard);
          changed = true;
        }
        migrationFlags.add(_accountsMigratedV2Key);
        if (changed) {
          migrationTxDirty = true;
          migrationAccountsDirty = true;
        }
      }
      // One-time re-key. Two classes of machine-derived keys went wrong:
      //  * chimera keys — accountKeyOf now skips fragments naming another bank
      //    ("credited to ICICI Bank Account XXX879" inside an Indian Bank alert
      //    used to become "INDBNK:879");
      //  * squash keys — brand senders missing from the bank-code map fell back
      //    to an alphanumeric squash ("Indian Bank" → "INDIANBANK:2080"),
      //    splitting one real account across two tiles.
      // Re-derive the key for every SMS transaction still carrying one of those
      // machine-derived forms. A key matching neither was assigned by hand and
      // is never touched.
      if (!(prefs.getBool(_accountsMigratedV3Key) ?? false)) {
        var changed = false;
        for (var i = 0; i < _transactions.length; i++) {
          final t = _transactions[i];
          if (t.source != TxSource.sms ||
              t.smsText.isEmpty ||
              t.acctKey == null) {
            continue;
          }
          final (legacyKey, _) = SmsTxnParser.legacyAccountKeyOf(
            t.sender,
            t.smsText,
          );
          if (legacyKey == null) continue;
          final squashKey =
              '${t.sender.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '')}'
              ':${legacyKey.split(':').last}';
          if (t.acctKey != legacyKey && t.acctKey != squashKey) continue;
          final (key, isCard) = SmsTxnParser.accountKeyOf(t.sender, t.smsText);
          if (key == t.acctKey) continue;
          _transactions[i] = t.copyWith(
            acctKey: key,
            clearAcctKey: key == null,
          );
          if (key != null) _ensureAccount(key, isCard: isCard);
          changed = true;
        }
        migrationFlags.add(_accountsMigratedV3Key);
        if (changed) {
          migrationTxDirty = true;
          migrationAccountsDirty = true;
        }
      }
      // One-time repair: rows hand-assigned to an account used to keep the SMS's
      // "Avl Bal" figure when the row had no derived key at assign time (the
      // "RD account adopts the ICICI balance" bug). Strip the figure from every
      // hand-moved row whose own SMS does not derive a key owned by the account
      // it now resolves to — that figure describes some other account and must
      // not anchor this one.
      if (!(prefs.getBool(_accountsMigratedV4Key) ?? false)) {
        var changed = false;
        for (var i = 0; i < _transactions.length; i++) {
          final t = _transactions[i];
          if (t.balanceAfter == null) continue;
          // No SMS text (e.g. restored from a body-less backup) = no
          // evidence either way — never destroy a balance on absence of
          // proof. v2/v3 have the same guard; this pass is the destructive
          // one so it needs it most.
          if (t.smsText.isEmpty) continue;
          final key = t.acctKey;
          if (key == null || !key.startsWith('manual:')) continue;
          final ownerId = _keyIndex[key];
          if (ownerId == null) continue;
          final (derivedKey, _) = SmsTxnParser.accountKeyOf(
            t.sender,
            t.smsText,
          );
          final owner = _accounts.firstWhere((a) => a.id == ownerId);
          if (derivedKey != null && owner.keys.contains(derivedKey)) continue;
          _transactions[i] = t.copyWith(clearBalanceAfter: true);
          changed = true;
        }
        migrationFlags.add(_accountsMigratedV4Key);
        if (changed) migrationTxDirty = true;
      }
      // One-time move: the raw SMS body historically lived in `note`; it now has
      // its own field so `note` can hold user text. Runs after v1–v4, which were
      // written against body-in-note data (their reads go through smsText and
      // work either way).
      if (!(prefs.getBool(_smsBodyMigratedKey) ?? false)) {
        var changed = false;
        for (var i = 0; i < _transactions.length; i++) {
          final moved = _transactions[i].migrateSmsBodyFromNote();
          if (identical(moved, _transactions[i])) continue;
          _transactions[i] = moved;
          changed = true;
        }
        migrationFlags.add(_smsBodyMigratedKey);
        if (changed) migrationTxDirty = true;
      }
      if (migrationTxDirty || migrationAccountsDirty) {
        await _persist(tx: migrationTxDirty, accounts: migrationAccountsDirty);
      }
      for (final flag in migrationFlags) {
        await prefs.setBool(flag, true);
      }
    } catch (_) {
      _loadWarnings.add('setup');
    }
    _rebuildKeyIndex();
    _loaded = true;
    notifyListeners();
  }

  // --- Persistence ----------------------------------------------------------

  /// When true (the default), the transaction blob — the one collection that
  /// grows unbounded, ~4 MB of JSON at 10k SMS rows — is encoded/decoded via
  /// [compute] so per-mutation writes and the initial [load] don't freeze the
  /// UI. Small payloads stay on the main isolate where spawning would cost
  /// more than it saves — which also keeps plain test fixtures on the
  /// synchronous path. `testWidgets` files whose fake clock can't complete
  /// real-isolate futures should set this to false in their setUp. (On web
  /// [compute] already runs inline, so this changes nothing there.)
  static bool useIsolateCodec = true;

  /// Payloads below this many characters aren't worth an isolate round-trip.
  static const _kIsolateCodecMinChars = 200000;

  static Future<String> _encodeTxBlob(List<Map<String, dynamic>> maps) async {
    // Rough size probe without encoding: ~120–300 chars per SMS row. Cheaper
    // than encoding twice; only the order of magnitude matters here.
    if (!useIsolateCodec || maps.length < 800) return jsonEncode(maps);
    return compute(jsonEncode, maps, debugLabel: 'encodeTxBlob');
  }

  static Future<List<dynamic>> _decodeTxBlob(String raw) async {
    if (!useIsolateCodec || raw.length < _kIsolateCodecMinChars) {
      return jsonDecode(raw) as List;
    }
    return await compute(jsonDecode, raw, debugLabel: 'decodeTxBlob') as List;
  }

  /// Monotonic sequence for transaction-blob writes; see the ordering guard
  /// in _persistOrThrow.
  int _txWriteSeq = 0;
  int _txWriteDispatched = 0;

  /// True after a storage write failed — the UI shows a persistent banner,
  /// because the alternative is an optimistic screen whose edits silently
  /// evaporate on the next launch. Cleared by the first successful write
  /// (any mutation, or [retryPersist]).
  bool _persistFailed = false;
  bool get persistFailed => _persistFailed;

  /// Rewrites every collection; the banner's Retry action.
  Future<void> retryPersist() => _persist(
    tx: true,
    rules: true,
    accounts: true,
    importRules: true,
    categories: true,
    overrides: true,
    groups: true,
    budgets: true,
  );

  /// Writes only the collections the caller says it changed.
  ///
  /// Every mutation used to rewrite all five blobs, so renaming an account
  /// re-encoded the entire transaction ledger — by far the largest of them.
  ///
  /// The write is immediate rather than debounced, deliberately: callers await
  /// this and then construct a second provider and [load], so the durability
  /// has to hold on return. (A timer-coalesced version deadlocks under
  /// `testWidgets`, whose fake clock never advances while a test awaits.)
  ///
  /// Never throws: callers mutate-then-persist optimistically and many don't
  /// await, so an error here surfaces via [persistFailed] instead of
  /// vanishing (or worse, aborting a caller halfway through a batch).
  Future<void> _persist({
    bool tx = false,
    bool rules = false,
    bool accounts = false,
    bool importRules = false,
    bool categories = false,
    bool overrides = false,
    bool groups = false,
    bool budgets = false,
  }) async {
    try {
      await _persistOrThrow(
        tx: tx,
        rules: rules,
        accounts: accounts,
        importRules: importRules,
        categories: categories,
        overrides: overrides,
        groups: groups,
        budgets: budgets,
      );
      if (_persistFailed) {
        _persistFailed = false;
        notifyListeners();
      }
    } catch (_) {
      if (!_persistFailed) {
        _persistFailed = true;
        notifyListeners();
      }
    }
  }

  Future<void> _persistOrThrow({
    bool tx = false,
    bool rules = false,
    bool accounts = false,
    bool importRules = false,
    bool categories = false,
    bool overrides = false,
    bool groups = false,
    bool budgets = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (tx) {
      // Ordering guard: two rapid mutations both persist, and with the
      // isolate codec the OLDER encode can finish LAST — writing it would
      // roll the newer mutation back on the next launch. Each write takes a
      // sequence number at snapshot time and is skipped if a newer write
      // has already been dispatched (dispatch marks the sequence before
      // awaiting, so a stale job can never slip in between).
      final seq = ++_txWriteSeq;
      final blob = await _encodeTxBlob(
        _transactions.map((t) => t.toJson()).toList(),
      );
      if (seq > _txWriteDispatched) {
        _txWriteDispatched = seq;
        await prefs.setString(_txKey, blob);
      }
    }
    if (rules) {
      await prefs.setString(
        _rulesKey,
        jsonEncode(_rules.map((r) => r.toJson()).toList()),
      );
    }
    if (accounts) {
      await prefs.setString(
        _accountsKey,
        jsonEncode(_accounts.map((a) => a.toJson()).toList()),
      );
    }
    if (importRules) {
      await prefs.setString(
        _importRulesKey,
        jsonEncode(_importRules.map((r) => r.toJson()).toList()),
      );
    }
    if (categories) {
      await prefs.setString(
        _customCategoriesKey,
        jsonEncode(customCategories.map((c) => c.toJson()).toList()),
      );
    }
    if (overrides) {
      await prefs.setString(
        _builtinOverridesKey,
        jsonEncode(builtinOverrides.values.map((c) => c.toJson()).toList()),
      );
    }
    if (groups) {
      await prefs.setString(
        _groupsKey,
        jsonEncode({
          'groups': _groups.map((g) => g.toJson()).toList(),
          'assignments': _groupAssignments,
        }),
      );
    }
    if (budgets) {
      await prefs.setString(
        _budgetsKey,
        jsonEncode(_budgets.map((b) => b.toJson()).toList()),
      );
    }
  }

  // Monotonic counter: the timestamp alone collides when two ids are minted
  // inside one clock tick (Windows granularity is ~1ms), and the transaction
  // count doesn't move between e.g. two rule creations — a shared id then
  // makes deleteRule silently remove both.
  int _idSeq = 0;
  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_transactions.length}'
      '_${_idSeq++}';

  // Monotonic counter so accounts created in the same microsecond (e.g. during
  // a batch import or backfill) never collide on id.
  int _acctSeq = 0;
  String _newAccountId() =>
      'acct_${DateTime.now().microsecondsSinceEpoch}_${_acctSeq++}';

  /// Adds a manual transaction and returns its new id (so callers can assign
  /// it to an account).
  Future<String> addTransaction({
    required TxType type,
    required String categoryId,
    required double amount,
    required String note,
    required DateTime date,
    String sender = '',
    double? myShare,
  }) async {
    final id = _newId();
    _transactions.add(
      Tx(
        id: id,
        type: type,
        categoryId: categoryId,
        amount: amount,
        note: note,
        date: date,
        sender: sender,
        myShare: myShare,
      ),
    );
    notifyListeners();
    await _persist(tx: true);
    return id;
  }

  Future<void> updateTransaction(Tx updated) async {
    final i = _transactions.indexWhere((t) => t.id == updated.id);
    if (i == -1) return;
    final old = _transactions[i];
    // A hand-picked category is a correction rules must never undo.
    final categoryChanged = old.categoryId != updated.categoryId;
    // A stated "Avl Bal" is the truth at the moment its SMS arrived; moving
    // the row to another DAY makes the anchor lie about when that truth
    // held — a salary re-dated to the 1st of next month otherwise anchors
    // the balance in the future, swallowing every spend dated before it and
    // out-ranking "Set balance…". Same-day time fixes (e.g. correcting the
    // midnight "time unknown" sentinel) keep it. Same invariant as
    // _assignInPlace, which clears the figure when a row changes accounts.
    final dayChanged =
        old.date.year != updated.date.year ||
        old.date.month != updated.date.month ||
        old.date.day != updated.date.day;
    _transactions[i] = updated.copyWith(
      userCategorized: categoryChanged ? true : null,
      clearBalanceAfter: dayChanged && updated.balanceAfter != null,
    );
    notifyListeners();
    await _persist(tx: true);
  }

  Future<void> deleteTransaction(String id) async {
    _transactions.removeWhere((t) => t.id == id);
    notifyListeners();
    await _persist(tx: true);
  }

  /// Bulk delete for the selection bar: removes every row whose id is in
  /// [ids] and returns the removed rows so the caller can offer Undo (via
  /// [restoreTransactions]). One notify + persist for the whole batch.
  Future<List<Tx>> deleteTransactions(Iterable<String> ids) async {
    final wanted = ids.toSet();
    final removed = [
      for (final t in _transactions)
        if (wanted.contains(t.id)) t,
    ];
    if (removed.isEmpty) return removed;
    _transactions.removeWhere((t) => wanted.contains(t.id));
    notifyListeners();
    await _persist(tx: true);
    return removed;
  }

  /// The undo half of [deleteTransaction]: reinserts the captured object
  /// verbatim (same id, flags and account key). Ordering doesn't depend on
  /// list position — views sort by date — so appending is enough.
  Future<void> restoreTransaction(Tx tx) async {
    if (_transactions.any((t) => t.id == tx.id)) return;
    _transactions.add(tx);
    notifyListeners();
    await _persist(tx: true);
  }

  /// Batch [restoreTransaction]: the undo half of [deleteTransactions] and
  /// [discardAllPending]. Rows whose id meanwhile reappeared are skipped.
  Future<void> restoreTransactions(List<Tx> rows) async {
    final existing = {for (final t in _transactions) t.id};
    var added = 0;
    for (final tx in rows) {
      if (existing.contains(tx.id)) continue;
      _transactions.add(tx);
      added++;
    }
    if (added == 0) return;
    notifyListeners();
    await _persist(tx: true);
  }

  /// The undo half of edits that only rewrite row fields (bulk category,
  /// bulk date & time, confirming a pending import): puts the captured
  /// pre-edit copies back by id. Rows deleted in the meantime are skipped
  /// rather than resurrected, and rows dropped as spam are re-added — the
  /// snapshot is the user's data either way. Not suitable for account
  /// assignment, which also rewrites account key sets.
  Future<void> restoreEditedTransactions(List<Tx> snapshot) async {
    var changed = 0;
    for (final old in snapshot) {
      final i = _transactions.indexWhere((t) => t.id == old.id);
      if (i == -1) {
        _transactions.add(old);
      } else {
        _transactions[i] = old;
      }
      changed++;
    }
    if (changed > 0) {
      notifyListeners();
      await _persist(tx: true);
    }
  }

  // --- Classifier rules -----------------------------------------------------

  Future<({int reclassified, int droppedPending, List<Tx> dropped})> addRule(
    String pattern,
    String categoryId,
  ) async {
    final rule = ClassifierRule(
      id: _newId(),
      pattern: pattern.trim(),
      categoryId: categoryId,
    );
    // Newest first: user rules are matched before older/seeded ones.
    _rules.insert(0, rule);
    // Re-applying can recategorise or drop SMS history, so transactions are
    // dirty too.
    final applied = _reapplyRulesToHistory();
    notifyListeners();
    await _persist(rules: true, tx: true);
    return applied;
  }

  Future<({int reclassified, int droppedPending, List<Tx> dropped})> updateRule(
    ClassifierRule updated,
  ) async {
    final i = _rules.indexWhere((r) => r.id == updated.id);
    if (i == -1) {
      return (reclassified: 0, droppedPending: 0, dropped: const <Tx>[]);
    }
    _rules[i] = updated;
    final applied = _reapplyRulesToHistory();
    notifyListeners();
    await _persist(rules: true, tx: true);
    return applied;
  }

  /// Deleting a rule stops it applying to future imports; existing
  /// transactions keep their categories (reverting them would be guesswork).
  Future<void> deleteRule(String id) async {
    _rules.removeWhere((r) => r.id == id);
    notifyListeners();
    await _persist(rules: true);
  }

  /// The undo half of [deleteRule]. [index] is the rule's old list position —
  /// rule order is match priority (first match wins), so it must come back
  /// exactly where it sat, not at the top like a new rule.
  Future<void> restoreRule(ClassifierRule rule, int index) async {
    if (_rules.any((r) => r.id == rule.id)) return;
    _rules.insert(index.clamp(0, _rules.length), rule);
    notifyListeners();
    await _persist(rules: true);
  }

  /// Folds several same-category rules into one whose conditions are the
  /// union of theirs, OR-chained. The survivor is the FIRST selected rule in
  /// list order: it keeps its id and its position — delete-then-addRule
  /// would promote the merged rule to the top, where it could newly shadow
  /// a different-category rule for some message. Conditions are joined in
  /// priority order, dropping case-insensitive duplicates (matching is
  /// case-insensitive, so "Swiggy" after "swiggy" adds nothing).
  ///
  /// The absorbed rules' priority slots disappear, so the merged rule can
  /// genuinely match earlier than an absorbed one used to — hence the same
  /// re-apply + result record as [addRule]/[updateRule].
  Future<({int reclassified, int droppedPending, List<Tx> dropped})> mergeRules(
    Set<String> ids,
  ) async {
    final selected = [
      for (final r in _rules)
        if (ids.contains(r.id)) r,
    ];
    final sameCategory = selected.map((r) => r.categoryId).toSet().length == 1;
    if (selected.length < 2 || !sameCategory) {
      return (reclassified: 0, droppedPending: 0, dropped: const <Tx>[]);
    }
    final seen = <String>{};
    final conditions = [
      for (final r in selected)
        for (final p in r.patterns)
          if (seen.add(p.toLowerCase())) p,
    ];
    final survivor = selected.first;
    final i = _rules.indexWhere((r) => r.id == survivor.id);
    _rules[i] = survivor.copyWith(pattern: conditions.join(' | '));
    _rules.removeWhere((r) => r.id != survivor.id && ids.contains(r.id));
    final applied = _reapplyRulesToHistory();
    notifyListeners();
    await _persist(rules: true, tx: true);
    return applied;
  }

  /// The undo half of [mergeRules]: puts back a full pre-merge snapshot.
  /// Wholesale, not per-rule — restoring N rules through [restoreRule] is
  /// order-dependent and would misplace priorities.
  Future<void> restoreRules(List<ClassifierRule> snapshot) async {
    _rules
      ..clear()
      ..addAll(snapshot);
    _reapplyRulesToHistory();
    notifyListeners();
    await _persist(rules: true, tx: true);
  }

  /// First rule that matches [text] AND can apply to a row of [type]: spam
  /// rules always can; a category rule only when its category's direction
  /// agrees. Type-mismatched matches are skipped rather than returned — one
  /// mis-targeted rule ("swiggy → Salary") used to shadow every later
  /// correct rule for the same text, silently.
  ClassifierRule? _matchRule(String text, TxType type) =>
      _matchRuleIn(_rules, text, type);

  ClassifierRule? _matchRuleIn(
    List<ClassifierRule> rules,
    String text,
    TxType type,
  ) {
    for (final r in rules) {
      if (!r.matches(text)) continue;
      if (r.isSpamRule || categoryById(r.categoryId).type == type) return r;
    }
    return null;
  }

  /// Dry run for the rule dialog: how many pending imports saving [pattern]
  /// → [categoryId] would drop as spam, honouring the same first-match-wins
  /// priority [_reapplyRulesToHistory] uses (an earlier rule that already
  /// claims a message shadows the candidate). [replacingRuleId] simulates
  /// editing that rule in place instead of adding a new one. Lets the
  /// dialog warn *before* the queue is touched, not after.
  int pendingSpamDropsFor(
    String pattern,
    String categoryId, {
    String? replacingRuleId,
  }) {
    final candidate = ClassifierRule(
      id: replacingRuleId ?? '_dry_run_',
      pattern: pattern.trim(),
      categoryId: categoryId,
    );
    final rules = replacingRuleId == null
        ? [candidate, ..._rules]
        : [
            for (final r in _rules)
              if (r.id == replacingRuleId) candidate else r,
          ];
    var drops = 0;
    for (final t in _transactions) {
      if (t.source != TxSource.sms || t.userCategorized || !t.pending) {
        continue;
      }
      final text = t.smsText;
      if (text.isEmpty) continue;
      final rule = _matchRuleIn(rules, text, t.type);
      if (rule != null && rule.isSpamRule) drops++;
    }
    return drops;
  }

  // --- Custom categories --------------------------------------------------

  /// Creates a user category and returns its id.
  Future<String> addCategory({
    required String label,
    required TxType type,
    required IconData icon,
    required Color color,
    bool isTransfer = false,
  }) async {
    final id = 'cat_${DateTime.now().microsecondsSinceEpoch}';
    setCustomCategories([
      ...customCategories,
      TxCategory(
        id: id,
        label: label.trim(),
        type: type,
        icon: icon,
        color: color,
        isTransfer: isTransfer,
      ),
    ]);
    notifyListeners();
    await _persist(categories: true);
    return id;
  }

  /// App-wide invariant: `tx.type == category.type`. Flipping a category's
  /// direction must re-type its existing rows, or budget bars (which read
  /// the definition's type) and the transaction filters (which read the
  /// row's type) silently disagree about the same money. Returns whether
  /// any row changed.
  bool _retypeRows(String categoryId, TxType newType) {
    var changed = false;
    for (var i = 0; i < _transactions.length; i++) {
      final t = _transactions[i];
      if (t.categoryId != categoryId || t.type == newType) continue;
      _transactions[i] = t.copyWith(type: newType);
      changed = true;
    }
    return changed;
  }

  Future<void> updateCategory(TxCategory updated) async {
    var txChanged = false;
    final previous = customCategories
        .where((c) => c.id == updated.id)
        .firstOrNull;
    if (previous != null && previous.type != updated.type) {
      txChanged = _retypeRows(updated.id, updated.type);
    }
    setCustomCategories([
      for (final c in customCategories) c.id == updated.id ? updated : c,
    ]);
    // A category edited into plain income can no longer be grouped or
    // budgeted — drop stale references so they don't linger invisibly.
    var detached = (groups: false, budgets: false);
    if (!isGroupable(updated)) detached = _detachCategory(updated.id);
    notifyListeners();
    await _persist(
      categories: true,
      tx: txChanged,
      groups: detached.groups,
      budgets: detached.budgets,
    );
  }

  /// Deletes a user category. Its transactions fall back to the matching
  /// "Other" category (by their own type) and rules targeting it are removed.
  /// Deletes a custom category. Its transactions move to [moveTo] when given
  /// (any existing category — rows are re-typed to match it, like a category
  /// direction change), otherwise to the row-type's "Other" fallback. Rules
  /// targeting the deleted category are removed either way.
  Future<void> deleteCategory(String id, {String? moveTo}) async {
    final target = moveTo == null || moveTo == id
        ? null
        : allCategories.where((c) => c.id == moveTo).firstOrNull;
    for (var i = 0; i < _transactions.length; i++) {
      final t = _transactions[i];
      if (t.categoryId != id) continue;
      _transactions[i] = target == null
          ? t.copyWith(
              categoryId: t.type == TxType.expense
                  ? 'other_expense'
                  : 'other_income',
            )
          : t.copyWith(
              categoryId: target.id,
              type: target.type,
              // Shares only exist on expense-typed non-transfer rows — a
              // leftover share would silently resurface if the row later
              // moved back out (same invariant as _sanitizeMyShare).
              clearMyShare:
                  target.type != TxType.expense ||
                  isTransferCategory(target.id),
            );
    }
    _rules.removeWhere((r) => r.categoryId == id);
    setCustomCategories(customCategories.where((c) => c.id != id));
    final detached = _detachCategory(id);
    notifyListeners();
    await _persist(
      categories: true,
      rules: true,
      tx: true,
      groups: detached.groups,
      budgets: detached.budgets,
    );
  }

  // --- Built-in category overrides ------------------------------------------

  bool isBuiltinCategory(String id) => kCategories.any((c) => c.id == id);

  bool isBuiltinOverridden(String id) => builtinOverrides.containsKey(id);

  /// The two "Other" built-ins are the app's hard-coded fallback/remap
  /// targets (deleteCategory, _sanitizeImportedTx, CSV import) — their
  /// direction and non-transfer-ness must never change, or every remap
  /// would mint invariant-breaking rows.
  static bool isFallbackCategory(String id) =>
      id == 'other_expense' || id == 'other_income';

  /// Edits a built-in category — fully: name, icon, colour, AND direction /
  /// transfer-ness (except the two fallback "Other" ids, whose structure is
  /// forced back to the built-in definition). A direction change re-types
  /// the category's existing rows; a category edited out of groupability
  /// (plain income) is detached from groups and budgets — mirroring
  /// [updateCategory] for customs.
  Future<void> overrideBuiltinCategory({
    required String id,
    required String label,
    required IconData icon,
    required Color color,
    TxType? type,
    bool? isTransfer,
  }) async {
    final base = kCategories.firstWhere((c) => c.id == id);
    final structural = !isFallbackCategory(id);
    final updated = TxCategory(
      id: id,
      label: label.trim(),
      type: structural ? (type ?? base.type) : base.type,
      icon: icon,
      color: color,
      isTransfer: structural
          ? (isTransfer ?? base.isTransfer)
          : base.isTransfer,
    );
    final previous = categoryById(id); // override-applied current definition
    final txChanged = previous.type != updated.type
        ? _retypeRows(id, updated.type)
        : false;
    setBuiltinOverrides({...builtinOverrides, id: updated});
    var detached = (groups: false, budgets: false);
    if (!isGroupable(updated)) detached = _detachCategory(id);
    notifyListeners();
    await _persist(
      overrides: true,
      tx: txChanged,
      groups: detached.groups,
      budgets: detached.budgets,
    );
  }

  /// Restores a built-in category's original definition. If the override
  /// had flipped the direction, the category's rows are re-typed back so
  /// the `tx.type == category.type` invariant holds after the reset too.
  Future<void> resetBuiltinCategory(String id) async {
    if (!isBuiltinOverridden(id)) return;
    final previous = categoryById(id);
    final base = kCategories.firstWhere((c) => c.id == id);
    final txChanged = previous.type != base.type
        ? _retypeRows(id, base.type)
        : false;
    setBuiltinOverrides({...builtinOverrides}..remove(id));
    var detached = (groups: false, budgets: false);
    if (!isGroupable(base)) detached = _detachCategory(id);
    notifyListeners();
    await _persist(
      overrides: true,
      tx: txChanged,
      groups: detached.groups,
      budgets: detached.budgets,
    );
  }

  // --- Parent groups ------------------------------------------------------

  List<CategoryGroup> get groups => List.unmodifiable(_groups);

  /// The group a category is assigned to, or null (the "Other" bucket).
  String? groupIdOf(String categoryId) => _groupAssignments[categoryId];

  /// Groups exist for spend analytics: expense categories and transfer
  /// categories (either direction) can be grouped; plain income cannot.
  bool isGroupable(TxCategory c) => c.type == TxType.expense || c.isTransfer;

  Future<String> addGroup({required String label, required Color color}) async {
    final id = 'grp_${DateTime.now().microsecondsSinceEpoch}';
    _groups.add(CategoryGroup(id: id, label: label.trim(), color: color));
    notifyListeners();
    await _persist(groups: true);
    return id;
  }

  Future<void> updateGroup(CategoryGroup updated) async {
    final i = _groups.indexWhere((g) => g.id == updated.id);
    if (i == -1) return;
    _groups[i] = updated;
    notifyListeners();
    await _persist(groups: true);
  }

  /// Deletes a group; its member categories become ungrouped ("Other").
  /// Budgets are untouched — they reference category ids, not groups.
  Future<void> deleteGroup(String id) async {
    _groups.removeWhere((g) => g.id == id);
    _groupAssignments.removeWhere((_, gid) => gid == id);
    notifyListeners();
    await _persist(groups: true);
  }

  /// Assigns [categoryId] to [groupId]; null unassigns it.
  Future<void> assignCategoryToGroup(String categoryId, String? groupId) async {
    if (groupId == null) {
      if (_groupAssignments.remove(categoryId) == null) return;
    } else {
      if (_groupAssignments[categoryId] == groupId) return;
      _groupAssignments[categoryId] = groupId;
    }
    notifyListeners();
    await _persist(groups: true);
  }

  // --- Spend budgets --------------------------------------------------------

  List<SpendBudget> get budgets => List.unmodifiable(_budgets);

  Future<String> addBudget({
    required String name,
    required double limit,
    required BudgetMode mode,
    required Set<String> categoryIds,
  }) async {
    final id = 'bud_${DateTime.now().microsecondsSinceEpoch}';
    _budgets.add(
      SpendBudget(
        id: id,
        name: name.trim(),
        limit: limit,
        mode: mode,
        categoryIds: {...categoryIds},
      ),
    );
    notifyListeners();
    await _persist(budgets: true);
    return id;
  }

  Future<void> updateBudget(SpendBudget updated) async {
    if (!_budgets.any((b) => b.id == updated.id)) return;
    // Clear the fired-alert marker BEFORE notifying: the budget monitor is
    // a provider listener, so notify-first let it fire against the new
    // limit + old marker, record a level, and then have a later clear
    // erase that record — the identical alert fired again on the next
    // change.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(customBudgetAlertKey(updated.id, DateTime.now()));
    // Re-lookup AFTER the awaits: an index captured before them could point
    // at a different (or removed) budget if a delete/clear/import landed in
    // the gap — writing through the stale index silently overwrote a
    // still-live budget and persisted it.
    final i = _budgets.indexWhere((b) => b.id == updated.id);
    if (i == -1) return;
    _budgets[i] = updated;
    notifyListeners();
    await _persist(budgets: true);
  }

  Future<void> deleteBudget(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(customBudgetAlertKey(id, DateTime.now()));
    _budgets.removeWhere((b) => b.id == id);
    notifyListeners();
    await _persist(budgets: true);
  }

  /// Removes [id] from the group-assignment map and every budget's category
  /// set — called when a category disappears or stops being groupable.
  /// Returns which blobs changed so the caller persists only those.
  ({bool groups, bool budgets}) _detachCategory(String id) {
    final hadGroup = _groupAssignments.remove(id) != null;
    var budgetsChanged = false;
    for (var i = 0; i < _budgets.length; i++) {
      if (!_budgets[i].categoryIds.contains(id)) continue;
      _budgets[i] = _budgets[i].copyWith(
        categoryIds: {..._budgets[i].categoryIds}..remove(id),
      );
      budgetsChanged = true;
    }
    return (groups: hadGroup, budgets: budgetsChanged);
  }

  // --- Import rules -----------------------------------------------------

  /// Adds the built-in keyword classifications as editable rules, skipping
  /// patterns the user already has. Appended after any existing user rules
  /// so user rules keep priority (first match wins). Called from first-run
  /// seeding in [load] and from [clearAll] with `includeConfig`.
  void _seedDefaultRules() {
    final existing = _rules.map((r) => r.pattern.toLowerCase()).toSet();
    kDefaultKeywordCategories.forEach((pattern, categoryId) {
      if (existing.contains(pattern)) return;
      _rules.add(
        ClassifierRule(
          id: 'builtin_${pattern.replaceAll(' ', '_')}',
          pattern: pattern,
          categoryId: categoryId,
        ),
      );
    });
  }

  /// The starter Needs/Wants parent groups with their default assignments.
  void _seedDefaultGroups() {
    _groups.addAll(const [
      CategoryGroup(id: 'grp_needs', label: 'Needs', color: FigmaPalette.blue),
      CategoryGroup(
        id: 'grp_wants',
        label: 'Wants',
        color: FigmaPalette.purple,
      ),
    ]);
    _groupAssignments.addAll(const {
      'food': 'grp_needs',
      'transport': 'grp_needs',
      'bills': 'grp_needs',
      'health': 'grp_needs',
      'education': 'grp_needs',
      'shopping': 'grp_wants',
      'entertainment': 'grp_wants',
    });
  }

  static String _importRuleSlug(String pattern) =>
      pattern.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  static String _builtinImportRuleId(String pattern, ImportRuleKind kind) =>
      'builtin_${kind == ImportRuleKind.ignore ? 'ignore' : 'spam'}'
      '_${_importRuleSlug(pattern)}';

  /// Adds any built-in ignore/spam rules not already present (matched by id).
  void _seedDefaultImportRules() {
    final existingIds = _importRules.map((r) => r.id).toSet();
    void seed(List<String> patterns, ImportRuleKind kind) {
      for (final pattern in patterns) {
        final id = _builtinImportRuleId(pattern, kind);
        if (existingIds.contains(id)) continue;
        _importRules.add(ImportRule(id: id, pattern: pattern, kind: kind));
      }
    }

    seed(kDefaultIgnorePhrases, ImportRuleKind.ignore);
    seed(kDefaultSpamSignals, ImportRuleKind.spamSignal);
  }

  /// Import rules only gate future scans — no retroactive application.
  Future<void> addImportRule(String pattern, ImportRuleKind kind) async {
    _importRules.insert(
      0,
      ImportRule(id: _newId(), pattern: pattern.trim(), kind: kind),
    );
    notifyListeners();
    await _persist(importRules: true);
  }

  Future<void> updateImportRule(ImportRule updated) async {
    final i = _importRules.indexWhere((r) => r.id == updated.id);
    if (i == -1) return;
    _importRules[i] = updated;
    notifyListeners();
    await _persist(importRules: true);
  }

  Future<void> deleteImportRule(String id) async {
    _importRules.removeWhere((r) => r.id == id);
    notifyListeners();
    await _persist(importRules: true);
  }

  /// The undo half of [deleteImportRule]; [index] restores the old position
  /// for the same priority reason as [restoreRule].
  Future<void> restoreImportRule(ImportRule rule, int index) async {
    if (_importRules.any((r) => r.id == rule.id)) return;
    _importRules.insert(index.clamp(0, _importRules.length), rule);
    notifyListeners();
    await _persist(importRules: true);
  }

  /// Re-adds deleted built-ins and resets edited ones to their default
  /// pattern/kind. User-created rules are left untouched.
  Future<void> restoreDefaultImportRules() async {
    _importRules.removeWhere((r) => r.isBuiltIn);
    _seedDefaultImportRules();
    notifyListeners();
    await _persist(importRules: true);
  }

  // --- Accounts -------------------------------------------------------------

  /// acctKey → accountId, rebuilt on any account mutation.
  final Map<String, String> _keyIndex = {};

  void _rebuildKeyIndex() {
    _keyIndex.clear();
    for (final a in _accounts) {
      for (final k in a.keys) {
        _keyIndex[k] = a.id;
      }
    }
  }

  /// accountId → account. Cache-scoped rather than a long-lived field: account
  /// edits replace the `Account` object in `_accounts`, so a persistent map
  /// would silently hand out stale copies. This one dies with every notify.
  ///
  /// Resolving an account used to be a linear scan of `_accounts`, which the
  /// transaction filter performs once *per transaction*.
  Map<String, Account> get _accountsById =>
      _d.accountById ??= {for (final a in _accounts) a.id: a};

  /// Creates an account owning [key] if none does yet. Card-ness only sets the
  /// type at creation — an existing account keeps whatever the user set.
  void _ensureAccount(String key, {required bool isCard}) {
    if (_keyIndex.containsKey(key)) return;
    final parts = key.split(':');
    final bankCode = parts.first;
    final last4 = parts.length > 1 ? parts.last : '';
    final acc = Account(
      id: _newAccountId(),
      name: Account.defaultName(bankCode, last4),
      type: isCard ? AccountType.creditCard : AccountType.bank,
      keys: {key},
    );
    _accounts.add(acc);
    _keyIndex[key] = acc.id;
  }

  /// Card/bank hints from a v9 backup's `acctKinds` map, set by [importData]
  /// for the duration of its `_ensureAccountsForTransactions` call. Backups
  /// carry no SMS bodies, so this is the only card-ness evidence a restored
  /// orphan key has.
  Map<String, bool> _acctKindHints = const {};

  /// Auto-creates accounts for any transaction whose acctKey no account owns
  /// yet — used after imports (a v1 backup or CSV may carry keys but no
  /// accounts). Card-ness comes from the backup's acctKinds hint when
  /// present, else is re-derived from the stored SMS body.
  void _ensureAccountsForTransactions() {
    for (final t in _transactions) {
      final key = t.acctKey;
      if (key == null || _keyIndex.containsKey(key)) continue;
      // `manual:<txId>` keys only ever mean "hand-assigned on the device
      // that minted them" — auto-creating from one (e.g. rows arriving via
      // CSV) produces a junk account literally named "manual ••17583…".
      if (key.startsWith('manual:')) continue;
      final (_, derivedCard) = SmsTxnParser.accountKeyOf(t.sender, t.smsText);
      _ensureAccount(key, isCard: _acctKindHints[key] ?? derivedCard);
    }
  }

  Account? accountForKey(String? key) {
    if (key == null) return null;
    final id = _keyIndex[key];
    return id == null ? null : _accountsById[id];
  }

  Account? accountById(String id) => _accountsById[id];

  /// accountId → its confirmed transactions, oldest first (so index order is
  /// also `(date, insertionIndex)` order). Built once per notification.
  Map<String, List<Tx>> get _byAccount => _d.byAccount ??= () {
    final map = <String, List<Tx>>{};
    for (final (t, _) in _ordered) {
      final id = _keyIndex[t.acctKey];
      if (id == null) continue;
      (map[id] ??= []).add(t);
    }
    return map;
  }();

  /// Confirmed transactions belonging to [accountId], newest first.
  List<Tx> transactionsForAccount(String accountId) =>
      (_byAccount[accountId] ?? const <Tx>[]).reversed.toList();

  /// How many confirmed transactions belong to [accountId] — no copy, no sort.
  int transactionCountForAccount(String accountId) =>
      _byAccount[accountId]?.length ?? 0;

  /// Every figure for one account, from a single pass over its transactions.
  ///
  /// The model is **anchor + everything since**: the newest authoritative
  /// figure (the user-entered one, or the latest SMS-stated `Avl Bal` /
  /// `Avl Lmt`) plus the ledger movement recorded after it. The anchoring
  /// transaction itself is excluded — the figure its SMS stated already
  /// includes its own effect.
  /// Cache key carries the calendar month: the figures embed "spent this
  /// month", and an app left open across midnight on the 1st would otherwise
  /// keep serving the old month's number until some mutation notified.
  _AccountFigures _figures(Account account) {
    final now = DateTime.now();
    final key = '${account.id}|${now.year * 12 + now.month}';
    return _d.accountFigures[key] ??= _computeFigures(account);
  }

  _AccountFigures _computeFigures(Account account) {
    // Resolve to the canonical instance: figures are cached per id, so reading
    // creditLimit/manualBalance off a caller's (possibly stale) copy would let
    // the first caller's values be served to everyone else this cycle.
    final acc = _accountsById[account.id] ?? account;
    final all = _byAccount[acc.id] ?? const <Tx>[];
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month);
    final monthEnd = DateTime(now.year, now.month + 1);

    // Rows dated beyond TODAY are excluded from balance math: they are
    // either mis-dated (a due date an older build read as the transaction
    // date — "EMI debited… next due on 05-09-26") or deliberate bookkeeping
    // (a salary re-dated to the 1st of next month). Left in, such a row
    // out-ranks every newer bank figure AND any manually set balance, and
    // its amount pre-counts movement whose date hasn't arrived. They join
    // the figures when their day comes. Rows dated later TODAY still count
    // — bank server clocks run minutes ahead of the phone.
    final endOfToday = DateTime(now.year, now.month, now.day + 1);
    final txs = [
      for (final t in all)
        if (t.date.isBefore(endOfToday)) t,
    ];

    // On a savings/asset account a transfer runs the opposite way to its
    // TxType: the expense-typed "To savings" debit left the *bank*, but HERE
    // it is a deposit (+); an income-typed transfer back to the bank is a
    // withdrawal (−). Non-transfer rows (interest income, fees) keep their
    // natural sign, as does everything on bank/card accounts.
    final invertTransfers = acc.type == AccountType.savings;
    double signed(Tx t) {
      final v = t.type == TxType.income ? t.amount : -t.amount;
      return (invertTransfers && isTransferCategory(t.categoryId)) ? -v : v;
    }

    // `txs` is oldest-first, so the last stated figure seen is the newest.
    Tx? anchor;
    var anchorIndex = -1;
    double? maxSeen;
    var ledgerTotal = 0.0;
    var spentThisMonth = 0.0;
    for (var i = 0; i < txs.length; i++) {
      final t = txs[i];
      ledgerTotal += signed(t);
      if (t.balanceAfter != null) {
        anchor = t;
        anchorIndex = i;
        if (maxSeen == null || t.balanceAfter! > maxSeen) {
          maxSeen = t.balanceAfter;
        }
      }
    }
    // Transfers are not "spent": a deposit into this savings account, a
    // card-bill payment from a bank account, money moved to savings — none
    // of it left the user. The dashboard's Spent card excludes transfers;
    // this tile must agree with it — over ALL rows in the month window, not
    // the balance-filtered list: the Spent card applies no date-vs-now
    // filter, so neither may this.
    for (final t in all) {
      if (t.type == TxType.expense &&
          !isTransferCategory(t.categoryId) &&
          !t.date.isBefore(monthStart) &&
          t.date.isBefore(monthEnd)) {
        // Group splits: only the user's own share, like the Spent card.
        spentThisMonth += t.spendAmount;
      }
    }

    var deltaAfterAnchor = 0.0;
    for (var i = anchorIndex + 1; i < txs.length; i++) {
      deltaAfterAnchor += signed(txs[i]);
    }

    // A manual figure with no timestamp (possible in a hand-edited or older
    // backup) counts as the oldest possible, never the newest — reading it as
    // "newer" used to dereference a null and crash every balance read.
    // Future-DAY anchors can't reach this comparison (the endOfToday filter
    // above drops them), and a same-day anchor timestamped minutes ahead is
    // a genuinely fresh bank statement — it correctly out-ranks an older
    // manual figure.
    final manualAt = acc.manualBalanceAt;
    final manualIsNewer =
        acc.manualBalance != null &&
        manualAt != null &&
        (anchor == null || manualAt.isAfter(anchor.date));

    var deltaAfterManual = 0.0;
    if (manualIsNewer) {
      for (final t in txs) {
        if (!t.date.isAfter(manualAt)) continue;
        deltaAfterManual += signed(t);
      }
    }

    final limitIsEstimated = acc.creditLimit == null;
    final limit = acc.creditLimit ?? maxSeen;

    final double balance;
    final BalanceSource balanceSource;
    final DateTime? balanceAsOf;
    if (manualIsNewer) {
      balance = acc.manualBalance! + deltaAfterManual;
      balanceSource = BalanceSource.manual;
      balanceAsOf = manualAt;
    } else if (anchor != null) {
      balance = anchor.balanceAfter! + deltaAfterAnchor;
      balanceSource = BalanceSource.alert;
      balanceAsOf = anchor.date;
    } else {
      balance = ledgerTotal;
      balanceSource = BalanceSource.ledger;
      balanceAsOf = null;
    }

    // An SMS states the *available* limit, never the total. Without a
    // user-entered total the app can only guess it as the largest available
    // figure ever seen — which is right only if the card was fully cleared at
    // some point in the history. Paying a bill *raises* the available limit, so
    // a payment alert is normally the largest figure on record; the guess then
    // equals the newest figure and `limit − available` collapses to exactly 0.
    // That is not "nothing owed", it is "unknowable" — say so instead of
    // reporting a confident zero.
    final limitCollapsed =
        limitIsEstimated && anchor != null && anchor.balanceAfter == maxSeen;

    final double? outstanding;
    if (manualIsNewer) {
      outstanding = (acc.manualBalance! - deltaAfterManual).clamp(
        0,
        double.infinity,
      );
    } else if (limit == null || anchor == null || limitCollapsed) {
      outstanding = null;
    } else {
      outstanding = (limit - anchor.balanceAfter! - deltaAfterAnchor).clamp(
        0,
        double.infinity,
      );
    }

    return _AccountFigures(
      balance: balance,
      balanceSource: balanceSource,
      balanceAsOf: balanceAsOf,
      creditLimit: limit,
      limitIsEstimated: limitIsEstimated,
      outstanding: outstanding,
      // Always the exact complement of outstanding, so the two figures shown
      // on a card can never contradict each other.
      available: (limit == null || outstanding == null)
          ? null
          : (limit - outstanding).clamp(0, double.infinity),
      spentThisMonth: spentThisMonth,
      // The full count, mis-dated rows included — the tile's "N txns" must
      // match what the transaction list shows.
      txCount: all.length,
    );
  }

  /// Where [accountBalance] currently comes from, and the moment it was
  /// stated: the user's manual entry, a bank alert, or plain ledger
  /// arithmetic.
  (BalanceSource, DateTime?) accountBalanceProvenance(Account account) {
    final f = _figures(account);
    return (f.balanceSource, f.balanceAsOf);
  }

  /// Bank / savings balance. See [_computeFigures] for the model.
  double accountBalance(Account account) => _figures(account).balance;

  /// Card available limit, or null when the outstanding is unknowable.
  double? accountAvailable(Account account) => _figures(account).available;

  /// Effective total credit limit: the user-set value, else the largest
  /// available-limit ever reported. Pending imports are excluded — an
  /// unreviewed message must not move the estimate.
  double? accountCreditLimit(Account account) => _figures(account).creditLimit;

  /// True when [accountCreditLimit] is a guess rather than a user-entered
  /// figure.
  bool creditLimitIsEstimated(Account account) =>
      _figures(account).limitIsEstimated;

  /// Card outstanding, or null when it cannot be determined — see
  /// [_computeFigures]. Callers should prompt for the real credit limit rather
  /// than render a zero.
  double? accountOutstanding(Account account) => _figures(account).outstanding;

  /// Cards whose amount owed is unknowable until the user enters their total
  /// credit limit. Surfaced in the balance breakdown so the headline figure
  /// isn't silently optimistic.
  int get cardsMissingLimit => _accounts
      .where((a) => !a.isClosed && a.isCard && accountOutstanding(a) == null)
      .length;

  // Closed accounts are skipped from every total below: a matured FD's last
  // stated value must not keep inflating the figures the user reads as
  // "money I have now".

  /// Sum of liquid bank-account balances (bank-stated where available).
  /// Savings/asset accounts are excluded — they are not spendable cash.
  double get bankBalanceTotal => _accounts
      .where((a) => !a.isClosed && a.type == AccountType.bank)
      .fold(0.0, (s, a) => s + accountBalance(a));

  /// Sum of savings/asset account values (RD, FD, stocks, gold…). Tracked
  /// separately because it is not liquid.
  double get savingsBalanceTotal => _accounts
      .where((a) => !a.isClosed && a.type == AccountType.savings)
      .fold(0.0, (s, a) => s + accountBalance(a));

  /// Sum of credit-card outstanding amounts (0 where unknown — see
  /// [cardsMissingLimit], which counts what this is silently omitting).
  double get cardOutstandingTotal => _accounts
      .where((a) => !a.isClosed && a.isCard)
      .fold(0.0, (s, a) => s + (accountOutstanding(a) ?? 0));

  /// Liquid money on hand: bank balances minus card outstanding. Savings/
  /// asset accounts are NOT included — they aren't spendable. The
  /// authoritative figure once accounts exist, since bank-stated balances
  /// don't depend on the SMS history being complete.
  double get netWorth => bankBalanceTotal - cardOutstandingTotal;

  /// This-month spend on the account (expenses only).
  double accountSpentThisMonth(Account account) =>
      _figures(account).spentThisMonth;

  /// Creates an account by hand (no keys yet — link numbers via
  /// [addAccountKey]). Returns the new account's id.
  Future<String> addAccount({
    required String name,
    required AccountType type,
    double? creditLimit,
    String? kind,
    String? kindIcon,
  }) async {
    final acc = Account(
      id: _newAccountId(),
      name: name.trim(),
      type: type,
      keys: {},
      creditLimit: creditLimit,
      kind: kind,
      kindIcon: kindIcon,
    );
    _accounts.add(acc);
    notifyListeners();
    await _persist(accounts: true);
    return acc.id;
  }

  /// Custom kind label + icon for a savings/asset account ("Stocks",
  /// "Gold"…). Null [kind] clears both back to the generic Savings look.
  Future<void> setAccountKind(
    String id,
    String? kind, {
    String? kindIcon,
  }) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1) return;
    _accounts[i] = (kind == null || kind.trim().isEmpty)
        ? _accounts[i].copyWith(clearKind: true)
        : _accounts[i].copyWith(kind: kind.trim(), kindIcon: kindIcon);
    notifyListeners();
    await _persist(accounts: true);
  }

  /// Links an account/card number key (`"BANK:1234"`) to [accountId] so SMS
  /// carrying that fragment resolve to it — past transactions included.
  /// Returns false when another account already owns the key.
  Future<bool> addAccountKey(String accountId, String key) async {
    final k = key.trim().toUpperCase();
    final owner = _keyIndex[k];
    if (owner != null && owner != accountId) return false;
    final i = _accounts.indexWhere((a) => a.id == accountId);
    if (i == -1) return false;
    _accounts[i] = _accounts[i].copyWith(keys: {..._accounts[i].keys, k});
    _keyIndex[k] = accountId;
    notifyListeners();
    await _persist(accounts: true);
    return true;
  }

  /// Unlinks a number from an account; matching transactions become
  /// unassigned (or get re-adopted by a future auto-created account).
  Future<void> removeAccountKey(String accountId, String key) async {
    final i = _accounts.indexWhere((a) => a.id == accountId);
    if (i == -1) return;
    final keys = {..._accounts[i].keys}..remove(key);
    _accounts[i] = _accounts[i].copyWith(keys: keys);
    _rebuildKeyIndex();
    notifyListeners();
    await _persist(accounts: true);
  }

  Future<void> renameAccount(String id, String name) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1) return;
    _accounts[i] = _accounts[i].copyWith(name: name.trim());
    notifyListeners();
    await _persist(accounts: true);
  }

  Future<void> setAccountType(String id, AccountType type) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1) return;
    _accounts[i] = _accounts[i].copyWith(type: type);
    notifyListeners();
    await _persist(accounts: true);
  }

  Future<void> setCreditLimit(String id, double? limit) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1) return;
    // A zero/negative limit isn't a limit: outstanding would clamp to 0
    // and the tile reads "₹0 owed" while money is genuinely owed. Clearing
    // is expressed with null only.
    if (limit != null && (!limit.isFinite || limit <= 0)) return;
    _accounts[i] = limit == null
        ? _accounts[i].copyWith(clearCreditLimit: true)
        : _accounts[i].copyWith(creditLimit: limit);
    notifyListeners();
    await _persist(accounts: true);
  }

  /// Savings goal target. Null clears; zero/negative/non-finite rejected —
  /// a ₹0 goal would render as instantly "reached".
  Future<void> setSavingsGoal(String id, double? amount) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1) return;
    if (amount != null && (!amount.isFinite || amount <= 0)) return;
    _accounts[i] = amount == null
        ? _accounts[i].copyWith(clearGoalAmount: true)
        : _accounts[i].copyWith(goalAmount: amount);
    notifyListeners();
    await _persist(accounts: true);
  }

  /// Card billing cycle: statement day and payment due day of month. Null
  /// clears the respective day; values outside 1–31 are rejected.
  Future<void> setCardCycle(String id, {int? statementDay, int? dueDay}) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1) return;
    bool bad(int? d) => d != null && (d < 1 || d > 31);
    if (bad(statementDay) || bad(dueDay)) return;
    _accounts[i] = _accounts[i].copyWith(
      statementDay: statementDay,
      clearStatementDay: statementDay == null,
      dueDay: dueDay,
      clearDueDay: dueDay == null,
    );
    notifyListeners();
    await _persist(accounts: true);
  }

  /// User-entered balance (banks) / outstanding (cards). Stamped with "now"
  /// so a later SMS-reported figure takes over again. Null clears it.
  Future<void> setManualBalance(String id, double? value) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1) return;
    _accounts[i] = value == null
        ? _accounts[i].copyWith(clearManualBalance: true)
        : _accounts[i].copyWith(
            manualBalance: value,
            manualBalanceAt: DateTime.now(),
          );
    notifyListeners();
    await _persist(accounts: true);
  }

  /// Closes an account: it leaves [openAccounts] (lists, pickers, totals)
  /// but keeps its identity and keys, so existing transactions still resolve
  /// and a late SMS (an FD interest credit) still lands on it instead of
  /// spawning a duplicate account. The inverse of [reopenAccount].
  Future<void> closeAccount(String id) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1 || _accounts[i].isClosed) return;
    _accounts[i] = _accounts[i].copyWith(closedAt: DateTime.now());
    notifyListeners();
    await _persist(accounts: true);
  }

  Future<void> reopenAccount(String id) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1 || !_accounts[i].isClosed) return;
    _accounts[i] = _accounts[i].copyWith(clearClosedAt: true);
    notifyListeners();
    await _persist(accounts: true);
  }

  /// Folds [sourceId] into [targetId]: the target absorbs all of the source's
  /// keys (so its transactions resolve to the target) and the source is
  /// removed. Transactions are never rewritten.
  Future<void> mergeAccounts(String sourceId, String targetId) async {
    if (sourceId == targetId) return;
    final si = _accounts.indexWhere((a) => a.id == sourceId);
    final ti = _accounts.indexWhere((a) => a.id == targetId);
    if (si == -1 || ti == -1) return;
    final merged = {..._accounts[ti].keys, ..._accounts[si].keys};
    _accounts[ti] = _accounts[ti].copyWith(keys: merged);
    _accounts.removeAt(si);
    _rebuildKeyIndex();
    notifyListeners();
    await _persist(accounts: true);
  }

  /// Deletes an account. Its transactions remain but become unassigned
  /// (their acctKey no longer resolves to any account).
  Future<void> deleteAccount(String id) async {
    _accounts.removeWhere((a) => a.id == id);
    _rebuildKeyIndex();
    notifyListeners();
    await _persist(accounts: true);
  }

  /// Assigns a transaction to [accountId], moving ONLY that transaction.
  ///
  /// It used to hand the target account the transaction's own acctKey. For an
  /// SMS entry that key (`"ICICI:879"`) is shared by every alert about that
  /// real-world account — so reassigning one transaction silently rerouted
  /// all of them, past and future, to the chosen account. A synthetic
  /// per-transaction key moves exactly one row and nothing else.
  ///
  /// The SMS-stated balance is dropped on a move: it described the account
  /// the alert was about, and as an anchor it would overwrite the target
  /// account's balance with another bank's figure.
  Future<void> assignAccount(String txId, String accountId) async {
    final ti = _transactions.indexWhere((t) => t.id == txId);
    final ai = _accounts.indexWhere((a) => a.id == accountId);
    if (ti == -1 || ai == -1) return;
    if (!_assignInPlace(ti, ai)) return;
    notifyListeners();
    await _persist(tx: true, accounts: true);
  }

  /// The move itself, shared by [assignAccount] and [assignAccountToMany].
  /// Returns false when the transaction already resolves to the target.
  /// Caller is responsible for notifyListeners + _persist.
  bool _assignInPlace(int ti, int ai) {
    final t = _transactions[ti];
    final accountId = _accounts[ai].id;
    // Already resolves there — leave the key structure untouched.
    if (t.acctKey != null && _keyIndex[t.acctKey] == accountId) return false;
    final key = 'manual:${t.id}';
    // A previous by-hand assignment may have parked this synthetic key in
    // another account's key set; retract it so exactly one account owns it.
    if (t.acctKey == key) {
      final prev = _accounts.indexWhere((a) => a.keys.contains(key));
      if (prev != -1 && _accounts[prev].id != accountId) {
        _accounts[prev] = _accounts[prev].copyWith(
          keys: {..._accounts[prev].keys}..remove(key),
        );
      }
    }
    // The stated "Avl Bal" describes the account the SMS was about. It may
    // only travel with the move when that account IS the target — i.e. the
    // key this row's own SMS derives is owned by the target account. A null
    // or foreign derivation means the figure belongs to some other account
    // and must not become an anchor on this one.
    var keepBalance = false;
    if (t.balanceAfter != null) {
      final (derivedKey, _) = SmsTxnParser.accountKeyOf(t.sender, t.smsText);
      keepBalance =
          derivedKey != null && _accounts[ai].keys.contains(derivedKey);
    }
    _transactions[ti] = t.copyWith(
      acctKey: key,
      clearBalanceAfter: !keepBalance,
    );
    _accounts[ai] = _accounts[ai].copyWith(keys: {..._accounts[ai].keys, key});
    _keyIndex[key] = accountId;
    return true;
  }

  // --- Bulk edits -------------------------------------------------------

  /// Applies [categoryId] to every transaction in [ids] whose type matches
  /// the category's type — an expense category cannot land on an income row.
  /// Returns how many rows changed.
  Future<int> setCategoryForMany(Set<String> ids, String categoryId) async {
    final catType = categoryById(categoryId).type;
    // Shares only exist on expense-typed non-transfer rows — the same
    // invariant deleteCategory's move-to branch and _sanitizeMyShare
    // enforce. Without this, bulk-moving a split row into "To savings"
    // kept a stale share that resurfaced if the row later moved back.
    final clearShare = isTransferCategory(categoryId);
    var changed = 0;
    for (var i = 0; i < _transactions.length; i++) {
      final t = _transactions[i];
      if (!ids.contains(t.id) || t.type != catType) continue;
      if (t.categoryId == categoryId) continue;
      _transactions[i] = t.copyWith(
        categoryId: categoryId,
        userCategorized: true,
        clearMyShare: clearShare && t.myShare != null,
      );
      changed++;
    }
    if (changed > 0) {
      notifyListeners();
      await _persist(tx: true);
    }
    return changed;
  }

  /// Bulk [assignAccount] — one notification and one write for the whole
  /// selection. Returns how many rows actually moved.
  Future<int> assignAccountToMany(Set<String> ids, String accountId) async {
    final ai = _accounts.indexWhere((a) => a.id == accountId);
    if (ai == -1) return 0;
    var changed = 0;
    for (var i = 0; i < _transactions.length; i++) {
      if (!ids.contains(_transactions[i].id)) continue;
      if (_assignInPlace(i, ai)) changed++;
    }
    if (changed > 0) {
      notifyListeners();
      await _persist(tx: true, accounts: true);
    }
    return changed;
  }

  /// Stamps the same date and time on every transaction in [ids]. Returns
  /// how many rows changed.
  Future<int> setDateTimeForMany(Set<String> ids, DateTime dateTime) async {
    var changed = 0;
    for (var i = 0; i < _transactions.length; i++) {
      final t = _transactions[i];
      if (!ids.contains(t.id) || t.date == dateTime) continue;
      // Day moves drop the stated "Avl Bal" — see updateTransaction: an
      // anchor re-dated away from its SMS's moment corrupts the balance.
      final dayChanged =
          t.date.year != dateTime.year ||
          t.date.month != dateTime.month ||
          t.date.day != dateTime.day;
      _transactions[i] = t.copyWith(
        date: dateTime,
        clearBalanceAfter: dayChanged && t.balanceAfter != null,
      );
      changed++;
    }
    if (changed > 0) {
      notifyListeners();
      await _persist(tx: true);
    }
    return changed;
  }

  /// Re-evaluates every SMS transaction against the full rule list after a
  /// rule is added or edited, so changes take effect retroactively with the
  /// same first-match-wins priority imports use. Messages matching no rule
  /// keep their current category (they may have been set by hand). Spam
  /// rules drop pending matches only; confirmed entries were already
  /// reviewed by the user and are never auto-removed.
  /// Caller is responsible for notifyListeners + _persist.
  /// Returns what actually happened so callers can tell the user — a
  /// too-broad new spam rule used to wipe the whole review queue with no
  /// feedback and no count. The dropped rows themselves come back too, so
  /// the screen can offer Undo: re-scans are incremental past the SMS
  /// watermark, which makes the drop permanent otherwise.
  ({int reclassified, int droppedPending, List<Tx> dropped})
  _reapplyRulesToHistory() {
    var reclassified = 0;
    final dropped = <Tx>[];
    for (var i = _transactions.length - 1; i >= 0; i--) {
      final t = _transactions[i];
      if (t.source != TxSource.sms) continue;
      // A category the user picked by hand always wins over rules.
      if (t.userCategorized) continue;
      // Backups strip SMS bodies, so restored rows have no text to match
      // against. Skip them rather than fall back to the sender — classifier
      // patterns running against DLT sender codes ("hdfc" vs "VM-HDFCBK")
      // would mass-reclassify restored history.
      final text = t.smsText;
      if (text.isEmpty) continue;
      final rule = _matchRule(text, t.type);
      if (rule == null) continue;
      if (rule.isSpamRule) {
        if (t.pending) {
          _transactions.removeAt(i);
          dropped.add(t);
        }
      } else if (t.categoryId != rule.categoryId) {
        _transactions[i] = t.copyWith(categoryId: rule.categoryId);
        reclassified++;
      }
    }
    return (
      reclassified: reclassified,
      droppedPending: dropped.length,
      dropped: dropped,
    );
  }

  // --- SMS import -----------------------------------------------------------

  /// Adds parsed SMS transactions as pending entries, skipping duplicates and
  /// rule-confirmed spam. Returns (added, confirmedSpamDropped).
  ///
  /// Rule handling: a matching spam rule drops the message entirely; a
  /// matching category rule overrides the parser's category guess and clears
  /// any spam suspicion (an explicit user rule outranks the heuristic) —
  /// income rules only apply to income, expense rules to expenses.
  ///
  /// Duplicate rules: same bank reference id + same direction always wins;
  /// without a ref, same type + amount with a date within 3 minutes is
  /// treated as the same bank alert sent twice. Fuzzy matching is only used to *skip* an import —
  /// never to touch existing user data.
  Future<(int, int)> addImported(List<ParsedTxn> parsed) async {
    var added = 0;
    var spamDropped = 0;
    // Duplicate lookups, built once per batch — a linear scan of the ledger
    // per parsed message made a year-long backfill against a 10k-row ledger
    // cost tens of millions of comparisons.
    //
    // Ref matching pairs the bank reference with the direction: both sides
    // of a credit-card bill payment (bank-side debit, issuer-side credit)
    // often quote the same reference — they are two different transactions,
    // not duplicates. A transaction without a ref is never a ref-match, so
    // it won't block a genuinely new message from the same bank.
    //
    // The fuzzy bucket (same type + amount + sender, dates compared within
    // the bucket) treats a matching alert within 3 minutes as the same bank
    // message sent twice; sender prevents cross-bank collisions (two banks
    // sending ₹500 alerts within 3 minutes). Every existing row goes in the
    // bucket — carrying a ref does not exempt a row from fuzzy-blocking a
    // ref-less incoming copy of itself.
    final refKeys = <String>{};
    final fuzzyDates = <String, List<DateTime>>{};
    String fuzzyKeyOf(TxType type, double amount, String sender) =>
        '${type.name}|$amount|$sender';
    for (final t in _transactions) {
      if (t.externalRef != null) refKeys.add('${t.type.name}|${t.externalRef}');
      (fuzzyDates[fuzzyKeyOf(t.type, t.amount, t.sender)] ??= []).add(t.date);
    }
    for (final p in parsed) {
      final ruleText = p.rawBody.isNotEmpty ? p.rawBody : p.merchant;
      final rule = _matchRule(ruleText, p.type);
      if (rule != null && rule.isSpamRule) {
        spamDropped++;
        continue;
      }

      final bool isDuplicate;
      if (p.ref != null) {
        isDuplicate = refKeys.contains('${p.type.name}|${p.ref}');
      } else {
        final dates = fuzzyDates[fuzzyKeyOf(p.type, p.amount, p.sender)];
        isDuplicate =
            dates != null &&
            dates.any(
              (d) => d.difference(p.date).abs() <= const Duration(minutes: 3),
            );
      }
      if (isDuplicate) continue;

      var categoryId = p.categoryId;
      var suspectedSpam = p.spamSuspect;
      // _matchRule already guarantees the type agrees.
      if (rule != null && !rule.isSpamRule) {
        categoryId = rule.categoryId;
        // Only an explicit user rule outranks the spam heuristic; a seeded
        // keyword ("recharge") must not let promos skip the spam queue.
        if (!rule.isBuiltIn) suspectedSpam = false;
      }
      // The parser pairs its category guess with the parsed direction, but
      // built-ins are user-editable now: a flipped target (e.g. card_bill
      // made income) would mint rows violating tx.type == category.type on
      // every import. The parsed direction is authoritative — money really
      // moved that way — so re-target to the type-correct Other instead.
      if (categoryById(categoryId).type != p.type) {
        categoryId = p.type == TxType.expense
            ? 'other_expense'
            : 'other_income';
      }

      _transactions.add(
        Tx(
          id: _newId(),
          type: p.type,
          categoryId: categoryId,
          amount: p.amount,
          note: '',
          // Full SMS text so the original alert is always reviewable;
          // fall back to the extracted merchant for synthetic inputs.
          smsBody: p.rawBody.isNotEmpty ? p.rawBody : p.merchant,
          date: p.date,
          source: TxSource.sms,
          sender: p.sender,
          externalRef: p.ref,
          pending: true,
          suspectedSpam: suspectedSpam,
          acctKey: p.acctKey,
          balanceAfter: p.balanceAfter,
        ),
      );
      if (p.acctKey != null) _ensureAccount(p.acctKey!, isCard: p.isCard);
      // The new row must block later duplicates in this same batch, exactly
      // as it would have when the old code rescanned _transactions each time.
      if (p.ref != null) refKeys.add('${p.type.name}|${p.ref}');
      (fuzzyDates[fuzzyKeyOf(p.type, p.amount, p.sender)] ??= []).add(p.date);
      added++;
    }
    if (added > 0) {
      notifyListeners();
      await _persist(tx: true, accounts: true);
    }
    return (added, spamDropped);
  }

  Future<void> confirmTransaction(String id) async {
    final i = _transactions.indexWhere((t) => t.id == id);
    if (i == -1) return;
    _transactions[i] = _transactions[i].copyWith(pending: false);
    notifyListeners();
    await _persist(tx: true);
  }

  /// Imports transactions (e.g. from a CSV). With [replace] all existing
  /// transactions are replaced (goals stay); otherwise entries whose ids
  /// already exist are skipped. Returns how many were added.
  /// CSV rows carry `type` and `category` as independent columns; the app's
  /// invariant is `tx.type == category.type`. When the category is known,
  /// its type wins (a disagreeing row would count in filters but not in
  /// budget bars); an unknown category id is remapped to the row-type's
  /// "Other" so it can't render under the wrong direction. Must run on the
  /// main isolate — the category registry isn't visible to [compute].
  Tx _sanitizeImportedTx(Tx t) {
    // Amount validity is enforced at the parse boundaries (importData's
    // up-front loop, the CSV row guard) so a bad file is rejected before
    // any state changes — this sanitizer may run mid-mutation (sanitizeTail)
    // and must never throw. Non-throwing cleanses only:
    if (t.balanceAfter != null && !t.balanceAfter!.isFinite) {
      t = t.copyWith(clearBalanceAfter: true);
    }
    var tx = _sanitizeMyShare(t);
    final known = allCategories.any((c) => c.id == tx.categoryId);
    if (known) {
      final cat = categoryById(tx.categoryId);
      tx = tx.type == cat.type ? tx : tx.copyWith(type: cat.type);
      // Re-typing can turn an expense row into income — re-check the share.
      return _sanitizeMyShare(tx);
    }
    return tx.copyWith(
      categoryId: tx.type == TxType.expense ? 'other_expense' : 'other_income',
    );
  }

  /// Enforces the [Tx.myShare] invariant on imported rows: only expense-typed
  /// non-transfer rows may carry a share, and it must sit inside
  /// `[0, amount]` — a hand-edited CSV must not mint negative spend.
  Tx _sanitizeMyShare(Tx t) {
    final share = t.myShare;
    if (share == null) return t;
    // NaN survives clamp (every comparison is false) — clear it outright.
    if (!share.isFinite ||
        t.type != TxType.expense ||
        isTransferCategory(t.categoryId)) {
      return t.copyWith(clearMyShare: true);
    }
    final clamped = share.clamp(0.0, t.amount).toDouble();
    return clamped == share ? t : t.copyWith(myShare: clamped);
  }

  Future<int> importTransactions(List<Tx> txs, {required bool replace}) async {
    final sanitized = txs.map(_sanitizeImportedTx).toList();
    if (replace) {
      _transactions
        ..clear()
        ..addAll(sanitized);
      // Parity with importData's replace mode: stale accounts must not
      // survive a "replace everything" import.
      _accounts.clear();
      _rebuildKeyIndex();
      _ensureAccountsForTransactions();
      notifyListeners();
      await _persist(tx: true, accounts: true);
      return sanitized.length;
    }
    final ids = _transactions.map((t) => t.id).toSet();
    final fresh = sanitized.where((t) => !ids.contains(t.id)).toList();
    _transactions.addAll(fresh);
    if (fresh.isNotEmpty) {
      _ensureAccountsForTransactions();
      notifyListeners();
      await _persist(tx: true, accounts: true);
    }
    return fresh.length;
  }

  /// Deletes every transaction and account, plus the fired budget-alert
  /// markers — a stale `budget_alert_fired_…` key would otherwise suppress
  /// this month's alerts after the data that earned them is gone.
  ///
  /// With [includeConfig] the wipe also covers rules, import rules, groups,
  /// budgets, custom categories and built-in overrides, then reseeds the
  /// built-in defaults — a true factory reset.
  Future<void> clearAll({bool includeConfig = false}) async {
    _transactions.clear();
    _accounts.clear();
    _keyIndex.clear();
    final prefs = await SharedPreferences.getInstance();
    for (final key
        in prefs
            .getKeys()
            .where((k) => k.startsWith('budget_alert_fired_'))
            .toList()) {
      await prefs.remove(key);
    }
    if (includeConfig) {
      _rules.clear();
      _importRules.clear();
      _groups.clear();
      _groupAssignments.clear();
      _budgets.clear();
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
      // Reseed immediately (flags stay set) so the app keeps working
      // without a restart — built-ins are the factory state, not "empty".
      _seedDefaultRules();
      _seedDefaultImportRules();
      _seedDefaultGroups();
    }
    notifyListeners();
    await _persist(
      tx: true,
      accounts: true,
      rules: includeConfig,
      importRules: includeConfig,
      categories: includeConfig,
      overrides: includeConfig,
      groups: includeConfig,
      budgets: includeConfig,
    );
  }

  /// Full snapshot of stored data, suitable for JSON backup.
  ///
  /// Raw SMS bodies are deliberately excluded: they are bulky, privacy-heavy
  /// (they leave the device via Drive backups), and everything a restore
  /// needs — sender, ref, amounts, account links, card-ness — is exported as
  /// its own field. No export carries them: the CSV and PDF omit them too, so
  /// alert text never leaves the app.
  Map<String, dynamic> exportData() => {
    'app': 'expense_tracker',
    // v10: transactions may carry `myShare` (group splits).
    // v11: callers may add a 'settings' block (SettingsProvider.toBackupMap
    // — monthly cap, alert flags, auto-import cadence, theme); applied on
    // replace-mode restores only.
    'version': 11,
    'transactions': _transactions
        .map((t) => t.toJson()..remove('smsBody'))
        .toList(),
    'accounts': _accounts.map((a) => a.toJson()).toList(),
    // v9 addition: card/bank kind per SMS-derived account key. Bodies are
    // stripped from the export, so a restore can no longer derive card-ness
    // from the SMS — without this, an orphaned card key (account deleted
    // pre-export) would re-materialise as a BANK account and its
    // outstanding would inflate the restored net worth.
    'acctKinds': _acctKinds(),
    // v4 addition: without these, restoring on a fresh install left rows
    // pointing at unknown category ids (displayed as "Other").
    'categories': customCategories.map((c) => c.toJson()).toList(),
    // v6 additions: parent groups, their assignments, and spend budgets.
    'groups': _groups.map((g) => g.toJson()).toList(),
    'groupAssignments': Map<String, String>.from(_groupAssignments),
    'budgets': _budgets.map((b) => b.toJson()).toList(),
    // v7 addition: cosmetic edits to built-in categories.
    'builtinOverrides': builtinOverrides.values.map((c) => c.toJson()).toList(),
    // v8 additions: classifier and import rules — a restore used to lose
    // every user rule silently (built-ins reseed, so the Classifiers page
    // looked populated and the loss was invisible).
    'rules': _rules.map((r) => r.toJson()).toList(),
    'importRules': _importRules.map((r) => r.toJson()).toList(),
  };

  /// Card/bank kind for every SMS-derived account key in the ledger.
  /// Prefers the owning account's actual type; falls back to deriving from
  /// the SMS body (still present on-device); records nothing when there is
  /// no evidence either way.
  Map<String, String> _acctKinds() {
    final kinds = <String, String>{};
    for (final t in _transactions) {
      final key = t.acctKey;
      if (key == null || key.startsWith('manual:') || kinds.containsKey(key)) {
        continue;
      }
      final owner = accountForKey(key);
      final bool isCard;
      if (owner != null) {
        isCard = owner.type == AccountType.creditCard;
      } else if (t.smsText.isNotEmpty) {
        final (_, derived) = SmsTxnParser.accountKeyOf(t.sender, t.smsText);
        isCard = derived;
      } else {
        continue;
      }
      kinds[key] = isCard ? 'card' : 'bank';
    }
    return kinds;
  }

  /// Restores data from an [exportData]-shaped map.
  ///
  /// With [replace] everything is overwritten; otherwise entries are merged,
  /// skipping ids that already exist. Returns transactions added. Any
  /// `goals` from older backups are ignored (the feature was removed).
  /// Throws [FormatException] when the payload is not a valid backup.
  Future<int> importData(
    Map<String, dynamic> data, {
    required bool replace,
  }) async {
    final rawTx = data['transactions'];
    if (data['app'] != 'expense_tracker' || rawTx is! List) {
      throw const FormatException('Not an Expense Tracker backup file');
    }
    // Parse everything up front so a malformed entry rejects the whole file
    // instead of leaving a half-imported state.
    //
    // Pre-v5 backups stored the raw SMS body in `note`; move it into smsBody.
    // v5+ backups are trusted verbatim — an sms row there with an empty
    // smsBody and a non-empty note carries a genuine user note.
    final version = (data['version'] as num?)?.toInt() ?? 0;
    var txs = rawTx
        .map((e) => Tx.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    // Mirrors the CSV importer's amount guard: a non-finite amount poisons
    // every jsonEncode persist for the rest of the session, and a
    // non-positive one silently corrupts totals — reject the file up here,
    // BEFORE any state is touched, like every other malformed entry.
    for (final t in txs) {
      if (!t.amount.isFinite || t.amount <= 0) {
        throw const FormatException(
          'Backup contains a transaction with an invalid amount.',
        );
      }
    }
    if (version < 5) {
      txs = txs.map((t) => t.migrateSmsBodyFromNote()).toList();
    }
    // Accounts are a v2 addition — absent in older backups (defaults to none).
    final rawAccounts = data['accounts'];
    final accounts = rawAccounts is List
        ? rawAccounts
              .map((e) => Account.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList()
        : <Account>[];
    // Custom categories are a v4 addition — absent in older backups (null,
    // meaning "leave whatever the device already has").
    final rawCategories = data['categories'];
    final categories = rawCategories is List
        ? rawCategories
              .map(
                (e) => TxCategory.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList()
        : null;
    // Groups, assignments and budgets are v6 additions — absent in older
    // backups (null, meaning "leave whatever the device already has").
    final rawGroups = data['groups'];
    final importedGroups = rawGroups is List
        ? rawGroups
              .map(
                (e) =>
                    CategoryGroup.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList()
        : null;
    final rawAssignments = data['groupAssignments'];
    final importedAssignments = rawAssignments is Map
        ? Map<String, String>.from(rawAssignments)
        : null;
    final rawBudgets = data['budgets'];
    final importedBudgets = rawBudgets is List
        ? rawBudgets
              .map(
                (e) =>
                    SpendBudget.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList()
        : null;
    // Built-in overrides are a v7 addition. Ids that aren't built-ins are
    // dropped (a hand-edited file must not invent categories); since
    // built-ins became fully editable, type/transfer-ness is TRUSTED from
    // the file — except for the two fallback "Other" ids, whose structure
    // stays anchored to the definition.
    // Rules are a v8 addition — absent in older backups (null, meaning
    // "leave whatever the device already has").
    final rawRules = data['rules'];
    final importedRules = rawRules is List
        ? rawRules
              .map(
                (e) => ClassifierRule.fromJson(
                  Map<String, dynamic>.from(e as Map),
                ),
              )
              .toList()
        : null;
    final rawImportRules = data['importRules'];
    final importedImportRules = rawImportRules is List
        ? rawImportRules
              .map(
                (e) => ImportRule.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList()
        : null;
    final rawOverrides = data['builtinOverrides'];
    Map<String, TxCategory>? importedOverrides;
    if (rawOverrides is List) {
      importedOverrides = {};
      for (final e in rawOverrides) {
        final parsed = TxCategory.fromJson(Map<String, dynamic>.from(e as Map));
        final base = kCategories.where((c) => c.id == parsed.id).firstOrNull;
        if (base == null) continue;
        final structural = !isFallbackCategory(parsed.id);
        importedOverrides[parsed.id] = TxCategory(
          id: parsed.id,
          label: parsed.label,
          type: structural ? parsed.type : base.type,
          icon: parsed.icon,
          color: parsed.color,
          isTransfer: structural ? parsed.isTransfer : base.isTransfer,
        );
      }
    }

    // v9 addition: card/bank hints for SMS-derived account keys (bodies are
    // stripped, so this is the only card-ness evidence a restore has).
    final rawKinds = data['acctKinds'];
    final kindHints = <String, bool>{
      if (rawKinds is Map)
        for (final e in rawKinds.entries)
          if (e.value == 'card' || e.value == 'bank')
            '${e.key}': e.value == 'card',
    };

    // Drop assignment entries whose group doesn't exist after the import —
    // possible after a merge that skipped an incoming group.
    void sanitizeAssignments() {
      final ids = _groups.map((g) => g.id).toSet();
      _groupAssignments.removeWhere((_, gid) => !ids.contains(gid));
    }

    // Enforce the tx.type == category.type invariant (and remap unknown
    // category ids to the row-type "Other") on [rows] — the last [count]
    // entries of _transactions. Must run AFTER the category registry
    // reflects the backup, or valid custom-category rows would be remapped.
    void sanitizeTail(int count) {
      for (
        var i = _transactions.length - count;
        i < _transactions.length;
        i++
      ) {
        _transactions[i] = _sanitizeImportedTx(_transactions[i]);
      }
    }

    if (replace) {
      _transactions
        ..clear()
        ..addAll(txs);
      _accounts
        ..clear()
        ..addAll(accounts);
      if (categories != null) setCustomCategories(categories);
      if (importedOverrides != null) setBuiltinOverrides(importedOverrides);
      if (importedGroups != null) {
        _groups
          ..clear()
          ..addAll(importedGroups);
      }
      if (importedAssignments != null) {
        _groupAssignments
          ..clear()
          ..addAll(importedAssignments);
      }
      if (importedGroups != null || importedAssignments != null) {
        sanitizeAssignments();
      }
      if (importedBudgets != null) {
        _budgets
          ..clear()
          ..addAll(importedBudgets);
      }
      if (importedRules != null) {
        _rules
          ..clear()
          ..addAll(importedRules);
      }
      if (importedImportRules != null) {
        _importRules
          ..clear()
          ..addAll(importedImportRules);
      }
      // Registry is final now — safe to enforce the type/category invariant
      // (CSV imports get this via importTransactions; this path didn't).
      sanitizeTail(_transactions.length);
      _rebuildKeyIndex();
      _acctKindHints = kindHints;
      _ensureAccountsForTransactions();
      _acctKindHints = const {};
      notifyListeners();
      await _persist(
        tx: true,
        accounts: true,
        categories: categories != null,
        overrides: importedOverrides != null,
        groups: importedGroups != null || importedAssignments != null,
        budgets: importedBudgets != null,
        rules: importedRules != null,
        importRules: importedImportRules != null,
      );
      return txs.length;
    }

    final txIds = _transactions.map((t) => t.id).toSet();
    final acctIds = _accounts.map((a) => a.id).toSet();
    final newTxs = txs.where((t) => !txIds.contains(t.id)).toList();
    // Accounts carry a second identity — their key set. Ids are minted
    // per-device, so the same real account arrives from another device
    // under a fresh id; matching by id alone would append a duplicate whose
    // keys then steal every transaction from the device's account (the key
    // index is last-writer-wins). Fold key-overlapping imports into the
    // existing owner instead; the device account's name, balance and limit
    // stay authoritative, matching the merge convention everywhere else.
    final newAccounts = <Account>[];
    // Folding mutates an existing account in place, so the "anything
    // changed" gate below must see it — appended-list emptiness alone would
    // skip the key-index rebuild and the persist.
    var accountKeysFolded = false;
    for (final a in accounts) {
      if (acctIds.contains(a.id)) continue;
      final ownerIdx = _accounts.indexWhere((e) => e.keys.any(a.keys.contains));
      if (ownerIdx == -1) {
        newAccounts.add(a);
      } else if (!_accounts[ownerIdx].keys.containsAll(a.keys)) {
        _accounts[ownerIdx] = _accounts[ownerIdx].copyWith(
          keys: {..._accounts[ownerIdx].keys, ...a.keys},
        );
        accountKeysFolded = true;
      }
    }
    // Merge categories by id — existing definitions win, like tx/accounts.
    final catIds = customCategories.map((c) => c.id).toSet();
    final newCategories = [
      ...?categories?.where((c) => !catIds.contains(c.id)),
    ];
    // Merge groups/budgets by id (existing wins); assignments only fill
    // categories the device hasn't assigned itself.
    final groupIds = _groups.map((g) => g.id).toSet();
    final newGroups = [
      ...?importedGroups?.where((g) => !groupIds.contains(g.id)),
    ];
    final budgetIds = _budgets.map((b) => b.id).toSet();
    final newBudgets = [
      ...?importedBudgets?.where((b) => !budgetIds.contains(b.id)),
    ];
    // Rules merge by id, existing wins. Order is match priority: imported
    // user rules slot in at the END of the device's user segment (device
    // rules keep top priority) while imported built-in-id rules append at
    // the very end, mirroring where seeding would put them.
    final ruleIds = _rules.map((r) => r.id).toSet();
    final newRules = [...?importedRules?.where((r) => !ruleIds.contains(r.id))];
    final importRuleIds = _importRules.map((r) => r.id).toSet();
    final newImportRules = [
      ...?importedImportRules?.where((r) => !importRuleIds.contains(r.id)),
    ];
    // Overrides merge per built-in id — an existing device edit wins.
    final newOverrides = <String, TxCategory>{
      if (importedOverrides != null)
        for (final e in importedOverrides.entries)
          if (!isBuiltinOverridden(e.key)) e.key: e.value,
    };
    var assignmentsChanged = false;
    _transactions.addAll(newTxs);
    _accounts.addAll(newAccounts);
    if (newCategories.isNotEmpty) {
      setCustomCategories([...customCategories, ...newCategories]);
    }
    if (newOverrides.isNotEmpty) {
      // An incoming override can flip a built-in's direction (device had no
      // edit of its own for that id — device wins otherwise). Existing
      // LOCAL rows of that category must be re-typed, or they'd disagree
      // with the new definition; sanitizeTail below only covers the
      // appended rows.
      for (final e in newOverrides.entries) {
        if (categoryById(e.key).type != e.value.type) {
          _retypeRows(e.key, e.value.type);
        }
      }
      setBuiltinOverrides({...builtinOverrides, ...newOverrides});
    }
    _groups.addAll(newGroups);
    importedAssignments?.forEach((catId, gid) {
      if (_groupAssignments.containsKey(catId)) return;
      _groupAssignments[catId] = gid;
      assignmentsChanged = true;
    });
    if (newGroups.isNotEmpty || assignmentsChanged) sanitizeAssignments();
    _budgets.addAll(newBudgets);
    if (newRules.isNotEmpty) {
      final firstBuiltin = _rules.indexWhere((r) => r.isBuiltIn);
      final userEnd = firstBuiltin == -1 ? _rules.length : firstBuiltin;
      _rules.insertAll(userEnd, newRules.where((r) => !r.isBuiltIn));
      _rules.addAll(newRules.where((r) => r.isBuiltIn));
    }
    _importRules.addAll(newImportRules);
    final groupsChanged = newGroups.isNotEmpty || assignmentsChanged;
    if (newTxs.isNotEmpty ||
        newAccounts.isNotEmpty ||
        accountKeysFolded ||
        newCategories.isNotEmpty ||
        newOverrides.isNotEmpty ||
        groupsChanged ||
        newBudgets.isNotEmpty ||
        newRules.isNotEmpty ||
        newImportRules.isNotEmpty) {
      // Merged categories are registered above, so the invariant check sees
      // the final registry; only the appended rows are sanitized.
      sanitizeTail(newTxs.length);
      _rebuildKeyIndex();
      _acctKindHints = kindHints;
      _ensureAccountsForTransactions();
      _acctKindHints = const {};
      notifyListeners();
      await _persist(
        tx: true,
        accounts: true,
        categories: newCategories.isNotEmpty,
        overrides: newOverrides.isNotEmpty,
        groups: groupsChanged,
        budgets: newBudgets.isNotEmpty,
        rules: newRules.isNotEmpty,
        importRules: newImportRules.isNotEmpty,
      );
    }
    return newTxs.length;
  }

  /// Confirms all pending imports EXCEPT suspected spam — those must be
  /// reviewed one at a time.
  Future<void> confirmAllPending() async {
    for (var i = 0; i < _transactions.length; i++) {
      if (_transactions[i].pending && !_transactions[i].suspectedSpam) {
        _transactions[i] = _transactions[i].copyWith(pending: false);
      }
    }
    notifyListeners();
    await _persist(tx: true);
  }

  /// The reject counterpart of [confirmAllPending]: removes every pending
  /// import EXCEPT suspected spam and returns the removed rows (still
  /// `pending: true`) so the caller can offer Undo via
  /// [restoreTransactions] — the rows then rejoin the review queue.
  Future<List<Tx>> discardAllPending() async {
    final removed = [
      for (final t in _transactions)
        if (t.pending && !t.suspectedSpam) t,
    ];
    if (removed.isEmpty) return removed;
    _transactions.removeWhere((t) => t.pending && !t.suspectedSpam);
    notifyListeners();
    await _persist(tx: true);
    return removed;
  }
}
