import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/recurring_detector.dart';
import '../utils/app_theme.dart';
import '../utils/fiscal_year.dart';
import '../utils/format.dart';
import '../utils/money_colors.dart';
import '../utils/search_text.dart';
import '../widgets/category_tile_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/glossy.dart';
import '../widgets/grouped_surface.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/section_label.dart';
import '../widgets/transaction_tile.dart';
import 'app_nav.dart';
import 'classifiers_screen.dart';
import 'transactions_screen.dart';

/// The results page's filter chips, in the order they show.
enum _SearchChip {
  all('All'),
  payments('Payments'),
  merchants('Merchants'),
  categories('Categories'),
  people('People'),
  settings('Settings');

  final String label;
  const _SearchChip(this.label);
}

/// Rows the All and Payments chips list before Show all.
const int _kResultsCap = 30;

/// A payment as the Spent figures count it: money out, not a transfer, and
/// counted in the totals.
bool _isPayment(Tx t, FinanceProvider f) =>
    t.type == TxType.expense &&
    !isTransferCategory(t.categoryId) &&
    f.countsInTotals(t);

/// The year that holds today, as the Year view names it.
DateTimeRange _thisYear(int startMonth) {
  final b = yearBounds(yearStartOf(DateTime.now(), startMonth), startMonth);
  return DateTimeRange(start: b.first, end: b.last);
}

/// One merchant the ledger pays: its [recurringKeyOf] key, the identity
/// after the direction, its label, and this year's payments and spend.
class _MerchantHit {
  final String key;
  final String identity;
  final String label;
  int count = 0;
  double spent = 0;

  _MerchantHit({
    required this.key,
    required this.identity,
    required this.label,
  });
}

/// Everything one query finds, per chip.
typedef _Hits = ({
  List<Tx> rows,
  List<Tx> payments,
  List<_MerchantHit> merchants,
  List<TxCategory> categories,
  List<PersonBalance> people,
  List<ClassifierRule> rules,
  List<Account> accounts,
});

bool _anyIn(_Hits h) =>
    h.rows.isNotEmpty ||
    h.merchants.isNotEmpty ||
    h.categories.isNotEmpty ||
    h.people.isNotEmpty ||
    h.rules.isNotEmpty ||
    h.accounts.isNotEmpty;

