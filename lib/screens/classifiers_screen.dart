import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:provider/provider.dart';

import '../models/import_rule.dart';
import '../models/transaction.dart';
import '../models/dashboard_layout.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/sms_parser.dart';
import '../services/subscriptions.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import '../utils/money_colors.dart';
import '../utils/search_text.dart';
import '../utils/text_scale.dart';
import '../widgets/animated_fold.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/dialog_expander.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/empty_state.dart';
import '../widgets/glossy.dart';
import '../widgets/grouped_surface.dart';
import '../widgets/info_tip.dart';
import '../widgets/keyboard_unfocus.dart';
import '../widgets/motion.dart';
import '../widgets/section_header.dart';
import '../widgets/budget_dialog.dart';
import '../widgets/reminder_editor_dialog.dart';
import '../widgets/undo_snackbar.dart';
import 'app_nav.dart';
import 'dashboard_layout_tab.dart';
import 'category_management.dart';
import 'cockpit_tabs.dart';

/// Cockpit tab ids, for callers that deep-link into a tab. Ids, not tab bar
/// indices: each [CockpitGroup] page numbers its own tabs from 0.
const int kCockpitTabRules = 0;
const int kCockpitTabImport = 1;
const int kCockpitTabTransactions = 2;
const int kCockpitTabCategories = 3;
const int kCockpitTabBudgets = 4;
const int kCockpitTabReminders = 5;
const int kCockpitTabSubscriptions = 6;
const int kCockpitTabTags = 7;
const int kCockpitTabDashOverview = 8;
const int kCockpitTabDashTrends = 9;
const int kCockpitTabDashBreakdown = 10;
const int kCockpitTabGroups = 11;

/// The Cockpit's groups, each one page holding the tabs in [tabs]
/// (kCockpitTab* ids, in tab order). Six tabs on one bar were too many to
/// scan, so the hub splits them by what they steer, as Settings does. The
/// value names are short ids and differ from the titles.
enum CockpitGroup {
  classify('Categories and rules', Icons.rule, [
    kCockpitTabRules,
    kCockpitTabCategories,
    kCockpitTabImport,
    kCockpitTabTransactions,
  ]),
  organise('Groups and tags', Icons.workspaces_outlined, [
    kCockpitTabGroups,
    kCockpitTabTags,
  ]),
  plan('Budgets and bills', Icons.track_changes, [
    kCockpitTabBudgets,
    kCockpitTabReminders,
    kCockpitTabSubscriptions,
  ]),
  dashboard('Dashboard layout', Icons.dashboard_customize_outlined, [
    kCockpitTabDashOverview,
    kCockpitTabDashTrends,
    kCockpitTabDashBreakdown,
  ]);

  const CockpitGroup(this.title, this.icon, this.tabs);

  final String title;
  final IconData icon;
  final List<int> tabs;

  /// The group whose page holds kCockpitTab* [tab].
  static CockpitGroup of(int tab) =>
      values.firstWhere((g) => g.tabs.contains(tab));
}

/// Tab bar labels by kCockpitTab* id. The Transactions tab reads "Results"
/// here: it sits beside Rules as the place to check what they did, and the
/// home screen already has a Transactions tab.
const Map<int, String> _kCockpitTabLabels = {
  kCockpitTabRules: 'Rules',
  kCockpitTabImport: 'Import',
  kCockpitTabTransactions: 'Results',
  kCockpitTabCategories: 'Categories',
  kCockpitTabGroups: 'Groups',
  kCockpitTabBudgets: 'Budgets',
  kCockpitTabReminders: 'Reminders',
  kCockpitTabSubscriptions: 'Subscriptions',
  kCockpitTabTags: 'Tags',
  kCockpitTabDashOverview: 'Overview',
  kCockpitTabDashTrends: 'Trends',
  kCockpitTabDashBreakdown: 'Breakdown',
};

/// The Cockpit: everything that steers the app — rules, import checks, the
/// ledger as a classification tool, categories, budgets and reminders.
/// (File and class keep the historical Classifiers name; only the
/// user-visible copy changed.)
///
/// Without [initialTab] it shows the hub of [CockpitGroup]s; with one it
/// opens straight on that tab's group page, the tab selected (deep links).
class ClassifiersScreen extends StatelessWidget {
  /// Which tab to open on — see the kCockpitTab* constants. Null: the hub.
  final int? initialTab;
  const ClassifiersScreen({super.key, this.initialTab});

  @override
  Widget build(BuildContext context) {
    final tab = initialTab;
    if (tab == null) return const _CockpitHub();
    return CockpitGroupPage(group: CockpitGroup.of(tab), initialTab: tab);
  }
}

/// Direction pairs (same pattern, opposite-direction categories) render as
/// ONE tile owned by the earlier rule: that rule's id maps to its twin,
/// which the Rules tab then skips.
Map<String, ClassifierRule> _pairSiblings(List<ClassifierRule> rules) {
  final siblingOf = <String, ClassifierRule>{};
  final absorbed = <String>{};
  for (final r in rules) {
    if (absorbed.contains(r.id) || siblingOf.containsKey(r.id)) continue;
    final s = directionSiblingOf(r, rules);
    if (s == null || absorbed.contains(s.id) || siblingOf.containsKey(s.id)) {
      continue;
    }
    siblingOf[r.id] = s;
    absorbed.add(s.id);
  }
  return siblingOf;
}

/// The Cockpit root: one card per [CockpitGroup], each with a live count so
/// the hub says what is inside before it is opened.
class _CockpitHub extends StatelessWidget {
  const _CockpitHub();

