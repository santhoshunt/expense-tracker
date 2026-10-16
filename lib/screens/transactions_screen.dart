import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/account.dart';
import '../models/spend_budget.dart';
import '../models/subscription_cycle.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/backup_service.dart';
import '../services/recurring_detector.dart';
import '../services/refund_matching.dart';
import '../services/transfer_pairing.dart';
import '../widgets/animated_fold.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../utils/contrast.dart';
import '../utils/haptics.dart';
import '../utils/money_colors.dart';
import '../utils/search_text.dart';
import '../widgets/category_chip_label.dart';
import '../widgets/cycle_label.dart';
import '../widgets/date_time_picker.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/empty_state.dart';
import '../widgets/glossy.dart';
import '../widgets/month_picker_sheet.dart';
import '../widgets/motion.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/status_dot.dart';
import '../widgets/tag_input.dart';
import '../widgets/transaction_tile.dart';
import '../widgets/undo_snackbar.dart';
import '../widgets/info_tip.dart';
import 'add_transaction_sheet.dart';
import 'app_nav.dart';

enum _Filter { all, income, expense, transfers }

/// Sentinel in the group filter for "Other" — groupable categories that
/// belong to no group.
const kUngroupedFilterKey = '_ungrouped';

enum _Sort { dateDesc, dateAsc, amountDesc, amountAsc }

const _sortLabels = {
  _Sort.dateDesc: 'Date · newest first',
  _Sort.dateAsc: 'Date · oldest first',
  _Sort.amountDesc: 'Amount · high to low',
  _Sort.amountAsc: 'Amount · low to high',
};

/// A deep-link into the Transactions tab: exactly which filters to apply.
/// Fields left null are RESET, not preserved — a tap on a dashboard figure
/// must land on that figure's rows, not that figure ANDed with whatever
/// chips were left over from last time.
class TxFilterRequest {
  final TxType? type;
  final String? accountId;
  final DateTime? month;
  final String? categoryId;
  final String? budgetId;
  final String? groupId;

  /// Free-text search, pre-filled into the search field — the merchant
  /// deep-link's only handle, since merchants live in SMS bodies/notes
  /// rather than any structured field.
  final String? query;

  /// Inclusive day range; mutually exclusive with [month] (range wins when
  /// both are set).
  final DateTimeRange? range;

  /// [range] matches the date each row counts in (Tx.countIn), like the
  /// dashboard's year totals, instead of the date it happened.
  final bool rangeCounted;

  /// The chip's text for [range], such as "FY 2026-27"; null shows the
  /// dates.
  final String? rangeLabel;

  /// Rows carrying this tag (matched ignoring case) — the Tags tab's rows.
  final String? tag;

  const TxFilterRequest({
    this.type,
    this.accountId,
    this.month,
    this.categoryId,
    this.budgetId,
    this.groupId,
    this.query,
    this.range,
    this.rangeCounted = false,
    this.rangeLabel,
    this.tag,
  });
}

/// Whether [t] falls on a day of [range], both ends included. [counted]
/// tests the date the row counts in (a dashboard year tap-through, so the
/// list adds up to the figure tapped); otherwise the date it happened (the
/// filter sheet's custom range).
bool txInRange(Tx t, DateTimeRange range, {required bool counted}) {
  // Whole days: the picker returns midnights, the rows carry times.
  final start = DateTime(range.start.year, range.start.month, range.start.day);
  final end = DateTime(range.end.year, range.end.month, range.end.day + 1);
  final d = counted ? t.effectiveDate : t.date;
  return !d.isBefore(start) && d.isBefore(end);
}

class TransactionsScreen extends StatefulWidget {
  /// Applied when [filterToken] changes — lets the dashboard's stat cards,
  /// budget rows, spending rows and the Accounts tab deep-link here.
  final TxFilterRequest? request;
  final int filterToken;

  const TransactionsScreen({super.key, this.request, this.filterToken = 0});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

/// One filter tab's derived list data — the output of the filter → group →
/// sort → flatten pipeline for that tab.
class _PageData {
  final List<Tx> filtered;
  final Map<DateTime, List<Tx>> groups;
  final List<(DateTime?, Tx?)> rows;

  /// The month each entry of [rows] sits under, header rows included, so
  /// the sticky header can name the month at any scroll position.
  final List<DateTime> rowMonths;

  /// Where each entry of [rows] sits in its card; month headers get
  /// [_RowShape.header].
  final List<_RowShape> shapes;
  final List<DateTime> months;
  final Map<DateTime, int> monthIndexes;

  const _PageData({
    required this.filtered,
    required this.groups,
    required this.rows,
    required this.rowMonths,
    required this.shapes,
    required this.months,
    required this.monthIndexes,
  });

  static const empty = _PageData(
    filtered: [],
    groups: {},
    rows: [],
    rowMonths: [],
    shapes: [],
    months: [],
    monthIndexes: {},
  );
}

/// How a transaction row sits in the run of rows drawn as one card: the
/// rows of a day under a date sort, the rows of a month under any other.
class _RowShape {
  final bool first;
  final bool last;

  /// The rows of this row's day, set on the first row of each day under a
  /// date sort only: a day header with their total shows above it.
  final List<Tx>? day;

  const _RowShape({required this.first, required this.last, this.day});

  static const header = _RowShape(first: false, last: false);
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  _Filter _filter = _Filter.all;

  /// A chip tap's slide in progress: the pages it passes must not select
  /// their chips on the way.
  bool _sliding = false;

  void _setFilter(_Filter f) {
    if (f == _filter) return;
    setState(() {
      _filter = f;
      _sliding = true;
    });
    _pageCtrl
        .animateToPage(
          f.index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() => _sliding = false);
  }

  _Sort _sort = _Sort.dateDesc;
  String _search = '';
  final Set<String> _categoryFilter = {};

  /// Selected parent-group ids; [kUngroupedFilterKey] stands for "Other"
  /// (groupable categories with no group).
  final Set<String> _groupFilter = {};

  /// Selected custom-budget ids — shows the rows counting toward any of them.
  final Set<String> _budgetFilter = {};

  /// Selected tags, by tagKey — shows rows carrying any of them.
  final Set<String> _tagFilter = {};
  double? _minAmount;
  double? _maxAmount;
  String? _accountId;
  DateTime? _monthFilter;

  /// Inclusive day range. Exclusive with [_monthFilter]: the filter sheet
  /// sets one and clears the other.
  DateTimeRange? _rangeFilter;

  /// [_rangeFilter] came from a dashboard year and matches the date rows
  /// count in, under [_rangeLabel]. Both reset with the range whenever it
  /// changes or clears.
  bool _rangeCounted = false;
  String? _rangeLabel;

  /// Sets the range and drops its year flavour: every path except a
  /// deep-link and an unchanged sheet Apply goes through here.
  void _setRange(DateTimeRange? r) {
    _rangeFilter = r;
    _rangeCounted = false;
    _rangeLabel = null;
  }

  /// Search text per row id (see [searchHaystack]); building one walks the
  /// SMS body with the merchant regex, so it is kept across pipeline runs
  /// and dropped only when the ledger revision changes.
  final Map<String, String> _haystacks = {};

  /// Ids of transactions picked in multi-select mode; non-empty = selecting.
  final Set<String> _selected = {};

  /// Selection mode entered from the ⋮ menu's Select, before
  /// any row is picked. Cleared by build once a row is picked, so from
  /// then on an empty selection ends the mode as before.
  bool _selectMode = false;
  bool get _selecting => _selectMode || _selected.isNotEmpty;

  void _toggleSelect(String id) {
    // No tick here: selection starts with a long-press, which already
    // vibrates, and later row taps are confirmed by the tile's animation.
    setState(
      () => _selected.contains(id) ? _selected.remove(id) : _selected.add(id),
    );
  }

  final _searchCtrl = TextEditingController();
  late final PageController _pageCtrl = PageController();

  // One controller/listener per filter: an ItemScrollController cannot be
  // attached to two lists at once, and during a page drag two filters'
  // lists are alive simultaneously.
  final _listCtrls = {
    for (final f in _Filter.values) f: ItemScrollController(),
  };
  final _listPositions = {
    for (final f in _Filter.values) f: ItemPositionsListener.create(),
  };

  // The month jump panel floats over the list, so it shows only for a short
  // while after a scroll comes to rest. It stays out of the way while a
  // finger drags the list, and parked off-screen otherwise, where it would
  // cover the month totals and trailing amounts.
  bool _jumpVisible = false;
  Timer? _jumpHideTimer;

  /// Applied in a microtask: a scroll can end during layout (the list
  /// shrinking under a fling), where a setState is not allowed.
  void _setJumpVisible(bool visible) => scheduleMicrotask(() {
    if (mounted && _jumpVisible != visible) {
      setState(() => _jumpVisible = visible);
    }
  });

  /// A finger is moving the list: the panel steps aside at once.
  void _hideJumpControls() {
    _jumpHideTimer?.cancel();
    _setJumpVisible(false);
  }

  /// The list came to rest: the panel shows, and goes again 1.6 s later.
  void _pokeJumpControls() {
    _setJumpVisible(true);
    _jumpHideTimer?.cancel();
    _jumpHideTimer = Timer(
      const Duration(milliseconds: 1600),
      () => _setJumpVisible(false),
    );
  }

  // The filter → group → sort → flatten pipeline walks the whole ledger, so
  // its output is cached and recomputed only when the data or the filters
  // actually change (see _recomputePipeline) — not on selection taps,
  // scroll-driven setStates or jump-control visibility toggles.
  /// Transfer-pair suggestions walk every row, so they are memoised on the
  /// ledger revision plus the dismissal list (dashboard `_recurring` idiom).
  Object? _pairRev;
  int _pairDismissedCount = -1;
  List<PairSuggestion> _pairs = const [];

  List<PairSuggestion> _pairSuggestions(
    FinanceProvider finance,
    List<Tx> pending,
    List<Tx> confirmed,
  ) {
    final dismissed = context.read<SettingsProvider>().dismissedPairSuggestions;
    if (!identical(_pairRev, finance.revision) ||
        _pairDismissedCount != dismissed.length) {
      _pairRev = finance.revision;
      _pairDismissedCount = dismissed.length;
      _pairs = suggestTransferPairs(
        [...pending, ...confirmed],
        dismissed: dismissed,
        accountFor: finance.accountForKey,
      );
    }
    return _pairs;
  }

  /// "Looks like a refund" suggestions, memoised the same way: for income
  /// rows in review, and for confirmed ones the one-time refund pass left
  /// to look at ([FinanceProvider.refundReviewIds]).
  Object? _refundRev;
  int _refundDismissedCount = -1;
  List<RefundSuggestion> _refunds = const [];

  List<RefundSuggestion> _refundSuggestions(
    FinanceProvider finance,
    List<Tx> pending,
  ) {
    final dismissed = context.read<SettingsProvider>().dismissedPairSuggestions;
    if (!identical(_refundRev, finance.revision) ||
        _refundDismissedCount != dismissed.length) {
      _refundRev = finance.revision;
      _refundDismissedCount = dismissed.length;
      final reviewIds = finance.refundReviewIds;
      bool open(Tx t) =>
          t.type == TxType.income &&
          t.refundOf == null &&
          t.pairId == null &&
          !isTransferCategory(t.categoryId);
      _refunds = finance.refundSuggestions([
        for (final t in pending)
          if (open(t)) t,
        if (reviewIds.isNotEmpty)
          for (final t in finance.transactions)
            if (reviewIds.contains(t.id) && open(t)) t,
      ], dismissed);
    }
    return _refunds;
  }

  Object? _pipelineRevision;
  String? _pipelineFingerprint;

  /// Lazily filled per filter tab (see _pageDataFor); cleared whenever the
  /// ledger or a non-tab filter input changes.
  final Map<_Filter, _PageData> _pageCache = {};

  /// One compact, dismissible chip per active filter. Named chips so a
  /// deep-link (or a sheet Apply) always says WHAT is filtering the list
  /// and offers an inline way out; compact density so a strip of many
  /// stays one short line (horizontally scrollable at the call site).
  List<Widget> _activeFilterChips(
    FinanceProvider finance,
    Account? activeAccount,
  ) {
    InputChip chip({
      required Widget avatar,
      required String label,
      required VoidCallback onDeleted,
    }) => InputChip(
      avatar: avatar,
      // Ellipsized when the strip caps the chip's width.
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onDeleted: onDeleted,
    );

    return [
      if (activeAccount != null)
        chip(
          avatar: Icon(activeAccount.icon, size: 16),
          label: 'Account · ${activeAccount.displayName}',
          onDeleted: () => setState(() => _accountId = null),
        ),
      if (_monthFilter != null)
        chip(
          avatar: const Icon(Icons.calendar_month, size: 16),
          label: 'Month · ${fmtMonth(_monthFilter!)}',
          onDeleted: () => setState(() => _monthFilter = null),
        ),
      if (_rangeFilter != null)
        chip(
          avatar: const Icon(Icons.date_range, size: 16),
          label: _rangeLabel ?? fmtDateRange(_rangeFilter!),
          onDeleted: () => setState(() => _setRange(null)),
        ),
      for (final b in finance.budgets)
        if (_budgetFilter.contains(b.id))
          chip(
            avatar: const Icon(Icons.track_changes, size: 16),
            label: 'Budget · ${b.name}',
            onDeleted: () => setState(() => _budgetFilter.remove(b.id)),
          ),
      for (final g in finance.groups)
        if (_groupFilter.contains(g.id))
          chip(
            avatar: const Icon(Icons.workspaces_outlined, size: 16),
            label: 'Group · ${g.label}',
            onDeleted: () => setState(() => _groupFilter.remove(g.id)),
          ),
      if (_groupFilter.contains(kUngroupedFilterKey))
        chip(
          avatar: const Icon(Icons.category, size: 16),
          label: 'Group · Other',
          onDeleted: () =>
              setState(() => _groupFilter.remove(kUngroupedFilterKey)),
        ),
      for (final id in _categoryFilter)
        chip(
          avatar: Icon(
            categoryById(id).icon,
            size: 16,
            color: categoryById(id).color,
          ),
          label: categoryById(id).label,
          onDeleted: () => setState(() => _categoryFilter.remove(id)),
        ),
      for (final u in finance.allTags)
        if (_tagFilter.contains(tagKey(u.tag)))
          chip(
            avatar: const Icon(Icons.label_outline, size: 16),
            label: 'Tag · ${u.tag}',
            onDeleted: () => setState(() => _tagFilter.remove(tagKey(u.tag))),
          ),
      // One chip for both bounds: its ✕ clears the range.
      if (_minAmount != null || _maxAmount != null)
        chip(
          avatar: const Icon(Icons.currency_rupee, size: 16),
          label: _amountChipLabel(_minAmount, _maxAmount),
          onDeleted: () => setState(() {
            _minAmount = null;
            _maxAmount = null;
          }),
        ),
    ];
  }

