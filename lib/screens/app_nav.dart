import 'package:flutter/material.dart';

import '../models/account.dart';
import '../models/dashboard_layout.dart';
import '../widgets/reminder_editor_dialog.dart';
import 'classifiers_screen.dart';
import 'people_screen.dart';
import 'settings_screen.dart';
import 'transactions_screen.dart';

/// What the Dashboard puts in Home's app bar: the month or year, its arrows
/// and the Month or Year switch, or on a page with no month (Ahead) a fixed
/// title over a [subtitle] with no arrows. Its ⋮ entries go through
/// [PageMenu]. The Dashboard owns the month and Year view state and
/// [update]s this after each change; Home's bar listens. Null callbacks
/// leave their control disabled.
class DashboardHeader extends ChangeNotifier {
  String label = '';

  /// A muted line under [label] on a page with no month (Ahead): the arrows hide and the label is not a picker.
  String? subtitle;
  bool yearMode = false;
  VoidCallback? onPrev;
  VoidCallback? onNext;
  VoidCallback? onPick;

  /// Switches between Month and Year view.
  VoidCallback? onToggleView;

  /// The Dashboard State whose callbacks the fields hold.
  Object? _owner;

  /// Sets every field; notifies only when the label, the view, which
  /// controls work or the publishing [owner] changed (callbacks are fresh
  /// closures on every build). A new owner always notifies: the bar would
  /// otherwise keep calling a disposed Dashboard's closures.
  void update({
    required Object owner,
    required String label,
    required bool yearMode,
    required VoidCallback? onPrev,
    required VoidCallback? onNext,
    required VoidCallback onPick,
    VoidCallback? onToggleView,
    String? subtitle,
  }) {
    final changed =
        owner != _owner ||
        label != this.label ||
        subtitle != this.subtitle ||
        yearMode != this.yearMode ||
        (onPrev == null) != (this.onPrev == null) ||
        (onNext == null) != (this.onNext == null) ||
        (onToggleView == null) != (this.onToggleView == null) ||
        this.onPick == null;
    _owner = owner;
    this.label = label;
    this.subtitle = subtitle;
    this.yearMode = yearMode;
    this.onPrev = onPrev;
    this.onNext = onNext;
    this.onPick = onPick;
    this.onToggleView = onToggleView;
    if (changed) notifyListeners();
  }

  /// Drops [owner]'s callbacks when it goes, so the bar never calls a
  /// disposed Dashboard; a newer owner's stay. The label stays for the
  /// frame until the next Dashboard publishes. No notification: this runs
  /// while the tree is torn down, and the controls read the fields on tap.
  void detach(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    onPrev = null;
    onNext = null;
    onPick = null;
    onToggleView = null;
  }
}

/// One entry in the "This page" part of Home's ⋮ menu. [trailing], when
/// set, sits at the row's end (the Year view tip's ⓘ).
class PageMenuAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;
  const PageMenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
  });
}

/// The "This page" entries each Home tab puts in the ⋮ menu, so the menu
/// has the same two sections (This page, then App) on every tab. A tab
/// [publish]es after it builds and [detach]es in dispose, like
/// [DashboardHeader].
class PageMenu extends ChangeNotifier {
  final Map<int, ({Object owner, List<PageMenuAction> actions})> _byTab = {};

  /// [actions] for [tab], from [owner]. Notifies only when the labels
  /// change or the owner is new: callbacks are fresh closures every build.
  void publish(Object owner, int tab, List<PageMenuAction> actions) {
    final old = _byTab[tab];
    final changed =
        old == null ||
        old.owner != owner ||
        old.actions.length != actions.length ||
        [
          for (var i = 0; i < actions.length; i++)
            old.actions[i].label != actions[i].label,
        ].any((d) => d);
    _byTab[tab] = (owner: owner, actions: List.unmodifiable(actions));
    if (changed) notifyListeners();
  }

  /// Drops [owner]'s entries when it goes; a newer owner's stay. No
  /// notification, for the same reason as [DashboardHeader.detach].
  void detach(Object owner) => _byTab.removeWhere((_, v) => v.owner == owner);

  List<PageMenuAction> actionsFor(int tab) => _byTab[tab]?.actions ?? const [];
}

/// Home tab indices (HomeScreen's bottom navigation).
const int kHomeTabDashboard = 0;
const int kHomeTabTransactions = 1;
const int kHomeTabAccounts = 2;