  /// "3 rules" with a non-breaking space (U+00A0) between the number and its
  /// noun, so a wrapped line never leaves a number at one line's end and its
  /// noun on the next.
  static String _count(int n, String one, String many) =>
      '$n\u{a0}${n == 1 ? one : many}';

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final cap = context.select<SettingsProvider, double>(
      (s) => s.monthlyBudget,
    );
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);
    // Limits this month's counted spending has passed: the custom budgets
    // and the monthly cap, which heads the Budgets tab.
    final over =
        finance.budgets
            .where(
              (b) => b.limit > 0 && finance.budgetSpentFor(b, month) > b.limit,
            )
            .length +
        (cap > 0 && finance.budgetSpentInMonth(month) > cap ? 1 : 0);
    // Your own rules as the Rules tab lists them: a direction pair is one
    // row, and the built-in rules are left out.
    final pairTwins = {
      for (final s in _pairSiblings(finance.rules).values) s.id,
    };
    final ownRules = finance.rules
        .where((r) => !r.isBuiltIn && !pairTwins.contains(r.id))
        .length;
    // What the Subscriptions tab lists as still charging. Selected by
    // content: the getter returns a fresh set on every call.
    context.select<SettingsProvider, String>(
      (s) => hiddenListKey(s.hiddenUpcoming),
    );
    final subscriptions = cachedSubscriptions(
      finance,
      context.read<SettingsProvider>().hiddenUpcoming,
    ).active.length;
    final hiddenSections = context.select<SettingsProvider, int>(
      (s) => s.hiddenSectionCount,
    );
    final counts = {
      // In the order of the group's name. Categories counts what the
      // Categories tab lists: your categories plus the built-ins.
      CockpitGroup.classify: [
        _count(
          customCategories.length + kCategories.length,
          'category',
          'categories',
        ),
        _count(ownRules, 'rule', 'rules'),
        _count(finance.importRules.length, 'import rule', 'import rules'),
      ],
      CockpitGroup.organise: [
        _count(finance.groups.length, 'group', 'groups'),
        _count(finance.allTags.length, 'tag', 'tags'),
      ],
      // A limit passed leads: it is the one thing here that needs acting on.
      CockpitGroup.plan: [
        // "1 budget over", the line's one warning, drawn in the error
        // colour below. Only the number and its noun are held together;
        // "over" may wrap.
        if (over > 0) '${_count(over, 'budget', 'budgets')} over',
        if (cap > 0) 'Monthly cap set',
        _count(finance.budgets.length, 'budget', 'budgets'),
        _count(finance.reminders.length, 'reminder', 'reminders'),
        _count(subscriptions, 'subscription', 'subscriptions'),
      ],
      CockpitGroup.dashboard: [
        hiddenSections > 0
            ? '$hiddenSections\u{a0}hidden'
            : 'All sections shown',
      ],
    };
    final scheme = Theme.of(context).colorScheme;
    final large = isLargeTextScale(context);

    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Cockpit')),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          // One grouped card: the rows touch, a hairline between them.
          children: [
            for (final (i, g) in CockpitGroup.values.indexed)
              GroupedSurface(
                first: i == 0,
                last: i == CockpitGroup.values.length - 1,
                child: ListTile(
                  // The counts wrap at large text; the icons stay level
                  // with the middle of each row.
                  titleAlignment: ListTileTitleAlignment.center,
                  // At large text the icon and chevron go, so the words get
                  // the row's width instead of breaking mid-word.
                  leading: large ? null : Icon(g.icon),
                  title: Text(g.title),
                  // The live counts say what is inside; the group's own
                  // gist repeated them in words. Muted like the Settings
                  // root's lines; only a passed limit takes a colour.
                  subtitle: Text.rich(
                    TextSpan(
                      children: [
                        for (final (j, part) in counts[g]!.indexed) ...[
                          // A no-break space before the dot: a line
                          // breaks after it, never starts with it.
                          if (j > 0) const TextSpan(text: ' · '),
                          TextSpan(
                            // Each fact whole, so "Monthly cap set" never
                            // leaves "set" alone on a line; the warning
                            // keeps its own rule ("over" may wrap).
                            text: g == CockpitGroup.plan && over > 0 && j == 0
                                ? part
                                : part.replaceAll(' ', ' '),
                            style: g == CockpitGroup.plan && over > 0 && j == 0
                                ? TextStyle(
                                    color: scheme.error,
                                    fontWeight: FontWeight.w500,
                                  )
                                : null,
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing: large ? null : const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CockpitGroupPage(group: g),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One Cockpit group on its own page: a tab bar over [group]'s tabs (none
/// for a single-tab group) and the add button of the tab showing.
class CockpitGroupPage extends StatefulWidget {
  final CockpitGroup group;

  /// The kCockpitTab* id to open on; null, or one outside [group], opens
  /// the first tab.
  final int? initialTab;

  const CockpitGroupPage({super.key, required this.group, this.initialTab});

  @override
  State<CockpitGroupPage> createState() => _CockpitGroupPageState();
}

class _CockpitGroupPageState extends State<CockpitGroupPage>
    with SingleTickerProviderStateMixin {
  /// Null on a single-tab group, which shows no tab bar.
  TabController? _tab;

  /// Whether the add button shows. Scrolling down slides it away so it
  /// covers none of the list; scrolling up or a tab change brings it back.
  /// Only a user scroll hides it, so a short list that cannot scroll always
  /// shows it.
  bool _fabShown = true;

  List<int> get _tabs => widget.group.tabs;

  /// The kCockpitTab* id showing.
  int get _current => _tabs[_tab?.index ?? 0];

  @override
  void initState() {
    super.initState();
    if (_tabs.length > 1) {
      final start = _tabs.indexOf(widget.initialTab ?? _tabs.first);
      _tab = TabController(
        length: _tabs.length,
        vsync: this,
        initialIndex: start < 0 ? 0 : start,
      )..addListener(() => setState(() => _fabShown = true));
    }
  }

  bool _onUserScroll(UserScrollNotification n) {
    // The TabBarView's own page swipes arrive here too, as horizontal
    // scrolls; only a list moving up or down steers the FAB.
    if (n.metrics.axis != Axis.vertical) return false;
    final show = switch (n.direction) {
      ScrollDirection.reverse => false,
      ScrollDirection.forward => true,
      ScrollDirection.idle => _fabShown,
    };
    if (show != _fabShown) setState(() => _fabShown = show);
    return false;
  }

  @override
  void dispose() {
    _tab?.dispose();
    super.dispose();
  }

  Widget _tabBody(int tab) => switch (tab) {
    kCockpitTabRules => _RulesTab(),
    kCockpitTabImport => _ImportTab(),
    kCockpitTabTransactions => _TransactionsTab(),
    kCockpitTabCategories => const CategoriesTab(),
    kCockpitTabGroups => const GroupsTab(),
    kCockpitTabBudgets => const BudgetsTab(),
    kCockpitTabSubscriptions => const SubscriptionsTab(),
    kCockpitTabTags => const TagsTab(),
    kCockpitTabDashOverview => const DashboardLayoutTab(
      page: DashboardPage.overview,
    ),
    kCockpitTabDashTrends => const DashboardLayoutTab(
      page: DashboardPage.trends,
    ),
    kCockpitTabDashBreakdown => const DashboardLayoutTab(
      page: DashboardPage.breakdown,
    ),
    _ => const RemindersTab(),
  };

  @override
  Widget build(BuildContext context) {
    final tab = _tab;
    // One add button per tab with an add flow, always with its label.
    final Widget? fab = switch (_current) {
      kCockpitTabRules => GlassButton(
        icon: Icons.add,
        label: 'New rule',
        onPressed: () => showRuleDialog(context),
      ),
      kCockpitTabImport => GlassButton(
        icon: Icons.add,
        label: 'New import rule',
        onPressed: () => _showImportRuleDialog(context),
      ),
      kCockpitTabCategories => GlassButton(
        icon: Icons.add,
        label: 'New category',
        onPressed: () => showCategoryDialog(context),
      ),
      kCockpitTabGroups => GlassButton(
        icon: Icons.add,
        label: 'New group',
        onPressed: () => showGroupDialog(context),
      ),
      kCockpitTabBudgets => GlassButton(
        icon: Icons.add,
        label: 'New budget',
        onPressed: () => showBudgetDialog(context),
      ),
      kCockpitTabReminders => GlassButton(
        icon: Icons.add,
        label: 'New reminder',
        onPressed: () => showReminderEditor(context),
      ),
      _ => null,
    };
    final fabMotion = motionDuration(
      context,
      const Duration(milliseconds: 200),
    );
    final scrollTabs = MediaQuery.textScalerOf(context).scale(1) > 1;
    return CockpitScope(
      controller: tab,
      tabs: _tabs,
      child: AmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: Text(widget.group.title),
            // At the default text size up to four short labels fit the
            // width, so the bar is fixed rather than scrolling.
            bottom: tab == null
                ? null
                : TabBar(
                    controller: tab,
                    // Half the default inset on every group page, so four
                    // tabs at 360dp keep "Categories" whole.
                    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                    // Any text larger than the default: the labels scroll
                    // whole. Four tabs at 360dp leave "Categories" no room
                    // to grow, so even Android's 1.15 step cuts it short
                    // in fixed quarters.
                    isScrollable: scrollTabs,
                    tabAlignment: scrollTabs ? TabAlignment.start : null,
                    tabs: [
                      for (final t in _tabs) Tab(text: _kCockpitTabLabels[t]),
                    ],
                  ),
          ),
          // Slides down and fades while hidden; hidden, it takes no taps
          // and leaves the semantics tree.
          floatingActionButton: fab == null
              ? null
              : AnimatedSlide(
                  offset: _fabShown ? Offset.zero : const Offset(0, 2),
                  duration: fabMotion,
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _fabShown ? 1 : 0,
                    duration: fabMotion,
                    child: IgnorePointer(
                      ignoring: !_fabShown,
                      child: ExcludeSemantics(
                        excluding: !_fabShown,
                        child: fab,
                      ),
                    ),
                  ),
                ),
          body: NotificationListener<UserScrollNotification>(
            onNotification: _onUserScroll,
            child: tab == null
                ? _tabBody(_tabs.single)
                : TabBarView(
                    controller: tab,
                    children: [for (final t in _tabs) _tabBody(t)],
                  ),
          ),
        ),
      ),
    );
  }
}

// ── Rules tab ────────────────────────────────────────────────────────────────

/// Whether [rule] should show for a search [query] (already lowercased and
/// trimmed; empty matches everything). Matches every OR-condition — not just
/// the one the tile headline shows — and the target category's label ('Spam'
/// for spam rules, which have no category to look up).
@visibleForTesting
bool ruleMatchesQuery(ClassifierRule rule, String query) {
  if (query.isEmpty) return true;
  if (rule.patterns.any((p) => p.toLowerCase().contains(query))) return true;
  final label = rule.isSpamRule ? 'Spam' : categoryById(rule.categoryId).label;
  return label.toLowerCase().contains(query);
}

class _RulesTab extends StatefulWidget {
  @override
  State<_RulesTab> createState() => _RulesTabState();
}

class _RulesTabState extends State<_RulesTab> {
  final _searchCtrl = TextEditingController();
  // No debounce: unlike the ledger searches, this filters a few dozen rules.
  String _search = '';

  /// Ids of rules picked in multi-select mode; non-empty = selecting.
  /// (Transactions-screen idiom.)
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  /// Whether the built-in rules show under their fold row. Folded on each
  /// visit and never stored; a search shows matching built-ins anyway.
  bool _builtinOpen = false;

  void _toggleBuiltins() => setState(() => _builtinOpen = !_builtinOpen);

  /// Puts every built-in rule back as it first was, with Undo. Past rows
  /// are not re-sorted here: the next rule add, edit or merge does that,
  /// and an Undo could not take a re-sort back.
  Future<void> _confirmRestoreBuiltins() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore built-in rules?'),
        content: const Text(
          'Deleted or edited built-in rules come back as they first were. '
          'Rules you created yourself are kept. Past transactions are sorted '
          'again the next time you add, edit or merge a rule.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final finance = context.read<FinanceProvider>();
    final messenger = ScaffoldMessenger.of(context);
    // The whole list, not only the built-ins: restoreRules puts back the
    // exact order, priorities included, and leaves past rows as they are.
    final before = List.of(finance.rules);
    final n = await finance.restoreDefaultRules();
    if (n > 0) {
      showUndoSnackBarOn(
        messenger,
        'Restored $n built-in rule${n == 1 ? '' : 's'}',
        () => finance.restoreRules(before, reapply: false),
        icon: Icons.settings_backup_restore,
      );
    } else {
      showAppToastOn(
        messenger,
        'Built-in rules are as they first were',
        tone: AppToastTone.info,
        icon: Icons.settings_backup_restore,
      );
    }
  }

  /// Ends the list, even with no built-in rule left, and sits under the
  /// empty state when every rule is gone.
  Widget _restoreBuiltinsButton({bool centered = false}) => Padding(
    // The list's 16dp gutter and a flush button: the icon starts on the
    // rows' icon column.
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Align(
      alignment: centered ? Alignment.center : Alignment.centerLeft,
      child: TextButton.icon(
        style: flushTextButtonStyle,
        icon: const Icon(Icons.settings_backup_restore),
        label: const Text('Restore built-in rules'),
        onPressed: _confirmRestoreBuiltins,
      ),
    ),
  );

  /// Merge is only meaningful within one category: the matcher's type gate
  /// skips mismatched rules anyway, so a cross-category merge would change
  /// what the absorbed rules do.
  bool _canMerge(List<ClassifierRule> rules) {
    if (_selected.length < 2) return false;
    final cats = {
      for (final r in rules)
        if (_selected.contains(r.id)) r.categoryId,
    };
    return cats.length == 1;
  }

  Future<void> _mergeSelected(FinanceProvider finance) async {
    // Snapshot BEFORE the merge — undo puts back the exact list, priorities
    // included (per-rule restore would be order-dependent).
    final before = List.of(finance.rules);
    final n = _selected.length;
    final messenger = ScaffoldMessenger.of(context);
    final applied = await finance.mergeRules(Set.of(_selected));
    if (!mounted) return;
    setState(_selected.clear);
    final parts = <String>[
      'Merged $n rules',
      if (applied.reclassified > 0)
        '${applied.reclassified} transaction'
            '${applied.reclassified == 1 ? '' : 's'} reclassified',
      // Recent: rows waiting for review and rows still marked new, which
      // already count.
      if (applied.droppedPending > 0)
        '${applied.droppedPending} recent import'
            '${applied.droppedPending == 1 ? '' : 's'} dropped as spam',
    ];
    showAppToastOn(
      messenger,
      parts.join(' · '),
      tone: AppToastTone.change,
      icon: Icons.call_merge,
      duration: const Duration(seconds: 5),
      actionLabel: 'Undo',
      onAction: () {
        finance.restoreRules(before);
        if (applied.dropped.isNotEmpty) {
          finance.restoreEditedTransactions(
            applied.dropped,
            reAddMissing: true,
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rules = context.watch<FinanceProvider>().rules;
    if (rules.isEmpty) {
      // Scrollable so the three paragraphs and the button survive a short
      // viewport or a large font scale.
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              EmptyState(
                icon: Icons.rule,
                message:
                    'No rules yet.\n\nRules categorise SMS imports '
                    'automatically, e.g. if the message contains "Starbucks" '
                    '→ Food & Dining.\n\n'
                    'A rule with the Spam category drops matching messages '
                    'entirely. They are never imported.',
                // Same words as the floating button on this tab.
                actionLabel: 'New rule',
                onAction: () => showRuleDialog(context),
              ),
              _restoreBuiltinsButton(centered: true),
            ],
          ),
        ),
      );
    }

    final q = _search.trim().toLowerCase();
    // Resolved over the full list so a search hit on either member keeps
    // the pair.
    final siblingOf = _pairSiblings(rules);
    final absorbed = {for (final s in siblingOf.values) s.id};
    bool shows(ClassifierRule r) =>
        ruleMatchesQuery(r, q) ||
        (siblingOf[r.id] != null && ruleMatchesQuery(siblingOf[r.id]!, q));
    final visible = rules
        .where((r) => !absorbed.contains(r.id) && shows(r))
        .toList();
    final userRules = visible.where((r) => !r.isBuiltIn).toList();
    final builtinRules = visible.where((r) => r.isBuiltIn).toList();
    // A search shows the matching built-ins whatever the fold.
    final builtinsShown = _builtinOpen || q.isNotEmpty;

    // Drop selections that no longer exist, were re-filtered away or sit
    // in the closed fold, so the bar count never lies (transactions-screen
    // idiom). Only rendered tiles count; a twin under a tile of your own
    // stays selected with its owner, so a merge never splits a pair.
    if (_selected.isNotEmpty) {
      final visibleIds = {
        for (final r in userRules) ...[r.id, ?siblingOf[r.id]?.id],
        if (builtinsShown)
          for (final r in builtinRules) ...[r.id, ?siblingOf[r.id]?.id],
      };
      _selected.removeWhere((id) => !visibleIds.contains(id));
    }

    // The ordering tip rides on the Your rules header, which shows even
    // with no rules of your own unless a search filtered them away.
    Widget orderHeader(String label) => _TipHeader(
      label: label,
      tip: InfoTip(
        title: label,
        message:
            'Rules are checked top to bottom, and the first match wins. '
            'Your rules always come before built-in ones, and a new rule '
            'goes to the top. Long-press rules to select them; rules with '
            'the same category can be merged.',
        link: const InfoLink(
          prompt: 'Want to check the results?',
          label: 'See classified transactions',
          onTap: goCockpitTransactions,
        ),
      ),
    );

    Widget tile(ClassifierRule r) {
      final sibling = siblingOf[r.id];
      return _RuleTile(
        // Keyed by rule: a search hands this slot another rule, whose tint
        // must not ease over from the previous one's.
        key: ValueKey(r.id),
        rule: r,
        sibling: sibling,
        selectionMode: _selecting,
        selected: _selected.contains(r.id),
        // A pair selects as one unit (both ids), so the count stays honest
        // and a merge can never split a pair.
        onToggleSelect: () {
          // Only a long-press can reach here with nothing selected, so this
          // ticks exactly when selection mode starts.
          setState(() {
            final ids = {r.id, ?sibling?.id};
            if (_selected.contains(r.id)) {
              _selected.removeAll(ids);
            } else {
              _selected.addAll(ids);
            }
          });
        },
      );
    }

    final scheme = Theme.of(context).colorScheme;
    // Flat item list keeps the whole thing lazily built. Filtering happens
    // before the section split, so a search that empties a section drops
    // its header.
    final items = <Widget>[
      if (userRules.isNotEmpty || q.isEmpty) orderHeader('Your rules'),
      ...userRules.map(tile),
      if (userRules.isEmpty && q.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            'No rules of your own yet.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      if (builtinRules.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: FrostedPanel(
            radius: BorderRadius.circular(AppRadius.card),
            // TalkBack says whether the fold is open. Merged, so the state
            // sits on the tile's own node rather than one above it.
            child: MergeSemantics(
              child: Semantics(
                button: true,
                expanded: builtinsShown,
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.format_list_bulleted, size: 20),
                  ),
                  title: Text('Built-in rules · ${builtinRules.length}'),
                  subtitle: const Text(
                    'Common words such as restaurant, petrol and pharmacy. '
                    'Checked after yours.',
                  ),
                  trailing: AnimatedRotation(
                    turns: builtinsShown ? 0 : 0.5,
                    duration: motionDuration(
                      context,
                      const Duration(milliseconds: 200),
                    ),
                    child: const Icon(Icons.expand_less),
                  ),
                  onTap: _toggleBuiltins,
                ),
              ),
            ),
          ),
        ),
      if (builtinsShown) ...builtinRules.map(tile),
      _restoreBuiltinsButton(),
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          // Rebuild on every controller change so the ✕ appears with the
          // first keystroke, not a rebuild late (same fix as the ledger
          // search).
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchCtrl,
            builder: (context, value, _) => TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search patterns and categories',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                        },
                      ),
              ),
            ),
          ),
        ),
        if (_selecting)
          _RuleSelectionBar(
            count: _selected.length,
            canMerge: _canMerge(visible),
            onMerge: () => _mergeSelected(context.read<FinanceProvider>()),
            onClose: () => setState(_selected.clear),
          ),
        Expanded(
          // The list always holds the Restore button, so an empty search
          // is told by its two sections.
          child: q.isNotEmpty && userRules.isEmpty && builtinRules.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Nothing matches your search.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 120),
                  itemCount: items.length,
                  itemBuilder: (context, i) => items[i],
                ),
        ),
      ],
    );
  }
}

