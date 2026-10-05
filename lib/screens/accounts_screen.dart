import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/card_bill.dart';
import '../services/savings_goal.dart';
import '../services/sms_parser.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/animated_fold.dart';
import '../widgets/balance_breakdown.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/empty_state.dart';
import '../widgets/glossy.dart';
import '../widgets/info_tip.dart';
import '../widgets/link_pill.dart';
import '../widgets/motion.dart';
import '../widgets/section_header.dart';
import '../widgets/undo_snackbar.dart';
import 'app_nav.dart';

class AccountsScreen extends StatefulWidget {
  /// Tapping an account jumps to its filtered transaction list.
  final void Function(String accountId) onViewAccount;

  const AccountsScreen({super.key, required this.onViewAccount});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  AccountType? _typeFilter; // null = all

  /// Order the pager steps through.
  static const List<AccountType?> _filterOrder = [
    null,
    AccountType.bank,
    AccountType.creditCard,
    AccountType.savings,
    AccountType.wallet,
  ];

  late final PageController _pageCtrl = PageController();

  @override
  void initState() {
    super.initState();
    // Tooltip links can land on a given page (e.g. Savings). Post-frame:
    // the jump arrives alongside the home tab switch that reveals us.
    AppNav.instance.attachAccounts(
      this,
      showType: (t) => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageCtrl.hasClients) {
          _pageCtrl.jumpToPage(_filterOrder.indexOf(t));
        }
      }),
    );
  }

  @override
  void dispose() {
    AppNav.instance.detachAccounts(this);
    _pageCtrl.dispose();
    super.dispose();
  }

  void _setTypeFilter(AccountType? t) {
    if (t == _typeFilter) return;
    _pageCtrl.animateToPage(
      _filterOrder.indexOf(t),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;

    final net = finance.netWorth;
    // The accounts the net figure is made of: savings and asset accounts
    // are left out of it, so they are left out of the count too.
    final netAccounts = finance.openAccounts
        .where((a) => a.type == AccountType.bank || a.isCard)
        .length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          // InkWell, not GestureDetector: ripple + button semantics.
          child: FrostedPanel(
            radius: BorderRadius.circular(24),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => showBalanceBreakdownSheet(context, finance),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Icon(
                      Icons.account_balance_wallet,
                      size: 32,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MorphingAmount(
                            value: net,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: accentTextColor(context),
                            ),
                          ),
                          InfoLabel(
                            // The chevron says the card opens the breakdown.
                            label: Text(
                              netAccounts == 1
                                  ? 'Net across 1 bank or card account'
                                  : 'Net across $netAccounts bank and card '
                                        'accounts',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                            tip: InfoTip(
                              title: 'Net balance',
                              message:
                                  'Bank balances minus credit card '
                                  'outstanding. Savings, asset and wallet '
                                  'accounts are not included.',
                              example: () =>
                                  '${fmtMoney(finance.bankBalanceTotal)} in '
                                  'banks − '
                                  '${fmtMoney(finance.cardOutstandingTotal)} '
                                  'on cards = ${fmtMoney(finance.netWorth)}',
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Type filter: All / Bank / Cards / Savings / Wallets.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GlassSegmented<AccountType?>(
            options: const [
              (null, 'All'),
              (AccountType.bank, 'Banks'),
              (AccountType.creditCard, 'Cards'),
              (AccountType.savings, 'Savings'),
              (AccountType.wallet, 'Wallets'),
            ],
            // Five labels only fit a narrow phone without their icons.
            icons: MediaQuery.sizeOf(context).width < 400
                ? null
                : const [
                    Icons.apps,
                    Icons.account_balance_outlined,
                    Icons.credit_card,
                    Icons.savings_outlined,
                    Icons.account_balance_wallet_outlined,
                  ],
            selected: _typeFilter,
            onChanged: _setTypeFilter,
            pager: _pageCtrl,
          ),
        ),
        Expanded(
          child: PageView(
            controller: _pageCtrl,
            onPageChanged: (i) => setState(() => _typeFilter = _filterOrder[i]),
            children: [
              for (final t in _filterOrder) _buildPage(finance, scheme, t),
            ],
          ),
        ),
      ],
    );
  }

  /// Wallets grouped by service ("Amazon Pay"), alphabetically, each group
  /// headed by its name and ₹ total; wallets with no service come last,
  /// under "Other wallets".
  List<Widget> _walletGroups(FinanceProvider finance, List<Account> wallets) {
    final groups = <String, List<Account>>{};
    for (final a in wallets) {
      (groups[a.service?.trim().toLowerCase() ?? ''] ??= []).add(a);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
        return a.compareTo(b);
      });
    return [
      for (final k in keys) ...[
        _WalletServiceHeader(
          service: k.isEmpty
              ? 'Other wallets'
              : groups[k]!.first.service!.trim(),
          total: groups[k]!.fold(0.0, (s, a) => s + finance.accountBalance(a)),
        ),
        for (final a in groups[k]!)
          _AccountCard(account: a, onView: widget.onViewAccount),
      ],
    ];
  }

  /// One pager page. Computes its own filtered lists for [t]: during a drag
  /// the neighbor page is alive too and must show its own filter, not
  /// [_typeFilter].
  Widget _buildPage(
    FinanceProvider finance,
    ColorScheme scheme,
    AccountType? t,
  ) {
    bool visible(Account a) => t == null || a.type == t;
    final accounts = finance.openAccounts.where(visible).toList();
    final closed = finance.closedAccounts.where(visible).toList();
    // Transparent ColoredBox: the empty state is shrink-wrapped, and a
    // PageView only receives drags that hit its subtree — blank regions
    // need an opaque hit-test surface or a swipe there would die.
    return ColoredBox(
      color: Colors.transparent,
      child: accounts.isEmpty && closed.isEmpty
          ? EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              message: t != null
                  ? (t == AccountType.wallet
                        ? 'No wallets yet.'
                        : 'No ${t.label.toLowerCase()} accounts yet.')
                  : 'No accounts yet.\n\nAccounts are detected '
                        'automatically from the account and card '
                        'numbers in your bank SMS. Import messages '
                        'to populate them.',
              // Same words as the floating button on this tab.
              actionLabel: 'New account',
              onAction: () => showAddAccountDialog(context, initialType: t),
            )
          : Builder(
              builder: (context) {
                // Flat heterogeneous list (Rules-tab pattern): open
                // cards, then a muted closed section. Closed cards keep
                // full tap/menu behavior — only dimmed. The All view
                // groups open accounts by type under section headers;
                // a filtered view IS one type, so it stays flat.
                final wallets = [
                  for (final a in accounts)
                    if (a.isWallet) a,
                ];
                final items = <Widget>[
                  if (t == null) ...[
                    for (final (type, header) in const [
                      (AccountType.bank, 'Banks'),
                      (AccountType.creditCard, 'Credit cards'),
                      (AccountType.savings, 'Savings & assets'),
                    ]) ...[
                      if (accounts.any((a) => a.type == type)) ...[
                        UppercaseSectionHeader(
                          header,
                          color: scheme.onSurfaceVariant,
                        ),
                        for (final a in accounts)
                          if (a.type == type)
                            _AccountCard(
                              account: a,
                              onView: widget.onViewAccount,
                            ),
                      ],
                    ],
                    if (wallets.isNotEmpty) ...[
                      UppercaseSectionHeader(
                        'Wallets',
                        color: scheme.onSurfaceVariant,
                      ),
                      ..._walletGroups(finance, wallets),
                    ],
                  ] else if (t == AccountType.wallet)
                    ..._walletGroups(finance, wallets)
                  else
                    for (final a in accounts)
                      _AccountCard(account: a, onView: widget.onViewAccount),
                  if (closed.isNotEmpty) ...[
                    // The header's own inset, less what the 32dp tip adds
                    // above and below the 11px text.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: InfoLabel(
                          label: UppercaseSectionHeader(
                            'Closed accounts',
                            color: scheme.onSurfaceVariant,
                            padding: EdgeInsets.zero,
                          ),
                          tip: const InfoTip(
                            title: 'Closed accounts',
                            message:
                                'Closed accounts are left out of totals, '
                                'pickers and Upcoming. They keep their '
                                'history and linked numbers, so new alerts '
                                'still land on them. Reopen one from its '
                                'menu.',
                          ),
                        ),
                      ),
                    ),
                    for (final a in closed)
                      Opacity(
                        opacity: 0.6,
                        child: _AccountCard(
                          account: a,
                          onView: widget.onViewAccount,
                        ),
                      ),
                  ],
                ];
                return ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 120),
                  itemCount: items.length,
                  itemBuilder: (context, i) => items[i],
                );
              },
            ),
    );
  }
}

