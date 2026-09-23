import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../providers/settings_provider.dart';

/// Where readings come from; tests pass their own stream.
typedef TiltSource = Stream<AccelerometerEvent> Function();

/// Turns the phone's tilt into a small offset for the screen glow
/// ([AmbientBackground]), from -1 to 1 on each axis. One sensor subscription
/// for the whole app: it sits above the Navigator, so every route shares it.
///
/// The accelerometer, not the gyroscope: gravity says which way is down, so
/// the glow cannot drift away over time. The offset is measured against a
/// slowly moving average of how the phone is held, so at rest the glow
/// settles back in its corner; only a change of tilt moves it. It moves
/// toward the lower edge, like liquid.
///
/// Needs no permission (Android asks only above 200 readings a second; this
/// reads about 15). Listens only while the setting is on, animations are
/// allowed, the app is in front and not locked (the lock gate turns tickers
/// off beneath it); otherwise the glow eases back and the sensor stops.
class GlowTilt extends StatefulWidget {
  final Widget child;

  /// Null reads the real accelerometer, on Android only.
  final TiltSource? source;

  const GlowTilt({super.key, required this.child, this.source});

  /// The current offset, or null outside a [GlowTilt] (the glow stays put).
  static ValueListenable<Offset>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_GlowTiltScope>()?.offset;

  @override
  State<GlowTilt> createState() => _GlowTiltState();
}

class _GlowTiltState extends State<GlowTilt>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _offset = ValueNotifier(Offset.zero);
  late final Ticker _ticker;
  StreamSubscription<AccelerometerEvent>? _sub;
  Duration _lastTick = Duration.zero;
  bool _resumed = true;

  // Read in didChangeDependencies: lifecycle callbacks may not look them up.
  bool _settingOn = false;
  bool _animationsOff = false;
  bool _tickersOn = true;
  bool _landscape = false;

  /// Smoothed gravity, the slow average of it, and where the glow heads.
  Offset? _gravity;
  Offset? _rest;
  Offset _target = Offset.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _resumed = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settingOn = Provider.of<SettingsProvider>(context).tiltGlow;
    _animationsOff = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _tickersOn = TickerMode.valuesOf(context).enabled;
    _landscape =
        MediaQuery.maybeOrientationOf(context) == Orientation.landscape;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  bool get _wanted => _resumed && _settingOn && !_animationsOff && _tickersOn;

  void _sync() {
    final wanted = _wanted;
    if (wanted && _sub == null) {
      final source =
          widget.source ??
          (!kIsWeb && Platform.isAndroid
              ? () => accelerometerEventStream(
                  samplingPeriod: SensorInterval.uiInterval,
                )
              : null);
      if (source == null) return;
      _gravity = null;
      _rest = null;
      try {
        // A phone without the sensor (or a platform error) leaves the glow
        // where it is.
        _sub = source().listen(
          _onReading,
          onError: (Object _) => _stop(),
          cancelOnError: true,
        );
      } catch (_) {
        _sub = null;
      }
    } else if (!wanted && _sub != null) {
      _stop();
    }
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    _setTarget(Offset.zero);
  }

  void _onReading(AccelerometerEvent e) {
    final g = Offset(e.x, e.y);
    final gravity = _gravity == null ? g : Offset.lerp(_gravity, g, 0.3)!;
    _gravity = gravity;
    // About a 3 s memory at 15 readings a second: holding still, the rest
    // position catches up and the glow returns to its corner.
    final rest = _rest == null ? gravity : Offset.lerp(_rest, gravity, 0.022)!;
    _rest = rest;
    // Readings follow the device's own axes. Upright: tipping the right
    // edge down lowers x, and the glow slides right, toward it; tipping the
    // top back raises y, and the glow slides down. Turned sideways the
    // screen's axes are the device's swapped, with the sign of whichever
    // side is down.
    final d = (gravity - rest) / 3.0;
    final Offset toward;
    if (_landscape) {
      final side = rest.dx >= 0 ? 1.0 : -1.0;
      toward = Offset(side * d.dy, side * d.dx);
    } else {
      toward = Offset(-d.dx, d.dy);
    }
    _setTarget(Offset(toward.dx.clamp(-1.0, 1.0), toward.dy.clamp(-1.0, 1.0)));
  }

  void _setTarget(Offset target) {
    // Sensor noise alone must not keep the screen repainting.
    if ((target - _target).distance < 0.02 && target != Offset.zero) return;
    _target = target;
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    // Eases in about a quarter second whatever the frame rate.
    final k = 1 - math.exp(-dt / 0.12);
    final next = Offset.lerp(_offset.value, _target, k)!;
    if ((next - _target).distance < 0.001) {
      _offset.value = _target;
      _ticker.stop();
    } else {
      _offset.value = next;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _ticker.dispose();
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _GlowTiltScope(offset: _offset, child: widget.child);
}

class _GlowTiltScope extends InheritedWidget {
  final ValueListenable<Offset> offset;

  const _GlowTiltScope({required this.offset, required super.child});

  @override
  bool updateShouldNotify(_GlowTiltScope old) => old.offset != offset;
}
