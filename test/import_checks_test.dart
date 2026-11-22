import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The store below extends the plugin's in-memory store, which only the
// platform interface exports. shared_preferences brings it in.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/import_checks.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/notification_ids.dart';
import 'package:expense_tracker/services/notification_service.dart';

/// The shade, faked: a posted note stays active until cancelled.
class _Shade implements NotificationService {
  final posted = <({int id, String title, String body, String? keepLabel})>[];
  final active = <int>[];
  final cancelled = <int>[];
  int? summary;

  @override
  Future<void> init() async {}

  @override
  Future<bool> get areEnabled async => true;

  @override
  Future<NotificationStatus> get status async => NotificationStatus.enabled;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {}

  @override
  Future<String?> launchPayload() async => null;

  @override
  Future<void> scheduleRecap(DateTime when, String monthName) async {}

  @override
  Future<void> cancelRecap() async {}

  @override
  Future<void> scheduleWeeklyDigest(
    DateTime when,
    DateTime week,
    String weekLabel,
  ) async {}

  @override
  Future<void> cancelWeeklyDigest() async {}

  @override
  Future<void> showReview(int count) async {}

  @override
  Future<void> cancelReview() async {}

  @override
  Future<void> showImportCheck({
    required int id,
    required String title,
    required String body,
    required String payload,
    String? keepLabel,
  }) async {
    posted.add((id: id, title: title, body: body, keepLabel: keepLabel));
    if (!active.contains(id)) active.add(id);
  }

  @override
  Future<void> showImportCheckSummary(int count) async => summary = count;

  @override
  Future<List<int>> activeImportChecks() async => List.of(active);

  @override
  Future<void> cancelId(int id) async {
    cancelled.add(id);
    active.remove(id);
    if (id == NotificationIds.importCheckSummary) summary = null;
  }
}

/// The in-memory store, except that writes to [failKey] report false, as
/// Android's commit() does when it cannot write.
class _OneKeyFailingStore extends InMemorySharedPreferencesStore {
  _OneKeyFailingStore(super.data) : super.withData();

  String? failKey;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      key == failKey ? false : super.setValue(valueType, key, value);
}

