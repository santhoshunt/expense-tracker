import 'package:flutter/material.dart';

/// Date picker, then time picker, as one moment. Null when either is
/// dismissed or [context] unmounts in between.
///
/// [initial] is clamped into `[firstDate, lastDate]`: `showDatePicker`
/// asserts on an initial date outside its range.
Future<DateTime?> pickDateThenTime(
  BuildContext context, {
  required DateTime initial,
  required DateTime firstDate,
  required DateTime lastDate,
}) async {
  final start = initial.isBefore(firstDate)
      ? firstDate
      : (initial.isAfter(lastDate) ? lastDate : initial);
  final date = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: firstDate,
    lastDate: lastDate,
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null || !context.mounted) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}
