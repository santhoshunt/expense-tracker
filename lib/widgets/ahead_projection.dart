import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dashboard_layout.dart' show kAheadDays;
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/forward_series.dart';
import '../services/month_forecast.dart';
import '../services/recurring_detector.dart';
import '../services/safe_to_spend.dart' show pendingIsSpend;
import '../services/subscriptions.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../utils/haptics.dart';
import 'motion.dart';
import 'section_label.dart';

/// The Ahead tab's Expected balance section: the balance each of the next
/// [kAheadDays] days leaves, from the headline net balance less spend
/// waiting for review, with subscriptions, savings, income and everyday
/// spending laid out day by day. Rolling from today whatever month the
/// other tabs show.
class AheadProjection extends StatefulWidget {
  final FinanceProvider finance;

  /// The dashboard's detected patterns (normal mode).
  final List<RecurringHit> patterns;

  const AheadProjection({
    super.key,
    required this.finance,
    required this.patterns,
  });

  @override
  State<AheadProjection> createState() => _AheadProjectionState();
}

class _AheadProjectionState extends State<AheadProjection> {
  /// Today. The PageView disposes Ahead on leaving it, so every visit
  /// starts on today.
  int _selected = 0;
  bool _dragging = false;
  final List<GlobalKey> _rowKeys = [];

  ForwardSeries? _series;
  double _headline = 0;
  double _waiting = 0;
  ({Object rev, String hidden, DateTime day})? _seriesKey;

  ForwardSeries _seriesFor(String hiddenKey) {
    final finance = widget.finance;
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final k = _seriesKey;
    final cached = _series;
    if (cached != null &&
        k != null &&
        identical(k.rev, finance.revision) &&
        k.hidden == hiddenKey &&
        k.day == day) {
      return cached;
    }
    final hidden = context.read<SettingsProvider>().hiddenUpcoming;
    final forecast = computeMonthForecast(
      finance,
      patterns: widget.patterns,
      hidden: hidden,
      now: now,
      wholeMonth: true,
    );
    final savingsHits = [
      for (final i in cachedSubscriptions(finance, hidden).active)
        if (i.isSavings) i.hit,
    ];
    final headline = finance.hasNetAccounts
        ? finance.netWorth
        : finance.balance;
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final waiting = finance.pendingTransactions
        .where((t) => pendingIsSpend(finance, t) && t.date.isBefore(tomorrow))
        .fold(0.0, (s, t) => s + t.amount);
    final series = buildForwardSeries(
      finance,
      patterns: widget.patterns,
      savings: savingsHits,
      hidden: hidden,
      now: now,
      to: DateTime(now.year, now.month, now.day + kAheadDays - 1),
      perDay: forecast?.perDay ?? 0,
      start: headline - waiting,
    );
    _series = series;
    _headline = headline;
    _waiting = waiting;
    _seriesKey = (rev: finance.revision, hidden: hiddenKey, day: day);
    while (_rowKeys.length < series.days.length) {
      _rowKeys.add(GlobalKey());
    }
    return series;
  }

