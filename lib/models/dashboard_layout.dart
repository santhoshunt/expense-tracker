/// The dashboard's pages, as the tab bar shows them.
enum DashboardPage { overview, trends, breakdown }

/// Every section the dashboard can reorder, hide or fold. A label that a
/// card also shows as its own heading matches it word for word: inside a
/// fold the card then drops its copy (DashboardFoldScope).
/// The page's fixed
/// top (banners, balance, month selector, stat cards) is not listed: it
/// always shows, in place.
enum DashboardSection {
  // Overview
  monthlyBudget(DashboardPage.overview, 'Monthly budget', true),
  recap(DashboardPage.overview, "Last month's recap", true),
  upcoming(DashboardPage.overview, 'Upcoming', true),
  budgets(DashboardPage.overview, 'Budgets', true),
  owed(DashboardPage.overview, 'Who owes you', true),
  // Trends
  pace(DashboardPage.trends, 'This month so far', true),
  previousMonth(DashboardPage.trends, 'This month vs last month', true),
  usual(DashboardPage.trends, 'This month vs usual', false),
  categoryComparison(DashboardPage.trends, 'Categories vs usual', false),
  sixMonths(DashboardPage.trends, 'Last 6 months', false),
  // Breakdown
  donut(DashboardPage.breakdown, 'Spending split', true),
  byCategory(DashboardPage.breakdown, 'By category', true),
  byTags(DashboardPage.breakdown, 'By tags', false),
  merchants(DashboardPage.breakdown, 'Top merchants', false),
  subscriptions(DashboardPage.breakdown, 'Subscriptions', false),
  groups(DashboardPage.breakdown, 'By group', false),
  heatmap(DashboardPage.breakdown, 'Spending heatmap', false),
  transfers(DashboardPage.breakdown, 'Transfers', false);

  const DashboardSection(this.page, this.label, this.openByDefault);

  final DashboardPage page;
  final String label;

  /// Trends and Breakdown open their first two sections, so each page fits
  /// about one screen until more are opened. Overview never folds.
  final bool openByDefault;

  /// [p]'s sections in their default order.
  static List<DashboardSection> of(DashboardPage p) => [
    for (final s in values)
      if (s.page == p) s,
  ];

  static DashboardSection? byName(Object? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// One page's section order and the sections hidden from it.
class DashboardPageLayout {
  final DashboardPage page;
  final List<DashboardSection> order;
  final Set<DashboardSection> hidden;

  const DashboardPageLayout({
    required this.page,
    required this.order,
    required this.hidden,
  });

  factory DashboardPageLayout.defaults(DashboardPage page) =>
      DashboardPageLayout(
        page: page,
        order: DashboardSection.of(page),
        hidden: const {},
      );

  Map<String, dynamic> toJson() => {
    'order': [for (final s in order) s.name],
    'hidden': [for (final s in hidden) s.name],
  };

  /// Tolerant: a wrongly-typed value reads as empty, unknown names and
  /// other pages' sections are dropped, a
  /// repeated name keeps its first place, and a section missing from the
  /// stored order (one a later release added) goes back in at its default
  /// place, after the default neighbour before it.
  factory DashboardPageLayout.fromJson(DashboardPage page, Object? json) {
    if (json is! Map) return DashboardPageLayout.defaults(page);
    final order = <DashboardSection>[];
    final storedOrder = json['order'];
    for (final name in storedOrder is List ? storedOrder : const []) {
      final s = DashboardSection.byName(name);
      if (s != null && s.page == page && !order.contains(s)) order.add(s);
    }
    final defaults = DashboardSection.of(page);
    for (var i = 0; i < defaults.length; i++) {
      final s = defaults[i];
      if (order.contains(s)) continue;
      // After the nearest earlier default section already placed.
      var at = 0;
      for (var j = i - 1; j >= 0; j--) {
        final k = order.indexOf(defaults[j]);
        if (k != -1) {
          at = k + 1;
          break;
        }
      }
      order.insert(at, s);
    }
    final storedHidden = json['hidden'];
    final hidden = <DashboardSection>{
      for (final name in storedHidden is List ? storedHidden : const [])
        if (DashboardSection.byName(name) case final s?)
          if (s.page == page) s,
    };
    return DashboardPageLayout(page: page, order: order, hidden: hidden);
  }
}
