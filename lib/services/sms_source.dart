import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A raw SMS message as returned by the platform.
class SmsMessage {
  final String sender;
  final String body;
  final DateTime date;

  const SmsMessage({
    required this.sender,
    required this.body,
    required this.date,
  });
}

enum SmsPermission {
  granted,
  denied,

  /// The OS refused without showing a dialog. READ_SMS is hard-restricted on
  /// Android 10+, so sideloaded installs must enable it manually in app
  /// settings ("Allow restricted settings" first on Android 13+).
  blocked,
}

/// One inbox scan's result. [complete] is false when the platform did NOT
/// read the whole requested window (hit its sanity ceiling, or the provider
/// threw mid-scan) — the import service must then leave its incremental
/// marker alone, or the unread tail is skipped forever.
class SmsQueryResult {
  final List<SmsMessage> messages;
  final bool complete;

  const SmsQueryResult({required this.messages, required this.complete});
}

/// Platform gateway for reading the SMS inbox. Only Android exposes an SMS
/// API; on iOS/web/desktop [isSupported] is false and the feature is hidden.
class SmsSource {
  static const _channel = MethodChannel('expense_tracker/sms');

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// True when READ_SMS is already granted — never shows a dialog.
  Future<bool> hasPermission() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('hasPermission') ?? false;
  }

  /// Asks for READ_SMS at runtime.
  Future<SmsPermission> requestPermission() async {
    if (!isSupported) return SmsPermission.denied;
    final status = await _channel.invokeMethod<String>('requestPermission');
    return SmsPermission.values.asNameMap()[status] ?? SmsPermission.denied;
  }

  /// Opens this app's system settings page so the user can grant SMS access
  /// manually when the permission dialog is suppressed.
  Future<void> openAppSettings() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('openAppSettings');
  }

  /// Inbox messages newer than [since] (and older than [until], when given),
  /// newest first. The platform side pages through the provider, so long
  /// windows are returned in full — and reports when they were not
  /// (see [SmsQueryResult.complete]).
  Future<SmsQueryResult> query({
    required DateTime since,
    DateTime? until,
  }) async {
    if (!isSupported) {
      return const SmsQueryResult(messages: [], complete: true);
    }
    final raw = await _channel.invokeMapMethod<String, dynamic>('querySms', {
      'sinceMillis': since.millisecondsSinceEpoch,
      if (until != null) 'untilMillis': until.millisecondsSinceEpoch,
    });
    final messages = ((raw?['messages'] as List?) ?? const []).map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return SmsMessage(
        sender: m['address'] as String? ?? '',
        body: m['body'] as String? ?? '',
        date: DateTime.fromMillisecondsSinceEpoch(
          (m['date'] as num?)?.toInt() ?? 0,
        ),
      );
    }).toList();
    return SmsQueryResult(
      messages: messages,
      complete: raw?['complete'] as bool? ?? false,
    );
  }
}
