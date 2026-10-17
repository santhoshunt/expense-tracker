import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/category_group.dart';
import '../models/dashboard_layout.dart';
import '../models/reminder.dart';
import '../models/spend_budget.dart';
import '../models/subscription_cycle.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/backup_service.dart';
import '../services/big_bills.dart';
import '../services/card_bill.dart';
import '../services/comparison_series.dart';
import '../services/merchant_stats.dart';
import '../services/month_forecast.dart';
import '../services/monthly_recap.dart';
import '../services/recurring_detector.dart';
import '../services/reminder_schedule.dart';
import '../services/spend_comparison.dart';
import '../services/spend_history.dart';
import '../services/safe_to_spend.dart';
import '../services/subscriptions.dart';
import '../services/upcoming_items.dart';
import '../services/weekly_digest.dart';
import '../services/year_comparison.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/dates.dart';
import '../utils/fiscal_year.dart';
import '../utils/format.dart';
import '../utils/money_colors.dart';
import '../widgets/animated_fold.dart';
import '../widgets/balance_breakdown.dart';
import '../widgets/big_bills_sheet.dart';
import '../widgets/budget_detail_sheet.dart';
import '../widgets/budget_dialog.dart';
import '../widgets/dashboard_fold.dart';
import '../widgets/delta_note.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/reminder_editor_dialog.dart';
import '../widgets/undo_snackbar.dart';
import '../widgets/notice_stack.dart';
import '../widgets/section_label.dart';
import '../widgets/spending_heatmap.dart';
import '../widgets/glossy.dart';
import '../widgets/info_tip.dart';
import '../widgets/motion.dart';
import '../widgets/category_donut_chart.dart';
import '../widgets/comparison_chart_sheet.dart';
import '../widgets/monthly_bar_chart.dart';
import '../widgets/monthly_recap_card.dart';
import '../widgets/recap_sheet.dart';
import '../widgets/rename_merchant_dialog.dart';
import '../widgets/show_all_list.dart';
import '../widgets/spend_comparison_cards.dart';
import '../widgets/spend_history_sheet.dart';
import '../widgets/tag_editor_dialog.dart';
import '../widgets/weekly_digest_sheet.dart';
import 'accounts_screen.dart' show showCardCycleDialog;
import 'add_transaction_sheet.dart';
import 'app_nav.dart';
import 'transactions_screen.dart' show TxFilterRequest;
import '../widgets/status_dot.dart';

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

  /// Opens Transactions on exactly [request]: the Year view's taps, which
  /// cover a whole year rather than a month.
  final void Function(TxFilterRequest request)? onOpenTransactions;

  const DashboardScreen({
    super.key,
    this.onViewTransactions,
    this.onViewCategory,
    this.onViewGroup,
    this.onViewBudget,
    this.onViewMerchant,
    this.onViewTag,
    this.onOpenTransactions,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

/// The heatmap's heading tip.
const _heatmapTip =
    "Each day is shaded by its spending compared with this month's biggest "
    'day, and shows what it spent. Days with no spending stay plain. A dot '
    'marks a day a bill is still due this month; tap a day for its payments '
    'and bills, or a day ahead to set a reminder on it.';

/// The Overview's "Next 7 days" window, in days from today.
const int _kUpcomingDays = 7;

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
/// sections, and how many are hidden now. Quiet, in the muted text colour:
/// the app bar's ⋯ menu holds the same entry.
class _CustomiseRow extends StatelessWidget {
  final DashboardPage page;
  final int hidden;
  const _CustomiseRow({required this.page, required this.hidden});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Center(
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
          textStyle: Theme.of(context).textTheme.labelLarge,
        ),
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
    final shown = [
      for (final id in layout.order)
        if (!layout.hidden.contains(id) && (sections[id]?.visible ?? false)) id,
    ];
    // An open section is a card of its own; the folded ones between open
    // ones stay rows of one card, rounded at that run's ends.
    bool isOpen(DashboardSection id) =>
        _openedForVisit.contains(id) || settings.sectionOpen(id);
    final opens = [for (final id in shown) isOpen(id)];
    for (final (i, id) in shown.indexed) {
      final s = sections[id]!;
      // A slot a home-screen widget can scroll to ([_showSection]).
      final slot = _sectionKeys[id];
      if (!fold) {
        if (slot == null) {
          out.addAll(s.body());
        } else {
          out.add(
            KeyedSubtree(
              key: slot,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: s.body(),
              ),
            ),
          );
        }
        continue;
      }
      final folded = DashboardFold(
        key: ValueKey('fold-${id.name}'),
        title: s.title ?? id.label,
        summary: s.summary,
        tip: s.tip,
        open: opens[i],
        first: opens[i] || i == 0 || opens[i - 1],
        last: opens[i] || i == shown.length - 1 || opens[i + 1],
        // The page's own gap at its top; AppSpace.gap between cards.
        gapAbove: i == 0 ? AppSpace.gap + 6 : AppSpace.gap,
        onChanged: (v) {
          // A tap is the user's choice again, and sticks.
          if (_openedForVisit.remove(id)) setState(() {});
          settings.setSectionOpen(id, v);
        },
        children: s.body(),
      );
      out.add(slot == null ? folded : KeyedSubtree(key: slot, child: folded));
    }
    out.add(_CustomiseRow(page: page, hidden: layout.hidden.length));
    // Room for the last card to scroll clear of the floating Add button.
    out.add(const SizedBox(height: 120));
    return out;
  }

  late DateTime _month;

  /// Sections a recap notification opened for this visit, without changing
  /// how they start next time. The visit ends on leaving Trends or on any
  /// stored fold change ([_openedAtLayout] is the layout it began under).
  final Set<DashboardSection> _openedForVisit = {};
  String? _openedAtLayout;

  /// Year view: the stat cards, category breakdown and bar chart cover the
  /// year holding `_month`, which starts in Settings' "Year starts in"
  /// month; the month-only sections (budgets, merchants, heatmap,
  /// transfers) step aside.
  bool _yearMode = false;

  /// The year's first month (1 or 4), for the picker, the PDF export and the
  /// selector. Build selects the same value, which rebuilds them on a change.
  int get _yearStartMonth => context.read<SettingsProvider>().yearStart.month;

  /// A Year-view tap: Transactions on the rows the year's figure counted,
  /// by the date each counts in, under the year's name. Null without a
  /// handler, which leaves the tap off.
  VoidCallback? _openYear(
    int startYear,
    int startMonth, {
    TxType? type,
    String? categoryId,
    String? tag,
  }) {
    final open = widget.onOpenTransactions;
    if (open == null) return null;
    final b = yearBounds(startYear, startMonth);
    return () => open(
      TxFilterRequest(
        type: type,
        categoryId: categoryId,
        tag: tag,
        range: DateTimeRange(start: b.first, end: b.last),
        rangeCounted: true,
        rangeLabel: yearLabel(startYear, startMonth),
      ),
    );
  }

  /// A category's or merchant's history over the window the selector shows:
  /// the 12 months to the shown month, or the shown year. [onViewTransactions]
  /// is what the row's tap did before, offered as the sheet's button.
  void _showHistory(
    HistorySubject subject, {
    IconData? icon,
    Color? color,
    VoidCallback? onViewTransactions,
  }) {
    final sm = _yearStartMonth;
    final year = yearStartOf(_month, sm);
    showSpendHistorySheet(
      context,
      subject: subject,
      months: _yearMode
          ? yearMonths(year, sm)
          : [
              for (var i = 11; i >= 0; i--)
                DateTime(_month.year, _month.month - i),
            ],
      windowLabel: _yearMode
          ? yearLabel(year, sm)
          : '12 months to ${fmtMonth(_month)}',
      yearView: _yearMode,
      icon: icon,
      color: color,
      onViewTransactions: onViewTransactions,
    );
  }

  /// [_showHistory] for a category, by id; its button opens the category's
  /// transactions for the shown month or year.
  void _showCategoryHistory(String id) {
    // Spending categories only: a dangling id reads as Other, not as
    // Other income.
    final cat = categoryById(id, fallbackType: TxType.expense);
    _showHistory(
      HistorySubject.category(id, cat.label),
      icon: cat.icon,
      color: cat.color,
      onViewTransactions: _categoryTransactions(id),
    );
  }

  /// The transactions tap for a category in the shown month or year, as the
  /// rows did before history: null without a handler.
  VoidCallback? _categoryTransactions(String id) {
    if (_yearMode) {
      final sm = _yearStartMonth;
      return _openYear(
        yearStartOf(_month, sm),
        sm,
        type: TxType.expense,
        categoryId: id,
      );
    }
    final view = widget.onViewCategory;
    return view == null ? null : () => view(id, _month);
  }

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
    AppNav.instance.dashboardHeader.detach(this);
    AppNav.instance.pageMenu.detach(this);
    _jumpReset?.cancel();
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
    // Opened for this visit only: how the section starts is the user's
    // choice (Cockpit, or a tap on its heading), not the notification's.
    final settings = context.read<SettingsProvider>();
    final opening =
        !recapWeek &&
        !settings.sectionOpen(DashboardSection.pace) &&
        !_openedForVisit.contains(DashboardSection.pace);
    if (opening) {
      setState(() {
        _openedForVisit.add(DashboardSection.pace);
        _openedAtLayout = settings.dashboardLayoutKey;
      });
    }
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

  /// The page a [_showSection] jump is sliding to: the pages it passes
  /// on the way must not end the visit it opened a section for.
  DashboardPage? _jumpingTo;
  Timer? _jumpReset;

  /// Sections a home-screen widget can open ([_showSection]): each wraps
  /// its slot in the page so it can be scrolled into view.
  final Map<DashboardSection, GlobalKey> _sectionKeys = {
    for (final s in const [
      DashboardSection.monthlyBudget,
      DashboardSection.budgets,
      DashboardSection.upcoming,
      DashboardSection.pace,
      DashboardSection.donut,
    ])
      s: GlobalKey(),
  };

  /// Where a home-screen widget lands: [section]'s page on this month,
  /// its fold opened for this visit (Upcoming's on Overview, any on Trends
  /// and Breakdown), scrolled into view. A section hidden in Cockpit leaves
  /// the page as it is.
  void _showSection(DashboardSection section) {
    if (!mounted) return;
    final now = DateTime.now();
    setState(() {
      _month = DateTime(now.year, now.month);
      _yearMode = false;
    });
    _setView(switch (section.page) {
      DashboardPage.overview => DashboardView.overview,
      DashboardPage.trends => DashboardView.trends,
      DashboardPage.breakdown => DashboardView.breakdown,
    });
    final settings = context.read<SettingsProvider>();
    // Upcoming folds by its own stored flag; the other Overview sections
    // never fold.
    final opening =
        !_openedForVisit.contains(section) &&
        (section == DashboardSection.upcoming
            ? settings.isSectionCollapsed('upcoming')
            : section.page != DashboardPage.overview &&
                  !settings.sectionOpen(section));
    if (opening) {
      setState(() {
        _openedForVisit.add(section);
        _openedAtLayout = settings.dashboardLayoutKey;
        // Already on its page: no slide, so nothing to wait for.
        final onPage = switch (_view) {
          DashboardView.overview => DashboardPage.overview,
          DashboardView.trends => DashboardPage.trends,
          DashboardView.breakdown => DashboardPage.breakdown,
        };
        _jumpingTo = onPage == section.page ? null : section.page;
      });
      // A drag that stops the slide short must not leave it set; a second
      // jump starts its own wait.
      _jumpReset?.cancel();
      _jumpReset = Timer(
        const Duration(milliseconds: 700),
        () => _jumpingTo = null,
      );
    }
    final key = _sectionKeys[section];
    if (key == null) return;
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
      Future.delayed(
        opening
            ? AnimatedFold.duration + const Duration(milliseconds: 50)
            : Duration.zero,
        () => reveal(retry: true),
      );
    });
  }

  /// The Upcoming header's tap. While a widget tap holds it open for this
  /// visit, the tap only ends the visit: the stored flag is still folded,
  /// so the card folds and the saved choice stays as it was.
  void _toggleUpcoming() {
    if (_openedForVisit.remove(DashboardSection.upcoming)) {
      setState(() {});
      return;
    }
    context.read<SettingsProvider>().toggleSection('upcoming');
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
    final monthEnd = DateTime(now.year, now.month + 1, 0);
    final bills = billsDue(
      finance,
      patterns: _patterns(finance, now),
      hidden: context.read<SettingsProvider>().hiddenUpcoming,
      from: now,
      to: monthEnd,
      now: now,
    );
    // billsDue leaves out reminders with no amount (nothing to set aside),
    // but their day still wants its dot: such as a one-time reminder saved
    // from a heatmap day with the amount left blank. Amount 0 marks them;
    // the day sheet lists them without one.
    final amountless = [
      for (final r in finance.reminders)
        if (r.expectedAmount == null && !isTransferCategory(r.categoryId))
          for (final due in reminderDueDatesBetween(r, now, monthEnd))
            if (!reminderOccurrenceDone(r, due))
              DueBill(due: due, label: r.name, amount: 0, reminderId: r.id),
    ];
    if (amountless.isEmpty) return bills;
    return [...bills, ...amountless]..sort((a, b) => a.due.compareTo(b.due));
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
        finance.countedTransactions,
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
        finance.countedTransactions,
        month: _month,
        // Every merchant: the card shows five and folds the rest.
        limit: 1 << 20,
        alias: finance.merchantAlias,
        spendOf: finance.netSpendOf,
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

  /// This year against the same months of last year, for the Year view:
  /// memoized on (revision, year, start month, day) like the month
  /// comparison, and for the same reason the day is in the key.
  Object? _yearCompareRev;
  (int, int, DateTime)? _yearCompareKey;
  YearComparison? _yearCompare;

  YearComparison? _yearComparison(
    FinanceProvider finance,
    int startYear,
    int startMonth,
  ) {
    final now = DateTime.now();
    final key = (startYear, startMonth, DateTime(now.year, now.month, now.day));
    if (!identical(_yearCompareRev, finance.revision) ||
        _yearCompareKey != key) {
      _yearCompareRev = finance.revision;
      _yearCompareKey = key;
      _yearCompare = buildYearComparison(
        finance,
        startYear: startYear,
        startMonth: startMonth,
        now: now,
      );
    }
    return _yearCompare;
  }

  /// Last month's recap for the first [kRecapDays] days (the Overview);
  /// null after. Memoized on (revision, day, cap): the recap walks every
  /// row's SMS body for merchants. A null recap caches too
  /// ([_monthCardSet]).
  Object? _monthCardRev;
  DateTime? _monthCardDay;
  double? _monthCardCap;
  MonthlyRecap? _monthCard;
  bool _monthCardSet = false;

  MonthlyRecap? _monthCardFor(
    FinanceProvider finance,
    SettingsProvider settings,
  ) {
    final now = recapClock();
    final day = DateTime(now.year, now.month, now.day);
    if (!_monthCardSet ||
        !identical(_monthCardRev, finance.revision) ||
        _monthCardDay != day ||
        _monthCardCap != settings.monthlyBudget) {
      _monthCardSet = true;
      _monthCardRev = finance.revision;
      _monthCardDay = day;
      _monthCardCap = settings.monthlyBudget;
      _monthCard = showsRecap(now)
          ? buildMonthlyRecap(finance, settings, now: now)
          : null;
    }
    return _monthCard;
  }

  /// The month cards' spending links: that month's expenses.
  void Function(DateTime)? get _viewSpending =>
      widget.onViewTransactions == null
      ? null
      : (m) => widget.onViewTransactions!(TxType.expense, m);

  /// A Top merchants row's tap, and See history in its ⋮ menu: the
  /// merchant's history, whose button searches its transactions.
  void _showMerchantHistory(MerchantSpend m) {
    final view = widget.onViewMerchant;
    _showHistory(
      HistorySubject.merchant(m.key, m.label),
      icon: Icons.storefront_outlined,
      onViewTransactions: view == null
          ? null
          // The search matches notes/bodies, so the query is the normalized
          // identity, not the cased label.
          : () => view(m.key.substring(m.key.indexOf('|') + 1), _month),
    );
  }

  /// Rename in a Top merchants row's ⋮ menu: give the payee a readable name.
  Future<void> _renameMerchant(BuildContext context, MerchantSpend m) =>
      showRenameMerchantDialog(
        context,
        identity: m.key.substring(m.key.indexOf('|') + 1),
        currentLabel: m.label,
      );

  /// The budget that caps exactly this one category (include mode, single
  /// id), if the user made one: the category row's ⋮ menu edits it instead
  /// of creating a duplicate.
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

  /// The icon in a budget's ring: the one picked for it, else its
  /// category's for a one-category "Only these" budget, a generic one for
  /// several or "All except" ([budgetIcon]).
  static IconData _budgetIcon(SpendBudget b) => budgetIcon(b);

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    AppNav.instance.attachDashboard(
      this,
      showRecap: _showMonthCard,
      showSection: _showSection,
      showCategoryHistory: _showAlertedCategory,
      showWeeklyDigest: _showWeeklyDigest,
      showBigBills: _showBigBills,
    );
  }

  /// The Big bills ahead sheet, as the Overview card opens it: from the Big
  /// bills widgets. After the frame, as [_showWeeklyDigest] is.
  void _showBigBills() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showBigBillsSheet(
        context,
        patterns: _patterns(context.read<FinanceProvider>(), DateTime.now()),
      );
    });
    // A post-frame callback alone waits for a frame nothing has asked for.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// The weekly digest sheet on [week]: from the This week row, the ⋮
  /// entry and the Monday note. After the frame, so a tap that switched
  /// the tab opens it over the settled page.
  void _showWeeklyDigest(DateTime week) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showWeeklyDigestSheet(
        context,
        week: week,
        hits: _recurring(context.read<FinanceProvider>()),
        onOpenTransactions: widget.onOpenTransactions,
      );
    });
    // A post-frame callback alone waits for a frame nothing has asked for.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Where an unusual spending alert lands: [id]'s history sheet to the
  /// alert's [month], in Month view, so its tiles are the alert's figures
  /// even when the tap comes a month later. The selector moves there too;
  /// the Overview, Trends or Breakdown page showing stays.
  void _showAlertedCategory(String id, DateTime month) {
    if (!mounted) return;
    setState(() {
      _month = DateTime(month.year, month.month);
      _yearMode = false;
    });
    // After the frame: the sheet then opens over the rebuilt page rather
    // than mid-rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showCategoryHistory(id);
    });
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
    final sm = _yearStartMonth;
    final List<DateTime> options;
    if (_yearMode) {
      final years = <int>{
        yearStartOf(now, sm),
        for (final m in months) yearStartOf(m, sm),
      }.toList()..sort((a, b) => b.compareTo(a));
      // The shown month's place in each year, so switching back to Month
      // view lands on the same month of the picked year.
      final offset = (_month.month - sm) % 12;
      options = [for (final y in years) DateTime(y, sm + offset)];
    } else {
      options = [if (!months.contains(current)) current, ...months];
    }
    // An option can sit in the next calendar year (February of FY
    // 2026-27 is 2027), so years compare by their first calendar year.
    bool isCurrent(DateTime m) =>
        _yearMode ? yearStartOf(m, sm) == yearStartOf(_month, sm) : m == _month;
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
              title: Text(
                _yearMode ? yearLabel(yearStartOf(m, sm), sm) : fmtMonth(m),
              ),
              selected: isCurrent(m),
              selectedColor: accentTextColor(ctx),
              onTap: () => Navigator.pop(ctx, m),
            ),
        ],
      ),
    );
    if (picked != null && mounted) setState(() => _month = picked);
  }

  /// The report for what the selector shows: the month, or the year.
  Future<void> _exportPdf(BuildContext context, FinanceProvider finance) async {
    final messenger = ScaffoldMessenger.of(context);
    final sm = _yearStartMonth;
    final year = yearStartOf(_month, sm);
    final yearView = _yearMode;
    try {
      final path = await BackupService.exportPdf(
        finance,
        year: yearView ? year : null,
        month: yearView ? null : _month,
        startMonth: sm,
      );
      if (path == null) return;
      showAppToastOn(
        messenger,
        'Saved report ${yearView ? yearLabel(year, sm) : fmtMonth(_month)}',
        tone: AppToastTone.success,
        icon: Icons.picture_as_pdf_outlined,
      );
    } catch (e) {
      showAppToastOn(messenger, 'Export failed: $e', tone: AppToastTone.error);
    }
  }

  /// What [_plan] last worked out, and for which inputs.
  Object? _planKey;
  SafeToSpend? _planSafe;
  MonthForecast? _planForecast;

  /// Safe to spend (with a cap, on the running month in Month view) and the
  /// Month-end forecast (on the running month), worked out once per ledger,
  /// cap, hidden bills, month and day: the budget slot, the forecast slot
  /// and the Safe to spend row ask for them in the same frame. Callers
  /// select the cap and the hidden bills themselves.
  ({SafeToSpend? safe, MonthForecast? forecast}) _plan(
    FinanceProvider finance,
  ) {
    final settings = context.read<SettingsProvider>();
    final budget = settings.monthlyBudget;
    final now = DateTime.now();
    final thisMonth = !_yearMode && _month == DateTime(now.year, now.month);
    final budgetShows = budget > 0 && !_yearMode;
    final key = (
      finance.revision,
      budget,
      hiddenListKey(settings.hiddenUpcoming),
      _month,
      _yearMode,
      DateTime(now.year, now.month, now.day),
    );
    if (_planKey != key) {
      _planKey = key;
      _planSafe = !budgetShows || !thisMonth
          ? null
          : computeSafeToSpend(
              finance,
              cap: budget,
              patterns: _patterns(finance, now),
              hidden: settings.hiddenUpcoming,
              now: now,
            );
      _planForecast = !thisMonth
          ? null
          : computeMonthForecast(
              finance,
              patterns: _patterns(finance, now),
              hidden: settings.hiddenUpcoming,
              now: now,
              cap: budget,
            );
    }
    return (safe: _planSafe, forecast: _planForecast);
  }

  /// The Overview's Monthly budget and Month-end forecast sections. Both
  /// showing (a cap, the running month, a forecast worth a card), neither
  /// hidden and next to each other in Cockpit's order, they are one card in
  /// the budget's slot, and the forecast's is empty; otherwise each slot
  /// shows its own card. Each card sits under its section label.
  ///
  /// The budget uses the shown month's spend, so a past month shows its
  /// usage too. Safe to spend and the forecast are about today, so only
  /// under this month's figures; the forecast shows without a cap too.
  Widget _monthPlanSlot(
    BuildContext context,
    FinanceProvider finance,
    DashboardSection slot,
  ) {
    final settings = context.read<SettingsProvider>();
    final budget = context.select<SettingsProvider, double>(
      (s) => s.monthlyBudget,
    );
    // Hiding an Upcoming row changes the bills both set aside.
    context.select<SettingsProvider, String>(
      (s) => hiddenListKey(s.hiddenUpcoming),
    );
    final budgetShows = budget > 0 && !_yearMode;
    final plan = _plan(finance);
    final safe = plan.safe;
    final forecast = plan.forecast;
    // Nothing spent, due or usual: no forecast worth a card.
    final forecastShows = forecast != null && forecast.total > 0;
    final layout = settings.dashboardLayout(DashboardPage.overview);
    final budgetAt = layout.order.indexOf(DashboardSection.monthlyBudget);
    final forecastAt = layout.order.indexOf(DashboardSection.forecast);
    // Next to each other in Cockpit's order: moved apart there, they stay
    // two cards where the user put them.
    final merged =
        budgetShows &&
        forecastShows &&
        (budgetAt - forecastAt).abs() == 1 &&
        !layout.hidden.contains(DashboardSection.monthlyBudget) &&
        !layout.hidden.contains(DashboardSection.forecast);
    // The budget's parts: confirmed spend, rows waiting for review and,
    // on the running month, the bills due.
    final confirmed = finance.budgetSpentInMonth(_month);
    final waiting = safe?.pendingSpent ?? pendingSpendIn(finance, _month);
    final bills = safe?.billsDue ?? 0.0;
    Widget budgetCard({MonthForecast? shared}) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LabelRow(
          text: DashboardSection.monthlyBudget.label,
          tip: _BudgetCard.tip(
            confirmed: confirmed,
            waiting: waiting,
            bills: bills,
            cap: budget,
            safe: safe,
          ),
          trailing: 'cap ${fmtMoneyWhole(budget)}',
        ),
        _BudgetCard(
          confirmed: confirmed,
          waiting: waiting,
          waitingCount: pendingSpendCountIn(finance, _month),
          cap: budget,
          safe: safe,
          billsForecast: forecast,
          forecast: shared,
        ),
      ],
    );
    final Widget? card;
    if (merged) {
      // Always the budget's slot: next to each other the two slots sit in
      // the same place, and the Budget widget's jump scrolls to this one.
      card = slot == DashboardSection.monthlyBudget
          ? budgetCard(shared: forecast)
          : null;
    } else if (slot == DashboardSection.monthlyBudget) {
      card = budgetShows ? budgetCard() : null;
    } else {
      card = forecastShows
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionLabel(
                  DashboardSection.forecast.label,
                  tip: _ForecastBody.tip(forecast),
                ),
                _ForecastCard(
                  forecast: forecast,
                  // The under or over the cap line is the budget card's
                  // verdict; on its own it shows only with that card hidden.
                  showCapLine: layout.hidden.contains(
                    DashboardSection.monthlyBudget,
                  ),
                ),
              ],
            )
          : null;
    }
    return AnimatedPresence(
      visible: card != null,
      child: card ?? const SizedBox.shrink(),
    );
  }

  /// The Year view tip, opened from the "i" on the Year view row of Home's
  /// ⋮ menu.
  static const _yearTip = InfoTip(
    title: 'Year view',
    message:
        'Year view adds up the 12 months of the year, from the month set in '
        'Settings → Appearance → Year starts in. April gives the financial '
        'year, April to March. Trends compares the year with last year. '
        'This week, the monthly budget, the Month-end forecast, the monthly '
        'recap, budgets, the month comparisons, the heatmap, merchants, '
        'groups and transfers are hidden.',
  );

  /// Hands the month selector to Home's app bar ([DashboardHeader]): the
  /// arrows, the tappable month label and the Month or Year switch; and the
  /// Dashboard's ⋮ entries
  /// ([PageMenu]): the Month/Year switch with the Year view tip, the PDF
  /// export and Customise. After the frame: the bar rebuilds on the change, and a listener must
  /// not rebuild mid-build. `_month` and `_yearMode` stay in this State.
  void _publishHeader(FinanceProvider finance, DateTime latestMonth) {
    final sm = _yearStartMonth;
    final year = yearStartOf(_month, sm);
    final canNext = _yearMode
        ? year < yearStartOf(latestMonth, sm)
        : _month.isBefore(latestMonth);
    final page = switch (_view) {
      DashboardView.overview => DashboardPage.overview,
      DashboardView.trends => DashboardPage.trends,
      DashboardView.breakdown => DashboardPage.breakdown,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppNav.instance.dashboardHeader.update(
        owner: this,
        label: _yearMode ? yearLabel(year, sm) : fmtMonth(_month),
        yearMode: _yearMode,
        onPrev: () => _shiftMonth(-1),
        onNext: canNext ? () => _shiftMonth(1) : null,
        // Browsing back a year used to take 12 arrow taps.
        onPick: () => _pickMonth(context, finance),
        // The Month or Year switch beside the arrows; the ⋮ entry stays.
        onToggleView: () => setState(() => _yearMode = !_yearMode),
      );
      // The "This page" part of Home's ⋮ menu.
      AppNav.instance.pageMenu.publish(this, kHomeTabDashboard, [
        PageMenuAction(
          icon: _yearMode ? Icons.calendar_view_month : Icons.date_range,
          label: _yearMode ? 'Month view' : 'Year view',
          // Month is the default; nothing is persisted.
          onTap: () => setState(() => _yearMode = !_yearMode),
          // Its own tap: the tip opens over the menu, pointing at the "i",
          // and the view stays as it is. A menu row is one node for a
          // screen reader, so the tip is also the row's custom action.
          trailing: Builder(
            builder: (anchor) => Semantics(
              customSemanticsActions: {
                const CustomSemanticsAction(label: 'About Year view'): () =>
                    openInfoTip(anchor, _yearTip),
              },
              child: IconButton(
                tooltip: 'About Year view',
                // Compact (40dp), so the row keeps the menu's 44dp height.
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.info_outline, size: 20),
                onPressed: () => openInfoTip(anchor, _yearTip),
              ),
            ),
          ),
        ),
        // In every view, unlike the This week row: the menu is the way in
        // when the row is hidden or another month is shown.
        PageMenuAction(
          icon: Icons.calendar_view_week,
          label: 'Weekly digest',
          onTap: () => _showWeeklyDigest(weekStartOf(weekClock())),
        ),
        // Any day of the month: the Overview card shows only on the 1st to
        // the 7th. Named for the newest past month with data; left out
        // until there is one.
        // recapClock, as the sheet reads it, so both name the same month.
        if (recapMonths(finance.monthsWithData, recapClock()) case [
          final newest,
          ...,
        ])
          PageMenuAction(
            icon: Icons.history,
            label: '${DateFormat('MMMM').format(newest)} recap',
            onTap: () => showRecapSheet(
              context,
              month: newest,
              onViewCategory: widget.onViewCategory,
              onViewMerchant: widget.onViewMerchant,
              onViewBudget: widget.onViewBudget,
              onViewSpending: _viewSpending,
            ),
          ),
        PageMenuAction(
          icon: Icons.picture_as_pdf_outlined,
          label: _yearMode ? 'Year report (PDF)' : 'Month report (PDF)',
          onTap: () => _exportPdf(context, finance),
        ),
        PageMenuAction(
          icon: Icons.dashboard_customize_outlined,
          label: 'Customise page',
          onTap: () => goCockpitDashboard(context, page),
        ),
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    // A section moved, hidden or folded, and a bill hidden (subscriptions,
    // the heatmap's dots), rebuild the pages.
    final layoutKey = context.select<SettingsProvider, String>(
      (s) => s.dashboardLayoutKey,
    );
    // A stored fold change (a heading tap, Cockpit, Reset) is the user's
    // word again: the notification's one-visit opening ends.
    if (_openedForVisit.isNotEmpty && layoutKey != _openedAtLayout) {
      _openedForVisit.clear();
    }
    // The Month-end forecast on Trends takes the cap and the hidden
    // Upcoming rows. The page lists build lazily
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
    // The year holding `_month`, named by its first calendar year: a
    // January start is the calendar year, April the financial year.
    final sm = context.select<SettingsProvider, int>((s) => s.yearStart.month);
    final year = yearStartOf(_month, sm);
    // In Year view the "month" figures below are the year's: same widgets,
    // wider window.
    final byCategory = _yearMode
        ? finance.expenseByCategoryInYear(year, startMonth: sm)
        : finance.expenseByCategory(_month);
    final monthExpense = _yearMode
        ? finance.expenseInYear(year, startMonth: sm)
        : finance.expenseInMonth(_month);
    final groupSpend = finance.groupSpendInMonth(_month);
    final groupTotal = groupSpend.fold(0.0, (sum, e) => sum + e.$2);
    final transfersBy = finance.transfersByCategoryInMonth(_month);
    final topMerchantsList = _topMerchants(finance);
    final byTag = _yearMode
        ? finance.expenseByTagInYear(year, startMonth: sm)
        : finance.expenseByTagInMonth(_month);
    // Tags count money-out transfers, so their shares are of all money out.
    final tagMoneyOut =
        monthExpense +
        (_yearMode
            ? finance.transferOutInYear(year, startMonth: sm)
            : finance.transferOutInMonth(_month));
    // Keys the capped lists, so a new month or view starts folded.
    final listKey = _yearMode ? 'y$year-$sm' : 'm${monthKey(_month)}';
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
        // A newer release, offered by the launch check, and a bank whose
        // alerts stopped importing: one at a time; empty when neither.
        const NoticeStack(),
        // First-run: the landing tab used to greet a new user with ₹0.00
        // everywhere and no hint of what to do next.
        if (!finance.hasTransactions) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.card),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 20, color: scheme.primary),
                      const SizedBox(width: 8),
                      // Flexible: at 320dp and large text the row ran
                      // 2.5px over.
                      Flexible(
                        child: Text(
                          'Get started',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
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
        // Safe to spend today, once, at the top: with a cap, on the running
        // month in Month view, while the Monthly budget section shows. A tap
        // scrolls to the budget card, which holds the working.
        Builder(
          key: const ValueKey('presence-safe-today'),
          builder: (context) {
            context.select<SettingsProvider, double>((s) => s.monthlyBudget);
            context.select<SettingsProvider, String>(
              (s) => hiddenListKey(s.hiddenUpcoming),
            );
            final settings = context.read<SettingsProvider>();
            final safe = _plan(finance).safe;
            final showing =
                safe != null &&
                !settings
                    .dashboardLayout(DashboardPage.overview)
                    .hidden
                    .contains(DashboardSection.monthlyBudget);
            return AnimatedPresence(
              visible: showing,
              child: showing
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.gap),
                      child: _SafeTodayRow(
                        safe: safe,
                        onTap: () =>
                            _showSection(DashboardSection.monthlyBudget),
                      ),
                    )
                  : const SizedBox.shrink(),
            );
          },
        ),
        // The balance, with the picked month's (or year's) totals as
        // columns inside it: three cards in a strip scrolled sideways and
        // cut Saved off at phone width.
        KeyedSubtree(
          key: const ValueKey('balance'),
          child: _BalanceCard(
            finance: finance,
            stats: [
              // Year-view taps open the whole year's rows (_openYear).
              if (!hideIncome)
                _StatColumn(
                  label: 'Income',
                  value: _yearMode
                      ? finance.incomeInYear(year, startMonth: sm)
                      : finance.incomeInMonth(_month),
                  icon: Icons.arrow_downward,
                  color: colors.green,
                  valueColor: moneyColor(context, type: TxType.income),
                  tip:
                      'Money in $period, not counting transfers between '
                      'your own accounts or pending imports.',
                  onTap: _yearMode
                      ? _openYear(year, sm, type: TxType.income)
                      : widget.onViewTransactions == null
                      ? null
                      : () => widget.onViewTransactions!(TxType.income, _month),
                ),
              _StatColumn(
                label: 'Spent',
                value: monthExpense,
                icon: Icons.arrow_upward,
                color: scheme.error,
                valueColor: moneyColor(context, type: TxType.expense),
                tip:
                    'Confirmed spending $period. Transfers and card bill '
                    'payments are left out, and a split bill counts only your '
                    'share.',
                link: const InfoLink(
                  prompt: 'Spending in the wrong category?',
                  label: 'Set up transaction rules',
                  onTap: goCockpitRules,
                ),
                onTap: _yearMode
                    ? _openYear(year, sm, type: TxType.expense)
                    : widget.onViewTransactions == null
                    ? null
                    : () => widget.onViewTransactions!(TxType.expense, _month),
              ),
              // Savings outflow — the DISPLAY figure, which keeps reporting
              // even when the user un-transferred the savings category (the
              // money then also sits inside Spent; the balance math uses the
              // gated figure separately).
              _StatColumn(
                label: 'Saved',
                value: _yearMode
                    ? finance.savingsOutflowInYear(year, startMonth: sm)
                    : finance.savingsOutflowInMonth(_month),
                icon: Icons.savings_outlined,
                color: colors.orange,
                tip: 'Money moved to savings $period.',
                // The savings category on the All tab: "To savings" is a
                // transfer by default, and the Expense tab leaves transfers
                // out, so it listed nothing.
                onTap: _yearMode
                    ? _openYear(
                        year,
                        sm,
                        categoryId: kSavingsTransferCategoryId,
                      )
                    : widget.onOpenTransactions != null
                    ? () => widget.onOpenTransactions!(
                        TxFilterRequest(
                          categoryId: kSavingsTransferCategoryId,
                          month: _month,
                        ),
                      )
                    : widget.onViewCategory == null
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
        DashboardSection.week: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            // This week so far, by the recap's rule: Month view on today's
            // month only, since under March's totals it would read as
            // March's. Hidden on an empty ledger.
            Builder(
              key: const ValueKey('presence-week'),
              builder: (context) {
                final today = weekClock();
                final showing =
                    !_yearMode &&
                    _month == DateTime(today.year, today.month) &&
                    finance.firstTransactionDate != null;
                return AnimatedPresence(
                  visible: showing,
                  child: !showing
                      ? const SizedBox.shrink()
                      : _WeekRow(
                          digest: buildWeekDigest(
                            finance,
                            weekStartOf(today),
                            now: today,
                          ),
                          onTap: () => _showWeeklyDigest(weekStartOf(today)),
                        ),
                );
              },
            ),
          ],
        ),
        DashboardSection.monthlyBudget: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            Builder(
              key: const ValueKey('presence-monthly-budget'),
              builder: (context) => _monthPlanSlot(
                context,
                finance,
                DashboardSection.monthlyBudget,
              ),
            ),
          ],
        ),
        DashboardSection.forecast: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            Builder(
              key: const ValueKey('presence-month-forecast'),
              builder: (context) =>
                  _monthPlanSlot(context, finance, DashboardSection.forecast),
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
                // Done on this month's recap puts it away until the next.
                final dismissed = context.select<SettingsProvider, String?>(
                  (s) => s.recapDismissed,
                );
                final recap = _monthCardFor(
                  finance,
                  context.read<SettingsProvider>(),
                );
                final today = recapClock();
                // Year view drops it with the budgets: its lines are monthly.
                final showing =
                    recap != null &&
                    !_yearMode &&
                    _month == DateTime(today.year, today.month) &&
                    dismissed != monthKey(recap.month);
                return AnimatedPresence(
                  visible: showing,
                  child: !showing
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SectionLabel(
                              '${DateFormat('MMMM').format(recap.month)} recap',
                              tip: kMonthlyRecapTip,
                            ),
                            MonthlyRecapCard(
                              recap: recap,
                              showTitle: false,
                              onViewCategory: widget.onViewCategory,
                              onViewMerchant: widget.onViewMerchant,
                              onViewBudget: widget.onViewBudget,
                              onViewSpending: _viewSpending,
                              onDone: () {
                                final settings = context
                                    .read<SettingsProvider>();
                                final before = settings.recapDismissed;
                                final name = fmtMonth(recap.month);
                                showUndoSnackBar(
                                  context,
                                  'Hid the $name recap',
                                  () => settings.setRecapDismissed(before),
                                  icon: Icons.check,
                                  tone: AppToastTone.success,
                                );
                                settings.setRecapDismissed(
                                  monthKey(recap.month),
                                );
                              },
                            ),
                          ],
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
            _UpcomingCard(
              finance: finance,
              hits: _recurring(finance),
              openedForVisit: _openedForVisit.contains(
                DashboardSection.upcoming,
              ),
              onHeaderTap: _toggleUpcoming,
            ),
          ],
        ),
        DashboardSection.bigBills: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            // Quarterly, half-yearly and yearly bills spread over the year.
            // About the months ahead like Upcoming, so the Year view keeps
            // it too. Hidden while there are none.
            Builder(
              key: const ValueKey('presence-big-bills'),
              builder: (context) {
                context.select<SettingsProvider, String>(
                  (s) => hiddenListKey(s.hiddenUpcoming),
                );
                final now = DateTime.now();
                final patterns = _patterns(finance, now);
                final plan = buildBigBillsPlan(
                  finance,
                  patterns: patterns,
                  hidden: context.read<SettingsProvider>().hiddenUpcoming,
                  now: now,
                );
                return AnimatedPresence(
                  visible: !plan.isEmpty,
                  child: plan.isEmpty
                      ? const SizedBox.shrink()
                      : _BigBillsCard(
                          plan: plan,
                          onTap: () =>
                              showBigBillsSheet(context, patterns: patterns),
                        ),
                );
              },
            ),
          ],
        ),
        DashboardSection.budgets: (
          visible: true,
          title: null,
          summary: null,
          tip: null,
          body: () => [
            // Custom spend limits, one row each in one card, shaped like the
            // monthly budget's. Budgets are monthly, so the Year view skips
            // them.
            // The sections the Year view drops fold away (and back) rather than
            // popping, so the switch reads as one change.
            AnimatedPresence(
              key: const ValueKey('presence-budgets'),
              visible: finance.budgets.isNotEmpty && !_yearMode,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionLabel(
                    'Budgets',
                    tip: InfoTip(
                      title: 'Budgets',
                      message:
                          '"Only these" budgets count the picked categories; '
                          '"All except" budgets count everything else. Tap a '
                          'budget for its '
                          'categories, trend and transactions.',
                      link: InfoLink(
                        prompt: 'Need another limit?',
                        label: 'Add or edit budgets',
                        onTap: goCockpitBudgets,
                      ),
                    ),
                  ),
                  FrostedPanel(
                    radius: BorderRadius.circular(AppRadius.card),
                    child: Padding(
                      // The Upcoming card's inset, so the two cards' rows
                      // line up.
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.card,
                        vertical: 4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final b in finance.budgets)
                            _BudgetRow(
                              icon: _budgetIcon(b),
                              title: Text(
                                b.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              spent: finance.budgetSpentFor(b, _month),
                              limit: b.limit,
                              // Detail sheet (ring + pie + trend); the
                              // transactions deep-link lives on a button
                              // inside it.
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
      final today = recapClock();
      final comparison = _yearMode ? null : _comparison(finance);
      final yearCompare = _yearMode ? _yearComparison(finance, year, sm) : null;
      // The Month-end forecast, for the running month only: the cards' On
      // track for and the chart's dashed line both use it.
      final forecastNow = DateTime.now();
      final settingsNow = context.read<SettingsProvider>();
      final trendsForecast =
          comparison == null ||
              _month != DateTime(forecastNow.year, forecastNow.month)
          ? null
          : computeMonthForecast(
              finance,
              patterns: _patterns(finance, forecastNow),
              hidden: settingsNow.hiddenUpcoming,
              now: forecastNow,
              cap: settingsNow.monthlyBudget,
            );
      // The cards take the forecast's total whenever there is one, so Trends
      // and the Overview agree. Without an everyday estimate it is a floor
      // and reads "At least"; the chart's dashed line waits for an
      // estimate.
      final cardForecast = trendsForecast?.total;
      final forecastFloor = trendsForecast?.basis == EverydayBasis.none;
      final chartForecast = forecastFloor ? null : trendsForecast;
      String? forecastExample() {
        final f = trendsForecast;
        if (f == null) return null;
        final parts = [
          '${fmtMoney(f.spentSoFar)} spent',
          if (f.billsDue > 0) '${fmtMoney(f.billsDue)} bills due',
          if (f.everyday > 0) '${fmtMoney(f.everyday)} everyday',
        ];
        return '${parts.join(' + ')} = ${fmtMoney(f.total)}';
      }

      void openChart({required bool usual}) {
        final c = comparison;
        if (c == null) return;
        showComparisonChartSheet(
          context,
          series: buildComparisonSeries(
            finance,
            _month,
            // The forecast's own clock, so the chart and the card agree;
            // the dashed line only when the card shows the forecast too.
            now: forecastNow,
            forecast: chartForecast,
            lastMonthOnRecord:
                c.vsPrevious.state != CompareState.notEnoughHistory,
          ),
          startOnUsual: usual,
        );
      }

      String? against(SpendCompare? c, String what) {
        // Nothing either side is the card's "Nothing recorded", not a match.
        if (c == null || c.state != CompareState.ok || c.empty) return null;
        if (c.negligible) return 'About the same as $what';
        final p = c.deltaPct;
        if (p == null) return null;
        // Past a doubling: "2.7 times last month".
        final times = timesPhrase(p);
        if (times != null) return '$times $what';
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
      final thisMonth = DateTime(today.year, today.month);
      final sixMonthsTitle = _yearMode
          ? 'Months of ${yearLabel(year, sm)}'
          : _month == thisMonth
          ? 'Last 6 months'
          : '6 months to ${fmtMonth(_month)}';
      // The chart's months that have ended and are fully on record: a
      // running month, one before the records, one they start part-way
      // through or one with nothing recorded (an import gap) would drag it
      // down. The usual month skips those too.
      final oldest = finance.firstTransactionDate;
      final firstMonth = oldest == null
          ? null
          : DateTime(oldest.year, oldest.month + (oldest.day == 1 ? 0 : 1));
      final recorded = finance.monthsWithData.toSet();
      final finished = [
        for (final m
            in _yearMode
                ? yearMonths(year, sm)
                : [
                    for (var i = 5; i >= 0; i--)
                      DateTime(_month.year, _month.month - i),
                  ])
          if (m.isBefore(thisMonth) &&
              firstMonth != null &&
              !m.isBefore(firstMonth) &&
              recorded.contains(m))
            m,
      ];
      final sixMonthAverage = finished.isEmpty
          ? null
          : finished.fold<double>(0, (s, m) => s + finance.expenseInMonth(m)) /
                finished.length;
      // The pace section's label for the running month; another month
      // names both sides. Its tip carries the same title.
      final paceTitle = comparison == null || _month == thisMonth
          ? null
          : '${DateFormat('MMMM').format(_month)} vs '
                '${DateFormat('MMMM').format(comparison.previousMonth)}';
      final sections = <DashboardSection, _DashSection>{
        // The shown month against the one before it, in Month view (any
        // month, the recap week included). Month concepts, so the Year
        // view steps aside the way budgets and the heatmap already do.
        DashboardSection.pace: (
          visible: comparison != null,
          title: paceTitle,
          summary: comparison == null
              ? null
              : () {
                  final c = comparison.vsPrevious;
                  final head =
                      '${fmtMoneyCompact(c.actual)}'
                      '${comparison.partial ? ' so far' : ''}';
                  final vs = against(c, 'last month');
                  return vs == null
                      ? head
                      : '$head, ${vs[0].toLowerCase()}${vs.substring(1)}';
                }(),
          tip: InfoTip(
            title: paceTitle ?? DashboardSection.pace.label,
            message: kPaceTipMessage,
            example: cardForecast == null
                ? () => projectionExample(comparison!)
                : forecastExample,
          ),
          body: () => [
            KeyedSubtree(
              key: _paceKey,
              child: MonthPaceCard(
                comparison: comparison!,
                forecastTotal: cardForecast,
                forecastIsFloor: forecastFloor,
                onSeeChart: () => openChart(usual: false),
              ),
            ),
          ],
        ),
        DashboardSection.usual: (
          visible: comparison != null,
          title: null,
          summary: against(comparison?.vsUsual, 'a usual month'),
          tip: comparison == null ? null : usualTip(comparison),
          body: () => [
            UsualSpendCard(
              comparison: comparison!,
              forecastTotal: cardForecast,
              forecastIsFloor: forecastFloor,
              onTap: () => openChart(usual: true),
            ),
          ],
        ),
        DashboardSection.categoryComparison: (
          visible: comparison != null,
          title: null,
          summary: mover == null
              ? null
              : '${mover.category.label} up most on usual',
          tip: comparison == null
              ? null
              : categoryComparisonTip(comparison, categorySort),
          body: () => [
            CategoryComparisonCard(
              comparison: comparison!,
              onViewCategory: _showCategoryHistory,
              sort: categorySort,
              onSortChanged: (s) =>
                  context.read<SettingsProvider>().setCategorySort(s),
            ),
          ],
        ),
        // The Year view's own comparison, where the month ones step aside.
        // Hidden on a year with nothing either side and no history to say
        // so about.
        DashboardSection.yearVsLast: (
          visible:
              yearCompare != null &&
              !(yearCompare.total.empty && yearCompare.categories.isEmpty),
          title: null,
          summary: against(yearCompare?.total, 'last year'),
          tip: yearCompare == null ? null : yearComparisonTip(yearCompare),
          body: () => [
            YearComparisonCard(
              comparison: yearCompare!,
              onViewCategory: _showCategoryHistory,
            ),
          ],
        ),
        DashboardSection.sixMonths: (
          visible: true,
          title: sixMonthsTitle,
          summary: sixMonthAverage == null
              ? (hideIncome ? 'Spend by month' : 'Income and spend by month')
              : '${fmtMoneyCompact(sixMonthAverage)} a month on average',
          tip: InfoTip(
            title: sixMonthsTitle,
            message:
                '${hideIncome ? "Each bar is one month's spending." : "Each pair of bars is one month's income and spending."} '
                'Tap a bar for its figures. The average counts finished '
                'months that are fully on record.',
          ),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.card),
                child: Column(
                  children: [
                    MonthlyBarChart(
                      months: _yearMode ? yearMonths(year, sm) : null,
                      end: _month,
                      showIncome: !hideIncome,
                    ),
                    const SizedBox(height: 8),
                    // Wraps at large text on a narrow phone.
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 16,
                      children: [
                        if (!hideIncome)
                          _LegendDot(color: colors.green, label: 'Income'),
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
      return _page(DashboardPage.trends, const [], sections, fold: true);
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
          tip: InfoTip(
            title: DashboardSection.donut.label,
            message:
                "Each slice is a category's share of the month's spending "
                "(the year's in Year view). Tap a slice for its amount, share "
                'and history. By category below lists every category.',
          ),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.card),
                child: CategoryDonutChart(
                  data: byCategory,
                  // By category lists every category: no second list here.
                  showLegend: false,
                  chartHeight: 140,
                  emptyText: _yearMode
                      ? 'No spending this year'
                      : 'No spending this month',
                  // The slice popup opens history; its sheet offers the
                  // transactions this used to open.
                  onCategoryHistory: _showCategoryHistory,
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
                "${_yearMode ? "year's" : "month's"} spending. Tap ⋮ on a "
                'row to set or edit a budget for it. "₹X / ₹Y" is the '
                'spending against that budget.',
            link: const InfoLink(
              prompt: 'Transactions not classified right?',
              label: 'Set up transaction rules',
              onTap: goCockpitRules,
            ),
          ),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.card),
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
                        onTap: () => _showCategoryHistory(entry.key.id),
                        actions: [
                          (
                            label: 'See history',
                            icon: Icons.history,
                            onSelected: () =>
                                _showCategoryHistory(entry.key.id),
                          ),
                          // Shortcut to a per-category cap: opens the shared
                          // budget dialog pre-filled (or the existing one).
                          (
                            label:
                                _singleCategoryBudget(finance, entry.key.id) ==
                                    null
                                ? 'Set budget'
                                : 'Edit budget',
                            icon: Icons.savings_outlined,
                            onSelected: () => showBudgetDialog(
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
                'money out, transfers included. A row with two tags counts '
                'under both, so shares can add past 100%. Tap ⋮ on a tag to '
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
                padding: const EdgeInsets.all(AppSpace.card),
                child: ShowAllList(
                  key: ValueKey('tags-$listKey'),
                  noun: 'tags',
                  rows: [
                    for (final t in byTag)
                      () {
                        // The All tab: the money-out transfers the figure
                        // counts are listed too.
                        final open = _yearMode
                            ? _openYear(year, sm, tag: t.tag)
                            : widget.onViewTag == null
                            ? null
                            : () => widget.onViewTag!(t.tag, _month);
                        return _CategoryRow(
                          icon: Icons.label_outline,
                          color: finance.tagColor(t.tag) ?? scheme.tertiary,
                          label: t.tag,
                          amount: t.spent,
                          fraction: tagMoneyOut == 0
                              ? 0
                              : t.spent / tagMoneyOut,
                          onTap: open,
                          actions: [
                            if (open != null)
                              (
                                label: 'See transactions',
                                icon: Icons.receipt_long_outlined,
                                onSelected: open,
                              ),
                            (
                              label: 'Edit tag',
                              icon: Icons.edit_outlined,
                              onSelected: () => showTagEditor(context, t.tag),
                            ),
                          ],
                        );
                      }(),
                  ],
                ),
              ),
            ),
          ],
        ),
        // Where the money actually went: per-payee totals for the month,
        // re-derived from SMS bodies / manual notes. A tap opens the
        // merchant's history, whose button searches its transactions.
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
                'are left out. Tap ⋮ on a merchant to rename it everywhere.',
          ),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.card),
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
                            onTap: () => _showMerchantHistory(m),
                            // No padding: the ⋮ button's 48dp sets the height.
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
                                      fmtMoneyWhole(m.total),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                                _RowMenu(
                                  actions: [
                                    (
                                      label: 'See history',
                                      icon: Icons.history,
                                      onSelected: () => _showMerchantHistory(m),
                                    ),
                                    (
                                      label: 'Rename',
                                      icon: Icons.edit_outlined,
                                      onSelected: () =>
                                          _renameMerchant(context, m),
                                    ),
                                  ],
                                ),
                              ],
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
          tip: const InfoTip(
            title: 'Subscriptions',
            message:
                'Monthly payments found in the last year, plus any you '
                'marked as monthly, quarterly, half-yearly or yearly. Only '
                'active ones count: a payment more than '
                '$kSubscriptionGraceDays days late counts as stopped. The '
                'monthly figure spreads the longer cycles across the year.',
          ),
          body: () {
            final n = subs.active.length;
            return [
              Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: () => goCockpitSubscriptions(context),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.card),
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
                        // A cap, as on the Owed card: a loose flex child
                        // shrank the total at half the row.
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${fmtMoneyWhole(subs.monthlyTotal)} a month',
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
              onTap: goCockpitGroups,
            ),
          ),
          body: () => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.card),
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
                padding: const EdgeInsets.all(AppSpace.card),
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
                padding: const EdgeInsets.all(AppSpace.card),
                child: Column(
                  children: [
                    BreakdownRow(
                      icon: Icons.arrow_downward,
                      color: colors.green,
                      label: 'In',
                      amount:
                          '+${fmtMoneyWhole(finance.transferInInMonth(_month))}',
                    ),
                    BreakdownRow(
                      icon: Icons.arrow_upward,
                      color: scheme.error,
                      label: 'Out',
                      amount:
                          '−${fmtMoneyWhole(finance.transferOutInMonth(_month))}',
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
                                '${fmtMoneyWhole(entry.value)}',
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
      return _page(DashboardPage.breakdown, const [], sections, fold: true);
    }

    // One selector for all three pages, in Home's app bar: it scopes every
    // page, so it stays put while the pages slide under it.
    _publishHeader(finance, latestMonth);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: UnderlineTabs<DashboardView>(
            options: [for (final v in DashboardView.values) (v, v.label)],
            selected: _view,
            onChanged: _setView,
            pager: _pageCtrl,
          ),
        ),
        Expanded(
          child: PageView(
            controller: _pageCtrl,
            onPageChanged: (i) => setState(() {
              _view = DashboardView.values[i];
              // A visit ends on leaving its page: a section opened on
              // Breakdown stays open while Breakdown shows.
              final page = switch (_view) {
                DashboardView.overview => DashboardPage.overview,
                DashboardView.trends => DashboardPage.trends,
                DashboardView.breakdown => DashboardPage.breakdown,
              };
              // Pages a jump passes through on its way are not left.
              final heading = _jumpingTo;
              if (heading == null || heading == page) {
                _jumpingTo = null;
                _openedForVisit.removeWhere((s) => s.page != page);
              }
            }),
            // No PageStorageKey anywhere: off-screen pages dispose (no
            // keepAlive, zero cache extent), so every view change still
            // starts at the top instead of at a remembered offset.
            children: [
              for (final (page, ahead) in [
                (overviewChildren, 5000.0),
                (trendsChildren, 2500.0),
                (breakdownChildren, 2500.0),
              ])
                // Transparent ColoredBox: a PageView only receives drags
                // that hit its subtree, and blank regions need an opaque
                // hit-test surface. The Builder defers each page's widget
                // construction until the page is mounted.
                ColoredBox(
                  color: Colors.transparent,
                  child: Builder(
                    builder: (context) => ListView(
                      padding: const EdgeInsets.all(AppSpace.card),
                      // Sections can be moved down the page, and the recap
                      // notification scrolls to the recap (Overview) or the
                      // pace (Trends), a home-screen widget to its section:
                      // build ahead so the card exists to scroll to.
                      scrollCacheExtent: ScrollCacheExtent.pixels(ahead),
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

/// "This week": the week's spending so far against the usual week, one
/// slim row under its label, opening the weekly digest.
class _WeekRow extends StatelessWidget {
  final WeekDigest digest;
  final VoidCallback onTap;
  const _WeekRow({required this.digest, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final usual = digest.usual;
    final d = usual == null ? null : digest.spent - usual;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(DashboardSection.week.label),
        FrostedPanel(
          radius: BorderRadius.circular(AppRadius.card),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.card,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_view_week,
                      size: 20,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 12),
                    // The label sits centred against the two-line figure.
                    // It keeps its own width, up to half the row, so at
                    // 1.3x "Spent so far" stays on one line; the figures
                    // shrink to fit what is left.
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) => Row(
                          children: [
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: box.maxWidth / 2,
                              ),
                              child: Text(
                                'Spent so far',
                                style: text.bodyMedium,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      fmtMoneyWhole(digest.spent),
                                      style: text.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  // Red over the usual week, green under.
                                  if (d != null)
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: DeltaNote(
                                        text: negligibleDelta(d)
                                            ? 'About usual'
                                            : '${fmtMoneyWhole(d.abs())} '
                                                  '${d > 0 ? 'over' : 'under'} '
                                                  'usual',
                                        delta: d,
                                        style: text.bodySmall,
                                        maxLines: 1,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Who owes you": under its label, the first person still owing on split
/// bills and how many more, and the total, opening the People page.
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
    // One name and a count: two names with their amounts were cut short
    // on one line.
    final line = owing.isEmpty
        ? ''
        : owing.length == 1
        ? owing.first.name
        : '${owing.first.name} and ${owing.length - 1} more';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(DashboardSection.owed.label),
        FrostedPanel(
          radius: BorderRadius.circular(AppRadius.card),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: () => goPeople(context),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.card),
              child: Row(
                children: [
                  Icon(Icons.group, size: 20, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // A cap, not Flexible: a loose flex child capped the total
                  // at half the row and left a gap before the chevron.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        fmtMoneyWhole(finance.totalOwed),
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
      ],
    );
  }
}

/// "Big bills ahead": the monthly figure to set aside for quarterly,
/// half-yearly and yearly bills, a bar per month for the next 12 and the
/// next two bills. The whole card opens the sheet listing every bill.
class _BigBillsCard extends StatelessWidget {
  final BigBillsPlan plan;
  final VoidCallback onTap;
  const _BigBillsCard({required this.plan, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final next = plan.bills.take(2).toList();
    final more = plan.bills.length - next.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel(
          'Big bills ahead',
          tip: InfoTip(
            title: 'Big bills ahead',
            message:
                'Quarterly, half-yearly and yearly bills, from your '
                'reminders with an amount and the subscriptions you '
                'marked. The monthly figure is each bill\'s yearly cost '
                'spread over 12 months. Safe to spend and the forecast '
                'still count a bill in full in the month it falls due.',
          ),
        ),
        FrostedPanel(
          radius: BorderRadius.circular(AppRadius.card),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.card),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  BigBillsHeadline(plan: plan),
                  const SizedBox(height: 12),
                  BigBillsStrip(plan: plan),
                  const SizedBox(height: 12),
                  for (final b in next)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          // The date on its own line: in one cut text a
                          // long-named bill lost it.
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  b.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(fmtDateCompact(b.nextDue), style: muted),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // A long figure shrinks rather than pushing the
                          // name off the row.
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 120),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                fmtMoneyWhole(b.amount),
                                maxLines: 1,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (more > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('+$more more', style: muted),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Next 7 days": card bills, reminders and detected repeats due within
/// [_kUpcomingDays] (or overdue), soonest first, plus a card bill marked
/// paid for its cycle, with its Paid tag. Shows its empty line, and the
/// bell, when nothing is due.
class _UpcomingCard extends StatelessWidget {
  final FinanceProvider finance;
  final List<RecurringHit> hits;

  /// A home-screen widget opened the folded card for this visit.
  final bool openedForVisit;

  /// The header's tap: folds or opens, or ends the visit.
  final VoidCallback onHeaderTap;

  const _UpcomingCard({
    required this.finance,
    required this.hits,
    required this.openedForVisit,
    required this.onHeaderTap,
  });

  /// One duration for the fold, the chevron flip and the count fade, so the
  /// three movements read as a single gesture.
  static const _foldDuration = Duration(milliseconds: 250);

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();

    // The Overview's window; the home widget and the digest keep their own.
    // A card marked paid for its cycle stays listed whatever its next due
    // date, so Mark unpaid stays in reach; a card not billed yet owes
    // nothing this week and is left off.
    bool inWindow(UpcomingItem u) {
      if (u.kind == UpcomingKind.cardBill) {
        if (u.paid) return true;
        if (u.cardStatus?.phase == CardBillPhase.notBilled) return false;
      }
      return u.days <= _kUpcomingDays;
    }

    final entries = [
      for (final u in buildUpcomingItems(
        finance,
        hits: hits,
        hidden: settings.hiddenUpcoming,
        now: now,
      ))
        if (inWindow(u))
          switch (u.kind) {
            UpcomingKind.cardBill => (
              due: u.due,
              icon: Icons.credit_card,
              // Traffic-light phases: green = paid, orange = billed, red =
              // due within the urgent window or overdue. A card not billed
              // yet is left off the list.
              color: cardBillColor(
                u.cardStatus!,
                green: AppColors.of(context).green,
                orange: AppColors.of(context).orange,
                red: scheme.error,
              ),
              label: u.label,
              // A paid cycle shows its Paid tag in place of the amount and
              // its next bill under the name; a billed one, when it is due.
              sub: u.paid
                  ? cardBillNextLine(u.cardStatus!)
                  : cardBillSubtitle(u.cardStatus!, withStatement: false),
              amount: u.amount,
              type: u.type,
              urgent: u.urgent,
              paid: u.paid,
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
                  : 'Expected ${fmtDateCompact(u.due)} · ${fmtInDays(u.days)}',
              amount: u.amount,
              type: u.type,
              urgent: u.urgent,
              paid: u.paid,
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
                  : 'Due ${fmtDateCompact(u.due)} · ${fmtInDays(u.days)}',
              amount: u.amount,
              type: u.type,
              urgent: u.urgent,
              paid: u.paid,
              hideKey: u.hideKey,
              reminder: u.reminder,
              card: u.card,
            ),
          },
    ];
    // A widget's tap opens a folded card for this visit only.
    final collapsed =
        settings.isSectionCollapsed('upcoming') && !openedForVisit;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tappable header: the card can dominate the top of the dashboard,
          // so it folds to this row (persisted per device). Styled like the
          // other section labels, and 48dp tall open or folded.
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.control),
            onTap: onHeaderTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 0, 0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    // The label, count and tip take the room the two buttons
                    // leave; at large text on a narrow phone the label
                    // shortens rather than pushing them off the row.
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              DashboardSection.upcoming.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: SectionLabel.style(context),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Static in both states. Fading the count in step with the
                          // fold rendered its glyphs in two halves on Impeller, so the
                          // header no longer animates any text. A paid card bill is
                          // listed but not counted: nothing is due on it.
                          Text(
                            '${entries.where((e) => !e.paid).length}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          // A direct child of the header row, beside the count: the
                          // row's own tap folds the card, the tip's tap stays its own,
                          // on a 48dp target so a near miss does not fold it.
                          // Only while open: a folded header stays quiet.
                          if (!collapsed)
                            const InfoTipTarget(
                              size: 48,
                              child: InfoTip(
                                title: 'Next 7 days',
                                message:
                                    'Bills and payments due in the next 7 days, and '
                                    'any up to a week overdue: card bills, your '
                                    'reminders, and payments the app spotted '
                                    'repeating (from SMS or your notes), including '
                                    'regular income. A repeat is spotted after 3 '
                                    'payments to the same merchant about a month '
                                    'apart. A paid card shows a Paid tag in place of its amount. '
                                    'Tap a spotted payment to see its transactions, '
                                    'make it a reminder or hide it. The Month-end '
                                    'forecast lists every bill due this month.',
                                link: InfoLink(
                                  prompt: 'A bill the app cannot detect?',
                                  label: 'Add a reminder',
                                  onTap: goNewReminder,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
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
          ),
          // Pure height reveal, no fade: cross-fading made the amounts appear
          // half-transparent while the card expanded.
          AnimatedFold(
            collapsed: collapsed,
            child: Column(
              // Full width, like the cards around it, even holding one line.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FrostedPanel(
                  radius: BorderRadius.circular(AppRadius.card),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpace.card,
                      // One quiet line when nothing is due.
                      vertical: entries.isEmpty ? 12 : 8,
                    ),
                    child: entries.isEmpty
                        ? Text(
                            'Nothing due in the next 7 days.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          )
                        // Six, then Show all: the rest used to be cut off.
                        : ShowAllList(
                            noun: 'upcoming',
                            shown: 6,
                            rows: [
                              for (final e in entries)
                                InkWell(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.control,
                                  ),
                                  // Manual reminders: tap for mark paid / edit /
                                  // delete. Card bills: mark paid / record payment.
                                  // Detected payments: view, make a reminder,
                                  // hide.
                                  onTap: e.reminder != null
                                      ? () => _showReminderActions(
                                          context,
                                          e.reminder!,
                                          e.due,
                                        )
                                      : e.card != null
                                      ? () => _showCardBillActions(
                                          context,
                                          e.card!,
                                        )
                                      : e.hideKey != null
                                      ? () => _showDetectedActions(
                                          context,
                                          e.hideKey!,
                                        )
                                      : null,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        // For card bills the icon's color
                                        // carries the state (green paid,
                                        // orange billed, red urgent).
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
                                              // Urgent: a red dot and red text.
                                              Row(
                                                children: [
                                                  if (e.urgent) ...[
                                                    StatusDot(
                                                      color: scheme.error,
                                                    ),
                                                    const SizedBox(width: 6),
                                                  ],
                                                  Expanded(
                                                    child: Text(
                                                      e.sub,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            color: e.urgent
                                                                ? scheme.error
                                                                : null,
                                                          ),
                                                    ),
                                                  ),
                                                ],
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
                                            // A paid card bill: its tag in
                                            // place of the figure.
                                            child: e.paid
                                                ? Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        Icons.check,
                                                        size: 16,
                                                        color: AppColors.of(
                                                          context,
                                                        ).green,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        'Paid',
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: AppColors.of(
                                                            context,
                                                          ).green,
                                                        ),
                                                      ),
                                                    ],
                                                  )
                                                : Text(
                                                    e.amount == null
                                                        ? ''
                                                        : fmtMoneyWhole(
                                                            e.amount!,
                                                          ),
                                                    // One colour for every
                                                    // bill; income keeps its
                                                    // green.
                                                    style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color:
                                                          e.type ==
                                                              TxType.income
                                                          ? moneyColor(
                                                              context,
                                                              type:
                                                                  TxType.income,
                                                            )
                                                          : scheme.onSurface,
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
                  title: const Text('Mark unpaid'),
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
                    'The amount keeps showing what has built up since. '
                    'That belongs to the next bill.',
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
                  'Use this for a payment the app never saw. The amount drops by '
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
                        'The bill amount you paid. This cycle is marked '
                        'paid and the outstanding drops by it.',
                    helperMaxLines: 4,
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

  Future<void> _confirmHide(
    BuildContext context,
    String label,
    String key,
  ) async {
    final hide = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hide "$label"?'),
        content: const Text(
          'This detected payment will no longer appear in Upcoming or fire '
          'reminders.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hide'),
          ),
        ],
      ),
    );
    if (hide != true || !context.mounted) return;
    final settings = context.read<SettingsProvider>();
    // The toast first: hiding rebuilds the list, which can unmount this
    // row before the preference write returns.
    showUndoSnackBar(
      context,
      'Hid "$label"',
      () => settings.unhideUpcoming(key),
      icon: Icons.visibility_off_outlined,
      tone: AppToastTone.removal,
    );
    await settings.hideUpcoming(key);
  }

  /// A detected payment's row: its transactions, a reminder made from it
  /// (money out only: reminders are for bills), or hiding it.
  Future<void> _showDetectedActions(BuildContext context, String key) async {
    RecurringHit? hit;
    for (final h in hits) {
      if (h.key == key) hit = h;
    }
    final h = hit;
    if (h == null) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      // Scrolls rather than overflowing at large text on a small phone.
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  h.label,
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                subtitle: Text('Expected ${fmtDate(h.nextDue)}'),
              ),
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('View transactions'),
                onTap: () => Navigator.pop(ctx, 'view'),
              ),
              if (h.type == TxType.expense)
                ListTile(
                  leading: const Icon(Icons.add_alert_outlined),
                  title: const Text('Make a reminder'),
                  subtitle: const Text(
                    'For bills that may stop showing in SMS',
                  ),
                  onTap: () => Navigator.pop(ctx, 'reminder'),
                ),
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: const Text('Hide'),
                subtitle: const Text('Also hides it from Subscriptions'),
                onTap: () => Navigator.pop(ctx, 'hide'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'view':
        AppNav.instance.openTransactions(
          context,
          // Its own tab, as the Subscriptions row opens it.
          TxFilterRequest(
            type: h.type,
            query: h.key.substring(h.key.indexOf('|') + 1),
          ),
        );
      case 'reminder':
        await showReminderEditor(
          context,
          name: h.label,
          dayOfMonth: h.nextDue.day,
          amount: h.expectedAmount,
          categoryId: h.categoryId,
          // Repeats like the payment, from the month it is next due.
          cycle: h.cycle ?? SubscriptionCycle.monthly,
          anchorMonth: h.nextDue.month,
        );
      case 'hide':
        await _confirmHide(context, h.label, h.key);
    }
  }
}

class _BalanceCard extends StatelessWidget {
  final FinanceProvider finance;

  /// The month's (or year's) Income, Spent and Saved, as columns under the
  /// balance; each opens its own rows.
  final List<_StatColumn> stats;
  const _BalanceCard({required this.finance, required this.stats});

  /// With accounts, the headline is the bank-stated net worth — ledger
  /// arithmetic (income − expense) is unreliable when the SMS history has no
  /// opening balances. Without accounts, fall back to the ledger figure.
  /// Wallets alone don't: they are never part of net balance.
  bool get _useAccounts => finance.hasNetAccounts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The balance half is a button (ripple, one a11y node) opening the
    // breakdown; each stat column below is its own button.
    return FrostedPanel(
      radius: BorderRadius.circular(AppRadius.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => showBalanceBreakdownSheet(context, finance),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.card,
                AppSpace.card,
                AppSpace.card,
                AppSpace.card,
              ),
              child: _balance(context, scheme),
            ),
          ),
          Divider(
            height: 1,
            indent: AppSpace.card,
            endIndent: AppSpace.card,
            color: scheme.outlineVariant,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: LayoutBuilder(
              // Side by side, each a third (a half with Hide income), down to
              // a 320dp phone; narrower or with large text they stack.
              builder: (context, c) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final across = c.maxWidth / stats.length >= 88 * scale;
                return across
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [for (final s in stats) Expanded(child: s)],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: stats,
                      );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _balance(BuildContext context, ColorScheme scheme) {
    final balance = _useAccounts ? finance.netWorth : finance.balance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: InfoLabel(
                  label: Text(
                    _useAccounts
                        ? 'Net balance today'
                        : 'Available balance today',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  tip: _useAccounts
                      ? InfoTip(
                          title: 'Net balance today',
                          message:
                              'Bank balances minus what you owe on '
                              'credit cards. Savings, wallet and '
                              'closed accounts are left out. A card '
                              'with no '
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
                          title: 'Available balance today',
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
        const SizedBox(height: 2),
        // Morphs in place when the figure changes (edit, import, sync).
        // Red below zero, the text colour otherwise.
        // Scales down rather than cutting digits: a lakh figure at large
        // text is wider than a 320dp card.
        FittedBox(
          key: const ValueKey('balance-figure'),
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: MorphingAmount(
            format: fmtMoneyWhole,
            value: balance,
            style: TextStyle(
              color: balance < 0 ? scheme.error : scheme.onSurface,
              fontSize: AppFigure.hero,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// One of the balance card's Income, Spent and Saved columns: a coloured
/// marker icon, the label (its tip), and the figure in whole rupees, in its
/// [valueColor] when it has one. The label opens the tip; the
/// rest of the column opens the rows.
class _StatColumn extends StatelessWidget {
  final String label;
  final double value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  /// The figure's money colour; none keeps the text colour.
  final Color? valueColor;

  /// What the figure counts, behind the dotted label.
  final String tip;
  final InfoLink? link;

  const _StatColumn({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.tip,
    this.onTap,
    this.link,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: TipTitle(
                    label: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    tip: InfoTip(title: label, message: tip, link: link),
                  ),
                ),
              ],
            ),
            // No increment animation: animating on month change made the
            // figures visibly "roll", which read as glitchy.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                fmtMoneyWhole(value),
                maxLines: 1,
                // Shrinks to fit a third of the card rather than wrapping.
                style: TextStyle(
                  fontSize: AppFigure.card,
                  fontWeight: FontWeight.w600,
                  color: valueColor ?? scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The monthly cap, one verdict: a bar stacking confirmed spending, rows
/// waiting for review and (this month) the bills still due against the
/// cap's line, a legend with each part, then what is left or over. Its
/// label sits above it ([_LabelRow]); [tip] is that label's tip.
class _BudgetCard extends StatelessWidget {
  /// Confirmed spending in the shown month.
  final double confirmed;

  /// Spending on rows still waiting for review, and how many rows.
  final double waiting;
  final int waitingCount;
  final double cap;

  /// This month's safe to spend today, which holds the bills due; null
  /// under any other month.
  final SafeToSpend? safe;

  /// The month-end forecast whose bills the legend's Due row opens, even
  /// when it does not share this card.
  final MonthForecast? billsForecast;

  /// The month-end forecast, when it shares this card (see
  /// [_DashboardScreenState._monthPlanSlot]): its rows follow a hairline.
  final MonthForecast? forecast;

  const _BudgetCard({
    required this.confirmed,
    required this.waiting,
    required this.waitingCount,
    required this.cap,
    this.safe,
    this.billsForecast,
    this.forecast,
  });

  /// The Monthly budget label's tip, with the sums worked out.
  static InfoTip tip({
    required double confirmed,
    required double waiting,
    required double bills,
    required double cap,
    SafeToSpend? safe,
  }) => InfoTip(
    title: 'Monthly budget',
    message:
        'Spending against the monthly cap set in Cockpit, Budgets and bills, '
        'Budgets. The bar adds confirmed spending, imports still waiting for '
        'review and the bills due this month, not card bills or transfers. '
        'The line marks the cap. Safe to spend today, at the top of the Overview, sets those '
        'bills aside and spreads the rest over the days left.',
    example: () {
      final line =
          '${fmtMoney(confirmed)} spent + ${fmtMoney(waiting)} waiting + '
          '${fmtMoney(bills)} due = '
          '${fmtMoney(safe?.committed ?? confirmed + waiting + bills)} '
          'of ${fmtMoney(cap)}';
      final s = safe;
      if (s == null || confirmed > cap || s.overCap) return line;
      final left = cap - s.spentBeforeToday - s.billsDue;
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
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = forecast;
    final s = safe;
    final bills = s?.billsDue ?? 0.0;
    final committed = s?.committed ?? confirmed + waiting;
    final color = budgetColor(context, cap <= 0 ? 0 : committed / cap);
    // One verdict, from unrounded figures. This month it is what safe to
    // spend leaves once the bills are paid; another month, what was spent
    // and is waiting against the cap.
    final String verdict;
    final bool over;
    if (s != null) {
      final r = s.remainingAfterToday;
      over = r < 0;
      verdict = over
          ? (s.billsDue > 0
                ? '${fmtMoneyWhole(-r)} over once these bills are paid'
                : '${fmtMoneyWhole(-r)} over the cap')
          : (s.billsDue > 0
                ? '${fmtMoneyWhole(r)} left after these bills'
                : '${fmtMoneyWhole(r)} left');
    } else {
      final r = cap - confirmed - waiting;
      over = r < 0;
      verdict = over
          ? '${fmtMoneyWhole(-r)} over the cap'
          : '${fmtMoneyWhole(r)} under the cap';
    }
    final bf = billsForecast;
    return FrostedPanel(
      radius: BorderRadius.circular(AppRadius.card),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BudgetStackBar(
              confirmed: confirmed,
              waiting: waiting,
              bills: bills,
              cap: cap,
              color: color,
            ),
            const SizedBox(height: 8),
            _BudgetLegendRow(
              swatch: _BudgetSwatch(color: color, style: _SwatchStyle.solid),
              label: 'Spent, confirmed',
              amount: confirmed,
            ),
            if (waiting > 0)
              _BudgetLegendRow(
                swatch: _BudgetSwatch(
                  color: color,
                  style: _SwatchStyle.striped,
                ),
                label: 'Waiting for review ($waitingCount)',
                amount: waiting,
              ),
            if (s != null && bills > 0)
              _BudgetLegendRow(
                swatch: _BudgetSwatch(
                  color: scheme.onSurfaceVariant,
                  style: _SwatchStyle.ring,
                ),
                label: 'Due this month (${s.billsCount})',
                amount: bills,
                onTap: bf == null
                    ? null
                    : () => _showForecastBills(context, bf),
              ),
            const SizedBox(height: 8),
            // Red once over; otherwise the bar's own green or orange.
            _BudgetVerdict(text: verdict, tone: over ? scheme.error : color),
            if (f != null) ...[
              const SizedBox(height: 12),
              Divider(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 8),
              _ForecastBody(forecast: f, compact: true),
            ],
          ],
        ),
      ),
    );
  }
}

/// A section label row with a figure at its right end: the Monthly budget
/// label and its cap. Spaced and styled as [SectionLabel], whose text stays
/// a plain [Text] so finders by text still land on it.
class _LabelRow extends StatelessWidget {
  final String text;
  final InfoTip tip;
  final String trailing;

  const _LabelRow({
    required this.text,
    required this.tip,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final style = SectionLabel.style(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TipTitle(
                label: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
                tip: tip,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Up to half the row; shrinks rather than overflowing at large
          // text on a narrow phone.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                trailing,
                maxLines: 1,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The three ways [_BudgetStackBar] draws a part, and its legend swatch.
enum _SwatchStyle { solid, striped, ring }

/// Confirmed, waiting and due stacked on one 12dp track against the cap's
/// line. Scaled to the cap or the total, whichever is larger, so a month
/// over the cap runs past the line.
class _BudgetStackBar extends StatelessWidget {
  final double confirmed;
  final double waiting;
  final double bills;
  final double cap;
  final Color color;

  const _BudgetStackBar({
    required this.confirmed,
    required this.waiting,
    required this.bills,
    required this.cap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label:
          'Spent ${fmtMoneyWhole(confirmed)}, waiting ${fmtMoneyWhole(waiting)}, '
          'due ${fmtMoneyWhole(bills)}, cap ${fmtMoneyWhole(cap)}',
      excludeSemantics: true,
      child: SizedBox(
        height: 20,
        width: double.infinity,
        child: CustomPaint(
          painter: _BudgetStackPainter(
            confirmed: confirmed,
            waiting: waiting,
            bills: bills,
            cap: cap,
            color: color,
            track: scheme.surfaceContainerHigh,
            outline: scheme.onSurfaceVariant,
            capLine: scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _BudgetStackPainter extends CustomPainter {
  final double confirmed;
  final double waiting;
  final double bills;
  final double cap;
  final Color color;
  final Color track;
  final Color outline;
  final Color capLine;

  _BudgetStackPainter({
    required this.confirmed,
    required this.waiting,
    required this.bills,
    required this.cap,
    required this.color,
    required this.track,
    required this.outline,
    required this.capLine,
  });

  static const _trackHeight = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final top = (size.height - _trackHeight) / 2;
    final bar = Rect.fromLTWH(0, top, size.width, _trackHeight);
    final radius = const Radius.circular(_trackHeight / 2);
    final rounded = RRect.fromRectAndRadius(bar, radius);
    canvas.drawRRect(rounded, Paint()..color = track);
    final total = confirmed + waiting + bills;
    final scale = math.max(cap, total);
    if (scale <= 0) return;
    double w(double v) => size.width * (v / scale).clamp(0.0, 1.0);
    // The parts share the track's rounded ends.
    canvas.save();
    canvas.clipRRect(rounded);
    final a = w(confirmed);
    final b = w(confirmed + waiting);
    final c = w(total);
    if (a > 0) {
      canvas.drawRect(
        Rect.fromLTRB(0, top, a, top + _trackHeight),
        Paint()..color = color,
      );
    }
    if (b > a) {
      _StripePainter.paintStripes(
        canvas,
        Rect.fromLTRB(a, top, b, top + _trackHeight),
        color,
      );
    }
    canvas.restore();
    if (c > b) {
      final r = Rect.fromLTRB(b, top, c, top + _trackHeight).deflate(1);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(3)),
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    // The cap: a 2dp line standing 4dp past the track at both ends.
    if (cap > 0) {
      final x = w(cap).clamp(1.0, size.width - 1);
      canvas.drawLine(
        Offset(x, top - 4),
        Offset(x, top + _trackHeight + 4),
        Paint()
          ..color = capLine
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_BudgetStackPainter old) =>
      old.confirmed != confirmed ||
      old.waiting != waiting ||
      old.bills != bills ||
      old.cap != cap ||
      old.color != color ||
      old.track != track ||
      old.outline != outline ||
      old.capLine != capLine;
}

/// 45 degree stripes 3dp apart: the part still waiting for review.
class _StripePainter extends CustomPainter {
  final Color color;
  _StripePainter(this.color);

  /// Stripes of [color] across [rect], clipped to it.
  static void paintStripes(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    canvas.save();
    canvas.clipRect(rect);
    for (var x = rect.left - rect.height; x < rect.right; x += 3) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) =>
      paintStripes(canvas, Offset.zero & size, color);

  @override
  bool shouldRepaint(_StripePainter old) => old.color != color;
}

/// A 10dp key for one part of the budget bar.
class _BudgetSwatch extends StatelessWidget {
  final Color color;
  final _SwatchStyle style;

  const _BudgetSwatch({required this.color, required this.style});

  @override
  Widget build(BuildContext context) {
    const size = 10.0;
    return switch (style) {
      _SwatchStyle.solid => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      _SwatchStyle.striped => ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: CustomPaint(
          size: const Size.square(size),
          painter: _StripePainter(color),
        ),
      ),
      _SwatchStyle.ring => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    };
  }
}

/// One legend line under the budget bar: its swatch, what it is, and its
/// amount. With [onTap] it is a 48dp button with a chevron.
class _BudgetLegendRow extends StatelessWidget {
  final Widget swatch;
  final String label;
  final double amount;
  final VoidCallback? onTap;

  const _BudgetLegendRow({
    required this.swatch,
    required this.label,
    required this.amount,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: onTap == null ? 40 : 48),
      child: Row(
        children: [
          swatch,
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (onTap != null)
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Capped, not Flexible: a flex child kept the label to half the
          // row, so "(3)" wrapped at 1.15x and the amount sat mid-card. A
          // lakh figure at large text shrinks past the cap.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                fmtMoneyWhole(amount),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: onTap,
      child: row,
    );
  }
}

/// The budget's one verdict in its tone: green, orange as it nears the cap,
/// red over.
class _BudgetVerdict extends StatelessWidget {
  final String text;

  /// Green, orange or red: the outline, the dot and the words.
  final Color tone;

  const _BudgetVerdict({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: tone),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        children: [
          StatusDot(color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: tone,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Safe to spend today, as a slim row at the top of the Overview: a dot,
/// the figure, and a chevron to the budget card that works it out.
class _SafeTodayRow extends StatelessWidget {
  final SafeToSpend safe;
  final VoidCallback onTap;

  const _SafeTodayRow({required this.safe, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = safe.leftToday >= 1;
    final tone = ok ? AppColors.of(context).green : scheme.error;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.card,
              vertical: 8,
            ),
            child: Row(
              children: [
                StatusDot(color: tone),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    ok
                        ? '${fmtMoneyWhole(safe.leftToday)} safe to spend today'
                        : 'Nothing safe to spend today',
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: tone),
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

/// Where this month is heading: spent so far, the bills still due and
/// everyday spending for the days left, against the monthly cap when one
/// is set ([computeMonthForecast]). Its own card when the monthly budget
/// card does not hold it.
class _ForecastCard extends StatelessWidget {
  final MonthForecast forecast;

  /// The under or over the cap line: only with the Monthly budget section
  /// hidden, since that card's verdict says it otherwise.
  final bool showCapLine;

  const _ForecastCard({required this.forecast, this.showCapLine = true});

  @override
  Widget build(BuildContext context) => FrostedPanel(
    radius: BorderRadius.circular(AppRadius.card),
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.card),
      // The section label above names it.
      child: _ForecastBody(
        forecast: forecast,
        showHeading: false,
        showCapLine: showCapLine,
      ),
    ),
  );
}

/// The forecast's heading, headline and rows, for [_ForecastCard] or for
/// the monthly budget card's lower half.
class _ForecastBody extends StatelessWidget {
  final MonthForecast forecast;

  /// Inside the budget card, whose legend already holds the spend so far
  /// and the bills: the headline, the everyday row and the footnote only.
  final bool compact;

  /// The under or over the cap line, when not [compact].
  final bool showCapLine;

  /// The "Month-end forecast" heading with its tip; off under a section
  /// label that says it.
  final bool showHeading;

  const _ForecastBody({
    required this.forecast,
    this.compact = false,
    this.showCapLine = true,
    this.showHeading = true,
  });

  /// "Next 12 days, about ₹240 a day: ..." for [f]'s everyday row; null
  /// without an estimate.
  static String? _everydayHow(MonthForecast f) {
    final days =
        '${f.daysAfterToday} ${f.daysAfterToday == 1 ? 'day' : 'days'}';
    final perDay = fmtMoneyWhole(f.perDay);
    // The day count leads: on a narrow screen at large text the label
    // wraps, and this is the part that must not be cut.
    return switch (f.basis) {
      EverydayBasis.usual when f.usualMonths == 2 =>
        'Next $days, about $perDay a day: the lower of 2 recent months',
      EverydayBasis.usual =>
        'Next $days, about $perDay a day: the middle of '
            '${f.usualMonths} recent months',
      EverydayBasis.pace =>
        "Next $days, about $perDay a day at this month's pace",
      EverydayBasis.none => null,
    };
  }

  /// The Month-end forecast's tip, with [f]'s sum worked out.
  static InfoTip tip(MonthForecast f) {
    final days =
        '${f.daysAfterToday} ${f.daysAfterToday == 1 ? 'day' : 'days'}';
    final perDay = fmtMoneyWhole(f.perDay);
    final showEveryday = _everydayHow(f) != null && f.daysAfterToday > 0;
    return InfoTip(
      title: 'Month-end forecast',
      message:
          'Spent so far, including alerts still to review, plus the bills '
          'still unpaid (due by the month end, or up to a week overdue; not '
          'card bills or transfers), plus what you usually spend on the days '
          'left, leaving bills out. Usual is the middle of your last complete '
          'months (the lower, with only two); a month with under a quarter '
          "of the others' middle spend counts as missing records. With fewer "
          "than two, this month's own pace once $kMinDaysOfData of its days "
          'are on record. Without an estimate the figure is a floor and reads '
          'At least.',
      example: () {
        final parts = [
          '${fmtMoney(f.spentSoFar)} spent',
          if (f.billsDue > 0) '${fmtMoney(f.billsDue)} bills due',
          if (showEveryday)
            '${fmtMoney(f.everyday)} everyday (about '
                '$perDay a day for $days)',
        ];
        return '${parts.join(' + ')} = ${fmtMoney(f.total)}';
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = forecast;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final by = fmtDateCompact(f.lastDay);
    // How the everyday figure was worked out, under its row.
    final everydayHow = _everydayHow(f);
    final showEveryday = everydayHow != null && f.daysAfterToday > 0;
    final under = f.underCap;
    // Spent so far includes rows still waiting for review, which the balance
    // card leaves out: the label says how many, so the two figures don't
    // seem to disagree.
    final toReview = pendingSpendCountIn(
      context.watch<FinanceProvider>(),
      DateTime(f.lastDay.year, f.lastDay.month),
    );

    Widget row(
      String label,
      double amount, {
      String? detail,
      VoidCallback? onTap,
    }) {
      // The label wraps, whole words only: the amount keeps at most 40% of
      // the row and shrinks past that, so at large text on a narrow phone
      // the label column stays wider than its longest word. The amounts
      // end at the card's edge, as the recap's do; a tappable row's
      // chevron follows its label instead of taking a slot after them.
      final line = Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(label, style: muted)),
                        if (onTap != null)
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                      ],
                    ),
                    if (detail != null)
                      Text(
                        detail,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * 0.4),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerEnd,
                  child: Text(fmtMoneyWhole(amount), maxLines: 1),
                ),
              ),
            ],
          ),
        ),
      );
      if (onTap == null) return line;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Align(alignment: Alignment.centerLeft, child: line),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeading) ...[
          Row(
            children: [
              Icon(Icons.trending_up, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Flexible(
                child: InfoLabel(
                  // Wraps at large text rather than cutting the name short.
                  label: Text('Month-end forecast', style: muted),
                  tip: tip(f),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        // The headline in whole rupees: "At least" when there is no
        // everyday estimate, so the total is a floor; "About" otherwise.
        Text(
          f.basis == EverydayBasis.none
              ? 'At least ${fmtMoneyWhole(f.total)} by $by'
              : 'About ${fmtMoneyWhole(f.total)} by $by',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        if (!compact) ...[
          row(
            toReview == 0
                ? 'Spent so far'
                : 'Spent so far, with $toReview to review',
            f.spentSoFar,
          ),
          if (f.billsDue > 0)
            row(
              'Due this month (${f.bills.length})',
              f.billsDue,
              onTap: () => _showForecastBills(context, f),
            ),
        ],
        if (showEveryday)
          row('Everyday spending', f.everyday, detail: everydayHow),
        if (under != null && !compact && showCapLine) ...[
          const SizedBox(height: 8),
          // Green under, red over: the dot and the words.
          Row(
            children: [
              StatusDot(
                color: under >= 0 ? AppColors.of(context).green : scheme.error,
                size: 8,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  under >= 0
                      ? '${fmtMoneyWhole(under)} under your '
                            '${fmtMoneyWhole(f.cap!)} budget'
                      : '${fmtMoneyWhole(-under)} over your '
                            '${fmtMoneyWhole(f.cap!)} budget',
                  style: TextStyle(
                    color: under >= 0
                        ? AppColors.of(context).green
                        : scheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (f.basis == EverydayBasis.none && f.daysAfterToday > 0) ...[
          const SizedBox(height: 6),
          Text(
            'Everyday spending is not counted yet: the records do not show '
            'enough of it to estimate.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// The forecast's bills, one row each: what it is, when it is due, what it
/// costs, whether it is a reminder or a payment the app detected, and a
/// Paid button for one that was paid but still shows (a reminder not
/// marked, an alert that never came). Whether a row is paid is read from
/// the provider, so a reminder's two rows (last month's and this month's)
/// and a reminder's payment alert arriving meanwhile stay right. A row
/// marked here keeps an Undo while its mark is still the current one; the
/// total below is the unpaid rows'.
Future<void> _showForecastBills(BuildContext context, MonthForecast f) {
  final finance = context.read<FinanceProvider>();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  // Row index → the Paid tapped on it: whether its mark still stands (a
  // later mark or an alert can move it on), and how to undo it.
  final undo =
      <int, ({bool Function() current, Future<void> Function() run})>{};

  Reminder? reminderOf(DueBill b) {
    for (final r in finance.reminders) {
      if (r.id == b.reminderId) return r;
    }
    return null;
  }

  bool isPaid(DueBill b) {
    final key = b.patternKey;
    if (key != null) {
      final through = DateTime.tryParse(finance.patternPaidThrough(key) ?? '');
      return through != null && !b.due.isAfter(through);
    }
    final r = reminderOf(b);
    return r != null && reminderOccurrenceDone(r, b.due);
  }

  /// Marks [b] paid; returns its undo when the tap changed anything.
  ({bool Function() current, Future<void> Function() run})? markPaid(
    DueBill b,
  ) {
    final key = b.patternKey;
    if (key != null) {
      final before = finance.patternPaidThrough(key);
      finance.markPatternPaid(key, b.due);
      final marked = finance.patternPaidThrough(key);
      if (marked == before) return null;
      return (
        current: () => finance.patternPaidThrough(key) == marked,
        run: () => finance.restorePatternPaid(key, before, marked: marked),
      );
    }
    final r = reminderOf(b);
    if (r == null) return null;
    final before = r.lastPaidMonth;
    finance.markReminderPaid(r.id, b.due);
    final marked = reminderOf(b)?.lastPaidMonth;
    if (marked == null || marked == before) return null;
    return (
      current: () => reminderOf(b)?.lastPaidMonth == marked,
      run: () =>
          finance.undoReminderPaid(r.id, marked: marked, previous: before),
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => ListenableBuilder(
      listenable: finance,
      builder: (ctx, _) => StatefulBuilder(
        builder: (ctx, setState) {
          final scheme = Theme.of(ctx).colorScheme;
          final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
          var total = 0.0;
          for (final b in f.bills) {
            if (!isPaid(b)) total += b.amount;
          }
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: FrostedPanel(
                radius: BorderRadius.circular(28),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Due this month',
                          style: Theme.of(ctx).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Reminders not yet paid, and regular payments the '
                          'app has spotted in your history, due by '
                          '${fmtDateCompact(f.lastDay)} or up to a week '
                          'overdue. Paid one already? Tap Paid: it leaves '
                          'the forecast.',
                          style: muted,
                        ),
                        const SizedBox(height: 8),
                        for (final (i, b) in f.bills.indexed)
                          _ForecastBillRow(
                            bill: b,
                            today: today,
                            paid: isPaid(b),
                            // Add it for me records its own expense on the
                            // due day: marking it paid would skip that.
                            autoAdd: reminderOf(b)?.autoAdd ?? false,
                            onPaid: () {
                              final back = markPaid(b);
                              if (back != null) {
                                setState(() => undo[i] = back);
                              }
                            },
                            onUndo: undo[i]?.current() ?? false
                                ? () {
                                    final back = undo.remove(i);
                                    setState(() {});
                                    back?.run();
                                  }
                                : null,
                          ),
                        const Divider(height: 24),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Total',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            Text(
                              fmtMoneyWhole(total),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// One bill in [_showForecastBills]: name and amount, then when it is due
/// and what kind it is beside its Paid (or, once paid, Undo) button.
class _ForecastBillRow extends StatelessWidget {
  final DueBill bill;
  final DateTime today;
  final bool paid;
  final bool autoAdd;
  final VoidCallback onPaid;

  /// Null once paid by other means (a later mark, an alert): nothing of
  /// this sheet's to undo.
  final VoidCallback? onUndo;

  const _ForecastBillRow({
    required this.bill,
    required this.today,
    required this.paid,
    required this.autoAdd,
    required this.onPaid,
    required this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final b = bill;
    final reminder = b.patternKey == null;
    // Each fact stays whole when the line wraps.
    final when = paid
        ? 'Marked paid'
        : joinFacts([
            // A detected payment's date is the app's guess: expected, not
            // due.
            switch ((reminder, b.due.isBefore(today))) {
              (true, true) => 'Overdue since ${fmtDateCompact(b.due)}',
              (true, false) => 'Due ${fmtDateCompact(b.due)}',
              (false, true) =>
                'Expected ${fmtDateCompact(b.due)}, not seen yet',
              (false, false) => 'Expected ${fmtDateCompact(b.due)}',
            },
            reminder ? 'reminder' : 'regular payment',
          ]);
    final nameStyle = paid ? TextStyle(color: scheme.onSurfaceVariant) : null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  b.label,
                  style: nameStyle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    fmtMoneyWhole(b.amount),
                    style: paid
                        ? TextStyle(
                            color: scheme.onSurfaceVariant,
                            decoration: TextDecoration.lineThrough,
                          )
                        : null,
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(child: Text(when, style: muted)),
              const SizedBox(width: 8),
              if (autoAdd && !paid)
                Text('Added for you on the day', style: muted)
              else if (!paid || onUndo != null)
                Semantics(
                  button: true,
                  label: paid
                      ? 'Undo marking ${b.label} paid'
                      : 'Mark ${b.label} paid',
                  excludeSemantics: true,
                  // The tap on the node itself: excludeSemantics drops the
                  // button's own, which Switch Access needs.
                  onTap: paid ? onUndo : onPaid,
                  child: TextButton(
                    // Ends on the amounts' right edge.
                    style: flushEndTextButtonStyle,
                    onPressed: paid ? onUndo : onPaid,
                    child: Text(paid ? 'Undo' : 'Paid'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A custom budget's line: a small ring (green, amber, red as
/// [budgetColor]) with [icon] inside, then [title] and what is left or
/// over in the ring's colour, then "₹4,200 of ₹6,000
/// · 70%". At large text on a narrow phone the first line wraps under the
/// name.
class _BudgetRow extends StatelessWidget {
  final IconData icon;
  final Widget title;
  final double spent;
  final double limit;
  final VoidCallback? onTap;

  const _BudgetRow({
    required this.icon,
    required this.title,
    required this.spent,
    required this.limit,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pct = limit <= 0 ? 0.0 : spent / limit;
    final over = spent > limit;
    final color = budgetColor(context, pct);
    final amount = Text(
      over
          ? '${fmtMoneyWhole(spent - limit)} over'
          : '${fmtMoneyWhole(limit - spent)} left',
      // The ring's green, orange or red, on the words too.
      style: text.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: color,
      ),
    );
    // Amount at the row's right end, centred against the ring and both
    // lines; at large text it goes under the name instead of squeezing
    // the name to nothing.
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final amountAtEnd = scale <= 1.6;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _BudgetGauge(value: pct, color: color, icon: icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (amountAtEnd)
                  title
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, amount],
                  ),
                const SizedBox(height: 2),
                // No-break spaces round the dot: a narrow line breaks
                // before "₹6,000", never leaving the share alone.
                Text(
                  '${fmtMoneyWhole(spent)} of ${fmtMoneyWhole(limit)}'
                  ' · ${(pct * 100).round()}%',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (amountAtEnd) ...[const SizedBox(width: 8), amount],
        ],
      ),
    );
    if (onTap == null) return row;
    // One button node: the name and figures read as its label.
    return Semantics(
      container: true,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: row,
      ),
    );
  }
}

/// The 44dp ring of a [_BudgetRow]: the arc eases to [value] (full past
/// 100%) around [icon].
class _BudgetGauge extends StatelessWidget {
  final double value;
  final Color color;
  final IconData icon;

  const _BudgetGauge({
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return SizedBox.square(
      dimension: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // begin == end: a row scrolled back in shows its value at once;
          // a changed value still eases.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: v, end: v),
            duration: motionDuration(
              context,
              const Duration(milliseconds: 600),
            ),
            curve: Curves.easeOutCubic,
            builder: (context, t, _) => SizedBox.square(
              dimension: 44,
              child: CircularProgressIndicator(
                value: t,
                strokeWidth: 4,
                strokeCap: StrokeCap.round,
                color: color,
                backgroundColor: color.withValues(alpha: 0.3),
              ),
            ),
          ),
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// One entry of a Breakdown row's ⋮ menu.
typedef _RowAction = ({String label, IconData icon, VoidCallback onSelected});

/// A Breakdown row's ⋮: its actions, in sight rather than behind a
/// long-press. 48dp, so the row's height comes from it.
class _RowMenu extends StatelessWidget {
  final List<_RowAction> actions;
  const _RowMenu({required this.actions});

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
    tooltip: 'More',
    icon: const Icon(Icons.more_vert, size: 20),
    itemBuilder: (_) => [
      for (final (i, a) in actions.indexed)
        PopupMenuItem(
          value: i,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(a.icon),
            title: Text(a.label),
          ),
        ),
    ],
    onSelected: (i) => actions[i].onSelected(),
  );
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

  /// The row's ⋮ menu; none leaves the button out.
  final List<_RowAction> actions;

  /// Cap of the single-category budget on this row, if any, shown as a
  /// "₹X / ₹Y" figure rather than a second bar in an already dense list.
  final double? budgetLimit;

  const _CategoryRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.amount,
    required this.fraction,
    this.onTap,
    this.actions = const [],
    this.budgetLimit,
  });

  @override
  Widget build(BuildContext context) {
    final over = budgetLimit != null && amount > budgetLimit!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Padding(
        // With a ⋮, its 48dp sets the row's height.
        padding: EdgeInsets.symmetric(vertical: actions.isEmpty ? 6 : 0),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, box) => Row(
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
                        // Width-capped + scale-down, not Flexible: a loose
                        // flex child kept the name to half the line and left
                        // a gap after the amount (transaction-tile pattern).
                        // 180 fits "₹X / ₹Y" at full size; on a narrow line
                        // the cap drops to 60% of it, so at 320dp with large
                        // text the figure shrinks rather than overflowing.
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: box.maxWidth * 0.6 < 180
                                ? box.maxWidth * 0.6
                                : 180,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerEnd,
                            child: Text(
                              budgetLimit == null
                                  ? fmtMoneyWhole(amount)
                                  : '${fmtMoneyWhole(amount)} / '
                                        '${fmtMoneyWhole(budgetLimit!)}',
                              // Red once over its budget.
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: over
                                    ? Theme.of(context).colorScheme.error
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: AnimatedProgress(
                          value: fraction,
                          minHeight: 6,
                          color: color,
                          backgroundColor: color.withValues(alpha: 0.25),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Share of the section total (month expense for the
                      // category list, group total for By group): the bar
                      // shows it visually, this makes it readable. On the
                      // bar's line, so the name above keeps the width. A
                      // fixed column fits "100%", so every bar ends at the
                      // same point.
                      SizedBox(
                        width: MediaQuery.textScalerOf(context).scale(34),
                        child: Text(
                          '${(fraction * 100).round()}%',
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          softWrap: false,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (actions.isNotEmpty) _RowMenu(actions: actions),
          ],
        ),
      ),
    );
  }
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
