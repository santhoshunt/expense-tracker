import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/account.dart';
import '../models/spend_budget.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/backup_service.dart';
import '../widgets/animated_fold.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../utils/contrast.dart';
import '../widgets/category_chip_label.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/glossy.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/transaction_tile.dart';
import '../widgets/undo_snackbar.dart';
import 'add_transaction_sheet.dart';

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

  const TxFilterRequest({
    this.type,
    this.accountId,
    this.month,
    this.categoryId,
    this.budgetId,
    this.groupId,
    this.query,
  });
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

class _TransactionsScreenState extends State<TransactionsScreen> {
  _Filter _filter = _Filter.all;
  _Sort _sort = _Sort.dateDesc;
  String _search = '';
  final Set<String> _categoryFilter = {};

  /// Selected parent-group ids; [kUngroupedFilterKey] stands for "Other"
  /// (groupable categories with no group).
  final Set<String> _groupFilter = {};

  /// Selected custom-budget ids — shows the rows counting toward any of them.
  final Set<String> _budgetFilter = {};
  double? _minAmount;
  double? _maxAmount;
  String? _accountId;
  DateTime? _monthFilter;

  /// Ids of transactions picked in multi-select mode; non-empty = selecting.
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  void _toggleSelect(String id) {
    setState(
      () => _selected.contains(id) ? _selected.remove(id) : _selected.add(id),
    );
  }

  final _searchCtrl = TextEditingController();
  final _itemScrollCtrl = ItemScrollController();
  final _itemPositions = ItemPositionsListener.create();

  // The month jump panel floats over the list, so it only shows while the
  // user is scrolling (plus a grace period) — parked off-screen otherwise it
  // covers the month totals and trailing amounts.
  bool _jumpVisible = false;
  Timer? _jumpHideTimer;

