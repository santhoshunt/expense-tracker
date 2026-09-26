import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../services/update_service.dart';
import 'update_sheet.dart';

/// The Overview's "Update available" card: shown when the launch check (or
/// Settings) found a newer release and the newest one wasn't answered with
/// Not now. It only opens the version sheet; nothing downloads from here.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final dismissed = context.select<SettingsProvider, String?>(
      (s) => s.updateDismissedTag,
    );
    return ValueListenableBuilder<UpdateList?>(
      valueListenable: availableUpdate,
      builder: (context, updates, _) {
        if (updates == null || updates.newer.isEmpty) {
          return const SizedBox.shrink();
        }
        final newest = updates.newer.first.tag;
        if (newest == dismissed) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final n = updates.newer.length;
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.system_update_alt,
                        size: 20,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Update available: $newest',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    n == 1
                        ? 'A newer version is on GitHub.'
                        : '$n newer versions on GitHub.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () => showUpdateSheet(context, updates),
                        child: const Text('See versions'),
                      ),
                      OutlinedButton(
                        onPressed: () => context
                            .read<SettingsProvider>()
                            .dismissUpdate(newest),
                        child: const Text('Not now'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