  /// Brings the chosen day's row into view after the frame. Only the page's
  /// own vertical list scrolls, never the dashboard's PageView.
  void _scrollToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selected >= _rowKeys.length) return;
      final ctx = _rowKeys[_selected].currentContext;
      final box = ctx?.findRenderObject();
      if (ctx == null || box == null) return;
      final scrollable = Scrollable.maybeOf(ctx);
      if (scrollable == null) return;
      scrollable.position.ensureVisible(
        box,
        alignment: 0.1,
        duration: motionDuration(context, const Duration(milliseconds: 250)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _select(int i) {
    if (i == _selected) return;
    setState(() => _selected = i);
  }

  @override
  Widget build(BuildContext context) {
    final hiddenKey = context.select<SettingsProvider, String>(
      (s) => hiddenListKey(s.hiddenUpcoming),
    );
    final hideIncome = context.select<SettingsProvider, bool>(
      (s) => s.hideIncome,
    );
    final calendar = context.select<SettingsProvider, bool>(
      (s) => s.aheadCalendar,
    );
    final series = _seriesFor(hiddenKey);
    final selected = _selected.clamp(0, series.days.length - 1);
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final view = (series: series, hideIncome: hideIncome, selected: selected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Headline(series: series),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.show_chart),
              label: Text('Chart'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.calendar_month),
              label: Text('Calendar'),
            ),
          ],
          selected: {calendar},
          onSelectionChanged: (s) =>
              context.read<SettingsProvider>().setAheadCalendar(s.first),
        ),
        const SizedBox(height: 8),
        if (calendar) ...[
          _DayCalendar(
            view: view,
            onSelect: (i) {
              Haptics.tick();
              _select(i);
              _scrollToSelected();
            },
          ),
          const SizedBox(height: 4),
          Text('Tap a day. The list below follows it.', style: muted),
        ] else ...[
          _BalanceChart(
            height: 132,
            view: view,
            dragging: _dragging,
            onDragStart: () => setState(() => _dragging = true),
            onSelect: _select,
            onDragEnd: () {
              setState(() => _dragging = false);
              _scrollToSelected();
            },
          ),
          const SizedBox(height: 4),
          Text(
            'Press and hold, then drag. The list below follows the day.',
            style: muted,
          ),
        ],
        const Divider(height: 24),
        _Totals(
          series: series,
          headline: _headline,
          waiting: _waiting,
          hideIncome: hideIncome,
        ),
        const Divider(height: 24),
        const SectionLabel('Day by day'),
        _DayRows(view: view, rowKeys: _rowKeys),
      ],
    );
  }
}

typedef _View = ({ForwardSeries series, bool hideIncome, int selected});

/// "Today, Fri 30 Oct" on day 0, "Sat 31 Oct" after.
String _dayLabel(ForwardSeries s, int i) {
  final d = fmtCountIn(s.days[i].date);
  return i == 0 ? 'Today, $d' : d;
}

/// "+₹85,000" for money in, "−₹5,000" otherwise; masked income when Hide
/// income is on.
String _signedText(ForwardItem item, bool hideIncome) {
  if (item.kind == ForwardKind.income) {
    return hideIncome ? kMaskedAmount : '+${fmtMoneyWhole(item.bill.amount)}';
  }
  return fmtMoneyWhole(-item.bill.amount);
}

Color _signedColor(BuildContext context, ForwardItem item) =>
    switch (item.kind) {
      ForwardKind.spend => Theme.of(context).colorScheme.error,
      ForwardKind.income => AppColors.of(context).green,
      ForwardKind.savings => Theme.of(context).colorScheme.onSurface,
    };

Color _balanceColor(BuildContext context, double v) => v < 0
    ? Theme.of(context).colorScheme.error
    : Theme.of(context).colorScheme.onSurface;

Color _lowestColor(BuildContext context, double v) =>
    v < 0 ? Theme.of(context).colorScheme.error : AppColors.of(context).orange;

/// The balance on the last day, and the lowest one on the way.
class _Headline extends StatelessWidget {
  final ForwardSeries series;

