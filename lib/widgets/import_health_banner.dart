import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/finance_provider.dart';
import '../services/import_health.dart';
import '../services/sms_source.dart';
import '../utils/format.dart';

/// The Overview's "bank alerts stopped importing" card: a bank whose alerts
/// look like transactions but cannot be read, or one that alerted regularly
/// and went quiet. Dismiss hides it until a newer problem; See alerts lists
/// the unread texts so one can be checked or sent for a parser fix.
class ImportHealthBanner extends StatefulWidget {
  const ImportHealthBanner({super.key});

  @override
  State<ImportHealthBanner> createState() => _ImportHealthBannerState();
}

class _ImportHealthBannerState extends State<ImportHealthBanner> {
  ImportHealthState _health = ImportHealthState.empty;
  DateTime? _lastScan;
  Object? _rev;
  List<BankSilence> _silent = const [];
  DateTime? _silentFor;
  Object? _silentRev;

  @override
  void initState() {
    super.initState();
    // An import that added no rows (every alert unreadable, say) does not
    // change the ledger, so it signals here instead.
    importHealthChanged.addListener(_onChanged);
  }

  @override
  void dispose() {
    importHealthChanged.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => unawaited(_reload());

  /// Read on a ledger change and on [importHealthChanged].
  Future<void> _reload() async {
    final health = await ImportHealth.load();
    var lastScan = await ImportHealth.lastScan();
    // With Read SMS revoked the marker stops, and silence measured to it
    // would never grow: that is the case the warning's advice names, so
    // count to today instead.
    if (lastScan != null && !await _smsReadable()) lastScan = DateTime.now();
    if (!mounted) return;
    setState(() {
      _health = health;
      _lastScan = lastScan;
    });
  }

  static Future<bool> _smsReadable() async {
    final source = SmsSource();
    if (!source.isSupported) return true;
    try {
      return await source.hasPermission();
    } catch (_) {
      // No platform answer (tests, a plugin hiccup): assume nothing changed.
      return true;
    }
  }

  Future<void> _dismiss(List<ImportWarning> warnings) async {
    final now = DateTime.now();
    for (final w in warnings) {
      await ImportHealth.dismiss(w.bank, now);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final now = DateTime.now();
    if (!identical(_rev, finance.revision)) {
      _rev = finance.revision;
      _silentFor = null;
      unawaited(_reload());
    }
    // Worked out again when the ledger or the last scan moves.
    if (_silentFor != _lastScan || _silentRev != _rev) {
      _silentFor = _lastScan;
      _silentRev = _rev;
      _silent = detectSilentBanks(
        [...finance.transactions, ...finance.pendingTransactions],
        now,
        scannedUntil: _lastScan,
      );
    }
    final warnings = buildImportWarnings(_health, _silent, now);
    if (warnings.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final first = warnings.first;
    final bank = bankLabel(first.bank);
    final title = first.kind == ImportWarningKind.unreadable
        ? '${first.count} $bank alerts in $kUnreadWindowDays days could not '
              'be read'
        : 'No $bank alerts since ${fmtDate(first.since)}';
    final detail = first.kind == ImportWarningKind.unreadable
        ? 'Their format may have changed. They are not imported until the '
              'app can read them.'
        : 'It usually sends one every ${first.usualGapDays} '
              '${first.usualGapDays == 1 ? 'day' : 'days'}. Check SMS '
              'permission and notification access, or dismiss this if the '
              'account is closed.';
    final more = warnings.length - 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.report_problem_outlined,
                    size: 20,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(title, style: text.titleMedium)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                more > 0
                    ? '$detail And $more more '
                          '${more == 1 ? 'bank' : 'banks'}.'
                    : detail,
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => showImportHealthSheet(context, warnings),
                    child: const Text('See alerts'),
                  ),
                  OutlinedButton(
                    onPressed: () => _dismiss(warnings),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Each warning with its reason and, for unreadable alerts, the stored
/// sample texts, each with Copy.
Future<void> showImportHealthSheet(
  BuildContext context,
  List<ImportWarning> warnings,
) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.8,
    ),
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final text = Theme.of(ctx).textTheme;
      // Copied samples show a tick instead of a toast, which would sit
      // under this sheet.
      final copied = <String>{};
      return StatefulBuilder(
        builder: (ctx, setState) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text('Bank alerts not importing', style: text.titleMedium),
              const SizedBox(height: 12),
              for (final w in warnings) ...[
                Text(bankLabel(w.bank), style: text.titleSmall),
                const SizedBox(height: 2),
                Text(
                  w.kind == ImportWarningKind.unreadable
                      ? '${w.count} alerts since ${fmtDate(w.since)} looked '
                            'like transactions but could not be read.'
                      : 'Last alert read on ${fmtDate(w.since)}; it usually '
                            'sends one every ${w.usualGapDays} '
                            '${w.usualGapDays == 1 ? 'day' : 'days'}.',
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                if (w.kind == ImportWarningKind.unreadable)
                  for (final s in (w.health?.samples ?? const []).reversed)
                    Builder(
                      builder: (_) {
                        final id = '${w.bank}|${s.at.millisecondsSinceEpoch}';
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${s.sender} · '
                                        '${fmtDateTime(s.at)}',
                                        style: text.labelSmall?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      SelectableText(
                                        s.body,
                                        style: text.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: copied.contains(id)
                                      ? 'Copied'
                                      : 'Copy',
                                  icon: Icon(
                                    copied.contains(id)
                                        ? Icons.check
                                        : Icons.copy_outlined,
                                  ),
                                  onPressed: () async {
                                    await Clipboard.setData(
                                      ClipboardData(text: s.body),
                                    );
                                    setState(() => copied.add(id));
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                const SizedBox(height: 8),
              ],
              Text(
                'To see why one fails, paste it into Cockpit, Import, Test '
                'a message.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          );
        },
      );
    },
  );
}
