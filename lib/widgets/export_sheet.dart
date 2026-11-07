import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../utils/fiscal_year.dart';
import '../utils/format.dart';
import 'editor_sheet.dart';

/// The one Export sheet, for Settings' Export (a backup, a CSV or a PDF
/// report, with dates for the last two) and the Accounts statement (PDF
/// only). Pops the format, one of Settings' backup action keys
/// ('export_json', 'export_csv', 'export_pdf'), and the dates; a null
/// range means every transaction. Null when dismissed.
Future<({String format, DateTimeRange? range})?> showExportSheet(
  BuildContext context, {
  bool pdfOnly = false,
}) {
  // The year chip follows the dashboard's year start.
  final startMonth = context.read<SettingsProvider?>()?.yearStart.month ?? 1;
  return showEditorSheet<({String format, DateTimeRange? range})>(
    context,
    builder: (_) => _ExportSheet(pdfOnly: pdfOnly, startMonth: startMonth),
  );
}

enum _Dates { all, thisMonth, lastMonth, year, custom }

class _ExportSheet extends StatefulWidget {
  final bool pdfOnly;
  final int startMonth;

  const _ExportSheet({required this.pdfOnly, required this.startMonth});

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  late var _format = widget.pdfOnly ? 'export_pdf' : 'export_json';
  var _dates = _Dates.all;
  DateTimeRange? _custom;

  static DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// The days [d] covers, ending today at the latest; null for all.
  DateTimeRange? _rangeOf(_Dates d) {
    final today = _today;
    final sm = widget.startMonth;
    return switch (d) {
      _Dates.all => null,
      _Dates.thisMonth => DateTimeRange(
        start: DateTime(today.year, today.month),
        end: today,
      ),
      _Dates.lastMonth => DateTimeRange(
        start: DateTime(today.year, today.month - 1),
        end: DateTime(today.year, today.month, 0),
      ),
      _Dates.year => DateTimeRange(
        start: yearBounds(yearStartOf(today, sm), sm).first,
        end: today,
      ),
      _Dates.custom => _custom,
    };
  }

  Future<void> _pickCustom() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: _today,
      initialDateRange: _custom,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _custom = picked;
      _dates = _Dates.custom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final today = _today;
    final sm = widget.startMonth;
    // A backup always holds everything.
    final dated = _format != 'export_json';
    final custom = _custom;
    return EditorSheetBody(
      title: widget.pdfOnly ? 'Export which dates?' : 'Export',
      footerLabel: 'Export',
      onSave: () => Navigator.pop(context, (
        format: _format,
        range: dated ? _rangeOf(_dates) : null,
      )),
      children: [
        if (!widget.pdfOnly) ...[
          Text('Format', style: text.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            key: const ValueKey('export-format'),
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (value, label) in const [
                ('export_json', 'Backup (JSON)'),
                ('export_csv', 'Transactions (CSV)'),
                ('export_pdf', 'Report (PDF)'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _format == value,
                  onSelected: (_) => setState(() => _format = value),
                ),
            ],
          ),
        ],
        if (dated) ...[
          if (!widget.pdfOnly) ...[
            const SizedBox(height: 16),
            Text('Dates', style: text.titleSmall),
            const SizedBox(height: 8),
          ],
          Wrap(
            key: const ValueKey('export-dates'),
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (d, label) in [
                (_Dates.all, 'All transactions'),
                (_Dates.thisMonth, 'This month'),
                (_Dates.lastMonth, 'Last month'),
                (_Dates.year, yearLabel(yearStartOf(today, sm), sm)),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _dates == d,
                  onSelected: (_) => setState(() => _dates = d),
                ),
              // Opens the range picker at once, then names what it picked.
              ChoiceChip(
                label: Text(
                  custom == null ? 'Custom…' : fmtDayRange(custom, today),
                ),
                selected: _dates == _Dates.custom,
                onSelected: (_) => _pickCustom(),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