/// Jumps between the app's places from anywhere, including pushed routes
/// (Cockpit, Settings) and tooltip links. Home and Accounts register their
/// handlers while they are alive; without them a jump just returns to the
/// root.
///
/// A single instance rather than a Provider: the pieces that register
/// (HomeScreen, AccountsScreen) and the ones that jump live on different
/// routes, and screens pumped alone in tests must not need extra setup.
class AppNav {
  AppNav._();
  static final AppNav instance = AppNav._();

  /// The Dashboard's month selector and menu entries, shown in Home's bar.
  final DashboardHeader dashboardHeader = DashboardHeader();

  /// Each tab's "This page" entries for Home's ⋮ menu.
  final PageMenu pageMenu = PageMenu();

  Object? _homeOwner;
  void Function(int tab)? _setHomeTab;
  void Function(TxFilterRequest request)? _openTransactions;
  VoidCallback? _importSms;
  VoidCallback? _openReview;

  Object? _accountsOwner;
  void Function(AccountType? type)? _showAccountType;

  Object? _dashboardOwner;
  VoidCallback? _showRecap;
  void Function(DashboardSection section)? _showSection;
  void Function(String categoryId, DateTime month)? _showCategoryHistory;
  void Function(DateTime week)? _showWeeklyDigest;
  VoidCallback? _showBigBills;

  void attachHome(
    Object owner, {
    required void Function(int tab) setTab,
    required void Function(TxFilterRequest request) openTransactions,
    VoidCallback? importSms,
    VoidCallback? openReview,
  }) {
    _homeOwner = owner;
    _setHomeTab = setTab;
    _openTransactions = openTransactions;
    _importSms = importSms;
    _openReview = openReview;
  }

  /// Only the registering screen may detach, so a newer one survives an
  /// older one's dispose.
  void detachHome(Object owner) {
    if (_homeOwner != owner) return;
    _homeOwner = null;
    _setHomeTab = null;
    _openTransactions = null;
    _importSms = null;
    _openReview = null;
  }

  void attachAccounts(
    Object owner, {
    required void Function(AccountType? type) showType,
  }) {
    _accountsOwner = owner;
    _showAccountType = showType;
  }

  void detachAccounts(Object owner) {
    if (_accountsOwner != owner) return;
    _accountsOwner = null;
    _showAccountType = null;
  }

  void attachDashboard(
    Object owner, {
    required VoidCallback showRecap,
    required void Function(DashboardSection section) showSection,
    required void Function(String categoryId, DateTime month)
    showCategoryHistory,
    required void Function(DateTime week) showWeeklyDigest,
    required VoidCallback showBigBills,
  }) {
    _dashboardOwner = owner;
    _showRecap = showRecap;
    _showSection = showSection;
    _showCategoryHistory = showCategoryHistory;
    _showWeeklyDigest = showWeeklyDigest;
    _showBigBills = showBigBills;
  }

  void detachDashboard(Object owner) {
    if (_dashboardOwner != owner) return;
    _dashboardOwner = null;
    _showRecap = null;
    _showSection = null;
    _showCategoryHistory = null;
    _showWeeklyDigest = null;
    _showBigBills = null;
  }

  /// The Dashboard's recap on the Overview, or after the recap week this
  /// month so far on Trends, scrolled into view. Leaves open routes alone:
  /// callers switch the home tab themselves.
  void showRecap() => _showRecap?.call();

  /// [section]'s Dashboard page on this month, its fold opened and scrolled
  /// into view (where each home-screen widget lands). Leaves open routes
  /// alone: callers switch the home tab themselves.
  void showDashboardSection(DashboardSection section) =>
      _showSection?.call(section);

  /// [categoryId]'s history sheet over the Dashboard on [month], in Month
  /// view (where an unusual spending alert lands). Leaves open routes
  /// alone: callers switch the home tab themselves.
  void showCategoryHistory(String categoryId, DateTime month) =>
      _showCategoryHistory?.call(categoryId, month);

  /// The weekly digest sheet over the Dashboard, on the week starting
  /// [week] (where the Monday note lands). Leaves open routes alone:
  /// callers switch the home tab themselves.
  void showWeeklyDigest(DateTime week) => _showWeeklyDigest?.call(week);

  /// The Big bills ahead sheet over the Dashboard (where the Big bills
  /// widgets land). Leaves open routes alone: callers switch the home tab
  /// themselves.
  void showBigBills() => _showBigBills?.call();

  void _toRoot(BuildContext context) =>
      Navigator.of(context).popUntil((r) => r.isFirst);

  /// Closes any pushed routes and shows home tab [tab].
  void openHomeTab(BuildContext context, int tab) {
    _toRoot(context);
    _setHomeTab?.call(tab);
  }

  /// The Transactions tab with [request]'s filter (an empty request shows
  /// everything).
  void openTransactions(BuildContext context, TxFilterRequest request) {
    _toRoot(context);
    _openTransactions?.call(request);
  }

