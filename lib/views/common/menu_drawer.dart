import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../repositories/database_repository.dart';
import '../../viewmodels/import_export_view_model.dart';
import '../../viewmodels/map_view_model.dart';

class MenuDrawer extends StatelessWidget {
  const MenuDrawer({super.key});

  /// Import の二重起動（file_picker の PlatformException(already_active) 対策）
  static bool _isImporting = false;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.blue),
            child: Text('Routing Menu',
                style: TextStyle(color: Colors.white, fontSize: 24)),
          ),
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
                }
                _isImporting = false;
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download),
            title: const Text('Export .mapping'),
            subtitle: const Text('Android・iOS両対応'),
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
                title: const Text('タイル解像度'),
                subtitle: Text(_resolutionLabel(vm.tileResolution)),
                children: [
                  for (final int ts in MapViewModel.tileResolutionOptions)
                    ListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.only(left: 72, right: 16),
                      title: Text(_resolutionLabel(ts)),
                      trailing: vm.tileResolution == ts
                          ? const Icon(Icons.check, color: Colors.blue)
                          : null,
                      onTap: () => vm.setTileResolution(ts),
                    ),
                ],
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('全記録をクリア',
                style: TextStyle(color: Colors.red)),
            subtitle: const Text('すべての DB を削除します'),
            onTap: () async {
              final mapVm =
                  Provider.of<MapViewModel>(context, listen: false);
              final messenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(context);

              // 確認ダイアログ
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('全記録をクリア'),
                  content: const Text(
                      '記録済みのデータを全て削除します。この操作は取り消せません。よろしいですか？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('キャンセル'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('削除する',
                          style: TextStyle(color: Colors.red)),
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
                  const SnackBar(content: Text('全ての記録を削除しました')),
                );
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(
                      content: Text('削除失敗: $e'),
                      backgroundColor: Colors.red),
                );
              } finally {
                await mapVm.setBusy(false);
                mapVm.refreshMap();
              }
            },
          ),
        ],
      ),
    );
  }

  static String _resolutionLabel(int ts) {
    switch (ts) {
      case 320:
        return '低 (320px)';
      case 480:
        return '中 (480px)';
      case 512:
        return '高 (512px)';
      default:
        return '${ts}px';
    }
  }
}