  const _Headline({required this.series});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final last = series.last;
    final lowest = series.lowest;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Expected on ${fmtCountIn(last.date)}', style: muted),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  fmtMoneyWhole(last.balance),
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: _balanceColor(context, last.balance),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Lowest · ${fmtCountIn(lowest.date)}',
                style: muted,
                textAlign: TextAlign.end,
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerEnd,
                child: Text(
                  fmtMoneyWhole(lowest.balance),
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: _lowestColor(context, lowest.balance),
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

/// The 31-day balance line. Only a long press selects a day, so a plain
/// swipe still turns the dashboard page; the marker stays after the finger
/// lifts, the readout bubble does not.
class _BalanceChart extends StatelessWidget {
  final double height;
  final _View view;
  final bool dragging;
  final VoidCallback onDragStart;
  final ValueChanged<int> onSelect;
  final VoidCallback onDragEnd;

  const _BalanceChart({
    required this.height,
    required this.view,
    required this.dragging,
    required this.onDragStart,
    required this.onSelect,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final series = view.series;
    final n = series.days.length;
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    final lowest = series.lowest;
    return Semantics(
      label:
          'Expected balance for the next $kAheadDays days, lowest '
          '${fmtMoneyWhole(lowest.balance)} on ${fmtCountIn(lowest.date)}, '
          '${fmtMoneyWhole(series.last.balance)} on '
          '${fmtCountIn(series.last.date)}',
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          int dayAt(double dx) =>
              n <= 1 ? 0 : (dx / width * (n - 1)).round().clamp(0, n - 1);
          var current = view.selected;
          void move(double dx) {
            final i = dayAt(dx);
            if (i == current) return;
            current = i;
            Haptics.tick();
            onSelect(i);
          }

          final x = n <= 1 ? 0.0 : view.selected / (n - 1) * width;
          final bubbleWidth = math.min(200.0, width * 0.6);
          final onLeft = x > width / 2;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (d) {
              Haptics.tick();
              onDragStart();
              current = dayAt(d.localPosition.dx);
              onSelect(current);
            },
            onLongPressMoveUpdate: (d) => move(d.localPosition.dx),
            onLongPressEnd: (_) => onDragEnd(),
            child: SizedBox(
              height: height,
              width: width,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _BalanceLinePainter(
                        balances: [for (final d in series.days) d.balance],
                        dates: [for (final d in series.days) d.date],
                        selected: view.selected,
                        lowest: series.days.indexOf(lowest),
                        line: scheme.primary,
                        guide: scheme.onSurfaceVariant,
                        grid: scheme.outlineVariant,
                        ring: colors.orange,
                        edge: Colors.white,
                        labelStyle:
                            Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ) ??
                            TextStyle(color: scheme.onSurfaceVariant),
                        textDirection: Directionality.of(context),
                        textScaler: MediaQuery.textScalerOf(context),
                      ),
                    ),
                  ),
                  if (dragging)
                    Positioned(
                      top: 0,
                      left: onLeft
                          ? null
                          : math.min(x + 10, width - bubbleWidth),
                      right: onLeft
                          ? math.min(width - x + 10, width - bubbleWidth)
                          : null,
                      width: bubbleWidth,
                      child: IgnorePointer(child: _ReadoutBubble(view: view)),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The chosen day while a finger drags: its date, the balance it leaves
/// and up to three of its payments.
class _ReadoutBubble extends StatelessWidget {
  final _View view;

  const _ReadoutBubble({required this.view});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final day = view.series.days[view.selected];
    final shown = day.items.take(3).toList();
    final more = day.items.length - shown.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _dayLabel(view.series, view.selected),
            style: text.labelMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            'Balance after ${fmtMoneyWhole(day.balance)}',
            style: text.bodySmall?.copyWith(
              color: _balanceColor(context, day.balance),
            ),
          ),
          for (final item in shown)
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.bill.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _signedText(item, view.hideIncome),
                  style: text.bodySmall?.copyWith(
                    color: _signedColor(context, item),
                  ),
                ),
              ],
            ),
          if (more > 0)
            Text(
              'and $more more',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _BalanceLinePainter extends CustomPainter {
  final List<double> balances;
  final List<DateTime> dates;
  final int selected;
  final int lowest;
  final Color line;
  final Color guide;
  final Color grid;
  final Color ring;
  final Color edge;
  final TextStyle labelStyle;
  final TextDirection textDirection;
  final TextScaler textScaler;

  _BalanceLinePainter({
    required this.balances,
    required this.dates,
    required this.selected,
    required this.lowest,
    required this.line,
    required this.guide,
    required this.grid,
    required this.ring,
    required this.edge,
    required this.labelStyle,
    required this.textDirection,
    required this.textScaler,
  });

  TextPainter _text(String s, {bool bold = false}) => TextPainter(
    text: TextSpan(
      text: s,
      style: bold
          ? labelStyle.copyWith(fontWeight: FontWeight.w700)
          : labelStyle,
    ),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final n = balances.length;
    if (n == 0) return;
    final sample = _text('9 Sep');
    const top = 6.0;
    final bottom = size.height - sample.height - 6;
    if (bottom <= top) return;
    var lo = balances.reduce(math.min);
    var hi = balances.reduce(math.max);
    if (hi - lo < 1) {
      lo -= 1;
      hi += 1;
    }
    double xFor(int i) => n <= 1 ? 0 : i / (n - 1) * size.width;
    double yFor(double v) => top + (hi - v) / (hi - lo) * (bottom - top);

    // Two dashed grid lines at round rupee levels inside the range.
    final span = hi - lo;
    final unit = math
        .pow(10, (math.log(span / 2) / math.ln10).floor())
        .toDouble();
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final levels = <double>{
      for (final share in const [0.25, 0.75])
        ((lo + span * share) / unit).round() * unit,
    }.where((v) => v >= lo && v <= hi);
    for (final level in levels) {
      final y = yFor(level);
      _dashed(canvas, Offset(0, y), Offset(size.width, y), gridPaint);
      final label = _text(fmtMoneyCompact(level));
      label.paint(canvas, Offset(0, y - label.height - 1));
    }

    // Area and line.
    final path = Path()..moveTo(xFor(0), yFor(balances[0]));
    for (var i = 1; i < n; i++) {
      path.lineTo(xFor(i), yFor(balances[i]));
    }
    final area = Path.from(path)
      ..lineTo(xFor(n - 1), bottom)
      ..lineTo(xFor(0), bottom)
      ..close();
    canvas.drawPath(area, Paint()..color = line.withValues(alpha: 0.12));
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // The lowest day's ring.
    canvas.drawCircle(
      Offset(xFor(lowest), yFor(balances[lowest])),
      5,
      Paint()
        ..color = ring
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    // The chosen day: guide, dot with a white edge.
    final sx = xFor(selected);
    _dashed(
      canvas,
      Offset(sx, top),
      Offset(sx, bottom),
      Paint()
        ..color = guide
        ..strokeWidth = 1,
    );
    final dot = Offset(sx, yFor(balances[selected]));
    canvas.drawCircle(dot, 5.5, Paint()..color = edge);
    canvas.drawCircle(dot, 4, Paint()..color = line);

    // Day labels: first, chosen (bold) and last; an end label that would
    // touch the chosen one is left out.
    final labelY = bottom + 4;
    final chosen = _text(fmtDateCompact(dates[selected]), bold: true);
    final chosenX = (sx - chosen.width / 2)
        .clamp(0.0, math.max(0.0, size.width - chosen.width))
        .toDouble();
    chosen.paint(canvas, Offset(chosenX, labelY));
    if (selected != 0) {
      final first = _text(fmtDateCompact(dates[0]));
      if (first.width + 8 < chosenX) first.paint(canvas, Offset(0, labelY));
    }
    if (selected != n - 1) {
      final last = _text(fmtDateCompact(dates[n - 1]));
      final lastX = size.width - last.width;
      if (chosenX + chosen.width + 8 < lastX) {
        last.paint(canvas, Offset(lastX, labelY));
      }
    }
  }

  @override
  bool shouldRepaint(_BalanceLinePainter old) =>
      old.selected != selected ||
      old.lowest != lowest ||
      old.line != line ||
      old.guide != guide ||
      old.grid != grid ||
      old.ring != ring ||
      old.labelStyle != labelStyle ||
      old.textScaler != textScaler ||
      !_sameList(old.balances, balances);

  static bool _sameList(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A dashed line from [a] to [b], 3 on and 3 off.
void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
  final length = (b - a).distance;
  if (length <= 0) return;
  final dir = (b - a) / length;
  for (var d = 0.0; d < length; d += 6) {
    canvas.drawLine(a + dir * d, a + dir * math.min(d + 3, length), paint);
  }
}

/// What the 31 days add up to, and where the line starts.
class _Totals extends StatelessWidget {
  final ForwardSeries series;
  final double headline;
  final double waiting;
  final bool hideIncome;

  const _Totals({
    required this.series,
    required this.headline,
    required this.waiting,
    required this.hideIncome,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final subs = series.spendSubscriptions;
    final reminders = series.spendReminders;
    final income = series.income;
    final everyday = series.everyday;
    final allSalary = series.days
        .expand((d) => d.items)
        .where((i) => i.kind == ForwardKind.income)
        .every((i) => i.categoryId == 'salary');
    final incomeText = hideIncome ? kMaskedAmount : '+${fmtMoneyWhole(income)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Spending subscriptions', style: muted),
                  Text(
                    fmtMoneyWhole(subs + reminders),
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.error,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Savings subscriptions',
                    style: muted,
                    textAlign: TextAlign.end,
                  ),
                  Text(
                    fmtMoneyWhole(series.savings),
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (subs > 0 && reminders > 0) ...[
          const SizedBox(height: 4),
          Text(
            joinFacts([
              'Subscriptions ${fmtMoneyWhole(subs)}',
              'reminders ${fmtMoneyWhole(reminders)}',
            ]),
            style: muted,
          ),
        ],
        const SizedBox(height: 4),
        Text(
          joinFacts([
            'From ${fmtMoneyWhole(headline)} today',
            if (waiting > 0) 'waiting for review ${fmtMoneyWhole(-waiting)}',
            if (income > 0) '${allSalary ? 'salary' : 'income'} $incomeText',
            if (everyday > 0) 'everyday spending ${fmtMoneyWhole(-everyday)}',
          ]),
          style: muted,
        ),
      ],
    );
  }
}

/// The 31 days as a Monday-first calendar with a dot per kind of payment.
class _DayCalendar extends StatelessWidget {
  final _View view;
  final ValueChanged<int> onSelect;

  const _DayCalendar({required this.view, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final series = view.series;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    final lowest = series.days.indexOf(series.lowest);
    final lead = series.days.first.date.weekday - 1;
    final cells = lead + series.days.length;
    final rows = (cells / 7).ceil();
    const initials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

    Widget cell(int i) {
      final day = series.days[i];
      final kinds = {for (final it in day.items) it.kind};
      final label = day.date.day == 1
          ? fmtDateCompact(day.date)
          : '${day.date.day}';
      final content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: text.bodyMedium?.copyWith(
              fontWeight: i == 0 ? FontWeight.w700 : null,
            ),
          ),
          Container(
            margin: const EdgeInsets.only(top: 1),
            height: 2,
            width: 14,
            color: i == 0 ? scheme.primary : Colors.transparent,
          ),
          const SizedBox(height: 3),
          SizedBox(
            height: 5,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (kind, color) in [
                  (ForwardKind.spend, scheme.error),
                  (ForwardKind.income, colors.green),
                  (ForwardKind.savings, colors.blue),
                ])
                  if (kinds.contains(kind))
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
              ],
            ),
          ),
        ],
      );
      return Semantics(
        button: true,
        selected: i == view.selected,
        label: _dayLabel(series, i),
        excludeSemantics: true,
        // excludeSemantics drops the InkWell's own tap action too, so it is
        // exposed here for screen readers.
        onTap: () => onSelect(i),
        child: CustomPaint(
          foregroundPainter: i == lowest
              ? _DashedOutline(color: colors.orange, radius: 10)
              : null,
          child: Container(
            height: 48,
            margin: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: i == view.selected ? scheme.primary : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onSelect(i),
              child: Center(
                child: FittedBox(fit: BoxFit.scaleDown, child: content),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            for (final s in initials)
              Expanded(
                child: Center(
                  child: Text(
                    s,
                    style: text.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var r = 0; r < rows; r++)
          Row(
            children: [
              for (var c = 0; c < 7; c++)
                Expanded(
                  child: () {
                    final i = r * 7 + c - lead;
                    return i < 0 || i >= series.days.length
                        ? const SizedBox(height: 50)
                        : cell(i);
                  }(),
                ),
            ],
          ),
      ],
    );
  }
}

/// A dashed rounded outline, 3dp on and 3dp off.
class _DashedOutline extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedOutline({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final PathMetric m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 6) {
        canvas.drawPath(m.extractPath(d, math.min(d + 3, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutline old) =>
      old.color != color || old.radius != radius;
}

/// One row per day with payments, quiet runs merged into one muted line;
/// the chosen day's row is outlined.
class _DayRows extends StatelessWidget {
  final _View view;

  /// One per day. A merged run carries every key of its days, so each day
  /// scrolls to the row that shows it.
  final List<GlobalKey> rowKeys;

  const _DayRows({required this.view, required this.rowKeys});

  @override
  Widget build(BuildContext context) {
    final series = view.series;
    final days = series.days;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final lowest = days.indexOf(series.lowest);
    // Set from the list's width below. A row's trailing figure scales down
    // past this, so at large text it never pushes the row past the card.
    var figureMax = double.infinity;
    Widget figure(Text t) => ConstrainedBox(
      constraints: BoxConstraints(maxWidth: figureMax),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerEnd,
        child: t,
      ),
    );

    Widget frame(int from, int to, Widget child) {
      final chosen = view.selected >= from && view.selected <= to;
      Widget out = Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(
            color: chosen ? scheme.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: child,
      );
      for (var i = to; i >= from; i--) {
        if (i < rowKeys.length) out = KeyedSubtree(key: rowKeys[i], child: out);
      }
      return out;
    }

    Widget busy(int i) {
      final day = days[i];
      return frame(
        i,
        i,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _dayLabel(series, i),
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (i == lowest) ...[
                  Flexible(
                    child: Text(
                      'Lowest ${fmtMoneyWhole(day.balance)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(
                        color: _lowestColor(context, day.balance),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                figure(
                  Text(
                    fmtMoneyWhole(day.balance),
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _balanceColor(context, day.balance),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final item in day.items)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.bill.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium,
                      ),
                    ),
                    if (item.kind == ForwardKind.savings) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.of(context).blue),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Savings',
                          style: text.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    figure(
                      Text(
                        _signedText(item, view.hideIncome),
                        style: text.bodyMedium?.copyWith(
                          color: _signedColor(context, item),
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

    Widget quiet(int from, int to) {
      final label = from == to
          ? '${_dayLabel(series, from)} · nothing due'
          : '${_dayLabel(series, from)} to ${_dayLabel(series, to)} · '
                'nothing due';
      final balance = days[to].balance;
      return frame(
        from,
        to,
        Row(
          children: [
            Expanded(child: Text(label, style: muted)),
            const SizedBox(width: 8),
            figure(
              Text(
                fmtMoneyWhole(balance),
                style: muted?.copyWith(
                  color: balance < 0 ? scheme.error : null,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Inside the frame's 10dp padding and 1.5dp border on each side.
        figureMax = math.max(0, (constraints.maxWidth - 23) * 0.6);
        final children = <Widget>[];
        var i = 0;
        while (i < days.length) {
          if (days[i].items.isNotEmpty) {
            children.add(busy(i));
            i++;
            continue;
          }
          var j = i;
          while (j + 1 < days.length && days[j + 1].items.isEmpty) {
            j++;
          }
          children.add(quiet(i, j));
          i = j + 1;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
      },
    );
  }
}
