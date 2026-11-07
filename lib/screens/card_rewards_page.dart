import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/card_rewards.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../services/card_rewards.dart';
import '../utils/format.dart';
import '../utils/text_scale.dart';
import '../widgets/category_chip_label.dart';
import '../widgets/dialog_expander.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/editor_sheet.dart';
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

/// What a reward group is called: its name ("Dining"), or for a group
/// saved before names existed, its categories then merchant words
/// ("Food & Dining, Shopping").
String rewardGroupName(RewardGroup g) => g.name.isNotEmpty
    ? g.name
    : [
        for (final id in g.categoryIds) categoryById(id).label,
        ...g.merchantWords,
      ].join(', ');

/// A group's chip: "10% Dining".
String rewardGroupLabel(RewardUnit unit, RewardGroup g) =>
    '${rewardRateLabel(unit, g.rate)} ${rewardGroupName(g)}'.trim();

/// The Everything else chip: "1% Everything else".
String everythingElseLabel(CardRewards r) =>
    '${rewardRateLabel(r.unit, r.baseRate)} Everything else';

/// A group's row on the rewards page: "Dining · 10% · min ₹500 · cap
/// ₹1,000". A points card's cap is in points ("cap 1,000 points"). A
/// no-break space after "min" and "cap" keeps each with its amount when the
/// row wraps.
String rewardGroupRowTitle(RewardUnit unit, RewardGroup g) => [
  rewardGroupName(g),
  rewardRateLabel(unit, g.rate),
  if (g.minimum != null) 'min ${fmtMoneyTidy(g.minimum!)}',
  if (g.cap case final cap?)
    'cap ${unit == RewardUnit.points ? fmtPoints(cap) : fmtMoneyTidy(cap)}',
].join(' · ');

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

  /// A group's row subtitle: its categories, then its merchant words; null
  /// when it has neither.
  Widget? _groupSubtitle(RewardGroup g) {
    final lines = [
      if (g.categoryIds.isNotEmpty)
        [for (final id in g.categoryIds) categoryById(id).label].join(', '),
      if (g.merchantWords.isNotEmpty)
        'Merchant words: ${g.merchantWords.join(', ')}',
    ];
    return lines.isEmpty ? null : Text(lines.join('\n'));
  }

  /// Cashback or Points saves at once, and every rate then reads in the
  /// other unit (5% becomes 5 points per ₹100), so saved rules get an Undo.
  void _switchUnit(RewardUnit unit) {
    final finance = context.read<FinanceProvider>();
    final id = widget.accountId;
    final before = finance.accountById(id)?.rewards;
    setState(() => _unit = unit);
    _save(unit: unit);
    if (before == null) return;
    showUndoSnackBar(
      context,
      unit == RewardUnit.points
          ? 'Rates now read as points per ₹100'
          : 'Rates now read as a percent',
      () {
        // The unit and point value back, onto the rules as they are now.
        final now = finance.accountById(id)?.rewards;
        finance.setCardRewards(
          id,
          now == null
              ? before
              : CardRewards(
                  unit: before.unit,
                  groups: now.groups,
                  baseRate: now.baseRate,
                  pointValue: before.pointValue,
                ),
        );
        if (mounted) setState(() => _unit = before.unit);
      },
      icon: Icons.swap_horiz,
      tone: AppToastTone.change,
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
          actions: [
            if (account != null && account.isCard && rewards != null)
              PopupMenuButton<String>(
                tooltip: 'Rewards actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (_) => _remove(rewards),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'remove',
                    child: Text(
                      'Remove rewards',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
          ],
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
                    onSelectionChanged: (s) => _switchUnit(s.first),
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
                    'Groups of categories or merchant words that earn one '
                    'rate, with an optional minimum per payment and cap per '
                    'cycle.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  for (final (i, g) in groups.indexed)
                    GroupedSurface(
                      first: i == 0,
                      last: i == groups.length - 1,
                      child: ListTile(
                        title: Text(rewardGroupRowTitle(_unit, g)),
                        subtitle: _groupSubtitle(g),
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
                      helperText: 'The rate for payments no group takes',
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
                ],
              ),
      ),
    );
  }
}

