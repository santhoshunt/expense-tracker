import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/add_transaction_sheet.dart';
import '../screens/app_nav.dart';
import '../services/refund_matching.dart';
import '../services/transfer_pairing.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../utils/money_colors.dart';
import '../utils/text_scale.dart';
import 'animated_fold.dart';
import 'category_tile_icon.dart';
import 'empty_state.dart';
import 'info_tip.dart';
import 'section_label.dart';
import 'undo_snackbar.dart';

/// True while a review sheet is open: a second call (a notification tapped
/// twice, the icon and a launch action together) does nothing.
bool _reviewSheetOpen = false;

/// The review sheet: imports waiting for review grouped by day, the
/// transfer and refund suggestions over them, and suspected spam folded at
/// the bottom. Opened from the message icon on Transactions, the review
/// notification, the This week widget's review count and the weekly digest.
Future<void> showReviewSheet(BuildContext context) async {
  if (_reviewSheetOpen) return;
  _reviewSheetOpen = true;
  // Home's messenger: the toast of an action that empties the sheet goes
  // there, since the sheet's own closes with it.
  final host = ScaffoldMessenger.of(context);
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _ReviewSheet(host: host),
    );
  } catch (_) {
    _reviewSheetOpen = false;
    rethrow;
  }
}

/// How a row or suggestion offers Undo: the sheet picks the messenger.
typedef _OfferUndo =
    void Function(
      String message,
      VoidCallback undo, {
      required IconData icon,
      AppToastTone tone,
    });

class _ReviewSheet extends StatefulWidget {
  final ScaffoldMessengerState host;

  const _ReviewSheet({required this.host});

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  /// The sheet's own messenger: toasts draw above the scrim and the pinned
  /// batch bar.
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final FinanceProvider _finance;
  late final SettingsProvider _settings;
  late final ScaffoldMessengerState _host;

  /// The sheet has listed something since it opened: once empty again it
  /// closes. Opened empty, it stays open on the empty state.
  bool _hadItems = false;
  bool _closing = false;

  /// Suspected spam unfolded by hand. Not persisted.
  bool _spamOpen = false;

  @override
  void initState() {
    super.initState();
    _finance = context.read<FinanceProvider>();
    _settings = context.read<SettingsProvider>();
    _host = widget.host;
  }

  @override
  void dispose() {
    // Here, not after showReviewSheet's await: removeRoute never completes
    // that future.
    _reviewSheetOpen = false;
    super.dispose();
  }

  /// Every toast from the sheet comes through here. When the action emptied
  /// the sheet, the toast goes to Home's messenger and the sheet closes, so
  /// Undo outlives it; otherwise it shows inside the sheet.
  void _offerUndo(
    String message,
    VoidCallback undo, {
    required IconData icon,
    AppToastTone tone = AppToastTone.change,
  }) {
    final closing =
        !mounted ||
        _closing ||
        (_hadItems &&
            _finance.reviewQueue(_settings.dismissedPairSuggestions).isEmpty);
    final target = closing ? _host : _messengerKey.currentState ?? _host;
    showUndoSnackBarOn(target, message, undo, icon: icon, tone: tone);
    if (closing && mounted && !_closing) {
      _closing = true;
      _close();
    }
  }

