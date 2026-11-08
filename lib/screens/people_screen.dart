import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../utils/text_scale.dart';
import '../widgets/empty_state.dart';
import '../widgets/fold_section.dart';
import '../widgets/glossy.dart';
import '../widgets/grouped_surface.dart';
import '../widgets/info_tip.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/undo_snackbar.dart';
import 'add_transaction_sheet.dart';

/// Who owes you: everyone named on a split bill, with what is still to come
/// back. A person's repayments pay off their oldest bills first; tapping a
/// person opens their bills and the ways to record, link or settle.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});

  /// Whether a people page is open, so the Who owes you widget does not
  /// stack a second one.
  static bool get isOpen => _PeopleScreenState._open > 0;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  /// People pages mounted now ([PeopleScreen.isOpen]).
  static int _open = 0;

  /// Folded by default and per visit: settled people are history.
  bool _settledOpen = false;

  @override
  void initState() {
    super.initState();
    _open++;
  }

  @override
  void dispose() {
    _open--;
    super.dispose();
  }

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
          // 16, the Settings and Cockpit card inset.
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            FrostedPanel(
              radius: BorderRadius.circular(AppRadius.card),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The total leads, in large type; the line above it
                    // says who it is from, or that nobody owes anything.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InfoLabel(
                            label: Text(
                              owers == 0
                                  ? 'Nobody owes you anything right now.'
                                  : '$owers ${owers == 1 ? 'person owes' : 'people owe'} you',
                              style: muted,
                            ),
                            tip: const InfoTip(
                              title: 'Who owes you',
                              message:
                                  'Each person on a split bill owes you their '
                                  'amount. Record what they pay back as Repaid '
                                  'to me (a transfer, never income); it pays '
                                  'off their oldest bills first, and part '
                                  'payments count. Splits without names are '
                                  'not counted. Mark a bill settled when it '
                                  'was paid outside the app.',
                            ),
                          ),
                          if (owers > 0)
                            Text(
                              fmtMoney(finance.totalOwed),
                              style: text.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (all.isEmpty)
                      const EmptyState(
                        compact: true,
                        icon: Icons.group_outlined,
                        message:
                            'Tick Group split payment on an expense and add '
                            'who owes what.',
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

/// "7 Oct": the day a bill was split, without its time. The time wrapped
/// the People rows onto a third line and says nothing about who owes what.
String _day(DateTime d) => fmtDateCompact(DateUtils.dateOnly(d));

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
        'oldest ${_day(b.open.first.bill.date)}',
      ] else
        'All settled',
      if (b.credit > 0) '${fmtMoney(b.credit)} paid ahead',
    ];
    // Large text: no avatar, and the amount moves under the subtitle. Beside
    // it, the subtitle was squeezed to two letters a line at 320dp.
    final large = isLargeTextScale(context);
    final owed = b.owed > 0
        ? Text(
            fmtMoney(b.owed),
            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          )
        : null;
    return ListTile(
      dense: true,
      leading: large
          ? null
          : CircleAvatar(
              radius: 18,
              child: Text(_initials(b.name), style: text.labelMedium),
            ),
      title: Text(
        b.name,
        maxLines: large ? 3 : 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: large && owed != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(joinFacts(parts), style: text.bodySmall),
                const SizedBox(height: 2),
                owed,
              ],
            )
          : Text(joinFacts(parts), style: text.bodySmall),
      trailing: large ? null : owed,
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
    // Its own toast: an add sheet opened from a bill or repayment row
    // closes with a toast while this sheet stays open over the page.
    builder: (ctx) => ToastHost(
      child: _PersonSheet(personKey: key, page: context),
    ),
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
      // Its own "Recorded a repayment" toast below says it better.
      announceAdd: false,
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
    // Closest to what they owe first: the first three lead.
    final candidates = finance.repaymentCandidates(near: b.owed);
    Navigator.pop(context);
    PickerItem<String> item(Tx t) => PickerItem(
      value: t.id,
      label: '+${fmtMoney(t.amount)} · ${t.category.label}',
      subtitle: [
        fmtDateCompact(t.date),
        ?finance.rowTitleFor(t),
        if (t.pending) 'to review',
      ].join(' · '),
    );
    final result = await showPickerSheet<String>(
      context: page,
      title: 'Which payment was from ${b.name}?',
      subtitle: 'Money in from the last 90 days. It moves to Repaid to me.',
      // Nothing owed has nothing to be close to: one plain list.
      items: b.owed > 0
          ? [
              PickerItem.header('Closest to ${fmtMoney(b.owed)}'),
              for (final t in candidates.take(3)) item(t),
              if (candidates.length > 3) ...[
                const PickerItem.header('Other money in'),
                for (final t in candidates.skip(3)) item(t),
              ],
            ]
          : [for (final t in candidates) item(t)],
    );
    final pickedId = result?.value;
    if (pickedId == null || !page.mounted) return;
    final picked = candidates.firstWhere((t) => t.id == pickedId);
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
    String billTitle(Tx t) => finance.rowTitleFor(t) ?? t.category.label;
    // One GroupedSurface row per item, the list's first and last rounded.
    List<Widget> rows<T>(List<T> items, Widget Function(T) row) => [
      for (final (i, item) in items.indexed)
        GroupedSurface(
          first: i == 0,
          last: i == items.length - 1,
          child: row(item),
        ),
    ];
    Widget heading(String label) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(label, style: text.titleSmall),
    );

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Pinned header: who, and where they stand, above the scroll.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.name,
                        style: text.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        b.owed > 0
                            ? 'Owes you ${fmtMoney(b.owed)}'
                            : b.credit > 0
                            ? 'Paid ${fmtMoney(b.credit)} ahead'
                            : 'Settled up',
                        style: text.titleMedium,
                      ),
                    ],
                  ),
                ),
                if (b.owed > 0)
                  PopupMenuButton<String>(
                    tooltip: 'Person actions',
                    icon: const Icon(Icons.more_vert),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'settle',
                        child: Text('Mark all settled'),
                      ),
                    ],
                    onSelected: (_) => _settle(b),
                  ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              children: [
                // The bills first: they are what the person owes for, and
                // each settles on its own.
                if (b.open.isNotEmpty) ...[
                  heading('Open bills'),
                  ...rows(
                    b.open,
                    (s) => ListTile(
                      dense: true,
                      title: Text(
                        billTitle(s.bill),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // What is left sits in the subtitle so Settle has the
                      // trailing slot to itself at large text.
                      subtitle: Text(
                        '${_day(s.bill.date)} · ${fmtMoney(s.left)} '
                        'left of ${fmtMoney(s.share)}',
                      ),
                      trailing: TextButton(
                        onPressed: () => _settle(b, bill: s.bill),
                        child: const Text('Settle'),
                      ),
                      onTap: () =>
                          showAddTransactionSheet(context, existing: s.bill),
                    ),
                  ),
                ],
                // A bank SMS for the same money would import it again, so
                // the cash path says so. In the scroll, under the bills:
                // pinned, it took four lines at 2x on a small phone and
                // left the bills little room.
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Record repayment is for cash. Paid by UPI or bank? Use '
                    'Link a payment.',
                    style: text.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (b.repayments.isNotEmpty) ...[
                  heading('Repayments'),
                  ...rows(
                    b.repayments,
                    (r) => ListTile(
                      dense: true,
                      title: Text('+${fmtMoney(r.amount)}'),
                      subtitle: Text(_day(r.date)),
                      onTap: () =>
                          showAddTransactionSheet(context, existing: r),
                    ),
                  ),
                ],
                if (b.settled.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  FoldSection(
                    title: 'Settled bills (${b.settled.length})',
                    open: _settledOpen,
                    onToggle: () =>
                        setState(() => _settledOpen = !_settledOpen),
                    children: rows(
                      b.settled.reversed.toList(),
                      (s) => ListTile(
                        dense: true,
                        title: Text(
                          billTitle(s.bill),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_day(s.bill.date)),
                        trailing: Text(fmtMoney(s.share)),
                        onTap: () =>
                            showAddTransactionSheet(context, existing: s.bill),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Pinned footer: the two ways a repayment arrives.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!canLink) ...[
                  Text(
                    'No money in from the last 90 days to link',
                    style: text.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                FilledButton(
                  key: const ValueKey('person-record'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () => _record(b),
                  child: const Text('Record repayment'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('person-link'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: canLink ? () => _link(b) : null,
                  child: const Text('Link a payment'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
