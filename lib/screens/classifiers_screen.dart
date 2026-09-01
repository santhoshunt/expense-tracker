import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/import_rule.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../services/sms_parser.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/glossy.dart';
import '../widgets/keyboard_unfocus.dart';
import '../widgets/section_header.dart';
import '../widgets/undo_snackbar.dart';
import 'category_management.dart';

class ClassifiersScreen extends StatefulWidget {
  /// Which tab to open on: 0 Rules, 1 Import, 2 Transactions, 3 Categories.
  final int initialTab;
  const ClassifiersScreen({super.key, this.initialTab = 0});

  @override
  State<ClassifiersScreen> createState() => _ClassifiersScreenState();
}

class _ClassifiersScreenState extends State<ClassifiersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialTab,
    );
    _tab.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Classifiers'),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          // Roomier labels: four tabs packed edge-to-edge read as cramped —
          // let the bar scroll instead.
          labelPadding: const EdgeInsets.symmetric(horizontal: 20),
          tabs: const [
            Tab(text: 'Rules'),
            Tab(text: 'Import'),
            Tab(text: 'Transactions'),
            Tab(text: 'Categories'),
          ],
        ),
      ),
      // FAB only on the tabs that create rules.
      floatingActionButton: switch (_tab.index) {
        0 => GlassButton(
          icon: Icons.add,
          label: 'New rule',
          onPressed: () => _showRuleDialog(context),
        ),
        1 => GlassButton(
          icon: Icons.add,
          label: 'New import rule',
          onPressed: () => _showImportRuleDialog(context),
        ),
        3 => GlassButton(
          icon: Icons.add,
          label: 'New category',
          onPressed: () => showCategoryDialog(context),
        ),
        _ => null,
      },
      body: AmbientBackground(
        child: TabBarView(
          controller: _tab,
          children: [
            _RulesTab(),
            _ImportTab(),
            _TransactionsTab(),
            const CategoriesTab(),
          ],
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

  void _toggleSelect(String id) {
    setState(
      () => _selected.contains(id) ? _selected.remove(id) : _selected.add(id),
    );
  }

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
      if (applied.droppedPending > 0)
        '${applied.droppedPending} pending import'
            '${applied.droppedPending == 1 ? '' : 's'} dropped as spam',
    ];
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(parts.join(' · ')),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              finance.restoreRules(before);
              if (applied.dropped.isNotEmpty) {
                finance.restoreEditedTransactions(applied.dropped);
              }
            },
          ),
        ),
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
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No rules yet.\n\nRules categorise SMS imports automatically, '
            'e.g. if the message contains "Chai Kings" → Food & Dining.\n\n'
            'A rule with the Spam category drops matching messages '
            'entirely — they are never imported.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final q = _search.trim().toLowerCase();
    final visible = rules.where((r) => ruleMatchesQuery(r, q)).toList();
    final userRules = visible.where((r) => !r.isBuiltIn).toList();
    final builtinRules = visible.where((r) => r.isBuiltIn).toList();

    // Drop selections that no longer exist or were re-filtered away, so the
    // bar count never lies (transactions-screen idiom).
    if (_selected.isNotEmpty) {
      final visibleIds = {for (final r in visible) r.id};
      _selected.removeWhere((id) => !visibleIds.contains(id));
    }

    Widget header(String label) => UppercaseSectionHeader(label);

    Widget tile(ClassifierRule r) => _RuleTile(
      rule: r,
      selectionMode: _selecting,
      selected: _selected.contains(r.id),
      onToggleSelect: () => _toggleSelect(r.id),
    );

    // Flat item list keeps the whole thing lazily built. Filtering happens
    // before the section split, so an all-filtered section drops its header.
    final items = <Widget>[
      if (userRules.isNotEmpty) header('Your rules'),
      ...userRules.map(tile),
      if (builtinRules.isNotEmpty) header('Built-in'),
      ...builtinRules.map(tile),
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
          child: items.isEmpty
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
                  padding: const EdgeInsets.only(bottom: 88),
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
    final scheme = Theme.of(context).colorScheme;
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
                  color: scheme.primary,
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

class _RuleTile extends StatelessWidget {
  final ClassifierRule rule;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggleSelect;

  const _RuleTile({
    required this.rule,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSpam = rule.isSpamRule;
    final cat = isSpam ? null : categoryById(rule.categoryId);

    return ListTile(
      onTap: selectionMode
          ? onToggleSelect
          : () => _showRuleDialog(context, existing: rule),
      onLongPress: onToggleSelect,
      selected: selected,
      // The avatar flips to a check when picked (TransactionTile precedent —
      // clearer than a checkbox column that reflows the whole list).
      leading: CircleAvatar(
        backgroundColor: selected
            ? scheme.primary.withValues(alpha: 0.18)
            : isSpam
            ? scheme.error.withValues(alpha: 0.12)
            : cat!.color.withValues(alpha: 0.15),
        child: selected
            ? Icon(Icons.check, color: scheme.primary, size: 20)
            : Icon(
                isSpam ? Icons.block : cat!.icon,
                color: isSpam
                    ? scheme.error
                    : categoryGlyphColor(context, cat!.color),
                size: 20,
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
          isSpam
              ? 'Spam — never imported'
              : '→ ${cat!.label} '
                    '(${cat.type == TxType.income ? 'income' : 'expense'})',
        ].join(' · '),
      ),
      // No delete while selecting — a mis-tap next to a checkable row would
      // silently drop a rule.
      trailing: selectionMode
          ? null
          : IconButton(
              tooltip: 'Delete rule',
              // 20 matches every other trailing delete icon in the app.
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () {
                final finance = context.read<FinanceProvider>();
                // Position = match priority; Undo must put it back where it was.
                final index = finance.rules.indexWhere((r) => r.id == rule.id);
                finance.deleteRule(rule.id);
                // patterns.first, not the raw stored string — the '|' encoding is
                // an implementation detail users never typed.
                showUndoSnackBar(
                  context,
                  'Deleted rule "${rule.patterns.firstOrNull ?? rule.pattern}"'
                  '${rule.patterns.length > 1 ? ' (+${rule.patterns.length - 1})' : ''}',
                  () => finance.restoreRule(rule, index),
                );
              },
            ),
    );
  }
}

// ── Import tab ───────────────────────────────────────────────────────────────

/// Shows every criterion the SMS importer applies: the fixed structural
/// checks (read-only) and the editable ignore/spam-signal rules.
class _ImportTab extends StatelessWidget {
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
      const _CoreChecksCard(),
      header('Ignored when containing'),
      if (ignoreRules.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Text('No ignore rules — every bank alert imports.'),
        ),
      ...ignoreRules.map((r) => _ImportRuleTile(rule: r)),
      header('Flagged as spam when containing'),
      if (spamRules.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Text('No spam signals — nothing gets flagged for review.'),
        ),
      ...spamRules.map((r) => _ImportRuleTile(rule: r)),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        // Wrap, not Row: the two buttons together overflow a 360dp screen.
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.science_outlined),
              label: const Text('Test a message'),
              onPressed: () => _showTestMessageDialog(context),
            ),
            TextButton.icon(
              icon: const Icon(Icons.settings_backup_restore),
              label: const Text('Restore defaults'),
              onPressed: () => _confirmRestoreDefaults(context),
            ),
          ],
        ),
      ),
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
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