  void _pokeJumpControls() {
    if (!_jumpVisible) setState(() => _jumpVisible = true);
    _jumpHideTimer?.cancel();
    _jumpHideTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _jumpVisible = false);
    });
  }

  // The filter → group → sort → flatten pipeline walks the whole ledger, so
  // its output is cached and recomputed only when the data or the filters
  // actually change (see _recomputePipeline) — not on selection taps,
  // scroll-driven setStates or jump-control visibility toggles.
  Object? _pipelineRevision;
  String? _pipelineFingerprint;
  List<Tx> _filtered = const [];
  Map<DateTime, List<Tx>> _groups = const {};
  List<(DateTime?, Tx?)> _rows = const [];
  List<DateTime> _months = const [];
  Map<DateTime, int> _monthIndexes = const {};
  int _itemCount = 0;

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
      label: Text(label),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onDeleted: onDeleted,
    );

    return [
      if (activeAccount != null)
        chip(
          avatar: Icon(activeAccount.icon, size: 16),
          label: 'Account · ${activeAccount.name}',
          onDeleted: () => setState(() => _accountId = null),
        ),
      if (_monthFilter != null)
        chip(
          avatar: const Icon(Icons.calendar_month, size: 16),
          label: 'Month · ${fmtMonth(_monthFilter!)}',
          onDeleted: () => setState(() => _monthFilter = null),
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
    ];
  }

  bool get _hasAdvancedFilters =>
      _categoryFilter.isNotEmpty ||
      _groupFilter.isNotEmpty ||
      _budgetFilter.isNotEmpty ||
      _minAmount != null ||
      _maxAmount != null ||
      _accountId != null ||
      _monthFilter != null;

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
      _accountId = req?.accountId;
      _monthFilter = req?.month;
      if (req?.categoryId != null) _categoryFilter.add(req!.categoryId!);
      if (req?.groupId != null) _groupFilter.add(req!.groupId!);
      if (req?.budgetId != null) _budgetFilter.add(req!.budgetId!);
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

  @override
  void dispose() {
    _jumpHideTimer?.cancel();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Tx> _applyFilters(List<Tx> all, FinanceProvider finance) {
    final q = _search.trim().toLowerCase();
    final budgetFilterList = _budgetFilter.isEmpty
        ? const <SpendBudget>[]
        : finance.budgets.where((b) => _budgetFilter.contains(b.id)).toList();
    return all.where((t) {
      if (_accountId != null &&
          finance.accountForKey(t.acctKey)?.id != _accountId) {
        return false;
      }
      final m = _monthFilter;
      if (m != null && (t.date.year != m.year || t.date.month != m.month)) {
        return false;
      }
      switch (_filter) {
        case _Filter.income:
          if (t.type != TxType.income || isTransferCategory(t.categoryId)) {
            return false;
          }
        case _Filter.expense:
          if (t.type != TxType.expense || isTransferCategory(t.categoryId)) {
            return false;
          }
        case _Filter.transfers:
          if (!isTransferCategory(t.categoryId)) return false;
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
        // income rows don't flood an Other-group filter.
        final matches = gid != null
            ? _groupFilter.contains(gid)
            : _groupFilter.contains(kUngroupedFilterKey) &&
                  finance.isGroupable(t.category);
        if (!matches) return false;
      }
      if (budgetFilterList.isNotEmpty &&
          !budgetFilterList.any((b) => finance.countsTowardBudget(t, b))) {
        return false;
      }
      if (_minAmount != null && t.amount < _minAmount!) return false;
      if (_maxAmount != null && t.amount > _maxAmount!) return false;
      if (q.isNotEmpty &&
          !t.note.toLowerCase().contains(q) &&
          !t.smsBody.toLowerCase().contains(q) &&
          !t.sender.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
  }

  /// Everything the pipeline output depends on besides the ledger itself.
  /// Cheap to build relative to one pipeline run; sets are sorted so
  /// insertion order can't fake a change.
  String _pipelineInputs() => [
    _filter.index,
    _sort.index,
    _search.trim().toLowerCase(),
    (_categoryFilter.toList()..sort()).join(','),
    (_groupFilter.toList()..sort()).join(','),
    (_budgetFilter.toList()..sort()).join(','),
    _minAmount,
    _maxAmount,
    _accountId,
    _monthFilter,
  ].join('|');

  /// Runs filter → group-by-month → sort → flatten, caching the result.
  /// Skipped entirely when neither the ledger (provider revision) nor any
  /// filter input changed — selection taps and the scroll-driven
  /// jump-control toggles rebuild this screen constantly.
  void _recomputePipeline(FinanceProvider finance, List<Tx> allConfirmed) {
    final fingerprint = _pipelineInputs();
    if (identical(_pipelineRevision, finance.revision) &&
        fingerprint == _pipelineFingerprint) {
      return;
    }
    _pipelineRevision = finance.revision;
    _pipelineFingerprint = fingerprint;

    // Prune filter ids whose target was deleted. A dead category/group id
    // silently emptied the list; a dead budget id was worse — the budget
    // check no-ops on an empty resolved list, so the filter stopped
    // filtering while the badge stayed lit. Same precedent as the
    // _selected pruning below.
    _categoryFilter.removeWhere((id) => !allCategories.any((c) => c.id == id));
    _groupFilter.removeWhere(
      (id) =>
          id != kUngroupedFilterKey && !finance.groups.any((g) => g.id == id),
    );
    _budgetFilter.removeWhere((id) => !finance.budgets.any((b) => b.id == id));

    final filtered = _applyFilters(allConfirmed, finance);

    // Drop selections that no longer exist (deleted, or re-filtered away by
    // an edit) so the action bar count never lies.
    if (_selected.isNotEmpty) {
      final visible = {for (final t in filtered) t.id};
      _selected.removeWhere((id) => !visible.contains(id));
    }

    // Group by month, months always newest-first; sort within each month.
    final groups = <DateTime, List<Tx>>{};
    for (final tx in filtered) {
      final month = DateTime(tx.date.year, tx.date.month);
      groups.putIfAbsent(month, () => []).add(tx);
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
    final rows = <(DateTime?, Tx?)>[];
    final monthIndexes = <DateTime, int>{};
    for (final month in months) {
      monthIndexes[month] = rows.length;
      rows.add((month, null));
      for (final tx in groups[month]!) {
        rows.add((null, tx));
      }
    }
    _filtered = filtered;
    _groups = groups;
    _rows = rows;
    _months = months;
    _monthIndexes = monthIndexes;
    _itemCount = rows.length;
  }

  void _scrollToIndex(int index, {double alignment = 0}) {
    if (!_itemScrollCtrl.isAttached) return;
    _itemScrollCtrl.scrollTo(
      index: index,
      alignment: alignment,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
    );
  }

  /// Step month-by-month: up snaps to the current month's header first,
  /// then to the previous month; down goes to the next month's header
  /// (or the end of the list when already in the last month).
  void _stepMonth({required bool up}) {
    if (_months.isEmpty) return;
    final positions = _itemPositions.itemPositions.value;
    if (positions.isEmpty) return;
    // Top-most item still visible in the viewport.
    final top = positions
        .where((p) => p.itemTrailingEdge > 0)
        .reduce((a, b) => a.index < b.index ? a : b);
    final headers = [for (final m in _months) _monthIndexes[m]!]; // ascending

    if (up) {
      var current = headers.lastIndexWhere((h) => h <= top.index);
      if (current < 0) current = 0;
      // Already sitting on this month's header → go to the previous month.
      final atHeader =
          headers[current] == top.index && top.itemLeadingEdge >= -0.001;
      final target = (current - (atHeader ? 1 : 0)).clamp(
        0,
        headers.length - 1,
      );
      _scrollToIndex(headers[target]);
    } else {
      final next = headers.indexWhere((h) => h > top.index);
      if (next == -1) {
        // Last month: land the final entry near the bottom of the viewport.
        _scrollToIndex(_itemCount - 1, alignment: 0.85);
      } else {
        _scrollToIndex(headers[next]);
      }
    }
  }

  void _scrollToMonth(DateTime month) {
    final index = _monthIndexes[month];
    if (index != null) _scrollToIndex(index);
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
    _recomputePipeline(finance, allConfirmed);
    final filtered = _filtered;
    final activeAccount = _accountId == null
        ? null
        : finance.accountById(_accountId!);

    return Column(
      children: [
        if (spamSuspects.isNotEmpty) _SuspectedSpamCard(suspects: spamSuspects),
        if (pending.isNotEmpty) _PendingReviewCard(pending: pending),
        _SearchAndFilterBar(
          searchCtrl: _searchCtrl,
          onSearch: _onSearchChanged,
          onClearSearch: () {
            _searchDebounce?.cancel();
            setState(() => _search = '');
          },
          filter: _filter,
          onFilter: (f) => setState(() => _filter = f),
          sort: _sort,
          onSort: (s) => setState(() => _sort = s),
          hasAdvancedFilters: _hasAdvancedFilters,
          onOpenFilters: _openFilterSheet,
          onExport: _exportCsv,
        ),
        if (activeAccount != null ||
            _monthFilter != null ||
            _categoryFilter.isNotEmpty ||
            _groupFilter.isNotEmpty ||
            _budgetFilter.isNotEmpty)
          // Single-line, horizontally scrollable strip of COMPACT chips —
          // a wrapping layout grew a row per filter and buried the list
          // when several were active.
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final chip in _activeFilterChips(finance, activeAccount))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: chip,
                    ),
                ],
              ),
            ),
          ),
        if (_selecting)
          _SelectionBar(
            count: _selected.length,
            onSelectAll: () => setState(
              () => _selected.addAll([for (final t in filtered) t.id]),
            ),
            onCategory: () => _bulkCategory(filtered),
            onAccount: _bulkAccount,
            onDateTime: _bulkDateTime,
            onDelete: _bulkDelete,
            onClose: () => setState(_selected.clear),
          ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        allConfirmed.isEmpty
                            ? 'No transactions yet.\nTap + to add one.'
                            : 'Nothing matches your search/filters.',
                        textAlign: TextAlign.center,
                      ),
                      // Something is hiding every row (a chip may be
                      // scrolled out of view) — offer the way out here.
                      if (allConfirmed.isNotEmpty) ...[
                        const SizedBox(height: 8),
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
                              _minAmount = null;
                              _maxAmount = null;
                              _accountId = null;
                              _monthFilter = null;
                            });
                          },
                        ),
                      ],
                    ],
                  ),
                )
              : Stack(
                  children: [
                    // Lazy indexed list: month jumps go by item index, so
                    // headers never need to be mounted to be reachable.
                    NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n is ScrollStartNotification ||
                            n is ScrollUpdateNotification) {
                          _pokeJumpControls();
                        }
                        return false;
                      },
                      child: ScrollablePositionedList.builder(
                        itemScrollController: _itemScrollCtrl,
                        itemPositionsListener: _itemPositions,
                        itemCount: _rows.length,
                        padding: const EdgeInsets.only(bottom: 120),
                        itemBuilder: (_, i) {
                          final (month, tx) = _rows[i];
                          return month != null
                              ? _MonthHeader(
                                  month: month,
                                  txs: _groups[month]!,
                                  onSelectMonth: () => _selectMonth(month),
                                )
                              : TransactionTile(
                                  tx: tx!,
                                  selectionMode: _selecting,
                                  selected: _selected.contains(tx.id),
                                  onToggleSelect: () => _toggleSelect(tx.id),
                                );
                        },
                      ),
                    ),
                    // With a month filter the list holds a single month —
                    // nothing to jump between.
                    if (_monthFilter == null)
                      Positioned(
                        right: 4,
                        top: 8,
                        child: AnimatedSlide(
                          offset: _jumpVisible
                              ? Offset.zero
                              : const Offset(1.4, 0),
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                          child: AnimatedOpacity(
                            opacity: _jumpVisible ? 1 : 0,
                            duration: const Duration(milliseconds: 250),
                            child: IgnorePointer(
                              ignoring: !_jumpVisible,
                              child: _JumpControls(
                                months: _months,
                                onUp: () => _stepMonth(up: true),
                                onDown: () => _stepMonth(up: false),
                                onMonth: _scrollToMonth,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  void _afterBulk(int changed, String what, {VoidCallback? onUndo}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            changed == 0
                ? 'No rows changed.'
                : '$what set on $changed transaction'
                      '${changed == 1 ? '' : 's'}.',
          ),
          duration: const Duration(seconds: 5),
          action: changed == 0 || onUndo == null
              ? null
              : SnackBarAction(label: 'Undo', onPressed: onUndo),
        ),
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
                    'its own type (income/expense).',
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
      onUndo: () => finance.restoreEditedTransactions(snapshot),
    );
  }

  Future<void> _bulkAccount() async {
    final finance = context.read<FinanceProvider>();
    // Open accounts only — bulk-assigning rows INTO a closed account is
    // always a mistake; existing history on closed accounts is untouched.
    final accounts = finance.openAccounts;
    if (accounts.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No accounts yet.')));
      return;
    }
    final result = await showPickerSheet<String>(
      context: context,
      title: 'Assign to account',
      items: [
        for (final a in accounts)
          PickerItem(
            value: a.id,
            label: a.name,
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
      'The selected transactions move to "${target.name}". Any stated '
          'balance they carry for another account is dropped.',
    )) {
      return;
    }
    final changed = await finance.assignAccountToMany(
      Set.of(_selected),
      picked,
    );
    _afterBulk(changed, 'Account');
  }

  Future<void> _bulkDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null || !mounted) return;
    final stamp = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final n = _selected.length;
    final finance = context.read<FinanceProvider>();
    // The one bulk edit whose old values cannot be re-derived from the rows
    // themselves — confirm with the count, and keep an Undo snapshot.
    if (!await _confirmBulk(
      'Set date & time on $n transaction${n == 1 ? '' : 's'}?',
      'Every selected transaction is stamped '
          '${MaterialLocalizations.of(context).formatMediumDate(stamp)}, '
          '${TimeOfDay.fromDateTime(stamp).format(context)}. '
          'Their original dates are replaced.',
    )) {
      return;
    }
    final snapshot = _selectedSnapshot(finance);
    final changed = await finance.setDateTimeForMany(Set.of(_selected), stamp);
    _afterBulk(
      changed,
      'Date & time',
      onUndo: () => finance.restoreEditedTransactions(snapshot),
    );
  }

  /// Exports exactly what the list is showing — same rows, same order.
  Future<void> _exportCsv() async {
    final rows = [for (final (_, tx) in _rows) ?tx];
    final messenger = ScaffoldMessenger.of(context);
    if (rows.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Nothing to export.')),
      );
      return;
    }
    try {
      final path = await BackupService.exportCsvRows(rows);
      // Null = the save dialog was cancelled — not worth a snackbar.
      if (path != null && path.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
      }
    } catch (e) {
      debugPrint('CSV export failed: $e');
      messenger.showSnackBar(const SnackBar(content: Text('Export failed.')));
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
    );
  }

  /// Month-header select toggle: selects every VISIBLE row of that month,
  /// or clears them when they are all already selected.
  void _selectMonth(DateTime month) {
    final ids = [for (final t in _groups[month] ?? const <Tx>[]) t.id];
    if (ids.isEmpty) return;
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
    var accountId = _accountId;
    // Live query narrowing the chip sections — the category list alone can
    // hold dozens of chips.
    var filterQuery = '';
    final finance = context.read<FinanceProvider>();
    final accounts = finance.accounts;
    final groups = finance.groups;
    final budgets = finance.budgets;
    final minCtrl = TextEditingController(
      text: _minAmount == null ? '' : _minAmount!.toStringAsFixed(0),
    );
    final maxCtrl = TextEditingController(
      text: _maxAmount == null ? '' : _maxAmount!.toStringAsFixed(0),
    );
    final filterSearchCtrl = TextEditingController();

    await showModalBottomSheet(
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
                // content below scrolls.
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Filters',
                        style: Theme.of(ctx).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
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
                          accountId = null;
                        });
                      },
                      child: const Text('Clear all'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
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
                          // parseAmount: "1,000" must filter, not silently
                          // clear the bound the user just typed.
                          _minAmount = parseAmount(minCtrl.text);
                          _maxAmount = parseAmount(maxCtrl.text);
                          _accountId = accountId;
                        });
                        Navigator.pop(ctx);
                      },
                      child: const Text('Apply'),
                    ),
                  ],
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
                          if (has(a.name) || accountId == a.id) a,
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
                      final visCategories = [
                        for (final c in allCategories)
                          if (has(c.label) || selected.contains(c.id)) c,
                      ];
                      return SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
                                      label: Text(a.name),
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
                            const SizedBox(height: 8),
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
  }
}

