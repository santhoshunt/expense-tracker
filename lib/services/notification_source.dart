import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'sms_source.dart' show SmsMessage;

/// Gateway to notification-captured bank alerts.
///
/// RCS business messages (verified "Yes Bank"-style chats) are stored in the
/// messaging app's private database and cannot be read through the SMS
/// provider. Their notifications *can* be observed: a platform-side
/// NotificationListenerService buffers anything money-looking from messaging
/// apps, and imports drain that buffer here.
///
/// Access is the system "Notification access" special permission — granted
/// on its own settings page, not via a runtime dialog.
class NotificationSource {
  static const _channel = MethodChannel('expense_tracker/sms');

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// True when notification access is granted — never shows any UI.
  Future<bool> hasAccess() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('notifHasAccess') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the system notification-access settings page.
  Future<void> openAccessSettings() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('notifOpenSettings');
  }

  /// Capture-chain diagnostics from the platform listener: connect times,
  /// per-stage event counters and the last observed message sample. Keys:
  /// connectedAt, disconnectedAt, eventsTotal, eventsWatched, eventsMoney,
  /// storedTotal, lastCapture (all int millis/counts), bufferSize (int),
  /// lastSample (String?). Empty map when unsupported.
  Future<Map<String, dynamic>> diagnostics() async {
    if (!isSupported) return const {};
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'notifDiagnostics',
      );
      return raw ?? const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// When the listener last captured a bank alert (survives drains), or null
  /// when nothing has ever been captured. Diagnostic: proves whether the
  /// capture pipeline is alive independent of imports.
  Future<DateTime?> lastCapture() async {
    if (!isSupported) return null;
    try {
      final millis = await _channel.invokeMethod<int>('notifLastCapture');
      if (millis == null || millis <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    } on MissingPluginException {
      return null;
    }
  }

  /// The captured messages, left in the platform buffer until [ack]: an
  /// import that dies before saving its rows reads them again next time.
  Future<NotificationBatch> peek() async {
    if (!isSupported || !await hasAccess()) return NotificationBatch.empty;
    final raw = await _channel.invokeMapMethod<String, dynamic>('notifPeek');
    final list = (raw?['messages'] as List?) ?? const [];
    return NotificationBatch([
      for (final e in list)
        () {
          final m = Map<String, dynamic>.from(e as Map);
          return SmsMessage(
            sender: m['address'] as String? ?? '',
            body: m['body'] as String? ?? '',
            date: DateTime.fromMillisecondsSinceEpoch(
              (m['date'] as num?)?.toInt() ?? 0,
            ),
          );
        }(),
    ], (raw?['maxSeq'] as num?)?.toInt() ?? -1);
  }

  /// Clears the messages [peek] returned (up to [batch]'s last one) once
  /// their rows are saved. Messages captured since stay buffered.
  Future<void> ack(NotificationBatch batch) async {
    if (!isSupported || batch.messages.isEmpty) return;
    await _channel.invokeMethod<void>('notifAck', {'maxSeq': batch.maxSeq});
  }
}

/// What [NotificationSource.peek] found, and where it ends in the buffer.
class NotificationBatch {
  final List<SmsMessage> messages;
  final int maxSeq;
  const NotificationBatch(this.messages, this.maxSeq);

  static const empty = NotificationBatch([], -1);
}
