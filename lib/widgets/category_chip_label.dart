import 'package:flutter/material.dart';

import '../models/transaction.dart';

/// Chip label with a muted transfer marker so transfer categories are
/// recognisable at a glance in pickers.
///
/// One line, cut with an ellipsis when the chip is narrower than its label
/// (large text on a small phone): a chip shows only a label's first line,
/// so a wrapped one was cut with no sign ("Food &"). The label is flexible
/// so the marker stays inside the chip.
Widget categoryChipLabel(TxCategory c) {
  final label = Text(c.label, maxLines: 1, overflow: TextOverflow.ellipsis);
  return c.isTransfer
      ? Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: label),
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.sync_alt, size: 12),
            ),
          ],
        )
      : label;
}