/// Action bar shown while transactions are selected: count, select-all for
/// the current filter, and the three bulk edits.
class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onCategory;
  final VoidCallback onAccount;
  final VoidCallback onDateTime;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const _SelectionBar({
    required this.count,
    required this.onSelectAll,
    required this.onCategory,
    required this.onAccount,
    required this.onDateTime,
    required this.onDelete,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: FrostedPanel(
        radius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Clear selection',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 20),
                onPressed: onClose,
              ),
              Text(
                '$count',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Select all shown',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.select_all, size: 20),
                onPressed: onSelectAll,
              ),
              IconButton(
                tooltip: 'Set category',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.category_outlined, size: 20),
                onPressed: onCategory,
              ),
              IconButton(
                tooltip: 'Assign account',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.account_balance_outlined, size: 20),
                onPressed: onAccount,
              ),
              IconButton(
                tooltip: 'Set date & time',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.schedule, size: 20),
                onPressed: onDateTime,
              ),
              IconButton(
                tooltip: 'Delete',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.delete_outline, size: 20, color: scheme.error),
                onPressed: onDelete,
              ),
            ],
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
  final _Sort sort;
  final ValueChanged<_Sort> onSort;
  final bool hasAdvancedFilters;
  final VoidCallback onOpenFilters;
  final VoidCallback onExport;

  const _SearchAndFilterBar({
    required this.searchCtrl,
    required this.onSearch,
    required this.onClearSearch,
    required this.filter,
    required this.onFilter,
    required this.sort,
    required this.onSort,
    required this.hasAdvancedFilters,
    required this.onOpenFilters,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        children: [
          // Sort/filter ride on the search row so the type segments below
          // get the full width — four cramped segments read badly.
          Row(
            children: [
              Expanded(
                // Listen to the controller directly: this widget only
                // rebuilds on the 250ms debounce, so the ✕ used to appear a
                // beat after the first keystroke.
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: searchCtrl,
                  builder: (context, value, _) => TextField(
                    controller: searchCtrl,
                    onChanged: onSearch,
                    decoration: InputDecoration(
                      hintText: 'Search notes and senders',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: value.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                searchCtrl.clear();
                                // Immediate, not debounced — clearing should
                                // never lag behind the tap.
                                onClearSearch();
                              },
                            ),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FrostedPanel(
                radius: BorderRadius.circular(AppRadius.section),
                child: IconButton(
                  tooltip: 'Sort',
                  icon: const Icon(Icons.sort, size: 20),
                  onPressed: () async {
                    final result = await showPickerSheet<_Sort>(
                      context: context,
                      title: 'Sort by',
                      items: [
                        for (final s in _Sort.values)
                          PickerItem(value: s, label: _sortLabels[s]!),
                      ],
                      selected: sort,
                    );
                    final v = result?.value;
                    if (v != null) onSort(v);
                  },
                ),
              ),
              const SizedBox(width: 8),
              FrostedPanel(
                radius: BorderRadius.circular(AppRadius.section),
                child: IconButton(
                  tooltip: 'Filters',
                  icon: Badge(
                    isLabelVisible: hasAdvancedFilters,
                    child: const Icon(Icons.filter_list, size: 20),
                  ),
                  onPressed: onOpenFilters,
                ),
              ),
              const SizedBox(width: 8),
              FrostedPanel(
                radius: BorderRadius.circular(AppRadius.section),
                child: IconButton(
                  tooltip: 'Export CSV',
                  icon: const Icon(Icons.ios_share, size: 20),
                  onPressed: onExport,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          GlassSegmented<_Filter>(
            options: const [
              (_Filter.all, 'All'),
              (_Filter.income, 'Income'),
              (_Filter.expense, 'Expenses'),
              (_Filter.transfers, 'Transfers'),
            ],
            selected: filter,
            onChanged: onFilter,
          ),
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

  const _MonthHeader({
    required this.month,
    required this.txs,
    this.onSelectMonth,
  });

  @override
  Widget build(BuildContext context) {
    // Own-account transfers are audit entries — the header totals mirror the
    // dashboard's income/expense figures, which exclude them.
    final income = txs
        .where(
          (t) => t.type == TxType.income && !isTransferCategory(t.categoryId),
        )
        .fold(0.0, (s, t) => s + t.amount);
    final expense = txs
        .where(
          (t) => t.type == TxType.expense && !isTransferCategory(t.categoryId),
        )
        // spendAmount: group splits count only the user's own share here,
        // matching the dashboard's Spent card.
        .fold(0.0, (s, t) => s + t.spendAmount);
    final scheme = Theme.of(context).colorScheme;

    final now = DateTime.now();
    final label = (month.year == now.year)
        ? DateFormat('MMMM').format(month).toUpperCase()
        : DateFormat('MMMM yyyy').format(month).toUpperCase();

    return Padding(
      // Right padding matches the jump-controls column width so the label
      // never slides under the nav pill.
      padding: const EdgeInsets.fromLTRB(20, 24, 52, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // accentTextColor, not scheme.primary: same 4.5:1 fix as
              // UppercaseSectionHeader — the raw accent read at ~2.5:1 on
              // the light surface (the amounts beside it were already
              // bumped for exactly this).
              style: TextStyle(
                color: accentTextColor(context),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
          ),
          // Width-capped as one unit: at large text scales the pair shrinks
          // to fit instead of overflowing past the jump controls.
          if (income > 0 || expense > 0)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 12/w700: at 11/w600 these saturated colours fell below
                    // AA contrast on the light surface.
                    if (income > 0)
                      Text(
                        '+${fmtMoneyCompact(income)}',
                        style: TextStyle(
                          color: AppColors.of(context).green,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    if (income > 0 && expense > 0) const SizedBox(width: 6),
                    if (expense > 0)
                      Text(
                        '−${fmtMoneyCompact(expense)}',
                        style: TextStyle(
                          color: scheme.error,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (onSelectMonth != null)
            IconButton(
              tooltip: 'Select month',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.checklist,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              onPressed: onSelectMonth,
            ),
        ],
      ),
    );
  }
}

class _JumpControls extends StatelessWidget {
  final List<DateTime> months;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final ValueChanged<DateTime> onMonth;

  const _JumpControls({
    required this.months,
    required this.onUp,
    required this.onDown,
    required this.onMonth,
  });

  @override
  Widget build(BuildContext context) {
    return FrostedPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Previous month',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_double_arrow_up, size: 20),
            onPressed: onUp,
          ),
          IconButton(
            tooltip: 'Jump to month',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.calendar_month, size: 20),
            onPressed: () => _showMonthPicker(context),
          ),
          IconButton(
            tooltip: 'Next month',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_double_arrow_down, size: 20),
            onPressed: onDown,
          ),
        ],
      ),
    );
  }

  /// Fixed-height frosted sheet with a scrollable month list — a long
  /// history must not overflow past the navigation bar.
  Future<void> _showMonthPicker(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      useSafeArea: true,
      // Absolute cap for tall screens; short landscape viewports get a
      // fraction of the viewport instead of overflowing a fixed 420.
      constraints: BoxConstraints(
        maxHeight: switch (MediaQuery.sizeOf(context).height * 0.6) {
          final h when h < 420 => h,
          _ => 420,
        },
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: FrostedPanel(
            radius: BorderRadius.circular(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      ctx,
                    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: Text(
                    'Jump to month',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: months.length,
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      title: Text(
                        DateFormat('MMMM yyyy').format(months[i]),
                        textAlign: TextAlign.center,
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        onMonth(months[i]);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Review queue for regular SMS imports: confirm/discard each, or the batch.
class _PendingReviewCard extends StatelessWidget {
  final List<Tx> pending;
  const _PendingReviewCard({required this.pending});

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

  Future<void> _rejectAll(BuildContext context) async {
    final finance = context.read<FinanceProvider>();
    final count = pending.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reject all $count import${count == 1 ? '' : 's'}?'),
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
            child: const Text('Reject all'),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final collapsed = context.watch<SettingsProvider>().isSectionCollapsed(
      'pending_review',
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => context.read<SettingsProvider>().toggleSection(
              'pending_review',
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  Icon(Icons.sms, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Imported from SMS · ${pending.length} to review',
                      style: Theme.of(context).textTheme.titleSmall,
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
          AnimatedFold(
            collapsed: collapsed,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Bulk actions live inside the fold: a collapsed card can't
                // fire them, and the wrapped title above keeps its room.
                // Compact everywhere: two review cards + toolbar + list must
                // fit short viewports without overflowing the tab Column.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.error,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => _rejectAll(context),
                        child: const Text('Reject all'),
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
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.builder(
                    shrinkWrap: true,
                    // Explicit: otherwise the list absorbs the extend-body
                    // safe-area insets as phantom top/bottom padding.
                    padding: EdgeInsets.zero,
                    itemCount: pending.length,
                    itemBuilder: (context, i) => _PendingRow(tx: pending[i]),
                  ),
                ),
              ],
            ),
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
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      color: scheme.errorContainer.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () =>
                context.read<SettingsProvider>().toggleSection('spam_review'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Suspected spam · ${suspects.length} — review one by one',
                      style: Theme.of(context).textTheme.titleSmall,
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
          AnimatedFold(
            collapsed: collapsed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: suspects.length,
                itemBuilder: (context, i) => _PendingRow(tx: suspects[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingRow extends StatelessWidget {
  final Tx tx;
  const _PendingRow({required this.tx});

  @override
  Widget build(BuildContext context) {
    final cat = tx.category;
    final isIncome = tx.type == TxType.income;
    return ListTile(
      dense: true,
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
        tx.sender.isNotEmpty ? tx.sender : cat.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${isIncome ? '+' : '-'}${fmtMoney(tx.amount)} · '
        '${fmtDateMaybeTime(tx.date)}\n${tx.smsText}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Confirm',
            icon: Icon(
              Icons.check_circle_outline,
              color: AppColors.of(context).green,
            ),
            // Symmetric with Discard below: a mis-tapped Confirm silently
            // moved the row into the ledger with nothing to grab — Undo
            // puts the captured pending copy back in the queue.
            onPressed: () {
              final finance = context.read<FinanceProvider>();
              final confirmed = tx;
              finance.confirmTransaction(confirmed.id);
              showUndoSnackBar(
                context,
                'Confirmed ${fmtMoney(confirmed.amount)} from '
                '${confirmed.sender.isEmpty ? 'SMS' : confirmed.sender}',
                () => finance.restoreEditedTransactions([confirmed]),
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
              );
            },
          ),
        ],
      ),
    );
  }
}