/// The global search: one field over payments, merchants, categories,
/// people, rules and accounts. Pushed over whatever page is open, so Back
/// returns there; every tap here opens on top of the results.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  String _query = '';
  _SearchChip _chip = _SearchChip.all;
  late final SettingsProvider _settings;
  late final FinanceProvider _finance;

  /// The ledger revision and year start the caches below were built for.
  Object? _revision;
  int? _yearStartMonth;

  /// [searchHaystack] per row id.
  final Map<String, String> _hay = {};
  List<_MerchantHit> _merchants = const [];
  Map<String, ({int count, double sum})> _catYear = const {};

  /// Whether the query last drawn ([_hitQuery]) found anything.
  bool _anyHit = false;
  String? _hitQuery;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsProvider>();
    _finance = context.read<FinanceProvider>();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  /// The ledger is searched again after a pause in typing, as the
  /// Transactions tab's field does.
  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = v);
    });
  }

  /// Shows [v]'s results at once, without the typing pause.
  void _apply(String v) {
    _debounce?.cancel();
    setState(() => _query = v);
  }

  void _clear() {
    _ctrl.clear();
    _apply('');
  }

  /// A recent search back in the field.
  void _useRecent(String q) {
    _ctrl.value = TextEditingValue(
      text: q,
      selection: TextSelection.collapsed(offset: q.length),
    );
    _apply(q);
  }

  /// Saves the field's text as a recent search when it found something.
  void _remember() {
    final text = _ctrl.text;
    if (text.trim().isEmpty) return;
    final hit = _hitQuery == text ? _anyHit : _anyIn(_collect(_finance, text));
    if (hit) _settings.addRecentSearch(text);
  }

  /// Rebuilds the caches on a new ledger revision or year start.
  void _refresh(FinanceProvider f) {
    final sm = _settings.yearStart.month;
    final sameRevision = identical(_revision, f.revision);
    if (sameRevision && _yearStartMonth == sm) return;
    if (!sameRevision) _hay.clear();
    _revision = f.revision;
    _yearStartMonth = sm;
    final year = _thisYear(sm);
    final merchants = <String, _MerchantHit>{};
    final catYear = <String, ({int count, double sum})>{};
    // Newest first, so a merchant takes its latest row's label.
    for (final t in f.transactions) {
      final inYear = txInRange(t, year, counted: true);
      if (inYear) {
        final c = catYear[t.categoryId] ?? (count: 0, sum: 0.0);
        final add = !f.countsInTotals(t)
            ? 0.0
            : t.type == TxType.expense
            ? f.netSpendOf(t)
            : f.isLinkedRefund(t)
            ? 0.0
            : t.amount;
        catYear[t.categoryId] = (count: c.count + 1, sum: c.sum + add);
      }
      if (t.type != TxType.expense) continue;
      final key = recurringKeyOf(t);
      if (key == null) continue;
      final identity = key.substring(key.indexOf('|') + 1);
      final m = merchants[key] ??= _MerchantHit(
        key: key,
        identity: identity,
        label: f.merchantLabelFor(t) ?? identity,
      );
      if (inYear && _isPayment(t, f)) {
        m.count++;
        m.spent += f.netSpendOf(t);
      }
    }
    _merchants = merchants.values.toList();
    _catYear = catYear;
  }

  /// Whether row [t] holds the normalized query [q].
  bool _hit(FinanceProvider f, Tx t, String q) =>
      (_hay[t.id] ??= searchHaystack(
        t,
        accountName: f.accountForKey(t.acctKey)?.displayName,
        merchantAlias: f.merchantAliasFor(t),
      )).contains(q);

  /// Why [t] matched [q], for line two of its row.
  String? _noteFor(FinanceProvider f, Tx t, String q) => searchMatchNote(
    t,
    q,
    title: f.rowTitleFor(t) ?? t.category.label,
    accountName: f.accountForKey(t.acctKey)?.displayName,
  );

  /// Every chip's hits for [query].
  _Hits _collect(FinanceProvider f, String query) {
    _refresh(f);
    final q = normalizeSearchText(query);
    if (q.isEmpty) {
      return (
        rows: const <Tx>[],
        payments: const <Tx>[],
        merchants: const <_MerchantHit>[],
        categories: const <TxCategory>[],
        people: const <PersonBalance>[],
        rules: const <ClassifierRule>[],
        accounts: const <Account>[],
      );
    }
    bool has(String s) => normalizeSearchText(s).contains(q);
    final rows = [
      for (final t in f.transactions)
        if (_hit(f, t, q)) t,
    ];
    final merchants =
        _merchants.where((m) => has(m.label) || has(m.identity)).toList()
          ..sort((a, b) {
            final s = b.spent.compareTo(a.spent);
            return s != 0 ? s : b.count.compareTo(a.count);
          });
    int yearCount(TxCategory c) => _catYear[c.id]?.count ?? 0;
    final categories = allCategories.where((c) => has(c.label)).toList()
      ..sort((a, b) => yearCount(b).compareTo(yearCount(a)));
    final ruleQuery = query.trim().toLowerCase();
    final rules = <ClassifierRule>[];
    for (final r in f.rules) {
      if (!ruleMatchesQuery(r, ruleQuery)) continue;
      // A direction pair lists once.
      final sib = directionSiblingOf(r, f.rules);
      if (sib != null && rules.any((x) => x.id == sib.id)) continue;
      rules.add(r);
    }
    return (
      rows: rows,
      payments: [
        for (final t in rows)
          if (_isPayment(t, f)) t,
      ],
      merchants: merchants,
      categories: categories,
      people: [
        for (final p in f.peopleBalances)
          if (has(p.name)) p,
      ],
      rules: rules,
      accounts: [
        for (final a in f.accounts)
          if (has(a.displayName)) a,
      ],
    );
  }

  void _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  /// The full list of the [chip]'s payment rows for [query].
  void _showAll(String query, _SearchChip chip) {
    _remember();
    final paymentsOnly = chip == _SearchChip.payments;
    final q = normalizeSearchText(query);
    _push(
      SearchPaymentsPage(
        title: '"${query.trim()}"',
        rowsOf: (f) {
          final h = _collect(f, query);
          return paymentsOnly ? h.payments : h.rows;
        },
        transactionsRequest: TxFilterRequest(query: query.trim()),
        matchNoteOf: (t) => _noteFor(_finance, t, q),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = context.watch<FinanceProvider>();
    // Rebuilds the year figures when the year start changes.
    context.select<SettingsProvider, int>((s) => s.yearStart.month);
    final hits = _collect(f, _query);
    _anyHit = _anyIn(hits);
    _hitQuery = _query;
    final empty = normalizeSearchText(_query).isEmpty;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _remember();
      },
      child: AmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            titleSpacing: 0,
            // Listens to the controller: the results wait for the typing
            // pause, the clear button must not.
            title: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _ctrl,
              builder: (context, value, _) => TextField(
                controller: _ctrl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                onSubmitted: (v) {
                  _apply(v);
                  _remember();
                },
                decoration: InputDecoration(
                  hintText: 'Search',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close),
                          onPressed: _clear,
                        ),
                  isDense: true,
                ),
              ),
            ),
          ),
          body: empty ? _recent(context) : _results(context, f, hits),
        ),
      ),
    );
  }

  /// The empty field: the recent searches, or what the page searches.
  Widget _recent(BuildContext context) {
    final recent = context.select<SettingsProvider, String>(
      (s) => s.recentSearches.join('\n'),
    );
    if (recent.isEmpty) {
      return const EmptyState(
        icon: Icons.search,
        message:
            'Search payments, merchants, categories, people, rules and '
            'accounts.',
      );
    }
    final list = recent.split('\n');
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        const SectionLabel('Recent searches'),
        for (var i = 0; i < list.length; i++)
          GroupedSurface(
            first: i == 0,
            last: i == list.length - 1,
            child: ListTile(
              leading: const Icon(Icons.history),
              title: Text(list[i]),
              onTap: () => _useRecent(list[i]),
            ),
          ),
      ],
    );
  }

  /// The chips over the chosen kind's rows.
  Widget _results(BuildContext context, FinanceProvider f, _Hits hits) {
    final query = _query.trim();
    final q = normalizeSearchText(_query);
    Widget none(String kind) => ListView(
      children: [
        EmptyState(
          compact: true,
          icon: Icons.search_off,
          message: 'No $kind match "$query".',
        ),
      ],
    );
    final body = switch (_chip) {
      _SearchChip.all =>
        hits.rows.isEmpty
            ? none('results')
            : _PaymentResults(
                rows: hits.rows,
                cap: _kResultsCap,
                onShowAll: () => _showAll(_query, _SearchChip.all),
                matchNoteOf: (t) => _noteFor(f, t, q),
              ),
      _SearchChip.payments =>
        hits.payments.isEmpty
            ? none('payments')
            : _PaymentResults(
                rows: hits.payments,
                cap: _kResultsCap,
                onShowAll: () => _showAll(_query, _SearchChip.payments),
                matchNoteOf: (t) => _noteFor(f, t, q),
              ),
      _SearchChip.merchants =>
        hits.merchants.isEmpty
            ? none('merchants')
            : _merchantList(context, hits.merchants),
      _SearchChip.categories =>
        hits.categories.isEmpty
            ? none('categories')
            : _categoryList(context, hits.categories),
      _SearchChip.people =>
        hits.people.isEmpty
            ? none('people')
            : _peopleList(context, hits.people),
      _SearchChip.settings =>
        hits.rules.isEmpty && hits.accounts.isEmpty
            ? none('rules or accounts')
            : _settingsList(context, f, hits.rules, hits.accounts),
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: ChipTabs<_SearchChip>(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            options: [for (final c in _SearchChip.values) (c, c.label)],
            selected: _chip,
            onChanged: (c) => setState(() => _chip = c),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  /// A scrolling list of [children], inset like the Settings lists.
  Widget _list(BuildContext context, List<Widget> children) => ListView(
    padding: EdgeInsets.fromLTRB(
      16,
      0,
      16,
      24 + MediaQuery.paddingOf(context).bottom,
    ),
    children: children,
  );

  List<Widget> _grouped(List<Widget> tiles) => [
    for (var i = 0; i < tiles.length; i++)
      GroupedSurface(
        first: i == 0,
        last: i == tiles.length - 1,
        child: tiles[i],
      ),
  ];

  /// A figure at a row's end; muted when [color] is null.
  Widget _figure(BuildContext context, String text, Color? color) => Text(
    text,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  Widget _merchantList(BuildContext context, List<_MerchantHit> merchants) {
    final expense = moneyColor(context, type: TxType.expense);
    return _list(context, [
      const SizedBox(height: 8),
      ..._grouped([
        for (final m in merchants)
          ListTile(
            leading: const Icon(Icons.storefront_outlined),
            title: Text(m.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              m.count == 0
                  ? 'None this year'
                  : m.count == 1
                  ? '1 payment this year'
                  : '${m.count} payments this year',
            ),
            trailing: m.spent > 0
                ? _figure(context, fmtMoneyWhole(m.spent), expense)
                : null,
            onTap: () {
              _remember();
              _push(
                SearchPaymentsPage(
                  title: m.label,
                  rowsOf: (f) => [
                    for (final t in f.transactions)
                      if (t.type == TxType.expense &&
                          recurringKeyOf(t) == m.key)
                        t,
                  ],
                  transactionsRequest: TxFilterRequest(query: m.identity),
                ),
              );
            },
          ),
      ]),
    ]);
  }

  Widget _categoryList(BuildContext context, List<TxCategory> categories) {
    final hideIncome = context.select<SettingsProvider, bool>(
      (s) => s.hideIncome,
    );
    return _list(context, [
      const SizedBox(height: 8),
      ..._grouped([
        for (final c in categories)
          () {
            final year = _catYear[c.id] ?? (count: 0, sum: 0.0);
            final Widget? figure = c.isTransfer || year.sum <= 0
                ? null
                : c.type == TxType.income && hideIncome
                ? _figure(context, kMaskedAmount, null)
                : _figure(
                    context,
                    fmtMoneyWhole(year.sum),
                    moneyColor(context, type: c.type),
                  );
            return ListTile(
              leading: CategoryTileIcon(category: c),
              title: Text(
                c.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                year.count == 1
                    ? '1 transaction this year'
                    : '${year.count} transactions this year',
              ),
              trailing: figure,
              onTap: () => _push(
                SearchPaymentsPage(
                  title: c.label,
                  rowsOf: (f) => [
                    for (final t in f.transactions)
                      if (t.categoryId == c.id) t,
                  ],
                  transactionsRequest: TxFilterRequest(categoryId: c.id),
                ),
              ),
            );
          }(),
      ]),
    ]);
  }

  Widget _peopleList(BuildContext context, List<PersonBalance> people) {
    final green = AppColors.of(context).green;
    return _list(context, [
      const SizedBox(height: 8),
      ..._grouped([
        for (final p in people)
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              p.owed > 0
                  ? 'Owes you'
                  : p.credit > 0
                  ? 'Paid you extra'
                  : 'Settled',
            ),
            trailing: p.owed > 0
                ? _figure(context, fmtMoneyWhole(p.owed), green)
                : null,
            onTap: () {
              _remember();
              goPeople(context);
            },
          ),
      ]),
    ]);
  }

  Widget _settingsList(
    BuildContext context,
    FinanceProvider f,
    List<ClassifierRule> rules,
    List<Account> accounts,
  ) {
    return _list(context, [
      if (rules.isNotEmpty) ...[
        const SectionLabel('Rules'),
        ..._grouped([
          for (final r in rules)
            () {
              final sib = directionSiblingOf(r, f.rules);
              final cat = r.isSpamRule ? null : categoryById(r.categoryId);
              return ListTile(
                leading: cat == null
                    ? const Icon(Icons.block)
                    : CategoryTileIcon(category: cat),
                title: Text(
                  r.patterns.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  cat == null
                      ? 'Marks as spam'
                      : 'Sets ${cat.label}'
                            '${sib == null ? '' : ' or ${categoryById(sib.categoryId).label}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => showRuleDialog(context, existing: r, sibling: sib),
              );
            }(),
        ]),
      ],
      if (accounts.isNotEmpty) ...[
        const SectionLabel('Accounts'),
        ..._grouped([
          for (final a in accounts)
            ListTile(
              leading: Icon(a.icon),
              title: Text(
                a.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                a.isClosed ? '${a.typeLabel} · closed' : a.typeLabel,
              ),
              onTap: () => _push(
                SearchPaymentsPage(
                  title: a.displayName,
                  // A bank lists its linked debit cards' rows too, as the
                  // Transactions account filter does.
                  rowsOf: (f) => [
                    for (final t in f.transactions)
                      if (f.accountForKey(t.acctKey) case final owner
                          when owner?.id == a.id ||
                              f.linkedAccountOf(owner)?.id == a.id)
                        t,
                  ],
                  transactionsRequest: TxFilterRequest(accountId: a.id),
                ),
              ),
            ),
        ]),
      ],
    ]);
  }
}

/// A full list of payment rows found by the search (Show all, a merchant,
/// a category or an account), pushed over the results so Back returns to
/// them. [rowsOf] reads the rows afresh on each change; the app bar's
/// button opens the same rows in the Transactions tab.
class SearchPaymentsPage extends StatelessWidget {
  final String title;
  final List<Tx> Function(FinanceProvider) rowsOf;
  final TxFilterRequest transactionsRequest;

  /// Why each row matched, for line two; null for none.
  final String? Function(Tx)? matchNoteOf;

  const SearchPaymentsPage({
    super.key,
    required this.title,
    required this.rowsOf,
    required this.transactionsRequest,
    this.matchNoteOf,
  });

  @override
  Widget build(BuildContext context) {
    final rows = rowsOf(context.watch<FinanceProvider>());
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(title),
          actions: [
            IconButton(
              tooltip: 'Open in Transactions',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => AppNav.instance.openTransactions(
                context,
                transactionsRequest,
              ),
            ),
          ],
        ),
        body: rows.isEmpty
            ? const EmptyState(
                icon: Icons.search_off,
                message: 'Nothing here any more.',
              )
            : _PaymentResults(rows: rows, matchNoteOf: matchNoteOf),
      ),
    );
  }
}

