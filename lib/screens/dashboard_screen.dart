import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/category_group.dart';
import '../models/dashboard_layout.dart';
import '../models/reminder.dart';
import '../models/spend_budget.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/backup_service.dart';
import '../services/card_bill.dart';
import '../services/merchant_stats.dart';
import '../services/monthly_recap.dart';
import '../services/recurring_detector.dart';
import '../services/spend_comparison.dart';
import '../services/safe_to_spend.dart';
import '../services/subscriptions.dart';
import '../services/upcoming_items.dart';
import '../utils/app_theme.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import '../widgets/animated_fold.dart';
import '../widgets/balance_breakdown.dart';
import '../widgets/budget_detail_sheet.dart';
import '../widgets/budget_dialog.dart';
import '../widgets/dashboard_fold.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/reminder_editor_dialog.dart';
import '../widgets/undo_snackbar.dart';
import '../widgets/import_health_banner.dart';
import '../widgets/update_banner.dart';
import '../widgets/spending_heatmap.dart';
import '../widgets/glossy.dart';
import '../widgets/info_tip.dart';
import '../widgets/motion.dart';
import '../widgets/category_donut_chart.dart';
import '../widgets/monthly_bar_chart.dart';
import '../widgets/monthly_recap_card.dart';
import '../widgets/rename_merchant_dialog.dart';
import '../widgets/show_all_list.dart';
import '../widgets/spend_comparison_cards.dart';
import '../widgets/tag_editor_dialog.dart';
import 'accounts_screen.dart' show showCardCycleDialog;
import 'add_transaction_sheet.dart';
import 'app_nav.dart';

/// Which slice of the dashboard is on screen. The page grew to fifteen
/// sections in one scroll; splitting it into sub-tabs (rather than a second
/// route) keeps the month selector, the year toggle and every deep-link
/// callback in this one State. Each section lives on one view only.
enum DashboardView {
  /// The landing view: the net balance, the picked month's figures (last
  /// month's recap among them), what's due, budgets, and what friends owe.
  overview('Overview'),
  trends('Trends'),
  breakdown('Breakdown');

  final String label;
  const DashboardView(this.label);
}

class DashboardScreen extends StatefulWidget {
  /// Called when a stat card is tapped, to open the Transactions tab
  /// pre-filtered to that type — scoped to the month the card was showing.
  final void Function(TxType type, DateTime month)? onViewTransactions;

  /// Called when a category / group spending row or a budget row is tapped,
  /// to open the Transactions tab pre-filtered to it — scoped to the month
  /// the dashboard was showing.
  final void Function(String categoryId, DateTime month)? onViewCategory;

  /// A null groupId means the "Other" (ungrouped) bucket.
  final void Function(String? groupId, DateTime month)? onViewGroup;
  final void Function(String budgetId, DateTime month)? onViewBudget;

  /// Called when a Top-merchants row is tapped: [query] is the normalized
  /// merchant identity, pre-filled into the Transactions search.
  final void Function(String query, DateTime month)? onViewMerchant;

  /// Called when a By tags row is tapped: Transactions filtered to [tag].
  final void Function(String tag, DateTime month)? onViewTag;