/// Contextual bar shown while rules are multi-selected: count + one action,
/// merge. Merge stays disabled until the selection is 2+ rules of one
/// category (a cross-category merge would change what the rules do).
class _RuleSelectionBar extends StatelessWidget {
  final int count;
  final bool canMerge;
  final VoidCallback onMerge;
  final VoidCallback onClose;

  const _RuleSelectionBar({
    required this.count,
    required this.canMerge,
    required this.onMerge,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
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
                  color: accentTextColor(context),
                ),
              ),
              const Spacer(),
              // Tooltip on the wrapper, not the button: a disabled
              // IconButton doesn't show its own tooltip, and the "why is
              // this disabled" case is exactly when guidance is needed.
              Tooltip(
                message: canMerge
                    ? 'Merge into one rule (conditions OR-chained)'
                    : 'Select 2+ rules with the same category to merge',
                child: TextButton.icon(
                  icon: const Icon(Icons.merge_type, size: 20),
                  label: const Text('Merge'),
                  onPressed: canMerge ? onMerge : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An [UppercaseSectionHeader] followed by an [InfoTip], keeping the plain
/// header's left inset and close to its height.
class _TipHeader extends StatelessWidget {
  final String label;
  final InfoTip tip;
  const _TipHeader({required this.label, required this.tip});

  @override
  Widget build(BuildContext context) => Padding(
    // The plain header's 20/6 vertical inset, less the 4dp the tip label
    // adds above and below the text.
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 2),
    // Left-aligned: stretched across the row, the whole width would open
    // the tip.
    child: Align(
      alignment: Alignment.centerLeft,
      child: InfoLabel(
        label: UppercaseSectionHeader(label, padding: EdgeInsets.zero),
        tip: tip,
      ),
    ),
  );
}

class _RuleTile extends StatelessWidget {
  final ClassifierRule rule;

  /// The opposite-direction twin (see [directionSiblingOf]); the tile then
  /// reads as one rule pair and edits/deletes both.
  final ClassifierRule? sibling;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggleSelect;

  const _RuleTile({
    super.key,
    required this.rule,
    this.sibling,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelect,
  });

  /// "↑ Food & Dining (expense)" / "↓ Salary (income)".
  static String _arrowLabel(TxCategory c) =>
      '${c.type == TxType.income ? '↓' : '↑'} ${c.label} '
      '(${c.type == TxType.income ? 'income' : 'expense'})';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSpam = rule.isSpamRule;
    final cat = isSpam ? null : categoryById(rule.categoryId);
    final sib = sibling;
    final sibCat = sib == null ? null : categoryById(sib.categoryId);
    final selectMotion = motionDuration(
      context,
      const Duration(milliseconds: 160),
    );

    return ListTile(
      onTap: selectionMode
          ? onToggleSelect
          : () => showRuleDialog(context, existing: rule, sibling: sib),
      onLongPress: onToggleSelect,
      selected: selected,
      selectedColor: accentTextColor(context),
      // The avatar flips to a check when picked (TransactionTile precedent —
      // clearer than a checkbox column that reflows the whole list). Same
      // motion as the transaction tile: the fill eases over and the glyphs
      // swap with a small pop. An AnimatedContainer rather than a
      // CircleAvatar, whose built-in fade ignores Remove animations.
      leading: AnimatedContainer(
        duration: selectMotion,
        curve: Curves.easeOutCubic,
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected
              ? scheme.primary.withValues(alpha: 0.18)
              : isSpam
              ? scheme.error.withValues(alpha: 0.12)
              : cat!.color.withValues(alpha: 0.15),
        ),
        child: AnimatedSwitcher(
          duration: selectMotion,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: 0.6, end: 1.0).animate(animation),
              child: child,
            ),
          ),
          // A pair shows its own (primary) rule's category like any rule;
          // the subtitle names both directions.
          child: selected
              ? Icon(
                  Icons.check,
                  key: const ValueKey(true),
                  color: scheme.primary,
                  size: 20,
                )
              : Icon(
                  isSpam ? Icons.block : cat!.icon,
                  key: const ValueKey(false),
                  color: isSpam
                      ? scheme.error
                      : categoryGlyphColor(context, cat!.color),
                  size: 20,
                ),
        ),
      ),
      // Patterns pre-filled from an SMS body can be whole sentences — cap
      // the row height instead of letting one rule blow out the list. With
      // several OR-conditions, an explicit count beats an ellipsis that
      // hides conditions 3+ without a trace.
      title: Text(
        rule.patterns.length > 1
            ? 'contains "${rule.patterns.first}"'
            : 'contains ${rule.patterns.map((p) => '"$p"').join()}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (rule.patterns.length > 1)
            'or ${rule.patterns.length - 1} more condition'
                '${rule.patterns.length == 2 ? '' : 's'}',
          if (isSpam)
            'Spam, never imported'
          else if (sibCat != null)
            // Expense side first, whichever rule owns the tile.
            [
              for (final c in [cat!, sibCat])
                if (c.type == TxType.expense) _arrowLabel(c),
              for (final c in [cat, sibCat])
                if (c.type == TxType.income) _arrowLabel(c),
            ].join(' · ')
          else
            '→ ${cat!.label} '
                '(${cat.type == TxType.income ? 'income' : 'expense'})',
        ].join(' · '),
      ),
      // Tap edits, and Delete lives in the editor. No chevron while
      // selecting, where a tap ticks the row, or at large text, where the
      // words need the width.
      trailing: selectionMode || isLargeTextScale(context)
          ? null
          : Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
    );
  }
}

