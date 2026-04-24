import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// アプリのテーマモードをアプリ内で管理する ChangeNotifier。
///
/// 端末のダーク設定（`ThemeMode.system`）ではなく、ユーザーが設定した値を
/// SharedPreferences に永続化し、アプリ内で完結させる。
///
/// - 初期値は [ThemeMode.light]（ユーザー指定がなければライト）。
/// - `setThemeMode` で切り替えると、即座に UI に反映され、非同期で永続化。
class ThemeController extends ChangeNotifier {
  ThemeController() {
    _load();
  }

  static const String _prefsKey = 'app_theme_mode';

  ThemeMode _themeMode = ThemeMode.light;
  ThemeMode get themeMode => _themeMode;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    switch (raw) {
      case 'dark':
        _themeMode = ThemeMode.dark;
        break;
      case 'system':
        _themeMode = ThemeMode.system;
        break;
      case 'light':
      default:
        _themeMode = ThemeMode.light;
        break;
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final String raw = switch (mode) {
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
      ThemeMode.light => 'light',
    };
    await prefs.setString(_prefsKey, raw);
  }
}
