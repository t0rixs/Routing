import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../generated/l10n/app_localizations.dart';
import '../../repositories/database_repository.dart';
import '../../viewmodels/import_export_view_model.dart';
import '../../viewmodels/map_view_model.dart';
import '../../viewmodels/theme_controller.dart';
import 'map_style_settings_screen.dart';

class MenuDrawer extends StatelessWidget {
  const MenuDrawer({super.key});

  /// Import の二重起動（file_picker の PlatformException(already_active) 対策）
  static bool _isImporting = false;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final l = AppLocalizations.of(context)!;
    return Drawer(
      backgroundColor: isDark ? Colors.black : null,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Colors.blue),
            child: Text(l.appTitle,
                style: const TextStyle(color: Colors.white, fontSize: 24)),
          ),
          // 位置情報記録の ON/OFF スイッチ。
          // OFF にすると GPS 購読を止め、foreground service 通知も消える。
          // 状態は SharedPreferences に永続化される。
          Consumer<MapViewModel>(
            builder: (context, vm, _) {
              final on = vm.recordingEnabled;
              return SwitchListTile(
                secondary: Icon(
                  on ? Icons.fiber_manual_record : Icons.stop_circle_outlined,
                  color: on ? Colors.red : null,
                ),
                title: Text(l.menuRecordLocation),
                subtitle: Text(on ? l.menuRecording : l.menuStopped),
                value: on,
                onChanged: (v) async {
                  if (v) {
                    await vm.startRecording();
                  } else {
                    await vm.stopRecording();
                  }
                },
              );
            },
          ),
          const Divider(height: 0),
          ListTile(
            leading: const Icon(Icons.file_upload),
            title: const Text('Import .mapping'),
            onTap: () async {
              // 二重起動ガード: file_picker が別の呼び出しを処理中だと
              // PlatformException(already_active) が返るため
              if (_isImporting) {
                debugPrint('Menu: Import already in progress, ignored.');
                Navigator.pop(context);
                return;
              }
              _isImporting = true;

              // Contextが有効なうちにViewModel・Messenger を取得しておく
              final importVm =
                  Provider.of<ImportExportViewModel>(context, listen: false);
              final mapVm = Provider.of<MapViewModel>(context, listen: false);
              final messenger = ScaffoldMessenger.of(context);

              Navigator.pop(context); // Close drawer

              debugPrint('Menu: Import tapped, drawer closed. Waiting...');

              // ピッカーを開くより先に busy にする。
              // 理由: FilePicker の表示中（数秒〜数十秒）も GPS は発火し続け、
              // _recordCellsForMovement が大量の DB 書き込みを
              // メインスレッドにキューイングしてしまう。
              // その結果、選択確定直後に closeAll と importFile を呼んでも、
              // キューが捌けるまで overlay の再描画フレームが走らない。
              // ここで先行停止することで、ピッカー表示中にバックログが溜まらない。
              await mapVm.setBusy(true);
              bool busyActivated = true;

              // ファイルピッカー起動
              // "File picker already active" エラー回避のため少し待つ
              await Future.delayed(const Duration(milliseconds: 500));

              try {
                debugPrint('Menu: Opening file picker...');
                final result =
                    await FilePicker.platform.pickFiles(type: FileType.any);

                if (result != null && result.files.single.path != null) {
                  final path = result.files.single.path!;
                  debugPrint('Menu: File picked: $path');

                  await importVm.importFile(path);

                  if (importVm.successMessage != null) {
                    debugPrint('Menu: Import success');
                    messenger.showSnackBar(
                      SnackBar(content: Text(importVm.successMessage!)),
                    );
                  } else if (importVm.errorMessage != null) {
                    debugPrint('Menu: Import failed: ${importVm.errorMessage}');
                    messenger.showSnackBar(
                      SnackBar(
                          content: Text(importVm.errorMessage!),
                          backgroundColor: Colors.red),
                    );
                  }
                } else {
                  debugPrint('Menu: File picker cancelled or no file selected');
                }
              } catch (e) {
                debugPrint('Pick file error: $e');
                messenger.showSnackBar(
                  SnackBar(
                      content: Text('Error: $e'),
                      backgroundColor: Colors.red),
                );
              } finally {
                if (busyActivated) {
                  // GPS 再開 + TileOverlay 再生成（新しい DB から描画が組み立てられる）
                  await mapVm.setBusy(false);
                  mapVm.refreshMap();
                  // HUD の {unique}/{visits} をインポート後の DB から再計算し、
                  // SharedPreferences キャッシュも更新する。
                  mapVm.refreshTotalStats(immediate: true);
                }
                _isImporting = false;
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download),
            title: const Text('Export .mapping'),
            onTap: () async {
              Navigator.pop(context); // Close drawer

              final importVm =
                  Provider.of<ImportExportViewModel>(context, listen: false);
              final mapVm = Provider.of<MapViewModel>(context, listen: false);

              // エクスポート中も GPS と描画を停止する（DB を close するため）。
              await mapVm.setBusy(true);
              try {
                await importVm.exportFile();
              } finally {
                await mapVm.setBusy(false);
              }

              if (!context.mounted) return;

              if (importVm.successMessage != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(importVm.successMessage!)),
                );
              } else if (importVm.errorMessage != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(importVm.errorMessage!),
                      backgroundColor: Colors.red),
                );
              }
            },
          ),
          const Divider(),
          // 解像度選択: ExpansionTile 内に 3 択のラジオ風 ListTile を並べる
          Consumer<MapViewModel>(
            builder: (context, vm, _) {
              return ExpansionTile(
                leading: const Icon(Icons.hd),
                title: Text(l.menuTileResolution),
                subtitle: Text(_resolutionLabel(vm.tileResolution, l)),
                children: [
                  for (final int ts in MapViewModel.tileResolutionOptions)
                    ListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.only(left: 72, right: 16),
                      title: Text(_resolutionLabel(ts, l)),
                      trailing: vm.tileResolution == ts
                          ? const Icon(Icons.check, color: Colors.blue)
                          : null,
                      onTap: () => vm.setTileResolution(ts),
                    ),
                ],
              );
            },
          ),
          // アプリ全体のダークモード（UI テーマ＋ベースマップ）を一括切替。
          // ThemeController（UI テーマ）と MapBaseStyle（マップ地図タイル）の
          // 両方を同時に更新し、SharedPreferences へ個別に永続化する。
          Consumer2<ThemeController, MapViewModel>(
            builder: (context, themeCtrl, vm, _) {
              final bool isDark = themeCtrl.themeMode == ThemeMode.dark;
              return SwitchListTile(
                secondary: Icon(
                  isDark ? Icons.dark_mode : Icons.light_mode,
                ),
                title: Text(l.menuDarkMode),
                subtitle: Text(isDark ? l.menuDarkModeOn : l.menuDarkModeOff),
                value: isDark,
                onChanged: (v) {
                  themeCtrl.setThemeMode(v ? ThemeMode.dark : ThemeMode.light);
                  vm.syncThemeIsDark(v);
                  vm.setMapBaseStyle(
                    v ? MapBaseStyle.dark : MapBaseStyle.standard,
                  );
                },
              );
            },
          ),
          // マップ表示の詳細設定（別画面へ遷移）
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(l.menuMapStyleSettings),
            subtitle: Text(l.menuMapStyleSettingsSubtitle),
            onTap: () {
              Navigator.pop(context); // drawer を閉じる
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const MapStyleSettingsScreen(),
                ),
              );
            },
          ),
          const Divider(),
          // z=14 → z=3..13 の親ズームデータを再構築する。
          // 旧バージョンで z=14 しか記録していなかった DB を修復するため。
          ListTile(
            leading: const Icon(Icons.layers),
            title: Text(l.menuRebuildLowZoom),
            subtitle: Text(l.menuRebuildSubtitle),
            onTap: () async {
              final mapVm =
                  Provider.of<MapViewModel>(context, listen: false);
              final messenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(context);

              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(l.menuRebuildLowZoom),
                  content: Text(l.menuRebuildLowZoomBody),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(l.cancel),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(l.execute),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;

              navigator.pop(); // close drawer

              // 進捗ダイアログ
              final progress = ValueNotifier<(int, int)>((0, 0));
              // ignore: unawaited_futures, use_build_context_synchronously
              showDialog<void>(
                context: navigator.context,
                barrierDismissible: false,
                builder: (ctx) => AlertDialog(
                  title: Text(l.menuRebuildInProgress),
                  content: ValueListenableBuilder<(int, int)>(
                    valueListenable: progress,
                    builder: (_, v, __) {
                      final (p, t) = v;
                      final double? frac =
                          t > 0 ? (p / t).clamp(0.0, 1.0) : null;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LinearProgressIndicator(value: frac),
                          const SizedBox(height: 12),
                          Text(t > 0
                              ? l.menuRebuildShards(p, t)
                              : l.menuRebuildScanning),
                        ],
                      );
                    },
                  ),
                ),
              );

              try {
                await mapVm.rebuildParentZooms(
                  onProgress: (p, t) => progress.value = (p, t),
                );
                if (navigator.canPop()) navigator.pop(); // close progress
                messenger.showSnackBar(SnackBar(
                    content: Text(l.menuRebuildSuccess)));
              } catch (e) {
                if (navigator.canPop()) navigator.pop();
                messenger.showSnackBar(SnackBar(
                    content: Text(l.menuRebuildFailed(e.toString())),
                    backgroundColor: Colors.red));
              } finally {
                progress.dispose();
              }
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: Text(l.menuClearAll,
                style: const TextStyle(color: Colors.red)),
            subtitle: Text(l.menuClearAllSubtitle),
            onTap: () async {
              final mapVm =
                  Provider.of<MapViewModel>(context, listen: false);
              final messenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(context);

              // 確認ダイアログ
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(l.menuClearAll),
                  content: Text(l.menuClearAllConfirmBody),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(l.cancel),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(l.delete,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );

              if (confirmed != true) return;

              navigator.pop(); // drawer を閉じる

              await mapVm.setBusy(true);
              try {
                await DatabaseRepository().clearAllData();
                messenger.showSnackBar(
                  SnackBar(content: Text(l.menuClearAllDone)),
                );
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(
                      content: Text(l.menuClearAllFailed(e.toString())),
                      backgroundColor: Colors.red),
                );
              } finally {
                await mapVm.setBusy(false);
                mapVm.refreshMap();
                // HUD の {unique}/{visits} を 0/0 に即時反映し、キャッシュも更新。
                mapVm.refreshTotalStats(immediate: true);
              }
            },
          ),
        ],
      ),
    );
  }

  static String _resolutionLabel(int ts, AppLocalizations l) {
    switch (ts) {
      case 320:
        return l.tileResLow;
      case 480:
        return l.tileResMid;
      case 512:
        return l.tileResHigh;
      default:
        return '${ts}px';
    }
  }
}
