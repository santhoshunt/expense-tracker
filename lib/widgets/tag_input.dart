import 'package:flutter/material.dart';

import '../models/transaction.dart';

/// Tags on a transaction: the chosen ones as removable chips, a field that
/// adds one on Done or a comma, and recent tags to pick with a tap.
///
/// [controller] belongs to the caller so text typed but not yet added can
/// be saved too (see [pendingTagsOf]); a Save tap does not always take the
/// focus away from the field first.
class TagInput extends StatelessWidget {
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;

  /// Tags already in use, most recent first.
  final List<String> suggestions;
  final TextEditingController controller;

  const TagInput({
    super.key,
    required this.tags,
    required this.onChanged,
    required this.suggestions,
    required this.controller,
  });

  void _add(Iterable<String> more) =>
      onChanged(normalizeTags([...tags, ...more]));

  void _submit(String text) {
    _add(text.split(','));
    controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final full = tags.length >= kMaxTagsPerTx;
    final chosen = {for (final t in tags) tagKey(t)};

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final typed = tagKey(value.text.trim());
        final picks = [
          for (final s in suggestions)
            if (!chosen.contains(tagKey(s)) &&
                (typed.isEmpty || tagKey(s).contains(typed)))
              s,
        ].take(8).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in tags)
                      InputChip(
                        // TalkBack would read the "#" as "number".
                        label: Text('# $t', semanticsLabel: 'Tag $t'),
                        visualDensity: VisualDensity.compact,
                        deleteButtonTooltipMessage: 'Remove tag $t',
                        onDeleted: () => onChanged([
                          for (final x in tags)
                            if (x != t) x,
                        ]),
                      ),
                  ],
                ),
              ),
            TextField(
              controller: controller,
              enabled: !full,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.sentences,
              maxLength: kMaxTagLength,
              decoration: InputDecoration(
                labelText: 'Tags',
                hintText: 'Goa trip, Reimbursable',
                helperText: full
                    ? 'Up to $kMaxTagsPerTx tags'
                    : 'For totals across categories, like a trip',
                counterText: '',
                prefixIcon: const Icon(Icons.sell_outlined),
              ),
              onChanged: (v) {
                if (v.contains(',')) _submit(v);
              },
              onSubmitted: _submit,
            ),
            if (picks.isNotEmpty && !full) ...[
              const SizedBox(height: 6),
              Text(
                typed.isEmpty ? 'Recent' : 'Matching',
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in picks)
                    ActionChip(
                      label: Text('+ $s'),
                      tooltip: 'Add tag $s',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        _add([s]);
                        controller.clear();
                      },
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// [tags] plus whatever is still typed in [controller], as they will be
/// saved.
List<String> pendingTagsOf(
  List<String> tags,
  TextEditingController controller,
) => normalizeTags([...tags, ...controller.text.split(',')]);