/// Deletes [rule] and its twin [sib] at once, with Undo. The toast shows
/// first: the delete rebuilds the list, which unmounts the row whose
/// [context] this is.
void _deleteRuleWithUndo(
  BuildContext context,
  ClassifierRule rule,
  ClassifierRule? sib,
) {
  final finance = context.read<FinanceProvider>();
  // Position = match priority; Undo must put each back where it was.
  // Indexes are captured before either delete and restored lowest-first so
  // the second insert lands right.
  final all = finance.rules;
  final index = all.indexWhere((r) => r.id == rule.id);
  final sibIndex = sib == null ? -1 : all.indexWhere((r) => r.id == sib.id);
  // patterns.first, not the raw stored string: the '|' encoding is an
  // implementation detail users never typed.
  showUndoSnackBar(
    context,
    'Deleted rule${sib == null ? '' : ' pair'} '
    '"${rule.patterns.firstOrNull ?? rule.pattern}"'
    '${rule.patterns.length > 1 ? ' (+${rule.patterns.length - 1})' : ''}',
    () {
      if (sib == null) {
        finance.restoreRule(rule, index);
      } else if (sibIndex < index) {
        finance.restoreRule(sib, sibIndex);
        finance.restoreRule(rule, index);
      } else {
        finance.restoreRule(rule, index);
        finance.restoreRule(sib, sibIndex);
      }
    },
    icon: Icons.delete_outline,
    tone: AppToastTone.removal,
  );
  finance.deleteRule(rule.id);
  if (sib != null) finance.deleteRule(sib.id);
}

// ── Import tab ───────────────────────────────────────────────────────────────

/// Shows every criterion the SMS importer applies: the fixed structural
/// checks (read-only) and the editable ignore/spam-signal rules, led by the
/// message tester.
class _ImportTab extends StatefulWidget {
  @override
  State<_ImportTab> createState() => _ImportTabState();
}

class _ImportTabState extends State<_ImportTab> {
  /// Whether the core checks show under their fold row. Folded on each
  /// visit and never stored.
  bool _checksOpen = false;

  @override
  Widget build(BuildContext context) {
    final rules = context.watch<FinanceProvider>().importRules;
    final ignoreRules = rules
        .where((r) => r.kind == ImportRuleKind.ignore)
        .toList();
    final spamRules = rules
        .where((r) => r.kind == ImportRuleKind.spamSignal)
        .toList();

    Widget header(String label) => UppercaseSectionHeader(label);

    final items = <Widget>[
      const _TestMessageCard(),
      _CoreChecksCard(
        open: _checksOpen,
        onToggle: () => setState(() => _checksOpen = !_checksOpen),
      ),
      header('Ignored when containing'),
      if (ignoreRules.isEmpty)
        const EmptyState(
          compact: true,
          icon: Icons.filter_alt_off_outlined,
          message: 'No ignore rules. Every bank alert imports.',
        ),
      ...ignoreRules.map((r) => _ImportRuleTile(rule: r)),
      const _TipHeader(
        label: 'Flagged as spam when containing',
        tip: InfoTip(
          title: 'Flagged as spam when containing',
          message:
              'Flagged messages are still imported, but held in the '
              'suspected spam queue for review. If one of your own rules '
              'matches a message when it is imported, the flag is cleared.',
          link: InfoLink(
            prompt: 'Something flagged by mistake?',
            label: 'Review suspected spam',
            onTap: goReview,
          ),
        ),
      ),
      if (spamRules.isEmpty)
        const EmptyState(
          compact: true,
          icon: Icons.report_off_outlined,
          message: 'No spam signals. Nothing gets flagged for review.',
        ),
      ...spamRules.map((r) => _ImportRuleTile(rule: r)),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.settings_backup_restore),
            label: const Text('Restore defaults'),
            onPressed: () => _confirmRestoreDefaults(context),
          ),
        ),
      ),
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 120),
      itemCount: items.length,
      itemBuilder: (context, i) => items[i],
    );
  }

  Future<void> _confirmRestoreDefaults(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore default criteria?'),
        content: const Text(
          'Deleted or edited built-in ignore phrases and spam signals are '
          'reset to their defaults. Rules you created yourself are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<FinanceProvider>().restoreDefaultImportRules();
    }
  }
}

