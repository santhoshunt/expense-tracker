import 'package:flutter/material.dart' show DateTimeRange;
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart' show AutoImportFrequency;
import 'notification_source.dart';
import 'sms_parser.dart';
import 'sms_source.dart';

class SmsImportResult {
  final int scanned;
  final int matched;
  final int imported;

  /// Dropped by a user spam rule — never imported.
  final int spamDropped;

  const SmsImportResult({
    required this.scanned,
    required this.matched,
    required this.imported,
    required this.spamDropped,
  });

  int get duplicates => matched - imported - spamDropped;
}

/// Orchestrates one import run: permission → query window →
/// parse → hand off to the provider (rules, dedupe, pending state).
class SmsImportService {
  static const _lastScanKey = 'sms_last_scan_millis';
  static const _autoRunKey = 'sms_auto_import_last_run_millis';
  static const _backfillDays = 30;

  final SmsSource source;
  final NotificationSource notifications;

  SmsImportService({SmsSource? source, NotificationSource? notifications})
    : source = source ?? SmsSource(),
      notifications = notifications ?? NotificationSource();

  bool get isSupported => source.isSupported;

  Future<void> openAppSettings() => source.openAppSettings();

  /// Forgets the incremental-scan marker so the next default run backfills.
  /// Also forgets the auto-run marker: after "Delete all data" a daily
  /// auto-import that already ran today would otherwise wait until tomorrow
  /// to re-backfill.
  Future<void> resetLastScan() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastScanKey);
    await prefs.remove(_autoRunKey);
  }

  /// Runs a scheduled incremental import when [frequency] says one is due.
  /// Silent by design: never prompts for permission (skips when not yet
  /// granted) and returns null when nothing was due.
  ///
  /// "Daily" fires on the first launch of each calendar day — opening the
  /// app any time after end-of-day catches up on the whole previous day.
  Future<SmsImportResult?> maybeAutoRun(
    FinanceProvider finance,
    AutoImportFrequency frequency,
  ) async {
    if (!isSupported || frequency == AutoImportFrequency.off) return null;
    if (!await source.hasPermission()) return null;

    final prefs = await SharedPreferences.getInstance();
    final last = DateTime.fromMillisecondsSinceEpoch(
      prefs.getInt(_autoRunKey) ?? 0,
    );
    final now = DateTime.now();
    final due = switch (frequency) {
      AutoImportFrequency.off => false,
      AutoImportFrequency.everyOpen => true,
      AutoImportFrequency.daily =>
        last.year != now.year || last.month != now.month || last.day != now.day,
      // `last.isAfter(now)`: a clock that ever jumped forward wrote a
      // future marker, and the plain difference then stays negative forever.
      AutoImportFrequency.weekly =>
        last.isAfter(now) || now.difference(last) >= const Duration(days: 7),
    };
    if (!due) return null;

    final result = await run(finance);
    if (result != null) {
      await prefs.setInt(_autoRunKey, now.millisecondsSinceEpoch);
    }
    return result;
  }

  /// Returns null when permission was not granted (or platform unsupported);
  /// [lastPermission] then tells the caller whether the dialog was suppressed.
  SmsPermission lastPermission = SmsPermission.denied;

  /// Drains the RCS notification buffer and imports whatever is found.
  /// Safe to call on every launch — [NotificationSource.drain()] is a no-op
  /// when notification access is not granted or the platform is not Android.
  Future<int> drainNotifications(FinanceProvider finance) async {
    // The platform buffer is cleared by the drain itself and captures are
    // ephemeral (no backfill). While ledger writes are known to be failing,
    // leave the messages buffered — importing them now would hold them only
    // in memory, and an app kill would lose them permanently.
    if (finance.persistFailed) return 0;
    final msgs = await notifications.drain();
    if (msgs.isEmpty) return 0;
    final ignorePhrases = finance.ignorePhrases;
    final spamSignals = finance.spamSignals;
    final parsed = <ParsedTxn>[];
    for (final msg in msgs) {
      final txn = SmsTxnParser.parse(
        msg.sender,
        msg.body,
        msg.date,
        relaxedSender: true,
        ignorePhrases: ignorePhrases,
        spamSignals: spamSignals,
      );
      if (txn != null) parsed.add(txn);
    }
    if (parsed.isEmpty) return 0;
    final (imported, _) = await finance.addImported(parsed);
    return imported;
  }

  /// Scan window, by precedence: [range] (explicit calendar range) >
  /// [lookback] (e.g. last 90 days) > incremental since the last run
  /// (first run: 30-day backfill).
  Future<SmsImportResult?> run(
    FinanceProvider finance, {
    Duration? lookback,
    DateTimeRange? range,
  }) async {
    lastPermission = await source.requestPermission();

    // SMS permission denied — still attempt to drain any buffered RCS alerts.
    // Returns null only when the buffer is also empty so the caller can show
    // the correct "permission denied" message without silently losing RCS data.
    if (lastPermission != SmsPermission.granted) {
      // Same durability guard as drainNotifications: don't empty the
      // one-shot RCS buffer while ledger writes are failing.
      if (finance.persistFailed) return null;
      final notifMsgs = await notifications.drain();
      if (notifMsgs.isEmpty) return null;
      final ignorePhrases = finance.ignorePhrases;
      final spamSignals = finance.spamSignals;
      final parsed = <ParsedTxn>[];
      for (final msg in notifMsgs) {
        final txn = SmsTxnParser.parse(
          msg.sender,
          msg.body,
          msg.date,
          relaxedSender: true,
          ignorePhrases: ignorePhrases,
          spamSignals: spamSignals,
        );
        if (txn != null) parsed.add(txn);
      }
      final (imported, spamDropped) = await finance.addImported(parsed);
      return SmsImportResult(
        scanned: notifMsgs.length,
        matched: parsed.length,
        imported: imported,
        spamDropped: spamDropped,
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final int sinceMillis;
    if (range != null) {
      sinceMillis = range.start.millisecondsSinceEpoch;
    } else if (lookback != null) {
      sinceMillis = DateTime.now().subtract(lookback).millisecondsSinceEpoch;
    } else {
      sinceMillis =
          prefs.getInt(_lastScanKey) ??
          DateTime.now()
              .subtract(const Duration(days: _backfillDays))
              .millisecondsSinceEpoch;
    }
    // Range end is inclusive: include the whole end day.
    final untilMillis = range == null
        ? null
        : DateTime(
            range.end.year,
            range.end.month,
            range.end.day + 1,
          ).millisecondsSinceEpoch;

    final queryResult = await source.query(
      since: DateTime.fromMillisecondsSinceEpoch(sinceMillis),
      until: untilMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(untilMillis),
    );
    final messages = queryResult.messages;

    final parsed = <ParsedTxn>[];
    var scanned = 0;
    var newestMillis = sinceMillis;
    final ignorePhrases = finance.ignorePhrases;
    final spamSignals = finance.spamSignals;
    for (final msg in messages) {
      final millis = msg.date.millisecondsSinceEpoch;
      if (untilMillis != null && millis >= untilMillis) continue;
      scanned++;
      if (millis > newestMillis) newestMillis = millis;
      final txn = SmsTxnParser.parse(
        msg.sender,
        msg.body,
        msg.date,
        ignorePhrases: ignorePhrases,
        spamSignals: spamSignals,
      );
      if (txn != null) parsed.add(txn);
    }

    // Notification-captured alerts (RCS business chats the SMS provider can't
    // see). The buffer is ephemeral, so it is drained on every run regardless
    // of the scan window — relaxed sender matching because RCS senders are
    // brand names ("Yes Bank"), not DLT codes. Skipped while ledger writes
    // are failing: SMS stays re-scannable from the inbox, drained RCS does
    // not.
    if (!finance.persistFailed) {
      for (final msg in await notifications.drain()) {
        scanned++;
        final txn = SmsTxnParser.parse(
          msg.sender,
          msg.body,
          msg.date,
          relaxedSender: true,
          ignorePhrases: ignorePhrases,
          spamSignals: spamSignals,
        );
        if (txn != null) parsed.add(txn);
      }
    }

    final (imported, spamDropped) = await finance.addImported(parsed);
    // Advance the marker only when this scan is authoritative up to
    // `newestMillis`:
    //  * complete — the platform read the whole window (not truncated at
    //    its ceiling, not aborted mid-scan);
    //  * contiguous — the window starts at or before the current marker.
    //    A short lookback after a long gap ("Last 7 days" when the marker
    //    is 20 days old) used to jump the marker to now, permanently
    //    skipping the unscanned 13 days in between. A first run (no marker
    //    yet) is always contiguous — the backfill window defines the start.
    //  * durable — the ledger write behind addImported actually landed.
    //    _persist swallows its errors into persistFailed; advancing past
    //    rows that exist only in memory would skip those alerts on every
    //    future incremental scan even though they are still in the inbox.
    // Never move the marker backwards either way.
    final existing = prefs.getInt(_lastScanKey);
    final contiguous = existing == null || sinceMillis <= existing;
    if (queryResult.complete &&
        contiguous &&
        !finance.persistFailed &&
        newestMillis > (existing ?? 0)) {
      await prefs.setInt(_lastScanKey, newestMillis);
    }

    return SmsImportResult(
      scanned: scanned,
      matched: parsed.length,
      imported: imported,
      spamDropped: spamDropped,
    );
  }
}
