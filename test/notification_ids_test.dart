import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/services/notification_ids.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/unusual_spend_monitor.dart';

void main() {
  test('no two notification id ranges overlap', () {
    final ranges = NotificationIds.ranges;
    for (final r in ranges) {
      expect(r.start, lessThanOrEqualTo(r.end), reason: r.owner);
    }
    for (var i = 0; i < ranges.length; i++) {
      for (var j = i + 1; j < ranges.length; j++) {
        final a = ranges[i];
        final b = ranges[j];
        final overlap = a.start <= b.end && b.start <= a.end;
        expect(overlap, isFalse, reason: '${a.owner} and ${b.owner}');
      }
    }
  });

  test('the fixed ids in NotificationService match the table', () {
    expect(NotificationService.reviewNotificationId, NotificationIds.review);
    expect(NotificationService.recapNotificationId, NotificationIds.recap);
  });

  test('every helper stays inside its own range', () {
    const keys = [
      '',
      'b1',
      'budget-0f3a',
      'food',
      'acct-hdfc-1234',
      'a much longer identifier than any real one would be',
    ];
    for (final k in keys) {
      final custom = NotificationIds.customBudget(k);
      expect(custom, inInclusiveRange(300000, 399999), reason: k);
      expect(
        NotificationIds.cardBill(k),
        inInclusiveRange(
          NotificationIds.cardBillStart,
          NotificationIds.cardBillEnd,
        ),
      );
      expect(
        NotificationIds.recurring(k),
        inInclusiveRange(
          NotificationIds.recurringStart,
          NotificationIds.recurringEnd,
        ),
      );
      expect(
        NotificationIds.reminder(k),
        inInclusiveRange(
          NotificationIds.reminderStart,
          NotificationIds.reminderEnd,
        ),
      );
      expect(
        UnusualSpendMonitor.notificationId(k),
        inInclusiveRange(
          NotificationIds.unusualStart,
          NotificationIds.unusualEnd,
        ),
      );
    }
    for (var m = 1; m <= 12; m++) {
      expect(
        NotificationIds.cap(m),
        inInclusiveRange(NotificationIds.capStart, NotificationIds.capEnd),
      );
    }
  });
}