/// Payment-to-check notes: which rows need one, posting, Keep taps queued
/// while the app is closed, and notes whose row was settled. Every name and
/// number is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FinanceProvider.useIsolateCodec = false;
  });

  // One clock read; rows are dated at noon on earlier days.
  final now = DateTime.now();
  DateTime daysAgo(int n) => DateTime(now.year, now.month, now.day - n, 12);

  Tx row(
    String id, {
    String category = 'food',
    bool guessed = true,
    bool unseen = true,
    bool pending = false,
    int ago = 1,
  }) => Tx(
    id: id,
    type: TxType.expense,
    categoryId: category,
    amount: 240,
    note: 'Pebble Bakery',
    date: daysAgo(ago),
    source: TxSource.sms,
    sender: 'VM-PBLBNK',
    categoryGuessed: guessed,
    unseen: unseen,
    pending: pending,
  );

  Future<FinanceProvider> ledger(List<Tx> rows) async {
    final p = FinanceProvider();
    await p.load();
    await p.importTransactions(rows, replace: true);
    return p;
  }

  Tx byId(FinanceProvider p, String id) =>
      p.transactions.singleWhere((t) => t.id == id);

  Future<List<String>> keptQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getStringList(kImportChecksKeptKey) ?? const [];
  }

  group('which rows need a check', () {
    test('a guessed or To sort row the user has not opened', () async {
      final p = await ledger([
        row('guess'),
        row('sort', category: 'to_sort_expense', guessed: false),
        row('seen', unseen: false),
        row('placed', guessed: false),
        row('waiting', pending: true),
      ]);
      expect(ImportChecks.checkIds(p), {'guess', 'sort'});
    });
  });

  group('the payload', () {
    test('round trips ids that hold separators', () {
      const id = 'sms:1:"x"|2';
      final parsed = parseImportCheckPayload(importCheckPayload(id, 'food'));
      expect(parsed?.txId, id);
      expect(parsed?.categoryId, 'food');
    });

    test('rejects a malformed payload', () {
      for (final bad in [
        '',
        'food',
        '{"tx":"a","cat":"food"}',
        'check:',
        'check:{broken',
        'check:["a","food"]',
        'check:{"tx":"","cat":"food"}',
        'check:{"tx":"a","cat":""}',
        'check:{"tx":7,"cat":"food"}',
      ]) {
        expect(parseImportCheckPayload(bad), isNull, reason: bad);
      }
    });

    test('Keep queues nothing for a malformed or missing payload', () async {
      await ImportChecks.keep(null);
      await ImportChecks.keep('check:{broken');
      expect(await keptQueue(), isEmpty);
    });
  });

  group('posting', () {
    test('one note per new row, newest first, under a summary', () async {
      final p = await ledger([
        row('old', ago: 3),
        row('new', ago: 1),
        row('sort', category: 'to_sort_expense', guessed: false, ago: 2),
        row('before', ago: 4),
      ]);
      final shade = _Shade();
      await ImportChecks.post(p, {'before'}, notifications: shade);
      expect(shade.posted.map((n) => n.id), [
        NotificationIds.importCheck('new'),
        NotificationIds.importCheck('sort'),
        NotificationIds.importCheck('old'),
      ]);
      final food = categoryById('food').label;
      expect(shade.posted.first.body, 'Guessed $food. Already counted.');
      expect(shade.posted.first.keepLabel, 'Keep $food');
      expect(shade.posted[1].body, 'To sort. Already counted.');
      expect(shade.posted[1].keepLabel, isNull);
      expect(shade.summary, 3);
    });

    test('posts at most five notes', () async {
      final p = await ledger([
        for (var i = 0; i < 7; i++) row('r$i', ago: i + 1),
      ]);
      final shade = _Shade();
      await ImportChecks.post(p, const {}, notifications: shade);
      expect(shade.posted, hasLength(kMaxImportCheckNotes));
      expect(
        shade.posted.first.id,
        NotificationIds.importCheck('r0'),
        reason: 'newest first',
      );
    });

    test('a single note has no summary', () async {
      final p = await ledger([row('only')]);
      final shade = _Shade()..summary = 4;
      await ImportChecks.post(p, const {}, notifications: shade);
      expect(shade.posted, hasLength(1));
      expect(shade.summary, isNull);
    });

    test('posts nothing while a collection failed to load', () async {
      SharedPreferences.setMockInitialValues({'saved_filters_v1': '{broken'});
      final p = await ledger([row('guess')]);
      expect(p.loadWarnings, isNotEmpty);
      final shade = _Shade();
      await ImportChecks.post(p, const {}, notifications: shade);
      expect(shade.posted, isEmpty);
    });
  });

  group('a Keep tapped while the app is closed', () {
    test('is applied once when the app opens', () async {
      final p = await ledger([row('guess'), row('other')]);
      await ImportChecks.keep(importCheckPayload('guess', 'food'));
      expect(await keptQueue(), hasLength(1));
      expect(byId(p, 'guess').categoryGuessed, isTrue, reason: 'not yet');

      await ImportChecks.applyKept(p);
      final kept = byId(p, 'guess');
      expect(kept.categoryGuessed, isFalse);
      expect(kept.userCategorized, isTrue);
      expect(kept.unseen, isFalse);
      expect(byId(p, 'other').categoryGuessed, isTrue);
      expect(await keptQueue(), isEmpty);

      // A second open finds nothing queued and leaves the ledger alone.
      final rev = p.revision;
      await ImportChecks.applyKept(p);
      expect(identical(p.revision, rev), isTrue);
    });

    test('from the widget queue too, and a malformed one is ignored', () async {
      SharedPreferences.setMockInitialValues({
        kImportChecksWidgetKeptKey: jsonEncode([
          importCheckPayload('guess', 'food'),
          'not a payload',
        ]),
      });
      final p = await ledger([row('guess')]);
      await ImportChecks.applyKept(p);
      expect(byId(p, 'guess').categoryGuessed, isFalse);
      // Everything read is drained: an entry that can never apply goes too.
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(kImportChecksWidgetKeptKey)!), []);

      SharedPreferences.setMockInitialValues({
        kImportChecksWidgetKeptKey: '{broken',
      });
      final q = await ledger([row('guess')]);
      await ImportChecks.applyKept(q);
      expect(byId(q, 'guess').categoryGuessed, isTrue);
    });

    test('does not confirm a row whose category changed since', () async {
      final p = await ledger([row('guess', category: 'shopping')]);
      await ImportChecks.keep(importCheckPayload('guess', 'food'));
      await ImportChecks.applyKept(p);
      expect(byId(p, 'guess').categoryGuessed, isTrue);
      expect(byId(p, 'guess').categoryId, 'shopping');
      expect(await keptQueue(), isEmpty);
    });

    test('waits while a collection failed to load', () async {
      SharedPreferences.setMockInitialValues({'saved_filters_v1': '{broken'});
      final p = await ledger([row('guess')]);
      await ImportChecks.keep(importCheckPayload('guess', 'food'));
      await ImportChecks.applyKept(p);
      expect(byId(p, 'guess').categoryGuessed, isTrue);
      expect(await keptQueue(), hasLength(1));
    });

    test('stays queued when the ledger write fails, and is applied once on '
        'the next open', () async {
      SharedPreferences.setMockInitialValues({
        kImportChecksWidgetKeptKey: jsonEncode([
          importCheckPayload('other', 'food'),
        ]),
      });
      final p = await ledger([row('guess'), row('other')]);
      await ImportChecks.keep(importCheckPayload('guess', 'food'));
      final prefs = await SharedPreferences.getInstance();
      final store = _OneKeyFailingStore({
        for (final k in prefs.getKeys()) 'flutter.$k': prefs.get(k)!,
      })..failKey = 'flutter.transactions_v1';
      SharedPreferencesStorePlatform.instance = store;
      await ImportChecks.applyKept(p);
      expect(p.persistFailed, isTrue);
      expect(await keptQueue(), hasLength(1));
      expect(
        jsonDecode(prefs.getString(kImportChecksWidgetKeptKey)!),
        hasLength(1),
      );

      // The app closes before any write lands; storage works on the next
      // open, which reads the ledger as it was saved: still guessed.
      store.failKey = null;
      await prefs.reload();
      final next = FinanceProvider();
      await next.load();
      expect(byId(next, 'guess').categoryGuessed, isTrue);
      await ImportChecks.applyKept(next);
      expect(next.persistFailed, isFalse);
      expect(byId(next, 'guess').categoryGuessed, isFalse);
      expect(byId(next, 'other').categoryGuessed, isFalse);
      expect(await keptQueue(), isEmpty);
      expect(jsonDecode(prefs.getString(kImportChecksWidgetKeptKey)!), []);

      // Saved, and a later open finds nothing left to apply.
      await prefs.reload();
      final later = FinanceProvider();
      await later.load();
      expect(byId(later, 'guess').categoryGuessed, isFalse);
      final rev = later.revision;
      await ImportChecks.applyKept(later);
      expect(identical(later.revision, rev), isTrue);
    });

    test('a Keep applied again changes nothing', () async {
      final p = await ledger([row('guess')]);
      final payload = (txId: 'guess', categoryId: 'food');
      await p.confirmGuesses([payload]);
      final confirmed = byId(p, 'guess');
      final rev = p.revision;
      await p.confirmGuesses([payload]);
      expect(identical(p.revision, rev), isTrue);
      expect(identical(byId(p, 'guess'), confirmed), isTrue);
    });
  });

  group('a note whose row was settled', () {
    test('is cancelled; the others stay', () async {
      final p = await ledger([row('a'), row('b'), row('c')]);
      final shade = _Shade();
      await ImportChecks.post(p, const {}, notifications: shade);
      expect(shade.summary, 3);

      await p.confirmGuesses([(txId: 'a', categoryId: 'food')]);
      await ImportChecks.sync(p, enabled: true, notifications: shade);
      expect(shade.cancelled, contains(NotificationIds.importCheck('a')));
      expect(
        shade.active,
        unorderedEquals([
          NotificationIds.importCheck('b'),
          NotificationIds.importCheck('c'),
        ]),
      );
      expect(shade.summary, 2);

      await p.confirmGuesses([(txId: 'b', categoryId: 'food')]);
      await ImportChecks.sync(p, enabled: true, notifications: shade);
      expect(shade.active, [NotificationIds.importCheck('c')]);
      expect(shade.summary, isNull, reason: 'one note needs no summary');
    });

    test('every note goes when the setting is off', () async {
      final p = await ledger([row('a'), row('b')]);
      final shade = _Shade();
      await ImportChecks.post(p, const {}, notifications: shade);
      await ImportChecks.sync(p, enabled: false, notifications: shade);
      expect(shade.active, isEmpty);
      expect(shade.summary, isNull);
    });
  });
}
