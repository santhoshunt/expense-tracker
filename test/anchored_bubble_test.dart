import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/info_tip.dart';

/// The anchored bubble's open transition.
void main() {
  testWidgets('the open transition builds no CurvedAnimation per frame', (
    tester,
  ) async {
    // A CurvedAnimation registers a status listener on the route's
    // animation when it is made, and nothing here disposes it.
    var curved = 0;
    void count(ObjectEvent event) {
      if (event is ObjectCreated && event.className == 'CurvedAnimation') {
        curved++;
      }
    }

    FlutterMemoryAllocations.instance.addListener(count);
    addTearDown(() => FlutterMemoryAllocations.instance.removeListener(count));

    final host = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(key: host)),
      ),
    );
    unawaited(
      showAnchoredBubble(
        host.currentContext!,
        anchor: const Rect.fromLTWH(20, 20, 32, 32),
        content: (_) => const Text('Bubble body'),
      ),
    );
    await tester.pump();
    final atStart = curved;
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Bubble body'), findsOneWidget);
    expect(curved, atStart);
  });
}
