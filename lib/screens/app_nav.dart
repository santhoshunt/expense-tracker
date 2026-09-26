import 'package:flutter/material.dart';

import '../models/account.dart';
import '../widgets/reminder_editor_dialog.dart';
import 'classifiers_screen.dart';
import 'transactions_screen.dart';

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

  Object? _homeOwner;
  void Function(int tab)? _setHomeTab;
  void Function(TxFilterRequest request)? _openTransactions;
  VoidCallback? _importSms;

  Object? _accountsOwner;
  void Function(AccountType? type)? _showAccountType;

  Object? _dashboardOwner;
  VoidCallback? _showRecap;

  void attachHome(
    Object owner, {
    required void Function(int tab) setTab,
    required void Function(TxFilterRequest request) openTransactions,
    VoidCallback? importSms,
  }) {
    _homeOwner = owner;
    _setHomeTab = setTab;
    _openTransactions = openTransactions;
    _importSms = importSms;
  }

  /// Only the registering screen may detach, so a newer one survives an
  /// older one's dispose.
  void detachHome(Object owner) {
    if (_homeOwner != owner) return;
    _homeOwner = null;
    _setHomeTab = null;
    _openTransactions = null;
    _importSms = null;
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

  void attachDashboard(Object owner, {required VoidCallback showRecap}) {
    _dashboardOwner = owner;
    _showRecap = showRecap;
  }

  void detachDashboard(Object owner) {
    if (_dashboardOwner != owner) return;
    _dashboardOwner = null;
    _showRecap = null;
  }

  /// The Dashboard's recap on the Month page, or after the recap week this
  /// month so far on Trends, scrolled into view. Leaves open routes alone:
  /// callers switch the home tab themselves.
  void showRecap() => _showRecap?.call();

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

  /// Cockpit tab [tab] (a kCockpitTab* id): switches in place when
  /// already on the Cockpit group page that holds it, otherwise opens that
  /// group's page on the tab (over the hub or another group's page).
  void openCockpit(BuildContext context, int tab) {
    final scope = CockpitScope.maybeOf(context);
    if (scope != null && scope.show(tab)) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ClassifiersScreen(initialTab: tab)),
    );
  }
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
void goCockpitBudgets(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabBudgets);
void goCockpitSubscriptions(BuildContext c) =>
    AppNav.instance.openCockpit(c, kCockpitTabSubscriptions);
void goDashboard(BuildContext c) =>
    AppNav.instance.openHomeTab(c, kHomeTabDashboard);

/// All transactions, filters cleared (the review and spam cards sit on top).
void goAllTransactions(BuildContext c) =>
    AppNav.instance.openTransactions(c, const TxFilterRequest());
void goAccounts(BuildContext c) => AppNav.instance.openAccounts(c);
void goSavingsAccounts(BuildContext c) =>
    AppNav.instance.openAccounts(c, type: AccountType.savings);
void goNewReminder(BuildContext c) => showReminderEditor(c);

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