/// The reward group editor sheet. Null when dismissed; a null group when
/// Delete group was tapped. [taken] holds the categories other groups name:
/// they are left out of the chips, so a category earns in one group at
/// most. A group needs a name and a category or a merchant word.
Future<({RewardGroup? group})?> showRewardGroupDialog(
  BuildContext context, {
  required RewardUnit unit,
  RewardGroup? existing,
  Set<String> taken = const {},
}) async {
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final rateCtrl = TextEditingController(
    text: existing == null ? '' : fmtFieldNumber(existing.rate),
  );
  final minCtrl = TextEditingController(
    text: existing?.minimum == null ? '' : fmtFieldNumber(existing!.minimum!),
  );
  final capCtrl = TextEditingController(
    text: existing?.cap == null ? '' : fmtFieldNumber(existing!.cap!),
  );
  final wordCtrl = TextEditingController();
  final controllers = [nameCtrl, rateCtrl, minCtrl, capCtrl, wordCtrl];
  final selected = {...?existing?.categoryIds};
  final words = {...?existing?.merchantWords};
  // The open fold: 'categories', 'words' or none.
  String? open;
  final categories = [
    for (final c in allCategories)
      if (isRewardCategory(c) && !taken.contains(c.id)) c,
  ];
  final points = unit == RewardUnit.points;
  // What the sheet opened with: back with nothing changed closes it
  // without asking.
  final initialTexts = [for (final c in controllers) c.text];
  final initialSelected = {...selected};
  final initialWords = {...words};
  return showEditorSheet<({RewardGroup? group})>(
    context,
    builder: (ctx) => DisposeScope(
      disposables: controllers,
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final name = nameCtrl.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          final rateText = rateCtrl.text.trim();
          final rate = parseAmount(rateText);
          final minText = minCtrl.text.trim();
          final min = parseAmount(minText);
          final capText = capCtrl.text.trim();
          final cap = parseAmount(capText);
          final pendingWord = rewardWordText(wordCtrl.text);
          final reason = name.isEmpty
              ? 'Enter a name'
              : rateText.isEmpty
              ? 'Enter a rate'
              : rate == null
              ? 'Enter a number'
              : rate < 0
              ? "A rate can't be below 0"
              : minText.isNotEmpty && (min == null || min <= 0)
              ? 'Enter a minimum above ₹0, or leave it blank'
              : capText.isNotEmpty && (cap == null || cap <= 0)
              ? 'Enter a cap above 0, or leave it blank'
              : selected.isEmpty && words.isEmpty && pendingWord.isEmpty
              ? 'Pick a category or add a merchant word'
              : null;
          final dirty =
              !listEquals([
                for (final c in controllers) c.text,
              ], initialTexts) ||
              !setEquals(selected, initialSelected) ||
              !setEquals(words, initialWords);
          void addWord() {
            if (pendingWord.isEmpty) return;
            setState(() {
              words.add(pendingWord);
              wordCtrl.clear();
            });
          }

          void toggle(String fold) => setState(() {
            FocusScope.of(ctx).unfocus();
            open = open == fold ? null : fold;
          });
          final theme = Theme.of(ctx);
          final addButton = TextButton(
            onPressed: pendingWord.isEmpty ? null : addWord,
            child: const Text('Add'),
          );
          final wordField = TextField(
            key: const ValueKey('reward-group-word'),
            controller: wordCtrl,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Add a merchant word',
              helperText:
                  'A word from the bank alert or Paid to, such as amazon',
              helperMaxLines: 2,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => addWord(),
          );
          return EditorSheetBody(
            title: existing == null ? 'New reward group' : 'Edit reward group',
            menu: existing == null
                ? null
                : [
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete group',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
            menuTooltip: 'Group actions',
            onMenu: (_) => Navigator.pop(ctx, (group: null)),
            footerLabel: 'Save',
            footerReason: reason,
            dirty: dirty,
            onSave: reason != null
                ? null
                : () => Navigator.pop(ctx, (
                    group: RewardGroup(
                      id: existing == null || existing.id.isEmpty
                          ? newRewardGroupId()
                          : existing.id,
                      name: name,
                      categoryIds: {...selected},
                      merchantWords: {
                        ...words,
                        if (pendingWord.isNotEmpty) pendingWord,
                      },
                      rate: rate!,
                      cap: capText.isEmpty ? null : cap,
                      minimum: minText.isEmpty ? null : min,
                    ),
                  )),
            children: [
              TextField(
                key: const ValueKey('reward-group-name'),
                controller: nameCtrl,
                autofocus: existing == null,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                maxLength: 30,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('reward-group-rate'),
                controller: rateCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: points ? 'Points per ₹100' : 'Cashback',
                  suffixText: points ? 'points' : '%',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('reward-group-minimum'),
                controller: minCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Minimum per payment (optional)',
                  prefixText: '₹ ',
                  helperText:
                      'A payment under it earns nothing from this group',
                  helperMaxLines: 2,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('reward-group-cap'),
                controller: capCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Cap per cycle (optional)',
                  prefixText: points ? null : '₹ ',
                  suffixText: points ? 'points' : null,
                  helperText: 'Most this group earns in one cycle',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              GroupedSurface(
                first: true,
                last: false,
                child: DialogExpander(
                  key: const ValueKey('reward-group-categories'),
                  title: 'Categories',
                  value: selected.isEmpty
                      ? 'None'
                      : [
                          for (final id in selected) categoryById(id).label,
                        ].join(', '),
                  keepClosed: false,
                  open: open == 'categories',
                  onToggle: () => toggle('categories'),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (taken.isNotEmpty) ...[
                          Text(
                            'Categories in another group are not listed.',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                        ],
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
                      ],
                    ),
                  ),
                ),
              ),
              GroupedSurface(
                first: false,
                last: true,
                child: DialogExpander(
                  key: const ValueKey('reward-group-words'),
                  title: 'Merchant words',
                  value: words.isEmpty ? 'None' : words.join(', '),
                  keepClosed: false,
                  open: open == 'words',
                  onToggle: () => toggle('words'),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (words.isNotEmpty) ...[
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final w in words)
                                InputChip(
                                  label: Text(w),
                                  deleteButtonTooltipMessage: 'Remove $w',
                                  onDeleted: () =>
                                      setState(() => words.remove(w)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
                        // The rule editor's Add box: past the large text
                        // scale the button drops under the field.
                        if (isLargeTextScale(ctx)) ...[
                          wordField,
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: addButton,
                          ),
                        ] else
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: wordField),
                              const SizedBox(width: 8),
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: addButton,
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