  /// "Amount ₹500 to ₹2,000", "Amount from ₹500" or "Amount up to ₹2,000".
  static String _amountChipLabel(double? min, double? max) {
    if (min != null && max != null) {
      return 'Amount ${fmtMoneyTidy(min)} to ${fmtMoneyTidy(max)}';
    }
    if (min != null) return 'Amount from ${fmtMoneyTidy(min)}';
    return 'Amount up to ${fmtMoneyTidy(max ?? 0)}';
  }

  bool get _hasAdvancedFilters =>
      _categoryFilter.isNotEmpty ||
      _groupFilter.isNotEmpty ||
      _budgetFilter.isNotEmpty ||
      _tagFilter.isNotEmpty ||
      _minAmount != null ||
      _maxAmount != null ||
      _accountId != null ||
      _monthFilter != null ||
      _rangeFilter != null;

  @override
  void didUpdateWidget(TransactionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filterToken != oldWidget.filterToken) {
      final req = widget.request;
      // Reset-then-apply: a stale chip from a previous visit must not AND
      // with the incoming request.
      _filter = switch (req?.type) {
        TxType.income => _Filter.income,
        TxType.expense => _Filter.expense,
        null => _Filter.all,
      };
      _categoryFilter.clear();
      _groupFilter.clear();
      _budgetFilter.clear();
      _tagFilter.clear();
      _minAmount = null;
      _maxAmount = null;
      // Cancel any in-flight debounce or it re-applies the pre-reset text
      // ~250ms after the deep-link lands.
      _searchDebounce?.cancel();
      _search = req?.query ?? '';
      _searchCtrl.text = _search;
      // A deep-link is a navigation, not an edit — leftover multi-select
      // mode would greet it with a selection bar nobody asked for.
      _selected.clear();
      _selectMode = false;
      _accountId = req?.accountId;
      _rangeFilter = req?.range;
      _rangeCounted = req?.range != null && req!.rangeCounted;
      _rangeLabel = req?.range != null ? req!.rangeLabel : null;
      _monthFilter = _rangeFilter == null ? req?.month : null;
      if (req?.categoryId != null) _categoryFilter.add(req!.categoryId!);
      if (req?.groupId != null) _groupFilter.add(req!.groupId!);
      if (req?.budgetId != null) _budgetFilter.add(req!.budgetId!);
      if (req?.tag != null) _tagFilter.add(tagKey(req!.tag!));
      // A deep-link is a jump, not a sideways step. Post-frame because
      // didUpdateWidget runs during build and a synchronous jumpToPage
      // would mutate scroll positions mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageCtrl.hasClients) {
          _pageCtrl.jumpToPage(_filter.index);
        }
      });
    }
  }

  Timer? _searchDebounce;

  /// Filtering and regrouping runs over the whole ledger, so wait for a pause
  /// in typing rather than doing it on every keystroke.
  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _search = v);
    });
  }

  /// The pending count the ⋮ menu entries were last scheduled for: the
  /// only part of their labels that changes.
  int? _menuPending;

  /// Publishes this tab's "This page" entries in Home's ⋮ menu after the
  /// frame, and only when their labels change.
  void _scheduleMenuPublish(int pendingCount) {
    if (_menuPending == pendingCount) return;
    _menuPending = pendingCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppNav.instance.pageMenu.publish(this, kHomeTabTransactions, [
        if (pendingCount > 0)
          PageMenuAction(
            icon: Icons.inbox_outlined,
            label: 'Review imports ($pendingCount)',
            onTap: _openReview,
          ),
        PageMenuAction(
          icon: Icons.checklist,
          label: 'Select',
          onTap: _enterSelectMode,
        ),
        PageMenuAction(
          icon: Icons.download_outlined,
          label: 'Export CSV',
          onTap: _exportCsv,
        ),
      ]);
    });
  }

  /// Opens whichever review card is folded. Both sit pinned above the
  /// list, so opening them is all it takes to bring them into view.
  void _openReview() {
    if (!mounted) return;
    final settings = context.read<SettingsProvider>();
    final pending = context.read<FinanceProvider>().pendingTransactions;
    if (pending.any((t) => !t.suspectedSpam) &&
        settings.isSectionCollapsed('pending_review')) {
      settings.toggleSection('pending_review');
    }
    if (pending.any((t) => t.suspectedSpam) &&
        settings.isSectionCollapsed('spam_review')) {
      settings.toggleSection('spam_review');
    }
  }

  /// Selection mode with nothing picked yet: row taps then select.
  void _enterSelectMode() {
    if (mounted) setState(() => _selectMode = true);
  }

  @override
  void dispose() {
    AppNav.instance.pageMenu.detach(this);
    _jumpHideTimer?.cancel();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _pageCtrl.dispose();
    _jumping.dispose();
    super.dispose();
  }

  List<Tx> _applyFilters(List<Tx> all, FinanceProvider finance, _Filter f) {
    final q = normalizeSearchText(_search);
    final budgetFilterList = _budgetFilter.isEmpty
        ? const <SpendBudget>[]
        : finance.budgets.where((b) => _budgetFilter.contains(b.id)).toList();
    final r = _rangeFilter;
    return all.where((t) {
      // A bank lists its linked debit cards' rows too, the rows its balance
      // runs over; a card lists its own.
      if (_accountId != null) {
        final owner = finance.accountForKey(t.acctKey);
        if (owner?.id != _accountId &&
            finance.linkedAccountOf(owner)?.id != _accountId) {
          return false;
        }
      }
      // The month a row counts in: a dashboard tap-through lists what its
      // total counted.
      final m = _monthFilter;
      final counts = t.effectiveDate;
      if (m != null && (counts.year != m.year || counts.month != m.month)) {
        return false;
      }
      if (r != null && !txInRange(t, r, counted: _rangeCounted)) {
        return false;
      }
      // The Income, Expense and Transfers tabs list what the totals count,
      // so an uncounted wallet row shows under All only.
      switch (f) {
        case _Filter.income:
          if (t.type != TxType.income ||
              isTransferCategory(t.categoryId) ||
              !finance.countsInTotals(t)) {
            return false;
          }
        case _Filter.expense:
          if (t.type != TxType.expense ||
              isTransferCategory(t.categoryId) ||
              !finance.countsInTotals(t)) {
            return false;
          }
        case _Filter.transfers:
          if (!isTransferCategory(t.categoryId) || !finance.countsInTotals(t)) {
            return false;
          }
        case _Filter.all:
          break;
      }
      if (_categoryFilter.isNotEmpty &&
          !_categoryFilter.contains(t.categoryId)) {
        return false;
      }
      if (_groupFilter.isNotEmpty) {
        final gid = finance.groupIdOf(t.categoryId);
        // "Other" matches unassigned *groupable* categories only, so plain
        // income rows don't flood an Other-group filter — and not ungrouped
        // transfers, which the dashboard's Other total leaves out.
        final matches = gid != null
            ? _groupFilter.contains(gid)
            : _groupFilter.contains(kUngroupedFilterKey) &&
                  finance.isGroupable(t.category) &&
                  !t.category.isTransfer;
        // Group totals leave uncounted wallet rows out; so does the list.
        if (!matches || !finance.countsInTotals(t)) return false;
      }
      if (budgetFilterList.isNotEmpty &&
          !budgetFilterList.any((b) => finance.countsTowardBudget(t, b))) {
        return false;
      }
      if (_tagFilter.isNotEmpty &&
          !t.tags.any((tag) => _tagFilter.contains(tagKey(tag)))) {
        return false;
      }
      if (_minAmount != null && t.amount < _minAmount!) return false;
      if (_maxAmount != null && t.amount > _maxAmount!) return false;
      if (q.isNotEmpty) {
        final hay = _haystacks[t.id] ??= searchHaystack(
          t,
          accountName: finance.accountForKey(t.acctKey)?.displayName,
          merchantAlias: finance.merchantAliasFor(t),
        );
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  /// Everything the pipeline output depends on besides the ledger itself
  /// and the filter tab (each tab is its own _pageCache entry). Cheap to
  /// build relative to one pipeline run; sets are sorted so insertion order
  /// can't fake a change.
  String _pipelineInputs() => [
    _sort.index,
    normalizeSearchText(_search),
    (_categoryFilter.toList()..sort()).join(','),
    (_groupFilter.toList()..sort()).join(','),
    (_budgetFilter.toList()..sort()).join(','),
    (_tagFilter.toList()..sort()).join(','),
    _minAmount,
    _maxAmount,
    _accountId,
    _monthFilter,
    _rangeFilter?.start,
    _rangeFilter?.end,
    _rangeCounted,
  ].join('|');

  /// Runs filter → group-by-month → sort → flatten for one filter tab,
  /// caching the result per tab. The cache is dropped only when the ledger
  /// (provider revision) or a non-tab filter input changes — selection taps
  /// and the scroll-driven jump-control toggles rebuild this screen
  /// constantly, and a page drag asks for two tabs in the same frame.
  _PageData _pageDataFor(
    _Filter f,
    FinanceProvider finance,
    List<Tx> allConfirmed,
  ) {
    final fingerprint = _pipelineInputs();
    if (!identical(_pipelineRevision, finance.revision) ||
        fingerprint != _pipelineFingerprint) {
      // Category labels, account names and aliases all ride on the revision.
      if (!identical(_pipelineRevision, finance.revision)) _haystacks.clear();
      _pipelineRevision = finance.revision;
      _pipelineFingerprint = fingerprint;
      _pageCache.clear();

      // Prune filter ids whose target was deleted. A dead category/group id
      // silently emptied the list; a dead budget id was worse — the budget
      // check no-ops on an empty resolved list, so the filter stopped
      // filtering while the badge stayed lit. Same precedent as the
      // _selected pruning in build.
      _categoryFilter.removeWhere(
        (id) => !allCategories.any((c) => c.id == id),
      );
      _groupFilter.removeWhere(
        (id) =>
            id != kUngroupedFilterKey && !finance.groups.any((g) => g.id == id),
      );
      _budgetFilter.removeWhere(
        (id) => !finance.budgets.any((b) => b.id == id),
      );
      // A tag renamed, deleted or taken off its last row has no chip left
      // to clear it with, and would keep the list empty.
      final liveTags = {for (final u in finance.allTags) tagKey(u.tag)};
      _tagFilter.removeWhere((k) => !liveTags.contains(k));
    }
    return _pageCache[f] ??= _buildPageData(f, finance, allConfirmed);
  }

  _PageData _buildPageData(
    _Filter f,
    FinanceProvider finance,
    List<Tx> allConfirmed,
  ) {
    final filtered = _applyFilters(allConfirmed, finance, f);

    // Group by month, months always newest-first; sort within each month.
    // Rows sit under the month they happened in, except in a month-filtered
    // view: an October tap-through would otherwise show a September header
    // holding only the salary that counts in October. Either way a header
    // totals the rows under it, so every row is in exactly one total. A
    // dashboard year's range groups the same way, for the same reason.
    final byCounted = _monthFilter != null || _rangeCounted;
    final groups = <DateTime, List<Tx>>{};
    for (final tx in filtered) {
      final d = byCounted ? tx.effectiveDate : tx.date;
      groups.putIfAbsent(DateTime(d.year, d.month), () => []).add(tx);
    }
    final months = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final list in groups.values) {
      list.sort(switch (_sort) {
        _Sort.dateDesc => (a, b) => b.date.compareTo(a.date),
        _Sort.dateAsc => (a, b) => a.date.compareTo(b.date),
        _Sort.amountDesc => (a, b) => b.amount.compareTo(a.amount),
        _Sort.amountAsc => (a, b) => a.amount.compareTo(b.amount),
      });
    }
    // Flat index model so month jumps can address a header that was never
    // mounted. Only the *data* is flattened — widgets are built on demand in
    // itemBuilder. Materialising a TransactionTile per transaction here (as
    // this used to) meant allocating the whole ledger's widgets on every
    // build, including every keystroke in the search box.
    //
    // Rows stay one flat list; the day cards are drawn from [shapes]. Under
    // a date sort a run is the rows of one day (by the date each happened,
    // the order they are sorted in); under any other sort it is the month.
    final byDate = _sort == _Sort.dateDesc || _sort == _Sort.dateAsc;
    final rows = <(DateTime?, Tx?)>[];
    final rowMonths = <DateTime>[];
    final shapes = <_RowShape>[];
    final monthIndexes = <DateTime, int>{};
    for (final month in months) {
      monthIndexes[month] = rows.length;
      rows.add((month, null));
      rowMonths.add(month);
      shapes.add(_RowShape.header);
      final txs = groups[month]!;
      var start = 0;
      while (start < txs.length) {
        var end = start + 1;
        while (end < txs.length &&
            (!byDate || DateUtils.isSameDay(txs[end].date, txs[start].date))) {
          end++;
        }
        final day = byDate ? txs.sublist(start, end) : null;
        for (var i = start; i < end; i++) {
          rows.add((null, txs[i]));
          rowMonths.add(month);
          shapes.add(
            _RowShape(
              first: i == start,
              last: i == end - 1,
              day: i == start ? day : null,
            ),
          );
        }
        start = end;
      }
    }
    return _PageData(
      filtered: filtered,
      groups: groups,
      rows: rows,
      rowMonths: rowMonths,
      shapes: shapes,
      months: months,
      monthIndexes: monthIndexes,
    );
  }

  /// The fronted tab's data; empty until build has run once.
  _PageData get _activeData => _pageCache[_filter] ?? _PageData.empty;

  void _scrollToIndex(int index, {double alignment = 0}) {
    final ctrl = _listCtrls[_filter]!;
    if (!ctrl.isAttached) return;
    // A long jump cross-fades in a second list whose positions are not
    // published, so the sticky header would name the old months; it steps
    // aside until the jump lands.
    _jumping.value = true;
    ctrl
        .scrollTo(
          index: index,
          alignment: alignment,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
        )
        .whenComplete(() {
          if (mounted) _jumping.value = false;
        });
  }

  final _jumping = ValueNotifier(false);

  /// The list's height in px, as the sticky band last laid out: positions
  /// are fractions of it.
  double _viewport = 0;

  /// Whether the list is scrolling (a fling included), and whether the
  /// current touch landed while it was: tapping the top of the screen to
  /// stop a fling is a habit, and must not open the month list.
  bool _listMoving = false;
  bool _touchStoppedList = false;

  /// Step month-by-month: up snaps to the current month's header first,
  /// then to the previous month; down goes to the next month's header
  /// (or the end of the list when already in the last month).
  void _stepMonth({required bool up}) {
    final data = _activeData;
    if (data.months.isEmpty) return;
    final positions = _listPositions[_filter]!.itemPositions.value;
    if (positions.isEmpty) return;
    // Top-most item still visible in the viewport.
    final top = positions
        .where((p) => p.itemTrailingEdge > 0)
        .reduce((a, b) => a.index < b.index ? a : b);
    final headers = [
      for (final m in data.months) data.monthIndexes[m]!,
    ]; // ascending

    if (up) {
      var current = headers.lastIndexWhere((h) => h <= top.index);
      if (current < 0) current = 0;
      // Already sitting on this month's header (its label still below the
      // sticky band's spot, as _stickyMonth decides) → previous month.
      final atHeader =
          headers[current] == top.index &&
          top.itemLeadingEdge * _viewport + _headerTopAt(top.index) > 0;
      final target = (current - (atHeader ? 1 : 0)).clamp(
        0,
        headers.length - 1,
      );
      _scrollToIndex(headers[target]);
    } else {
      final next = headers.indexWhere((h) => h > top.index);
      if (next == -1) {
        // Last month: land the final entry near the bottom of the viewport.
        _scrollToIndex(data.rows.length - 1, alignment: 0.85);
      } else {
        _scrollToIndex(headers[next]);
      }
    }
  }

  void _scrollToMonth(DateTime month) {
    final index = _activeData.monthIndexes[month];
    if (index != null) _scrollToIndex(index);
  }

  /// The month the sticky header should name for [positions], or null when
  /// it should not show: at the very top, or while the month's own header
  /// row is at the top with its label still below the band's label. The
  /// band takes over once the two labels line up, so the name never shows
  /// twice or jumps.
  DateTime? _stickyMonth(
    _PageData data,
    Iterable<ItemPosition> positions,
    double viewport,
  ) {
    final shown = positions.where((p) => p.itemTrailingEdge > 0);
    if (shown.isEmpty) return null;
    final top = shown.reduce((a, b) => a.index < b.index ? a : b);
    // Positions can still describe the previous, longer list for a frame
    // after a delete or a filter change.
    if (top.index >= data.rowMonths.length) return null;
    // The band and a header row's content share one height, so the labels
    // line up once the row's top padding has scrolled away.
    final labelBelowBand =
        data.rows[top.index].$1 != null &&
        top.itemLeadingEdge * viewport + _headerTopAt(top.index) > 0;
    return labelBelowBand ? null : data.rowMonths[top.index];
  }

  /// Whether the "N new · Mark all seen" line shows above the list, as the
  /// last build decided.
  bool _newLineShown = false;

  /// The top gap of the month header at row [index]. The list's first
  /// header keeps a small one while the "N new" line sits right above it:
  /// that line's 48dp button already leaves the room.
  double _headerTopAt(int index) => index == 0 && _newLineShown
      ? _kMonthHeaderTopUnderLine
      : _kMonthHeaderTop;

  Widget _stickyBand(
    BuildContext context,
    _PageData data,
    _Filter f,
    double viewport,
  ) {
    _viewport = viewport;
    if (_jumping.value || viewport <= 0) return const SizedBox.shrink();
    final positions = _listPositions[f]!.itemPositions.value;
    final month = _stickyMonth(data, positions, viewport);
    if (month == null) return const SizedBox.shrink();
    // A header row's content height, so the band's label sits where the
    // row's was at the hand-off.
    final band = _monthHeaderRowHeight(context);
    // The first header below the top row: once it reaches the band, the
    // band slides up with it.
    var push = 0.0;
    for (final p in positions) {
      if (p.index >= data.rows.length || data.rows[p.index].$1 == null) {
        continue;
      }
      final top = p.itemLeadingEdge * viewport;
      if (top > 0 && top < band) push = math.min(push, top - band);
    }
    final colors = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    Future<void> jump() async {
      final picked = await showMonthPickerSheet(
        context,
        title: 'Jump to month',
        months: data.months,
        selected: month,
      );
      if (picked != null && mounted) _scrollToMonth(picked);
    }

    return Align(
      alignment: Alignment.topCenter,
      child: Transform.translate(
        offset: Offset(0, push),
        child: Semantics(
          button: true,
          label:
              'Jump to month, showing ${DateFormat('MMMM yyyy').format(month)}',
          onTap: jump,
          excludeSemantics: true,
          // Translucent over a strip that ignores pointers: the tap lands
          // here (its recognizer joins the arena first, so it beats the row
          // beneath), while the list behind still receives the pointer and
          // wins any drag, so scrolling from the strip keeps working.
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _touchStoppedList = _listMoving,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (!_touchStoppedList) jump();
              },
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('sticky-month-header'),
                  height: band,
                  alignment: Alignment.centerLeft,
                  // The card fill, fully opaque, with a hairline edge: reads
                  // as a pinned strip over the rows, and no row text shows
                  // through it.
                  decoration: BoxDecoration(
                    color: colors.cardFill ?? scheme.surface,
                  ),
                  // Drawn over the content: a border in [decoration] pads
                  // the child by its width and lifts the label off the
                  // row's by half a pixel at the hand-off.
                  foregroundDecoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: _MonthHeader(
                    month: month,
                    txs: data.groups[month]!,
                    compact: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    // Read once: each of these getters used to be called two or more times per
    // build, and each one filters the whole ledger.
    final allPending = finance.pendingTransactions;
    final allConfirmed = finance.transactions;
    final pending = allPending.where((t) => !t.suspectedSpam).toList();
    final spamSuspects = allPending.where((t) => t.suspectedSpam).toList();
    final filtered = _pageDataFor(_filter, finance, allConfirmed).filtered;
    _scheduleMenuPublish(finance.pendingCount);
    _newLineShown = finance.unseenCount > 0;
    // Drop selections that no longer exist (deleted, or re-filtered away by
    // an edit) so the action bar count never lies.
    if (_selected.isNotEmpty) {
      // A picked row ends the menu's empty selection mode: from here an
      // empty selection closes the bar, as after a long-press.
      _selectMode = false;
      final visible = {for (final t in filtered) t.id};
      _selected.removeWhere((id) => !visible.contains(id));
    }
    final activeAccount = _accountId == null
        ? null
        : finance.accountById(_accountId!);
    // Rebuilds on "Not a transfer" and its Undo: the suggestions below
    // read the dismissed list, which lives in settings, not the ledger.
    context.select<SettingsProvider, int>(
      (s) => s.dismissedPairSuggestions.length,
    );
    final pairs = pending.isEmpty
        ? const <PairSuggestion>[]
        : _pairSuggestions(finance, allPending, allConfirmed);
    final refunds = pending.isEmpty && finance.refundReviewIds.isEmpty
        ? const <RefundSuggestion>[]
        : _refundSuggestions(finance, pending);
    // Refunds already counted, offered for a link: they keep the review
    // card up with no import waiting, and count in its title.
    final pastRefunds = refunds.where((s) => !s.refund.pending).length;
    // Up to three suggestions, transfers first. A row already in a shown
    // transfer is not offered as a refund too.
    final shownPairs = pairs.take(3).toList();
    final paired = {
      for (final s in shownPairs) ...[s.out.id, s.incoming.id],
    };
    final shownRefunds = refunds
        .where((s) => !paired.contains(s.refund.id))
        .take(3 - shownPairs.length)
        .toList();
    final showReview = pending.isNotEmpty || pastRefunds > 0;

    final hasFilterChips =
        activeAccount != null ||
        _monthFilter != null ||
        _rangeFilter != null ||
        _categoryFilter.isNotEmpty ||
        _groupFilter.isNotEmpty ||
        _budgetFilter.isNotEmpty ||
        _tagFilter.isNotEmpty ||
        _minAmount != null ||
        _maxAmount != null;

    // The cards and bars above the list fold in and out (AnimatedPresence)
    // so the list slides instead of jumping. Each child is built only while
    // it shows: once hidden, the switcher keeps the last built copy for the
    // fold-out, so no card is ever built from an empty list.
    //
    // The two review cards share at most [_kReviewCardsShare] of the
    // height and scroll inside it: open, with large text on a small phone,
    // they used to take the whole screen and leave the list none. They stay
    // out of the list itself, whose rows are indexed for the month jumps
    // and the sticky band.
    return LayoutBuilder(
      builder: (context, box) => Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: box.maxHeight.isFinite
                  ? box.maxHeight * _kReviewCardsShare
                  : double.infinity,
            ),
            child: _ReviewCardsScroll(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedPresence(
                    key: const ValueKey('spam-card'),
                    visible: spamSuspects.isNotEmpty,
                    child: spamSuspects.isEmpty
                        ? const SizedBox.shrink()
                        : _SuspectedSpamCard(suspects: spamSuspects),
                  ),
                  AnimatedPresence(
                    key: const ValueKey('pending-card'),
                    visible: showReview,
                    child: !showReview
                        ? const SizedBox.shrink()
                        : _PendingReviewCard(
                            pending: pending,
                            suggestions: shownPairs,
                            refundSuggestions: shownRefunds,
                            pastRefunds: pastRefunds,
                          ),
                  ),
                ],
              ),
            ),
          ),
          _SearchAndFilterBar(
            searchCtrl: _searchCtrl,
            onSearch: _onSearchChanged,
            onClearSearch: () {
              _searchDebounce?.cancel();
              setState(() => _search = '');
            },
            filter: _filter,
            onFilter: _setFilter,
            hasAdvancedFilters: _hasAdvancedFilters,
            onOpenFilters: _openFilterSheet,
          ),
          AnimatedPresence(
            key: const ValueKey('filter-chips'),
            visible: hasFilterChips,
            child: !hasFilterChips
                ? const SizedBox.shrink()
                // Single-line, horizontally scrollable strip of COMPACT chips —
                // a wrapping layout grew a row per filter and buried the list
                // when several were active.
                // Left-aligned under the type chips: a narrower strip would
                // otherwise sit centred. Each chip is capped at the strip's
                // width, its label ellipsized, so its ✕ never runs off screen
                // at large text.
                : Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: LayoutBuilder(
                      builder: (context, box) => Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              for (final chip in _activeFilterChips(
                                finance,
                                activeAccount,
                              ))
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: math.max(
                                        0.0,
                                        box.maxWidth - 32,
                                      ),
                                    ),
                                    child: chip,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          AnimatedPresence(
            key: const ValueKey('selection-bar'),
            visible: _selecting,
            child: !_selecting
                ? const SizedBox.shrink()
                : _SelectionBar(
                    count: _selected.length,
                    onSelectAll: () => setState(
                      () => _selected.addAll([for (final t in filtered) t.id]),
                    ),
                    onCategory: () => _bulkCategory(filtered),
                    onAccount: _bulkAccount,
                    onCountIn: _bulkCountIn,
                    onDateTime: _bulkDateTime,
                    onTags: _bulkTags,
                    onSubscription: _bulkSubscription,
                    // Pairing is a two-row concept — the button only exists at
                    // exactly two selected.
                    onPair: _selected.length == 2 ? _bulkPair : null,
                    onDelete: _bulkDelete,
                    onClose: () => setState(() {
                      _selected.clear();
                      _selectMode = false;
                    }),
                  ),
          ),
          AnimatedPresence(
            key: const ValueKey('unseen-line'),
            visible: finance.unseenCount > 0,
            child: finance.unseenCount == 0
                ? const SizedBox.shrink()
                : _UnseenLine(count: finance.unseenCount),
          ),
          Expanded(
            child: PageView(
              controller: _pageCtrl,
              onPageChanged: (i) {
                if (_sliding) return;
                final f = _Filter.values[i];
                if (f != _filter) setState(() => _filter = f);
              },
              children: [
                for (final f in _Filter.values)
                  _buildPage(f, finance, allConfirmed),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One pager page: [f]'s empty state or list. Uses [f]'s own data and
  /// controllers — during a drag the neighbor page is alive too.
  Widget _buildPage(_Filter f, FinanceProvider finance, List<Tx> allConfirmed) {
    final data = _pageDataFor(f, finance, allConfirmed);
    // Date sorts put a day header over each day's rows.
    final byDate = _sort == _Sort.dateDesc || _sort == _Sort.dateAsc;
    // Transparent ColoredBox: the empty state is shrink-wrapped, and a
    // PageView only receives drags that hit its subtree — blank regions
    // need an opaque hit-test surface or a swipe there would die.
    return ColoredBox(
      color: Colors.transparent,
      child: data.filtered.isEmpty
          // Scrollable so the empty state survives being squeezed: while
          // the review cards and a snackbar animate, this area can pass
          // through a few frames shorter than the text.
          ? Center(
              child: SingleChildScrollView(
                child: allConfirmed.isEmpty
                    ? EmptyState(
                        icon: Icons.receipt_long_outlined,
                        message: 'No transactions yet.',
                        actionLabel: 'Add transaction',
                        onAction: () => showAddTransactionSheet(context),
                      )
                    // Something is hiding every row (a chip may be
                    // scrolled out of view) — offer the way out here.
                    // EmptyState's filled button would outweigh a reset,
                    // so the quieter text button stays below it.
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const EmptyState(
                            icon: Icons.search_off,
                            message: 'Nothing matches your search or filters.',
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.filter_alt_off, size: 18),
                            label: const Text('Clear search & filters'),
                            onPressed: () {
                              _searchDebounce?.cancel();
                              _searchCtrl.clear();
                              setState(() {
                                _search = '';
                                _filter = _Filter.all;
                                _categoryFilter.clear();
                                _groupFilter.clear();
                                _budgetFilter.clear();
                                _tagFilter.clear();
                                _minAmount = null;
                                _maxAmount = null;
                                _accountId = null;
                                _monthFilter = null;
                                _setRange(null);
                              });
                              // A reset is a jump, not a sideways step.
                              if (_pageCtrl.hasClients) {
                                _pageCtrl.jumpToPage(0);
                              }
                            },
                          ),
                        ],
                      ),
              ),
            )
          : Stack(
              children: [
                // Lazy indexed list: month jumps go by item index, so
                // headers never need to be mounted to be reachable.
                NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    // Only a drag hides the panel: an arrow tap scrolls the
                    // list too, and the panel must stay under the finger
                    // for the next tap.
                    if ((n is ScrollStartNotification &&
                            n.dragDetails != null) ||
                        (n is ScrollUpdateNotification &&
                            n.dragDetails != null)) {
                      _hideJumpControls();
                    }
                    if (n is ScrollEndNotification) _pokeJumpControls();
                    if (n is ScrollStartNotification) _listMoving = true;
                    if (n is ScrollEndNotification) _listMoving = false;
                    return false;
                  },
                  child: ScrollablePositionedList.builder(
                    itemScrollController: _listCtrls[f],
                    itemPositionsListener: _listPositions[f],
                    itemCount: data.rows.length,
                    padding: const EdgeInsets.only(bottom: 120),
                    itemBuilder: (_, i) {
                      final (month, tx) = data.rows[i];
                      if (month != null) {
                        return _MonthHeader(
                          month: month,
                          txs: data.groups[month]!,
                          onSelectMonth: () => _selectMonth(month),
                          top: _headerTopAt(i),
                        );
                      }
                      final shape = data.shapes[i];
                      // One root per row whether or not a day header sits
                      // above it, so a row that gains or loses the header
                      // keeps its tile's state.
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (shape.day case final day?)
                            _DayHeader(day: tx!.date, txs: day),
                          TransactionTile(
                            // Keyed by row: a search or sort hands this
                            // slot another transaction, whose tint must
                            // not ease over from the previous row's.
                            key: ValueKey(tx!.id),
                            tx: tx,
                            selectionMode: _selecting,
                            selected: _selected.contains(tx.id),
                            onToggleSelect: () => _toggleSelect(tx.id),
                            grouped: true,
                            groupedFirst: shape.first,
                            groupedLast: shape.last,
                            // A day header names the date of every row
                            // under it; the row adds its time.
                            showDate: !byDate,
                          ),
                        ],
                      );
                    },
                  ),
                ),
                // Sticky month header: names the month of the top-most row
                // once its own header has scrolled away. Listens to the
                // list's positions directly, so scrolling never rebuilds
                // the screen for it.
                //
                // A tap on it opens the month list; a drag starting on it
                // still scrolls the list (see _stickyBand). The next
                // month's header pushes it up and out, so it never names a
                // month whose rows are not beneath it.
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, box) => ListenableBuilder(
                      listenable: Listenable.merge([
                        _listPositions[f]!.itemPositions,
                        _jumping,
                      ]),
                      builder: (context, _) =>
                          _stickyBand(context, data, f, box.maxHeight),
                    ),
                  ),
                ),
                // With a month or range filter the list holds one
                // month (or a few) — nothing worth jumping between. A
                // dashboard year's range holds twelve, so it keeps them.
                // Painted after the sticky header and inside the 52dp gutter
                // _MonthHeader keeps clear on its right, so both stay usable
                // at the same top offset.
                if (_monthFilter == null &&
                    (_rangeFilter == null || _rangeCounted))
                  Positioned(
                    right: 4,
                    top: 8,
                    child: AnimatedSlide(
                      offset: _jumpVisible ? Offset.zero : const Offset(1.4, 0),
                      duration: motionDuration(
                        context,
                        const Duration(milliseconds: 250),
                      ),
                      curve: Curves.easeOut,
                      child: AnimatedOpacity(
                        key: const ValueKey('jump-controls'),
                        opacity: _jumpVisible ? 1 : 0,
                        duration: motionDuration(
                          context,
                          const Duration(milliseconds: 250),
                        ),
                        child: IgnorePointer(
                          ignoring: !_jumpVisible,
                          child: _JumpControls(
                            onUp: () => _stepMonth(up: true),
                            onDown: () => _stepMonth(up: false),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  /// [done] replaces the `<what> set on N transactions.` wording for an
  /// edit that takes something off rather than setting it.
  void _afterBulk(
    int changed,
    String what, {
    required IconData icon,
    VoidCallback? onUndo,
    String? done,
  }) {
    if (!mounted) return;
    showAppToast(
      context,
      changed == 0
          ? 'No rows changed.'
          : done ??
                '$what set on $changed transaction'
                    '${changed == 1 ? '' : 's'}.',
      tone: changed == 0 ? AppToastTone.info : AppToastTone.change,
      icon: changed == 0 ? null : icon,
      duration: const Duration(seconds: 5),
      actionLabel: changed == 0 || onUndo == null ? null : 'Undo',
      onAction: changed == 0 ? null : onUndo,
    );
    setState(_selected.clear);
  }

  /// Bulk edits rewrite many rows at once with no per-row review, so they
  /// get a confirmation stating the blast radius first — the app's own undo
  /// contract reserves dialogs for exactly this (see undo_snackbar.dart).
  Future<bool> _confirmBulk(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  /// Pre-edit copies of the selected rows, captured for the Undo action.
  List<Tx> _selectedSnapshot(FinanceProvider finance) => [
    for (final t in finance.transactions)
      if (_selected.contains(t.id)) t,
  ];

  /// Bulk category. A category belongs to one side (income/expense), so the
  /// sheet offers only categories whose type appears in the selection, and
  /// the provider applies each one to matching-type rows only.
  Future<void> _bulkCategory(List<Tx> filtered) async {
    // The selection bar keeps taking taps while it folds away.
    if (_selected.isEmpty) return;
    final finance = context.read<FinanceProvider>();
    final selectedTxs = [
      for (final t in filtered)
        if (_selected.contains(t.id)) t,
    ];
    final types = {for (final t in selectedTxs) t.type};
    final options = [
      for (final c in allCategories)
        if (types.contains(c.type)) c,
    ];
    final picked = await showModalBottomSheet<TxCategory>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Set category', style: Theme.of(ctx).textTheme.titleLarge),
              if (types.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Mixed selection: the category applies only to rows of '
                    'its own type, income or expense.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final c in options)
                    ActionChip(
                      avatar: Icon(c.icon, size: 16, color: c.color),
                      label: categoryChipLabel(c),
                      onPressed: () => Navigator.pop(ctx, c),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final n = _selected.length;
    if (!await _confirmBulk(
      'Set category on $n transaction${n == 1 ? '' : 's'}?',
      'Rows of the matching type get the category '
          '"${picked.label}". Their current categories are replaced.',
    )) {
      return;
    }
    final snapshot = _selectedSnapshot(finance);
    final changed = await finance.setCategoryForMany(
      Set.of(_selected),
      picked.id,
    );
    _afterBulk(
      changed,
      'Category',
      icon: Icons.category_outlined,
      onUndo: () => finance.restoreEditedTransactions(snapshot),
    );
  }

  Future<void> _bulkAccount() async {
    if (_selected.isEmpty) return;
    final finance = context.read<FinanceProvider>();
    // Open accounts only — bulk-assigning rows INTO a closed account is
    // always a mistake; existing history on closed accounts is untouched.
    // No wallets while a transfer leg is selected: it can't go on one.
    final paired = _selectedSnapshot(finance).any((t) => t.pairId != null);
    final accounts = [
      for (final a in finance.openAccounts)
        if (!paired || !a.isWallet) a,
    ];
    if (accounts.isEmpty) {
      showAppToast(context, 'No accounts yet.');
      return;
    }
    final result = await showPickerSheet<String>(
      context: context,
      title: 'Assign to account',
      items: [
        for (final a in accounts)
          PickerItem(
            value: a.id,
            label: a.displayName,
            leading: Icon(a.icon, size: 18),
          ),
      ],
    );
    final picked = result?.value;
    if (picked == null || !mounted) return;
    final target = accounts.firstWhere((a) => a.id == picked);
    final n = _selected.length;
    // No Undo here: assignment also rewrites account key sets, which a row
    // snapshot cannot restore — the dialog carries the weight instead.
    if (!await _confirmBulk(
      'Assign $n transaction${n == 1 ? '' : 's'}?',
      'The selected transactions move to "${target.displayName}". Any stated '
          'balance they carry for another account is dropped.',
    )) {
      return;
    }
    final changed = await finance.assignAccountToMany(
      Set.of(_selected),
      picked,
    );
    _afterBulk(changed, 'Account', icon: Icons.account_balance_wallet_outlined);
  }

  Future<void> _bulkDateTime() async {
    if (_selected.isEmpty) return;
    final now = DateTime.now();
    final stamp = await pickDateThenTime(
      context,
      initial: now,
      firstDate: DateTime(2000),
      lastDate: now.add(const Duration(days: 1)),
    );
    if (stamp == null || !mounted) return;
    final n = _selected.length;
    final finance = context.read<FinanceProvider>();
    // The one bulk edit whose old values cannot be re-derived from the rows
    // themselves — confirm with the count, and keep an Undo snapshot.
    final moved = _selectedSnapshot(finance).any((t) => t.countIn != null);
    if (!await _confirmBulk(
      'Set date & time on $n transaction${n == 1 ? '' : 's'}?',
      'Every selected transaction is stamped '
          '${MaterialLocalizations.of(context).formatMediumDate(stamp)}, '
          '${TimeOfDay.fromDateTime(stamp).format(context)}. '
          'Their original dates are replaced'
          '${moved ? ', and any Count in date is removed' : ''}.',
    )) {
      return;
    }
    final snapshot = _selectedSnapshot(finance);
    final changed = await finance.setDateTimeForMany(Set.of(_selected), stamp);
    _afterBulk(
      changed,
      'Date & time',
      icon: Icons.edit_calendar_outlined,
      onUndo: () => finance.restoreEditedTransactions(snapshot),
    );
  }

  /// Bulk Count in: the month figures count the selected rows in another
  /// moment while their own dates, and so account balances, stay put.
  Future<void> _bulkCountIn() async {
    if (_selected.isEmpty) return;
    final finance = context.read<FinanceProvider>();
    final selectedTxs = _selectedSnapshot(finance);
    if (selectedTxs.isEmpty) return;
    // Rows already moved can go back to their own dates in one step.
    final movedCount = selectedTxs.where((t) => t.countIn != null).length;
    if (movedCount > 0) {
      final choice = await showPickerSheet<bool>(
        context: context,
        title: 'Count in',
        items: [
          const PickerItem(
            value: true,
            label: 'Pick a date…',
            leading: Icon(Icons.event_repeat_outlined, size: 18),
          ),
          PickerItem(
            value: false,
            label: movedCount == 1
                ? 'Count on its own date'
                : 'Count on their own dates',
            leading: const Icon(Icons.undo, size: 18),
          ),
        ],
      );
      if (choice == null || !mounted) return;
      if (choice.value == false) {
        await _applyCountIn(finance, null);
        return;
      }
    }
    if (!mounted) return;
    // Opens on a Count in already chosen, else the 1st of the month after
    // the newest selected row: the salary-on-the-30th case.
    final newest = selectedTxs
        .map((t) => t.date)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final existing = [for (final t in selectedTxs) ?t.countIn];
    final now = DateTime.now();
    final later = newest.isAfter(now) ? newest : now;
    final stamp = await pickDateThenTime(
      context,
      initial: existing.isNotEmpty
          ? existing.first
          : DateTime(newest.year, newest.month + 1),
      firstDate: DateTime(2000),
      // The end of the next month.
      lastDate: DateTime(later.year, later.month + 2, 0, 23, 59),
    );
    if (stamp == null || !mounted) return;
    await _applyCountIn(finance, stamp);
  }

  Future<void> _applyCountIn(FinanceProvider finance, DateTime? stamp) async {
    String rows(int n) => '$n transaction${n == 1 ? '' : 's'}';
    // Clearing touches only the rows that were moved; say that many.
    final moved = _selectedSnapshot(
      finance,
    ).where((t) => t.countIn != null).length;
    final ok = stamp == null
        ? await _confirmBulk(
            'Put ${rows(moved)} back on ${moved == 1 ? 'its' : 'their'} own '
                'date${moved == 1 ? '' : 's'}?',
            'Monthly totals, budgets, the recap, Trends and Breakdown go back '
                'to counting ${moved == 1 ? 'it on the date it' : 'them on '
                          'the dates they'} happened.',
          )
        : await _confirmBulk(
            'Count ${rows(_selected.length)} on ${fmtCountIn(stamp)}?',
            "Their own dates stay, so account balances don't change. Monthly "
                'totals, budgets, the recap, Trends and Breakdown count them '
                'in ${fmtMonth(stamp)}.',
          );
    if (!ok) return;
    final snapshot = _selectedSnapshot(finance);
    final changed = await finance.setCountInForMany(Set.of(_selected), stamp);
    _afterBulk(
      changed,
      'Count in',
      icon: Icons.event_repeat_outlined,
      onUndo: () => finance.restoreEditedTransactions(snapshot),
      done: stamp == null
          ? '${rows(changed)} back on '
                '${changed == 1 ? 'its own date' : 'their own dates'}.'
          : null,
    );
  }

  /// Bulk tags: add tags to every selected row, and take off tags some of
  /// them carry. Returns the rows' tags to what they were on Undo.
  Future<void> _bulkTags() async {
    if (_selected.isEmpty) return;
    final finance = context.read<FinanceProvider>();
    final selectedTxs = _selectedSnapshot(finance);
    // Tags on any selected row, in the order the rows list them. Not
    // normalizeTags: its cap of five per row would hide the rest here.
    final seen = <String>{};
    final present = [
      for (final t in selectedTxs)
        for (final tag in t.tags)
          if (seen.add(tagKey(tag))) tag,
    ];
    final result =
        await showModalBottomSheet<({Set<String> add, Set<String> remove})>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          builder: (ctx) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: _BulkTagSheet(
              present: present,
              suggestions: [for (final u in finance.allTags) u.tag],
            ),
          ),
        );
    if (result == null || !mounted) return;
    if (result.add.isEmpty && result.remove.isEmpty) return;
    final n = _selected.length;
    final parts = [
      if (result.add.isNotEmpty) 'adds ${result.add.join(', ')}',
      if (result.remove.isNotEmpty) 'removes ${result.remove.join(', ')}',
    ];
    if (!await _confirmBulk(
      'Tag $n transaction${n == 1 ? '' : 's'}?',
      'This ${parts.join(' and ')} on the selected transactions.',
    )) {
      return;
    }
    final before = await finance.setTagsForMany(
      Set.of(_selected),
      add: result.add,
      remove: result.remove,
    );
    _afterBulk(
      before.length,
      'Tags',
      icon: Icons.label_outline,
      onUndo: () => finance.restoreEditedTransactions(before),
    );
  }

  /// Marks the merchants of the selected expenses as subscriptions, with
  /// one cycle for all. Rows without a merchant (transfers, anonymous
  /// alerts) are skipped and counted. Undo puts back the previous marks and
  /// the hide list.
  Future<void> _bulkSubscription() async {
    if (_selected.isEmpty) return;
    final finance = context.read<FinanceProvider>();
    final settings = context.read<SettingsProvider>();
    final labels = <String, String>{};
    var skipped = 0;
    for (final t in _selectedSnapshot(finance)) {
      final key = t.type == TxType.expense ? recurringKeyOf(t) : null;
      if (key == null) {
        skipped++;
        continue;
      }
      labels.putIfAbsent(
        key,
        () => merchantDisplayLabel(t, alias: finance.merchantAlias),
      );
    }
    if (labels.isEmpty) {
      showAppToast(
        context,
        'None of these has a merchant to mark as a subscription.',
      );
      return;
    }
    final cycle = await showModalBottomSheet<SubscriptionCycle>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => _BulkSubscriptionSheet(
        labels: labels.values.toList(),
        skipped: skipped,
      ),
    );
    if (cycle == null || !mounted) return;
    final pinsBefore = finance.subscriptionPinsBefore(labels.keys);
    final hiddenBefore = settings.hiddenUpcoming;
    await finance.setSubscriptionPins({for (final k in labels.keys) k: cycle});
    for (final k in labels.keys) {
      await settings.unhideUpcoming(k);
    }
    if (!mounted) return;
    final n = labels.length;
    showAppToast(
      context,
      'Marked $n merchant${n == 1 ? '' : 's'} as '
      '${cycle.label.toLowerCase()} subscriptions.',
      tone: AppToastTone.change,
      icon: Icons.autorenew,
      duration: const Duration(seconds: 5),
      actionLabel: 'Undo',
      onAction: () async {
        await finance.setSubscriptionPins(pinsBefore);
        for (final k in labels.keys) {
          if (hiddenBefore.contains(k)) await settings.hideUpcoming(k);
        }
      },
    );
    setState(_selected.clear);
  }

  /// Exports exactly what the list is showing — same rows, same order.
  /// Rebuilt from the current filters rather than read from the last
  /// build: the Filters sheet applies its choices just before this runs.
  Future<void> _exportCsv() async {
    final finance = context.read<FinanceProvider>();
    final data = _pageDataFor(_filter, finance, finance.transactions);
    final rows = [for (final (_, tx) in data.rows) ?tx];
    final messenger = ScaffoldMessenger.of(context);
    if (rows.isEmpty) {
      showAppToastOn(messenger, 'Nothing to export.');
      return;
    }
    try {
      final path = await BackupService.exportCsvRows(rows);
      // Null = the save dialog was cancelled — not worth a snackbar.
      if (path != null && path.isNotEmpty) {
        showAppToastOn(
          messenger,
          'Saved to $path',
          tone: AppToastTone.success,
          icon: Icons.download_done,
        );
      }
    } catch (e) {
      debugPrint('CSV export failed: $e');
      showAppToastOn(messenger, 'Export failed.', tone: AppToastTone.error);
    }
  }

  Future<void> _bulkDelete() async {
    final finance = context.read<FinanceProvider>();
    final ids = Set<String>.of(_selected);
    if (ids.isEmpty) return;
    final count = ids.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $count transaction${count == 1 ? '' : 's'}?'),
        content: const Text(
          'They are removed from the ledger. Undo restores them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final removed = await finance.deleteTransactions(ids);
    if (!mounted || removed.isEmpty) return;
    setState(_selected.clear);
    showUndoSnackBar(
      context,
      'Deleted ${removed.length} transaction${removed.length == 1 ? '' : 's'}',
      () => finance.restoreTransactions(removed),
      icon: Icons.delete_sweep_outlined,
      tone: AppToastTone.removal,
    );
  }

  /// Links the two selected rows as one transfer (bank debit ↔ card credit,
  /// bank ↔ savings, …). The provider enforces the real rules — one money-in
  /// plus one money-out, neither already paired — so this only relays them.
  Future<void> _bulkPair() async {
    final finance = context.read<FinanceProvider>();
    final ids = _selected.toList();
    if (ids.length != 2) return;
    final pairId = await finance.pairTransactions(ids[0], ids[1]);
    if (!mounted) return;
    if (pairId == null) {
      final onWallet = finance.transactions.any(
        (t) =>
            ids.contains(t.id) &&
            finance.accountForKey(t.acctKey)?.isWallet == true,
      );
      showAppToast(
        context,
        onWallet
            ? "Wallet rows can't be paired as a transfer: the wallet "
                  'side stays out of totals.'
            : 'Pick one money-in and one money-out row; neither can '
                  'already be part of a pair.',
      );
      return;
    }
    setState(_selected.clear);
    showUndoSnackBar(
      context,
      'Paired as transfer',
      () => finance.unpair(pairId),
      icon: Icons.link,
    );
  }

  /// Month-header select toggle: selects every VISIBLE row of that month,
  /// or clears them when they are all already selected.
  void _selectMonth(DateTime month) {
    final ids = [
      for (final t in _activeData.groups[month] ?? const <Tx>[]) t.id,
    ];
    if (ids.isEmpty) return;
    // Only this branch can start selection mode: clearing needs a
    // selection to exist already.
    if (_selected.isEmpty) Haptics.tick();
    setState(() {
      if (ids.every(_selected.contains)) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
  }

  Future<void> _openFilterSheet() async {
    final selected = Set<String>.from(_categoryFilter);
    final selectedGroups = Set<String>.from(_groupFilter);
    final selectedBudgets = Set<String>.from(_budgetFilter);
    final selectedTags = Set<String>.from(_tagFilter);
    var accountId = _accountId;
    var month = _monthFilter;
    var range = _rangeFilter;
    // Live query narrowing the chip sections — the category list alone can
    // hold dozens of chips.
    var filterQuery = '';
    final finance = context.read<FinanceProvider>();
    final accounts = finance.accounts;
    final monthsWithData = finance.monthsWithData;
    final groups = finance.groups;
    final budgets = finance.budgets;
    final tags = finance.allTags;
    final minCtrl = TextEditingController(
      text: _minAmount == null ? '' : _minAmount!.toStringAsFixed(0),
    );
    final maxCtrl = TextEditingController(
      text: _maxAmount == null ? '' : _maxAmount!.toStringAsFixed(0),
    );
    final filterSearchCtrl = TextEditingController();
    // The sort is a view setting, not a filter: a pick applies at once (a
    // sheet swiped away keeps it) and Clear all leaves it alone.
    var sort = _sort;

    // Apply and Export CSV both commit the sheet's choices.
    void apply() {
      setState(() {
        _categoryFilter
          ..clear()
          ..addAll(selected);
        _groupFilter
          ..clear()
          ..addAll(selectedGroups);
        _budgetFilter
          ..clear()
          ..addAll(selectedBudgets);
        _tagFilter
          ..clear()
          ..addAll(selectedTags);
        // parseAmount: "1,000" must filter, not silently clear the bound
        // the user just typed.
        _minAmount = parseAmount(minCtrl.text);
        _maxAmount = parseAmount(maxCtrl.text);
        _accountId = accountId;
        _monthFilter = month;
        // The range the sheet opened with keeps its year flavour; any new
        // pick (or none) is a plain range.
        if (!identical(range, _rangeFilter)) _setRange(range);
      });
    }

    // True when the sheet closed through Export CSV.
    final exportAfter = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      // Keeps the sheet (and its drag handle) below the status bar / notch.
      useSafeArea: true,
      showDragHandle: true,
      // Disposal is tied to unmount, not to this future: the sheet keeps
      // rebuilding (and re-reading the controllers) through its exit
      // transition, which completes after the future does.
      builder: (ctx) => DisposeScope(
        disposables: [minCtrl, maxCtrl, filterSearchCtrl],
        child: StatefulBuilder(
          builder: (ctx, setSheetState) => Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Pinned header: the actions stay reachable however long the
                // filter content grows or when the keyboard is open — only the
                // content below scrolls. Wraps rather than overflowing: at
                // 320dp and 2x text the title and both buttons outgrew the
                // line, so the buttons drop under the title, and under each
                // other when even that is too narrow. Full width, or the
                // Column centres the Wrap and the title leaves the margin.
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 4,
                    children: [
                      Text(
                        'Filters',
                        key: const ValueKey('filters-title'),
                        style: Theme.of(ctx).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          TextButton(
                            // Resets the draft in place — everything else in the
                            // sheet waits for Apply, so Clear-all applying and
                            // closing immediately was the one inconsistent control.
                            onPressed: () {
                              minCtrl.clear();
                              maxCtrl.clear();
                              // Clearing the query too: mid-search, deselected
                              // chips would just vanish (only visible via the
                              // selected-chip escape hatch) and Clear-all read
                              // as a no-op.
                              filterSearchCtrl.clear();
                              setSheetState(() {
                                filterQuery = '';
                                selected.clear();
                                selectedGroups.clear();
                                selectedBudgets.clear();
                                selectedTags.clear();
                                accountId = null;
                                month = null;
                                range = null;
                              });
                            },
                            child: const Text('Clear all'),
                          ),
                          FilledButton(
                            onPressed: () {
                              apply();
                              Navigator.pop(ctx);
                            },
                            child: const Text('Apply'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Pinned like the header: narrows every chip section below.
                // Selected chips always stay visible so an active selection
                // can't become invisible/un-removable behind the query.
                TextField(
                  controller: filterSearchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search filters…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    suffixIcon: filterQuery.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              filterSearchCtrl.clear();
                              setSheetState(() => filterQuery = '');
                            },
                          ),
                  ),
                  onChanged: (v) =>
                      setSheetState(() => filterQuery = v.trim().toLowerCase()),
                ),
                Flexible(
                  child: Builder(
                    builder: (ctx) {
                      bool has(String label) =>
                          filterQuery.isEmpty ||
                          label.toLowerCase().contains(filterQuery);
                      final visAccounts = [
                        for (final a in accounts)
                          if (has(a.displayName) || accountId == a.id) a,
                      ];
                      final visBudgets = [
                        for (final b in budgets)
                          if (has(b.name) || selectedBudgets.contains(b.id)) b,
                      ];
                      final visGroups = [
                        for (final g in groups)
                          if (has(g.label) || selectedGroups.contains(g.id)) g,
                      ];
                      final showOther =
                          has('Other') ||
                          selectedGroups.contains(kUngroupedFilterKey);
                      final visTags = [
                        for (final u in tags)
                          if (has(u.tag) ||
                              selectedTags.contains(tagKey(u.tag)))
                            u.tag,
                      ];
                      final visCategories = [
                        for (final c in allCategories)
                          if (has(c.label) || selected.contains(c.id)) c,
                      ];
                      return SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Not narrowed by the filter query, like Date.
                            const SizedBox(height: 12),
                            Text(
                              'Sort by',
                              style: Theme.of(ctx).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                for (final s in _Sort.values)
                                  ChoiceChip(
                                    label: Text(_sortLabels[s]!),
                                    selected: sort == s,
                                    onSelected: (_) {
                                      setSheetState(() => sort = s);
                                      setState(() => _sort = s);
                                    },
                                  ),
                              ],
                            ),
                            // Not narrowed by the filter query: three fixed
                            // choices, and the one that is active must stay
                            // reachable.
                            const SizedBox(height: 12),
                            Text(
                              'Date',
                              style: Theme.of(ctx).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                ChoiceChip(
                                  label: const Text('All time'),
                                  selected: month == null && range == null,
                                  onSelected: (_) => setSheetState(() {
                                    month = null;
                                    range = null;
                                  }),
                                ),
                                ChoiceChip(
                                  label: Text(
                                    month == null ? 'Month…' : fmtMonth(month!),
                                  ),
                                  avatar: const Icon(
                                    Icons.calendar_month,
                                    size: 16,
                                  ),
                                  selected: month != null,
                                  onSelected: (_) async {
                                    final picked = await showMonthPickerSheet(
                                      ctx,
                                      title: 'Month',
                                      months: monthsWithData,
                                      selected: month,
                                    );
                                    if (picked == null) return;
                                    setSheetState(() {
                                      month = picked;
                                      range = null;
                                    });
                                  },
                                ),
                                ChoiceChip(
                                  // The range the sheet opened with keeps
                                  // its year name, as on the filter chip.
                                  label: Text(
                                    range == null
                                        ? 'Custom range…'
                                        : identical(range, _rangeFilter) &&
                                              _rangeLabel != null
                                        ? _rangeLabel!
                                        : fmtDateRange(range!),
                                  ),
                                  avatar: const Icon(
                                    Icons.date_range,
                                    size: 16,
                                  ),
                                  selected: range != null,
                                  onSelected: (_) async {
                                    final now = DateTime.now();
                                    final today = DateTime(
                                      now.year,
                                      now.month,
                                      now.day,
                                    );
                                    // A dashboard year still running ends
                                    // after today, which the picker rejects:
                                    // start it at the part up to today.
                                    final r = range;
                                    final initial =
                                        r == null || r.start.isAfter(today)
                                        ? null
                                        : r.end.isAfter(today)
                                        ? DateTimeRange(
                                            start: r.start,
                                            end: today,
                                          )
                                        : r;
                                    final picked = await showDateRangePicker(
                                      context: ctx,
                                      firstDate: DateTime(2000),
                                      lastDate: today,
                                      initialDateRange: initial,
                                    );
                                    if (picked == null) return;
                                    setSheetState(() {
                                      range = picked;
                                      month = null;
                                    });
                                  },
                                ),
                              ],
                            ),
                            if (visAccounts.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                'Account',
                                style: Theme.of(ctx).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  ChoiceChip(
                                    label: const Text('All'),
                                    selected: accountId == null,
                                    onSelected: (_) =>
                                        setSheetState(() => accountId = null),
                                  ),
                                  for (final a in visAccounts)
                                    ChoiceChip(
                                      label: Text(a.displayName),
                                      avatar: Icon(a.icon, size: 16),
                                      selected: accountId == a.id,
                                      onSelected: (_) =>
                                          setSheetState(() => accountId = a.id),
                                    ),
                                ],
                              ),
                            ],
                            if (visBudgets.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                'Budgets',
                                style: Theme.of(ctx).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  for (final b in visBudgets)
                                    FilterChip(
                                      label: Text(b.name),
                                      avatar: const Icon(
                                        Icons.track_changes,
                                        size: 16,
                                      ),
                                      selected: selectedBudgets.contains(b.id),
                                      onSelected: (on) => setSheetState(
                                        () => on
                                            ? selectedBudgets.add(b.id)
                                            : selectedBudgets.remove(b.id),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            // No groups.isNotEmpty gate: an active "Other"
                            // (ungrouped) filter must keep its chip — and
                            // its only ✕ — even after the last group is
                            // deleted.
                            if (visGroups.isNotEmpty || showOther) ...[
                              const SizedBox(height: 12),
                              Text(
                                'Groups',
                                style: Theme.of(ctx).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  for (final g in visGroups)
                                    FilterChip(
                                      label: Text(g.label),
                                      avatar: Icon(
                                        Icons.workspaces_outlined,
                                        size: 16,
                                        color: g.color,
                                      ),
                                      selected: selectedGroups.contains(g.id),
                                      onSelected: (on) => setSheetState(
                                        () => on
                                            ? selectedGroups.add(g.id)
                                            : selectedGroups.remove(g.id),
                                      ),
                                    ),
                                  if (showOther)
                                    FilterChip(
                                      label: const Text('Other'),
                                      avatar: const Icon(
                                        Icons.category,
                                        size: 16,
                                      ),
                                      selected: selectedGroups.contains(
                                        kUngroupedFilterKey,
                                      ),
                                      onSelected: (on) => setSheetState(
                                        () => on
                                            ? selectedGroups.add(
                                                kUngroupedFilterKey,
                                              )
                                            : selectedGroups.remove(
                                                kUngroupedFilterKey,
                                              ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            if (visTags.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                'Tags',
                                style: Theme.of(ctx).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  for (final tag in visTags)
                                    FilterChip(
                                      label: Text(tag),
                                      avatar: const Icon(
                                        Icons.label_outline,
                                        size: 16,
                                      ),
                                      selected: selectedTags.contains(
                                        tagKey(tag),
                                      ),
                                      onSelected: (on) => setSheetState(
                                        () => on
                                            ? selectedTags.add(tagKey(tag))
                                            : selectedTags.remove(tagKey(tag)),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            if (visCategories.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                'Categories',
                                style: Theme.of(ctx).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  for (final c in visCategories)
                                    FilterChip(
                                      label: categoryChipLabel(c),
                                      avatar: Icon(
                                        c.icon,
                                        size: 16,
                                        color: c.color,
                                      ),
                                      selected: selected.contains(c.id),
                                      onSelected: (on) => setSheetState(
                                        () => on
                                            ? selected.add(c.id)
                                            : selected.remove(c.id),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 16),
                            Text(
                              'Amount range',
                              style: Theme.of(ctx).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: minCtrl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: 'Min',
                                      prefixText: '₹ ',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextField(
                                    controller: maxCtrl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: 'Max',
                                      prefixText: '₹ ',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            const Divider(height: 1),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.ios_share),
                              title: const Text('Export CSV'),
                              subtitle: const Text(
                                'Applies these filters, then saves the rows '
                                'the list shows',
                              ),
                              onTap: () {
                                apply();
                                Navigator.pop(ctx, true);
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Run from this screen once the sheet has gone, so a save dialog never
    // opens over a route that is closing.
    if (exportAfter == true && mounted) await _exportCsv();
  }
}

/// The bulk Subscription sheet: which merchants the selection marks, and
/// the cycle for all of them. Pops the chosen cycle.
class _BulkSubscriptionSheet extends StatelessWidget {
  final List<String> labels;
  final int skipped;

  const _BulkSubscriptionSheet({required this.labels, required this.skipped});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final n = labels.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Mark $n merchant${n == 1 ? '' : 's'} as '
              'subscription${n == 1 ? '' : 's'}',
              style: text.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              [
                labels.join(', '),
                if (skipped > 0)
                  '$skipped row${skipped == 1 ? '' : 's'} skipped '
                      '(income, transfers, or no merchant).',
                'Every payment to ${n == 1 ? 'it' : 'them'} counts.',
              ].join(' · '),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            // Two rows of two: four across shrank each name to its own size
            // at 320dp.
            for (final (r, row) in [
              SubscriptionCycle.values.take(2).toList(),
              SubscriptionCycle.values.skip(2).toList(),
            ].indexed) ...[
              if (r > 0) const SizedBox(height: 8),
              Row(
                children: [
                  for (final (i, c) in row.indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => Navigator.pop(context, c),
                        child: cycleLabel(c.label),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The bulk Tag sheet: tags to add to every selected row, and the tags the
/// rows already carry, each removable from all of them.
class _BulkTagSheet extends StatefulWidget {
  /// Tags on any of the selected rows.
  final List<String> present;
  final List<String> suggestions;

  const _BulkTagSheet({required this.present, required this.suggestions});

  @override
  State<_BulkTagSheet> createState() => _BulkTagSheetState();
}

class _BulkTagSheetState extends State<_BulkTagSheet> {
  List<String> _add = const [];
  final Set<String> _remove = {};
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Tags', style: text.titleLarge),
            const SizedBox(height: 12),
            TagInput(
              tags: _add,
              controller: _ctrl,
              suggestions: widget.suggestions,
              onChanged: (t) => setState(() => _add = t),
            ),
            if (widget.present.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'On these rows · tap one to take it off all of them',
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in widget.present)
                    FilterChip(
                      label: Text('# $t', semanticsLabel: 'Tag $t'),
                      selected: !_remove.contains(t),
                      tooltip: _remove.contains(t) ? 'Keep $t' : 'Remove $t',
                      onSelected: (keep) => setState(
                        () => keep ? _remove.remove(t) : _remove.add(t),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(context, (
                    add: pendingTagsOf(_add, _ctrl).toSet(),
                    remove: Set.of(_remove),
                  )),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _MoreAction { selectAll, tags, subscription, dateTime, pair }

/// Action bar shown while transactions are selected: the count, the four
/// most used bulk edits as labelled icons, and the rest behind More. A
/// fixed row: nothing scrolls off screen, whatever the width or text size.
class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onCategory;
  final VoidCallback onAccount;
  final VoidCallback onCountIn;
  final VoidCallback onDateTime;
  final VoidCallback onTags;
  final VoidCallback onSubscription;

  /// Null hides the menu item (shown only with exactly two rows selected).
  final VoidCallback? onPair;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const _SelectionBar({
    required this.count,
    required this.onSelectAll,
    required this.onCategory,
    required this.onAccount,
    required this.onCountIn,
    required this.onDateTime,
    required this.onTags,
    required this.onSubscription,
    required this.onPair,
    required this.onDelete,
    required this.onClose,
  });

  PopupMenuItem<_MoreAction> _item(
    _MoreAction value,
    String key,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    key: ValueKey('bulk-more-$key'),
    value: value,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Flexible(child: Text(label)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: FrostedPanel(
        radius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Clear selection',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: _kBarIconSize),
                onPressed: onClose,
              ),
              _SelectedCount(count: count, color: scheme.primary),
              Expanded(
                child: _BarAction(
                  icon: Icons.category_outlined,
                  label: 'Category',
                  tooltip: 'Set category',
                  onTap: onCategory,
                ),
              ),
              Expanded(
                child: _BarAction(
                  icon: Icons.account_balance_outlined,
                  label: 'Account',
                  tooltip: 'Assign account',
                  onTap: onAccount,
                ),
              ),
              Expanded(
                child: _BarAction(
                  icon: Icons.event_repeat_outlined,
                  label: 'Count in',
                  tooltip: 'Count in another date',
                  onTap: onCountIn,
                ),
              ),
              Expanded(
                child: _BarAction(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  tooltip: 'Delete',
                  onTap: onDelete,
                  color: scheme.error,
                ),
              ),
              PopupMenuButton<_MoreAction>(
                tooltip: 'More actions',
                icon: const Icon(Icons.more_vert, size: _kBarIconSize),
                // Compact like Close, so each labelled action keeps about
                // 48dp of width on a 320dp phone.
                style: IconButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                // Instant, as on the Accounts menu: the grow animation
                // re-clamps the menu's position every frame.
                popUpAnimationStyle: const AnimationStyle(
                  duration: Duration.zero,
                ),
                onSelected: (v) {
                  switch (v) {
                    case _MoreAction.selectAll:
                      onSelectAll();
                    case _MoreAction.tags:
                      onTags();
                    case _MoreAction.subscription:
                      onSubscription();
                    case _MoreAction.dateTime:
                      onDateTime();
                    case _MoreAction.pair:
                      onPair?.call();
                  }
                },
                itemBuilder: (_) => [
                  _item(
                    _MoreAction.selectAll,
                    'select-all',
                    Icons.select_all,
                    'Select all shown',
                  ),
                  _item(_MoreAction.tags, 'tags', Icons.label_outline, 'Tags'),
                  _item(
                    _MoreAction.subscription,
                    'subscription',
                    Icons.autorenew,
                    'Mark as subscription',
                  ),
                  _item(
                    _MoreAction.dateTime,
                    'date-time',
                    Icons.edit_calendar_outlined,
                    'Date & time',
                  ),
                  if (onPair != null)
                    _item(
                      _MoreAction.pair,
                      'pair',
                      Icons.link,
                      'Pair as transfer',
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Icon size across the selection bar: close, actions and More alike.
const double _kBarIconSize = 18;

/// The selection count: the number alone at the icons' size, centred in
/// the bar's height. Shrinks to fit rather than crowding the actions.
class _SelectedCount extends StatelessWidget {
  final int count;
  final Color color;
  const _SelectedCount({required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$count selected',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, maxWidth: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          // FittedBox centres the number in the 48dp height.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$count',
              maxLines: 1,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: _kBarIconSize,
                height: 1,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The smallest a selection-bar label may be scaled to fit, as a share of
/// its size at the user's text scale.
@visibleForTesting
const double kMinLabelScale = 0.75;

/// One labelled selection-bar action: icon over a one-line label, or the
/// icon alone when the label can't fit readably.
class _BarAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  const _BarAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: color);
    // One node for screen readers: the name once, and the tap re-exposed
    // because excludeSemantics drops the InkWell's own action.
    return Semantics(
      button: true,
      label: tooltip,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: LayoutBuilder(
                builder: (context, box) {
                  // The label shrinks a little to fit ("Category" is wider
                  // than its quarter of a 320dp bar), but never below
                  // kMinLabelScale: large text would otherwise come out
                  // small. Past that the action is its icon alone, named by
                  // the tooltip and the screen-reader label.
                  final painter = TextPainter(
                    text: TextSpan(text: label, style: style),
                    maxLines: 1,
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                  )..layout();
                  final natural = painter.width;
                  painter.dispose();
                  final fits = natural * kMinLabelScale <= box.maxWidth;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: _kBarIconSize, color: color),
                      if (fits) ...[
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(label, maxLines: 1, style: style),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchAndFilterBar extends StatelessWidget {
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSearch;
  final VoidCallback onClearSearch;
  final _Filter filter;
  final ValueChanged<_Filter> onFilter;
  final bool hasAdvancedFilters;

  /// The Filters sheet, which also holds the sort and Export CSV.
  final VoidCallback onOpenFilters;

  const _SearchAndFilterBar({
    required this.searchCtrl,
    required this.onSearch,
    required this.onClearSearch,
    required this.filter,
    required this.onFilter,
    required this.hasAdvancedFilters,
    required this.onOpenFilters,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        children: [
          // Listen to the controller directly: this widget only rebuilds on
          // the 250ms debounce, so the ✕ used to appear a beat after the
          // first keystroke.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: searchCtrl,
            builder: (context, value, _) => TextField(
              controller: searchCtrl,
              onChanged: onSearch,
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: const Icon(Icons.search),
                // Sort, filters and export sit behind one button in the
                // field, so the search gets the whole row.
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (value.text.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          searchCtrl.clear();
                          // Immediate, not debounced: clearing should
                          // never lag behind the tap.
                          onClearSearch();
                        },
                      ),
                    IconButton(
                      tooltip: 'Sort, filter and export',
                      icon: Badge(
                        isLabelVisible: hasAdvancedFilters,
                        child: const Icon(Icons.tune),
                      ),
                      onPressed: onOpenFilters,
                    ),
                  ],
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: ChipTabs<_Filter>(
              options: const [
                (_Filter.all, 'All'),
                (_Filter.income, 'Income'),
                (_Filter.expense, 'Expenses'),
                (_Filter.transfers, 'Transfers'),
              ],
              selected: filter,
              onChanged: onFilter,
            ),
          ),
        ],
      ),
    );
  }
}

/// Space above a list month header's label.
const double _kMonthHeaderTop = 24;

/// [_kMonthHeaderTop] for the list's first header while the "N new" line
/// shows above it.
const double _kMonthHeaderTopUnderLine = 4;

/// The most of the tab's height the open review cards take together; past
/// it they scroll inside that space.
const double _kReviewCardsShare = 0.4;

/// Room a month header keeps beside its name for the Select month button:
/// the 18dp icon, its padding and the compact tap target around it.
const double _kSelectMonthWidth = 48;

/// Width of [text] on one line as a `Text` with [style] lays it out here:
/// same default style, bold-text setting and text scale.
double _labelWidth(BuildContext context, String text, TextStyle style) {
  var effective = DefaultTextStyle.of(context).style.merge(style);
  if (MediaQuery.boldTextOf(context)) {
    effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
  }
  final painter = TextPainter(
    text: TextSpan(text: text, style: effective),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// A month header's content height, list row and sticky band alike: the
/// Select month button's compact tap target, or taller for large text.
/// One value for both, so the labels line up at the hand-off.
double _monthHeaderRowHeight(BuildContext context) =>
    math.max(40, MediaQuery.textScalerOf(context).scale(12) * 1.4);

/// The income and spend totals of [txs] as the list headers show them.
/// Own-account transfers are audit entries: the totals mirror the
/// dashboard's income/expense figures, which exclude them, and leave out
/// uncounted wallet rows the same way. A linked refund is not income: it
/// comes off its purchase's spend instead.
(double, double) _listTotals(List<Tx> txs, FinanceProvider finance) {
  final income = txs
      .where(
        (t) =>
            t.type == TxType.income &&
            !isTransferCategory(t.categoryId) &&
            finance.countsInTotals(t) &&
            !finance.isLinkedRefund(t),
      )
      .fold(0.0, (s, t) => s + t.amount);
  final expense = txs
      .where(
        (t) =>
            t.type == TxType.expense &&
            !isTransferCategory(t.categoryId) &&
            finance.countsInTotals(t),
      )
      // netSpendOf: group splits count only the user's own share here,
      // less any refund linked to the row, matching the dashboard's Spent
      // card.
      .fold(0.0, (s, t) => s + finance.netSpendOf(t));
  return (income, expense);
}

/// The label above a day's rows under a date sort: "Today", "Yesterday" or
/// the weekday and date, with the day's net on the right, green when money
/// came in on balance and red when it went out. The rows under it show
/// their times, not the date again.
class _DayHeader extends StatelessWidget {
  final DateTime day;

  /// That day's rows in this month's list.
  final List<Tx> txs;

  const _DayHeader({required this.day, required this.txs});

  /// Totals per day list, as [_MonthHeader] caches its own.
  static final _totals = Expando<(double, double)>();

  static final _format = DateFormat('EEE d MMM');

  @override
  Widget build(BuildContext context) {
    final (income, expense) = _totals[txs] ??= _listTotals(
      txs,
      context.read<FinanceProvider>(),
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(day.year, day.month, day.day);
    final label = date == today
        ? 'Today'
        : date == DateTime(now.year, now.month, now.day - 1)
        ? 'Yesterday'
        : _format.format(date);

    // Like the month header, a day with nothing counted shows no figure. A
    // net would give away a hidden income, so that day shows the mask.
    String? total;
    Color? totalColor;
    if (income > 0 || expense > 0) {
      final net = income - expense;
      // Read only on a day with income, as the month header does.
      final masked =
          income > 0 &&
          context.select<SettingsProvider, bool>((s) => s.hideIncome);
      total = masked
          ? kMaskedAmount
          : net > 0
          ? '+${fmtMoneyTidy(net)}'
          : fmtMoneyTidy(net);
      // A masked net keeps the plain colour: its sign would give it away.
      if (!masked) totalColor = signedMoneyColor(context, net);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, AppSpace.gap, 20, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (total != null) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  total,
                  maxLines: 1,
                  style: style?.copyWith(color: totalColor),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final DateTime month;
  final List<Tx> txs;

  /// Selects (or clears) every visible row of this month.
  final VoidCallback? onSelectMonth;

  /// The sticky copy: tight padding so it covers as few rows as it can.
  final bool compact;

  /// The gap above the row in the list (see _headerTopAt); the sticky copy
  /// has none.
  final double top;

  const _MonthHeader({
    required this.month,
    required this.txs,
    this.onSelectMonth,
    this.compact = false,
    this.top = _kMonthHeaderTop,
  });

  /// Totals per month list: the sticky copy rebuilds on every scroll frame,
  /// and the lists are rebuilt (new keys) whenever the rows change.
  static final _totals = Expando<(double, double)>();

  @override
  Widget build(BuildContext context) {
    final (income, expense) = _totals[txs] ??= _listTotals(
      txs,
      context.read<FinanceProvider>(),
    );
    final scheme = Theme.of(context).colorScheme;

    final now = DateTime.now();
    // Large text takes the short name ("OCT"), so the name and the totals
    // still share the line.
    final name = isLargeTextScale(context) ? 'MMM' : 'MMMM';
    final label = (month.year == now.year)
        ? DateFormat(name).format(month).toUpperCase()
        : DateFormat('$name yyyy').format(month).toUpperCase();

    return Padding(
      // Right padding matches the jump-controls column width so the label
      // never slides under the nav pill.
      padding: compact
          ? const EdgeInsets.fromLTRB(20, 0, 52, 0)
          : EdgeInsets.fromLTRB(20, top, 52, 6),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: _monthHeaderRowHeight(context)),
        child: _row(context, scheme, label, income, expense),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    ColorScheme scheme,
    String label,
    double income,
    double expense,
  ) => LayoutBuilder(
    builder: (context, box) {
      // accentTextColor, not scheme.primary: same 4.5:1 fix as
      // UppercaseSectionHeader: the raw accent read at ~2.5:1 on the light
      // surface (the amounts beside it were already bumped for exactly
      // this).
      final labelStyle = TextStyle(
        color: accentTextColor(context),
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.4,
      );
      // Large text: the short name ("OCT") stays whole and the totals take
      // what is left, up to their usual cap; capped at 160 alone they left
      // the list copy "O…" beside its Select month button. Both copies
      // reserve that button's width, so their totals match at the hand-off.
      var totalsCap = 160.0;
      if (isLargeTextScale(context)) {
        final name = _labelWidth(context, label, labelStyle);
        totalsCap = (box.maxWidth - name - _kSelectMonthWidth - 8 - 1).clamp(
          40.0,
          160.0,
        );
      }
      return _rowWith(
        context,
        scheme,
        label,
        labelStyle,
        totalsCap,
        income,
        expense,
      );
    },
  );

  Widget _rowWith(
    BuildContext context,
    ColorScheme scheme,
    String label,
    TextStyle labelStyle,
    double totalsCap,
    double income,
    double expense,
  ) => Row(
    children: [
      // Expanded, so the totals always end at the right edge. With a
      // Flexible name beside a Spacer the two split the free space, and the
      // totals moved with the name's length and the icon beside it: the
      // pinned copy's sat left of the list header's.
      Expanded(
        child: Row(
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
            ),
            // The pinned copy opens the month list: the arrow says so.
            if (compact)
              Icon(
                Icons.arrow_drop_down,
                size: 18,
                color: accentTextColor(context),
              ),
            // Beside the name, not the amounts: it acts on the month, and
            // next to the totals it read as an amount action.
            if (onSelectMonth != null)
              IconButton(
                tooltip: 'Select month',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                constraints: const BoxConstraints(),
                icon: Icon(
                  Icons.checklist,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: onSelectMonth,
              ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      // Width-capped as one unit: at large text scales the pair shrinks
      // to fit instead of overflowing past the jump controls.
      if (income > 0 || expense > 0)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: totalsCap),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Money in green, money out red, as on the rows below.
                if (income > 0)
                  Text(
                    context.select<SettingsProvider, bool>((s) => s.hideIncome)
                        ? '+$kMaskedAmount'
                        : '+${fmtMoneyCompact(income)}',
                    style: TextStyle(
                      color: moneyColor(context, type: TxType.income),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                if (income > 0 && expense > 0) const SizedBox(width: 6),
                if (expense > 0)
                  Text(
                    '−${fmtMoneyCompact(expense)}',
                    style: TextStyle(
                      color: moneyColor(context, type: TxType.expense),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ),
    ],
  );
}

/// Width of the month jump panel: slim, so it covers little of the rows,
/// inside the 52dp gutter [_MonthHeader] keeps clear.
const double _kJumpControlsWidth = 32;

/// The month jump panel: up and down only. The month list opens from the
/// sticky month band instead. Each button is a tall 48dp target in the
/// slim width.
class _JumpControls extends StatelessWidget {
  final VoidCallback onUp;
  final VoidCallback onDown;

  const _JumpControls({required this.onUp, required this.onDown});

  @override
  Widget build(BuildContext context) {
    final style = IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(_kJumpControlsWidth, 48),
      fixedSize: const Size(_kJumpControlsWidth, 48),
      padding: EdgeInsets.zero,
    );
    return FrostedPanel(
      child: SizedBox(
        width: _kJumpControlsWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The list runs newest first, so up is the newer month.
            IconButton(
              key: const ValueKey('jump-up'),
              tooltip: 'Newer month',
              style: style,
              icon: const Icon(Icons.keyboard_double_arrow_up, size: 20),
              onPressed: onUp,
            ),
            IconButton(
              key: const ValueKey('jump-down'),
              tooltip: 'Older month',
              style: style,
              icon: const Icon(Icons.keyboard_double_arrow_down, size: 20),
              onPressed: onDown,
            ),
          ],
        ),
      ),
    );
  }
}

/// A review card's title in its fold header, with the "i" beside it only
/// while the card is open; folded, the title shows alone. The title itself
/// stays plain: a tap on the header folds the card.
class _FoldTitle extends StatelessWidget {
  final bool collapsed;
  final Widget label;
  final InfoTip tip;

  const _FoldTitle({
    required this.collapsed,
    required this.label,
    required this.tip,
  });

  @override
  Widget build(BuildContext context) =>
      collapsed ? label : InfoLabel(icon: true, label: label, tip: tip);
}

/// The review cards' capped area. When the cards outgrow it, it says so: a
/// scrollbar that stays visible, and, while more lies below, the last card
/// fades out over its bottom 24dp and ends on the card's rounded corners
/// instead of a flat cut.
class _ReviewCardsScroll extends StatefulWidget {
  final Widget child;
  const _ReviewCardsScroll({required this.child});

  @override
  State<_ReviewCardsScroll> createState() => _ReviewCardsScrollState();
}

class _ReviewCardsScrollState extends State<_ReviewCardsScroll> {
  final _ctrl = ScrollController();

  /// The cards are taller than the area.
  bool _overflow = false;

  /// Some of them lie below the area's bottom edge.
  bool _moreBelow = false;

  /// Applied in a microtask: metrics change during layout, where a
  /// setState is not allowed.
  void _update(ScrollMetrics m) {
    final overflow = m.maxScrollExtent > 0.5;
    final moreBelow = m.extentAfter > 0.5;
    if (overflow == _overflow && moreBelow == _moreBelow) return;
    scheduleMicrotask(() {
      if (!mounted) return;
      if (overflow == _overflow && moreBelow == _moreBelow) return;
      setState(() {
        _overflow = overflow;
        _moreBelow = moreBelow;
      });
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A fold or a new row changes the height without a scroll: check after
    // every layout this widget takes part in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _ctrl.hasClients && _ctrl.position.hasContentDimensions) {
        _update(_ctrl.position);
      }
    });
    // The same widgets every time, only their settings change: swapping a
    // wrapper in or out would rebuild the cards and lose their state.
    return NotificationListener<Notification>(
      onNotification: (n) {
        // Depth 0 only: the review list inside a card scrolls too.
        if (n is ScrollMetricsNotification && n.depth == 0) {
          _update(n.metrics);
        } else if (n is ScrollNotification && n.depth == 0) {
          _update(n.metrics);
        }
        return false;
      },
      child: Scrollbar(
        controller: _ctrl,
        thumbVisibility: _overflow,
        child: ClipPath(
          clipper: _CardBottomClip(rounded: _moreBelow),
          child: ShaderMask(
            // dstIn keeps the cards where the gradient is opaque; dst
            // leaves them untouched.
            blendMode: _moreBelow ? BlendMode.dstIn : BlendMode.dst,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: const [Colors.black, Colors.black, Colors.transparent],
              stops: [0, rect.height <= 24 ? 0 : 1 - 24 / rect.height, 1],
            ).createShader(rect),
            child: SingleChildScrollView(
              key: const ValueKey('review-cards'),
              controller: _ctrl,
              primary: false,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Clips the review cards' area. While a card runs past its bottom edge,
/// the edge follows the cards' rounded corners (inside their 16dp side
/// margins); otherwise it is the plain rectangle.
class _CardBottomClip extends CustomClipper<Path> {
  final bool rounded;
  const _CardBottomClip({required this.rounded});

  @override
  Path getClip(Size size) {
    if (!rounded) return Path()..addRect(Offset.zero & size);
    const inset = 16.0;
    const r = Radius.circular(AppRadius.card);
    return Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, math.max(0, size.height - r.y)))
      ..addRRect(
        RRect.fromLTRBAndCorners(
          inset,
          0,
          math.max(inset, size.width - inset),
          size.height,
          bottomLeft: r,
          bottomRight: r,
        ),
      );
  }

  @override
  bool shouldReclip(_CardBottomClip old) => old.rounded != rounded;
}

/// Review queue for regular SMS imports: confirm/discard each, or the batch.
/// Also holds the refunds already counted that look like they belong to a
/// purchase.
class _PendingReviewCard extends StatelessWidget {
  final List<Tx> pending;

  /// "Looks like a transfer" cards, shown above the list. At most three
  /// together with [refundSuggestions].
  final List<PairSuggestion> suggestions;

  /// "Looks like a refund" cards, after the transfers.
  final List<RefundSuggestion> refundSuggestions;

  /// Refund suggestions for confirmed rows, which count in the title.
  final int pastRefunds;
  const _PendingReviewCard({
    required this.pending,
    this.suggestions = const [],
    this.refundSuggestions = const [],
    this.pastRefunds = 0,
  });

  // Bulk and effectively irreversible (rows join the ledger with no batch
  // inverse) — warrants a dialog instead of an Undo snackbar.
  Future<void> _confirmAll(BuildContext context) async {
    final finance = context.read<FinanceProvider>();
    final count = pending.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirm all $count transaction${count == 1 ? '' : 's'}?'),
        content: const Text(
          'They join the ledger as reviewed entries. '
          'Suspected spam stays in its own queue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm all'),
          ),
        ],
      ),
    );
    if (ok == true) await finance.confirmAllPending();
  }

  Future<void> _discardAll(BuildContext context) async {
    final finance = context.read<FinanceProvider>();
    final count = pending.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Discard all $count import${count == 1 ? '' : 's'}?'),
        content: const Text(
          'They leave the review queue without joining the ledger. '
          'Suspected spam stays in its own queue. Undo restores them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard all'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final removed = await finance.discardAllPending();
    if (removed.isEmpty || !context.mounted) return;
    showUndoSnackBar(
      context,
      'Discarded ${removed.length} import${removed.length == 1 ? '' : 's'}',
      () => finance.restoreTransactions(removed),
      icon: Icons.block,
      tone: AppToastTone.removal,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final collapsed = context.watch<SettingsProvider>().isSectionCollapsed(
      'pending_review',
    );
    // A row shown in a suggestion card above leaves the list: it would
    // otherwise show twice.
    final inCards = {
      for (final s in suggestions) ...[s.out.id, s.incoming.id],
      for (final s in refundSuggestions) ...[s.refund.id, s.purchase.id],
    };
    final rows = [
      for (final t in pending)
        if (!inCards.contains(t.id)) t,
    ];
    // The plain card fill: tinted, every line on it was text on a colour.
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => context.read<SettingsProvider>().toggleSection(
              'pending_review',
            ),
            child: Padding(
              // 4 + the tip's 32dp target + 4: the old 10 + 20 + 10 height,
              // so the pinned cards leave the list the same room. The row
              // keeps that height folded too, where the tip is gone.
              padding: const EdgeInsets.fromLTRB(
                AppSpace.card,
                4,
                AppSpace.card,
                4,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: Row(
                  children: [
                    Icon(Icons.sms, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _FoldTitle(
                          collapsed: collapsed,
                          label: Text(
                            'Imported from SMS · '
                            '${pending.length + pastRefunds} to review',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          tip: const InfoTip(
                            title: 'Imported from SMS',
                            message:
                                'These imports need a look: the app was not '
                                'sure of their account, category or whether '
                                'they are a transfer. They count once you '
                                'confirm them. Other imports already count '
                                'and show as new in the list.',
                            link: InfoLink(
                              prompt: 'Imports classified wrong?',
                              label: 'Set up transaction rules',
                              onTap: goCockpitRules,
                            ),
                          ),
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: collapsed ? 0.5 : 0,
                      duration: AnimatedFold.duration,
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_less,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedFold(
            collapsed: collapsed,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Two legs of one own-account move arrive as an expense and
                // an income; pairing books both as transfers so neither
                // inflates Spent or Income.
                for (final s in suggestions)
                  _TransferSuggestionRow(suggestion: s),
                // A refund linked to its purchase takes that spend down
                // instead of counting as income.
                for (final s in refundSuggestions)
                  _RefundSuggestionRow(suggestion: s),
                if (rows.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      // Explicit: otherwise the list absorbs the extend-body
                      // safe-area insets as phantom top/bottom padding.
                      padding: EdgeInsets.zero,
                      itemCount: rows.length,
                      itemBuilder: (context, i) => _PendingRow(tx: rows[i]),
                    ),
                  ),
                // Bulk actions live inside the fold: a collapsed card can't
                // fire them, and the wrapped title above keeps its room.
                // Under the list, so the rows come first. Compact
                // everywhere: two review cards + toolbar + list must fit
                // short viewports without overflowing the tab Column. An
                // OverflowBar: at 320dp with large text the two buttons
                // stack, right-aligned, instead of running off the card.
                if (pending.isNotEmpty)
                  Padding(
                    key: const ValueKey('review-bulk-actions'),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.end,
                      children: [
                        // Plain text: the dialog's red button carries the
                        // warning.
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.onSurface,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => _discardAll(context),
                          child: const Text('Discard all'),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => _confirmAll(context),
                          child: const Text('Confirm all'),
                        ),
                      ],
                    ),
                  )
                else
                  const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A suggestion side's account: its name, else the SMS sender.
String _side(FinanceProvider finance, Tx t) =>
    finance.accountForKey(t.acctKey)?.name ??
    (t.sender.isNotEmpty ? t.sender : 'Unknown account');

/// One "Looks like a transfer" suggestion: pair the two legs, or dismiss
/// the guess for good.
class _TransferSuggestionRow extends StatelessWidget {
  final PairSuggestion suggestion;
  const _TransferSuggestionRow({required this.suggestion});

  @override
  Widget build(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    final s = suggestion;
    final kindLabel = switch (s.kind) {
      PairKind.cardPayment => 'card payment',
      PairKind.savings => 'savings deposit',
      PairKind.transfer => 'transfer',
    };
    return _SuggestionCard(
      icon: Icons.sync_alt,
      kind: 'Looks like a $kindLabel',
      sides: [
        (label: _side(finance, s.out), tx: s.out),
        (label: _side(finance, s.incoming), tx: s.incoming),
      ],
      dismissLabel: 'Not a transfer',
      onDismiss: () {
        final settings = context.read<SettingsProvider>();
        final key = s.key;
        // The toast goes up before the dismissal notifies: this card
        // leaves the tree once it does.
        showUndoSnackBar(
          context,
          'Marked not a $kindLabel',
          () => settings.restorePairSuggestion(key),
          icon: Icons.link_off,
        );
        settings.dismissPairSuggestion(key);
      },
      acceptLabel: 'Pair',
      onAccept: () async {
        // Taken first: the paired rows leave the queue, and this card
        // with them, before the save completes.
        final messenger = ScaffoldMessenger.of(context);
        final pairId = await finance.pairTransactions(s.out.id, s.incoming.id);
        if (pairId == null) return;
        _undoToastOn(
          messenger,
          'Paired as $kindLabel',
          () => finance.unpair(pairId),
        );
      },
    );
  }
}

/// [showUndoSnackBar] on a messenger taken before an await, for a card
/// that may have left the tree by then.
void _undoToastOn(
  ScaffoldMessengerState messenger,
  String message,
  VoidCallback undo,
) => showAppToastOn(
  messenger,
  message,
  tone: AppToastTone.change,
  icon: Icons.link,
  actionLabel: 'Undo',
  onAction: undo,
  duration: const Duration(seconds: 5),
);

/// One "Looks like a refund" suggestion: link the refund to the purchase
/// it gives money back for, or dismiss the guess for good.
class _RefundSuggestionRow extends StatelessWidget {
  final RefundSuggestion suggestion;
  const _RefundSuggestionRow({required this.suggestion});

  @override
  Widget build(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    final s = suggestion;
    return _SuggestionCard(
      icon: Icons.undo,
      kind: 'Looks like a refund',
      sides: [
        (
          label:
              finance.merchantLabelFor(s.purchase) ?? s.purchase.category.label,
          tx: s.purchase,
        ),
        (label: _side(finance, s.refund), tx: s.refund),
      ],
      dismissLabel: 'Not a refund',
      onDismiss: () {
        final settings = context.read<SettingsProvider>();
        final key = s.key;
        final refundId = s.refund.id;
        final past = !s.refund.pending;
        // As Not a transfer: the toast first, then the dismissal.
        showUndoSnackBar(context, 'Marked not a refund', () {
          settings.restorePairSuggestion(key);
          if (past) finance.restoreRefundReviewId(refundId);
        }, icon: Icons.link_off);
        settings.dismissPairSuggestion(key);
        // A counted refund the one-time pass offered stops being looked at.
        if (past) finance.dropRefundReviewId(refundId);
      },
      acceptLabel: 'Link',
      onAccept: () async {
        // Taken first: a linked refund leaves the queue, and this card
        // with it, before the save completes.
        final messenger = ScaffoldMessenger.of(context);
        final before = s.refund;
        final linked = await finance.linkRefund(before.id, s.purchase.id);
        if (!linked) return;
        // Putting the row back as it was also returns a refund that was
        // in review to the queue, which unlinking alone would not; a past
        // refund goes back on the one-time pass's list.
        _undoToastOn(messenger, 'Linked as a refund', () {
          finance.restoreEditedTransactions([before]);
          if (!before.pending) finance.restoreRefundReviewId(before.id);
        });
      },
    );
  }
}

/// A suggestion as its own outlined card inside the review card: what the
/// match looks like, one line per side (its account or merchant and date
/// on the left, its signed amount on the right), then dismiss and accept.
class _SuggestionCard extends StatelessWidget {
  final IconData icon;
  final String kind;
  final List<({String label, Tx tx})> sides;
  final String dismissLabel;
  final VoidCallback onDismiss;
  final String acceptLabel;
  final VoidCallback onAccept;

  const _SuggestionCard({
    required this.icon,
    required this.kind,
    required this.sides,
    required this.dismissLabel,
    required this.onDismiss,
    required this.acceptLabel,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpace.card, 4, AppSpace.card, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  kind,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final side in sides)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Two lines before a long account name is cut.
                  Expanded(
                    flex: 3,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: side.label),
                          // The day alone: with the time the line wrapped
                          // at 360dp, and the two sides are hours apart.
                          TextSpan(
                            text:
                                ' · ${fmtDateCompact(DateUtils.dateOnly(side.tx.date))}',
                            style: muted,
                          ),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // At most 2/5 of the line: a large figure at a large
                  // text scale shrinks rather than push the name out.
                  Flexible(
                    flex: 2,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Text(
                        '${side.tx.type == TxType.income ? '+' : '−'}'
                        '${fmtMoneyTidy(side.tx.amount)}',
                        style: text.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: moneyColor(
                            context,
                            type: side.tx.type,
                            transfer: isTransferCategory(side.tx.categoryId),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Stacks, right-aligned, when the two buttons do not fit side by
          // side (320dp with large text).
          OverflowBar(
            alignment: MainAxisAlignment.end,
            overflowAlignment: OverflowBarAlignment.end,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onDismiss,
                child: Text(dismissLabel),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onAccept,
                child: Text(acceptLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Suspected spam: individually reviewed only — deliberately no batch action.
class _SuspectedSpamCard extends StatelessWidget {
  final List<Tx> suspects;
  const _SuspectedSpamCard({required this.suspects});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final collapsed = context.watch<SettingsProvider>().isSectionCollapsed(
      'spam_review',
    );
    // The warning lives on the outline and icon, not a pink fill under text.
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: scheme.error.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () =>
                context.read<SettingsProvider>().toggleSection('spam_review'),
            child: Padding(
              // 4 + the tip's 32dp target + 4, as on the review card, and
              // the same height folded.
              padding: const EdgeInsets.fromLTRB(
                AppSpace.card,
                4,
                AppSpace.card,
                4,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _FoldTitle(
                          collapsed: collapsed,
                          label: Text(
                            'Suspected spam · ${suspects.length} to review',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          tip: const InfoTip(
                            title: 'Suspected spam',
                            message:
                                'Messages containing one of the Flagged as '
                                "spam phrases on the Cockpit's Import tab "
                                'wait here. Confirm or discard each one; '
                                'there is no batch confirm for these.',
                            link: InfoLink(
                              prompt: 'Want fewer false flags?',
                              label: 'Edit import rules',
                              onTap: goCockpitImport,
                            ),
                          ),
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: collapsed ? 0.5 : 0,
                      duration: AnimatedFold.duration,
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_less,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedFold(
            collapsed: collapsed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: suspects.length,
                itemBuilder: (context, i) =>
                    _PendingRow(tx: suspects[i], spam: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One import waiting for review: "category · merchant" over the amount,
/// the date and the sender, with Confirm and Discard. Above
/// [kLargeTextScale] the two buttons move under the text, so the text
/// keeps the row's width.
class _PendingRow extends StatelessWidget {
  final Tx tx;

  /// A suspected spam row: its amount is plain text, not money green or
  /// red, since it may be no money at all.
  final bool spam;
  const _PendingRow({required this.tx, this.spam = false});

  /// "Food & Dining · Swiggy": what the row would count as, and where. The
  /// category alone when the row names no merchant. The Cockpit's Review
  /// tab titles its rows the same way, though it lists confirmed rows,
  /// not these.
  static String titleOf(Tx tx, FinanceProvider finance) {
    final merchant = merchantLabelOrNull(tx, alias: finance.merchantAlias);
    return merchant == null
        ? tx.category.label
        : '${tx.category.label} · $merchant';
  }

  /// "13 Oct, 12:02 PM · VM-DEMOBK", without the sender when there is none.
  static String whenAndWho(Tx tx) => [
    fmtDateCompact(tx.date),
    if (tx.sender.isNotEmpty) tx.sender,
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final cat = tx.category;
    final isIncome = tx.type == TxType.income;
    final large = isLargeTextScale(context);
    final finance = context.read<FinanceProvider>();
    final tile = ListTile(
      dense: true,
      // Starts in line with the card header's icon; the end keeps the
      // Material 3 default.
      contentPadding: EdgeInsetsDirectional.only(
        start: AppSpace.card,
        end: large ? AppSpace.card : 24,
      ),
      onTap: () => showAddTransactionSheet(context, existing: tx),
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: cat.color.withValues(alpha: 0.15),
        child: Icon(
          cat.icon,
          color: categoryGlyphColor(context, cat.color),
          size: 16,
        ),
      ),
      title: Text(
        titleOf(tx, finance),
        maxLines: large ? 2 : 1,
        overflow: TextOverflow.ellipsis,
      ),
      // The amount in its money colour, as on the ledger rows; plain on a
      // spam suspect.
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${isIncome ? '+' : '−'}${fmtMoney(tx.amount)}',
              style: TextStyle(
                color: spam
                    ? Theme.of(context).colorScheme.onSurface
                    : moneyColor(
                        context,
                        type: tx.type,
                        transfer: isTransferCategory(tx.categoryId),
                      ),
              ),
            ),
            TextSpan(text: ' · ${whenAndWho(tx)}'),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: large ? null : _actions(context),
    );
    if (!large) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: _actions(context),
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Confirm',
        icon: Icon(
          Icons.check_circle_outline,
          color: AppColors.of(context).green,
        ),
        // Symmetric with Discard below: a mis-tapped Confirm silently
        // moved the row into the ledger with nothing to grab. Undo puts
        // the captured pending copy back in the queue.
        onPressed: () {
          final finance = context.read<FinanceProvider>();
          final confirmed = tx;
          finance.confirmTransaction(confirmed.id);
          showUndoSnackBar(
            context,
            'Confirmed ${fmtMoney(confirmed.amount)} from '
            '${confirmed.sender.isEmpty ? 'SMS' : confirmed.sender}',
            () => finance.restoreEditedTransactions([confirmed]),
            icon: Icons.done_all,
            tone: AppToastTone.success,
          );
        },
      ),
      IconButton(
        tooltip: 'Discard',
        icon: const Icon(Icons.cancel_outlined),
        onPressed: () {
          final finance = context.read<FinanceProvider>();
          final discarded = tx;
          finance.deleteTransaction(discarded.id);
          // Restoring keeps pending: true, so the row returns to this
          // review queue rather than silently joining the ledger.
          showUndoSnackBar(
            context,
            'Discarded ${fmtMoney(discarded.amount)} from '
            '${discarded.sender.isEmpty ? 'SMS' : discarded.sender}',
            () => finance.restoreTransaction(discarded),
            icon: Icons.block,
            tone: AppToastTone.removal,
          );
        },
      ),
    ],
  );
}

/// "3 new · Mark all seen" above the list while imports that counted at
/// once still carry their "new" marker.
class _UnseenLine extends StatelessWidget {
  final int count;
  const _UnseenLine({required this.count});

  void _markAllSeen(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    // The rows as they are, for Undo: restoring them brings the markers
    // back.
    final snapshot = [
      ...finance.transactions,
      ...finance.pendingTransactions,
    ].where((t) => t.unseen).toList();
    if (snapshot.isEmpty) return;
    // The markers clear in memory before the first await, so the toast
    // goes up while this context is still mounted.
    finance.markAllSeen();
    showUndoSnackBar(
      context,
      'Marked ${snapshot.length} as seen',
      () => finance.restoreEditedTransactions(snapshot),
      icon: Icons.done_all,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // One size for the count and the button, the button's own.
    final size = theme.textTheme.labelLarge;
    // Start-aligned at the list's 20dp inset (the screen's Column centres
    // what does not fill it). The button keeps its 48dp tap target.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 12, 0),
        // Wraps, so "Mark all seen" drops under the count at 320dp with
        // large text instead of overflowing.
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 2,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The rows' "new" dot.
                StatusDot(color: accentTextColor(context)),
                const SizedBox(width: 6),
                Text(
                  '$count new ·',
                  style: size?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
            TextButton(
              style: TextButton.styleFrom(
                textStyle: size,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () => _markAllSeen(context),
              child: const Text('Mark all seen'),
            ),
          ],
        ),
      ),
    );
  }
}