/// The structural criteria that are code, not data — shown so the whole
/// import decision is visible in one place.
class _CoreChecksCard extends StatelessWidget {
  const _CoreChecksCard();

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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: FrostedPanel(
        radius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const UppercaseSectionHeader(
                'Core checks (always applied)',
                padding: EdgeInsets.zero,
              ),
              const SizedBox(height: 10),
              check(
                Icons.account_balance,
                'Sender must look like a bank or payment app '
                '(DLT ids like VM-HDFCBK, or brand names for '
                'notification-captured alerts).',
              ),
              check(
                Icons.currency_rupee,
                'The message must state an amount (Rs / INR / ₹).',
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
                '"Card payment" income — they cancel out.',
              ),
              const SizedBox(height: 8),
              Text(
                'Changes below apply to future scans. To re-evaluate old '
                'messages, run Import from SMS with a date range.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
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
            ? 'Ignored — never imported'
            : 'Flagged for individual review — still imported',
      ),
      trailing: IconButton(
        tooltip: 'Delete rule',
        // 20 matches every other trailing delete icon in the app.
        icon: const Icon(Icons.delete_outline, size: 20),
        onPressed: () {
          final finance = context.read<FinanceProvider>();
          final index = finance.importRules.indexWhere((r) => r.id == rule.id);
          finance.deleteImportRule(rule.id);
          showUndoSnackBar(
            context,
            'Deleted rule "${rule.pattern}"',
            () => finance.restoreImportRule(rule, index),
          );
        },
      ),
    );
  }
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
    final q = _search.trim().toLowerCase();
    final txs = q.isEmpty
        ? all
        : all
              .where(
                (t) =>
                    t.note.toLowerCase().contains(q) ||
                    t.smsBody.toLowerCase().contains(q) ||
                    t.sender.toLowerCase().contains(q) ||
                    t.category.label.toLowerCase().contains(q),
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
          child: Text(
            'Tap to recategorise · long-press to make a rule from a message.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: txs.isEmpty
              ? Center(
                  child: Text(
                    all.isEmpty
                        ? 'No confirmed transactions yet.'
                        : 'Nothing matches your search.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
                  itemCount: txs.length,
                  itemBuilder: (context, i) => _ClassificationTile(tx: txs[i]),
                ),
        ),
      ],
    );
  }
}

