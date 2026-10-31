import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/format.dart';
import 'launch_actions.dart';
import 'notification_ids.dart';
import 'notification_service.dart';

/// Keep taps not yet applied, as [importCheckPayload] strings. The plugin's
/// own engine writes it and must never load the ledger (only one isolate
/// may hold it), so the engine that does applies them ([applyKept]).
const String kImportChecksKeptKey = 'import_checks_kept_v1';

/// Keep taps from the Payments to check widget, a JSON array of
/// [importCheckPayload] strings that Kotlin writes as a plain string
/// (HomeWidgets.queueKeep), drained here.
const String kImportChecksWidgetKeptKey = 'import_checks_widget_kept_v1';

/// The payloads queued under [kImportChecksWidgetKeptKey], or none when the
/// key is missing or malformed.
List<String> _widgetKept(SharedPreferences prefs) {
  final raw = prefs.getString(kImportChecksWidgetKeptKey);
  if (raw == null) return [];
  try {
    final list = jsonDecode(raw);
    if (list is! List) return [];
    return [
      for (final p in list)
        if (p is String && p.isNotEmpty) p,
    ];
  } on FormatException {
    return [];
  }
}

/// The name the open app's port for Keep taps goes by. The plugin's engine
/// runs in the app's process, so it finds the port here and the app applies
/// the tap at once; with no app open the tap waits in [kImportChecksKeptKey].
const String kImportChecksPortName = 'import_checks_keep';

/// The most notes one background run posts, newest first. A first-run
/// backfill can count dozens of rows; the rest show their pill in the app.
const int kMaxImportCheckNotes = 5;

/// A row that counted at once with a guessed category or as To sort, and
/// the user has not opened yet.
bool needsImportCheck(Tx t) =>
    !t.pending &&
    t.unseen &&
    (t.categoryGuessed || isToSortCategory(t.categoryId));

/// Payment-to-check notes: one per row a background import counted with a
/// guessed category or as To sort, bundled under a summary. Keep confirms
/// the guess without opening the app, at once when the app is open and
/// otherwise when it next opens; Change opens the row. The
/// shade itself is the record of which notes are up
/// ([NotificationService.activeImportChecks]), so swipes need no tracking.
abstract final class ImportChecks {
  /// Ids of the rows that need a check now.
  static Set<String> checkIds(FinanceProvider finance) => {
    for (final t in finance.transactions)
      if (needsImportCheck(t)) t.id,
  };

  /// Posts a note for each row needing a check that was not in [before]
  /// (the [checkIds] taken before the import).
  static Future<void> post(
    FinanceProvider finance,
    Set<String> before, {
    NotificationService? notifications,
  }) async {
    if (finance.loadWarnings.isNotEmpty) return;
    final n = notifications ?? NotificationService.instance;
    final fresh = [
      for (final t in finance.transactions)
        if (needsImportCheck(t) && !before.contains(t.id)) t,
    ]..sort((a, b) => b.date.compareTo(a.date));
    if (fresh.isEmpty) return;
    for (final t in fresh.take(kMaxImportCheckNotes)) {
      final guessed = t.categoryGuessed;
      final category = categoryById(t.categoryId).label;
      await n.showImportCheck(
        id: NotificationIds.importCheck(t.id),
        title: _titleOf(finance, t),
        body: guessed
            ? 'Guessed $category. Already counted.'
            : 'To sort. Already counted.',
        payload: importCheckPayload(t.id, t.categoryId),
        keepLabel: guessed ? 'Keep $category' : null,
      );
    }
    await syncSummary(n);
  }

  /// "₹2,450 to Supermarket", or "₹2,450 paid" when the row names no one.
  static String _titleOf(FinanceProvider finance, Tx t) {
    final income = t.type == TxType.income;
    final name = finance.rowTitleFor(t);
    if (name == null) {
      return '${fmtMoney(t.amount)} ${income ? 'received' : 'paid'}';
    }
    return '${fmtMoney(t.amount)} ${income ? 'from' : 'to'} $name';
  }

