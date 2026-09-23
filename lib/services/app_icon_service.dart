import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A selectable launcher icon. [key] `"default"` is the provided receipt
/// logo carried by MainActivity; the rest are activity-aliases.
class AppIconOption {
  final String key;
  final String label;
  final String previewAsset;
  const AppIconOption(this.key, this.label, this.previewAsset);
}

const List<AppIconOption> kAppIcons = [
  AppIconOption('default', 'Receipt', 'assets/icon_previews/receipt.png'),
  AppIconOption('swoosh', 'Swoosh', 'assets/icon_previews/swoosh.png'),
  AppIconOption('classic', 'Classic ₹', 'assets/icon_previews/classic.png'),
  AppIconOption('midnight', 'Midnight', 'assets/icon_previews/midnight.png'),
  AppIconOption('aurora', 'Aurora', 'assets/icon_previews/aurora.png'),
  AppIconOption('sunset', 'Sunset coin', 'assets/icon_previews/sunset.png'),
  AppIconOption('wallet', 'Wallet', 'assets/icon_previews/wallet.png'),
  AppIconOption('piggy', 'Piggy', 'assets/icon_previews/piggy.png'),
  AppIconOption('pie', 'Pie chart', 'assets/icon_previews/pie.png'),
  AppIconOption('forest', 'Forest', 'assets/icon_previews/forest.png'),
];

/// Switches the launcher icon by toggling Android activity-aliases. The
/// enabled component is the source of truth — nothing extra is persisted.
class AppIconService {
  static const _channel = MethodChannel('expense_tracker/sms');

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<String> current() async {
    if (!isSupported) return 'default';
    try {
      return await _channel.invokeMethod<String>('getAppIcon') ?? 'default';
    } on MissingPluginException {
      return 'default';
    }
  }

  /// Returns whether the switch actually happened. Callers must only mark
  /// the new icon as selected on true — swallowing the failure into a void
  /// return made the tile show an icon the launcher never got.
  Future<bool> select(String key) async {
    if (!isSupported) return false;
    try {
      await _channel.invokeMethod<void>('setAppIcon', {'icon': key});
      return true;
    } on PlatformException {
      // Component toggling can fail on locked-down ROMs — the tile simply
      // keeps showing the current icon rather than crashing the screen.
      return false;
    } on MissingPluginException {
      // Symmetric with current(): headless/test environments.
      return false;
    }
  }
}