class _ClassificationTile extends StatelessWidget {
  final Tx tx;
  const _ClassificationTile({required this.tx});

  @override
  Widget build(BuildContext context) {
    final cat = tx.category;
    final isIncome = tx.type == TxType.income;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final amountColor = isIncome ? AppColors.of(context).green : scheme.error;

    final title = tx.note.isNotEmpty
        ? tx.note.split('\n').first
        : tx.smsBody.isNotEmpty
        ? tx.smsBody.split('\n').first
        : (tx.sender.isNotEmpty ? tx.sender : cat.label);

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
            child: Row(
              children: [
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${cat.label} · ${fmtDateMaybeTime(tx.date)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Width-capped like TransactionTile: shrink extreme
                // figures instead of overflowing the row.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${isIncome ? '+' : '−'}${fmtMoney(tx.amount)}',
                      style: TextStyle(
                        color: amountColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
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
    final finance = context.read<FinanceProvider>();
    final result = await showPickerSheet<String>(
      context: context,
      title: 'Category',
      items: _categoryPickerItems(context, includeSpam: false),
      selected: tx.categoryId,
    );
    final id = result?.value;
    if (id == null) return;
    // Reclassifying also rewrites tx.type — the category's own type is
    // authoritative, which keeps transfer categories (either direction)
    // consistent with the app-wide `tx.type == category.type` invariant.
    final c = categoryById(id);
    await finance.updateTransaction(
      tx.copyWith(categoryId: c.id, type: c.type),
    );
  }

  /// Long-press shortcut: opens the rule dialog with the transaction body
  /// pre-filled as the pattern, making it easy to codify a manual correction.
  Future<void> _showRuleFromTransaction(BuildContext context) {
    // Use the first line of the SMS body (or the note for manual rows) as a
    // suggested pattern — rules match against the SMS text. '|' is the
    // stored OR separator, so a prefill carrying one (common in UPI alerts)
    // would open the dialog already in its error state — trim at the pipe:
    // the fragment before it is still a valid substring of the SMS.
    final suggestion = tx.smsText.split('\n').first.split('|').first.trim();
    return _showRuleDialog(context, patternSuggestion: suggestion);
  }
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
      label: 'Spam — do not import',
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
                        decoration: BoxDecoration(
                          color: tint.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: tint.withValues(alpha: 0.45),
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
                                // Tinted like the icon so the pass/fail meaning
                                // isn't carried by an 8%-alpha background alone
                                // — but through accentTextColor for the success
                                // branch: the raw accent measured 2.6:1 on its
                                // own light-mode tint while the error branch
                                // passed, leaving the reassuring verdict the
                                // unreadable one.
                                style: Theme.of(ctx).textTheme.bodySmall
                                    ?.copyWith(
                                      color: rejected
                                          ? scheme.error
                                          : accentTextColor(ctx),
                                      fontWeight: FontWeight.w500,
                                    ),
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
                                '\nDropped by your spam rule "${r.pattern}" — '
                                'never imported.';
                            break;
                          }
                          final target = categoryById(r.categoryId);
                          if (parsed != null && target.type != parsed.type) {
                            v +=
                                '\nRule "${r.pattern}" matches but targets '
                                '${target.type == TxType.income ? 'income' : 'expense'}'
                                ' — skipped for this '
                                '${parsed.type == TxType.income ? 'income' : 'expense'}'
                                ' message.';
                            continue;
                          }
                          v +=
                              '\nClassifier rule "${r.pattern}" applies → '
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
                        'Case-insensitive, matched as plain text — '
                        'e.g. "will be debited"',
                  ),
                ),
                const SizedBox(height: 16),
                AppDropdownField<ImportRuleKind>(
                  label: 'Then',
                  value: kind,
                  items: const [
                    PickerItem(
                      value: ImportRuleKind.ignore,
                      label: 'Ignore — never import',
                    ),
                    PickerItem(
                      value: ImportRuleKind.spamSignal,
                      label: 'Flag as spam — review individually',
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
}

Future<void> _showRuleDialog(
  BuildContext context, {
  ClassifierRule? existing,
  String? patternSuggestion,
}) async {
  // One controller per OR-condition. `allCtrls` only grows — DisposeScope
  // reads the list at dispose time, so removed rows still get disposed.
  final seeds = existing?.patterns ?? [patternSuggestion ?? ''];
  final ctrls = [
    for (final s in (seeds.isEmpty ? [''] : seeds))
      TextEditingController(text: s),
  ];
  final allCtrls = List<TextEditingController>.of(ctrls);
  var categoryId = existing?.categoryId ?? 'food';

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: allCtrls,
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? 'New classifier rule' : 'Edit rule'),
          // Scrollable: autofocused field + keyboard on a small screen. Top
          // padding keeps the first field's floating label from clipping.
          // UnfocusOnScroll: dragging the dialog while a condition field is
          // focused left its selection handle floating over the title —
          // handles render in an overlay the scroll viewport doesn't clip.
          content: UnfocusOnScroll(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Category first: it names what the rule DOES, and below
                  // the condition list it sat under the fold once the
                  // keyboard opened.
                  AppDropdownField<String>(
                    label: 'Then classify as',
                    value: categoryId,
                    items: [..._categoryPickerItems(ctx)],
                    onChanged: (v) {
                      if (v != null) setState(() => categoryId = v);
                    },
                  ),
                  // The add-condition button sits with the dropdown, above
                  // the conditions: with several fields plus a keyboard it
                  // lived below the fold exactly when it was needed.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add another condition (OR)'),
                      onPressed: () => setState(() {
                        final c = TextEditingController();
                        ctrls.add(c);
                        allCtrls.add(c);
                      }),
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < ctrls.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            // Keyed by controller: removeAt(i) shifts later
                            // rows across positional element slots — without
                            // keys, focus jumps and a different row silently
                            // resizes.
                            key: ObjectKey(ctrls[i]),
                            controller: ctrls[i],
                            autofocus: i == 0,
                            // Prefills from an SMS can run 5–6 display lines —
                            // wrap instead of scrolling invisibly in one line.
                            minLines: i == 0 ? 2 : 1,
                            maxLines: 6,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: i == 0
                                  ? 'If the SMS contains…'
                                  : 'or contains…',
                              helperText: i == ctrls.length - 1
                                  ? 'Case-insensitive. Use "Add another '
                                        'condition" for OR.'
                                  : null,
                              // '|' is the stored OR separator — typed here it
                              // would silently split into extra conditions.
                              errorText: ctrls[i].text.contains('|')
                                  ? 'Remove "|" — use "Add another condition" '
                                        'for OR'
                                  : null,
                            ),
                          ),
                        ),
                        if (ctrls.length > 1)
                          IconButton(
                            tooltip: 'Remove condition',
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => setState(() => ctrls.removeAt(i)),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            // Disabled while every condition is empty instead of a silent
            // no-op.
            FilledButton(
              onPressed:
                  ctrls.every((c) => c.text.trim().isEmpty) ||
                      ctrls.any((c) => c.text.contains('|'))
                  ? null
                  : () async {
                      // Rules match single-line SMS text — collapse stray
                      // newlines/runs of whitespace so a wrapped edit can't
                      // silently stop matching. Conditions join with '|',
                      // the OR separator ClassifierRule.patterns splits on —
                      // so a literal '|' inside a condition (common in UPI
                      // alerts) must be neutralised or it silently splits
                      // into extra, broader conditions the user never wrote.
                      final pattern = ctrls
                          .map(
                            (c) => c.text
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
                            title: const Text('Drop pending imports?'),
                            content: Text(
                              'This rule matches $wouldDrop pending import'
                              '${wouldDrop == 1 ? '' : 's'} in the review '
                              'queue and will remove '
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
                      final applied = existing == null
                          ? await finance.addRule(pattern, categoryId)
                          : await finance.updateRule(
                              existing.copyWith(
                                pattern: pattern,
                                categoryId: categoryId,
                              ),
                            );
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
                          '${applied.droppedPending} pending import'
                              '${applied.droppedPending == 1 ? '' : 's'} '
                              'dropped as spam',
                      ];
                      if (parts.isNotEmpty) {
                        messenger
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            SnackBar(
                              content: Text(parts.join(' · ')),
                              duration: const Duration(seconds: 5),
                              action: applied.dropped.isEmpty
                                  ? null
                                  : SnackBarAction(
                                      label: 'Restore',
                                      onPressed: () =>
                                          finance.restoreEditedTransactions(
                                            applied.dropped,
                                          ),
                                    ),
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
}
