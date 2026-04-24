import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'viewmodels/map_view_model.dart';
import 'viewmodels/import_export_view_model.dart';
import 'viewmodels/theme_controller.dart';
import 'views/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop (macOS / Linux / Windows) では sqflite を FFI 経由で動かす
  if (!kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // AdMob を初期化（Android/iOS のみ）
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await MobileAds.instance.initialize();
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => MapViewModel()),
        ChangeNotifierProvider(create: (_) => ImportExportViewModel()),
        ChangeNotifierProvider(create: (_) => ThemeController()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeController>(
      builder: (context, themeCtrl, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Routing App',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
            // 進捗画面（Scaffold）・メニュー（Drawer）の背景を黒に固定。
            // FAB など他の UI は `colorScheme.surface`（ダークグレー）を使うので
            // 黒背景の上でもコントラストが出る。
            scaffoldBackgroundColor: Colors.black,
            drawerTheme: const DrawerThemeData(backgroundColor: Colors.black),
          ),
          themeMode: themeCtrl.themeMode,
          home: const HomeScreen(),
        );
      },
    );
  }
}
