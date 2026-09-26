import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/format.dart';
import '../widgets/empty_state.dart';
import '../widgets/fold_section.dart';
import '../widgets/glossy.dart';
import '../widgets/info_tip.dart';
import '../widgets/undo_snackbar.dart';
import 'add_transaction_sheet.dart';

/// Who owes you: everyone named on a split bill, with what is still to come
/// back. A person's repayments pay off their oldest bills first; tapping a
/// person opens their bills and the ways to record, link or settle.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  /// Folded by default and per visit: settled people are history.
  bool _settledOpen = false;

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final all = finance.peopleBalances;
    final owing = [
      for (final b in all)
        if (b.owed > 0 || b.credit > 0) b,
    ];
    final settled = [
      for (final b in all)
        if (b.owed <= 0 && b.credit <= 0) b,
    ];
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final owers = owing.where((b) => b.owed > 0).length;

    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Who owes you')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
          children: [
            InfoLabel(
              label: Text('Owed to you', style: text.titleMedium),
              tip: const InfoTip(
                title: 'Owed to you',
                message:
                    'Each person on a split bill owes you their amount. Record '
                    'what they pay back as Repaid to me (a transfer, never '
                    'income); it pays off their oldest bills first, and part '
                    'payments count. Splits without names are not counted. '
                    'Mark a bill settled when it was paid outside the app.',
              ),
            ),
            const SizedBox(height: 4),
            Text(
              owers == 0
                  ? 'Nobody owes you anything right now.'
                  : '${fmtMoney(finance.totalOwed)} from $owers '
                        '${owers == 1 ? 'person' : 'people'}',
              style: muted,
            ),
            const SizedBox(height: 12),
            FrostedPanel(
              radius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (all.isEmpty)
                      const EmptyState(
                        compact: true,
                        icon: Icons.group_outlined,
                        message:
                            'Tick Group split payment on an expense and add '
                            'who owes what.',
                      )
                    else if (owing.isEmpty)
                      const EmptyState(
                        compact: true,
                        icon: Icons.check_circle_outline,
                        message: 'Everyone is settled up.',
                      ),
                    for (final b in owing)
                      _PersonTile(balance: b, page: context),
                  ],
                ),
              ),
            ),
            if (settled.isNotEmpty)
              FoldSection(
                title: 'Settled (${settled.length})',
                open: _settledOpen,
                onToggle: () => setState(() => _settledOpen = !_settledOpen),
                children: [
                  for (final b in settled)
                    _PersonTile(balance: b, page: context),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

String _initials(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  final letters = [
    for (final w in words.take(2))
      if (w.isNotEmpty) w.characters.first.toUpperCase(),
  ];
  return letters.isEmpty ? '?' : letters.join();
}

String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';

class _PersonTile extends StatelessWidget {
  final PersonBalance balance;

  /// The page itself, not this tile: the list changes when an action
  /// settles someone, which can unmount the tile before its Undo toast.
  final BuildContext page;

  const _PersonTile({required this.balance, required this.page});

  @override
  Widget build(BuildContext context) {
    final b = balance;
    final text = Theme.of(context).textTheme;
    final parts = [
      if (b.open.isNotEmpty) ...[
        _count(b.open.length, 'open bill', 'open bills'),
        'oldest ${fmtDateCompact(b.open.first.bill.date)}',
      ] else
        'All settled',
      if (b.credit > 0) '${fmtMoney(b.credit)} paid ahead',
    ];
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 18,
        child: Text(_initials(b.name), style: text.labelMedium),
      ),
      title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(parts.join(' · '), style: text.bodySmall),
      trailing: b.owed > 0
          ? Text(
              fmtMoney(b.owed),
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            )
          : null,
      onTap: () => showPersonSheet(page, b.key),
    );
  }
}

/// [key]'s bills and repayments, with the ways to record a repayment, link
/// one that already arrived, or mark bills settled. Reads the balance live,
/// so it follows every change made from inside it.
Future<void> showPersonSheet(BuildContext context, String key) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => _PersonSheet(personKey: key, page: context),
  );
}

class _PersonSheet extends StatefulWidget {
  final String personKey;

  /// The page under the sheet: toasts and the add sheet open from it, since
  /// the actions close this sheet first.
  final BuildContext page;

  const _PersonSheet({required this.personKey, required this.page});

  @override
  State<_PersonSheet> createState() => _PersonSheetState();
}

class _PersonSheetState extends State<_PersonSheet> {
  bool _settledOpen = false;

  Future<void> _record(PersonBalance b) async {
    final finance = context.read<FinanceProvider>();
    final page = widget.page;
    Navigator.pop(context);
    final id = await showAddTransactionSheet(
      page,
      prefill: TxPrefill(
        categoryId: kRepaidToMeCategoryId,
        amount: b.owed > 0 ? b.owed : null,
        person: b.name,
      ),
    );
    if (id == null || !page.mounted) return;
    showUndoSnackBar(
      page,
      'Recorded a repayment from ${b.name}',
      () => finance.deleteTransaction(id),
      icon: Icons.payments_outlined,
      tone: AppToastTone.success,
    );
  }