/// The Import tab's first card: opens the message tester, which shows what
/// import would do with a pasted SMS.
class _TestMessageCard extends StatelessWidget {
  const _TestMessageCard();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: FrostedPanel(
        radius: BorderRadius.circular(AppRadius.card),
        child: ListTile(
          leading: const CircleAvatar(
            child: Icon(Icons.science_outlined, size: 20),
          ),
          // Left-aligned in the title slot: stretched, the whole width
          // would open the tip.
          title: const Align(
            alignment: Alignment.centerLeft,
            child: InfoLabel(
              icon: true,
              label: Text('Test a message'),
              tip: InfoTip(
                title: 'Test a message',
                message:
                    'Shows what the parser does with the pasted text. It is '
                    'more lenient about senders than the real inbox scan and '
                    'does not check for duplicates, so a real import can '
                    'still skip the message.',
              ),
            ),
          ),
          subtitle: const Text('Paste a bank SMS to see what import would do'),
          trailing: OutlinedButton(
            onPressed: () => _showTestMessageDialog(context),
            child: const Text('Test'),
          ),
          onTap: () => _showTestMessageDialog(context),
        ),
      ),
    );
  }
}

/// The structural criteria that are code, not data, shown so the whole
/// import decision is visible in one place. Folded to its header row until
/// [onToggle] opens it.
class _CoreChecksCard extends StatelessWidget {
  final bool open;
  final VoidCallback onToggle;

  const _CoreChecksCard({required this.open, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget check(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FrostedPanel(
        radius: BorderRadius.circular(AppRadius.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // TalkBack says whether the fold is open. Merged, so the state
            // sits on the tile's own node rather than one above it.
            MergeSemantics(
              child: Semantics(
                button: true,
                expanded: open,
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.fact_check_outlined, size: 20),
                  ),
                  title: const Text('Core checks · 4'),
                  subtitle: const Text(
                    'Always applied: sender, amount, debit or credit word',
                  ),
                  trailing: AnimatedRotation(
                    turns: open ? 0 : 0.5,
                    duration: motionDuration(
                      context,
                      const Duration(milliseconds: 200),
                    ),
                    child: const Icon(Icons.expand_less),
                  ),
                  onTap: onToggle,
                ),
              ),
            ),
            AnimatedFold(
              collapsed: !open,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.card,
                  0,
                  AppSpace.card,
                  AppSpace.card,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    check(
                      Icons.account_balance,
                      'Sender must look like a bank or payment app '
                      '(DLT ids like VM-HDFCBK, or brand names for '
                      'notification-captured alerts).',
                    ),
                    check(
                      Icons.currency_rupee,
                      'The message must state an amount in Rs, INR or ₹.',
                    ),
                    check(
                      Icons.swap_vert,
                      'It must contain a debit verb (debited, spent, paid…) or a '
                      'credit verb (credited, received…).',
                    ),
                    check(
                      Icons.credit_card,
                      'Credit-card bill payments import on both sides: the bank '
                      'debit as a "Card bill" expense, the card confirmation as a '
                      '"Card payment" income. The two cancel out.',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Changes below apply to future scans. To re-evaluate old '
                      'messages, run Import from SMS with a date range.',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportRuleTile extends StatelessWidget {
  final ImportRule rule;
  const _ImportRuleTile({required this.rule});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isIgnore = rule.kind == ImportRuleKind.ignore;
    final color = isIgnore ? scheme.error : AppColors.of(context).orange;

    return ListTile(
      onTap: () => _showImportRuleDialog(context, existing: rule),
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(
          isIgnore ? Icons.block : Icons.flag_outlined,
          color: color,
          size: 20,
        ),
      ),
      title: Text(
        'contains "${rule.pattern}"',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        isIgnore
            ? 'Ignored, never imported'
            : 'Flagged for individual review, still imported',
      ),
      // Tap edits, and Delete lives in the editor.
      trailing: isLargeTextScale(context)
          ? null
          : Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
    );
  }
}

/// Deletes [rule] with Undo. The toast shows first: the delete rebuilds
/// the list, which unmounts the row whose [context] this is.
void _deleteImportRuleWithUndo(BuildContext context, ImportRule rule) {
  final finance = context.read<FinanceProvider>();
  final index = finance.importRules.indexWhere((r) => r.id == rule.id);
  showUndoSnackBar(
    context,
    'Deleted rule "${rule.pattern}"',
    () => finance.restoreImportRule(rule, index),
    icon: Icons.delete_outline,
    tone: AppToastTone.removal,
  );
  finance.deleteImportRule(rule.id);
}

// ── Transactions tab ─────────────────────────────────────────────────────────

class _TransactionsTab extends StatefulWidget {
  @override
  State<_TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<_TransactionsTab> {
  String _search = '';
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  /// The row just recategorised. It shows "Make rule" until another row is
  /// moved, the rule is made, or the move is undone: the toast has room for
  /// Undo only.
  String? _ruleOfferId;

  /// Moves [before] to [categoryId], with Undo. Runs here, not in the row:
  /// a search filter can unmount the row while the picker is open.
  Future<void> _recategorise(Tx before, String categoryId) async {
    if (categoryId == before.categoryId) return;
    final finance = context.read<FinanceProvider>();
    // Reclassifying also rewrites tx.type: the category's own type is
    // authoritative, which keeps transfer categories (either direction)
    // consistent with the app-wide `tx.type == category.type` invariant.
    final c = categoryById(categoryId);
    await finance.updateTransaction(
      before.copyWith(categoryId: c.id, type: c.type),
    );
    if (!mounted) return;
    setState(() => _ruleOfferId = before.id);
    showUndoSnackBar(context, 'Moved to ${c.label}', () {
      // The snapshot also restores the row's earlier "set by hand" flag.
      finance.restoreEditedTransactions([before]);
      if (mounted && _ruleOfferId == before.id) {
        setState(() => _ruleOfferId = null);
      }
    }, icon: Icons.category_outlined);
  }

  /// Opens the rule dialog from the row's message, set to its new category.
  Future<void> _makeRule(Tx tx) {
    setState(() => _ruleOfferId = null);
    return showRuleDialog(
      context,
      patternSuggestion: _rulePatternFor(tx),
      categorySuggestion: tx.categoryId,
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Filtering re-runs over the whole ledger, so wait for a pause in typing
  /// rather than doing it per keystroke.
  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _search = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final all = finance.transactions;
    // The ledger search's matching: the note, payee, SMS, sender, category,
    // account, merchant and its alias, tags, people on a split, the payer
    // of a repayment and the amount.
    final q = normalizeSearchText(_search);
    final txs = q.isEmpty
        ? all
        : all
              .where(
                (t) => searchHaystack(
                  t,
                  accountName: finance.accountForKey(t.acctKey)?.displayName,
                  merchantAlias: finance.merchantAliasFor(t),
                ).contains(q),
              )
              .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Search transactions',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchDebounce?.cancel();
                        _searchCtrl.clear();
                        setState(() => _search = '');
                      },
                    ),
            ),
          ),
        ),
        // The long-press gesture is this tab's whole point and nothing else
        // hints at it — the FAB is hidden here and both gestures are
        // otherwise unlabelled.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          // The icon, not a dotted label: the label is a whole instruction
          // sentence.
          child: InfoLabel(
            icon: true,
            label: Text(
              'Tap to recategorise · long-press to make a rule from a message.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            tip: const InfoTip(
              title: 'Tap to recategorise',
              message:
                  'Picking a category also switches the row to that '
                  "category's direction and marks it as set by hand, so "
                  'rules will not change it again.',
              link: InfoLink(
                prompt: 'Transactions not classified right?',
                label: 'Set up transaction rules',
                onTap: goCockpitRules,
              ),
            ),
          ),
        ),
        Expanded(
          child: txs.isEmpty
              ? Center(
                  child: SingleChildScrollView(
                    child: all.isEmpty
                        ? const EmptyState(
                            icon: Icons.receipt_long_outlined,
                            message: 'No confirmed transactions yet.',
                          )
                        : const EmptyState(
                            icon: Icons.search_off,
                            message: 'Nothing matches your search.',
                          ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
                  itemCount: txs.length,
                  itemBuilder: (context, i) => _ClassificationTile(
                    tx: txs[i],
                    named: finance.rowTitleFor(txs[i]),
                    offerRule: txs[i].id == _ruleOfferId,
                    onPicked: _recategorise,
                    onMakeRule: _makeRule,
                  ),
                ),
        ),
      ],
    );
  }
}

/// The pattern a rule made from [tx] starts with: the first line of its SMS
/// (or of the note, for manual rows), since rules match against the SMS
/// text. '|' is the stored OR separator, so a prefill carrying one (common
/// in UPI alerts) would open the dialog already in its error state; it is
/// cut at the pipe, and the fragment before it is still a valid substring.
String _rulePatternFor(Tx tx) =>
    tx.smsText.split('\n').first.split('|').first.trim();

/// One Results row: the merchant first, as the ledger names it, then the
/// category and date under it.
class _ClassificationTile extends StatelessWidget {
  final Tx tx;

  /// What the row leads with ([FinanceProvider.rowTitleFor]); null when
  /// the row names no merchant, payee or note, and its category leads.
  final String? named;

  /// Shows "Make rule" under the row: it was just recategorised.
  final bool offerRule;
  final Future<void> Function(Tx before, String categoryId) onPicked;
  final Future<void> Function(Tx tx) onMakeRule;

  const _ClassificationTile({
    required this.tx,
    required this.named,
    required this.offerRule,
    required this.onPicked,
    required this.onMakeRule,
  });

