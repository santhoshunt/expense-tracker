import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/dashboard_layout.dart';
import 'package:expense_tracker/providers/settings_provider.dart';

/// The dashboard's section order, hidden sections and folds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('DashboardPageLayout', () {
    test('defaults list the page sections in order, none hidden', () {
      final l = DashboardPageLayout.defaults(DashboardPage.trends);
      expect(l.order, [
        DashboardSection.pace,
        DashboardSection.previousMonth,
        DashboardSection.usual,
        DashboardSection.categoryComparison,
        DashboardSection.sixMonths,
      ]);
      expect(l.hidden, isEmpty);
    });

    test('round-trips through JSON', () {
      final l = DashboardPageLayout(
        page: DashboardPage.breakdown,
        order: DashboardSection.of(DashboardPage.breakdown).reversed.toList(),
        hidden: {DashboardSection.transfers},
      );
      final back = DashboardPageLayout.fromJson(
        DashboardPage.breakdown,
        jsonDecode(jsonEncode(l.toJson())),
      );
      expect(back.order, l.order);
      expect(back.hidden, l.hidden);
    });

    test('drops unknown, foreign and repeated names', () {
      final l = DashboardPageLayout.fromJson(DashboardPage.overview, {
        'order': ['owed', 'nope', 'owed', 'heatmap', 'upcoming'],
        'hidden': ['heatmap', 'budgets', 'x'],
      });
      // The stored pair keeps its order; the missing ones return around it.
      expect(
        l.order.indexOf(DashboardSection.owed) <
            l.order.indexOf(DashboardSection.upcoming),
        isTrue,
      );
      expect(l.order.where((s) => s == DashboardSection.owed), hasLength(1));
      expect(l.order.contains(DashboardSection.heatmap), isFalse);
      expect(l.hidden, {DashboardSection.budgets});
      expect(
        l.order.toSet(),
        DashboardSection.of(DashboardPage.overview).toSet(),
      );
    });

    test('a 1.30 Overview order gains the forecast after the budget', () {
      final l = DashboardPageLayout.fromJson(DashboardPage.overview, {
        'order': ['upcoming', 'monthlyBudget', 'recap', 'budgets', 'owed'],
      });
      expect(l.order, [
        DashboardSection.upcoming,
        DashboardSection.monthlyBudget,
        DashboardSection.forecast,
        DashboardSection.recap,
        DashboardSection.budgets,
        DashboardSection.owed,
      ]);
    });

    test('a section missing from a stored order returns at its place', () {
      // As if a later release added "usual" between these two.
      final l = DashboardPageLayout.fromJson(DashboardPage.trends, {
        'order': ['sixMonths', 'pace', 'previousMonth', 'categoryComparison'],
      });
      expect(l.order, [
        DashboardSection.sixMonths,
        DashboardSection.pace,
        DashboardSection.previousMonth,
        DashboardSection.usual,
        DashboardSection.categoryComparison,
      ]);
    });

    test('wrongly-typed lists read as empty', () {
      final l = DashboardPageLayout.fromJson(DashboardPage.overview, {
        'order': 'owed',
        'hidden': {'owed': true},
      });
      expect(l.order, DashboardSection.of(DashboardPage.overview));
      expect(l.hidden, isEmpty);
    });

    test('damaged JSON gives the defaults', () {
      expect(
        DashboardPageLayout.fromJson(DashboardPage.overview, 'x').order,
        DashboardSection.of(DashboardPage.overview),
      );
    });
  });

  group('SettingsProvider', () {
    Future<SettingsProvider> fresh() async {
      final s = SettingsProvider();
      await s.load();
      return s;
    }

    test('order, hidden and folds persist across a reload', () async {
      final s = await fresh();
      expect(s.sectionOpen(DashboardSection.donut), isTrue);
      expect(s.sectionOpen(DashboardSection.heatmap), isFalse);
      await s.setDashboardOrder(DashboardPage.breakdown, [
        DashboardSection.heatmap,
        ...DashboardSection.of(
          DashboardPage.breakdown,
        ).where((x) => x != DashboardSection.heatmap),
      ]);
      await s.setSectionHidden(DashboardSection.transfers, true);
      await s.setSectionOpen(DashboardSection.heatmap, true);
      final again = await fresh();
      final l = again.dashboardLayout(DashboardPage.breakdown);
      expect(l.order.first, DashboardSection.heatmap);
      expect(l.hidden, {DashboardSection.transfers});
      expect(again.sectionOpen(DashboardSection.heatmap), isTrue);
      expect(again.hiddenSectionCount, 1);
    });

    test('a corrupt stored layout loads as the defaults', () async {
      SharedPreferences.setMockInitialValues({'dashboard_layout_v1': '{bad'});
      final s = await fresh();
      expect(
        s.dashboardLayout(DashboardPage.breakdown).order,
        DashboardSection.of(DashboardPage.breakdown),
      );
      expect(s.sectionOpen(DashboardSection.donut), isTrue);
    });

    test('reset puts back one page only', () async {
      final s = await fresh();
      await s.setSectionHidden(DashboardSection.transfers, true);
      await s.setSectionHidden(DashboardSection.owed, true);
      await s.setSectionOpen(DashboardSection.heatmap, true);
      await s.resetDashboardLayout(DashboardPage.breakdown);
      expect(s.dashboardLayout(DashboardPage.breakdown).hidden, isEmpty);
      expect(s.sectionOpen(DashboardSection.heatmap), isFalse);
      expect(s.dashboardLayout(DashboardPage.overview).hidden, {
        DashboardSection.owed,
      });
    });

    test(
      'a malformed layout block reads as the defaults, the rest restores',
      () async {
        final s = await fresh();
        await s.setSectionHidden(DashboardSection.owed, true);
        await s.applyBackupMap({
          'monthlyBudget': 1234,
          'dashboardLayout': {
            'pages': {
              'overview': {'order': 7, 'hidden': 'owed'},
            },
            'open': 'x',
          },
        });
        // The rest of the block landed; the overview layout reads as default.
        expect(s.monthlyBudget, 1234);
        expect(s.dashboardLayout(DashboardPage.overview).hidden, isEmpty);
      },
    );

    test('the backup block carries the layout', () async {
      final s = await fresh();
      await s.setSectionHidden(DashboardSection.byTags, true);
      await s.setSectionOpen(DashboardSection.usual, true);
      final map = jsonDecode(jsonEncode(s.toBackupMap()));
      SharedPreferences.setMockInitialValues({});
      final other = await fresh();
      await other.applyBackupMap(map as Map<String, dynamic>);
      expect(other.dashboardLayout(DashboardPage.breakdown).hidden, {
        DashboardSection.byTags,
      });
      expect(other.sectionOpen(DashboardSection.usual), isTrue);
      // And it survives the restore's own reload.
      final reloaded = await fresh();
      expect(reloaded.dashboardLayout(DashboardPage.breakdown).hidden, {
        DashboardSection.byTags,
      });
    });
  });
}