  /// The Accounts tab, on [type]'s page (null: All).
  void openAccounts(BuildContext context, {AccountType? type}) {
    openHomeTab(context, kHomeTabAccounts);
    _showAccountType?.call(type);
  }

  /// Whether [importSms] can run: Home registered an SMS import.
  bool get canImportSms => _importSms != null;

  /// Runs Home's SMS import (the top bar's message button).
  void importSms(BuildContext context) {
    _toRoot(context);
    _importSms?.call();
  }

  /// The review sheet over the Transactions tab, pushed routes closed.
  void openReview(BuildContext context) {
    _toRoot(context);
    _openReview?.call();
  }

  /// Cockpit tab [tab] (a kCockpitTab* id): switches in place when
  /// already on the Cockpit group page that holds it, otherwise opens that
  /// group's page on the tab. From another group's page it goes over that
  /// page; from outside the Cockpit the hub goes in first, without a
  /// transition of its own, so Back from the group page lands on the hub.
  void openCockpit(BuildContext context, int tab) {
    final scope = CockpitScope.maybeOf(context);
    if (scope != null && scope.show(tab)) return;
    final navigator = Navigator.of(context);
    if (scope == null) {
      navigator.push(
        _InstantPageRoute(builder: (_) => const ClassifiersScreen()),
      );
    }
    navigator.push(
      MaterialPageRoute(builder: (_) => ClassifiersScreen(initialTab: tab)),
    );
  }
}

/// A page that appears at once, under the page pushed right after it, so
/// only that page's transition shows. Back from it still animates.
class _InstantPageRoute<T> extends MaterialPageRoute<T> {
  _InstantPageRoute({required super.builder});

  @override
  Duration get transitionDuration => Duration.zero;
}

// Link targets for tooltips (InfoLink.onTap). Top-level so links can be
// const.
void goCockpitRules(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabRules);
void goCockpitImport(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabImport);
void goCockpitTransactions(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabTransactions);
void goCockpitCategories(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabCategories);
void goCockpitGroups(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabGroups);
void goCockpitBudgets(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabBudgets);
void goCockpitSubscriptions(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabSubscriptions);
void goCockpitTags(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabTags);

/// Cockpit, Dashboard: the tab that orders and hides [page]'s sections.
void goCockpitDashboard(BuildContext c, DashboardPage page) =>
    AppNav.instance.openCockpit(c, switch (page) {
      DashboardPage.overview => kCockpitTabDashOverview,
      DashboardPage.ahead => kCockpitTabDashAhead,
      DashboardPage.trends => kCockpitTabDashTrends,
      DashboardPage.breakdown => kCockpitTabDashBreakdown,
    });
void goDashboard(BuildContext c) =>
    AppNav.instance.openHomeTab(c, kHomeTabDashboard);

/// All transactions, filters cleared.
void goAllTransactions(BuildContext c) =>
    AppNav.instance.openTransactions(c, const TxFilterRequest());

/// The review sheet over the Transactions tab.
void goReview(BuildContext c) => AppNav.instance.openReview(c);
void goAccounts(BuildContext c) => AppNav.instance.openAccounts(c);
void goNewReminder(BuildContext c) => showReminderEditor(c);

/// Settings, Notifications: the alert switches, pushed over whatever is
/// open.
void goNotificationSettings(BuildContext c) => Navigator.of(
  c,
).push(MaterialPageRoute<void>(builder: (_) => const NotificationsPage()));

/// Who owes you, pushed over whatever is open.
void goPeople(BuildContext c) => Navigator.of(
  c,
).push(MaterialPageRoute<void>(builder: (_) => const PeopleScreen()));

/// Marks the inside of a Cockpit group page, so [AppNav.openCockpit]
/// switches its tab instead of stacking a second copy of the page.
class CockpitScope extends InheritedWidget {
  /// The page's tab bar controller; null on a single-tab page.
  final TabController? controller;

  /// The kCockpitTab* ids the page shows, in tab order.
  final List<int> tabs;

  const CockpitScope({
    super.key,
    required this.controller,
    required this.tabs,
    required super.child,
  });

  /// Selects [tab] when this page holds it. False: the tab lives on another
  /// group's page, which the caller must open.
  bool show(int tab) {
    final i = tabs.indexOf(tab);
    if (i < 0) return false;
    controller?.animateTo(i);
    return true;
  }

  static CockpitScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CockpitScope>();

  @override
  bool updateShouldNotify(CockpitScope old) =>
      old.controller != controller || old.tabs != tabs;
}
