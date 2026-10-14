import 'package:flutter/material.dart';

import '../models/transaction.dart';

/// Chip label with a muted transfer marker so transfer categories are
/// recognisable at a glance in pickers.
///
/// The label is flexible so a long one wraps inside a narrow chip (large
/// text on a small phone), as a plain label does, instead of pushing the
/// marker past the chip's edge.
Widget categoryChipLabel(TxCategory c) => c.isTransfer
    ? Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(c.label)),
          const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(Icons.sync_alt, size: 12),
          ),
        ],
      )
    : Text(c.label);