  @override
  Widget build(BuildContext context) {
    final cat = tx.category;
    final isIncome = tx.type == TxType.income;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // Green in, red out, plain for a transfer: the Transactions rows' rule.
    final amountColor = moneyColor(
      context,
      type: tx.type,
      transfer: cat.isTransfer,
    );

    // The merchant, not the raw SMS, as the ledger reads; the category,
    // which a tap changes, leads the line under it. The category alone
    // leads when nothing names the merchant.
    final title = named ?? cat.label;
    final date = fmtDateCompact(tx.date);
    final details = named == null ? date : '${cat.label} · $date';
    final canMakeRule = offerRule && _rulePatternFor(tx).isNotEmpty;
    // Large text: no icon, and the amount moves under the date, so the
    // words get the row's width (at 320dp and 2x text the title read "Tra…").
    final large = isLargeTextScale(context);
    final amount = Text(
      '${isIncome ? '+' : '−'}${fmtMoney(tx.amount)}',
      style: TextStyle(
        color: amountColor,
        fontWeight: FontWeight.w700,
        fontSize: 15,
      ),
    );

    // No swipe-to-delete, matching TransactionTile — deleting lives in the
    // edit flows (with Undo).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: FrostedPanel(
        radius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showCategoryPicker(context),
          onLongPress: () => _showRuleFromTransaction(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (!large) ...[
                      // Rounded-square category icon
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: cat.color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          cat.icon,
                          color: categoryGlyphColor(context, cat.color),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: large ? 3 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          // The amount stays on the right in its money colour,
                          // so the line under the title is the category and
                          // date.
                          Text(
                            details,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          if (large)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: amount,
                            ),
                        ],
                      ),
                    ),
                    if (!large) ...[
                      const SizedBox(width: 12),
                      // Width-capped like TransactionTile: shrink extreme
                      // figures instead of overflowing the row.
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 140),
                        child: FittedBox(fit: BoxFit.scaleDown, child: amount),
                      ),
                    ],
                  ],
                ),
                // Its own line under the text, lined up with the title: in
                // the text column at 320dp and 2x text it had room for a
                // letter or two. Large text has no icon to line up with.
                if (canMakeRule)
                  Padding(
                    padding: EdgeInsets.only(left: large ? 0 : 56),
                    // No icon: at 2x text its width wrapped the label.
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () => onMakeRule(tx),
                      child: const Text('Make rule'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Category picker — tap to reassign. Changing type is allowed since SMS
  /// imports sometimes miscategorise income vs expense.
  Future<void> _showCategoryPicker(BuildContext context) async {
    final result = await showPickerSheet<String>(
      context: context,
      title: 'Category',
      items: _categoryPickerItems(context, includeSpam: false),
      selected: tx.categoryId,
    );
    final id = result?.value;
    if (id == null) return;
    await onPicked(tx, id);
  }

  /// Long-press shortcut: opens the rule dialog with the transaction body
  /// pre-filled as the pattern, making it easy to codify a manual correction.
  Future<void> _showRuleFromTransaction(BuildContext context) =>
      showRuleDialog(context, patternSuggestion: _rulePatternFor(tx));
}

// ── Shared dialog helpers ─────────────────────────────────────────────────────

/// Sectioned category rows for anchored pickers: Expenses / Income /
/// Transfers (+ the Spam pseudo-category when classifying).
List<PickerItem<String>> _categoryPickerItems(
  BuildContext context, {
  bool includeSpam = true,
}) => [
  const PickerItem.header('Expenses'),
  for (final c in allCategories)
    if (c.type == TxType.expense && !c.isTransfer) _categoryPickerItem(c),
  const PickerItem.header('Income'),
  for (final c in allCategories)
    if (c.type == TxType.income && !c.isTransfer) _categoryPickerItem(c),
  const PickerItem.header('Transfers'),
  for (final c in allCategories)
    if (c.isTransfer) _categoryPickerItem(c),
  if (includeSpam) ...[
    const PickerItem.header('Spam'),
    PickerItem(
      value: kSpamCategoryId,
      label: 'Spam, do not import',
      leading: Icon(
        Icons.block,
        color: Theme.of(context).colorScheme.error,
        size: 20,
      ),
    ),
  ],
];

PickerItem<String> _categoryPickerItem(TxCategory c) => PickerItem(
  value: c.id,
  label: c.label,
  leading: Icon(c.icon, color: c.color, size: 20),
);

/// Paste any SMS to see exactly how the importer would treat it — which
/// check rejects it, or what it imports as (type, category, account).
Future<void> _showTestMessageDialog(BuildContext context) async {
  final senderCtrl = TextEditingController();
  final bodyCtrl = TextEditingController();
  String? verdict;

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [senderCtrl, bodyCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Test a message'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: senderCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Sender',
                    hintText: 'e.g. VM-HDFCBK or "Yes Bank"',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bodyCtrl,
                  minLines: 3,
                  maxLines: 6,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Message text',
                    alignLabelWithHint: true,
                  ),
                ),
                if (verdict != null) ...[
                  const SizedBox(height: 16),
                  Builder(
                    builder: (ctx) {
                      final scheme = Theme.of(ctx).colorScheme;
                      // Rejected outright, or matched but killed by a spam rule.
                      final rejected =
                          verdict!.startsWith('Not imported') ||
                          verdict!.contains('Dropped by your spam rule');
                      final tint = rejected ? scheme.error : scheme.primary;
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        // Pass or fail lives on the outline and icon; the
                        // text stays plain so it never sits on a tint.
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: tint.withValues(alpha: 0.6),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              rejected
                                  ? Icons.cancel_outlined
                                  : Icons.check_circle_outline,
                              size: 18,
                              color: tint,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                verdict!,
                                style: Theme.of(ctx).textTheme.bodySmall
                                    ?.copyWith(fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            FilledButton(
              // Disabled on an empty body — a confident verdict about
              // nothing reads as broken.
              onPressed: bodyCtrl.text.trim().isEmpty
                  ? null
                  : () {
                      final finance = ctx.read<FinanceProvider>();
                      var v = SmsTxnParser.explain(
                        senderCtrl.text.trim(),
                        bodyCtrl.text,
                        DateTime.now(),
                        ignorePhrases: finance.ignorePhrases,
                        spamSignals: finance.spamSignals,
                      );
                      // The provider layer applies classifier rules on import —
                      // walk them exactly like _matchRule does so the verdict shows
                      // the real outcome, including matches that are SKIPPED for
                      // targeting the wrong direction (the tool used to claim a
                      // mismatched rule "applies" when the import would ignore it).
                      if (v.startsWith('Imports as')) {
                        final parsed = SmsTxnParser.parse(
                          senderCtrl.text.trim(),
                          bodyCtrl.text,
                          DateTime.now(),
                          relaxedSender: true,
                          ignorePhrases: finance.ignorePhrases,
                          spamSignals: finance.spamSignals,
                        );
                        for (final r in finance.rules) {
                          if (!r.matches(bodyCtrl.text)) continue;
                          if (r.isSpamRule) {
                            v +=
                                '\nDropped by your spam rule "${r.pattern}". '
                                'Never imported.';
                            break;
                          }
                          final target = categoryById(r.categoryId);
                          if (parsed != null && target.type != parsed.type) {
                            v +=
                                '\nRule "${r.pattern}" matches but targets '
                                '${target.type == TxType.income ? 'income' : 'expense'}'
                                ', so this '
                                '${parsed.type == TxType.income ? 'income' : 'expense'}'
                                ' message skips it. Add a rule for the other '
                                'direction '
                                'to classify both ways.';
                            continue;
                          }
                          v +=
                              '\nRule "${r.pattern}" applies → '
                              '${target.label}.';
                          break;
                        }
                      }
                      setState(() => verdict = v);
                    },
              child: const Text('Test'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _showImportRuleDialog(
  BuildContext context, {
  ImportRule? existing,
}) async {
  final patternCtrl = TextEditingController(text: existing?.pattern ?? '');
  var kind = existing?.kind ?? ImportRuleKind.ignore;
  // Delete pops the editor first; the caller's row then deletes with Undo.
  var deleteRequested = false;

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [patternCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(
            existing == null ? 'New import rule' : 'Edit import rule',
          ),
          // Scrollable: autofocused field + keyboard on a small screen. Top
          // padding keeps the first field's floating label from clipping.
          content: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: patternCtrl,
                  autofocus: true,
                  // Long phrases pasted from an SMS wrap instead of scrolling
                  // invisibly in a single line.
                  minLines: 2,
                  maxLines: 6,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'If the SMS contains…',
                    helperText:
                        'Case-insensitive, matches whole words, '
                        'e.g. "will be debited"',
                  ),
                ),
                // The field's helper line already sits under it; a full 16
                // on top of that left the dropdown floating apart.
                const SizedBox(height: 12),
                // Short names fit the dialog's field; the helper explains.
                AppDropdownField<ImportRuleKind>(
                  label: 'Then',
                  value: kind,
                  helper: kind == ImportRuleKind.ignore
                      ? 'Never imported.'
                      : 'Imported, but held for you to review one by one.',
                  items: const [
                    PickerItem(value: ImportRuleKind.ignore, label: 'Ignore'),
                    PickerItem(
                      value: ImportRuleKind.spamSignal,
                      label: 'Flag as spam',
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => kind = v);
                  },
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: () {
                  deleteRequested = true;
                  Navigator.pop(ctx);
                },
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            // Disabled while the pattern is empty instead of a silent no-op.
            FilledButton(
              onPressed: patternCtrl.text.trim().isEmpty
                  ? null
                  : () {
                      // Same collapse as the rule dialog: matching is a
                      // literal substring scan, so an embedded newline from
                      // the multiline field could never match a one-line SMS.
                      final pattern = patternCtrl.text
                          .replaceAll(RegExp(r'\s+'), ' ')
                          .trim();
                      final finance = ctx.read<FinanceProvider>();
                      if (existing == null) {
                        finance.addImportRule(pattern, kind);
                      } else {
                        finance.updateImportRule(
                          existing.copyWith(pattern: pattern, kind: kind),
                        );
                      }
                      Navigator.pop(ctx);
                    },
              child: Text(existing == null ? 'Create' : 'Save'),
            ),
          ],
        ),
      ),
    ),
  );
  if (deleteRequested && existing != null && context.mounted) {
    _deleteImportRuleWithUndo(context, existing);
  }
}

/// Category rows of one money direction only, for the pair's second slot.
List<PickerItem<String?>> _oppositeDirectionItems(TxType type) => [
  const PickerItem<String?>(value: null, label: 'Not for this direction'),
  PickerItem<String?>.header(type == TxType.income ? 'Income' : 'Expenses'),
  for (final c in allCategories)
    if (c.type == type && !c.isTransfer)
      PickerItem<String?>(
        value: c.id,
        label: c.label,
        leading: Icon(c.icon, color: c.color, size: 20),
      ),
  const PickerItem<String?>.header('Transfers'),
  for (final c in allCategories)
    if (c.type == type && c.isTransfer)
      PickerItem<String?>(
        value: c.id,
        label: c.label,
        leading: Icon(c.icon, color: c.color, size: 20),
      ),
];

/// The New rule / Edit rule dialog. [patternSuggestion] and
/// [categorySuggestion] prefill a new rule; the edit sheet's Make rule
/// passes the selected SMS text and the row's category.
Future<void> showRuleDialog(
  BuildContext context, {
  ClassifierRule? existing,
  ClassifierRule? sibling,
  String? patternSuggestion,
  String? categorySuggestion,
}) async {
  // The OR-conditions, shown as chips in the order they match. An existing
  // rule's patterns load as they are, duplicates included, so saving it
  // unchanged writes the same pattern back.
  final conditions = <String>[...?existing?.patterns];
  // The Add box. An SMS suggestion (Make rule) lands here rather than as a
  // chip: it can run 5-6 lines, and the user trims it before adding. Save
  // counts text left here, so Make rule then Save still works in one step.
  final addCtrl = TextEditingController(
    text: existing == null ? (patternSuggestion ?? '') : '',
  );
  final addFocus = FocusNode();
  // Ignores case, after the same whitespace collapse save applies.
  bool isDuplicate(String text) {
    final key = _collapseSpaces(text).toLowerCase();
    return conditions.any((c) => _collapseSpaces(c).toLowerCase() == key);
  }

  // Add and the keyboard's done key: chip the box, clear it, and keep focus
  // there for the next word. A duplicate just clears the box, since the
  // condition is already in the list.
  void addWord(StateSetter setState) {
    final text = _collapseSpaces(addCtrl.text);
    if (text.isEmpty || addCtrl.text.contains('|')) return;
    setState(() {
      if (!isDuplicate(text)) conditions.add(text);
      addCtrl.clear();
    });
    addFocus.requestFocus();
  }

  var categoryId = existing?.categoryId ?? categorySuggestion ?? 'food';
  // The opposite-direction twin (a second ordinary rule sharing the
  // pattern): pre-filled when editing a rule that already has one.
  final twin =
      sibling ??
      (existing == null
          ? null
          : directionSiblingOf(
              existing,
              context.read<FinanceProvider>().rules,
            ));
  String? otherCategoryId = twin?.categoryId;
  // The other-direction expander starts open on a pair, so its second
  // category is in view.
  var otherOpen = twin != null;
  // Delete pops the editor first; the caller's row then deletes the rule,
  // and its twin, with Undo.
  var deleteRequested = false;

  // What the rule matches, in one line under the fields: a pair stays
  // readable while its expander is closed.
  String helperLine() {
    if (categoryId == kSpamCategoryId) {
      return 'Ignores case. Matching messages are never imported.';
    }
    String side(TxCategory c) => c.type == TxType.income ? 'in' : 'out';
    final first = categoryById(categoryId);
    final other = otherCategoryId;
    if (other == null) {
      return 'Ignores case. Only money ${side(first)} matches '
          '${first.label}.';
    }
    final second = categoryById(other);
    return 'Ignores case. Money ${side(first)} matches ${first.label}, '
        'money ${side(second)} matches ${second.label}.';
  }

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [addCtrl, addFocus],
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(
            existing == null
                ? 'New rule'
                : twin == null
                ? 'Edit rule'
                : 'Edit rule pair',
          ),
          // Narrower side margins than the 40dp default, as in New account:
          // the condition chips get a third more room per line on a small
          // phone.
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          // Scrollable: autofocused field + keyboard on a small screen. Top
          // padding keeps the first field's floating label from clipping.
          // UnfocusOnScroll: dragging the dialog while a text field is
          // focused left its selection handle floating over the title —
          // handles render in an overlay the scroll viewport doesn't clip.
          content: UnfocusOnScroll(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The category and the Add box first: with 10 or more
                  // conditions they used to sit below the whole list. The
                  // field already has a suffix (the arrow), so the tip
                  // trails it.
                  Row(
                    children: [
                      Expanded(
                        child: AppDropdownField<String>(
                          label: 'Classify as',
                          value: categoryId,
                          items: [..._categoryPickerItems(ctx)],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              categoryId = v;
                              // The second slot must stay the OPPOSITE
                              // direction; drop it when the first pick moves
                              // onto its side (or becomes spam, which has no
                              // direction).
                              final other = otherCategoryId;
                              if (v == kSpamCategoryId ||
                                  (other != null &&
                                      categoryById(other).type ==
                                          categoryById(v).type)) {
                                otherCategoryId = null;
                              }
                            });
                          },
                        ),
                      ),
                      const InfoTip(
                        title: 'Classify as',
                        message:
                            'Saving applies the rule to past SMS rows right '
                            'away, except rows you categorised by hand. '
                            'Spam: matching messages are never imported, and '
                            'matching recent imports, waiting for review or '
                            'still marked new, are deleted after you confirm.',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _RuleAddBox(
                    controller: addCtrl,
                    focusNode: addFocus,
                    // A new rule types straight away; on an edit the
                    // keyboard would only shrink the dialog over the chips.
                    autofocus: existing == null,
                    onChanged: () => setState(() {}),
                    onAdd: () => addWord(setState),
                  ),
                  // Rules only fire for alerts moving money in the category's
                  // direction (the matcher skips the rest), so one keyword
                  // needs a rule per direction to classify both ways. The
                  // twin is a second ordinary rule sharing the pattern; most
                  // rules need none, so it waits behind an expander.
                  if (categoryId != kSpamCategoryId) ...[
                    const SizedBox(height: 4),
                    DialogExpander(
                      title: categoryById(categoryId).type == TxType.income
                          ? 'Money out goes to another category'
                          : 'Money in goes to another category',
                      open: otherOpen,
                      onToggle: () => setState(() => otherOpen = !otherOpen),
                      child: Row(
                        children: [
                          Expanded(
                            child: AppDropdownField<String?>(
                              label: 'Other direction',
                              value: otherCategoryId,
                              items: _oppositeDirectionItems(
                                categoryById(categoryId).type == TxType.income
                                    ? TxType.expense
                                    : TxType.income,
                              ),
                              onChanged: (v) =>
                                  setState(() => otherCategoryId = v),
                            ),
                          ),
                          // Explained here, while the pair is being made,
                          // rather than on the finished row in the list.
                          const InfoTip(
                            title: 'Rule pair',
                            message:
                                'Picking a category here makes a rule pair: '
                                'one pattern, two rules, one for money out '
                                'and one for money in. The Rules list shows '
                                'the pair as one row, and editing or deleting '
                                'it changes both. Not for this direction '
                                'removes the second rule.',
                          ),
                        ],
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      helperLine(),
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // The conditions last: the list can grow long, and nothing
                  // else in the dialog sits below it.
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'If the SMS contains any of (${conditions.length})',
                          style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const InfoTip(
                        title: 'If the SMS contains…',
                        message:
                            'Matches whole words in the SMS text, ignoring '
                            'case: "RD Ac" matches "RD Ac 1234" but not '
                            '"card account". Apart from spam rules, a rule '
                            'fires only when the message moves money in its '
                            "category's direction. Transactions added by "
                            'hand are never matched.',
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < conditions.length; i++)
                        _ConditionChip(
                          text: conditions[i],
                          onRemove: () =>
                              setState(() => conditions.removeAt(i)),
                          onEdit: () async {
                            final edited = await _editConditionDialog(
                              ctx,
                              conditions[i],
                              others: [
                                for (var j = 0; j < conditions.length; j++)
                                  if (j != i) conditions[j],
                              ],
                            );
                            if (edited == null || !ctx.mounted) return;
                            setState(() => conditions[i] = edited);
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: () {
                  deleteRequested = true;
                  Navigator.pop(ctx);
                },
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            // Disabled while there is no condition, chipped or typed,
            // instead of a silent no-op.
            FilledButton(
              onPressed:
                  (conditions.isEmpty && addCtrl.text.trim().isEmpty) ||
                      addCtrl.text.contains('|')
                  ? null
                  : () async {
                      // Rules match single-line SMS text — collapse stray
                      // newlines/runs of whitespace so a wrapped edit can't
                      // silently stop matching. Conditions join with '|',
                      // the OR separator ClassifierRule.patterns splits on —
                      // so a literal '|' inside a condition (common in UPI
                      // alerts) must be neutralised or it silently splits
                      // into extra, broader conditions the user never wrote.
                      // Text left in the Add box counts as one more
                      // condition, unless it repeats a chip.
                      final pattern =
                          [
                                ...conditions,
                                if (addCtrl.text.trim().isNotEmpty &&
                                    !isDuplicate(addCtrl.text))
                                  addCtrl.text,
                              ]
                              .map(
                                (c) => c
                                    .replaceAll('|', ' ')
                                    .replaceAll(RegExp(r'\s+'), ' ')
                                    .trim(),
                              )
                              .where((s) => s.isNotEmpty)
                              .join(' | ');
                      final finance = ctx.read<FinanceProvider>();
                      final messenger = ScaffoldMessenger.of(context);
                      // Warn BEFORE touching the queue: spam rules delete
                      // matching pending imports, and incremental scans
                      // never bring them back.
                      final wouldDrop = finance.pendingSpamDropsFor(
                        pattern,
                        categoryId,
                        replacingRuleId: existing?.id,
                      );
                      if (wouldDrop > 0) {
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (dCtx) => AlertDialog(
                            // Rows waiting for review and rows still marked
                            // new (already counted) both drop.
                            title: const Text('Drop recent imports?'),
                            content: Text(
                              'This rule matches $wouldDrop recent import'
                              '${wouldDrop == 1 ? '' : 's'} and will remove '
                              '${wouldDrop == 1 ? 'it' : 'them'} as spam.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dCtx, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(dCtx, true),
                                child: const Text('Apply rule'),
                              ),
                            ],
                          ),
                        );
                        if (ok != true || !ctx.mounted) return;
                      }
                      Navigator.pop(ctx);
                      var applied = existing == null
                          ? await finance.addRule(pattern, categoryId)
                          : await finance.updateRule(
                              existing.copyWith(
                                pattern: pattern,
                                categoryId: categoryId,
                              ),
                            );
                      // The opposite-direction twin: create, repoint or
                      // drop it to match the second slot. Deleting never
                      // re-applies (rows keep their categories), same as the
                      // tile's delete.
                      final other = otherCategoryId;
                      if (other != null) {
                        final twinApplied = twin == null
                            ? await finance.addRule(pattern, other)
                            : await finance.updateRule(
                                twin.copyWith(
                                  pattern: pattern,
                                  categoryId: other,
                                ),
                              );
                        applied = (
                          reclassified:
                              applied.reclassified + twinApplied.reclassified,
                          droppedPending:
                              applied.droppedPending +
                              twinApplied.droppedPending,
                          dropped: [...applied.dropped, ...twinApplied.dropped],
                        );
                      } else if (twin != null) {
                        await finance.deleteRule(twin.id);
                      }
                      // Rules re-apply to history immediately — say what that
                      // did. A broad spam rule silently emptying the review
                      // queue was the worst case, so dropped imports get a
                      // Restore action (the rule itself stays in force).
                      final parts = <String>[
                        if (applied.reclassified > 0)
                          '${applied.reclassified} transaction'
                              '${applied.reclassified == 1 ? '' : 's'} '
                              'reclassified',
                        if (applied.droppedPending > 0)
                          '${applied.droppedPending} recent import'
                              '${applied.droppedPending == 1 ? '' : 's'} '
                              'dropped as spam',
                      ];
                      if (parts.isNotEmpty) {
                        final dropped = applied.dropped;
                        showAppToastOn(
                          messenger,
                          parts.join(' · '),
                          tone: dropped.isEmpty
                              ? AppToastTone.info
                              : AppToastTone.change,
                          icon: Icons.rule,
                          duration: const Duration(seconds: 5),
                          actionLabel: dropped.isEmpty ? null : 'Restore',
                          onAction: dropped.isEmpty
                              ? null
                              : () => finance.restoreEditedTransactions(
                                  dropped,
                                  reAddMissing: true,
                                ),
                        );
                      }
                    },
              child: Text(existing == null ? 'Create' : 'Save'),
            ),
          ],
        ),
      ),
    ),
  );
  if (deleteRequested && existing != null && context.mounted) {
    _deleteRuleWithUndo(context, existing, twin);
  }
}

/// Runs of whitespace as one space, trimmed: rules match single-line SMS
/// text, so a condition is stored the way it can match.
String _collapseSpaces(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The rule dialog's Add box: a field and its Add button. Past
/// [kLargeTextScale] the button drops under the field, which keeps the
/// field wide enough to read on a narrow dialog.
class _RuleAddBox extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final VoidCallback onChanged;
  final VoidCallback onAdd;

  const _RuleAddBox({
    required this.controller,
    required this.focusNode,
    required this.autofocus,
    required this.onChanged,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final text = controller.text;
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      // An SMS suggestion can run 5-6 lines: four show it for trimming,
      // the rest scrolls.
      minLines: 1,
      maxLines: 4,
      // Done, not newline: the keyboard key adds the word. A multi-line
      // field defaults to the multiline keyboard, whose Enter key many
      // Android keyboards keep as a newline whatever the action says, so the
      // type is plain text; wrapping still comes from maxLines. With
      // onEditingComplete set, done no longer drops focus, so the next word
      // goes straight in.
      keyboardType: TextInputType.text,
      textInputAction: TextInputAction.done,
      onChanged: (_) => onChanged(),
      onEditingComplete: onAdd,
      decoration: InputDecoration(
        labelText: 'Add a word…',
        // '|' is the stored OR separator: typed here it would silently
        // split into extra conditions.
        errorText: text.contains('|')
            ? 'Remove "|". Add each word on its own.'
            : null,
      ),
    );
    final button = FilledButton.tonal(
      onPressed: text.trim().isEmpty || text.contains('|') ? null : onAdd,
      child: const Text('Add'),
    );
    if (isLargeTextScale(context)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field,
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerRight, child: button),
        ],
      );
    }
    return Row(
      // Top, not centre: an error line under the field would push a
      // centred button down off the field.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: field),
        const SizedBox(width: 8),
        Padding(padding: const EdgeInsets.only(top: 8), child: button),
      ],
    );
  }
}

