import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart' hide TextDirection;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';

/// Export (JSON backup / CSV / PDF report) and import (JSON / CSV) of the
/// stored data. Files are saved via the platform's save dialog (browser
/// download on web).
class BackupService {
  static String _stamp() =>
      DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now());

  /// Saves bytes, letting the user pick the location where the platform
  /// supports it. Returns the chosen path/name, or null if cancelled.
  static Future<String?> _save(
    String name,
    Uint8List bytes,
    String ext,
    MimeType mime,
  ) async {
    if (kIsWeb) {
      await FileSaver.instance.saveFile(
        name: name,
        bytes: bytes,
        fileExtension: ext,
        mimeType: mime,
      );
      return '$name.$ext (browser downloads)';
    }
    final path = await FileSaver.instance.saveAs(
      name: name,
      bytes: bytes,
      fileExtension: ext,
      mimeType: mime,
    );
    return path == null ? null : savedLabel(path, '$name.$ext');
  }

  /// What a toast shows for where [saved] went. From file_saver 0.4 Android
  /// returns a content:// URI rather than a file path. A shared-storage URI
  /// ends in "primary:Download/name.json", so that part is kept; any other
  /// URI falls back to the file name.
  @visibleForTesting
  static String savedLabel(String saved, String fallback) {
    if (!saved.startsWith('content://')) return saved;
    final uri = Uri.tryParse(saved);
    final last = uri == null || uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.last;
    final colon = last.indexOf(':');
    final rest = colon < 0 ? '' : last.substring(colon + 1);
    return rest.contains('/') ? rest : fallback;
  }

  /// The picked file's bytes, or null if the picker was cancelled.
  static Future<Uint8List?> _pick(List<String> extensions) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    return picked == null ? null : await picked.readAsBytes();
  }

  // --- JSON ------------------------------------------------------------------

  /// Pretty-printing + UTF-8 encoding of a full backup is main-isolate work
  /// proportional to the ledger, so it runs under [compute]. Top-level-style
  /// static so [compute] can send it to a worker isolate.
  static Uint8List _encodeBackupBytes(Map<String, dynamic> data) =>
      Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
      );

  static dynamic _decodeBackupBytes(Uint8List bytes) =>
      jsonDecode(utf8.decode(bytes));

  /// Saves a JSON backup. Returns the saved path, or null if cancelled.
  /// [settings] adds the SettingsProvider block (monthly cap, alert flags,
  /// theme…) the finance snapshot alone can't see.
  static Future<String?> exportJson(
    FinanceProvider finance, {
    SettingsProvider? settings,
  }) async {
    final data = finance.exportData();
    if (settings != null) data['settings'] = settings.toBackupMap();
    final bytes = await compute(
      _encodeBackupBytes,
      data,
      debugLabel: 'encodeBackup',
    );
    return _save(
      'expense_tracker_backup_${_stamp()}',
      bytes,
      'json',
      MimeType.json,
    );
  }

  /// Lets the user pick a backup file and imports it.
  /// Returns the number of transactions added, or null if cancelled.
  /// The preference block is applied only on replace: merge means "existing
  /// wins", and silently overwriting the device's cap/theme from a merged
  /// file would contradict that.
  static Future<int?> importJson(
    FinanceProvider finance, {
    required bool replace,
    SettingsProvider? settings,
  }) async {
    final bytes = await _pick(['json']);
    if (bytes == null) return null;
    final data = await compute(
      _decodeBackupBytes,
      bytes,
      debugLabel: 'decodeBackup',
    );
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Not an Expense Tracker backup file');
    }
    final added = await finance.importData(data, replace: replace);
    final block = data['settings'];
    if (replace && settings != null && block is Map<String, dynamic>) {
      await settings.applyBackupMap(block);
    }
    return added;
  }

  // --- CSV -------------------------------------------------------------------

  // No smsBody column: raw SMS text never leaves the app in any export.
  // `category` is the internal id (authoritative on re-import);
  // `categoryName` is the display label for humans/spreadsheets.
  static const _csvHeader = [
    'id',
    'date',
    'type',
    'category',
    'categoryName',
    'amount',
    'myShare',
    'note',
    'sender',
    'ref',
    'pending',
    'suspectedSpam',
    'source',
    'acctKey',
    'balanceAfter',
    'userCategorized',
    // Appended last so older column positions are unchanged.
    'pairId',
    // Joined with " | "; normalizeTags keeps `|` out of any one tag.
    'tags',
    // "Name:amount" per person (":settled" appended when settled, then
    // ":paid" when repayments had paid part of it), joined with " | ";
    // normalizePersonName keeps both separators out of names.
    'people',
    'repaidBy',
  ];

  /// A split's people as one CSV cell:
  /// `Arun:1400.00 | Priya:800.00:settled | Ravi:500.00:settled:200.00`.
  static String _peopleCell(List<SplitShare> people) => [
    for (final p in people)
      [
        p.name,
        p.amount.toStringAsFixed(2),
        if (p.settled) 'settled',
        if (p.settled && p.paid > 0) p.paid.toStringAsFixed(2),
      ].join(':'),
  ].join(' | ');

  /// The reverse of [_peopleCell]. Parts without a name and a number are
  /// skipped; range and duplicate rules are the provider sanitizer's.
  static List<SplitShare> _parsePeopleCell(String v) {
    final out = <SplitShare>[];
    for (final part in v.split('|')) {
      final bits = part.split(':').map((s) => s.trim()).toList();
      if (bits.length < 2 || bits[0].isEmpty) continue;
      final amount = _parseMoneyCell(bits[1]);
      if (amount == null || !amount.isFinite) continue;
      final settled = bits.length > 2 && bits[2].toLowerCase() == 'settled';
      final paid = settled && bits.length > 3 ? _parseMoneyCell(bits[3]) : 0.0;
      out.add(
        SplitShare(
          name: bits[0],
          amount: amount,
          settled: settled,
          paid: paid ?? 0,
        ),
      );
    }
    return out;
  }

  /// Quote-escapes [v]; a leading formula trigger (`= + - @`, per OWASP)
  /// additionally gets a `'` prefix — spreadsheets evaluate such cells even
  /// inside quotes, so a note or an RCS sender name starting with `=` would
  /// otherwise execute on open. `cell()` strips the prefix on re-import so
  /// the app's own round-trip stays lossless.
  static String _csvEscape(String v) {
    final guarded = v.isNotEmpty && '=+-@'.contains(v[0]) ? "'$v" : v;
    return '"${guarded.replaceAll('"', '""')}"';
  }

  /// Parses a money cell. Commas are Indian thousands grouping and are
  /// stripped — but a comma-decimal locale cell ("1234,56": no dot, comma
  /// followed by 1-2 trailing digits) would silently inflate the value
  /// 100×, so it parses as null (ambiguous) instead. Indian grouping
  /// always leaves 3 digits after the last comma, so the app's own exports
  /// never trip this.
  static double? _parseMoneyCell(String v) {
    if (v.isEmpty) return null;
    if (!v.contains('.') && RegExp(r',\d{1,2}$').hasMatch(v)) return null;
    return double.tryParse(v.replaceAll(',', ''));
  }

  /// Display labels for every category id in [all], resolved on the main
  /// isolate — the registries behind [categoryById] (custom categories,
  /// built-in overrides) are per-isolate statics that a [compute] worker
  /// re-initialises to defaults.
  static Map<String, String> _labelsFor(List<Tx> all) => {
    for (final id in all.map((t) => t.categoryId).toSet())
      id: categoryById(id).label,
  };

  /// Every transaction (confirmed + pending), date-desc — the Home menu's
  /// full-history export.
  static List<Tx> _allRows(FinanceProvider finance) =>
      [...finance.transactions, ...finance.pendingTransactions]
        ..sort((a, b) => b.date.compareTo(a.date));

  /// Rows dated inside [range] (whole days, both ends inclusive); all of
  /// them when the range is null.
  @visibleForTesting
  static List<Tx> rowsInRange(List<Tx> rows, DateTimeRange? range) {
    if (range == null) return rows;
    final start = DateTime(
      range.start.year,
      range.start.month,
      range.start.day,
    );
    final end = DateTime(range.end.year, range.end.month, range.end.day + 1);
    return [
      for (final t in rows)
        if (!t.date.isBefore(start) && t.date.isBefore(end)) t,
    ];
  }

  /// Filesystem-safe range suffix for export filenames.
  static String _rangeStamp(DateTimeRange r) {
    final f = DateFormat('yyyyMMdd');
    return '${f.format(r.start)}-${f.format(r.end)}';
  }

  /// Transactions (confirmed + pending) as CSV text.
  static String buildCsv(FinanceProvider finance) =>
      buildCsvOf(_allRows(finance));

  /// [rows] as CSV text, in the caller's order — the filtered-list export
  /// hands over exactly what the Transactions screen is showing.
  static String buildCsvOf(List<Tx> rows) =>
      _csvOfTxs((rows, _labelsFor(rows)));

  /// The string-building half of [buildCsv]: pure over its input, so
  /// [exportCsv] can run it under [compute]. `Tx` holds only sendable fields;
  /// category labels come pre-resolved in the record's map.
  static String _csvOfTxs((List<Tx>, Map<String, String>) args) {
    final (all, labels) = args;
    final rows = <String>[_csvHeader.join(',')];
    for (final t in all) {
      rows.add(
        [
          _csvEscape(t.id),
          _csvEscape(t.date.toIso8601String()),
          _csvEscape(t.type.name),
          _csvEscape(t.categoryId),
          _csvEscape(labels[t.categoryId] ?? t.categoryId),
          t.amount.toStringAsFixed(2),
          t.myShare?.toStringAsFixed(2) ?? '',
          _csvEscape(t.note),
          _csvEscape(t.sender),
          _csvEscape(t.externalRef ?? ''),
          t.pending.toString(),
          t.suspectedSpam.toString(),
          _csvEscape(t.source.name),
          _csvEscape(t.acctKey ?? ''),
          t.balanceAfter?.toStringAsFixed(2) ?? '',
          t.userCategorized.toString(),
          _csvEscape(t.pairId ?? ''),
          _csvEscape(t.tags.join(' | ')),
          _csvEscape(_peopleCell(t.people)),
          _csvEscape(t.repaidBy ?? ''),
        ].join(','),
      );
    }
    return rows.join('\r\n');
  }

  static Uint8List _csvBytesOfTxs((List<Tx>, Map<String, String>) args) =>
      Uint8List.fromList(utf8.encode(_csvOfTxs(args)));

  /// The bytes [exportCsv] writes. Split out so tests can exercise the real
  /// [compute] hop: the record payload has to be isolate-sendable, and the
  /// labels have to be resolved on this side of it.
  @visibleForTesting
  static Future<Uint8List> csvBytes(FinanceProvider finance) =>
      csvBytesOf(_allRows(finance));

  /// Bytes for an explicit row list, in the caller's order.
  @visibleForTesting
  static Future<Uint8List> csvBytesOf(List<Tx> rows) =>
      compute(_csvBytesOfTxs, (rows, _labelsFor(rows)), debugLabel: 'buildCsv');

  /// Saves a CSV of all transactions, optionally only those dated inside
  /// [range]. Returns the path, or null if cancelled.
  static Future<String?> exportCsv(
    FinanceProvider finance, {
    DateTimeRange? range,
  }) => exportCsvRows(rowsInRange(_allRows(finance), range), range: range);

  /// Saves a CSV of exactly [rows] (e.g. the Transactions tab's filtered
  /// list), in the given order. [range] only decorates the filename.
  /// Returns the path, or null if cancelled.
  static Future<String?> exportCsvRows(
    List<Tx> rows, {
    DateTimeRange? range,
  }) async {
    final bytes = await csvBytesOf(rows);
    return _save(
      range == null
          ? 'expense_tracker_transactions_${_stamp()}'
          : 'expense_tracker_transactions_${_rangeStamp(range)}_${_stamp()}',
      bytes,
      'csv',
      MimeType.csv,
    );
  }

  /// RFC-4180-ish CSV parser: handles quoted fields with embedded commas,
  /// quotes, and newlines.
  ///
  /// Works on code units — `text[i]` allocates a one-character String per
  /// step, which on a multi-megabyte import meant millions of throwaway
  /// allocations. Surrogate halves written back-to-back recombine, so
  /// non-BMP characters survive.
  @visibleForTesting
  static List<List<String>> parseCsv(String text) {
    const quote = 0x22, comma = 0x2C, cr = 0x0D, lf = 0x0A;
    final rows = <List<String>>[];
    var field = StringBuffer();
    var row = <String>[];
    var inQuotes = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (inQuotes) {
        if (c == quote) {
          if (i + 1 < text.length && text.codeUnitAt(i + 1) == quote) {
            field.writeCharCode(quote);
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.writeCharCode(c);
        }
      } else if (c == quote) {
        inQuotes = true;
      } else if (c == comma) {
        row.add(field.toString());
        field = StringBuffer();
      } else if (c == lf || c == cr) {
        if (c == cr && i + 1 < text.length && text.codeUnitAt(i + 1) == lf) {
          i++;
        }
        row.add(field.toString());
        field = StringBuffer();
        if (row.any((f) => f.isNotEmpty)) rows.add(row);
        row = <String>[];
      } else {
        field.writeCharCode(c);
      }
    }
    row.add(field.toString());
    if (row.any((f) => f.isNotEmpty)) rows.add(row);
    return rows;
  }

  /// Converts parsed CSV rows into transactions.
  /// Throws [FormatException] when mandatory columns are missing.
  @visibleForTesting
  static List<Tx> txsFromCsv(String text) {
    final rows = parseCsv(text);
    if (rows.isEmpty) throw const FormatException('Empty CSV file');
    final header = rows.first.map((h) => h.trim().toLowerCase()).toList();
    int? col(String name) {
      final i = header.indexOf(name);
      return i == -1 ? null : i;
    }

    final dateCol = col('date');
    final typeCol = col('type');
    final amountCol = col('amount');
    if (dateCol == null || typeCol == null || amountCol == null) {
      throw const FormatException(
        'CSV must have at least date, type, and amount columns',
      );
    }
    final idCol = col('id');
    final categoryCol = col('category');
    // Present only in files written by the current exporter. Its value is
    // deliberately NOT used for mapping — the id column stays authoritative,
    // so a label hand-edited in a spreadsheet can't silently remap rows. It
    // does mark the file as new-format for the note migration below.
    final categoryNameCol = col('categoryname');
    final noteCol = col('note');
    final senderCol = col('sender');
    final refCol = col('ref');
    final pendingCol = col('pending');
    final suspectedSpamCol = col('suspectedspam');
    final sourceCol = col('source');
    final acctKeyCol = col('acctkey');
    final balanceAfterCol = col('balanceafter');
    final smsBodyCol = col('smsbody');
    final myShareCol = col('myshare');
    final userCategorizedCol = col('usercategorized');
    final pairIdCol = col('pairid');
    final tagsCol = col('tags');
    final peopleCol = col('people');
    final repaidByCol = col('repaidby');

    String cell(List<String> r, int? c) {
      final v = c == null || c >= r.length ? '' : r[c].trim();
      // Undo _csvEscape's formula guard, keeping the round-trip lossless.
      return v.length >= 2 && v[0] == "'" && '=+-@'.contains(v[1])
          ? v.substring(1)
          : v;
    }

    // Salted with the import time so fallback ids can never collide across
    // two files (the old `csv_<txDate>_<row>` collided whenever two files
    // shared a date + row index — the second row was silently dropped as
    // "already imported").
    final batchId = DateTime.now().microsecondsSinceEpoch;
    final seenIds = <String>{};
    final txs = <Tx>[];
    for (final (index, r) in rows.skip(1).indexed) {
      final rowNo = index + 2;
      final date = DateTime.tryParse(cell(r, dateCol));
      final type = TxType.values.asNameMap()[cell(r, typeCol).toLowerCase()];
      final amount = _parseMoneyCell(cell(r, amountCol));
      // isFinite: "NaN" parses, passes `<= 0` (false), and then poisons
      // every jsonEncode persist for the rest of the session.
      if (date == null ||
          type == null ||
          amount == null ||
          !amount.isFinite ||
          amount <= 0) {
        throw FormatException('Invalid row $rowNo in CSV');
      }
      final categoryId = cell(r, categoryCol);
      final ref = cell(r, refCol);
      // A duplicate id within one file would make deleteTransaction remove
      // both rows later — the second occurrence gets a generated id.
      var id = cell(r, idCol);
      if (id.isEmpty || seenIds.contains(id)) id = 'csv_${batchId}_$rowNo';
      seenIds.add(id);
      final acctKey = cell(r, acctKeyCol);
      // Same money parsing as amount — this cell used to skip the comma
      // strip, silently dropping any thousands-grouped balance to null.
      final parsedBalance = _parseMoneyCell(cell(r, balanceAfterCol));
      final balanceAfter = parsedBalance != null && parsedBalance.isFinite
          ? parsedBalance
          : null;
      // Sanity cap: real bank alerts are a few hundred chars; an absurd
      // cell would bloat the ledger blob forever.
      var smsBody = cell(r, smsBodyCol);
      if (smsBody.length > 4000) smsBody = smsBody.substring(0, 4000);
      // Group-split share. Range/row-type invariants are enforced by
      // _sanitizeImportedTx on the provider side, like category ids.
      final parsedShare = _parseMoneyCell(cell(r, myShareCol));
      final myShare = parsedShare != null && parsedShare.isFinite
          ? parsedShare
          : null;
      final tx = Tx(
        id: id,
        type: type,
        categoryId: categoryId.isEmpty
            ? (type == TxType.expense ? 'other_expense' : 'other_income')
            : categoryId,
        amount: amount,
        note: cell(r, noteCol),
        smsBody: smsBody,
        date: date,
        sender: cell(r, senderCol),
        externalRef: ref.isEmpty ? null : ref,
        pending: cell(r, pendingCol).toLowerCase() == 'true',
        suspectedSpam: cell(r, suspectedSpamCol).toLowerCase() == 'true',
        userCategorized: cell(r, userCategorizedCol).toLowerCase() == 'true',
        source:
            TxSource.values.asNameMap()[cell(r, sourceCol)] ?? TxSource.manual,
        acctKey: acctKey.isEmpty ? null : acctKey,
        balanceAfter: balanceAfter,
        myShare: myShare,
        pairId: switch (cell(r, pairIdCol)) {
          '' => null,
          final p => p,
        },
        tags: normalizeTags(cell(r, tagsCol).split('|')),
        people: _parsePeopleCell(cell(r, peopleCol)),
        repaidBy: switch (cell(r, repaidByCol)) {
          '' => null,
          final p => p,
        },
      );
      // CSVs written before the smsBody column existed kept the raw SMS in
      // the note, so that note has to be moved. Files with either the
      // smsBody column (the old exporter) or categoryName (the current one,
      // which omits SMS text entirely) are trusted verbatim — without the
      // categoryName check, re-importing a current export would move a
      // user's note on an SMS row into smsBody and blank the note.
      final legacyNoteFormat = smsBodyCol == null && categoryNameCol == null;
      txs.add(legacyNoteFormat ? tx.migrateSmsBodyFromNote() : tx);
    }
    return txs;
  }

  /// Picks a CSV file and imports the transactions in it. With [replace] all
  /// existing transactions are replaced (goals are untouched); otherwise rows
  /// whose ids already exist are skipped. Returns transactions added, or null
  /// if the picker was cancelled.
  static Future<int?> importCsv(
    FinanceProvider finance, {
    required bool replace,
  }) async {
    final bytes = await _pick(['csv']);
    if (bytes == null) return null;
    // Parse off the main isolate: txsFromCsv is pure string → Tx work (the
    // category registry is not consulted — ids are carried verbatim).
    final txs = await compute(
      txsFromCsv,
      utf8.decode(bytes),
      debugLabel: 'parseCsv',
    );
    return finance.importTransactions(txs, replace: replace);
  }

  // --- PDF -------------------------------------------------------------------

  static final _money = NumberFormat.currency(symbol: '₹', decimalDigits: 2);
  static final _date = DateFormat('dd-MM-yy');

  static const PdfColor _green = PdfColor.fromInt(0xFF2E7D6B);
  static const PdfColor _greenLight = PdfColor.fromInt(0xFFE4F2EE);
  static const PdfColor _zebra = PdfColor.fromInt(0xFFF4F6F5);
  static const PdfColor _red = PdfColor.fromInt(0xFFC62828);
  static const PdfColor _greenText = PdfColor.fromInt(0xFF1B5E20);

  /// Saves a PDF statement — the whole ledger, one [year] of it, or the
  /// rows inside [range]. Returns the saved path, or null if cancelled.
  static Future<String?> exportPdf(
    FinanceProvider finance, {
    int? year,
    DateTimeRange? range,
  }) async {
    final bytes = await buildPdf(finance, year: year, range: range);
    return _save(
      year != null
          ? 'expense_tracker_report_${year}_${_stamp()}'
          : range != null
          ? 'expense_tracker_report_${_rangeStamp(range)}_${_stamp()}'
          : 'expense_tracker_report_${_stamp()}',
      bytes,
      'pdf',
      MimeType.pdf,
    );
  }

  static pw.Widget _summaryBox(String label, double value, PdfColor color) =>
      pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.symmetric(horizontal: 3),
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: _greenLight,
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                label,
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey700,
                ),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                _money.format(value),
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );

  /// One roll-up line under the PDF accounts table (label left, figure
  /// right) — the print counterpart of the in-app balance breakdown rows.
  static pw.Widget _netLine(String label, String value, {bool bold = false}) {
    final style = pw.TextStyle(
      fontSize: 8.5,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    );
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: style),
          pw.Text(value, style: style),
        ],
      ),
    );
  }

  /// Builds the report bytes. Exposed separately so tests can render it
  /// without touching the platform save dialog. [year] and [range] are
  /// alternatives; when both are given the range wins.
  static Future<Uint8List> buildPdf(
    FinanceProvider finance, {
    int? year,
    DateTimeRange? range,
  }) async {
    if (range != null) year = null;
    final baseFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
    );
    final boldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
    );

    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: baseFont, bold: boldFont),
    );
    final txs = year != null
        ? [
            for (final t in finance.transactions)
              if (t.date.year == year) t,
          ]
        : rowsInRange(finance.transactions, range);
    // Summary figures follow the same population as the table: whole-ledger
    // provider totals, the year's own sums, or (for a range) sums folded
    // from the filtered rows with the provider's rules — transfers excluded,
    // splits counting only the user's own share.
    final double sumIncome;
    final double sumExpense;
    final double sumSavings;
    if (range != null) {
      sumIncome = txs
          .where(
            (t) => t.type == TxType.income && !isTransferCategory(t.categoryId),
          )
          .fold(0.0, (s, t) => s + t.amount);
      sumExpense = txs
          .where(
            (t) =>
                t.type == TxType.expense && !isTransferCategory(t.categoryId),
          )
          .fold(0.0, (s, t) => s + t.spendAmount);
      sumSavings = txs
          .where(
            (t) =>
                t.type == TxType.expense &&
                t.categoryId == kSavingsTransferCategoryId,
          )
          .fold(0.0, (s, t) => s + t.amount);
    } else if (year != null) {
      sumIncome = finance.incomeInYear(year);
      sumExpense = finance.expenseInYear(year);
      sumSavings = finance.savingsOutflowInYear(year);
    } else {
      sumIncome = finance.totalIncome;
      sumExpense = finance.totalExpense;
      sumSavings = finance.totalSavingsTransfers;
    }

    // Group transactions by month, newest first.
    final byMonth = <DateTime, List<Tx>>{};
    for (final t in txs) {
      byMonth.putIfAbsent(DateTime(t.date.year, t.date.month), () => []).add(t);
    }
    final months = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final list in byMonth.values) {
      list.sort((a, b) => b.date.compareTo(a.date));
    }

    // Overall expense breakdown by category. Transfers are excluded so the
    // shares use the same population as the TOTAL EXPENSES box (provider
    // totals) — including them let category shares exceed 100%.
    final catTotals = <String, double>{};
    for (final t in txs.where(
      (t) => t.type == TxType.expense && !isTransferCategory(t.categoryId),
    )) {
      // Group splits contribute only the user's own share, like the totals.
      catTotals[t.categoryId] = (catTotals[t.categoryId] ?? 0) + t.spendAmount;
    }
    final catEntries = catTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final totalExpense = sumExpense;

    String clip(String s, [int max = 160]) {
      final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 36),
        footer: (ctx) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Expense Tracker',
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey),
              ),
              pw.Text(
                'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey),
              ),
            ],
          ),
        ),
        build: (ctx) => [
          // Header band
          pw.Container(
            padding: const pw.EdgeInsets.all(14),
            decoration: pw.BoxDecoration(
              color: _green,
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      year == null
                          ? 'Expense Tracker — Statement'
                          : 'Expense Tracker — Report $year',
                      style: pw.TextStyle(
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.white,
                      ),
                    ),
                    if (range != null)
                      pw.Text(
                        'Period: '
                        '${DateFormat('dd MMM yyyy').format(range.start)}'
                        ' – ${DateFormat('dd MMM yyyy').format(range.end)}',
                        style: const pw.TextStyle(
                          fontSize: 9,
                          color: PdfColors.grey200,
                        ),
                      ),
                  ],
                ),
                pw.Text(
                  DateFormat('dd MMM yyyy, HH:mm').format(DateTime.now()),
                  style: const pw.TextStyle(
                    fontSize: 9,
                    color: PdfColors.grey200,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 10),
          pw.Row(
            children: [
              _summaryBox('TOTAL INCOME', sumIncome, _greenText),
              _summaryBox('TOTAL EXPENSES', sumExpense, _red),
              _summaryBox('TO SAVINGS', sumSavings, _green),
              // Balance is a running figure; a bounded slice (year or
              // range) has a net instead.
              if (year == null && range == null)
                _summaryBox('AVAILABLE BALANCE', finance.balance, _green)
              else
                _summaryBox(
                  year == null ? 'NET FOR PERIOD' : 'NET FOR $year',
                  sumIncome - sumExpense - sumSavings,
                  _green,
                ),
            ],
          ),
          if (finance.openAccounts.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text(
              'Accounts',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              'Live balances at export time — not scoped to the report '
              'period.',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              columnWidths: {
                0: const pw.FlexColumnWidth(),
                1: const pw.FixedColumnWidth(75),
                2: const pw.FixedColumnWidth(130),
                3: const pw.FixedColumnWidth(95),
              },
              headers: ['Account', 'Type', 'Numbers', 'Balance'],
              headerStyle: pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(color: _greenLight),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              cellAlignments: {3: pw.Alignment.centerRight},
              oddRowDecoration: const pw.BoxDecoration(color: _zebra),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 3,
              ),
              data: [
                for (final a in finance.openAccounts)
                  [
                    a.name,
                    a.typeLabel,
                    a.keys.isEmpty
                        ? '—'
                        : [
                            for (final k in a.keys) k.replaceFirst(':', ' ••'),
                          ].join(', '),
                    a.isCard
                        ? switch (finance.accountOutstanding(a)) {
                            null => 'owed —',
                            final o => '${_money.format(o)} owed',
                          }
                        : _money.format(finance.accountBalance(a)),
                  ],
              ],
            ),
            pw.SizedBox(height: 6),
            // The same roll-up the in-app balance breakdown shows.
            _netLine('Bank balances', _money.format(finance.bankBalanceTotal)),
            _netLine(
              'Credit card outstanding',
              '− ${_money.format(finance.cardOutstandingTotal)}',
            ),
            if (finance.cardsMissingLimit > 0)
              pw.Text(
                '${finance.cardsMissingLimit} card(s) with unknown '
                'outstanding are not counted.',
                style: const pw.TextStyle(
                  fontSize: 7.5,
                  color: PdfColors.grey700,
                ),
              ),
            _netLine(
              'Net balance (liquid)',
              _money.format(finance.netWorth),
              bold: true,
            ),
            if (finance.savingsBalanceTotal > 0)
              _netLine(
                'In savings & assets (not liquid)',
                _money.format(finance.savingsBalanceTotal),
              ),
          ],
          if (catEntries.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text(
              'Spending by category',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              columnWidths: {
                0: const pw.FlexColumnWidth(),
                1: const pw.FixedColumnWidth(90),
                2: const pw.FixedColumnWidth(50),
              },
              headers: ['Category', 'Amount', 'Share'],
              headerStyle: pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(color: _greenLight),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              cellAlignments: {
                1: pw.Alignment.centerRight,
                2: pw.Alignment.centerRight,
              },
              oddRowDecoration: const pw.BoxDecoration(color: _zebra),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 3,
              ),
              data: [
                for (final e in catEntries)
                  [
                    categoryById(e.key).label,
                    _money.format(e.value),
                    // A zero-share split can leave entries with totalExpense
                    // 0.0 — 0/0 printed "NaN%".
                    totalExpense <= 0
                        ? '—'
                        : '${(e.value / totalExpense * 100).toStringAsFixed(1)}%',
                  ],
              ],
            ),
          ],
          pw.SizedBox(height: 16),
          pw.Text(
            'Transactions (${txs.length})',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          if (txs.isEmpty) pw.Text('No transactions recorded.'),
          for (final month in months) ...[
            pw.SizedBox(height: 10),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              decoration: pw.BoxDecoration(
                color: _greenLight,
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    DateFormat('MMMM yyyy').format(month),
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: _green,
                    ),
                  ),
                  pw.Text(
                    // Transfers excluded — these mirror the app's own month
                    // header figures; transfer rows stay in the table below.
                    'in ${_money.format(byMonth[month]!.where((t) => t.type == TxType.income && !isTransferCategory(t.categoryId)).fold(0.0, (s, t) => s + t.amount))}'
                    '   out ${_money.format(byMonth[month]!.where((t) => t.type == TxType.expense && !isTransferCategory(t.categoryId)).fold(0.0, (s, t) => s + t.spendAmount))}',
                    style: const pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.grey700,
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 4),
            pw.TableHelper.fromTextArray(
              columnWidths: {
                0: const pw.FixedColumnWidth(48),
                1: const pw.FixedColumnWidth(68),
                2: const pw.FlexColumnWidth(),
                3: const pw.FixedColumnWidth(72),
              },
              headers: ['Date', 'Category', 'Note', 'Amount'],
              headerStyle: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey300,
              ),
              cellStyle: const pw.TextStyle(fontSize: 7.5),
              cellAlignments: {3: pw.Alignment.centerRight},
              oddRowDecoration: const pw.BoxDecoration(color: _zebra),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 2.5,
              ),
              data: [
                for (final t in byMonth[month]!)
                  [
                    _date.format(t.date),
                    // Split rows: the Amount column shows the full debit
                    // while every total on the page counts only the share —
                    // without the annotation the statement doesn't add up
                    // from the artifact alone.
                    t.isSplit
                        ? '${t.category.label} '
                              '(split — own share ${_money.format(t.spendAmount)})'
                        : t.category.label,
                    // The user's own words only — no fallback. Blank stays
                    // blank; the raw SMS body never leaves the app.
                    clip(t.note),
                    '${t.type == TxType.income ? '+' : '-'}${_money.format(t.amount)}',
                  ],
              ],
            ),
          ],
        ],
      ),
    );
    return doc.save();
  }
}
