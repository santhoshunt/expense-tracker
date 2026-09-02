import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'glossy.dart';

/// Fixed-height frosted sheet listing [months] (as given, normally newest
/// first); resolves to the tapped month or null when dismissed. A long
/// history must not overflow past the navigation bar, hence the cap.
Future<DateTime?> showMonthPickerSheet(
  BuildContext context, {
  required String title,
  required List<DateTime> months,
  DateTime? selected,
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    useSafeArea: true,
    // Absolute cap for tall screens; short landscape viewports get a
    // fraction of the viewport instead of overflowing a fixed 420.
    constraints: BoxConstraints(
      maxHeight: switch (MediaQuery.sizeOf(context).height * 0.6) {
        final h when h < 420 => h,
        _ => 420,
      },
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: FrostedPanel(
          radius: BorderRadius.circular(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(
                    ctx,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(title, style: Theme.of(ctx).textTheme.titleSmall),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: months.length,
                  itemBuilder: (_, i) {
                    final m = months[i];
                    final isSelected =
                        selected != null &&
                        selected.year == m.year &&
                        selected.month == m.month;
                    return ListTile(
                      dense: true,
                      selected: isSelected,
                      title: Text(
                        DateFormat('MMMM yyyy').format(m),
                        textAlign: TextAlign.center,
                      ),
                      onTap: () => Navigator.pop(ctx, m),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