/// One account: collapsed to its name and one figure (the balance, or what
/// a card owes) until tapped; open, today's full details and a way into its
/// transactions. Which cards are open is remembered ([SettingsProvider]).
class _AccountCard extends StatelessWidget {
  final Account account;
  final void Function(String accountId) onView;

  const _AccountCard({required this.account, required this.onView});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final settings = context.read<SettingsProvider>();
    final expanded = context.select<SettingsProvider, bool>(
      (s) => s.isAccountExpanded(account.id),
    );
    final scheme = Theme.of(context).colorScheme;
    final isCard = account.isCard;
    final txCount = finance.transactionCountForAccount(account.id);
    final orphaned = finance.isOrphanedAccount(account);
    final String figure;
    if (isCard) {
      final owed = finance.accountOutstanding(account);
      // No figure: name the same blocker the open card explains.
      figure = owed != null
          ? fmtMoney(owed)
          : finance.accountProvenance(account).blocker ==
                OutstandingBlocker.noAlert
          ? 'No balance yet'
          : 'Limit needed';
    } else {
      figure = fmtMoney(finance.accountBalance(account));
    }
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: FrostedPanel(
        radius: BorderRadius.circular(20),
        // TalkBack says whether the card is open.
        child: Semantics(
          expanded: expanded,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => settings.setAccountExpanded(account.id, !expanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(
                            AppRadius.control,
                          ),
                        ),
                        child: Icon(
                          account.icon,
                          color: categoryGlyphColor(context, scheme.primary),
                          size: 21,
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Name over figure, each with the full width: side by
                      // side, a long name and a shrink-to-fit figure left
                      // every card's amount a different size.
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              // Under its service header a wallet is its
                              // login; closed, it has no header to lean on.
                              account.isWallet && account.isClosed
                                  ? account.displayName
                                  : account.name,
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (expanded)
                              Text(
                                '${account.typeLabel} · $txCount '
                                'txn${txCount == 1 ? '' : 's'}',
                                style: muted,
                              )
                            else
                              // Shrinks only past the full width (a huge
                              // font): cut off, a balance hides its digits.
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  figure,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // The hint lives in the open card; closed, a mark
                      // says there is one.
                      if (!expanded && orphaned)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Tooltip(
                            message: 'No transactions use this account',
                            child: Icon(
                              Icons.info_outline,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        // No label: the card's Semantics(expanded:) says it.
                        color: scheme.onSurfaceVariant,
                      ),
                      _AccountMenu(account: account),
                    ],
                  ),
                  AnimatedFold(
                    collapsed: !expanded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 14),
                        if (isCard)
                          _CardFigures(account: account, onView: onView)
                        else
                          _BankBalance(account: account),
                        // An account the 1.28 re-key emptied keeps its set
                        // balance in net balance: say so, and offer the two
                        // ways out.
                        if (orphaned) ...[
                          const SizedBox(height: 10),
                          Text(
                            [
                              'No transactions use this account.',
                              // Only what a figure set by hand still adds to
                              // net balance; savings sit outside it.
                              if (account.manualBalance != null)
                                if (account.isCard)
                                  'Its set outstanding still counts in net '
                                      'balance.'
                                else if (account.type == AccountType.bank)
                                  'Its set balance still counts in net balance.',
                            ].join(' '),
                            style: muted,
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: () =>
                                    mergeAccountFlow(context, account),
                                child: const Text('Merge into…'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    deleteAccountFlow(context, account),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 6),
                        TextButton.icon(
                          onPressed: () => onView(account.id),
                          icon: const Icon(Icons.list_alt, size: 18),
                          label: const Text('View transactions'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A service's row above its wallets: "Amazon Pay" and what they hold in ₹.
class _WalletServiceHeader extends StatelessWidget {
  final String service;
  final double total;
  const _WalletServiceHeader({required this.service, required this.total});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              service,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleSmall,
            ),
          ),
          const SizedBox(width: 8),
          Text(fmtMoney(total), style: text.titleSmall?.copyWith(color: muted)),
        ],
      ),
    );
  }
}

/// One line saying how the displayed figure was calculated — shared by the
/// bank/savings Balance block and the card Outstanding block. The "+ N txns
/// since" suffix is a delta count (rows applied on top of the stated
/// figure), deliberately not the header's total transaction count.
String provenanceLine(
  ({
    BalanceSource source,
    DateTime? asOf,
    int rowsSince,
    OutstandingBlocker? blocker,
  })
  p,
) {
  final n = p.rowsSince;
  final since = n == 0 ? '' : ' + $n txn${n == 1 ? '' : 's'} since';
  final at = p.asOf == null ? '' : ' · ${fmtDateMaybeTime(p.asOf!)}';
  return switch (p.source) {
    BalanceSource.manual => 'Set by you$at$since',
    BalanceSource.alert => 'From bank alert$at$since',
    BalanceSource.ledger => 'Sum of $n recorded txn${n == 1 ? '' : 's'}',
  };
}

class _BankBalance extends StatelessWidget {
  final Account account;
  const _BankBalance({required this.account});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final p = finance.accountProvenance(account);
    // Say where the figure comes from — "why is it showing this number"
    // should be readable off the tile, not reverse-engineered.
    final provenance = provenanceLine(p);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // One group, so spaceBetween keeps the tip beside the label.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Balance',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                InfoTip(
                  title: 'Balance',
                  message: account.isWallet
                      ? 'The balance you set, plus transactions dated '
                            'after it, counted as spending or not. '
                            'Wallets stay out of net balance.'
                      : 'The newest known balance wins, whether you set it '
                            'or a bank alert stated it. Transactions after it '
                            'are added on.',
                  link: InfoLink(
                    prompt: 'Balance looks off?',
                    label: 'Set the balance',
                    onTap: (c) => showSetBalanceDialog(c, account),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            // Shrink rather than overflow when the amount and label compete
            // for width (long balances, large font scales).
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: MorphingAmount(
                  value: finance.accountBalance(account),
                  alignment: Alignment.centerRight,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: accentTextColor(context),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // A points wallet reads in points first: "500 points · ₹0.25 each".
        if (account.pointsOf(finance.accountBalance(account))
            case final points?)
          Text(
            '${fmtPoints(points)} · ${fmtPerPoint(account.pointValue!)} each',
            style: TextStyle(color: scheme.onSurface, fontSize: 13),
          ),
        Text(
          provenance,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
        if (account.type == AccountType.savings &&
            (account.goalAmount ?? 0) > 0)
          _GoalProgress(account: account),
      ],
    );
  }
}

/// Progress toward a savings goal, plus a projected completion date from
/// the trailing-90-day deposit rate.
class _GoalProgress extends StatelessWidget {
  final Account account;
  const _GoalProgress({required this.account});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    final goal = account.goalAmount!;
    final balance = finance.accountBalance(account);
    final reached = balance >= goal;

