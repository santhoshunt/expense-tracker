import 'package:flutter/material.dart';

import '../models/transaction.dart';

/// Chip label with a muted transfer marker so transfer categories are
/// recognisable at a glance in pickers.
Widget categoryChipLabel(TxCategory c) => c.isTransfer
    ? Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(c.label),
          const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(Icons.sync_alt, size: 12),
          ),
        ],
      )
    : Text(c.label);