/// Search rows as the Transactions tab draws them: a total line with a
/// sort button, the top merchants, then the rows under month labels and
/// day headers (newest first) or by amount. [cap] rows at most, then Show
/// all.
class _PaymentResults extends StatefulWidget {
  final List<Tx> rows;
  final int? cap;
  final VoidCallback? onShowAll;
  final String? Function(Tx)? matchNoteOf;

  const _PaymentResults({
    required this.rows,
    this.cap,
    this.onShowAll,
    this.matchNoteOf,
  });

  @override
  State<_PaymentResults> createState() => _PaymentResultsState();
}

class _PaymentResultsState extends State<_PaymentResults> {
  bool _byAmount = false;

  Future<void> _pickSort() async {
    final picked = await showPickerSheet<bool>(
      context: context,
      title: 'Sort by',
      items: const [
        PickerItem(value: false, label: 'Date · newest first'),
        PickerItem(value: true, label: 'Amount · high to low'),
      ],
      selected: _byAmount,
    );
    final v = picked?.value;
    if (v == null || !mounted) return;
    setState(() => _byAmount = v);
  }

  @override
  Widget build(BuildContext context) {
    final f = context.read<FinanceProvider>();
    final sm = context.select<SettingsProvider, int>((s) => s.yearStart.month);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final rows = widget.rows;
    final n = rows.length;
    final payments = rows.every((t) => _isPayment(t, f));
    String word(int n) => payments
        ? (n == 1 ? 'payment' : 'payments')
        : (n == 1 ? 'match' : 'matches');
    final year = _thisYear(sm);
    final spent = rows
        .where((t) => _isPayment(t, f) && txInRange(t, year, counted: true))
        .fold(0.0, (s, t) => s + f.netSpendOf(t));
    final counts = <String, int>{};
    for (final t in rows) {
      final label = f.merchantLabelFor(t);
      if (label != null) counts[label] = (counts[label] ?? 0) + 1;
    }
    final labels = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final sorted = [...rows]
      ..sort(
        _byAmount
            ? (a, b) => b.amount.compareTo(a.amount)
            : (a, b) => b.date.compareTo(a.date),
      );
    final cap = widget.cap;
    final cut = cap != null && sorted.length > cap;
    final shown = cut ? sorted.sublist(0, cap) : sorted;

    final items = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$n ${word(n)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (spent > 0) ...[
                      const TextSpan(text: ', '),
                      TextSpan(
                        text: fmtMoneyWhole(spent),
                        style: TextStyle(
                          color: moneyColor(context, type: TxType.expense),
                        ),
                      ),
                      const TextSpan(text: ' this year'),
                    ],
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Sort by',
              icon: const Icon(Icons.swap_vert),
              onPressed: _pickSort,
            ),
          ],
        ),
      ),
      if (labels.length >= 2)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text(
            labels.take(3).map((e) => '${e.key} ${e.value}').join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
        ),
    ];

    if (_byAmount) {
      for (final t in shown) {
        items.add(
          TransactionTile(
            key: ValueKey(t.id),
            tx: t,
            matchNote: widget.matchNoteOf?.call(t),
          ),
        );
      }
    } else {
      DateTime dayOf(Tx t) => DateTime(t.date.year, t.date.month, t.date.day);
      final byDay = <DateTime, List<Tx>>{};
      for (final t in shown) {
        (byDay[dayOf(t)] ??= []).add(t);
      }
      final now = DateTime.now();
      final running = DateTime(now.year, now.month);
      DateTime? month;
      for (var i = 0; i < shown.length; i++) {
        final t = shown[i];
        final m = DateTime(t.date.year, t.date.month);
        if (m != month) {
          month = m;
          if (m != running) {
            items.add(
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SectionLabel(fmtMonth(m)),
              ),
            );
          }
        }
        final day = dayOf(t);
        final first = i == 0 || dayOf(shown[i - 1]) != day;
        final last = i == shown.length - 1 || dayOf(shown[i + 1]) != day;
        if (first) items.add(TxDayHeader(day: t.date, txs: byDay[day]!));
        items.add(
          TransactionTile(
            key: ValueKey(t.id),
            tx: t,
            grouped: true,
            groupedFirst: first,
            groupedLast: last,
            showDate: false,
            matchNote: widget.matchNoteOf?.call(t),
          ),
        );
      }
    }
    if (cut && widget.onShowAll != null) {
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Center(
            child: TextButton(
              onPressed: widget.onShowAll,
              child: Text('Show all $n ${word(n)}'),
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.only(
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
      ),
      children: items,
    );
  }
}