/// One condition in the rule dialog: tap to edit, the cross to remove. One
/// line at most 220 wide, or the dialog's width when that is less, so a
/// long phrase ends in an ellipsis instead of taking rows of its own.
class _ConditionChip extends StatelessWidget {
  final String text;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const _ConditionChip({
    required this.text,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    // Wrap hands each child its full width, and ConstrainedBox keeps the
    // tighter of the two; the chip then shrinks its label to fit.
    constraints: const BoxConstraints(maxWidth: 220),
    child: InputChip(
      label: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
      // Compact and with trimmed padding, so 15 conditions take a few lines
      // rather than a screen. The cross gets a 20dp box instead of the
      // chip's full height, which made it as wide as a short word; its tap
      // area is that box plus the label's right padding.
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
      labelPadding: const EdgeInsets.only(left: 6, right: 4),
      deleteIconBoxConstraints: const BoxConstraints.tightFor(
        width: 20,
        height: 20,
      ),
      deleteIcon: const Icon(Icons.close, size: 18),
      deleteButtonTooltipMessage: 'Remove condition',
      onDeleted: onRemove,
      onPressed: onEdit,
    ),
  );
}

/// Edits one condition of the rule dialog. Returns the new text with its
/// whitespace collapsed, or null on Cancel. [others] are the remaining
/// conditions, for the duplicate check.
Future<String?> _editConditionDialog(
  BuildContext context,
  String initial, {
  required List<String> others,
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [ctrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final text = _collapseSpaces(ctrl.text);
          final key = text.toLowerCase();
          // Same '|' rule as the Add box; a repeat of another condition
          // would only store it twice.
          final error = ctrl.text.contains('|')
              ? 'Remove "|". Add each word on its own.'
              : others.any((o) => _collapseSpaces(o).toLowerCase() == key)
              ? 'Already a condition.'
              : null;
          return AlertDialog(
            title: const Text('Edit condition'),
            // Top padding keeps the field's floating label from clipping.
            content: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: ctrl,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'If the SMS contains…',
                  errorText: error,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              // Disabled while empty: clearing a condition is the cross's
              // job.
              FilledButton(
                onPressed: text.isEmpty || error != null
                    ? null
                    : () => Navigator.pop(ctx, text),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    ),
  );
}