    String line;
    String? example;
    if (reached) {
      line = 'Goal reached · ${fmtMoney(goal)}';
    } else {
      line = 'Saved ${fmtMoney(balance)} of ${fmtMoney(goal)}';
      final avg = avgMonthlyNet(
        finance.transactionsForAccount(account.id),
        now: DateTime.now(),
      );
      final projected = projectedGoalDate(
        balance: balance,
        goal: goal,
        avgMonthlyNet: avg,
        now: DateTime.now(),
      );
      // No projection line when nothing is flowing in — a made-up date is
      // worse than none.
      if (projected != null) {
        line += ' · on track for ~${fmtMonth(projected)}';
        final months = ((goal - balance) / avg * 10).round() / 10;
        final n = months == months.roundToDouble()
            ? '${months.round()}'
            : months.toStringAsFixed(1);
        example =
            '${fmtMoney(goal - balance)} left ÷ ${fmtMoney(avg)} a month '
            '≈ $n month${n == '1' ? '' : 's'}';
      }
    }
    final text = Text(
      line,
      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        AnimatedProgress(
          value: goal <= 0 ? 0 : (balance / goal).clamp(0.0, 1.0),
          minHeight: 8,
          borderRadius: const BorderRadius.all(Radius.circular(5)),
          color: colors.green,
          backgroundColor: colors.green.withValues(alpha: 0.12),
        ),
        const SizedBox(height: 6),
        if (reached)
          text
        else
          InfoLabel(
            label: text,
            tip: InfoTip(
              title: 'Savings goal',
              message:
                  'The finish month assumes you keep adding your average '
                  "over the last 90 days, or since the account's first "
                  'transaction if that is more recent. It waits for 14 days '
                  'of history and is hidden when the average is zero or '
                  'negative.',
              example: () => example,
              link: InfoLink(
                prompt: 'Want a different target?',
                label: 'Edit the goal',
                onTap: (c) => showSavingsGoalDialog(c, account),
              ),
            ),
          ),
      ],
    );
  }
}