  const DashboardScreen({
    super.key,
    this.onViewTransactions,
    this.onViewCategory,
    this.onViewGroup,
    this.onViewBudget,
    this.onViewMerchant,
    this.onViewTag,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

/// The heatmap's heading tip.
const _heatmapTip =
    "Each day is shaded by its spending compared with this month's biggest "
    'day, and shows what it spent. Days with no spending stay plain. A dot '
    'marks a day a bill is still due this month; tap a day for its payments '
    'and bills.';

/// One movable dashboard section, as its page builder describes it:
/// whether it has anything to show now, its heading (null: the section's
/// label), the one line a folded section shows, its info tip, and its
/// cards.
typedef _DashSection = ({
  bool visible,
  String? title,
  String? summary,
  Widget? tip,
  List<Widget> Function() body,
});

const _kWeekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// The last row of every dashboard page: the way to reorder or hide its
/// sections, and how many are hidden now.
class _CustomiseRow extends StatelessWidget {
  final DashboardPage page;
  final int hidden;
  const _CustomiseRow({required this.page, required this.hidden});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Center(
      child: TextButton.icon(
        icon: const Icon(Icons.dashboard_customize_outlined, size: 18),
        label: Text(
          hidden > 0
              ? 'Customise this page · $hidden hidden'
              : 'Customise this page',
        ),
        onPressed: () => goCockpitDashboard(context, page),
      ),
    ),
  );
}

class _DashboardScreenState extends State<DashboardScreen> {
  /// [header], then [sections] in [page]'s stored order less the hidden
  /// ones (and those with nothing to show), folded on Trends and
  /// Breakdown, then the Customise row.
  List<Widget> _page(
    DashboardPage page,
    List<Widget> header,
    Map<DashboardSection, _DashSection> sections, {
    required bool fold,
  }) {
    final settings = context.read<SettingsProvider>();
    final layout = settings.dashboardLayout(page);
    final out = <Widget>[...header];
    for (final id in layout.order) {
      if (layout.hidden.contains(id)) continue;
      final s = sections[id];
      if (s == null || !s.visible) continue;
      if (!fold) {
        out.addAll(s.body());
        continue;
      }
      out.add(
        DashboardFold(
          key: ValueKey('fold-${id.name}'),
          title: s.title ?? id.label,
          summary: s.summary,
          tip: s.tip,
          open: settings.sectionOpen(id),
          onChanged: (v) => settings.setSectionOpen(id, v),
          children: s.body(),
        ),
      );
    }
    out.add(_CustomiseRow(page: page, hidden: layout.hidden.length));
    out.add(const SizedBox(height: 120));
    return out;
  }

  late DateTime _month;

  /// Year view: the stat cards, category breakdown and bar chart cover
  /// `_month.year`; the month-only sections (budgets, merchants, heatmap,
  /// transfers) step aside.
  bool _yearMode = false;

  /// Not persisted, matching `_month` and `_yearMode`.
  DashboardView _view = DashboardView.overview;

  late final PageController _pageCtrl = PageController();

  /// The slots of the Overview's recap and the Trends pace card, so a
  /// recap notification tap can scroll the card into view: on a small phone
  /// the recap sits below the fold. On the slot's Builder, outside
  /// AnimatedPresence, so a quick Year toggle can't give the outgoing and
  /// incoming copies the same GlobalKey.
  final GlobalKey _recapKey = GlobalKey();
  final GlobalKey _paceKey = GlobalKey();

  @override
  void dispose() {
    AppNav.instance.detachDashboard(this);
    _pageCtrl.dispose();
    super.dispose();
  }

  /// Where the recap notification lands: last month's recap on the Overview
  /// during the recap week, and after it (a late tap) this month so far
  /// on Trends, the card that took its place. Both are about today's month,
  /// so the selector returns there first.
  void _showMonthCard() {
    if (!mounted) return;
    final now = recapClock();
    final recapWeek = showsRecap(now);
    setState(() {
      _month = DateTime(now.year, now.month);
      _yearMode = false;
    });
    _setView(recapWeek ? DashboardView.overview : DashboardView.trends);
    // Trends folds: the pace card is only there to see once opened, and
    // only fully laid out once the fold has finished opening.
    final settings = context.read<SettingsProvider>();
    final opening = !recapWeek && !settings.sectionOpen(DashboardSection.pace);
    if (opening) settings.setSectionOpen(DashboardSection.pace, true);
    final key = recapWeek ? _recapKey : _paceKey;
    // Off-screen pages are disposed, so after a page switch the card
    // exists only once its view has slid in: try after this frame, and
    // once more when the page animation is done.
    void reveal({required bool retry}) {
      final slot = key.currentContext;
      if (!mounted) return;
      if (slot == null) {
        if (retry) {
          Future.delayed(
            const Duration(milliseconds: 350),
            () => reveal(retry: false),
          );
        }
        return;
      }
      // The page's own list only: Scrollable.ensureVisible would also move
      // the horizontal pager, which then snaps back.
      final list = Scrollable.maybeOf(slot);
      final box = slot.findRenderObject();
      if (list == null || box == null) return;
      list.position.ensureVisible(
        box,
        duration: motionDuration(context, const Duration(milliseconds: 300)),
        curve: Curves.easeOutCubic,
        alignment: 0.1,
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!opening) return reveal(retry: true);
      Future.delayed(
        AnimatedFold.duration + const Duration(milliseconds: 50),
        () => reveal(retry: true),
      );
    });
  }

  void _setView(DashboardView v) {
    if (v == _view) return;
    _pageCtrl.animateToPage(
      v.index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  /// Recurring detection scans the whole ledger — memoized on the provider's
  /// revision token so it reruns only when data actually changes.
  /// The Upcoming card's window of [_patterns] (what detectRecurring
  /// keeps), filtered from the same scan.
  Object? _recurringFrom;
  List<RecurringHit> _recurringHits = const [];

  List<RecurringHit> _recurring(FinanceProvider finance) {
    final now = DateTime.now();
    final patterns = _patterns(finance, now);
    if (!identical(_recurringFrom, patterns)) {
      _recurringFrom = patterns;
      _recurringHits = [
        for (final h in patterns)
          if (h.daysUntil(now) <= 14 && h.daysUntil(now) >= -7) h,
      ];
    }
    return _recurringHits;
  }

  /// This month's unpaid bills from today on, for the heatmap's dots;
  /// none under other months, whose bills show as the spend they became.
  List<DueBill> _heatmapBills(FinanceProvider finance) {
    final now = DateTime.now();
    if (_month != DateTime(now.year, now.month)) return const [];
    return billsDue(
      finance,
      patterns: _patterns(finance, now),
      hidden: context.read<SettingsProvider>().hiddenUpcoming,
      from: now,
      to: DateTime(now.year, now.month + 1, 0),
      now: now,
    );
  }

  /// Every live pattern, not only the next fortnight's: safe to spend sets
  /// aside the whole month's bills. Scans the ledger once per data change
  /// or day.
  Object? _patternsRev;
  int? _patternsDay;
  List<RecurringHit> _patternHits = const [];

  List<RecurringHit> _patterns(FinanceProvider finance, DateTime now) {
    // The whole date, not the day of the month: an untouched ledger a
    // month later is still a new day.
    final day = now.year * 10000 + now.month * 100 + now.day;
    if (!identical(_patternsRev, finance.revision) || _patternsDay != day) {
      _patternsRev = finance.revision;
      _patternsDay = day;
      _patternHits = detectRecurringPatterns(
        finance.transactions,
        now: now,
        alias: finance.merchantAlias,
        pinned: finance.subscriptionPins,
      );
    }
    return _patternHits;
  }

  /// Per-merchant totals scan every row's SMS body — memoized on
  /// (revision, month) like the recurring hits.
  Object? _merchantsRev;
  DateTime? _merchantsMonth;
  List<MerchantSpend> _merchants = const [];

  List<MerchantSpend> _topMerchants(FinanceProvider finance) {
    if (!identical(_merchantsRev, finance.revision) ||
        _merchantsMonth != _month) {
      _merchantsRev = finance.revision;
      _merchantsMonth = _month;
      _merchants = topMerchants(
        finance.transactions,
        month: _month,
        // Every merchant: the card shows five and folds the rest.
        limit: 1 << 20,
        alias: finance.merchantAlias,
      );
    }
    return _merchants;
  }

  /// The spending comparisons walk the shown month plus six reference
  /// months — memoized on (revision, month, day) like the merchant totals.
  ///
  /// The day belongs in the key: Android keeps the process alive across days,
  /// so a session opened on the 17th and resumed on the 18th would otherwise
  /// keep reporting "Through 17 Sep" until something wrote to the ledger —
  /// the stale-by-a-day figure this whole comparison exists to avoid.
  Object? _compareRev;
  DateTime? _compareMonth;
  int _compareDay = 0;
  MonthComparison? _compare;

  MonthComparison _comparison(FinanceProvider finance) {
    final now = DateTime.now();
    if (!identical(_compareRev, finance.revision) ||
        _compareMonth != _month ||
        _compareDay != now.day) {
      _compareRev = finance.revision;
      _compareMonth = _month;
      _compareDay = now.day;
      _compare = buildMonthComparison(finance, _month, now: now);
    }
    return _compare!;
  }

  /// The month cards: last month's recap for the first [kRecapDays] days
  /// (the Overview), this month's pace after (Trends). Memoized on (revision,
  /// day, cap) — the recap walks every row's SMS body for merchants, and
  /// the pace is day-aligned, so the day belongs in the key.
  Object? _monthCardRev;
  DateTime? _monthCardDay;
  double? _monthCardCap;
  ({MonthlyRecap? recap, MonthPace? pace})? _monthCard;

  ({MonthlyRecap? recap, MonthPace? pace}) _monthCardFor(
    FinanceProvider finance,
    SettingsProvider settings,
  ) {
    final now = recapClock();
    final day = DateTime(now.year, now.month, now.day);
    if (!identical(_monthCardRev, finance.revision) ||
        _monthCardDay != day ||
        _monthCardCap != settings.monthlyBudget) {
      _monthCardRev = finance.revision;
      _monthCardDay = day;
      _monthCardCap = settings.monthlyBudget;
      _monthCard = showsRecap(now)
          ? (recap: buildMonthlyRecap(finance, settings, now: now), pace: null)
          : (recap: null, pace: buildMonthPace(finance, settings, now: now));
    }
    return _monthCard!;
  }

  /// The month cards' spending links: that month's expenses.
  void Function(DateTime)? get _viewSpending =>
      widget.onViewTransactions == null
      ? null
      : (m) => widget.onViewTransactions!(TxType.expense, m);

  /// Long-press on a Top-merchants row: give the payee a readable name.
  Future<void> _renameMerchant(BuildContext context, MerchantSpend m) =>
      showRenameMerchantDialog(
        context,
        identity: m.key.substring(m.key.indexOf('|') + 1),
        currentLabel: m.label,
      );

  /// The budget that caps exactly this one category (include mode, single
  /// id), if the user made one — the category row's long-press edits it
  /// instead of creating a duplicate.
  static SpendBudget? _singleCategoryBudget(
    FinanceProvider finance,
    String categoryId,
  ) {
    for (final b in finance.budgets) {
      if (b.mode == BudgetMode.include &&
          b.categoryIds.length == 1 &&
          b.categoryIds.contains(categoryId)) {
        return b;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    AppNav.instance.attachDashboard(this, showRecap: _showMonthCard);
  }

  /// Steps one month, or one year in Year view (the month is kept so
  /// switching back lands on the same month of the new year).
  void _shiftMonth(int delta) => setState(
    () => _month = _yearMode
        ? DateTime(_month.year + delta, _month.month)
        : DateTime(_month.year, _month.month + delta),
  );

  /// Jump straight to any month (or, in Year view, year) that has data,
  /// plus the current one.
  Future<void> _pickMonth(BuildContext context, FinanceProvider finance) async {
    final now = DateTime.now();
    final current = DateTime(now.year, now.month);
    final months = finance.monthsWithData;
    final List<DateTime> options;
    if (_yearMode) {
      final years = <int>{now.year, for (final m in months) m.year}.toList()
        ..sort((a, b) => b.compareTo(a));
      options = [for (final y in years) DateTime(y, _month.month)];
    } else {
      options = [if (!months.contains(current)) current, ...months];
    }
    bool isCurrent(DateTime m) =>
        _yearMode ? m.year == _month.year : m == _month;
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      builder: (ctx) => ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          for (final m in options)
            ListTile(
              leading: Icon(
                Icons.calendar_month,
                color: isCurrent(m)
                    ? Theme.of(ctx).colorScheme.primary
                    : Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
              title: Text(_yearMode ? '${m.year}' : fmtMonth(m)),
              selected: isCurrent(m),
              onTap: () => Navigator.pop(ctx, m),
            ),
        ],
      ),
    );
    if (picked != null && mounted) setState(() => _month = picked);
  }

  Future<void> _exportYearPdf(
    BuildContext context,
    FinanceProvider finance,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final year = _month.year;
    try {
      final path = await BackupService.exportPdf(finance, year: year);
      if (path == null) return;
      showAppToastOn(
        messenger,
        'Saved report $year',
        tone: AppToastTone.success,
        icon: Icons.picture_as_pdf_outlined,
      );
    } catch (e) {
      showAppToastOn(messenger, 'Export failed: $e', tone: AppToastTone.error);
    }
  }

  /// Chevrons, the tappable month label, the year PDF shortcut and the
  /// Month/Year switch. Shared by the month-scoped views rather than duplicated:
  /// `_month` and `_yearMode` live in this one State.
  Widget _monthSelector(
    BuildContext context,
    FinanceProvider finance,
    DateTime latestMonth,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final year = _month.year;
    return Row(
      children: [
        IconButton(
          tooltip: _yearMode ? 'Previous year' : 'Previous month',
          onPressed: () => _shiftMonth(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        // Tappable: browsing back a year used to take 12 arrow taps.
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _pickMonth(context, finance),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _yearMode ? '$year' : fmtMonth(_month),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: _yearMode ? 'Next year' : 'Next month',
          onPressed:
              (_yearMode
                  ? year < latestMonth.year
                  : _month.isBefore(latestMonth))
              ? () => _shiftMonth(1)
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
        // Scope switch as a quiet text button: a full-width segmented
        // control here read as a primary action and drew the eye away
        // from the figures. Month is the default; nothing is persisted.
        if (_yearMode)
          IconButton(
            tooltip: 'Export year report (PDF)',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.picture_as_pdf_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () => _exportYearPdf(context, finance),
          ),
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: scheme.onSurfaceVariant,
            textStyle: Theme.of(context).textTheme.labelMedium,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: () => setState(() => _yearMode = !_yearMode),
          child: Text(_yearMode ? 'Month view' : 'Year'),
        ),
        const InfoTip(
          title: 'Year view',
          message:
              'Year view adds up the 12 months of the year. Budgets, the '
              'monthly recap and pace, comparisons, the heatmap, merchants, '
              'groups and transfers are hidden, and the totals and '
              'categories do not open their transactions.',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    // A section moved, hidden or folded, and a bill hidden (subscriptions,
    // the heatmap's dots), rebuild the pages.
    context.select<SettingsProvider, String>((s) => s.dashboardLayoutKey);
    // The pace card on Trends reads the cap. The page lists build lazily
    // inside each page's Builder, so selects belong here, not in them.
    context.select<SettingsProvider, double>((s) => s.monthlyBudget);
    context.select<SettingsProvider, String>(
      (s) => hiddenListKey(s.hiddenUpcoming),
    );
    // The next-month arrow steps as far as data exists: rows re-dated one
    // day ahead put real entries in next month, which the picker sheet
    // already reaches — capping the arrow at the current month made the
    // two disagree.
    final now = DateTime.now();
    var latestMonth = DateTime(now.year, now.month);
    for (final m in finance.monthsWithData) {
      if (m.isAfter(latestMonth)) latestMonth = m;
    }
    final year = _month.year;
    // In Year view the "month" figures below are the year's: same widgets,
    // wider window.
    final byCategory = _yearMode
        ? finance.expenseByCategoryInYear(year)
        : finance.expenseByCategory(_month);
    final monthExpense = _yearMode
        ? finance.expenseInYear(year)
        : finance.expenseInMonth(_month);
    final groupSpend = finance.groupSpendInMonth(_month);
    final groupTotal = groupSpend.fold(0.0, (sum, e) => sum + e.$2);
    final transfersBy = finance.transfersByCategoryInMonth(_month);
    final topMerchantsList = _topMerchants(finance);
    final byTag = _yearMode
        ? finance.expenseByTagInYear(year)
        : finance.expenseByTagInMonth(_month);
    // Keys the capped lists, so a new month or view starts folded.
    final listKey = _yearMode ? 'y$year' : 'm${monthKey(_month)}';
    final colors = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hideIncome = context.select<SettingsProvider, bool>(
      (s) => s.hideIncome,
    );
    final categorySort = context.select<SettingsProvider, CategorySort>(
      (s) => s.categorySort,
    );
    // The stat cards' tips name the window their figures cover.
    final period = _yearMode ? 'this year' : 'this month';
    // One children-list builder per view; called lazily from each page's
    // Builder so only mounted pages construct their widgets.
    List<Widget> overviewChildren() {
      final header = <Widget>[
        // A newer release, offered by the launch check; empty otherwise.
        const UpdateBanner(),
        // A bank whose alerts stopped importing; empty otherwise.
        const ImportHealthBanner(),
        // First-run: the landing tab used to greet a new user with ₹0.00
        // everywhere and no hint of what to do next.
        if (!finance.hasTransactions) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 20, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Get started',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No transactions yet. Import your bank SMS, or add one by '
                    'hand.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // The two ways in, as buttons rather than directions to
                  // icons elsewhere on the screen.
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (AppNav.instance.canImportSms)
                        FilledButton.icon(
                          onPressed: () => AppNav.instance.importSms(context),
                          icon: const Icon(Icons.sms_outlined),
                          label: const Text('Import SMS'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => showAddTransactionSheet(context),
                        icon: const Icon(Icons.add),
                        label: const Text('Add transaction'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        KeyedSubtree(
          key: const ValueKey('balance'),
          child: _BalanceCard(finance: finance),
        ),
        // The picked month (or year) below the balance: the selector, its
        // totals, the monthly budget bar and last month's recap.
        const SizedBox(height: 16),
        _monthSelector(context, finance, latestMonth),
        const SizedBox(height: 4),
        // Horizontally scrollable so each card is wide enough to show its
        // amount on one line, however large the number. The height follows
        // the system font scale — fixed 88dp clips at "Large" text size.
        SizedBox(
          height: MediaQuery.textScalerOf(context).scale(88),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            children: [
              // Year-view taps stay month-scoped deep links (the Transactions
              // filter has no year), so they are disabled there.
              if (!hideIncome) ...[
                _StatCard(
                  label: 'Income',
                  value: _yearMode
                      ? finance.incomeInYear(year)
                      : finance.incomeInMonth(_month),
                  icon: Icons.arrow_downward,
                  color: colors.green,
                  tip:
                      'Money in $period, not counting transfers between '
                      'your own accounts or pending imports.',
                  onTap: widget.onViewTransactions == null || _yearMode
                      ? null
                      : () => widget.onViewTransactions!(TxType.income, _month),
                ),
                const SizedBox(width: 12),
              ],
              _StatCard(
                label: 'Spent',
                value: monthExpense,
                icon: Icons.arrow_upward,
                color: scheme.error,
                tip:
                    'Confirmed spending $period. Transfers and card bill '
                    'payments are left out, and a split bill counts only your '
                    'share.',
                link: const InfoLink(
                  prompt: 'Spending in the wrong category?',
                  label: 'Set up transaction rules',
                  onTap: goCockpitRules,
                ),
                onTap: widget.onViewTransactions == null || _yearMode
                    ? null
                    : () => widget.onViewTransactions!(TxType.expense, _month),
              ),
              const SizedBox(width: 12),
              // Savings outflow — the DISPLAY figure, which keeps reporting
              // even when the user un-transferred the savings category (the
              // money then also sits inside Spent; the balance math uses the
              // gated figure separately).
              _StatCard(
                label: 'Saved',
                value: _yearMode
                    ? finance.savingsOutflowInYear(year)
                    : finance.savingsOutflowInMonth(_month),
                icon: Icons.savings_outlined,
                color: colors.orange,
                tip: 'Money moved to savings $period.',
                onTap: widget.onViewCategory == null || _yearMode
                    ? null
                    : () => widget.onViewCategory!(
                        kSavingsTransferCategoryId,
                        _month,
                      ),
              ),
            ],
          ),
        ),
      ];
      // Overview never folds: each section is today's card, self-hiding as
      // before; only its place and whether it shows are the user's.
      final sections = <DashboardSection, _DashSection>{
        DashboardSection.monthlyBudget: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            // Monthly budget progress — only when a cap is set. Uses the selected
            // month's spend so browsing past months shows their usage too.
            Builder(
              key: const ValueKey('presence-monthly-budget'),
              builder: (context) {
                final budget = context.select<SettingsProvider, double>(
                  (s) => s.monthlyBudget,
                );
                // Hiding an Upcoming row changes the bills safe to spend sets
                // aside.
                context.select<SettingsProvider, String>(
                  (s) => hiddenListKey(s.hiddenUpcoming),
                );
                final now = DateTime.now();
                // About today, so only under this month's figures.
                final safe =
                    budget <= 0 || _month != DateTime(now.year, now.month)
                    ? null
                    : computeSafeToSpend(
                        finance,
                        cap: budget,
                        patterns: _patterns(finance, now),
                        hidden: context.read<SettingsProvider>().hiddenUpcoming,
                        now: now,
                      );
                return AnimatedPresence(
                  visible: budget > 0 && !_yearMode,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: _BudgetCard(
                      spent: finance.budgetSpentInMonth(_month),
                      cap: budget,
                      safe: safe,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        DashboardSection.recap: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            // Last month's recap, for the first days of a month. About today's
            // month, so only while the selector shows it: under March's totals it
            // would read as March's. Its title names the month it sums up.
            Builder(
              key: _recapKey,
              builder: (context) {
                // Selected so a cap edit re-evaluates the budget lines.
                context.select<SettingsProvider, double>(
                  (s) => s.monthlyBudget,
                );
                final recap = _monthCardFor(
                  finance,
                  context.read<SettingsProvider>(),
                ).recap;
                final today = recapClock();
                // Year view drops it with the budgets: its lines are monthly.
                final showing =
                    recap != null &&
                    !_yearMode &&
                    _month == DateTime(today.year, today.month);
                return AnimatedPresence(
                  visible: showing,
                  child: !showing
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: MonthlyRecapCard(
                            recap: recap,
                            onViewCategory: widget.onViewCategory,
                            onViewMerchant: widget.onViewMerchant,
                            onViewBudget: widget.onViewBudget,
                            onViewSpending: _viewSpending,
                          ),
                        ),
                );
              },
            ),
          ],
        ),
        DashboardSection.upcoming: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            // Card bills coming due + detected recurring payments. Not
            // month-scoped: it is about the days ahead whatever month is picked.
            _UpcomingCard(finance: finance, hits: _recurring(finance)),
          ],
        ),
        DashboardSection.budgets: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            // Custom spend limits, one compact progress row each — full ring
            // cards would dominate the page with several budgets. Budgets are
            // monthly, so the Year view skips them.
            // The sections the Year view drops fold away (and back) rather than
            // popping, so the switch reads as one change.
            AnimatedPresence(
              key: const ValueKey('presence-budgets'),
              visible: finance.budgets.isNotEmpty && !_yearMode,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  const _SectionHeading(
                    'Budgets',
                    tip:
                        '"Only these" budgets count the picked categories; "All '
                        'except" budgets count everything else. Same colours as the '
                        'monthly budget.',
                    link: InfoLink(
                      prompt: 'Need another limit?',
                      label: 'Add or edit budgets',
                      onTap: goCockpitBudgets,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      // all(16): the dashboard's section cards had six different
                      // inner paddings — edges never lined up while scrolling.
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          for (final b in finance.budgets)
                            _SpendBudgetRow(
                              name: b.name,
                              spent: finance.budgetSpentFor(b, _month),
                              limit: b.limit,
                              // Detail sheet (ring + pie + trend); the transactions
                              // deep-link lives on a button inside it.
                              onTap: () => showBudgetDetailSheet(
                                context,
                                b,
                                _month,
                                onViewTransactions: widget.onViewBudget,
                                onViewCategory: widget.onViewCategory,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        DashboardSection.owed: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            // What friends still owe on split bills. All-time, so the Year view
            // keeps it.
            AnimatedPresence(
              key: const ValueKey('presence-owed'),
              visible: finance.totalOwed > 0,
              child: finance.totalOwed > 0
                  ? _OwedCard(finance: finance)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      };
      return _page(DashboardPage.overview, header, sections, fold: false);
    }

    List<Widget> trendsChildren() {
      final pace = _monthCardFor(
        finance,
        context.read<SettingsProvider>(),
      ).pace;
      final today = recapClock();
      final comparison = _yearMode ? null : _comparison(finance);
      String? against(SpendCompare? c, String what) {
        // Nothing either side is the card's "Nothing recorded", not a match.
        if (c == null || c.state != CompareState.ok || c.empty) return null;
        if (c.negligible) return 'Same as $what';
        final p = c.deltaPct;
        if (p == null) return null;
        final n = (p.abs() * 100).round();
        if (n == 0) return 'About the same as $what';
        return p > 0 ? 'Up $n% on $what' : 'Down $n% on $what';
      }

      CategoryCompare? mover;
      // Only with a usual to speak of: short of the months it needs, the
      // card says so, and every category reads as "up" on a zero usual.
      final hasUsual =
          comparison != null && comparison.usualMonths >= kMinUsualMonths;
      for (final c
          in hasUsual ? comparison.categories : const <CategoryCompare>[]) {
        if (c.state == CompareState.ok && !c.negligible && c.delta > 0) {
          mover = c;
          break;
        }
      }
      final sections = <DashboardSection, _DashSection>{
        // This month so far, once the recap week is over. About today's
        // month, so only while the selector shows it.
        DashboardSection.pace: (
          visible:
              pace != null &&
              !_yearMode &&
              _month == DateTime(today.year, today.month),
          title: null,
          // The card's own figure: spend through today.
          summary: pace == null
              ? null
              : '${fmtMoneyCompact(pace.comparison.vsPrevious.actual)} so far',
          tip: null,
          body: () => [
            KeyedSubtree(
              key: _paceKey,
              child: MonthPaceCard(
                pace: pace!,
                onViewBudget: widget.onViewBudget,
                onViewSpending: _viewSpending,
              ),
            ),
          ],
        ),
        // Now vs then. Month concepts, so the Year view steps aside the
        // way budgets and the heatmap already do.
        DashboardSection.previousMonth: (
          visible: comparison != null,
          title: null,
          summary: against(comparison?.vsPrevious, 'last month'),
          tip: null,
          body: () => [PreviousMonthCard(comparison: comparison!)],
        ),
        DashboardSection.usual: (
          visible: comparison != null,
          title: null,
          summary: against(comparison?.vsUsual, 'a usual month'),
          tip: null,
          body: () => [UsualSpendCard(comparison: comparison!)],
        ),
        DashboardSection.categoryComparison: (
          visible: comparison != null,
          title: null,
          summary: mover == null
              ? null
              : '${mover.category.label} up most on usual',
          tip: null,
          body: () => [
            CategoryComparisonCard(
              comparison: comparison!,
              onViewCategory: widget.onViewCategory == null
                  ? null
                  : (id) => widget.onViewCategory!(id, _month),
              sort: categorySort,
              onSortChanged: (s) =>
                  context.read<SettingsProvider>().setCategorySort(s),
            ),
          ],
        ),
        DashboardSection.sixMonths: (
          visible: true,
          title: _yearMode
              ? 'Months of $year'
              : _month == DateTime(DateTime.now().year, DateTime.now().month)
              ? 'Last 6 months'
              : '6 months to ${fmtMonth(_month)}',
          summary: hideIncome ? 'Spend by month' : 'Income and spend by month',
          tip: null,
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    MonthlyBarChart(
                      months: _yearMode
                          ? [for (var m = 1; m <= 12; m++) DateTime(year, m)]
                          : null,
                      end: _month,
                      showIncome: !hideIncome,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!hideIncome) ...[
                          _LegendDot(color: colors.green, label: 'Income'),
                          const SizedBox(width: 16),
                        ],
                        _LegendDot(color: scheme.error, label: 'Expense'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      };
      return _page(
        DashboardPage.trends,
        [
          _monthSelector(context, finance, latestMonth),
          const SizedBox(height: 4),
        ],
        sections,
        fold: true,
      );
    }

    List<Widget> breakdownChildren() {
      final subs = cachedSubscriptions(
        finance,
        context.read<SettingsProvider>().hiddenUpcoming,
      );
      final bills = _yearMode ? const <DueBill>[] : _heatmapBills(finance);
      final weekdays = finance.avgExpenseByWeekday();
      var busiest = 0;
      for (var i = 1; i < weekdays.length; i++) {
        if (weekdays[i] > weekdays[busiest]) busiest = i;
      }
      (CategoryGroup?, double)? topGroup;
      for (final g in groupSpend) {
        if (topGroup == null || g.$2 > topGroup.$2) topGroup = g;
      }
      String pct(double part, double whole) =>
          whole <= 0 ? '' : ', ${(part / whole * 100).round()}%';
      final sections = <DashboardSection, _DashSection>{
        DashboardSection.donut: (
          visible: true,
          title: null,
          summary: byCategory.isEmpty
              ? null
              : '${fmtMoneyCompact(monthExpense)} across ${byCategory.length} '
                    '${byCategory.length == 1 ? 'category' : 'categories'}',
          tip: null,
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: CategoryDonutChart(
                  data: byCategory,
                  emptyText: _yearMode
                      ? 'No spending this year'
                      : 'No spending this month',
                  onCategoryTap: widget.onViewCategory == null || _yearMode
                      ? null
                      : (id) => widget.onViewCategory!(id, _month),
                ),
              ),
            ),
          ],
        ),
        DashboardSection.byCategory: (
          visible: byCategory.isNotEmpty,
          title: null,
          summary: byCategory.isEmpty
              ? null
              : '${byCategory.first.key.label} leads'
                    '${pct(byCategory.first.value, monthExpense)}',
          tip: InfoTip(
            title: 'By category',
            message:
                "The percentage is this category's share of the "
                "${_yearMode ? "year's" : "month's"} spending. Long-press a "
                'row to set or edit a budget for it; "of ₹X" shows that '
                'budget.',
            link: const InfoLink(
              prompt: 'Transactions not classified right?',
              label: 'Set up transaction rules',
              onTap: goCockpitRules,
            ),
          ),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ShowAllList(
                  key: ValueKey('categories-$listKey'),
                  noun: 'categories',
                  rows: [
                    for (final entry in byCategory)
                      _CategoryRow(
                        icon: entry.key.icon,
                        color: entry.key.color,
                        label: entry.key.label,
                        amount: entry.value,
                        fraction: monthExpense == 0
                            ? 0
                            : entry.value / monthExpense,
                        budgetLimit: _yearMode
                            ? null
                            : _singleCategoryBudget(
                                finance,
                                entry.key.id,
                              )?.limit,
                        onTap: widget.onViewCategory == null || _yearMode
                            ? null
                            : () =>
                                  widget.onViewCategory!(entry.key.id, _month),
                        // Shortcut to a per-category cap: opens the shared
                        // budget dialog pre-filled (or the existing one).
                        onLongPress: () => showBudgetDialog(
                          context,
                          existing: _singleCategoryBudget(
                            finance,
                            entry.key.id,
                          ),
                          presetName: entry.key.label,
                          presetMode: BudgetMode.include,
                          presetCategoryIds: {entry.key.id},
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        DashboardSection.byTags: (
          visible: byTag.isNotEmpty,
          title: null,
          summary: byTag.isEmpty
              ? null
              : '${byTag.first.tag} ${fmtMoneyCompact(byTag.first.spent)}',
          tip: InfoTip(
            title: 'By tags',
            message:
                "Each tag's share of the ${_yearMode ? "year's" : "month's"} "
                'spending. A transaction with two tags counts under both, so '
                'the shares can add up to more than 100%. Long-press a tag to '
                'rename it, give it a colour or delete it.',
            link: const InfoLink(
              prompt: 'Every tag, with all-time totals?',
              label: 'Open Tags',
              onTap: goCockpitTags,
            ),
          ),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ShowAllList(
                  key: ValueKey('tags-$listKey'),
                  noun: 'tags',
                  rows: [
                    for (final t in byTag)
                      _CategoryRow(
                        icon: Icons.sell_outlined,
                        color: finance.tagColor(t.tag) ?? scheme.tertiary,
                        label: t.tag,
                        amount: t.spent,
                        fraction: monthExpense == 0
                            ? 0
                            : t.spent / monthExpense,
                        onTap: widget.onViewTag == null || _yearMode
                            ? null
                            : () => widget.onViewTag!(t.tag, _month),
                        onLongPress: () => showTagEditor(context, t.tag),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        // Where the money actually went: per-payee totals for the month,
        // re-derived from SMS bodies / manual notes. Display-only — the
        // transactions filter can't express a free-text payee (yet).
        // Shown whenever the month has spending: an empty month-start used
        // to make the whole section vanish, which read as a bug rather than
        // "nothing identifiable yet".
        DashboardSection.merchants: (
          visible:
              !_yearMode && (topMerchantsList.isNotEmpty || monthExpense > 0),
          title: null,
          summary: topMerchantsList.isEmpty
              ? null
              : '${topMerchantsList.first.label} '
                    '${fmtMoneyCompact(topMerchantsList.first.total)}',
          tip: const InfoTip(
            title: 'Top merchants',
            message:
                'Names come from the SMS text or the note. Transfers and spam '
                'are left out. Long-press a merchant to rename it everywhere.',
          ),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (topMerchantsList.isEmpty)
                      Text(
                        'No identifiable merchants in ${fmtMonth(_month)} yet. '
                        'Payments to phone numbers, VPAs without a name and '
                        'bank references are left out; add a note to a '
                        'transaction to name it.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ShowAllList(
                      key: ValueKey('merchants-$listKey'),
                      noun: 'merchants',
                      rows: [
                        for (final m in topMerchantsList)
                          InkWell(
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                            onTap: widget.onViewMerchant == null
                                ? null
                                // The search matches notes/bodies, so the query is
                                // the normalized identity, not the cased label.
                                : () => widget.onViewMerchant!(
                                    m.key.substring(m.key.indexOf('|') + 1),
                                    _month,
                                  ),
                            onLongPress: () => _renameMerchant(context, m),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.storefront_outlined,
                                    size: 20,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          m.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          m.count == 1
                                              ? '1 payment'
                                              : '${m.count} payments',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 120,
                                    ),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        fmtMoney(m.total),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        // Regular payments at a glance; the list lives in the Cockpit. Not
        // month-scoped (it reads the last year), so it shows in both views.
        DashboardSection.subscriptions: (
          visible: subs.active.isNotEmpty,
          title: null,
          summary:
              '${subs.active.length} active, '
              '${fmtMoneyCompact(subs.monthlyTotal)} a month',
          tip: null,
          body: () {
            final n = subs.active.length;
            return [
              Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: () => goCockpitSubscriptions(context),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.autorenew,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Subscriptions',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              Text(
                                '$n regular '
                                '${n == 1 ? 'payment' : 'payments'}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${fmtMoney(subs.monthlyTotal)} a month',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ];
          },
        ),
        // Spending per parent group (Needs/Wants/…). Grouped transfer
        // outflows are included in their group's sum; "Other" collects
        // ungrouped categories (ungrouped transfers stay out of it).
        DashboardSection.groups: (
          visible: finance.groups.isNotEmpty && groupTotal > 0 && !_yearMode,
          title: null,
          summary: topGroup == null || groupTotal <= 0
              ? null
              : '${topGroup.$1?.label ?? 'Other'} '
                    '${(topGroup.$2 / groupTotal * 100).round()}%',
          tip: const InfoTip(
            title: 'By group',
            message:
                "Each group's share of the grouped total. Categories with "
                'no group count under Other. Money-out transfers in a grouped '
                'category count toward its group; other transfers are left '
                'out.',
            link: InfoLink(
              prompt: 'Change what is in each group?',
              label: 'Edit groups',
              onTap: goCockpitCategories,
            ),
          ),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ShowAllList(
                  key: ValueKey('groups-$listKey'),
                  noun: 'groups',
                  rows: [
                    for (final (group, amount) in groupSpend)
                      _CategoryRow(
                        icon: group == null
                            ? Icons.category
                            : Icons.workspaces_outlined,
                        color: group?.color ?? scheme.onSurfaceVariant,
                        label: group?.label ?? 'Other',
                        amount: amount,
                        fraction: groupTotal == 0 ? 0 : amount / groupTotal,
                        // null group = the "Other" (ungrouped) bucket — the
                        // callback owner maps it to the ungrouped filter key.
                        onTap: widget.onViewGroup == null
                            ? null
                            : () => widget.onViewGroup!(group?.id, _month),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        // Spending hotspots: which DATES were hot this month, and which
        // weekdays are usually hot across history. Also before the month's
        // first spend, once bills are due: the dots are most useful then.
        DashboardSection.heatmap: (
          visible: !_yearMode && (monthExpense > 0 || bills.isNotEmpty),
          title: null,
          summary: bills.isNotEmpty
              ? '${bills.length} ${bills.length == 1 ? 'bill' : 'bills'} due'
              : weekdays[busiest] > 0
              ? 'Busiest on ${_kWeekdayNames[busiest]}s'
              : null,
          tip: const InfoTip(title: 'Spending heatmap', message: _heatmapTip),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SpendingHeatmap(month: _month, bills: bills),
              ),
            ),
          ],
        ),
        // Transfers: own-account moves for the month. Not income or
        // expense; shown separately so the flows are still visible.
        DashboardSection.transfers: (
          visible: transfersBy.isNotEmpty && !_yearMode,
          title: null,
          summary:
              '${fmtMoneyCompact(finance.transferOutInMonth(_month))} out, '
              '${fmtMoneyCompact(finance.transferInInMonth(_month))} in',
          tip: const InfoTip(
            title: 'Transfers',
            message:
                'Money moved between your own accounts. Out also includes '
                "friends' shares of split bills, which have no transaction of "
                'their own.',
            link: InfoLink(
              prompt: 'A category should count as a transfer?',
              label: 'Edit categories',
              onTap: goCockpitCategories,
            ),
          ),
          body: () => [
            Card(
              child: Padding(
                // all(16): the dashboard's section cards had six different
                // inner paddings — edges never lined up while scrolling.
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    BreakdownRow(
                      icon: Icons.arrow_downward,
                      color: colors.green,
                      label: 'In',
                      amount: '+${fmtMoney(finance.transferInInMonth(_month))}',
                    ),
                    BreakdownRow(
                      icon: Icons.arrow_upward,
                      color: scheme.error,
                      label: 'Out',
                      amount:
                          '−${fmtMoney(finance.transferOutInMonth(_month))}',
                    ),
                    const Divider(height: 20),
                    ShowAllList(
                      key: ValueKey('transfers-$listKey'),
                      noun: 'categories',
                      rows: [
                        for (final entry in transfersBy)
                          BreakdownRow(
                            icon: entry.key.icon,
                            color: entry.key.color,
                            label: entry.key.label,
                            amount:
                                '${entry.key.type == TxType.income ? '+' : '−'}'
                                '${fmtMoney(entry.value)}',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      };
      return _page(
        DashboardPage.breakdown,
        [
          _monthSelector(context, finance, latestMonth),
          const SizedBox(height: 4),
        ],
        sections,
        fold: true,
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: GlassSegmented<DashboardView>(
            options: [for (final v in DashboardView.values) (v, v.label)],
            icons: const [
              Icons.space_dashboard_outlined,
              Icons.show_chart,
              Icons.pie_chart_outline,
            ],
            selected: _view,
            onChanged: _setView,
            pager: _pageCtrl,
          ),
        ),
        Expanded(
          child: PageView(
            controller: _pageCtrl,
            onPageChanged: (i) =>
                setState(() => _view = DashboardView.values[i]),
            // No PageStorageKey anywhere: off-screen pages dispose (no
            // keepAlive, zero cache extent), so every view change still
            // starts at the top instead of at a remembered offset.
            children: [
              for (final (page, ahead) in [
                (overviewChildren, 5000.0),
                (trendsChildren, 2500.0),
                (breakdownChildren, null),
              ])
                // Transparent ColoredBox: a PageView only receives drags
                // that hit its subtree, and blank regions need an opaque
                // hit-test surface. The Builder defers each page's widget
                // construction until the page is mounted.
                ColoredBox(
                  color: Colors.transparent,
                  child: Builder(
                    builder: (context) => ListView(
                      padding: const EdgeInsets.all(16),
                      // Sections can be moved down the page, and the recap
                      // notification scrolls to the recap (Overview) or the
                      // pace (Trends): build ahead so the card exists to
                      // scroll to. Breakdown has nothing to reveal.
                      scrollCacheExtent: ahead == null
                          ? null
                          : ScrollCacheExtent.pixels(ahead),
                      children: page(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Owed to you": the total friends still owe on split bills and the two
/// biggest balances, opening the People page.
class _OwedCard extends StatelessWidget {
  final FinanceProvider finance;
  const _OwedCard({required this.finance});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final owing = [
      for (final b in finance.peopleBalances)
        if (b.owed > 0) b,
    ];
    final line = [
      for (final b in owing.take(2)) '${b.name} ${fmtMoney(b.owed)}',
      if (owing.length > 2) '+${owing.length - 2} more',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: () => goPeople(context),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.group, size: 20, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Owed to you', style: text.titleSmall),
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      fmtMoney(finance.totalOwed),
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Upcoming": card bills coming due plus detected monthly payments,
/// soonest first. Renders nothing (zero height) when there is nothing to
/// show, so the sections around it keep their spacing.
class _UpcomingCard extends StatelessWidget {
  final FinanceProvider finance;
  final List<RecurringHit> hits;
  const _UpcomingCard({required this.finance, required this.hits});

  /// One duration for the fold, the chevron flip and the count fade, so the
  /// three movements read as a single gesture.
  static const _foldDuration = Duration(milliseconds: 250);

  static String _inDays(int days) => days == 0
      ? 'today'
      : days == 1
      ? 'tomorrow'
      : 'in $days days';

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();

    final entries = [
      for (final u in buildUpcomingItems(
        finance,
        hits: hits,
        hidden: settings.hiddenUpcoming,
        now: now,
      ))
        switch (u.kind) {
          UpcomingKind.cardBill => (
            due: u.due,
            icon: Icons.credit_card,
            // Traffic-light phases: green = nothing owed right now (not
            // billed / paid), orange = billed, red = due within the urgent
            // window or overdue.
            color: cardBillColor(
              u.cardStatus!,
              green: AppColors.of(context).green,
              orange: AppColors.of(context).orange,
              red: scheme.error,
            ),
            label: u.label,
            // Paid and not-yet-billed cycles keep their row (the amount is
            // the live figure building toward the next/current statement)
            // with the amount muted — only a billed, unpaid cycle asks for
            // attention.
            sub: cardBillSubtitle(u.cardStatus!),
            amount: u.amount,
            urgent: u.urgent,
            muted: u.muted,
            hideKey: u.hideKey,
            reminder: u.reminder,
            card: u.card,
          ),
          UpcomingKind.recurring => (
            due: u.due,
            icon: categoryById(u.categoryId!, fallbackType: u.type).icon,
            color: categoryById(u.categoryId!, fallbackType: u.type).color,
            label: u.label,
            sub: u.days < 0
                ? 'Overdue · expected ${fmtDateCompact(u.due)}'
                : 'Expected ${fmtDateCompact(u.due)} · ${_inDays(u.days)}',
            amount: u.amount,
            urgent: u.urgent,
            muted: u.muted,
            hideKey: u.hideKey,
            reminder: u.reminder,
            card: u.card,
          ),
          // Manual reminders: shown from a week before the due day (the
          // schedule already skips a month marked paid).
          UpcomingKind.reminder => (
            due: u.due,
            icon: categoryById(u.categoryId!, fallbackType: u.type).icon,
            color: categoryById(u.categoryId!, fallbackType: u.type).color,
            label: u.label,
            sub: u.days < 0
                ? 'Overdue · was due ${fmtDateCompact(u.due)}'
                : 'Due ${fmtDateCompact(u.due)} · ${_inDays(u.days)}',
            amount: u.amount,
            urgent: u.urgent,
            muted: u.muted,
            hideKey: u.hideKey,
            reminder: u.reminder,
            card: u.card,
          ),
        },
    ];
    if (entries.isEmpty && finance.reminders.isEmpty) {
      return const SizedBox.shrink();
    }
    final collapsed = settings.isSectionCollapsed('upcoming');

    // The gap lives here, not at the call site: an empty card renders
    // nothing, and must not leave its gap behind.
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tappable header: the card can dominate the top of the dashboard,
          // so it folds to this row (persisted per device).
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.control),
            onTap: () =>
                context.read<SettingsProvider>().toggleSection('upcoming'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Text(
                    'Upcoming',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(width: 8),
                  // Static in both states. Fading the count in step with the
                  // fold rendered its glyphs in two halves on Impeller, so the
                  // header no longer animates any text.
                  Text(
                    '${entries.length}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  // A direct child of the header row, beside the count: the
                  // row's own tap folds the card, the tip's tap stays its own.
                  const InfoTip(
                    title: 'Upcoming',
                    message:
                        'Card bills, your reminders from a week before to a '
                        'week after their due day, and payments the app '
                        'spotted repeating (from SMS or your notes), '
                        'including regular income. A repeat is spotted after 3 '
                        'payments to the same merchant about a month apart. '
                        'Card icons: green not billed or paid, orange billed, '
                        'red due within 5 days or overdue. Long-press a '
                        'spotted payment to hide it.',
                    link: InfoLink(
                      prompt: 'A bill the app cannot detect?',
                      label: 'Add a reminder',
                      onTap: goNewReminder,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Add reminder',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.add_alert_outlined,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                    onPressed: () => showReminderEditor(context),
                  ),
                  AnimatedRotation(
                    turns: collapsed ? 0.5 : 0,
                    duration: _foldDuration,
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
          // Pure height reveal, no fade: cross-fading made the amounts appear
          // half-transparent while the card expanded.
          AnimatedFold(
            collapsed: collapsed,
            child: Column(
              children: [
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        if (entries.isEmpty)
                          Text(
                            'Nothing due soon.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        for (final e in entries.take(6))
                          InkWell(
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                            // Manual reminders: tap for mark paid / edit /
                            // delete. Card bills: mark paid / record payment.
                            onTap: e.reminder != null
                                ? () => _showReminderActions(
                                    context,
                                    e.reminder!,
                                    e.due,
                                  )
                                : e.card != null
                                ? () => _showCardBillActions(context, e.card!)
                                : null,
                            // Detected patterns can be wrong — long-press hides one.
                            // Card bills aren't hideable; clear the card's due day
                            // instead.
                            onLongPress: e.hideKey == null
                                ? null
                                : () => _confirmHide(
                                    context,
                                    e.label,
                                    e.hideKey!,
                                  ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  // The icon keeps its color even on muted
                                  // rows — for card bills the color itself
                                  // carries the state (green/orange/red).
                                  Icon(e.icon, size: 20, color: e.color),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          e.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          e.sub,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: e.urgent
                                                    ? scheme.error
                                                    : null,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 120,
                                    ),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        e.amount == null
                                            ? ''
                                            : fmtMoney(e.amount!),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: e.muted
                                              ? scheme.onSurfaceVariant
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Three plain actions for a manual reminder row. (showPickerSheet was
  /// rejected here: its always-on search field is wrong for a 3-item menu.)
  void _showReminderActions(BuildContext context, Reminder r, DateTime due) {
    final finance = context.read<FinanceProvider>();
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(r.name, style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: Text('Due ${fmtDate(due)}'),
            ),
            if (r.autoAdd)
              // It records its own expense: paying early means recording it
              // now, since marking it paid alone would leave it out.
              ListTile(
                leading: const Icon(Icons.add_task),
                title: const Text('Add it now'),
                subtitle: const Text(
                  'Paid early: records it today, not on the due day',
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final messenger = ScaffoldMessenger.of(context);
                  final before = r;
                  final txId = await finance.addReminderPaymentNow(
                    r.id,
                    due,
                    DateTime.now(),
                  );
                  if (txId == null) return;
                  showAppToastOn(
                    messenger,
                    'Added ${r.name}',
                    tone: AppToastTone.success,
                    icon: Icons.add_task,
                    actionLabel: 'Undo',
                    onAction: () async {
                      await finance.deleteTransactions([txId]);
                      await finance.updateReminder(before);
                    },
                    duration: const Duration(seconds: 5),
                  );
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Mark paid'),
                onTap: () {
                  Navigator.pop(ctx);
                  final before = r;
                  finance.markReminderPaid(r.id, due);
                  showUndoSnackBar(
                    context,
                    '${r.name} marked paid',
                    () => finance.updateReminder(before),
                    icon: Icons.task_alt,
                    tone: AppToastTone.success,
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                showReminderEditor(context, existing: r);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(ctx);
                final before = r;
                finance.deleteReminder(r.id);
                showUndoSnackBar(
                  context,
                  'Deleted reminder "${r.name}"',
                  () => finance.restoreReminder(before),
                  icon: Icons.delete_outline,
                  tone: AppToastTone.removal,
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Mark paid / record payment for a card bill row. The natural due (this
  /// cycle's, ignoring the paid flag) is recomputed here: a paid row already
  /// DISPLAYS next cycle's date, but un-marking and the paid flag itself are
  /// about the current cycle.
  void _showCardBillActions(BuildContext context, Account a) {
    final finance = context.read<FinanceProvider>();
    final now = DateTime.now();
    final natural = nextMonthlyOccurrence(a.dueDay!, now);
    final paid = a.billPaidMonth == monthKey(natural);
    final status = cardBillStatus(a, now)!;
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      // Four tiles can outgrow the sheet's default max height on short
      // screens — scroll instead of clipping.
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  '${a.name} bill',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                subtitle: Text(cardBillSubtitle(status)),
              ),
              if (paid)
                ListTile(
                  leading: const Icon(Icons.undo),
                  title: const Text('Undo mark paid'),
                  onTap: () {
                    Navigator.pop(ctx);
                    finance.clearCardBillPaid(a.id);
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.check_circle_outline),
                  title: const Text('Mark paid for this cycle'),
                  subtitle: const Text(
                    'The amount keeps showing what has built up since — '
                    'that belongs to the next bill.',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    final prev = a.billPaidMonth;
                    finance.markCardBillPaid(a.id, natural);
                    showUndoSnackBar(
                      context,
                      '${a.name} bill marked paid',
                      () => finance.setCardBillPaidMonth(a.id, prev),
                      icon: Icons.task_alt,
                      tone: AppToastTone.success,
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: const Text('Record a payment…'),
                subtitle: const Text(
                  'For a payment the app never saw — the amount drops by '
                  'what you paid.',
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showRecordPaymentDialog(context, a, natural);
                },
              ),
              // The phase logic is only as good as the cycle dates — surface
              // the editor here so the statement day can be set where its
              // absence shows.
              ListTile(
                leading: const Icon(Icons.edit_calendar_outlined),
                title: const Text('Statement & due dates…'),
                onTap: () {
                  Navigator.pop(ctx);
                  showCardCycleDialog(context, a);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showRecordPaymentDialog(
    BuildContext context,
    Account a,
    DateTime due,
  ) async {
    final finance = context.read<FinanceProvider>();
    final ctrl = TextEditingController();
    var paidOn = DateTime.now();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => DisposeScope(
        disposables: [ctrl],
        child: StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            scrollable: true,
            title: const Text('Record a payment'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Amount paid',
                    prefixText: '₹ ',
                    helperText:
                        'The bill amount you paid — this cycle is marked '
                        'paid and the outstanding drops by it.',
                    helperMaxLines: 4,
                    border: const OutlineInputBorder(),
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: const Text('Paid on'),
                  subtitle: Text(fmtDate(paidOn)),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: paidOn,
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 30),
                      ),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setState(() => paidOn = picked);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  final v = parseAmount(ctrl.text.trim());
                  if (v == null || v <= 0) {
                    setState(() => error = 'Enter the amount you paid');
                    return;
                  }
                  Navigator.pop(ctx);
                  final result = await finance.recordCardPayment(
                    accountId: a.id,
                    amount: v,
                    paidOn: paidOn,
                    due: due,
                  );
                  if (result == null || !context.mounted) return;
                  showUndoSnackBar(
                    context,
                    'Recorded ${fmtMoney(v)} payment'
                    '${result.pairId != null ? ' · matched a bank debit' : ''}',
                    () async {
                      await finance.deleteTransaction(result.txId);
                      if (result.bankLegBefore != null) {
                        await finance.restoreEditedTransactions([
                          result.bankLegBefore!,
                        ]);
                      }
                      await finance.setCardBillPaidMonth(
                        a.id,
                        result.prevPaidMonth,
                      );
                    },
                    icon: Icons.payments_outlined,
                    tone: AppToastTone.success,
                  );
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmHide(BuildContext context, String label, String key) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hide "$label"?'),
        content: const Text(
          'This detected payment will no longer appear in Upcoming or fire '
          'reminders.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              ctx.read<SettingsProvider>().hideUpcoming(key);
              Navigator.pop(ctx);
            },
            child: const Text('Hide'),
          ),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final FinanceProvider finance;
  const _BalanceCard({required this.finance});

  /// With accounts, the headline is the bank-stated net worth — ledger
  /// arithmetic (income − expense) is unreliable when the SMS history has no
  /// opening balances. Without accounts, fall back to the ledger figure.
  bool get _useAccounts => finance.accounts.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Neutral frosted panel with the amount as the neon accent — same
    // material as the segmented filter bar. InkWell, not GestureDetector:
    // the card is a button and should ripple and read as one to a11y.
    return FrostedPanel(
      radius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => showBalanceBreakdownSheet(context, finance),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: InfoLabel(
                        label: Text(
                          _useAccounts ? 'Net balance' : 'Available balance',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        tip: _useAccounts
                            ? InfoTip(
                                title: 'Net balance',
                                message:
                                    'Bank balances minus what you owe on '
                                    'credit cards. Savings and closed '
                                    'accounts are left out. A card with no '
                                    'known outstanding counts as zero.',
                                // The balance breakdown sheet's own figures.
                                example: () =>
                                    'Now: ${fmtMoney(finance.bankBalanceTotal)} '
                                    'in banks − '
                                    '${fmtMoney(finance.cardOutstandingTotal)} '
                                    'on cards = ${fmtMoney(finance.netWorth)}',
                                link: const InfoLink(
                                  prompt: 'A card missing its credit limit?',
                                  label: 'Open accounts',
                                  onTap: goAccounts,
                                ),
                              )
                            : InfoTip(
                                title: 'Available balance',
                                message:
                                    'All income minus all spending and money '
                                    'moved to savings, since your first '
                                    'transaction.',
                                example: () {
                                  if (!finance.hasTransactions) return null;
                                  // Masked like the breakdown sheet's
                                  // income row when income is hidden.
                                  final hide = context
                                      .read<SettingsProvider>()
                                      .hideIncome;
                                  final saved = finance.totalSavingsTransfers;
                                  return '${hide ? kMaskedAmount : fmtMoney(finance.totalIncome)} in'
                                      ' − ${fmtMoney(finance.totalExpense)} out'
                                      '${saved > 0 ? ' − ${fmtMoney(saved)} to savings' : ''}'
                                      ' = ${fmtMoney(finance.balance)}';
                                },
                              ),
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 6),
              // Morphs in place when the figure changes (edit, import, sync).
              MorphingAmount(
                value: _useAccounts ? finance.netWorth : finance.balance,
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (finance.totalSavingsTransfers > 0) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.savings,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: InfoLabel(
                          label: Text(
                            '${fmtMoney(finance.totalSavingsTransfers)} moved '
                            'to savings',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          tip: const InfoTip(
                            title: 'Moved to savings',
                            message:
                                'All money moved to savings since your first '
                                'transaction. It is already taken out of the '
                                "figure above. Your savings accounts' value "
                                'shows under Accounts.',
                            link: InfoLink(
                              prompt: 'Where is the money now?',
                              label: 'See savings accounts',
                              onTap: goSavingsAccounts,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Monthly-cap progress: spent vs cap, coloured by [budgetColor] (green,
/// then amber from 80%, red above 95%).
class _BudgetCard extends StatelessWidget {
  final double spent;
  final double cap;

  /// This month's safe to spend today; null under any other month.
  final SafeToSpend? safe;
  const _BudgetCard({required this.spent, required this.cap, this.safe});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pct = cap <= 0 ? 0.0 : (spent / cap);
    final over = spent > cap;
    final color = budgetColor(context, pct);
    final remaining = cap - spent;

    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            // Ring sweeps to the usage fraction while the centre % counts up
            // in sync. Passing the true fraction (may exceed 1) lets the
            // label keep climbing past 100% while the arc stays full.
            RingProgress(
              value: pct,
              color: color,
              // 15% was invisible on the light surface — an empty ring read
              // as "no track at all" at low spend.
              trackColor: color.withValues(alpha: 0.3),
              labelStyle: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.account_balance_wallet_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: InfoLabel(
                          label: Text(
                            'Monthly budget',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          tip: InfoTip(
                            title: 'Monthly budget',
                            message:
                                'Spending against the monthly cap set in '
                                'Cockpit, Plan, Budgets. Green below 80%, orange '
                                'from 80%, red above 95%. The ring stays full '
                                'past 100% while the percentage keeps '
                                'counting. Safe to spend today sets aside the '
                                'bills still due this month (not card bills or '
                                'transfers) and spreads the rest over the days '
                                'left.',
                            // Rounded the way the ring's centre label is.
                            example: () {
                              final line =
                                  '${fmtMoney(spent)} of ${fmtMoney(cap)} = '
                                  '${(pct * 100).round()}%';
                              final s = safe;
                              if (s == null || over || s.overCap) return line;
                              final left =
                                  cap - s.spentBeforeToday - s.billsDue;
                              return '$line\n\nSafe to spend today: '
                                  '${fmtMoney(cap)} − '
                                  '${fmtMoney(s.spentBeforeToday)} spent − '
                                  '${fmtMoney(s.billsDue)} bills due = '
                                  '${fmtMoney(left)} over ${s.daysLeft} '
                                  '${s.daysLeft == 1 ? 'day' : 'days'} = '
                                  '${fmtMoney(s.dailyAllowance)} a day'
                                  '${s.spentToday > 0 ? ', less ${fmtMoney(s.spentToday)} spent today' : ''}.';
                            },
                            link: const InfoLink(
                              prompt: 'Want a different cap?',
                              label: 'Change the monthly cap',
                              onTap: goCockpitBudgets,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Compact figures keep this readable even at 1000%+ overshoot.
                  Text(
                    '${fmtMoneyCompact(spent)} spent of ${fmtMoneyCompact(cap)}',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    over
                        ? '${fmtMoneyCompact(-remaining)} over'
                        : '${fmtMoneyCompact(remaining)} left',
                    style: TextStyle(color: color, fontWeight: FontWeight.w700),
                  ),
                  // Over the cap, the line above says it all; bills due
                  // that eat the rest read as nothing left today.
                  if (safe != null && !over) ...[
                    const SizedBox(height: 2),
                    Text(
                      safe!.overCap
                          // Confirmed spend is under the cap, but not with
                          // the alerts still waiting for review.
                          ? 'Over budget with rows to review'
                          : safe!.leftToday >= 1
                          ? '${fmtMoneyCompact(safe!.leftToday)} safe to '
                                'spend today'
                          : 'Nothing left to spend today',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final double value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  /// What the figure counts, behind the card's "i".
  final String tip;
  final InfoLink? link;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.tip,
    this.onTap,
    this.link,
  });

  @override
  Widget build(BuildContext context) {
    // The "i" sits in the card's top-right corner, over the padding, rather
    // than in the label row: its 32dp target would make the row taller than
    // the strip's 88dp height allows.
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            _body(context),
            Positioned(
              top: 6,
              right: 0,
              child: InfoTip(title: label, message: tip, link: link),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 132),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              // Keeps the label clear of the corner "i".
              const SizedBox(width: 20),
            ],
          ),
          const SizedBox(height: 8),
          // Plain text — no increment animation. Animating on month change
          // made the figures visibly "roll", which read as glitchy.
          Text(
            fmtMoney(value),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// One compact progress row per custom budget: name, spent/limit, and a bar
/// using the same green/orange/error thresholds as the monthly budget card.
class _SpendBudgetRow extends StatelessWidget {
  final String name;
  final double spent;
  final double limit;

  /// Opens Transactions filtered to this budget (wired at the call site so
  /// the budget id needn't be threaded through).
  final VoidCallback? onTap;

  const _SpendBudgetRow({
    required this.name,
    required this.spent,
    required this.limit,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pct = limit == 0 ? 0.0 : spent / limit;
    final over = spent > limit;
    final color = budgetColor(context, pct);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                // Width-capped + scale-down: prevents overflow at large font
                // scale without the trailing gap a loose Flexible leaves
                // (which drifted the figure off the right edge).
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${fmtMoneyCompact(spent)} / ${fmtMoneyCompact(limit)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            AnimatedProgress(
              value: pct,
              minHeight: 6,
              color: color,
              // Visible track: 12% vanished on light surfaces, so a bar at 5%
              // looked like an empty region.
              backgroundColor: color.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 2),
            Text(
              over
                  ? '${fmtMoneyCompact(spent - limit)} over'
                  : '${fmtMoneyCompact(limit - spent)} left',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final double amount;
  final double fraction;

  /// Opens Transactions filtered to this category/group (wired at the call
  /// site — the two sections using this row filter differently).
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Cap of the single-category budget on this row, if any — shown as an
  /// "of ₹X" suffix rather than a second bar in an already dense list.
  final double? budgetLimit;

  const _CategoryRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.amount,
    required this.fraction,
    this.onTap,
    this.onLongPress,
    this.budgetLimit,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Custom category names can be arbitrarily long.
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Share of the section total (month expense for the
                      // category list, group total for By group) — the bar
                      // shows it visually, this makes it readable.
                      Text(
                        '${(fraction * 100).round()}%',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Width-capped + scale-down, not Flexible: a loose
                      // flex child leaves a trailing gap and the amount
                      // drifts off the right edge (transaction-tile pattern).
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            budgetLimit == null
                                ? fmtMoney(amount)
                                : '${fmtMoney(amount)} of '
                                      '${fmtMoneyCompact(budgetLimit!)}',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color:
                                  budgetLimit != null && amount > budgetLimit!
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  AnimatedProgress(
                    value: fraction,
                    minHeight: 6,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.25),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A dashboard section's titleMedium heading with its "i" explaining it.
/// The heading keeps a plain [Text] so finders by text still land on it.
class _SectionHeading extends StatelessWidget {
  final String title;
  final String tip;
  final InfoLink? link;

  const _SectionHeading(this.title, {required this.tip, this.link});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: InfoLabel(
      label: Text(title, style: Theme.of(context).textTheme.titleMedium),
      tip: InfoTip(title: title, message: tip, link: link),
    ),
  );
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
