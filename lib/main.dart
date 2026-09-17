import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'theme.dart';
import 'home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final accent = prefs.getInt('lumen_accent');
  if (accent != null) gAccent = Color(accent);
  final w = prefs.getDouble('win_w') ?? 1280;
  final h = prefs.getDouble('win_h') ?? 820;

  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: Size(w, h),
      minimumSize: const Size(900, 560),
      title: 'Lumen SSH',
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(const LumenApp());
}

class LumenApp extends StatefulWidget {
  const LumenApp({super.key});
  @override
  State<LumenApp> createState() => _LumenAppState();
}

class _LumenAppState extends State<LumenApp> with WindowListener {
  ThemeMode _mode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _restoreTheme();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _restoreTheme() async {
    final p = await SharedPreferences.getInstance();
    if (p.getString('lumen_theme') == 'light') {
      setState(() => _mode = ThemeMode.light);
    }
  }

  Future<void> _toggle() async {
    setState(() {
      _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
    final p = await SharedPreferences.getInstance();
    await p.setString('lumen_theme', _mode == ThemeMode.dark ? 'dark' : 'light');
  }

  Future<void> _setAccent(Color c) async {
    setState(() => gAccent = c);
    final p = await SharedPreferences.getInstance();
    await p.setInt('lumen_accent', c.toARGB32());
  }

  @override
  void onWindowResized() {
    _saveBounds();
  }

  Future<void> _saveBounds() async {
    final size = await windowManager.getSize();
    final p = await SharedPreferences.getInstance();
    await p.setDouble('win_w', size.width);
    await p.setDouble('win_h', size.height);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lumen SSH',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(false),
      darkTheme: buildTheme(true),
      themeMode: _mode,
      home: HomePage(
        isDark: _mode == ThemeMode.dark,
        onToggleTheme: _toggle,
        onAccentChanged: _setAccent,
      ),
    );
  }
}
