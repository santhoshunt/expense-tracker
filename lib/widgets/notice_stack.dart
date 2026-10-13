import 'package:flutter/material.dart';

import '../services/update_service.dart';
import 'import_health_banner.dart';
import 'update_banner.dart';

/// The Overview's notices (a newer release, bank alerts not importing) in
/// one slot: one at a time with "1 of 2" and arrows, instead of a stack of
/// cards pushing the balance down. Both cards stay mounted (the hidden one
/// offstage), so each keeps watching for its own news.
class NoticeStack extends StatefulWidget {
  const NoticeStack({super.key});

  @override
  State<NoticeStack> createState() => _NoticeStackState();
}

class _NoticeStackState extends State<NoticeStack> {
  /// Which notice shows while both do: 0 the update, 1 the import warning.
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateList?>(
      valueListenable: availableUpdate,
      builder: (context, updates, _) => ValueListenableBuilder<bool>(
        valueListenable: ImportHealthBanner.showing,
        builder: (context, importShowing, _) {
          final updateShowing = UpdateBanner.showing(context, updates);
          final both = updateShowing && importShowing;
          // One notice alone always shows; the pager only splits two.
          final shown = !both ? (updateShowing ? 0 : 1) : _index;
          final scheme = Theme.of(context).colorScheme;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Offstage(offstage: shown != 0, child: const UpdateBanner()),
              Offstage(offstage: shown != 1, child: const ImportHealthBanner()),
              if (both)
                Padding(
                  // Pulls up into the shown card's bottom gap.
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Transform.translate(
                    offset: const Offset(0, -12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '${shown + 1} of 2',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        IconButton(
                          tooltip: 'Previous notice',
                          visualDensity: VisualDensity.compact,
                          onPressed: shown == 0
                              ? null
                              : () => setState(() => _index = 0),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        IconButton(
                          tooltip: 'Next notice',
                          visualDensity: VisualDensity.compact,
                          onPressed: shown == 1
                              ? null
                              : () => setState(() => _index = 1),
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
