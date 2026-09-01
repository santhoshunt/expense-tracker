import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../providers/finance_provider.dart';
import '../services/sms_parser.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import '../widgets/anchored_picker.dart';
import '../widgets/balance_breakdown.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/glossy.dart';
import '../widgets/motion.dart';
import '../widgets/section_header.dart';
import '../widgets/undo_snackbar.dart';

class AccountsScreen extends StatefulWidget {
  /// Tapping an account jumps to its filtered transaction list.
  final void Function(String accountId) onViewAccount;

  const AccountsScreen({super.key, required this.onViewAccount});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  AccountType? _typeFilter; // null = all

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    bool visible(Account a) => _typeFilter == null || a.type == _typeFilter;
    final accounts = finance.openAccounts.where(visible).toList();
    final closed = finance.closedAccounts.where(visible).toList();
    final scheme = Theme.of(context).colorScheme;

    final net = finance.netWorth;

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
                              color: scheme.primary,
                            ),
                          ),
                          Text(
                            'Net across ${finance.openAccounts.length} '
                            'account'
                            '${finance.openAccounts.length == 1 ? '' : 's'}'
                            ' · tap for breakdown',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant),
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
        // Type filter: All / Bank / Cards / Savings.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GlassSegmented<AccountType?>(
            options: const [
              (null, 'All'),
              (AccountType.bank, 'Banks'),
              (AccountType.creditCard, 'Cards'),
              (AccountType.savings, 'Savings'),
            ],
            selected: _typeFilter,
            onChanged: (t) => setState(() => _typeFilter = t),
          ),
        ),
        Expanded(
          child: accounts.isEmpty && closed.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      _typeFilter != null
                          ? 'No ${_typeFilter!.label.toLowerCase()} '
                                'accounts yet.'
                          : 'No accounts yet.\n\nAccounts are detected '
                                'automatically from the account and card '
                                'numbers in your bank SMS. Import messages '
                                'to populate them.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Builder(
                  builder: (context) {
                    // Flat heterogeneous list (Rules-tab pattern): open
                    // cards, then a muted closed section. Closed cards keep
                    // full tap/menu behavior — only dimmed.
                    final items = <Widget>[
                      for (final a in accounts)
                        _AccountCard(account: a, onView: widget.onViewAccount),
                      if (closed.isNotEmpty) ...[
                        UppercaseSectionHeader(
                          'Closed accounts',
                          color: scheme.onSurfaceVariant,
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
        ),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  final Account account;
  final void Function(String accountId) onView;

  const _AccountCard({required this.account, required this.onView});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final isCard = account.isCard;
    final txCount = finance.transactionCountForAccount(account.id);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: FrostedPanel(
        radius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => onView(account.id),
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
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      child: Icon(
                        account.icon,
                        color: categoryGlyphColor(context, scheme.primary),
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account.name,
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${account.typeLabel} · $txCount '
                            'txn${txCount == 1 ? '' : 's'}',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _AccountMenu(account: account),
                  ],
                ),
                const SizedBox(height: 14),
                if (isCard)
                  _CardFigures(account: account)
                else
                  _BankBalance(account: account),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BankBalance extends StatelessWidget {
  final Account account;
  const _BankBalance({required this.account});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final (source, asOf) = finance.accountBalanceProvenance(account);
    // Say where the figure comes from — "why is it showing this number"
    // should be readable off the tile, not reverse-engineered.
    final provenance = switch (source) {
      BalanceSource.manual =>
        'Set by you${asOf == null ? '' : ' · ${fmtDateMaybeTime(asOf)}'}',
      BalanceSource.alert =>
        'From bank alert${asOf == null ? '' : ' · ${fmtDateMaybeTime(asOf)}'}',
      BalanceSource.ledger => 'From transaction history',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Balance', style: TextStyle(color: scheme.onSurfaceVariant)),
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
                    color: scheme.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          provenance,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
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
                  'Alerts state only the available limit — the total '
                  'is needed to work out what is owed. Leave blank to clear.',
              helperMaxLines: 4,
              border: const OutlineInputBorder(),
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
                        'Enter an amount above 0 — leave empty to clear',
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

class _CardFigures extends StatelessWidget {
  final Account account;
  const _CardFigures({required this.account});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final outstanding = finance.accountOutstanding(account);
    final available = finance.accountAvailable(account);
    final limit = finance.accountCreditLimit(account);
    final spent = finance.accountSpentThisMonth(account);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Outstanding',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  outstanding == null ? '—' : fmtMoney(outstanding),
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
        // No outstanding figure means the total limit is unknown: alerts state
        // only what is still available, and paying a bill raises that — so the
        // "largest ever seen" estimate tracks the newest figure and the
        // subtraction collapses to zero. Ask for the real limit instead of
        // reporting a confident ₹0.
        if (outstanding == null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => showCreditLimitDialog(context, account),
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text("Set credit limit to see what's owed"),
              // Keep the small text, not the small target: Size.zero +
              // shrinkWrap left ~24dp of tap height on the one control that
              // unblocks "Outstanding —".
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 4),
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          )
        else if (limit != null && available != null) ...[
          const SizedBox(height: 10),
          AnimatedProgress(
            value: (limit == 0) ? 0 : (1 - available / limit).clamp(0.0, 1.0),
            minHeight: 8,
            borderRadius: const BorderRadius.all(Radius.circular(5)),
            color: scheme.error,
            backgroundColor: scheme.error.withValues(alpha: 0.12),
          ),
          const SizedBox(height: 6),
          Text(
            'Available ${fmtMoney(available)} of ${fmtMoney(limit)}'
            '${account.creditLimit == null ? ' (est.)' : ''}',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          'Spent this month ${fmtMoney(spent)}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
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
          case 'type':
            _toggleType(context);
          case 'kind':
            _setKind(context);
          case 'limit':
            _setLimit(context);
          case 'balance':
            _setBalance(context);
          case 'merge':
            _merge(context);
          case 'close':
            _close(context);
          case 'reopen':
            context.read<FinanceProvider>().reopenAccount(account.id);
          case 'delete':
            _delete(context);
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
              const PopupMenuItem(
                value: 'numbers',
                child: Text('Linked numbers…'),
              ),
              const PopupMenuItem(value: 'type', child: Text('Change type…')),
              if (account.type == AccountType.savings)
                const PopupMenuItem(value: 'kind', child: Text('Kind & icon…')),
              if (account.isCard)
                const PopupMenuItem(
                  value: 'limit',
                  child: Text('Set credit limit'),
                ),
              PopupMenuItem(
                value: 'balance',
                child: Text(
                  account.isCard ? 'Set outstanding…' : 'Set balance…',
                ),
              ),
              const PopupMenuItem(value: 'merge', child: Text('Merge into…')),
              if (account.type == AccountType.savings)
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
                            finance.removeAccountKey(account.id, k);
                            // Relinking by hand means re-typing bank + digits;
                            // addAccountKey is the exact inverse, so offer it.
                            showUndoSnackBar(
                              context,
                              'Unlinked ${k.replaceFirst(':', ' ••')}',
                              () => finance.addAccountKey(account.id, k),
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'That number is already linked to another account.',
                        ),
                      ),
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
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
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

  void _toggleType(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Account type'),
        children: [
          for (final t in AccountType.values)
            SimpleDialogOption(
              onPressed: () {
                ctx.read<FinanceProvider>().setAccountType(account.id, t);
                Navigator.pop(ctx);
              },
              child: Row(
                children: [
                  Icon(t.icon, size: 20),
                  const SizedBox(width: 12),
                  Expanded(child: Text(t.label)),
                  if (t == account.type)
                    Icon(
                      Icons.check,
                      size: 18,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
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
                      border: OutlineInputBorder(),
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

  /// Manual balance (banks) / outstanding (cards). The entered figure wins
  /// until a newer SMS-reported one arrives.
  ///
  /// Only an explicitly empty field clears the value. An unreadable entry
  /// shows an error — it used to fall through `double.tryParse` as null and
  /// silently *clear* the balance, so typing "45,000" wiped the very figure
  /// being set and the tile snapped back to the SMS-derived number.
  Future<void> _setBalance(BuildContext context) async {
    final isCard = account.isCard;
    final ctrl = TextEditingController(
      text: account.manualBalance?.toStringAsFixed(2) ?? '',
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
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: isCard ? 'Current outstanding' : 'Current balance',
                prefixText: '₹ ',
                helperText:
                    'A newer bank alert takes over automatically. '
                    'Leave blank to go back to SMS figures only.',
                border: const OutlineInputBorder(),
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
                  ctx.read<FinanceProvider>().setManualBalance(account.id, v);
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

  /// No confirm dialog: closing is fully reversible (Reopen / the snackbar),
  /// unlike merge and delete which destroy the account's identity.
  void _close(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    finance.closeAccount(account.id);
    showUndoSnackBar(
      context,
      'Closed "${account.name}"',
      () => finance.reopenAccount(account.id),
    );
  }

  void _merge(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    final others = finance.openAccounts
        .where((a) => a.id != account.id)
        .toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other account to merge into.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Merge "${account.name}" into…'),
        children: [
          for (final a in others)
            SimpleDialogOption(
              // Picking a target only selects it — the merge itself is
              // confirmed separately: it permanently removes this account
              // (name, balance, credit limit) with no undo.
              onPressed: () async {
                final txCount = finance.transactions
                    .where(
                      (t) =>
                          t.acctKey != null && account.keys.contains(t.acctKey),
                    )
                    .length;
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (dCtx) => AlertDialog(
                    title: Text('Merge "${account.name}"?'),
                    content: Text(
                      '$txCount transaction${txCount == 1 ? '' : 's'} '
                      'move${txCount == 1 ? 's' : ''} to "${a.name}". '
                      '"${account.name}" is removed permanently, along '
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
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(a.name),
              ),
            ),
        ],
      ),
    );
  }

  void _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${account.name}"?'),
        content: const Text(
          'The account is removed. Its transactions stay but become '
          'unassigned. This does not delete any transactions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      context.read<FinanceProvider>().deleteAccount(account.id);
    }
  }
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
          title: const Text('Account / card number'),
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
                  // 39 opaque codes — searchable by design.
                  searchable: true,
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
                    helperText: 'The last 3–4 digits shown in the bank\'s SMS',
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

/// Creates an account by hand: name, type, and optionally a first linked
/// number so imports start matching immediately.
Future<void> showAddAccountDialog(BuildContext context) async {
  final nameCtrl = TextEditingController();
  final kindCtrl = TextEditingController();
  var type = AccountType.bank;
  var kindIcon = 'savings';
  String? key;
  // Re-entrancy latch: Create awaits the account write before popping, and
  // a second tap in that window minted a duplicate account.
  var saving = false;

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [nameCtrl, kindCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('New account'),
          // Top padding keeps the Name field's floating label from clipping.
          content: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Name (e.g. HDFC Salary)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                // No per-segment icons: with three segments the icon + label
                // won't fit the dialog width and the labels wrap ("Sa/vin/gs").
                SegmentedButton<AccountType>(
                  showSelectedIcon: false,
                  segments: [
                    for (final t in AccountType.values)
                      ButtonSegment(
                        value: t,
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
                if (type == AccountType.savings) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: kindCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Kind',
                      hintText: 'e.g. RD, Stocks, Gold, Mutual fund',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _AssetIconPicker(
                    selected: kindIcon,
                    onChanged: (v) => setState(() => kindIcon = v),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Record deposits/purchases as "To savings" transactions from '
                    'your bank account; keep the current value with '
                    '"Set balance…" in this account\'s ⋮ menu.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
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
              onPressed: nameCtrl.text.trim().isEmpty || saving
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
                        );
                        if (key != null) {
                          final ok = await finance.addAccountKey(id, key!);
                          if (!ok) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'That number is already linked to another account — '
                                  'account created without it.',
                                ),
                              ),
                            );
                          }
                        }
                        navigator.pop();
                      } catch (e) {
                        setState(() => saving = false);
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text('Could not create account: $e'),
                          ),
                        );
                      }
                    },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    ),
  );
}