  /// Pops the sheet, or removes it from under the edit sheet that emptied
  /// it, so that one closes normally.
  void _close() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  // Bulk: a dialog first, then Undo, which puts the rows back in review.
  Future<void> _confirmAll(int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirm all $count transaction${count == 1 ? '' : 's'}?'),
        content: const Text(
          'They join the ledger as reviewed entries. Suspected spam stays in '
          'its own list. Undo puts them back in review.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm all'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final rows = await _finance.confirmAllPending();
    if (rows.isEmpty) return;
    // No mounted check: _offerUndo sends the toast to Home once the sheet
    // is gone.
    _offerUndo(
      'Confirmed ${rows.length} import${rows.length == 1 ? '' : 's'}',
      () => _finance.restoreEditedTransactions(rows),
      icon: Icons.done_all,
      tone: AppToastTone.success,
    );
  }

  Future<void> _discardAll(int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Discard all $count import${count == 1 ? '' : 's'}?'),
        content: const Text(
          'They leave the review list without joining the ledger. Suspected '
          'spam stays in its own list. Undo restores them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard all'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final removed = await _finance.discardAllPending();
    if (removed.isEmpty) return;
    _offerUndo(
      'Discarded ${removed.length} import${removed.length == 1 ? '' : 's'}',
      () => _finance.restoreTransactions(removed),
      icon: Icons.block,
      tone: AppToastTone.removal,
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<FinanceProvider>();
    context.select<SettingsProvider, int>(
      (s) => s.dismissedPairSuggestions.length,
    );
    final q = _finance.reviewQueue(_settings.dismissedPairSuggestions);
    if (!q.isEmpty) _hadItems = true;
    if (_hadItems && q.isEmpty && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _close());
    }
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final spamLine = q.spam.isEmpty ? null : '${q.spam.length} suspected spam';
    final subtitle = q.isEmpty
        ? null
        : q.reviewCount == 0
        ? spamLine
        : ['${q.reviewCount} to review', ?spamLine].join(' · ');

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.card, 0, 4, 4),
      child: Row(
        children: [
          Icon(Icons.sms, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                InfoLabel(
                  icon: true,
                  label: Text('Imported from SMS', style: text.titleMedium),
                  tip: const InfoTip(
                    title: 'Imported from SMS',
                    message:
                        'These imports need a look: the app was not sure of '
                        'their account, category or whether they are a '
                        'transfer. They count once you confirm them. Other '
                        'imports already count and show as new in the list.',
                    link: InfoLink(
                      prompt: 'Imports classified wrong?',
                      label: 'Set up transaction rules',
                      onTap: goCockpitRules,
                    ),
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );

    // The batch bar sits in a SafeArea; without it (spam or suggestions
    // only, or nothing) the list keeps clear of the system nav bar itself.
    final navInset = q.pending.isEmpty
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    final Widget body;
    if (q.isEmpty && _hadItems) {
      // Sliding away after its last item: no flash of the empty state.
      body = const SizedBox.shrink();
    } else if (q.isEmpty) {
      final canImport = AppNav.instance.canImportSms;
      // Scrollable so the empty state survives a short sheet at large text.
      body = Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: navInset),
          child: EmptyState(
            icon: Icons.inbox_outlined,
            message:
                'Nothing to review. New alerts land here when the app is '
                'unsure.',
            actionLabel: canImport ? 'Import from SMS' : null,
            actionIcon: Icons.sms_outlined,
            onAction: canImport
                ? () => AppNav.instance.importSms(context)
                : null,
          ),
        ),
      );
    } else {
      final labelled =
          (q.pairs.isNotEmpty || q.refunds.isNotEmpty) && q.rows.isNotEmpty;
      DateTime? lastDay;
      body = ListView(
        padding: EdgeInsets.only(bottom: 16 + navInset),
        children: [
          if (labelled)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SectionLabel('Suggestions'),
            ),
          // Two legs of one own-account move arrive as an expense and an
          // income; pairing books both as transfers so neither inflates
          // Spent or Income.
          for (final s in q.pairs)
            _TransferSuggestionRow(suggestion: s, offerUndo: _offerUndo),
          // A refund linked to its purchase takes that spend down instead
          // of counting as income.
          for (final s in q.refunds)
            _RefundSuggestionRow(suggestion: s, offerUndo: _offerUndo),
          if (labelled)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SectionLabel('To review'),
            ),
          for (final tx in q.rows) ...[
            if (DateUtils.dateOnly(tx.date) != lastDay)
              _DayLabel(day: lastDay = DateUtils.dateOnly(tx.date)),
            _ReviewRow(tx: tx, offerUndo: _offerUndo),
          ],
          if (q.spam.isNotEmpty)
            _SpamFold(
              suspects: q.spam,
              open: _spamOpen || !q.hasReview,
              canFold: q.hasReview,
              onToggle: () => setState(() => _spamOpen = !_spamOpen),
              offerUndo: _offerUndo,
            ),
        ],
      );
    }

    // Pinned under the list while imports wait; toasts sit above it.
    final Widget? batchBar = q.pending.isEmpty
        ? null
        : SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Divider(height: 1),
                Padding(
                  key: const ValueKey('review-bulk-actions'),
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
                  child: OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: 8,
                    children: [
                      // Plain text: the dialog's red button carries the
                      // warning.
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.onSurface,
                        ),
                        onPressed: () => _discardAll(q.pending.length),
                        child: const Text('Discard all'),
                      ),
                      FilledButton(
                        onPressed: () => _confirmAll(q.pending.length),
                        child: const Text('Confirm all'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );

    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(child: body),
          ],
        ),
        bottomNavigationBar: batchBar,
      ),
    );
  }
}

