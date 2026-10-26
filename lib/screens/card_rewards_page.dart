import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/card_rewards.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../services/card_rewards.dart';
import '../utils/format.dart';
import '../widgets/category_chip_label.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/glossy.dart';
import '../widgets/grouped_surface.dart';
import '../widgets/undo_snackbar.dart';

/// Opens [CardRewardsPage] for the card with [accountId].
Future<void> openCardRewards(BuildContext context, String accountId) =>
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CardRewardsPage(accountId: accountId)),
    );

final NumberFormat _wholePoints = NumberFormat('#,##0');

/// "10%" on a cashback card, "4 points per ₹100" on a points card.
String rewardRateLabel(RewardUnit unit, double rate) =>
    unit == RewardUnit.cashback
    ? '${fmtFieldNumber(rate)}%'
    : '${fmtFieldNumber(rate)} ${rate == 1 ? 'point' : 'points'} per ₹100';

/// The Settings list's line for a card: "2 groups · 1% on everything else".
String cardRewardsSummary(CardRewards r) {
  final base = '${rewardRateLabel(r.unit, r.baseRate)} on everything else';
  if (r.groups.isEmpty) return base;
  final n = r.groups.length;
  return '$n ${n == 1 ? 'group' : 'groups'} · $base';
}

/// The card tile's estimate: "Cashback this cycle ≈ ₹324", or "Points this
/// cycle ≈ 1,250 · ≈ ₹312" with a point value set; " · capped" when a group
/// reached its cap. A card with no statement day counts the calendar month.
String rewardEstimateLine(Account card, RewardEstimate e) {
  final period = card.statementDay == null ? 'this month' : 'this cycle';
  final rupees = e.rupees;
  final figure = card.rewards?.unit == RewardUnit.points
      ? 'Points $period ≈ ${_wholePoints.format(e.earned)}'
            '${rupees == null ? '' : ' · ≈ ${fmtMoneyWhole(rupees)}'}'
      : 'Cashback $period ≈ ${fmtMoneyWhole(e.earned)}';
  return e.capped ? '$figure · capped' : figure;
}

/// The muted line under the estimate: "Cycle 16 Oct to 15 Nov · last cycle
/// ₹290", or "Last month ₹290" for a card with no statement day.
String rewardCycleLine(Account card, CardCycle cycle, RewardEstimate last) {
  final earned = card.rewards?.unit == RewardUnit.points
      ? fmtPoints(last.earned)
      : fmtMoneyWhole(last.earned);
  if (card.statementDay == null) return 'Last month $earned';
  return 'Cycle ${fmtDateCompact(cycle.start)} to '
      '${fmtDateCompact(cycle.end)} · last cycle $earned';
}

/// The categories a reward group may name: spending categories and Paid for
/// Others, the rows a card's estimate counts. To sort is left out.
bool isRewardCategory(TxCategory c) =>
    c.type == TxType.expense &&
    !isToSortCategory(c.id) &&
    (!isTransferCategory(c.id) || c.id == kPaidForOthersCategoryId);

/// A credit card's reward rules: cashback or points, reward groups, the
/// Everything else rate and, for points, what a point is worth. Each change
/// is saved as it is made, as on the Settings pages; a rate that does not
/// read shows its error and is not saved. A card with no group and no base
/// rate has no rewards at all, so its Accounts card shows no estimate.
class CardRewardsPage extends StatefulWidget {
  final String accountId;

  const CardRewardsPage({super.key, required this.accountId});

  @override
  State<CardRewardsPage> createState() => _CardRewardsPageState();
}

class _CardRewardsPageState extends State<CardRewardsPage> {
  late final TextEditingController _baseCtrl;
  late final TextEditingController _valueCtrl;

  /// Held here as well as in the saved rules: a card with nothing set yet
  /// keeps the picked unit until its first rate is saved.
  late RewardUnit _unit;

