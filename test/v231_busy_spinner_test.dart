import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/pdf_export_flow.dart';

/// The busy spinner (PDF export, Settings' backup and import) closes its own
/// dialog when the work ends, never whatever route is on top by then.
void main() {
  // The spinner turns for ever, so pumpAndSettle never settles while it
  // shows: step past route transitions instead.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  late Completer<String> work;
  late Future<String> result;

  Future<void> start(WidgetTester tester) async {
    work = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  result = withBusySpinner(context, 'Working…', () => work.future),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await settle(tester);
    expect(find.text('Working…'), findsOneWidget);
  }

  testWidgets('a page pushed over the spinner stays when the work ends', (
    tester,
  ) async {
    await start(tester);
    // As a home-screen widget does: a page opens over the spinner.
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Pushed page')),
            ),
          ),
    );
    await settle(tester);

    work.complete('done');
    await settle(tester);
    expect(await result, 'done');
    expect(find.text('Working…', skipOffstage: false), findsNothing);
    expect(find.text('Pushed page'), findsOneWidget);
  });

  testWidgets('with nothing pushed the spinner closes', (tester) async {
    await start(tester);
    work.complete('done');
    await settle(tester);
    expect(await result, 'done');
    expect(find.text('Working…', skipOffstage: false), findsNothing);
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets('failed work closes the spinner and passes the error on', (
    tester,
  ) async {
    await start(tester);
    final failed = expectLater(result, throwsStateError);
    work.completeError(StateError('Demo failure'));
    await settle(tester);
    await failed;
    expect(find.text('Working…', skipOffstage: false), findsNothing);
  });
}