/// "Today", "Yesterday" or "Thu 15 Oct" over a day's rows, in the ledger's
/// day label style.
class _DayLabel extends StatelessWidget {
  final DateTime day;

  const _DayLabel({required this.day});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, AppSpace.gap, 20, 6),
      child: Text(
        fmtDayHeading(day),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A suggestion side's account: its name, else the SMS sender.
String _side(FinanceProvider finance, Tx t) =>
    finance.accountForKey(t.acctKey)?.name ??
    (t.sender.isNotEmpty ? t.sender : 'Unknown account');

/// One "Looks like a transfer" suggestion: pair the two legs, or dismiss
/// the guess for good.
class _TransferSuggestionRow extends StatelessWidget {
  final PairSuggestion suggestion;
  final _OfferUndo offerUndo;

  const _TransferSuggestionRow({
    required this.suggestion,
    required this.offerUndo,
  });

  @override
  Widget build(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    final s = suggestion;
    final kindLabel = switch (s.kind) {
      PairKind.cardPayment => 'card payment',
      PairKind.savings => 'savings deposit',
      PairKind.transfer => 'transfer',
    };
    return _SuggestionCard(
      icon: Icons.sync_alt,
      kind: 'Looks like a $kindLabel',
      sides: [
        (label: _side(finance, s.out), tx: s.out),
        (label: _side(finance, s.incoming), tx: s.incoming),
      ],
      dismissLabel: 'Not a transfer',
      onDismiss: () {
        final settings = context.read<SettingsProvider>();
        final key = s.key;
        // Dismissed first: offerUndo belongs to the sheet and stays valid
        // when this card leaves, and it reads the queue after the change.
        settings.dismissPairSuggestion(key);
        offerUndo(
          'Marked not a $kindLabel',
          () => settings.restorePairSuggestion(key),
          icon: Icons.link_off,
        );
      },
      acceptLabel: 'Pair',
      onAccept: () async {
        // Pairing confirms both legs and rewrites their categories; Undo
        // puts the rows back as they were, a pending leg back in review.
        final before = [s.out, s.incoming];
        final pairId = await finance.pairTransactions(s.out.id, s.incoming.id);
        if (pairId == null) return;
        offerUndo(
          'Paired as $kindLabel',
          () => finance.restoreEditedTransactions(before),
          icon: Icons.link,
        );
      },
    );
  }
}

/// One "Looks like a refund" suggestion: link the refund to the purchase
/// it gives money back for, or dismiss the guess for good.
class _RefundSuggestionRow extends StatelessWidget {
  final RefundSuggestion suggestion;
  final _OfferUndo offerUndo;

  const _RefundSuggestionRow({
    required this.suggestion,
    required this.offerUndo,
  });

  @override
  Widget build(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    final s = suggestion;
    return _SuggestionCard(
      icon: Icons.undo,
      kind: 'Looks like a refund',
      sides: [
        (
          label:
              finance.merchantLabelFor(s.purchase) ?? s.purchase.category.label,
          tx: s.purchase,
        ),
        (label: _side(finance, s.refund), tx: s.refund),
      ],
      dismissLabel: 'Not a refund',
      onDismiss: () {
        final settings = context.read<SettingsProvider>();
        final key = s.key;
        final refundId = s.refund.id;
        final past = !s.refund.pending;
        settings.dismissPairSuggestion(key);
        // A counted refund the one-time pass offered stops being looked at.
        if (past) finance.dropRefundReviewId(refundId);
        offerUndo('Marked not a refund', () {
          settings.restorePairSuggestion(key);
          if (past) finance.restoreRefundReviewId(refundId);
        }, icon: Icons.link_off);
      },
      acceptLabel: 'Link',
      onAccept: () async {
        final before = s.refund;
        final linked = await finance.linkRefund(before.id, s.purchase.id);
        if (!linked) return;
        // Putting the row back as it was also returns a refund that was
        // in review to the sheet, which unlinking alone would not; a past
        // refund goes back on the one-time pass's list.
        offerUndo('Linked as a refund', () {
          finance.restoreEditedTransactions([before]);
          if (!before.pending) finance.restoreRefundReviewId(before.id);
        }, icon: Icons.link);
      },
    );
  }
}

/// A suggestion as its own outlined card: what the match looks like, one
/// line per side (its account or merchant and date on the left, its signed
/// amount on the right), then dismiss and accept.
class _SuggestionCard extends StatelessWidget {
  final IconData icon;
  final String kind;
  final List<({String label, Tx tx})> sides;
  final String dismissLabel;
  final VoidCallback onDismiss;
  final String acceptLabel;
  final VoidCallback onAccept;

  const _SuggestionCard({
    required this.icon,
    required this.kind,
    required this.sides,
    required this.dismissLabel,
    required this.onDismiss,
    required this.acceptLabel,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpace.card, 4, AppSpace.card, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  kind,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final side in sides)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Two lines before a long account name is cut.
                  Expanded(
                    flex: 3,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: side.label),
                          // The day alone: with the time the line wrapped
                          // at 360dp, and the two sides are hours apart.
                          TextSpan(
                            text:
                                ' · ${fmtDateCompact(DateUtils.dateOnly(side.tx.date))}',
                            style: muted,
                          ),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // At most 2/5 of the line: a large figure at a large
                  // text scale shrinks rather than push the name out.
                  Flexible(
                    flex: 2,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Text(
                        '${side.tx.type == TxType.income ? '+' : '−'}'
                        '${fmtMoneyTidy(side.tx.amount)}',
                        style: text.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: moneyColor(
                            context,
                            type: side.tx.type,
                            transfer: isTransferCategory(side.tx.categoryId),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Stacks, right-aligned, when the two buttons do not fit side by
          // side (320dp with large text). Compact-sized buttons with a 48dp
          // tap target: compact density would shrink the target to 40.
          OverflowBar(
            alignment: MainAxisAlignment.end,
            overflowAlignment: OverflowBarAlignment.end,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.standard,
                  minimumSize: const Size(56, 32),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                onPressed: onDismiss,
                child: Text(dismissLabel),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.standard,
                  minimumSize: const Size(56, 32),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                onPressed: onAccept,
                child: Text(acceptLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Suspected spam at the bottom of the sheet: a red-outlined fold, folded
/// while anything else waits and held open (no fold control) once spam is
/// all that is left. Reviewed one at a time only: no batch action.
class _SpamFold extends StatelessWidget {
  final List<Tx> suspects;
  final bool open;
  final bool canFold;
  final VoidCallback onToggle;
  final _OfferUndo offerUndo;

  const _SpamFold({
    required this.suspects,
    required this.open,
    required this.canFold,
    required this.onToggle,
    required this.offerUndo,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final title = Text(
      'Suspected spam · ${suspects.length}',
      style: text.titleSmall,
    );
    // The warning lives on the outline and icon, not a pink fill under text.
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: scheme.error.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: canFold ? onToggle : null,
            // A 48dp row, folded or open, so the fold and the "i" each
            // take a full tap.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.card),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        // The "i" only while open; folded, the title alone.
                        // 48dp: a near miss would fold the card.
                        child: !open
                            ? title
                            : InfoTipTarget(
                                size: 48,
                                child: InfoLabel(
                                  icon: true,
                                  label: title,
                                  tip: const InfoTip(
                                    title: 'Suspected spam',
                                    message:
                                        'Messages containing one of the '
                                        'Flagged as spam phrases on the '
                                        "Cockpit's Import tab wait here. "
                                        'Confirm or discard each one; there '
                                        'is no batch confirm for these.',
                                    link: InfoLink(
                                      prompt: 'Want fewer false flags?',
                                      label: 'Edit import rules',
                                      onTap: goCockpitImport,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                    if (canFold)
                      AnimatedRotation(
                        turns: open ? 0 : 0.5,
                        duration: AnimatedFold.duration,
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.expand_less,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedFold(
            collapsed: !open,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.card,
                    0,
                    AppSpace.card,
                    4,
                  ),
                  child: Text(
                    'Confirm all and Discard all skip these.',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final tx in suspects)
                  _ReviewRow(tx: tx, spam: true, offerUndo: offerUndo),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One import waiting for review: the merchant (or the category when the
/// row names none) over the signed amount and the category, with Confirm
/// and Discard. Above [kLargeTextScale] the two buttons move under the
/// text, so the text keeps the row's width. Time and sender stay in the
/// edit sheet.
class _ReviewRow extends StatelessWidget {
  final Tx tx;

  /// A suspected spam row: its amount is plain text, not money green or
  /// red, since it may be no money at all, and its day ends line two, as
  /// the fold has no day labels.
  final bool spam;
  final _OfferUndo offerUndo;

  const _ReviewRow({
    required this.tx,
    required this.offerUndo,
    this.spam = false,
  });

  /// "the sender" part of a toast: the SMS sender, or "SMS".
  String get _from => tx.sender.isEmpty ? 'SMS' : tx.sender;

  @override
  Widget build(BuildContext context) {
    final cat = tx.category;
    final isIncome = tx.type == TxType.income;
    final large = isLargeTextScale(context);
    final finance = context.read<FinanceProvider>();
    final title = finance.rowTitleFor(tx) ?? cat.label;
    final tile = ListTile(
      dense: true,
      contentPadding: EdgeInsetsDirectional.only(
        start: AppSpace.card,
        end: large ? AppSpace.card : 24,
      ),
      // The edit sheet's Undo offers made as it closes (a delete, Unpair, a
      // confirming save) go through this sheet's routing too, tone and all.
      onTap: () =>
          showAddTransactionSheet(context, existing: tx, onUndoable: offerUndo),
      leading: CategoryTileIcon(category: cat),
      title: Text(
        title,
        // Two lines at every size: SMS merchant names run long.
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      // The amount in its money colour, as on the ledger rows; plain on a
      // spam suspect.
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${isIncome ? '+' : '−'}${fmtMoney(tx.amount)}',
              style: TextStyle(
                color: spam
                    ? Theme.of(context).colorScheme.onSurface
                    : moneyColor(
                        context,
                        type: tx.type,
                        transfer: isTransferCategory(tx.categoryId),
                      ),
              ),
            ),
            if (title != cat.label) TextSpan(text: ' · ${cat.label}'),
            if (spam)
              TextSpan(
                text: ' · ${fmtDateCompact(DateUtils.dateOnly(tx.date))}',
              ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: large ? null : _actions(context),
    );
    if (!large) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: _actions(context),
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Confirm',
        icon: Icon(
          Icons.check_circle_outline,
          color: AppColors.of(context).green,
        ),
        // Symmetric with Discard below: Undo puts the captured pending copy
        // back in review.
        onPressed: () {
          final finance = context.read<FinanceProvider>();
          final confirmed = tx;
          finance.confirmTransaction(confirmed.id);
          offerUndo(
            'Confirmed ${fmtMoney(confirmed.amount)} from $_from',
            () => finance.restoreEditedTransactions([confirmed]),
            icon: Icons.done_all,
            tone: AppToastTone.success,
          );
        },
      ),
      IconButton(
        tooltip: 'Discard',
        icon: const Icon(Icons.cancel_outlined),
        onPressed: () {
          final finance = context.read<FinanceProvider>();
          final discarded = tx;
          finance.deleteTransaction(discarded.id);
          // Restoring keeps pending: true, so the row returns to review
          // rather than silently joining the ledger.
          offerUndo(
            'Discarded ${fmtMoney(discarded.amount)} from $_from',
            () => finance.restoreTransaction(discarded),
            icon: Icons.block,
            tone: AppToastTone.removal,
          );
        },
      ),
    ],
  );
}