/// Total credit limit for a card. Shared by the account menu and the
/// "amount owed is unknowable" prompt on the card itself.
///
/// Same input contract as the set-balance dialog: empty clears, an
/// unreadable entry errors instead of silently clearing the limit.
/// Manual balance (banks) / outstanding (cards). The entered figure wins
/// until a newer SMS-reported one arrives. Shared by the account menu's
/// "Set balance… / Set outstanding…" and the card tile's no-alert affordance.
///
/// Only an explicitly empty field clears the value. An unreadable entry
/// shows an error — it used to fall through `double.tryParse` as null and
/// silently *clear* the balance, so typing "45,000" wiped the very figure
/// being set and the tile snapped back to the SMS-derived number.
Future<void> showSetBalanceDialog(BuildContext context, Account account) async {
  final isCard = account.isCard;
  // A points wallet takes points and stores their ₹ value.
  final perPoint = account.pointsOf(1) == null ? null : account.pointValue;
  final manual = account.manualBalance;
  final ctrl = TextEditingController(
    text: manual == null
        ? ''
        : perPoint == null
        ? manual.toStringAsFixed(2)
        : fmtFieldNumber(manual / perPoint),
  );
  String? error;
  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [ctrl],
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          // Keyboard + multi-line helper text overflow a small landscape
          // viewport without this.
          scrollable: true,
          title: Text(isCard ? 'Set outstanding' : 'Set balance'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            onChanged: perPoint == null ? null : (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: isCard
                  ? 'Current outstanding'
                  : perPoint != null
                  ? 'Current points'
                  : 'Current balance',
              prefixText: perPoint == null ? '₹ ' : null,
              helperText: account.isWallet
                  ? (perPoint != null && parseAmount(ctrl.text) != null
                        ? '= ${fmtMoney(parseAmount(ctrl.text)! * perPoint)}'
                        : 'Transactions after it are added on. Leave blank '
                              'to clear it.')
                  : 'A newer bank alert takes over automatically. '
                        'Leave blank to go back to SMS figures only.',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final text = ctrl.text.trim();
                if (text.isEmpty) {
                  ctx.read<FinanceProvider>().setManualBalance(
                    account.id,
                    null,
                  );
                  Navigator.pop(ctx);
                  return;
                }
                final v = parseAmount(text);
                if (v == null) {
                  setState(() => error = 'Enter a number, e.g. 45000');
                  return;
                }
                ctx.read<FinanceProvider>().setManualBalance(
                  account.id,
                  perPoint == null ? v : v * perPoint,
                );
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showCreditLimitDialog(
  BuildContext context,
  Account account,
) async {
  final ctrl = TextEditingController(
    text: account.creditLimit?.toStringAsFixed(0) ?? '',
  );
  String? error;
  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [ctrl],
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          // Keyboard + multi-line helper text overflow a small landscape
          // viewport without this.
          scrollable: true,
          title: const Text('Credit limit'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Total credit limit',
              prefixText: '₹ ',
              helperText:
                  'Alerts state only the available limit. The total '
                  'is needed to work out what is owed. Leave blank to clear.',
              helperMaxLines: 4,
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final text = ctrl.text.trim();
                if (text.isEmpty) {
                  ctx.read<FinanceProvider>().setCreditLimit(account.id, null);
                  Navigator.pop(ctx);
                  return;
                }
                final v = parseAmount(text);
                if (v == null) {
                  setState(() => error = 'Enter a number, e.g. 300000');
                  return;
                }
                // 0 is not a limit — it used to store and report "₹0 owed"
                // on a card with a real balance.
                if (v <= 0) {
                  setState(
                    () => error =
                        'Enter an amount above 0, or leave blank to clear',
                  );
                  return;
                }
                ctx.read<FinanceProvider>().setCreditLimit(account.id, v);
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Savings goal target for a savings/asset account. Same input contract as
/// the credit-limit dialog: empty clears, an unreadable entry errors instead
/// of silently clearing.
Future<void> showSavingsGoalDialog(
  BuildContext context,
  Account account,
) async {
  final ctrl = TextEditingController(
    text: account.goalAmount?.toStringAsFixed(0) ?? '',
  );
  String? error;
  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [ctrl],
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          scrollable: true,
          title: const Text('Savings goal'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Target amount',
              prefixText: '₹ ',
              helperText:
                  'The account card shows progress and a projected date '
                  'from your recent deposits. Leave blank to clear.',
              helperMaxLines: 4,
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final text = ctrl.text.trim();
                if (text.isEmpty) {
                  ctx.read<FinanceProvider>().setSavingsGoal(account.id, null);
                  Navigator.pop(ctx);
                  return;
                }
                final v = parseAmount(text);
                if (v == null) {
                  setState(() => error = 'Enter a number, e.g. 500000');
                  return;
                }
                if (v <= 0) {
                  setState(
                    () => error =
                        'Enter an amount above 0, or leave blank to clear',
                  );
                  return;
                }
                ctx.read<FinanceProvider>().setSavingsGoal(account.id, v);
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Statement + payment due day for a card. Same input contract as the
/// credit-limit dialog: empty clears, an unreadable entry errors instead of
/// silently clearing.
Future<void> showCardCycleDialog(BuildContext context, Account account) async {
  final stmtCtrl = TextEditingController(
    text: account.statementDay?.toString() ?? '',
  );
  final dueCtrl = TextEditingController(text: account.dueDay?.toString() ?? '');
  String? stmtError;
  String? dueError;
  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [stmtCtrl, dueCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          scrollable: true,
          title: const Text('Statement & due dates'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: stmtCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Statement day',
                  helperText:
                      'Day of month the statement is generated. '
                      'Leave blank if unknown.',
                  helperMaxLines: 3,
                  errorText: stmtError,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: dueCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Payment due day',
                  helperText:
                      'Day of month the bill is due. It sets the '
                      '"bill due" reminder. Shorter months use their last '
                      'day. Leave blank to clear.',
                  helperMaxLines: 4,
                  errorText: dueError,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                // Empty clears; anything unreadable or out of range errors.
                (int?, String?) parseDay(String raw) {
                  final text = raw.trim();
                  if (text.isEmpty) return (null, null);
                  final v = int.tryParse(text);
                  if (v == null || v < 1 || v > 31) {
                    return (null, 'Enter a day between 1 and 31');
                  }
                  return (v, null);
                }

                final (stmt, sErr) = parseDay(stmtCtrl.text);
                final (due, dErr) = parseDay(dueCtrl.text);
                if (sErr != null || dErr != null) {
                  setState(() {
                    stmtError = sErr;
                    dueError = dErr;
                  });
                  return;
                }
                ctx.read<FinanceProvider>().setCardCycle(
                  account.id,
                  statementDay: stmt,
                  dueDay: due,
                );
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _CardFigures extends StatelessWidget {
  final Account account;

  /// Opens this card's transactions (the Spent this month tip's link).
  final void Function(String accountId) onView;
  const _CardFigures({required this.account, required this.onView});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final outstanding = finance.accountOutstanding(account);
    final available = finance.accountAvailable(account);
    final limit = finance.accountCreditLimit(account);
    final spent = finance.accountSpentThisMonth(account);
    final p = finance.accountProvenance(account);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                'Outstanding',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  outstanding == null ? 'Unknown' : fmtMoney(outstanding),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: scheme.error,
                  ),
                ),
              ),
            ),
          ],
        ),
        // No outstanding figure has two distinct causes, each with its own
        // remedy — name the right one instead of always asking for the
        // credit limit (which does nothing when no alert ever stated a
        // balance).
        if (outstanding == null) ...[
          const SizedBox(height: 4),
          Text(
            p.blocker == OutstandingBlocker.noAlert
                ? "No bank alert has stated this card's balance yet."
                : 'Bank alerts state only the available limit; the total '
                      'limit is needed.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 8),
          // The app's link pill: the one control that unblocks
          // "Outstanding Unknown".
          Align(
            alignment: Alignment.centerLeft,
            child: LinkPill(
              onTap: () => p.blocker == OutstandingBlocker.noAlert
                  ? showSetBalanceDialog(context, account)
                  : showCreditLimitDialog(context, account),
              label: p.blocker == OutstandingBlocker.noAlert
                  ? 'Set outstanding…'
                  : 'Set credit limit…',
            ),
          ),
        ] else ...[
          const SizedBox(height: 4),
          // Same "how was this calculated" line the bank tiles carry.
          Text(
            provenanceLine(p),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
        if (outstanding != null && limit != null && available != null) ...[
          const SizedBox(height: 10),
          AnimatedProgress(
            value: (limit == 0) ? 0 : (1 - available / limit).clamp(0.0, 1.0),
            minHeight: 8,
            borderRadius: const BorderRadius.all(Radius.circular(5)),
            color: scheme.error,
            backgroundColor: scheme.error.withValues(alpha: 0.12),
          ),
          const SizedBox(height: 6),
          Builder(
            builder: (context) {
              final estimated = finance.creditLimitIsEstimated(account);
              final text = Text(
                'Available ${fmtMoney(available)} of ${fmtMoney(limit)}'
                '${estimated ? ' (est.)' : ''}',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              );
              if (!estimated) return text;
              return InfoLabel(
                label: text,
                tip: InfoTip(
                  title: 'Estimated limit',
                  message:
                      '"Est." means the credit limit is estimated from the '
                      'highest available limit a bank alert ever reported. '
                      "Set the real limit from the card's menu for an exact "
                      'figure.',
                  link: InfoLink(
                    prompt: 'Know the real limit?',
                    label: 'Set the credit limit',
                    onTap: (c) => showCreditLimitDialog(c, account),
                  ),
                ),
              );
            },
          ),
        ],
        const SizedBox(height: 6),
        InfoLabel(
          label: Text(
            'Spent this month ${fmtMoney(spent)}',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          tip: InfoTip(
            title: 'Spent this month',
            message:
                'Spending on this card in the current calendar month, '
                'whatever month the dashboard shows. Transfers are left out.',
            link: InfoLink(
              prompt: 'See what makes it up?',
              label: "This card's transactions",
              onTap: (_) => onView(account.id),
            ),
          ),
        ),
        if (account.dueDay != null) ...[
          const SizedBox(height: 6),
          Builder(
            builder: (context) {
              final hasDues = outstanding != null && outstanding > 0;
              if (!hasDues) {
                return Text(
                  // Unknown is not zero: with no outstanding figure there
                  // is no telling whether anything is owed.
                  outstanding == null ? 'Dues unknown' : 'No dues',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                );
              }
              final s = cardBillStatus(account, DateTime.now())!;
              return Text(
                cardBillSubtitle(s),
                style: TextStyle(
                  // Imminent dues stand out; a comfortable gap — and a paid
                  // or not-yet-billed cycle — stays muted.
                  color: s.urgent ? scheme.error : scheme.onSurfaceVariant,
                  fontWeight: s.urgent ? FontWeight.w600 : null,
                  fontSize: 12,
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class _AccountMenu extends StatelessWidget {
  final Account account;
  const _AccountMenu({required this.account});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Account options',
      // Instant, not animated: the stock grow animation re-clamps the menu's
      // position every frame, so a menu opened near the bottom edge visibly
      // slid upward as it outgrew the space below the button. Rendering it
      // fully-formed lands it at its final position on the first frame.
      popUpAnimationStyle: const AnimationStyle(duration: Duration.zero),
      onSelected: (v) {
        switch (v) {
          case 'rename':
            _rename(context);
          case 'numbers':
            _showLinkedNumbers(context);
          case 'wallet':
            showWalletDetailsDialog(context, account);
          case 'type':
            _toggleType(context);
          case 'kind':
            _setKind(context);
          case 'goal':
            showSavingsGoalDialog(context, account);
          case 'limit':
            _setLimit(context);
          case 'cycle':
            showCardCycleDialog(context, account);
          case 'balance':
            showSetBalanceDialog(context, account);
          case 'merge':
            mergeAccountFlow(context, account);
          case 'close':
            closeAccountFlow(context, account);
          case 'reopen':
            context.read<FinanceProvider>().reopenAccount(account.id);
          case 'delete':
            deleteAccountFlow(context, account);
        }
      },
      // A closed account is an archive entry: everything except Reopen and
      // Delete is managing a live account, so the menu shrinks.
      itemBuilder: (_) => account.isClosed
          ? [
              const PopupMenuItem(value: 'reopen', child: Text('Reopen')),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete account'),
              ),
            ]
          : [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              // Wallets are entered by hand; no bank number resolves to one.
              if (!account.isWallet)
                const PopupMenuItem(
                  value: 'numbers',
                  child: Text('Linked numbers…'),
                ),
              if (account.isWallet)
                const PopupMenuItem(
                  value: 'wallet',
                  child: Text('Wallet details…'),
                ),
              const PopupMenuItem(value: 'type', child: Text('Change type…')),
              if (account.type == AccountType.savings)
                const PopupMenuItem(value: 'kind', child: Text('Kind & icon…')),
              if (account.type == AccountType.savings)
                const PopupMenuItem(value: 'goal', child: Text('Set goal…')),
              if (account.isCard)
                const PopupMenuItem(
                  value: 'limit',
                  child: Text('Set credit limit…'),
                ),
              if (account.isCard)
                const PopupMenuItem(
                  value: 'cycle',
                  child: Text('Statement & due dates…'),
                ),
              PopupMenuItem(
                value: 'balance',
                child: Text(
                  account.isCard ? 'Set outstanding…' : 'Set balance…',
                ),
              ),
              const PopupMenuItem(value: 'merge', child: Text('Merge into…')),
              if (account.type == AccountType.savings || account.isWallet)
                const PopupMenuItem(
                  value: 'close',
                  child: Text('Close account'),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete account'),
              ),
            ],
    );
  }

  /// Lists the account/card numbers (keys) linked to this account, with
  /// unlink buttons and an add flow.
  void _showLinkedNumbers(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => Consumer<FinanceProvider>(
        builder: (ctx, finance, _) {
          final current = finance.accountById(account.id);
          if (current == null) return const SizedBox.shrink();
          final keys = current.keys.toList()..sort();
          return AlertDialog(
            title: const Text('Linked numbers'),
            // Scrollable: an account can accumulate more linked numbers than
            // a small landscape screen has room for.
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (keys.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No numbers linked yet. SMS mentioning a linked '
                          'number are assigned to this account.',
                        ),
                      ),
                    for (final k in keys)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.tag, size: 18),
                        // Show "HDFC ••1234" instead of the raw key.
                        title: Text(k.replaceFirst(':', ' ••')),
                        trailing: IconButton(
                          tooltip: 'Unlink',
                          icon: const Icon(Icons.link_off, size: 18),
                          onPressed: () {
                            // How it was linked travels with the undo: an
                            // SMS-made number stays one.
                            final hand =
                                (finance.accountById(account.id) ?? account)
                                    .linkedByHand
                                    .contains(k);
                            finance.removeAccountKey(account.id, k);
                            // Relinking by hand means re-typing bank + digits;
                            // addAccountKey is the exact inverse, so offer it.
                            showUndoSnackBar(
                              context,
                              'Unlinked ${k.replaceFirst(':', ' ••')}',
                              () => finance.addAccountKey(
                                account.id,
                                k,
                                byHand: hand,
                              ),
                              icon: Icons.link_off,
                              tone: AppToastTone.removal,
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add number'),
                onPressed: () async {
                  final key = await showAccountKeyDialog(ctx);
                  if (key == null || !ctx.mounted) return;
                  final ok = await finance.addAccountKey(account.id, key);
                  if (!ok && ctx.mounted) {
                    showAppToast(
                      context,
                      'That number is already linked to another account.',
                      tone: AppToastTone.error,
                    );
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: account.name);
    await showDialog(
      context: context,
      builder: (ctx) => DisposeScope(
        disposables: [ctrl],
        child: StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Rename account'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: account.isWallet ? 'Login label' : 'Name',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              // Disabled while empty — Save used to pop and silently drop
              // the edit.
              FilledButton(
                onPressed: ctrl.text.trim().isEmpty
                    ? null
                    : () {
                        ctx.read<FinanceProvider>().renameAccount(
                          account.id,
                          ctrl.text.trim(),
                        );
                        Navigator.pop(ctx);
                      },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleType(BuildContext context) async {
    final finance = context.read<FinanceProvider>();
    final walletOk = finance.canBecomeWallet(account);
    final result = await showPickerSheet<AccountType>(
      context: context,
      title: 'Account type',
      items: [
        for (final t in AccountType.values)
          // An account with linked bank or card numbers can't be a wallet:
          // its SMS rows would land there.
          if (t != AccountType.wallet || walletOk || account.isWallet)
            PickerItem(
              value: t,
              label: t.label,
              leading: Icon(t.icon, size: 20),
            ),
      ],
      selected: account.type,
    );
    final t = result?.value;
    if (t == null || t == account.type || !context.mounted) return;
    // Crossing the wallet line changes what counts: say how much first.
    if (t == AccountType.wallet || account.isWallet) {
      final toWallet = t == AccountType.wallet;
      // Rows whose counting changes: all of them into a wallet, the
      // uncounted ones out of it.
      // Transfers never count either way, so they aren't in it.
      final n = finance
          .transactionsForAccount(account.id)
          .where(
            (r) =>
                !isTransferCategory(r.categoryId) &&
                (toWallet || !r.walletCounted),
          )
          .length;
      // Only banks and cards make up net balance; savings stay out anyway.
      final netType = toWallet ? account.type : t;
      final netMoves =
          netType == AccountType.bank || netType == AccountType.creditCard;
      final net = !netMoves
          ? ''
          : toWallet
          ? 'It leaves net balance.'
          : 'It joins net balance.';
      final ok = await showDialog<bool>(
        context: context,
        builder: (dCtx) => AlertDialog(
          title: Text(
            toWallet
                ? 'Make "${account.name}" a wallet?'
                : 'Make "${account.displayName}" a ${t.label.toLowerCase()} '
                      'account?',
          ),
          content: Text(
            [
              if (n > 0)
                toWallet
                    ? (n == 1
                          ? '1 transaction on it stops counting in spending '
                                'and income. You can count it again from its '
                                'edit sheet.'
                          : '$n transactions on it stop counting in spending '
                                'and income. You can count any of them again '
                                'from their edit sheets.')
                    : (n == 1
                          ? '1 transaction on it starts counting in spending '
                                'and income.'
                          : '$n transactions on it start counting in '
                                'spending and income.'),
              if (net.isNotEmpty) net,
              if (n == 0 && net.isEmpty) 'Nothing on it changes.',
            ].join(' '),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: const Text('Change'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    // The navigator's context, not this menu's: changing the type can move
    // the card off this page (the last Savings account) and unmount it.
    final navContext = Navigator.of(context).context;
    final changed = await finance.setAccountType(account.id, t);
    if (!changed || !navContext.mounted) return;
    if (t == AccountType.wallet) {
      final updated = finance.accountById(account.id);
      if (updated != null) await showWalletDetailsDialog(navContext, updated);
    }
  }

  void _setLimit(BuildContext context) =>
      showCreditLimitDialog(context, account);

  /// Custom kind label + icon for a savings/asset account.
  Future<void> _setKind(BuildContext context) async {
    final ctrl = TextEditingController(text: account.kind ?? '');
    var kindIcon = account.kindIcon ?? 'savings';
    await showDialog(
      context: context,
      builder: (ctx) => DisposeScope(
        disposables: [ctrl],
        child: StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Kind & icon'),
            // Scrollable: the keyboard (autofocused field) plus the icon grid
            // does not fit a small screen otherwise. Top padding keeps the
            // first field's floating label from clipping.
            content: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Kind',
                      hintText: 'e.g. RD, Stocks, Gold',
                      helperText: 'Leave blank for plain "Savings"',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _AssetIconPicker(
                    selected: kindIcon,
                    onChanged: (v) => setState(() => kindIcon = v),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  ctx.read<FinanceProvider>().setAccountKind(
                    account.id,
                    ctrl.text,
                    kindIcon: kindIcon,
                  );
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// No confirm dialog: closing is fully reversible (Reopen / the snackbar),
/// unlike merge and delete which destroy the account's identity.
void closeAccountFlow(BuildContext context, Account account) {
  final finance = context.read<FinanceProvider>();
  finance.closeAccount(account.id);
  showUndoSnackBar(
    context,
    'Closed "${account.displayName}"',
    () => finance.reopenAccount(account.id),
    icon: Icons.archive_outlined,
    tone: AppToastTone.removal,
  );
}

Future<void> mergeAccountFlow(BuildContext context, Account account) async {
  final finance = context.read<FinanceProvider>();
  // Wallets merge only with wallets, money accounts only with money
  // accounts (see FinanceProvider.mergeAccounts).
  final others = finance.openAccounts
      .where((a) => a.id != account.id && a.isWallet == account.isWallet)
      .toList();
  if (others.isEmpty) {
    showAppToast(
      context,
      account.isWallet
          ? 'No other wallet to merge into.'
          : 'No other account to merge into.',
    );
    return;
  }
  // Picking a target only selects it — the merge itself is confirmed
  // separately: it permanently removes this account (name, balance,
  // credit limit) with no undo.
  final result = await showPickerSheet<Account>(
    context: context,
    title: 'Merge "${account.displayName}" into…',
    items: [
      for (final a in others)
        PickerItem(
          value: a,
          label: a.displayName,
          leading: Icon(a.icon, size: 20),
        ),
    ],
  );
  final a = result?.value;
  if (a == null || !context.mounted) return;
  final txCount = finance.transactions
      .where((t) => t.acctKey != null && account.keys.contains(t.acctKey))
      .length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dCtx) => AlertDialog(
      title: Text('Merge "${account.displayName}"?'),
      content: Text(
        '$txCount transaction${txCount == 1 ? '' : 's'} '
        'move${txCount == 1 ? 's' : ''} to "${a.displayName}". '
        '"${account.displayName}" is removed permanently, along '
        'with its name, type, manual balance and credit '
        'limit. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dCtx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dCtx, true),
          child: const Text('Merge'),
        ),
      ],
    ),
  );
  if (ok == true) {
    finance.mergeAccounts(account.id, a.id);
  }
}

Future<void> deleteAccountFlow(BuildContext context, Account account) async {
  final finance = context.read<FinanceProvider>();
  // Off a wallet its uncounted rows start counting; Close keeps them out.
  final uncounted = !account.isWallet
      ? 0
      : finance
            .transactionsForAccount(account.id)
            .where((t) => !t.walletCounted && !isTransferCategory(t.categoryId))
            .length;
  final ok = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete "${account.displayName}"?'),
      content: Text(
        [
          'The account is removed. Its transactions stay but become '
              'unassigned. This does not delete any transactions.',
          if (uncounted == 1)
            '1 of them is out of spending and income now and would count '
                'once unassigned.',
          if (uncounted > 1)
            '$uncounted of them are out of spending and income now and '
                'would count once unassigned.',
          if (uncounted > 0 && !account.isClosed)
            'Close the wallet instead to keep '
                '${uncounted == 1 ? 'it' : 'them'} out.',
        ].join(' '),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        if (uncounted > 0 && !account.isClosed)
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'close'),
            child: const Text('Close instead'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'delete'),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (ok == 'close') closeAccountFlow(context, account);
  if (ok == 'delete') finance.deleteAccount(account.id);
}

/// Bank + last-4 picker, returning an account key like `"HDFC:1234"`.
/// The bank list is exactly the set of codes the SMS parser can produce, so
/// a manually linked number is guaranteed to match future imports.
Future<String?> showAccountKeyDialog(BuildContext context) async {
  var bankCode = 'HDFC';
  final digitsCtrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [digitsCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Account or card number'),
          // Scrollable: keyboard + dropdown clip the fixed column on small
          // screens and in landscape. Top padding keeps the first field's
          // floating label from clipping.
          content: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppDropdownField<String>(
                  label: 'Bank',
                  value: bankCode,
                  items: [
                    for (final code in SmsTxnParser.knownBankCodes)
                      PickerItem(value: code, label: code),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => bankCode = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: digitsCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  // Rebuild so the Add button's enabled state tracks the input.
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Last digits',
                    helperText:
                        'The last 3 or 4 digits shown in the bank\'s SMS',
                    helperMaxLines: 2,
                    counterText: '',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            // Disabled until valid — a button that swallows the tap silently
            // reads as broken.
            Builder(
              builder: (_) {
                final digits = digitsCtrl.text.trim();
                final valid =
                    digits.length >= 3 &&
                    digits.length <= 4 &&
                    int.tryParse(digits) != null;
                return FilledButton(
                  onPressed: valid
                      ? () => Navigator.pop(ctx, '$bankCode:$digits')
                      : null,
                  child: const Text('Add'),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}

/// Icon choices for savings/asset accounts (RD, stocks, gold, property…).
class _AssetIconPicker extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  const _AssetIconPicker({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in kAssetIconChoices.entries)
          Semantics(
            button: true,
            selected: entry.key == selected,
            label: entry.key,
            excludeSemantics: true,
            // 48dp target around the 40dp visual — Material's minimum.
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  onTap: () => onChanged(entry.key),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: entry.key == selected
                          ? scheme.primary.withValues(alpha: 0.2)
                          : scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      border: entry.key == selected
                          ? Border.all(color: scheme.primary, width: 2)
                          : null,
                    ),
                    child: Icon(
                      entry.value,
                      size: 20,
                      color: entry.key == selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A wallet's service, money or points, and ₹ per point. Changing the
/// value keeps the point count (FinanceProvider.setWalletDetails).
Future<void> showWalletDetailsDialog(
  BuildContext context,
  Account account,
) async {
  final serviceCtrl = TextEditingController(text: account.service ?? '');
  final valueCtrl = TextEditingController(
    text: account.pointValue == null
        ? ''
        : fmtPerPointField(account.pointValue!),
  );
  var holdsPoints = account.holdsPoints;
  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [serviceCtrl, valueCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final value = parseAmount(valueCtrl.text);
          final ready = !holdsPoints || (value != null && value > 0);
          return AlertDialog(
            title: const Text('Wallet details'),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                TextField(
                  controller: serviceCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Service',
                    hintText: 'e.g. Amazon Pay, Zomato',
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Money')),
                    ButtonSegment(value: true, label: Text('Points')),
                  ],
                  selected: {holdsPoints},
                  onSelectionChanged: (s) =>
                      setState(() => holdsPoints = s.first),
                ),
                if (holdsPoints) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: valueCtrl,
                    onChanged: (_) => setState(() {}),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Value per point',
                      prefixText: '₹ ',
                      hintText: 'e.g. 0.25',
                      helperText: 'Past transactions keep their ₹ amounts.',
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: !ready
                    ? null
                    : () {
                        ctx.read<FinanceProvider>().setWalletDetails(
                          account.id,
                          service: serviceCtrl.text,
                          holdsPoints: holdsPoints,
                          pointValue: holdsPoints ? value : null,
                        );
                        Navigator.pop(ctx);
                      },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Creates an account by hand: name, type, and optionally a first linked
/// number so imports start matching immediately.
Future<void> showAddAccountDialog(
  BuildContext context, {
  AccountType? initialType,
}) async {
  final nameCtrl = TextEditingController();
  final kindCtrl = TextEditingController();
  final serviceCtrl = TextEditingController();
  final pointValueCtrl = TextEditingController();
  final balanceCtrl = TextEditingController();
  // A page's own empty state opens on its own type.
  var type = initialType ?? AccountType.bank;
  var kindIcon = 'savings';
  var holdsPoints = false;
  String? key;
  // Re-entrancy latch: Create awaits the account write before popping, and
  // a second tap in that window minted a duplicate account.
  var saving = false;

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [
        nameCtrl,
        kindCtrl,
        serviceCtrl,
        pointValueCtrl,
        balanceCtrl,
      ],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final wallet = type == AccountType.wallet;
          final pointValue = parseAmount(pointValueCtrl.text);
          final balanceText = balanceCtrl.text.trim();
          final balance = parseAmount(balanceText);
          // Points need a value per point to be stored in ₹; a typed
          // balance must read as a number.
          final walletReady =
              !wallet ||
              ((!holdsPoints || (pointValue != null && pointValue > 0)) &&
                  (balanceText.isEmpty || balance != null));
          return AlertDialog(
            title: const Text('New account'),
            // Narrower side margins than the 40dp default: four type
            // segments need the width on a small phone.
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            // Top padding keeps the Name field's floating label from clipping.
            content: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Type first: picking Wallet swaps the fields below it.
                  // No per-segment icons: with four segments the icon + label
                  // won't fit the dialog width and the labels wrap ("Sa/vin/gs").
                  SegmentedButton<AccountType>(
                    showSelectedIcon: false,
                    // Tight padding leaves the labels their size.
                    style: const ButtonStyle(
                      padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 4),
                      ),
                    ),
                    segments: [
                      for (final t in AccountType.values)
                        ButtonSegment(
                          value: t,
                          tooltip: t.label,
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              t == AccountType.creditCard ? 'Card' : t.label,
                              maxLines: 1,
                            ),
                          ),
                        ),
                    ],
                    selected: {type},
                    onSelectionChanged: (s) => setState(() => type = s.first),
                  ),
                  const SizedBox(height: 12),
                  if (wallet) ...[
                    TextField(
                      controller: serviceCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Service',
                        hintText: 'e.g. Amazon Pay, Zomato',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: wallet
                          ? 'Login label (e.g. me, mom)'
                          : 'Name (e.g. HDFC Salary)',
                    ),
                  ),
                  if (wallet) ...[
                    const SizedBox(height: 12),
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: false, label: Text('Money')),
                        ButtonSegment(value: true, label: Text('Points')),
                      ],
                      selected: {holdsPoints},
                      onSelectionChanged: (s) =>
                          setState(() => holdsPoints = s.first),
                    ),
                    if (holdsPoints) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: pointValueCtrl,
                        onChanged: (_) => setState(() {}),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Value per point',
                          prefixText: '₹ ',
                          hintText: 'e.g. 0.25',
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: balanceCtrl,
                      onChanged: (_) => setState(() {}),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: holdsPoints
                            ? 'Points now (optional)'
                            : 'Balance now (optional)',
                        prefixText: holdsPoints ? null : '₹ ',
                        helperText:
                            holdsPoints && balance != null && pointValue != null
                            ? '= ${fmtMoney(balance * pointValue)}'
                            : 'Wallets stay out of net balance.',
                        errorText: balanceText.isNotEmpty && balance == null
                            ? 'Enter a number, e.g. 840'
                            : null,
                      ),
                    ),
                  ],
                  if (type == AccountType.savings) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: kindCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Kind',
                        hintText: 'e.g. RD, Stocks, Gold, Mutual fund',
                      ),
                    ),
                    const SizedBox(height: 10),
                    _AssetIconPicker(
                      selected: kindIcon,
                      onChanged: (v) => setState(() => kindIcon = v),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Record deposits or purchases as "To savings" '
                      'transactions from your bank account. Keep the current '
                      'value with '
                      '"Set balance…" in this account\'s ⋮ menu.',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                  // Wallets are entered by hand: no bank number to link.
                  if (!wallet) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      icon: Icon(
                        key == null ? Icons.add_link : Icons.link,
                        size: 18,
                      ),
                      label: Text(
                        key == null
                            ? 'Link a number (optional)'
                            : key!.replaceFirst(':', ' ••'),
                      ),
                      onPressed: () async {
                        final k = await showAccountKeyDialog(ctx);
                        if (k != null) setState(() => key = k);
                      },
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                // Disabled while the name is empty instead of a silent no-op,
                // and while a save is already in flight.
                onPressed:
                    nameCtrl.text.trim().isEmpty || saving || !walletReady
                    ? null
                    : () async {
                        setState(() => saving = true);
                        final name = nameCtrl.text.trim();
                        final finance = ctx.read<FinanceProvider>();
                        final navigator = Navigator.of(ctx);
                        final messenger = ScaffoldMessenger.of(context);
                        final kind = kindCtrl.text.trim();
                        // A throw used to leave the dialog open forever with no
                        // message — surface it and keep the dialog for a retry.
                        try {
                          final id = await finance.addAccount(
                            name: name,
                            type: type,
                            kind: type == AccountType.savings && kind.isNotEmpty
                                ? kind
                                : null,
                            kindIcon: type == AccountType.savings
                                ? kindIcon
                                : null,
                            service: wallet ? serviceCtrl.text.trim() : null,
                            holdsPoints: wallet && holdsPoints,
                            pointValue: wallet && holdsPoints
                                ? pointValue
                                : null,
                          );
                          // Stored in ₹: points at their value.
                          if (wallet && balance != null) {
                            await finance.setManualBalance(
                              id,
                              holdsPoints ? balance * pointValue! : balance,
                            );
                          }
                          if (key != null && !wallet) {
                            final ok = await finance.addAccountKey(id, key!);
                            if (!ok) {
                              showAppToastOn(
                                messenger,
                                'That number is already linked to another '
                                'account. The account was created without it.',
                                tone: AppToastTone.error,
                              );
                            }
                          }
                          navigator.pop();
                        } catch (e) {
                          setState(() => saving = false);
                          showAppToastOn(
                            messenger,
                            'Could not create account: $e',
                            tone: AppToastTone.error,
                          );
                        }
                      },
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    ),
  );
}
