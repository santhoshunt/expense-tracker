import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/widgets/glow_tilt.dart';

/// The glow's tilt: readings move it, and it listens only while allowed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  AccelerometerEvent reading(double x, double y) =>
      AccelerometerEvent(x, y, 0, DateTime(2026));

  late StreamController<AccelerometerEvent> readings;
  late SettingsProvider settings;
  ValueListenable<Offset>? tilt;

  Future<void> pump(
    WidgetTester tester, {
    bool disableAnimations = false,
    bool tickers = true,
  }) async {
    settings = SettingsProvider();
    await settings.load();
    readings = StreamController<AccelerometerEvent>.broadcast();
    addTearDown(readings.close);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: TickerMode(
            enabled: tickers,
            child: GlowTilt(
              source: () => readings.stream,
              child: Builder(
                builder: (context) {
                  tilt = GlowTilt.of(context);
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> frames(WidgetTester tester, int n) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('tipping the right edge down slides the glow right', (
    tester,
  ) async {
    await pump(tester);
    expect(readings.hasListener, isTrue, reason: 'on by default');
    readings.add(reading(0, 9.8));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      readings.add(reading(-4, 9.8));
      await tester.pump(const Duration(milliseconds: 66));
    }
    await frames(tester, 30);
    expect(tilt!.value.dx, greaterThan(0.5));
    expect(tilt!.value.dy.abs(), lessThan(0.05));
  });

  testWidgets('switching the setting off stops the sensor and eases back', (
    tester,
  ) async {
    await pump(tester);
    readings.add(reading(0, 9.8));
    for (var i = 0; i < 6; i++) {
      readings.add(reading(-4, 9.8));
      await tester.pump(const Duration(milliseconds: 66));
    }
    await frames(tester, 30);
    expect(tilt!.value.dx, greaterThan(0.5));

    await settings.setTiltGlow(false);
    await tester.pump();
    expect(readings.hasListener, isFalse);
    await frames(tester, 60);
    expect(tilt!.value, Offset.zero);
  });

  testWidgets('Remove animations keeps the sensor off', (tester) async {
    await pump(tester, disableAnimations: true);
    expect(readings.hasListener, isFalse);
  });

  testWidgets('a locked app (tickers off) keeps the sensor off', (
    tester,
  ) async {
    await pump(tester, tickers: false);
    expect(readings.hasListener, isFalse);
  });

  testWidgets('a sensor error leaves the glow where it rests', (tester) async {
    await pump(tester);
    readings.addError(Exception('no accelerometer'));
    await tester.pump();
    expect(readings.hasListener, isFalse);
    await frames(tester, 10);
    expect(tilt!.value, Offset.zero);
  });
}