  Future<void> _link(PersonBalance b) async {
    final finance = context.read<FinanceProvider>();
    final page = widget.page;
    final candidates = finance.repaymentCandidates(near: b.owed);
    Navigator.pop(context);
    final picked = await showModalBottomSheet<Tx>(
      context: page,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _LinkPicker(name: b.name, candidates: candidates),
    );
    if (picked == null || !page.mounted) return;
    final before = await finance.linkRepayment(picked.id, b.name);
    if (before == null || !page.mounted) return;
    showUndoSnackBar(
      page,
      'Linked ${fmtMoney(picked.amount)} from ${b.name}',
      () => finance.restoreEditedTransactions([before]),
      icon: Icons.link,
    );
  }

  Future<void> _settle(PersonBalance b, {Tx? bill}) async {
    final finance = context.read<FinanceProvider>();
    final page = widget.page;
    // Closed first: the Undo toast shows on the page, under this sheet.
    Navigator.pop(context);
    final before = await finance.settleShares(b.name, billId: bill?.id);
    if (before.isEmpty || !page.mounted) return;
    showUndoSnackBar(
      page,
      bill == null
          ? 'Marked ${b.name} settled'
          : 'Marked ${b.name}\'s share settled',
      () => finance.restoreEditedTransactions(before),
      icon: Icons.task_alt,
    );
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final b = finance.peopleBalances
        .where((p) => p.key == widget.personKey)
        .firstOrNull;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    if (b == null) {
      return const SafeArea(
        child: EmptyState(
          compact: true,
          icon: Icons.group_outlined,
          message: 'Nothing on record for this person any more.',
        ),
      );
    }
    final canLink = finance.repaymentCandidates(near: b.owed).isNotEmpty;
    String billTitle(Tx t) =>
        t.note.isNotEmpty ? t.note.split('\n').first : t.category.label;

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text(b.name, style: text.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(
            b.owed > 0
                ? 'Owes you ${fmtMoney(b.owed)}'
                : b.credit > 0
                ? 'Paid ${fmtMoney(b.credit)} ahead'
                : 'Settled up',
            style: text.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.payments_outlined),
            title: const Text('Record repayment'),
            // A bank SMS for the same money would import it a second time.
            subtitle: const Text(
              'For cash. Paid by UPI or bank? Link its SMS instead',
            ),
            onTap: () => _record(b),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Link a payment you received'),
            subtitle: Text(
              canLink
                  ? 'A UPI credit or transfer already here'
                  : 'No money in from the last 90 days to link',
            ),
            enabled: canLink,
            onTap: () => _link(b),
          ),
          if (b.owed > 0)
            ListTile(
              leading: const Icon(Icons.task_alt),
              title: const Text('Mark all settled'),
              subtitle: const Text('Paid outside the app, or let go'),
              onTap: () => _settle(b),
            ),
          if (b.open.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Open bills', style: text.titleSmall),
            Text(
              'Long-press a bill to mark just that one settled.',
              style: muted,
            ),
            for (final s in b.open)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  billTitle(s.bill),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${fmtDateCompact(s.bill.date)} · share '
                  '${fmtMoney(s.share)}',
                ),
                trailing: Text('${fmtMoney(s.left)} left'),
                onTap: () => showAddTransactionSheet(context, existing: s.bill),
                onLongPress: () => _settle(b, bill: s.bill),
              ),
          ],
          if (b.repayments.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Repayments', style: text.titleSmall),
            for (final r in b.repayments)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('+${fmtMoney(r.amount)}'),
                subtitle: Text(fmtDateCompact(r.date)),
                onTap: () => showAddTransactionSheet(context, existing: r),
              ),
          ],
          if (b.settled.isNotEmpty)
            FoldSection(
              title: 'Settled bills (${b.settled.length})',
              open: _settledOpen,
              onToggle: () => setState(() => _settledOpen = !_settledOpen),
              children: [
                for (final s in b.settled.reversed)
                  ListTile(
                    dense: true,
                    title: Text(
                      billTitle(s.bill),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(fmtDateCompact(s.bill.date)),
                    trailing: Text(fmtMoney(s.share)),
                    onTap: () =>
                        showAddTransactionSheet(context, existing: s.bill),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Money-in rows that could be [name]'s repayment, closest to what they owe
/// first. Pops with the picked row.
class _LinkPicker extends StatelessWidget {
  final String name;
  final List<Tx> candidates;
  const _LinkPicker({required this.name, required this.candidates});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(
              'Which payment was from $name?',
              style: text.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'Money in from the last 90 days. It moves to Repaid to me.',
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            if (candidates.isEmpty)
              const EmptyState(
                compact: true,
                icon: Icons.inbox_outlined,
                message: 'No money in over the last 90 days to link.',
              ),
            for (final t in candidates)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('+${fmtMoney(t.amount)} · ${t.category.label}'),
                subtitle: Text(
                  [
                    fmtDateCompact(t.date),
                    if (t.note.isNotEmpty) t.note.split('\n').first,
                    if (t.pending) 'to review',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(context, t),
              ),
          ],
        ),
      ),
    );
  }
}