  @override
  void initState() {
    super.initState();
    final r = context
        .read<FinanceProvider>()
        .accountById(widget.accountId)
        ?.rewards;
    _unit = r?.unit ?? RewardUnit.cashback;
    _baseCtrl = TextEditingController(
      text: r == null || r.baseRate == 0 ? '' : fmtFieldNumber(r.baseRate),
    );
    final value = r?.pointValue;
    _valueCtrl = TextEditingController(
      text: value == null ? '' : fmtPerPointField(value),
    );
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  /// The Everything else rate, 0 when blank; null when it does not read or
  /// is below 0.
  double? get _base {
    final text = _baseCtrl.text.trim();
    if (text.isEmpty) return 0;
    final v = parseAmount(text);
    return v == null || v < 0 ? null : v;
  }

  String? get _baseError {
    if (_base != null) return null;
    return parseAmount(_baseCtrl.text) == null
        ? 'Enter a number'
        : "A rate can't be below 0";
  }

  /// ₹ per point: ok with a null value when blank, not ok when the text
  /// does not read as an amount above 0.
  ({bool ok, double? value}) get _pointValue {
    final text = _valueCtrl.text.trim();
    if (text.isEmpty) return (ok: true, value: null);
    final v = parseAmount(text);
    return v == null || v <= 0
        ? (ok: false, value: null)
        : (ok: true, value: v);
  }

  /// Saves the rules with [unit] and [groups] in place of the current ones.
  /// A field in error keeps its last saved value.
  void _save({RewardUnit? unit, List<RewardGroup>? groups}) {
    final finance = context.read<FinanceProvider>();
    final saved = finance.accountById(widget.accountId)?.rewards;
    final u = unit ?? _unit;
    final value = _pointValue;
    final next = CardRewards(
      unit: u,
      groups: List.unmodifiable(groups ?? saved?.groups ?? const []),
      baseRate: _base ?? saved?.baseRate ?? 0,
      pointValue: u == RewardUnit.points
          ? (value.ok ? value.value : saved?.pointValue)
          : null,
    );
    final empty = next.groups.isEmpty && next.baseRate == 0;
    if (empty && saved == null) return;
    finance.setCardRewards(widget.accountId, empty ? null : next);
  }

  Future<void> _editGroup(List<RewardGroup> groups, int? index) async {
    final result = await showRewardGroupDialog(
      context,
      unit: _unit,
      existing: index == null ? null : groups[index],
      taken: {
        for (final (i, g) in groups.indexed)
          if (i != index) ...g.categoryIds,
      },
    );
    if (result == null || !mounted) return;
    final group = result.group;
    if (group != null) {
      _save(
        groups: [
          for (final (i, g) in groups.indexed) i == index ? group : g,
          if (index == null) group,
        ],
      );
      return;
    }
    if (index == null) return;
    final removed = groups[index];
    final finance = context.read<FinanceProvider>();
    final id = widget.accountId;
    // Deleting the only group with no base rate clears the rules; the Undo
    // then takes the unit and point value from before.
    final before = finance.accountById(id)?.rewards;
    _save(groups: [...groups]..removeAt(index));
    showUndoSnackBar(
      context,
      'Deleted reward group',
      () {
        // Back into the rules as they are now, at its old place.
        final now = finance.accountById(id)?.rewards;
        if (now == null) {
          finance.setCardRewards(id, before);
          return;
        }
        final rest = [...now.groups]
          ..insert(index.clamp(0, now.groups.length), removed);
        finance.setCardRewards(
          id,
          CardRewards(
            unit: now.unit,
            groups: List.unmodifiable(rest),
            baseRate: now.baseRate,
            pointValue: now.pointValue,
          ),
        );
      },
      icon: Icons.delete_outline,
      tone: AppToastTone.removal,
    );
  }

  void _remove(CardRewards previous) {
    final finance = context.read<FinanceProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final id = widget.accountId;
    finance.setCardRewards(id, null);
    Navigator.pop(context);
    showUndoSnackBarOn(
      messenger,
      'Removed card rewards',
      () => finance.setCardRewards(id, previous),
      icon: Icons.delete_outline,
      tone: AppToastTone.removal,
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = context.select<FinanceProvider, Account?>(
      (f) => f.accountById(widget.accountId),
    );
    final theme = Theme.of(context);
    final rewards = account?.rewards;
    final groups = rewards?.groups ?? const <RewardGroup>[];
    final points = _unit == RewardUnit.points;
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            account == null || !account.isCard
                ? 'Card rewards'
                : '${account.displayName} rewards',
          ),
        ),
        body: account == null || !account.isCard
            ? const Center(child: Text('This card no longer exists.'))
            : ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  16 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                children: [
                  SegmentedButton<RewardUnit>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: RewardUnit.cashback,
                        label: Text('Cashback'),
                      ),
                      ButtonSegment(
                        value: RewardUnit.points,
                        label: Text('Points'),
                      ),
                    ],
                    selected: {_unit},
                    onSelectionChanged: (s) {
                      setState(() => _unit = s.first);
                      _save(unit: s.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    points
                        ? 'Rates are points per ₹100 spent.'
                        : 'Rates are a percent of each spend.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  Text('Reward groups', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Categories that earn one rate, with an optional cap per '
                    'statement cycle.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  for (final (i, g) in groups.indexed)
                    GroupedSurface(
                      first: i == 0,
                      last: i == groups.length - 1,
                      child: ListTile(
                        title: Text(rewardRateLabel(_unit, g.rate)),
                        subtitle: Text(
                          [
                            [
                              for (final id in g.categoryIds)
                                categoryById(id).label,
                            ].join(', '),
                            switch (g.cap) {
                              null => 'No cap',
                              final cap when points =>
                                'Up to ${fmtPoints(cap)} a cycle',
                              final cap => 'Up to ${fmtMoneyTidy(cap)} a cycle',
                            },
                          ].join('\n'),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _editGroup(groups, i),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _editGroup(groups, null),
                      icon: const Icon(Icons.add),
                      label: const Text('Add a group'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _baseCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Everything else',
                      suffixText: points ? 'points per ₹100' : '%',
                      helperText: 'The rate for categories in no group',
                      errorText: _baseError,
                    ),
                    onChanged: (_) {
                      setState(() {});
                      if (_base != null) _save();
                    },
                  ),
                  if (points) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _valueCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: '₹ per point (optional)',
                        prefixText: '₹ ',
                        helperText: 'Shows what the points are worth',
                        errorText: _pointValue.ok
                            ? null
                            : 'Enter a value above 0, or leave it blank',
                      ),
                      onChanged: (_) {
                        setState(() {});
                        if (_pointValue.ok) _save();
                      },
                    ),
                  ],
                  if (rewards != null) ...[
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _remove(rewards),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remove rewards'),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// The reward group editor. Null when dismissed; a null group when Delete
/// group was tapped. [taken] holds the categories other groups name: they
/// are left out of the chips, so a category earns in one group at most.
Future<({RewardGroup? group})?> showRewardGroupDialog(
  BuildContext context, {
  required RewardUnit unit,
  RewardGroup? existing,
  Set<String> taken = const {},
}) async {
  final rateCtrl = TextEditingController(
    text: existing == null ? '' : fmtFieldNumber(existing.rate),
  );
  final capCtrl = TextEditingController(
    text: existing?.cap == null ? '' : fmtFieldNumber(existing!.cap!),
  );
  final selected = {...?existing?.categoryIds};
  final categories = [
    for (final c in allCategories)
      if (isRewardCategory(c) && !taken.contains(c.id)) c,
  ];
  final points = unit == RewardUnit.points;
  // Errors show once Save has been tried, then follow each edit.
  var tried = false;
  return showDialog<({RewardGroup? group})>(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [rateCtrl, capCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final rateText = rateCtrl.text.trim();
          final rate = parseAmount(rateText);
          final capText = capCtrl.text.trim();
          final cap = parseAmount(capText);
          final rateError = rateText.isEmpty
              ? 'Enter a rate'
              : rate == null
              ? 'Enter a number'
              : rate < 0
              ? "A rate can't be below 0"
              : null;
          final capError = capText.isNotEmpty && (cap == null || cap <= 0)
              ? 'Enter a cap above 0, or leave it blank'
              : null;
          final categoryError = selected.isEmpty
              ? 'Pick at least one category'
              : null;
          final theme = Theme.of(ctx);
          return AlertDialog(
            title: Text(existing == null ? 'New reward group' : 'Reward group'),
            content: SingleChildScrollView(
              // Keeps the floating label of the first field from clipping.
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: rateCtrl,
                    autofocus: existing == null,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: points ? 'Points per ₹100' : 'Cashback',
                      suffixText: points ? 'points' : '%',
                      errorText: tried ? rateError : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: capCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Cap per cycle (optional)',
                      prefixText: points ? null : '₹ ',
                      suffixText: points ? 'points' : null,
                      helperText: 'Most this group earns in one cycle',
                      errorText: tried ? capError : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  Text('Categories', style: theme.textTheme.labelMedium),
                  if (taken.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Categories in another group are not listed.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in categories)
                        FilterChip(
                          label: categoryChipLabel(c),
                          selected: selected.contains(c.id),
                          onSelected: (v) => setState(() {
                            if (v) {
                              selected.add(c.id);
                            } else {
                              selected.remove(c.id);
                            }
                          }),
                        ),
                    ],
                  ),
                  if (tried && categoryError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      categoryError,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              if (existing != null)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: () => Navigator.pop(ctx, (group: null)),
                  child: const Text('Delete group'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (rateError != null ||
                      capError != null ||
                      categoryError != null) {
                    setState(() => tried = true);
                    return;
                  }
                  Navigator.pop(ctx, (
                    group: RewardGroup(
                      categoryIds: {...selected},
                      rate: rate!,
                      cap: capText.isEmpty ? null : cap,
                    ),
                  ));
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