  /// Cancels the notes whose row no longer needs a check (confirmed,
  /// edited, opened, deleted), or every note when [enabled] is false.
  static Future<void> sync(
    FinanceProvider finance, {
    required bool enabled,
    NotificationService? notifications,
  }) async {
    final n = notifications ?? NotificationService.instance;
    final active = await n.activeImportChecks();
    // No early return on an empty shade: a summary whose last note went
    // still has to go.
    // Matched by note id, the hash of the row id: the shade hands back no
    // payloads.
    final open = enabled
        ? {for (final id in checkIds(finance)) NotificationIds.importCheck(id)}
        : const <int>{};
    for (final id in active) {
      if (!open.contains(id)) await n.cancelId(id);
    }
    await syncSummary(n);
  }

  /// Queues a Keep tap for [applyKept]. Reloads first: another engine may
  /// have queued one since this isolate last read prefs.
  static Future<void> keep(String? payload) async {
    if (payload == null || parseImportCheckPayload(payload) == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.setStringList(kImportChecksKeptKey, [
      ...?prefs.getStringList(kImportChecksKeptKey),
      payload,
    ]);
    // An open app applies it now rather than on its next resume.
    IsolateNameServer.lookupPortByName(kImportChecksPortName)?.send(null);
  }

  /// The open app's port for Keep taps: [onKeep] runs for each one. Replaces
  /// a mapping a previous engine left behind.
  static ReceivePort listenForKeeps(void Function() onKeep) {
    IsolateNameServer.removePortNameMapping(kImportChecksPortName);
    final port = ReceivePort()..listen((_) => onKeep());
    IsolateNameServer.registerPortWithName(
      port.sendPort,
      kImportChecksPortName,
    );
    return port;
  }

  /// Closes a [listenForKeeps] port and drops its name.
  static void stopListening(ReceivePort port) {
    IsolateNameServer.removePortNameMapping(kImportChecksPortName);
    port.close();
  }

  /// Confirms the queued Keep taps in the ledger, from the notes
  /// ([kImportChecksKeptKey]) and from the Payments to check widget
  /// ([kImportChecksWidgetKeptKey]), then drops them from both queues. A tap
  /// landing between the second reload and the write is lost and its row
  /// stays guessed; the row still counts and its pill still offers Keep.
  static Future<void> applyKept(FinanceProvider finance) async {
    if (finance.loadWarnings.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final read = prefs.getStringList(kImportChecksKeptKey) ?? const [];
    final fromWidget = _widgetKept(prefs);
    if (read.isEmpty && fromWidget.isEmpty) return;
    await finance.confirmGuesses([
      for (final p in [...read, ...fromWidget]) ?parseImportCheckPayload(p),
    ]);
    await prefs.reload();
    if (read.isNotEmpty) {
      final now = [...?prefs.getStringList(kImportChecksKeptKey)];
      for (final p in read) {
        now.remove(p);
      }
      await prefs.setStringList(kImportChecksKeptKey, now);
    }
    if (fromWidget.isNotEmpty) {
      await prefs.setString(
        kImportChecksWidgetKeptKey,
        jsonEncode(_widgetKept(prefs)..removeWhere(fromWidget.contains)),
      );
    }
  }

  /// Shows the summary over two or more notes, else cancels it.
  static Future<void> syncSummary([NotificationService? notifications]) async {
    final n = notifications ?? NotificationService.instance;
    final count = (await n.activeImportChecks()).length;
    if (count >= 2) {
      await n.showImportCheckSummary(count);
    } else {
      await n.cancelId(NotificationIds.importCheckSummary);
    }
  }
}

/// Keep on a payment-to-check note, run by the plugin in its own engine
/// whether or not the app is alive. The plugin has already cancelled the
/// note, so the summary count is current.
@pragma('vm:entry-point')
Future<void> importCheckAction(NotificationResponse r) async {
  if (r.actionId != kImportCheckKeepAction) return;
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await ImportChecks.keep(r.payload);
  } catch (e) {
    debugPrint('Keep failed: $e');
  }
  try {
    await NotificationService.instance.init();
    await ImportChecks.syncSummary();
  } catch (e) {
    debugPrint('Payments to check summary failed: $e');
  }
}
