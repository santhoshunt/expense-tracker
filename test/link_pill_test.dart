import 'package:expense_tracker/widgets/link_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('linkPillLabel', () {
    test('keeps the host and the last path segment', () {
      expect(
        linkPillLabel('https://github.com/example/app/compare/v1.0.0...v1.0.1'),
        'github.com/…/v1.0.0...v1.0.1',
      );
    });

    test('a bare host, a one-segment path, and www', () {
      expect(linkPillLabel('https://example.com'), 'example.com');
      expect(linkPillLabel('https://example.com/'), 'example.com');
      expect(linkPillLabel('https://www.example.com/docs'), 'example.com/docs');
    });

    test('text that is not a web address comes back unchanged', () {
      expect(linkPillLabel('not a link'), 'not a link');
    });
  });

  group('LinkifiedText', () {
    Future<void> pump(WidgetTester tester, String text) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LinkifiedText(text))),
    );

    testWidgets('plain text has no pill', (tester) async {
      await pump(tester, 'Bills paid early count once.');
      expect(find.byType(LinkPill), findsNothing);
      expect(find.text('Bills paid early count once.'), findsOneWidget);
    });

    testWidgets('each address becomes a pill; the full stop stays text', (
      tester,
    ) async {
      await pump(
        tester,
        'Changes: https://example.com/a/b/v2. Docs at https://example.com.',
      );
      final pills = tester.widgetList<LinkPill>(find.byType(LinkPill)).toList();
      expect(pills.map((p) => p.fullUrl), [
        'https://example.com/a/b/v2',
        'https://example.com',
      ]);
      expect(pills.map((p) => p.label), ['example.com/…/v2', 'example.com']);
      expect(pills.every((p) => p.external), isTrue);
    });

    testWidgets('a long press shows the full address', (tester) async {
      await pump(tester, 'See https://example.com/a/b/v2');
      await tester.longPress(find.byType(LinkPill));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('https://example.com/a/b/v2'), findsOneWidget);
    });

    testWidgets('a closing parenthesis stays when the address opened one', (
      tester,
    ) async {
      await pump(
        tester,
        'Read https://example.com/wiki/Foo_(bar) (or https://example.com/x).',
      );
      final urls = tester
          .widgetList<LinkPill>(find.byType(LinkPill))
          .map((p) => p.fullUrl);
      expect(urls, [
        'https://example.com/wiki/Foo_(bar)',
        'https://example.com/x',
      ]);
    });
  });

  testWidgets('TalkBack can open the pill: a link with a tap action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LinkPill(label: 'Set up rules', onTap: () => taps++),
          ),
        ),
      ),
    );
    expect(
      tester.getSemantics(find.byType(LinkPill)),
      isSemantics(label: 'Set up rules', isLink: true, hasTapAction: true),
    );
    await tester.tap(find.text('Set up rules'));
    expect(taps, 1);
    handle.dispose();
  });
}
